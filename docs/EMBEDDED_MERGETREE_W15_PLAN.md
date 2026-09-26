# W15 paired semantic fixed-width payload plan

Status: implemented on the pinned W15 frontier; final verification evidence is
recorded in `EMBEDDED_MERGETREE_FRONTIER.md`.

Risk: CAUTION. A raw fixed-width stream can look valid while its semantic
type, enum mapping, scale, or null map is wrong. Rollback: one W15-only local
feature commit, with no push, or remove only uncommitted W15-owned changes.
Never mutate an existing ClickHouse data root.

The source frontier is `EMBEDDED_MERGETREE_FRONTIER.md`, W15. The reader's
typed whitelist is consumed by `WidePart.open_typed`, `WidePartTable` typed
dispatch, `OfflineCatalog` selection/materialization, and the example TUI
selection/formatting. Bounded inventory command:
`rg -n 'supports_typed_type\?|read_nullable_datetime|read_datetime64|scan_typed|typed_column_size|format_cell' src examples spec`.
Writer typed dispatch and readback are in `wide_part_writer.cr`; inferred
primitive numeric writes must remain primitive numeric types.

1. Probe pinned ClickHouse 26.7.1.1315 in a uniquely owned temporary root.
   Record exact normalized type spellings, physical substream order, codec,
   marks, raw bytes, `serialization.json`, RowBinary, and `CHECK TABLE` for
   Bool, Enum8/16, Decimal32/64 and BASIC Nullable forms. If a shape differs
   from the assumed fixed-width model, narrow or revise the SDD before code.
2. Add focused RED specs for exact type grammars, stock-to-Crystal multi-mark
   reads, semantic accessor isolation, invalid Bool/enum values, decimal
   scale boundaries, NULL vs zero, and prepublication rejection. Sources:
   `spec/wide_part_reader_w15_spec.cr`, `spec/wide_part_writer_w15_spec.cr`.
3. Implement the reader in `src/crystal_click/wide_part.cr` and its table and
   catalog consumers in `src/crystal_click/wide_part_table.cr` and
   `src/crystal_click/offline_catalog.cr`. New values are raw fixed-width
   semantics; no SQL conversions. Guard check: the old primitive accessors
   must reject the new semantic metadata.
4. Implement matching named writer entry points in
   `src/crystal_click/wide_part_writer.cr`. Staged self-read is a local guard,
   not compatibility proof. Guard check: invalid input leaves no published
   destination or owned staging directory behind.
5. Update `examples/offline_tui/page_source.cr` and focused TUI specs if the
   example admits the new reader types; otherwise gate selection explicitly
   to its renderable subset. Do not silently offer selectable columns that
   fail when a page loads.
6. Run the independent `scripts/check_bool_enum_decimal_oracle.sh` in both
   stock-to-Crystal and Crystal-to-stock directions, including `ATTACH PART`,
   RowBinary full/key-range bytes, and `CHECK TABLE`. Re-run W9-W14 oracles,
   full debug/release `crystal spec`, headless TUI tests, format checks, shell
   syntax, and `git diff --check`; record exact results in the SDD.

Definition of Done: every shape in W15 passes the pinned differential oracle;
full debug/release Crystal suites pass without omissions; invalid metadata,
value, and prepublication inputs fail closed; and an adversary review finds no
claim broader than the executed checks. If only a subset passes, keep W15
`IN_PROGRESS` and name that subset explicitly rather than claiming parity.

Observed gate: debug/release each passed 425 specs; the 19-case pinned
ClickHouse oracle passed stock-to-Crystal and Crystal-to-stock, including
escaped Enum labels, full/key-range RowBinary, `ATTACH PART`, `CHECK TABLE`,
and representative same-size corruption checks. W9-W14 oracles, the headless
TUI harness (six specs), and linked example build passed. The reader rejects
noncanonical Enum spacing and W15 per-column/missing-column serialization
overrides; the writer rejects invalid enum codes/declarations and scales
before staging. The user-facing API retains JSON typed-path reads without
matching JSON writer support, so this W15 gate is paired scalar parity only.
