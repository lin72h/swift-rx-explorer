# Swift 6.4 Gate Handoff

Gatekeeper is standing by. Do not run the Swift compiler suites until the
Arranger/Coordinator signal that a coherent, test-enabled 6.4 toolchain exists.

## Required From Implementer

Provide a 6.4 build that can build and run these targets without a from-scratch
reconfigure during Gatekeeper execution:

- Tier 1: `check-swift-freebsd-x86_64`
- Tier 2: `check-swift-all-freebsd-x86_64`

Required handoff details:

- Swift source path and exact source pin.
- Build directory containing the Swift ninja graph.
- Installed or staged `swiftc` path for provenance.
- Confirmation that the build is test-enabled, not a `no_test` tree.
- Confirmation that the two target names above exist in `ninja -t targets`.
- Expected incremental action count for Tier 1 and Tier 2 before lit starts.
- Any required environment variables beyond `LIT_OPTS`.
- Whether LLDB is enabled and runnable, because Swift lit config may call
  `lldb -P` during configuration.

## Gatekeeper Invocation Shape

The harness is parameterized, so the 6.4 run should be a config change, not a
code change:

```sh
scripts/run_swift_gate.zsh \
  --tier fast \
  --build-dir <swift-6.4-build-dir>/swift-freebsd-x86_64 \
  --swiftc <swift-6.4-swiftc> \
  --run-dir <artifact-run-dir> \
  --lit-jobs <N> \
  --watchdog-cpu-seconds <N>
```

For Tier 2, use `--tier full` with the same build directory/toolchain and the
Coordinator-approved job count and watchdog budget.

## Gatekeeper Will Record

- raw lit/ninja log;
- watchdog log;
- parsed run JSON;
- accepted baseline JSON only after lit accounting is present;
- diff/negative-control JSON;
- exact invocation, job count, watchdog budget, source pin, host identity, and
  tool versions.

If a prerequisite build fails before lit starts, the attempt is classified as
non-consumed and no baseline/disposition is produced.
