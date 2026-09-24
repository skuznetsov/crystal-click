# Offline Atomic Catalog Frontier

Document status: implemented and verified for the bounded public-fixture scope
below. This does not certify a live ClickHouse table snapshot.

This document records the original `UInt64` catalog slice. The subsequent
fixed-width primitive numeric scan is governed by
[`FIXED_NUMERIC_SCAN_FRONTIER.md`](FIXED_NUMERIC_SCAN_FRONTIER.md); it does not
change the offline candidate or server-state boundary described here.
The later bounded part-selection slice is governed by
[`OFFLINE_MERGETREE_PART_RESOLUTION_FRONTIER.md`](OFFLINE_MERGETREE_PART_RESOLUTION_FRONTIER.md);
the overlap rejection below records the original behavior, not that later API.
The synthetic offline `system.part_candidates` column projection is governed
separately by
[`OFFLINE_PART_CANDIDATE_VALUES_FRONTIER.md`](OFFLINE_PART_CANDIDATE_VALUES_FRONTIER.md);
the `system.*` exclusion below records the scope of this original catalog
slice.

Object-navigation extension (implemented for the bounded offline scope): expose
`catalog.databases` as sorted `OfflineDatabase` objects and targeted
`catalog.database(name)`. Each database object has its validated `name` and
`uuid`, plus `table_names`, targeted `table(name)`, and `tables` returning
`OfflineTable` objects. The database retains what it needs for later lookup;
callers need not keep the catalog variable alive. Table objects already retain
their parsed DDL, candidate paths, and scan methods. Enumeration of databases
does not eagerly parse every table or part. Enumerating `tables` is all-or-error
if any table fails validation, while targeted lookup must keep working for an
unrelated valid table. Existing name-based methods remain compatible. A
database object does not silently retarget to a different database UUID if
metadata changes between calls; it is bound to its originating catalog, but
this is not a live snapshot guarantee.

Targeted bracket navigation is admitted as syntax sugar:
`catalog[database_name]` is exactly `catalog.database(database_name)`, and
`database[table_name]` is exactly `database.table(table_name)`, including
typed errors and identity guards. A virtual `system` database and
`table[column_name]` are not admitted by this extension. The latter should
eventually return a data-bearing column handle, not merely parsed DDL metadata.
In that later API, `table[column_name].values` means all values of the selected
column in an owned, materialized collection; a separate iteration API should
serve large columns without forcing that materialization. Selection alone
must not silently read the entire column. The value type, allocation bound,
and semantics of virtual offline system tables require their own verified
frontier before this syntax is exposed.

Extension falsifiers: database objects retain their identity after the caller
drops the catalog reference; object and name-based lookups agree on table UUID,
columns, part candidates, and scans; malformed later table metadata does not
break targeted lookup but rejects `tables` without returning a partial array;
unsupported engines remain inspectable without fabricated part inventory;
`default` and escaped names retain the current path guards. The strongest
failure is resolving a table through a different UUID than the database object
originally represented. Verification uses focused public-fixture catalog
specs, full debug/release specs, formatting, and an example smoke run. Rollback
is the scoped feature commit. This extension does not admit `system.*` or server
Active-state inference.

Object navigation from a Crystal program:

```crystal
database = CrystalClick::OfflineCatalog.open(data_root).databases.first
database.tables.each do |table|
  puts "#{database.name}.#{table.name}: #{table.columns.size} columns"
end

table = CrystalClick::OfflineCatalog.open(data_root)["lab"]["events"]
puts table.engine
```

`databases` resolves every database DDL but not table DDL; a malformed sibling
database therefore fails enumeration while targeted `database(name)` still
works. `tables` resolves every table and its candidate inventory, while
targeted `table(name)` remains usable if a sibling table is malformed.

Extension verification: the new `databases` and then bracket navigation calls
were absent in red focused specs; after implementation, 29 focused catalog
examples and 229 full examples
in both debug and release passed on the final source. The inventory example
compiled and printed one database, one table, its UInt64 column, and an empty
physical-candidate inventory from a temporary Atomic root, using the host's
system-linker override and a writable temporary Crystal cache. Format and
diff checks passed. Adversary review found and closed cross-catalog object
reuse, UUID drift, and repeated enumeration paths. This is robust only for an
immutable, quiescent offline root; metadata
mutation during a call remains outside the contract.

Current frontier: read a bounded local ClickHouse Atomic metadata tree in
Crystal, expose database/table objects and names, table column names and
declared types,
and inventory physical MergeTree part candidates. For an unambiguous, immutable
single-disk table, hand selected `UInt64` columns to `WidePartTable` so caller
code can filter rows. This is an offline catalog, not the ClickHouse `system.*`
engine or an authoritative live table snapshot.

## Factual anchor and problem

The public ClickHouse `26.7.1.1315` local probe writes an Atomic database DDL
at `metadata/<database>.sql`, table DDL under the database UUID's
`store/<prefix>/<uuid>/` directory, and data under the table UUID's store
directory. `metadata/<database>` and `data/<database>/<table>` are convenience
symlinks. The pinned ClickHouse source at `066ea77c` confirms this path mapping
in `DatabaseCatalog.cpp`, `DatabaseAtomic.cpp`, and `DatabaseOnDisk.cpp`.

The present `WidePartTable` accepts explicit part paths only. The user needs a
Crystal entry point from an offline data root to table metadata, physical
part inventory, and a guarded scan without starting a ClickHouse server.

## Admitted surface

- Read-only `OfflineCatalog.open(data_root)` for a bounded local Atomic layout.
  Catalog names are decoded from ClickHouse-escaped metadata filenames. A
  database DDL supplies its UUID; the special built-in `default` database may
  instead use a validated in-root metadata symlink to a UUID store directory.
- Targeted database/table lookup reads bounded `.sql` DDL generated by the
  pinned ClickHouse version. It exposes table UUID, engine name, and column
  name/type pairs; it does not interpret defaults, expressions, codecs, or
  arbitrary SQL. Unrecognized DDL fails with a typed unsupported error.
  Lookups are targeted: this slice does not validate global UUID uniqueness
  across all database and table metadata files.
- Derive table data paths from the parsed UUID, not from `data/` convenience
  symlinks. For exact `MergeTree`, inventory immediate physical part directories
  with parsed part names and bounded `count.txt` row counts. Keep `detached`,
  temporary, and moving directories outside this candidate inventory. For an
  unsupported engine, keep DDL metadata inspectable but reject candidate
  inventory rather than returning a misleading empty set. Never call a
  candidate Active or Outdated.
- For exact `MergeTree` tables with zero pairwise overlap, scan selected
  `UInt64` columns through `WidePartTable`. An empty table yields no batches.
  Any overlap, unsupported selected column or physical format, malformed part,
  or ambiguous path fails closed before a data callback.
- Preserve distinct authority labels: DDL describes the table-level schema;
  `columns.txt` records per-part schema; directory presence identifies only a
  physical candidate. No equality of these layers is implied by names alone.

The original name-based API is `catalog.database_names`,
`catalog.table_names(database)`,
and `catalog.table(database, name)`. A targeted `OfflineTable` exposes parsed
metadata UUID, engine, declared columns, and `part_candidates`, then
`scan_uint64(columns, batch_rows: ...)` for the admitted physical scan.
Candidate entries include their parsed part-name fields and row counts, not
an `active` Boolean.

Example from a Crystal program:

```crystal
catalog = CrystalClick::OfflineCatalog.open("/path/to/clickhouse-root")
table = catalog.table("lab", "events")

table.columns.each { |column| puts "#{column.name}: #{column.type}" }
table.part_candidates.each { |part| puts "#{part.name}: #{part.row_count} rows" }

table.scan_uint64(["id", "value"], batch_rows: 256) do |batch|
  ids = batch.values_for("id")
  values = batch.values_for("value")
  ids.each_with_index do |id, index|
    puts "#{id}: #{values[index]}" if id > 100_u64
  end
end
```

The callback slices are borrowed and must not be retained after the callback.
Use an immutable, quiescent, single-disk data-root copy for this API.

Execution order: write a failing public-fixture spec; implement bounded
metadata discovery and DDL parsing; add candidate inventory; delegate guarded
scanning to `WidePartTable`; run focused and full checks; attack the result.
The code paths are `src/crystal_click/offline_catalog.cr`,
`src/crystal_click.cr`, and `spec/offline_catalog_spec.cr`. Risk is CAUTION
because an incorrect catalog mapping could read the wrong table. Rollback is
the single feature commit, not a rewrite of existing part readers.

## Rejected surface

- Querying or emulating virtual `system.*` tables, including server-derived
  Active/Outdated, replica/Keeper, mutation, transaction, or current SELECT
  state; SQL parsing/execution, joins, functions, and server connectivity.
- Non-Atomic database engines, non-`MergeTree` scans, secondary storage disks,
  remote/object storage, malformed or unrecognized DDL, and concurrent
  mutation/snapshot guarantees. A valid targeted lookup is not a whole-tree
  ClickHouse startup or catalog-consistency certificate.
- Choosing a covering part over covered parts, selecting a replacement by
  level or mutation suffix, or treating a non-overlapping on-disk set as proof
  of server Active status.

## Design laws and strongest failure

1. Bound every directory enumeration and metadata read. Reject traversal,
   unexpected symlinks, duplicate decoded names, invalid UUIDs, and paths
   escaping the supplied data root.
2. Resolve Atomic database and table store paths from validated UUIDs. The
   built-in `default` metadata symlink is only an observed pointer and must be
   canonical, in-root, and fail closed when malformed.
3. Enumerate before exposing a table inventory or yielding scan batches;
   do not silently omit part-like malformed entries.
4. Never infer Active from an on-disk name. ClickHouse keeps lifecycle state
   in memory and may use covering-part recovery, transaction state, secondary
   disks, and Keeper expectations. Same visible names can produce different
   server states.
5. A scan uses all admitted physical candidates only when no pair overlaps;
   it never chooses among conflicting candidates. The caller must provide a
   quiescent immutable local copy and accepts that separate metadata reads
   are not an atomic snapshot.

Strongest likely failure: an offline scan silently double-counts stale and
replacement parts, or labels stale data Active. Guard: expose candidates as
unknown-state observations and reject overlap before the first callback.

## Falsifier roster

| Probe | Required signal |
| --- | --- |
| Public Atomic database with populated and empty MergeTree tables | Names, UUID-derived paths, DDL columns, exact part counts, and direct Crystal `if` filtering agree with the fixture |
| Same-partition covering and covered directories | Both remain visible as candidates; scan rejects before any callback |
| Detached and temporary directories | Excluded with no Active inference |
| Poisoned metadata/store symlink, UUID, escaped name, or path | Typed failure; no path escapes the data root |
| Malformed later table/part metadata | Targeted lookup fails without a partial result; unrelated targeted tables remain inspectable |
| Unsupported engine or selected type | Metadata remains inspectable where structurally parsed; unsupported inventory or scan rejects rather than looking empty |
| Empty table | Columns remain visible from DDL and scan produces zero batches |

## Completion and decay

Observed DoD: focused catalog specs were red before implementation and pass
afterward (13 examples); full debug and release Crystal suites pass (167
examples each); formatting and diff checks pass. A separately generated public
ClickHouse 26.7 Atomic root yields the expected database/table names, nested
column types, one 8-row part candidate, and an 8-row two-column scan with
`value = id * 2` and sum 56. The adversary pass found and the regressions
closed escaped database-alias lookup, a silently omitted short malformed part
directory, a second `ENGINE` in a forged DDL suffix, and ClickHouse
`tmp-fetch_`/`delete_tmp_` recovery-directory handling. Overlapping parts
still reject before callbacks; the catalog does not report server Active state.

The suffix check is deliberately not a general SQL validator. Global UUID
uniqueness, secondary disks, and a consistent snapshot under concurrent
ClickHouse mutation remain outside this certificate.

Rollback is the single feature commit. Evidence decays when ClickHouse DDL or
Atomic path layout changes, the catalog parser or part discovery changes, or
the fixture producer version changes. Refresh against the pinned source and a
new public fixture before widening compatibility.
