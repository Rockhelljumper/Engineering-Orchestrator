import type { TaskState } from '../states.ts';

export interface Claim {
  owner: string;
  /** Epoch milliseconds. A claim past this time is expired and may be reclaimed. */
  leaseExpiresAt: number;
}

export interface TaskNote {
  ts: string;
  text: string;
}

export interface TaskCounters {
  /** Implementation attempts started (attempt numbers are 1-based). */
  attempt: number;
  /** Correction attempts consumed (verification/review failures). */
  correctionFailures: number;
  /** Infra retries consumed (crash, kill, timeout, interruption). */
  infraFailures: number;
  /** Normalised signature of the last correction failure and how many times in a row it repeated. */
  lastFailureSignature: string | null;
  repeatCount: number;
}

export interface TaskRecord extends TaskCounters {
  id: string;
  epicId: string;
  title: string;
  deps: string[];
  state: TaskState;
  claim: Claim | null;
  notes: TaskNote[];
}

export interface NewTask {
  id: string;
  epicId: string;
  title: string;
  deps: string[];
}

/**
 * Durable task graph. Only the controller process calls it (architecture principle 4).
 * Every mutating operation is atomic with respect to other callers, including other processes.
 */
export interface TaskStore {
  readonly kind: string;
  createTask(t: NewTask): TaskRecord;
  get(id: string): TaskRecord | undefined;
  list(): TaskRecord[];
  /** Change state only if the current state is `from`. Returns false (and changes nothing) otherwise. */
  compareAndSetState(id: string, from: TaskState, to: TaskState, counters?: Partial<TaskCounters>): boolean;
  /** Set counters without a state change. */
  updateCounters(id: string, counters: Partial<TaskCounters>): void;
  /** Atomically claim one task in state `ready` with no live claim. Lowest id first. */
  claimReady(owner: string, leaseMs: number, now: number, exclude?: ReadonlySet<string>): TaskRecord | null;
  /** Atomically claim a specific task if it has no live claim. */
  claim(id: string, owner: string, leaseMs: number, now: number): boolean;
  heartbeat(id: string, owner: string, leaseMs: number, now: number): boolean;
  release(id: string, owner: string): boolean;
  /** Clear claims whose lease has expired. Returns the affected task ids. */
  reclaimExpired(now: number): string[];
  addNote(id: string, text: string): void;
}

export class StoreError extends Error {}
