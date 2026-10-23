import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { spawnSync } from 'node:child_process';
import { canonicalJson, sha256Hex } from '../../../src/util/canonical.ts';
import { appendLineDurable, writeFileAtomic } from '../../../src/util/fsx.ts';

/**
 * Durable checkpoints for long-running test suites (M2-0).
 *
 * A run directory holds everything about one run of one suite, on storage that outlives the
 * runner, its worker processes and the container:
 *
 *   manifest.json      the run's identity and the full list of scenarios, written once
 *   checkpoints.jsonl  append-only, fsynced, hash-chained records (one start and one end per scenario attempt)
 *   head.json          seq and hash of the last record, replaced atomically after each append
 *   heartbeat.json     the active runner's liveness, replaced every few seconds
 *   aggregate.json     the result computed from the above (informational; recomputed on every read)
 *   work/              a fresh directory per scenario attempt, removed when it passes
 *   forensics/         logs set aside after an integrity failure
 *
 * The chain and the head file catch a truncated, reordered or edited log and a crash between
 * the append and the head update (the log is then exactly one record ahead). They do not stop
 * someone who rewrites the log and the head consistently; the run directory must be writable
 * only by the person running the suite.
 */

export interface RunIdentity {
  /** HEAD of the checkout the suite runs from. */
  commit: string;
  /** Uncommitted or untracked changes in the checkout. */
  dirty: boolean;
  /** SHA-256 over every source, test and fixture file as on disk (so it changes with an uncommitted edit). */
  testSourceSha256: string;
  /** SHA-256 of every binary the suite executes. */
  binaries: Record<string, string>;
  /** The suite, its parameters and every environment variable the suites read. */
  config: Record<string, unknown>;
  configSha256: string;
  platform: { os: string; arch: string; node: string };
}

export interface Manifest {
  version: 1;
  runId: string;
  suite: string;
  /** The suite's parameters as given; part of the identity. */
  params: Record<string, unknown>;
  /** What planning found (baseline states, the number of boundaries); fixed for the run. */
  derived: Record<string, unknown>;
  scenarios: Array<{ id: string; seed?: number }>;
  identity: RunIdentity;
  createdAt: string;
  /** A runner whose heartbeat is older than this is gone (INTERRUPTED). */
  stallWindowS: number;
}

export type ScenarioResult = 'pass' | 'fail' | 'interrupted';

export interface CheckpointRecord {
  seq: number;
  prev: string;
  ts: string;
  runId: string;
  manifestSha256: string;
  identity: RunIdentity;
  /** The runner process that wrote it (a resumed run has a new one). */
  invocation: string;
  /** Not part of the identity: they change across container restarts. */
  host: { name: string; kernel: string; pid: number };
  kind: 'run.start' | 'run.resume' | 'run.reset' | 'scenario.start' | 'scenario.end' | 'run.end';
  scenario?: string;
  seed?: number;
  attempt?: number;
  result?: ScenarioResult;
  startedAt?: string;
  endedAt?: string;
  detail?: string;
  data?: Record<string, unknown>;
  hash: string;
}

export const FILES = { manifest: 'manifest.json', log: 'checkpoints.jsonl', head: 'head.json', heartbeat: 'heartbeat.json', aggregate: 'aggregate.json', lock: 'runner.lock' } as const;

/** Environment variables the suites read; recorded in the identity. */
export const CONFIG_ENV = ['EO_TEST_STORE', 'EO_BD_BIN', 'EO_REQUIRE_BD', 'EO_REQUIRE_TRACE'] as const;

const SOURCE_PATHS = ['src', 'tests', 'fixtures', 'package.json', 'tsconfig.json', 'deps.lock.json'];

function git(repo: string, args: string[]): string | null {
  const r = spawnSync('git', ['-C', repo, ...args], { encoding: 'utf8' });
  return r.status === 0 ? r.stdout : null;
}

export function fileSha256(file: string): string {
  return sha256Hex(fs.readFileSync(file));
}

export function computeIdentity(repo: string, suite: string, params: Record<string, unknown>, overrides: Partial<RunIdentity> = {}): RunIdentity {
  const commit = git(repo, ['rev-parse', 'HEAD'])?.trim() ?? 'none';
  const status = git(repo, ['status', '--porcelain']);
  const files = (git(repo, ['ls-files', '-co', '--exclude-standard', '-z', '--', ...SOURCE_PATHS]) ?? '').split('\0').filter(Boolean).sort();
  const parts = files.filter((f) => fs.existsSync(path.join(repo, f))).map((f) => `${f}\0${fileSha256(path.join(repo, f))}`);
  const binaries: Record<string, string> = { node: fileSha256(process.execPath) };
  if (process.env['EO_BD_BIN']) binaries['bd'] = fileSha256(process.env['EO_BD_BIN']);
  const env: Record<string, string | null> = {};
  for (const k of CONFIG_ENV) env[k] = process.env[k] ?? null;
  const config = { suite, params, env };
  return {
    commit,
    dirty: status === null || status.trim() !== '',
    testSourceSha256: sha256Hex(parts.join('\n')),
    binaries,
    config,
    configSha256: sha256Hex(canonicalJson(config)),
    platform: { os: process.platform, arch: process.arch, node: process.version },
    ...overrides,
  };
}

export function identitySha256(i: RunIdentity): string {
  return sha256Hex(canonicalJson(i));
}

/** Which identity fields differ (for STALE and mixed-identity reports). */
export function identityDiff(a: RunIdentity, b: RunIdentity): string[] {
  const out: string[] = [];
  for (const k of Object.keys(a) as Array<keyof RunIdentity>) if (canonicalJson(a[k]) !== canonicalJson(b[k])) out.push(k);
  return out;
}

export function recordHash(r: Omit<CheckpointRecord, 'hash'>): string {
  return sha256Hex(canonicalJson(r));
}

export function genesis(runId: string): string {
  return `genesis:${runId}`;
}

export interface LogRead {
  records: CheckpointRecord[];
  /** Problems that make the log untrustworthy (truncated, edited, reordered). */
  integrity: string[];
  /** The last line was cut off by a crash mid-write; ignored. */
  tornTail: boolean;
}

/** Read and verify a run's log against its chain and head file. */
export function readLog(dir: string, runId: string): LogRead {
  const integrity: string[] = [];
  const records: CheckpointRecord[] = [];
  const file = path.join(dir, FILES.log);
  let text = '';
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== 'ENOENT') integrity.push(`log unreadable: ${(err as Error).message}`);
  }
  const lines = text.split('\n');
  const endsClean = text.length === 0 || text.endsWith('\n');
  if (lines[lines.length - 1] === '') lines.pop();
  let tornTail = false;
  let prev = genesis(runId);
  for (const [i, line] of lines.entries()) {
    let r: CheckpointRecord;
    try {
      r = JSON.parse(line) as CheckpointRecord;
    } catch {
      if (i === lines.length - 1 && !endsClean) {
        tornTail = true;
        break;
      }
      integrity.push(`line ${i + 1}: not valid JSON`);
      break;
    }
    const { hash, ...rest } = r;
    if (r.seq !== records.length + 1) integrity.push(`line ${i + 1}: seq ${r.seq}, expected ${records.length + 1}`);
    if (r.prev !== prev) integrity.push(`line ${i + 1}: chain broken`);
    if (hash !== recordHash(rest)) integrity.push(`line ${i + 1}: hash mismatch (record edited)`);
    if (r.runId !== runId) integrity.push(`line ${i + 1}: belongs to run ${r.runId}`);
    if (integrity.length > 0) break;
    prev = hash;
    records.push(r);
  }
  // The head is written after each append: the log may be one record past it (a crash in
  // between), never behind it.
  const headFile = path.join(dir, FILES.head);
  if (integrity.length === 0) {
    if (fs.existsSync(headFile)) {
      let head: { seq: number; hash: string } | undefined;
      try {
        head = JSON.parse(fs.readFileSync(headFile, 'utf8')) as { seq: number; hash: string };
      } catch {
        integrity.push('head.json is unreadable');
      }
      if (head) {
        const at = records[head.seq - 1];
        if (head.seq > records.length) integrity.push(`log truncated: ${records.length} records, head says ${head.seq}`);
        else if (!at || at.hash !== head.hash) integrity.push(`record ${head.seq} differs from head.json (log altered)`);
        else if (records.length > head.seq + 1) integrity.push(`log is ${records.length - head.seq} records past head.json; a crash leaves at most one`);
      }
    } else if (records.length > 1) {
      integrity.push('head.json is missing');
    }
  }
  return { records, integrity, tornTail };
}

/** Appends to a run's log; one writer at a time (the runner lock). */
export class CheckpointWriter {
  private seq: number;
  private prev: string;
  private readonly base: Pick<CheckpointRecord, 'runId' | 'manifestSha256' | 'identity' | 'invocation' | 'host'>;

  readonly dir: string;

  constructor(dir: string, manifest: Manifest, manifestSha256: string, invocation: string, existing: readonly CheckpointRecord[]) {
    this.dir = dir;
    const last = existing.at(-1);
    this.seq = last?.seq ?? 0;
    this.prev = last?.hash ?? genesis(manifest.runId);
    this.base = { runId: manifest.runId, manifestSha256, identity: manifest.identity, invocation, host: { name: os.hostname(), kernel: os.release(), pid: process.pid } };
  }

  append(r: Omit<CheckpointRecord, 'seq' | 'prev' | 'ts' | 'hash' | 'runId' | 'manifestSha256' | 'identity' | 'invocation' | 'host'>): CheckpointRecord {
    const rest = { seq: this.seq + 1, prev: this.prev, ts: new Date().toISOString(), ...this.base, ...r };
    const rec: CheckpointRecord = { ...rest, hash: recordHash(rest) };
    appendLineDurable(path.join(this.dir, FILES.log), JSON.stringify(rec));
    writeFileAtomic(path.join(this.dir, FILES.head), JSON.stringify({ seq: rec.seq, hash: rec.hash }) + '\n');
    this.seq = rec.seq;
    this.prev = rec.hash;
    return rec;
  }
}
