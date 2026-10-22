# Mutation check: each mutation must make its target tests fail. Files are restored after each.
import subprocess, shutil, sys
R=sys.argv[1]
M=[
 ('M1 states: allow planned -> done', 'src/states.ts', "planned: ['ready', 'blocked'],", "planned: ['ready', 'blocked', 'done'],", ['tests/unit/states.test.ts']),
 ('budget: USD cap never exceeded', 'src/budget.ts', "if (round(base.usd + add.usd) > cap.usd + 1e-9) return 'usd';", "if (round(base.usd + add.usd) > cap.usd + 1e9) return 'usd';", ['tests/unit/budget.test.ts','tests/unit/controller.test.ts']),
 ('budget: open reservations not counted (no defer)', 'src/budget.ts', "for (const k of keys(r)) add(this.reservedBy, k, r);", "for (const k of keys(r)) void k;", ['tests/unit/budget.test.ts']),
 ('store: claims without the cross-process lock', 'src/store/fake.ts', "const lock = this.lockFile === null ? null : new FileLock(this.lockFile, `store:${process.pid}`);", "const lock = null as FileLock | null;", ['tests/integration/concurrent-claims.test.ts']),
 ('resume: never-launched reservations left open', 'src/controller.ts', "if (!startedReservations.has(res.id)) {", "if (false && !startedReservations.has(res.id)) {", ['tests/behavioral/crash-recovery.test.ts']),
 ('journal: MAC omits the chain link', 'src/journal.ts', "data: r.data, prev: r.prev }));", "data: r.data }));", ['tests/unit/journal.test.ts']),
 ('limits: one extra correction attempt', 'src/controller.ts', "if (correctionFailures >= L.maxAttempts) {", "if (correctionFailures > L.maxAttempts) {", ['tests/unit/controller.test.ts']),
 ('evidence: artefact hashes not checked', 'src/evidence.ts', "if (actual !== e.sha256) problems.push", "if (false && actual !== e.sha256) problems.push", ['tests/unit/evidence-policy-plan.test.ts','tests/integration/cli.test.ts']),
 ('recovery: a store ahead of or off the journal is accepted', 'src/controller.ts', "    if (drift === 'diverged') {\n", "    if (false && drift === 'diverged') {\n", ['tests/unit/controller.test.ts','tests/integration/cli.test.ts']),
 ('recovery: any task behind is accepted, not only the last transition', 'src/controller.ts', "} else if (drift === 'behind' && exp.counters.journalSeq !== lastTransition) {", "} else if (false && drift === 'behind') {", ['tests/unit/controller.test.ts']),
 ('recovery: evidence the journal never recorded is accepted', 'src/controller.ts', "for (const a of evidenceAttempts) if (!ended.has(a)) problems.push", "for (const a of evidenceAttempts) if (false && !ended.has(a)) problems.push", ['tests/unit/controller.test.ts']),
 ('recovery: escalation files the journal never recorded are accepted', 'src/controller.ts', "for (const e of escalationFiles) if (!escalations.has(e)) problems.push", "for (const e of escalationFiles) if (false && !escalations.has(e)) problems.push", ['tests/unit/controller.test.ts']),
 ('recovery: not checked on open (only in resume)', 'src/controller.ts', "    this.assertRecoverable('open', before.records);\n", "", ['tests/unit/controller.test.ts']),
 ('forensics: written through a link', 'src/controller.ts', "    assertPrivateDir(dir);\n    // Random suffix", "    // Random suffix", ['tests/unit/controller.test.ts']),
 ('transition: journal position not recorded', 'src/controller.ts', "journalSeq: appended.seq };", "};", ['tests/unit/controller.test.ts']),
 ('state root: group/other write not checked', 'src/util/fsx.ts', "if ((st.mode & 0o022) !== 0) {", "if (false) {", ['tests/integration/cli.test.ts']),
 ('init: initialises over an existing journal', 'src/stateRoot.ts', "if (leftovers.length > 0) throw", "if (false) throw", ['tests/integration/cli.test.ts']),
 ('plan import: journaled ids not reserved', 'src/controller.ts', "if (this.store.get(t.id) || journaled.has(t.id))", "if (this.store.get(t.id))", ['tests/unit/controller.test.ts']),
]
out=[]
ok=True
for name,f,a,b,tests in M:
    p=f'{R}/{f}'; bak=p+'.mutbak'
    src=open(p).read(); assert src.count(a)==1,(name,a)
    shutil.copy(p,bak)
    try:
        open(p,'w').write(src.replace(a,b))
        r=subprocess.run(['node','--test','--test-concurrency=1',*tests],cwd=R,capture_output=True,text=True,timeout=1200)
        fails=[l for l in r.stdout.splitlines() if l.startswith('# fail')]
        killed = r.returncode!=0
        ok = ok and killed
        out.append(f"{'KILLED' if killed else 'SURVIVED'}  {name}  [{f}]  {fails[-1] if fails else ''}  ({', '.join(tests)})")
    finally:
        shutil.move(bak,p)
print('\n'.join(out)); print('ALL KILLED' if ok else 'SOME SURVIVED')
