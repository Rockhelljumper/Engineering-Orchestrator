import { canonicalJson, sha256Hex } from './util/canonical.ts';
import { assertValid, type Schema } from './schema.ts';

/**
 * Plan file accepted by `eo plan import`. M4 replaces the hand-written plan with the planner's
 * output and adds the full plan gate; M1 validates structure, ids and the dependency graph.
 */
export interface PlanTask {
  id: string;
  title: string;
  deps: string[];
}

export interface Plan {
  epicId: string;
  title: string;
  tasks: PlanTask[];
}

const idPattern = '^[A-Za-z0-9._-]{1,100}$';

export const planSchema: Schema = {
  type: 'object',
  required: ['epicId', 'title', 'tasks'],
  additionalProperties: false,
  properties: {
    epicId: { type: 'string', pattern: idPattern },
    title: { type: 'string', minLength: 1 },
    tasks: {
      type: 'array',
      minItems: 1,
      items: {
        type: 'object',
        required: ['id', 'title', 'deps'],
        additionalProperties: false,
        properties: {
          id: { type: 'string', pattern: idPattern },
          title: { type: 'string', minLength: 1 },
          deps: { type: 'array', items: { type: 'string', pattern: idPattern } },
        },
      },
    },
  },
};

export function validatePlan(value: unknown): Plan {
  assertValid(planSchema, value, 'plan');
  const plan = value as Plan;
  const ids = new Set<string>();
  for (const t of plan.tasks) {
    if (ids.has(t.id)) throw new Error(`plan is invalid: duplicate task id ${t.id}`);
    ids.add(t.id);
  }
  for (const t of plan.tasks) {
    for (const d of t.deps) {
      if (!ids.has(d)) throw new Error(`plan is invalid: ${t.id} depends on unknown task ${d}`);
      if (d === t.id) throw new Error(`plan is invalid: ${t.id} depends on itself`);
    }
  }
  const cycle = findCycle(plan.tasks);
  if (cycle) throw new Error(`plan is invalid: dependency cycle ${cycle.join(' -> ')}`);
  return plan;
}

/** Topological order (dependencies first); ties broken by id for determinism. */
export function topoOrder(tasks: PlanTask[]): PlanTask[] {
  const byId = new Map(tasks.map((t) => [t.id, t]));
  const done = new Set<string>();
  const out: PlanTask[] = [];
  const visit = (t: PlanTask): void => {
    if (done.has(t.id)) return;
    done.add(t.id);
    for (const d of [...t.deps].sort()) visit(byId.get(d) as PlanTask);
    out.push(t);
  };
  for (const t of [...tasks].sort((a, b) => (a.id < b.id ? -1 : 1))) visit(t);
  return out;
}

function findCycle(tasks: PlanTask[]): string[] | null {
  const byId = new Map(tasks.map((t) => [t.id, t]));
  const state = new Map<string, 'visiting' | 'done'>();
  const stack: string[] = [];
  const dfs = (id: string): string[] | null => {
    state.set(id, 'visiting');
    stack.push(id);
    for (const d of byId.get(id)?.deps ?? []) {
      if (state.get(d) === 'visiting') return [...stack.slice(stack.indexOf(d)), d];
      if (!state.has(d)) {
        const c = dfs(d);
        if (c) return c;
      }
    }
    stack.pop();
    state.set(id, 'done');
    return null;
  };
  for (const t of tasks) {
    if (!state.has(t.id)) {
      const c = dfs(t.id);
      if (c) return c;
    }
  }
  return null;
}

export function planHash(plan: Plan): string {
  return sha256Hex(canonicalJson(plan));
}
