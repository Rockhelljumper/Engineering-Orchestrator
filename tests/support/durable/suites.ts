import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { spawn, type ChildProcess } from 'node:child_process';
import { appendLineDurable } from '../../../src/util/fsx.ts';
import { FakeStore } from '../../../src/store/fake.ts';
import { BeadsStore } from '../../../src/store/beads.ts';
import type { TaskStore } from '../../../src/store/types.ts';
import { sleepSync } from '../../../src/util/lock.ts';
import { BD_BIN, REPO_ROOT, tmpDir } from '../helpers.ts';
import { assertExpectedBaseline, baselineRun, escalationBoundary, randomKillSeed, sampleBoundary, type CrashPhase } from '../crash-scenarios.ts';

/**
 * Suites the durable runner (M2-0) can run, each split into scenarios that run one per
 * process and are checkpointed one by one: one crash boundary, one kill seed or one claim
 * round. `plan` runs once when the run is created (it may need a baseline run to know how many
 * boundaries there are); its result is fixed in the manifest so a resumed run checks the same
 * scenarios. `run` throws on failure and returns a line for the evidence.
 */
export interface Scenario {
  id: string;
  seed?: number;
}

export interface Suite {
  plan(params: Record<string, unknown>): Promise<{ scenarios: Scenario[]; derived: Record<string, unknown> }>;
  run(s: Scenario, params: Record<string, unknown>, derived: Record<string, unknown>): Promise<string>;
}

const phaseOf = (p: Record<string, unknown>): CrashPhase => (p['phase'] === 'anchor' ? 'anchor' : 'journal');
const num = (p: Record<string, unknown>, k: string, d: number): number => (p[k] === undefined ? d : Number(p[k]));

function boundaries(n: number): Scenario[] {
  return Array.from({ length: n }, (_, i) => ({ id: `boundary-${i + 1}`, seed: i + 1 }));
}

const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

export const SUITES: Record<string, Suite> = {
  /**
   * A small synthetic suite for testing the runner itself: each scenario records that it ran
   * (in params.markerDir), sleeps, and passes, except params.failAt.
   */
  selftest: {
    async plan(p) {
      return { scenarios: Array.from({ length: num(p, 'count', 6) }, (_, i) => ({ id: `s${i + 1}`, seed: 1000 + i })), derived: {} };
    },
    async run(s, p) {
      if (typeof p['markerDir'] === 'string') appendLineDurable(path.join(p['markerDir'], 'executions.log'), `${s.id} ${process.pid} ${process.env['TMPDIR'] ?? ''}`);
      await sleep(num(p, 'sleepMs', 300));
      if (p['failAt'] === s.id) throw new Error(`scenario ${s.id} fails by request`);
      // A scenario that crashes on its own (not killed from outside).
      if (p['abortAt'] === s.id) process.kill(process.pid, 'SIGABRT');
      return `slept ${num(p, 'sleepMs', 300)} ms (seed ${s.seed})`;
    },
  },

  /** M1-4: crash after every journal step boundary of the 5-task sample run (params.phase journal | anchor). */
  'crash-sample': {
    async plan() {
      const b = baselineRun('sample');
      assertExpectedBaseline('sample', b);
      return { scenarios: boundaries(b.boundaries), derived: { baseline: b.baseline } };
    },
    async run(s, p, d) {
      const label = sampleBoundary(Number(s.seed), d['baseline'] as Record<string, string>, phaseOf(p));
      return `boundary ${label} (${phaseOf(p)} phase) recovered to the baseline`;
    },
  },

  /** M1-4: crash at every boundary of the run that ends in an escalation. */
  'crash-escalation': {
    async plan() {
      const b = baselineRun('escalation');
      assertExpectedBaseline('escalation', b);
      return { scenarios: boundaries(b.boundaries), derived: { baseline: b.baseline, escalations: b.escalations } };
    },
    async run(s, p, d) {
      escalationBoundary(Number(s.seed), d['baseline'] as Record<string, string>, d['escalations'] as string[], phaseOf(p));
      return `escalation boundary ${s.seed} (${phaseOf(p)} phase) recovered to the baseline`;
    },
  },

  /** M1-4: random SIGKILLs of the controller during attempts; the seed fixes the kill delays. */
  'random-kills': {
    async plan(p) {
      const b = baselineRun('sample', 150);
      assertExpectedBaseline('sample', b);
      return { scenarios: Array.from({ length: num(p, 'seeds', 8) }, (_, i) => ({ id: `seed-${i + 1}`, seed: i + 1 })), derived: { baseline: b.baseline, durationMs: b.durationMs } };
    },
    async run(s, _p, d) {
      const killed = await randomKillSeed(Number(s.seed), Number(d['durationMs']), d['baseline'] as Record<string, string>);
      assert.ok(killed >= 1, `seed ${s.seed}: no kill landed; the scenario did not exercise recovery`);
      return `seed ${s.seed}: ${killed} SIGKILLs delivered, recovered to the baseline`;
    },
  },

  /** M1-3: params.workers processes race for one ready task, exactly one winner; one round per scenario. */
  'claim-race': {
    async plan(p) {
      return { scenarios: Array.from({ length: num(p, 'rounds', 100) }, (_, i) => ({ id: `round-${i + 1}`, seed: i + 1 })), derived: {} };
    },
    async run(s, p) {
      const kind = p['store'] === 'beads' ? 'beads' : 'fake';
      return claimRound(kind, num(p, 'workers', 20), Number(s.seed));
    },
  },
};

async function claimRound(kind: 'fake' | 'beads', workers: number, round: number): Promise<string> {
  if (kind === 'beads' && !BD_BIN) throw new Error('claim-race on beads needs EO_BD_BIN');
  const dir = tmpDir('eo-claims-');
  const storeDir = path.join(dir, 'store');
  const barrier = path.join(dir, 'barrier');
  fs.mkdirSync(barrier);
  const store: TaskStore = kind === 'beads' ? BeadsStore.atDir(storeDir, { bin: BD_BIN as string, create: true }) : FakeStore.atDir(storeDir);
  const worker = path.join(REPO_ROOT, 'tests', 'support', 'claim-worker.ts');
  const children: ChildProcess[] = [];
  const exits: Array<Promise<number | null>> = [];
  try {
    for (let w = 0; w < workers; w++) {
      const c = spawn(process.execPath, [worker, storeDir, barrier, String(w), '1', kind, BD_BIN ?? ''], { stdio: ['ignore', 'ignore', 'inherit'] });
      children.push(c);
      exits.push(new Promise((resolve) => c.on('exit', (code) => resolve(code))));
    }
    const wait = (cond: () => boolean, what: string, ms: number): void => {
      const deadline = Date.now() + ms;
      while (!cond()) {
        if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
        sleepSync(2);
      }
    };
    wait(() => fs.readdirSync(barrier).filter((f) => f.startsWith('up-')).length === workers, 'workers to start', 120_000);
    const id = `R${String(round).padStart(3, '0')}`;
    store.createTask({ id, epicId: 'E', title: id, deps: [] });
    store.compareAndSetState(id, 'planned', 'ready');
    fs.writeFileSync(path.join(barrier, 'go-1'), '');
    wait(() => fs.readdirSync(barrier).filter((f) => f.startsWith('res-1-')).length === workers, 'results', kind === 'beads' ? 600_000 : 60_000);
    const results = Array.from({ length: workers }, (_, w) => fs.readFileSync(path.join(barrier, `res-1-${w}`), 'utf8'));
    const winners = results.filter((x) => x !== '');
    assert.equal(winners.length, 1, `round ${round}: ${winners.length} winners`);
    assert.equal(winners[0], id);
    assert.equal(store.get(id)?.claim?.owner, `w${results.indexOf(id)}`, `round ${round}: the store's claim owner is the reported winner`);
    assert.deepEqual(await Promise.all(exits), Array(workers).fill(0));
    return `round ${round}: ${workers} workers, one winner (w${results.indexOf(id)})`;
  } finally {
    for (const c of children) if (c.exitCode === null) c.kill('SIGKILL');
  }
}
