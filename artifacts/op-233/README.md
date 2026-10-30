# op-233: macOS reference run of the libdispatch tests and probes that fail on rmxOS

Host: mm4, macOS 27.2 (26B123), Apple Swift 6.4 (swiftlang-6.4.0.34.1), Apple clang 21.0.0
(clang-2100.3.34.2), Xcode 27.1. Full versions are in `host.txt`. libdispatch is the system copy
(`/usr/lib/system/libdispatch.dylib` exists only in the dyld shared cache, so there is no file
to hash). This is a reference run, not a qualification.

Inputs: `/Volumes/MM4-1T/Local/swift-rx/swift-sdk-op-233/`. `shasum -a 256 -c SHA256SUMS`
passed for all 8 entries. Inputs were not modified. swift-fifo was built from a copy at
`results/swift-fifo-build/`.

Method: `probes/op-233/build_run.zsh` (a copy is in `results/`). Each C case is built with
`clang -fblocks -O0 -g` against the system libdispatch. The upstream tests are compiled with
`-I tests` plus `bsdtests.c` and `dispatch_test.c`. Each case ran 5 times under
`timeout 120 … </dev/null`. The whole matrix ran twice, both times with identical results:
- `results/logs/`: inside Claude Code's Bash sandbox;
- `results/logs-nosandbox/`: outside it.

Raw logs are hashed in `RESULTS.SHA256SUMS` (696 files). `results/crash-reports/` holds 19 `.ips`
files; ReportCrash did not write one for every crash.

| Case | macOS (5/5 runs, both passes) | rmxOS (as briefed) | Verdict |
|---|---|---|---|
| `dispatch_io_pipe_close.c` | pass: rc 0, "all done", no BUG IN CLIENT | abort "BUG IN CLIENT OF LIBDISPATCH: Over-resume of an object" | rmxOS differs from macOS |
| `dispatch_readsync.c` | **does not build**: `dispatch_readsync.c:22: fatal error: 'dispatch/private.h' file not found` (the SDK has no private headers) | hang, killed at 120 s | no macOS reference (not ported, per brief) |
| `dispatch_concur.c` | **does not build**: `dispatch_concur.c:22: fatal error: 'dispatch/private.h' file not found` | `:110` concurrently completed workers 0, expected 4 | no macOS reference (not ported, per brief) |
| `dispatch_thread_name.c` | fail, rc 255: 10/10 `[FAIL] worker thread name must not be empty (dispatch_thread_name.c:77)`, stderr `Worker thread name: ''` ×10; 10/10 `[PASS] worker thread must not inherit parent name` | `:77` worker thread name must not be empty | same on macOS (the test assumes Linux) |
| `block_wait.c` | pass, rc 0: `qos item wait=0 ran=1`, `plain item wait=0 ran=2` | cancel/notify/wait abort "Invalid block object", SIGILL | rmxOS differs from macOS |
| `variants plain-call` | pass, rc 0: `ran`, `done` | pass | same on macOS |
| `variants plain-perform` | pass, rc 0: `perform ran`, `done` | pass | same on macOS |
| `variants plain-cancel` | pass, rc 0: `testcancel=1`, `done` | abort "Invalid block object", SIGILL | rmxOS differs from macOS |
| `variants plain-notify-async` | rc 0: `ran`, `done`; no abort. `notified` was never printed (0/10): the probe returns after `dispatch_sync` before the notify block runs, which is a race in the probe | abort "Invalid block object", SIGILL | rmxOS differs from macOS |
| `variants plain-wait` | rc 0: `wait=49` (KERN_OPERATION_TIMED_OUT after 2 s; the block is never run), `done` | abort "Invalid block object", SIGILL | rmxOS differs from macOS |
| `variants plain-async-wait` | rc 0: `ran`, `wait=0`, `done` | abort "Invalid block object", SIGILL | rmxOS differs from macOS |
| `variants qos-call` | rc 0: `ran`, `done` | pass | same on macOS |
| `variants qos-wait` | rc 0: `wait=49` after 2 s, `done` | abort "Invalid block object", SIGILL | rmxOS differs from macOS |
| `variants qos-async-wait` | rc 0: `ran`, `wait=0`, `done` | abort "Invalid block object", SIGILL | rmxOS differs from macOS |
| `double_init` (no arg) | pass, rc 0: `main queue ran` after about 2.1 s | pass (implied) | same on macOS |
| `double_init init` | crash, rc 137 (SIGKILL) within 10 ms, no output. The `.ips` shows EXC_BREAKPOINT delivered as SIGKILL, with abort cause "BUG IN CLIENT OF LIBPTHREAD: workgroup functions already installed" in `pthread_install_workgroup_functions_np` called from `main`. `libdispatch_init` links: undefined external `_libdispatch_init` resolved from libSystem | hang (before the rmxOS fix) | rmxOS differs: macOS traps a second init at once rather than hanging. Neither OS supports a second call |
| `blocked_worker 0` | pass, rc 0: `PASS: second block ran while first was blocked` | pass | same on macOS |
| `blocked_worker 0x15` | pass, rc 0 (same output) | pass | same on macOS |
| `fifo_global_queue 0` | pass, rc 0: `writer opened`, `reader opened` | pass | same on macOS |
| `fifo_global_queue 16` | pass, rc 0 (same output) | pass | same on macOS |
| `swift-fifo`: `swift build -c release` | builds, rc 0 | n/a | |
| `fifo posix` | pass, rc 0: `PASS posix read test-secret-token` | pass 3/3 | same on macOS |
| `fifo foundation` | fail, rc 133 (SIGTRAP, `swift_errorInMain`): NSCocoaErrorDomain 257 / NSPOSIXErrorDomain 13 "Permission denied" from `String(contentsOfFile:)`. It also fails outside the sandbox (5/5 more), so it is not an artefact of the sandbox | NSCocoaErrorDomain 257, POSIX 13 | same on macOS (not the rmxOS sandbox) |
| SwiftPM `swift test --filter localFileSystemReadFileContentsAcceptsNonRegularFile` | **not run**: mm4 has no SwiftPM 6.4.0 checkout | hang in `fifo_open` | untested |

Notes:
- Upstream tests: on Apple, `test_stop()` spawns `./leaks-wrapper`. That file is absent, so the
  harness prints a `perror` with a stale errno ("Operation timed out" / "Resource temporarily
  unavailable") and records no test result. This has no effect on the results.
- `bsdtestharness.c` does not build on macOS: `#error "bsdtestharness not implemented on this
  platform"` plus undeclared `attr`/`spawnflags`. Tests were run directly, without it.
- The `fifo foundation` mode is not SwiftPM's read path. On macOS, `String(contentsOfFile:)`
  refuses this FIFO with 257/13 even though `open(O_RDONLY)` works in the same process. The
  rmxOS 257/13 result therefore matches macOS. It does not reproduce the SwiftPM hang.

Suggested rmxOS regression assertions (expected = the macOS result):
- `dispatch_io_pipe_close.c`: exit 0, no BUG IN CLIENT.
- `probes/variants.c`: each of the 9 cases exits 0 and prints `done`. `*-wait` without async
  prints a nonzero result; `*-async-wait` prints `wait=0`.
- `probes/block_wait.c`: exit 0, both waits are 0.
- `dispatch_thread_name.c:77`: do not use it as an rmxOS gate. Unnamed workers are Apple
  behaviour.
