#!/bin/bash
# M1-9: two independent builds of bd with the final build script, fresh GOCACHE each, stdout and stderr captured.
S=/tmp/claude-0/-home-claude-Engineering-Orchestrator/1994d459-4dcf-5bd8-a13c-602ea0e44623/scratchpad
O=$S/m19-out; mkdir -p $O
cd $S/m1-dev2
for n in 1 2; do
  src=$S/beads-src; [ $n = 2 ] && src=$S/beads-src-2
  rm -rf $S/gocache-m19-$n; mkdir -p $S/gocache-m19-$n
  {
    echo "# M1-9 build $n: scripts/build-bd.sh at $(git rev-parse HEAD), checkout $src, fresh GOCACHE, started $(date -u +%FT%TZ)"
    GO=/opt/go1.26.7/bin/go GOCACHE=$S/gocache-m19-$n GOMODCACHE=$S/gopath/pkg/mod nice -n 10 scripts/build-bd.sh $src $S/m19-out/bd-$n 2>&1
    echo "# exit $? finished $(date -u +%FT%TZ)"
    sha256sum < $S/m19-out/bd-$n
  } > $O/build$n.log
done
echo done > $O/ALLDONE
