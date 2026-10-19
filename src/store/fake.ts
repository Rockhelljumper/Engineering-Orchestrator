import * as fs from 'node:fs';
import * as path from 'node:path';
import { writeFileAtomic } from '../util/fsx.ts';
import { FileLock } from '../util/lock.ts';
import type { TaskState } from '../states.ts';
import { StoreError, titleProblem, type NewTask, type TaskCounters, type TaskRecord, type TaskStore } from './types.ts';

interface StoreFile {
  version: 1;
  tasks: Record<string, TaskRecord>;
}

const ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/;

/**
 * Reference TaskStore. In memory for unit tests, or file-backed (one JSON file written
 * atomically under a cross-process lock) for integration and crash tests. It defines the
 * semantics the beads adapter must match (tests/integration/store-contract.test.ts).
 */
export class FakeStore implements TaskStore {
  readonly kind = 'fake';
  private readonly file: string | null;
  private readonly lockFile: string | null;
  private memory: StoreFile = { version: 1, tasks: {} };

  private constructor(dir: string | null) {
    if (dir === null) {
      this.file = null;
      this.lockFile = null;
    } else {
      fs.mkdirSync(dir, { recursive: true });
      this.file = path.join(dir, 'tasks.json');
      this.lockFile = path.join(dir, 'tasks.lock');
    }
  }

  static inMemory(): FakeStore {
    return new FakeStore(null);
  }

  static atDir(dir: string): FakeStore {
    return new FakeStore(dir);
  }

  private load(): StoreFile {
    if (this.file === null) return this.memory;
    if (!fs.existsSync(this.file)) return { version: 1, tasks: {} };
    return JSON.parse(fs.readFileSync(this.file, 'utf8')) as StoreFile;
  }

  private save(s: StoreFile): void {
    if (this.file === null) {
      this.memory = s;
      return;
    }
    writeFileAtomic(this.file, JSON.stringify(s, null, 1));
  }

  /** Read-modify-write under the store lock. Returns fn's result; saves only if `dirty` is set. */
  private mutate<T>(fn: (s: StoreFile, markDirty: () => void) => T): T {
    const lock = this.lockFile === null ? null : new FileLock(this.lockFile, `store:${process.pid}`);
    lock?.acquire(30_000);
    try {
      const s = this.load();
      let dirty = false;
      const out = fn(s, () => {
        dirty = true;
      });
      if (dirty) this.save(s);
      return out;
    } finally {
      lock?.release();
    }
  }

  /** Reads also take the lock so a reader never races an in-progress rename (matters on Windows). */
  private read<T>(fn: (s: StoreFile) => T): T {
    return this.mutate((s) => fn(s));
  }

  createTask(t: NewTask): TaskRecord {
    if (!ID.test(t.id)) throw new StoreError(`invalid task id: ${t.id}`);
    const bad = titleProblem(t.title);
    if (bad) throw new StoreError(`invalid task ${t.id}: ${bad}`);
    return this.mutate((s, dirty) => {
      if (s.tasks[t.id]) throw new StoreError(`task exists: ${t.id}`);
      for (const d of t.deps) if (!s.tasks[d]) throw new StoreError(`unknown dependency ${d} for ${t.id}`);
      const rec: TaskRecord = {
        id: t.id,
        epicId: t.epicId,
        title: t.title,
        deps: [...t.deps],
        state: 'planned',
        claim: null,
        notes: [],
        attempt: 0,
        correctionFailures: 0,
        infraFailures: 0,
        lastFailureSignature: null,
        repeatCount: 0,
        journalSeq: 0,
      };
      s.tasks[t.id] = rec;
      dirty();
      return structuredClone(rec);
    });
  }

  get(id: string): TaskRecord | undefined {
    return this.read((s) => (s.tasks[id] ? structuredClone(s.tasks[id]) : undefined));
  }

  list(): TaskRecord[] {
    return this.read((s) => Object.values(s.tasks).sort(byId).map((t) => structuredClone(t)));
  }

  compareAndSetState(id: string, from: TaskState, to: TaskState, counters?: Partial<TaskCounters>): boolean {
    return this.mutate((s, dirty) => {
      const t = s.tasks[id];
      if (!t) throw new StoreError(`unknown task ${id}`);
      if (t.state !== from) return false;
      t.state = to;
      if (counters) Object.assign(t, pickCounters(counters));
      dirty();
      return true;
    });
  }

  updateCounters(id: string, counters: Partial<TaskCounters>): void {
    this.mutate((s, dirty) => {
      const t = s.tasks[id];
      if (!t) throw new StoreError(`unknown task ${id}`);
      Object.assign(t, pickCounters(counters));
      dirty();
    });
  }

  claimReady(owner: string, leaseMs: number, now: number, exclude?: ReadonlySet<string>): TaskRecord | null {
    return this.mutate((s, dirty) => {
      const candidates = Object.values(s.tasks)
        .filter((t) => t.state === 'ready' && !isLive(t, now) && !exclude?.has(t.id))
        .sort(byId);
      const t = candidates[0];
      if (!t) return null;
      t.claim = { owner, leaseExpiresAt: now + leaseMs };
      dirty();
      return structuredClone(t);
    });
  }

  claim(id: string, owner: string, leaseMs: number, now: number): boolean {
    return this.mutate((s, dirty) => {
      const t = s.tasks[id];
      if (!t) throw new StoreError(`unknown task ${id}`);
      if (isLive(t, now) && t.claim?.owner !== owner) return false;
      t.claim = { owner, leaseExpiresAt: now + leaseMs };
      dirty();
      return true;
    });
  }

  heartbeat(id: string, owner: string, leaseMs: number, now: number): boolean {
    return this.mutate((s, dirty) => {
      const t = s.tasks[id];
      if (!t || t.claim?.owner !== owner || !isLive(t, now)) return false;
      t.claim.leaseExpiresAt = now + leaseMs;
      dirty();
      return true;
    });
  }

  release(id: string, owner: string): boolean {
    return this.mutate((s, dirty) => {
      const t = s.tasks[id];
      if (!t || t.claim?.owner !== owner) return false;
      t.claim = null;
      dirty();
      return true;
    });
  }

  reclaimExpired(now: number): string[] {
    return this.mutate((s, dirty) => {
      const ids: string[] = [];
      for (const t of Object.values(s.tasks)) {
        if (t.claim && t.claim.leaseExpiresAt <= now) {
          t.claim = null;
          ids.push(t.id);
        }
      }
      if (ids.length) dirty();
      return ids.sort();
    });
  }

  addNote(id: string, text: string): void {
    this.mutate((s, dirty) => {
      const t = s.tasks[id];
      if (!t) throw new StoreError(`unknown task ${id}`);
      t.notes.push({ ts: new Date().toISOString(), text });
      dirty();
    });
  }
}

function isLive(t: TaskRecord, now: number): boolean {
  return t.claim !== null && t.claim.leaseExpiresAt > now;
}

function byId(a: TaskRecord, b: TaskRecord): number {
  return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
}

function pickCounters(c: Partial<TaskCounters>): Partial<TaskCounters> {
  const out: Partial<TaskCounters> = {};
  if (c.attempt !== undefined) out.attempt = c.attempt;
  if (c.correctionFailures !== undefined) out.correctionFailures = c.correctionFailures;
  if (c.infraFailures !== undefined) out.infraFailures = c.infraFailures;
  if (c.lastFailureSignature !== undefined) out.lastFailureSignature = c.lastFailureSignature;
  if (c.repeatCount !== undefined) out.repeatCount = c.repeatCount;
  if (c.journalSeq !== undefined) out.journalSeq = c.journalSeq;
  return out;
}
