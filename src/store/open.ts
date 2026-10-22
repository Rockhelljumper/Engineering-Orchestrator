import { assertPrivateStateRoot, readStoreConfig, type StateRootPaths } from '../stateRoot.ts';
import { BeadsStore } from './beads.ts';
import { FakeStore } from './fake.ts';
import { StoreError, type TaskStore } from './types.ts';
import type { JournalRecord } from '../journal.ts';

/**
 * Open the TaskStore a state root is configured for (store.json). Only the controller, which
 * holds the controller lock, may create the store; read-only commands pass create: false.
 */
export function openStore(paths: StateRootPaths, opts: { create: boolean; records?: readonly JournalRecord[]; evidenceOrEscalations?: boolean }): TaskStore {
  try {
    assertPrivateStateRoot(paths);
  } catch (err) {
    throw new StoreError(`unsafe state root: ${(err as Error).message}`);
  }
  const cfg = readStoreConfig(paths);
  const bound = opts.records?.find((r) => r.type === 'store.bound')?.data as { kind: string } | undefined;
  if (bound && bound.kind !== cfg.kind) throw new StoreError(`store.json says ${cfg.kind}, but this state root is bound to the ${bound.kind} store`);
  if (cfg.kind === 'beads') {
    // A store is initialised once, on the controller's first open, before anything is
    // journaled. Once the journal holds any record, or evidence or escalations exist, a store
    // without its marker was damaged or replaced; re-initialising would erase what is left of
    // it, so refuse and leave it for a human. Only a crash during that first bd init is repaired.
    const established = (opts.records?.length ?? 0) > 0 || opts.evidenceOrEscalations === true;
    if (established && !BeadsStore.isInitialised(paths.store)) {
      throw new StoreError(`the beads store at ${paths.store} is not initialised, but this state root is already in use (journal records, evidence or escalations); refusing to re-initialise it`);
    }
    return BeadsStore.atDir(paths.store, { bin: cfg.bin, create: opts.create && !established });
  }
  return FakeStore.atDir(paths.store);
}
