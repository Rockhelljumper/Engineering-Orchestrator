import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { Controller } from '../../src/controller.ts';
import { CLI, REPO_ROOT, samplePlan, sandbox, TIMEOUT_SCALE, writeJson } from '../support/helpers.ts';

/**
 * M1-6: no outbound network connection from the controller during the M1-4 scenario
 * (crash mid-run, resume, run to completion). Two independent detectors:
 *   1. a preload that records and refuses every Node network API (all platforms);
 *   2. on Linux with strace and unshare: every connect() syscall of the process tree, inside
 *      a fresh network namespace that has no route out.
 * Each detector has a positive control proving it would have caught a connection.
 * The beads store's bd processes are covered by tests/integration/beads.test.ts (M1-6 on beads).
 */
const PRELOAD = pathToFileURL(path.join(REPO_ROOT, 'tests', 'support', 'deny-network.ts')).href;
const EVIDENCE = process.env['EO_EVIDENCE_DIR'];

function has(cmd: string, args: string[]): boolean {
  if (process.platform !== 'linux') return false;
  return spawnSync(cmd, args, { stdio: 'ignore' }).status === 0;
}
const STRACE = has('strace', ['-V']) && has('unshare', ['-n', 'true']);

function scenario(): { root: string; repo: string; script: string } {
  const sb = sandbox();
  const c = Controller.open(sb.root);
  c.importPlan(samplePlan(), sb.repo, 'test-human');
  c.close();
  const script = writeJson(path.join(sb.dir, 'script.json'), {
    default: { behaviour: 'pass' },
    tasks: { T2: [{ behaviour: 'verify-fail', signature: 's' }], T3: [{ behaviour: 'crash' }] },
  });
  return { root: sb.root, repo: sb.repo, script };
}

function eo(args: string[], env: Record<string, string>, wrap: string[] = []): { status: number | null; stderr: string } {
  const cmd = [...wrap, process.execPath, '--import', PRELOAD, CLI, ...args];
  const r = spawnSync(cmd[0] as string, cmd.slice(1), { encoding: 'utf8', env: { ...process.env, ...env }, timeout: 120_000 * TIMEOUT_SCALE });
  return { status: r.status, stderr: r.stderr };
}

function steps(s: ReturnType<typeof scenario>): string[][] {
  const run = ['run', '--state-root', s.root, '--repo', s.repo, '--runner', 'fake', '--script', s.script];
  return [run, ['resume', '--state-root', s.root], run, ['doctor', '--state-root', s.root], ['status', '--state-root', s.root]];
}

test('M1-6: the preload detector catches a connection attempt (positive control)', () => {
  const log = path.join(sandbox().dir, 'net.log');
  const r = spawnSync(process.execPath, ['--import', PRELOAD, '-e', "require('node:net').connect(9, '192.0.2.1')"], {
    encoding: 'utf8',
    env: { ...process.env, EO_NET_LOG: log },
  });
  assert.notEqual(r.status, 0);
  assert.match(fs.readFileSync(log, 'utf8'), /net\.Socket\.connect/);
});

test('M1-6: no network API is used during crash, resume and run', () => {
  const s = scenario();
  const log = path.join(path.dirname(s.root), 'net.log');
  const all = steps(s);
  const crashed = eo(all[0] as string[], { EO_NET_LOG: log, EO_CRASH_AT: '9' });
  assert.equal(crashed.status, 137, crashed.stderr);
  for (const a of all.slice(1)) {
    const r = eo(a, { EO_NET_LOG: log });
    assert.equal(r.status, 0, `${a[0]}: ${r.stderr}`);
  }
  assert.equal(fs.existsSync(log) ? fs.readFileSync(log, 'utf8') : '', '', 'network attempts were recorded');
});

test('M1-6: strace detector sees a connect() inside the namespace (positive control)', { skip: !STRACE && 'needs Linux with strace and unshare -n' }, () => {
  const out = path.join(sandbox().dir, 'strace.log');
  spawnSync('unshare', ['-n', 'strace', '-f', '-qq', '-e', 'trace=connect', '-o', out, process.execPath, '-e', "require('node:net').connect(9, '192.0.2.1').on('error', () => {})"], { encoding: 'utf8' });
  assert.match(fs.readFileSync(out, 'utf8'), /connect\(\d+, \{sa_family=AF_INET/);
});

test('M1-6: no connect() syscall to an IP address during crash, resume and run, in an isolated network namespace', { skip: !STRACE && 'needs Linux with strace and unshare -n' }, () => {
  const s = scenario();
  const dir = path.dirname(s.root);
  const logs: string[] = [];
  steps(s).forEach((a, i) => {
    const out = path.join(dir, `strace-${i}.log`);
    logs.push(out);
    const r = eo(a, i === 0 ? { EO_CRASH_AT: '9' } : {}, ['unshare', '-n', 'strace', '-f', '-qq', '-e', 'trace=connect,sendto,sendmsg', '-o', out]);
    assert.equal(r.status, i === 0 ? 137 : 0, `${a[0]}: ${r.stderr}`);
  });
  const text = logs.map((l) => fs.readFileSync(l, 'utf8')).join('');
  const inet = text.split('\n').filter((l) => /sa_family=AF_INET6?\b/.test(l));
  if (EVIDENCE) {
    fs.mkdirSync(EVIDENCE, { recursive: true });
    fs.writeFileSync(path.join(EVIDENCE, 'm1-6-strace.log'), text || '(no traced network syscalls)\n');
  }
  assert.deepEqual(inet, [], 'IPv4/IPv6 network syscalls were made');
});
