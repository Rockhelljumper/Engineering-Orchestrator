# M2 Phase A mutation check, after the review fixes: each mutation reintroduces a defect the
# code prevents; its target tests must fail. Files are restored after each.
#   python3 -I mutate-m2b.py <checkout>
import subprocess, shutil, sys
R = sys.argv[1]
U = ['tests/unit/anchor.test.ts']
D = ['tests/behavioral/durable-run.test.ts']
M = [
 ('lock: an expired breaker is cleared but the takeover waits for another attempt', 'src/util/lock.ts', "return expired && !retried ? this.removeIfStale(true) : false;", "return false;", ['tests/integration/concurrent-claims.test.ts']),
 ('lock: a breaker left by a kill is never cleared', 'src/util/lock.ts', "if (Date.now() - fs.statSync(breaker).mtimeMs > 10_000) {", "if (false) {", ['tests/integration/concurrent-claims.test.ts']),
 ('lock: the refusal does not say the holder is not running', 'src/util/lock.ts', "isProcessAlive(info.pid) ? 'running' : 'not running'", "'running'", ['tests/integration/concurrent-claims.test.ts']),
 ('lock: an empty lock left by a kill is held for 30 s', 'src/util/lock.ts', "(st.size === 0 ? 2_000 : 30_000)", "30_000", ['tests/integration/concurrent-claims.test.ts']),
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
