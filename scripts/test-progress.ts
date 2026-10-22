#!/usr/bin/env node
// Summarise a progress file written by tests/support/progress.ts.
//
//   node scripts/test-progress.ts <progress.jsonl> [--stall-after <seconds>]
//
// One line per test: completed/total scenarios, the current scenario, the last meaningful
// activity and how long ago it happened. A test whose last activity is older than
// --stall-after (default 600 s) and that has not completed every scenario is marked STALLED;
// that is a prompt to inspect its processes, not proof that it is stuck.
import * as fs from 'node:fs';

interface Rec {
  ts: string;
  test: string;
  scenario: string;
  completed: number;
  total: number;
  activity: string;
  elapsedS: number;
}

const args = process.argv.slice(2);
const file = args[0];
if (!file) {
  process.stderr.write('usage: test-progress.ts <progress.jsonl> [--stall-after <seconds>]\n');
  process.exit(2);
}
const i = args.indexOf('--stall-after');
const stallAfter = i >= 0 ? Number(args[i + 1]) : 600;

const latest = new Map<string, Rec>();
for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
  if (!line.trim()) continue;
  try {
    const r = JSON.parse(line) as Rec;
    latest.set(r.test, r);
  } catch {
    // A partly written last line.
  }
}

const now = Date.now();
for (const r of latest.values()) {
  const age = Math.round((now - Date.parse(r.ts)) / 1000);
  const finished = r.completed >= r.total;
  const state = finished ? 'FINISHED' : age > stallAfter ? 'STALLED?' : 'ACTIVE';
  process.stdout.write(
    `${state.padEnd(9)} ${r.test}: ${r.completed}/${r.total} done; current ${r.scenario || '-'}; ` +
      `last activity "${r.activity}" ${age}s ago (${r.ts}); elapsed ${r.elapsedS}s at that point\n`,
  );
}
