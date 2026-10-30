#!/bin/zsh
# op-236 supplementary row: dispatch_io_net.c hits its "#error not implemented"
# branch only because the op-233 method has no config.h. Upstream CMake defines
# HAVE_POSIX_SPAWNP via check_function_exists (true on macOS); pass that one
# define, no source change, and run 5x like build_run.zsh.
set -u
IN=/Volumes/MM4-1T/Local/swift-rx/swift-sdk-op-233
R=$IN/results-full
T=$IN/results/src/swift-corelibs-libdispatch-swift-6.4.0-RELEASE/tests
B=$R/bin; L=$R/logs-supplement; W=$R/work; mkdir -p $L
n=dispatch_io_net+HAVE_POSIX_SPAWNP
cmd=(clang -fblocks -Wall -Wno-deprecated-declarations -g -I $T -DHAVE_POSIX_SPAWNP=1 $T/dispatch_io_net.c $B/bsdtests.o $B/dispatch_test.o -lm -o $B/$n)
print -r -- $cmd >$L/$n.build.cmd
$cmd >$L/$n.build.log 2>&1; echo $? >$L/$n.build.rc
[[ $(cat $L/$n.build.rc) == 0 ]] || exit 0
mkdir -p $W/$n
for i in 1 2 3 4 5; do
  t0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  (cd $W/$n && timeout 120 $B/$n >$L/$n.run$i.out 2>$L/$n.run$i.err </dev/null)
  rc=$?
  t1=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  echo "rc=$rc elapsed_s=$(( t1 - t0 ))" >$L/$n.run$i.status
done
