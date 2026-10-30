# id-011 follow-up: macOS answers to the open items from op-233 and op-236 (mm4)

This was a user-authorised follow-up on 2026-10-30. It has no op number and was not briefed by
the Arranger.

**Host.** mm4, macOS 27.2 (26B123), Apple Swift 6.4, Apple clang 21.0.0, Xcode 27.1.
- CPUs: 10 (`hw.activecpu=10`: 4 performance, 6 efficiency); 16 GiB RAM.
- System libdispatch: 1605.40.4.
- The host is shared; the load average was 7.6 when the work started.
- Full versions are in `host.txt`.

**Raw evidence.** `/Volumes/MM4-1T/Local/swift-rx/swift-sdk-op-233/results-id-011-followup/`,
hashed in `RESULTS.SHA256SUMS` (319 files, sha256 `3ea36649…ff98e2a8`). Every case ran 5 times
under `timeout 120`, outside Claude Code's tool sandbox.

## 1. SwiftPM 6.4.0's FIFO test on macOS

**Source.** `swift-package-manager` at `swift-6.4.0-RELEASE` (`18da3eb`). Its related
dependencies follow `release/6.4.x`; the revisions resolved on 2026-10-30 are in
`swiftpm-6.4.0.Package.resolved` (TSC `75a4f85`).

**Method.** `swift build --build-tests`, then `swift test --skip-build --filter
localFileSystemReadFileContentsAcceptsNonRegularFile` (script: `probes/id-011-followup/swiftpm_fifo.zsh`).

| Cooperative pool | macOS result (5 runs) | Where it waits |
|---|---|---|
| default | **pass** 5/5, in 0.001–0.002 s | nowhere |
| `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` (width 1) | **hang** 5/5, killed at 120 s (rc 124) | see below |

Under the strict pool, the only cooperative thread (`com.apple.root.default-qos.cooperative`) is
blocked in `__open`. The call chain is `+[NSFileHandle fileHandleForReadingAtPath:]` ←
`LocalFileSystem.readFileContents` (TSC `FileSystem.swift:663`) ← the test. The `Task.detached`
writer never runs. Each run has a stack sample; `swiftpm-strict-helper.sample.txt` is one of
them.

How the test works (`Tests/BasicsTests/FileSystem/FileSystemTests.swift:21-47`):
- It is a Swift Testing `async` test, so its body runs on the cooperative pool.
- `readFileContents` stats the path. Because a FIFO is not a regular file, TSC opens it with
  `FileHandle(forReadingAtPath:)`, a blocking `open(O_RDONLY)` on that cooperative thread.
- The writer is a `Task.detached`, so it needs a second cooperative thread. The test therefore
  needs at least 2 threads; blocking one of them is a forward-progress violation.
- The test's comment (SwiftPM issue 9915) explains the background: TSC switched to
  `Data(contentsOf:)`, which "rejects non-regular files on Linux … and some macOS/Foundation
  versions", so non-regular files now go through `FileHandle`.

**Verdict.** On macOS the test passes with its default 10-wide pool. With a 1-wide pool it hangs
exactly as rmxOS does ("hang in `fifo_open`"). Whether rmxOS differs from macOS depends on the
width of rmxOS's pool, which is what section 2 measures.

**The op-233 `fifo foundation` result is the same on macOS.** `String(contentsOfFile:)` gives
NSCocoaErrorDomain 257 / POSIX 13 on macOS too. That is Foundation refusing a non-regular file,
the same behaviour the test comment describes, not a sandbox artefact.

`timeout` kills only `swift-test`. The orphaned `swiftpm-testing-helper` stays blocked in
`open`, so the script kills it after each run; the pids are in the status lines.

## 2. Cooperative-pool probe (Swift Testing), runnable on rmxOS

The probe is `probes/id-011-followup/pool-probe` (`import Testing` only, no dependencies, with
the scratch path outside the repo). Each test ran on its own (`pool_probe.zsh`). Both tests
bound their own blocking, so they cannot hang a runner.

| Test | Default pool (5 runs) | Strict pool, width 1 (5 runs) |
|---|---|---|
| `cooperativePoolWidthForBlockedTasks` | **pass**: width 10 = `hw.activecpu`. 9 tasks had started at 0.5, 1, 2 and 4 s, so the pool does not grow while its threads are blocked | **fail**, as expected: width 1 (0 tasks started within 4 s); `Expectation failed: width >= 2` |
| `fifoReaderBlocksTaskWriterDetached` | **pass**: reads `test-secret-token` | **fail**, as expected: the watchdog fired at 10.01 s and the writer never opened; `Expectation failed: !fired`; the run ends at about 10.6 s with no leftover processes |

What each test does:
- **`cooperativePoolWidthForBlockedTasks`:** 64 detached tasks each block their thread, and the
  test task blocks its own while it counts how many have started. Width = tasks started + 1 (the
  test task).
- **`fifoReaderBlocksTaskWriterDetached`:** SwiftPM's pattern written with POSIX I/O. A watchdog
  on a plain `Thread` (outside the executor) unblocks the reader after 10 s.

**Inference (unverified).** rmxOS's `dispatch_concur.c:110` failure expects 4. In the source,
that value is `MIN(n × workers, width)` with `workers = 4` and `n = activecpu/2`, clamped to at
least 1. Expecting 4 therefore means `n = 1`, so adx01 reports `hw.activecpu ≤ 3`.
- **1 active CPU:** if rmxOS sizes its pool by active CPUs as macOS does, the SwiftPM hang is the
  test's 2-thread assumption, the same as on macOS.
- **2–3 active CPUs:** the test should pass, and a hang would mean rmxOS's executor gives blocked
  tasks fewer threads than macOS would.

To settle it, run on adx01:
- `sysctl hw.activecpu`;
- `swift test --filter PoolProbeTests.cooperativePoolWidthForBlockedTasks`;
- `swift test --filter PoolProbeTests.fifoReaderBlocksTaskWriterDetached`.

## 3. The op-236 tests that did not build

The method is op-236's: system libdispatch 1605.40.4, `private_and_ported.zsh`. It has two
labelled deviations.

**Private headers.** An overlay, `private-headers/inc`, adds only the Apple
`libdispatch-1542.100.32` private headers that the public SDK lacks. 1542.100.32 is the newest
version Apple has published; 1605.40.4 is not published. The glue header
`private-overlay-glue.h` does two things:
- neutralises `DISPATCH_ENUM_SPI_AVAILABLE`, which the SDK defines as `API_UNAVAILABLE`;
- adds the internal bridgeOS availability helpers.

Corelibs' own private headers cannot be used: corelibs' `private.h` requires
`DISPATCH_API_VERSION 20180109`, and the SDK has `20181008`.

**Harness.** The tests are built from a copy of `tests/` with one line fixed in `dispatch_test.h`
(`ported-tests.diff`). The stale `sysctlbyname` prototype breaks not only `apply` but also
`concur`, `priority`, `priority2`, `readsync` and `vm`. The prototype is still wrong on `main`;
an upstream report is drafted in `upstream-issue-draft-dispatch_test-sysctlbyname.md` (not
filed).

| File | macOS result (5 runs) | rmxOS (op-224 run 5) | Verdict |
|---|---|---|---|
| `dispatch_apply` | pass: 6 PASS, 0 FAIL, 0.13–0.36 s | pass | same |
| `dispatch_concur` | SIGTRAP 5/5 after 12 PASS, 0 FAIL: "BUG IN CLIENT OF LIBDISPATCH: Cannot set width of a serial queue" (`dispatch_queue_set_width` ← `create_queue`, `dispatch_concur.c:221`) | fail at `:110` "concurrently completed workers" 0, expected 4 | both fail, differently (see notes) |
| `dispatch_deadname` | hang 5/5 (rc 124 at 120 s) after 2 PASS, 0 FAIL | not registered | unsupported on both |
| `dispatch_overcommit` | pass: 33 PASS, 0 FAIL | pass | same |
| `dispatch_priority` | pass: 3 PASS, 0 FAIL, 7.1–7.5 s | pass | same |
| `dispatch_priority2` | pass: 7 PASS, 0 FAIL, 6.9–7.4 s | pass | same |
| `dispatch_readsync` | **pass**: 6 PASS, 0 FAIL, 11.9–14.2 s | hang, killed at 120 s | **rmxOS differs** |
| `dispatch_sync_on_main` | pass: 10 PASS, 0 FAIL | not registered | rmxOS differs (macOS passes; not registered on rmxOS) |
| `dispatch_transform` | pass: 58 PASS, 0 FAIL (rerun, see notes) | not registered | rmxOS differs (macOS passes; not registered on rmxOS) |
| `dispatch_vm` | builds; **not run** | not registered | no macOS result |

Notes:
- **`dispatch_concur`.**
  - On macOS every global and concurrent queue hierarchy passes, including `:110`
    "concurrently completed workers" (20 ≤ 20).
  - The test traps at its first "wide" hierarchy. There it creates a serial queue and calls
    `dispatch_queue_set_width` on it, which modern libdispatch refuses. rmxOS's base,
    libdispatch 442.1.4, predates that restriction.
  - So macOS gives no reference for the wide and serial hierarchies. If the
    "Testing … queue hierarchy" line before rmxOS's `:110` failure names a global or concurrent
    hierarchy, rmxOS differs from macOS.
- **`dispatch_readsync`:** passes on macOS but hangs on rmxOS, so this is an rmxOS difference to
  investigate.
- **`dispatch_deadname`:** its first case, `test_dead_name`, waits for `DISPATCH_MACH_SEND_DEAD`
  on a worker thread's own thread port. It assumes the worker thread exits once its block
  returns, and the notification does not arrive within 120 s on macOS 27.2.
- **`dispatch_transform`:** the first build failed to link because my script did not link
  CoreFoundation (the test reaches CF only through `Security.h`). That attempt is kept in
  `c-tests/logs-superseded/`. The rerun used `-framework CoreFoundation -framework Security`, and
  the corrected rule changes no other test's link command.
- **`dispatch_vm`:** not run on mm4. It allocates in 20 MB chunks up to `hw.memsize` (16 GiB)
  until the host reports memory pressure twice, which would disrupt other agents on this shared
  host.

**Updated coverage target ("what macOS passes").** op-236 gave 33 tests plus `dispatch_io_net`.
This adds `apply`, `overcommit`, `priority`, `priority2`, `readsync`, `sync_on_main` and
`transform`, for **41** in total. The new seven need the labelled header deviations above.

## 4. Tooling change

`tools/summarize_op236.exs` has a new verdict for tests that were built but not run: "no macOS
result (built, not run)". Its self-test now has 14 negative controls and all pass
(`summarize-op236.negative-controls.v1.json`). Re-summarising op-236's raw logs gives unchanged
verdicts.

## Not done

- adx01 runs: `sysctl hw.activecpu` and the pool probe. These need a guest run authorised by a
  brief.
- `dispatch_vm` on macOS; it needs a dedicated, unshared host.
- `OPS.md` for this repo is the Arranger's to render; it is still absent.
