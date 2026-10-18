import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { spawn } from 'node:child_process';
import { Controller } from '../../src/controller.ts';
import { verifyJournalFile } from '../../src/journal.ts';
import { readJournalKey, statePaths } from '../../src/stateRoot.ts';
import { CLI, readExecLog, runCli, samplePlan, sandbox, writeJson, type Sandbox } from '../support/helpers.ts';
import type { Policy } from '../../src/policy.ts';

/**
 * M1-4. A scripted 5-task run with one verification failure and one worker crash. The
 * controller process is killed right after each of its N journal appends in turn; after
 * `eo resume` and `eo run` every run must end in the uninterrupted run's final states, with
 * no (task, attempt) executed twice and every execution preceded by its journaled intent.
 *
 * Interruptions consume infra retries and charge full reservations, so this policy gives
 * room for them; the scripted failures still exercise both retry paths.
 */
const roomy = (p: Policy): Policy => ({
  ...p,
  limits: { ...p.limits, maxInfraRetries: 8 },
  budget: { ...p.budget, epic: { usd: 1000, tokens: 1_000_000_000 }, task: { usd: 100, tokens: 100_000_000 } },
});

const script = (log: string, delayMs = 0): object => ({
  execLog: log,
  default: { behaviour: 'pass', costUsd: 0.05, tokens: 2000, ...(delayMs ? { delayMs } : {}) },
  tasks: {
    T2: [{ behaviour: 'verify-fail', signature: 'test:T2', costUsd: 0.05 }],
    T3: [{ behaviour: 'crash', costUsd: 0.01 }],
  },
});

interface Scenario {
  sb: Sandbox;
  log: string;
  scriptFile: string;
}

function setup(delayMs = 0): Scenario {
  const sb = sandbox(roomy);
  const c = Controller.open(sb.root);
  c.importPlan(samplePlan(), sb.repo, 'test-human');
  c.close();
  const log = path.join(sb.dir, 'exec.log');
  const scriptFile = writeJson(path.join(sb.dir, 'script.json'), script(log, delayMs));
  return { sb, log, scriptFile };
}

const runArgs = (s: Scenario): string[] => ['run', '--state-root', s.sb.root, '--repo', s.sb.repo, '--runner', 'fake', '--script', s.scriptFile];

function journalCount(s: Scenario): number {
  const p = statePaths(s.sb.root);
  return verifyJournalFile(p.journal, readJournalKey(p)).records.length;
}

function finalStates(s: Scenario): Record<string, string> {
  const c = Controller.open(s.sb.root);
  try {
    return c.summary().states;
  } finally {
    c.close();
  }
}

/** Every invariant that must hold after recovery. */
function checkRecovered(s: Scenario, baseline: Record<string, string>, label: string): void {
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

function recover(s: Scenario, label: string, crashAt?: number): void {
  if (crashAt !== undefined) {
    // A second crash, this time during recovery.
    const r = runCli(runArgs(s), { EO_CRASH_AT: String(crashAt) });
    assert.ok(r.status === 137 || r.status === 0, `${label}: second run exit ${r.status}: ${r.stderr}`);
  }
  const res = runCli(['resume', '--state-root', s.sb.root]);
  assert.equal(res.status, 0, `${label}: resume: ${res.stderr}`);
  const run = runCli(runArgs(s));
  assert.equal(run.status, 0, `${label}: run: ${run.stderr}`);
}

test('M1-4: crash after every journal step boundary of a 5-task run, then resume', { timeout: 900_000 }, (t) => {
  const base = setup();
  const before = journalCount(base);
  const r = runCli(runArgs(base));
  assert.equal(r.status, 0, r.stderr);
  const baseline = finalStates(base);
  const N = journalCount(base) - before;
  assert.deepEqual(baseline, { T1: 'done', T2: 'done', T3: 'done', T4: 'done', T5: 'done' });
  assert.ok(N >= 12, `only ${N} boundaries`);
  checkRecovered(base, baseline, 'baseline');

  const results: string[] = [];
  for (let k = 1; k <= N; k++) {
    const s = setup();
    const crashed = runCli(runArgs(s), { EO_CRASH_AT: String(k) });
    assert.equal(crashed.status, 137, `boundary ${k}: expected the injected crash, got ${crashed.status}: ${crashed.stderr}`);
    assert.match(crashed.stderr, new RegExp(`injected crash after journal append #${k}`));
    // Every third boundary also crashes during recovery, at a varying point.
    const second = k % 3 === 0 ? 1 + ((k * 7) % 15) : undefined;
    recover(s, `boundary ${k}`, second);
    checkRecovered(s, baseline, `boundary ${k}`);
    results.push(`${k}${second ? `+${second}` : ''}`);
  }
  // Recorded for the evidence report.
  t.diagnostic(`boundaries tested: ${N} (${results.join(', ')}); +j = second crash during recovery at append j`);
});

function runAndKill(s: Scenario, afterMs: number): Promise<number | null> {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [CLI, ...runArgs(s)], { stdio: 'ignore' });
    const t = setTimeout(() => child.kill('SIGKILL'), afterMs);
    child.on('exit', (code) => {
      clearTimeout(t);
      resolve(code);
    });
  });
}

test('M1-4: random SIGKILLs during attempts, then resume', { timeout: 600_000 }, async (t) => {
  const base = setup(150);
  const t0 = Date.now();
  assert.equal(runCli(runArgs(base)).status, 0);
  const duration = Date.now() - t0; // an uninterrupted run; kills land inside this window
  const baseline = finalStates(base);
  let rnd = 12345;
  const next = (): number => {
    rnd = (rnd * 1103515245 + 12345) % 2 ** 31;
    return rnd / 2 ** 31;
  };
  let killed = 0;
  for (let seed = 1; seed <= 8; seed++) {
    const s = setup(150);
    for (let i = 0; i < 4; i++) {
      const code = await runAndKill(s, 150 + Math.floor(next() * Math.max(100, duration / (i + 2))));
      if (code === null) killed++;
      else break; // finished before the kill
    }
    recover(s, `kill seed ${seed}`);
    checkRecovered(s, baseline, `kill seed ${seed}`);
  }
  t.diagnostic(`SIGKILLs delivered: ${killed} across 8 runs`);
  assert.ok(killed >= 8, `only ${killed} kills landed; the test is not exercising recovery`);
});
