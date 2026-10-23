import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { writeFileAtomic } from '../../../src/util/fsx.ts';
import { REPO_ROOT } from '../helpers.ts';
import { aggregate, heartbeatAgeS, readManifest, type Aggregate } from './aggregate.ts';
import { CheckpointWriter, computeIdentity, FILES, readLog, type Manifest, type RunIdentity, type ScenarioResult } from './checkpoints.ts';
import { SUITES } from './suites.ts';

export class DurableRunError extends Error {
  readonly code: 'stale' | 'not-verified' | 'busy' | 'usage';

  constructor(message: string, code: 'stale' | 'not-verified' | 'busy' | 'usage') {
    super(message);
    this.code = code;
  }
}

export interface ExecuteOptions {
  /** Identity of the checkout under review; computed from REPO_ROOT when absent. */
  identity?: RunIdentity;
  /** How often a scenario killed from outside (signal) is retried in one invocation before the run stops. */
  maxInterruptsPerScenario?: number;
  log?: (line: string) => void;
}

const CHILD = path.join(REPO_ROOT, 'tests', 'support', 'durable', 'scenario-child.ts');
const HEARTBEAT_MS = 2_000;
const INTERRUPT_SIGNALS = new Set(['SIGKILL', 'SIGTERM', 'SIGINT', 'SIGHUP']);

/** Create a run: plan the suite (a baseline where it needs one) and fix its scenarios and identity in the manifest. */
export async function createRun(dir: string, suiteName: string, params: Record<string, unknown>, opts: { stallWindowS?: number; identity?: RunIdentity } = {}): Promise<Manifest> {
  const suite = SUITES[suiteName];
  if (!suite) throw new DurableRunError(`unknown suite ${suiteName} (known: ${Object.keys(SUITES).join(', ')})`, 'usage');
  if (fs.existsSync(dir) && fs.readdirSync(dir).length > 0) throw new DurableRunError(`${dir} is not empty; resume it, or choose a new run directory`, 'usage');
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const { scenarios, derived } = await suite.plan(params);
  const manifest: Manifest = {
    version: 1,
    runId: randomUUID(),
    suite: suiteName,
    params,
    derived,
    scenarios,
    identity: opts.identity ?? computeIdentity(REPO_ROOT, suiteName, params),
    createdAt: new Date().toISOString(),
    stallWindowS: opts.stallWindowS ?? 120,
  };
  writeFileAtomic(path.join(dir, FILES.manifest), JSON.stringify(manifest, null, 2) + '\n');
  return manifest;
}

function takeLock(dir: string, invocation: string, stallWindowS: number): void {
  const lock = path.join(dir, FILES.lock);
  for (let i = 0; i < 2; i++) {
    try {
      const fd = fs.openSync(lock, 'wx', 0o600);
      fs.writeSync(fd, JSON.stringify({ invocation, pid: process.pid, host: os.hostname(), ts: new Date().toISOString() }));
      fs.closeSync(fd);
      return;
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code !== 'EEXIST') throw err;
      // A runner that left its lock behind is gone once its heartbeat is older than the stall
      // window (its pid means nothing after a container restart).
      const age = heartbeatAgeS(dir);
      if (age !== null && age <= stallWindowS) throw new DurableRunError(`another runner is active in ${dir} (heartbeat ${Math.round(age)} s ago)`, 'busy');
      fs.rmSync(lock, { force: true });
    }
  }
  throw new DurableRunError(`could not take the runner lock in ${dir}`, 'busy');
}

/**
 * Run, or resume, every scenario of a run that has no result yet. Scenarios that passed under
 * the same identity are skipped; an interrupted one is rerun from scratch in a fresh
 * directory; a failed one is never rerun (its failure stands). Returns the final aggregate.
 */
export async function execute(dir: string, opts: ExecuteOptions = {}): Promise<Aggregate> {
  const log = opts.log ?? ((l: string) => process.stderr.write(`durable: ${l}\n`));
  const m = readManifest(dir);
  if ('error' in m) throw new DurableRunError(`${dir}: ${m.error}`, 'not-verified');
  const { manifest } = m;
  // Crash injection would reach every scenario through the environment.
  for (const k of ['EO_CRASH_AT', 'EO_CRASH_PHASE']) if (process.env[k] !== undefined) throw new DurableRunError(`${k} is set; unset it before running a suite`, 'usage');
  const identity = opts.identity ?? computeIdentity(REPO_ROOT, manifest.suite, manifest.params);
  // A run for another checkout or configuration is refused before anything in it is touched.
  const first = aggregate(dir, identity);
  if (first.status === 'STALE') throw new DurableRunError(`run ${manifest.runId} is STALE: ${first.reasons.join('; ')}. Its results do not apply to this checkout; start a new run.`, 'stale');
  if (first.manifestChanged) throw new DurableRunError(`run ${manifest.runId} is NOT_VERIFIED: ${first.reasons.join('; ')}`, 'not-verified');
  // The declared scenarios must be the ones the suite plans for these parameters, so an
  // edited manifest (with no records yet to give it away) cannot drop a scenario either.
  const suite = SUITES[manifest.suite];
  if (!suite) throw new DurableRunError(`unknown suite ${manifest.suite}`, 'not-verified');
  const planned = (await suite.plan(manifest.params)).scenarios.map((s) => `${s.id}:${s.seed ?? ''}`).join(',');
  if (planned !== manifest.scenarios.map((s) => `${s.id}:${s.seed ?? ''}`).join(',')) {
    throw new DurableRunError(`run ${manifest.runId} is NOT_VERIFIED: its manifest declares other scenarios than suite ${manifest.suite} plans for its parameters`, 'not-verified');
  }
  const invocation = randomUUID().slice(0, 8);
  takeLock(dir, invocation, manifest.stallWindowS);
  let current: string | null = null;
  let childPid: number | null = null;
  const beat = (scenario: string | null): void =>
    writeFileAtomic(path.join(dir, FILES.heartbeat), JSON.stringify({ invocation, pid: process.pid, host: os.hostname(), ts: new Date().toISOString(), scenario, childPid }) + '\n');
  beat(null);
  const timer = setInterval(() => beat(current), HEARTBEAT_MS);
  try {
    let before = aggregate(dir, identity);
    if (before.status === 'STALE') throw new DurableRunError(`run ${manifest.runId} is STALE: ${before.reasons.join('; ')}. Its results do not apply to this checkout; start a new run.`, 'stale');
    if (before.status === 'NOT_VERIFIED') throw new DurableRunError(`run ${manifest.runId} is NOT_VERIFIED: ${before.reasons.join('; ')}`, 'not-verified');
    let reset: string[] | undefined;
    if (before.integrityFailed) {
      // The log cannot be trusted, so none of its results count: keep it for forensics and
      // rerun every scenario.
      const keep = path.join(dir, 'forensics', `${new Date().toISOString().replace(/[:.]/g, '-')}-${invocation}`);
      fs.mkdirSync(keep, { recursive: true });
      fs.copyFileSync(path.join(dir, FILES.manifest), path.join(keep, FILES.manifest));
      for (const f of [FILES.log, FILES.head]) if (fs.existsSync(path.join(dir, f))) fs.renameSync(path.join(dir, f), path.join(keep, f));
      reset = [...before.reasons, `log set aside in ${keep}`];
      log(`integrity failure, every scenario reruns: ${reset.join('; ')}`);
      before = aggregate(dir, identity);
    }
    const records = readLog(dir, manifest.runId).records;
    const w = new CheckpointWriter(dir, manifest, m.sha256, invocation, records);
    if (reset) w.append({ kind: 'run.reset', detail: reset.join('; ') });
    const resumed = records.length > 0;
    w.append({ kind: resumed ? 'run.resume' : 'run.start', data: { statusBefore: before.status, passedBefore: before.passed, interruptedBefore: before.interrupted } });
    const done = new Set<string>();
    const failed = new Set(before.failed);
    // A pass under this identity is skipped; tallies come from the aggregate.
    {
      const agg = before;
      for (const s of manifest.scenarios) if (!agg.missing.includes(s.id) && !failed.has(s.id)) done.add(s.id);
    }
    const startsSoFar = new Map<string, number>();
    for (const r of readLog(dir, manifest.runId).records) if (r.kind === 'scenario.start' && r.scenario) startsSoFar.set(r.scenario, (startsSoFar.get(r.scenario) ?? 0) + 1);
    const maxInterrupts = opts.maxInterruptsPerScenario ?? 3;
    let stoppedEarly = false;
    for (const s of manifest.scenarios) {
      if (done.has(s.id) || failed.has(s.id)) continue;
      let interrupts = 0;
      for (;;) {
        const attempt = (startsSoFar.get(s.id) ?? 0) + 1;
        startsSoFar.set(s.id, attempt);
        const work = path.join(dir, 'work', s.id, `${attempt}-${invocation}`);
        fs.mkdirSync(work, { recursive: true, mode: 0o700 });
        current = s.id;
        beat(s.id);
        const startedAt = new Date().toISOString();
        w.append({ kind: 'scenario.start', scenario: s.id, ...(s.seed !== undefined ? { seed: s.seed } : {}), attempt, startedAt, data: { work } });
        const { result, detail } = await runChild(dir, s.id, work, (pid) => {
          childPid = pid;
          beat(s.id);
        });
        childPid = null;
        w.append({ kind: 'scenario.end', scenario: s.id, ...(s.seed !== undefined ? { seed: s.seed } : {}), attempt, result, startedAt, endedAt: new Date().toISOString(), detail });
        log(`${s.id} attempt ${attempt}: ${result}${result === 'pass' ? '' : ` (${detail.split('\n')[0]})`}`);
        if (result === 'pass') fs.rmSync(work, { recursive: true, force: true });
        if (result !== 'interrupted') break;
        if (++interrupts >= maxInterrupts) {
          stoppedEarly = true;
          break;
        }
      }
      current = null;
      if (stoppedEarly) break;
    }
    const after = aggregate(dir, identity);
    w.append({ kind: 'run.end', data: { status: after.status, passed: after.passed, failed: after.failed, stoppedEarly } });
    const final = aggregate(dir, identity);
    writeFileAtomic(path.join(dir, FILES.aggregate), JSON.stringify(final, null, 2) + '\n');
    return final;
  } finally {
    clearInterval(timer);
    // Only our own lock: a runner wrongly taken for dead must not remove its successor's.
    try {
      if ((JSON.parse(fs.readFileSync(path.join(dir, FILES.lock), 'utf8')) as { invocation?: string }).invocation === invocation) fs.rmSync(path.join(dir, FILES.lock), { force: true });
    } catch {
      // gone already
    }
  }
}

/** Run one scenario process; a signal from outside is "interrupted", not a failure. */
function runChild(dir: string, id: string, work: string, started: (pid: number | null) => void): Promise<{ result: ScenarioResult; detail: string }> {
  const resultFile = path.join(work, 'result.json');
  const out = fs.openSync(path.join(work, 'output.log'), 'w');
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [CHILD, dir, id, resultFile], { stdio: ['ignore', out, out], env: { ...process.env, TMPDIR: work, TMP: work, TEMP: work } });
    started(child.pid ?? null);
    child.on('exit', (code, signal) => {
      fs.closeSync(out);
      let r: { ok: boolean; detail: string } | undefined;
      try {
        r = JSON.parse(fs.readFileSync(resultFile, 'utf8')) as { ok: boolean; detail: string };
      } catch {
        r = undefined;
      }
      // Killed from outside (a runner, container or host going down) is an interruption; a
      // scenario that crashes on its own (SIGSEGV, SIGABRT, ...) has failed.
      if (signal !== null && INTERRUPT_SIGNALS.has(signal)) resolve({ result: 'interrupted', detail: `scenario process killed by ${signal}` });
      else if (signal !== null) resolve({ result: 'fail', detail: `scenario process died by ${signal}` });
      else if (code === 0 && r?.ok === true) resolve({ result: 'pass', detail: r.detail });
      else resolve({ result: 'fail', detail: r?.detail ?? `scenario process exited ${code} without a result` });
    });
  });
}
