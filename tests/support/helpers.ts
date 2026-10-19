import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { spawnSync, type SpawnSyncReturns } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { initStateRoot, type StoreConfig } from '../../src/stateRoot.ts';
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

export { policyHash };
