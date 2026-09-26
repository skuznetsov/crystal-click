# W18 paired IPv4 payload plan

Status: verified on the pinned ClickHouse 26.7.1.1315 Wide/LZ4/Darwin
frontier. Source
boundary: `EMBEDDED_MERGETREE_FRONTIER.md`, W18. Risk: CAUTION (octet reversal
can silently change every valid address). Rollback: one W18-only local feature
commit; never edit an existing ClickHouse data root or push.

1. Probe pinned ClickHouse 26.7.1.1315 in a unique temporary root for `IPv4`
   and BASIC `Nullable(IPv4)`. Include `1.2.3.4`, `4.3.2.1`, zero, NULL,
   multiple marks, and a short final granule. Record exact `columns.txt`,
   stream names/order, `serialization.json`, decoded bytes, marks, RowBinary,
   and `CHECK TABLE`. Amend the SDD before implementation if the observation
   conflicts with the proposed contract.
2. Add and run RED reader/writer specs in `spec/wide_part_reader_w18_spec.cr`
   and `spec/wide_part_writer_w18_spec.cr`: canonical value rendering,
   multi-mark reads, NULL versus zero, exact type dispatch, primitive accessor
   isolation, malformed metadata, truncated streams, and prepublication
   rejection. This is the cheapest falsifier for the proposed API.
3. Add a four-byte `CrystalClick::IPv4Value` in
   `src/crystal_click/ipv4_value.cr`, required by `src/crystal_click.cr`.
   Store the network-order 32-bit address (`1.2.3.4` = `0x01020304`) in
   the value type and serialize that integer little-endian, as the pinned
   RowBinary probe observed `04 03 02 01`. Expose named octet construction
   and dotted-decimal rendering so callers do not confuse the value with an
   ordinary `UInt32`.
   Integrate exact reader dispatch in `src/crystal_click/wide_part.cr`, batch
   accessors/unions in `src/crystal_click/wide_part_table.cr`, and selected
   column materialization in `src/crystal_click/offline_catalog.cr`.
   Guard: no generic `UInt32` reinterpretation, and no noncanonical type
   spelling admitted by a prefix match.
4. Add named bare/nullable IPv4 writer APIs in
   `src/crystal_click/wide_part_writer.cr` with the probed four-byte order,
   BASIC null map, zero-filled NULL slots, and staged self-readback. Validate
   all inputs before stage creation; a rejected write leaves no part.
5. Render IPv4 in `examples/offline_tui/page_source.cr` with focused
   `spec/offline_tui_page_source_spec.cr` coverage, or reject the type at
   page-source initialization. A selectable type cannot fail only at load.
6. Add `scripts/check_ipv4_oracle.sh`: stock-to-Crystal and Crystal-to-stock
   `ATTACH PART`, byte-exact full/key-range RowBinary, physical payload and
   mark comparison, clean `CHECK TABLE`, and same-size corruption rejection.
   Run it and W9-W17 type oracles, full debug/release `crystal spec`, the
   selected-column TUI spec and optional headless harness, formatter, shell
   syntax check, and `git diff --check`.

Definition of Done: both IPv4 shapes pass the pinned bidirectional oracle,
focused negative cases fail closed, full suites and earlier type oracles pass,
and the SDD records observed evidence and residual rejected surfaces. If
either direction or shape fails, keep W18 in progress and make no paired
compatibility claim.

Observed closure: the preimplementation probe established the network-order
UInt32 payload encoded little-endian (`1.2.3.4` as `04 03 02 01`) and a
separate BASIC null map with four zero nested bytes under NULL. The paired
pinned oracle passed stock-to-Crystal and Crystal-to-stock `ATTACH PART`,
including exact metadata/streams/marks, full and key-range RowBinary,
`CHECK TABLE`, and isolated stock checksum rejection for same-size payload
and null-map corruption. Full debug and release suites each passed 458
examples; W9-W17 oracles, the 23-example selected-column TUI spec, and the
six-example optional headless harness passed. The adversarial review found
no blocker within the pinned scope. ClickHouse checksum rejection is not a
claim that Crystal detects arbitrary rechecksummed semantic corruption.
