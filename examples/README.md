# Offline reader examples

These examples read local files under a ClickHouse data root (`metadata/` and
`store/`). They do not connect to a server, execute SQL, or provide a
server-consistent snapshot. Use an immutable, quiescent local copy.

List databases, tables, DDL columns, and physical part candidates:

```sh
crystal run examples/list_atomic_catalog.cr -- /var/lib/clickhouse
```

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
