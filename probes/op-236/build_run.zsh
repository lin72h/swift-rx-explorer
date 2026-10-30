#!/bin/zsh
# op-236: build every file in upstream libdispatch 6.4.0 tests/ against
# macOS's system libdispatch (op-233 method) and run each test 5x under
# timeout 120. Thin orchestration only: raw build logs, stdout/stderr and
# exit status per run are written unchanged; summarize_op236.exs parses them.
set -u
IN=/Volumes/MM4-1T/Local/swift-rx/swift-sdk-op-233
R=$IN/results-full
T=$IN/results/src/swift-corelibs-libdispatch-swift-6.4.0-RELEASE/tests
B=$R/bin; L=$R/logs; W=$R/work; mkdir -p $B $L $W
CFLAGS=(-fblocks -Wall -Wno-deprecated-declarations -g -I $T)
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time' }

# harness objects shared by every test (C, so dispatch_plusplus links them too)
for s in bsdtests dispatch_test; do
  clang $CFLAGS -c $T/$s.c -o $B/$s.o >$L/_$s.o.build.log 2>&1; echo $? >$L/_$s.o.build.rc
done

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

HARN=($B/bsdtests.o $B/dispatch_test.o -lm)
for f in $T/*.c $T/*.cpp; do
  n=${${f:t}:r}
  case $n in
    bsdtests|dispatch_test|func|generic_win_port)  # no main(): compile-only check
      build $n clang $CFLAGS -c $f -o $B/$n.o; continue ;;
    bsdtestharness|bsdtestsummarize)               # tools, not tests: build only
      build $n clang $CFLAGS $f $HARN -o $B/$n; continue ;;
  esac
  fw=()
  grep -q 'CoreFoundation/CoreFoundation.h' $f && fw+=(-framework CoreFoundation)
  grep -q 'Security/Security.h' $f && fw+=(-framework Security)
  case $n in
    dispatch_plusplus) build $n clang++ -fblocks -Wall -Wno-deprecated-declarations -g -I $T $f $HARN -o $B/$n ;;
    dispatch_c99)      build $n clang -std=c99 $CFLAGS $f $HARN $fw -o $B/$n ;;
    *)                 build $n clang $CFLAGS $f $HARN $fw -o $B/$n ;;
  esac
  run $n
done
# CMake's extended-suite oddball: dispatch_priority.c with -DUSE_SET_TARGET_QUEUE=1
build dispatch_priority2 clang $CFLAGS -DUSE_SET_TARGET_QUEUE=1 $T/dispatch_priority.c $HARN -o $B/dispatch_priority2
run dispatch_priority2
echo finished
