import * as fs from 'node:fs';
import * as path from 'node:path';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import type { TaskState } from '../states.ts';
import { StoreError, type Claim, type NewTask, type TaskCounters, type TaskNote, type TaskRecord, type TaskStore } from './types.ts';

const ID = /^[A-Za-z0-9._-]{1,100}$/;
const PREFIX = 'eo';
/** `bd update --if-revision` exits with this code when the guard did not hold and nothing was written. */
const EXIT_PRECONDITION = 13;
const MAX_CAS_TRIES = 200;
const LOCK_FILE = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..', 'deps.lock.json');

/**
 * Environment for every `bd` invocation. bd inherits nothing else from the controller, so it
 * never sees API keys or tokens (bd links an Anthropic client for optional AI features), and
 * its usage metrics are off whatever the user's own bd configuration says (M1-7).
 */
export function bdEnv(home: string): Record<string, string> {
  const env: Record<string, string> = {
    BD_DISABLE_METRICS: '1',
    DO_NOT_TRACK: '1',
    BD_DISABLE_EVENT_FLUSH: '1',
    BD_NON_INTERACTIVE: '1',
    BEADS_ACTOR: 'eo-controller',
    HOME: home,
    USERPROFILE: home,
    XDG_CONFIG_HOME: path.join(home, '.config'),
    PATH: process.env['PATH'] ?? '',
    LANG: 'C.UTF-8',
  };
  if (process.platform === 'win32') {
    for (const k of ['SystemRoot', 'SYSTEMROOT', 'TEMP', 'TMP', 'PATHEXT', 'ComSpec']) {
      const v = process.env[k];
      if (v !== undefined) env[k] = v;
    }
  }
  return env;
}

export function platformKey(): string {
  return `${process.platform === 'win32' ? 'windows' : process.platform}-${process.arch === 'x64' ? 'amd64' : process.arch}`;
}

/** The SHA-256 recorded in deps.lock.json for this platform's pinned bd build, if any. */
export function pinnedBdSha256(): string | undefined {
  const lock = JSON.parse(fs.readFileSync(LOCK_FILE, 'utf8')) as { beads?: { binaries?: Record<string, { sha256?: string }> } };
  return lock.beads?.binaries?.[platformKey()]?.sha256;
}

const verifiedBins = new Map<string, string>();

function sha256File(file: string): string {
  return createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

/** Eo's fields, kept in the bead's metadata under "eo". */
interface EoMeta extends TaskCounters {
  v: 1;
  epicId: string;
  state: TaskState;
  claim: Claim | null;
}

interface BdIssue {
  id: string;
  title?: string;
  status?: string;
  notes?: string;
  metadata?: { eo?: EoMeta };
  revision?: string;
  dependencies?: Array<{ id?: string; depends_on_id?: string; type?: string; dependency_type?: string }>;
}

export interface BeadsStoreOptions {
  /** Path to the bd binary. Its SHA-256 must match deps.lock.json unless `sha256` overrides it. */
  bin: string;
  /** Expected SHA-256 of `bin`. Defaults to the pinned build for this platform. */
  sha256?: string;
  /** Observer for every spawn (tests use it to check the environment, M1-7). */
  onSpawn?: (args: readonly string[], env: Readonly<Record<string, string>>) => void;
}

/**
 * TaskStore on beads (`bd`, embedded Dolt), passing the same contract as FakeStore.
 *
 * Each task is one bead with id `eo-<task id>`. Eo's fine-grained state, counters and claim
 * live in the bead's metadata; the bead's own status mirrors them coarsely (done → closed,
 * blocked → blocked, claimed → in_progress, otherwise open) so bd's views stay truthful.
 *
 * Atomicity: every read-modify-write is a `bd update --if-revision`, a compare-and-swap on
 * the bead's row token, which bd rewrites with a fresh random value on every write. A losing
 * writer gets exit 13, re-reads and retries. Leases use the controller's clock, as in
 * FakeStore, rather than bd's own lease (which uses bd's clock and a reclaim grace window),
 * so both stores behave identically and the contract suite runs unchanged.
 */
export class BeadsStore implements TaskStore {
  readonly kind = 'beads';
  readonly dir: string;
  private readonly bin: string;
  private readonly env: Record<string, string>;
  private readonly onSpawn: BeadsStoreOptions['onSpawn'];

  private constructor(dir: string, opts: BeadsStoreOptions) {
    this.dir = dir;
    this.bin = path.resolve(opts.bin);
    this.onSpawn = opts.onSpawn;
    const want = opts.sha256 ?? pinnedBdSha256();
    if (!want) throw new StoreError(`no pinned bd build for ${platformKey()} in deps.lock.json`);
    const cached = verifiedBins.get(this.bin);
    if (cached !== want) {
      if (!fs.existsSync(this.bin)) throw new StoreError(`bd binary not found: ${this.bin}`);
      const got = sha256File(this.bin);
      if (got !== want) throw new StoreError(`bd binary ${this.bin} has SHA-256 ${got}, expected the pinned ${want}`);
      verifiedBins.set(this.bin, want);
    }
    const home = path.join(dir, 'bd-home');
    fs.mkdirSync(home, { recursive: true, mode: 0o700 });
    this.env = bdEnv(home);
  }

  /** Open the beads workspace in `dir`, creating it on first use. */
  static atDir(dir: string, opts: BeadsStoreOptions): BeadsStore {
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    const s = new BeadsStore(path.resolve(dir), opts);
    if (!fs.existsSync(path.join(s.dir, '.beads'))) s.bd(['init', '--prefix', PREFIX, '--skip-agents', '--skip-hooks', '--non-interactive', '--quiet']);
    return s;
  }

  // ---------------------------------------------------------------- bd plumbing

  private run(args: string[], input?: string): { status: number; stdout: string; stderr: string } {
    this.onSpawn?.(args, this.env);
    const r = spawnSync(this.bin, args, {
      cwd: this.dir,
      env: this.env,
      encoding: 'utf8',
      timeout: 120_000,
      maxBuffer: 64 * 1024 * 1024,
      windowsHide: true,
      ...(input !== undefined ? { input } : {}),
    });
    if (r.error) throw new StoreError(`bd ${args[0]}: ${r.error.message}`);
    return { status: r.status ?? -1, stdout: r.stdout, stderr: r.stderr };
  }

  private bd(args: string[], input?: string): string {
    const r = this.run(args, input);
    if (r.status !== 0) throw new StoreError(`bd ${args[0]} failed (exit ${r.status}): ${(r.stderr || r.stdout).trim()}`);
    return r.stdout;
  }

  private show(id: string): BdIssue | undefined {
    const r = this.run(['show', `--id=${bead(id)}`, '--json']);
    if (r.status !== 0) {
      if (/not found|no issues found/.test(r.stderr + r.stdout)) return undefined;
      throw new StoreError(`bd show failed (exit ${r.status}): ${(r.stderr || r.stdout).trim()}`);
    }
    const issue = (JSON.parse(r.stdout) as BdIssue[])[0];
    // bd resolves short ids; accept only the exact bead.
    return issue && issue.id === bead(id) ? issue : undefined;
  }

  private all(): BdIssue[] {
    return (JSON.parse(this.bd(['list', '--json', '--all', '--flat', '--limit', '0'])) as BdIssue[]).filter((i) => i.id.startsWith(`${PREFIX}-`) && i.metadata?.eo);
  }

  /**
   * Read, decide, and write back under the revision guard, retrying when another writer got
   * there first. `decide` returns the new metadata, or null to write nothing.
   */
  private cas<T>(id: string, decide: (cur: EoMeta, issue: BdIssue) => { next: EoMeta | null; result: T }, missing?: () => T): T {
    for (let i = 0; i < MAX_CAS_TRIES; i++) {
      const issue = this.show(id);
      const cur = issue?.metadata?.eo;
      if (!issue || !cur) {
        if (missing) return missing();
        throw new StoreError(`unknown task ${id}`);
      }
      const { next, result } = decide(structuredClone(cur), issue);
      if (next === null) return result;
      const status = bdStatus(next);
      const args = ['update', bead(id), '--if-revision', String(issue.revision), '--metadata', JSON.stringify({ eo: next }), '--status', status, '--json'];
      // bd refuses to close an issue with an open blocker. Ordering is the controller's job
      // (the journal is authoritative, and resume may repair tasks in any order), so the close
      // is forced. This update sets no assignee or notes, the other things --force unlocks.
      if (status === 'closed') args.push('--force');
      const r = this.run(args);
      if (r.status === 0) return result;
      if (r.status !== EXIT_PRECONDITION) throw new StoreError(`bd update failed (exit ${r.status}): ${(r.stderr || r.stdout).trim()}`);
    }
    throw new StoreError(`gave up on ${id} after ${MAX_CAS_TRIES} conflicting writes`);
  }

  // ---------------------------------------------------------------- TaskStore

  createTask(t: NewTask): TaskRecord {
    if (!ID.test(t.id)) throw new StoreError(`invalid task id: ${t.id}`);
    if (this.show(t.id)) throw new StoreError(`task exists: ${t.id}`);
    for (const d of t.deps) if (!this.show(d)) throw new StoreError(`unknown dependency ${d} for ${t.id}`);
    const meta: EoMeta = { v: 1, epicId: t.epicId, state: 'planned', claim: null, attempt: 0, correctionFailures: 0, infraFailures: 0, lastFailureSignature: null, repeatCount: 0 };
    const args = ['create', '--id', bead(t.id), '--title', t.title, '--type', 'task', '--metadata', JSON.stringify({ eo: meta }), '--json'];
    if (t.deps.length) args.push('--deps', t.deps.map(bead).join(','));
    const r = this.run(args);
    if (r.status !== 0) {
      if (/already exists/.test(r.stderr + r.stdout)) throw new StoreError(`task exists: ${t.id}`);
      throw new StoreError(`bd create failed (exit ${r.status}): ${(r.stderr || r.stdout).trim()}`);
    }
    const rec = this.get(t.id);
    if (!rec) throw new StoreError(`created ${t.id} but cannot read it back`);
    return rec;
  }

  get(id: string): TaskRecord | undefined {
    const issue = this.show(id);
    return issue?.metadata?.eo ? toRecord(issue) : undefined;
  }

  list(): TaskRecord[] {
    return this.all()
      .map(toRecord)
      .sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  }

  compareAndSetState(id: string, from: TaskState, to: TaskState, counters?: Partial<TaskCounters>): boolean {
    return this.cas(id, (m) => {
      if (m.state !== from) return { next: null, result: false };
      return { next: { ...m, ...pickCounters(counters ?? {}), state: to }, result: true };
    });
  }

  updateCounters(id: string, counters: Partial<TaskCounters>): void {
    this.cas(id, (m) => ({ next: { ...m, ...pickCounters(counters) }, result: undefined }));
  }

  claimReady(owner: string, leaseMs: number, now: number, exclude?: ReadonlySet<string>): TaskRecord | null {
    for (let i = 0; i < MAX_CAS_TRIES; i++) {
      const candidates = this.list().filter((t) => t.state === 'ready' && !isLive(t.claim, now) && !exclude?.has(t.id));
      const pick = candidates[0];
      if (!pick) return null;
      // Re-checked against the guarded read: someone may have taken it since the list.
      const won = this.cas(pick.id, (m) =>
        m.state === 'ready' && !isLive(m.claim, now) ? { next: { ...m, claim: { owner, leaseExpiresAt: now + leaseMs } }, result: true } : { next: null, result: false },
      );
      if (won) return this.get(pick.id) ?? null;
    }
    throw new StoreError(`claimReady gave up after ${MAX_CAS_TRIES} lost races`);
  }

  claim(id: string, owner: string, leaseMs: number, now: number): boolean {
    return this.cas(id, (m) =>
      isLive(m.claim, now) && m.claim?.owner !== owner ? { next: null, result: false } : { next: { ...m, claim: { owner, leaseExpiresAt: now + leaseMs } }, result: true },
    );
  }

  heartbeat(id: string, owner: string, leaseMs: number, now: number): boolean {
    return this.cas(
      id,
      (m) => (m.claim?.owner === owner && isLive(m.claim, now) ? { next: { ...m, claim: { owner, leaseExpiresAt: now + leaseMs } }, result: true } : { next: null, result: false }),
      () => false,
    );
  }

  release(id: string, owner: string): boolean {
    return this.cas(id, (m) => (m.claim?.owner === owner ? { next: { ...m, claim: null }, result: true } : { next: null, result: false }), () => false);
  }

  reclaimExpired(now: number): string[] {
    const ids: string[] = [];
    for (const t of this.list()) {
      if (!t.claim || t.claim.leaseExpiresAt > now) continue;
      const cleared = this.cas(t.id, (m) => (m.claim && m.claim.leaseExpiresAt <= now ? { next: { ...m, claim: null }, result: true } : { next: null, result: false }));
      if (cleared) ids.push(t.id);
    }
    return ids.sort();
  }

  addNote(id: string, text: string): void {
    if (!this.show(id)) throw new StoreError(`unknown task ${id}`);
    // One JSON object per line, so multi-line notes keep their boundaries and timestamps.
    this.bd(['note', bead(id), '--stdin'], JSON.stringify({ ts: new Date().toISOString(), text }) + '\n');
  }
}

function bead(id: string): string {
  return `${PREFIX}-${id}`;
}

function bdStatus(m: EoMeta): string {
  if (m.state === 'done') return 'closed';
  if (m.state === 'blocked') return 'blocked';
  return m.claim ? 'in_progress' : 'open';
}

function isLive(c: Claim | null, now: number): boolean {
  return c !== null && c.leaseExpiresAt > now;
}

function parseNotes(text: string | undefined): TaskNote[] {
  if (!text) return [];
  return text
    .split('\n')
    .filter((l) => l !== '')
    .map((l) => {
      try {
        const n = JSON.parse(l) as Partial<TaskNote>;
        if (typeof n.ts === 'string' && typeof n.text === 'string') return { ts: n.ts, text: n.text };
      } catch {
        // A line not written by eo (someone used bd directly); keep it as text.
      }
      return { ts: '', text: l };
    });
}

function toRecord(issue: BdIssue): TaskRecord {
  const m = issue.metadata?.eo as EoMeta;
  const deps = (issue.dependencies ?? [])
    .filter((d) => (d.type ?? d.dependency_type) === 'blocks')
    .map((d) => (d.depends_on_id ?? d.id ?? '').slice(PREFIX.length + 1))
    .sort();
  return {
    id: issue.id.slice(PREFIX.length + 1),
    epicId: m.epicId,
    title: issue.title ?? '',
    deps,
    state: m.state,
    claim: m.claim ? { owner: m.claim.owner, leaseExpiresAt: m.claim.leaseExpiresAt } : null,
    notes: parseNotes(issue.notes),
    attempt: m.attempt,
    correctionFailures: m.correctionFailures,
    infraFailures: m.infraFailures,
    lastFailureSignature: m.lastFailureSignature,
    repeatCount: m.repeatCount,
  };
}

function pickCounters(c: Partial<TaskCounters>): Partial<TaskCounters> {
  const out: Partial<TaskCounters> = {};
  if (c.attempt !== undefined) out.attempt = c.attempt;
  if (c.correctionFailures !== undefined) out.correctionFailures = c.correctionFailures;
  if (c.infraFailures !== undefined) out.infraFailures = c.infraFailures;
  if (c.lastFailureSignature !== undefined) out.lastFailureSignature = c.lastFailureSignature;
  if (c.repeatCount !== undefined) out.repeatCount = c.repeatCount;
  return out;
}
