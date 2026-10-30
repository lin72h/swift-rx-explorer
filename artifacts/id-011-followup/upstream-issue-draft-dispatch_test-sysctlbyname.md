# Draft, not filed: tests/dispatch_test.h declares sysctlbyname with the wrong signature on Apple

Target: swiftlang/swift-corelibs-libdispatch (checked against `swift-6.4.0-RELEASE`,
`024805a`, and `main` on 2026-10-30; an issue/PR search for `sysctlbyname` found no
existing report).

## Problem

`tests/dispatch_test.h:55-58`:

```c
#if __APPLE__
int sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp,
		size_t *newpl);
#endif
```

The last parameter is `size_t newlen` in `<sys/sysctl.h>` on Darwin (and on FreeBSD).
Any test that includes both `<sys/sysctl.h>` and `dispatch_test.h` fails to compile on
macOS:

```
tests/dispatch_test.h:56:5: error: conflicting types for 'sysctlbyname'
```

Affected on macOS 27.2 / Apple clang 21.0.0: `dispatch_apply.c` (fails on this alone),
and `dispatch_concur.c`, `dispatch_priority.c` (and the `dispatch_priority2` variant),
`dispatch_readsync.c` and `dispatch_vm.c`. The latter four also need `<dispatch/private.h>`,
which hides this error until those headers are found.

## Fix

```diff
 #if __APPLE__
 int sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp,
-		size_t *newpl);
+		size_t newlen);
 #endif
```

or drop the declaration, since every caller includes `<sys/sysctl.h>`.

## Evidence

With only this change (a patched copy of `tests/`, linked against macOS's system
libdispatch 1605.40.4), `dispatch_apply` builds and its results are in
`artifacts/id-011-followup/README.md` of swift-rx-explorer.
