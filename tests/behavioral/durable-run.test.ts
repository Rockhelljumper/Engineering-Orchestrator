import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { spawnSync } from 'node:child_process';
import { REPO_ROOT, tmpDir } from '../support/helpers.ts';
import { aggregate } from '../support/durable/aggregate.ts';
import { CheckpointWriter, computeIdentity, FILES, readLog, type Manifest } from '../support/durable/checkpoints.ts';
import { createRun, execute } from '../support/durable/run.ts';

/**
 * M2-0: durable long-running test execution, tested on the runner's synthetic suite. The
 * same runner and drill run the real crash-recovery and claim-race suites for the evidence.
 */

const DRILL = path.join(REPO_ROOT, 'tests', 'support', 'durable', 'drill.ts');
const quiet = { log: () => {} };

function manifestOf(dir: string): Manifest {
  return JSON.parse(fs.readFileSync(path.join(dir, FILES.manifest), 'utf8')) as Manifest;
}

function executions(markerDir: string): string[] {
  const f = path.join(markerDir, 'executions.log');
  return fs.existsSync(f) ? fs.readFileSync(f, 'utf8').split('\n').filter(Boolean).map((l) => l.split(' ')[0] as string) : [];
}

test('M2-0: the interruption drill (3 runner kills mid-scenario, a worker kill, a container restart) matches the uninterrupted run and rejects damaged evidence', { timeout: 600_000 }, () => {
  const out = tmpDir('eo-drill-');
  const r = spawnSync(process.execPath, [DRILL, out, '--suite', 'selftest', '--param', 'count=10', '--param', 'sleepMs=700', '--kills', '3', '--stall-window', '3'], { encoding: 'utf8', timeout: 590_000 });
  const report = JSON.parse(fs.readFileSync(path.join(out, 'drill-report.json'), 'utf8')) as { ok: boolean; checks: Array<{ check: string; ok: boolean; detail: string }>; killedIn: string[] };
  for (const c of report.checks) assert.ok(c.ok, `${c.check}: ${c.detail}`);
  assert.equal(report.killedIn.length, 3);
  assert.equal(r.status, 0, r.stderr.slice(-2000));
});

test('M2-0: a resumed run skips what passed and reruns only the interrupted scenario, in a fresh directory', { timeout: 120_000 }, async () => {
  const dir = path.join(tmpDir(), 'run');
  const markers = tmpDir();
  await createRun(dir, 'selftest', { count: 4, sleepMs: 50, markerDir: markers });
  const m = manifestOf(dir);
  // Simulate a runner that died inside s3: s1 and s2 passed, s3 started, no end.
  const id = computeIdentity(REPO_ROOT, m.suite, m.params);
  const sha = (await import('../../src/util/canonical.ts')).sha256Hex(fs.readFileSync(path.join(dir, FILES.manifest)));
  const w = new CheckpointWriter(dir, m, sha, 'dead0001', []);
  w.append({ kind: 'run.start' });
  for (const s of ['s1', 's2']) {
    w.append({ kind: 'scenario.start', scenario: s, attempt: 1 });
    w.append({ kind: 'scenario.end', scenario: s, attempt: 1, result: 'pass', detail: 'ok' });
  }
  w.append({ kind: 'scenario.start', scenario: 's3', attempt: 1, data: { work: path.join(dir, 'work', 's3', '1-dead0001') } });
  const before = aggregate(dir, id);
  assert.equal(before.status, 'INTERRUPTED');
  assert.deepEqual(before.interrupted, ['s3']);
  const after = await execute(dir, quiet);
  assert.equal(after.status, 'PASSED');
  assert.deepEqual(executions(markers), ['s3', 's4'], 'only s3 (rerun) and s4 ran');
  const s3 = readLog(dir, m.runId).records.filter((r) => r.scenario === 's3' && r.kind === 'scenario.start');
  assert.deepEqual(s3.map((r) => r.attempt), [1, 2]);
  assert.notEqual((s3[1]?.data as { work: string }).work, (s3[0]?.data as { work: string }).work, 'the rerun used a fresh directory');
});

test('M2-0: a failed scenario stands: the run is FAILED, and resuming never reruns it into a PASS', { timeout: 120_000 }, async () => {
  const dir = path.join(tmpDir(), 'run');
  const markers = tmpDir();
  await createRun(dir, 'selftest', { count: 4, sleepMs: 20, markerDir: markers, failAt: 's2' });
  const a = await execute(dir, quiet);
  assert.equal(a.status, 'FAILED');
  assert.deepEqual(a.failed, ['s2']);
  const b = await execute(dir, quiet);
  assert.equal(b.status, 'FAILED');
  assert.deepEqual(executions(markers), ['s1', 's2', 's3', 's4'], 'nothing reran');
});

test('M2-0: duplicated, foreign, mixed-identity or undeclared records and a changed manifest never give PASSED', { timeout: 120_000 }, async () => {
  const dir = path.join(tmpDir(), 'run');
  await createRun(dir, 'selftest', { count: 3, sleepMs: 10 });
  const ok = await execute(dir, quiet);
  assert.equal(ok.status, 'PASSED');
  const m = manifestOf(dir);
  const id = computeIdentity(REPO_ROOT, m.suite, m.params);
  const { sha256Hex } = await import('../../src/util/canonical.ts');
  const sha = sha256Hex(fs.readFileSync(path.join(dir, FILES.manifest)));
  const variant = (name: string, fn: (d: string, w: CheckpointWriter) => void): ReturnType<typeof aggregate> => {
    const d = path.join(path.dirname(dir), name);
    fs.cpSync(dir, d, { recursive: true });
    fn(d, new CheckpointWriter(d, m, sha, 'forge001', readLog(d, m.runId).records));
    return aggregate(d, id);
  };
  // A second pass for a scenario, appended with a valid chain (a runner bug, or a merged log).
  const twice = variant('twice', (_d, w) => {
    w.append({ kind: 'scenario.start', scenario: 's1', attempt: 2 });
    w.append({ kind: 'scenario.end', scenario: 's1', attempt: 2, result: 'pass', detail: 'again' });
  });
  assert.equal(twice.status, 'FAILED');
  assert.match(twice.reasons.join(), /counted twice: s1/);
  // A pass appended on its own, with no start by the same runner, is not a result.
  const lone = variant('lone-end', (_d, w) => w.append({ kind: 'scenario.end', scenario: 's2', attempt: 2, result: 'pass', detail: 'forged' }));
  assert.equal(lone.status, 'FAILED');
  assert.match(lone.reasons.join(), /an end for s2 attempt 2 with no matching start by the same runner/);
  // A record for a scenario the manifest does not declare.
  const extra = variant('undeclared', (_d, w) => w.append({ kind: 'scenario.end', scenario: 's9', result: 'pass' }));
  assert.equal(extra.status, 'FAILED');
  assert.match(extra.reasons.join(), /s9 is not in the manifest/);
  // A record carrying another identity (written by a run at another commit).
  const mixed = variant('mixed', (d) => {
    const w = new CheckpointWriter(d, { ...m, identity: { ...m.identity, commit: 'f'.repeat(40) } }, sha, 'forge002', readLog(d, m.runId).records);
    w.append({ kind: 'run.resume' });
  });
  assert.equal(mixed.status, 'FAILED');
  assert.match(mixed.reasons.join(), /identity differs from the manifest \(commit\)/);
  // The manifest edited after the run (a scenario dropped so a failing one disappears).
  const edited = variant('manifest', (d) => {
    const f = path.join(d, FILES.manifest);
    const mm = manifestOf(d);
    fs.writeFileSync(f, JSON.stringify({ ...mm, scenarios: mm.scenarios.slice(0, 2) }, null, 2));
  });
  assert.equal(edited.status, 'NOT_VERIFIED');
  assert.match(edited.reasons.join(), /written for a different manifest/);
  // A log from another run copied in.
  const other = path.join(tmpDir(), 'other');
  await createRun(other, 'selftest', { count: 3, sleepMs: 10 });
  await execute(other, quiet);
  const foreign = variant('foreign', (d) => {
    fs.copyFileSync(path.join(other, FILES.log), path.join(d, FILES.log));
    fs.copyFileSync(path.join(other, FILES.head), path.join(d, FILES.head));
  });
  assert.equal(foreign.status, 'FAILED');
  // An empty log, or no log at all, is not a pass.
  const empty = variant('empty', (d) => {
    fs.rmSync(path.join(d, FILES.log));
    fs.rmSync(path.join(d, FILES.head));
    fs.rmSync(path.join(d, FILES.heartbeat));
  });
  assert.equal(empty.status, 'INTERRUPTED');
  // A second run.end changes nothing.
  const again = variant('second-end', (d, w) => {
    void d;
    w.append({ kind: 'run.end' });
  });
  assert.equal(again.status, 'PASSED', 'a complete run stays PASSED after a second run.end');
  // A run that ended with scenarios missing is INCOMPLETE.
  const part = path.join(tmpDir(), 'part');
  await createRun(part, 'selftest', { count: 3, sleepMs: 10 });
  const pm = manifestOf(part);
  const pw = new CheckpointWriter(part, pm, sha256Hex(fs.readFileSync(path.join(part, FILES.manifest))), 'part0001', []);
  pw.append({ kind: 'run.start' });
  pw.append({ kind: 'scenario.start', scenario: 's1', attempt: 1 });
  pw.append({ kind: 'scenario.end', scenario: 's1', attempt: 1, result: 'pass' });
  pw.append({ kind: 'run.end' });
  const inc = aggregate(part, computeIdentity(REPO_ROOT, pm.suite, pm.params));
  assert.equal(inc.status, 'INCOMPLETE');
  assert.deepEqual(inc.missing, ['s2', 's3']);
});

test('M2-0: a run is RUNNING while its runner beats, and a second runner is refused meanwhile', { timeout: 120_000 }, async () => {
  const dir = path.join(tmpDir(), 'run');
  await createRun(dir, 'selftest', { count: 3, sleepMs: 1500 });
  const m = manifestOf(dir);
  const id = computeIdentity(REPO_ROOT, m.suite, m.params);
  const running = execute(dir, quiet);
  const deadline = Date.now() + 10_000;
  while (!fs.existsSync(path.join(dir, FILES.log)) && Date.now() < deadline) await new Promise((r) => setTimeout(r, 20));
  assert.equal(aggregate(dir, id).status, 'RUNNING');
  await assert.rejects(execute(dir, quiet), /another runner is active/);
  assert.equal((await running).status, 'PASSED');
});

test('M2-0: a manifest edited to drop a failed scenario is never resumed into a PASS, and an edited manifest with no records yet is refused too', { timeout: 120_000 }, async () => {
  const dir = path.join(tmpDir(), 'run');
  await createRun(dir, 'selftest', { count: 5, sleepMs: 10, failAt: 's4' });
  assert.equal((await execute(dir, quiet)).status, 'FAILED');
  const f = path.join(dir, FILES.manifest);
  const original = fs.readFileSync(f);
  const mm = manifestOf(dir);
  fs.writeFileSync(f, JSON.stringify({ ...mm, scenarios: mm.scenarios.filter((x) => x.id !== 's4') }, null, 2));
  const st = aggregate(dir, computeIdentity(REPO_ROOT, mm.suite, mm.params));
  assert.equal(st.status, 'NOT_VERIFIED');
  await assert.rejects(execute(dir, quiet), (err: unknown) => (err as { code?: string }).code === 'not-verified' && /written for a different manifest/.test((err as Error).message));
  assert.equal(aggregate(dir).status, 'NOT_VERIFIED', 'still not verified: nothing was reset or rerun');
  fs.writeFileSync(f, original);
  assert.equal(aggregate(dir).status, 'FAILED', 'the original manifest brings back the original verdict');
  // Before any record exists, the declared scenarios are checked against the suite's plan.
  const fresh = path.join(tmpDir(), 'fresh');
  await createRun(fresh, 'selftest', { count: 5, sleepMs: 10, failAt: 's4' });
  const fm = manifestOf(fresh);
  fs.writeFileSync(path.join(fresh, FILES.manifest), JSON.stringify({ ...fm, scenarios: fm.scenarios.filter((x) => x.id !== 's4') }, null, 2));
  await assert.rejects(execute(fresh, quiet), /declares other scenarios than suite selftest plans/);
});

test('M2-0: a log whose last line was torn by a crash is cut back before the next append, keeping the fragment', { timeout: 120_000 }, async () => {
  const dir = path.join(tmpDir(), 'run');
  await createRun(dir, 'selftest', { count: 4, sleepMs: 10 });
  assert.equal((await execute(dir, quiet)).status, 'PASSED');
  const m = manifestOf(dir);
  // Drop the last two records (the s4 end and run.end), then leave half a record: a host crash mid-write.
  const lines = fs.readFileSync(path.join(dir, FILES.log), 'utf8').split('\n').filter(Boolean);
  const kept = lines.slice(0, -3);
  const fragment = (lines.at(-2) as string).slice(0, 40);
  fs.writeFileSync(path.join(dir, FILES.log), kept.join('\n') + '\n' + lines.at(-3) + '\n' + fragment);
  const last = JSON.parse(lines.at(-3) as string) as { seq: number; hash: string };
  fs.writeFileSync(path.join(dir, FILES.head), JSON.stringify({ seq: last.seq, hash: last.hash }));
  fs.rmSync(path.join(dir, FILES.heartbeat));
  const before = aggregate(dir);
  assert.equal(before.status, 'INTERRUPTED');
  const after = await execute(dir, quiet);
  assert.equal(after.status, 'PASSED', after.reasons.join('; '));
  assert.equal(readLog(dir, m.runId).integrity.length, 0);
  const torn = fs.readdirSync(path.join(dir, 'forensics')).filter((x) => x.endsWith('-torn-tail.bin'));
  assert.equal(torn.length, 1);
  assert.equal(fs.readFileSync(path.join(dir, 'forensics', torn[0] as string), 'utf8'), fragment);
});

test('M2-0: a source-file change makes a run STALE; a scenario that crashes on its own fails; crash injection is refused', { timeout: 120_000 }, async () => {
  const dir = path.join(tmpDir(), 'run');
  await createRun(dir, 'selftest', { count: 3, sleepMs: 10, abortAt: 's2' });
  const m = manifestOf(dir);
  const here = computeIdentity(REPO_ROOT, m.suite, m.params);
  await assert.rejects(execute(dir, { ...quiet, identity: { ...here, testSourceSha256: 'f'.repeat(64) } }), (err: unknown) => (err as { code?: string }).code === 'stale' && /testSourceSha256/.test((err as Error).message));
  const r = await execute(dir, quiet);
  assert.equal(r.status, 'FAILED');
  assert.deepEqual(r.failed, ['s2']);
  assert.match(readLog(dir, m.runId).records.find((x) => x.scenario === 's2' && x.kind === 'scenario.end')?.detail ?? '', /died by SIGABRT/);
  process.env['EO_CRASH_AT'] = '3';
  try {
    await assert.rejects(execute(dir, quiet), /EO_CRASH_AT is set/);
  } finally {
    delete process.env['EO_CRASH_AT'];
  }
});

test('M2-0: a checkout git cannot list has no identity, so no run can be verified there', () => {
  const bare = tmpDir();
  fs.writeFileSync(path.join(bare, 'package.json'), '{}');
  assert.throws(() => computeIdentity(bare, 'selftest', {}), /cannot identify the checkout/);
});
