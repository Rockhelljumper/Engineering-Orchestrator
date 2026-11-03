import { validate, type Schema } from '../schema.ts';
import type { ReportedCost, RunResult } from './types.ts';

/**
 * The runner's result is untrusted: the worker behind it may be compromised (threat T5). The
 * controller journals only what passes this strict schema. Verdict fields a runner supplies
 * anyway are dropped and named in the journal; anything else unexpected rejects the result,
 * which is then journaled as an infra failure (its reported cost still counts, when valid).
 */

/** Fields an older runner (M1) put in its result. The controller never trusts them now. */
export const VERDICT_FIELDS = ['verification', 'review'] as const;

const costSchema: Schema = {
  type: ['object', 'null'],
  required: ['usd', 'tokens'],
  additionalProperties: false,
  properties: { usd: { type: 'number', minimum: 0 }, tokens: { type: 'integer', minimum: 0 } },
};

const completedSchema: Schema = {
  type: 'object',
  required: ['kind', 'cost', 'summary'],
  additionalProperties: false,
  properties: {
    kind: { const: 'completed' },
    cost: costSchema,
    summary: { type: 'string' },
    observations: {
      type: 'object',
      additionalProperties: false,
      properties: {
        exitCode: { type: ['integer', 'null'] },
        artifacts: { type: 'array', items: { type: 'string' } },
        note: { type: 'string' },
      },
    },
  },
};

const infraSchema: Schema = {
  type: 'object',
  required: ['kind', 'reason', 'cost'],
  additionalProperties: false,
  properties: { kind: { const: 'infra' }, reason: { type: 'string' }, cost: costSchema },
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

function validCost(c: unknown): c is ReportedCost {
  const x = c as { usd?: unknown; tokens?: unknown } | null;
  return (
    typeof x === 'object' && x !== null && typeof x.usd === 'number' && Number.isFinite(x.usd) && x.usd >= 0 &&
    typeof x.tokens === 'number' && Number.isInteger(x.tokens) && x.tokens >= 0
  );
}

export function acceptRunResult(raw: unknown): AcceptedRunResult {
  // A plain-data copy: getters run once, prototypes and functions are dropped, and nothing the
  // runner holds a reference to can change what is validated and journaled.
  let copy: unknown;
  try {
    copy = JSON.parse(JSON.stringify(raw) ?? 'null');
  } catch (err) {
    return { result: { kind: 'infra', reason: `runner result rejected: not serialisable (${(err as Error).message})`, cost: null }, rejected: 'not serialisable' };
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
