#!/bin/sh
set -eu

ARTIFACT_DIR="/Users/me/wip-rnx/role-gatekeeper/artifacts/block-005/20260618T093012Z"
SWIFT_ROOT="/Users/me/wip-rnx/nx-/swift-source-vx-632"
BUILD_SUBDIR="rnx-vx-swift632-selfhost-install1"

export SWIFT_BUILD_ROOT="$SWIFT_ROOT/build"
export CMAKE_Swift_COMPILER="$SWIFT_ROOT/install/$BUILD_SUBDIR/usr/bin/swiftc"
export LIT_OPTS="-j 32"

exec /usr/local/bin/python3 /Users/me/wip-rnx/role-gatekeeper/tools/cpu_watchdog_runner.py \
  --raw-log "$ARTIFACT_DIR/validation.raw.log" \
  --kill-log "$ARTIFACT_DIR/watchdog.kill.log" \
  --cpu-budget-seconds 900 \
  --poll-seconds 5 \
  --status-seconds 60 \
  -- \
  "$SWIFT_ROOT/workspace/swift/utils/build-script" \
  -T \
  -j 32 \
  --lit-jobs 32 \
  --build-subdir "$BUILD_SUBDIR" \
  --release \
  --no-swift-stdlib-assertions \
  --build-swift-static-sdk-overlay \
  --build-swift-static-stdlib \
  --skip-build \
  --skip-test-lldb \
  --skip-test-llbuild \
  --skip-test-xctest \
  --skip-test-foundation \
  --skip-test-libdispatch \
  --skip-test-swiftpm \
  --skip-test-swift-driver \
  --skip-test-swiftdocc \
  --skip-test-swiftformat \
  --skip-test-sourcekit-lsp \
  --lit-args=-sv
