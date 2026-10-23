import * as fs from 'node:fs';
import * as path from 'node:path';
import { createHash } from 'node:crypto';
import { verifyJournalFile } from './journal.ts';
import { EvidenceLedger } from './evidence.ts';
import { BudgetLedger } from './budget.ts';
import { loadPolicy, policyHash } from './policy.ts';
import { readJournalKey, statePaths, type StateRootPaths } from './stateRoot.ts';
import { defaultAnchorDir, inspectAnchor } from './anchor.ts';
import { sleepSync } from './util/lock.ts';
import { isProcessAlive } from './util/fsx.ts';
import { openStore } from './store/open.ts';
import type { TaskRecord, TaskStore } from './store/types.ts';
import { expectedStates, listEscalationFiles, listEvidenceAttempts, recoveryProblems, storeDrift, journaledTasks, planMismatches, type EscalationRecord } from './controller.ts';

export interface DoctorReport {
  ok: boolean;
  problems: string[];
  warnings: string[];
  journalRecords: number;
}

/** How many times doctor rereads when a running controller changes the journal under it. */
const SNAPSHOT_ATTEMPTS = 20;

function fileHash(file: string): string {
  try {
    return createHash('sha256').update(fs.readFileSync(file)).digest('hex');
  } catch {
    return 'absent';
  }
}

/**
 * Integrity check of a state root. It never changes the journal, policy, evidence or tasks.
 * Opening a beads store can still restore the store's private bd entry, and bd itself
 * touches its lock and version files.
 *
 * Doctor takes no lock, so a controller may be running. It reads a consistent snapshot: the
 * journal file must be byte-identical before and after the store and evidence are read, or
 * the read is repeated (M2-0b). A transition in flight is then never reported as tampering;
 * if the journal keeps changing, doctor says a controller is running instead of guessing.
 */
export function doctor(root: string, store?: TaskStore, opts: { anchorDir?: string } = {}): DoctorReport {
  const p = statePaths(root);
  const key = readJournalKey(p);
  for (let attempt = 1; ; attempt++) {
    const before = fileHash(p.journal);
    const r = check(p, key, store, opts);
    if (fileHash(p.journal) === before) return r;
    if (attempt >= SNAPSHOT_ATTEMPTS) {
      return {
        ok: false,
        problems: [`snapshot: the journal changed during each of ${SNAPSHOT_ATTEMPTS} reads, so a controller is running; the store was not checked (run doctor again when it is idle)`],
        warnings: r.warnings,
        journalRecords: r.journalRecords,
      };
    }
    sleepSync(25 * attempt);
  }
}

/** The pid of a live controller holding the lock, if any. */
function runningController(lockFile: string): number | undefined {
  try {
    const pid = (JSON.parse(fs.readFileSync(lockFile, 'utf8')) as { pid?: unknown }).pid;
    return typeof pid === 'number' && pid !== process.pid && isProcessAlive(pid) ? pid : undefined;
  } catch {
    return undefined;
  }
}

function check(p: StateRootPaths, key: Buffer, store: TaskStore | undefined, opts: { anchorDir?: string }): DoctorReport {
  const problems: string[] = [];
  const warnings: string[] = [];
  if (process.env['EO_CRASH_AT'] !== undefined) warnings.push('EO_CRASH_AT is set (test-only crash injection)');
  if (process.env['EO_CRASH_PHASE'] !== undefined) warnings.push('EO_CRASH_PHASE is set (test-only crash injection)');
  const v = verifyJournalFile(p.journal, key);
  problems.push(...v.errors.map((e) => `journal: ${e}`));
  if (v.tornTail) warnings.push('journal has a torn final line (crash during write); the next command that opens the controller removes it');
  const running = runningController(p.controllerLock);
  if (running !== undefined) warnings.push(`a controller is running (pid ${running}); a transition may be in flight`);

  // M2-0b: the journal against its rollback anchor, outside the state root.
  try {
    const a = inspectAnchor(opts.anchorDir ?? defaultAnchorDir(), p.root, key, v.records).check;
    if (a.kind === 'refuse' || a.kind === 'unadopted') problems.push(`anchor: ${a.reason} (the controller refuses to open)`);
    else if (a.kind === 'one-ahead') warnings.push(`anchor: the journal is one record ahead of its anchor (seq ${a.anchored}), left by a crash; the next controller open records it`);
    else if (a.kind === 'new') warnings.push('anchor: this new state root is not bound to the anchor yet; the next controller open binds it');
  } catch (err) {
    problems.push(`anchor: ${(err as Error).message}`);
  }

  try {
    const pol = loadPolicy(p.policy);
    const sets = v.records.filter((r) => r.type === 'policy.set');
    const last = sets[sets.length - 1]?.data as { hash: string } | undefined;
    if (last && last.hash !== policyHash(pol)) problems.push('policy.json differs from the last journaled policy hash');
  } catch (err) {
    problems.push(`policy: ${(err as Error).message}`);
  }

  // The store is checked through one listing; an unreadable or tampered store is a problem
  // to report, not a crash.
  let tasks: TaskRecord[] = [];
  try {
    const s = store ?? openStore(p, { create: false, records: v.records });
    tasks = s.list();
    const byId = new Map(tasks.map((t) => [t.id, t]));
    const lastTransition = v.records.filter((r) => r.type === 'task.transition').at(-1)?.seq;
    for (const [id, exp] of expectedStates(v.records)) {
      const t = byId.get(id);
      if (!t && !exp.prev) problems.push(`store: task ${id} missing (journal has it; resume will create it)`);
      else if (t && storeDrift(t, exp) === 'behind' && exp.counters.journalSeq === lastTransition) {
        // With a controller running, this is a transition in flight, not damage.
        if (running !== undefined) warnings.push(`store: ${id} is ${t.state}, journal says ${exp.state} (the journal's last transition, being applied by the running controller)`);
        else problems.push(`store: ${id} is ${t.state}, journal says ${exp.state} (the journal's last transition, left unapplied by a crash; the next controller open finishes it)`);
      }
    }
    // What resume refuses: states no crash can produce.
    for (const m of recoveryProblems(v.records, tasks, listEvidenceAttempts(p.evidence), listEscalationFiles(p.escalations))) {
      problems.push(`store: ${m} (ahead of or off the journal; resume refuses, a human must investigate)`);
    }
    for (const m of planMismatches(tasks, journaledTasks(v.records))) problems.push(`store: ${m}`);
  } catch (err) {
    problems.push(`store: ${(err as Error).message}`);
  }

  try {
    const ledger = BudgetLedger.fromRecords(v.records);
    for (const r of ledger.openReservations()) warnings.push(`budget: reservation ${r.id} still open`);
  } catch (err) {
    problems.push(`budget: ${(err as Error).message}`);
  }

  const ev = new EvidenceLedger(p.evidence, key);
  for (const t of tasks) {
    if (t.state === 'done') {
      if (t.attempt < 1) {
        problems.push(`evidence ${t.id}: done without any attempt`);
        continue;
      }
      for (const prob of ev.verify(t.id, t.attempt)) problems.push(`evidence ${t.id}#${t.attempt}: ${prob}`);
    }
  }

  for (const r of v.records) {
    if (r.type !== 'escalation') continue;
    const e = r.data as EscalationRecord;
    if (!fs.existsSync(path.join(p.escalations, `${e.id}.json`))) warnings.push(`escalation file ${e.id} missing (resume will rewrite)`);
  }

  return { ok: problems.length === 0, problems, warnings, journalRecords: v.records.length };
}
