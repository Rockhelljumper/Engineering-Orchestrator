#!/usr/bin/env node
// Interruption drill for the durable runner (M2-0): run a suite once uninterrupted, then
// again while killing the runner and its whole process group mid-scenario --kills times,
// killing one scenario process on its own (a worker), and simulating a container restart
// (every process killed, the run directory copied to a new location as a fresh mount, and the
// run resumed from that copy alone). The drill then checks that the interrupted run's result
// matches the uninterrupted one and that damaged or foreign evidence is rejected.
//
//   node tests/support/durable/drill.ts <out dir> --suite <name> [--param k=v ...] [--kills 3] [--seed 1] [--stall-window 5]
//
// Writes <out dir>/drill-report.json and exits 0 only if every check passed.
import * as fs from 'node:fs';
import * as path from 'node:path';
import { spawn, spawnSync, type ChildProcess } from 'node:child_process';
import { parseArgs } from 'node:util';
import { REPO_ROOT } from '../helpers.ts';
import { aggregate, type Aggregate } from './aggregate.ts';
import { computeIdentity, FILES, readLog, type CheckpointRecord, type Manifest } from './checkpoints.ts';

const CLI = path.join(REPO_ROOT, 'tests', 'support', 'durable', 'cli.ts');
const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

const { values, positionals } = parseArgs({
  args: process.argv.slice(2),
  allowPositionals: true,
  options: { suite: { type: 'string' }, param: { type: 'string', multiple: true }, kills: { type: 'string' }, seed: { type: 'string' }, 'stall-window': { type: 'string' } },
});
const out = path.resolve(positionals[0] ?? '');
const suite = values.suite as string;
const params = values.param ?? [];
const kills = Number(values.kills ?? 3);
const stall = Number(values['stall-window'] ?? 5);
let rnd = Number(values.seed ?? 1) * 2654435761 % 2 ** 31;
const random = (): number => {
  rnd = (rnd * 1103515245 + 12345) % 2 ** 31;
  return rnd / 2 ** 31;
};
fs.mkdirSync(out, { recursive: true });
const events: string[] = [];
const note = (s: string): void => {
  const line = `${new Date().toISOString()} ${s}`;
  events.push(line);
  process.stderr.write(`drill: ${line}\n`);
};

function cli(args: string[], env: Record<string, string> = {}): { status: number | null; stdout: string; stderr: string } {
  const r = spawnSync(process.execPath, [CLI, ...args], { encoding: 'utf8', env: { ...process.env, ...env }, maxBuffer: 64 * 1024 * 1024 });
  return { status: r.status, stdout: r.stdout, stderr: r.stderr };
}

function detached(args: string[]): ChildProcess {
  return spawn(process.execPath, [CLI, ...args], { stdio: ['ignore', 'ignore', fs.openSync(path.join(out, 'runner-stderr.log'), 'a')], detached: true });
}

function records(dir: string): CheckpointRecord[] {
  const m = JSON.parse(fs.readFileSync(path.join(dir, FILES.manifest), 'utf8')) as Manifest;
  return readLog(dir, m.runId).records;
}

/** How many runners have started or resumed this run so far. */
function invocations(dir: string): number {
  return fs.existsSync(path.join(dir, FILES.manifest)) ? records(dir).filter((r) => r.kind === 'run.start' || r.kind === 'run.resume').length : 0;
}

/**
 * The scenario the newest runner has started and not yet ended, if that runner is the
 * `nth` one (so a start left open by a runner killed earlier never counts as in flight).
 */
function inFlight(dir: string, nth: number): { scenario: string; invocation: string; attempt: number } | undefined {
  if (invocations(dir) < nth) return undefined;
  const recs = records(dir);
  const from = recs.map((r) => r.kind === 'run.start' || r.kind === 'run.resume').lastIndexOf(true);
  const last = recs.at(-1);
  if (from < 0 || !last || last.kind !== 'scenario.start' || recs.indexOf(last) < from) return undefined;
  return { scenario: last.scenario as string, invocation: last.invocation, attempt: last.attempt ?? 1 };
}

async function waitFor(cond: () => boolean, what: string, ms: number): Promise<void> {
  const deadline = Date.now() + ms;
  while (!cond()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await sleep(50);
  }
}

function killGroup(c: ChildProcess): Promise<void> {
  return new Promise((resolve) => {
    if (c.exitCode !== null || c.signalCode !== null) return resolve();
    c.on('exit', () => resolve());
    process.kill(-(c.pid as number), 'SIGKILL');
  });
}

const checks: Array<{ check: string; ok: boolean; detail: string }> = [];
const check = (name: string, ok: boolean, detail = ''): void => {
  checks.push({ check: name, ok, detail });
  note(`${ok ? 'PASS' : 'FAIL'} ${name}${detail ? `: ${detail}` : ''}`);
};

// 1. The uninterrupted run.
const baseDir = path.join(out, 'uninterrupted');
note(`uninterrupted run of ${suite} ${params.join(' ')}`);
const base = cli(['start', baseDir, '--suite', suite, ...params.flatMap((p) => ['--param', p])]);
const baseAgg = JSON.parse(base.stdout) as Aggregate;
check('uninterrupted run PASSED', baseAgg.status === 'PASSED', `${baseAgg.passed}/${baseAgg.declared}`);

// 2. The interrupted run: runner and process group killed mid-scenario, --kills times.
const runA = path.join(out, 'interrupted');
let runner = detached(['start', runA, '--suite', suite, '--stall-window', String(stall), ...params.flatMap((p) => ['--param', p])]);
const killedIn: string[] = [];
const kills_: Array<{ scenario: string; invocation: string; attempt: number }> = [];
let nth = 1;
for (let k = 1; k <= kills; k++) {
  await waitFor(() => inFlight(runA, nth) !== undefined, `a scenario in flight before kill ${k}`, 3_600_000);
  const s = inFlight(runA, nth);
  // Somewhere inside that scenario: wait a random fraction of a second, then make sure it is still the one running.
  await sleep(Math.floor(random() * 1500));
  const now = inFlight(runA, nth);
  if (now === undefined || now.scenario !== s?.scenario || now.attempt !== s.attempt) {
    k--;
    continue;
  }
  await killGroup(runner);
  killedIn.push(now.scenario);
  kills_.push(now);
  note(`kill ${k}: SIGKILL to the runner's process group with ${now.scenario} attempt ${now.attempt} in flight (runner ${now.invocation})`);
  if (k < kills) {
    await sleep(stall * 1000 + 500); // the killed runner's heartbeat must go stale before another may take over
    runner = detached(['resume', runA]);
    nth++;
  }
}
// A worker killed on its own while the runner lives: the runner records it as interrupted and reruns it.
await sleep(stall * 1000 + 500); // the killed runner's heartbeat must go stale before another may take over
runner = detached(['resume', runA]);
nth++;
// The live runner's own heartbeat names its scenario process (a dead runner's never counts).
type Beat = { invocation: string; childPid: number | null; scenario: string | null };
const liveChild = (): Beat | undefined => {
  const f = inFlight(runA, nth);
  if (!f) return undefined;
  try {
    const hb = JSON.parse(fs.readFileSync(path.join(runA, FILES.heartbeat), 'utf8')) as Beat;
    return hb.invocation === f.invocation && hb.childPid !== null && hb.scenario === f.scenario ? hb : undefined;
  } catch {
    return undefined;
  }
};
let workerKilled: string | null = null;
let workerAttempt = 0;
for (let tries = 0; workerKilled === null && tries < 20; tries++) {
  await waitFor(() => liveChild() !== undefined, 'a scenario process to kill', 3_600_000);
  await sleep(Math.floor(random() * 800));
  const hb = liveChild();
  if (!hb) continue;
  try {
    process.kill(hb.childPid as number, 'SIGKILL');
    workerKilled = hb.scenario;
    workerAttempt = inFlight(runA, nth)?.attempt ?? 0;
    note(`worker kill: SIGKILL to scenario process ${hb.childPid} (${hb.scenario}) only; the runner lives`);
  } catch {
    // it finished just now; wait for the next one
  }
}
check('the worker kill landed on a running scenario process', workerKilled !== null, workerKilled ?? 'no scenario process could be killed');
await waitFor(() => workerKilled === null || records(runA).some((r) => r.kind === 'scenario.end' && r.scenario === workerKilled && r.attempt === workerAttempt && r.result === 'interrupted'), 'the runner to record the worker kill', 600_000);
// 3. Container restart: every process killed mid-scenario; the run directory is all that survives.
await waitFor(() => inFlight(runA, nth) !== undefined, 'a scenario in flight before the restart', 3_600_000);
const atRestart = inFlight(runA, nth);
await killGroup(runner);
note(`container restart: every process killed with ${atRestart?.scenario} attempt ${atRestart?.attempt} in flight (runner ${atRestart?.invocation})`);
const runB = path.join(out, 'after-restart');
fs.cpSync(runA, runB, { recursive: true });
fs.rmSync(path.join(runB, 'work'), { recursive: true, force: true });
const statusBefore = JSON.parse(cli(['status', runB]).stdout) as Aggregate;
check('a run whose runner vanished reads as RUNNING within the stall window, never PASSED', statusBefore.status === 'RUNNING' || statusBefore.status === 'INTERRUPTED', statusBefore.status);
await sleep(stall * 1000 + 500);
const stalled = JSON.parse(cli(['status', runB]).stdout) as Aggregate;
check('after the stall window it is INTERRUPTED', stalled.status === 'INTERRUPTED', `${stalled.status}: ${stalled.reasons.join('; ')}`);
const resumed = cli(['resume', runB]);
const finalAgg = JSON.parse(resumed.stdout) as Aggregate;
note(`resumed from the copy: ${finalAgg.status} ${finalAgg.passed}/${finalAgg.declared}`);

// 4. The interrupted run matches the uninterrupted one.
check('interrupted run PASSED after resuming', finalAgg.status === 'PASSED', finalAgg.reasons.join('; '));
check('same scenarios passed as the uninterrupted run', finalAgg.passed === baseAgg.passed && finalAgg.declared === baseAgg.declared, `${finalAgg.passed}/${finalAgg.declared} vs ${baseAgg.passed}/${baseAgg.declared}`);
const recs = records(runB);
const passes = new Map<string, number>();
for (const r of recs) if (r.kind === 'scenario.end' && r.result === 'pass') passes.set(r.scenario as string, (passes.get(r.scenario as string) ?? 0) + 1);
check('no scenario counted twice', [...passes.values()].every((n) => n === 1), JSON.stringify([...passes].filter(([, n]) => n !== 1)));
const rerun = [...new Set([...killedIn, ...(workerKilled ? [workerKilled] : [])])];
const rerunOk = rerun.every((s) => recs.some((r) => r.kind === 'scenario.end' && r.scenario === s && r.result === 'pass' && (r.attempt ?? 1) > 1));
check('every interrupted scenario was rerun from scratch (a later attempt passed)', rerunOk, rerun.join(', '));
const kinds = recs.map((r) => r.kind);
check('the log records each resume', kinds.filter((k) => k === 'run.resume').length >= kills, `${kinds.filter((k) => k === 'run.resume').length} resumes`);
// Each runner kill hit a scenario that runner had started and never ended, in a different runner each time.
const midScenario = kills_.every((k) => {
  const own = recs.filter((r) => r.invocation === k.invocation && r.scenario === k.scenario && r.attempt === k.attempt);
  return own.some((r) => r.kind === 'scenario.start') && !own.some((r) => r.kind === 'scenario.end');
});
check(`each of the ${kills} runner kills landed mid-scenario, in ${kills} different runners`, kills_.length === kills && midScenario && new Set(kills_.map((k) => k.invocation)).size === kills, JSON.stringify(kills_));

// 5. Evidence that must not pass.
const m = JSON.parse(fs.readFileSync(path.join(runB, FILES.manifest), 'utf8')) as Manifest;
const here = computeIdentity(REPO_ROOT, m.suite, m.params);
const stale = aggregate(runB, { ...here, commit: '0'.repeat(40) });
check('a different commit reads STALE', stale.status === 'STALE', stale.reasons.join('; '));
const staleCli = cli(['resume', runB], { EO_REQUIRE_TRACE: process.env['EO_REQUIRE_TRACE'] === '1' ? '0' : '1' });
check('resuming under a different configuration is refused as STALE (exit 3)', staleCli.status === 3, staleCli.stderr.trim());
const damaged = (name: string, edit: (lines: string[]) => string[]): Aggregate => {
  const d = path.join(out, `damaged-${name}`);
  fs.cpSync(runB, d, { recursive: true });
  const f = path.join(d, FILES.log);
  fs.writeFileSync(f, edit(fs.readFileSync(f, 'utf8').split('\n').filter(Boolean)).join('\n') + '\n');
  return aggregate(d, here);
};
const trunc = damaged('truncated', (l) => l.slice(0, -2));
check('a truncated log is detected', trunc.status === 'FAILED' && trunc.integrityFailed, trunc.reasons.join('; '));
const edited = damaged('edited', (l) => l.map((x, i) => (i === Math.floor(l.length / 2) ? x.replace(/"ts":"2/, '"ts":"1') : x)));
check('an edited record is detected', edited.status === 'FAILED' && edited.integrityFailed, edited.reasons.join('; '));
const reordered = damaged('reordered', (l) => [l[1] as string, l[0] as string, ...l.slice(2)]);
check('reordered records are detected', reordered.status === 'FAILED' && reordered.integrityFailed, reordered.reasons.join('; '));
const noManifest = path.join(out, 'damaged-no-manifest');
fs.cpSync(runB, noManifest, { recursive: true });
fs.rmSync(path.join(noManifest, FILES.manifest));
const nm = aggregate(noManifest, here);
check('a missing manifest is NOT_VERIFIED', nm.status === 'NOT_VERIFIED', nm.reasons.join('; '));
// Resuming the truncated copy sets its log aside and reruns every scenario.
const truncDir = path.join(out, 'damaged-truncated');
const rr = cli(['resume', truncDir]);
const rrAgg = JSON.parse(rr.stdout) as Aggregate;
const forensics = fs.existsSync(path.join(truncDir, 'forensics')) ? fs.readdirSync(path.join(truncDir, 'forensics')) : [];
check('resuming a damaged log keeps it in forensics/ and reruns every scenario', rrAgg.status === 'PASSED' && forensics.length === 1 && records(truncDir).filter((r) => r.kind === 'scenario.end' && r.result === 'pass').length === rrAgg.declared, `${rrAgg.status}, forensics ${forensics.join(',')}`);

const ok = checks.every((c) => c.ok);
fs.writeFileSync(
  path.join(out, 'drill-report.json'),
  JSON.stringify({ suite, params, kills, killedIn, runnerKills: kills_, workerKilled, identity: here, uninterrupted: baseAgg, interrupted: finalAgg, checks, events, ok }, null, 2) + '\n',
);
note(ok ? 'DRILL PASSED' : 'DRILL FAILED');
process.exit(ok ? 0 : 1);
