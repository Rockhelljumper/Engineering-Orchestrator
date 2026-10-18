import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { REPO_ROOT } from '../support/helpers.ts';
import { TASK_STATES, TRANSITIONS, assertTransition, canTransition, IllegalTransitionError, type TaskState } from '../../src/states.ts';

// Architecture §5, written out independently of src/states.ts so a change to either is caught.
const SPEC: Record<TaskState, TaskState[]> = {
  planned: ['ready', 'blocked'],
  ready: ['implementing', 'blocked'],
  implementing: ['verifying', 'ready', 'blocked'],
  verifying: ['reviewing', 'ready', 'blocked'],
  reviewing: ['security_review', 'accepted', 'ready', 'blocked'],
  security_review: ['accepted', 'ready', 'blocked'],
  accepted: ['integrating'],
  integrating: ['done', 'ready', 'blocked'],
  done: [],
  blocked: ['ready'],
};

test('M1-1: every ordered pair of states is allowed exactly when the spec allows it', () => {
  let legal = 0;
  let illegal = 0;
  for (const from of TASK_STATES) {
    for (const to of TASK_STATES) {
      const allowed = SPEC[from].includes(to);
      assert.equal(canTransition(from, to), allowed, `${from} -> ${to}`);
      if (allowed) {
        assert.doesNotThrow(() => assertTransition('T', from, to));
        legal++;
      } else {
        assert.throws(() => assertTransition('T', from, to), IllegalTransitionError);
        illegal++;
      }
    }
  }
  assert.equal(legal + illegal, TASK_STATES.length ** 2);
  assert.equal(legal, docEdges().size);
});

/** The edges of the stateDiagram in docs/02-architecture.md §5, excluding [*] start/end markers. */
function docEdges(): Set<string> {
  const doc = fs.readFileSync(path.join(REPO_ROOT, 'docs', '02-architecture.md'), 'utf8');
  const section = doc.slice(doc.indexOf('## 5. Task lifecycle'), doc.indexOf('## 6.'));
  const edges = new Set<string>();
  for (const m of section.matchAll(/^\s*([a-z_]+) --> ([a-z_]+)/gm)) edges.add(`${m[1]}->${m[2]}`);
  return edges;
}

test('M1-1: the spec table matches the architecture diagram edge for edge', () => {
  const fromSpec = new Set(Object.entries(SPEC).flatMap(([f, tos]) => tos.map((t) => `${f}->${t}`)));
  const fromDoc = docEdges();
  assert.ok(fromDoc.size > 0, 'no edges parsed from the architecture document');
  assert.deepEqual([...fromSpec].sort(), [...fromDoc].sort());
});

test('no self-transitions and done is terminal', () => {
  for (const s of TASK_STATES) assert.equal(canTransition(s, s), false);
  assert.deepEqual(TRANSITIONS.done, []);
});

test('only "blocked -> ready" leaves blocked', () => {
  assert.deepEqual([...TRANSITIONS.blocked], ['ready']);
});
