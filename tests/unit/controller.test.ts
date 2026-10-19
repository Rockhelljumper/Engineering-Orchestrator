import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { Controller, ControllerError, RecoveryRefusedError, type EscalationRecord } from '../../src/controller.ts';
import { FakeRunner, type FakeScript } from '../../src/runner/fake.ts';
import { PolicyError, canonicalRepoPath, loadPolicy, policyHash } from '../../src/policy.ts';
import { doctor } from '../../src/doctor.ts';
import { readExecLog, samplePlan, sandbox, TEST_STORE, tmpDir, type Sandbox } from '../support/helpers.ts';
import { planHash, type Plan } from '../../src/plan.ts';
import { statePaths } from '../../src/stateRoot.ts';
import { openStore } from '../../src/store/open.ts';
import { StoreError, type TaskRecord, type TaskStore } from '../../src/store/types.ts';
import { BudgetLedger } from '../../src/budget.ts';

interface Run {
  sb: Sandbox;
  c: Controller;
  log: string;
}

async function runPlan(plan: Plan, script: Omit<FakeScript, 'execLog'>, sb = sandbox()): Promise<Run & { summary: Awaited<ReturnType<Controller['run']>> }> {
  const log = path.join(sb.dir, 'exec.log');
  const c = Controller.open(sb.root);
  c.importPlan(plan, sb.repo, 'test-human');
  const summary = await c.run(new FakeRunner({ ...script, execLog: log }), { repoPath: sb.repo });
  return { sb, c, log, summary };
}

function escalations(c: Controller): EscalationRecord[] {
  return c.journal.ofType<EscalationRecord>('escalation').map((r) => r.data);
}

const twoIndependent: Plan = {
  epicId: 'E1',
  title: 'independent',
  tasks: [
    { id: 'A', title: 'a', deps: [] },
    { id: 'B', title: 'b', deps: [] },
  ],
};

// ------------------------------------------------------------------ happy path and ordering

test('happy path: every task reaches done in dependency order with verified evidence', async () => {
  const { c, log, summary } = await runPlan(samplePlan(), { default: { behaviour: 'pass' } });
  try {
    assert.deepEqual(summary.states, { T1: 'done', T2: 'done', T3: 'done', T4: 'done', T5: 'done' });
    assert.equal(summary.steps, 5);
    assert.deepEqual(readExecLog(log).map((e) => e.taskId), ['T1', 'T2', 'T3', 'T4', 'T5']);
    for (const t of c.store.list()) assert.deepEqual(c.evidence.verify(t.id, t.attempt), []);
    assert.equal(c.budget.ledger.openReservations().length, 0);
  } finally {
    c.close();
  }
  const d = doctor(c.paths.root);
  assert.deepEqual(d.problems, []);
});

test('a task never starts before its dependencies are done', async () => {
  const { c } = await runPlan(samplePlan(), { default: { behaviour: 'pass' } });
  try {
    const order: string[] = [];
    const doneAt = new Map<string, number>();
    for (const r of c.journal.records()) {
      if (r.type !== 'task.transition') continue;
      const d = r.data as { taskId: string; to: string; attempt?: number };
      if (d.to === 'implementing') order.push(d.taskId);
      if (d.to === 'implementing') {
        for (const dep of samplePlan().tasks.find((t) => t.id === d.taskId)?.deps ?? []) {
          assert.ok((doneAt.get(dep) ?? Infinity) < r.seq, `${d.taskId} started before ${dep} was done`);
        }
      }
      if (d.to === 'done') doneAt.set(d.taskId, r.seq);
    }
    assert.equal(order.length, 5);
  } finally {
    c.close();
  }
});

test('the same plan and script produce the same journal sequence (determinism)', async () => {
  const shape = async (): Promise<string[]> => {
    const { c } = await runPlan(samplePlan(), { default: { behaviour: 'pass' }, tasks: { T2: [{ behaviour: 'verify-fail', signature: 's1' }] } });
    try {
      return c.journal.records().map((r) => {
        const d = r.data as { taskId?: string; to?: string };
        return `${r.type}:${d.taskId ?? ''}:${d.to ?? ''}`;
      });
    } finally {
      c.close();
    }
  };
  assert.deepEqual(await shape(), await shape());
});

// ------------------------------------------------------------------ correction loop (requirement 4)

test('failed verification returns the task to implementation and it then completes', async () => {
  const { c, log, summary } = await runPlan(twoIndependent, {
    default: { behaviour: 'pass' },
    tasks: { A: [{ behaviour: 'verify-fail', signature: 'test:a1' }] },
  });
  try {
    assert.equal(summary.states['A'], 'done');
    const a = c.store.get('A');
    assert.equal(a?.attempt, 2);
    assert.equal(a?.correctionFailures, 1);
    assert.deepEqual(
      readExecLog(log).filter((e) => e.taskId === 'A').map((e) => e.attempt),
      [1, 2],
    );
    const trail = c.journal
      .ofType<{ taskId: string; from: string; to: string }>('task.transition')
      .filter((r) => r.data.taskId === 'A')
      .map((r) => `${r.data.from}->${r.data.to}`);
    assert.deepEqual(trail, [
      'planned->ready',
      'ready->implementing',
      'implementing->verifying',
      'verifying->ready',
      'ready->implementing',
      'implementing->verifying',
      'verifying->reviewing',
      'reviewing->accepted',
      'accepted->integrating',
      'integrating->done',
    ]);
    // Failure evidence for attempt 1 is kept.
    assert.deepEqual(c.evidence.verify('A', 1), []);
    assert.equal(c.evidence.read('A', 1)?.facts['verification'], 'fail');
  } finally {
    c.close();
  }
});

test('review changes-requested returns the task to implementation', async () => {
  const { c, summary } = await runPlan(twoIndependent, { default: { behaviour: 'pass' }, tasks: { A: [{ behaviour: 'review-fail' }] } });
  try {
    assert.equal(summary.states['A'], 'done');
    assert.equal(c.store.get('A')?.attempt, 2);
    assert.ok(c.journal.ofType<{ taskId: string; from: string; to: string }>('task.transition').some((r) => r.data.taskId === 'A' && r.data.from === 'reviewing' && r.data.to === 'ready'));
  } finally {
    c.close();
  }
});

// ------------------------------------------------------------------ bounded retries and escalation (requirement 8)

test('correction attempts are bounded: the third distinct failure blocks with an escalation', async () => {
  const { c, log, summary } = await runPlan(samplePlan(), {
    default: { behaviour: 'pass' },
    tasks: { T2: [1, 2, 3, 4].map((i) => ({ behaviour: 'verify-fail' as const, signature: `sig-${i}` })) },
  });
  try {
    assert.equal(summary.states['T2'], 'blocked');
    assert.equal(summary.states['T3'], 'done');
    assert.equal(summary.states['T4'], 'planned');
    assert.equal(summary.states['T5'], 'planned');
    assert.deepEqual(summary.stalled, ['T4']);
    assert.equal(readExecLog(log).filter((e) => e.taskId === 'T2').length, 3, 'exactly maxAttempts launches');
    const esc = escalations(c).filter((e) => e.taskId === 'T2');
    assert.equal(esc.length, 1);
    assert.equal(esc[0]?.category, 'attempts');
    assert.ok(fs.existsSync(path.join(c.paths.escalations, `${esc[0]?.id}.json`)));
    const blockTr = c.journal.ofType<{ taskId: string; to: string; escalationId?: string }>('task.transition').find((r) => r.data.taskId === 'T2' && r.data.to === 'blocked');
    assert.equal(blockTr?.data.escalationId, esc[0]?.id);
  } finally {
    c.close();
  }
});

test('the same failure twice in a row escalates early', async () => {
  const { c, log, summary } = await runPlan(twoIndependent, {
    default: { behaviour: 'pass' },
    tasks: { A: [{ behaviour: 'verify-fail', signature: 'same' }, { behaviour: 'verify-fail', signature: 'same' }, { behaviour: 'pass' }] },
  });
  try {
    assert.equal(summary.states['A'], 'blocked');
    assert.equal(summary.states['B'], 'done');
    assert.equal(readExecLog(log).filter((e) => e.taskId === 'A').length, 2);
    assert.equal(escalations(c).find((e) => e.taskId === 'A')?.category, 'repeated-failure');
  } finally {
    c.close();
  }
});

test('infra failures are retried separately and then block', async () => {
  const { c, log, summary } = await runPlan(twoIndependent, {
    default: { behaviour: 'pass' },
    tasks: { A: [{ behaviour: 'crash' }, { behaviour: 'crash' }, { behaviour: 'crash' }, { behaviour: 'pass' }] },
  });
  try {
    assert.equal(summary.states['A'], 'blocked');
    const a = c.store.get('A');
    assert.equal(a?.infraFailures, 3);
    assert.equal(a?.correctionFailures, 0, 'infra failures do not consume correction attempts');
    assert.equal(readExecLog(log).filter((e) => e.taskId === 'A').length, 3, 'one try plus maxInfraRetries (2)');
    assert.equal(escalations(c).find((e) => e.taskId === 'A')?.category, 'infra');
  } finally {
    c.close();
  }
});

test('a hanging worker is aborted at the timeout and retried as an infra failure', async () => {
  const sb = sandbox((p) => ({ ...p, timeouts: { invocationMs: 150 } }));
  const { c, summary } = await runPlan(twoIndependent, { default: { behaviour: 'pass' }, tasks: { A: [{ behaviour: 'hang' }] } }, sb);
  try {
    assert.equal(summary.states['A'], 'done');
    assert.equal(c.store.get('A')?.infraFailures, 1);
    const end = c.journal.ofType<{ taskId: string; attempt: number; result: { kind: string; reason: string } }>('attempt.end').find((r) => r.data.taskId === 'A' && r.data.attempt === 1);
    // Bounded per attempt, from its journaled start to its end, so the store's own latency
    // (bd takes ~0.3 s per call) does not count.
    const start = c.journal
      .ofType<{ taskId: string; to: string; attempt?: number }>('task.transition')
      .find((r) => r.data.taskId === 'A' && r.data.to === 'implementing' && r.data.attempt === 1);
    assert.ok(start && end && Date.parse(end.ts) - Date.parse(start.ts) < 5_000, 'the hang was bounded by the timeout');
    assert.match(end?.data.result.reason ?? '', /timeout after 150ms/);
    // A hang reports no cost, so the full reservation is charged.
    const settle = c.journal.ofType<{ id: string; basis: string }>('budget.settle').find((r) => r.data.id.startsWith('A#1@'));
    assert.equal(settle?.data.basis, 'unknown');
  } finally {
    c.close();
  }
});

test('a lease that cannot be renewed ends the attempt as an infra failure instead of crashing the controller', async () => {
  const sb = sandbox((p) => ({ ...p, leaseMs: 300, limits: { ...p.limits, maxInfraRetries: 5 } }));
  const inner = openStore(statePaths(sb.root), { create: false });
  // The first renewal throws (bd failing), the second reports the lease lost; then normal.
  let calls = 0;
  const store = new Proxy(inner, {
    get(target, key, receiver) {
      if (key === 'heartbeat') {
        return (...args: Parameters<TaskStore['heartbeat']>): boolean => {
          calls++;
          if (calls === 1) throw new StoreError('bd update failed (exit 1): simulated');
          if (calls === 2) return false;
          return target.heartbeat(...args);
        };
      }
      const v = Reflect.get(target, key, receiver) as unknown;
      return typeof v === 'function' ? (v as (...a: unknown[]) => unknown).bind(target) : v;
    },
  });
  const log = path.join(sb.dir, 'exec.log');
  const c = Controller.open(sb.root, { store });
  try {
    c.importPlan(twoIndependent, sb.repo, 'h');
    const summary = await c.run(new FakeRunner({ default: { behaviour: 'pass' }, tasks: { A: [{ behaviour: 'hang' }, { behaviour: 'hang' }] }, execLog: log }), { repoPath: sb.repo });
    // Both hung attempts report no cost, so each is charged the full $5 reservation and the
    // $10 task cap then stops a third attempt: the budget, not the lease, decides the end state.
    assert.equal(summary.states['A'], 'blocked');
    const reasons = c.journal
      .ofType<{ taskId: string; attempt: number; result: { kind: string; reason?: string } }>('attempt.end')
      .filter((r) => r.data.taskId === 'A')
      .map((r) => `${r.data.attempt}:${r.data.result.kind}:${r.data.result.reason ?? ''}`);
    assert.deepEqual(reasons, ['1:infra:lease renewal failed: bd update failed (exit 1): simulated', '2:infra:lease lost']);
    assert.equal(summary.states['B'], 'done');
    assert.equal(c.store.get('A')?.infraFailures, 2);
  } finally {
    c.close();
  }
});

// ------------------------------------------------------------------ budget through the scheduler

test('budget: affordable work starts while unaffordable work is rejected before launch', async () => {
  // A's first attempt costs $5.50 and fails verification. A retry would need $5 more against a
  // $10 task cap (5.5 + 5 > 10), so it is rejected without launching. B is affordable and runs.
  const { c, log, summary } = await runPlan(twoIndependent, {
    default: { behaviour: 'pass', costUsd: 0.2 },
    tasks: { A: [{ behaviour: 'verify-fail', costUsd: 5.5, signature: 'x' }, { behaviour: 'pass' }] },
  });
  try {
    assert.equal(summary.states['A'], 'blocked');
    assert.equal(summary.states['B'], 'done');
    const launches = readExecLog(log);
    assert.deepEqual(launches.filter((e) => e.taskId === 'A').map((e) => e.attempt), [1], 'the unaffordable retry never launched');
    assert.deepEqual(launches.filter((e) => e.taskId === 'B').map((e) => e.attempt), [1], 'the affordable task launched');
    const esc = escalations(c).find((e) => e.taskId === 'A');
    assert.equal(esc?.category, 'budget');
    assert.match(esc?.detail ?? '', /task A: spent \$5\.5000 \+ reservation \$5\.0000 exceeds cap \$10\.0000/);
    // No reservation was journaled for the rejected attempt.
    assert.deepEqual(
      c.journal.ofType<{ id: string; taskId: string }>('budget.reserve').filter((r) => r.data.taskId === 'A').map((r) => r.data.id.split('@')[0]),
      ['A#1'],
      'only the first attempt was ever reserved',
    );
    assert.equal(c.store.get('A')?.attempt, 1);
  } finally {
    c.close();
  }
});

test('budget: unknown costs charge the full reservation, so the budget can stop retries first', async () => {
  // Each crash reports no cost: $5 charged per attempt. Attempt 2 fits exactly (5 + 5 = 10);
  // attempt 3 does not, so the task blocks on budget before reaching the infra retry limit.
  const { c, log, summary } = await runPlan(twoIndependent, {
    default: { behaviour: 'pass' },
    tasks: { A: [{ behaviour: 'crash', noCost: true }, { behaviour: 'crash', noCost: true }, { behaviour: 'pass' }] },
  });
  try {
    assert.equal(summary.states['A'], 'blocked');
    assert.equal(readExecLog(log).filter((e) => e.taskId === 'A').length, 2);
    assert.equal(escalations(c).find((e) => e.taskId === 'A')?.category, 'budget');
    assert.deepEqual(c.budget.ledger.spent('task', 'A'), { usd: 10, tokens: 4_000_000 });
  } finally {
    c.close();
  }
});

test('budget: the epic cap stops new tasks once the epic is spent', async () => {
  const sb = sandbox((p) => ({ ...p, budget: { ...p.budget, epic: { usd: 12, tokens: 20_000_000 } } }));
  const plan: Plan = { epicId: 'E1', title: 'three', tasks: ['A', 'B', 'C'].map((id) => ({ id, title: id, deps: [] })) };
  const { c, log, summary } = await runPlan(plan, { default: { behaviour: 'pass', costUsd: 4 } }, sb);
  try {
    // A: 0 + 5 <= 12, spends 4. B: 4 + 5 <= 12, spends 4. C: 8 + 5 > 12 -> rejected.
    assert.deepEqual(summary.states, { A: 'done', B: 'done', C: 'blocked' });
    assert.deepEqual(readExecLog(log).map((e) => e.taskId), ['A', 'B']);
    assert.match(escalations(c).find((e) => e.taskId === 'C')?.detail ?? '', /^epic E1/);
  } finally {
    c.close();
  }
});

// ------------------------------------------------------------------ human gates and policy

test('M1-10: run and plan import refuse a repository that is not approved', async () => {
  const sb = sandbox();
  const other = tmpDir();
  const c = Controller.open(sb.root);
  try {
    assert.throws(() => c.importPlan(samplePlan(), other, 'h'), PolicyError);
    assert.equal(c.store.list().length, 0);
    c.importPlan(samplePlan(), sb.repo, 'h');
    const before = c.journal.records().length;
    const log = path.join(sb.dir, 'exec.log');
    await assert.rejects(c.run(new FakeRunner({ default: { behaviour: 'pass' }, execLog: log }), { repoPath: other }), PolicyError);
    assert.equal(c.journal.records().length, before, 'nothing was journaled for the refused run');
    assert.deepEqual(readExecLog(log), [], 'nothing was launched');
  } finally {
    c.close();
  }
});

test('blocked requires an escalation record, and only unblock leaves it', async () => {
  const { c } = await runPlan(twoIndependent, { default: { behaviour: 'pass' }, tasks: { A: [{ behaviour: 'verify-fail', signature: 's' }, { behaviour: 'verify-fail', signature: 's' }] } });
  try {
    assert.equal(c.store.get('A')?.state, 'blocked');
    assert.throws(() => c.transition({ taskId: 'B', from: 'done', to: 'blocked', reason: 'x' }));
    assert.throws(() => c.transition({ taskId: 'A', from: 'blocked', to: 'implementing', reason: 'skip ahead' }), /illegal/i);
    // Unblock resets the correction counters and the task can run again.
    c.unblock('A', 'test-human', 'clarified requirement');
    const a = c.store.get('A');
    assert.equal(a?.state, 'ready');
    assert.equal(a?.correctionFailures, 0);
    assert.equal(a?.attempt, 2, 'attempt numbering continues');
    const s = await c.run(new FakeRunner({ default: { behaviour: 'pass' } }), { repoPath: c.policy.approvedRepositories[0]?.path ?? '' });
    assert.equal(s.states['A'], 'done');
    assert.equal(c.store.get('A')?.attempt, 3);
  } finally {
    c.close();
  }
});

test('a transition to blocked without an escalation id is refused', () => {
  const sb = sandbox();
  const c = Controller.open(sb.root);
  try {
    c.importPlan(twoIndependent, sb.repo, 'h');
    assert.throws(() => c.transition({ taskId: 'A', from: 'planned', to: 'blocked', reason: 'no record' }), /needs an escalation record/);
    assert.equal(c.store.get('A')?.state, 'planned');
  } finally {
    c.close();
  }
});

test('a second controller on the same state root is refused in the same process', () => {
  const sb = sandbox();
  const c = Controller.open(sb.root);
  try {
    assert.throws(() => Controller.open(sb.root), ControllerError);
  } finally {
    c.close();
  }
  // Released: a new controller can open.
  Controller.open(sb.root).close();
});

test('a policy edited outside the controller is refused until accepted', () => {
  const sb = sandbox();
  const file = path.join(sb.root, 'policy.json');
  const p = loadPolicy(file);
  p.limits.maxAttempts = 50; // an agent loosening its own limits
  fs.writeFileSync(file, JSON.stringify(p, null, 2));
  assert.throws(() => Controller.open(sb.root), /differs from the last policy recorded/);
  assert.match(doctor(sb.root).problems.join(';'), /policy.json differs/);
});

test('importing the same task twice is refused', () => {
  const sb = sandbox();
  const c = Controller.open(sb.root);
  try {
    c.importPlan(twoIndependent, sb.repo, 'h');
    assert.throws(() => c.importPlan(twoIndependent, sb.repo, 'h'), /already exists/);
  } finally {
    c.close();
  }
});

test('a task id from a journaled plan cannot be imported again, even if a crash kept it out of the store', () => {
  const sb = sandbox();
  // A crash right after the plan.import record, before its tasks were created.
  const planA: Plan = { epicId: 'EA', title: 'a', tasks: [{ id: 'X', title: 'x', deps: [] }] };
  const c1 = Controller.open(sb.root);
  c1.journal.append('plan.import', { epicId: 'EA', planHash: planHash(planA), approvedBy: 'h', repoPath: canonicalRepoPath(sb.repo), plan: planA });
  c1.close();
  const c = Controller.open(sb.root);
  try {
    assert.equal(c.store.get('X') ?? null, null);
    const planB: Plan = { epicId: 'EB', title: 'b', tasks: [{ id: 'X', title: 'x', deps: [] }] };
    assert.throws(() => c.importPlan(planB, sb.repo, 'h'), /task X already exists/);
    // The state root still resumes: X is created for plan A.
    c.resume();
    assert.equal(c.store.get('X')?.epicId, 'EA');
  } finally {
    c.close();
  }
});

/** Every task as the store holds it, for comparing before and after a refused recovery. */
function storeSnapshot(root: string): TaskRecord[] {
  return openStore(statePaths(root), { create: false }).list();
}

/** Every file under `dir` with its bytes (base64), for "left exactly as found" checks. */
function filesUnder(dir: string): Record<string, string> {
  const out: Record<string, string> = {};
  if (!fs.existsSync(dir)) return out;
  for (const e of fs.readdirSync(dir, { recursive: true, withFileTypes: true })) {
    if (!e.isFile()) continue;
    const f = path.join(e.parentPath, e.name);
    out[path.relative(dir, f)] = fs.readFileSync(f).toString('base64');
  }
  return out;
}

/** Evidence and escalations as found. */
function evidenceAndEscalations(root: string): { evidence: Record<string, string>; escalations: Record<string, string> } {
  const p = statePaths(root);
  return { evidence: filesUnder(p.evidence), escalations: filesUnder(p.escalations) };
}

test('restoring any older valid journal never rewinds finished tasks, attempts or spend; recovery refuses without changing anything and leaves a forensic record', async (t) => {
  // A run with a verification failure, so tasks pass through several transitions and attempts.
  const { sb, c, log } = await runPlan(samplePlan(), { default: { behaviour: 'pass' }, tasks: { T2: [{ behaviour: 'verify-fail', signature: 's' }] } });
  c.close();
  const jf = path.join(sb.root, 'journal.jsonl');
  const full = fs.readFileSync(jf);
  const lines = full.toString('utf8').split('\n').filter(Boolean);
  const before = storeSnapshot(sb.root);
  const filesBefore = evidenceAndEscalations(sb.root);
  const executions = readExecLog(log).length;
  const spent = BudgetLedger.fromRecords(c.journal.records()).spent('epic', 'E1');
  assert.ok(before.every((t) => t.state === 'done'));
  const forensics = path.join(sb.root, 'forensics');
  // Every earlier point of the journal (a valid prefix: its HMAC chain verifies, so it is
  // exactly what restoring an older copy gives), including the policy records written while
  // the sandbox was set up. On beads every third point.
  const start = 1;
  const stride = TEST_STORE === 'beads' ? 3 : 1;
  let refused = 0;
  let accepted = 0;
  for (let k = start; k < lines.length; k += stride) {
    const prefix = Buffer.from(lines.slice(0, k).join('\n') + '\n');
    fs.writeFileSync(jf, prefix);
    const reports = fs.existsSync(forensics) ? fs.readdirSync(forensics).length : 0;
    // Opening is where the controller refuses, before any command could write.
    let ck: Controller | undefined;
    let error: unknown;
    try {
      ck = Controller.open(sb.root);
      ck.resume();
    } catch (err) {
      error = err;
    } finally {
      ck?.close();
    }
    const at = `journal cut to ${k} of ${lines.length} records`;
    // Nothing finished was undone and nothing ran again, whichever way recovery went.
    assert.deepEqual(storeSnapshot(sb.root), before, `${at}: the store is unchanged`);
    assert.equal(readExecLog(log).length, executions, `${at}: nothing ran again`);
    if (error !== undefined) {
      refused++;
      assert.ok(error instanceof RecoveryRefusedError, `${at}: ${String(error)}`);
      assert.match(error.message, /task store is ahead of or diverged from the journal \(.*journal says .* at seq \d+|task store does not match the journaled plans \(.* is not in any journaled plan/, at);
      assert.match(error.message, /nothing was changed/, at);
      assert.deepEqual(fs.readFileSync(jf), prefix, `${at}: the journal is unchanged`);
      assert.deepEqual(evidenceAndEscalations(sb.root), filesBefore, `${at}: evidence and escalations are unchanged`);
      // The forensic record names the inconsistency and keeps the store as found.
      const files = fs.readdirSync(forensics).sort();
      assert.equal(files.length, reports + 1, `${at}: one forensic record`);
      const rec = JSON.parse(fs.readFileSync(path.join(forensics, files[files.length - 1] as string), 'utf8')) as { problems: string[]; journal: { lastSeq: number }; store: TaskRecord[] };
      assert.ok(rec.problems.length > 0 && rec.problems.every((p) => error instanceof Error && error.message.includes(p)), at);
      assert.equal(rec.journal.lastSeq, k, at);
      assert.deepEqual(rec.store, before, at);
    } else {
      // Only a cut after every transition the store applied is indistinguishable from a crash,
      // and recovering from it must keep all spend.
      accepted++;
      const after = Controller.open(sb.root);
      try {
        assert.ok(BudgetLedger.fromRecords(after.journal.records()).spent('epic', 'E1').usd >= spent.usd, `${at}: no spend lost`);
      } finally {
        after.close();
      }
    }
    fs.writeFileSync(jf, full);
  }
  t.diagnostic(`earlier journals tried: ${refused + accepted}; refused ${refused}; accepted ${accepted} (cuts after the last transition)`);
  assert.ok(refused > 0, 'some restored journals were refused');
  assert.ok(refused >= accepted * 5, `almost every earlier journal is refused (refused ${refused}, accepted ${accepted})`);
  // Doctor names the same inconsistency.
  const lastTransition = lines.map((l) => l.includes('"type":"task.transition"')).lastIndexOf(true);
  fs.writeFileSync(jf, lines.slice(0, lastTransition).join('\n') + '\n');
  assert.ok(doctor(sb.root).problems.some((p) => /T5 is done at journal seq \d+, journal says \w+ at seq \d+ .*resume refuses/.test(p)));
  fs.writeFileSync(jf, full);
});

test('a journal cut back past a repeated block cannot undo the block by passing for a crash', async () => {
  // The second review's case: blocked (budget), unblocked by a human, blocked again. Cut just
  // after the unblock, the journal expects ready one step after blocked, and the store is
  // blocked again; only the journal position recorded in the store tells the two blocks apart.
  // As in the epic-cap test: X and Y spend $4 each, then Z (5 more) no longer fits in $12.
  const sb = sandbox((p) => ({ ...p, budget: { ...p.budget, epic: { usd: 12, tokens: 20_000_000 } } }));
  const plan: Plan = { epicId: 'E1', title: 'three', tasks: ['X', 'Y', 'Z'].map((id) => ({ id, title: id, deps: [] })) };
  const runner = (): FakeRunner => new FakeRunner({ default: { behaviour: 'pass', costUsd: 4 } });
  let c = Controller.open(sb.root);
  try {
    c.importPlan(plan, sb.repo, 'h');
    assert.equal((await c.run(runner(), { repoPath: sb.repo })).states['Z'], 'blocked');
    c.unblock('Z', 'h', 'try again');
    assert.equal((await c.run(runner(), { repoPath: sb.repo })).states['Z'], 'blocked');
  } finally {
    c.close();
  }
  const jf = path.join(sb.root, 'journal.jsonl');
  const lines = fs.readFileSync(jf, 'utf8').split('\n').filter(Boolean);
  const unblocked = lines.findIndex((l) => l.includes('"type":"task.transition"') && l.includes('"from":"blocked"'));
  fs.writeFileSync(jf, lines.slice(0, unblocked + 1).join('\n') + '\n');
  assert.throws(() => Controller.open(sb.root), /Z is blocked at journal seq \d+, journal says ready at seq \d+ \(or blocked at seq \d+ after a crash\)/);
  assert.equal(storeSnapshot(sb.root).find((t) => t.id === 'Z')?.state, 'blocked', 'the block stands');
});

test('evidence or escalation files the journal never recorded make recovery refuse', async () => {
  const { sb, c } = await runPlan(twoIndependent, { default: { behaviour: 'pass' } });
  c.close();
  const ev = path.join(sb.root, 'evidence');
  fs.cpSync(path.join(ev, 'A', 'a1'), path.join(ev, 'A', 'a2'), { recursive: true });
  assert.throws(() => Controller.open(sb.root), /evidence for attempt A#2 exists, but the journal has no end for that attempt/);
  fs.rmSync(path.join(ev, 'A', 'a2'), { recursive: true });
  fs.writeFileSync(path.join(sb.root, 'escalations', 'esc-A-99.json'), '{}');
  assert.throws(() => Controller.open(sb.root), /escalation file esc-A-99 exists, but the journal has no such escalation/);
});

test('no command can act on a state root that recovery refuses: the controller refuses on open', async () => {
  // The second rollback review's case: A blocked, B done; the journal is then restored to just
  // after the plan import. unblock, plan import and policy commands all open the controller.
  const sb = sandbox();
  const plan: Plan = { epicId: 'E1', title: 'two', tasks: ['A', 'B'].map((id) => ({ id, title: id, deps: [] })) };
  const { c } = await runPlan(plan, { default: { behaviour: 'pass' }, tasks: { A: [{ behaviour: 'verify-fail', signature: 's' }, { behaviour: 'verify-fail', signature: 's' }] } }, sb);
  c.close();
  const jf = path.join(sb.root, 'journal.jsonl');
  const lines = fs.readFileSync(jf, 'utf8').split('\n').filter(Boolean);
  const cut = Buffer.from(lines.slice(0, lines.findIndex((l) => l.includes('"type":"plan.import"')) + 1).join('\n') + '\n');
  fs.writeFileSync(jf, cut);
  const before = storeSnapshot(sb.root);
  assert.equal(before.find((t) => t.id === 'A')?.state, 'blocked');
  for (let i = 0; i < 3; i++) {
    assert.throws(() => Controller.open(sb.root), RecoveryRefusedError);
    assert.throws(() => Controller.open(sb.root, { allowPolicyDrift: true }), RecoveryRefusedError);
  }
  assert.deepEqual(fs.readFileSync(jf), cut, 'the journal is unchanged');
  assert.deepEqual(storeSnapshot(sb.root), before, 'the store is unchanged');
});

test('counters changed in the store behind the controller are refused, even ones the journal never set', () => {
  const sb = sandbox();
  const c0 = Controller.open(sb.root);
  c0.importPlan(twoIndependent, sb.repo, 'h');
  c0.close();
  // A task no transition has touched: the journal has set none of its counters.
  openStore(statePaths(sb.root), { create: false }).updateCounters('A', { correctionFailures: -100 });
  assert.throws(() => Controller.open(sb.root), /A counters differ from the journal \(correctionFailures -100, journal says 0\)/);
  assert.ok(doctor(sb.root).problems.some((p) => /A counters differ from the journal/.test(p)));
});

test('two tasks behind the journal at once are refused: a crash leaves at most the last transition unapplied', () => {
  const sb = sandbox();
  let c = Controller.open(sb.root);
  c.importPlan(twoIndependent, sb.repo, 'h');
  c.journal.append('task.transition', { taskId: 'A', from: 'planned', to: 'ready', reason: 'dependencies done' });
  c.journal.append('task.transition', { taskId: 'B', from: 'planned', to: 'ready', reason: 'dependencies done' });
  c.close();
  assert.throws(() => Controller.open(sb.root), /A is one transition behind .* but only the journal's last transition \(seq \d+\) can be left unapplied by a crash/);
  // With A applied, B alone is a legitimate crash state.
  openStore(statePaths(sb.root), { create: false }).compareAndSetState('A', 'planned', 'ready', { journalSeq: JSON.parse(fs.readFileSync(path.join(sb.root, 'journal.jsonl'), 'utf8').trim().split('\n').at(-2) as string).seq });
  c = Controller.open(sb.root);
  try {
    assert.deepEqual(c.resume().transitionsReplayed, ['B:planned->ready']);
  } finally {
    c.close();
  }
});

test('a refusal is reported with its problems even when the forensic record cannot be written', () => {
  const sb = sandbox();
  const c0 = Controller.open(sb.root);
  c0.importPlan(twoIndependent, sb.repo, 'h');
  c0.close();
  openStore(statePaths(sb.root), { create: false }).compareAndSetState('A', 'planned', 'done');
  fs.writeFileSync(path.join(sb.root, 'forensics'), 'not a directory');
  assert.throws(() => Controller.open(sb.root), (err: Error) => {
    assert.ok(err instanceof RecoveryRefusedError);
    assert.match(err.message, /A is done at journal seq 0, journal says planned at seq 0/);
    assert.match(err.message, /The forensic record could not be written \(/);
    return true;
  });
});

test('a torn journal tail is preserved in a forensic record before the repair drops it', () => {
  const sb = sandbox();
  const jf = path.join(sb.root, 'journal.jsonl');
  const torn = '{"seq":99,"ts":"2026-10-19T00:00:00.000Z","type":"task.tr';
  fs.appendFileSync(jf, torn);
  const c = Controller.open(sb.root);
  c.close();
  assert.equal(fs.readFileSync(jf, 'utf8').includes(torn), false, 'the repair dropped the partial line');
  const dir = path.join(sb.root, 'forensics');
  const kept = fs.readdirSync(dir).filter((f) => f.includes('torn-journal')).map((f) => JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8')) as { journalBase64: string });
  assert.equal(kept.length, 1);
  assert.ok(Buffer.from(kept[0]?.journalBase64 ?? '', 'base64').toString('utf8').endsWith(torn), 'the torn bytes were kept');
});

test('a refused state root with a torn journal tail is left exactly as found', () => {
  const sb = sandbox();
  const c0 = Controller.open(sb.root);
  c0.importPlan(twoIndependent, sb.repo, 'h');
  c0.close();
  openStore(statePaths(sb.root), { create: false }).compareAndSetState('A', 'planned', 'done');
  const jf = path.join(sb.root, 'journal.jsonl');
  fs.appendFileSync(jf, '{"seq":9');
  const found = fs.readFileSync(jf);
  const tasksFound = storeSnapshot(sb.root);
  const filesFound = evidenceAndEscalations(sb.root);
  assert.throws(() => Controller.open(sb.root), RecoveryRefusedError);
  assert.deepEqual(fs.readFileSync(jf), found, 'the torn tail was not repaired before the refusal');
  assert.deepEqual(storeSnapshot(sb.root), tasksFound, 'the store is unchanged');
  assert.deepEqual(evidenceAndEscalations(sb.root), filesFound, 'evidence and escalations are unchanged');
});

test('forensic records are never written through a link out of the state root', { skip: process.platform === 'win32' && 'symlinks need privileges on Windows' }, () => {
  const sb = sandbox();
  const c0 = Controller.open(sb.root);
  c0.importPlan(twoIndependent, sb.repo, 'h');
  c0.close();
  openStore(statePaths(sb.root), { create: false }).compareAndSetState('A', 'planned', 'done');
  const outside = tmpDir();
  fs.symlinkSync(outside, path.join(sb.root, 'forensics'));
  assert.throws(() => Controller.open(sb.root), /A is done .*The forensic record could not be written \(.*must be a directory, not a link/);
  assert.deepEqual(fs.readdirSync(outside), []);
});

test('a legitimate crash followed by eo unblock of another task still recovers', async () => {
  // The third review's case: the journal's last transition is unapplied when a human unblocks
  // another task, which journals a transition after it. Opening finishes the interrupted
  // transition first, so the state root never looks like it has an older unapplied one.
  const sb = sandbox();
  const plan: Plan = { epicId: 'E1', title: 'two', tasks: ['A', 'B'].map((id) => ({ id, title: id, deps: [] })) };
  const { c } = await runPlan(plan, { default: { behaviour: 'pass' }, tasks: { A: [{ behaviour: 'verify-fail', signature: 's' }, { behaviour: 'verify-fail', signature: 's' }] } }, sb);
  c.close();
  assert.equal(storeSnapshot(sb.root).find((t) => t.id === 'A')?.state, 'blocked');
  // Crash: a new task C's first transition is journaled, the store never applies it.
  const c1 = Controller.open(sb.root);
  c1.importPlan({ epicId: 'E2', title: 'more', tasks: [{ id: 'C', title: 'c', deps: [] }] }, sb.repo, 'h');
  c1.journal.append('task.transition', { taskId: 'C', from: 'planned', to: 'ready', reason: 'dependencies done' });
  c1.close();
  const c2 = Controller.open(sb.root);
  try {
    assert.equal(c2.store.get('C')?.state, 'ready', 'opening finished the interrupted transition');
    c2.unblock('A', 'h', 'retry');
  } finally {
    c2.close();
  }
  const c3 = Controller.open(sb.root);
  try {
    c3.resume();
    assert.equal(c3.store.get('A')?.state, 'ready');
    assert.equal(c3.store.get('C')?.state, 'ready');
  } finally {
    c3.close();
  }
  assert.deepEqual(doctor(sb.root).problems, []);
});

test('a state root written before journal positions is refused with a clear message', { skip: TEST_STORE === 'beads' && 'edits the FakeStore file' }, () => {
  const sb = sandbox();
  const c0 = Controller.open(sb.root);
  c0.importPlan(twoIndependent, sb.repo, 'h');
  c0.close();
  editStore(sb, (t) => {
    delete (t['A'] as Record<string, unknown>)['journalSeq'];
  });
  assert.throws(() => Controller.open(sb.root), /A has no journal position: it was written by an older eo/);
});

test('other refusals to open also leave a forensic record', () => {
  const sb = sandbox();
  const pf = path.join(sb.root, 'policy.json');
  fs.writeFileSync(pf, fs.readFileSync(pf, 'utf8').replace('"max": 2', '"max": 1'));
  assert.throws(() => Controller.open(sb.root), /policy.json differs .* Forensic record: .*open-refused/);
});

test('a legitimate crash between the journal append and the store update is recovered', () => {
  const sb = sandbox();
  let c = Controller.open(sb.root);
  c.importPlan(twoIndependent, sb.repo, 'h');
  // The transition is journaled, then the controller dies before the store applies it.
  const rec = c.journal.append('task.transition', { taskId: 'A', from: 'planned', to: 'ready', reason: 'dependencies done' });
  c.close();
  assert.equal(storeSnapshot(sb.root).find((t) => t.id === 'A')?.state, 'planned');
  assert.ok(doctor(sb.root).problems.some((p) => /A is planned, journal says ready \(the journal's last transition, left unapplied by a crash/.test(p)));
  c = Controller.open(sb.root);
  try {
    const report = c.resume();
    assert.deepEqual(report.transitionsReplayed, ['A:planned->ready']);
    const a = c.store.get('A');
    assert.equal(a?.state, 'ready');
    assert.equal(a?.journalSeq, rec.seq, 'the store records which journal record it applied');
  } finally {
    c.close();
  }
  assert.deepEqual(doctor(sb.root).problems, []);
});

test('known limit (M2-0b): restoring the journal and the store together to an older consistent snapshot is not detected', { skip: TEST_STORE === 'beads' && 'copies the FakeStore state root' }, async () => {
  // Without a checkpoint outside the state root, an older copy of the whole state root is
  // internally consistent and looks like a state root that simply stopped there. Recording
  // the journal head somewhere a rollback of the state root cannot reach is M2-0b.
  const sb = sandbox();
  let c = Controller.open(sb.root);
  c.importPlan(twoIndependent, sb.repo, 'h');
  c.close();
  const snapshot = path.join(sb.dir, 'snapshot');
  fs.cpSync(sb.root, snapshot, { recursive: true });
  c = Controller.open(sb.root);
  await c.run(new FakeRunner({ default: { behaviour: 'pass' } }), { repoPath: sb.repo });
  c.close();
  fs.rmSync(sb.root, { recursive: true });
  fs.cpSync(snapshot, sb.root, { recursive: true });
  c = Controller.open(sb.root);
  try {
    c.resume();
    assert.deepEqual(c.store.list().map((t) => t.state), ['planned', 'planned'], 'the rollback went unnoticed');
  } finally {
    c.close();
  }
});

test('the run summary reports tasks stalled behind a blocked dependency', async () => {
  const { c, summary } = await runPlan(samplePlan(), { default: { behaviour: 'pass' }, tasks: { T1: [{ behaviour: 'verify-fail', signature: 'z' }, { behaviour: 'verify-fail', signature: 'z' }] } });
  try {
    assert.equal(summary.states['T1'], 'blocked');
    assert.deepEqual(summary.stalled, ['T2', 'T3']);
  } finally {
    c.close();
  }
});

// ------------------------------------------------------------------ review repairs

function storeFile(sb: Sandbox): string {
  return path.join(sb.root, 'store', 'tasks.json');
}

function editStore(sb: Sandbox, fn: (tasks: Record<string, Record<string, unknown>>) => void): void {
  const s = JSON.parse(fs.readFileSync(storeFile(sb), 'utf8')) as { tasks: Record<string, Record<string, unknown>> };
  fn(s.tasks);
  fs.writeFileSync(storeFile(sb), JSON.stringify(s));
}

test('a task injected into the store behind the controller is refused, not run', { skip: TEST_STORE === 'beads' && 'edits the FakeStore file; the beads equivalent is in tests/integration/beads.test.ts' }, async () => {
  const sb = sandbox();
  const c0 = Controller.open(sb.root);
  c0.importPlan(twoIndependent, sb.repo, 'h');
  c0.close();
  editStore(sb, (t) => {
    t['X'] = { ...(t['A'] as object), id: 'X', epicId: 'EVIL', state: 'ready' };
  });
  // Refused on open, before any command (run, unblock, import) could act on it.
  assert.throws(() => Controller.open(sb.root), /X is not in any journaled plan/);
  assert.match(doctor(sb.root).problems.join(';'), /X is not in any journaled plan/);
});

test('a task whose epic or dependencies were edited in the store is refused', { skip: TEST_STORE === 'beads' && 'edits the FakeStore file; the beads equivalent is in tests/integration/beads.test.ts' }, async () => {
  for (const edit of [(t: Record<string, Record<string, unknown>>) => ((t['A'] as Record<string, unknown>)['epicId'] = 'OTHER'), (t: Record<string, Record<string, unknown>>) => ((t['T5'] as Record<string, unknown>)['deps'] = [])]) {
    const sb = sandbox();
    const c0 = Controller.open(sb.root);
    c0.importPlan({ ...samplePlan(), tasks: [...samplePlan().tasks, { id: 'A', title: 'a', deps: [] }] }, sb.repo, 'h');
    c0.close();
    editStore(sb, edit);
    assert.throws(() => Controller.open(sb.root), /does not match the journaled plans/);
  }
});

test('tasks run only against the repository their plan was approved for', async () => {
  const sb = sandbox();
  const other = path.join(sb.dir, 'other-repo');
  fs.mkdirSync(other);
  const c = Controller.open(sb.root);
  try {
    c.approveRepository(other, 'h');
    c.importPlan(twoIndependent, sb.repo, 'h');
    const log = path.join(sb.dir, 'exec.log');
    const s = await c.run(new FakeRunner({ default: { behaviour: 'pass' }, execLog: log }), { repoPath: other });
    assert.deepEqual(readExecLog(log), [], 'nothing launched under the other repository');
    assert.deepEqual(s.states, { A: 'ready', B: 'ready' });
    assert.equal(c.journal.ofType('run.skip').length, 2);
    const ok = await c.run(new FakeRunner({ default: { behaviour: 'pass' } }), { repoPath: sb.repo });
    assert.deepEqual(ok.states, { A: 'done', B: 'done' });
  } finally {
    c.close();
  }
});

test('a hand-edited policy can be accepted by a human, after which the controller opens', () => {
  const sb = sandbox();
  const file = path.join(sb.root, 'policy.json');
  const p = loadPolicy(file);
  p.limits.maxAttempts = 4;
  fs.writeFileSync(file, JSON.stringify(p, null, 2));
  assert.throws(() => Controller.open(sb.root), /eo policy accept/);
  const c = Controller.open(sb.root, { allowPolicyDrift: true });
  c.acceptPolicy('test-human');
  c.close();
  const c2 = Controller.open(sb.root);
  try {
    assert.equal(c2.policy.limits.maxAttempts, 4);
  } finally {
    c2.close();
  }
  assert.deepEqual(doctor(sb.root).problems, []);
});

test('a crash between journaling a policy change and committing it does not wedge the state root', () => {
  // Crash after the intent but before the file write: the old policy stays in force.
  const sb = sandbox();
  const file = path.join(sb.root, 'policy.json');
  let c = Controller.open(sb.root);
  const next = { ...c.policy, leaseMs: 1234 };
  c.journal.append('policy.pending', { hash: policyHash(next), reason: 'test' });
  c.close();
  c = Controller.open(sb.root);
  assert.notEqual(c.policy.leaseMs, 1234);
  // Crash after the file write but before the commit: the change is completed on open.
  c.journal.append('policy.pending', { hash: policyHash(next), reason: 'test' });
  fs.writeFileSync(file, JSON.stringify(next, null, 2));
  c.close();
  c = Controller.open(sb.root);
  try {
    assert.equal(c.policy.leaseMs, 1234);
    const last = c.journal.ofType<{ reason: string }>('policy.set').at(-1);
    assert.match(last?.data.reason ?? '', /^completed: test/);
  } finally {
    c.close();
  }
});

test('a malformed reported cost is charged as unknown instead of wedging the journal', async () => {
  const sb = sandbox();
  const c = Controller.open(sb.root);
  try {
    c.importPlan(twoIndependent, sb.repo, 'h');
    const runner = {
      kind: 'bad-cost',
      run: async () => ({ kind: 'completed' as const, cost: { usd: -1, tokens: 1.5 }, verification: { verdict: 'pass' as const, signature: null }, review: { verdict: 'approve' as const }, summary: '' }),
    };
    const s = await c.run(runner, { repoPath: sb.repo });
    assert.deepEqual(s.states, { A: 'done', B: 'done' });
    const end = c.journal.ofType<{ taskId: string; invalidCost?: string; result: { cost: unknown } }>('attempt.end').find((r) => r.data.taskId === 'A');
    assert.equal(end?.data.result.cost, null);
    assert.match(end?.data.invalidCost ?? '', /-1/);
    assert.ok(c.journal.ofType<{ basis: string }>('budget.settle').every((r) => r.data.basis === 'unknown'));
  } finally {
    c.close();
  }
});
