# Embedded table and offline reader examples

Create, insert into, merge, reopen, and scan a bounded Crystal-owned table:

```sh
crystal run examples/embedded_merge_tree_table.cr -- /tmp/my-new-crystal-click-table
```

Choose a destination outside any ClickHouse server data root; the destination
must not exist. The example leaves the table on disk for inspection. This is
not a ClickHouse server data root or a mutable
`OfflineCatalog` table. The experimental table currently supports only one
sorted `UInt64` key, one `String` value, and the `all` partition. The example
inserts two interleaved parts and logically merges them; the scan returns each
row once in key order because only the merged part remains active. A table
scan over multiple active parts does not generally promise global key order.
A published part becomes visible only after its commit
marker appears. Merge retains old physical parts and markers but selects the
new covering part for reads; orphans are not read. On a Crystal-owned table,
call `table.reclaim_obsolete!` explicitly to remove covered history and stale
writer stages. It keeps active parts and uncovered unmarked parts, which still
reserve block numbers or merge levels. This operation must not be used on a
ClickHouse server data root. `part_paths` is an instantaneous inventory, not a
file-lifetime lease once reclamation is possible; use `with_part_paths` when
passing paths to a direct reader, or use `scan_typed`, which pins its scan
through callbacks. Those callbacks must not reenter a table write. Commit
markers provide process-level atomicity, not power-loss durability,
exactly-once retries, or a server `Active` state.

For a bounded inclusive range on that table's `UInt64` key:

```sh
crystal run examples/scan_embedded_merge_tree_pk_range.cr -- /tmp/my-new-crystal-click-table --lower 2 --upper 4
```

Either bound may be omitted. The typed candidate API returns whole physical
granules with `UInt64` keys and `String` values, not only rows that match the
range. The example applies the exact residual predicate before printing;
callers must do likewise. It prunes by the primary index of each active part,
so output across multiple active parts is not necessarily globally sorted.
The scan holds the table's shared lock through callbacks, preventing explicit
GC by cooperating processes from deleting its parts during iteration. It
checks each active `primary.idx` against its recorded physical-file hash
before callbacks. This detects an isolated index change while `checksums.txt`
remains intact; it does not verify other part files or defend against a
coordinated rewrite of both files. Callers must still use immutable,
writer-produced parts. No speedup is promised.

## Read-only ClickHouse data-root examples

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

Read a bounded physical-row window from two `UInt64` columns without
materializing the complete table:

```sh
crystal run examples/read_typed_window.cr -- /var/lib/clickhouse lab events left right 8190 5
```

`scan_typed_window` also supports the existing typed `String`, nullable, and
numeric column readers; this example uses `UInt64` accessors for compact
output. `START_ROW` is zero-based in resolved part/mark order, not SQL order.
The window is at most 4,096 rows, and its callbacks expose borrowed slices
that must be copied if retained. The current implementation still decodes
whole intersecting marks, so this is a bounded *result* API, not row-level
lazy decoding or a performance claim. It requires the same immutable,
quiescent copy and overlapping-part rejection as other offline scans.

Browse a local catalog and page through physical MergeTree rows with the
optional `crystal_tui` example. Keep `crystal_tui` checked out separately and
point `CRYSTAL_PATH` at its `src` directory; the core shard has no TUI
dependency:

```sh
CRYSTAL_PATH="/path/to/crystal_tui/src:$(crystal env CRYSTAL_PATH)" \
  crystal run examples/offline_tui/main.cr -- /path/to/immutable/clickhouse-data-root
```

Choose a database with Enter to load its table names, then choose a table with
Enter. Tab switches focus between the tree and the page; PageDown/PageUp move
by one bounded physical window, and `q` or Ctrl+C quits. From the page pane,
`/` opens a filter input: enter `column=value` to compare one selected direct
`String` or `UInt64` column, press Enter to apply, or Escape to cancel.
`String` values preserve accepted characters after the first `=`, including
spaces and more `=` characters; `UInt64` values use unsigned decimal. Press
`c` in the page pane to clear the filter. While editing, `q` is text, not the
quit command, and Tab keeps the input focused. The interactive expression is
limited to 512 bytes and rejects terminal controls and a defined set of
invisible Unicode formatting characters; it does not normalize lookalike
characters. The pane shows at most 256 owned rows from up to 16 directly
supported typed columns. Omitted columns are reported, not silently decoded.
`Date` and `Date32` cells display their lossless raw epoch-day codes, not
formatted calendar dates; neither is an equality-filter type in this example.
Non-NULL Strings are quoted and escaped; only their first 256 source bytes are
retained for display. Longer values carry a `[truncated]` prefix. Equality
uses raw typed values, not truncated display text. Each filtered page examines
one bounded *physical* window, so it may show no matching rows even though
later windows have matches. PageDown still advances through those windows. Row
offsets follow the resolved physical part order; these candidates are **not**
ClickHouse server Active parts. The example does not provide global sorting,
match counts, primary-key pruning for this equality filter, or a snapshot of a
live server. Keep the data root
immutable while browsing: a newly added part may remain invisible because the
inventory was captured when the table was opened. It still decodes whole
intersecting marks and reopens reader metadata on page requests, so no speedup
or memory-use claim is implied.

The opt-in headless UI check needs the same `CRYSTAL_PATH`:

```sh
CRYSTAL_PATH="/path/to/crystal_tui/src:$(crystal env CRYSTAL_PATH)" \
  crystal spec examples/offline_tui/spec/browser_spec.cr
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
