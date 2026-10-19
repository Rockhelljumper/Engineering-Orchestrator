import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { randomBytes } from 'node:crypto';
import { assertPrivateDir, writeFileAtomic } from './util/fsx.ts';
import { defaultPolicy, savePolicy } from './policy.ts';

/**
 * The state root holds everything the controller owns: policy, journal and its HMAC key,
 * task store, evidence and escalations. It must live outside every workspace and outside
 * the isolation boundary (architecture §3).
 */
export interface StateRootPaths {
  root: string;
  policy: string;
  journal: string;
  journalKey: string;
  store: string;
  evidence: string;
  escalations: string;
  locks: string;
  controllerLock: string;
  /** Which TaskStore backs this state root (absent: FakeStore, for state roots made before beads). */
  storeConfig: string;
}

export type StoreConfig = { kind: 'fake' } | { kind: 'beads'; bin: string };

export function defaultStateRoot(project = 'default'): string {
  if (process.platform === 'win32') {
    const base = process.env['LOCALAPPDATA'] ?? path.join(os.homedir(), 'AppData', 'Local');
    return path.join(base, 'eo', project);
  }
  const base = process.env['XDG_STATE_HOME'] ?? path.join(os.homedir(), '.local', 'state');
  return path.join(base, 'eo', project);
}

export function statePaths(root: string): StateRootPaths {
  const r = path.resolve(root);
  return {
    root: r,
    policy: path.join(r, 'policy.json'),
    journal: path.join(r, 'journal.jsonl'),
    journalKey: path.join(r, 'journal.key'),
    store: path.join(r, 'store'),
    evidence: path.join(r, 'evidence'),
    escalations: path.join(r, 'escalations'),
    locks: path.join(r, 'locks'),
    controllerLock: path.join(r, 'locks', 'controller.lock'),
    storeConfig: path.join(r, 'store.json'),
  };
}

export function isInitialised(root: string): boolean {
  const p = statePaths(root);
  return fs.existsSync(p.policy) && fs.existsSync(p.journalKey);
}

/**
 * Create the layout, a fresh 256-bit journal key and the default policy. Refuses a root that
 * holds any part of an earlier state root (a key, a journal, a store or its config), even if
 * policy.json is gone: a new key would make the existing journal and evidence unverifiable.
 */
export function initStateRoot(root: string, store: StoreConfig = { kind: 'fake' }): StateRootPaths {
  const p = statePaths(root);
  if (isInitialised(root)) throw new Error(`state root already initialised: ${p.root}`);
  const leftovers = [p.journalKey, p.journal, p.storeConfig].filter((f) => fs.existsSync(f));
  if (fs.existsSync(p.store) && fs.readdirSync(p.store).length > 0) leftovers.push(p.store);
  if (leftovers.length > 0) throw new Error(`state root ${p.root} holds an earlier state root (${leftovers.join(', ')}); refusing to initialise over it`);
  for (const dir of [p.root, p.store, p.evidence, p.escalations, p.locks]) fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  assertPrivateDir(p.root);
  assertPrivateDir(p.store);
  writeFileAtomic(p.journalKey, randomBytes(32).toString('hex'), 0o600);
  writeFileAtomic(p.storeConfig, JSON.stringify(store.kind === 'beads' ? { kind: 'beads', bin: path.resolve(store.bin) } : store, null, 2) + '\n');
  savePolicy(p.policy, defaultPolicy());
  return p;
}

/** Refuse a state root, or its store directory, that others could change (see assertPrivateDir). */
export function assertPrivateStateRoot(p: StateRootPaths): void {
  assertPrivateDir(p.root);
  if (fs.existsSync(p.store)) assertPrivateDir(p.store);
}

export function readStoreConfig(p: StateRootPaths): StoreConfig {
  if (!fs.existsSync(p.storeConfig)) return { kind: 'fake' };
  const c = JSON.parse(fs.readFileSync(p.storeConfig, 'utf8')) as Partial<{ kind: string; bin: string }>;
  if (c.kind === 'fake') return { kind: 'fake' };
  if (c.kind === 'beads' && typeof c.bin === 'string' && c.bin !== '') return { kind: 'beads', bin: c.bin };
  throw new Error(`${p.storeConfig} is malformed`);
}

export function readJournalKey(p: StateRootPaths): Buffer {
  const hex = fs.readFileSync(p.journalKey, 'utf8').trim();
  if (!/^[0-9a-f]{64}$/.test(hex)) throw new Error('journal key is malformed');
  return Buffer.from(hex, 'hex');
}
