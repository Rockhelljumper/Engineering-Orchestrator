import * as fs from 'node:fs';

/**
 * Progress records for long-running tests (crash recovery, claim races), so a reader can tell
 * a slow suite from a stalled one without interrupting it. Each call appends one JSON line to
 * EO_PROGRESS_FILE, or writes it to stderr when that is unset:
 *
 *   {"ts", "test", "scenario", "completed", "total", "activity", "elapsedS"}
 *
 * `activity` is the last meaningful step (a crash injected, a recovery finished, a round
 * checked), and `ts` is when it happened. `scripts/test-progress.ts` summarises the file.
 * Reporting is diagnostic only: it never affects a test's result.
 */
export class Progress {
  private readonly started = Date.now();
  private readonly file = process.env['EO_PROGRESS_FILE'] || undefined;
  private readonly test: string;
  private readonly total: number;
  private scenario = '';
  private completed = 0;

  constructor(test: string, total: number) {
    this.test = test;
    this.total = total;
    this.emit('started');
  }

  /** Begin scenario `name` (one boundary, seed or round). */
  begin(name: string): void {
    this.scenario = name;
    this.emit('begin');
  }

  /** Record a meaningful step inside the current scenario. */
  step(activity: string): void {
    this.emit(activity);
  }

  /** The current scenario passed its checks. */
  done(): void {
    this.completed++;
    this.emit('completed');
  }

  private emit(activity: string): void {
    const line = JSON.stringify({
      ts: new Date().toISOString(),
      test: this.test,
      scenario: this.scenario,
      completed: this.completed,
      total: this.total,
      activity,
      elapsedS: Math.round((Date.now() - this.started) / 1000),
    });
    try {
      if (this.file) fs.appendFileSync(this.file, line + '\n');
      else process.stderr.write(`progress ${line}\n`);
    } catch {
      // Diagnostic only.
    }
  }
}
