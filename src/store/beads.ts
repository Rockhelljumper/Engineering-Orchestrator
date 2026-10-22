import * as fs from 'node:fs';
import * as path from 'node:path';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import type { TaskState } from '../states.ts';
import { StoreError, titleProblem, type Claim, type NewTask, type TaskCounters, type TaskNote, type TaskRecord, type TaskStore } from './types.ts';
import { assertPrivateDir } from '../util/fsx.ts';

const ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/;
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
export function bdEnv(home: string, workspace = home): Record<string, string> {
  const env: Record<string, string> = {
    // bd runs git; it must never find (and commit to, or configure) a repository that
    // happens to enclose the state root. bd clears this for some commands, so the store also
    // gets a repository of its own (BeadsStore.atDir).
    GIT_CEILING_DIRECTORIES: path.dirname(path.resolve(workspace)),
    GIT_CONFIG_NOSYSTEM: '1',
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
  // Same names as scripts/build-bd.sh: amd64, arm64.
  return `${process.platform === 'win32' ? 'windows' : process.platform}-${process.arch === 'x64' ? 'amd64' : process.arch}`;
}

/** The SHA-256 recorded in deps.lock.json for this platform's pinned bd build, if any. */
export function pinnedBdSha256(): string | undefined {
  const lock = JSON.parse(fs.readFileSync(LOCK_FILE, 'utf8')) as { beads?: { binaries?: Record<string, { sha256?: string }> } };
  return lock.beads?.binaries?.[platformKey()]?.sha256;
}

function sha256(buf: Buffer): string {
  return createHash('sha256').update(buf).digest('hex');
}

/** Check a candidate bd binary against the pin before anything is created with it. */
export function verifyBdBinary(bin: string, want = pinnedBdSha256()): void {
  if (!want) throw new StoreError(`no pinned bd build for ${platformKey()} in deps.lock.json`);
  if (!fs.existsSync(bin)) throw new StoreError(`bd binary not found: ${bin}`);
  const got = sha256(fs.readFileSync(bin));
  if (got !== want) throw new StoreError(`bd binary ${bin} has SHA-256 ${got}, expected the pinned ${want}`);
}

/**
 * Identity of a file for detecting replacement between spawns, or undefined when it is not a
 * private regular file: a symlink, a file with other hard links (whose inode another path can
 * reach), or on POSIX a file owned by another user.
 */
function fileId(file: string): string | undefined {
  const st = fs.lstatSync(file, { bigint: true, throwIfNoEntry: false });
  if (!st || !st.isFile() || st.nlink !== 1n) return undefined;
  const euid = process.geteuid?.();
  if (process.platform !== 'win32' && euid !== undefined && st.uid !== BigInt(euid)) return undefined;
  return `${st.dev}:${st.ino}:${st.size}:${st.mtimeNs}:${st.ctimeNs}`;
}

/** The file's identity if it is private, its bytes hash to `want` and it did not change while hashing. */
function verifiedId(file: string, want: string): string | undefined {
  const before = fileId(file);
  if (before === undefined) return undefined;
  if (sha256(fs.readFileSync(file)) !== want) return undefined;
  return fileId(file) === before ? before : undefined;
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
  /**
   * Create (or repair a half-created) workspace; default false. Only the controller, under
   * its lock, passes true in production; tests pass it where they create a store.
   */
  create?: boolean;
}

const INIT_MARKER = '.eo-initialised';

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
  /** The verified copy that is actually executed, inside the store directory. */
  private readonly bin: string;
  private readonly want: string;
  private binId: string;
  private readonly env: Record<string, string>;
  private readonly onSpawn: BeadsStoreOptions['onSpawn'];

  private constructor(dir: string, opts: BeadsStoreOptions) {
    this.dir = dir;
    this.onSpawn = opts.onSpawn;
    const want = opts.sha256 ?? pinnedBdSha256();
    if (!want) throw new StoreError(`no pinned bd build for ${platformKey()} in deps.lock.json`);
    this.want = want;
    // Execute only a private copy inside the store whose bytes were hashed, so neither renaming
    // something onto the source path nor writing to the source file can change what runs. (A
    // hard link would share the source's inode, and every link or unlink of that inode changes
    // its ctime, which run() would read as a replacement.) The copy is a reflink where the file
    // system supports it.
    // The identity recorded for run() is taken before hashing and confirmed unchanged after,
    // so a write that lands while the file is being hashed is never recorded as verified.
    const binDir = path.join(dir, 'bin');
    fs.mkdirSync(binDir, { recursive: true, mode: 0o700 });
    try {
      assertPrivateDir(dir);
      assertPrivateDir(binDir);
    } catch (err) {
      throw new StoreError(`unsafe beads store: ${(err as Error).message}`);
    }
    this.bin = path.join(binDir, process.platform === 'win32' ? 'bd.exe' : 'bd');
    // An existing entry is trusted only if it is still a private regular file with the pinned
    // bytes; anything else (a symlink, a hard link from an older version, other bytes) is replaced.
    let id = fs.existsSync(this.bin) ? verifiedId(this.bin, want) : undefined;
    if (id === undefined) {
      const src = path.resolve(opts.bin);
      if (!fs.existsSync(src)) throw new StoreError(`bd binary not found: ${src}`);
      const tmp = `${this.bin}.${process.pid}.tmp`;
      try {
        fs.rmSync(tmp, { force: true });
        fs.copyFileSync(src, tmp, fs.constants.COPYFILE_FICLONE);
        fs.chmodSync(tmp, 0o500);
        const got = sha256(fs.readFileSync(tmp));
        if (got !== want) throw new StoreError(`bd binary ${src} has SHA-256 ${got}, expected the pinned ${want}`);
        // On Windows a read-only file cannot be replaced by rename (POSIX renames over it). Only
        // there, and only a private file: chmod of a symlink or hard link would change the file
        // it shares, such as the user's own bd.
        if (process.platform === 'win32' && fileId(this.bin) !== undefined) fs.chmodSync(this.bin, 0o700);
        fs.renameSync(tmp, this.bin);
      } catch (err) {
        if (err instanceof StoreError) throw err;
        throw new StoreError(`could not install the verified bd entry ${this.bin}: ${(err as Error).message}`);
      } finally {
        fs.rmSync(tmp, { force: true });
      }
      id = verifiedId(this.bin, want);
      if (id === undefined) throw new StoreError(`bd binary ${this.bin} changed while it was being verified; refusing to run it`);
    }
    this.binId = id;
    const home = path.join(dir, 'bd-home');
    fs.mkdirSync(home, { recursive: true, mode: 0o700 });
    this.env = bdEnv(home, dir);
  }

  /** Whether `dir` holds a beads store whose initialisation completed. */
  static isInitialised(dir: string): boolean {
    return fs.existsSync(path.join(dir, INIT_MARKER));
  }

  /**
   * Open the beads workspace in `dir`. With `create`, initialise it on first use, and
   * re-initialise one whose init never completed (a crash during `bd init`); without it,
   * refuse a workspace that is not fully initialised.
   */

  static atDir(dir: string, opts: BeadsStoreOptions): BeadsStore {
    const create = opts.create ?? false;
    if (!create && !fs.existsSync(path.join(dir, INIT_MARKER))) throw new StoreError(`beads store at ${dir} is not initialised`);
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    const s = new BeadsStore(path.resolve(dir), opts);
    if (!fs.existsSync(path.join(s.dir, INIT_MARKER))) {
      for (const f of ['.beads', '.git', '.gitignore', '.beads.gate.lock']) fs.rmSync(path.join(s.dir, f), { recursive: true, force: true });
      // bd init stages and commits into the nearest enclosing git repository and clears
      // GIT_CEILING_DIRECTORIES itself, so give it a repository of its own, inside the store.
      const g = spawnSync('git', ['init', '-q', s.dir], { env: s.env, encoding: 'utf8', windowsHide: true });
      if (g.error || g.status !== 0) throw new StoreError(`git init of the beads store failed: ${g.error?.message ?? g.stderr.trim()}`);
      s.bd(['init', '--prefix', PREFIX, '--skip-agents', '--skip-hooks', '--non-interactive', '--quiet']);
      fs.writeFileSync(path.join(s.dir, INIT_MARKER), `bd ${s.want}\n`, { mode: 0o600 });
    }
    return s;
  }

  // ---------------------------------------------------------------- bd plumbing

  private run(args: string[], input?: string): { status: number; stdout: string; stderr: string } {
    if (fileId(this.bin) !== this.binId) {
      const id = verifiedId(this.bin, this.want);
      if (id === undefined) throw new StoreError(`bd binary ${this.bin} was replaced; refusing to run it`);
      this.binId = id;
    }
    // A write between this check and the spawn below is not detectable from here; the entry
    // lives in the state root, which agents cannot reach (threat model T10).
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
    const issues = JSON.parse(this.bd(['list', '--json', '--all', '--flat', '--limit', '0'])) as BdIssue[];
    const foreign = issues.filter((i) => !i.metadata?.eo).map((i) => i.id);
    if (foreign.length) throw new StoreError(`beads ${foreign.join(', ')} have no eo metadata (created or edited outside the controller)`);
    return issues;
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
    const bad = titleProblem(t.title);
    if (bad) throw new StoreError(`invalid task ${t.id}: ${bad}`);
    if (this.show(t.id)) throw new StoreError(`task exists: ${t.id}`);
    for (const d of t.deps) if (!this.show(d)) throw new StoreError(`unknown dependency ${d} for ${t.id}`);
    const meta: EoMeta = { v: 1, epicId: t.epicId, state: 'planned', claim: null, attempt: 0, correctionFailures: 0, infraFailures: 0, lastFailureSignature: null, repeatCount: 0, journalSeq: 0 };
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
    if (!issue) return undefined;
    if (!issue.metadata?.eo) throw new StoreError(`bead ${issue.id} has no eo metadata (created or edited outside the controller)`);
    return toRecord(issue);
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
      const won = this.cas<TaskRecord | null>(pick.id, (m, issue) => {
        if (m.state !== 'ready' || isLive(m.claim, now)) return { next: null, result: null };
        const next: EoMeta = { ...m, claim: { owner, leaseExpiresAt: now + leaseMs } };
        // The record as written, not a later re-read.
        return { next, result: toRecord({ ...issue, metadata: { eo: next } }) };
      });
      if (won) return won;
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
    lastFailureSignature: m.lastFailureSignature ?? null,
    repeatCount: m.repeatCount,
    // Absent only on beads written by an older eo; left absent so recovery names the cause.
    journalSeq: m.journalSeq as number,
  };
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
