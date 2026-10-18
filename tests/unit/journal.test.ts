import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { randomBytes } from 'node:crypto';
import { Journal, JournalTamperError, verifyJournalFile } from '../../src/journal.ts';
import { tmpDir } from '../support/helpers.ts';

function journalWith(n: number): { file: string; key: Buffer } {
  const file = path.join(tmpDir(), 'journal.jsonl');
  const key = randomBytes(32);
  const j = Journal.open(file, key);
  for (let i = 1; i <= n; i++) j.append('test', { i });
  return { file, key };
}

function lines(file: string): string[] {
  return fs.readFileSync(file, 'utf8').split('\n').filter(Boolean);
}

test('appends are chained, sequential and verify', () => {
  const { file, key } = journalWith(5);
  const v = verifyJournalFile(file, key);
  assert.equal(v.ok, true);
  assert.deepEqual(v.records.map((r) => r.seq), [1, 2, 3, 4, 5]);
  assert.equal(v.records[0]?.prev, 'genesis');
  for (let i = 1; i < v.records.length; i++) assert.equal(v.records[i]?.prev, v.records[i - 1]?.mac);
});

test('reopening continues the chain', () => {
  const { file, key } = journalWith(3);
  const j = Journal.open(file, key);
  j.append('more', {});
  const v = verifyJournalFile(file, key);
  assert.equal(v.ok, true);
  assert.equal(v.records.length, 4);
});

test('M1-5: editing a record is detected', () => {
  const { file, key } = journalWith(4);
  const ls = lines(file);
  const rec = JSON.parse(ls[1] as string) as { data: { i: number } };
  rec.data.i = 99;
  ls[1] = JSON.stringify(rec);
  fs.writeFileSync(file, ls.join('\n') + '\n');
  const v = verifyJournalFile(file, key);
  assert.equal(v.ok, false);
  assert.match(v.errors.join(';'), /line 2: MAC mismatch/);
  assert.throws(() => Journal.open(file, key), JournalTamperError);
});

test('M1-5: deleting a record is detected', () => {
  const { file, key } = journalWith(4);
  const ls = lines(file);
  ls.splice(1, 1);
  fs.writeFileSync(file, ls.join('\n') + '\n');
  const v = verifyJournalFile(file, key);
  assert.equal(v.ok, false);
  assert.match(v.errors.join(';'), /seq 3, expected 2/);
  assert.match(v.errors.join(';'), /chain broken/);
});

test('M1-5: deleting the final record is not detectable from the file alone (documented limit)', () => {
  // Truncating the tail leaves a valid shorter chain. The controller detects it because the
  // store and other artefacts reference later records; doctor tests cover that path.
  const { file, key } = journalWith(4);
  const ls = lines(file);
  fs.writeFileSync(file, ls.slice(0, 3).join('\n') + '\n');
  assert.equal(verifyJournalFile(file, key).ok, true);
});

test('M1-5: reordering records is detected', () => {
  const { file, key } = journalWith(4);
  const ls = lines(file);
  [ls[1], ls[2]] = [ls[2] as string, ls[1] as string];
  fs.writeFileSync(file, ls.join('\n') + '\n');
  assert.equal(verifyJournalFile(file, key).ok, false);
});

test('M1-5: a record re-MACed with a different key is detected', () => {
  const { file, key } = journalWith(2);
  const forged = journalWith(3);
  const ls = lines(file);
  ls.push(lines(forged.file)[2] as string);
  fs.writeFileSync(file, ls.join('\n') + '\n');
  const v = verifyJournalFile(file, key);
  assert.equal(v.ok, false);
  assert.match(v.errors.join(';'), /line 3/);
});

test('the wrong key fails every record', () => {
  const { file } = journalWith(3);
  const v = verifyJournalFile(file, randomBytes(32));
  assert.equal(v.errors.filter((e) => e.includes('MAC mismatch')).length, 3);
});

test('a torn final line is reported, refused without repair, and removed with repair', () => {
  const { file, key } = journalWith(3);
  fs.appendFileSync(file, '{"seq":4,"ts":"2026-');
  const v = verifyJournalFile(file, key);
  assert.equal(v.ok, true);
  assert.equal(v.tornTail, true);
  assert.equal(v.records.length, 3);
  assert.throws(() => Journal.open(file, key), /torn final line/);
  const j = Journal.open(file, key, { repairTornTail: true });
  j.append('after', {});
  const v2 = verifyJournalFile(file, key);
  assert.equal(v2.ok, true);
  assert.equal(v2.tornTail, false);
  assert.deepEqual(v2.records.map((r) => r.seq), [1, 2, 3, 4]);
});

test('garbage in the middle of the journal is tampering, not a torn tail', () => {
  const { file, key } = journalWith(3);
  const ls = lines(file);
  ls.splice(1, 0, '{not json');
  fs.writeFileSync(file, ls.join('\n') + '\n');
  const v = verifyJournalFile(file, key);
  assert.equal(v.ok, false);
  assert.equal(v.tornTail, false);
});

test('a complete final record without its newline is accepted (its MAC proves it whole)', () => {
  const { file, key } = journalWith(2);
  const text = fs.readFileSync(file, 'utf8');
  fs.writeFileSync(file, text.slice(0, -1)); // drop the final newline only
  const v = verifyJournalFile(file, key);
  // A complete JSON line is accepted even without its newline; its MAC proves it whole.
  assert.equal(v.ok, true);
  assert.equal(v.records.length, 2);
});

test('ofType filters and records() reflects appends', () => {
  const file = path.join(tmpDir(), 'j.jsonl');
  const j = Journal.open(file, randomBytes(32));
  j.append('a', 1);
  j.append('b', 2);
  j.append('a', 3);
  assert.deepEqual(j.ofType<number>('a').map((r) => r.data), [1, 3]);
  assert.equal(j.records().length, 3);
});

test('appending after a final record that lost its newline keeps the journal valid', () => {
  const { file, key } = journalWith(2);
  const text = fs.readFileSync(file, 'utf8');
  fs.writeFileSync(file, text.slice(0, -1));
  Journal.open(file, key, { repairTornTail: true }).append('after', {});
  const v = verifyJournalFile(file, key);
  assert.equal(v.ok, true, v.errors.join('; '));
  assert.deepEqual(v.records.map((r) => r.seq), [1, 2, 3]);
});

test('M1-5: a record spliced in from a diverged copy (same key) with its prev rewritten is detected', () => {
  // Two copies of one state root diverge after record 2, e.g. a restored backup. Record 4 of
  // the other copy has the right seq and key; only the MAC over the chain link exposes it.
  const { file, key } = journalWith(2);
  const forkFile = file + '.fork';
  fs.copyFileSync(file, forkFile);
  const a = Journal.open(file, key);
  a.append('real', { v: 'a3' });
  a.append('real', { v: 'a4' });
  const b = Journal.open(forkFile, key);
  b.append('forged', { v: 'b3' });
  b.append('forged', { v: 'b4' });
  const real = lines(file);
  const forged = JSON.parse(lines(forkFile)[3] as string) as { prev: string };
  forged.prev = (JSON.parse(real[3] as string) as { prev: string }).prev; // fit the real chain
  real[3] = JSON.stringify(forged);
  fs.writeFileSync(file, real.join('\n') + '\n');
  const v = verifyJournalFile(file, key);
  assert.equal(v.ok, false);
  assert.deepEqual(v.errors, ['line 4: MAC mismatch']);
});
