import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { randomBytes, timingSafeEqual } from 'node:crypto';
import { canonicalJson, hmacHex, sha256Hex } from './util/canonical.ts';
import { assertPrivateDir, fsyncDir, writeFileAtomic } from './util/fsx.ts';
import type { JournalRecord } from './journal.ts';

/**
 * Rollback anchor (M2-0b). After every journal append the controller records the journal
 * head (seq and MAC) here, outside the state root. A copy of the whole state root restored
 * from an older backup is internally consistent, so nothing inside the state root can tell it
 * from a state root that simply stopped there; the anchor can, because restoring the state
 * root does not restore it.
 *
 * Layout of an anchor directory (one directory can anchor many state roots):
 *
 *   anchor.json          {"id", "key"}: this anchor's id and the 256-bit key that MACs its heads
 *   heads/<rootId>.json  the latest journal head of one state root, MACed with that key
 *
 * A state root is known to the anchor by its canonical path (rootId) and by the fingerprint of
 * its journal key (keyId), both of which the head records. Neither can be changed from inside
 * the state root: a restored copy re-signed with a new key still sits at the same path, whose
 * head names the old key, and a copy at another path has no head and is refused until an
 * operator adopts it ("eo anchor adopt"). Only a state root with an empty journal is bound
 * without an operator.
 *
 * Each head is replaced atomically (write, fsync, rename), so a crash leaves the old head or
 * the new one, never a mix. The controller writes the head after the journal record is
 * durable, so a crash between the two leaves the journal exactly one record ahead of its
 * anchor; that is the only gap a crash can produce, and the next open closes it.
 *
 * What the anchor protects against depends on where it lives: it must be somewhere a rollback
 * of the state root cannot also roll back (another directory tree, backup set, account or
 * host). This module refuses an anchor inside the state root, or a state root inside the
 * anchor; giving the anchor its own protection (a separate OS account or host) is a
 * deployment decision (M2 Phase B).
 */

export interface AnchorHead {
  rootId: string;
  anchorId: string;
  /** Fingerprint of the journal key the head was recorded under. */
  keyId: string;
  /** The canonical state-root path rootId was derived from (for people reading the head). */
  root: string;
  journalSeq: number;
  journalMac: string;
  ts: string;
  mac: string;
}

export class AnchorError extends Error {}

/**
 * The canonical form of a state-root path: symlinks resolved and, where the filesystem
 * usually folds case (Windows, macOS), lower-cased, so one directory never gets two ids. Two
 * directories differing only by case on a case-sensitive macOS volume share an id, which
 * refuses the second rather than accepting either wrongly.
 */
export function canonicalRoot(stateRoot: string): string {
  const real = resolveExisting(stateRoot);
  return process.platform === 'win32' || process.platform === 'darwin' ? real.toLowerCase() : real;
}

/** A state root's id in an anchor: derived from where it lives, which nothing inside it can change. */
export function rootIdOf(stateRoot: string): string {
  return sha256Hex(Buffer.from(`eo-root-id\0${canonicalRoot(stateRoot)}`)).slice(0, 32);
}

/** Fingerprint of a journal key: a copy re-signed with a new key has a different one. */
export function keyIdOf(journalKey: Buffer): string {
  return sha256Hex(Buffer.concat([Buffer.from('eo-key-id\0'), journalKey])).slice(0, 32);
}

/** The default anchor directory: beside, never inside, the default state roots. EO_ANCHOR_DIR overrides it. */
export function defaultAnchorDir(): string {
  const env = process.env['EO_ANCHOR_DIR'];
  if (env) return path.resolve(env);
  if (process.platform === 'win32') {
    const base = process.env['LOCALAPPDATA'] ?? path.join(os.homedir(), 'AppData', 'Local');
    return path.join(base, 'eo-anchor');
  }
  const base = process.env['XDG_STATE_HOME'] ?? path.join(os.homedir(), '.local', 'state');
  return path.join(base, 'eo-anchor');
}

function isWithin(child: string, parent: string): boolean {
  const rel = path.relative(parent, child);
  return rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel));
}

/**
 * Resolve a path whose tail may not exist yet: realpath its deepest existing ancestor and
 * append the rest, so a link anywhere along an existing prefix is followed before anything is
 * created under it.
 */
function resolveExisting(p: string): string {
  let cur = path.resolve(p);
  const rest: string[] = [];
  for (;;) {
    try {
      return path.join(fs.realpathSync.native(cur), ...rest);
    } catch {
      const parent = path.dirname(cur);
      if (parent === cur) return path.join(cur, ...rest);
      rest.unshift(path.basename(cur));
      cur = parent;
    }
  }
}

function macEqual(a: string, b: string): boolean {
  const ba = Buffer.from(a, 'hex');
  const bb = Buffer.from(b, 'hex');
  return ba.length === bb.length && ba.length > 0 && timingSafeEqual(ba, bb);
}

export class RollbackAnchor {
  readonly dir: string;
  readonly id: string;
  private readonly key: Buffer;

  private constructor(dir: string, id: string, key: Buffer) {
    this.dir = dir;
    this.id = id;
    this.key = key;
  }

  /**
   * Open (creating on first use) the anchor directory for the state root at `stateRoot`.
   * Refuses an anchor that a copy of the state root would carry with it, and one that others
   * could change.
   */
  static open(dir: string, stateRoot: string, opts: { create?: boolean } = {}): RollbackAnchor {
    const d = path.resolve(dir);
    // Both paths are resolved through their existing prefixes before anything is created, so a
    // link into the state root is refused before a file is written there.
    const root = resolveExisting(stateRoot);
    if (isWithin(resolveExisting(d), root)) throw new AnchorError(`the rollback anchor ${d} is inside the state root ${root}; a restored copy of the state root would carry it`);
    if (isWithin(root, resolveExisting(d))) throw new AnchorError(`the state root ${root} is inside the rollback anchor ${d}`);
    const meta = path.join(d, 'anchor.json');
    if (!fs.existsSync(meta)) {
      if (opts.create === false) throw new AnchorError(`no rollback anchor at ${d}`);
      fs.mkdirSync(path.join(d, 'heads'), { recursive: true, mode: 0o700 });
      assertPrivateDir(d);
      const body = JSON.stringify({ id: randomBytes(16).toString('hex'), key: randomBytes(32).toString('hex') }) + '\n';
      // Written in full and fsynced under a temporary name, then linked into place: link fails
      // if the name exists, so two controllers opening a fresh anchor at once agree on one key,
      // and a crash leaves either no anchor.json or a complete one, never an empty file.
      const tmp = path.join(d, `.anchor.json.${process.pid}.${randomBytes(4).toString('hex')}.tmp`);
      const fd = fs.openSync(tmp, 'wx', 0o600);
      try {
        fs.writeSync(fd, body);
        fs.fsyncSync(fd);
      } finally {
        fs.closeSync(fd);
      }
      try {
        fs.linkSync(tmp, meta);
      } catch (err) {
        if ((err as NodeJS.ErrnoException).code !== 'EEXIST') throw err;
      } finally {
        fs.rmSync(tmp, { force: true });
      }
      fsyncDir(d);
      fsyncDir(path.dirname(d));
    }
    assertPrivateDir(d);
    if (fs.existsSync(path.join(d, 'heads'))) assertPrivateDir(path.join(d, 'heads'));
    // Re-check after creation, in case a link was swapped in meanwhile.
    if (isWithin(resolveExisting(d), root)) throw new AnchorError(`the rollback anchor ${d} is inside the state root ${root}`);
    let m: Partial<{ id: string; key: string }>;
    try {
      m = JSON.parse(fs.readFileSync(meta, 'utf8')) as Partial<{ id: string; key: string }>;
    } catch (err) {
      throw new AnchorError(`rollback anchor ${meta} is unreadable: ${(err as Error).message}`);
    }
    if (typeof m.id !== 'string' || !/^[0-9a-f]{32}$/.test(m.id) || typeof m.key !== 'string' || !/^[0-9a-f]{64}$/.test(m.key)) {
      throw new AnchorError(`rollback anchor ${meta} is malformed`);
    }
    return new RollbackAnchor(d, m.id, Buffer.from(m.key, 'hex'));
  }

  private headFile(rootId: string): string {
    if (!/^[0-9a-f]{32}$/.test(rootId)) throw new AnchorError(`invalid root id ${rootId}`);
    return path.join(this.dir, 'heads', `${rootId}.json`);
  }

  private macOf(h: Omit<AnchorHead, 'mac'>): string {
    return hmacHex(this.key, canonicalJson({ rootId: h.rootId, anchorId: h.anchorId, keyId: h.keyId, root: h.root, journalSeq: h.journalSeq, journalMac: h.journalMac, ts: h.ts }));
  }

  /** The head file's bytes as found (base64), for forensic records; null if there is none. */
  rawHead(rootId: string): string | null {
    try {
      return fs.readFileSync(this.headFile(rootId)).toString('base64');
    } catch {
      return null;
    }
  }

  /** The recorded head for a state root, or null if this anchor has never seen it. Throws on a head that fails its MAC. */
  read(rootId: string): AnchorHead | null {
    const f = this.headFile(rootId);
    if (!fs.existsSync(f)) return null;
    let h: AnchorHead;
    try {
      h = JSON.parse(fs.readFileSync(f, 'utf8')) as AnchorHead;
    } catch (err) {
      throw new AnchorError(`anchor head ${f} is unreadable: ${(err as Error).message}`);
    }
    if (
      h.rootId !== rootId ||
      h.anchorId !== this.id ||
      typeof h.keyId !== 'string' ||
      typeof h.root !== 'string' ||
      !Number.isInteger(h.journalSeq) ||
      h.journalSeq < 1 ||
      typeof h.journalMac !== 'string' ||
      typeof h.mac !== 'string' ||
      !macEqual(h.mac, this.macOf(h))
    ) {
      throw new AnchorError(`anchor head ${f} failed verification`);
    }
    return h;
  }

  /**
   * Record a new journal head. Monotonic: a head behind the recorded one is refused, so the
   * anchor itself never moves backwards.
   */
  advance(rootId: string, keyId: string, root: string, journalSeq: number, journalMac: string): AnchorHead {
    const cur = this.read(rootId);
    if (cur && cur.keyId !== keyId) throw new AnchorError(`refusing to move the anchor of ${rootId}: it was recorded under journal key ${cur.keyId}, not ${keyId}`);
    if (cur && journalSeq < cur.journalSeq) throw new AnchorError(`refusing to move the anchor of ${rootId} back from journal seq ${cur.journalSeq} to ${journalSeq}`);
    if (cur && journalSeq === cur.journalSeq) {
      if (cur.journalMac !== journalMac) throw new AnchorError(`journal seq ${journalSeq} of ${rootId} has a different MAC from the anchored one`);
      return cur;
    }
    return this.write(rootId, keyId, root, journalSeq, journalMac);
  }

  /**
   * Drop a state root's head, so its next append starts a new one. Only for an operator who
   * adopts a state root and explicitly accepts that it is older than, or differs from, what
   * the anchor recorded ("eo anchor adopt --accept-rollback"); the controller keeps a forensic
   * record of the head it drops.
   */
  forget(rootId: string): void {
    fs.rmSync(this.headFile(rootId), { force: true });
    fsyncDir(path.join(this.dir, 'heads'));
  }

  private write(rootId: string, keyId: string, root: string, journalSeq: number, journalMac: string): AnchorHead {
    const base = { rootId, anchorId: this.id, keyId, root, journalSeq, journalMac, ts: new Date().toISOString() };
    const head: AnchorHead = { ...base, mac: this.macOf(base) };
    writeFileAtomic(this.headFile(rootId), JSON.stringify(head) + '\n');
    return head;
  }
}

export type AnchorCheck =
  | { kind: 'match' }
  /** A crash between the journal append and the anchor update: the journal is one record ahead. */
  | { kind: 'one-ahead'; anchored: number }
  /** An empty journal with no head: a new state root, bound on open. */
  | { kind: 'new' }
  /** A journal with records but no head and no binding here: made before M2-0b, moved, or copied. An operator must adopt it. */
  | { kind: 'unadopted'; reason: string }
  | { kind: 'refuse'; reason: string };

export interface AnchorBinding {
  anchorId: string;
  rootId: string;
  keyId: string;
  root?: string;
}

/** The journal's latest record of which anchor holds its head, if any (a later adoption supersedes an earlier binding). */
export function journaledBinding(records: readonly JournalRecord[]): AnchorBinding | undefined {
  return records.findLast((r) => r.type === 'anchor.bound')?.data as AnchorBinding | undefined;
}

const ADOPT = 'an operator who has checked where it came from can adopt it with "eo anchor adopt"';

/**
 * Compare a verified journal with its anchored head. Shared by open (which refuses, repairs
 * or binds), doctor and the read-only commands (which report). Pure: it reads nothing and
 * writes nothing.
 */
export function checkAnchor(records: readonly JournalRecord[], head: AnchorHead | null, anchorId: string, rootId: string, keyId: string): AnchorCheck {
  const bound = journaledBinding(records);
  const n = records.length;
  if (head && head.keyId !== keyId) {
    return { kind: 'refuse', reason: `the journal key differs from the one this state root was anchored under (${head.keyId}, now ${keyId}): an older copy re-signed with a new key, or the key was replaced` };
  }
  if (bound && bound.anchorId !== anchorId) {
    return { kind: 'refuse', reason: `the journal is bound to rollback anchor ${bound.anchorId}, but the configured anchor is ${anchorId}` };
  }
  if (bound && (bound.rootId !== rootId || bound.keyId !== keyId)) {
    return head
      ? { kind: 'refuse', reason: `the journal's latest binding is for ${bound.root ?? bound.rootId} under key ${bound.keyId}, not this state root: it was copied over this one` }
      : { kind: 'unadopted', reason: `the journal is bound to the state root at ${bound.root ?? bound.rootId}, not this one: it was moved or copied here; ${ADOPT}` };
  }
  if (!head) {
    if (n === 0) return { kind: 'new' };
    // A crash right after journaling the binding, before its first head was written.
    if (bound && records.at(-1)?.type === 'anchor.bound') return { kind: 'one-ahead', anchored: n - 1 };
    if (bound) return { kind: 'refuse', reason: `the journal is bound to rollback anchor ${bound.anchorId}, which has no head for this state root (the anchor was removed or replaced)` };
    return { kind: 'unadopted', reason: `the journal has ${n} records but this state root has never been anchored (made before M2-0b, or restored where no anchor knows it); ${ADOPT}` };
  }
  if (head.journalSeq > n) {
    return { kind: 'refuse', reason: `the journal ends at seq ${n}, behind its anchored head at seq ${head.journalSeq}: the state root was rolled back or the journal truncated` };
  }
  const at = records[head.journalSeq - 1];
  if (!at || at.mac !== head.journalMac) {
    return { kind: 'refuse', reason: `journal record ${head.journalSeq} differs from the anchored head: the journal was replaced by a different history` };
  }
  if (!bound) return { kind: 'refuse', reason: 'the anchor holds a head for this state root, but the journal has no anchor binding: an older copy of the state root was restored' };
  if (n === head.journalSeq) return { kind: 'match' };
  if (n === head.journalSeq + 1) return { kind: 'one-ahead', anchored: head.journalSeq };
  return { kind: 'refuse', reason: `the journal is ${n - head.journalSeq} records ahead of its anchored head (seq ${head.journalSeq}); a crash leaves at most one` };
}

/** Where a state root stands against an anchor, without creating or changing anything. */
export interface AnchorInspection {
  dir: string;
  anchorId: string | null;
  rootId: string;
  keyId: string;
  head: AnchorHead | null;
  check: AnchorCheck;
}

export function inspectAnchor(dir: string, stateRoot: string, journalKey: Buffer, records: readonly JournalRecord[]): AnchorInspection {
  const rootId = rootIdOf(stateRoot);
  const keyId = keyIdOf(journalKey);
  if (!fs.existsSync(path.join(dir, 'anchor.json'))) {
    const bound = journaledBinding(records);
    const check: AnchorCheck = bound
      ? { kind: 'refuse', reason: `the journal is bound to rollback anchor ${bound.anchorId}, but there is no anchor at ${dir}` }
      : records.length === 0
        ? { kind: 'new' }
        : { kind: 'unadopted', reason: `there is no anchor at ${dir} and the journal has ${records.length} records; ${ADOPT}` };
    return { dir, anchorId: null, rootId, keyId, head: null, check };
  }
  const anchor = RollbackAnchor.open(dir, stateRoot, { create: false });
  const head = anchor.read(rootId);
  return { dir, anchorId: anchor.id, rootId, keyId, head, check: checkAnchor(records, head, anchor.id, rootId, keyId) };
}
