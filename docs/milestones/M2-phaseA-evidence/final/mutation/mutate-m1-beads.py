# Mutation check for the beads integration: each mutation must make its target tests fail.
# Runs in a separate worktree so the evidence suites in the main tree are untouched.
import subprocess, shutil, os
import sys
R=sys.argv[1]
B='src/store/beads.ts'
M=[
 ('CAS guard dropped from updates', B, "'--if-revision', String(issue.revision), ", "", ['tests/integration/concurrent-claims.test.ts'], 'M1-3 \\(beads\\)'),
 ('metrics opt-out removed from the bd environment', B, "    BD_DISABLE_METRICS: '1',\n", "", ['tests/integration/beads.test.ts'], 'M1-7'),
 ('binary hash not checked', B, "        if (got !== want) throw", "        if (false && got !== want) throw", ['tests/integration/beads.test.ts'], 'pinned build|unpinned'),
 ('per-spawn binary identity check removed', B, "    if (fileId(this.bin) !== this.binId) {", "    if (false && fileId(this.bin) !== this.binId) {", ['tests/integration/beads.test.ts'], 'verified private entry'),
 ('store not given its own git repository', B, "spawnSync('git', ['init', '-q', s.dir]", "spawnSync('git', ['--version']", ['tests/integration/beads.test.ts'], 'encloses'),
 ('half-initialised store not repaired', B, "    if (!fs.existsSync(path.join(s.dir, INIT_MARKER))) {\n      for", "    if (!fs.existsSync(path.join(s.dir, '.beads'))) {\n      for", ['tests/integration/beads.test.ts'], 'killed part-way'),
 ('beads without eo metadata accepted', B, "    if (foreign.length) throw", "    if (false && foreign.length) throw", ['tests/integration/beads.test.ts'], 'behind the controller'),
 ('store binding checked only after the store is created', 'src/controller.ts', "openStore(paths, { create: true, records: before.records, evidenceOrEscalations:", "openStore(paths, { create: true, records: undefined, evidenceOrEscalations:", ['tests/integration/beads.test.ts'], 'bound to the fake store'),
 ('store runs a hard link to the source instead of its own copy', B, "fs.copyFileSync(src, tmp, fs.constants.COPYFILE_FICLONE);", "fs.linkSync(src, tmp);", ['tests/integration/beads.test.ts'], 'its own copy'),
 ('closing a task with open dependencies not forced', B, "      if (status === 'closed') args.push('--force');", "", ['tests/integration/store-contract.test.ts'], "ordering is the controller"),
 ('existing bd entry trusted when it is a link', B, "if (!st || !st.isFile() || st.nlink !== 1n) return undefined;", "if (!st) return undefined;", ['tests/integration/beads.test.ts'], 'symlink or a hard link'),
 ('beads store directory permissions not checked', B, "      assertPrivateDir(dir);\n      assertPrivateDir(binDir);", "", ['tests/integration/beads.test.ts'], 'others can write'),
 ('re-initialisation allowed once evidence exists', 'src/store/open.ts', "const established = (opts.records?.length ?? 0) > 0 || opts.evidenceOrEscalations === true;", "const established = (opts.records?.length ?? 0) > 0;", ['tests/integration/beads.test.ts'], 'refused once evidence exists'),
 ('re-initialisation allowed after plans were imported', 'src/store/open.ts', "    if (established && !BeadsStore.isInitialised(paths.store)) {", "    if (false && !BeadsStore.isInitialised(paths.store)) {", ['tests/integration/beads.test.ts'], 'after plans were imported'),
]
out=[]; ok=True
env=dict(os.environ, EO_BD_BIN='/opt/beads-9c6f6e1/bd')
for name,f,a,b,tests,pat in M:
    p=f'{R}/{f}'; bak=p+'.mutbak'
    src=open(p).read(); assert src.count(a)==1,(name,a)
    shutil.copy(p,bak)
    try:
        open(p,'w').write(src.replace(a,b))
        r=subprocess.run(['node','--test','--test-concurrency=1','--test-name-pattern',pat,*tests],cwd=R,capture_output=True,text=True,timeout=3600,env=env)
        fails=[l for l in r.stdout.splitlines() if l.startswith('# fail')]
        passes=[l for l in r.stdout.splitlines() if l.startswith('# pass')]
        killed = r.returncode!=0
        ok = ok and killed
        out.append(f"{'KILLED' if killed else 'SURVIVED'}  {name}  [{f}]  {fails[-1] if fails else ''}  ({', '.join(tests)}, pattern {pat!r})")
    finally:
        shutil.move(bak,p)
# Control: the unmutated tree passes the same selections.
for name,f,a,b,tests,pat in M:
    if 'M1-3' in pat: continue
    r=subprocess.run(['node','--test','--test-concurrency=1','--test-name-pattern',pat,*tests],cwd=R,capture_output=True,text=True,timeout=3600,env=env)
    out.append(f"control {'PASS' if r.returncode==0 else 'FAIL'}  pattern {pat!r}")
print('\n'.join(out)); print('ALL KILLED' if ok else 'SOME SURVIVED')
