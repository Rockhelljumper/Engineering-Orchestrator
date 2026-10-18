import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as path from 'node:path';
import { randomBytes } from 'node:crypto';
import { Journal } from '../../src/journal.ts';
import { BudgetGovernor, BudgetLedger, decide, reservationAmount } from '../../src/budget.ts';
import { defaultPolicy, validatePolicy, type BudgetPolicy } from '../../src/policy.ts';
import { tmpDir } from '../support/helpers.ts';

function budget(patch: Partial<BudgetPolicy> = {}): BudgetPolicy {
  return { ...defaultPolicy().budget, ...patch };
}

function governor(b: BudgetPolicy): { g: BudgetGovernor; journal: Journal; file: string; key: Buffer } {
  const file = path.join(tmpDir(), 'journal.jsonl');
  const key = randomBytes(32);
  const journal = Journal.open(file, key);
  return { g: new BudgetGovernor(journal, b), journal, file, key };
}

// ------------------------------------------------------------------ reservation amount

test('unmeasured reservation is max(10 x cap, cap + extra) per dimension', () => {
  // Defaults: $0.50 cap -> max($5, $1.50) = $5; 200k tokens -> max(2M, 300k) = 2M.
  assert.deepEqual(reservationAmount(budget()), { usd: 5, tokens: 2_000_000 });
  // Small cap: the additive floor dominates. $0.05 -> max($0.50, $1.05) = $1.05.
  assert.deepEqual(reservationAmount(budget({ invocation: { usd: 0.05, tokens: 5_000 } })), { usd: 1.05, tokens: 105_000 });
});

test('measured reservation is cap + largest measured turn', () => {
  const b = budget({ maxTurnCostUsd: 0.2, maxTurnTokens: 50_000 });
  assert.deepEqual(reservationAmount(b), { usd: 0.7, tokens: 250_000 });
});

// ------------------------------------------------------------------ admit / reject / defer

test('affordable work is admitted and its reservation is journaled before reserve() returns', () => {
  const { g, journal } = governor(budget());
  const d = g.reserve('T1#1', 'T1', 'E1');
  assert.equal(d.kind, 'admit');
  const recs = journal.ofType<{ id: string; usd: number; tokens: number }>('budget.reserve');
  assert.equal(recs.length, 1);
  assert.deepEqual({ id: recs[0]?.data.id, usd: recs[0]?.data.usd, tokens: recs[0]?.data.tokens }, { id: 'T1#1', usd: 5, tokens: 2_000_000 });
  assert.deepEqual(g.ledger.reserved('task', 'T1'), { usd: 5, tokens: 2_000_000 });
  assert.deepEqual(g.ledger.reserved('epic', 'E1'), { usd: 5, tokens: 2_000_000 });
});

test('unaffordable work is rejected and nothing is reserved', () => {
  const { g, journal } = governor(budget()); // task cap $10, R = $5
  assert.equal(g.reserve('T1#1', 'T1', 'E1').kind, 'admit');
  g.settle('T1#1', { usd: 5.5, tokens: 10_000 }); // spent 5.5; 5.5 + 5 > 10
  const before = journal.records().length;
  const d = g.reserve('T1#2', 'T1', 'E1');
  assert.equal(d.kind, 'reject');
  assert.match(d.kind === 'reject' ? d.reason : '', /task T1: spent \$5\.5000 \+ reservation \$5\.0000 exceeds cap \$10\.0000/);
  assert.equal(journal.records().length, before, 'a rejected reservation must not be journaled');
  assert.deepEqual(g.ledger.reserved('task', 'T1'), { usd: 0, tokens: 0 });
});

test('a reservation that lands exactly on the cap is admitted; one cent more is rejected', () => {
  const { g } = governor(budget());
  g.reserve('T1#1', 'T1', 'E1');
  g.settle('T1#1', { usd: 5, tokens: 1 }); // 5 + 5 = 10 = cap
  assert.equal(g.reserve('T1#2', 'T1', 'E1').kind, 'admit');
  g.settle('T1#2', { usd: 0.01, tokens: 1 }); // 5.01 + 5 > 10
  assert.equal(g.reserve('T1#3', 'T1', 'E1').kind, 'reject');
});

test('work that fits once running work settles is deferred, not rejected, and later admitted', () => {
  const b = budget({ epic: { usd: 12, tokens: 20_000_000 } });
  const { g } = governor(b);
  assert.equal(g.reserve('T1#1', 'T1', 'E1').kind, 'admit');
  assert.equal(g.reserve('T2#1', 'T2', 'E1').kind, 'admit');
  // epic: spent 0 + reserved 10 + R 5 = 15 > 12, but spent 0 + 5 <= 12, so it may fit later.
  const d = g.reserve('T3#1', 'T3', 'E1');
  assert.equal(d.kind, 'defer');
  assert.match(d.kind === 'defer' ? d.reason : '', /until running work settles/);
  g.settle('T1#1', { usd: 0.3, tokens: 5_000 }); // spent 0.3 + reserved 5 + 5 = 10.3 <= 12
  assert.equal(g.reserve('T3#1', 'T3', 'E1').kind, 'admit');
});

test('the epic cap rejects a task whose own cap would still allow it', () => {
  const b = budget({ epic: { usd: 12, tokens: 20_000_000 } });
  const { g } = governor(b);
  g.reserve('T1#1', 'T1', 'E1');
  g.settle('T1#1', { usd: 7.5, tokens: 1 }); // epic spent 7.5; 7.5 + 5 > 12
  const d = g.reserve('T2#1', 'T2', 'E1'); // T2's own cap is untouched
  assert.equal(d.kind, 'reject');
  assert.match(d.kind === 'reject' ? d.reason : '', /^epic E1/);
});

test('tokens are checked independently of USD', () => {
  const { g } = governor(budget());
  g.reserve('T1#1', 'T1', 'E1');
  g.settle('T1#1', { usd: 0.01, tokens: 2_000_001 }); // USD fine; 2,000,001 + 2,000,000 > 4M tokens
  const d = g.reserve('T1#2', 'T1', 'E1');
  assert.equal(d.kind, 'reject');
  assert.match(d.kind === 'reject' ? d.reason : '', /tokens exceeds cap 4000000 tokens/);
});

// ------------------------------------------------------------------ settlement

test('settling with a reported cost charges it and releases the reservation', () => {
  const { g } = governor(budget());
  g.reserve('T1#1', 'T1', 'E1');
  const s = g.settle('T1#1', { usd: 0.42, tokens: 1234 });
  assert.equal(s.basis, 'reported');
  assert.deepEqual(g.ledger.spent('task', 'T1'), { usd: 0.42, tokens: 1234 });
  assert.deepEqual(g.ledger.reserved('task', 'T1'), { usd: 0, tokens: 0 });
  assert.equal(g.ledger.isOpen('T1#1'), false);
  assert.throws(() => g.settle('T1#1', null), /no open reservation/);
});

test('an unknown cost (crash, kill) charges the full reservation', () => {
  const { g } = governor(budget());
  g.reserve('T1#1', 'T1', 'E1');
  const s = g.settle('T1#1', null);
  assert.equal(s.basis, 'unknown');
  assert.deepEqual(g.ledger.spent('task', 'T1'), { usd: 5, tokens: 2_000_000 });
});

test('a reservation proven never launched charges nothing', () => {
  const { g } = governor(budget());
  g.reserve('T1#1', 'T1', 'E1');
  const s = g.settle('T1#1', null, true);
  assert.equal(s.basis, 'not-started');
  assert.deepEqual(g.ledger.spent('task', 'T1'), { usd: 0, tokens: 0 });
});

test('an overshoot beyond the reservation is journaled and counts against later admissions', () => {
  const { g, journal } = governor(budget());
  g.reserve('T1#1', 'T1', 'E1');
  const s = g.settle('T1#1', { usd: 7, tokens: 2_500_000 }); // R was $5 / 2M
  assert.equal(s.overshootUsd, 2);
  assert.equal(s.overshootTokens, 500_000);
  const rec = journal.ofType<{ overshootUsd: number }>('budget.settle')[0];
  assert.equal(rec?.data.overshootUsd, 2);
  assert.equal(g.reserve('T1#2', 'T1', 'E1').kind, 'reject'); // 7 + 5 > 10
});

test('negative reported costs are refused', () => {
  const { g } = governor(budget());
  g.reserve('T1#1', 'T1', 'E1');
  assert.throws(() => g.settle('T1#1', { usd: -1, tokens: 0 }), /non-negative/);
});

// ------------------------------------------------------------------ durability

test('budget state is rebuilt identically from the journal after reopening', () => {
  const { g, file, key } = governor(budget());
  g.reserve('T1#1', 'T1', 'E1');
  g.settle('T1#1', { usd: 1.25, tokens: 9_000 });
  g.reserve('T2#1', 'T2', 'E1');
  const reopened = new BudgetGovernor(Journal.open(file, key), budget());
  assert.deepEqual(reopened.ledger.spent('epic', 'E1'), { usd: 1.25, tokens: 9_000 });
  assert.deepEqual(reopened.ledger.reserved('epic', 'E1'), { usd: 5, tokens: 2_000_000 });
  assert.deepEqual(reopened.ledger.openReservations().map((r) => r.id), ['T2#1']);
});

test('the ledger refuses duplicate reservations and settlement of unknown ids', () => {
  const l = new BudgetLedger();
  l.applyReserve({ id: 'a', taskId: 'T', epicId: 'E', usd: 1, tokens: 1 });
  assert.throws(() => l.applyReserve({ id: 'a', taskId: 'T', epicId: 'E', usd: 1, tokens: 1 }), /duplicate/);
  assert.throws(() => l.applySettle({ id: 'b', usd: 0, tokens: 0, basis: 'reported', overshootUsd: 0, overshootTokens: 0 }), /unknown/);
});

// ------------------------------------------------------------------ policy coherence

test('a policy whose single reservation exceeds the task cap is invalid', () => {
  const p = defaultPolicy();
  p.budget.task = { usd: 4.99, tokens: 4_000_000 };
  assert.throws(() => validatePolicy(p), /one reservation .* exceeds the task cap/);
  const q = defaultPolicy();
  q.budget.task = { usd: 10, tokens: 1_999_999 };
  assert.throws(() => validatePolicy(q), /exceeds the task cap/);
  assert.doesNotThrow(() => validatePolicy(defaultPolicy()));
});

// ------------------------------------------------------------------ property test

/** Small deterministic PRNG (mulberry32) so failures reproduce from the printed seed. */
function rng(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

test('property: over random caps and spend, every decision matches the reservation rule', () => {
  let admits = 0;
  let rejects = 0;
  let defers = 0;
  for (let seed = 1; seed <= 200; seed++) {
    const r = rng(seed);
    const inv = { usd: Math.round((0.01 + r() * 0.99) * 100) / 100, tokens: 1_000 + Math.floor(r() * 200_000) };
    const b = budget({ invocation: inv, maxTurnCostUsd: r() < 0.5 ? null : Math.round(r() * 100) / 100, maxTurnTokens: r() < 0.5 ? null : Math.floor(r() * 50_000) });
    const R = reservationAmount(b);
    b.task = { usd: Math.round(R.usd * (1 + r() * 3) * 100) / 100 + 0.01, tokens: Math.ceil(R.tokens * (1 + r() * 3)) };
    b.epic = { usd: Math.round(b.task.usd * (1 + r() * 4) * 100) / 100, tokens: Math.ceil(b.task.tokens * (1 + r() * 4)) };
    const { g } = governor(b);
    // Independent model of spent/reserved per scope.
    const spent = new Map<string, { usd: number; tokens: number }>();
    const reserved = new Map<string, { usd: number; tokens: number }>();
    const open: Array<{ id: string; task: string }> = [];
    const z = { usd: 0, tokens: 0 };
    const bump = (m: Map<string, typeof z>, k: string, a: typeof z, sign = 1): void => {
      const c = m.get(k) ?? z;
      m.set(k, { usd: c.usd + sign * a.usd, tokens: c.tokens + sign * a.tokens });
    };
    let n = 0;
    for (let step = 0; step < 40; step++) {
      if (open.length > 0 && r() < 0.5) {
        const [o] = open.splice(Math.floor(r() * open.length), 1);
        if (!o) continue;
        const kind = r();
        const cost = kind < 0.6 ? { usd: Math.round(r() * R.usd * 1.5 * 1e4) / 1e4, tokens: Math.floor(r() * R.tokens * 1.5) } : null;
        const notStarted = kind > 0.9;
        const s = g.settle(o.id, cost, notStarted);
        const charge = { usd: s.usd, tokens: s.tokens };
        for (const k of [`task:${o.task}`, 'epic:E']) {
          bump(reserved, k, R, -1);
          bump(spent, k, charge);
        }
        continue;
      }
      const task = `T${Math.floor(r() * 4)}`;
      const id = `${task}#${++n}`;
      const scopes = [{ k: `task:${task}`, cap: b.task }, { k: 'epic:E', cap: b.epic }];
      const fitsEver = scopes.every((s) => (spent.get(s.k) ?? z).usd + R.usd <= s.cap.usd + 1e-6 && (spent.get(s.k) ?? z).tokens + R.tokens <= s.cap.tokens);
      const fitsNow = scopes.every(
        (s) =>
          (spent.get(s.k) ?? z).usd + (reserved.get(s.k) ?? z).usd + R.usd <= s.cap.usd + 1e-6 &&
          (spent.get(s.k) ?? z).tokens + (reserved.get(s.k) ?? z).tokens + R.tokens <= s.cap.tokens,
      );
      const expected = !fitsEver ? 'reject' : !fitsNow ? 'defer' : 'admit';
      const d = g.reserve(id, task, 'E');
      assert.equal(d.kind, expected, `seed ${seed} step ${step} ${id}`);
      if (d.kind === 'admit') {
        admits++;
        open.push({ id, task });
        for (const s of scopes) bump(reserved, s.k, R);
        // Invariant: at admission, committed spend plus reservations fits every cap.
        for (const s of scopes) {
          const c = { usd: (spent.get(s.k) ?? z).usd + (reserved.get(s.k) ?? z).usd, tokens: (spent.get(s.k) ?? z).tokens + (reserved.get(s.k) ?? z).tokens };
          assert.ok(c.usd <= s.cap.usd + 1e-6 && c.tokens <= s.cap.tokens, `seed ${seed}: admitted past cap`);
        }
      } else if (d.kind === 'reject') rejects++;
      else defers++;
    }
    // The governor's view matches the model.
    for (const k of ['epic:E']) {
      const [scope, key] = k.split(':') as ['epic', string];
      assert.ok(Math.abs(g.ledger.spent(scope, key).usd - (spent.get(k) ?? z).usd) < 1e-4, `seed ${seed} spent`);
      assert.equal(g.ledger.spent(scope, key).tokens, (spent.get(k) ?? z).tokens, `seed ${seed} tokens`);
    }
  }
  // The generator must exercise all three outcomes, or the property proves little.
  assert.ok(admits > 100 && rejects > 50 && defers > 20, `admits ${admits} rejects ${rejects} defers ${defers}`);
});

test('decide() is pure: evaluating does not reserve', () => {
  const { g } = governor(budget());
  const d1 = decide(g.ledger, budget(), 'T1', 'E1');
  const d2 = g.evaluate('T1', 'E1');
  assert.equal(d1.kind, 'admit');
  assert.equal(d2.kind, 'admit');
  assert.deepEqual(g.ledger.openReservations(), []);
});
