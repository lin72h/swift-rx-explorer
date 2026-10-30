#!/bin/zsh
# id-011 follow-up: macOS results for the op-236 tests that did not build.
# Same method as probes/op-236/build_run.zsh (system libdispatch, 5 runs,
# timeout 120, own work dir, stdin /dev/null) with two labelled deviations:
#  - private-headers/inc: an overlay that adds only Apple libdispatch-1542.100.32
#    private headers the public SDK lacks, plus glue in inc/dispatch/private.h;
#  - ported-tests/: a copy of tests/ whose dispatch_test.h has the one-line
#    sysctlbyname prototype fix (ported-tests.diff), for every test here.
# dispatch_vm is built but not run: it allocates up to hw.memsize in 20 MB
# chunks until the host reports memory pressure twice (mm4 is shared).
set -u
F=/Volumes/MM4-1T/Local/swift-rx/swift-sdk-op-233/results-id-011-followup
INC=$F/private-headers/inc
P=$F/ported-tests
R=$F/c-tests
B=$R/bin; L=$R/logs; W=$R/work; mkdir -p $B $L $W
CFLAGS=(-fblocks -Wall -Wno-deprecated-declarations -g -I $INC -I $P)
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time' }
# ONLY="transform ..." builds and runs just those tests (for corrected reruns)
want() { [[ -z ${ONLY:-} || " $ONLY " == *" $1 "* ]] }

for s in bsdtests dispatch_test; do
  clang $CFLAGS -c $P/$s.c -o $B/$s.o >$L/_$s.o.build.log 2>&1; echo $? >$L/_$s.o.build.rc
done
HARN=($B/bsdtests.o $B/dispatch_test.o -lm)

build() { # name, then compiler + args; records the exact command line
  local n=$1; shift
  print -r -- "$@" >$L/$n.build.cmd
  "$@" >$L/$n.build.log 2>&1; echo $? >$L/$n.build.rc
}
run() { # name
  local n=$1
  [[ $(cat $L/$n.build.rc) == 0 ]] || return
  mkdir -p $W/$n
  for i in 1 2 3 4 5; do
    local t0=$(now)
    (cd $W/$n && timeout 120 $B/$n >$L/$n.run$i.out 2>$L/$n.run$i.err </dev/null)
    local rc=$?
    local t1=$(now)
    echo "rc=$rc elapsed_s=$(( t1 - t0 ))" >$L/$n.run$i.status
  done
}

for n in apply concur deadname overcommit priority readsync sync_on_main transform vm; do
  want $n || continue
  f=$P/dispatch_$n.c
  fw=()
  # CoreFoundation also when CF is only reached through another framework's
  # header (dispatch_transform calls CFData* via <Security/Security.h>)
  grep -q -E 'CoreFoundation/CoreFoundation.h|\bCF[A-Z][A-Za-z]*\(' $f && fw+=(-framework CoreFoundation)
  grep -q 'Security/Security.h' $f && fw+=(-framework Security)
  build dispatch_$n clang $CFLAGS $f $HARN $fw -o $B/dispatch_$n
done
want priority2 && build dispatch_priority2 clang $CFLAGS -DUSE_SET_TARGET_QUEUE=1 $P/dispatch_priority.c $HARN -o $B/dispatch_priority2

for n in apply concur deadname overcommit priority priority2 readsync sync_on_main transform; do
  want $n || continue
  run dispatch_$n
done
echo finished
