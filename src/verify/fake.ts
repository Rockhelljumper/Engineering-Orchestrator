import * as fs from 'node:fs';
import { appendLineDurable } from '../util/fsx.ts';
import { assertValid, type Schema } from '../schema.ts';
import type { FakeScript } from '../runner/fake.ts';
import type { JudgeContext, Judges, Reviewer, ReviewVerdict, VerificationVerdict, Verifier } from './types.ts';

/**
 * Scripted controller-side judges, for deterministic tests and failure simulation, in the
 * manner of FakeRunner: behaviour per task and attempt comes from a script, and attempts
 * beyond the script use `default`. They stand in for the M3 verifier and reviewer.
 */
export interface VerifierStep {
  verdict: 'pass' | 'fail';
  signature?: string;
}

export interface ReviewerStep {
  verdict: 'approve' | 'changes';
}

export interface FakeJudgeScript<S> {
  /** File that receives one line per call: {stage, taskId, attempt}. */
  log?: string;
  default: S;
  tasks?: Record<string, S[]>;
}

const judgeScriptSchema = (step: Schema): Schema => ({
  type: 'object',
  required: ['default'],
  additionalProperties: false,
  properties: { log: { type: 'string' }, default: step, tasks: { type: 'object', additionalProperties: { type: 'array', items: step } } },
});

const verifierStep: Schema = {
  type: 'object',
  required: ['verdict'],
  additionalProperties: false,
  properties: { verdict: { enum: ['pass', 'fail'] }, signature: { type: 'string' } },
};
const reviewerStep: Schema = { type: 'object', required: ['verdict'], additionalProperties: false, properties: { verdict: { enum: ['approve', 'changes'] } } };

function stepFor<S>(script: FakeJudgeScript<S>, taskId: string, attempt: number): S {
  return script.tasks?.[taskId]?.[attempt - 1] ?? script.default;
}

function logCall(file: string | undefined, stage: string, ctx: JudgeContext): void {
  if (file) appendLineDurable(file, JSON.stringify({ stage, taskId: ctx.taskId, attempt: ctx.attempt, pid: process.pid }));
}

export class FakeVerifier implements Verifier {
  readonly kind = 'fake';
  private readonly script: FakeJudgeScript<VerifierStep>;

  constructor(script: FakeJudgeScript<VerifierStep>) {
    assertValid(judgeScriptSchema(verifierStep), script, 'fake verifier script');
    this.script = script;
  }

  async verify(ctx: JudgeContext): Promise<VerificationVerdict> {
    logCall(this.script.log, 'verification', ctx);
    const s = stepFor(this.script, ctx.taskId, ctx.attempt);
    return { taskId: ctx.taskId, attempt: ctx.attempt, verdict: s.verdict, signature: s.verdict === 'fail' ? (s.signature ?? 'scripted-failure') : null };
  }
}

export class FakeReviewer implements Reviewer {
  readonly kind = 'fake';
  private readonly script: FakeJudgeScript<ReviewerStep>;

  constructor(script: FakeJudgeScript<ReviewerStep>) {
    assertValid(judgeScriptSchema(reviewerStep), script, 'fake reviewer script');
    this.script = script;
  }

  async review(ctx: JudgeContext): Promise<ReviewVerdict> {
    logCall(this.script.log, 'review', ctx);
    return { taskId: ctx.taskId, attempt: ctx.attempt, verdict: stepFor(this.script, ctx.taskId, ctx.attempt).verdict };
  }
}

/**
 * The fake judges for a FakeRunner scenario script, so the scenario names (pass, verify-fail,
 * review-fail, crash, hang) keep meaning what they meant when the runner returned verdicts:
 * verify-fail scripts the verifier to fail with the step's signature, review-fail scripts the
 * reviewer to request changes, everything else passes and approves. The runner itself only
 * reports that it ran.
 */
export function fakeJudgesFor(script: FakeScript): Judges {
  const v = (s: FakeScript['default']): VerifierStep => (s.behaviour === 'verify-fail' ? { verdict: 'fail', signature: s.signature ?? 'scripted-failure' } : { verdict: 'pass' });
  const r = (s: FakeScript['default']): ReviewerStep => ({ verdict: s.behaviour === 'review-fail' ? 'changes' : 'approve' });
  const tasks = Object.entries(script.tasks ?? {});
  const log = script.verdictLog !== undefined ? { log: script.verdictLog } : {};
  return {
    verifier: new FakeVerifier({ ...log, default: v(script.default), tasks: Object.fromEntries(tasks.map(([id, steps]) => [id, steps.map(v)])) }),
    reviewer: new FakeReviewer({ ...log, default: r(script.default), tasks: Object.fromEntries(tasks.map(([id, steps]) => [id, steps.map(r)])) }),
  };
}

/** Read a verdict log written by the fake judges. */
export function readVerdictLog(file: string): Array<{ stage: string; taskId: string; attempt: number }> {
  if (!fs.existsSync(file)) return [];
  return fs
    .readFileSync(file, 'utf8')
    .split('\n')
    .filter(Boolean)
    .map((l) => JSON.parse(l) as { stage: string; taskId: string; attempt: number });
}
