// One scenario of a durable run (M2-0), in its own process so a crash or kill of it, or of
// the runner, never corrupts another scenario. The runner sets TMPDIR to a fresh directory
// for this attempt, so every sandbox the scenario creates starts empty.
//
//   node scenario-child.ts <run dir> <scenario id> <result file>
import * as fs from 'node:fs';
import * as path from 'node:path';
import { writeFileAtomic } from '../../../src/util/fsx.ts';
import { FILES, type Manifest } from './checkpoints.ts';
import { SUITES } from './suites.ts';

const [dir, id, resultFile] = process.argv.slice(2) as [string, string, string];
const manifest = JSON.parse(fs.readFileSync(path.join(dir, FILES.manifest), 'utf8')) as Manifest;
const suite = SUITES[manifest.suite];
const scenario = manifest.scenarios.find((s) => s.id === id);

try {
  if (!suite || !scenario) throw new Error(`unknown suite ${manifest.suite} or scenario ${id}`);
  const detail = await suite.run(scenario, manifest.params, manifest.derived);
  writeFileAtomic(resultFile, JSON.stringify({ ok: true, detail }));
  process.exit(0);
} catch (err) {
  writeFileAtomic(resultFile, JSON.stringify({ ok: false, detail: (err as Error).stack ?? String(err) }));
  process.exit(1);
}
