import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { randomBytes, timingSafeEqual } from 'node:crypto';
import { canonicalJson, hmacHex, sha256Hex } from './util/canonical.ts';
import { assertPrivateDir, writeFileAtomic } from './util/fsx.ts';
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
  journalSeq: number;
  journalMac: string;
  ts: string;
  mac: string;
}

export class AnchorError extends Error {}

/** A state root's id: stable for its whole life (every copy of it shares it), derived from its journal key. */
export function rootIdOf(journalKey: Buffer): string {
  return sha256Hex(Buffer.concat([Buffer.from('eo-root-id\0'), journalKey])).slice(0, 32);
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

function realOrResolved(p: string): string {
  try {
    return fs.realpathSync(p);
  } catch {
    return path.resolve(p);
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
    const root = realOrResolved(stateRoot);
    if (isWithin(realOrResolved(d), root)) throw new AnchorError(`the rollback anchor ${d} is inside the state root ${root}; a restored copy of the state root would carry it`);
    if (isWithin(root, realOrResolved(d))) throw new AnchorError(`the state root ${root} is inside the rollback anchor ${d}`);
    const meta = path.join(d, 'anchor.json');
    if (!fs.existsSync(meta)) {
      if (opts.create === false) throw new AnchorError(`no rollback anchor at ${d}`);
      fs.mkdirSync(path.join(d, 'heads'), { recursive: true, mode: 0o700 });
      assertPrivateDir(d);
      const body = JSON.stringify({ id: randomBytes(16).toString('hex'), key: randomBytes(32).toString('hex') }) + '\n';
      // Exclusive create: two controllers opening a fresh anchor at once agree on one key.
      try {
        const fd = fs.openSync(meta, 'wx', 0o600);
        try {
          fs.writeSync(fd, body);
          fs.fsyncSync(fd);
        } finally {
          fs.closeSync(fd);
        }
      } catch (err) {
        if ((err as NodeJS.ErrnoException).code !== 'EEXIST') throw err;
      }
    }
    assertPrivateDir(d);
    if (fs.existsSync(path.join(d, 'heads'))) assertPrivateDir(path.join(d, 'heads'));
    // Re-check after creation: the directory now exists, so a link is resolved.
    if (isWithin(realOrResolved(d), root)) throw new AnchorError(`the rollback anchor ${d} is inside the state root ${root}`);
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
    return hmacHex(this.key, canonicalJson({ rootId: h.rootId, anchorId: h.anchorId, journalSeq: h.journalSeq, journalMac: h.journalMac, ts: h.ts }));
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
  advance(rootId: string, journalSeq: number, journalMac: string): AnchorHead {
    const cur = this.read(rootId);
    if (cur && journalSeq < cur.journalSeq) throw new AnchorError(`refusing to move the anchor of ${rootId} back from journal seq ${cur.journalSeq} to ${journalSeq}`);
    if (cur && journalSeq === cur.journalSeq) {
      if (cur.journalMac !== journalMac) throw new AnchorError(`journal seq ${journalSeq} of ${rootId} has a different MAC from the anchored one`);
      return cur;
    }
    const base = { rootId, anchorId: this.id, journalSeq, journalMac, ts: new Date().toISOString() };
    const head: AnchorHead = { ...base, mac: this.macOf(base) };
    writeFileAtomic(this.headFile(rootId), JSON.stringify(head) + '\n');
    return head;
  }
}

export type AnchorCheck =
  | { kind: 'match' }
  /** A crash between the journal append and the anchor update: the journal is one record ahead. */
  | { kind: 'one-ahead'; anchored: number }
  /** Neither the anchor nor the journal has a binding: a new state root, or one made before M2-0b. */
  | { kind: 'unbound' }
  | { kind: 'refuse'; reason: string };

export interface AnchorBinding {
  anchorId: string;
  rootId: string;
}

/** The journal's record of which anchor holds its head, if any. */
export function journaledBinding(records: readonly JournalRecord[]): AnchorBinding | undefined {
  return records.find((r) => r.type === 'anchor.bound')?.data as AnchorBinding | undefined;
}

/**
 * Compare a verified journal with its anchored head. Shared by open (which refuses or
 * repairs) and doctor (which reports). Pure: it reads nothing and writes nothing.
 */
export function checkAnchor(records: readonly JournalRecord[], head: AnchorHead | null, anchorId: string, rootId: string): AnchorCheck {
  const bound = journaledBinding(records);
  if (bound && bound.rootId !== rootId) return { kind: 'refuse', reason: `the journal is bound to state root id ${bound.rootId}, not ${rootId}` };
  if (bound && bound.anchorId !== anchorId) {
    return { kind: 'refuse', reason: `the journal is bound to rollback anchor ${bound.anchorId}, but the configured anchor is ${anchorId}` };
  }
  if (!head) {
    // A crash right after journaling the binding, before its first head was written.
    const boundAt = records.findIndex((r) => r.type === 'anchor.bound');
    if (bound && boundAt === records.length - 1) return { kind: 'one-ahead', anchored: 0 };
    if (bound) return { kind: 'refuse', reason: `the journal is bound to rollback anchor ${bound.anchorId}, which has no head for this state root (the anchor was removed or replaced)` };
    return { kind: 'unbound' };
  }
  const n = records.length;
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
