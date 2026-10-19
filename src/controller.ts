import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { Journal, verifyJournalFile, type JournalRecord } from './journal.ts';
import { EvidenceLedger } from './evidence.ts';
import { BudgetGovernor, type Amount } from './budget.ts';
import { assertRepositoryApproved, canonicalRepoPath, loadPolicy, policyHash, savePolicy, withApprovedRepository, type Policy } from './policy.ts';
import { assertPrivateStateRoot, readJournalKey, statePaths, type StateRootPaths } from './stateRoot.ts';
import { assertTransition, type TaskState } from './states.ts';
import { openStore } from './store/open.ts';
import type { TaskCounters, TaskRecord, TaskStore } from './store/types.ts';
import { planHash, topoOrder, validatePlan, type Plan } from './plan.ts';
import { FileLock } from './util/lock.ts';
import { assertPrivateDir, writeFileAtomic } from './util/fsx.ts';
import type { RunResult, Runner } from './runner/types.ts';

export interface TransitionRecord {
  taskId: string;
  from: TaskState;
  to: TaskState;
  reason: string;
  counters?: Partial<TaskCounters>;
  /** Set on ready -> implementing: this record is the attempt start. */
  attempt?: number;
  reservationId?: string;
  escalationId?: string;
}

export interface AttemptEndRecord {
  taskId: string;
  attempt: number;
  result: RunResult | { kind: 'infra'; reason: 'interrupted'; cost: null };
  synthesized: boolean;
  /** A cost the runner reported that was not a valid amount; charged as unknown instead. */
  invalidCost?: string;
}

export type EscalationCategory = 'budget' | 'attempts' | 'repeated-failure' | 'infra' | 'evidence' | 'policy';

export interface EscalationRecord {
  id: string;
  taskId: string;
  category: EscalationCategory;
  detail: string;
  question: string;
}

export interface ResumeReport {
  tornTailRepaired: boolean;
  tasksCreated: string[];
  transitionsReplayed: string[];
  interrupted: string[];
  reservationsNotStarted: string[];
  claimsReleased: string[];
  advanced: string[];
}

export interface RunSummary {
  steps: number;
  states: Record<string, TaskState>;
  stalled: string[];
}

export class ControllerError extends Error {}

/** A refusal to work on a state root whose store, evidence or journal no crash can explain. */
export class RecoveryRefusedError extends ControllerError {}

/**
 * Write a forensic record under <root>/forensics, beside the journal and the store and never
 * into them. Returns a sentence for the refusal message; a failure to write is reported in it
 * rather than replacing the refusal.
 */
function writeForensic(root: string, kind: string, body: unknown): string {
  try {
    const dir = path.join(root, 'forensics');
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    // Never through a link out of the state root, or into a directory others can change.
    assertPrivateDir(dir);
    const file = path.join(dir, `${new Date().toISOString().replace(/[:.]/g, '-')}-${process.pid}-${kind}.json`);
    writeFileAtomic(file, JSON.stringify(body, null, 2));
    return `Forensic record: ${file}.`;
  } catch (err) {
    return `The forensic record could not be written (${(err as Error).message}).`;
  }
}

/** The journal file as found, for forensic records. */
function journalContent(file: string): string | null {
  try {
    return fs.readFileSync(file).toString('base64');
  } catch {
    return null;
  }
}

/** Facts about the journal file as found, for forensic records. */
function journalFileFacts(file: string): { bytes: number; sha256: string } | { error: string } {
  try {
    const buf = fs.readFileSync(file);
    return { bytes: buf.length, sha256: createHash('sha256').update(buf).digest('hex') };
  } catch (err) {
    return { error: (err as Error).message };
  }
}

/**
 * The controller owns every state change. It is single-instance per state root (controller
 * lock), journals each intent before acting, and can resume from any step boundary.
 */
export class Controller {
  readonly paths: StateRootPaths;
  policy: Policy;
  readonly journal: Journal;
  readonly store: TaskStore;
  readonly evidence: EvidenceLedger;
  readonly budget: BudgetGovernor;
  readonly owner: string;
  readonly tornTailRepaired: boolean;
  /** The interrupted transition this open finished, if any ("task:from->to"). */
  private readonly finishedOnOpen: string | undefined;
  private readonly lock: FileLock;

  private constructor(paths: StateRootPaths, lock: FileLock, opts: { store?: TaskStore; allowPolicyDrift?: boolean }) {
    this.paths = paths;
    this.lock = lock;
    this.owner = `ctl:${os.hostname()}:${process.pid}:${randomUUID().slice(0, 8)}`;
    const key = readJournalKey(paths);
    const before = verifyJournalFile(paths.journal, key);
    // A tampered journal is refused here, before anything else.
    if (!before.ok) Journal.open(paths.journal, key);
    this.policy = loadPolicy(paths.policy);
    // With the journal's records, openStore checks the store binding before it creates or
    // repairs anything.
    this.store = opts.store ?? openStore(paths, { create: true, records: before.records, evidenceOrEscalations: this.evidenceAttempts().length + this.escalationFiles().length > 0 });
    this.evidence = new EvidenceLedger(paths.evidence, key);
    this.planIndex = journaledTasks(before.records);
    // Before this controller writes anything (a torn-tail repair, policy records, the store
    // binding, or any command run on it), the state root must be one a crash can explain.
    this.assertRecoverable('open', before.records);
    if (before.tornTail) {
      // A crash during an append: the repair below drops the partial line. Keep the file's
      // bytes as found first; if that is impossible, do not repair.
      const raw = fs.readFileSync(paths.journal);
      const note = writeForensic(paths.root, 'torn-journal', {
        records: before.records.length,
        file: { bytes: raw.length, sha256: createHash('sha256').update(raw).digest('hex') },
        journalBase64: raw.toString('base64'),
      });
      if (!note.startsWith('Forensic record:')) throw new ControllerError(`the journal has a torn final line, and it could not be preserved before repair. ${note}`);
    }
    this.journal = Journal.open(paths.journal, key, { repairTornTail: true });
    this.tornTailRepaired = before.tornTail;
    // A crash can leave the journal's last transition unapplied. Finish it now, so a command
    // run before resume (eo unblock) cannot journal a transition after it and make it look
    // like an older one that was never applied.
    this.finishedOnOpen = this.finishLastTransition();
    this.budget = new BudgetGovernor(this.journal, this.policy.budget);
    const now = policyHash(this.policy);
    const { committed, pending } = policyRecords(this.journal.records());
    if (committed === undefined) {
      this.journal.append('policy.set', { hash: now, reason: 'initial' });
    } else if (now !== committed) {
      if (pending && pending.hash === now) {
        // A controller change was journaled and written but not committed before a crash.
        this.journal.append('policy.set', { hash: now, reason: `completed: ${pending.reason}` });
      } else if (!opts.allowPolicyDrift) {
        throw new ControllerError('policy.json differs from the last policy recorded in the journal; a human must review it and run "eo policy accept"');
      }
    }
    // The store kind is bound to the state root on first open; swapping it later would hide
    // the journaled tasks from the controller.
    const bound = this.journal.ofType<{ kind: string }>('store.bound')[0];
    if (!bound) this.journal.append('store.bound', { kind: this.store.kind });
    else if (bound.data.kind !== this.store.kind) throw new ControllerError(`this state root uses the ${bound.data.kind} store, not ${this.store.kind}`);
    this.planIndex = journaledTasks(this.journal.records());
  }

  /** Task facts as approved in journaled plans; authoritative over the store's copy. */
  private planIndex: Map<string, PlannedTask>;

  /** Acquire the controller lock and open state. Throws if another controller is running. */
  static open(root: string, opts: { store?: TaskStore; allowPolicyDrift?: boolean } = {}): Controller {
    const paths = statePaths(root);
    // Before anything is written: a root others can change is never used.
    if (fs.existsSync(paths.root)) {
      try {
        assertPrivateStateRoot(paths);
      } catch (err) {
        throw new ControllerError(`unsafe state root: ${(err as Error).message}`);
      }
    }
    fs.mkdirSync(paths.locks, { recursive: true });
    const lock = new FileLock(paths.controllerLock, `controller:${process.pid}`);
    if (!lock.tryAcquire()) throw new ControllerError(`another controller holds ${paths.controllerLock}`);
    try {
      return new Controller(paths, lock, opts);
    } catch (err) {
      try {
        // Every refusal to open leaves a record; a recovery refusal has written its own.
        if (!(err instanceof RecoveryRefusedError) && fs.existsSync(paths.root)) {
          const note = writeForensic(paths.root, 'open-refused', { error: (err as Error).message, journal: journalFileFacts(paths.journal) });
          if (err instanceof Error) err.message = `${err.message} ${note}`;
        }
      } finally {
        lock.release();
      }
      throw err;
    }
  }

  close(): void {
    this.lock.release();
  }

  // ---------------------------------------------------------------- policy

  /** Approve a repository. The CLI only calls this after an interactive human confirmation. */
  approveRepository(repoPath: string, approvedBy: string): Policy {
    const next = withApprovedRepository(this.policy, repoPath, approvedBy, new Date(), this.paths.root);
    const reason = `approve-repo ${path.resolve(repoPath)} by ${approvedBy}`;
    // Write-ahead: intent, file, commit. A crash in between is completed or ignored on open.
    this.journal.append('policy.pending', { hash: policyHash(next), reason });
    savePolicy(this.paths.policy, next);
    this.journal.append('policy.set', { hash: policyHash(next), reason });
    this.policy = next;
    return next;
  }

  /**
   * Human action: accept policy.json as it is now on disk. Requires a controller opened with
   * allowPolicyDrift; the CLI confirms interactively first.
   */
  acceptPolicy(by: string): string {
    const hash = policyHash(this.policy);
    this.journal.append('policy.set', { hash, reason: `accepted by ${by}` });
    return hash;
  }

  // ---------------------------------------------------------------- plan

  /** Import an approved plan. Write-ahead: the journal record precedes store creation. */
  importPlan(planValue: unknown, repoPath: string, approvedBy: string): Plan {
    assertRepositoryApproved(this.policy, repoPath);
    const plan = validatePlan(planValue);
    // Ids from any journaled plan count as taken, even if a crash kept their tasks out of the store.
    const journaled = journaledTasks(this.journal.records());
    for (const t of plan.tasks) {
      if (this.store.get(t.id) || journaled.has(t.id)) throw new ControllerError(`task ${t.id} already exists`);
    }
    this.journal.append('plan.import', { epicId: plan.epicId, planHash: planHash(plan), approvedBy, repoPath: canonicalRepoPath(repoPath), plan });
    this.planIndex = journaledTasks(this.journal.records());
    this.materialisePlan(plan);
    return plan;
  }

  private materialisePlan(plan: Plan): string[] {
    const created: string[] = [];
    for (const t of topoOrder(plan.tasks)) {
      if (!this.store.get(t.id)) {
        this.store.createTask({ id: t.id, epicId: plan.epicId, title: t.title, deps: t.deps });
        created.push(t.id);
      }
    }
    return created;
  }

  // ---------------------------------------------------------------- transitions

  /** Journal the transition, then apply it to the store. */
  transition(rec: TransitionRecord): void {
    const t = this.mustGet(rec.taskId);
    if (t.state !== rec.from) throw new ControllerError(`${rec.taskId} is ${t.state}, expected ${rec.from}`);
    assertTransition(rec.taskId, rec.from, rec.to);
    if (rec.to === 'blocked' && !rec.escalationId) throw new ControllerError('a transition to blocked needs an escalation record');
    const appended = this.journal.append('task.transition', rec);
    const counters = { ...(rec.counters ?? {}), ...(rec.attempt !== undefined ? { attempt: rec.attempt } : {}), journalSeq: appended.seq };
    if (!this.store.compareAndSetState(rec.taskId, rec.from, rec.to, counters)) {
      throw new ControllerError(`store changed under the controller for ${rec.taskId}`);
    }
  }

  escalate(taskId: string, from: TaskState, category: EscalationCategory, detail: string, question: string, counters?: Partial<TaskCounters>): EscalationRecord {
    // Reuse an escalation journaled for this task whose blocking transition never landed (crash in between).
    const pending = this.pendingEscalation(taskId, category);
    const esc: EscalationRecord = pending ?? { id: `esc-${taskId}-${this.journal.records().length + 1}`, taskId, category, detail, question };
    if (!pending) this.journal.append('escalation', esc);
    this.writeEscalationFile(esc);
    this.transition({ taskId, from, to: 'blocked', reason: `escalation ${category}`, escalationId: esc.id, ...(counters ? { counters } : {}) });
    return esc;
  }

  private pendingEscalation(taskId: string, category: EscalationCategory): EscalationRecord | undefined {
    const recs = this.journal.records();
    for (let i = recs.length - 1; i >= 0; i--) {
      const r = recs[i] as JournalRecord;
      if (r.type === 'task.transition' && (r.data as TransitionRecord).taskId === taskId) return undefined;
      if (r.type === 'escalation') {
        const e = r.data as EscalationRecord;
        if (e.taskId === taskId) return e.category === category ? e : undefined;
      }
    }
    return undefined;
  }

  private writeEscalationFile(esc: EscalationRecord): void {
    writeFileAtomic(path.join(this.paths.escalations, `${esc.id}.json`), JSON.stringify(esc, null, 2));
  }

  /** Human action: move a blocked task back to ready. The CLI confirms interactively first. */
  unblock(taskId: string, by: string, note: string): void {
    this.journal.append('human.unblock', { taskId, by, note });
    this.transition({ taskId, from: 'blocked', to: 'ready', reason: `unblocked by ${by}: ${note}`, counters: { correctionFailures: 0, infraFailures: 0, repeatCount: 0, lastFailureSignature: null } });
  }

  // ---------------------------------------------------------------- resume

  /** Every evidence attempt directory on disk, as "task#attempt". */
  private evidenceAttempts(): string[] {
    return listEvidenceAttempts(this.paths.evidence);
  }

  /** Every escalation file on disk, by escalation id. */
  private escalationFiles(): string[] {
    return listEscalationFiles(this.paths.escalations);
  }

  /** Apply the one transition a crash can leave unapplied (checked by assertRecoverable). */
  private finishLastTransition(): string | undefined {
    for (const [taskId, exp] of expectedStates(this.journal.records())) {
      const t = this.store.get(taskId);
      if (t && storeDrift(t, exp) === 'behind') {
        if (!this.store.compareAndSetState(taskId, t.state, exp.state, exp.counters)) {
          throw new ControllerError(`store changed under the controller for ${taskId} while finishing an interrupted transition`);
        }
        return `${taskId}:${t.state}->${exp.state}`;
      }
    }
    return undefined;
  }

  /**
   * Refuse a state root whose store, evidence or escalation files no crash can explain from
   * this journal (see recoveryProblems), before anything is written. The refusal keeps what a
   * human needs to investigate: the problems, the journal's head, and the store as found.
   */
  private assertRecoverable(kind: string, records: readonly JournalRecord[] = this.journal.records()): void {
    const tasks = this.store.list();
    const mismatches = planMismatches(tasks, this.planIndex);
    const problems = mismatches.length > 0 ? mismatches : recoveryProblems(records, tasks, this.evidenceAttempts(), this.escalationFiles());
    if (problems.length === 0) return;
    const last = records[records.length - 1];
    const note = writeForensic(this.paths.root, `${kind}-refused`, {
      kind,
      at: new Date().toISOString(),
      problems,
      journal: { records: records.length, lastSeq: last?.seq ?? 0, lastMac: last?.mac ?? null, file: journalFileFacts(this.paths.journal), content: journalContent(this.paths.journal) },
      policyHash: policyHash(this.policy),
      store: tasks,
      evidenceAttempts: this.evidenceAttempts(),
      escalationFiles: this.escalationFiles(),
    });
    if (mismatches.length > 0) {
      throw new RecoveryRefusedError(`task store does not match the journaled plans (${mismatches.join('; ')}); nothing was changed. ${note} Investigate with "eo doctor"`);
    }
    throw new RecoveryRefusedError(
      `task store is ahead of or diverged from the journal (${problems.join('; ')}); nothing was changed. This needs a human: the store, evidence or escalations were changed behind the controller, or the journal was truncated or restored from an older copy. ${note} Investigate with "eo doctor"`,
    );
  }

  /**
   * Bring the store in line with the journal and settle anything a crash left open.
   * Safe to run any number of times.
   */
  resume(): ResumeReport {
    const report: ResumeReport = {
      tornTailRepaired: this.tornTailRepaired,
      tasksCreated: [],
      transitionsReplayed: this.finishedOnOpen ? [this.finishedOnOpen] : [],
      interrupted: [],
      reservationsNotStarted: [],
      claimsReleased: [],
      advanced: [],
    };
    const records = [...this.journal.records()];

    // 1. Before anything is written: refuse any combination of store, evidence and journal that
    //    no crash can produce (the journal is written ahead of both). Recovering from one would
    //    rewind finished work, re-run attempts or lose spend, so a human must decide.
    this.assertRecoverable('resume');

    // 2. Tasks from imported plans, escalation files, and the one transition a crash can leave
    //    unapplied per task.
    for (const r of records) {
      if (r.type === 'plan.import') report.tasksCreated.push(...this.materialisePlan((r.data as { plan: Plan }).plan));
    }
    for (const r of records) {
      if (r.type === 'escalation') {
        const esc = r.data as EscalationRecord;
        if (!fs.existsSync(path.join(this.paths.escalations, `${esc.id}.json`))) this.writeEscalationFile(esc);
      }
    }
    const expected = expectedStates(records);
    for (const [taskId, exp] of expected) {
      const t = this.mustGet(taskId);
      if (storeDrift(t, exp) === 'behind') {
        if (!this.store.compareAndSetState(taskId, t.state, exp.state, exp.counters)) {
          throw new ControllerError(`store changed under the controller for ${taskId} during resume`);
        }
        report.transitionsReplayed.push(`${taskId}:${t.state}->${exp.state}`);
      }
    }

    // 3. Claims: no other controller can be alive (we hold the lock), so every claim is stale.
    for (const t of this.store.list()) {
      if (t.claim) {
        this.store.release(t.id, t.claim.owner);
        report.claimsReleased.push(t.id);
      }
    }

    // 4. Reservations journaled without an attempt start never launched anything.
    const startedReservations = new Set(
      records.filter((r) => r.type === 'task.transition' && (r.data as TransitionRecord).reservationId).map((r) => (r.data as TransitionRecord).reservationId as string),
    );
    for (const res of this.budget.ledger.openReservations()) {
      if (!startedReservations.has(res.id)) {
        this.budget.settle(res.id, null, true);
        report.reservationsNotStarted.push(res.id);
      }
    }

    // 5. Attempts started without an outcome were interrupted.
    const ends = new Set(records.filter((r) => r.type === 'attempt.end').map((r) => attemptKey(r.data as AttemptEndRecord)));
    for (const r of records) {
      if (r.type !== 'task.transition') continue;
      const tr = r.data as TransitionRecord;
      if (tr.to !== 'implementing' || tr.attempt === undefined) continue;
      const key = `${tr.taskId}#${tr.attempt}`;
      if (ends.has(key)) continue;
      const end: AttemptEndRecord = { taskId: tr.taskId, attempt: tr.attempt, result: { kind: 'infra', reason: 'interrupted', cost: null }, synthesized: true };
      this.journal.append('attempt.end', end);
      ends.add(key);
      report.interrupted.push(key);
    }

    // 6. Finish post-attempt processing for every task that has an ended latest attempt.
    for (const t of this.store.list()) {
      if (['implementing', 'verifying', 'reviewing', 'security_review', 'accepted', 'integrating'].includes(t.state)) {
        if (this.advance(t.id)) report.advanced.push(t.id);
      }
    }
    this.journal.append('resume', report);
    return report;
  }

  // ---------------------------------------------------------------- scheduling

  /** Promote planned tasks whose dependencies are all done. */
  promote(): string[] {
    const tasks = this.store.list();
    const states = new Map(tasks.map((t) => [t.id, t.state]));
    const promoted: string[] = [];
    for (const t of tasks) {
      const deps = this.planIndex.get(t.id)?.deps ?? t.deps;
      if (t.state === 'planned' && deps.every((d) => states.get(d) === 'done')) {
        this.transition({ taskId: t.id, from: 'planned', to: 'ready', reason: 'dependencies done' });
        promoted.push(t.id);
      }
    }
    return promoted;
  }

  /**
   * Run until no task can make progress. Sequential (one worker at a time) in M1; M5 adds
   * concurrency. Always resumes first.
   */
  async run(runner: Runner, opts: { maxSteps?: number; repoPath: string }): Promise<RunSummary> {
    assertRepositoryApproved(this.policy, opts.repoPath);
    const runRepo = canonicalRepoPath(opts.repoPath);
    this.resume();
    this.journal.append('run.start', { owner: this.owner, runner: runner.kind });
    let steps = 0;
    const deferred = new Set<string>();
    for (;;) {
      if (opts.maxSteps !== undefined && steps >= opts.maxSteps) break;
      this.promote();
      const t = this.store.claimReady(this.owner, this.policy.leaseMs, Date.now(), deferred);
      if (!t) break;
      const planned = this.planIndex.get(t.id);
      if (!planned || planned.repoPath !== runRepo) {
        // Tasks run only against the repository their plan was approved for.
        this.store.release(t.id, this.owner);
        deferred.add(t.id);
        this.journal.append('run.skip', { taskId: t.id, reason: `planned for ${planned?.repoPath ?? 'unknown repository'}` });
        continue;
      }
      // The run's repository was checked as approved above, so this task's repository is too.
      steps++;
      await this.runAttempt(t, runner, deferred);
    }
    const summary = this.summary(steps);
    this.journal.append('run.end', summary);
    return summary;
  }

  summary(steps = 0): RunSummary {
    const tasks = this.store.list();
    const states = Object.fromEntries(tasks.map((t) => [t.id, t.state])) as Record<string, TaskState>;
    const stalled = tasks.filter((t) => t.state === 'planned' && t.deps.some((d) => states[d] === 'blocked')).map((t) => t.id);
    return { steps, states, stalled };
  }

  private async runAttempt(t: TaskRecord, runner: Runner, deferred: Set<string>): Promise<void> {
    const attempt = t.attempt + 1;
    // Unique per reservation: a reservation released by resume (never launched) must not
    // collide with the retry of the same attempt number.
    const reservationId = `${t.id}#${attempt}@${this.journal.records().length + 1}`;
    const decision = this.budget.reserve(reservationId, t.id, this.planIndex.get(t.id)?.epicId ?? t.epicId);
    if (decision.kind !== 'admit') {
      this.store.release(t.id, this.owner);
      if (decision.kind === 'defer') {
        deferred.add(t.id);
        this.journal.append('budget.defer', { taskId: t.id, reason: decision.reason });
      } else {
        this.escalate(t.id, 'ready', 'budget', decision.reason, 'Raise the budget cap in policy, or descope the task?');
      }
      return;
    }
    // This transition record is the attempt start. Nothing is launched before it is durable.
    this.transition({ taskId: t.id, from: 'ready', to: 'implementing', reason: `attempt ${attempt}`, attempt, reservationId });

    const controller = new AbortController();
    // A lease that cannot be renewed (lost, or the store failing) ends the attempt as an infra
    // failure instead of letting it run unowned or crashing the controller from a timer.
    let leaseLost: (r: RunResult) => void = () => {};
    const lost = new Promise<RunResult>((resolve) => (leaseLost = resolve));
    const heartbeat = setInterval(() => {
      let reason: string | undefined;
      try {
        if (!this.store.heartbeat(t.id, this.owner, this.policy.leaseMs, Date.now())) reason = 'lease lost';
      } catch (err) {
        reason = `lease renewal failed: ${(err as Error).message}`;
      }
      if (reason !== undefined) {
        controller.abort();
        leaseLost({ kind: 'infra', reason, cost: null });
      }
    }, Math.max(50, Math.floor(this.policy.leaseMs / 3)));
    let timer: NodeJS.Timeout | undefined;
    let result: RunResult;
    try {
      const timeout = new Promise<RunResult>((resolve) => {
        timer = setTimeout(() => {
          controller.abort();
          resolve({ kind: 'infra', reason: `timeout after ${this.policy.timeouts.invocationMs}ms`, cost: null });
        }, this.policy.timeouts.invocationMs);
      });
      result = await Promise.race([
        runner.run({ taskId: t.id, attempt, role: 'implementer', signal: controller.signal }).catch(
          (err: unknown): RunResult => ({ kind: 'infra', reason: `runner error: ${(err as Error).message}`, cost: null }),
        ),
        timeout,
        lost,
      ]);
    } finally {
      clearInterval(heartbeat);
      if (timer) clearTimeout(timer);
      controller.abort();
    }
    const end: AttemptEndRecord = { taskId: t.id, attempt, result: sanitizeCost(result), synthesized: false };
    if (end.result !== result) end.invalidCost = JSON.stringify(result.cost);
    this.journal.append('attempt.end', end);
    this.advance(t.id);
    this.store.release(t.id, this.owner);
  }

  /**
   * Drive a task forward from wherever it stands after its latest attempt ended. Idempotent:
   * every step checks the current state and journal, so resume can call it after a crash at
   * any boundary. Returns true if anything changed.
   */
  advance(taskId: string): boolean {
    let changed = false;
    for (let guard = 0; guard < 16; guard++) {
      const t = this.mustGet(taskId);
      const end = this.latestEnd(taskId, t.attempt);
      if (!end) return changed;
      const resId = this.attemptReservation(taskId, end.attempt);
      if (resId !== undefined && this.budget.ledger.isOpen(resId)) {
        this.budget.settle(resId, costOf(end.result));
        changed = true;
        continue;
      }
      const L = this.policy.limits;
      const r = end.result;
      if (r.kind === 'infra') {
        if (t.state !== 'implementing') return changed;
        const infraFailures = t.infraFailures + 1;
        if (infraFailures > L.maxInfraRetries) {
          this.escalate(taskId, 'implementing', 'infra', `infra failures exhausted (${infraFailures}): ${r.reason}`, 'Investigate the worker environment, then unblock?', { infraFailures });
        } else {
          this.transition({ taskId, from: 'implementing', to: 'ready', reason: `infra retry: ${r.reason}`, counters: { infraFailures } });
        }
        return true;
      }
      switch (t.state) {
        case 'implementing':
          this.transition({ taskId, from: 'implementing', to: 'verifying', reason: `attempt ${end.attempt} completed` });
          changed = true;
          continue;
        case 'verifying': {
          const evProblem = this.ensureEvidence(t, end);
          if (evProblem) {
            this.escalate(taskId, 'verifying', 'evidence', evProblem, 'Evidence failed verification; investigate tampering?');
            return true;
          }
          if (r.verification.verdict === 'pass') {
            this.transition({ taskId, from: 'verifying', to: 'reviewing', reason: 'verification passed (M1: scripted)' });
          } else {
            this.correctionFailure(t, 'verifying', r.verification.signature ?? 'unspecified');
          }
          changed = true;
          continue;
        }
        case 'reviewing':
          if (r.review.verdict === 'approve') {
            this.transition({ taskId, from: 'reviewing', to: 'accepted', reason: 'review approved (M1: scripted)' });
          } else {
            this.correctionFailure(t, 'reviewing', 'review:changes-requested');
          }
          changed = true;
          continue;
        case 'accepted':
          this.transition({ taskId, from: 'accepted', to: 'integrating', reason: 'queued for integration (M1: no-op)' });
          changed = true;
          continue;
        case 'integrating': {
          const problems = this.evidence.verify(taskId, end.attempt);
          const sealed = this.sealedMac(taskId, end.attempt);
          if (sealed === undefined) problems.push('no journaled seal');
          else if (this.evidence.read(taskId, end.attempt)?.mac !== sealed) problems.push('manifest differs from the journaled seal');
          if (problems.length > 0) {
            this.escalate(taskId, 'integrating', 'evidence', `evidence invalid: ${problems.join(', ')}`, 'Evidence failed verification; investigate tampering?');
          } else {
            this.transition({ taskId, from: 'integrating', to: 'done', reason: 'evidence verified' });
          }
          return true;
        }
        default:
          return changed;
      }
    }
    throw new ControllerError(`advance did not settle for ${taskId}`);
  }

  private correctionFailure(t: TaskRecord, from: 'verifying' | 'reviewing', signature: string): void {
    const L = this.policy.limits;
    const correctionFailures = t.correctionFailures + 1;
    const repeatCount = t.lastFailureSignature === signature ? t.repeatCount + 1 : 1;
    const counters = { correctionFailures, repeatCount, lastFailureSignature: signature };
    if (correctionFailures >= L.maxAttempts) {
      this.escalate(t.id, from, 'attempts', `${correctionFailures} correction attempts used; last failure ${signature}`, 'Clarify the requirement or fix manually?', counters);
    } else if (repeatCount >= L.repeatedFailureStop) {
      this.escalate(t.id, from, 'repeated-failure', `same failure ${repeatCount} times in a row: ${signature}`, 'The same failure keeps recurring; what is missing?', counters);
    } else {
      this.transition({ taskId: t.id, from, to: 'ready', reason: `correction needed: ${signature}`, counters });
    }
  }

  /**
   * Evidence for the attempt, written by the controller (never by a worker). Idempotent.
   * Returns a problem when evidence that was already sealed no longer verifies: that is
   * tampering, and it is escalated rather than silently rewritten.
   */
  private ensureEvidence(t: TaskRecord, end: AttemptEndRecord): string | null {
    const sealed = this.sealedMac(t.id, end.attempt);
    const problems = this.evidence.verify(t.id, end.attempt);
    if (problems.length === 0) {
      const mac = this.evidence.read(t.id, end.attempt)?.mac as string;
      if (sealed === undefined) {
        // Sealed, then a crash before the journal record. The MAC proves the controller wrote it.
        this.journal.append('evidence.sealed', { taskId: t.id, attempt: end.attempt, mac });
        return null;
      }
      return mac === sealed ? null : 'manifest differs from the journaled seal';
    }
    if (sealed !== undefined) return `sealed evidence no longer verifies: ${problems.join(', ')}`;
    // Never sealed (a crash while writing it): write it now.
    const r = end.result;
    if (r.kind !== 'completed') return null;
    const entries = [
      this.evidence.writeArtifact(t.id, end.attempt, 'runner-result.json', JSON.stringify(r, null, 2)),
      this.evidence.writeArtifact(
        t.id,
        end.attempt,
        'verification.json',
        JSON.stringify({ source: 'scripted (M1 placeholder for the M3 verifier)', verdict: r.verification.verdict, signature: r.verification.signature }, null, 2),
      ),
    ];
    const m = this.evidence.seal(t.id, end.attempt, entries, { verification: r.verification.verdict, review: r.review.verdict, placeholder: 'M1' });
    this.journal.append('evidence.sealed', { taskId: t.id, attempt: end.attempt, mac: m.mac });
    return null;
  }

  private sealedMac(taskId: string, attempt: number): string | undefined {
    const recs = this.journal.ofType<{ taskId: string; attempt: number; mac: string }>('evidence.sealed').filter((r) => r.data.taskId === taskId && r.data.attempt === attempt);
    return recs[recs.length - 1]?.data.mac;
  }

  /** The reservation recorded on the attempt-start transition. */
  private attemptReservation(taskId: string, attempt: number): string | undefined {
    const starts = this.journal
      .ofType<TransitionRecord>('task.transition')
      .filter((r) => r.data.taskId === taskId && r.data.to === 'implementing' && r.data.attempt === attempt);
    return starts[starts.length - 1]?.data.reservationId;
  }

  private latestEnd(taskId: string, attempt: number): AttemptEndRecord | undefined {
    const ends = this.journal.ofType<AttemptEndRecord>('attempt.end').filter((r) => r.data.taskId === taskId && r.data.attempt === attempt);
    return ends[ends.length - 1]?.data;
  }

  private mustGet(id: string): TaskRecord {
    const t = this.store.get(id);
    if (!t) throw new ControllerError(`unknown task ${id}`);
    return t;
  }
}

export interface PlannedTask {
  epicId: string;
  deps: string[];
  repoPath: string;
}

/** Every task of every journaled plan, as approved. */
export function journaledTasks(records: readonly JournalRecord[]): Map<string, PlannedTask> {
  const out = new Map<string, PlannedTask>();
  for (const r of records) {
    if (r.type !== 'plan.import') continue;
    const d = r.data as { plan: Plan; repoPath: string };
    for (const t of d.plan.tasks) if (!out.has(t.id)) out.set(t.id, { epicId: d.plan.epicId, deps: [...t.deps], repoPath: d.repoPath });
  }
  return out;
}

/** Store tasks that are unknown to the journal, or whose epic or dependencies were changed. */
export function planMismatches(tasks: readonly TaskRecord[], planned: ReadonlyMap<string, PlannedTask>): string[] {
  const out: string[] = [];
  for (const t of tasks) {
    const p = planned.get(t.id);
    if (!p) out.push(`${t.id} is not in any journaled plan`);
    else {
      if (t.epicId !== p.epicId) out.push(`${t.id} epic is ${t.epicId}, plan says ${p.epicId}`);
      if ([...t.deps].sort().join(',') !== [...p.deps].sort().join(',')) out.push(`${t.id} dependencies differ from the plan`);
    }
  }
  return out;
}

function policyRecords(records: readonly JournalRecord[]): { committed?: string; pending?: { hash: string; reason: string } } {
  let committed: string | undefined;
  let pending: { hash: string; reason: string } | undefined;
  for (const r of records) {
    if (r.type === 'policy.set') {
      committed = (r.data as { hash: string }).hash;
      pending = undefined;
    } else if (r.type === 'policy.pending') pending = r.data as { hash: string; reason: string };
  }
  return { ...(committed !== undefined ? { committed } : {}), ...(pending ? { pending } : {}) };
}

function validAmount(c: unknown): boolean {
  const x = c as { usd?: unknown; tokens?: unknown } | null;
  return (
    typeof x === 'object' && x !== null && typeof x.usd === 'number' && Number.isFinite(x.usd) && x.usd >= 0 &&
    typeof x.tokens === 'number' && Number.isInteger(x.tokens) && x.tokens >= 0
  );
}

/** A malformed reported cost becomes "unknown" (full reservation charged) before it is journaled. */
function sanitizeCost(r: RunResult): RunResult {
  return r.cost === null || validAmount(r.cost) ? r : { ...r, cost: null };
}

function costOf(r: AttemptEndRecord['result']): Amount | null {
  return r.cost ? { usd: r.cost.usd, tokens: r.cost.tokens } : null;
}

function attemptKey(e: { taskId: string; attempt: number }): string {
  return `${e.taskId}#${e.attempt}`;
}

const COUNTER_KEYS = ['attempt', 'correctionFailures', 'infraFailures', 'lastFailureSignature', 'repeatCount', 'journalSeq'] as const;

/** A new task's counters, as every store creates it; every key is compared from the start. */
const INITIAL_COUNTERS: TaskCounters = { attempt: 0, correctionFailures: 0, infraFailures: 0, lastFailureSignature: null, repeatCount: 0, journalSeq: 0 };

/** Fold transitions into the state and counters the store should hold for each task. */
export interface ExpectedState {
  state: TaskState;
  counters: Partial<TaskCounters>;
  /**
   * The state and counters before the task's last journaled transition. The journal is
   * written ahead of the store, so a crash can leave the store here, one step behind, but
   * never anywhere else.
   */
  prev?: { state: TaskState; counters: Partial<TaskCounters> };
}

export function expectedStates(records: readonly JournalRecord[]): Map<string, ExpectedState> {
  const out = new Map<string, ExpectedState>();
  for (const r of records) {
    if (r.type === 'plan.import') {
      for (const t of (r.data as { plan: Plan }).plan.tasks) {
        if (!out.has(t.id)) out.set(t.id, { state: 'planned', counters: { ...INITIAL_COUNTERS } });
      }
    } else if (r.type === 'task.transition') {
      const tr = r.data as TransitionRecord;
      const cur: ExpectedState = out.get(tr.taskId) ?? { state: 'planned', counters: { ...INITIAL_COUNTERS } };
      cur.prev = { state: cur.state, counters: { ...cur.counters } };
      cur.state = tr.to;
      Object.assign(cur.counters, tr.counters ?? {}, tr.attempt !== undefined ? { attempt: tr.attempt } : {}, { journalSeq: r.seq });
      out.set(tr.taskId, cur);
    }
  }
  return out;
}

/**
 * Whether a store task is where the journal allows it to be: at the journaled state, or one
 * transition behind it (a crash between the journal append and the store update). Anything
 * else, a store ahead of the journal or off its path, means the store was changed behind the
 * controller or the journal was truncated or restored from an older copy; replaying the
 * journal onto it would rewind finished work and lose spend, so nobody may "repair" it.
 */
export function storeDrift(t: TaskRecord, exp: ExpectedState): 'none' | 'behind' | 'diverged' {
  // Counters include journalSeq, the journal record of the last transition the store applied,
  // so "behind" means exactly the previous transition and "none" exactly the last one.
  if (t.state === exp.state && countersMatch(t, exp.counters)) return 'none';
  if (exp.prev && t.state === exp.prev.state && countersMatch(t, exp.prev.counters)) return 'behind';
  return 'diverged';
}

/**
 * Everything about the store, evidence and escalation files that no crash can produce from
 * this journal. The journal is written first, so a crash leaves each task at its journaled
 * state or one transition behind, a task missing only if it has no transition yet, and
 * evidence or escalation files only for attempts and escalations the journal records.
 * Shared by resume (which refuses) and doctor (which reports).
 */
export function recoveryProblems(records: readonly JournalRecord[], tasks: readonly TaskRecord[], evidenceAttempts: readonly string[], escalationFiles: readonly string[]): string[] {
  const problems: string[] = [];
  const byId = new Map(tasks.map((t) => [t.id, t]));
  // A single writer applies one transition at a time, so a crash can leave at most the
  // journal's last transition unapplied.
  const transitions = records.filter((r) => r.type === 'task.transition');
  const lastTransition = transitions[transitions.length - 1]?.seq;
  for (const [id, exp] of expectedStates(records)) {
    const t = byId.get(id);
    if (!t) {
      if (exp.prev) problems.push(`${id} is missing from the store, but the journal has transitions for it (last at seq ${exp.counters.journalSeq})`);
      continue;
    }
    if (typeof t.journalSeq !== 'number') {
      problems.push(`${id} has no journal position: it was written by an older eo, and state roots from before journal positions are not supported`);
      continue;
    }
    const drift = storeDrift(t, exp);
    if (drift === 'diverged') {
      const counters = COUNTER_KEYS.filter((k) => exp.counters[k] !== undefined && t[k] !== exp.counters[k]).map((k) => `${k} ${JSON.stringify(t[k])}, journal says ${JSON.stringify(exp.counters[k])}`);
      if (t.state === exp.state && t.journalSeq === exp.counters.journalSeq) {
        problems.push(`${id} counters differ from the journal (${counters.join('; ')})`);
      } else {
        problems.push(`${id} is ${t.state} at journal seq ${t.journalSeq}, journal says ${exp.state} at seq ${exp.counters.journalSeq}${exp.prev ? ` (or ${exp.prev.state} at seq ${exp.prev.counters.journalSeq} after a crash)` : ''}`);
      }
    } else if (drift === 'behind' && exp.counters.journalSeq !== lastTransition) {
      problems.push(`${id} is one transition behind (store at seq ${t.journalSeq}, journal at seq ${exp.counters.journalSeq}), but only the journal's last transition (seq ${lastTransition}) can be left unapplied by a crash`);
    }
  }
  const ended = new Set(records.filter((r) => r.type === 'attempt.end').map((r) => attemptKey(r.data as AttemptEndRecord)));
  for (const a of evidenceAttempts) if (!ended.has(a)) problems.push(`evidence for attempt ${a} exists, but the journal has no end for that attempt`);
  const escalations = new Set(records.filter((r) => r.type === 'escalation').map((r) => (r.data as EscalationRecord).id));
  for (const e of escalationFiles) if (!escalations.has(e)) problems.push(`escalation file ${e} exists, but the journal has no such escalation`);
  return problems;
}

/** Evidence attempt directories under `dir` (evidence/<task>/a<n>), as "task#n". */
export function listEvidenceAttempts(dir: string): string[] {
  const out: string[] = [];
  if (!fs.existsSync(dir)) return out;
  for (const task of fs.readdirSync(dir).sort()) {
    const td = path.join(dir, task);
    if (!fs.statSync(td).isDirectory()) continue;
    for (const a of fs.readdirSync(td).sort()) {
      const m = /^a([1-9][0-9]*)$/.exec(a);
      if (m) out.push(`${task}#${m[1]}`);
    }
  }
  return out;
}

/** Escalation ids with a file under `dir`. */
export function listEscalationFiles(dir: string): string[] {
  if (!fs.existsSync(dir)) return [];
  return fs
    .readdirSync(dir)
    .filter((f) => f.endsWith('.json'))
    .map((f) => f.slice(0, -'.json'.length))
    .sort();
}

function countersMatch(t: TaskRecord, c: Partial<TaskCounters>): boolean {
  return COUNTER_KEYS.every((k) => c[k] === undefined || t[k] === c[k]);
}
