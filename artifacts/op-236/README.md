# op-236: macOS baseline for every upstream libdispatch 6.4.0 test (mm4)

Host: mm4, macOS 27.2 (26B123), Apple Swift 6.4, Apple clang 21.0.0 (clang-2100.3.34.2), Xcode
27.1 with the MacOSX.sdk. Full versions are in `host.txt`. libdispatch is the system copy from
the dyld shared cache. The input tarball sha256 is `af15fcc3…c104c6` (matches op-233
`SHA256SUMS`).

Method: op-233's method, scripted in `probes/op-236/build_run.zsh`. All 50 files in `tests/` were
built with Apple clang and `-fblocks -Wall -Wno-deprecated-declarations -g -I tests`, linked
with `bsdtests.o`, `dispatch_test.o` and `-lm`. There is no corelibs libdispatch and no
`config.h`. Where a test includes CoreFoundation or Security, that framework was linked.
`dispatch_c99` was built with `-std=c99` and `dispatch_plusplus.cpp` with clang++. CMake's
extended-suite variant `dispatch_priority2` is `dispatch_priority.c` built with
`-DUSE_SET_TARGET_QUEUE=1`.

Each test that built ran directly (`bsdtestharness.c` does not build on macOS), 5 times, under
`timeout 120 … </dev/null`, from its own work directory, outside Claude Code's tool sandbox.
Results were parsed from the raw logs by `tools/summarize_op236.exs` (13 negative controls
pass, see `summarize-op236.negative-controls.v1.json`). Raw logs are in
`/Volumes/MM4-1T/Local/swift-rx/swift-sdk-op-233/results-full/`, hashed in
`RESULTS.SHA256SUMS` (691 files). No run crashed, timed out or varied across the 5 runs.

Totals: 50 files are 44 tests and 6 support files; with `dispatch_priority2` that makes 45
test rows.
- **macOS:** 33 pass 5/5, 1 fails 5/5 (`dispatch_thread_name`), 11 do not build.
- **Builds:** 9 of the 11 failures are `dispatch/private.h` missing from the public SDK, 1 is a
  `sysctlbyname` prototype conflict and 1 is an `#error` for lack of `config.h`.
- **rmxOS differs:** `dispatch_io` and `dispatch_io_pipe_close` (macOS passes, rmxOS fails).
- **Not registered on rmxOS but pass on macOS:** `cffd`, `dispatch_cf_main`, `dispatch_proc`,
  `dispatch_vnode` and `dispatch_workqueue`.

## Table

The rmxOS column uses swift-sdk op-224 run 5 on adx01 (36 registered). `not_registered` means
the test is not in rmxOS's 36. Cells are generated (`summary.md`); the notes below the table
are mine.

| File | macOS build | macOS result (5 runs) | rmxOS | Verdict |
|---|---|---|---|---|
| `bsdtestharness` | no: `bsdtestharness.c:81:41: error: use of undeclared identifier 'attr'` | support | not_registered | harness/support file, not a test |
| `bsdtests` | yes | support | not_registered | harness/support file, not a test |
| `bsdtestsummarize` | yes | support | not_registered | harness/support file, not a test |
| `cffd` | yes | 5× pass(rc 0); PASS 1, FAIL 0; 1.204–1.457 s | not_registered | rmxOS differs (macOS passes; not registered on rmxOS) |
| `dispatch_after` | yes | 5× pass(rc 0); PASS 6, FAIL 0; 9.447–9.799 s | pass | same |
| `dispatch_api` | yes | 5× pass(rc 0); PASS 1, FAIL 0; 0.14–0.386 s | pass | same |
| `dispatch_apply` | no: `dispatch_test.h:56:5: error: conflicting types for 'sysctlbyname'` | no_build | pass | no macOS result (does not build against the public SDK) |
| `dispatch_c99` | yes | 5× pass(rc 0); PASS 1, FAIL 0; 0.134–0.392 s | pass | same |
| `dispatch_cascade` | yes | 5× pass(rc 0); PASS 0, FAIL 0; 0.148–0.428 s | pass | same |
| `dispatch_cf_main` | yes | 5× pass(rc 0); PASS 9, FAIL 0; 1.157–1.431 s | not_registered | rmxOS differs (macOS passes; not registered on rmxOS) |
| `dispatch_concur` | no: `dispatch_concur.c:22:10: fatal error: 'dispatch/private.h' file not found` | no_build | fail | no macOS result (does not build against the public SDK) |
| `dispatch_context_for_key` | yes | 5× pass(rc 0); PASS 8, FAIL 0; 0.14–0.385 s | pass | same |
| `dispatch_data` | yes | 5× pass(rc 0); PASS 4, FAIL 0; 0.14–0.393 s | pass | same |
| `dispatch_deadname` | no: `dispatch_deadname.c:22:10: fatal error: 'dispatch/private.h' file not found` | no_build | not_registered | unsupported on both (macOS: no build; rmxOS: not registered) |
| `dispatch_debug` | yes | 5× pass(rc 0); PASS 0, FAIL 0; 0.14–0.383 s | pass | same |
| `dispatch_drift` | yes | 5× pass(rc 0); PASS 2, FAIL 0; 25.141–25.396 s | pass | same |
| `dispatch_group` | yes | 5× pass(rc 0); PASS 8, FAIL 0; 9.574–9.96 s | pass | same |
| `dispatch_io` | yes | 5× pass(rc 0); PASS 45, FAIL 0; 2.217–2.508 s | fail: does not build (struct rlimit without <sys/resource.h>) | rmxOS differs |
| `dispatch_io_muxed` | yes | 5× pass(rc 0); PASS 5, FAIL 0; 0.668–0.918 s | pass | same |
| `dispatch_io_net` | no: `dispatch_io_net.c:294:2: error: "dispatch_io_net not implemented on this platform"` | no_build | pass | no macOS result (does not build against the public SDK) |
| `dispatch_io_pipe` | yes | 5× pass(rc 0); PASS 36, FAIL 0; 2.199–2.477 s | pass | same |
| `dispatch_io_pipe_close` | yes | 5× pass(rc 0); PASS 0, FAIL 0; 0.14–0.39 s | fail | rmxOS differs |
| `dispatch_overcommit` | no: `dispatch_overcommit.c:26:10: fatal error: 'dispatch/private.h' file not found` | no_build | pass | no macOS result (does not build against the public SDK) |
| `dispatch_pingpong` | yes | 5× pass(rc 0); PASS 4, FAIL 0; 1.312–1.624 s | pass | same |
| `dispatch_plusplus` | yes | 5× pass(rc 0); PASS 1, FAIL 0; 0.137–0.39 s | pass | same |
| `dispatch_priority` | no: `dispatch_priority.c:23:10: fatal error: 'dispatch/private.h' file not found` | no_build | pass | no macOS result (does not build against the public SDK) |
| `dispatch_priority2` | no: `dispatch_priority.c:23:10: fatal error: 'dispatch/private.h' file not found` | no_build | pass | no macOS result (does not build against the public SDK) |
| `dispatch_proc` | yes | 5× pass(rc 0); PASS 24, FAIL 0; 12.596–12.75 s | not_registered | rmxOS differs (macOS passes; not registered on rmxOS) |
| `dispatch_queue_finalizer` | yes | 5× pass(rc 0); PASS 3, FAIL 0; 1.137–1.469 s | pass | same |
| `dispatch_read` | yes | 5× pass(rc 0); PASS 23, FAIL 0; 0.138–0.409 s | pass | same |
| `dispatch_read2` | yes | 5× pass(rc 0); PASS 19, FAIL 0; 4.85–5.093 s | pass | same |
| `dispatch_readsync` | no: `dispatch_readsync.c:22:10: fatal error: 'dispatch/private.h' file not found` | no_build | fail | no macOS result (does not build against the public SDK) |
| `dispatch_select` | yes | 5× pass(rc 0); PASS 31, FAIL 0; 0.146–0.385 s | pass | same |
| `dispatch_sema` | yes | 5× pass(rc 0); PASS 1, FAIL 0; 0.155–0.418 s | pass | same |
| `dispatch_starfish` | yes | 5× pass(rc 0); PASS 10, FAIL 0; 5.688–6.083 s | pass | same |
| `dispatch_suspend_timer` | yes | 5× pass(rc 0); PASS 7, FAIL 0; 9.64–9.888 s | pass | same |
| `dispatch_sync_on_main` | no: `dispatch_sync_on_main.c:22:10: fatal error: 'dispatch/private.h' file not found` | no_build | not_registered | unsupported on both (macOS: no build; rmxOS: not registered) |
| `dispatch_test` | yes | support | not_registered | harness/support file, not a test |
| `dispatch_thread_name` | yes | 5× fail(rc 255); PASS 10, FAIL 10; 0.14–0.381 s; first `[FAIL] worker thread name must not be empty (dispatch_thread_name.c:77)` | fail | same (fails on both) |
| `dispatch_timer` | yes | 5× pass(rc 0); PASS 10, FAIL 0; 2.147–2.384 s | pass | same |
| `dispatch_timer_bit31` | yes | 5× pass(rc 0); PASS 3, FAIL 0; 2.286–2.545 s | pass | same |
| `dispatch_timer_bit63` | yes | 5× pass(rc 0); PASS 0, FAIL 0; 1.151–1.431 s | pass | same |
| `dispatch_timer_set_time` | yes | 5× pass(rc 0); PASS 3, FAIL 0; 2.452–2.69 s | pass | same |
| `dispatch_timer_short` | yes | 5× pass(rc 0); PASS 3, FAIL 0; 1.155–1.428 s | pass | same |
| `dispatch_timer_timeout` | yes | 5× pass(rc 0); PASS 2, FAIL 0; 6.151–6.39 s | pass | same |
| `dispatch_transform` | no: `dispatch_transform.c:28:10: fatal error: 'dispatch/private.h' file not found` | no_build | not_registered | unsupported on both (macOS: no build; rmxOS: not registered) |
| `dispatch_vm` | no: `dispatch_vm.c:42:10: fatal error: 'dispatch/private.h' file not found` | no_build | not_registered | unsupported on both (macOS: no build; rmxOS: not registered) |
| `dispatch_vnode` | yes | 5× pass(rc 0); PASS 1, FAIL 0; 0.183–0.465 s | not_registered | rmxOS differs (macOS passes; not registered on rmxOS) |
| `dispatch_workqueue` | yes | 5× pass(rc 0); PASS 3, FAIL 0; 2.149–2.394 s | not_registered | rmxOS differs (macOS passes; not registered on rmxOS) |
| `func` | yes | support | not_registered | harness/support file, not a test |
| `generic_win_port` | no: `generic_win_port.h:7:10: fatal error: 'Windows.h' file not found` | support | not_registered | harness/support file, not a test |
| `dispatch_io_net` + `-DHAVE_POSIX_SPAWNP=1` (supplementary) | yes | 5× pass(rc 0); PASS 9, FAIL 0; 0.259–0.513 s | pass | same. The define is what CMake's `check_function_exists(posix_spawnp)` writes to `config.h` on macOS; there is no source change |

## Notes

- **Doesn't build: `dispatch/private.h`.** `concur`, `deadname`, `overcommit`, `priority`,
  `priority2`, `readsync`, `sync_on_main`, `transform` and `vm`. Upstream CMake symlinks
  corelibs' `private/` as `dispatch/`, but the macOS SDK ships no private dispatch headers, so
  under "system libdispatch only" there is no macOS result. Of these, rmxOS passes `overcommit`,
  `priority` and `priority2` (using corelibs' private header), and fails `concur` and
  `readsync`. Not ported, per the brief.
- **Doesn't build: `dispatch_apply`.** `dispatch_test.h:56` declares
  `int sysctlbyname(..., size_t *newpl)`, which conflicts with the SDK's
  `size_t newlen`. That `#if __APPLE__` declaration is stale, an upstream test-harness bug on
  Apple. No macOS result; rmxOS passes. Not ported.
- **Doesn't build: `dispatch_io_net`.** It reaches `#error "not implemented on this platform"`
  only because the op-233 method has no `config.h` (`HAVE_POSIX_SPAWNP` unset, and Apple is not
  `__unix__`). The supplementary row passes 5/5 with that one define.
- **`dispatch_thread_name`:** exit 255 (`_exit(-1)`, not a signal), 10 `[FAIL]` at `:77`
  (`worker thread name must not be empty`) and 10 `[PASS]` per run. This is the same result as
  op-233 and the same as rmxOS. Apple workers are unnamed, so the test assumes Linux.
- **`dispatch_io`:** passes 5/5 on macOS (45 `[PASS]`). rmxOS fails to build it (`struct
  rlimit` without `<sys/resource.h>`), which is an rmxOS header gap; macOS's headers supply it.
- **No `[PASS]` lines with exit 0:** `cascade`, `debug`, `io_pipe_close` and `timer_bit63` print
  no `[PASS]` lines yet exit 0. They report through the exit status only.
- **CMake timeouts:** CMake sets `dispatch_io_pipe` to 15 s and `dispatch_io_pipe_close` to 5 s.
  On macOS they took about 2.5 s and 0.4 s. `dispatch_drift` takes about 25 s, the longest test.
- **leaks-wrapper:** on Apple, `test_stop()` spawns `./leaks-wrapper`. It is absent, so it
  `perror`s (stale errno) and records no result. CMake would set `NOLEAKS=1` here; this has no
  effect on any result.
- **Not run:** `tests/Foundation/*.m` / `.mm`. They are not `*.c` files, CMake does not build
  them, and they are outside the brief.
- **No `LENIENT_DEADLINES`:** not defined (the op-233 method). Swift CI sets it with
  `ENABLE_SWIFT`; all timing tests passed without it.
- **Suggested rmxOS coverage target ("what macOS passes"):** the 33 macOS passes plus
  `dispatch_io_net`. Of those, rmxOS still has to fix `dispatch_io` and `dispatch_io_pipe_close`
  and register `cffd`, `dispatch_cf_main`, `dispatch_proc`, `dispatch_vnode` and
  `dispatch_workqueue` (Darwin process, vnode, workqueue and CoreFoundation-main behaviour).
