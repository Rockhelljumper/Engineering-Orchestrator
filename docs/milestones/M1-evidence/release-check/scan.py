# Scan every blob added anywhere in the PR's history (origin/main..HEAD) for secrets and personal data.
import subprocess, re, sys, collections
R=sys.argv[1]; rng=sys.argv[2]
objs=subprocess.run(['git','-C',R,'rev-list','--objects',rng],capture_output=True,text=True).stdout.split('\n')
blobs={}
for l in objs:
    p=l.split(' ',1)
    if len(p)==2: blobs.setdefault(p[0],set()).add(p[1])
P={
 'private key block': r'-----BEGIN [A-Z ]*PRIVATE KEY-----',
 'github token': r'\b(gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})',
 'aws key id': r'\b(AKIA|ASIA)[0-9A-Z]{16}\b',
 'anthropic/openai key': r'\bsk-(ant-)?[A-Za-z0-9_-]{20,}',
 'slack token': r'\bxox[abposr]-[A-Za-z0-9-]{10,}',
 'google api key': r'\bAIza[0-9A-Za-z_-]{35}\b',
 'jwt': r'\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}',
 'bearer/authorization header': r'(?i)(authorization:\s*(bearer|basic|token)\s+[A-Za-z0-9._~+/=-]{8,})',
 'url with credentials': r'[a-z]+://[^/\s:@]+:[^/\s@]+@',
 'signed url (sig=)': r'[?&](sig|X-Amz-Signature|token)=[A-Za-z0-9%/+=_-]{10,}',
 'password/secret assignment': r'(?i)\b(password|passwd|secret|api[_-]?key|access[_-]?token)\b\s*[:=]\s*["\']?[A-Za-z0-9/+_=-]{8,}',
 'email': r'\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b',
 'ipv4': r'\b(?:\d{1,3}\.){3}\d{1,3}\b',
 'home/user path': r'(/home/[a-z][a-z0-9_-]*|/Users/[A-Za-z][^/\s]*|C:\\\\Users\\\\[^\\\\\s]+)',
 'root/claude paths': r'(/root/|/tmp/claude-0/|/home/claude/)',
 'runner temp path': r'D:\\a\\_temp',
 'hex 40+ (possible key)': r'\b[0-9a-f]{64}\b',
}
counts=collections.defaultdict(collections.Counter); samples=collections.defaultdict(set)
for b,paths in blobs.items():
    data=subprocess.run(['git','-C',R,'cat-file','-p',b],capture_output=True).stdout
    try: t=data.decode('utf-8','replace')
    except Exception: continue
    for name,rx in P.items():
        for m in re.finditer(rx,t):
            v=m.group(0)
            for p in paths: counts[name][p]+=1
            if len(samples[name])<12: samples[name].add(v[:90])
for name in P:
    tot=sum(counts[name].values())
    print(f"== {name}: {tot} matches in {len(counts[name])} file paths")
    for v in sorted(samples[name]): print("   sample:", v)
    for p,c in counts[name].most_common(6): print(f"   {c:6d}  {p}")
