import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { Controller, type AttemptEndRecord } from '../../src/controller.ts';
import { FakeRunner } from '../../src/runner/fake.ts';
import { fakeJudgesFor, readVerdictLog } from '../../src/verify/fake.ts';
import { doctor } from '../../src/doctor.ts';
import { REPO_ROOT, sandbox, tmpDir } from '../support/helpers.ts';
import type { Plan } from '../../src/plan.ts';

/**
 * State roots written before verdicts moved to the controller still open, resume and replay.
 *
 * tests/fixtures/legacy-m1 holds state roots produced by that code (origin/main at 79fef7a,
 * fake store, `eo run --runner fake`), copied as they were left:
 *   crash-after-fail-end  killed (EO_CRASH_AT) right after A#1's attempt.end, whose result
 *                         carries the runner's own verdict: verification fail "legacy:A1"
 *   crash-after-pass-end  the same, with verification pass and review approve
 *   complete              a finished run: A failed verification once, B had changes requested once
 * They were made elsewhere, under another rollback anchor, so each is adopted into this test's
 * anchor first, as an operator does for a state root moved between machines
 * ("eo anchor adopt --accept-rollback"). The M1 recovery checks still apply to it.
 */
const FIXTURES = path.join(REPO_ROOT, 'tests', 'fixtures', 'legacy-m1');

function copyFixture(name: string): string {
  const root = path.join(tmpDir('eo-legacy-'), 'state');
  fs.cpSync(path.join(FIXTURES, name), root, { recursive: true });
  // A checkout does not keep modes; a state root must be private.
  const fix = (p: string): void => {
    const st = fs.statSync(p);
    if (st.isDirectory()) {
      fs.chmodSync(p, 0o700);
      for (const e of fs.readdirSync(p)) fix(path.join(p, e));
    } else fs.chmodSync(p, 0o600);
  };
  fix(root);
  return root;
}

function adopt(root: string): Controller {
  return Controller.open(root, { adopt: { by: 'test-operator', acceptRollback: true } });
}

function newRecordTypes(c: Controller, from: number): string[] {
  return c.journal.records().slice(from).map((r) => r.type);
}

test('legacy: an M1 journal killed after an attempt.end with an embedded pass resumes to done, with no verifier', () => {
  const root = copyFixture('crash-after-pass-end');
  const c = adopt(root);
  try {
    const before = c.journal.records().length;
    const end = c.journal.ofType<AttemptEndRecord>('attempt.end').at(-1);
    assert.equal((end?.data.result as { verification?: { verdict: string } }).verification?.verdict, 'pass', 'the fixture has an M1 attempt.end');
    assert.equal(c.store.get('A')?.state, 'implementing');
    const rep = c.resume();
    assert.deepEqual(rep.advanced, ['A']);
    assert.deepEqual(rep.awaitingVerdict, []);
    const a = c.store.get('A');
    assert.equal(a?.state, 'done');
    assert.equal(a?.attempt, 1);
    // The M1 verdicts were replayed from the old record; no controller verdict was made up for them.
    const added = newRecordTypes(c, before);
    assert.ok(!added.includes('verify.verdict') && !added.includes('review.verdict') && !added.includes('verdict.rejected'), added.join(' '));
    const reasons = c.journal.ofType<{ taskId: string; reason: string }>('task.transition').filter((r) => r.data.taskId === 'A').map((r) => r.data.reason);
    assert.ok(reasons.includes('verification passed (M1: scripted)') && reasons.includes('review approved (M1: scripted)'), reasons.join(' | '));
    // Evidence sealed on resume is marked as the M1 placeholder, as that code sealed it.
    assert.deepEqual(c.evidence.verify('A', 1), []);
    assert.equal(c.evidence.read('A', 1)?.facts['placeholder'], 'M1');
    assert.match(fs.readFileSync(path.join(c.evidence.attemptDir('A', 1), 'verification.json'), 'utf8'), /M1 placeholder/);
    // The spend of the attempt the old controller ran was settled once, at its reported cost.
    assert.deepEqual(c.journal.ofType<{ usd: number; basis: string }>('budget.settle').map((r) => [r.data.usd, r.data.basis]), [[0.01, 'reported']]);
    assert.equal(c.store.get('B')?.state, 'ready');
  } finally {
    c.close();
  }
  assert.deepEqual(doctor(root).problems, []);
});

test('legacy: an M1 journal killed after an attempt.end with an embedded failure resumes into the correction loop', () => {
  const root = copyFixture('crash-after-fail-end');
  const c = adopt(root);
  try {
    c.resume();
    const a = c.store.get('A');
    assert.equal(a?.state, 'ready');
    assert.equal(a?.attempt, 1);
    assert.equal(a?.correctionFailures, 1);
    assert.equal(a?.lastFailureSignature, 'legacy:A1');
    assert.equal(c.evidence.read('A', 1)?.facts['verification'], 'fail');
    // Resuming again changes nothing.
    const n = c.journal.records().length;
    const rep = c.resume();
    assert.deepEqual(rep.advanced, []);
    assert.equal(c.journal.records().length, n + 1, 'only the resume record');
  } finally {
    c.close();
  }
  assert.deepEqual(doctor(root).problems, []);
});

test('legacy: a finished M1 state root opens, resumes as a no-op and verifies, its evidence untouched', () => {
  const root = copyFixture('complete');
  const evidenceBefore = fs.readFileSync(path.join(root, 'evidence', 'A', 'a1', 'manifest.json'), 'utf8');
  const c = adopt(root);
  try {
    assert.deepEqual(c.summary().states, { A: 'done', B: 'done' });
    const rep = c.resume();
    assert.deepEqual([rep.advanced, rep.interrupted, rep.transitionsReplayed, rep.awaitingVerdict], [[], [], [], []]);
    for (const [id, attempts] of [['A', 2], ['B', 2]] as const) {
      assert.equal(c.store.get(id)?.attempt, attempts);
      for (let n = 1; n <= attempts; n++) assert.deepEqual(c.evidence.verify(id, n), [], `${id}#${n}`);
    }
    assert.equal(c.store.get('A')?.lastFailureSignature, 'legacy:A1');
    assert.equal(c.evidence.read('B', 1)?.facts['review'], 'changes');
  } finally {
    c.close();
  }
  assert.equal(fs.readFileSync(path.join(root, 'evidence', 'A', 'a1', 'manifest.json'), 'utf8'), evidenceBefore);
  assert.deepEqual(doctor(root).problems, []);
});

test('legacy and new records in one journal: an M1 attempt end is replayed, the next attempt is judged by the controller', async () => {
  // Built by hand: an attempt the M1 controller ended with an embedded failure, then a run
  // under the new code. Only attempt 2 goes to the controller's verifier and reviewer.
  const sb = sandbox();
  const plan: Plan = { epicId: 'E1', title: 'one', tasks: [{ id: 'A', title: 'a', deps: [] }] };
  const log = path.join(sb.dir, 'verdicts.log');
  let c = Controller.open(sb.root);
  try {
    c.importPlan(plan, sb.repo, 'h');
    c.promote();
    assert.equal(c.budget.reserve('A#1@m1', 'A', 'E1').kind, 'admit');
    c.transition({ taskId: 'A', from: 'ready', to: 'implementing', reason: 'attempt 1', attempt: 1, reservationId: 'A#1@m1' });
    c.journal.append('attempt.end', {
      taskId: 'A',
      attempt: 1,
      result: { kind: 'completed', cost: { usd: 0.01, tokens: 1000 }, verification: { verdict: 'fail', signature: 'm1-sig' }, review: { verdict: 'approve' }, summary: 'scripted verification failure' },
      synthesized: false,
    });
  } finally {
    c.close();
  }
  c = Controller.open(sb.root);
  try {
    const script = { default: { behaviour: 'pass' as const }, verdictLog: log };
    const s = await c.run(new FakeRunner(script), { ...fakeJudgesFor(script), repoPath: sb.repo });
    assert.equal(s.states['A'], 'done');
    const a = c.store.get('A');
    assert.equal(a?.attempt, 2);
    assert.equal(a?.correctionFailures, 1);
    assert.equal(a?.lastFailureSignature, 'm1-sig');
    assert.deepEqual(readVerdictLog(log).map((e) => `${e.stage}:${e.taskId}#${e.attempt}`), ['verification:A#2', 'review:A#2']);
    assert.equal(c.evidence.read('A', 1)?.facts['placeholder'], 'M1');
    assert.equal(c.evidence.read('A', 2)?.facts['verificationSource'], 'controller');
  } finally {
    c.close();
  }
  assert.deepEqual(doctor(sb.root).problems, []);
});
