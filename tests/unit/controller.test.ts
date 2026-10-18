import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { Controller, ControllerError, type EscalationRecord } from '../../src/controller.ts';
import { FakeRunner, type FakeScript } from '../../src/runner/fake.ts';
import { PolicyError, loadPolicy, policyHash } from '../../src/policy.ts';
import { doctor } from '../../src/doctor.ts';
import { readExecLog, samplePlan, sandbox, TEST_STORE, tmpDir, type Sandbox } from '../support/helpers.ts';
import type { Plan } from '../../src/plan.ts';

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
  const log = path.join(sb.dir, 'exec.log');
  const c = Controller.open(sb.root);
  try {
    await assert.rejects(c.run(new FakeRunner({ default: { behaviour: 'pass' }, execLog: log }), { repoPath: sb.repo }), /X is not in any journaled plan/);
    assert.deepEqual(readExecLog(log), []);
  } finally {
    c.close();
  }
  assert.match(doctor(sb.root).problems.join(';'), /X is not in any journaled plan/);
});

test('a task whose epic or dependencies were edited in the store is refused', { skip: TEST_STORE === 'beads' && 'edits the FakeStore file; the beads equivalent is in tests/integration/beads.test.ts' }, async () => {
  for (const edit of [(t: Record<string, Record<string, unknown>>) => ((t['A'] as Record<string, unknown>)['epicId'] = 'OTHER'), (t: Record<string, Record<string, unknown>>) => ((t['T5'] as Record<string, unknown>)['deps'] = [])]) {
    const sb = sandbox();
    const c0 = Controller.open(sb.root);
    c0.importPlan({ ...samplePlan(), tasks: [...samplePlan().tasks, { id: 'A', title: 'a', deps: [] }] }, sb.repo, 'h');
    c0.close();
    editStore(sb, edit);
    const c = Controller.open(sb.root);
    try {
      await assert.rejects(c.run(new FakeRunner({ default: { behaviour: 'pass' } }), { repoPath: sb.repo }), /does not match the journaled plans/);
    } finally {
      c.close();
    }
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
