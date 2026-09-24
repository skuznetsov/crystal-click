# Offline reader examples

These examples read local files under a ClickHouse data root (`metadata/` and
`store/`). They do not connect to a server, execute SQL, or provide a
server-consistent snapshot. Use an immutable, quiescent local copy.

List databases, tables, DDL columns, and physical part candidates:

```sh
crystal run examples/list_atomic_catalog.cr -- /var/lib/clickhouse
```

The example uses `catalog.databases` and each database's `tables` collection.
An `OfflineDatabase` retains its catalog context, so callers may keep the
database object after the original catalog variable goes out of scope. Each
enumeration validates its full level and fails if any sibling DDL is malformed;
use `catalog.database(name)` or `database.table(name)` for targeted access.
Targeted bracket aliases also work: `catalog["lab"]["events"]` returns an
`OfflineTable`.

Read all `rows` values from the synthetic offline `system.part_candidates` projection:

```sh
crystal run examples/read_offline_part_candidate_rows.cr -- /var/lib/clickhouse
```

`catalog["system"]["part_candidates"]["rows"].values` selects the `rows` column and
returns an owned, bounded collection of all physical part-candidate counts.
These are not ClickHouse server Active parts. The projection rejects
overlapping candidates and malformed metadata instead of returning a partial
collection. `system.tables` and `system.columns` are not implemented. In ClickHouse itself,
`system.tables` calls its row estimate `total_rows`; `rows` is a column of
`system.parts`.

Read one physical table column into an owned array:

```sh
crystal run examples/read_offline_column_values.cr -- /var/lib/clickhouse lab events left
```

`catalog["lab"]["events"]["left"].values` reads all values for a supported
stored column after selection. The result is bounded to 100,000 rows and
64 MiB of returned non-NULL String content; this does not bound total bytes
read, including nested bytes under NULL rows. Larger reads should use
`scan_typed`. Since the column type is selected at runtime, elements have the
`CrystalClick::OfflineColumnValue` union type; callers can cast an expected
`UInt64` value with `value.as(UInt64)`. Pass `max_rows:` or
`max_string_bytes:` to `.values` to request a smaller budget; values above
the hard ceilings are rejected.
Values follow the offline resolved-part and mark order, not SQL `ORDER BY`.
Whole JSON objects and computed `ALIAS` columns are not materialized.

On this macOS toolchain, Crystal's default LLD linker cannot parse the
installed Xcode TAPI SDK files. If that affects your setup, put
`--link-flags='-fuse-ld=ld'` before the source path, for example:

```sh
crystal run --link-flags='-fuse-ld=ld' examples/list_atomic_catalog.cr -- /var/lib/clickhouse
```

For exact `MergeTree` tables, the listed part directories are physical
candidates only. Their server `Active` state is unknown. Other engines show
DDL columns but do not expose part inventory through this reader.

Scan one table for an inclusive key range:

```sh
crystal run examples/scan_uint64_pk_range.cr -- /var/lib/clickhouse lab events pk value --lower 100 --upper 200
```

Bounds are optional individually and inclusive; supply at least one. For
example, a lower-only scan is:

```sh
crystal run examples/scan_uint64_pk_range.cr -- /var/lib/clickhouse lab events pk value --lower 100
```

The selected key and value columns must both be exact `UInt64` columns, and
the key must be the table's one supported ascending `UInt64` `ORDER BY` key.
The reader selects whole candidate granules from adaptive Wide parts
(`.mrk2`/`.cmrk2`); the example applies the exact inclusive row predicate
before printing each row. Candidate pruning is not a SQL result or proof that
the files represent the server's current table.

The reader is read-only and supports only its bounded Atomic metadata and
physical-part subset. It does not handle arbitrary SQL, composite or
descending keys, legacy fixed-granularity Wide marks, Compact parts, or
secondary/remote storage. The primary-index path relies on immutable
ClickHouse-produced parts; it does not verify content hashes.
