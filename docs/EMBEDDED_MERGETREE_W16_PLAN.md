# W16 paired Decimal128 payload plan

Status: verified on the pinned ClickHouse 26.7.1.1315 Wide/LZ4/Darwin
frontier. Source boundary: `EMBEDDED_MERGETREE_FRONTIER.md`, W16. Risk:
CAUTION (16-byte signed data and scale metadata may silently round-trip
incorrectly). Rollback: one W16-only local feature commit, no push; never
edit an existing ClickHouse data root.

1. Probe pinned ClickHouse 26.7.1.1315 in a unique temporary root for bare
   `Decimal128(S)` and BASIC Nullable at scales 0, a middle value, and 38.
   Record normalized `columns.txt`, physical stream order and 16-byte bytes,
   marks, serialization metadata, RowBinary, and `CHECK TABLE`. If any shape
   differs from the W16 design, revise the SDD before production code.
2. Write focused RED reader and writer specs for signed endpoints/large raw
   values, multi-mark short tails, NULL versus zero, exact scale grammar,
   primitive-accessor isolation, truncated streams, and prepublication
   rejection. Files: `spec/wide_part_reader_w16_spec.cr` and
   `spec/wide_part_writer_w16_spec.cr`.
3. Add only exact Decimal128 type recognition, 16-byte signed decoding, and
   bare/Nullable accessors in `src/crystal_click/wide_part.cr`. Propagate the
   type through batch dispatch in `src/crystal_click/wide_part_table.cr` and
   selected-column materialization in `src/crystal_click/offline_catalog.cr`.
   Consumer inventory: `rg -n 'supports_typed_type|decimal64|WidePartNumeric|WidePartNullable|typed_column_size|format_cell' src examples spec`.
   Guard: generic numeric and `Int128` paths must not reinterpret Decimal128.
4. Add explicit `write_uint64_decimal128_pair` and nullable counterpart in
   `src/crystal_click/wide_part_writer.cr`. Extend byte width, little-endian
   write, staged readback, and type validation only for these named APIs.
   Invalid scale/input must fail before staging or publication.
5. Either render the new raw values in `examples/offline_tui/page_source.cr`
   with focused headless specs, or explicitly reject selection there. Never
   expose a selectable column that fails only when a page loads.
6. Add `scripts/check_decimal128_oracle.sh`: independent stock-to-Crystal
   reads and Crystal-to-stock `ATTACH PART`, full/key-range byte-exact
   RowBinary, `CHECK TABLE`, and same-size corruption rejection. Then run the
   W9-W15 pinned oracles, full debug/release `crystal spec`, TUI harness,
   formatter, shell syntax, and `git diff --check`.

Definition of Done: both W16 shapes pass the pinned paired oracle; focused
negative cases fail closed; full debug/release suites and earlier oracles pass;
the final SDD records observed evidence and residual rejected types. If only
one direction or shape passes, retain W16 as in progress and do not claim
paired type parity.

Observed closure: seven stock-to-Crystal and Crystal-to-stock oracle cases
passed at scales 0, 2, and 38, including a bare raw `Int128::MIN/MAX` case;
all included physical streams/marks, full and key-range RowBinary, attach,
and `CHECK TABLE`. The full debug and release suites each passed 436 examples;
the W9-W15 pinned type oracles and optional headless TUI harness passed. The
remaining type families and layouts are rejected as listed in the W16 SDD.
