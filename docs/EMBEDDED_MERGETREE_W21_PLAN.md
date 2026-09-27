# W21 paired Array(UInt64) and Array(String) payload plan

Status: verified within the pinned W21 boundary. Source boundary:
`EMBEDDED_MERGETREE_FRONTIER.md`, W21.
Risk: CAUTION (a valid-looking offset stream can shift values between rows).
Rollback: one W21-only local feature commit, with no push or mutation of an
existing ClickHouse data root.

1. Probe pinned ClickHouse 26.7.1.1315 in a unique temporary root for both
   exact payload types, with empty/nonempty rows, empty and embedded-zero
   strings, multiple marks, and a short final granule. Record exact type and
   serializer metadata, substreams, raw bytes, marks, RowBinary, and `CHECK
   TABLE`. A source-code inference alone is not a format certificate.
2. Write focused failing reader and writer specs before production changes.
   Cover exact type admission, per-row boundaries, empty values, keyed mark
   ranges, malformed offsets, truncated nested bytes, and scalar accessor
   isolation. The writer test must distinguish staged self-read from a stock
   ClickHouse acceptance check.
3. Add only `Array(UInt64)` and `Array(String)` reader paths in
   `src/crystal_click/wide_part.cr`, propagating batches through
   `src/crystal_click/wide_part_table.cr`. Preflight outer row count, nested
   element count, and raw bytes before materializing, and reject unsupported
   serializer versions and stream shapes. Include present-but-zero-byte
   flattened streams, without treating absent files as valid empties.
4. Add two named writer paths in `src/crystal_click/wide_part_writer.cr` with
   exact physical streams, marks, checksums, deterministic metadata, bounded
   input validation, staged readback, and exclusive publication.
5. Add catalog materialization in `src/crystal_click/offline_catalog.cr` and
   bounded display or upfront selection rejection in
   `examples/offline_tui/page_source.cr`. Keep equality filtering restricted
   to its existing scalar types. Apply a whole-call 1,000,000 flattened
   element ceiling to catalog `.values`, alongside the existing row and
   String-byte ceilings; direct lazy scans remain usable above it.
6. Add a pinned bidirectional stock/Crystal oracle for each array shape,
   including full/key-range RowBinary, `ATTACH PART`, `CHECK TABLE`, and
   independent same-size corruption controls. Re-run the earlier type
   oracles, full debug/release specs, focused TUI specs, formatter, shell
   syntax, and Git diff checks.

Consumer search:
`rg -n 'supports_typed_type\?|expected_physical_streams|read_string_mark_range|read_numeric_mark_range|typed_column_size|format_cell|append_materialized_values|write_typed_payload_streams|validate_staged.*part' src/crystal_click examples/offline_tui spec/offline_tui_page_source_spec.cr`.
The observed consumers span reader metadata and stream selection, batch
dispatch, catalog values, TUI page loading, writer serialization, and staged
validation. No type name alone proves all these contexts are covered.

Definition of Done: both exact shapes pass a pinned bidirectional oracle,
negative cases reject before publishing bad parts, focused and full Crystal
suites pass, earlier type oracles remain green, and the SDD records observed
evidence plus residual unsupported surfaces. A green self-readback is
insufficient. If either shape fails stock attachment or keyed positional
results, W21 remains in progress.

Observed gate on ClickHouse 26.7.1.1315/Darwin: the bidirectional Array oracle
passed both types, stock and Crystal parts, full/key-range RowBinary,
`ATTACH PART`, `CHECK TABLE`, empty/zero-byte streams, and same-size corruption
controls. Full debug and release suites each passed 495 examples with zero
failures/errors; all 14 prior type oracles passed. Formatter, shell syntax,
and Git diff checks passed. Independent review verdict: ROBUST within the
pinned Wide/LZ4/plain-mark and bounded API scope, not a claim of arbitrary
checksum verification or measured performance.
