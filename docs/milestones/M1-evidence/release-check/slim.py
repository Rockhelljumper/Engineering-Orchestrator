# Replace evidence logs over 250 KB with summaries; record every evidence file's SHA-256 at the
# archived commit so the raw files stay verifiable at a stable reference.
import subprocess, hashlib, re, sys, os
R, REF, REPO = sys.argv[1], sys.argv[2], 'Rockhelljumper/Engineering-Orchestrator'
E = 'docs/milestones/M1-evidence'
LIMIT = 250_000
def git(*a, binary=False):
    r = subprocess.run(['git', '-C', R, *a], capture_output=True, check=True)
    return r.stdout if binary else r.stdout.decode()
rows = [l.split(None, 4) for l in git('ls-tree', '-r', '-l', REF, E).splitlines()]
files = [(int(r[3]), r[4]) for r in rows]
manifest, moved = [], []
for size, p in sorted(files, key=lambda x: x[1]):
    data = git('show', f'{REF}:{p}', binary=True)
    h = hashlib.sha256(data).hexdigest(); assert len(data) == size
    manifest.append(f'{h}  {size:9d}  {p[len(E)+1:]}')
    if size > LIMIT: moved.append((p, size, h, data.decode('utf-8', 'replace')))
open(f'{R}/{E}/MANIFEST.sha256', 'w').write(
    f'# SHA-256, size in bytes and path (relative to {E}/) of every evidence file at commit {REF}.\n'
    f'# Files over {LIMIT} bytes were moved out of the tree; see RAW-LOGS.md for their stable references.\n'
    '# Verify the archived copies: git fetch origin <commit>; git show <commit>:<path> | sha256sum\n'
    + '\n'.join(manifest) + '\n')
def summary(p, t):
    lines = t.splitlines(); out = [f'lines: {len(lines)}']
    if 'strace' in p:
        out.append('first line: ' + (lines[0] if lines else ''))
        net = [l for l in lines if re.search(r'\b(connect|sendto|sendmsg)\(', l)]
        inet = [l for l in net if re.search(r'AF_INET6?\b', l)]
        out.append(f'connect/sendto/sendmsg lines: {len(net)}; of them to AF_INET/AF_INET6: {len(inet)}')
        calls = {}
        for l in lines:
            m = re.match(r'^\d+\s+([a-z_0-9]+)\(', l)
            if m: calls[m.group(1)] = calls.get(m.group(1), 0) + 1
        out.append('syscall lines by name: ' + (', '.join(f'{k} {v}' for k, v in sorted(calls.items())) or 'none'))
        out.append('other lines (signals, exits): ' + str(len(lines) - sum(calls.values())))
    elif p.endswith('module-download.log'):
        out.append('first lines:'); out += ['  ' + l for l in lines[:3]]
        out.append(f'"# get" requests: {sum(1 for l in lines if l.startswith("# get"))}')
    else:
        keep = re.compile(r'HEAD is now at|^# (tests|suites|pass|fail|cancelled|skipped|todo) |build [12]: [0-9a-f]{64}|matches the pin|go\.zip: OK|go version go|build-bd: |^not ok ')
        out.append('key lines (timestamps and ANSI codes removed):')
        for l in lines:
            c = re.sub(r'^﻿?\d{4}-\d\d-\d\dT[\d:.]+Z ', '', l); c = re.sub(r'\x1b\[[0-9;]*m', '', c)
            if keep.search(c): out.append('  ' + c[:200])
    return '\n'.join(out) + '\n'
md = [f'# Raw logs moved out of the tree', '',
      f'These {len(moved)} logs (each over {LIMIT // 1000} KB, {sum(m[1] for m in moved) / 1e6:.1f} MB in all) were committed as evidence and are kept, byte for byte, at commit `{REF}`. '
      'The tree keeps a summary next to where each one was (`<name>.summary.txt`) and [MANIFEST.sha256](MANIFEST.sha256) lists the SHA-256 of every evidence file at that commit.', '',
      'Fetch and verify one: `git fetch origin ' + REF + ' && git show ' + REF + ':<path> | sha256sum`.', '',
      '| File | Bytes | SHA-256 | Archived copy |', '|---|---|---|---|']
for p, size, h, t in moved:
    rel = p[len(E)+1:]
    open(f'{R}/{p}.summary.txt', 'w').write(f'# Summary of {rel}\n# The full log ({size} bytes, SHA-256 {h}) is archived at commit {REF}:\n# https://github.com/{REPO}/blob/{REF}/{p}\n' + summary(p, t))
    os.remove(f'{R}/{p}')
    md.append(f'| `{rel}` | {size} | `{h}` | [{REF[:7]}](https://github.com/{REPO}/blob/{REF}/{p}) |')
open(f'{R}/{E}/RAW-LOGS.md', 'w').write('\n'.join(md) + '\n')
print(len(manifest), 'files in manifest;', len(moved), 'moved;', sum(m[1] for m in moved), 'bytes')
