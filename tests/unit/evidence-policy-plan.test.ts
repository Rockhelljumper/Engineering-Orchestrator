import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { randomBytes } from 'node:crypto';
import { EvidenceLedger } from '../../src/evidence.ts';
import {
  assertRepositoryApproved,
  defaultPolicy,
  isRepositoryApproved,
  loadPolicy,
  policyHash,
  PolicyError,
  savePolicy,
  validatePolicy,
  withApprovedRepository,
} from '../../src/policy.ts';
import { planHash, topoOrder, validatePlan } from '../../src/plan.ts';
import { tmpDir, samplePlan } from '../support/helpers.ts';

// ------------------------------------------------------------------ evidence

function ledger(): EvidenceLedger {
  return new EvidenceLedger(path.join(tmpDir(), 'evidence'), randomBytes(32));
}

test('sealed evidence verifies', () => {
  const ev = ledger();
  const e = ev.writeArtifact('T1', 1, 'out.txt', 'hello');
  ev.seal('T1', 1, [e], { exit: 0 });
  assert.deepEqual(ev.verify('T1', 1), []);
});

test('M1-5: changing an artefact, the manifest or its identity is detected', () => {
  const ev = ledger();
  const e = ev.writeArtifact('T1', 1, 'out.txt', 'hello');
  ev.seal('T1', 1, [e], { exit: 0 });
  const dir = ev.attemptDir('T1', 1);

  fs.writeFileSync(path.join(dir, 'out.txt'), 'HELLO');
  assert.deepEqual(ev.verify('T1', 1), ['out.txt hash mismatch']);
  fs.writeFileSync(path.join(dir, 'out.txt'), 'hello');

  const mf = path.join(dir, 'manifest.json');
  const m = JSON.parse(fs.readFileSync(mf, 'utf8')) as { facts: { exit: number } };
  m.facts.exit = 1;
  fs.writeFileSync(mf, JSON.stringify(m));
  assert.deepEqual(ev.verify('T1', 1), ['manifest MAC mismatch']);

  fs.rmSync(dir, { recursive: true });
  assert.deepEqual(ev.verify('T1', 1), ['manifest missing']);
});

test('M1-5: a manifest copied from another attempt is detected', () => {
  const ev = ledger();
  ev.seal('T1', 1, [], {});
  fs.mkdirSync(ev.attemptDir('T1', 2), { recursive: true });
  fs.copyFileSync(path.join(ev.attemptDir('T1', 1), 'manifest.json'), path.join(ev.attemptDir('T1', 2), 'manifest.json'));
  assert.deepEqual(ev.verify('T1', 2), ['manifest identity mismatch']);
});

test('M1-5: a forged manifest without the key is detected', () => {
  const ev = ledger();
  const e = ev.writeArtifact('T1', 1, 'out.txt', 'x');
  new EvidenceLedger(ev.dir, randomBytes(32)).seal('T1', 1, [e], {}); // attacker's key
  assert.deepEqual(ev.verify('T1', 1), ['manifest MAC mismatch']);
});

test('evidence paths cannot escape the ledger', () => {
  const ev = ledger();
  assert.throws(() => ev.writeArtifact('../x', 1, 'a', ''), /unsafe task id/);
  assert.throws(() => ev.writeArtifact('T1', 1, '../a', ''), /unsafe artifact name/);
  assert.throws(() => ev.writeArtifact('T1', 1, 'manifest.json', ''), /unsafe artifact name/);
  assert.throws(() => ev.writeArtifact('T1', 0, 'a', ''), /bad attempt/);
  // '.' and '..' contain no separator but still name the ledger or its parent.
  for (const id of ['.', '..', '.x']) assert.throws(() => ev.writeArtifact(id, 1, 'a', ''), /unsafe task id/, id);
  for (const name of ['.', '..']) assert.throws(() => ev.writeArtifact('T1', 1, name, ''), /unsafe artifact name/, name);
});

// ------------------------------------------------------------------ policy

test('the default policy is valid and round-trips', () => {
  const file = path.join(tmpDir(), 'policy.json');
  savePolicy(file, defaultPolicy());
  assert.deepEqual(loadPolicy(file), defaultPolicy());
  assert.equal(policyHash(loadPolicy(file)), policyHash(defaultPolicy()));
});

test('invalid policies are refused', () => {
  const bad: Array<[(p: ReturnType<typeof defaultPolicy>) => void, RegExp]> = [
    [(p) => (p.limits.maxAttempts = 0), /maxAttempts must be >= 1/],
    [(p) => (p.limits.repeatedFailureStop = 1), /repeatedFailureStop must be >= 2/],
    [(p) => (p.concurrency.max = 9), /must be <= 8/],
    [(p) => (p.budget.task.usd = 30), /task.usd exceeds budget.epic.usd/],
    [(p) => (p.budget.invocation.usd = 11), /invocation.usd exceeds budget.task.usd/],
    [(p) => ((p as unknown as Record<string, unknown>)['extra'] = 1), /unexpected property "extra"/],
  ];
  for (const [mutate, re] of bad) {
    const p = defaultPolicy();
    mutate(p);
    assert.throws(() => validatePolicy(p), re);
  }
});

test('M1-10: repository approval is by canonical path', () => {
  const dir = tmpDir();
  const repo = path.join(dir, 'repo');
  const other = path.join(dir, 'other');
  fs.mkdirSync(repo);
  fs.mkdirSync(other);
  let linked = true;
  try {
    fs.symlinkSync(repo, path.join(dir, 'link'), 'junction');
  } catch {
    linked = false; // Windows without symlink privilege
  }
  const p = withApprovedRepository(defaultPolicy(), repo, 'human');
  assert.equal(isRepositoryApproved(p, repo), true);
  if (linked) assert.equal(isRepositoryApproved(p, path.join(dir, 'link')), true, 'a symlink to an approved repo resolves to it');
  assert.equal(isRepositoryApproved(p, path.join(repo, '..', 'repo')), true);
  assert.equal(isRepositoryApproved(p, other), false);
  assert.equal(isRepositoryApproved(p, path.join(repo, 'sub')), false, 'subdirectories are not implicitly approved');
  assert.equal(isRepositoryApproved(p, path.join(dir, 'missing')), false);
  assert.throws(() => assertRepositoryApproved(p, other), PolicyError);
  assert.equal(isRepositoryApproved(defaultPolicy(), repo), false);
  // Idempotent.
  assert.equal(withApprovedRepository(p, repo, 'human'), p);
});

// ------------------------------------------------------------------ plan

test('the sample plan is valid and orders dependencies first', () => {
  const plan = validatePlan(samplePlan());
  const order = topoOrder(plan.tasks).map((t) => t.id);
  assert.deepEqual(order, ['T1', 'T2', 'T3', 'T4', 'T5']);
  for (const t of plan.tasks) for (const d of t.deps) assert.ok(order.indexOf(d) < order.indexOf(t.id));
});

test('invalid plans are refused', () => {
  const base = samplePlan();
  const cases: Array<[unknown, RegExp]> = [
    [{ ...base, tasks: [...base.tasks, { id: 'T1', title: 'dup', deps: [] }] }, /duplicate task id T1/],
    [{ ...base, tasks: [{ id: 'A', title: 'a', deps: ['Z'] }] }, /depends on unknown task Z/],
    [{ ...base, tasks: [{ id: 'A', title: 'a', deps: ['A'] }] }, /depends on itself/],
    [
      { ...base, tasks: [{ id: 'A', title: 'a', deps: ['C'] }, { id: 'B', title: 'b', deps: ['A'] }, { id: 'C', title: 'c', deps: ['B'] }] },
      /dependency cycle/,
    ],
    [{ ...base, tasks: [] }, /must have >= 1 items/],
    [{ ...base, epicId: '../x' }, /must match/],
    [{ ...base, tasks: [{ id: '..', title: 'a', deps: [] }] }, /must match/],
    [{ ...base, tasks: [{ id: '.', title: 'a', deps: [] }] }, /must match/],
    [{ ...base, epicId: '..' }, /must match/],
    [{ ...base, tasks: [{ id: 'A', title: 'a', deps: [], run: 'rm -rf /' }] }, /unexpected property "run"/],
    [{ ...base, tasks: [{ id: 'A', title: '  ', deps: [] }] }, /task A: title is empty/],
    [{ ...base, tasks: [{ id: 'A', title: 'x'.repeat(501), deps: [] }] }, /task A: title is longer than 500 bytes/],
    [{ ...base, tasks: [{ id: 'A', title: 'a\u0000', deps: [] }] }, /task A: title contains a control character/],
  ];
  for (const [plan, re] of cases) assert.throws(() => validatePlan(plan), re);
});

test('plan hash is independent of key order', () => {
  const a = samplePlan();
  const b = JSON.parse(JSON.stringify({ tasks: a.tasks, title: a.title, epicId: a.epicId })) as typeof a;
  assert.equal(planHash(a), planHash(b));
});

test('a corrupt or malformed manifest is reported, not thrown', () => {
  const ev = ledger();
  ev.seal('T1', 1, [], {});
  const mf = path.join(ev.attemptDir('T1', 1), 'manifest.json');
  fs.writeFileSync(mf, '{not json');
  assert.deepEqual(ev.verify('T1', 1), ['manifest unreadable']);
  fs.writeFileSync(mf, JSON.stringify({ taskId: 'T1', attempt: 1, entries: 'x', mac: 'ab' }));
  assert.deepEqual(ev.verify('T1', 1), ['manifest malformed']);
});

test('a repository that contains the state root, or lies inside it, cannot be approved', () => {
  const dir = tmpDir();
  const root = path.join(dir, 'state');
  fs.mkdirSync(path.join(root, 'inner'), { recursive: true });
  const other = path.join(dir, 'other');
  fs.mkdirSync(other);
  assert.throws(() => withApprovedRepository(defaultPolicy(), dir, 'h', new Date(), root), /contains or lies inside the state root/);
  assert.throws(() => withApprovedRepository(defaultPolicy(), root, 'h', new Date(), root), /contains or lies inside the state root/);
  assert.throws(() => withApprovedRepository(defaultPolicy(), path.join(root, 'inner'), 'h', new Date(), root), /contains or lies inside the state root/);
  assert.equal(withApprovedRepository(defaultPolicy(), other, 'h', new Date(), root).approvedRepositories.length, 1);
});

test('M1-10: replacing an approved directory with a symlink does not move the approval', () => {
  const dir = tmpDir();
  const repo = path.join(dir, 'repo');
  const elsewhere = path.join(dir, 'elsewhere');
  fs.mkdirSync(repo);
  fs.mkdirSync(elsewhere);
  const p = withApprovedRepository(defaultPolicy(), repo, 'human');
  fs.renameSync(repo, path.join(dir, 'moved'));
  try {
    fs.symlinkSync(elsewhere, repo, 'junction');
  } catch {
    return; // Windows without symlink privilege
  }
  assert.equal(isRepositoryApproved(p, repo), false);
  assert.equal(isRepositoryApproved(p, elsewhere), false);
});
