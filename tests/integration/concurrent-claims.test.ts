import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { spawn, type ChildProcess } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { FakeStore } from '../../src/store/fake.ts';
import { FileLock, sleepSync } from '../../src/util/lock.ts';
import { REPO_ROOT, tmpDir } from '../support/helpers.ts';

const WORKERS = 20;
const ROUNDS = 100;

function waitFor(cond: () => boolean, what: string, ms = 60_000): void {
  const deadline = Date.now() + ms;
  while (!cond()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    sleepSync(2);
  }
}

test(`M1-3: ${WORKERS} processes race for one ready task, exactly one winner, ${ROUNDS} rounds in a row`, { timeout: 300_000 }, async () => {
  const dir = tmpDir('eo-claims-');
  const storeDir = path.join(dir, 'store');
  const barrier = path.join(dir, 'barrier');
  fs.mkdirSync(barrier);
  const store = FakeStore.atDir(storeDir);
  const worker = path.join(REPO_ROOT, 'tests', 'support', 'claim-worker.ts');
  const children: ChildProcess[] = [];
  const exits: Array<Promise<number | null>> = [];
  for (let w = 0; w < WORKERS; w++) {
    const c = spawn(process.execPath, [worker, storeDir, barrier, String(w), String(ROUNDS)], { stdio: ['ignore', 'ignore', 'inherit'] });
    children.push(c);
    exits.push(new Promise((resolve) => c.on('exit', (code) => resolve(code))));
  }
  try {
    waitFor(() => fs.readdirSync(barrier).filter((f) => f.startsWith('up-')).length === WORKERS, 'workers to start');
    const tally: number[] = [];
    for (let r = 1; r <= ROUNDS; r++) {
      const id = `R${String(r).padStart(3, '0')}`;
      store.createTask({ id, epicId: 'E', title: id, deps: [] });
      store.compareAndSetState(id, 'planned', 'ready');
      fs.writeFileSync(path.join(barrier, `go-${r}`), '');
      waitFor(() => fs.readdirSync(barrier).filter((f) => f.startsWith(`res-${r}-`)).length === WORKERS, `round ${r} results`);
      const results = Array.from({ length: WORKERS }, (_, w) => fs.readFileSync(path.join(barrier, `res-${r}-${w}`), 'utf8'));
      const winners = results.filter((x) => x !== '');
      assert.equal(winners.length, 1, `round ${r}: ${winners.length} winners`);
      assert.equal(winners[0], id);
      const owner = store.get(id)?.claim?.owner;
      assert.equal(owner, `w${results.indexOf(id)}`, `round ${r}: the store's claim owner is the reported winner`);
      // Retire the task so the next round has exactly one ready task.
      store.compareAndSetState(id, 'ready', 'done');
      tally.push(winners.length);
    }
    assert.equal(tally.length, ROUNDS);
    const codes = await Promise.all(exits);
    assert.deepEqual(codes, Array(WORKERS).fill(0));
  } finally {
    for (const c of children) if (c.exitCode === null) c.kill('SIGKILL');
  }
});

test('a lock left by a killed process is taken over, and a live one is not', async () => {
  const dir = tmpDir();
  const storeDir = path.join(dir, 'store');
  const store = FakeStore.atDir(storeDir);
  store.createTask({ id: 'A', epicId: 'E', title: 'a', deps: [] });
  // A child takes the store lock and is killed while holding it.
  const holder = spawn(process.execPath, [
    '--input-type=module',
    '-e',
    `import { FileLock } from ${JSON.stringify(pathToFileURL(path.join(REPO_ROOT, 'src', 'util', 'lock.ts')).href)};
     new FileLock(${JSON.stringify(path.join(storeDir, 'tasks.lock'))}, 'holder').acquire();
     process.stdout.write('held\\n'); setInterval(() => {}, 1000);`,
  ]);
  await new Promise<void>((resolve) => holder.stdout?.once('data', () => resolve()));
  assert.equal(new FileLock(path.join(storeDir, 'tasks.lock'), 'contender').tryAcquire(), false, 'a live holder keeps its lock');
  const started = Date.now();
  holder.kill('SIGKILL');
  await new Promise((resolve) => holder.on('exit', resolve));
  assert.equal(store.compareAndSetState('A', 'planned', 'ready'), true, 'stale lock taken over');
  assert.ok(Date.now() - started < 5_000);
});
