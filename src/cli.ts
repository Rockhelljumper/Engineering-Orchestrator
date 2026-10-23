#!/usr/bin/env node
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as readline from 'node:readline/promises';
import { parseArgs } from 'node:util';
import { Controller } from './controller.ts';
import { doctor } from './doctor.ts';
import { defaultStateRoot, initStateRoot, statePaths } from './stateRoot.ts';
import { FakeRunner } from './runner/fake.ts';
import { openStore } from './store/open.ts';
import { verifyBdBinary } from './store/beads.ts';
import { BudgetLedger, reservationAmount } from './budget.ts';
import { verifyJournalFile } from './journal.ts';
import { readJournalKey } from './stateRoot.ts';
import { loadPolicy } from './policy.ts';
import { EvidenceLedger } from './evidence.ts';
import { defaultAnchorDir, inspectAnchor } from './anchor.ts';

const USAGE = `eo — Engineering Orchestrator controller (M2 Phase A)

Usage: eo <command> [options]   (global: --state-root <dir>, or EO_STATE_ROOT)

  The rollback anchor (M2-0b) records the journal head outside the state root, in
  EO_ANCHOR_DIR or the platform default (~/.local/state/eo-anchor on Linux); keep it where a
  restore of the state root cannot reach it. A state root the anchor refuses is not opened;
  only a human can adopt it.

  init [--store fake|beads] [--bd-bin <path>]
                                    create a state root (policy, journal key, store); beads
                                    needs the pinned bd build (--bd-bin, or EO_BD_BIN)
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
  anchor adopt [--accept-rollback]  bind a state root the anchor has never seen (made before
                                    M2-0b, or moved) after checking where it came from; with
                                    --accept-rollback, also one the anchor refuses (an older
                                    or different copy), keeping a forensic record of the head
                                    it replaces (interactive confirmation)
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
      store: { type: 'string' },
      'bd-bin': { type: 'string' },
      'accept-rollback': { type: 'boolean' },
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
      const kind = values.store ?? 'fake';
      if (kind !== 'fake' && kind !== 'beads') throw new UsageError('--store must be fake or beads');
      const bin = values['bd-bin'] ?? process.env['EO_BD_BIN'];
      if (kind === 'beads' && !bin) throw new UsageError('--store beads needs --bd-bin <path> (or EO_BD_BIN)');
      if (kind === 'beads') verifyBdBinary(bin as string); // before anything is written
      const p = initStateRoot(root, kind === 'beads' ? { kind, bin: bin as string } : { kind });
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
    case 'anchor': {
      if (sub !== 'adopt') break;
      const p = statePaths(root);
      const a = inspectAnchor(defaultAnchorDir(), p.root, readJournalKey(p), verifyJournalFile(p.journal, readJournalKey(p)).records);
      out(`anchor: ${a.check.kind}${'reason' in a.check ? `: ${a.check.reason}` : ''}`);
      const rollback = values['accept-rollback'] === true;
      if (a.check.kind === 'refuse' && !rollback) throw new UsageError('the anchor refuses this state root; adopting it means accepting it as older than, or different from, what the anchor recorded: rerun with --accept-rollback after investigating');
      if (a.check.kind !== 'refuse' && a.check.kind !== 'unadopted') {
        out('nothing to adopt');
        return 0;
      }
      await confirmHuman(
        rollback ? `Accept ${p.root} as the state root to carry on from, replacing the anchor's head for it? Type "accept rollback" to continue: ` : `Adopt ${p.root} into the rollback anchor? Type "adopt" to continue: `,
        rollback ? 'accept rollback' : 'adopt',
      );
      const c = Controller.open(root, { adopt: { by: os.userInfo().username, acceptRollback: rollback } });
      try {
        out(`${c.anchorBinding ?? 'already bound'}: ${p.root}`);
        return 0;
      } finally {
        c.close();
      }
    }
    case 'evidence': {
      if (!sub) throw new UsageError('usage: eo evidence <task> [--attempt n]');
      const p = statePaths(root);
      const v = verifyJournalFile(p.journal, readJournalKey(p));
      // Evidence from a rolled-back or unknown state root is not reported as verified.
      const a = inspectAnchor(defaultAnchorDir(), p.root, readJournalKey(p), v.records).check;
      if (a.kind === 'refuse' || a.kind === 'unadopted') throw new UsageError(`not verified: the rollback anchor refuses this state root (${a.reason})`);
      const store = openStore(p, { create: false, records: v.records });
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
  const key = readJournalKey(p);
  const v = verifyJournalFile(p.journal, key);
  let anchor: string;
  try {
    const a = inspectAnchor(defaultAnchorDir(), p.root, key, v.records).check;
    anchor = a.kind === 'refuse' || a.kind === 'unadopted' ? `REFUSED: ${a.reason}` : a.kind;
  } catch (err) {
    anchor = `REFUSED: ${(err as Error).message}`;
  }
  const store = openStore(p, { create: false, records: v.records });
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
    anchor,
  };
  if (json) {
    out(JSON.stringify(data, null, 2));
    return anchor.startsWith('REFUSED') ? 1 : 0;
  }
  const lines = ['TASK                 STATE            ATTEMPT  FAILS(corr/infra)'];
  for (const t of data.tasks) lines.push(`${t.id.padEnd(20)} ${t.state.padEnd(16)} ${String(t.attempt).padEnd(8)} ${t.correctionFailures}/${t.infraFailures}`);
  for (const b of data.budget) lines.push(`budget ${b.epic}: spent $${b.spent.usd.toFixed(4)} / ${b.spent.tokens} tok, reserved $${b.reserved.usd.toFixed(4)}, cap $${b.cap.usd} / ${b.cap.tokens} tok (estimates, not billing)`);
  for (const e of data.escalations) lines.push(`ESCALATION ${JSON.stringify(e)}`);
  lines.push(`journal: ${data.journal.records} records, ${data.journal.ok ? 'verified' : 'FAILED VERIFICATION'}`);
  lines.push(`rollback anchor: ${anchor}${anchor.startsWith('REFUSED') ? ' (these states are not trustworthy; run "eo doctor")' : ''}`);
  out(lines.join('\n'));
  return anchor.startsWith('REFUSED') ? 1 : 0;
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
