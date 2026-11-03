import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { spawn, spawnSync, type SpawnSyncReturns } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { initStateRoot, readJournalKey, statePaths, type StoreConfig } from '../../src/stateRoot.ts';
import { canonicalRoot, keyIdOf, rootIdOf } from '../../src/anchor.ts';
import { verifyJournalFile } from '../../src/journal.ts';
import { canonicalJson, hmacHex } from '../../src/util/canonical.ts';
import { Controller } from '../../src/controller.ts';
import { loadPolicy, savePolicy, policyHash, type Policy } from '../../src/policy.ts';
import type { Plan } from '../../src/plan.ts';

export const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
export const CLI = path.join(REPO_ROOT, 'src', 'cli.ts');

/**
 * The pinned `bd` binary for BeadsStore tests. Without EO_BD_BIN those tests are skipped
 * (CI has no bd build); with EO_REQUIRE_BD=1 a missing binary fails the run instead, which
 * is how the M1 evidence is produced.
 */
export const BD_BIN: string | undefined = process.env['EO_BD_BIN'] || undefined;
if (!BD_BIN && process.env['EO_REQUIRE_BD'] === '1') throw new Error('EO_REQUIRE_BD=1 but EO_BD_BIN is not set');

/**
 * The strace-based network checks (M1-6) fail instead of skipping when strace or `unshare -n`
 * is unavailable if EO_REQUIRE_TRACE=1, or on Linux if EO_REQUIRE_BD=1, so a Linux evidence
 * run cannot pass without them.
 */
export function requireTrace(available: boolean): void {
  if (available) return;
  if (process.env['EO_REQUIRE_TRACE'] === '1') throw new Error('EO_REQUIRE_TRACE=1 but strace or unshare -n is not available');
  if (process.platform === 'linux' && process.env['EO_REQUIRE_BD'] === '1') throw new Error('EO_REQUIRE_BD=1 on Linux needs strace and unshare -n for the M1-6 checks');
}

const made: string[] = [];
// Beads stores are large; remove this process's temporary directories when it exits
// (EO_KEEP_TMP=1 keeps them for debugging).
process.on('exit', () => {
  if (process.env['EO_KEEP_TMP'] === '1') return;
  for (const d of made) fs.rmSync(d, { recursive: true, force: true });
});

export function tmpDir(prefix = 'eo-test-'): string {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  made.push(d);
  return d;
}

// M2-0b: each test process anchors its state roots in its own directory, outside all of them,
// unless the run sets EO_ANCHOR_DIR. Child processes (the CLI) inherit it.
if (!process.env['EO_ANCHOR_DIR']) process.env['EO_ANCHOR_DIR'] = tmpDir('eo-anchor-');

/**
 * M2 Phase B: EO_TEST_ANCHOR=service runs the suites against the eo-anchor service instead of
 * the anchor directory. Each test process starts its own service (as the test user, on
 * temporary sockets) unless EO_ANCHOR_SOCKET is already set; child processes inherit the socket.
 * Tests that edit the anchor directory directly skip themselves in this mode (ANCHOR_IS_SERVICE).
 */
export const ANCHOR_IS_SERVICE = process.env['EO_TEST_ANCHOR'] === 'service' || Boolean(process.env['EO_ANCHOR_SOCKET']);
export let anchorAdminSocket: string | undefined = process.env['EO_ANCHOR_ADMIN_SOCKET'] || undefined;
if (process.env['EO_TEST_ANCHOR'] === 'service' && !process.env['EO_ANCHOR_SOCKET']) {
  const d = tmpDir('eo-anchor-svc-');
  const state = path.join(d, 'state');
  fs.mkdirSync(state, { mode: 0o700 });
  const data = path.join(d, 'anchor.sock');
  const admin = path.join(d, 'admin.sock');
  const uid = String(process.getuid?.() ?? 0);
  const svc = spawn('python3', ['-I', path.join(REPO_ROOT, 'services', 'anchor', 'eo_anchor.py'), '--state-dir', state, '--controller-user', uid, '--admin-uid', uid, '--data-socket', data, '--admin-socket', admin], { stdio: 'ignore', detached: false });
  svc.unref();
  process.on('exit', () => svc.kill('SIGKILL'));
  const deadline = Date.now() + 15_000;
  while (!(fs.existsSync(data) && fs.existsSync(admin))) {
    if (Date.now() > deadline) throw new Error('the test anchor service did not start');
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 20);
  }
  process.env['EO_ANCHOR_SOCKET'] = data;
  process.env['EO_ANCHOR_ADMIN_SOCKET'] = admin;
  process.env['EO_ANCHOR_SERVER_USER'] = uid;
  anchorAdminSocket = admin;
}

/** Test-only: an operator command on the anchor service's admin socket (eo-anchorctl). */
export function anchorAdmin(args: string[]): Record<string, unknown> {
  if (!anchorAdminSocket) throw new Error('no anchor service admin socket');
  const r = spawnSync('python3', ['-I', path.join(REPO_ROOT, 'services', 'anchor', 'eo_anchorctl.py'), '--socket', anchorAdminSocket, ...args], { encoding: 'utf8' });
  return JSON.parse(r.stdout) as Record<string, unknown>;
}

/** Remove a sandbox now (long sweeps create many). */
export function disposeSandbox(sb: { dir: string }): void {
  if (process.env['EO_KEEP_TMP'] !== '1') fs.rmSync(sb.dir, { recursive: true, force: true });
}

/** EO_TEST_STORE=beads runs the controller-level suites on BeadsStore instead of FakeStore. */
export const TEST_STORE = process.env['EO_TEST_STORE'] === 'beads' ? 'beads' : 'fake';
if (TEST_STORE === 'beads' && !BD_BIN) throw new Error('EO_TEST_STORE=beads needs EO_BD_BIN');

/** Each bd invocation costs ~0.3 s (it opens the embedded Dolt database), so beads runs get longer timeouts. */
export const TIMEOUT_SCALE = TEST_STORE === 'beads' ? 15 : 1;

export function testStore(): StoreConfig {
  return TEST_STORE === 'beads' ? { kind: 'beads', bin: BD_BIN as string } : { kind: 'fake' };
}

export interface Sandbox {
  dir: string;
  root: string;
  repo: string;
}

/**
 * A fresh state root with one approved repository. Approval goes through the controller API
 * (the CLI path needs a TTY by design), mirroring what a human does with "eo policy approve-repo".
 */
export function sandbox(policyPatch?: (p: Policy) => Policy): Sandbox {
  const dir = tmpDir();
  const root = path.join(dir, 'state');
  const repo = path.join(dir, 'repo');
  fs.mkdirSync(repo);
  initStateRoot(root, testStore());
  if (policyPatch) {
    const file = path.join(root, 'policy.json');
    savePolicy(file, policyPatch(loadPolicy(file)));
  }
  const c = Controller.open(root);
  c.approveRepository(repo, 'test-human');
  c.close();
  return { dir, root, repo };
}

export function samplePlan(epicId = 'E1'): Plan {
  // A diamond plus a tail: T1 -> (T2, T3) -> T4 -> T5
  return {
    epicId,
    title: 'Sample epic',
    tasks: [
      { id: 'T1', title: 'base', deps: [] },
      { id: 'T2', title: 'left', deps: ['T1'] },
      { id: 'T3', title: 'right', deps: ['T1'] },
      { id: 'T4', title: 'join', deps: ['T2', 'T3'] },
      { id: 'T5', title: 'tail', deps: ['T4'] },
    ],
  };
}

export function withController<T>(root: string, fn: (c: Controller) => T): T {
  const c = Controller.open(root);
  try {
    return fn(c);
  } finally {
    c.close();
  }
}

export function runCli(args: string[], env: Record<string, string | undefined> = {}, input?: string): SpawnSyncReturns<string> {
  const childEnv: Record<string, string> = {};
  for (const [k, v] of Object.entries({ ...process.env, ...env })) if (v !== undefined) childEnv[k] = v;
  return spawnSync(process.execPath, [CLI, ...args], { encoding: 'utf8', env: childEnv, ...(input !== undefined ? { input } : {}), timeout: 60_000 * TIMEOUT_SCALE });
}

export function writeJson(file: string, value: unknown): string {
  fs.writeFileSync(file, JSON.stringify(value, null, 2));
  return file;
}

export function readExecLog(file: string): Array<{ taskId: string; attempt: number }> {
  if (!fs.existsSync(file)) return [];
  return fs
    .readFileSync(file, 'utf8')
    .split('\n')
    .filter(Boolean)
    .map((l) => JSON.parse(l) as { taskId: string; attempt: number });
}

/**
 * Test-only: move a state root's anchored head to record `seq` of its journal as it is now,
 * as someone who controls the anchor as well as the state root could. The M1 checks inside
 * the state root must still hold when the anchor is rolled back with it.
 */
export function setAnchorHead(root: string, seq: number): void {
  const dir = process.env['EO_ANCHOR_DIR'] as string;
  const meta = JSON.parse(fs.readFileSync(path.join(dir, 'anchor.json'), 'utf8')) as { id: string; key: string };
  const p = statePaths(root);
  const jkey = readJournalKey(p);
  const rec = verifyJournalFile(p.journal, jkey).records[seq - 1];
  if (!rec) throw new Error(`no journal record ${seq}`);
  const rootId = rootIdOf(root);
  const base = { rootId, anchorId: meta.id, keyId: keyIdOf(jkey), root: canonicalRoot(root), journalSeq: rec.seq, journalMac: rec.mac, ts: new Date().toISOString() };
  const head = { ...base, mac: hmacHex(Buffer.from(meta.key, 'hex'), canonicalJson(base)) };
  fs.writeFileSync(path.join(dir, 'heads', `${rootId}.json`), JSON.stringify(head) + '\n');
}

export { policyHash };
