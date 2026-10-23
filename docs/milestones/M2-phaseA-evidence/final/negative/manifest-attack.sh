#!/bin/bash
# Durable runner: drop a failed scenario from manifest.json, then resume.
#   manifest-attack.sh <checkout> <work dir>
# VULNERABLE if the run ends PASSED; DEFENDED if the resume is refused and status stays not passing.
R=$1; W=$2; rm -rf "$W"; mkdir -p "$W"
cd "$R" || exit 2
node tests/support/durable/cli.ts start "$W/run" --suite selftest --param count=5 --param sleepMs=10 --param failAt=s4 > "$W/start.json" 2>"$W/start.err"; echo "start exit $?"
python3 -I -c "import json,sys; f=sys.argv[1]+'/run/manifest.json'; m=json.load(open(f)); m['scenarios']=[s for s in m['scenarios'] if s['id']!='s4']; json.dump(m,open(f,'w'),indent=2)" "$W"
node tests/support/durable/cli.ts resume "$W/run" > "$W/resume.json" 2>"$W/resume.err"; echo "resume exit $?"; tail -1 "$W/resume.err"
node tests/support/durable/cli.ts status "$W/run" > "$W/status.json" 2>&1; rc=$?; echo "status exit $rc"
st=$(python3 -I -c "import json,sys; print(json.load(open(sys.argv[1]))['status'])" "$W/status.json")
echo "final status $st"
if [ "$st" = PASSED ]; then echo "verdict VULNERABLE"; else echo "verdict DEFENDED"; fi
