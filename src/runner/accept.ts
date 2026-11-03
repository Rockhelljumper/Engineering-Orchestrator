import { validate, type Schema } from '../schema.ts';
import type { ReportedCost, RunResult } from './types.ts';

/**
 * The runner's result is untrusted: the worker behind it may be compromised (threat T5). The
 * controller journals only what passes this strict schema. Verdict fields a runner supplies
 * anyway are dropped and named in the journal; anything else unexpected rejects the result,
 * which is then journaled as an infra failure (its reported cost still counts, when valid).
 *
 * Reported cost is worker-controlled and untrusted. It is accepted as reported whenever it is
 * a well-formed amount within MAX_REPORTED_USD / MAX_REPORTED_TOKENS (anything else is charged
 * as unknown, i.e. the full reservation), so a compromised worker can under-report, down to
 * {usd: 0, tokens: 0}, on the completed and on the rejected path alike. The controller cannot
 * check it; only the provider-side spend limit on the worker's API key bounds real spend.
 */

/** Fields an older runner (M1) put in its result. The controller never trusts them now. */
export const VERDICT_FIELDS = ['verification', 'review'] as const;

/**
 * Upper bounds on a reported cost. Far beyond any real invocation, and small enough that the
 * budget ledger's arithmetic (rounding to 1e-6 USD, summing per task and epic) stays finite
 * and exact: a larger figure is not a cost, it is charged as unknown.
 */
export const MAX_REPORTED_USD = 1e9;
export const MAX_REPORTED_TOKENS = Number.MAX_SAFE_INTEGER;

/** Size limits on what a runner may report; a result over any of them is rejected. */
export const LIMITS = {
  /** The whole result, serialised as JSON (UTF-8 bytes). */
  totalBytes: 64 * 1024,
  summaryChars: 4096,
  noteChars: 4096,
  reasonChars: 4096,
  artifacts: 256,
  artifactChars: 1024,
} as const;

const costSchema: Schema = {
  type: ['object', 'null'],
  required: ['usd', 'tokens'],
  additionalProperties: false,
  properties: { usd: { type: 'number', minimum: 0, maximum: MAX_REPORTED_USD }, tokens: { type: 'integer', minimum: 0, maximum: MAX_REPORTED_TOKENS } },
};

const completedSchema: Schema = {
  type: 'object',
  required: ['kind', 'cost', 'summary'],
  additionalProperties: false,
  properties: {
    kind: { const: 'completed' },
    cost: costSchema,
    summary: { type: 'string', maxLength: LIMITS.summaryChars },
    observations: {
      type: 'object',
      additionalProperties: false,
      properties: {
        exitCode: { type: ['integer', 'null'] },
        artifacts: { type: 'array', maxItems: LIMITS.artifacts, items: { type: 'string', maxLength: LIMITS.artifactChars } },
        note: { type: 'string', maxLength: LIMITS.noteChars },
      },
    },
  },
};

const infraSchema: Schema = {
  type: 'object',
  required: ['kind', 'reason', 'cost'],
  additionalProperties: false,
  properties: { kind: { const: 'infra' }, reason: { type: 'string', maxLength: LIMITS.reasonChars }, cost: costSchema },
};

export interface AcceptedRunResult {
  result: RunResult;
  /** Verdict fields the runner supplied; dropped, never used. */
  ignoredFields?: string[];
  /** A reported cost that was not a valid amount; charged as unknown instead. */
  invalidCost?: string;
  /** Why the result was rejected and replaced by an infra failure. */
  rejected?: string;
}

/**
 * A cost the budget can charge as reported: finite USD in [0, MAX_REPORTED_USD] and whole
 * tokens in [0, MAX_REPORTED_TOKENS]. Used on journaled costs too (costOf in the controller),
 * so a record written before these bounds is charged as unknown rather than as an overflow.
 */
export function validCost(c: unknown): c is ReportedCost {
  const x = c as { usd?: unknown; tokens?: unknown } | null;
  return (
    typeof x === 'object' && x !== null &&
    typeof x.usd === 'number' && Number.isFinite(x.usd) && x.usd >= 0 && x.usd <= MAX_REPORTED_USD &&
    typeof x.tokens === 'number' && Number.isSafeInteger(x.tokens) && x.tokens >= 0 && x.tokens <= MAX_REPORTED_TOKENS
  );
}

export function acceptRunResult(raw: unknown): AcceptedRunResult {
  // A plain-data copy: getters run once, prototypes and functions are dropped, and nothing the
  // runner holds a reference to can change what is validated and journaled.
  let copy: unknown;
  let bytes: number;
  try {
    const text = JSON.stringify(raw) ?? 'null';
    bytes = Buffer.byteLength(text, 'utf8');
    copy = JSON.parse(text);
  } catch (err) {
    return { result: { kind: 'infra', reason: `runner result rejected: not serialisable (${(err as Error).message})`, cost: null }, rejected: 'not serialisable' };
  }
  if (bytes > LIMITS.totalBytes) {
    // Nothing of an oversized result is journaled but its cost, when that is a valid amount.
    const c = (copy as { cost?: unknown } | null)?.cost;
    const why = `result is ${bytes} bytes, over the ${LIMITS.totalBytes}-byte limit`;
    return { result: { kind: 'infra', reason: `runner result rejected: ${why}`, cost: validCost(c) ? { usd: c.usd, tokens: c.tokens } : null }, rejected: why };
  }
  if (typeof copy !== 'object' || copy === null || Array.isArray(copy)) {
    return { result: { kind: 'infra', reason: 'runner result rejected: not an object', cost: null }, rejected: 'not an object' };
  }
  const obj = copy as Record<string, unknown>;
  const out: Omit<AcceptedRunResult, 'result'> = {};
  if ('cost' in obj && obj['cost'] !== null && !validCost(obj['cost'])) {
    out.invalidCost = JSON.stringify(obj['cost']);
    obj['cost'] = null;
  }
  const cost = validCost(obj['cost']) ? { usd: obj['cost'].usd, tokens: obj['cost'].tokens } : null;
  if (obj['kind'] === 'completed') {
    const ignored = VERDICT_FIELDS.filter((f) => Object.hasOwn(obj, f));
    for (const f of ignored) delete obj[f];
    if (ignored.length > 0) out.ignoredFields = [...ignored];
  }
  const schema = obj['kind'] === 'completed' ? completedSchema : obj['kind'] === 'infra' ? infraSchema : undefined;
  const errors = schema ? validate(schema, obj) : [{ path: '$.kind', message: `must be "completed" or "infra", got ${JSON.stringify(obj['kind'])}` }];
  if (errors.length > 0) {
    const why = errors.map((e) => `${e.path} ${e.message}`).join('; ');
    return { ...out, result: { kind: 'infra', reason: `runner result rejected: ${why}`, cost }, rejected: why };
  }
  return { ...out, result: obj as unknown as RunResult };
}
