export interface RunRequest {
  taskId: string;
  attempt: number;
  role: 'implementer';
  /** Aborted by the controller on timeout or shutdown. */
  signal: AbortSignal;
}

export interface ReportedCost {
  usd: number;
  tokens: number;
}

/**
 * What a worker run produced. In M1 the fake runner also supplies the verification and review
 * verdicts that M3's real verifier and reviewer will produce; the controller treats them as
 * scripted stand-ins and records them as such in evidence.
 */
export type RunResult =
  | {
      kind: 'completed';
      cost: ReportedCost | null;
      verification: { verdict: 'pass' | 'fail'; signature: string | null };
      review: { verdict: 'approve' | 'changes' };
      summary: string;
    }
  | { kind: 'infra'; reason: string; cost: ReportedCost | null };

export interface Runner {
  readonly kind: string;
  run(req: RunRequest): Promise<RunResult>;
}
