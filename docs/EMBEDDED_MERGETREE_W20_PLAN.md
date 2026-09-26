# W20 paired raw Decimal256 payload plan

Status: completed within the pinned W20 boundary. Source boundary:
`EMBEDDED_MERGETREE_FRONTIER.md`, W20. Risk: CAUTION (32-byte signed word
order and scale metadata can be silently wrong). Rollback: one W20-only
local feature commit; no push or existing ClickHouse data-root mutation.

1. Probe pinned ClickHouse 26.7.1.1315 in a unique temporary root for bare
   `Decimal256(S)` and BASIC Nullable at scales 0, a middle scale, and 76.
   Use asymmetric negative/positive raw coefficients, zero, NULL, multiple
   marks, a short tail, and backing extrema if raw RowBinary accepts them.
   Record canonical metadata, exact streams/bytes/marks, RowBinary, and
   `CHECK TABLE`. Revise the SDD before code if the contract differs.
2. Add a distinct 32-byte value type in `src/crystal_click/decimal256_value.cr`
   with explicit raw signed words and no per-row heap object. Write focused
   RED reader and writer specs in `spec/wide_part_reader_w20_spec.cr` and
   `spec/wide_part_writer_w20_spec.cr` before production edits. Cover sign
   extension, endian order, NULL versus zero, malformed metadata, truncated
   streams, exact scales, alias isolation, and prepublication rejection.
3. Admit exact canonical declarations and physical decoding in
   `src/crystal_click/wide_part.cr`; propagate the value through batches in
   `src/crystal_click/wide_part_table.cr` and catalog materialization in
   `src/crystal_click/offline_catalog.cr`. Consumer inventory:
   `rg -n 'decimal128|supports_typed_type|WidePartNumeric|WidePartNullable|typed_column_size|format_cell' src examples spec`.
   Guard: no generic Int128, UUID, or IPv6 accessor may reinterpret W20.
4. Add named bare/nullable writer APIs in
   `src/crystal_click/wide_part_writer.cr`, exact 32-byte encoding,
   deterministic zero-filled NULL slots, and staged readback. Invalid scale
   or input must fail before the destination is published.
5. Add Decimal256 display or up-front rejection in
   `examples/offline_tui/page_source.cr`, with focused
   `spec/offline_tui_page_source_spec.cr` coverage. A selectable column may
   not fail only when its first page loads.
6. Add `scripts/check_decimal256_oracle.sh` with independently constructed
   expected bytes, stock-to-Crystal and Crystal-to-stock `ATTACH PART`, exact
   metadata and marks, full/key-range RowBinary, clean `CHECK TABLE`, and
   same-size corruption controls. Run W9-W19 type oracles, full debug/release
   specs, selected-column TUI spec and optional headless harness, formatter,
   shell syntax, and diff checks.

Definition of Done: both shapes pass the pinned bidirectional oracle,
negative cases fail closed, full suites and earlier oracles pass, and the SDD
records observed evidence and residual rejected surfaces. A green
self-readback alone is insufficient. If either direction or shape fails,
leave W20 in progress and make no paired compatibility claim.

Closure evidence (ClickHouse local 26.7.1.1315): the strengthened pinned
oracle passed for bare and BASIC Nullable scales 0, 38, and 76, with hardcoded
raw byte fixtures, exact streams and marks, stock-to-Crystal and
Crystal-to-stock `ATTACH PART`, full/key-range RowBinary, `CHECK TABLE`, and
isolated same-size corruption controls. Full debug and release specs each
passed 478 examples; all W9-W19 pinned oracles passed; TUI page-source passed
25 examples and headless TUI passed 6. `crystal tool format --check`,
`bash -n`, and `git diff --check` passed. The independent adversarial review
returned ROBUST within this bounded path. This does not verify arithmetic,
rounding, other part layouts, or untested ClickHouse versions. Re-run the
oracle and suites if format, serializer, reader dispatch, or pinned producer
changes.
