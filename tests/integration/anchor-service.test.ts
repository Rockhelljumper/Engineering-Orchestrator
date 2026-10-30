import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { rootIdOf } from '../../src/anchor.ts';
import { AnchorServiceClient } from '../../src/anchorService.ts';
import { Controller, RecoveryRefusedError } from '../../src/controller.ts';
import { FakeRunner } from '../../src/runner/fake.ts';
import { anchorAdmin, ANCHOR_IS_SERVICE, samplePlan, sandbox, type Sandbox } from '../support/helpers.ts';

/**
 * M2 Phase B, B7 and B8 through the controller: the Phase A rollback attacks rerun with the
 * anchor held by the eo-anchor service. Runs only with EO_TEST_ANCHOR=service (Linux).
 */
const skip = !ANCHOR_IS_SERVICE && 'set EO_TEST_ANCHOR=service';

function snapshot(sb: Sandbox, name: string): string {
  const dst = path.join(sb.dir, `snap-${name}`);
  fs.cpSync(sb.root, dst, { recursive: true });
  return dst;
}

function restore(sb: Sandbox, snap: string): void {
  fs.rmSync(sb.root, { recursive: true });
  fs.cpSync(snap, sb.root, { recursive: true });
}

function planned(): Sandbox {
  const sb = sandbox();
  const c = Controller.open(sb.root);
  c.importPlan(samplePlan(), sb.repo, 'h');
  c.close();
  return sb;
}

function service(): AnchorServiceClient {
  return AnchorServiceClient.open(process.env['EO_ANCHOR_SOCKET'] as string);
}

async function runSome(sb: Sandbox, steps: number): Promise<void> {
  const c = Controller.open(sb.root);
  try {
    await c.run(new FakeRunner({ default: { behaviour: 'pass', costUsd: 0.1 } }), { repoPath: sb.repo, maxSteps: steps });
  } finally {
    c.close();
  }
}

test('B7: the controller keeps its head in the service, one record at a time', { skip }, async () => {
  const sb = planned();
  await runSome(sb, 1);
  const c = Controller.open(sb.root);
  try {
    const head = service().read(rootIdOf(sb.root));
    const last = c.journal.records().at(-1);
    assert.equal(head?.journalSeq, last?.seq);
    assert.equal(head?.journalMac, last?.mac);
    assert.match(c.anchor.dir, /^eo-anchor service at /);
  } finally {
    c.close();
  }
});

test('B7: restoring an older copy of the state root is refused, nothing runs, and a forensic record is written', { skip }, async () => {
  const sb = planned();
  await runSome(sb, 1);
  const snap = snapshot(sb, 'early');
  await runSome(sb, 2);
  const before = service().read(rootIdOf(sb.root));
  restore(sb, snap);
  assert.throws(() => Controller.open(sb.root), (e: unknown) => e instanceof RecoveryRefusedError && /behind its anchored head/.test((e as Error).message));
  const forensic = fs.readdirSync(path.join(sb.root, 'forensics')).filter((f) => f.endsWith('-rollback-refused.json'));
  assert.equal(forensic.length, 1);
  assert.deepEqual(service().read(rootIdOf(sb.root)), before, 'the refused open did not move the anchor');
});

test('B8: a controller that tries to move the head backwards is refused by the service itself and locks the root', { skip }, async () => {
  const sb = planned();
  await runSome(sb, 1);
  const rootId = rootIdOf(sb.root);
  const s = service();
  const head = s.read(rootId);
  assert.ok(head && head.journalSeq > 2);
  // Bypass the controller's own checks: ask the service directly for an older head.
  assert.throws(() => s.advance(rootId, head.keyId, head.root, head.journalSeq - 1, 'a'.repeat(64), 'b'.repeat(64)), /refused the request: backwards/);
  assert.throws(() => Controller.open(sb.root), /locked after an earlier refused request/);
  const refusals = anchorAdmin(['refusals'])['records'] as Array<{ reason: string; peer: { uid: number } }>;
  assert.ok(refusals.some((r) => /backwards/.test(r.reason) && r.peer.uid === process.getuid?.()));
  assert.equal(anchorAdmin(['clear', rootId, '--note', 'test'])['ok'], true);
  await runSome(sb, 1);
});

test('B7: an operator grant is needed to accept a rollback; the dropped head is kept by the service', { skip }, async () => {
  const sb = planned();
  await runSome(sb, 1);
  const snap = snapshot(sb, 'early');
  await runSome(sb, 1);
  const rootId = rootIdOf(sb.root);
  restore(sb, snap);
  // Without the grant the controller's forget is refused by the service.
  assert.throws(() => Controller.open(sb.root, { adopt: { by: 'operator', acceptRollback: true } }), /accept-rollback grant/);
  anchorAdmin(['clear', rootId]);
  assert.equal(anchorAdmin(['grant', rootId, 'accept-rollback', '--ttl', '60'])['ok'], true);
  const c = Controller.open(sb.root, { adopt: { by: 'operator', acceptRollback: true } });
  try {
    assert.equal(c.anchorBinding, 'rollback-accepted');
  } finally {
    c.close();
  }
  await runSome(sb, 1);
  // The grant was used once; a second rollback needs a new one.
  const snap2 = snapshot(sb, 'later');
  await runSome(sb, 1);
  restore(sb, snap2);
  assert.throws(() => Controller.open(sb.root, { adopt: { by: 'operator', acceptRollback: true } }), /accept-rollback grant/);
});

test('B7: a state root moved to a new path needs an adopt grant', { skip }, async () => {
  const sb = planned();
  await runSome(sb, 1);
  const moved = path.join(sb.dir, 'moved');
  fs.renameSync(sb.root, moved);
  assert.throws(() => Controller.open(moved), /moved or copied here/);
  assert.throws(() => Controller.open(moved, { adopt: { by: 'operator' } }), /no operator grant/);
  anchorAdmin(['clear', rootIdOf(moved)]);
  assert.equal(anchorAdmin(['grant', rootIdOf(moved), 'adopt', '--ttl', '60'])['ok'], true);
  // The refused attempt journaled its anchor.bound record before the service refused to
  // anchor it, so this open finds the journal one record ahead and anchors that record now,
  // which the grant allows. Without the grant the repair is refused like any other advance.
  const c = Controller.open(moved, { adopt: { by: 'operator' } });
  try {
    assert.equal(c.anchorRepaired, true);
    const bound = c.journal.ofType('anchor.bound').at(-1);
    assert.equal((bound?.data as { adoptedBy?: string } | undefined)?.adoptedBy, 'operator');
    assert.equal(service().read(rootIdOf(moved))?.journalMac, c.journal.records().at(-1)?.mac);
  } finally {
    c.close();
  }
});
