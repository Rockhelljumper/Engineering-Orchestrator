import type { RunResult } from '../runner/types.ts';

/**
 * Controller-owned judges of a worker's attempt. The controller calls them itself after the
 * run has ended and its observations are journaled; their verdicts are journaled as
 * controller records (verify.verdict, review.verdict) bound to the task, the attempt and the
 * attempt.end record they judge. A worker never supplies a verdict (threat T5).
 *
 * M2 ships only scripted fakes (src/verify/fake.ts); M3 adds the real verifier and reviewer.
 */
export interface JudgeContext {
  taskId: string;
  attempt: number;
  /** The run's journaled, schema-checked observations (untrusted worker claims). */
  result: Extract<RunResult, { kind: 'completed' }>;
  /** Aborted by the controller on timeout. */
  signal: AbortSignal;
}

/**
 * Every verdict names the task and attempt it judges. The controller rejects one that names
 * anything else (a replayed or misrouted verdict) instead of applying it.
 */
export interface VerificationVerdict {
  taskId: string;
  attempt: number;
  verdict: 'pass' | 'fail';
  /** Failure signature (for repeated-failure detection); null on a pass. */
  signature: string | null;
}

export interface ReviewVerdict {
  taskId: string;
  attempt: number;
  verdict: 'approve' | 'changes';
}

export interface Verifier {
  readonly kind: string;
  verify(ctx: JudgeContext): Promise<VerificationVerdict>;
}

export interface Reviewer {
  readonly kind: string;
  review(ctx: JudgeContext): Promise<ReviewVerdict>;
}

export interface Judges {
  verifier: Verifier;
  reviewer: Reviewer;
}

export type VerdictStage = 'verification' | 'review';

/** Journal record types for the two controller-produced verdicts. */
export const VERDICT_RECORD: Readonly<Record<VerdictStage, string>> = { verification: 'verify.verdict', review: 'review.verdict' };

/** A controller-produced verdict, as journaled. */
export interface VerdictRecord {
  stage: VerdictStage;
  taskId: string;
  attempt: number;
  /** Journal seq of the attempt.end record this verdict judges. */
  endSeq: number;
  verdict: 'pass' | 'fail' | 'approve' | 'changes';
  /** Verification failures only. */
  signature: string | null;
  /** Always "controller": the judge ran on the controller side, never in the worker. */
  source: 'controller';
  /** The judge's kind (e.g. "fake"). */
  judge: string;
}

/** A verdict the controller refused to apply; the task is escalated instead. */
export interface VerdictRejectedRecord {
  stage: VerdictStage;
  taskId: string;
  attempt: number;
  endSeq: number;
  judge: string;
  category: 'infra' | 'evidence';
  reason: string;
}
