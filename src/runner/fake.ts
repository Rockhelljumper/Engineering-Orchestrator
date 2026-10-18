import * as fs from 'node:fs';
import { appendLineDurable } from '../util/fsx.ts';
import { assertValid, type Schema } from '../schema.ts';
import type { ReportedCost, RunRequest, RunResult, Runner } from './types.ts';

/**
 * Scripted stand-in for a Claude worker, used for deterministic tests and failure simulation.
 * Behaviour per task and attempt comes from a script; attempts beyond the script use `default`.
 *
 *   pass         completes; verification passes; review approves
 *   verify-fail  completes; verification fails with `signature`
 *   review-fail  completes; verification passes; review requests changes
 *   crash        throws an infra failure (worker died)
 *   hang         never finishes until aborted (timeout path)
 */
export type Behaviour = 'pass' | 'verify-fail' | 'review-fail' | 'crash' | 'hang';

export interface AttemptScript {
  behaviour: Behaviour;
  costUsd?: number;
  tokens?: number;
  /** Report no cost at all (cost unknown). */
  noCost?: boolean;
  delayMs?: number;
  signature?: string;
}

export interface FakeScript {
  /** File that receives one line per execution, written before the work starts. */
  execLog?: string;
  default: AttemptScript;
  tasks?: Record<string, AttemptScript[]>;
}

const attemptSchema: Schema = {
  type: 'object',
  required: ['behaviour'],
  additionalProperties: false,
  properties: {
    behaviour: { enum: ['pass', 'verify-fail', 'review-fail', 'crash', 'hang'] },
    costUsd: { type: 'number', minimum: 0 },
    tokens: { type: 'integer', minimum: 0 },
    noCost: { type: 'boolean' },
    delayMs: { type: 'integer', minimum: 0 },
    signature: { type: 'string' },
  },
};

export const fakeScriptSchema: Schema = {
  type: 'object',
  required: ['default'],
  additionalProperties: false,
  properties: {
    execLog: { type: 'string' },
    default: attemptSchema,
    tasks: { type: 'object', additionalProperties: { type: 'array', items: attemptSchema } },
  },
};

export class FakeRunner implements Runner {
  readonly kind = 'fake';
  private readonly script: FakeScript;

  constructor(script: FakeScript) {
    assertValid(fakeScriptSchema, script, 'fake runner script');
    this.script = script;
  }

  static fromFile(file: string): FakeRunner {
    return new FakeRunner(JSON.parse(fs.readFileSync(file, 'utf8')) as FakeScript);
  }

  scriptFor(taskId: string, attempt: number): AttemptScript {
    return this.script.tasks?.[taskId]?.[attempt - 1] ?? this.script.default;
  }

  async run(req: RunRequest): Promise<RunResult> {
    const s = this.scriptFor(req.taskId, req.attempt);
    if (this.script.execLog) {
      appendLineDurable(this.script.execLog, JSON.stringify({ taskId: req.taskId, attempt: req.attempt, pid: process.pid }));
    }
    if (s.delayMs) await sleep(s.delayMs, req.signal);
    const cost: ReportedCost | null = s.noCost ? null : { usd: s.costUsd ?? 0.01, tokens: s.tokens ?? 1000 };
    switch (s.behaviour) {
      case 'hang':
        await sleep(Number.MAX_SAFE_INTEGER, req.signal);
        return { kind: 'infra', reason: 'unreachable', cost: null };
      case 'crash':
        return { kind: 'infra', reason: 'worker crashed (scripted)', cost };
      case 'pass':
        return { kind: 'completed', cost, verification: { verdict: 'pass', signature: null }, review: { verdict: 'approve' }, summary: 'scripted pass' };
      case 'verify-fail':
        return {
          kind: 'completed',
          cost,
          verification: { verdict: 'fail', signature: s.signature ?? 'scripted-failure' },
          review: { verdict: 'approve' },
          summary: 'scripted verification failure',
        };
      case 'review-fail':
        return { kind: 'completed', cost, verification: { verdict: 'pass', signature: null }, review: { verdict: 'changes' }, summary: 'scripted review rejection' };
    }
  }
}

function sleep(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal.aborted) return reject(new AbortError());
    const t = setTimeout(resolve, Math.min(ms, 2_147_000_000));
    signal.addEventListener(
      'abort',
      () => {
        clearTimeout(t);
        reject(new AbortError());
      },
      { once: true },
    );
  });
}

export class AbortError extends Error {
  constructor() {
    super('aborted');
  }
}
