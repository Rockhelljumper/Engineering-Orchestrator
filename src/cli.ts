#!/usr/bin/env node
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as readline from 'node:readline/promises';
import { parseArgs } from 'node:util';
import { Controller } from './controller.ts';
import { doctor } from './doctor.ts';
import { defaultStateRoot, initStateRoot, statePaths } from './stateRoot.ts';
import { FakeRunner } from './runner/fake.ts';
import { FakeStore } from './store/fake.ts';
import { BudgetLedger, reservationAmount } from './budget.ts';
import { verifyJournalFile } from './journal.ts';
import { readJournalKey } from './stateRoot.ts';
import { loadPolicy } from './policy.ts';
import { EvidenceLedger } from './evidence.ts';

const USAGE = `eo — Engineering Orchestrator controller (M1)

Usage: eo <command> [options]   (global: --state-root <dir>, or EO_STATE_ROOT)

  init                              create a state root (policy, journal key, store)
  policy show                       print the policy
  policy approve-repo <path>        approve a repository (interactive confirmation)
  policy accept                     accept a hand-edited policy.json (interactive confirmation)
  plan import <file> --repo <path>  import and approve a plan (interactive confirmation)
  run --repo <path> --runner fake --script <file> [--max-steps n]
  resume                            reconcile after a crash or interruption
  status [--json]                   tasks, budget and escalations
  doctor                            read-only integrity check (exit 1 on problems)
  unblock <task> --note <text>      return a blocked task to ready (interactive confirmation)
  evidence <task> [--attempt n]     show and verify an evidence manifest
`;

async function main(argv: string[]): Promise<number> {
  const { values, positionals } = parseArgs({
    args: argv,
    allowPositionals: true,
    options: {
      'state-root': { type: 'string' },
      repo: { type: 'string' },
      runner: { type: 'string' },
      script: { type: 'string' },
      'max-steps': { type: 'string' },
      attempt: { type: 'string' },
      note: { type: 'string' },
      json: { type: 'boolean' },
      help: { type: 'boolean', short: 'h' },
    },
  });
  const [cmd, sub, arg] = positionals;
  if (values.help || !cmd) {
    process.stdout.write(USAGE);
    return cmd ? 0 : 2;
  }
  const root = values['state-root'] ?? process.env['EO_STATE_ROOT'] ?? defaultStateRoot();

  switch (cmd) {
    case 'init': {
      const p = initStateRoot(root);
      const c = Controller.open(p.root);
      c.close();
      out(`initialised ${p.root}\nNext: a human approves a repository with "eo policy approve-repo <path>".`);
      return 0;
    }
    case 'policy': {
      if (sub === 'show') {
        out(fs.readFileSync(statePaths(root).policy, 'utf8'));
        return 0;
      }
      if (sub === 'accept') {
        out(fs.readFileSync(statePaths(root).policy, 'utf8'));
        await confirmHuman('Accept the policy above as the new controller policy? Type "accept" to continue: ', 'accept');
        const c = Controller.open(root, { allowPolicyDrift: true });
        try {
          out(`accepted policy ${c.acceptPolicy(os.userInfo().username)}`);
          return 0;
        } finally {
          c.close();
        }
      }
      if (sub === 'approve-repo' && arg) {
        await confirmHuman(`Approve repository ${arg} for eo? Type "approve" to continue: `, 'approve');
        return withController(root, (c) => {
          c.approveRepository(arg, os.userInfo().username);
          out(`approved ${arg}`);
          return 0;
        });
      }
      break;
    }
    case 'plan': {
      if (sub === 'import' && arg && values.repo) {
        const plan = JSON.parse(fs.readFileSync(arg, 'utf8')) as unknown;
        await confirmHuman(`Approve and import plan ${arg}? Type "approve" to continue: `, 'approve');
        const repo = values.repo;
        return withController(root, (c) => {
          const p = c.importPlan(plan, repo, os.userInfo().username);
          out(`imported epic ${p.epicId} with ${p.tasks.length} tasks`);
          return 0;
        });
      }
      break;
    }
    case 'run': {
      if (!values.repo) throw new UsageError('--repo is required');
      if (values.runner !== 'fake' || !values.script) throw new UsageError('M1 supports only --runner fake --script <file>');
      const runner = FakeRunner.fromFile(values.script);
      const c = Controller.open(root);
      try {
        const maxSteps = values['max-steps'] ? Number(values['max-steps']) : undefined;
        const s = await c.run(runner, { repoPath: values.repo, ...(maxSteps !== undefined ? { maxSteps } : {}) });
        out(JSON.stringify(s, null, 2));
        return 0;
      } finally {
        c.close();
      }
    }
    case 'resume':
      return withController(root, (c) => {
        out(JSON.stringify(c.resume(), null, 2));
        return 0;
      });
    case 'status':
      return status(root, values.json === true);
    case 'doctor': {
      const r = doctor(root);
      out(JSON.stringify(r, null, 2));
      return r.ok ? 0 : 1;
    }
    case 'unblock': {
      if (!sub || !values.note) throw new UsageError('usage: eo unblock <task> --note <text>');
      await confirmHuman(`Unblock ${sub}? Type "unblock" to continue: `, 'unblock');
      const task = sub;
      const note = values.note;
      return withController(root, (c) => {
        c.unblock(task, os.userInfo().username, note);
        out(`${task} -> ready`);
        return 0;
      });
    }
    case 'evidence': {
      if (!sub) throw new UsageError('usage: eo evidence <task> [--attempt n]');
      const p = statePaths(root);
      const store = FakeStore.atDir(p.store);
      const t = store.get(sub);
      if (!t) throw new UsageError(`unknown task ${sub}`);
      const attempt = values.attempt ? Number(values.attempt) : t.attempt;
      const ev = new EvidenceLedger(p.evidence, readJournalKey(p));
      const problems = ev.verify(sub, attempt);
      out(JSON.stringify({ manifest: ev.read(sub, attempt), problems }, null, 2));
      return problems.length === 0 ? 0 : 1;
    }
  }
  throw new UsageError(`unknown command: ${positionals.join(' ')}`);
}

function withController(root: string, fn: (c: Controller) => number): number {
  const c = Controller.open(root);
  try {
    return fn(c);
  } finally {
    c.close();
  }
}

function status(root: string, json: boolean): number {
  const p = statePaths(root);
  const store = FakeStore.atDir(p.store);
  const key = readJournalKey(p);
  const v = verifyJournalFile(p.journal, key);
  const policy = loadPolicy(p.policy);
  const ledger = BudgetLedger.fromRecords(v.records);
  const tasks = store.list();
  const epics = [...new Set(tasks.map((t) => t.epicId))];
  const escalations = v.records.filter((r) => r.type === 'escalation').map((r) => r.data);
  const blockedIds = new Set(tasks.filter((t) => t.state === 'blocked').map((t) => t.id));
  const openEsc = escalations.filter((e) => blockedIds.has((e as { taskId: string }).taskId));
  const data = {
    tasks: tasks.map((t) => ({ id: t.id, state: t.state, attempt: t.attempt, correctionFailures: t.correctionFailures, infraFailures: t.infraFailures, deps: t.deps })),
    budget: epics.map((e) => ({ epic: e, cap: policy.budget.epic, spent: ledger.spent('epic', e), reserved: ledger.reserved('epic', e) })),
    reservationPerInvocation: reservationAmount(policy.budget),
    escalations: openEsc,
    journal: { records: v.records.length, ok: v.ok, tornTail: v.tornTail },
  };
  if (json) {
    out(JSON.stringify(data, null, 2));
    return 0;
  }
  const lines = ['TASK                 STATE            ATTEMPT  FAILS(corr/infra)'];
  for (const t of data.tasks) lines.push(`${t.id.padEnd(20)} ${t.state.padEnd(16)} ${String(t.attempt).padEnd(8)} ${t.correctionFailures}/${t.infraFailures}`);
  for (const b of data.budget) lines.push(`budget ${b.epic}: spent $${b.spent.usd.toFixed(4)} / ${b.spent.tokens} tok, reserved $${b.reserved.usd.toFixed(4)}, cap $${b.cap.usd} / ${b.cap.tokens} tok (estimates, not billing)`);
  for (const e of data.escalations) lines.push(`ESCALATION ${JSON.stringify(e)}`);
  lines.push(`journal: ${data.journal.records} records, ${data.journal.ok ? 'verified' : 'FAILED VERIFICATION'}`);
  out(lines.join('\n'));
  return 0;
}

/**
 * Human gates (repository approval, plan approval, unblocking) require typing a word on an
 * interactive terminal. Agents driving the CLI through a non-TTY shell cannot pass them.
 */
async function confirmHuman(prompt: string, word: string): Promise<void> {
  if (!process.stdin.isTTY || !process.stdout.isTTY) {
    throw new UsageError('this action needs a human at an interactive terminal (no TTY detected)');
  }
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  try {
    const answer = (await rl.question(prompt)).trim();
    if (answer !== word) throw new UsageError('not confirmed');
  } finally {
    rl.close();
  }
}

function out(s: string): void {
  process.stdout.write(s.endsWith('\n') ? s : s + '\n');
}

class UsageError extends Error {}

main(process.argv.slice(2)).then(
  (code) => {
    process.exitCode = code;
  },
  (err: unknown) => {
    process.stderr.write(`eo: ${(err as Error).message}\n`);
    process.exitCode = err instanceof UsageError ? 2 : 1;
  },
);
