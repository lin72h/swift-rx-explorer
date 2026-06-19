# Corelibs Dimension Design

Status: design-only. Do not treat this as an accepted gate dimension until the
Arranger/Coordinator explicitly add it to scope.

## Purpose

The current two-tier Swift regression gate covers the Swift compiler lit graph:

- Tier 1: `check-swift-freebsd-x86_64`
- Tier 2: `check-swift-all-freebsd-x86_64`

Foundation, Dispatch, XCTest, and swift-testing are not named by those two
targets as a separate matrix dimension. A later corelibs dimension should be
tracked separately so compiler regressions and corelibs regressions do not blur
into one accounting record.

## Observed 6.3.2 Build Surfaces

This was inspected only; no corelibs tests were run.

Build directories present under the 6.3.2 build root:

- `foundation-freebsd-x86_64`
- `foundation_static-freebsd-x86_64`
- `libdispatch-freebsd-x86_64`
- `libdispatch_static-freebsd-x86_64`
- `xctest-freebsd-x86_64`
- `swifttesting-freebsd-x86_64`
- `swiftpm-freebsd-x86_64`

Source directories present:

- `workspace/swift-corelibs-foundation`
- `workspace/swift-corelibs-libdispatch`
- `workspace/swift-corelibs-xctest`
- `workspace/swift-testing`

## Candidate Invocation Surfaces

### Foundation

Observed source has `Package.swift` and `Tests/Foundation/...`.

Observed CMake build directories did not expose an obvious `check-foundation`
target in the abandoned 6.3.2 no-test tree. Candidate later surfaces:

- SwiftPM: run package tests from `workspace/swift-corelibs-foundation`
  using the staged 6.4 toolchain.
- CMake/CTest: only if the 6.4 test-enabled build exposes Foundation test
  targets or CTest entries.

Open requirement: discover the concrete 6.4 test-enabled Foundation target
before adding this dimension.

### Dispatch

Observed CMake target surface:

- `ninja -C <libdispatch-build-dir> test`
- CTest entries in `libdispatch-freebsd-x86_64/tests/CTestTestfile.cmake`
- Individual CTest tests invoke `bsdtestharness` with built dispatch test
  binaries.

Candidate later surface:

- `ctest --test-dir <libdispatch-build-dir> --output-on-failure`
- or `ninja -C <libdispatch-build-dir> test`

Gate note: because Dispatch tests already have CTest `TIMEOUT` properties, the
external CPU watchdog should still wrap the whole invocation and record any
process CPU-budget kill as a hard failure.

### XCTest

Observed CMake target surface:

- `ninja -C <xctest-build-dir> check-xctest`

The generated `check-xctest` command runs `llvm-lit -sv` against
`workspace/swift-corelibs-xctest/Tests/Functional` with environment including
`BUILT_PRODUCTS_DIR`, `FOUNDATION_BUILT_PRODUCTS_DIR`, `LIBDISPATCH_*`, and
`SWIFT_EXEC`.

Candidate later surface:

- Wrap `ninja -C <xctest-build-dir> check-xctest`.
- Reuse the lit parser if the output is standard lit accounting.

### swift-testing

Observed source has `Package.swift` and `Tests/TestingTests`,
`Tests/TestingMacrosTests`, and related test directories.

Observed CMake build directory exposes libraries/modules, but no obvious
`check-swift-testing` target in the abandoned 6.3.2 no-test tree.

Candidate later surfaces:

- SwiftPM: run package tests from `workspace/swift-testing` using the staged
  6.4 toolchain.
- CMake/CTest: only if the 6.4 test-enabled build exposes test targets.

Open requirement: discover the concrete 6.4 test-enabled swift-testing target
before adding this dimension.

## Evidence Requirements

Each corelibs dimension should produce its own JSON artifact and baseline. Do
not mix corelibs results into the Swift compiler Tier 1/Tier 2 baseline.

Minimum requirements:

- raw log is immutable primary evidence;
- wrapper is orchestration only;
- parser/validator is Elixir unless the output is already handled by an
  accepted parser;
- external CPU watchdog wraps runtime execution;
- provenance records toolchain, source pin, target/build dir, invocation, job
  count, watchdog budget, and tool versions;
- negative controls are required before a new parser/validator can support
  acceptance.

## Deferred Decisions

- Whether corelibs is one combined dimension or four separate dimensions.
- Whether Dispatch CTest output needs a separate Elixir parser.
- Whether Foundation and swift-testing use SwiftPM or CMake targets in the 6.4
  test-enabled build.
- Baseline timing relative to the first coherent 6.4 snapshot and the 6.4
  release tag.
