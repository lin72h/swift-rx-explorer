# Gatekeeper Test Strategy

This document records the rmxOS/Oracle testing discipline used by the
Gatekeeper role. It is standing doctrine for future validators, probes,
negative controls, evidence checkers, and accepted-result records.

## Core Rule

Run existing tests in whatever language they are already written in. Do not
rewrite working test surfaces just to normalize language.

For new tests, validators, probes, negative-control generators, and evidence
checkers, use **Elixir or Zig**:

- Use **Elixir** for parsers, validators, schema checks, marker and ordering
  validation, provenance checks, no-copy/static checks, evidence classification,
  and negative controls.
- Use **Zig** for runtime probes, ABI and IPC checks, syscall/Mach/libdispatch
  tests, process/runtime monitoring, and compiled guest/client/server smoke
  binaries.
- Use shell only as thin orchestration: build routing, environment projection,
  staging, guest invocation, command status, file/executable existence checks,
  simple hash/cmp/stat checks, and simple preflight string checks.

Shell must not own substantive marker validation, ordering logic, terminal
status checks, raw return-code normalization, hard-stop classification, or
negative-control semantics.

## Existing Tests

- Preserve and run inherited test suites as-is.
- Treat the current test language as part of the inherited surface.
- Do not weaken, skip, or replace existing tests unless a reviewed migration
  says so.
- If an existing test is flaky or underspecified, record the smallest
  falsifiable requirement before changing it.
- Existing Python, Ruby, or other evidence tools are grandfathered as read-only
  legacy. Run them when they are part of the inherited evidence flow. When
  touched for substantive behavior, port to Elixir/Zig or add a reviewed
  exception.

## New Validators And Probes

Default Elixir form:

- Use dependency-light `.exs` scripts for gate-local validators, serial
  validators, one-off schema checks, and negative controls.
- Use Mix modules/tests when logic becomes shared authority, reusable contract
  code, or repo-wide static checking.
- Use escript only when a stable standalone CLI is useful.

Default Zig form:

- Prefer static or minimally dynamic binaries where practical.
- Record Zig version, target triple, optimization mode, source file hashes,
  linked libraries and hashes where relevant, binary SHA256, guest path, and
  runtime OS/kernel/module identity.
- For guest probes, record both build-host provenance and staged-guest binary
  hash.

Third-party dependencies are disallowed by default. Use standard library plus
checked-in code. If a dependency is unavoidable, it must be pinned, vendored or
lockfile-governed, hashable, recorded in provenance, and covered by the same
evidence discipline.

## Tool Versions

Pin exact tool versions per repo and record them in provenance. The current
recommended baseline is:

- Elixir: `1.20.x` observed as `1.20.0`
- Erlang/OTP: `29.x` observed as `OTP 29`
- Zig: `0.16.x` observed as `0.16.0`

Use the same pinned versions on FreeBSD, rmxOS, macOS, and Linux coordinator
hosts unless a repo-specific environment matrix explicitly permits divergence.
Every run artifact should record `elixir --version`, OTP release, `zig version`,
host OS, target triple, and source commit.

## Evidence Discipline

- Raw evidence is authoritative.
- Runtime evidence must be preserved unchanged.
- UI snapshots, summaries, and generated reports are cache/state only unless
  explicitly promoted by an evidence record.
- Never synthesize `pass`, `fresh`, or `accepted` from absence.
- Unknown data remains `unknown`, `parser_missing`, or `null`.
- Post-run validation may add curated artifacts, but must not mutate raw
  serials or logs.
- Generated summaries may be consistency-checked, but cannot satisfy a claim,
  marker, order, hard-stop, terminal, or acceptance contract.

For acceptance, validators read raw serial/log evidence plus explicit
provenance inputs. Generated summaries are not primary evidence.

## Validator Requirements

Validators must check:

- exact marker keys and field policies;
- strict order where order is load-bearing;
- singleton and duplicate rules;
- terminal status;
- raw return-code normalization rules;
- hard-stop strings;
- negative controls for every claim class.

Presence-only marker checks are not enough.

Each validator must have a self-test mode:

- `elixir validator.exs --self-test <tmpdir>` for standalone `.exs` validators;
- `mix test` for Mix-owned validators;
- `zig test` for Zig libraries/probes where applicable;
- repo-level preflight may invoke all of the above.

Self-tests must emit machine-readable JSON negative-control evidence, not just
text. A representative shape is:

```json
{
  "schema": "negative-controls.v1",
  "validator": "name",
  "validator_pin": "...",
  "cases": [
    {
      "id": "missing_terminal",
      "mutation": "removed terminal marker",
      "expected": "fail",
      "actual": "fail",
      "passed": true
    }
  ],
  "passed": true
}
```

Every new validator should include negative controls in the same change. Shared
class-level controls may be reused, but each new claim must have at least one
targeted red path proving its load-bearing rule fails closed. Batching is
acceptable only when the claim is not used for acceptance until the batch lands.

## Canonical Schemas

Use one repo-owned namespace:

- `schemas/` for JSON Schemas and version history;
- `schemas/outcomes.v1.json` for shared outcome enums;
- `schemas/provenance-envelope.v1.json` for minimum provenance;
- `schemas/README.md` for compatibility rules and changelog.

Shared code may mirror these in `lib/...`, but `schemas/` is the blessed source.

Canonical evidence format is JSON:

- raw serial/log text remains immutable primary evidence;
- JSON is used for provenance, disposition, validation, negative controls,
  marker coverage, boot identity, and summaries;
- JSONL is allowed only for append-heavy event streams where ordering is
  intrinsic;
- TOML/YAML should not be used for gate evidence.

Every JSON artifact should include a schema/version field and provenance
envelope.

## Schema Compatibility

Within the same major schema version:

- additive optional fields are allowed;
- required-field changes require a new major schema;
- enum removals or renames require a new major schema;
- meaning changes or stricter interpretations require a new major schema.

Validators may reject older artifacts only if the governing record names the
cutoff and migration path.

Unknown-field policy:

- authority, disposition, and activation records reject unknown fields;
- raw-fact producer outputs may allow unknown fields, but must ignore them
  unless schema-known;
- UI/cache summaries are permissive and are never primary evidence.

## Minimum Provenance Envelope

Every JSON evidence artifact must include at least:

```json
{
  "schema": "name.v1",
  "artifact_kind": "validation|disposition|provenance|coverage|negative_controls",
  "created_at_utc": "RFC3339",
  "mode": "explorer|gatekeeper",
  "repo": {
    "path": "...",
    "head": "...",
    "dirty": true
  },
  "source": {
    "path": "...",
    "pin": "..."
  },
  "inputs": [
    {"path": "...", "sha256": "..."}
  ],
  "tool_versions": {
    "elixir": "...",
    "otp": "...",
    "zig": "..."
  }
}
```

Gate-specific artifacts add run id, validator pin, evidence path, raw digest,
and disposition.

## Outcome Taxonomy

Gatekeeper/Oracle owns the shared outcome taxonomy. Centralize enums in a
versioned schema/module, not per-validator. Core terms include:

- `pass`
- `fail`
- `accepted`
- `not_accepted`
- `blocked`
- `unknown`
- `parser_missing`
- `setup_failure_before_candidate`
- `hard_stop`
- `attempt_consumed`
- `non_consumed_attempt`

Producers may emit raw facts. They must not synthesize acceptance.

## Failure Rule

If a test fails, stop and report the smallest falsifiable requirement. Do not
broaden scope, rerun guests, or patch around the failure unless new
authorization allows it.

A failed runtime attempt with candidate markers is consumed. A setup failure
before guest execution and before candidate markers is not consumed, but still
must be preserved and classified.

## Raw Evidence Retention

- Accepted raw evidence is kept forever.
- Failed consumed attempts are kept forever as falsifiers.
- Setup failures before candidate markers are preserved by default.
- Compression of non-consumed setup failures is allowed only after a disposition
  records `attempt_consumed=false`, the raw digest, compression hash, and restore
  command.
- Pruning requires Coordinator acceptance.

## Time Representation

Use UTC RFC3339 for wall-clock time:

```text
2026-06-18T03:14:15Z
```

Use monotonic durations for elapsed or ordering-sensitive measurements:

```json
{"duration_ms": 1234, "clock": "monotonic"}
```

Never use local time as a primary evidence timestamp.

## Exceptions

Record exceptions as JSON waiver artifacts under:

```text
waivers/<id>.json
```

A waiver must include owner, reason, scope, expiry or review trigger,
approved-by, affected paths, and compensating checks. Source comments may point
to the waiver, but comments are not authority.

## Promotion To Shared Authority

Gatekeeper may propose promotion of a gate-local `.exs` validator after accepted
evidence or repeated reuse.

Promotion requires:

- Arranger review for design and scope;
- Coordinator acceptance for making it shared authority;
- Gatekeeper ownership of implementation and disposition once accepted.

## Gatekeeper Posture

Gatekeeper owns disposition, not optimism.

Accept only what the evidence proves. Defer everything else as an explicit
non-claim or open obligation.
