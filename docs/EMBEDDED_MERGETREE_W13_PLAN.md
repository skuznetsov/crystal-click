# W13 raw DateTime/DateTime64 reader/writer plan

Status: completed on the pinned W13 frontier. Contract:
`EMBEDDED_MERGETREE_FRONTIER.md`, W13. Risk: CAUTION (semantic
type and precision dispatch, persisted writer bytes). Rollback: one local W13
feature commit after the gate passes, or W13-owned paths before commit. No push.

Factual anchor: pinned ClickHouse local 26.7.1.1315 preserved `UInt32::MAX`
for bare `DateTime` and both `Int64` extrema for `DateTime64(0)`, `(3)`, and
`(9)` in RowBinary; detach/attach also preserved the DateTime and p=3 rows.
The stock parts have one little-endian payload stream, plain adaptive marks
`[2, 2, 1]` plus sentinel, and passed `CHECK TABLE`. Scale 10 and negative
scale were rejected by the pinned build. Stock metadata preserves
`DateTime64(3)` separately from `DateTime64(3, 'UTC')`. Catalog parsing
preserves the complete type expression, and the W12 reader/writer already
carry the underlying
UInt32/Int64 values as primitive numbers. The missing capability is exact
semantic dispatch and an explicit writer type, not a new integer codec.

Consumer inventory at W12 HEAD `b9d9ecf`: `rg -n 'supports_typed_type\?' src examples`
finds the reader entry point in `src/crystal_click/wide_part.cr`, catalog
selection in `src/crystal_click/offline_catalog.cr`, and the page source and
browser widget under `examples/offline_tui/`. The widget permits only
UInt64/String equality filters; W13 must not widen them. Batch dispatch in
`src/crystal_click/wide_part_table.cr` and catalog materialization are the
other typed-value consumers. `spec/date_scan_spec.cr`,
`spec/wide_part_writer_date_spec.cr`, and `scripts/check_date_oracle.sh` are
the bounded W12 templates, not W13 evidence.

1. First establish stock endpoint-scale behavior for `DateTime64(0)` and
   `(9)` plus the rejected `(10)`/negative precision forms. If the pinned
   build disagrees with the proposed grammar or raw-code preservation,
   narrow the SDD before any source promotion. Add RED specs for exact
   metadata and raw codes across marks, scale retention, negative/extreme
   ticks, primitive-accessor rejection, numeric-scan rejection, and invalid
   types. New file: `spec/datetime_scan_spec.cr`.
2. Add a canonical `DateTime64(p)` precision parser and exact `DateTime`
   support in `src/crystal_click/wide_part.cr`; add semantic mark and batch
   accessors in it and `src/crystal_click/wide_part_table.cr`, preserving
   primitive numeric gates. Extend `src/crystal_click/offline_catalog.cr`
   materialization without dropping the full type string. Make the RED
   reader/catalog specs pass.
3. Add RED writer specs in `spec/wide_part_writer_datetime_spec.cr`, then
   explicit writer entry points and staged semantic reread in
   `src/crystal_click/wide_part_writer.cr`. Keep inferred UInt32/Int64
   numeric, preflight precision and shape, and clean staging on publication
   failure. No broad writer refactor.
4. Extend `examples/offline_tui/page_source.cr` and its existing spec to
   render raw seconds/ticks with an explicit scale label on DateTime64 cells
   (the existing header shows only a column name); document that choice in
   `examples/README.md`,
   and assert equality filters remain unsupported. Add a pinned
   `scripts/check_datetime_oracle.sh` for stock-to-Crystal and
   Crystal-to-stock bytes/marks/RowBinary/`CHECK TABLE`/corruption. The
   oracle must prove a clean case and a seeded same-size violation.

DoD: focused RED-to-green specs; full Crystal debug and release suites with
`--link-flags='-fuse-ld=ld'` and isolated Crystal caches if concurrent tests
would collide; `crystal tool format --check`, `bash -n`, and
`git diff --cached --check`; pinned W13 oracle and W9-W12 oracle controls
pass. Build the optional TUI and run its headless suite. Adversarially check
scale 0/3/9, timezone/noncanonical metadata refusal, primitive aliases,
full raw domains tested by the pinned build, and no destination after a
failed publication. A Crystal part rejected by stock ClickHouse, or a
stock part whose raw codes change after attach, blocks a compatibility claim
and commit. The result will be bounded to pinned build, Wide/LZ4/plain
adaptive marks, tested fixtures, and Darwin publication.

Observed closure: RED reader and writer specs failed on missing entry points,
then their focused suites passed. Full debug and release Crystal suites each
passed 388 examples. The W13 oracle passed stock-to-Crystal and
Crystal-to-stock for `DateTime` and `DateTime64(0)`, `(3)`, `(9)`, including
extreme raw codes, exact physical marks/payloads, byte-exact full/key-range
RowBinary, `ATTACH PART`, `CHECK TABLE`, and same-size corruption rejection.
W9-W12 differential oracles passed; headless TUI specs and the linked example
build passed. Formatting, shell syntax, and diff whitespace checks passed.
This closes only the admitted pinned build/format/fixture scope. Refresh the
evidence if time dispatch, serialization, part framing, or the pinned
ClickHouse build changes; timezone-qualified types and civil conversions
remain guard-only.
