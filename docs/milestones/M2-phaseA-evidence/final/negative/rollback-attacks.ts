// Black-box rollback attacks against a checkout's controller (requirement 7 evidence).
//   node rollback-attacks.ts <checkout>
// Uses only APIs that exist on main (M1) and on the M2 Phase A branch. Prints one JSON line
// per attack: VULNERABLE when finished tasks ran again, DEFENDED when the open was refused.
import * as fs from 'node:fs';
import * as path from 'node:path';
import { randomBytes } from 'node:crypto';
const R = path.resolve(process.argv[2] as string);
const h = await import(path.join(R, 'tests/support/helpers.ts'));
const { Controller } = await import(path.join(R, 'src/controller.ts'));
const { FakeRunner } = await import(path.join(R, 'src/runner/fake.ts'));
const { statePaths } = await import(path.join(R, 'src/stateRoot.ts'));
const { canonicalJson, hmacHex } = await import(path.join(R, 'src/util/canonical.ts'));

const plan = { epicId: 'E1', title: 't', tasks: [{ id: 'A', title: 'a', deps: [] }, { id: 'B', title: 'b', deps: [] }] };

function rekey(root: string): void {
  const p = statePaths(root);
  const newKey = randomBytes(32);
  let prev = 'genesis';
  const out: string[] = [];
  for (const line of fs.readFileSync(p.journal, 'utf8').split('\n').filter(Boolean)) {
    const r = JSON.parse(line);
    if (r.type === 'anchor.bound') { r.type = 'note'; r.data = {}; }
    r.prev = prev;
    r.mac = hmacHex(newKey, canonicalJson({ seq: r.seq, ts: r.ts, type: r.type, data: r.data, prev: r.prev }));
    prev = r.mac;
    out.push(JSON.stringify(r));
  }
  fs.writeFileSync(p.journal, out.join('\n') + '\n');
  fs.writeFileSync(p.journalKey, newKey.toString('hex'), { mode: 0o600 });
}

async function attack(name: string, tamper: (root: string) => void): Promise<void> {
  const sb = h.sandbox();
  const log = path.join(sb.dir, 'exec.log');
  const script = { execLog: log, default: { behaviour: 'pass', costUsd: 0.5 } };
  let c = Controller.open(sb.root);
  c.importPlan(plan, sb.repo, 'h');
  c.close();
  const snap = path.join(sb.dir, 'snap');
  fs.cpSync(sb.root, snap, { recursive: true });
  c = Controller.open(sb.root);
  await c.run(new FakeRunner(script), { repoPath: sb.repo });
  c.close();
  const before = h.readExecLog(log).length;
  fs.rmSync(sb.root, { recursive: true });
  fs.cpSync(snap, sb.root, { recursive: true });
  tamper(sb.root);
  let refused: string | null = null;
  try {
    c = Controller.open(sb.root);
    await c.run(new FakeRunner(script), { repoPath: sb.repo });
    c.close();
  } catch (err) {
    refused = (err as Error).message.slice(0, 200);
  }
  const after = h.readExecLog(log).length;
  console.log(JSON.stringify({ attack: name, executionsBefore: before, executionsAfter: after, verdict: refused ? 'DEFENDED' : after > before ? 'VULNERABLE' : 'UNCLEAR', refused }));
}

await attack('older copy of the whole state root restored', () => {});
await attack('older copy restored and re-signed with a new journal key, binding stripped', rekey);
