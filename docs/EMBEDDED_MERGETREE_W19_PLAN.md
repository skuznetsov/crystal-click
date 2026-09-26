# W19 paired IPv6 payload plan

Status: verified on the pinned ClickHouse/Darwin frontier. Source boundary:
`EMBEDDED_MERGETREE_FRONTIER.md`, W19. Risk: CAUTION (reversing any of 16
address bytes produces structurally valid but semantically wrong values).
Rollback: one W19-only local feature commit; never mutate an existing
ClickHouse data root or push.

1. Probe pinned ClickHouse 26.7.1.1315 in an isolated temporary root for
   `IPv6` and BASIC `Nullable(IPv6)`. Use asymmetric, all-zero, loopback,
   compressed, full-width, and NULL addresses over multiple marks with a
   short tail. Record exact metadata, stream names, decoded bytes, marks,
   RowBinary, text output (including one IPv4-mapped address), and
   `CHECK TABLE`. Revise the SDD first if the
   observations conflict with the proposed contract.
2. Write and run RED reader/writer specs in
   `spec/wide_part_reader_w19_spec.cr` and
   `spec/wide_part_writer_w19_spec.cr`: exact declaration admission, 16-byte
   value and rendering (including mapped dotted-tail text),
   cross-mark/batch/catalog access, NULL versus `::`,
   UUID/numeric alias isolation, malformed metadata, truncated streams, and
   prepublication rejection. The failing signal must precede production edits.
3. Add a distinct IPv6 value type in `src/crystal_click/ipv6_value.cr` and
   require it in `src/crystal_click.cr`. Integrate exact reader dispatch in
   `src/crystal_click/wide_part.cr`, typed batch unions/accessors in
   `src/crystal_click/wide_part_table.cr`, and catalog materialization in
   `src/crystal_click/offline_catalog.cr`. No per-row heap string is needed
   for raw storage. Guard against interpreting IPv6 as UUID or UInt128.
4. Add named bare/nullable writer APIs and exact type dispatch in
   `src/crystal_click/wide_part_writer.cr`, including zero-filled nested
   NULL slots, staged self-readback, and rejection before stage creation.
5. Add IPv6 display or up-front rejection in
   `examples/offline_tui/page_source.cr`, with focused coverage in
   `spec/offline_tui_page_source_spec.cr`. A selectable column must not fail
   only when the first page is loaded.
6. Add `scripts/check_ipv6_oracle.sh`: independently constructed expected
   bytes, stock-to-Crystal and Crystal-to-stock `ATTACH PART`, exact metadata,
   streams and marks, full/key-range RowBinary, clean `CHECK TABLE`, and a
   same-size corruption negative control. Run W9-W18 type oracles, full
   debug/release specs, selected-column TUI spec and optional headless
   harness, formatter, shell syntax, and diff checks.

Definition of Done: both IPv6 shapes pass the pinned bidirectional oracle,
negative cases fail closed, full suites and earlier type oracles pass, and
the SDD records observed evidence and residual rejected surfaces. A green
self-readback alone is insufficient. If either direction or shape fails,
leave W19 in progress and make no paired compatibility claim.

Observed closure: the pinned `scripts/check_ipv6_oracle.sh` passed in both
directions for bare and BASIC Nullable IPv6, including independent byte/text
controls, full/key-range RowBinary, clean stock `CHECK TABLE`, and isolated
same-size corruption rejection. The full debug and release specs each passed
467 examples; W9-W18 type oracles, the focused page-source spec, and the
optional six-example headless TUI harness passed. Formatter, shell syntax,
and diff checks passed. This is a bounded physical compatibility result, not
general ClickHouse type, schema, key, or platform parity.
