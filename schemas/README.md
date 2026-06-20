# Gatekeeper Schemas

This directory is the blessed source for Gatekeeper JSON schemas and outcome
taxonomy. Shared code may mirror these definitions, but authority starts here.

Compatibility rules:

- Same major version: additive optional fields only.
- Required-field changes require a new major schema.
- Enum removals or renames require a new major schema.
- Meaning changes or stricter interpretation require a new major schema.
- Validators may reject older artifacts only when the governing record names
  the cutoff and migration path.

Unknown-field policy:

- Authority, disposition, and activation records reject unknown fields.
- Raw-fact producer outputs may allow unknown fields, but ignore them unless
  schema-known.
- UI/cache summaries are permissive and are never primary evidence.

Changelog:

- `v1`: initial Gatekeeper testing-strategy schema namespace.
- `swift-testing-run.v1` / `swift-testing-baseline.v1`: proposed by
  explorer-mx-a64z (block-021) for the swift-testing corelibs dimension.
  Parser/producer output for `swift test` native (✔/✘/➜) output, plus the
  derived regression baseline. Pending gatekeeper ratification; additive,
  no change to existing v1 schemas.
- `swift-r64z-lane-a-vectors.v1`: proposed by explorer-mx-a64z (block-017) for
  Lane A substrate behavior probe vectors (ABI/runtime/stdlib). Producer
  output assembled by parse_swift_probe_vectors.exs. Pending gatekeeper
  ratification; additive.
