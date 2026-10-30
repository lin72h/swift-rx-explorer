#!/bin/zsh
# op-233: build the supplied libdispatch tests/probes against macOS's system
# libdispatch and run each case 5x under timeout 120. Thin orchestration only:
# raw stdout/stderr and exit status per run are written unchanged.
set -u
IN=/Volumes/MM4-1T/Local/swift-rx/swift-sdk-op-233
R=$IN/results
T=$(echo $R/src/swift-corelibs-libdispatch-swift-6.4.0-RELEASE/tests)
B=$R/bin; L=$R/${LOGDIR:-logs}; mkdir -p $B $L
CFLAGS=(-fblocks -O0 -g)

build() { # name, then clang args
  local n=$1; shift
  clang $CFLAGS "$@" -o $B/$n >$L/$n.build.log 2>&1
  echo $? > $L/$n.build.rc
}
run() { # label, then argv
  local lab=$1; shift
  for i in 1 2 3 4 5; do
    local t0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
    timeout 120 "$@" >$L/$lab.run$i.out 2>$L/$lab.run$i.err </dev/null
    local rc=$?
    local t1=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
    echo "rc=$rc elapsed_s=$(( t1 - t0 ))" > $L/$lab.run$i.status
  done
}

for t in dispatch_io_pipe_close dispatch_readsync dispatch_concur dispatch_thread_name; do
  build $t -I $T $T/$t.c $T/bsdtests.c $T/dispatch_test.c
  [[ $(cat $L/$t.build.rc) == 0 ]] && run $t $B/$t
done
build bsdtestharness -I $T $T/bsdtestharness.c $T/bsdtests.c $T/dispatch_test.c

for p in block_wait variants double_init blocked_worker fifo_global_queue; do
  build $p $IN/probes/$p.c
done
run block_wait $B/block_wait
for c in plain-call plain-perform plain-cancel plain-notify-async plain-wait plain-async-wait qos-call qos-wait qos-async-wait; do
  run variants.$c $B/variants $c
done
run double_init.noarg $B/double_init
run double_init.init $B/double_init init
nm -m $B/double_init | grep libdispatch_init > $L/double_init.symbol.txt
otool -L $B/double_init >> $L/double_init.symbol.txt
run blocked_worker.0 $B/blocked_worker 0
run blocked_worker.0x15 $B/blocked_worker 0x15
run fifo_global_queue.0 $B/fifo_global_queue 0
run fifo_global_queue.16 $B/fifo_global_queue 16

# swift-fifo: build a copy so the hashed input tree stays untouched
rm -rf $R/swift-fifo-build && cp -R $IN/swift-fifo $R/swift-fifo-build
(cd $R/swift-fifo-build && swift build -c release) >$L/swift-fifo.build.log 2>&1
echo $? > $L/swift-fifo.build.rc
run fifo.posix $R/swift-fifo-build/.build/release/fifo posix
run fifo.foundation $R/swift-fifo-build/.build/release/fifo foundation
