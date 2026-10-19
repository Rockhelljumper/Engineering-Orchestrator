// Child process for the concurrent-claim test (M1-3). For each round it waits for the
// coordinator's go file, races to claim the ready task, and writes what it got.
import * as fs from 'node:fs';
import * as path from 'node:path';
import { FakeStore } from '../../src/store/fake.ts';
import { BeadsStore } from '../../src/store/beads.ts';
import { sleepSync } from '../../src/util/lock.ts';

const [storeDir, barrierDir, workerId, roundsArg, kind, bdBin] = process.argv.slice(2) as [string, string, string, string, string, string];
const store = kind === 'beads' ? BeadsStore.atDir(storeDir, { bin: bdBin, create: false }) : FakeStore.atDir(storeDir);
const rounds = Number(roundsArg);
fs.writeFileSync(path.join(barrierDir, `up-${workerId}`), '');
for (let r = 1; r <= rounds; r++) {
  const go = path.join(barrierDir, `go-${r}`);
  const deadline = Date.now() + (kind === 'beads' ? 600_000 : 60_000);
  while (!fs.existsSync(go)) {
    if (Date.now() > deadline) process.exit(3);
    sleepSync(1);
  }
  const t = store.claimReady(`w${workerId}`, 60_000, Date.now());
  fs.writeFileSync(path.join(barrierDir, `res-${r}-${workerId}`), t?.id ?? '');
}
