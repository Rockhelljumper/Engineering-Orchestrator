import * as fs from 'node:fs';
import * as path from 'node:path';
import { timingSafeEqual } from 'node:crypto';
import { canonicalJson, hmacHex, sha256Hex } from './util/canonical.ts';
import { writeFileAtomic } from './util/fsx.ts';

export interface ManifestEntry {
  name: string;
  sha256: string;
  bytes: number;
}

export interface EvidenceManifest {
  taskId: string;
  attempt: number;
  createdAt: string;
  entries: ManifestEntry[];
  /** Free-form facts the gate engine relies on (e.g. exit codes, test counts). */
  facts: Record<string, unknown>;
  mac: string;
}

const SAFE_NAME = /^[A-Za-z0-9._-]{1,100}$/;
const SAFE_ID = /^[A-Za-z0-9._-]{1,100}$/;

/**
 * Evidence lives in the state root under evidence/<task>/<attempt>/. The manifest lists
 * every artifact with its SHA-256 and carries an HMAC over the whole manifest.
 */
export class EvidenceLedger {
  readonly dir: string;
  private readonly key: Buffer;

  constructor(dir: string, key: Buffer) {
    this.dir = dir;
    this.key = key;
  }

  attemptDir(taskId: string, attempt: number): string {
    if (!SAFE_ID.test(taskId)) throw new Error(`unsafe task id for evidence path: ${taskId}`);
    if (!Number.isInteger(attempt) || attempt < 1) throw new Error(`bad attempt number: ${attempt}`);
    return path.join(this.dir, taskId, `a${attempt}`);
  }

  writeArtifact(taskId: string, attempt: number, name: string, content: string | Buffer): ManifestEntry {
    if (!SAFE_NAME.test(name) || name === 'manifest.json') throw new Error(`unsafe artifact name: ${name}`);
    const file = path.join(this.attemptDir(taskId, attempt), name);
    writeFileAtomic(file, content);
    const buf = typeof content === 'string' ? Buffer.from(content) : content;
    return { name, sha256: sha256Hex(buf), bytes: buf.length };
  }

  seal(taskId: string, attempt: number, entries: ManifestEntry[], facts: Record<string, unknown>): EvidenceManifest {
    const body = { taskId, attempt, createdAt: new Date().toISOString(), entries, facts };
    const manifest: EvidenceManifest = { ...body, mac: hmacHex(this.key, canonicalJson(body)) };
    writeFileAtomic(path.join(this.attemptDir(taskId, attempt), 'manifest.json'), JSON.stringify(manifest, null, 2));
    return manifest;
  }

  read(taskId: string, attempt: number): EvidenceManifest | null {
    const file = path.join(this.attemptDir(taskId, attempt), 'manifest.json');
    if (!fs.existsSync(file)) return null;
    try {
      return JSON.parse(fs.readFileSync(file, 'utf8')) as EvidenceManifest;
    } catch {
      return null;
    }
  }

  /** Recompute the MAC and every artifact hash. Returns a list of problems (empty = valid). */
  verify(taskId: string, attempt: number): string[] {
    const m = this.read(taskId, attempt);
    if (m === null) return [fs.existsSync(path.join(this.attemptDir(taskId, attempt), 'manifest.json')) ? 'manifest unreadable' : 'manifest missing'];
    if (typeof m !== 'object' || !Array.isArray(m.entries) || typeof m.mac !== 'string') return ['manifest malformed'];
    const problems: string[] = [];
    const { mac, ...body } = m;
    if (!macEqual(hmacHex(this.key, canonicalJson(body)), mac)) problems.push('manifest MAC mismatch');
    if (m.taskId !== taskId || m.attempt !== attempt) problems.push('manifest identity mismatch');
    for (const e of m.entries) {
      if (typeof e !== 'object' || e === null || typeof e.name !== 'string' || !SAFE_NAME.test(e.name)) {
        problems.push(`unsafe entry name ${String((e as { name?: unknown } | null)?.name)}`);
        continue;
      }
      const file = path.join(this.attemptDir(taskId, attempt), e.name);
      if (!fs.existsSync(file)) {
        problems.push(`${e.name} missing`);
        continue;
      }
      const actual = sha256Hex(fs.readFileSync(file));
      if (actual !== e.sha256) problems.push(`${e.name} hash mismatch`);
    }
    return problems;
  }
}

function macEqual(a: string, b: string): boolean {
  const ba = Buffer.from(a, 'hex');
  const bb = Buffer.from(b, 'hex');
  return ba.length === bb.length && ba.length > 0 && timingSafeEqual(ba, bb);
}
