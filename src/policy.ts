import * as fs from 'node:fs';
import * as path from 'node:path';
import { canonicalJson, sha256Hex } from './util/canonical.ts';
import { readJson, writeFileAtomic } from './util/fsx.ts';
import { assertValid, type Schema } from './schema.ts';
import { reservationAmount } from './budget.ts';

export interface ApprovedRepository {
  /** Absolute path of the repository on this machine (compared after realpath). */
  path: string;
  approvedBy: string;
  approvedAt: string;
}

export interface Caps {
  usd: number;
  tokens: number;
}

export interface BudgetPolicy {
  epic: Caps;
  task: Caps;
  /** Per-invocation cap passed to the worker (e.g. as --max-budget-usd). A client-side estimate, not a billing limit. */
  invocation: Caps;
  /** Largest single-turn cost measured in M2-6b. null until measured. */
  maxTurnCostUsd: number | null;
  maxTurnTokens: number | null;
  /** Used while maxTurn* is null: reserve max(factor x cap, cap + minExtra). */
  unmeasuredFactor: number;
  unmeasuredMinExtraUsd: number;
  unmeasuredMinExtraTokens: number;
}

export interface Limits {
  maxAttempts: number;
  maxInfraRetries: number;
  maxInvalidOutput: number;
  maxIntegrationAttempts: number;
  repeatedFailureStop: number;
}

export interface Policy {
  version: 1;
  approvedRepositories: ApprovedRepository[];
  limits: Limits;
  budget: BudgetPolicy;
  concurrency: { max: number };
  timeouts: { invocationMs: number };
  leaseMs: number;
  protectedPaths: string[];
}

const capsSchema: Schema = {
  type: 'object',
  required: ['usd', 'tokens'],
  additionalProperties: false,
  properties: { usd: { type: 'number', exclusiveMinimum: 0 }, tokens: { type: 'integer', exclusiveMinimum: 0 } },
};

const posInt: Schema = { type: 'integer', minimum: 1 };

export const policySchema: Schema = {
  type: 'object',
  required: ['version', 'approvedRepositories', 'limits', 'budget', 'concurrency', 'timeouts', 'leaseMs', 'protectedPaths'],
  additionalProperties: false,
  properties: {
    version: { const: 1 },
    approvedRepositories: {
      type: 'array',
      items: {
        type: 'object',
        required: ['path', 'approvedBy', 'approvedAt'],
        additionalProperties: false,
        properties: { path: { type: 'string', minLength: 1 }, approvedBy: { type: 'string', minLength: 1 }, approvedAt: { type: 'string' } },
      },
    },
    limits: {
      type: 'object',
      required: ['maxAttempts', 'maxInfraRetries', 'maxInvalidOutput', 'maxIntegrationAttempts', 'repeatedFailureStop'],
      additionalProperties: false,
      properties: {
        maxAttempts: posInt,
        maxInfraRetries: { type: 'integer', minimum: 0 },
        maxInvalidOutput: { type: 'integer', minimum: 0 },
        maxIntegrationAttempts: posInt,
        repeatedFailureStop: { type: 'integer', minimum: 2 },
      },
    },
    budget: {
      type: 'object',
      required: ['epic', 'task', 'invocation', 'maxTurnCostUsd', 'maxTurnTokens', 'unmeasuredFactor', 'unmeasuredMinExtraUsd', 'unmeasuredMinExtraTokens'],
      additionalProperties: false,
      properties: {
        epic: capsSchema,
        task: capsSchema,
        invocation: capsSchema,
        maxTurnCostUsd: { type: ['number', 'null'], minimum: 0 },
        maxTurnTokens: { type: ['integer', 'null'], minimum: 0 },
        unmeasuredFactor: { type: 'number', minimum: 1 },
        unmeasuredMinExtraUsd: { type: 'number', minimum: 0 },
        unmeasuredMinExtraTokens: { type: 'integer', minimum: 0 },
      },
    },
    concurrency: { type: 'object', required: ['max'], additionalProperties: false, properties: { max: { type: 'integer', minimum: 1, maximum: 8 } } },
    timeouts: { type: 'object', required: ['invocationMs'], additionalProperties: false, properties: { invocationMs: posInt } },
    leaseMs: posInt,
    protectedPaths: { type: 'array', items: { type: 'string', minLength: 1 } },
  },
};

export function defaultPolicy(): Policy {
  return {
    version: 1,
    approvedRepositories: [],
    limits: { maxAttempts: 3, maxInfraRetries: 2, maxInvalidOutput: 1, maxIntegrationAttempts: 2, repeatedFailureStop: 2 },
    budget: {
      // Unmeasured reservations are max(10 x invocation, invocation + extra) = $5 / 2M tokens, so a
      // task cap must hold one reservation plus the spend of earlier attempts.
      epic: { usd: 25, tokens: 20_000_000 },
      task: { usd: 10, tokens: 4_000_000 },
      invocation: { usd: 0.5, tokens: 200_000 },
      maxTurnCostUsd: null,
      maxTurnTokens: null,
      unmeasuredFactor: 10,
      unmeasuredMinExtraUsd: 1,
      unmeasuredMinExtraTokens: 100_000,
    },
    concurrency: { max: 2 },
    timeouts: { invocationMs: 15 * 60_000 },
    leaseMs: 5 * 60_000,
    protectedPaths: [
      'tests/**', 'test/**', '**/*.test.*', '**/*.spec.*', '**/fixtures/**', '**/__mocks__/**', '**/__snapshots__/**',
      'package.json', 'package-lock.json', 'pnpm-lock.yaml', 'yarn.lock', 'tsconfig*.json',
      '.github/**', '.claude/**', 'CLAUDE.md', '.mcp.json', '.git*',
    ],
  };
}

export function validatePolicy(value: unknown): Policy {
  assertValid(policySchema, value, 'policy');
  const p = value as Policy;
  if (p.budget.task.usd > p.budget.epic.usd) throw new Error('policy is invalid: budget.task.usd exceeds budget.epic.usd');
  if (p.budget.invocation.usd > p.budget.task.usd) throw new Error('policy is invalid: budget.invocation.usd exceeds budget.task.usd');
  if (p.budget.task.tokens > p.budget.epic.tokens) throw new Error('policy is invalid: budget.task.tokens exceeds budget.epic.tokens');
  if (p.budget.invocation.tokens > p.budget.task.tokens) throw new Error('policy is invalid: budget.invocation.tokens exceeds budget.task.tokens');
  // A cap smaller than one reservation would reject every task before it starts.
  const R = reservationAmount(p.budget);
  if (R.usd > p.budget.task.usd || R.tokens > p.budget.task.tokens) {
    throw new Error(`policy is invalid: one reservation ($${R.usd} / ${R.tokens} tokens) exceeds the task cap`);
  }
  return p;
}

export function policyHash(p: Policy): string {
  return sha256Hex(canonicalJson(p));
}

export function loadPolicy(file: string): Policy {
  return validatePolicy(readJson<unknown>(file));
}

export function savePolicy(file: string, p: Policy): void {
  validatePolicy(p);
  writeFileAtomic(file, JSON.stringify(p, null, 2) + '\n');
}

function canonicalRepoPath(p: string): string {
  const real = fs.realpathSync.native(path.resolve(p));
  return process.platform === 'win32' ? real.toLowerCase() : real;
}

export function isRepositoryApproved(p: Policy, repoPath: string): boolean {
  let target: string;
  try {
    target = canonicalRepoPath(repoPath);
  } catch {
    return false;
  }
  return p.approvedRepositories.some((r) => {
    try {
      return canonicalRepoPath(r.path) === target;
    } catch {
      return false;
    }
  });
}

export function assertRepositoryApproved(p: Policy, repoPath: string): void {
  if (!isRepositoryApproved(p, repoPath)) {
    throw new PolicyError(
      `repository not approved: ${repoPath}. A human must add it with "eo policy approve-repo" (interactive confirmation).`,
    );
  }
}

/** Pure helper used by the interactive CLI command; returns a new policy. */
export function withApprovedRepository(p: Policy, repoPath: string, approvedBy: string, now = new Date()): Policy {
  const resolved = fs.realpathSync.native(path.resolve(repoPath));
  if (isRepositoryApproved(p, resolved)) return p;
  return { ...p, approvedRepositories: [...p.approvedRepositories, { path: resolved, approvedBy, approvedAt: now.toISOString() }] };
}

export class PolicyError extends Error {}
