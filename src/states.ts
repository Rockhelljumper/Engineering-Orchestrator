/** Task lifecycle from architecture §5. The controller is the only component that changes state. */
export const TASK_STATES = [
  'planned',
  'ready',
  'implementing',
  'verifying',
  'reviewing',
  'security_review',
  'accepted',
  'integrating',
  'done',
  'blocked',
] as const;

export type TaskState = (typeof TASK_STATES)[number];

/** Allowed transitions. Anything not listed is illegal. */
export const TRANSITIONS: Readonly<Record<TaskState, readonly TaskState[]>> = {
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

export function isTaskState(s: unknown): s is TaskState {
  return typeof s === 'string' && (TASK_STATES as readonly string[]).includes(s);
}

export function canTransition(from: TaskState, to: TaskState): boolean {
  return TRANSITIONS[from].includes(to);
}

export class IllegalTransitionError extends Error {
  constructor(taskId: string, from: TaskState, to: TaskState) {
    super(`illegal transition for ${taskId}: ${from} -> ${to}`);
  }
}

export function assertTransition(taskId: string, from: TaskState, to: TaskState): void {
  if (!canTransition(from, to)) throw new IllegalTransitionError(taskId, from, to);
}

/** Transitions that must carry an escalation record (architecture §5: blocked always has one). */
export function requiresEscalation(to: TaskState): boolean {
  return to === 'blocked';
}

/** Leaving blocked is a human decision; the scheduler never does it on its own. */
export function requiresHuman(from: TaskState, to: TaskState): boolean {
  return from === 'blocked' && to === 'ready';
}
