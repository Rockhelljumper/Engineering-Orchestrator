import type { BudgetPolicy, Caps } from './policy.ts';
import type { Journal, JournalRecord } from './journal.ts';

/**
 * Budget governor: reservation semantics
 * --------------------------------------
 * Costs reported by Claude Code (`total_cost_usd`, token usage) are client-side estimates
 * and a single invocation can end above its `--max-budget-usd` cap (docs/07 §5). The governor
 * therefore never trusts a cap to hold during a run; it controls what may *start*.
 *
 * For every invocation it reserves R before launch:
 *   R.usd    = invocation.usd    + maxTurnCostUsd          (once measured, M2-6b)
 *            = max(factor * invocation.usd, invocation.usd + minExtraUsd)   (until then)
 *   R.tokens = the same rule on tokens.
 *
 * For each scope S in {task, epic}, with spent(S) = settled charges and reserved(S) = open
 * reservations, the decision is:
 *   reject  if spent(S) + R > cap(S) for any S   -> can never fit (spent only grows); the task
 *                                                  is blocked with a budget escalation
 *   defer   else if spent(S) + reserved(S) + R > cap(S) for any S
 *                                                -> may fit once running work settles; the task
 *                                                  stays ready and is retried later
 *   admit   otherwise                            -> the reservation is journaled before launch
 *
 * Settling a reservation releases R and charges:
 *   - the reported actual cost, when the run reported one (it may exceed R; the excess is
 *     journaled as an overshoot and later admissions see the higher `spent`);
 *   - the full R, when the cost is unknown (crash, kill, interrupted before an outcome);
 *   - nothing, when the journal proves the invocation never launched (reserved, then the
 *     controller died before journaling the attempt start).
 * Both dimensions (USD and tokens) are checked independently; either one can reject or defer.
 *
 * All state is derived from journal records ('budget.reserve' / 'budget.settle'), so it
 * survives crashes exactly as the journal does.
 */

export interface Amount {
  usd: number;
  tokens: number;
}

export type Scope = 'task' | 'epic';

export interface ReserveRecord {
  id: string;
  taskId: string;
  epicId: string;
  usd: number;
  tokens: number;
}

export interface SettleRecord {
  id: string;
  usd: number;
  tokens: number;
  basis: 'reported' | 'unknown' | 'not-started';
  overshootUsd: number;
  overshootTokens: number;
}

export interface ScopeFigures {
  scope: Scope;
  key: string;
  cap: Caps;
  spent: Amount;
  reserved: Amount;
}

export type Decision =
  | { kind: 'admit'; reservation: Amount; figures: ScopeFigures[] }
  | { kind: 'defer'; reservation: Amount; figures: ScopeFigures[]; reason: string }
  | { kind: 'reject'; reservation: Amount; figures: ScopeFigures[]; reason: string };

export function reservationAmount(b: BudgetPolicy): Amount {
  const usd =
    b.maxTurnCostUsd !== null
      ? b.invocation.usd + b.maxTurnCostUsd
      : Math.max(b.unmeasuredFactor * b.invocation.usd, b.invocation.usd + b.unmeasuredMinExtraUsd);
  const tokens =
    b.maxTurnTokens !== null
      ? b.invocation.tokens + b.maxTurnTokens
      : Math.max(b.unmeasuredFactor * b.invocation.tokens, b.invocation.tokens + b.unmeasuredMinExtraTokens);
  return { usd: round(usd), tokens: Math.ceil(tokens) };
}

/** Budget state folded from journal records. */
export class BudgetLedger {
  private readonly open = new Map<string, ReserveRecord>();
  private readonly spentBy = new Map<string, Amount>();
  private readonly reservedBy = new Map<string, Amount>();
  private readonly settled = new Set<string>();

  static fromRecords(records: readonly JournalRecord[]): BudgetLedger {
    const l = new BudgetLedger();
    for (const r of records) {
      if (r.type === 'budget.reserve') l.applyReserve(r.data as ReserveRecord);
      else if (r.type === 'budget.settle') l.applySettle(r.data as SettleRecord);
    }
    return l;
  }

  applyReserve(r: ReserveRecord): void {
    if (this.open.has(r.id) || this.settled.has(r.id)) throw new Error(`duplicate reservation ${r.id}`);
    this.open.set(r.id, r);
    for (const k of keys(r)) add(this.reservedBy, k, r);
  }

  applySettle(s: SettleRecord): void {
    const r = this.open.get(s.id);
    if (!r) throw new Error(`settle of unknown or already settled reservation ${s.id}`);
    this.open.delete(s.id);
    this.settled.add(s.id);
    for (const k of keys(r)) {
      add(this.reservedBy, k, { usd: -r.usd, tokens: -r.tokens });
      add(this.spentBy, k, s);
    }
  }

  openReservations(): ReserveRecord[] {
    return [...this.open.values()];
  }

  isOpen(id: string): boolean {
    return this.open.has(id);
  }

  spent(scope: Scope, key: string): Amount {
    return get(this.spentBy, `${scope}:${key}`);
  }

  reserved(scope: Scope, key: string): Amount {
    return get(this.reservedBy, `${scope}:${key}`);
  }
}

/** Pure admission decision. */
export function decide(ledger: BudgetLedger, b: BudgetPolicy, taskId: string, epicId: string): Decision {
  const R = reservationAmount(b);
  const figures: ScopeFigures[] = [
    { scope: 'task', key: taskId, cap: b.task, spent: ledger.spent('task', taskId), reserved: ledger.reserved('task', taskId) },
    { scope: 'epic', key: epicId, cap: b.epic, spent: ledger.spent('epic', epicId), reserved: ledger.reserved('epic', epicId) },
  ];
  for (const f of figures) {
    const dim = exceeds(f.spent, R, f.cap);
    if (dim) {
      return {
        kind: 'reject',
        reservation: R,
        figures,
        reason: `${f.scope} ${f.key}: spent ${fmt(f.spent, dim)} + reservation ${fmt(R, dim)} exceeds cap ${fmt(f.cap, dim)}`,
      };
    }
  }
  for (const f of figures) {
    const committed = { usd: f.spent.usd + f.reserved.usd, tokens: f.spent.tokens + f.reserved.tokens };
    const dim = exceeds(committed, R, f.cap);
    if (dim) {
      return {
        kind: 'defer',
        reservation: R,
        figures,
        reason: `${f.scope} ${f.key}: spent+reserved ${fmt(committed, dim)} + reservation ${fmt(R, dim)} exceeds cap ${fmt(f.cap, dim)} until running work settles`,
      };
    }
  }
  return { kind: 'admit', reservation: R, figures };
}

/** Journal-backed governor used by the scheduler. */
export class BudgetGovernor {
  private readonly journal: Journal;
  private readonly policy: BudgetPolicy;
  readonly ledger: BudgetLedger;

  constructor(journal: Journal, policy: BudgetPolicy) {
    this.journal = journal;
    this.policy = policy;
    this.ledger = BudgetLedger.fromRecords(journal.records());
  }

  evaluate(taskId: string, epicId: string): Decision {
    return decide(this.ledger, this.policy, taskId, epicId);
  }

  /** Evaluate and, if admitted, journal the reservation before returning. */
  reserve(reservationId: string, taskId: string, epicId: string): Decision {
    const d = this.evaluate(taskId, epicId);
    if (d.kind === 'admit') {
      const rec: ReserveRecord = { id: reservationId, taskId, epicId, usd: d.reservation.usd, tokens: d.reservation.tokens };
      this.journal.append('budget.reserve', rec);
      this.ledger.applyReserve(rec);
    }
    return d;
  }

  /**
   * Settle with the reported cost, with the full reservation when `reported` is null, or with
   * zero when `notStarted` is set (only valid when the journal shows no attempt start).
   */
  settle(reservationId: string, reported: Amount | null, notStarted = false): SettleRecord {
    const r = this.ledger.openReservations().find((x) => x.id === reservationId);
    if (!r) throw new Error(`no open reservation ${reservationId}`);
    const charge = notStarted ? { usd: 0, tokens: 0 } : (reported ?? { usd: r.usd, tokens: r.tokens });
    if (!(charge.usd >= 0) || !(charge.tokens >= 0)) throw new Error('reported cost must be non-negative');
    const rec: SettleRecord = {
      id: reservationId,
      usd: round(charge.usd),
      tokens: Math.ceil(charge.tokens),
      basis: notStarted ? 'not-started' : reported ? 'reported' : 'unknown',
      overshootUsd: round(Math.max(0, charge.usd - r.usd)),
      overshootTokens: Math.max(0, Math.ceil(charge.tokens) - r.tokens),
    };
    this.journal.append('budget.settle', rec);
    this.ledger.applySettle(rec);
    return rec;
  }
}

function exceeds(base: Amount, add: Amount, cap: Caps): 'usd' | 'tokens' | null {
  if (round(base.usd + add.usd) > cap.usd + 1e-9) return 'usd';
  if (base.tokens + add.tokens > cap.tokens) return 'tokens';
  return null;
}

function fmt(a: Amount | Caps, dim: 'usd' | 'tokens'): string {
  return dim === 'usd' ? `$${a.usd.toFixed(4)}` : `${a.tokens} tokens`;
}

function keys(r: { taskId: string; epicId: string }): string[] {
  return [`task:${r.taskId}`, `epic:${r.epicId}`];
}

function add(m: Map<string, Amount>, k: string, a: { usd: number; tokens: number }): void {
  const cur = m.get(k) ?? { usd: 0, tokens: 0 };
  m.set(k, { usd: round(cur.usd + a.usd), tokens: cur.tokens + a.tokens });
}

function get(m: Map<string, Amount>, k: string): Amount {
  return m.get(k) ?? { usd: 0, tokens: 0 };
}

function round(x: number): number {
  return Math.round(x * 1e6) / 1e6;
}
