import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { canonicalJson, hmacHex } from '../../src/util/canonical.ts';
import { keyIdOf, RollbackAnchor, rootIdOf } from '../../src/anchor.ts';
import { Controller, RecoveryRefusedError } from '../../src/controller.ts';
import { doctor } from '../../src/doctor.ts';
import { Journal, JournalTamperError, verifyJournalFile } from '../../src/journal.ts';
import { FakeRunner } from '../../src/runner/fake.ts';
import { initStateRoot, readJournalKey, statePaths } from '../../src/stateRoot.ts';
import { openStore } from '../../src/store/open.ts';
import { BudgetLedger } from '../../src/budget.ts';
import { policyHash, loadPolicy } from '../../src/policy.ts';
import type { Plan } from '../../src/plan.ts';
import { CLI, readExecLog, runCli, samplePlan, sandbox, TEST_STORE, tmpDir, writeJson, type Sandbox } from '../support/helpers.ts';

/**
 * M2-0b: rollback detection for the whole state root. The journal head is recorded after
 * every append in an anchor outside the state root; an older copy of the state root is
 * consistent inside but behind its anchor.
 */

const copiesRoot = TEST_STORE === 'beads' && 'copies the FakeStore state root';
const twoIndependent: Plan = { epicId: 'E1', title: 'two', tasks: [{ id: 'A', title: 'a', deps: [] }, { id: 'B', title: 'b', deps: [] }] };
const anchorDir = (): string => process.env['EO_ANCHOR_DIR'] as string;

function storeStates(root: string): Record<string, string> {
  const p = statePaths(root);
  const s = openStore(p, { create: false, records: verifyJournalFile(p.journal, readJournalKey(p)).records });
  return Object.fromEntries(s.list().map((t) => [t.id, t.state]));
}

function headOf(root: string): { journalSeq: number; journalMac: string } | null {
  return RollbackAnchor.open(anchorDir(), root).read(rootIdOf(root));
}

function headFile(root: string): string {
  return path.join(anchorDir(), 'heads', `${rootIdOf(root)}.json`);
}

/** Re-sign a journal with a new key, as someone holding a copy of the state root can. */
function rekey(root: string, edit: (r: { type: string; data: unknown }) => void = () => {}): void {
  const p = statePaths(root);
  const newKey = randomBytes(32);
  let prev = 'genesis';
  const out: string[] = [];
  for (const line of fs.readFileSync(p.journal, 'utf8').split('\n').filter(Boolean)) {
    const r = JSON.parse(line) as { seq: number; ts: string; type: string; data: unknown; prev: string; mac: string };
    edit(r);
    r.prev = prev;
    r.mac = hmacHex(newKey, canonicalJson({ seq: r.seq, ts: r.ts, type: r.type, data: r.data, prev: r.prev }));
    prev = r.mac;
    out.push(JSON.stringify(r));
  }
  fs.writeFileSync(p.journal, out.join('\n') + '\n');
  fs.writeFileSync(p.journalKey, newKey.toString('hex'), { mode: 0o600 });
}

function journalLength(root: string): number {
  const p = statePaths(root);
  return verifyJournalFile(p.journal, readJournalKey(p)).records.length;
}

function forensicFiles(root: string, kind: string): string[] {
  const d = path.join(root, 'forensics');
  return fs.existsSync(d) ? fs.readdirSync(d).filter((f) => f.endsWith(`-${kind}.json`)).sort() : [];
}

function snapshot(sb: Sandbox, name: string): string {
  const dst = path.join(sb.dir, `snap-${name}`);
  fs.cpSync(sb.root, dst, { recursive: true });
  return dst;
}

function restore(sb: Sandbox, snap: string): void {
  fs.rmSync(sb.root, { recursive: true });
  fs.cpSync(snap, sb.root, { recursive: true });
}

test('M2-0b: the anchor records every journal append, and a fresh state root is bound to it', () => {
  const sb = sandbox();
  const c = Controller.open(sb.root);
  try {
    c.importPlan(twoIndependent, sb.repo, 'h');
    const last = c.journal.records().at(-1);
    assert.deepEqual(headOf(sb.root) && { seq: headOf(sb.root)?.journalSeq, mac: headOf(sb.root)?.journalMac }, { seq: last?.seq, mac: last?.mac });
    const bound = c.journal.ofType<{ anchorId: string; rootId: string }>('anchor.bound');
    assert.equal(bound.length, 1);
    assert.equal(bound[0]?.data.anchorId, c.anchor.id);
    assert.equal(bound[0]?.data.rootId, c.rootId);
  } finally {
    c.close();
  }
  assert.deepEqual(doctor(sb.root).problems, []);
});

test('M2-0b: an older copy of the whole state root is refused at every point; nothing runs again, no spend is lost, a forensic record keeps it', { skip: copiesRoot }, async () => {
  const sb = sandbox();
  const log = path.join(sb.dir, 'exec.log');
  const script = { execLog: log, default: { behaviour: 'pass' as const, costUsd: 0.5 } };
  let c = Controller.open(sb.root);
  c.importPlan(samplePlan(), sb.repo, 'h');
  c.close();
  // A copy after the import and after each controller step: every one is a consistent state
  // root that M1 accepted as "stopped there".
  const snaps = [snapshot(sb, '0')];
  for (let step = 1; ; step++) {
    c = Controller.open(sb.root);
    const s = await c.run(new FakeRunner(script), { repoPath: sb.repo, maxSteps: 1 });
    c.close();
    if (Object.values(s.states).every((x) => x === 'done')) break;
    snaps.push(snapshot(sb, String(step)));
  }
  const latest = snapshot(sb, 'latest');
  const executions = readExecLog(log).length;
  const spent = BudgetLedger.fromRecords(verifyJournalFile(statePaths(sb.root).journal, readJournalKey(statePaths(sb.root))).records).spent('epic', 'E1');
  assert.ok(spent.usd >= 2.5 && snaps.length >= 3, `${snaps.length} copies, $${spent.usd} spent`);
  for (const [i, snap] of snaps.entries()) {
    restore(sb, snap);
    const journalBefore = fs.readFileSync(statePaths(sb.root).journal);
    const statesBefore = storeStates(sb.root);
    assert.throws(() => Controller.open(sb.root), (err: unknown) => {
      assert.ok(err instanceof RecoveryRefusedError, String(err));
      assert.match(err.message, /behind its anchored head at seq \d+: the state root was rolled back/);
      assert.match(err.message, /Nothing was changed/);
      return true;
    }, `copy ${i}`);
    // The CLI refuses too, and doctor names it.
    const run = runCli(['run', '--state-root', sb.root, '--repo', sb.repo, '--runner', 'fake', '--script', writeJson(path.join(sb.dir, 'script.json'), script)]);
    assert.notEqual(run.status, 0, `copy ${i}: eo run`);
    assert.match(run.stderr, /behind its anchored head/);
    assert.ok(doctor(sb.root).problems.some((p) => /^anchor: the journal ends at seq \d+, behind its anchored head/.test(p)), `copy ${i}: doctor`);
    // The read-only reports do not present the older copy as current.
    const st = runCli(['status', '--state-root', sb.root]);
    assert.equal(st.status, 1, `copy ${i}: eo status`);
    assert.match(st.stdout, /rollback anchor: REFUSED: the journal ends at seq \d+, behind its anchored head/);
    const ev = runCli(['evidence', 'T1', '--state-root', sb.root]);
    assert.notEqual(ev.status, 0, `copy ${i}: eo evidence`);
    assert.match(ev.stderr, /not verified: the rollback anchor refuses this state root/);
    // Nothing changed and nothing ran.
    assert.deepEqual(fs.readFileSync(statePaths(sb.root).journal), journalBefore, `copy ${i}: journal unchanged`);
    assert.deepEqual(storeStates(sb.root), statesBefore, `copy ${i}: store unchanged`);
    assert.equal(readExecLog(log).length, executions, `copy ${i}: nothing ran again`);
    // The forensic record keeps the refused journal as found.
    const files = forensicFiles(sb.root, 'rollback-refused');
    assert.ok(files.length >= 1, `copy ${i}: forensic record`);
    const rec = JSON.parse(fs.readFileSync(path.join(sb.root, 'forensics', files.at(-1) as string), 'utf8')) as { reason: string; journalBase64: string; anchor: { head: { journalSeq: number } } };
    assert.match(rec.reason, /behind its anchored head/);
    assert.deepEqual(Buffer.from(rec.journalBase64, 'base64'), journalBefore);
    assert.ok(rec.anchor.head.journalSeq > journalLength(sb.root));
  }
  // The real state root is untouched by all this and carries on with every dollar spent.
  restore(sb, latest);
  c = Controller.open(sb.root);
  try {
    assert.deepEqual(BudgetLedger.fromRecords(c.journal.records()).spent('epic', 'E1'), spent);
    assert.deepEqual(c.summary().states, { T1: 'done', T2: 'done', T3: 'done', T4: 'done', T5: 'done' });
  } finally {
    c.close();
  }
  assert.deepEqual(doctor(sb.root).problems, []);
});

test('M2-0b: a crash between the journal append and the anchor update is recovered on open', () => {
  const sb = sandbox();
  let c = Controller.open(sb.root);
  c.importPlan(twoIndependent, sb.repo, 'h');
  c.close();
  // The journal record is durable; the process dies before the anchor records it.
  const p = statePaths(sb.root);
  const rec = Journal.open(p.journal, readJournalKey(p)).append('task.transition', { taskId: 'A', from: 'planned', to: 'ready', reason: 'dependencies done' });
  assert.equal(headOf(sb.root)?.journalSeq, rec.seq - 1);
  const d = doctor(sb.root);
  assert.ok(d.warnings.some((w) => /journal is one record ahead of its anchor/.test(w)), JSON.stringify(d));
  assert.ok(!d.problems.some((x) => x.startsWith('anchor:')), JSON.stringify(d));
  c = Controller.open(sb.root);
  try {
    assert.equal(c.anchorRepaired, true);
    // Repaired by the open itself, before any further append.
    assert.equal(headOf(sb.root)?.journalSeq, rec.seq);
    const report = c.resume();
    assert.equal(report.anchorRepaired, true);
    assert.deepEqual(report.transitionsReplayed, ['A:planned->ready']);
  } finally {
    c.close();
  }
  assert.equal(headOf(sb.root)?.journalSeq, journalLength(sb.root));
  assert.deepEqual(doctor(sb.root).problems, []);
});

test('M2-0b: a crash right after journaling the binding, before the first head, is recovered', () => {
  const dir = tmpDir();
  const root = path.join(dir, 'state');
  const p = initStateRoot(root);
  const key = readJournalKey(p);
  const anchor = RollbackAnchor.open(anchorDir(), root);
  Journal.open(p.journal, key).append('anchor.bound', { anchorId: anchor.id, rootId: rootIdOf(root), keyId: keyIdOf(key) });
  assert.equal(anchor.read(rootIdOf(root)), null);
  const c = Controller.open(root);
  try {
    assert.equal(c.anchorRepaired, true);
  } finally {
    c.close();
  }
  assert.equal(headOf(root)?.journalSeq, journalLength(root));
});

test('M2-0b: a journal more than one record ahead of its anchor is refused', () => {
  const sb = sandbox();
  const c = Controller.open(sb.root);
  c.importPlan(twoIndependent, sb.repo, 'h');
  c.close();
  const p = statePaths(sb.root);
  const j = Journal.open(p.journal, readJournalKey(p));
  j.append('task.transition', { taskId: 'A', from: 'planned', to: 'ready', reason: 'x' });
  j.append('task.transition', { taskId: 'B', from: 'planned', to: 'ready', reason: 'x' });
  assert.throws(() => Controller.open(sb.root), /2 records ahead of its anchored head .* a crash leaves at most one/);
  assert.deepEqual(storeStates(sb.root), { A: 'planned', B: 'planned' });
  assert.ok(doctor(sb.root).problems.some((x) => /2 records ahead/.test(x)));
});

test('M2-0b: a different journal history of the same or greater length is refused', { skip: copiesRoot }, async () => {
  // Someone with the state root (and so the journal key) restores an older copy and writes
  // valid records onto it until it is as long as the real journal.
  const sb = sandbox();
  let c = Controller.open(sb.root);
  c.importPlan(twoIndependent, sb.repo, 'h');
  c.close();
  const snap = snapshot(sb, 'old');
  c = Controller.open(sb.root);
  await c.run(new FakeRunner({ default: { behaviour: 'pass' } }), { repoPath: sb.repo });
  c.close();
  const n = journalLength(sb.root);
  for (const extra of [0, 1]) {
    restore(sb, snap);
    const p = statePaths(sb.root);
    const j = Journal.open(p.journal, readJournalKey(p));
    while (j.records().length < n + extra) j.append('note', { forged: true });
    assert.throws(() => Controller.open(sb.root), /journal record \d+ differs from the anchored head: the journal was replaced by a different history/, `length n+${extra}`);
  }
});

test('M2-0b: a removed journal is refused before the store is opened or repaired', () => {
  const sb = sandbox();
  const c = Controller.open(sb.root);
  c.importPlan(twoIndependent, sb.repo, 'h');
  c.close();
  const p = statePaths(sb.root);
  const storeBefore = fs.readdirSync(p.store).sort();
  fs.rmSync(p.journal);
  assert.throws(() => Controller.open(sb.root), /the journal ends at seq 0, behind its anchored head/);
  assert.deepEqual(fs.readdirSync(p.store).sort(), storeBefore);
  assert.equal(fs.existsSync(p.journal), false, 'nothing recreated the journal');
});

test('M2-0b: a tampered anchor head is refused, and the forensic record keeps its bytes and the journal', () => {
  const sb = sandbox();
  const f = headFile(sb.root);
  const h = JSON.parse(fs.readFileSync(f, 'utf8')) as { journalSeq: number };
  fs.writeFileSync(f, JSON.stringify({ ...h, journalSeq: 1 }));
  const tampered = fs.readFileSync(f);
  assert.throws(() => Controller.open(sb.root), (err: unknown) => err instanceof RecoveryRefusedError && /failed verification.*Forensic record: .*rollback-refused/.test(err.message));
  const rec = JSON.parse(fs.readFileSync(path.join(sb.root, 'forensics', forensicFiles(sb.root, 'rollback-refused').at(-1) as string), 'utf8')) as { anchor: { headFileBase64: string }; journalBase64: string };
  assert.deepEqual(Buffer.from(rec.anchor.headFileBase64, 'base64'), tampered);
  assert.deepEqual(Buffer.from(rec.journalBase64, 'base64'), fs.readFileSync(statePaths(sb.root).journal));
  assert.ok(doctor(sb.root).problems.some((x) => /^anchor: anchor head .* failed verification/.test(x)));
});

test('M2-0b: an older copy re-signed with a new journal key is refused, with or without its binding', { skip: copiesRoot }, async () => {
  const sb = sandbox();
  const log = path.join(sb.dir, 'exec.log');
  const script = { execLog: log, default: { behaviour: 'pass' as const, costUsd: 0.5 } };
  let c = Controller.open(sb.root);
  c.importPlan(twoIndependent, sb.repo, 'h');
  c.close();
  const snap = snapshot(sb, 'old');
  c = Controller.open(sb.root);
  await c.run(new FakeRunner(script), { repoPath: sb.repo });
  c.close();
  const executions = readExecLog(log).length;
  assert.equal(executions, 2);
  const strip = (r: { type: string; data: unknown }): void => {
    if (r.type === 'anchor.bound') {
      r.type = 'note';
      r.data = {};
    }
  };
  for (const edit of [undefined, strip]) {
    restore(sb, snap);
    rekey(sb.root, edit);
    assert.throws(() => Controller.open(sb.root), /the journal key differs from the one this state root was anchored under/);
    assert.ok(doctor(sb.root).problems.some((x) => /journal key differs/.test(x)));
    assert.equal(runCli(['status', '--state-root', sb.root]).status, 1);
  }
  assert.equal(readExecLog(log).length, executions, 'nothing ran again');
  // The anchor itself refuses to record a head under another key.
  const a = RollbackAnchor.open(anchorDir(), sb.root);
  const h = a.read(rootIdOf(sb.root));
  assert.throws(() => a.advance(rootIdOf(sb.root), 'f'.repeat(32), 'x', (h?.journalSeq ?? 0) + 1, 'aa'), /recorded under journal key/);
});

test('M2-0b: a copy at another path is not adopted without an operator, and its older copy is refused even then', { skip: copiesRoot }, async () => {
  const sb = sandbox();
  let c = Controller.open(sb.root);
  c.importPlan(twoIndependent, sb.repo, 'h');
  c.close();
  const old = path.join(sb.dir, 'old-copy');
  fs.cpSync(sb.root, old, { recursive: true });
  c = Controller.open(sb.root);
  await c.run(new FakeRunner({ default: { behaviour: 'pass' } }), { repoPath: sb.repo });
  c.close();
  // Moved (or copied) elsewhere: the anchor has never seen that path.
  const moved = path.join(sb.dir, 'moved');
  fs.cpSync(old, moved, { recursive: true });
  assert.throws(() => Controller.open(moved), /bound to the state root at .*, not this one: it was moved or copied here; an operator .* "eo anchor adopt"/);
  assert.ok(doctor(moved).problems.some((x) => /moved or copied here/.test(x)));
  assert.equal(forensicFiles(moved, 'rollback-refused').length, 1);
  // The CLI's adopt needs a person at a terminal.
  const r = runCli(['anchor', 'adopt', '--state-root', moved]);
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /needs a human at an interactive terminal/);
  // An operator adopts it; from then on it is anchored at its new path.
  c = Controller.open(moved, { adopt: { by: 'operator' } });
  try {
    assert.equal(c.anchorBinding, 'adopted');
    const b = c.journal.ofType<{ rootId: string; adoptedBy: string }>('anchor.bound').at(-1);
    assert.equal(b?.data.rootId, rootIdOf(moved));
    assert.equal(b?.data.adoptedBy, 'operator');
  } finally {
    c.close();
  }
  assert.equal(headOf(moved)?.journalSeq, journalLength(moved));
  assert.deepEqual(doctor(moved).problems, []);
  // The original stays anchored and untouched; its older copy put back is refused as before.
  restore(sb, old);
  assert.throws(() => Controller.open(sb.root), /behind its anchored head/);
});

test('M2-0b: an operator can accept a restored backup explicitly; the replaced head is kept, and M1 checks still apply', { skip: copiesRoot }, async () => {
  const sb = sandbox();
  let c = Controller.open(sb.root);
  c.importPlan(twoIndependent, sb.repo, 'h');
  c.close();
  const snap = snapshot(sb, 'backup');
  c = Controller.open(sb.root);
  await c.run(new FakeRunner({ default: { behaviour: 'pass' } }), { repoPath: sb.repo });
  c.close();
  const headBefore = fs.readFileSync(headFile(sb.root));
  restore(sb, snap);
  // Adoption alone does not accept a rollback.
  assert.throws(() => Controller.open(sb.root, { adopt: { by: 'operator' } }), /behind its anchored head/);
  c = Controller.open(sb.root, { adopt: { by: 'operator', acceptRollback: true } });
  try {
    assert.equal(c.anchorBinding, 'rollback-accepted');
    const b = c.journal.ofType<{ acceptedRollback: string }>('anchor.bound').at(-1);
    assert.match(b?.data.acceptedRollback ?? '', /behind its anchored head/);
  } finally {
    c.close();
  }
  const rec = JSON.parse(fs.readFileSync(path.join(sb.root, 'forensics', forensicFiles(sb.root, 'rollback-accepted')[0] as string), 'utf8')) as { by: string; anchor: { headFileBase64: string } };
  assert.equal(rec.by, 'operator');
  assert.deepEqual(Buffer.from(rec.anchor.headFileBase64, 'base64'), headBefore);
  assert.equal(headOf(sb.root)?.journalSeq, journalLength(sb.root));
  assert.deepEqual(doctor(sb.root).problems, []);
  // Accepting a rollback is not a way past the checks inside the state root.
  restore(sb, snap);
  const p = statePaths(sb.root);
  const j = Journal.open(p.journal, readJournalKey(p));
  j.append('task.transition', { taskId: 'A', from: 'planned', to: 'ready', reason: 'x' });
  fs.writeFileSync(p.journal, fs.readFileSync(p.journal, 'utf8').replace('"to":"ready"', '"to":"done"'));
  assert.throws(() => Controller.open(sb.root, { adopt: { by: 'operator', acceptRollback: true } }), /tamper|MAC|verif/i);
});

test('M2-0b: an anchor inside the state root, or a state root inside the anchor, is refused', () => {
  const sb = sandbox();
  assert.throws(() => Controller.open(sb.root, { anchorDir: path.join(sb.root, 'anchor') }), /inside the state root/);
  assert.throws(() => Controller.open(sb.root, { anchorDir: sb.dir }), /the state root .* is inside the rollback anchor/);
  // Through a link, too.
  if (process.platform !== 'win32') {
    const link = path.join(tmpDir(), 'link');
    fs.symlinkSync(path.join(sb.root, 'evidence'), link);
    assert.throws(() => Controller.open(sb.root, { anchorDir: link }), /inside the state root/);
    // A link earlier in a path that does not exist yet: refused before anything is created.
    fs.symlinkSync(sb.root, path.join(sb.dir, 'root-link'));
    assert.throws(() => Controller.open(sb.root, { anchorDir: path.join(sb.dir, 'root-link', 'sub', 'anchor') }), /inside the state root/);
    assert.equal(fs.existsSync(path.join(sb.root, 'sub')), false, 'nothing was written inside the state root');
  }
});

test('M2-0b: a state root whose anchor lost its head, or that is pointed at another anchor, is refused', () => {
  const sb = sandbox();
  const p = statePaths(sb.root);
  const other = tmpDir('eo-anchor-other-');
  // Another anchor: the journal is bound to this one.
  assert.throws(() => Controller.open(sb.root, { anchorDir: other }), /bound to rollback anchor [0-9a-f]+, but the configured anchor is [0-9a-f]+/);
  // The head removed from the right anchor.
  void p;
  fs.rmSync(headFile(sb.root));
  assert.throws(() => Controller.open(sb.root), /which has no head for this state root/);
  assert.ok(doctor(sb.root).problems.some((x) => /no head for this state root/.test(x)));
});

test('M2-0b: a state root made before M2-0b is refused until an operator adopts it; its older copy is refused after that', { skip: copiesRoot }, () => {
  // Build a pre-M2-0b state root: its journal has no anchor binding and no anchor has its head.
  const dir = tmpDir();
  const root = path.join(dir, 'state');
  const p = initStateRoot(root);
  const key = readJournalKey(p);
  const j = Journal.open(p.journal, key);
  j.append('policy.set', { hash: policyHash(loadPolicy(p.policy)), reason: 'initial' });
  j.append('store.bound', { kind: 'fake' });
  const old = path.join(dir, 'old');
  fs.cpSync(root, old, { recursive: true });
  assert.ok(doctor(root).problems.some((w) => /has 2 records but this state root has never been anchored/.test(w)));
  assert.throws(() => Controller.open(root), /never been anchored .* "eo anchor adopt"/);
  const c = Controller.open(root, { adopt: { by: 'operator' } });
  c.close();
  const records = verifyJournalFile(p.journal, key).records;
  assert.equal(records.filter((r) => r.type === 'anchor.bound').length, 1);
  assert.equal(headOf(root)?.journalSeq, records.length);
  fs.rmSync(root, { recursive: true });
  fs.cpSync(old, root, { recursive: true });
  assert.throws(() => Controller.open(root, { adopt: { by: 'operator' } }), /the journal ends at seq 2, behind its anchored head at seq 3/);
});

test('M2-0b: a fresh anchor is created whole: a leftover temporary file is ignored and two opens agree on one key', () => {
  const dir = tmpDir();
  const root = path.join(dir, 'state');
  fs.mkdirSync(root, { mode: 0o700 });
  const ad = path.join(dir, 'anchor');
  fs.mkdirSync(path.join(ad, 'heads'), { recursive: true, mode: 0o700 });
  // What a crash before the link leaves: a temporary file, never an empty anchor.json.
  fs.writeFileSync(path.join(ad, '.anchor.json.1.dead.tmp'), '');
  const a = RollbackAnchor.open(ad, root);
  const b = RollbackAnchor.open(ad, root);
  assert.equal(a.id, b.id);
  assert.match(fs.readFileSync(path.join(ad, 'anchor.json'), 'utf8'), /"key":"[0-9a-f]{64}"/);
  assert.deepEqual(fs.readdirSync(ad).filter((f) => f.startsWith('.anchor.json.') && !f.includes('dead')), [], 'no temporary file of ours is left');
});

test('M2-0b: the anchor never moves backwards, and the journal stops after a failed anchor update', () => {
  const dir = tmpDir();
  const root = path.join(dir, 'state');
  fs.mkdirSync(root, { mode: 0o700 });
  const a = RollbackAnchor.open(path.join(dir, 'anchor'), root);
  const id = 'ab'.repeat(16);
  const k = 'cd'.repeat(16);
  a.advance(id, k, root, 5, 'aa');
  assert.throws(() => a.advance(id, k, root, 4, 'bb'), /refusing to move the anchor .* back from journal seq 5 to 4/);
  assert.throws(() => a.advance(id, k, root, 5, 'cc'), /different MAC/);
  assert.equal(a.read(id)?.journalSeq, 5);
  // An append whose anchor update fails is the last: one more would leave the journal two ahead.
  const file = path.join(dir, 'journal.jsonl');
  let fail = true;
  const j = Journal.open(file, Buffer.alloc(32, 1), {
    onAppend: () => {
      if (fail) throw new Error('disk full');
    },
  });
  assert.throws(() => j.append('x', {}), /disk full/);
  fail = false;
  assert.throws(() => j.append('y', {}), (err: unknown) => err instanceof JournalTamperError && /recording an earlier one failed/.test(err.message));
});

test('M2-0b: doctor reports the last transition unapplied as damage when no controller runs, and as in flight while one does', async () => {
  const sb = sandbox();
  const c = Controller.open(sb.root);
  c.importPlan(twoIndependent, sb.repo, 'h');
  c.journal.append('task.transition', { taskId: 'A', from: 'planned', to: 'ready', reason: 'dependencies done' });
  c.close();
  const unapplied = /A is planned, journal says ready/;
  assert.ok(doctor(sb.root).problems.some((x) => unapplied.test(x)), 'no controller: reported');
  // A live process holds the controller lock.
  const holder = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], { stdio: 'ignore' });
  try {
    fs.writeFileSync(statePaths(sb.root).controllerLock, JSON.stringify({ pid: holder.pid, owner: 'controller:test', acquiredAt: new Date().toISOString(), nonce: 'x' }));
    const d = doctor(sb.root);
    assert.ok(!d.problems.some((x) => unapplied.test(x)), JSON.stringify(d.problems));
    assert.ok(d.warnings.some((x) => unapplied.test(x) && /being applied by the running controller/.test(x)));
    assert.ok(d.warnings.some((x) => /a controller is running \(pid \d+\)/.test(x)));
  } finally {
    holder.kill('SIGKILL');
    await new Promise((resolve) => holder.on('exit', resolve));
  }
  // The holder is gone: its lock is left over from a crash, and the gap is reported again.
  assert.ok(doctor(sb.root).problems.some((x) => unapplied.test(x)), 'dead holder: reported');
});

test('M2-0b: doctor run beside a working controller never reports a transition in flight as damage', { skip: TEST_STORE === 'beads' && 'FakeStore timing' }, async () => {
  const sb = sandbox((pol) => ({ ...pol, budget: { ...pol.budget, epic: { usd: 1000, tokens: 1_000_000_000 }, task: { usd: 100, tokens: 100_000_000 } } }));
  const c = Controller.open(sb.root);
  c.importPlan({ epicId: 'E1', title: 'many', tasks: Array.from({ length: 12 }, (_, i) => ({ id: `T${i}`, title: `t${i}`, deps: [] })) }, sb.repo, 'h');
  c.close();
  const scriptFile = writeJson(path.join(sb.dir, 'script.json'), { default: { behaviour: 'pass', costUsd: 0.01 } });
  const child = spawn(process.execPath, [CLI, 'run', '--state-root', sb.root, '--repo', sb.repo, '--runner', 'fake', '--script', scriptFile], { stdio: 'ignore' });
  const exited = new Promise<number | null>((resolve) => child.on('exit', (code) => resolve(code)));
  let done = false;
  void exited.then(() => {
    done = true;
  });
  let reports = 0;
  let inFlight = 0;
  while (!done) {
    const r = doctor(sb.root);
    reports++;
    if (r.warnings.some((w) => /being applied by the running controller/.test(w))) inFlight++;
    for (const prob of r.problems) {
      // A consistent snapshot is either clean or, if the journal never settled, says so.
      assert.match(prob, /^snapshot: the journal changed during each of \d+ reads, so a controller is running/, `doctor report ${reports}: ${prob}`);
    }
    await new Promise((resolve) => setImmediate(resolve));
  }
  assert.equal(await exited, 0);
  assert.ok(reports >= 5, `only ${reports} doctor runs overlapped the controller`);
  assert.deepEqual(doctor(sb.root).problems, []);
  // Recorded for the evidence report.
  process.stderr.write(`doctor runs during the controller run: ${reports}; with a transition in flight: ${inFlight}\n`);
});
