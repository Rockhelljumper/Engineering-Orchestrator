import { assertPrivateStateRoot, readStoreConfig, type StateRootPaths } from '../stateRoot.ts';
import { BeadsStore } from './beads.ts';
import { FakeStore } from './fake.ts';
import { StoreError, type TaskStore } from './types.ts';
import type { JournalRecord } from '../journal.ts';

/**
 * Open the TaskStore a state root is configured for (store.json). Only the controller, which
 * holds the controller lock, may create the store; read-only commands pass create: false.
 */
export function openStore(paths: StateRootPaths, opts: { create: boolean; records?: readonly JournalRecord[] }): TaskStore {
  try {
    assertPrivateStateRoot(paths);
  } catch (err) {
    throw new StoreError(`unsafe state root: ${(err as Error).message}`);
  }
  const cfg = readStoreConfig(paths);
  const bound = opts.records?.find((r) => r.type === 'store.bound')?.data as { kind: string } | undefined;
  if (bound && bound.kind !== cfg.kind) throw new StoreError(`store.json says ${cfg.kind}, but this state root is bound to the ${bound.kind} store`);
  return cfg.kind === 'beads' ? BeadsStore.atDir(paths.store, { bin: cfg.bin, create: opts.create }) : FakeStore.atDir(paths.store);
}
