# W17 paired UUID payload plan

Status: verified on the pinned ClickHouse 26.7.1.1315 Wide/LZ4/Darwin
frontier. Source boundary: `EMBEDDED_MERGETREE_FRONTIER.md`, W17. Risk:
CAUTION (a half-word byte-order error can silently change every valid UUID).
Rollback: one W17-only local feature commit; never edit an existing
ClickHouse data root or push.

1. Probe the pinned ClickHouse 26.7.1.1315 binary in a unique temporary root
   for `UUID` and BASIC `Nullable(UUID)` with asymmetric high/low halves,
   zero, NULL, multiple marks, and a short final granule. Record exact
   `columns.txt`, substreams, `serialization.json`, raw bytes, marks,
   RowBinary, and `CHECK TABLE`. Revise the SDD if the observed format
   differs from the W17 design.
2. Write and run RED reader/writer specs in `spec/wide_part_reader_w17_spec.cr`
   and `spec/wide_part_writer_w17_spec.cr`: canonical value rendering,
   multi-mark reads, NULL versus zero, primitive accessor isolation,
   malformed metadata, truncated streams, and prepublication rejection.
3. Add a 16-byte `CrystalClick::UUIDValue` in
   `src/crystal_click/uuid_value.cr`, required by `src/crystal_click.cr`.
   Integrate exact reader dispatch in `src/crystal_click/wide_part.cr`, batch
   accessors in `src/crystal_click/wide_part_table.cr`, and selected-column
   materialization in `src/crystal_click/offline_catalog.cr`. Inventory:
   `rg -n 'WidePartNumeric|WidePartNullable|supports_typed_type|typed_column_size|format_cell' src examples spec`.
   Guard: no generic `UInt128` or `FixedString(16)` reinterpretation.
4. Add named bare/nullable UUID writer APIs in
   `src/crystal_click/wide_part_writer.cr` with exact fixed-width bytes,
   BASIC null map, zero-filled NULL slots, and staged self-readback. Validate
   every input before stage creation; failed writes leave no part.
5. Render UUIDs in `examples/offline_tui/page_source.cr` with focused
   `spec/offline_tui_page_source_spec.cr` coverage, or reject the type at
   page-source initialization. A selectable type cannot fail only at load.
6. Add `scripts/check_uuid_oracle.sh` with independent stock-to-Crystal reads
   and Crystal-to-stock `ATTACH PART`, full/key-range byte-exact RowBinary,
   clean `CHECK TABLE`, and same-size corruption rejection. Run that oracle,
   W9-W16 pinned oracles, full debug/release `crystal spec`, the optional
   headless TUI harness, formatting, shell syntax, and `git diff --check`.

Definition of Done: both UUID shapes pass the paired pinned oracle, focused
negative cases fail closed, full suites and earlier type oracles pass, and the
SDD records evidence and residual rejected surfaces. If either direction or
shape fails, keep W17 in progress and make no paired compatibility claim.

Observed closure: bare UUID and BASIC Nullable(UUID) passed the pinned
stock-to-Crystal and Crystal-to-stock oracle, including exact physical
streams/marks, `ATTACH PART`, full and key-range RowBinary, `CHECK TABLE`,
and isolated same-size corruption. Full debug and release suites each passed
448 examples; W9-W16 oracles, the 22-example selected-column TUI spec, and
the six-example optional headless harness passed. Remaining type families
and part layouts are rejected as listed in the W17 SDD.
