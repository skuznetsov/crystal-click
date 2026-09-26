# W14 nullable raw date/time reader/writer plan

Status: completed on the pinned W14 frontier. Contract:
`EMBEDDED_MERGETREE_FRONTIER.md`, W14. Risk: CAUTION (semantic type
dispatch and persistent two-stream serialization). Rollback: one local W14
feature commit only after the gate passes; otherwise revert only W14-owned
paths. No push or mutation of an existing ClickHouse data root.

The W13 reader and writer preserve raw `Date`, `Date32`, `DateTime`, and
canonical `DateTime64(0..9)` codes. The W9 reader/writer already support
BASIC `Nullable` primitive numbers with a separate null-map stream and a
nested value stream. The missing capability is the exact semantic wrapper,
not another integer representation. The stock ClickHouse probe must first
confirm that this codec and its marks apply to the four proposed temporal
types; matching source-code shape alone is insufficient. That probe now
confirms exact `.null`/nested substreams, zero nested placeholders under NULL,
plain adaptive `.mrk2` rows `4,4,1` plus sentinel, byte-exact RowBinary for
NULL/zero/extrema, and `CHECK TABLE=1` for the pinned build. The stock
`serialization.json` contains only a key column record, plus version 1,
`types_serialization_versions:{"string":1}`, and nested-version propagation;
it has no temporal column records. Reverse compatibility was tested by the
independent W14 oracle, which attached Crystal-written parts for every tested
concrete type.

1. Probe isolated stock ClickHouse 26.7.1.1315 Wide/LZ4 parts with NULL,
   zero, extrema, multiple marks, and a short tail. Record
   `serialization.json`, `columns_substreams.txt`, stream names, marks,
   nested NULL placeholders, exact RowBinary input/output, and `CHECK TABLE`.
   If the shape differs, revise the W14 contract before source changes.
2. Add failing reader specs for exact metadata, raw optional codes across
   marks, null/zero distinction, primitive-accessor alias rejection,
   malformed null flags, and noncanonical/timezone type rejection. Then
   implement the bounded reader and typed batch/table/catalog dispatch in
   `src/crystal_click/wide_part.cr`, `wide_part_table.cr`, and
   `offline_catalog.cr`. Nullable temporal accessors must be named for
   their semantic type, with DateTime64 precision retained.
3. Add failing writer specs for four explicit nullable temporal entry points,
   precision/shape preflight, staging cleanup, and semantic reread. Then
   implement them in `src/crystal_click/wide_part_writer.cr`. Inferred
   nullable numeric slices remain numeric; no implicit reinterpretation.
4. Extend `examples/offline_tui/page_source.cr` and its focused spec to
   display NULL or raw codes, with an explicit precision label for
   DateTime64. Do not widen the current UInt64/String equality filters.
   Add a pinned `scripts/check_nullable_temporal_oracle.sh` proving stock
   parts read by Crystal and Crystal parts attached by stock ClickHouse,
   including byte-exact full/key-range RowBinary, `CHECK TABLE`, and seeded
   same-size corruption of both physical streams. Update
   `examples/README.md` only for the admitted display behavior.

DoD: RED-to-green focused specs; full debug and release Crystal suites with
`--link-flags='-fuse-ld=ld'` and separate caches; `crystal tool format
--check`, `bash -n`, `git diff --cached --check`; W14 pinned differential
oracle and W9-W13 oracle controls pass. Build the optional TUI and run its
headless suite. Adversarially check NULL versus raw zero, exact semantic
aliases, p=0/3/9, rejected timezone/noncanonical metadata, malformed
null-map/nested stream bytes, and absence of a destination after failed
publication. Crystal self-read alone cannot establish ClickHouse writer
compatibility. Claim scope stays pinned to the tested build, Wide/LZ4/plain
adaptive marks, fixtures, and Darwin publication. Refresh if nullable
dispatch, date/time codecs, part framing, or pinned ClickHouse changes.

Observed closure: focused reader/catalog, writer, and TUI specs passed after
their RED gates. A separate RED probe exposed acceptance of a missing or
unsupported `string` serialization version; the narrowed W14 reader guard
rejects these metadata variants. The full debug and release Crystal suites
each passed 405 examples. The pinned W14 oracle passed stock-to-Crystal and
Crystal-to-stock for Nullable Date, Date32, DateTime, and DateTime64 at
precisions 0, 3, and 9, including exact physical streams/marks and raw
NULL/zero/extrema, full/key-range RowBinary, `ATTACH PART`, `CHECK TABLE`,
and independent same-size corruption rejection on the null and nested
streams. W9-W13 differential controls passed, as did the headless TUI suite,
linked example build, formatting, shell syntax, and whitespace checks. The
oracle tests only p=0/3/9, not every intermediate precision; the parser and
writer use the same canonical fixed-width path for all p=0..9. All guard-only
surfaces in the W14 contract remain outside this closure.
