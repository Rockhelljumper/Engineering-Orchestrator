import { describe, test } from 'node:test';
import assert from 'node:assert/strict';
import * as path from 'node:path';
import { FakeStore } from '../../src/store/fake.ts';
import { BeadsStore } from '../../src/store/beads.ts';
import type { TaskStore } from '../../src/store/types.ts';
import { BD_BIN, tmpDir } from '../support/helpers.ts';

/**
 * The TaskStore contract. Every adapter must pass it unchanged (M1-2). It runs against
 * FakeStore in memory and file-backed, and against BeadsStore driving the real, pinned `bd`
 * binary named by EO_BD_BIN (see tests/support/helpers.ts for when its absence is an error).
 */
const factories: Array<{ name: string; make: () => { store: TaskStore; reopen?: () => TaskStore } }> = [
  { name: 'FakeStore (memory)', make: () => ({ store: FakeStore.inMemory() }) },
  {
    name: 'FakeStore (file)',
    make: () => {
      const dir = path.join(tmpDir(), 'store');
      return { store: FakeStore.atDir(dir), reopen: () => FakeStore.atDir(dir) };
    },
  },
];
if (BD_BIN) {
  const bin = BD_BIN;
  factories.push({
    name: 'BeadsStore (file)',
    make: () => {
      const dir = path.join(tmpDir(), 'store');
      return { store: BeadsStore.atDir(dir, { bin }), reopen: () => BeadsStore.atDir(dir, { bin }) };
    },
  });
}

const T0 = 1_000_000;
const LEASE = 300_000;

for (const f of factories) {
  describe(`TaskStore contract: ${f.name}`, () => {
    test('create: new tasks are planned with zeroed counters; ids and deps are validated', () => {
      const { store } = f.make();
      const t = store.createTask({ id: 'A', epicId: 'E', title: 'a', deps: [] });
      assert.equal(t.state, 'planned');
      assert.deepEqual([t.attempt, t.correctionFailures, t.infraFailures, t.repeatCount, t.lastFailureSignature, t.claim], [0, 0, 0, 0, null, null]);
      assert.throws(() => store.createTask({ id: 'A', epicId: 'E', title: 'dup', deps: [] }), /exists/);
      assert.throws(() => store.createTask({ id: 'B', epicId: 'E', title: 'b', deps: ['nope'] }), /unknown dependency/);
      assert.throws(() => store.createTask({ id: '../x', epicId: 'E', title: 'x', deps: [] }), /invalid task id/);
    });

    test('deps: dependencies are stored and returned', () => {
      const { store } = f.make();
      store.createTask({ id: 'A', epicId: 'E', title: 'a', deps: [] });
      store.createTask({ id: 'B', epicId: 'E', title: 'b', deps: ['A'] });
      assert.deepEqual(store.get('B')?.deps, ['A']);
      assert.deepEqual(store.list().map((t) => t.id), ['A', 'B']);
    });

    test('compare-and-set changes state only from the expected state', () => {
      const { store } = f.make();
      store.createTask({ id: 'A', epicId: 'E', title: 'a', deps: [] });
      assert.equal(store.compareAndSetState('A', 'ready', 'implementing'), false);
      assert.equal(store.get('A')?.state, 'planned');
      assert.equal(store.compareAndSetState('A', 'planned', 'ready', { attempt: 2, repeatCount: 1 }), true);
      const a = store.get('A');
      assert.equal(a?.state, 'ready');
      assert.equal(a?.attempt, 2);
      assert.equal(a?.repeatCount, 1);
      assert.throws(() => store.compareAndSetState('Z', 'planned', 'ready'), /unknown task/);
    });

    test('counters can be updated without a state change, and unknown fields are ignored', () => {
      const { store } = f.make();
      store.createTask({ id: 'A', epicId: 'E', title: 'a', deps: [] });
      store.updateCounters('A', { infraFailures: 2, lastFailureSignature: 'sig', ...({ state: 'done' } as object) });
      const a = store.get('A');
      assert.equal(a?.infraFailures, 2);
      assert.equal(a?.lastFailureSignature, 'sig');
      assert.equal(a?.state, 'planned', 'updateCounters must not change state');
    });

    test('ready: claimReady takes only ready, unclaimed, non-excluded tasks, lowest id first', () => {
      const { store } = f.make();
      for (const id of ['C', 'A', 'B', 'D']) store.createTask({ id, epicId: 'E', title: id, deps: [] });
      for (const id of ['C', 'B', 'D']) store.compareAndSetState(id, 'planned', 'ready');
      assert.equal(store.claimReady('w1', LEASE, T0)?.id, 'B');
      assert.equal(store.claimReady('w2', LEASE, T0, new Set(['C']))?.id, 'D');
      assert.equal(store.claimReady('w3', LEASE, T0, new Set(['C'])), null);
      assert.equal(store.claimReady('w3', LEASE, T0)?.id, 'C');
      assert.equal(store.claimReady('w4', LEASE, T0), null, 'A is planned, others claimed');
    });

    test('claim: exclusive while the lease is live; re-claim by the holder renews', () => {
      const { store } = f.make();
      store.createTask({ id: 'A', epicId: 'E', title: 'a', deps: [] });
      assert.equal(store.claim('A', 'w1', LEASE, T0), true);
      assert.equal(store.claim('A', 'w2', LEASE, T0 + 1), false);
      assert.equal(store.get('A')?.claim?.owner, 'w1');
      assert.equal(store.claim('A', 'w1', LEASE, T0 + 10), true);
      assert.equal(store.get('A')?.claim?.leaseExpiresAt, T0 + 10 + LEASE);
    });

    test('heartbeat: extends only the live holder\'s lease', () => {
      const { store } = f.make();
      store.createTask({ id: 'A', epicId: 'E', title: 'a', deps: [] });
      store.claim('A', 'w1', LEASE, T0);
      assert.equal(store.heartbeat('A', 'w2', LEASE, T0 + 1), false);
      assert.equal(store.heartbeat('A', 'w1', LEASE, T0 + 100), true);
      assert.equal(store.get('A')?.claim?.leaseExpiresAt, T0 + 100 + LEASE);
      assert.equal(store.heartbeat('A', 'w1', LEASE, T0 + 100 + LEASE), false, 'an expired lease cannot be revived');
    });

    test('reclaim: expired claims are cleared and the task can be claimed again', () => {
      const { store } = f.make();
      for (const id of ['A', 'B']) {
        store.createTask({ id, epicId: 'E', title: id, deps: [] });
        store.compareAndSetState(id, 'planned', 'ready');
      }
      store.claim('A', 'w1', 100, T0);
      store.claim('B', 'w1', 10_000, T0);
      assert.equal(store.claimReady('w2', LEASE, T0 + 50), null);
      assert.equal(store.claim('A', 'w2', LEASE, T0 + 100), true, 'a lease ending exactly now is expired');
      store.release('A', 'w2');
      store.claim('A', 'w1', 100, T0);
      assert.deepEqual(store.reclaimExpired(T0 + 100), ['A']);
      assert.equal(store.get('A')?.claim, null);
      assert.equal(store.get('B')?.claim?.owner, 'w1');
      assert.deepEqual(store.reclaimExpired(T0 + 100), []);
    });

    test('release: only the holder can release', () => {
      const { store } = f.make();
      store.createTask({ id: 'A', epicId: 'E', title: 'a', deps: [] });
      store.claim('A', 'w1', LEASE, T0);
      assert.equal(store.release('A', 'w2'), false);
      assert.equal(store.release('A', 'w1'), true);
      assert.equal(store.get('A')?.claim, null);
      assert.equal(store.release('A', 'w1'), false);
    });

    test('notes: appended in order', () => {
      const { store } = f.make();
      store.createTask({ id: 'A', epicId: 'E', title: 'a', deps: [] });
      store.addNote('A', 'one');
      store.addNote('A', 'two');
      assert.deepEqual(store.get('A')?.notes.map((n) => n.text), ['one', 'two']);
    });

    test('close: a done task is never offered as ready', () => {
      const { store } = f.make();
      store.createTask({ id: 'A', epicId: 'E', title: 'a', deps: [] });
      store.compareAndSetState('A', 'planned', 'ready');
      store.compareAndSetState('A', 'ready', 'done');
      assert.equal(store.claimReady('w1', LEASE, T0), null);
    });

    test('state changes do not depend on dependency states: ordering is the controller\'s job', () => {
      const { store } = f.make();
      store.createTask({ id: 'A', epicId: 'E', title: 'a', deps: [] });
      store.createTask({ id: 'B', epicId: 'E', title: 'b', deps: ['A'] });
      assert.equal(store.compareAndSetState('B', 'planned', 'done'), true, 'resume may repair a dependent before its dependency');
      assert.equal(store.get('B')?.state, 'done');
      assert.equal(store.get('A')?.state, 'planned');
    });

    test('returned records are copies: mutating them does not change the store', () => {
      const { store } = f.make();
      store.createTask({ id: 'A', epicId: 'E', title: 'a', deps: [] });
      const a = store.get('A');
      if (a) {
        a.state = 'done';
        a.deps.push('X');
      }
      assert.equal(store.get('A')?.state, 'planned');
      assert.deepEqual(store.get('A')?.deps, []);
    });

    test('notes keep their boundaries, including multi-line text', () => {
      const { store } = f.make();
      store.createTask({ id: 'A', epicId: 'E', title: 'a', deps: [] });
      store.addNote('A', 'line one\nline two');
      store.addNote('A', '{"ts":"forged","text":"x"} still one note');
      const notes = store.get('A')?.notes ?? [];
      assert.deepEqual(notes.map((n) => n.text), ['line one\nline two', '{"ts":"forged","text":"x"} still one note']);
      assert.ok(notes.every((n) => !Number.isNaN(Date.parse(n.ts))), 'every note has a timestamp');
    });

    test('unknown tasks: reads return nothing, ownership operations return false, writes throw', () => {
      const { store } = f.make();
      store.createTask({ id: 'A1', epicId: 'E', title: 'a', deps: [] });
      assert.equal(store.get('A'), undefined, 'no prefix or partial-id matching');
      assert.equal(store.heartbeat('Z', 'w1', LEASE, T0), false);
      assert.equal(store.release('Z', 'w1'), false);
      assert.throws(() => store.claim('Z', 'w1', LEASE, T0), /unknown task/);
      assert.throws(() => store.updateCounters('Z', { attempt: 1 }), /unknown task/);
      assert.throws(() => store.addNote('Z', 'n'), /unknown task/);
    });

    if (f.name.includes('file')) {
      test('durability: a new instance on the same directory sees every change', () => {
        const { store, reopen } = f.make();
        store.createTask({ id: 'A', epicId: 'E', title: 'a', deps: [] });
        store.compareAndSetState('A', 'planned', 'ready', { attempt: 1 });
        store.claim('A', 'w1', LEASE, T0);
        store.addNote('A', 'n');
        const again = reopen?.();
        const a = again?.get('A');
        assert.equal(a?.state, 'ready');
        assert.equal(a?.attempt, 1);
        assert.equal(a?.claim?.owner, 'w1');
        assert.equal(a?.notes.length, 1);
      });
    }
  });
}
