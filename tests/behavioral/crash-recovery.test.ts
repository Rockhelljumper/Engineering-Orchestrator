import { test } from 'node:test';
import assert from 'node:assert/strict';
import { TIMEOUT_SCALE } from '../support/helpers.ts';
import { Progress } from '../support/progress.ts';
import { baselineRun, escalationBoundary, randomKillSeed, sampleBoundary, type CrashPhase } from '../support/crash-scenarios.ts';

/**
 * M1-4. A scripted 5-task run with one verification failure and one worker crash. The
 * controller process is killed right after each of its N journal appends in turn; after
 * `eo resume` and `eo run` every run must end in the uninterrupted run's final states, with
 * no (task, attempt) executed twice and every execution preceded by its journaled intent.
 *
 * M2-0b adds the rollback anchor, updated after each append: the "journal" sweeps crash
 * between the append and the anchor update, the "anchor" sweeps right after the update.
 *
 * The scenarios live in tests/support/crash-scenarios.ts, shared with the durable runner
 * (M2-0), which runs each boundary as its own checkpointed scenario.
 */

for (const phase of ['journal', 'anchor'] as CrashPhase[]) {
  test(`M1-4: crash after every journal step boundary of a 5-task run, then resume (${phase} phase)`, { timeout: 900_000 * TIMEOUT_SCALE }, (t) => {
    const { baseline, boundaries: N } = baselineRun('sample');
    assert.deepEqual(baseline, { T1: 'done', T2: 'done', T3: 'done', T4: 'done', T5: 'done' });
    assert.ok(N >= 12, `only ${N} boundaries`);
    const results: string[] = [];
    const progress = new Progress(`M1-4 every boundary (${phase})`, N);
    for (let k = 1; k <= N; k++) {
      progress.begin(`boundary ${k}`);
      results.push(sampleBoundary(k, baseline, phase, progress));
      progress.done();
    }
    // Recorded for the evidence report.
    t.diagnostic(`boundaries tested (${phase} phase): ${N} (${results.join(', ')}); +j = second crash during recovery at append j`);
  });
}

test('M1-4: random SIGKILLs during attempts, then resume', { timeout: 600_000 * TIMEOUT_SCALE }, async (t) => {
  const { baseline, durationMs } = baselineRun('sample', 150); // kills land inside an uninterrupted run's length
  let killed = 0;
  const progress = new Progress('M1-4 random SIGKILLs', 8);
  for (let seed = 1; seed <= 8; seed++) {
    progress.begin(`seed ${seed}`);
    killed += await randomKillSeed(seed, durationMs, baseline, progress);
    progress.done();
  }
  t.diagnostic(`SIGKILLs delivered: ${killed} across 8 runs`);
  assert.ok(killed >= 8, `only ${killed} kills landed; the test is not exercising recovery`);
});

for (const phase of ['journal', 'anchor'] as CrashPhase[]) {
  test(`M1-4: crash at every boundary of a run that ends in an escalation, then resume (${phase} phase)`, { timeout: 900_000 * TIMEOUT_SCALE }, (t) => {
    const { baseline, boundaries: N, escalations } = baselineRun('escalation');
    assert.deepEqual(baseline, { A: 'blocked', B: 'planned', C: 'done' });
    assert.deepEqual(escalations, ['A:attempts']);
    const progress = new Progress(`M1-4 escalation boundaries (${phase})`, N);
    for (let k = 1; k <= N; k++) {
      progress.begin(`escalation boundary ${k}`);
      escalationBoundary(k, baseline, escalations, phase, progress);
      progress.done();
    }
    t.diagnostic(`escalation scenario boundaries tested (${phase} phase): ${N}`);
  });
}
