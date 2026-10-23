import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { spawn } from 'node:child_process';
import { Controller } from '../../src/controller.ts';
import { verifyJournalFile } from '../../src/journal.ts';
import { readJournalKey, statePaths } from '../../src/stateRoot.ts';
import { CLI, disposeSandbox, readExecLog, runCli, samplePlan, sandbox, writeJson, type Sandbox } from './helpers.ts';
import type { Progress } from './progress.ts';
import type { Policy } from '../../src/policy.ts';
import type { Plan } from '../../src/plan.ts';

// Crash-recovery scenarios (M1-4), shared by tests/behavioral/crash-recovery.test.ts and the
// durable runner's suites (M2-0), which run each boundary or seed as its own checkpointed
// scenario.

/**
 * M1-4. A scripted 5-task run with one verification failure and one worker crash. The
 * controller process is killed right after each of its N journal appends in turn; after
 * `eo resume` and `eo run` every run must end in the uninterrupted run's final states, with
 * no (task, attempt) executed twice and every execution preceded by its journaled intent.
 *
 * Interruptions consume infra retries and charge full reservations, so this policy gives
 * room for them; the scripted failures still exercise both retry paths.
 */
export const roomy = (p: Policy): Policy => ({
  ...p,
  limits: { ...p.limits, maxInfraRetries: 8 },
  budget: { ...p.budget, epic: { usd: 1000, tokens: 1_000_000_000 }, task: { usd: 100, tokens: 100_000_000 } },
});

export const script = (log: string, delayMs = 0): object => ({
  execLog: log,
  default: { behaviour: 'pass', costUsd: 0.05, tokens: 2000, ...(delayMs ? { delayMs } : {}) },
  tasks: {
    T2: [{ behaviour: 'verify-fail', signature: 'test:T2', costUsd: 0.05 }],
    T3: [{ behaviour: 'crash', costUsd: 0.01 }],
  },
});

export interface Scenario {
  sb: Sandbox;
  log: string;
  scriptFile: string;
}

/** Second scenario: A exhausts its correction attempts and blocks; B (needs A) stalls; C runs. */
export const escalationPlan: Plan = {
  epicId: 'E2',
  title: 'escalation',
  tasks: [
    { id: 'A', title: 'a', deps: [] },
    { id: 'B', title: 'b', deps: ['A'] },
    { id: 'C', title: 'c', deps: [] },
  ],
};
export const escalationScript = (log: string): object => ({
  execLog: log,
  default: { behaviour: 'pass' },
  tasks: { A: Array.from({ length: 12 }, (_, i) => ({ behaviour: 'verify-fail', signature: `sig-${i + 1}` })) },
});

export function setup(delayMs = 0, variant: 'sample' | 'escalation' = 'sample'): Scenario {
  const sb = sandbox(roomy);
  const c = Controller.open(sb.root);
  c.importPlan(variant === 'sample' ? samplePlan() : escalationPlan, sb.repo, 'test-human');
  c.close();
  const log = path.join(sb.dir, 'exec.log');
  const scriptFile = writeJson(path.join(sb.dir, 'script.json'), variant === 'sample' ? script(log, delayMs) : escalationScript(log));
  return { sb, log, scriptFile };
}

/** Escalation categories per task, which must also match the baseline. */
export function escalationsOf(s: Scenario): string[] {
  const p = statePaths(s.sb.root);
  return verifyJournalFile(p.journal, readJournalKey(p))
    .records.filter((r) => r.type === 'escalation')
    .map((r) => `${(r.data as { taskId: string }).taskId}:${(r.data as { category: string }).category}`)
    .sort();
}

export const runArgs = (s: Scenario): string[] => ['run', '--state-root', s.sb.root, '--repo', s.sb.repo, '--runner', 'fake', '--script', s.scriptFile];

export function journalCount(s: Scenario): number {
  const p = statePaths(s.sb.root);
  return verifyJournalFile(p.journal, readJournalKey(p)).records.length;
}

export function finalStates(s: Scenario): Record<string, string> {
  const c = Controller.open(s.sb.root);
  try {
    return c.summary().states;
  } finally {
    c.close();
  }
}

/** Every invariant that must hold after recovery. */
export function checkRecovered(s: Scenario, baseline: Record<string, string>, label: string): void {
  assert.deepEqual(finalStates(s), baseline, `${label}: final states`);
  const p = statePaths(s.sb.root);
  const v = verifyJournalFile(p.journal, readJournalKey(p));
  assert.equal(v.ok, true, `${label}: journal verifies`);
  const starts = new Set(
    v.records
      .filter((r) => r.type === 'task.transition' && (r.data as { to: string }).to === 'implementing')
      .map((r) => `${(r.data as { taskId: string }).taskId}#${(r.data as { attempt: number }).attempt}`),
  );
  const execs = readExecLog(s.log).map((e) => `${e.taskId}#${e.attempt}`);
  assert.equal(new Set(execs).size, execs.length, `${label}: a (task, attempt) executed twice: ${execs.join(' ')}`);
  for (const e of execs) assert.ok(starts.has(e), `${label}: ${e} executed without a journaled attempt start`);
  const d = runCli(['doctor', '--state-root', s.sb.root]);
  assert.equal(d.status, 0, `${label}: doctor\n${d.stdout}`);
  const rep = JSON.parse(d.stdout) as { warnings: string[] };
  assert.deepEqual(rep.warnings.filter((w) => w.includes('reservation')), [], `${label}: open reservations`);
}

export function recover(s: Scenario, label: string, crashAt?: number, progress?: Progress, phase: CrashPhase = 'journal'): void {
  if (crashAt !== undefined) {
    // A second crash, this time during recovery.
    const r = runCli(runArgs(s), crashEnv(crashAt, phase));
    assert.ok(r.status === 137 || r.status === 0, `${label}: second run exit ${r.status}: ${r.stderr}`);
    progress?.step(`second crash during recovery at append ${crashAt} (exit ${r.status})`);
  }
  let res = runCli(['resume', '--state-root', s.sb.root]);
  // A SIGKILL between creating the controller lock and writing it leaves an empty lock, which
  // counts as held for 2 s (src/util/lock.ts); an operator retries, and so does this.
  const lockFile = path.join(s.sb.root, 'locks', 'controller.lock');
  if (res.status !== 0 && /another controller holds/.test(res.stderr) && fs.existsSync(lockFile) && fs.statSync(lockFile).size === 0) {
    progress?.step('empty controller lock left by the kill; retrying resume after 2.5 s');
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 2_500);
    res = runCli(['resume', '--state-root', s.sb.root]);
  }
  assert.equal(res.status, 0, `${label}: resume: ${res.stderr}`);
  progress?.step('resume finished');
  const run = runCli(runArgs(s));
  assert.equal(run.status, 0, `${label}: run: ${run.stderr}`);
  progress?.step('run after resume finished');
}

/**
 * SIGKILL the controller and, on POSIX, its whole process group, so a store helper process
 * (bd) dies mid-operation too, as in a power loss.
 */
export function runAndKill(s: Scenario, afterMs: number): Promise<number | null> {
  return new Promise((resolve) => {
    const group = process.platform !== 'win32';
    const child = spawn(process.execPath, [CLI, ...runArgs(s)], { stdio: 'ignore', detached: group });
    const t = setTimeout(() => {
      if (group && child.pid !== undefined) process.kill(-child.pid, 'SIGKILL');
      else child.kill('SIGKILL');
    }, afterMs);
    child.on('exit', (code) => {
      clearTimeout(t);
      resolve(code);
    });
  });
}


/** Exit status of an injected crash, and its stderr line, for EO_CRASH_PHASE journal (default) or anchor. */
export function crashEnv(k: number, phase: CrashPhase): Record<string, string> {
  return phase === 'anchor' ? { EO_CRASH_AT: String(k), EO_CRASH_PHASE: 'anchor' } : { EO_CRASH_AT: String(k) };
}

export type CrashPhase = 'journal' | 'anchor';

/** The second crash during recovery used for boundary k of the sample sweep (every third boundary). */
export function secondCrash(k: number): number | undefined {
  return k % 3 === 0 ? 1 + ((k * 7) % 15) : undefined;
}

/**
 * One boundary of the sample sweep: crash after journal append k (before the anchor update,
 * or after it with phase "anchor"), recover, and check every invariant against the baseline.
 * Returns a label for the evidence ("k" or "k+j" with a second crash at j during recovery).
 */
export function sampleBoundary(k: number, baseline: Record<string, string>, phase: CrashPhase, progress?: Progress): string {
  const s = setup();
  try {
    const crashed = runCli(runArgs(s), crashEnv(k, phase));
    assert.equal(crashed.status, 137, `boundary ${k}: expected the injected crash, got ${crashed.status}: ${crashed.stderr}`);
    assert.match(crashed.stderr, new RegExp(`injected crash after (anchor update for )?journal append #${k}`));
    progress?.step(`crashed after journal append ${k} (${phase})`);
    const second = secondCrash(k);
    recover(s, `boundary ${k}`, second, progress, phase);
    checkRecovered(s, baseline, `boundary ${k}`);
    return `${k}${second ? `+${second}` : ''}`;
  } finally {
    disposeSandbox(s.sb);
  }
}

/** One boundary of the escalation sweep. */
export function escalationBoundary(k: number, baseline: Record<string, string>, baseEsc: string[], phase: CrashPhase, progress?: Progress): void {
  const s = setup(0, 'escalation');
  try {
    assert.equal(runCli(runArgs(s), crashEnv(k, phase)).status, 137, `boundary ${k}`);
    progress?.step(`crashed after journal append ${k} (${phase})`);
    recover(s, `escalation boundary ${k}`, undefined, progress);
    checkRecovered(s, baseline, `escalation boundary ${k}`);
    assert.deepEqual(escalationsOf(s), baseEsc, `escalation boundary ${k}: escalations`);
    const esc = fs.readdirSync(path.join(s.sb.root, 'escalations'));
    assert.equal(esc.length, 1, `escalation boundary ${k}: one escalation file`);
  } finally {
    disposeSandbox(s.sb);
  }
}

/** The baseline of a sweep: an uninterrupted run, its final states and its number of journal step boundaries. */
export function baselineRun(variant: 'sample' | 'escalation', delayMs = 0): { baseline: Record<string, string>; boundaries: number; escalations: string[]; durationMs: number } {
  const base = setup(delayMs, variant);
  try {
    const before = journalCount(base);
    const t0 = Date.now();
    const r = runCli(runArgs(base));
    const durationMs = Date.now() - t0;
    assert.equal(r.status, 0, r.stderr);
    const baseline = finalStates(base);
    checkRecovered(base, baseline, 'baseline');
    return { baseline, boundaries: journalCount(base) - before, escalations: escalationsOf(base), durationMs };
  } finally {
    disposeSandbox(base.sb);
  }
}

/** Kill delays for one random-kill seed: deterministic in the seed and the measured run length, so a seed replays exactly. */
export function killDelays(seed: number, durationMs: number): number[] {
  let rnd = (seed * 2654435761) % 2 ** 31;
  const next = (): number => {
    rnd = (rnd * 1103515245 + 12345) % 2 ** 31;
    return rnd / 2 ** 31;
  };
  return Array.from({ length: 4 }, (_, i) => 150 + Math.floor(next() * Math.max(100, durationMs / (i + 2))));
}

/** One random-kill seed: up to 4 SIGKILLs of the controller during attempts, then recovery. Returns the number of kills that landed. */
export async function randomKillSeed(seed: number, durationMs: number, baseline: Record<string, string>, progress?: Progress): Promise<number> {
  const s = setup(150);
  try {
    let killed = 0;
    for (const [i, delay] of killDelays(seed, durationMs).entries()) {
      const code = await runAndKill(s, delay);
      progress?.step(code === null ? `SIGKILL ${i + 1} delivered` : `run finished before kill ${i + 1}`);
      if (code === null) killed++;
      else break; // finished before the kill
    }
    recover(s, `kill seed ${seed}`, undefined, progress);
    checkRecovered(s, baseline, `kill seed ${seed}`);
    return killed;
  } finally {
    disposeSandbox(s.sb);
  }
}
