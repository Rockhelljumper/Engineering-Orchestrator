import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { Controller } from '../../src/controller.ts';
import { FakeRunner } from '../../src/runner/fake.ts';
import { BeadsStore, bdEnv, pinnedBdSha256 } from '../../src/store/beads.ts';
import { initStateRoot, statePaths } from '../../src/stateRoot.ts';
import { doctor } from '../../src/doctor.ts';
import { BD_BIN, CLI, readExecLog, samplePlan, tmpDir, writeJson } from '../support/helpers.ts';

/**
 * BeadsStore against the real, pinned `bd` binary (M1-2, M1-6, M1-7). Skipped without
 * EO_BD_BIN; the M1 evidence run sets EO_REQUIRE_BD=1 so a missing binary fails instead.
 */
const skip = !BD_BIN && 'needs the pinned bd build (EO_BD_BIN)';
const bin = BD_BIN as string;
const LINUX_TRACE =
  process.platform === 'linux' && spawnSync('strace', ['-V'], { stdio: 'ignore' }).status === 0 && spawnSync('unshare', ['-n', 'true'], { stdio: 'ignore' }).status === 0;
const EVIDENCE = process.env['EO_EVIDENCE_DIR'];

/** A beads-backed state root with one approved repository. */
function beadsSandbox(onSpawn?: (args: readonly string[], env: Readonly<Record<string, string>>) => void): { dir: string; root: string; repo: string; store: BeadsStore } {
  const dir = tmpDir();
  const root = path.join(dir, 'state');
  const repo = path.join(dir, 'repo');
  fs.mkdirSync(repo);
  initStateRoot(root, { kind: 'beads', bin });
  const store = BeadsStore.atDir(statePaths(root).store, { bin, create: true, ...(onSpawn ? { onSpawn } : {}) });
  const c = Controller.open(root, { store });
  c.approveRepository(repo, 'test-human');
  c.close();
  return { dir, root, repo, store };
}

/** Run bd by hand in a store, the way someone bypassing the controller would. */
function bdRaw(storeDir: string, args: string[]): string {
  const r = spawnSync(path.join(storeDir, 'bin', 'bd'), args, { cwd: storeDir, env: bdEnv(path.join(storeDir, 'bd-home'), storeDir), encoding: 'utf8' });
  assert.equal(r.status, 0, `bd ${args.join(' ')}: ${r.stderr}`);
  return r.stdout;
}

test('M1-7: the bd binary is the pinned build, and any other binary is refused', { skip }, () => {
  const want = pinnedBdSha256();
  assert.match(want ?? '', /^[0-9a-f]{64}$/, 'deps.lock.json records a SHA-256 for this platform');
  assert.equal(createHash('sha256').update(fs.readFileSync(bin)).digest('hex'), want);
  const v = spawnSync(bin, ['--version'], { env: bdEnv(tmpDir()), encoding: 'utf8' });
  assert.match(v.stdout, /bd version 1\.3\.0 \(9c6f6e1\)/);

  const tampered = path.join(tmpDir(), 'bd');
  fs.copyFileSync(bin, tampered);
  fs.appendFileSync(tampered, Buffer.from([0]));
  fs.chmodSync(tampered, 0o755);
  assert.throws(() => BeadsStore.atDir(path.join(tmpDir(), 'store'), { bin: tampered, create: true }), /has SHA-256 [0-9a-f]{64}, expected the pinned/);
  assert.throws(() => BeadsStore.atDir(path.join(tmpDir(), 'store'), { bin: path.join(tmpDir(), 'missing'), create: true }), /not found/);
});

test('M1-7: every bd spawn of a full controller run gets the metrics opt-out and a scrubbed environment', { skip, timeout: 900_000 }, async () => {
  const spawns: Array<{ args: readonly string[]; env: Readonly<Record<string, string>> }> = [];
  process.env['ANTHROPIC_API_KEY'] = 'sk-test-must-not-reach-bd';
  try {
    const sb = beadsSandbox((args, env) => spawns.push({ args, env }));
    const c = Controller.open(sb.root, { store: sb.store });
    try {
      c.importPlan(samplePlan(), sb.repo, 'h');
      const script = { default: { behaviour: 'pass' as const }, tasks: { T2: [{ behaviour: 'verify-fail' as const, signature: 's' }], T3: [{ behaviour: 'crash' as const }] } };
      const s = await c.run(new FakeRunner(script), { repoPath: sb.repo });
      assert.deepEqual(Object.values(s.states), ['done', 'done', 'done', 'done', 'done']);
    } finally {
      c.close();
    }
    const kinds = new Set(spawns.map((x) => x.args[0]));
    for (const k of ['init', 'create', 'show', 'list', 'update']) assert.ok(kinds.has(k), `bd ${k} was exercised`);
    assert.ok(spawns.length > 100, `${spawns.length} spawns`);
    for (const { args, env } of spawns) {
      assert.equal(env['BD_DISABLE_METRICS'], '1', `bd ${args[0]}`);
      assert.equal(env['DO_NOT_TRACK'], '1', `bd ${args[0]}`);
      assert.equal(env['ANTHROPIC_API_KEY'], undefined, `bd ${args[0]} must not see API keys`);
      assert.deepEqual(Object.keys(env).filter((k) => /KEY|TOKEN|SECRET|PASSWORD/i.test(k)), [], `bd ${args[0]}`);
    }
    // Metrics off means bd's event queue is never created.
    assert.equal(fs.existsSync(path.join(statePaths(sb.root).store, 'bd-home', '.beads', 'eventsData')), false);
  } finally {
    delete process.env['ANTHROPIC_API_KEY'];
  }
});

test('M1-7: the environment the bd process actually receives (wrapper records it, then runs the pinned bd)', { skip: skip || (process.platform === 'win32' && 'POSIX wrapper') }, () => {
  const dir = tmpDir();
  const log = path.join(dir, 'env.log');
  const wrapper = path.join(dir, 'bd-wrapper');
  fs.writeFileSync(wrapper, `#!/bin/sh\n{ echo "ARGS $1"; env; echo END; } >> '${log}'\nexec '${bin}' "$@"\n`, { mode: 0o755 });
  const sha = createHash('sha256').update(fs.readFileSync(wrapper)).digest('hex');
  process.env['GITHUB_TOKEN'] = 'ghp_test_must_not_reach_bd';
  try {
    const s = BeadsStore.atDir(path.join(dir, 'store'), { bin: wrapper, sha256: sha, create: true });
    s.createTask({ id: 'A', epicId: 'E', title: 'a', deps: [] });
    s.compareAndSetState('A', 'planned', 'ready');
    s.claimReady('w1', 60_000, Date.now());
    s.addNote('A', 'n');
  } finally {
    delete process.env['GITHUB_TOKEN'];
  }
  const blocks = fs.readFileSync(log, 'utf8').split('END\n').filter((b) => b.trim());
  assert.ok(blocks.length >= 8, `${blocks.length} spawns recorded`);
  for (const b of blocks) {
    assert.match(b, /^BD_DISABLE_METRICS=1$/m, b.split('\n')[0] ?? '');
    assert.match(b, /^DO_NOT_TRACK=1$/m, b.split('\n')[0] ?? '');
    assert.doesNotMatch(b, /GITHUB_TOKEN|ghp_test/, b.split('\n')[0] ?? '');
  }
});

test('M1-6: bd with metrics left on tries to reach the network (positive control for the detector)', { skip: skip || (!LINUX_TRACE && 'needs Linux with strace and unshare -n') }, () => {
  const dir = tmpDir();
  const out = path.join(dir, 'strace.log');
  const env = { PATH: process.env['PATH'] ?? '', HOME: dir, BD_NON_INTERACTIVE: '1', GIT_CEILING_DIRECTORIES: path.dirname(dir) }; // no opt-out
  spawnSync('unshare', ['-n', 'strace', '-f', '-qq', '-e', 'trace=connect,sendto,sendmsg', '-o', out, bin, 'init', '--prefix', 'eo', '--skip-agents', '--skip-hooks', '--non-interactive', '--quiet'], { cwd: dir, env, encoding: 'utf8', timeout: 60_000 });
  // The metrics flusher is a detached child that strace -f still follows; wait for its attempt.
  const inet = (): string[] => fs.readFileSync(out, 'utf8').split('\n').filter((l) => /sa_family=AF_INET6?\b/.test(l));
  const deadline = Date.now() + 20_000;
  while (inet().length === 0 && Date.now() < deadline) spawnSync('sleep', ['0.5']);
  assert.ok(inet().length > 0, 'with metrics on, the traced bd process tree attempts an IPv4/IPv6 connection');
});

test('M1-6: no outbound connection from bd or the controller during crash, resume and run on beads', { skip: skip || (!LINUX_TRACE && 'needs Linux with strace and unshare -n'), timeout: 1_800_000 }, () => {
  const sb = beadsSandbox();
  const c = Controller.open(sb.root, { store: sb.store });
  c.importPlan(samplePlan(), sb.repo, 'h');
  c.close();
  const script = writeJson(path.join(sb.dir, 'script.json'), { default: { behaviour: 'pass' }, tasks: { T2: [{ behaviour: 'verify-fail', signature: 's' }], T3: [{ behaviour: 'crash' }] } });
  const run = ['run', '--state-root', sb.root, '--repo', sb.repo, '--runner', 'fake', '--script', script];
  const steps = [run, ['resume', '--state-root', sb.root], run, ['doctor', '--state-root', sb.root], ['status', '--state-root', sb.root]];
  let text = '';
  let bdSpawns = 0;
  steps.forEach((a, i) => {
    const out = path.join(sb.dir, `strace-${i}.log`);
    const env = { ...process.env, ...(i === 0 ? { EO_CRASH_AT: '9' } : {}) };
    const r = spawnSync('unshare', ['-n', 'strace', '-f', '-qq', '-e', 'trace=connect,sendto,sendmsg,execve', '-o', out, process.execPath, CLI, ...a], { encoding: 'utf8', env, timeout: 900_000 });
    assert.equal(r.status, i === 0 ? 137 : 0, `${a[0]}: ${r.stderr}`);
    const t = fs.readFileSync(out, 'utf8');
    bdSpawns += t.split('\n').filter((l) => l.includes(`execve("${path.join(statePaths(sb.root).store, 'bin', 'bd')}"`)).length;
    text += t
      .split('\n')
      .filter((l) => !l.includes('execve('))
      .join('\n');
  });
  assert.ok(bdSpawns > 50, `bd ran inside the traced tree (${bdSpawns} times)`);
  const inet = text.split('\n').filter((l) => /sa_family=AF_INET6?\b/.test(l));
  if (EVIDENCE) {
    fs.mkdirSync(EVIDENCE, { recursive: true });
    fs.writeFileSync(path.join(EVIDENCE, 'm1-6-strace-beads.log'), `bd processes traced: ${bdSpawns}\n${text.trim() || '(no traced network syscalls)'}\n`);
  }
  assert.deepEqual(inet, [], 'IPv4/IPv6 network syscalls were made');
  assert.equal(fs.existsSync(path.join(statePaths(sb.root).store, 'bd-home', '.beads', 'eventsData')), false, 'no metrics queue');
});

test('changes made with bd directly, behind the controller, are refused', { skip, timeout: 900_000 }, async () => {
  const cases: Array<[string, (storeDir: string) => void, RegExp, RegExp]> = [
    [
      'injected task',
      (d) => {
        const meta = { eo: { v: 1, epicId: 'EVIL', state: 'ready', claim: null, attempt: 0, correctionFailures: 0, infraFailures: 0, lastFailureSignature: null, repeatCount: 0 } };
        bdRaw(d, ['create', '--id', 'eo-X', '--title', 'x', '--metadata', JSON.stringify(meta), '--json']);
      },
      /X is not in any journaled plan/,
      /X is not in any journaled plan/,
    ],
    ['bead without eo metadata', (d) => bdRaw(d, ['create', '--id', 'eo-Y', '--title', 'y', '--json']), /eo-Y ha(s|ve) no eo metadata/, /eo-Y ha(s|ve) no eo metadata/],
    ['dependency removed', (d) => bdRaw(d, ['dep', 'remove', 'eo-T5', 'eo-T4']), /does not match the journaled plans/, /T5 dependencies differ from the plan/],
    [
      'epic changed',
      (d) => {
        const cur = (JSON.parse(bdRaw(d, ['show', '--id=eo-T1', '--json'])) as Array<{ metadata: { eo: Record<string, unknown> } }>)[0];
        bdRaw(d, ['update', 'eo-T1', '--metadata', JSON.stringify({ eo: { ...cur?.metadata.eo, epicId: 'OTHER' } })]);
      },
      /does not match the journaled plans/,
      /T1 epic is OTHER, plan says E1/,
    ],
  ];
  for (const [name, tamper, re, doctorRe] of cases) {
    const sb = beadsSandbox();
    const c0 = Controller.open(sb.root, { store: sb.store });
    c0.importPlan(samplePlan(), sb.repo, 'h');
    c0.close();
    tamper(statePaths(sb.root).store);
    const log = path.join(sb.dir, 'exec.log');
    const c = Controller.open(sb.root, { store: sb.store });
    try {
      await assert.rejects(c.run(new FakeRunner({ default: { behaviour: 'pass' }, execLog: log }), { repoPath: sb.repo }), re, name);
    } finally {
      c.close();
    }
    assert.deepEqual(readExecLog(log), [], `${name}: nothing ran`);
    assert.match(doctor(sb.root).problems.join(';'), doctorRe, `${name}: doctor reports it`);
  }
});

test('a state root cannot be switched to a different store kind, and read-only commands notice too', { skip }, () => {
  const sb = beadsSandbox();
  const cfg = statePaths(sb.root).storeConfig;
  fs.writeFileSync(cfg, JSON.stringify({ kind: 'fake' }));
  // The binding is checked when the store is opened, before anything is created in it.
  assert.throws(() => Controller.open(sb.root), /store\.json says fake, but this state root is bound to the beads store/);
  assert.match(doctor(sb.root).problems.join(';'), /bound to the beads store/);
  const st = spawnSync(process.execPath, [CLI, 'status', '--state-root', sb.root], { encoding: 'utf8' });
  assert.equal(st.status, 1);
  assert.match(st.stderr, /bound to the beads store/);
  fs.rmSync(cfg);
  assert.match(doctor(sb.root).problems.join(';'), /store\.json says fake, but this state root is bound to the beads store/);
});

test('bd never touches a git repository that encloses the state root', { skip, timeout: 300_000 }, () => {
  const outer = tmpDir();
  const git = (...a: string[]): string => spawnSync('git', ['-C', outer, ...a], { encoding: 'utf8' }).stdout;
  spawnSync('git', ['init', '-q', outer]);
  git('config', 'user.name', 'outer');
  git('config', 'user.email', 'outer@example.invalid');
  fs.writeFileSync(path.join(outer, 'README'), 'x');
  git('add', 'README');
  git('commit', '-q', '-m', 'outer');
  const before = { log: git('log', '--format=%H %s'), config: fs.readFileSync(path.join(outer, '.git', 'config'), 'utf8'), status: git('status', '--porcelain', '--ignored') };
  const store = BeadsStore.atDir(path.join(outer, 'state', 'store'), { bin, create: true });
  store.createTask({ id: 'A', epicId: 'E', title: 'a', deps: [] });
  assert.equal(git('log', '--format=%H %s'), before.log, 'no commit in the enclosing repository');
  assert.equal(fs.readFileSync(path.join(outer, '.git', 'config'), 'utf8'), before.config, 'its config is unchanged');
  assert.equal(git('diff', '--cached', '--name-only'), '', 'nothing staged in it');
});

test('a bd init killed part-way is redone on the next open, and read-only opens refuse it', { skip: skip || (process.platform === 'win32' && 'POSIX signals'), timeout: 300_000 }, async () => {
  const sb = beadsSandbox();
  const dir = path.join(sb.dir, 'store2');
  fs.mkdirSync(dir);
  fs.mkdirSync(path.join(dir, 'bin'));
  fs.copyFileSync(bin, path.join(dir, 'bin', 'bd'));
  fs.chmodSync(path.join(dir, 'bin', 'bd'), 0o500);
  const { spawn } = await import('node:child_process');
  const child = spawn(path.join(dir, 'bin', 'bd'), ['init', '--prefix', 'eo', '--skip-agents', '--skip-hooks', '--non-interactive', '--quiet'], { cwd: dir, env: bdEnv(path.join(dir, 'bd-home'), dir) });
  // Kill once init has started writing its database.
  const deadline = Date.now() + 30_000;
  while (!fs.existsSync(path.join(dir, '.beads')) && Date.now() < deadline) await new Promise((r) => setTimeout(r, 20));
  child.kill('SIGKILL');
  await new Promise((r) => child.on('exit', r));
  assert.ok(fs.existsSync(path.join(dir, '.beads')), 'init was interrupted after it began writing');
  assert.throws(() => BeadsStore.atDir(dir, { bin, create: false }), /not initialised/);
  const s = BeadsStore.atDir(dir, { bin, create: true });
  s.createTask({ id: 'A', epicId: 'E', title: 'a', deps: [] });
  assert.equal(BeadsStore.atDir(dir, { bin, create: false }).get('A')?.state, 'planned');
});

test('the executed bd is a verified private entry: swapping the source path or modifying the binary cannot run other code', { skip: skip || (process.platform === 'win32' && 'POSIX permissions') }, () => {
  const dir = tmpDir();
  const src = path.join(dir, 'bd-src');
  fs.copyFileSync(bin, src);
  fs.chmodSync(src, 0o755);
  const s = BeadsStore.atDir(path.join(dir, 'store'), { bin: src, create: true });
  s.createTask({ id: 'A', epicId: 'E', title: 'a', deps: [] });
  const evil = `#!/bin/sh\necho pwned > ${path.join(dir, 'pwned')}\n`;
  // Renaming another file onto the source path after open has no effect: the store's entry still runs the verified binary.
  fs.writeFileSync(path.join(dir, 'evil'), evil, { mode: 0o755 });
  fs.renameSync(path.join(dir, 'evil'), src);
  assert.equal(s.get('A')?.state, 'planned');
  // Writing into the store's entry in place (it may be a hard link) is detected before the next spawn.
  const entry = path.join(dir, 'store', 'bin', 'bd');
  fs.chmodSync(entry, 0o700);
  fs.appendFileSync(entry, Buffer.from([0]));
  assert.throws(() => s.get('A'), /was replaced; refusing to run it/);
  assert.equal(fs.existsSync(path.join(dir, 'pwned')), false, 'no other code ran');
  // A new open refuses the modified entry and the swapped source alike.
  assert.throws(() => BeadsStore.atDir(path.join(dir, 'store'), { bin: src, create: true }), /expected the pinned/);
});

test('a store entry that is stale or tampered with is replaced on the next open, even when read-only', { skip }, () => {
  const dir = path.join(tmpDir(), 'store');
  BeadsStore.atDir(dir, { bin, create: true }).createTask({ id: 'A', epicId: 'E', title: 'a', deps: [] });
  const binDir = path.join(dir, 'bin');
  const entry = path.join(binDir, process.platform === 'win32' ? 'bd.exe' : 'bd');
  // Replace the entry (never write through it: it may be a hard link to the pinned binary).
  fs.chmodSync(entry, 0o700);
  fs.rmSync(entry);
  fs.writeFileSync(entry, 'not bd');
  fs.chmodSync(entry, 0o400); // read-only, as the Windows copy fallback leaves it
  const s = BeadsStore.atDir(dir, { bin, create: false });
  assert.equal(s.get('A')?.state, 'planned');
  assert.equal(createHash('sha256').update(fs.readFileSync(entry)).digest('hex'), pinnedBdSha256());
  assert.deepEqual(fs.readdirSync(binDir).filter((f) => f.endsWith('.tmp')), [], 'no temporary copy left behind');
});

test('a state root bound to the fake store is refused before any beads files are written', { skip }, () => {
  const root = path.join(tmpDir(), 'state');
  initStateRoot(root, { kind: 'fake' });
  Controller.open(root).close();
  const p = statePaths(root);
  fs.writeFileSync(p.storeConfig, JSON.stringify({ kind: 'beads', bin }));
  const before = fs.readdirSync(p.store).sort();
  assert.throws(() => Controller.open(root), /bound to the fake store/);
  assert.deepEqual(fs.readdirSync(p.store).sort(), before, 'nothing created or repaired in the store directory');
});

test('eo init --store beads refuses an unpinned binary before writing anything', { skip }, () => {
  const root = path.join(tmpDir(), 'state');
  const fake = path.join(tmpDir(), 'bd');
  fs.writeFileSync(fake, '#!/bin/sh\n', { mode: 0o755 });
  const r = spawnSync(process.execPath, [CLI, 'init', '--store', 'beads', '--bd-bin', fake, '--state-root', root], { encoding: 'utf8' });
  assert.equal(r.status, 1, r.stderr);
  assert.match(r.stderr, /expected the pinned/);
  assert.equal(fs.existsSync(root), false, 'no state root was created');
});
