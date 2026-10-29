# M2 Phase A mutation check, after the review fixes: each mutation reintroduces a defect the
# code prevents; its target tests must fail. Files are restored after each.
#   python3 -I mutate-m2b.py <checkout>
import subprocess, shutil, sys
R = sys.argv[1]
U = ['tests/unit/anchor.test.ts']
D = ['tests/behavioral/durable-run.test.ts']
M = [
 ('anchor: a refused state root is opened without --accept-rollback', 'src/controller.ts', "if (!opts.adopt?.acceptRollback) throw refusal(", "if (false) throw refusal(", U),
 ('anchor: an unanchored non-empty journal is bound without an operator', 'src/controller.ts', "if (!opts.adopt) throw refusal(", "if (false) throw refusal(", U),
 ('anchor: adopting also accepts a rollback', 'src/controller.ts', "if (!opts.adopt?.acceptRollback) throw refusal(", "if (!opts.adopt) throw refusal(", U),
 ('anchor: a re-keyed journal is not named as such', 'src/anchor.ts', "  if (head && head.keyId !== keyId) {", "  if (false) {", U),
 ('anchor: the anchor records a head under another key', 'src/anchor.ts', "    if (cur && cur.keyId !== keyId) throw", "    if (false) throw", U),
 ('anchor: a journal copied over another root is accepted', 'src/anchor.ts', "  if (bound && (bound.rootId !== rootId || bound.keyId !== keyId)) {", "  if (false) {", U),
 ('anchor: a journal behind its anchored head is accepted', 'src/anchor.ts', "  if (head.journalSeq > n) {", "  if (false) {", U),
 ('anchor: a different history is accepted', 'src/anchor.ts', "  if (!at || at.mac !== head.journalMac) {", "  if (false) {", U),
 ('anchor: any number of records ahead counts as a crash', 'src/anchor.ts', "  if (n === head.journalSeq + 1) return", "  if (n > head.journalSeq) return", U),
 ('anchor: not updated on append', 'src/controller.ts', "{ repairTornTail: true, onAppend: (r) => this.anchor.advance(this.rootId, this.keyId, root, r.seq, r.mac) }", "{ repairTornTail: true }", U),
 ('anchor: an interrupted update is not repaired on open', 'src/controller.ts', "    if (anchorState.kind === 'one-ahead' && last) this.anchor.advance", "    if (false && last) this.anchor.advance", U),
 ('anchor: may move backwards', 'src/anchor.ts', "    if (cur && journalSeq < cur.journalSeq) throw", "    if (false) throw", U),
 ('anchor: head MAC not verified', 'src/anchor.ts', "      !macEqual(h.mac, this.macOf(h))", "      false", U),
 ('anchor: allowed inside the state root', 'src/anchor.ts', "if (isWithin(resolveExisting(d), root)) throw", "if (false) throw", U),
 ('anchor: a link in a path not yet created is not followed', 'src/anchor.ts', "    if (isWithin(resolveExisting(d), root)) throw new AnchorError(`the rollback anchor ${d} is inside the state root ${root}; a restored", "    if (isWithin(path.resolve(d), root)) throw new AnchorError(`the rollback anchor ${d} is inside the state root ${root}; a restored", U),
 ('anchor: another anchor accepted for a bound journal', 'src/anchor.ts', "  if (bound && bound.anchorId !== anchorId) {", "  if (false) {", U),
 ('anchor: a removed head is accepted for a bound journal', 'src/anchor.ts', "    if (bound) return { kind: 'refuse', reason: `the journal is bound to rollback anchor ${bound.anchorId}, which has no head", "    if (false) return { kind: 'refuse', reason: `the journal is bound to rollback anchor ${bound.anchorId}, which has no head", U),
 ('anchor: the forensic record drops the head bytes', 'src/controller.ts', "head, headFileBase64: rawHead },", "head, headFileBase64: null },", U),
 ('cli: eo status ignores the anchor', 'src/cli.ts', "    anchor = a.kind === 'refuse' || a.kind === 'unadopted' ? `REFUSED", "    anchor = false ? `REFUSED", U),
 ('cli: eo evidence ignores the anchor', 'src/cli.ts', "      if (a.kind === 'refuse' || a.kind === 'unadopted') throw new UsageError(`not verified", "      if (false) throw new UsageError(`not verified", U),
 ('journal: appends continue after a failed anchor update', 'src/journal.ts', "    if (this.failed) throw", "    if (false) throw", U),
 ("doctor: a running controller's transition in flight is reported as damage", 'src/doctor.ts', "        if (running !== undefined) warnings.push(`store:", "        if (false) warnings.push(`store:", U),
 ('lock: an empty lock left by a kill is held for 30 s', 'src/util/lock.ts', "(st.size === 0 ? 2_000 : 30_000)", "30_000", ['tests/integration/concurrent-claims.test.ts']),
 ('durable: a scenario passed twice counts', 'tests/support/durable/aggregate.ts', "  if (twice.length > 0) return", "  if (false) return", D),
 ('durable: a run for another checkout is not STALE', 'tests/support/durable/aggregate.ts', "  if (current && identitySha256(current) !== want) {", "  if (false) {", D),
 ('durable: records with another identity accepted', 'tests/support/durable/aggregate.ts', "    if (identitySha256(r.identity) !== want) integrity.push", "    if (false) integrity.push", D),
 ('durable: a changed manifest is resumed', 'tests/support/durable/aggregate.ts', "  if (changed.length > 0) {", "  if (false) {", D),
 ('durable: resume does not check the declared scenarios against the plan', 'tests/support/durable/run.ts', "  if (planned !== manifest.scenarios", "  if (false && planned !== manifest.scenarios", D),
 ('durable: an end with no matching start counts', 'tests/support/durable/aggregate.ts', "      if (!st || st.scenario !== r.scenario || st.attempt !== r.attempt) integrity.push", "      if (false) integrity.push", D),
 ('durable: a torn tail is appended onto', 'tests/support/durable/checkpoints.ts', "    dropTornTail(dir, invocation);", "", D),
 ('durable: a truncated log accepted', 'tests/support/durable/checkpoints.ts', "        if (head.seq > records.length) integrity.push", "        if (false) integrity.push", D),
 ('durable: edited records accepted', 'tests/support/durable/checkpoints.ts', "    if (hash !== recordHash(rest)) integrity.push", "    if (false) integrity.push", D),
 ('durable: identity without git', 'tests/support/durable/checkpoints.ts', "  if (!commit || status === null || listed === null) throw", "  if (false) throw", D),
 ('durable: resume reruns scenarios that passed', 'tests/support/durable/run.ts', "      if (done.has(s.id) || failed.has(s.id)) continue;", "      if (failed.has(s.id)) continue;", D),
 ('durable: resume reruns a failed scenario', 'tests/support/durable/run.ts', "      if (done.has(s.id) || failed.has(s.id)) continue;", "      if (done.has(s.id)) continue;", D),
 ('durable: a killed scenario counts as passed', 'tests/support/durable/run.ts', "INTERRUPT_SIGNALS.has(signal)) resolve({ result: 'interrupted',", "INTERRUPT_SIGNALS.has(signal)) resolve({ result: 'pass',", D),
 ('durable: a scenario dying of its own signal is retried', 'tests/support/durable/run.ts', "      if (signal !== null && INTERRUPT_SIGNALS.has(signal)) resolve", "      if (signal !== null) resolve", D),
 ('durable: crash injection allowed', 'tests/support/durable/run.ts', "if (process.env[k] !== undefined) throw new DurableRunError", "if (false) throw new DurableRunError", D),
 ('drill: a dead runner\'s open start counts as in flight', 'tests/support/durable/drill.ts', "  if (invocations(dir) < nth) return undefined;", "", D),
]
out = []; ok = True
for name, f, a, b, tests in M:
    p = f'{R}/{f}'; bak = p + '.mutbak'
    src = open(p).read(); assert src.count(a) >= 1, (name, a)
    shutil.copy(p, bak)
    try:
        open(p, 'w').write(src.replace(a, b))
        r = subprocess.run(['node', '--test', '--test-concurrency=1', *tests], cwd=R, capture_output=True, text=True, timeout=1800)
        fails = [l for l in r.stdout.splitlines() if l.startswith('# fail')]
        killed = r.returncode != 0
        ok = ok and killed
        out.append(f"{'KILLED' if killed else 'SURVIVED'}  {name}  [{f}]  {fails[-1] if fails else ''}  ({', '.join(tests)})")
        print(out[-1], flush=True)
    finally:
        shutil.move(bak, p)
print('ALL KILLED' if ok else 'SOME SURVIVED')
