import { readStoreConfig, type StateRootPaths } from '../stateRoot.ts';
import { BeadsStore } from './beads.ts';
import { FakeStore } from './fake.ts';
import type { TaskStore } from './types.ts';

/** Open the TaskStore a state root is configured for (store.json). */
export function openStore(paths: StateRootPaths): TaskStore {
  const cfg = readStoreConfig(paths);
  return cfg.kind === 'beads' ? BeadsStore.atDir(paths.store, { bin: cfg.bin }) : FakeStore.atDir(paths.store);
}
