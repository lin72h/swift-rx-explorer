#!/bin/zsh
# id-011 follow-up: run the Swift Testing pool probe (pool-probe/) on macOS,
# each test on its own, 5x with the default cooperative pool and 5x with
# LIBDISPATCH_COOPERATIVE_POOL_STRICT=1, timeout 120. The tests bound their own
# blocking, so a starved writer shows up as a recorded issue, not a hang.
# Thin orchestration: raw output and exit status per run; leftover helpers killed.
set -u
HERE=${0:A:h}
R=/Volumes/MM4-1T/Local/swift-rx/swift-sdk-op-233/results-id-011-followup/pool-probe
L=$R/logs; mkdir -p $L
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time' }
for t in cooperativePoolWidthForBlockedTasks fifoReaderBlocksTaskWriterDetached; do
  for mode in default strict; do
    envs=(); [[ $mode == strict ]] && envs=(LIBDISPATCH_COOPERATIVE_POOL_STRICT=1)
    for i in 1 2 3 4 5; do
      t0=$(now)
      env $envs timeout 120 swift test --skip-build --package-path $HERE/pool-probe --scratch-path $R/.build \
        --filter "PoolProbeTests.$t" >$L/$t.$mode.run$i.out 2>$L/$t.$mode.run$i.err </dev/null
      rc=$?
      t1=$(now)
      left=$(pgrep -f 'test-bundle-path .*PoolProbeTests' | tr '\n' ' ')
      [[ -n $left ]] && kill -KILL ${=left} 2>/dev/null
      echo "rc=$rc elapsed_s=$(( t1 - t0 )) leftover_helpers=${left:-none}" >$L/$t.$mode.run$i.status
    done
  done
done
echo finished
