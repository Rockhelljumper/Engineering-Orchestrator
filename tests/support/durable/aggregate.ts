import * as fs from 'node:fs';
import * as path from 'node:path';
import { FILES, fileSha256, identityDiff, identitySha256, readLog, type CheckpointRecord, type Manifest, type RunIdentity } from './checkpoints.ts';

export type RunStatus = 'RUNNING' | 'PASSED' | 'FAILED' | 'INTERRUPTED' | 'INCOMPLETE' | 'STALE' | 'NOT_VERIFIED';

export interface ScenarioState {
  id: string;
  passes: number;
  fails: number;
  interrupted: number;
  /** Started (in the latest attempt) without an end record. */
  open: boolean;
}

export interface Aggregate {
  status: RunStatus;
  reasons: string[];
  runId: string | null;
  suite: string | null;
  identity: RunIdentity | null;
  declared: number;
  passed: number;
  failed: string[];
  missing: string[];
  /** Scenarios whose run was cut short (an end record "interrupted", or a start with no end). */
  interrupted: string[];
  records: number;
  chainHead: { seq: number; hash: string } | null;
  /** True when the log's integrity failed: resume sets it aside and reruns every scenario. */
  integrityFailed: boolean;
  /**
   * True when manifest.json is not the manifest the records were written for. Nothing in the
   * run directory says which scenarios were declared then, so such a run is NOT_VERIFIED and
   * is never resumed: rerunning under an edited manifest could drop a failed scenario.
   */
  manifestChanged: boolean;
  heartbeatAgeS: number | null;
}

export function readManifest(dir: string): { manifest: Manifest; sha256: string } | { error: string } {
  const f = path.join(dir, FILES.manifest);
  try {
    const manifest = JSON.parse(fs.readFileSync(f, 'utf8')) as Manifest;
    if (manifest.version !== 1 || typeof manifest.runId !== 'string' || !Array.isArray(manifest.scenarios) || typeof manifest.identity !== 'object') return { error: 'manifest.json is malformed' };
    const ids = manifest.scenarios.map((s) => s.id);
    if (new Set(ids).size !== ids.length) return { error: 'manifest.json declares a scenario twice' };
    if (ids.length === 0) return { error: 'manifest.json declares no scenarios' };
    return { manifest, sha256: fileSha256(f) };
  } catch (err) {
    return { error: `manifest.json: ${(err as Error).message}` };
  }
}

export function heartbeatAgeS(dir: string, now = Date.now()): number | null {
  try {
    const hb = JSON.parse(fs.readFileSync(path.join(dir, FILES.heartbeat), 'utf8')) as { ts: string };
    const t = Date.parse(hb.ts);
    return Number.isFinite(t) ? Math.max(0, (now - t) / 1000) : null;
  } catch {
    return null;
  }
}

/**
 * The status of a run, from its manifest and checkpoint log alone. PASSED needs every declared
 * scenario to have exactly one passing record and no failing one, every record to carry the
 * manifest's identity, an intact log, and (when `current` is given) the identity of the
 * checkout under review. Anything missing or unreadable is NOT_VERIFIED or FAILED, never PASSED.
 */
export function aggregate(dir: string, current?: RunIdentity, now = Date.now()): Aggregate {
  const empty: Aggregate = { status: 'NOT_VERIFIED', reasons: [], runId: null, suite: null, identity: null, declared: 0, passed: 0, failed: [], missing: [], interrupted: [], records: 0, chainHead: null, integrityFailed: false, manifestChanged: false, heartbeatAgeS: heartbeatAgeS(dir, now) };
  const m = readManifest(dir);
  if ('error' in m) return { ...empty, reasons: [m.error] };
  const { manifest } = m;
  const base: Aggregate = { ...empty, runId: manifest.runId, suite: manifest.suite, identity: manifest.identity, declared: manifest.scenarios.length };
  const log = readLog(dir, manifest.runId);
  const records = log.records;
  const last = records.at(-1);
  base.records = records.length;
  base.chainHead = last ? { seq: last.seq, hash: last.hash } : null;
  const reasons: string[] = [];

  // 1. The manifest the records were written for.
  const changed = records.filter((r) => r.manifestSha256 !== m.sha256).map((r) => r.seq);
  if (changed.length > 0) {
    return { ...base, status: 'NOT_VERIFIED', manifestChanged: true, reasons: [`records ${changed.slice(0, 5).join(', ')}${changed.length > 5 ? ', ...' : ''} were written for a different manifest (manifest.json changed); this run cannot be verified or resumed, start a new one`] };
  }

  // 2. Integrity of the evidence itself.
  const integrity = [...log.integrity];
  const want = identitySha256(manifest.identity);
  for (const r of records) {
    if (identitySha256(r.identity) !== want) integrity.push(`record ${r.seq}: identity differs from the manifest (${identityDiff(manifest.identity, r.identity).join(', ')})`);
  }
  // Each end closes the start of the same scenario, attempt and runner just before it in that
  // runner's records: an end appended on its own is not a result.
  const openStart = new Map<string, CheckpointRecord>();
  for (const r of records) {
    if (r.kind === 'scenario.start' && r.scenario !== undefined) openStart.set(r.invocation, r);
    if (r.kind === 'scenario.end') {
      const st = openStart.get(r.invocation);
      if (!st || st.scenario !== r.scenario || st.attempt !== r.attempt) integrity.push(`record ${r.seq}: an end for ${r.scenario} attempt ${r.attempt} with no matching start by the same runner`);
      openStart.delete(r.invocation);
    }
  }
  const declared = new Set(manifest.scenarios.map((s) => s.id));
  for (const r of records) if (r.scenario !== undefined && !declared.has(r.scenario)) integrity.push(`record ${r.seq}: scenario ${r.scenario} is not in the manifest`);
  if (integrity.length > 0) return { ...base, status: 'FAILED', reasons: integrity, integrityFailed: true };

  // 3. Results for the checkout under review only.
  if (current && identitySha256(current) !== want) {
    return { ...base, status: 'STALE', reasons: [`the run's identity differs from the checkout under review in: ${identityDiff(manifest.identity, current).join(', ')}`] };
  }

  // 4. Per-scenario tally. Only the records after the last reset count.
  const resetAt = records.map((r) => r.kind).lastIndexOf('run.reset');
  const live = records.slice(resetAt + 1);
  const states = new Map<string, ScenarioState>(manifest.scenarios.map((s) => [s.id, { id: s.id, passes: 0, fails: 0, interrupted: 0, open: false }]));
  for (const r of live) {
    const s = r.scenario === undefined ? undefined : states.get(r.scenario);
    if (!s) continue;
    if (r.kind === 'scenario.start') s.open = true;
    if (r.kind === 'scenario.end') {
      s.open = false;
      if (r.result === 'pass') s.passes++;
      else if (r.result === 'fail') s.fails++;
      else s.interrupted++;
    }
  }
  const all = [...states.values()];
  const failed = all.filter((s) => s.fails > 0).map((s) => s.id);
  const twice = all.filter((s) => s.passes > 1).map((s) => s.id);
  const passed = all.filter((s) => s.passes === 1 && s.fails === 0).length;
  const missing = all.filter((s) => s.passes === 0 && s.fails === 0).map((s) => s.id);
  const interrupted = all.filter((s) => s.passes === 0 && s.fails === 0 && (s.open || s.interrupted > 0)).map((s) => s.id);
  const out = { ...base, passed, failed, missing, interrupted };
  if (twice.length > 0) return { ...out, status: 'FAILED', reasons: [`counted twice: ${twice.join(', ')}`] };
  if (failed.length > 0) return { ...out, status: 'FAILED', reasons: [`failed: ${failed.join(', ')}`] };
  if (missing.length === 0) return { ...out, status: 'PASSED', reasons };

  // 5. Not finished: still running, stopped early, or its runner is gone.
  const age = base.heartbeatAgeS;
  const ended = last?.kind === 'run.end';
  if (!ended && age !== null && age <= manifest.stallWindowS) return { ...out, status: 'RUNNING', reasons: [`${missing.length} of ${manifest.scenarios.length} scenarios to go`] };
  if (ended) return { ...out, status: 'INCOMPLETE', reasons: [`the runner finished with ${missing.length} scenarios not run: ${missing.join(', ')}`] };
  return { ...out, status: 'INTERRUPTED', reasons: [`no heartbeat for ${age === null ? 'ever' : `${Math.round(age)} s`} (stall window ${manifest.stallWindowS} s); ${missing.length} scenarios not finished`] };
}

/** The records of the latest start or resume of a run, for reports. */
export function lastInvocation(records: readonly CheckpointRecord[]): CheckpointRecord[] {
  const i = records.map((r) => r.kind === 'run.start' || r.kind === 'run.resume').lastIndexOf(true);
  return i < 0 ? [] : records.slice(i);
}
