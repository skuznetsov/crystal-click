# CrystalClick project status

Source checkpoint: shared writer extraction `571dc3c`, sparse-consumer Tuple
correction `9d87293`, W128 normalized whole-part checkpoint `1c5bab4`, and
the W129 bounded Object catalog integration, W130 mixed table delivery
`4b18812`, W131 declared Int64 `02dd99f`, W132 paired numeric declared
fields `e043be7`, W133 paired declared Date/Date32 `2e150f4`, W135
paired bare declared UUID/IPv4/IPv6 `ffa5730`, W136 paired bare
declared FixedString(N) `700d5b8`, W137 canonical bare declared
Decimal(P, S) `73914c8`, and W138 canonical bare declared Enum8/Enum16 over
that checkpoint in
[JSON_GENERAL_STORAGE_FRONTIER.md](JSON_GENERAL_STORAGE_FRONTIER.md).
W134 extracts nine existing Array/Map row/slice owners to separate files,
preserving their exact bodies and API. Root passed 22 focused DEBUG, 37 adjacent
RELEASE and 2,242 complete-inventory examples (353 unique specs, 15 disjoint
non-release groups), plus a fresh unchanged W133 stock regression. This is
bounded behavior-preserving extraction, not full facade modularization.
The executed certificate and responsibility-level owner boundaries are in
[MODULARIZATION_FRONTIER.md](MODULARIZATION_FRONTIER.md).
W136 root gates pass 52 focused DEBUG, 177 adjacent RELEASE and 2,260
complete-inventory examples (357 unique specs in 15 disjoint non-release
groups), plus the eight-cell FixedString stock oracle and fresh unchanged
UUID/IP, Date and numeric regressions. Its scoped hostile verdict is ROBUST
in the JSON frontier; the full-inventory result is not a combined-process run.
W137 root gates pass 61 focused DEBUG, 186 adjacent RELEASE and 2,269
complete-inventory examples (359 unique specs in 15 disjoint non-release
groups). Its fresh eight-cell Decimal stock matrix passes exact nominal
types, scale-preserving text, independent RowBinary, actual CHECK for all
cells and ATTACH for the four library-owned parts. The JSON frontier retains
the complete gate record and residual scope; schema coverage of all 3,002
legal precision/scale pairs is not exhaustive physical part qualification.
W138 root gates pass 72 focused DEBUG, 197 adjacent RELEASE and 2,280
complete-inventory examples (361 unique specs in 16 disjoint non-release
groups). Eight fresh native/library Enum cells pass nominal maps, labels,
literal signed RowBinary, actual CHECK and four library ATTACH operations;
an independent Ruby checker rechecks all eight stores without Crystal codecs.
Five fresh unchanged neighboring stock oracles pass. Full-width map admission
(256/65,536 entries) is schema evidence, not exhaustive physical-map coverage.
Reviewed on 2026-10-03. This is a navigation summary, not a new compatibility
certificate; the linked frontier documents retain their tested profiles,
source/runtime identities and executed evidence.

## What is usable now

- `WidePart` and `WidePartTable`: selected-column and typed reads, including
  windowed delivery. The public contracts admit explicit physical profiles,
  not arbitrary ClickHouse parts or recursive type combinations.
- Paired part readers/writers cover broad primitive, String/FixedString,
  Nullable, Enum, Decimal, identifier, temporal, container and geometry
  families, including QBit and several LowCardinality/Variant/Dynamic profiles.
  Exact supported declarations, wrappers and layouts are in
  [EMBEDDED_MERGETREE_FRONTIER.md](EMBEDDED_MERGETREE_FRONTIER.md) and its
  linked family frontiers. A supported scalar does not imply every container
  or serialization profile containing it.
- `WidePartWriter.write_uint64_object_pair`: a complete standalone normalized
  JSON/Object part from library-owned keys, explicit schema/rosters and
  documents, without borrowed stock sidecars. W128 qualifies hashed Wide,
  Object V3/Dynamic V3, one-bucket shared MAP, LZ4 and plain adaptive marks;
  W128 declared typed fields are UInt64/String. Five fresh parts passed actual
  stock ATTACH/CHECK=1/full/PK SQL and explicit file-reader full/middle/zero windows.
  W129 adds bounded catalog Object materialization; W130 adds the separately
  qualified mixed typed-table reader. Neither widens the writer to multiple
  Object columns or arbitrary schemas. W132 admits declared UInt8/16/32/64/128/256,
  Int8/16/32/64/128/256, Float32/64, Bool and String through those same owners.
  Four fresh native and four library-owned parts pass actual CHECK/full/PK SQL,
  independent numeric RowBinary and file/column/catalog/table consumer checks,
  including float signed zero, infinity and NaN payloads. Bool is nominally
  distinct from UInt8; logical writes canonicalize true to byte 1. BFloat16 is
  excluded by the measured stock Object schema gate. String 0/1 × BASIC/COMPACT
  is qualified in both directions; this is still normalized Object V3/MAP,
  not arbitrary JSON. W133 adds bare declared Date/Date32 through the same
  writer and public consumers: eight fresh native/library matrix cells pass
  calendar/day-code/type/byte checks, actual CHECK and exact RowBinary; two
  separate raw Date32 extrema cases qualify transport only, not calendar range.
  W135 adds bare declared UUID/IPv4/IPv6 through the same fixed-value and
  bulk owners. Eight fresh native/library cells pass actual CHECK (and
  ATTACH for library-owned parts), canonical text, nominal SQL types,
  independent literal RowBinary and public file/column/catalog/table consumers.
  Twelve seeded comparator
  controls reject byte/order, same-width nominal, serializer, grid and CHECK
  mismatches. UUID remains distinct from UInt128/IPv6, and IPv4 from UInt32.
  W136 adds canonical bare declared FixedString(N), retaining N as nominal
  identity and using existing exact-width payload/bulk owners. The schema
  admits N=1..16777215; stock part qualification covers N=1/3/16/17/31/257
  across eight fresh native/library cells, with exact bytes, padding, UTF-8
  byte lengths, actual CHECK and public consumer/PK checks. N>256 requires
  the server's suspicious-type opt-in; maximum-N evidence is schema-only.
  Library raw inputs require exactly N bytes, without implicit text padding.
  W137 adds canonical bare Decimal(P, S), P=1..76 and S=0..P, through the same
  fixed-value/bulk, writer and public consumers. All 3,002 legal schema pairs
  pass constructor/parser checks; independent stock qualification samples
  nine P/S witnesses across all four storage widths in eight fresh cells.
  Raw signed coefficients, precision, scale and width stay exact; this is
  storage interoperability, not Decimal arithmetic/conversion/rounding.
  W138 adds canonical bare Enum8/Enum16 with exact width and complete
  label/code-map identity, all eight canonical escapes and opaque label bytes.
  Existing fixed-value/bulk owners provide paired writer/reader transport;
  stock part evidence covers seven-entry maps with signed extrema across the
  same eight cells. Same-width integer aliases and changed maps are not equal.
  Full 256/65,536-entry maps remain eligible with sufficient logical budgets.
  The shared declared-field policy now admits 21 static nominal types plus
  the FixedString, Decimal and Enum parameterized families. See
  [the example](../examples/write_object_document_part.cr) and
  [the qualified frontier](JSON_GENERAL_STORAGE_FRONTIER.md).
- `OfflineCatalog`: disk-based Atomic metadata discovery, database/table/
  column objects and part candidates. `catalog[db][table][column].values`
  explicitly materializes a bounded owned column; it is not a lazy result.
  Normalized whole-JSON columns now return owned `ObjectDocument` values
  within the W129 declaration/layout profile, with aggregate cross-part
  logical, row, String and recursive-cell limits. That accounting is not an
  RSS or pre-decode transient-memory ceiling. See
  [read_object_catalog.cr](../examples/read_object_catalog.cr).
  W130 separately admits selected normalized Object roots, alone or mixed
  with existing typed columns, through full batches, physical windows and
  bounded UInt64-PK candidate delivery. More than one selected Object root
  is kept separately bound. `batch.object_documents_for(column)` exposes
  callback-scoped slices of immutable retainable document handles. See
  [read_object_table.cr](../examples/read_object_table.cr).
  Synthetic `catalog["system"]["part_candidates"]["rows"].values` is supported;
  these are candidates, not server-proven Active parts or the real `system.*`
  tables. See [OFFLINE_CATALOG_FRONTIER.md](OFFLINE_CATALOG_FRONTIER.md) and
  [OFFLINE_PART_CANDIDATE_VALUES_FRONTIER.md](OFFLINE_PART_CANDIDATE_VALUES_FRONTIER.md).
- Primary-index granule pruning is available for the bounded UInt64 key
  profile. Candidate scans deliver complete selected granules; application
  code must apply the exact residual predicate. See
  [PRIMARY_KEY_GRANULE_PRUNING_FRONTIER.md](PRIMARY_KEY_GRANULE_PRUNING_FRONTIER.md).
- `EmbeddedMergeTreeTable`: a Crystal-owned experimental table with one
  UInt64 key, one String value and the `all` partition; insert, reopen, merge,
  candidate scans and explicit reclamation. Its process-atomic commit-marker
  protocol is not a ClickHouse server data-root lifecycle or power-loss
  durability guarantee. See [examples/README.md](../examples/README.md).

## Important remaining boundaries

1. **General JSON compatibility.** W117-W138 provide
   reusable type/value, bulk, structure, binding, transport, normalized Object
   reader, column writer and complete normalized whole-part owners. W128
   generates every pre-ATTACH file from owned inputs and has fresh stock
   qualification; W127's older shell-based oracle is not the whole-part
   certificate. The catalog now dispatches whole normalized JSON through
   `ObjectColumnReader`, and W130 integrates that bounded profile into public
   mixed `WidePartTable` batches/windows and UInt64 PK candidates. W132 admits
   the numeric primitive family, Bool and String declared fields with paired
   stock evidence; W133 adds bare Date/Date32 with independent calendar and
   signed raw-carrier checks; W135 adds bare UUID/IPv4/IPv6 with independent
   text, nominal and byte-order evidence; W136 adds canonical bare
   FixedString(N) with bounded parameter grammar and independent fixed-byte
   evidence; W137 adds canonical bare Decimal(P, S) with exact persisted P/S
   identity and independent signed coefficients; W138 adds canonical bare
   Enum8/Enum16 with nominal full-map and independent label/signed-byte checks.
   Other temporal and recursive declared-field families remain open within
   Object, even where standalone part support exists. The older scalar typed-path behavior is
   unchanged. Neither adapter implies arbitrary
   JSON schemas or physical layouts; Default serialization metadata is still
   required, and whole-Object projection child reads remain refused. See
   [JSON_GENERAL_STORAGE_FRONTIER.md](JSON_GENERAL_STORAGE_FRONTIER.md).
2. **Additional physical profiles and recursive composition.** Normalized
   Wide/SUFFIX Object V3 with explicit rosters and one-bucket MAP is not general
   JSON/Dynamic compatibility. Bucketed/advanced layouts, other structure
   versions, Compact parts and unqualified wrapper/container combinations need
   their own paired evidence. Existing logical binary codecs alone do not
   widen public part admission. Generic Variant arms, shared Nested offsets,
   AggregateFunction state serialization and SimpleAggregateFunction alias
   canonicalization remain unqualified; aggregate states and aliases are not
   interchangeable capabilities.
3. **MV/projection coverage.** Offline declaration metadata and explicit reads
   of fully covered physical Wide projection child parts are available. The
   persisted MV materializer is one explicit-TO identity projection over
   unpartitioned `k UInt64, v String`. General MV execution, projection
   planning/writing and arbitrary MV transformations are not implemented.
4. **General table writing.** The detached-part writers and small
   `EmbeddedMergeTreeTable` are not an arbitrary-schema, arbitrary-partition
   MergeTree writer with compound keys and a server lifecycle.
5. **Responsibility-level architecture.** The reader/writer/table facades remain
   large. Individual new owners have separate files, but the overall refactor
   is unfinished. File count alone does not prove lower coupling.

## Next implementation order

1. Continue behavior-preserving decomposition. Shared VarUInt/checksums,
   primary index and staging/publication have separate owners; the new Object
   schema, metadata, whole-part orchestrator and catalog materialization
   owners also have separate files.
   W134 moved the nine existing inline Array/Map payload/row classes from
   `wide_part_table.cr` into nine separate files, preserving public names,
   generic signatures, retained ownership and limits. The remaining facade
   is 6,786 lines; the reader/writer remain 15,985/25,991 lines.
   Next remain legacy shared schema/substream planning, physical
   I/O/validation, leaf codecs and thin table/catalog adapters. Keep one
   cohesive class per file rather than one new class per type combination.
2. Extend paired Object declared fields beyond numeric primitives/Bool/String,
   bare Date/Date32, UUID/IPv4/IPv6, FixedString(N), Decimal(P, S) and Enum8/Enum16.
   The next proposed lanes are parameterized temporal and recursive declared
   fields, not yet admitted Object support. Reuse existing leaf owners only
   after bounded declaration parsing, semantic parameter identity and
   independent physical qualification.
   Require independent native and library parts, asymmetric bytes/RowBinary
   and actual stock CHECK.
   Address parameterized/recursive field grammar and semantic identity, then
   widen layouts with their own stock-generated and library-owned evidence.
   Object declarations retain the stock maximum of 1,000 typed paths.
3. Expand remaining paired type/profile and MV/projection frontiers.
   For MV/projections, prioritize declaration/dependency/TO-target inspection
   and compatible projection storage, not adding a SQL functions/joins engine.
4. Only then reopen memory/performance work. No current claim of stock-reader
   speed parity or a quantified percentage of complete ClickHouse support.

## Source reference

The newest separate shallow checkout is
`/Users/sergey/SrcArchives/clickhouse-2026-10-03-depth1-f86ca42b`, revision
`f86ca42b6e90eadb97f7481638ff04ca1ee8e71f`.
[CLICKHOUSE_SOURCE_REFERENCE.md](CLICKHOUSE_SOURCE_REFERENCE.md) records the
comparison and earlier identities. Root's recursive comparisons against
`101871ba` found identical DataTypes/Serializations, DataTypes and Columns;
MergeTree differs in 34 files. No executable from
this newest checkout has been built or qualified.

This summary becomes stale when source admission, facade dispatch, the tested
runtime/profile or the architecture boundary changes. Refresh it from the
linked owners/frontiers and rerun the affected gates; do not promote a guard or
logical codec into full part support based on this summary alone.
