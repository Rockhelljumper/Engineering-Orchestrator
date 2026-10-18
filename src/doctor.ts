import * as fs from 'node:fs';
import * as path from 'node:path';
import { verifyJournalFile } from './journal.ts';
import { EvidenceLedger } from './evidence.ts';
import { BudgetLedger } from './budget.ts';
import { loadPolicy, policyHash } from './policy.ts';
import { readJournalKey, statePaths } from './stateRoot.ts';
import { FakeStore } from './store/fake.ts';
import type { TaskStore } from './store/types.ts';
import { expectedStates, type EscalationRecord } from './controller.ts';

export interface DoctorReport {
  ok: boolean;
  problems: string[];
  warnings: string[];
  journalRecords: number;
}

/** Read-only integrity check of a state root. Never modifies anything. */
export function doctor(root: string, store?: TaskStore): DoctorReport {
  const p = statePaths(root);
  const problems: string[] = [];
  const warnings: string[] = [];
  if (process.env['EO_CRASH_AT'] !== undefined) warnings.push('EO_CRASH_AT is set (test-only crash injection)');
  const key = readJournalKey(p);
  const v = verifyJournalFile(p.journal, key);
  problems.push(...v.errors.map((e) => `journal: ${e}`));
  if (v.tornTail) warnings.push('journal has a torn final line (crash during write); "eo resume" will remove it');

  try {
    const pol = loadPolicy(p.policy);
    const sets = v.records.filter((r) => r.type === 'policy.set');
    const last = sets[sets.length - 1]?.data as { hash: string } | undefined;
    if (last && last.hash !== policyHash(pol)) problems.push('policy.json differs from the last journaled policy hash');
  } catch (err) {
    problems.push(`policy: ${(err as Error).message}`);
  }

  const s = store ?? FakeStore.atDir(p.store);
  const expected = expectedStates(v.records);
  for (const [id, exp] of expected) {
    const t = s.get(id);
    if (!t) problems.push(`store: task ${id} missing (journal has it)`);
    else if (t.state !== exp.state) problems.push(`store: ${id} is ${t.state}, journal says ${exp.state} (resume will repair)`);
  }
  for (const t of s.list()) if (!expected.has(t.id)) problems.push(`store: task ${t.id} not in journal`);

  try {
    const ledger = BudgetLedger.fromRecords(v.records);
    for (const r of ledger.openReservations()) warnings.push(`budget: reservation ${r.id} still open`);
  } catch (err) {
    problems.push(`budget: ${(err as Error).message}`);
  }

  const ev = new EvidenceLedger(p.evidence, key);
  for (const t of s.list()) {
    if (t.state === 'done') {
      if (t.attempt < 1) {
        problems.push(`evidence ${t.id}: done without any attempt`);
        continue;
      }
      for (const prob of ev.verify(t.id, t.attempt)) problems.push(`evidence ${t.id}#${t.attempt}: ${prob}`);
    }
  }

  for (const r of v.records) {
    if (r.type !== 'escalation') continue;
    const e = r.data as EscalationRecord;
    if (!fs.existsSync(path.join(p.escalations, `${e.id}.json`))) warnings.push(`escalation file ${e.id} missing (resume will rewrite)`);
  }

  return { ok: problems.length === 0, problems, warnings, journalRecords: v.records.length };
}
