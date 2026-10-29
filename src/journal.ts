import * as fs from 'node:fs';
import { timingSafeEqual } from 'node:crypto';
import { canonicalJson, hmacHex } from './util/canonical.ts';
import { appendLineDurable, writeFileAtomic } from './util/fsx.ts';

/**
 * Append-only, fsynced, HMAC-chained journal. Each record's MAC covers its own fields and
 * the previous record's MAC, keyed with a secret held in the state root, so a record cannot
 * be edited, removed or reordered without detection by anyone lacking the key.
 *
 * Records are write-ahead: the controller journals an intent before acting and an outcome
 * after, and the journal is authoritative when it disagrees with the task store.
 */
export interface JournalRecord<T = unknown> {
  seq: number;
  ts: string;
  type: string;
  data: T;
  prev: string;
  mac: string;
}

export interface JournalVerification {
  ok: boolean;
  records: JournalRecord[];
  errors: string[];
  /** The final line was incomplete (crash during write). It carries no valid MAC and is ignored. */
  tornTail: boolean;
}

const GENESIS = 'genesis';

function macOf(key: Buffer, r: Omit<JournalRecord, 'mac'>): string {
  return hmacHex(key, canonicalJson({ seq: r.seq, ts: r.ts, type: r.type, data: r.data, prev: r.prev }));
}

function macEqual(a: string, b: string): boolean {
  const ba = Buffer.from(a, 'hex');
  const bb = Buffer.from(b, 'hex');
  return ba.length === bb.length && ba.length > 0 && timingSafeEqual(ba, bb);
}

export function verifyJournalFile(file: string, key: Buffer): JournalVerification {
  const errors: string[] = [];
  const records: JournalRecord[] = [];
  if (!fs.existsSync(file)) return { ok: true, records, errors, tornTail: false };
  const text = fs.readFileSync(file, 'utf8');
  const lines = text.split('\n');
  const endsClean = text.length === 0 || text.endsWith('\n');
  if (lines[lines.length - 1] === '') lines.pop();
  let tornTail = false;
  let prev = GENESIS;
  lines.forEach((line, i) => {
    const isLast = i === lines.length - 1;
    let rec: JournalRecord;
    try {
      rec = JSON.parse(line) as JournalRecord;
    } catch {
      if (isLast && !endsClean) {
        tornTail = true;
        return;
      }
      errors.push(`line ${i + 1}: not valid JSON`);
      return;
    }
    if (rec.seq !== records.length + 1) errors.push(`line ${i + 1}: seq ${rec.seq}, expected ${records.length + 1}`);
    if (rec.prev !== prev) errors.push(`line ${i + 1}: chain broken (prev mismatch)`);
    if (typeof rec.mac !== 'string' || !macEqual(rec.mac, macOf(key, rec))) errors.push(`line ${i + 1}: MAC mismatch`);
    prev = rec.mac;
    records.push(rec);
  });
  return { ok: errors.length === 0, records, errors, tornTail };
}

export class JournalTamperError extends Error {}

export class Journal {
  readonly file: string;
  private readonly key: Buffer;
  private lastSeq = 0;
  private lastMac = GENESIS;
  private recordsCache: JournalRecord[] = [];
  private appendsThisProcess = 0;
  /** Called after each record is durable (the rollback anchor, M2-0b). An append is complete only when it returns. */
  private onAppend: ((rec: JournalRecord) => void) | undefined;
  /** Set when onAppend failed: the journal is then ahead of its anchor, and one more append would put it two ahead. */
  private failed: Error | undefined;

  private constructor(file: string, key: Buffer) {
    this.file = file;
    this.key = key;
  }

  /**
   * Open for appending. Refuses a tampered journal. A torn final line (crash during write)
   * is removed only when `repairTornTail` is set; the controller sets it on open and reports it in the resume record.
   */
  static open(file: string, key: Buffer, opts: { repairTornTail?: boolean; onAppend?: (rec: JournalRecord) => void } = {}): Journal {
    const v = verifyJournalFile(file, key);
    if (!v.ok) throw new JournalTamperError(`journal failed verification: ${v.errors.join('; ')}`);
    if (v.tornTail) {
      if (!opts.repairTornTail) throw new JournalTamperError('journal has a torn final line; opening the controller repairs it');
      const keep = v.records.map((r) => JSON.stringify(r) + '\n').join('');
      writeFileAtomic(file, keep);
    } else if (v.records.length > 0 && !fs.readFileSync(file, 'utf8').endsWith('\n')) {
      // A crash after writing the last record but before its newline; terminate it so the
      // next append starts on a fresh line.
      appendLineDurable(file, '');
    }
    const j = new Journal(file, key);
    j.onAppend = opts.onAppend;
    j.recordsCache = v.records;
    const last = v.records[v.records.length - 1];
    if (last) {
      j.lastSeq = last.seq;
      j.lastMac = last.mac;
    }
    return j;
  }

  append<T>(type: string, data: T): JournalRecord<T> {
    if (this.failed) throw new JournalTamperError(`no further appends: recording an earlier one failed (${this.failed.message})`);
    const base = { seq: this.lastSeq + 1, ts: new Date().toISOString(), type, data, prev: this.lastMac };
    const rec: JournalRecord<T> = { ...base, mac: macOf(this.key, base) };
    appendLineDurable(this.file, JSON.stringify(rec));
    this.lastSeq = rec.seq;
    this.lastMac = rec.mac;
    this.recordsCache.push(rec);
    this.appendsThisProcess++;
    if (process.env['EO_CRASH_PHASE'] !== 'anchor') crashHook(this.appendsThisProcess, 'journal append');
    try {
      this.onAppend?.(rec);
    } catch (err) {
      this.failed = err as Error;
      throw err;
    }
    if (process.env['EO_CRASH_PHASE'] === 'anchor') crashHook(this.appendsThisProcess, 'anchor update for journal append');
    return rec;
  }

  records(): readonly JournalRecord[] {
    return this.recordsCache;
  }

  ofType<T>(type: string): JournalRecord<T>[] {
    return this.recordsCache.filter((r) => r.type === type) as JournalRecord<T>[];
  }
}

/**
 * Test-only crash injection: with EO_CRASH_AT=N the process exits abruptly right after its
 * Nth durable journal append, before the rollback anchor records it, simulating a kill at
 * that step boundary. With EO_CRASH_PHASE=anchor it exits right after the anchor update
 * instead. Production runs never set either; `eo doctor` reports when they are set.
 */
function crashHook(count: number, what: string): void {
  const at = process.env['EO_CRASH_AT'];
  if (at !== undefined && Number(at) === count) {
    process.stderr.write(`eo: injected crash after ${what} #${count}\n`);
    process.exit(137);
  }
}
