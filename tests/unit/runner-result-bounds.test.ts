import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as path from 'node:path';
import { randomBytes } from 'node:crypto';
import { Controller, type AttemptEndRecord } from '../../src/controller.ts';
import { acceptRunResult, LIMITS, MAX_REPORTED_TOKENS, MAX_REPORTED_USD } from '../../src/runner/accept.ts';
import type { RunResult, Runner } from '../../src/runner/types.ts';
import { fakeJudgesFor } from '../../src/verify/fake.ts';
import { BudgetGovernor, reservationAmount, type SettleRecord } from '../../src/budget.ts';
import { Journal } from '../../src/journal.ts';
import { defaultPolicy } from '../../src/policy.ts';
import { doctor } from '../../src/doctor.ts';
import { sandbox, tmpDir } from '../support/helpers.ts';
import type { Plan } from '../../src/plan.ts';

// Bounds on what a runner may report: its cost must be an amount the budget ledger can hold
// exactly, and its strings, arrays and whole result have size limits. The runner is
// untrusted (threat T5), and its reported cost is accepted as reported within these bounds.

const one: Plan = { epicId: 'E1', title: 'one', tasks: [{ id: 'A', title: 'a', deps: [] }] };
const completed = (cost: unknown, extra: Record<string, unknown> = {}): unknown => ({ kind: 'completed', cost, summary: 's', ...extra });

// ------------------------------------------------------------------ reported cost range

test('cost bounds: an amount the ledger cannot hold exactly is invalid and charged as unknown', () => {
  for (const cost of [
    { usd: 1e303, tokens: 1 },
    { usd: Number.MAX_VALUE, tokens: 1 },
    { usd: 1e308, tokens: 1 },
    { usd: MAX_REPORTED_USD * (1 + 1e-12), tokens: 1 },
    { usd: 1, tokens: MAX_REPORTED_TOKENS + 1 },
    { usd: 1, tokens: 2 ** 60 },
    { usd: 1, tokens: Number.MAX_VALUE },
    // JSON has no Infinity: the plain copy turns it into null.
    { usd: Number.POSITIVE_INFINITY, tokens: 1 },
  ]) {
    for (const raw of [completed(cost), { kind: 'infra', reason: 'r', cost }]) {
      const a = acceptRunResult(raw);
      assert.equal(a.result.cost, null, JSON.stringify(cost));
      assert.ok(a.invalidCost !== undefined, `named as invalid: ${String(cost.usd)}/${String(cost.tokens)}`);
    }
  }
  // At the bounds, a cost is accepted as reported.
  assert.deepEqual(acceptRunResult(completed({ usd: MAX_REPORTED_USD, tokens: MAX_REPORTED_TOKENS })).result.cost, { usd: MAX_REPORTED_USD, tokens: MAX_REPORTED_TOKENS });
  // On the rejected path too an out-of-range cost is not kept; a valid one is.
  const rej = acceptRunResult(completed({ usd: 1e303, tokens: 1 }, { verdict: 'pass' }));
  assert.ok(rej.rejected !== undefined);
  assert.equal(rej.result.cost, null);
  assert.deepEqual(acceptRunResult(completed({ usd: 0, tokens: 0 }, { verdict: 'pass' })).result.cost, { usd: 0, tokens: 0 }, 'an under-report is accepted as reported');
});

test('cost bounds: a run reporting {usd: 1e303} is charged its full reservation, and spent stays correct after reopening', async () => {
  const sb = sandbox();
  const R = reservationAmount(defaultPolicy().budget);
  let c = Controller.open(sb.root);
  try {
    c.importPlan(one, sb.repo, 'h');
    const runner: Runner = { kind: 'huge-cost', run: async () => completed({ usd: 1e303, tokens: 1 }) as RunResult };
    const s = await c.run(runner, { ...fakeJudgesFor({ default: { behaviour: 'pass' } }), repoPath: sb.repo });
    assert.equal(s.states['A'], 'done');
    const end = c.journal.ofType<AttemptEndRecord>('attempt.end')[0];
    assert.equal(end?.data.result.cost, null);
    assert.match(end?.data.invalidCost ?? '', /1e\+303/);
    const settles = c.journal.ofType<SettleRecord>('budget.settle').map((r) => r.data);
    assert.deepEqual(settles.map((x) => [x.usd, x.tokens, x.basis]), [[R.usd, R.tokens, 'unknown']]);
    assert.deepEqual(c.budget.ledger.spent('task', 'A'), R);
  } finally {
    c.close();
  }
  c = Controller.open(sb.root);
  try {
    assert.deepEqual(c.budget.ledger.spent('task', 'A'), R);
    assert.deepEqual(c.budget.ledger.spent('epic', 'E1'), R);
  } finally {
    c.close();
  }
  const d = doctor(sb.root);
  assert.deepEqual(d.problems, []);
  assert.deepEqual(d.warnings.filter((w) => w.startsWith('budget:')), []);
});

test('cost bounds: settle refuses a charge that is not finite or would overflow the ledger', () => {
  const file = path.join(tmpDir(), 'journal.jsonl');
  const g = new BudgetGovernor(Journal.open(file, randomBytes(32)), defaultPolicy().budget);
  g.reserve('T#1', 'T', 'E');
  assert.throws(() => g.settle('T#1', { usd: Number.POSITIVE_INFINITY, tokens: 0 }), /finite/);
  assert.throws(() => g.settle('T#1', { usd: 0, tokens: Number.POSITIVE_INFINITY }), /finite/);
  assert.throws(() => g.settle('T#1', { usd: 1e303, tokens: 1 }), /out of range/);
  assert.throws(() => g.settle('T#1', { usd: Number.MAX_VALUE, tokens: 1 }), /out of range/);
  assert.throws(() => g.settle('T#1', { usd: Number.NaN, tokens: 1 }), /non-negative/);
  assert.equal(g.ledger.isOpen('T#1'), true, 'nothing was settled');
  const ok = g.settle('T#1', { usd: 0.5, tokens: 7 });
  assert.deepEqual([ok.basis, ok.trust], ['reported', 'worker-reported']);
});

test('cost bounds: a journaled settle with a lost (null) charge is replayed as the full reservation, and doctor warns', () => {
  const sb = sandbox();
  const R = reservationAmount(defaultPolicy().budget);
  let c = Controller.open(sb.root);
  try {
    c.importPlan(one, sb.repo, 'h');
    c.promote();
    assert.equal(c.budget.reserve('A#1@x', 'A', 'E1').kind, 'admit');
    // What code before the cost bounds journaled for {usd: 1e303}: round() overflowed to Infinity, which JSON writes as null.
    c.journal.append('budget.settle', { id: 'A#1@x', usd: null, tokens: 1, basis: 'reported', overshootUsd: null, overshootTokens: 0 });
  } finally {
    c.close();
  }
  c = Controller.open(sb.root);
  try {
    assert.deepEqual(c.budget.ledger.spent('task', 'A'), R);
    assert.deepEqual(c.budget.ledger.reserved('task', 'A'), { usd: 0, tokens: 0 });
    assert.match(c.budget.ledger.invalidCharges().join(' '), /A#1@x journaled an invalid charge .* counted as its full reservation/);
  } finally {
    c.close();
  }
  assert.ok(doctor(sb.root).warnings.some((w) => /^budget: settle A#1@x journaled an invalid charge/.test(w)));
});

// ------------------------------------------------------------------ size limits

test('size limits: summary, note, reason, artifacts and the whole result are capped; over a cap is rejected as infra, keeping a valid cost', () => {
  const cost = { usd: 0.1, tokens: 3 };
  const atLimit = acceptRunResult(
    completed(cost, {
      summary: 's'.repeat(LIMITS.summaryChars),
      observations: { note: 'n'.repeat(LIMITS.noteChars), artifacts: Array.from({ length: 8 }, () => 'a'.repeat(LIMITS.artifactChars)) },
    }),
  );
  assert.equal(atLimit.rejected, undefined);
  assert.equal(atLimit.result.kind, 'completed');
  assert.equal(acceptRunResult(completed(cost, { observations: { artifacts: Array.from({ length: LIMITS.artifacts }, (_, i) => `f${i}`) } })).rejected, undefined);
  assert.equal(acceptRunResult({ kind: 'infra', reason: 'r'.repeat(LIMITS.reasonChars), cost }).rejected, undefined);
  for (const [raw, why] of [
    [completed(cost, { summary: 's'.repeat(LIMITS.summaryChars + 1) }), /\$\.summary must have length <= 4096/],
    [completed(cost, { observations: { note: 'n'.repeat(LIMITS.noteChars + 1) } }), /\$\.observations\.note must have length <= 4096/],
    [completed(cost, { observations: { artifacts: Array.from({ length: LIMITS.artifacts + 1 }, () => 'f') } }), /\$\.observations\.artifacts must have <= 256 items/],
    [completed(cost, { observations: { artifacts: ['ok', 'a'.repeat(LIMITS.artifactChars + 1)] } }), /\$\.observations\.artifacts\[1\] must have length <= 1024/],
    [{ kind: 'infra', reason: 'r'.repeat(LIMITS.reasonChars + 1), cost }, /\$\.reason must have length <= 4096/],
    // Every field within its own cap, the whole over 64 KiB.
    [completed(cost, { observations: { artifacts: Array.from({ length: 80 }, () => 'a'.repeat(LIMITS.artifactChars)) } }), /over the 65536-byte limit/],
    // Size counts what the runner sent, including verdict fields that would be dropped.
    [completed(cost, { verification: { verdict: 'pass', signature: 'x'.repeat(LIMITS.totalBytes) } }), /over the 65536-byte limit/],
    // Bytes, not characters: four-byte characters (two UTF-16 units each) within every field's
    // character cap, over the byte cap in total.
    [completed(cost, { summary: '\u{1F600}'.repeat(2048), observations: { note: '\u{1F600}'.repeat(2048), artifacts: Array.from({ length: 30 }, () => '\u{1F600}'.repeat(512)) } }), /over the 65536-byte limit/],
  ] as const) {
    const a = acceptRunResult(raw);
    assert.equal(a.result.kind, 'infra');
    assert.match(a.rejected ?? '', why);
    assert.deepEqual(a.result.cost, cost, 'the reported cost still counts');
    // What is journaled for a rejected result is small: not the oversized content.
    assert.ok(JSON.stringify(a).length < 1024, `rejection is small (${JSON.stringify(a).length})`);
  }
  // An oversized result whose cost is not valid is charged as unknown.
  assert.equal(acceptRunResult(completed({ usd: 1e303, tokens: 1 }, { summary: 'x'.repeat(LIMITS.totalBytes) })).result.cost, null);
});

test('size limits: a runner returning an oversized result is journaled as an infra failure, never as completed', async () => {
  const sb = sandbox((p) => ({ ...p, limits: { ...p.limits, maxInfraRetries: 1 } }));
  const c = Controller.open(sb.root);
  try {
    c.importPlan(one, sb.repo, 'h');
    const runner: Runner = { kind: 'big', run: async () => completed({ usd: 0.01, tokens: 1 }, { summary: 'x'.repeat(LIMITS.totalBytes + 1) }) as RunResult };
    const s = await c.run(runner, { ...fakeJudgesFor({ default: { behaviour: 'pass' } }), repoPath: sb.repo });
    assert.equal(s.states['A'], 'blocked');
    const end = c.journal.ofType<AttemptEndRecord>('attempt.end')[0];
    assert.equal(end?.data.result.kind, 'infra');
    assert.match(end?.data.rejected ?? '', /over the 65536-byte limit/);
    assert.ok(JSON.stringify(end?.data).length < 1024);
  } finally {
    c.close();
  }
});
