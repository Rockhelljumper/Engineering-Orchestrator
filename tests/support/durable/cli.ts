#!/usr/bin/env node
// Durable runner for long test suites (M2-0). See checkpoints.ts for the run directory.
//
//   node tests/support/durable/cli.ts start  <run dir> --suite <name> [--param key=value ...] [--stall-window <s>]
//   node tests/support/durable/cli.ts resume <run dir>
//   node tests/support/durable/cli.ts status <run dir>             (exit 0 only when PASSED for this checkout)
//   node tests/support/durable/cli.ts replay <run dir> <scenario>  (rerun one scenario with its recorded seed; records nothing)
//
// Suites: selftest, crash-sample, crash-escalation (--param phase=journal|anchor),
// random-kills (--param seeds=8), claim-race (--param store=fake|beads --param rounds=100 --param workers=20).
import * as fs from 'node:fs';
import * as path from 'node:path';
import { spawnSync } from 'node:child_process';
import { parseArgs } from 'node:util';
import { REPO_ROOT, tmpDir } from '../helpers.ts';
import { aggregate, readManifest } from './aggregate.ts';
import { computeIdentity } from './checkpoints.ts';
import { createRun, DurableRunError, execute } from './run.ts';

const CODES = { usage: 2, stale: 3, 'not-verified': 4, busy: 5 } as const;

function parseParam(s: string): [string, unknown] {
  const i = s.indexOf('=');
  if (i < 1) throw new DurableRunError(`--param needs key=value, got ${s}`, 'usage');
  const v = s.slice(i + 1);
  return [s.slice(0, i), /^-?\d+$/.test(v) ? Number(v) : v];
}

async function main(argv: string[]): Promise<number> {
  const { values, positionals } = parseArgs({ args: argv, allowPositionals: true, options: { suite: { type: 'string' }, param: { type: 'string', multiple: true }, 'stall-window': { type: 'string' } } });
  const [cmd, dirArg, scenario] = positionals;
  if (!cmd || !dirArg) throw new DurableRunError('usage: cli.ts start|resume|status|replay <run dir> ...', 'usage');
  const dir = path.resolve(dirArg);
  if (cmd === 'start') {
    if (!values.suite) throw new DurableRunError('start needs --suite', 'usage');
    const params = Object.fromEntries((values.param ?? []).map(parseParam));
    await createRun(dir, values.suite, params, values['stall-window'] ? { stallWindowS: Number(values['stall-window']) } : {});
  }
  if (cmd === 'start' || cmd === 'resume') {
    const agg = await execute(dir);
    process.stdout.write(JSON.stringify(agg, null, 2) + '\n');
    return agg.status === 'PASSED' ? 0 : 1;
  }
  if (cmd === 'status') {
    const m = readManifest(dir);
    const agg = aggregate(dir, 'error' in m ? undefined : computeIdentity(REPO_ROOT, m.manifest.suite, m.manifest.params));
    process.stdout.write(JSON.stringify(agg, null, 2) + '\n');
    return agg.status === 'PASSED' ? 0 : 1;
  }
  if (cmd === 'replay') {
    if (!scenario) throw new DurableRunError('replay needs a scenario id', 'usage');
    const m = readManifest(dir);
    if ('error' in m) throw new DurableRunError(m.error, 'not-verified');
    if (!m.manifest.scenarios.some((s) => s.id === scenario)) throw new DurableRunError(`no scenario ${scenario} in this run`, 'usage');
    const work = tmpDir('eo-replay-');
    const resultFile = path.join(work, 'result.json');
    const r = spawnSync(process.execPath, [path.join(REPO_ROOT, 'tests', 'support', 'durable', 'scenario-child.ts'), dir, scenario, resultFile], { stdio: 'inherit', env: { ...process.env, TMPDIR: work, TMP: work, TEMP: work } });
    process.stdout.write(fs.existsSync(resultFile) ? fs.readFileSync(resultFile, 'utf8') + '\n' : `no result (exit ${r.status}, signal ${r.signal})\n`);
    return r.status ?? 1;
  }
  throw new DurableRunError(`unknown command ${cmd}`, 'usage');
}

main(process.argv.slice(2)).then(
  (code) => process.exit(code),
  (err: unknown) => {
    process.stderr.write(`durable: ${(err as Error).message}\n`);
    process.exit(err instanceof DurableRunError ? CODES[err.code] : 1);
  },
);
