import { validate, type Schema } from '../schema.ts';
import type { VerdictStage } from './types.ts';

const bound = { taskId: { type: 'string', minLength: 1 }, attempt: { type: 'integer', minimum: 1 } } satisfies Record<string, Schema>;

const verificationSchema: Schema = {
  type: 'object',
  required: ['taskId', 'attempt', 'verdict', 'signature'],
  additionalProperties: false,
  properties: { ...bound, verdict: { enum: ['pass', 'fail'] }, signature: { type: ['string', 'null'] } },
};

const reviewSchema: Schema = {
  type: 'object',
  required: ['taskId', 'attempt', 'verdict'],
  additionalProperties: false,
  properties: { ...bound, verdict: { enum: ['approve', 'changes'] } },
};

export type CheckedVerdict = { ok: true; verdict: 'pass' | 'fail' | 'approve' | 'changes'; signature: string | null } | { ok: false; problem: string };

/**
 * Check what a verifier or reviewer returned before the controller journals it: a strict
 * schema, and the task and attempt it names must be the ones it was asked about. A verdict
 * for another attempt or task (replayed, cached or misrouted) is rejected, never applied.
 */
export function checkVerdict(stage: VerdictStage, raw: unknown, taskId: string, attempt: number): CheckedVerdict {
  let v: unknown;
  try {
    v = JSON.parse(JSON.stringify(raw) ?? 'null');
  } catch (err) {
    return { ok: false, problem: `${stage} verdict is not serialisable (${(err as Error).message})` };
  }
  const errors = validate(stage === 'verification' ? verificationSchema : reviewSchema, v);
  if (errors.length > 0) return { ok: false, problem: `${stage} verdict is invalid: ${errors.map((e) => `${e.path} ${e.message}`).join('; ')}` };
  const o = v as { taskId: string; attempt: number; verdict: 'pass' | 'fail' | 'approve' | 'changes'; signature?: string | null };
  if (o.taskId !== taskId || o.attempt !== attempt) {
    return { ok: false, problem: `${stage} verdict is for ${o.taskId}#${o.attempt}, not ${taskId}#${attempt} (replayed or misrouted)` };
  }
  return { ok: true, verdict: o.verdict, signature: o.verdict === 'fail' ? (o.signature ?? null) : null };
}
