# CrystalClick project status

Source checkpoint: `9ca6a6b`, plus the behavior-preserving shared writer
infrastructure extraction documented in [MODULARIZATION_FRONTIER.md](MODULARIZATION_FRONTIER.md).
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
- `OfflineCatalog`: disk-based Atomic metadata discovery, database/table/
  column objects and part candidates. `catalog[db][table][column].values`
  explicitly materializes a bounded owned column; it is not a lazy result.
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

1. **Complete general JSON parts and table API integration.** W117-W127 provide
   reusable type/value, bulk, structure, binding, transport, normalized Object
   reader and unpublished column writer owners. W127 creates fresh JSON column
   files/statistics, but its stock whole-part oracle borrows surrounding part
   metadata from a matching stock-generated shell. It does not prove that the
   library creates a complete general JSON part. The public table facade still
   admits only the older scalar typed-path JSON profile; it does not dispatch
   through `ObjectDocumentFileReader`. See
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

1. Continue behavior-preserving decomposition: shared encoding/checksums and
   staging/publication first, then explicit schema/substream planning, physical
   I/O/validation, leaf codecs and thin table/catalog adapters. Keep one
   cohesive class per file rather than one new class per type combination.
2. Introduce an explicit reusable JSON schema owner and whole-part metadata
   composer with table/PK/granularity/partition context. Emit every required
   pre-ATTACH file from library-owned inputs; borrow no stock part sidecars.
   Gate on actual stock ATTACH/CHECK=1 and exact full/PK/window reads.
3. Wire the qualified normalized Object reader/writer into the table/catalog
   facade without silently widening layout or schema discovery.
4. Expand remaining paired type/profile and MV/projection frontiers.
   For MV/projections, prioritize declaration/dependency/TO-target inspection
   and compatible projection storage, not adding a SQL functions/joins engine.
5. Only then reopen memory/performance work. No current claim of stock-reader
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
