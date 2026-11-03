// Generates the legacy-m1 state roots in this directory with the PRE-SPLIT code, where runner
// results still carried their own verdicts. Kept for provenance; it is not part of any test.
//
// It must be run against a checkout of origin/main at 79fef7a, not against this code:
//   git worktree add /tmp/eo-m1 79fef7a
//   node tests/fixtures/legacy-m1/generate.ts /tmp/eo-m1 <out dir>
// It imports the controller, journal and test helpers from the checkout given as the first
// argument and writes crash-after-fail-end, crash-after-pass-end and complete under the second.
// Output is not byte-reproducible (journal keys, timestamps, temp paths and owners differ per
// run), so the committed fixtures are the ones it produced once; never regenerate them in place.
import * as fs from 'node:fs';
import * as path from 'node:path';
const WT = process.argv[2]!;
const OUT = process.argv[3]!;
const { sandbox, runCli, writeJson } = await import(path.join(WT, 'tests/support/helpers.ts'));
const { Controller } = await import(path.join(WT, 'src/controller.ts'));
const { verifyJournalFile } = await import(path.join(WT, 'src/journal.ts'));
const { readJournalKey, statePaths } = await import(path.join(WT, 'src/stateRoot.ts'));
const plan = { epicId: 'L1', title: 'legacy', tasks: [{ id: 'A', title: 'a', deps: [] }, { id: 'B', title: 'b', deps: [] }] };
const records = (root: string): any[] => verifyJournalFile(statePaths(root).journal, readJournalKey(statePaths(root))).records;
function make(name: string, script: object, crashAfter?: (r: any) => boolean): void {
  const sb = sandbox();
  const c = Controller.open(sb.root);
  c.importPlan(plan, sb.repo, 'fixture-human');
  c.close();
  const sf = writeJson(path.join(sb.dir, 'script.json'), script);
  const args = ['run', '--state-root', sb.root, '--repo', sb.repo, '--runner', 'fake', '--script', sf];
  if (crashAfter) {
    // A dry run on a twin state root finds the append count (EO_CRASH_AT) of the record to crash after.
    const b = sandbox();
    const cb = Controller.open(b.root);
    cb.importPlan(plan, b.repo, 'fixture-human');
    cb.close();
    const before = records(b.root).length;
    const bsf = writeJson(path.join(b.dir, 'script.json'), script);
    const r0 = runCli(['run', '--state-root', b.root, '--repo', b.repo, '--runner', 'fake', '--script', bsf]);
    if (r0.status !== 0) throw new Error(r0.stderr);
    const k = records(b.root).slice(before).findIndex(crashAfter) + 1;
    const r = runCli(args, { EO_CRASH_AT: String(k) });
    if (r.status !== 137) throw new Error(`expected crash: ${r.status} ${r.stderr}`);
  } else {
    const r = runCli(args);
    if (r.status !== 0) throw new Error(r.stderr);
  }
  const dest = path.join(OUT, name);
  fs.rmSync(dest, { recursive: true, force: true });
  fs.cpSync(sb.root, dest, { recursive: true });
  fs.rmSync(path.join(dest, 'locks'), { recursive: true, force: true });
  fs.mkdirSync(path.join(dest, 'locks'));
  fs.writeFileSync(path.join(dest, 'locks', '.keep'), '');
  console.log(name, 'records', records(sb.root).length, 'last', records(sb.root).at(-1).type);
}
const isEnd = (task: string, verdict: string) => (r: any): boolean => r.type === 'attempt.end' && r.data.taskId === task && r.data.result.verification?.verdict === verdict;
make('crash-after-fail-end', { default: { behaviour: 'pass' }, tasks: { A: [{ behaviour: 'verify-fail', signature: 'legacy:A1' }] } }, isEnd('A', 'fail'));
make('crash-after-pass-end', { default: { behaviour: 'pass' } }, isEnd('A', 'pass'));
make('complete', { default: { behaviour: 'pass' }, tasks: { A: [{ behaviour: 'verify-fail', signature: 'legacy:A1' }], B: [{ behaviour: 'review-fail' }] } });
