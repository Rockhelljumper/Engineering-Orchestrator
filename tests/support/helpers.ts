import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { spawnSync, type SpawnSyncReturns } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { initStateRoot } from '../../src/stateRoot.ts';
import { Controller } from '../../src/controller.ts';
import { loadPolicy, savePolicy, policyHash, type Policy } from '../../src/policy.ts';
import type { Plan } from '../../src/plan.ts';

export const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
export const CLI = path.join(REPO_ROOT, 'src', 'cli.ts');

export function tmpDir(prefix = 'eo-test-'): string {
  return fs.mkdtempSync(path.join(os.tmpdir(), prefix));
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
  initStateRoot(root);
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
  return spawnSync(process.execPath, [CLI, ...args], { encoding: 'utf8', env: childEnv, ...(input !== undefined ? { input } : {}), timeout: 60_000 });
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
