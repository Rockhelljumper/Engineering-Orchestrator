import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { Controller } from '../../src/controller.ts';
import { statePaths } from '../../src/stateRoot.ts';
import { openStore } from '../../src/store/open.ts';
import { readExecLog, runCli, samplePlan, sandbox, tmpDir, writeJson } from '../support/helpers.ts';

function imported(): ReturnType<typeof sandbox> {
  const sb = sandbox();
  const c = Controller.open(sb.root);
  c.importPlan(samplePlan(), sb.repo, 'test-human');
  c.close();
  return sb;
}

test('eo init creates a state root and refuses to overwrite it', () => {
  const root = path.join(tmpDir(), 'state');
  const r = runCli(['init', '--state-root', root]);
  assert.equal(r.status, 0, r.stderr);
  for (const f of ['policy.json', 'journal.key', 'journal.jsonl']) assert.ok(fs.existsSync(path.join(root, f)), f);
  if (process.platform !== 'win32') assert.equal(fs.statSync(path.join(root, 'journal.key')).mode & 0o077, 0, 'key is owner-only');
  const again = runCli(['init', '--state-root', root]);
  assert.equal(again.status, 1);
  assert.match(again.stderr, /already initialised/);
});

test('human gates refuse to run without an interactive terminal', () => {
  const sb = imported();
  const planFile = writeJson(path.join(sb.dir, 'plan.json'), { ...samplePlan('E2'), tasks: [{ id: 'X1', title: 'x', deps: [] }] });
  const cases = [
    ['policy', 'approve-repo', tmpDir()],
    ['plan', 'import', planFile, '--repo', sb.repo],
    ['unblock', 'T1', '--note', 'n'],
  ];
  for (const args of cases) {
    // Piping the confirmation word on stdin must not count as a human.
    const word = args[0] === 'unblock' ? 'unblock' : 'approve';
    const r = runCli([...args, '--state-root', sb.root], {}, `${word}\n`);
    assert.equal(r.status, 2, `${args.join(' ')}: ${r.stderr}`);
    assert.match(r.stderr, /needs a human at an interactive terminal/);
  }
  const c = Controller.open(sb.root);
  try {
    assert.equal(c.policy.approvedRepositories.length, 1, 'no repository was approved');
    assert.equal(c.store.get('X1'), undefined, 'no plan was imported');
  } finally {
    c.close();
  }
});

test('M1-10: eo run refuses an unapproved repository and launches nothing', () => {
  const sb = imported();
  const log = path.join(sb.dir, 'exec.log');
  const script = writeJson(path.join(sb.dir, 'script.json'), { default: { behaviour: 'pass' }, execLog: log });
  const r = runCli(['run', '--state-root', sb.root, '--repo', tmpDir(), '--runner', 'fake', '--script', script]);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /repository not approved/);
  assert.deepEqual(readExecLog(log), []);
});

test('eo run with the fake runner completes the sample epic; status and doctor agree', () => {
  const sb = imported();
  const log = path.join(sb.dir, 'exec.log');
  const script = writeJson(path.join(sb.dir, 'script.json'), { default: { behaviour: 'pass' }, tasks: { T3: [{ behaviour: 'verify-fail' }] }, execLog: log });
  const r = runCli(['run', '--state-root', sb.root, '--repo', sb.repo, '--runner', 'fake', '--script', script]);
  assert.equal(r.status, 0, r.stderr);
  const summary = JSON.parse(r.stdout) as { states: Record<string, string> };
  assert.deepEqual(Object.values(summary.states), ['done', 'done', 'done', 'done', 'done']);

  const st = runCli(['status', '--json', '--state-root', sb.root]);
  assert.equal(st.status, 0, st.stderr);
  const s = JSON.parse(st.stdout) as { tasks: Array<{ id: string; state: string; attempt: number }>; journal: { ok: boolean }; budget: Array<{ spent: { usd: number }; reserved: { usd: number } }> };
  assert.equal(s.tasks.find((t) => t.id === 'T3')?.attempt, 2);
  assert.equal(s.journal.ok, true);
  assert.equal(s.budget[0]?.reserved.usd, 0);
  assert.ok((s.budget[0]?.spent.usd ?? 0) > 0);
  const human = runCli(['status', '--state-root', sb.root]);
  assert.match(human.stdout, /estimates, not billing/);

  const d = runCli(['doctor', '--state-root', sb.root]);
  assert.equal(d.status, 0, d.stdout);
  const ev = runCli(['evidence', 'T3', '--attempt', '1', '--state-root', sb.root]);
  assert.equal(ev.status, 0, ev.stdout);
  assert.match(ev.stdout, /"verification": "fail"/);
});

test('M1-5: eo doctor detects an edited journal record and an altered evidence file', () => {
  const sb = imported();
  const script = writeJson(path.join(sb.dir, 'script.json'), { default: { behaviour: 'pass' } });
  assert.equal(runCli(['run', '--state-root', sb.root, '--repo', sb.repo, '--runner', 'fake', '--script', script]).status, 0);

  // Evidence tamper.
  const evFile = path.join(sb.root, 'evidence', 'T5', 'a1', 'verification.json');
  const original = fs.readFileSync(evFile, 'utf8');
  fs.writeFileSync(evFile, original.replace('"pass"', '"PASS"'));
  let d = runCli(['doctor', '--state-root', sb.root]);
  assert.equal(d.status, 1);
  assert.match(d.stdout, /evidence T5#1: verification.json hash mismatch/);
  fs.writeFileSync(evFile, original);

  // Journal tamper: rewrite one task's verdict.
  const jf = path.join(sb.root, 'journal.jsonl');
  const lines = fs.readFileSync(jf, 'utf8').split('\n');
  const i = lines.findIndex((l) => l.includes('"type":"task.transition"') && l.includes('"to":"done"'));
  lines[i] = (lines[i] as string).replace('"to":"done"', '"to":"blocked"');
  fs.writeFileSync(jf, lines.join('\n'));
  d = runCli(['doctor', '--state-root', sb.root]);
  assert.equal(d.status, 1);
  assert.match(d.stdout, new RegExp(`journal: line ${i + 1}: MAC mismatch`));
  // And the controller refuses to operate on it.
  const res = runCli(['resume', '--state-root', sb.root]);
  assert.equal(res.status, 1);
  assert.match(res.stderr, /journal failed verification/);
});

test('eo doctor reports a store that is ahead of the journal, and resume refuses to rewind it', () => {
  const sb = imported();
  // Someone marks work done behind the controller, directly in the store.
  assert.equal(openStore(statePaths(sb.root), { create: false }).compareAndSetState('T5', 'planned', 'done'), true);
  const d = runCli(['doctor', '--state-root', sb.root]);
  assert.equal(d.status, 1);
  assert.match(d.stdout, /T5 is done, journal says planned \(ahead of or off the journal/);
  assert.match(d.stdout, /evidence T5: done without any attempt/);
  // A store ahead of a write-ahead journal is never a crash state, so resume must not "repair"
  // it by rewinding: that would undo finished work and forget its spend. A human decides.
  const r = runCli(['resume', '--state-root', sb.root]);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /task store is ahead of or diverged from the journal \(T5 is done, journal says planned\)/);
  assert.equal(openStore(statePaths(sb.root), { create: false }).get('T5')?.state, 'done', 'the store was left as found');
  assert.equal(runCli(['doctor', '--state-root', sb.root]).status, 1);
});

test('eo init refuses a root left over from an earlier state root, even without policy.json', () => {
  const root = path.join(tmpDir(), 'state');
  assert.equal(runCli(['init', '--state-root', root]).status, 0);
  const key = fs.readFileSync(path.join(root, 'journal.key'), 'utf8');
  fs.rmSync(path.join(root, 'policy.json'));
  const again = runCli(['init', '--state-root', root]);
  assert.equal(again.status, 1);
  assert.match(again.stderr, /holds an earlier state root/);
  assert.equal(fs.readFileSync(path.join(root, 'journal.key'), 'utf8'), key, 'the journal key was kept');
  // A crash during init (a key, but no journal yet) has signed nothing, so init may start over.
  const crashed = path.join(tmpDir(), 'state');
  fs.mkdirSync(crashed, { mode: 0o700 });
  fs.writeFileSync(path.join(crashed, 'journal.key'), 'f'.repeat(64));
  assert.equal(runCli(['init', '--state-root', crashed]).status, 0);
  assert.notEqual(fs.readFileSync(path.join(crashed, 'journal.key'), 'utf8'), 'f'.repeat(64));
});

test('a state root that others can write is refused', { skip: process.platform === 'win32' && 'POSIX permissions' }, () => {
  const sb = imported();
  for (const d of [sb.root, statePaths(sb.root).store]) {
    fs.chmodSync(d, 0o777);
    const r = runCli(['status', '--state-root', sb.root]);
    assert.equal(r.status, 1);
    assert.match(r.stderr, /writable by group or others/);
    fs.chmodSync(d, 0o700);
  }
  assert.equal(runCli(['status', '--state-root', sb.root]).status, 0);
  // The controller refuses before writing anything, even with a store handed to it.
  fs.chmodSync(sb.root, 0o777);
  const journalBefore = fs.readFileSync(statePaths(sb.root).journal);
  fs.rmSync(statePaths(sb.root).locks, { recursive: true, force: true });
  assert.throws(() => Controller.open(sb.root, { store: openStoreUnchecked(sb.root) }), /unsafe state root: .* writable by group or others/);
  assert.equal(fs.existsSync(statePaths(sb.root).locks), false, 'no lock directory was created');
  assert.deepEqual(fs.readFileSync(statePaths(sb.root).journal), journalBefore);
  fs.chmodSync(sb.root, 0o700);
  // eo init refuses to adopt one too.
  const open = path.join(tmpDir(), 'open');
  fs.mkdirSync(open, { mode: 0o700 });
  fs.chmodSync(open, 0o777);
  assert.equal(runCli(['init', '--state-root', open]).status, 1);
});

/** The store of a state root, opened while its directories are still private. */
function openStoreUnchecked(root: string): ReturnType<typeof openStore> {
  const mode = fs.statSync(root).mode & 0o777;
  fs.chmodSync(root, 0o700);
  try {
    return openStore(statePaths(root), { create: false });
  } finally {
    fs.chmodSync(root, mode);
  }
}

test('usage errors exit 2', () => {
  assert.equal(runCli([]).status, 2);
  assert.equal(runCli(['frobnicate', '--state-root', tmpDir()]).status, 2);
  const sb = imported();
  assert.equal(runCli(['run', '--state-root', sb.root, '--repo', sb.repo, '--runner', 'claude']).status, 2);
});

test('sealed evidence tampered with after a crash is escalated, not silently rewritten', () => {
  // Find the run's journal append that seals T1's evidence, using an identical scenario.
  const probe = imported();
  const script = (dir: string): string => writeJson(path.join(dir, 'script.json'), { default: { behaviour: 'pass' } });
  const jf = (root: string): string[] => fs.readFileSync(path.join(root, 'journal.jsonl'), 'utf8').split('\n').filter(Boolean);
  const before = jf(probe.root).length;
  assert.equal(runCli(['run', '--state-root', probe.root, '--repo', probe.repo, '--runner', 'fake', '--script', script(probe.dir)]).status, 0);
  const k = jf(probe.root).slice(before).findIndex((l) => l.includes('"type":"evidence.sealed"')) + 1;
  assert.ok(k > 0);

  const sb = imported();
  const crashed = runCli(['run', '--state-root', sb.root, '--repo', sb.repo, '--runner', 'fake', '--script', script(sb.dir)], { EO_CRASH_AT: String(k) });
  assert.equal(crashed.status, 137, crashed.stderr);
  const evFile = path.join(sb.root, 'evidence', 'T1', 'a1', 'verification.json');
  fs.writeFileSync(evFile, fs.readFileSync(evFile, 'utf8').replace('"pass"', '"PASS"'));
  assert.equal(runCli(['resume', '--state-root', sb.root]).status, 0);
  const st = JSON.parse(runCli(['status', '--json', '--state-root', sb.root]).stdout) as { tasks: Array<{ id: string; state: string }>; escalations: Array<{ category: string; detail: string }> };
  assert.equal(st.tasks.find((t) => t.id === 'T1')?.state, 'blocked');
  assert.equal(st.escalations[0]?.category, 'evidence');
  assert.match(st.escalations[0]?.detail ?? '', /sealed evidence no longer verifies: verification.json hash mismatch/);
});

test('eo policy accept refuses without an interactive terminal', () => {
  const sb = imported();
  const r = runCli(['policy', 'accept', '--state-root', sb.root], {}, 'accept\n');
  assert.equal(r.status, 2);
  assert.match(r.stderr, /needs a human at an interactive terminal/);
});
