import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as path from 'node:path';
import { Controller } from '../../src/controller.ts';
import { verifyJournalFile, type JournalRecord } from '../../src/journal.ts';
import { readJournalKey, statePaths } from '../../src/stateRoot.ts';
import { readVerdictLog } from '../../src/verify/fake.ts';
import type { SettleRecord } from '../../src/budget.ts';
import { disposeSandbox, readExecLog, runCli, sandbox, TIMEOUT_SCALE, writeJson, type Sandbox } from '../support/helpers.ts';
import { crashEnv, type CrashPhase } from '../support/crash-scenarios.ts';
import type { Plan } from '../../src/plan.ts';

/**
 * Crashes around the controller's own verdicts. The controller process is killed (EO_CRASH_AT)
 * right after each journal record of interest: between a run's completion (attempt.end) and
 * its verdict, between a verdict and the evidence seal or transition it leads to, and after
 * the review verdict. After `eo resume` and `eo run`, the attempt is never run again, no spend
 * is settled twice, each verdict is asked for exactly once and none is lost.
 */

const plan: Plan = { epicId: 'E1', title: 'verdicts', tasks: [{ id: 'A', title: 'a', deps: [] }] };

interface Run {
  sb: Sandbox;
  exec: string;
  verdicts: string;
  args: string[];
}

function setup(): Run {
  const sb = sandbox();
  const c = Controller.open(sb.root);
  c.importPlan(plan, sb.repo, 'test-human');
  c.close();
  const exec = path.join(sb.dir, 'exec.log');
  const verdicts = path.join(sb.dir, 'verdicts.log');
  const script = writeJson(path.join(sb.dir, 'script.json'), {
    execLog: exec,
    verdictLog: verdicts,
    default: { behaviour: 'pass', costUsd: 0.25 },
    tasks: { A: [{ behaviour: 'verify-fail', signature: 'crash:A1', costUsd: 0.5 }] },
  });
  return { sb, exec, verdicts, args: ['run', '--state-root', sb.root, '--repo', sb.repo, '--runner', 'fake', '--script', script] };
}

function records(r: Run): JournalRecord[] {
  const p = statePaths(r.sb.root);
  return verifyJournalFile(p.journal, readJournalKey(p)).records;
}

const of = (rec: JournalRecord): { taskId?: string; attempt?: number } => rec.data as { taskId?: string; attempt?: number };

/** The crash points, as predicates on the record the crash follows, and which tasks resume leaves waiting for a verdict. */
const POINTS: Array<[string, (r: JournalRecord) => boolean, string[]]> = [
  ['after attempt.end A#1, before its verdict', (r) => r.type === 'attempt.end' && of(r).attempt === 1, ['A']],
  ['after the verification verdict A#1, before its evidence and transition', (r) => r.type === 'verify.verdict' && of(r).attempt === 1, []],
  ['after the evidence seal A#1, before the transition', (r) => r.type === 'evidence.sealed' && of(r).attempt === 1, []],
  ['after attempt.end A#2, before its verdict', (r) => r.type === 'attempt.end' && of(r).attempt === 2, ['A']],
  // Resume applies the journaled pass; the review verdict is still to come.
  ['after the verification verdict A#2, before the transition', (r) => r.type === 'verify.verdict' && of(r).attempt === 2, ['A']],
  ['after the review verdict A#2, before the transition', (r) => r.type === 'review.verdict' && of(r).attempt === 2, []],
];

function checkRecovered(r: Run, label: string): void {
  const recs = records(r);
  const c = Controller.open(r.sb.root);
  try {
    const a = c.store.get('A');
    assert.equal(a?.state, 'done', `${label}: state`);
    assert.equal(a?.attempt, 2, `${label}: attempt counted once each`);
    assert.equal(a?.correctionFailures, 1, `${label}: one correction failure`);
    assert.equal(a?.lastFailureSignature, 'crash:A1', `${label}: the verdict was not lost`);
  } finally {
    c.close();
  }
  assert.deepEqual(readExecLog(r.exec).map((e) => `${e.taskId}#${e.attempt}`), ['A#1', 'A#2'], `${label}: each attempt ran once`);
  assert.deepEqual(
    readVerdictLog(r.verdicts).map((e) => `${e.stage}:${e.taskId}#${e.attempt}`),
    ['verification:A#1', 'verification:A#2', 'review:A#2'],
    `${label}: each verdict asked for exactly once`,
  );
  const key = (x: JournalRecord): string => `${x.type}:${of(x).taskId}#${of(x).attempt}`;
  const once = recs.filter((x) => ['attempt.end', 'verify.verdict', 'review.verdict', 'evidence.sealed'].includes(x.type)).map(key);
  assert.deepEqual(once, ['attempt.end:A#1', 'verify.verdict:A#1', 'evidence.sealed:A#1', 'attempt.end:A#2', 'verify.verdict:A#2', 'evidence.sealed:A#2', 'review.verdict:A#2'], `${label}: journal`);
  const settles = recs.filter((x) => x.type === 'budget.settle').map((x) => x.data as SettleRecord);
  assert.deepEqual(settles.map((s) => [s.usd, s.basis]), [[0.5, 'reported'], [0.25, 'reported']], `${label}: spend settled once per attempt`);
  const d = runCli(['doctor', '--state-root', r.sb.root]);
  assert.equal(d.status, 0, `${label}: doctor\n${d.stdout}`);
}

test('verdict crash windows: a kill around each controller verdict recovers without re-running, double-charging or losing a verdict', { timeout: 300_000 * TIMEOUT_SCALE }, (t) => {
  // The uninterrupted run, and where each crash point falls in its journal appends.
  const base = setup();
  let at: number[];
  try {
    const before = records(base).length;
    const res = runCli(base.args);
    assert.equal(res.status, 0, res.stderr);
    checkRecovered(base, 'baseline');
    const appended = records(base).slice(before);
    at = POINTS.map(([label, is]) => {
      const i = appended.findIndex(is);
      assert.ok(i >= 0, `baseline has no record for "${label}"`);
      return i + 1;
    });
  } finally {
    disposeSandbox(base.sb);
  }
  const tested: string[] = [];
  for (const phase of ['journal', 'anchor'] as CrashPhase[]) {
    for (const [i, [label, , awaiting]] of POINTS.entries()) {
      const k = at[i] as number;
      const name = `${label} (append ${k}, ${phase} phase)`;
      const r = setup();
      try {
        const crashed = runCli(r.args, crashEnv(k, phase));
        assert.equal(crashed.status, 137, `${name}: expected the injected crash: ${crashed.stderr}`);
        const last = records(r).at(-1) as JournalRecord;
        assert.ok(POINTS[i]?.[1](last), `${name}: crashed after ${last.type}`);
        const resumed = runCli(['resume', '--state-root', r.sb.root]);
        assert.equal(resumed.status, 0, `${name}: resume: ${resumed.stderr}`);
        const rep = JSON.parse(resumed.stdout) as { awaitingVerdict: string[]; interrupted: string[] };
        assert.deepEqual(rep.interrupted, [], `${name}: an ended attempt is not "interrupted"`);
        // Resume never invents a verdict: a crash before one leaves A waiting for the run's judges.
        assert.deepEqual(rep.awaitingVerdict, awaiting, `${name}: awaiting`);
        const run = runCli(r.args);
        assert.equal(run.status, 0, `${name}: run: ${run.stderr}`);
        checkRecovered(r, name);
        tested.push(`${k}/${phase}`);
      } finally {
        disposeSandbox(r.sb);
      }
    }
  }
  t.diagnostic(`verdict crash points tested: ${tested.join(', ')}`);
});
