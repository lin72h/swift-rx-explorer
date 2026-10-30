#!/bin/zsh
# id-011 follow-up: SwiftPM 6.4.0's own localFileSystemReadFileContentsAcceptsNonRegularFile
# on macOS, 5x with the default cooperative pool and 5x with
# LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 (cooperative pool width 1), timeout 120 each.
# Thin orchestration: raw output and exit status per run. A run still alive at
# 20 s gets one stack sample of its test helper; timeout kills only swift-test,
# so orphaned helpers are listed in the status line and killed after each run.
set -u
R=/Volumes/MM4-1T/Local/swift-rx/swift-sdk-op-233/results-id-011-followup/swiftpm
S=$R/src/swift-package-manager
L=$R/logs; mkdir -p $L
TEST=localFileSystemReadFileContentsAcceptsNonRegularFile
HELPER="test-bundle-path $S/.build/out/Products/Debug/BasicsTests"
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time' }
pause() { perl -e "select(undef,undef,undef,$1)" }
run() { # label, then env assignments
  local lab=$1; shift
  for i in 1 2 3 4 5; do
    local t0=$(now)
    (cd $S && env "$@" timeout 120 swift test --skip-build --filter $TEST >$L/$lab.run$i.out 2>$L/$lab.run$i.err </dev/null; echo $? >$L/$lab.run$i.rc) &
    local bg=$!
    local waited=0
    while kill -0 $bg 2>/dev/null && (( waited < 80 )); do pause 0.25; (( waited++ )); done
    if kill -0 $bg 2>/dev/null; then
      local hp=$(pgrep -f "$HELPER" | head -1)
      [[ -n $hp ]] && sample $hp 1 -file $L/$lab.run$i.helper.sample.txt >/dev/null 2>&1
    fi
    wait $bg
    local t1=$(now)
    local left=$(pgrep -f "$HELPER" | tr '\n' ' ')
    [[ -n $left ]] && kill -KILL ${=left} 2>/dev/null
    echo "rc=$(cat $L/$lab.run$i.rc) elapsed_s=$(( t1 - t0 )) leftover_helpers=${left:-none}" >$L/$lab.run$i.status
  done
}
run default
run strict LIBDISPATCH_COOPERATIVE_POOL_STRICT=1
echo finished
