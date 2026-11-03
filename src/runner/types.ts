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
 * What the worker reports it observed while executing: never a judgement of its own work.
 * The controller treats all of it as untrusted input (see acceptRunResult).
 */
export interface RunObservations {
  /** Exit status of the worker's own process, when it has one. */
  exitCode?: number | null;
  /** References to artifacts the worker says it produced (paths or ids, not contents). */
  artifacts?: string[];
  /** Free-form note from the worker. */
  note?: string;
}

/**
 * What a worker run produced: execution observations only. Verification and review verdicts
 * are produced by the controller's own Verifier and Reviewer after the run (src/verify), so a
 * worker cannot grade itself (threat T5).
 */
export type RunResult =
  | {
      kind: 'completed';
      cost: ReportedCost | null;
      summary: string;
      observations?: RunObservations;
    }
  | { kind: 'infra'; reason: string; cost: ReportedCost | null };

export interface Runner {
  readonly kind: string;
  run(req: RunRequest): Promise<RunResult>;
}
