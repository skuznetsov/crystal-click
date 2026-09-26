# W11 Nullable(FixedString(N)) reader/writer plan

Status: verified within the stated pinned W11 scope. Contract:
`EMBEDDED_MERGETREE_FRONTIER.md`, W11.
Risk: CAUTION (new typed grammar, two-stream serialization, public writer
entry point). Rollback: one W11 feature commit only after the declared DoD;
keep the clean W10 commit as the return point and preserve W9/W10 APIs.

Factual anchor: W10 reads/writes one-stream `FixedString(N)`; W9 handles
BASIC Nullable numeric and variable `Nullable(String)`. The pinned ClickHouse
26.7.1.1315 executable reports BASIC Nullable and WITH_SIZE_STREAM global
String serialization settings. Current ClickHouse source shows a null map
plus `N` nested bytes per row, including a zero-filled slot under NULL.
The source checkout is newer than the pinned executable, so only an actual
pinned part and attach oracle can certify the physical shape.

Inventory: a bounded search for `supports_nullable_string_type?`,
`read_nullable_string_mark_range`, `nullable_strings_for`,
`write_uint64_typed_pair`, `typed_substreams_metadata`, and
`typed_serialization_metadata` finds the relevant consumers in
`src/crystal_click/wide_part.cr`, `wide_part_table.cr`, `offline_catalog.cr`,
and `wide_part_writer.cr`, plus their specs. Keep `Nullable(String)` exact;
the same Crystal `String?` type cannot infer the new ClickHouse type.

1. Add RED reader specs in `spec/nullable_fixed_string_scan_spec.cr` for
   exact grammar, two-stream shape, values and null-map rejection; add RED
   writer specs in `spec/wide_part_writer_nullable_fixed_string_spec.cr` for
   an explicit-width API, zero placeholders and no-publish failures.
2. Extend `WidePart`, `WidePartTableBatch`, `WidePartTable`, and
   `OfflineCatalog` for the exact W11 type and a distinct nullable-fixed
   accessor. Preflight `rows * N` (including NULLs), <=64 MiB raw bytes and
<=65,536 values before allocation; reject unknown serialization versions,
malformed null flags, unequal marks, and extra `.size` streams. Preserve
ClickHouse's version-0 defaults for omitted per-type entries while requiring
the versions object itself.
3. Add `WidePartWriter.write_uint64_nullable_fixed_string_pair` with
   explicit width. Reuse fixed-width stream, BASIC null map, staged checksums,
   self-read and exclusive publish; reject overwidth and oversized mark inputs
   before staging, and write `N` zero bytes beneath every NULL.
4. Add `scripts/check_nullable_fixed_string_oracle.sh`: build an isolated
   stock ClickHouse part and read it with Crystal; attach a Crystal part and
   compare full/key-range null flags and hex bytes, then require `CHECK TABLE`
   and a corruption negative. Re-run W9 and W10 oracles as regression guards.

DoD: focused RED-to-green specs; full Crystal debug and release suites;
`crystal tool format --check`, shell syntax and `git diff --check`; pinned W11
differential oracle and W9/W10 guards all pass. The strongest likely failure
is a self-consistent Crystal null/bytes mapping rejected by stock ClickHouse;
the stock-generated read plus `ATTACH PART`/`CHECK TABLE` are mandatory.
The external oracle tests `N=3` only; other widths remain bounded by local
grammar/resource tests, not a blanket stock compatibility claim.

Closure evidence: 366 debug and 366 release examples passed; format, shell
syntax, and diff checks passed. The pinned stock-to-Crystal and
Crystal-to-stock `N=3` oracle passed with exact two-stream marks, NULL and
byte values, `ATTACH PART`, `CHECK TABLE`, two corruption negatives, invalid
null flag, and all-NULL control. W9/W10 regression oracles passed. Adversarial
review found no blocking code issue within this scope; staged Crystal
selected-entry validation is size-only, so external `CHECK TABLE` supplies
the independent content-integrity check.
