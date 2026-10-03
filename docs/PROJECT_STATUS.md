# CrystalClick project status

Source checkpoint: shared writer extraction `571dc3c`, sparse-consumer Tuple
correction `9d87293`, W128 normalized whole-part checkpoint `1c5bab4`, and
the W129 bounded Object catalog integration in
[JSON_GENERAL_STORAGE_FRONTIER.md](JSON_GENERAL_STORAGE_FRONTIER.md).
Responsibility-level owner boundaries are documented in
[MODULARIZATION_FRONTIER.md](MODULARIZATION_FRONTIER.md).
Reviewed on 2026-10-02. This is a navigation summary, not a new compatibility
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
  declared typed fields are UInt64/String. Five fresh parts passed actual stock
  ATTACH/CHECK=1/full/PK SQL and explicit file-reader full/middle/zero windows.
  W129 separately adds bounded catalog Object materialization, not mixed
  table batch dispatch. See
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

1. **General JSON table API integration.** W117-W129 provide
   reusable type/value, bulk, structure, binding, transport, normalized Object
   reader, column writer and complete normalized whole-part owners. W128
   generates every pre-ATTACH file from owned inputs and has fresh stock
   qualification; W127's older shell-based oracle is not the whole-part
   certificate. The catalog now dispatches whole normalized JSON through
   `ObjectColumnReader`; the public mixed `WidePartTable` batch/window/PK
   adapter is still missing. Its older scalar typed-path behavior is unchanged.
   Neither adapter implies arbitrary JSON schemas or physical layouts. See
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
   Next are legacy shared schema/substream planning, physical
   I/O/validation, leaf codecs and thin table/catalog adapters. Keep one
   cohesive class per file rather than one new class per type combination.
2. Extend the qualified normalized Object catalog read path into mixed table
   batches, windows and PK candidate delivery, without silently widening
   layout or schema discovery. Object declaration admission also enforces
   the stock maximum of 1,000 typed paths regardless of caller codec limits.
3. Expand remaining paired type/profile and MV/projection frontiers.
   For MV/projections, prioritize declaration/dependency/TO-target inspection
   and compatible projection storage, not adding a SQL functions/joins engine.
4. Only then reopen memory/performance work. No current claim of stock-reader
   speed parity or a quantified percentage of complete ClickHouse support.

## Source reference

The newest separate shallow checkout is
`/Users/sergey/SrcArchives/clickhouse-2026-10-02-depth1-101871ba`, revision
`101871ba6da8221c7cf30ac3a04bc1063106f412`.
[CLICKHOUSE_SOURCE_REFERENCE.md](CLICKHOUSE_SOURCE_REFERENCE.md) records the
comparison and earlier identities. The serializer directory is unchanged
against `31d2addb`; Columns and MergeTree are not identical. No executable from
this newest checkout has been built or qualified.

This summary becomes stale when source admission, facade dispatch, the tested
runtime/profile or the architecture boundary changes. Refresh it from the
linked owners/frontiers and rerun the affected gates; do not promote a guard or
logical codec into full part support based on this summary alone.
