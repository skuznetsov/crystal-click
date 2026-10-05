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

## Write and read a standalone typed Wide part

This example writes a `UInt64` key and a `Decimal32(2)` payload, then reads the
raw scaled integers back through the typed reader:

```sh
crystal run examples/write_w15_decimal_part.cr -- /tmp/my-new-decimal-part
```

Choose a destination that does not exist and is outside any ClickHouse data
root. The writer does not insert into a table or attach the part to a server.
`Decimal32(2)` is stored as signed `Int32` values scaled by 100; its part
metadata uses ClickHouse's canonical `Decimal(9, 2)` spelling. The paired W15
writer also has named Bool and Enum8/16 entry points, each with a BASIC
Nullable form. Enum entry points require an explicit label/code declaration;
ordinary signed-integer writes do not infer an Enum or Decimal type. The
separate `write_uint64_json_typed_paths` API now writes explicitly declared
scalar String/numeric JSON paths with caller-normalized defaults. It does not
preserve path presence or accept dynamic/shared JSON data; see the
[JSON typed-path frontier](../docs/JSON_TYPED_PATH_FRONTIER.md).

Write and lazily read exact scalar `Point` values:

```sh
crystal run examples/write_point_part.cr -- /tmp/my-new-point-part
```

The example writes one sorted UInt64 key and one exact Point payload, then
prints each coordinate's IEEE bits by mark, including negative zero, NaN and
infinity. It preserves the `Point` declaration rather than exposing an unnamed
Tuple. Choose a new standalone destination outside a live server data root.
The bounded profile is Wide/LZ4, Default serialization and plain adaptive marks;
Geo arrays, Nullable Point and general Geometry are not admitted by this API.
Lazy delivery has eager structural validation of all selected mark boundaries
before the first callback; it is not a promise of zero selected preflight I/O.
See the [Geo frontier](../docs/GEO_TYPES_FRONTIER.md) for exact qualification.

Write and read a standalone `SimpleAggregateFunction(sum, UInt64)` part:

```sh
crystal run examples/write_simple_aggregate_part.cr -- /tmp/my-simple-aggregate-table/all_1_1_0
```

Create the parent directory first and choose a new destination outside any
ClickHouse server data root. This example writes raw UInt64 storage values
and preserves the exact function declaration; it does not execute `sum`,
merge aggregate values or attach the part to a server. The paired APIs admit
nine explicit unary, non-parametric UInt64 functions and their outer Nullable
forms. Other carriers/functions remain closed. See the
[SimpleAggregateFunction frontier](../docs/SIMPLE_AGGREGATE_FRONTIER.md).

Write and read a ragged `Array` of recursively named Tuple elements:

```sh
crystal run examples/write_array_tuple_part.cr -- /tmp/my-new-array-tuple-part
```

This example includes an empty outer row, a nested `Nullable(String)` leaf,
and distinct logical NULL/empty-String values. The writer takes outer row
sizes separately from flattened leaf buffers. It creates a standalone
Wide/LZ4/String-v1/plain-mark part with one sorted UInt64 key and one payload;
it does not insert into a server table. Total outer rows and flat elements
are each capped at 65,536 for staged readback. Use a new destination outside
any ClickHouse data root. See the paired profile and exclusions in the
[Array(Tuple) frontier](../docs/ARRAY_TUPLE_COMPOSITION_FRONTIER.md).

## Write a complete normalized JSON/Object part

```sh
crystal run examples/write_object_document_part.cr -- /tmp/my-new-object-part
```

The destination must not exist. This standalone writer creates the key and
JSON data, marks, primary index, checksums and all pre-ATTACH sidecars itself;
it does not borrow a stock-generated part or insert into a server data root.
The writer example reads the result through `ObjectDocumentFileReader`.
The separately qualified catalog and typed-table readers are shown below.

This profile is a hashed Wide part with a sorted UInt64 key, explicit typed
UInt64/String JSON fields and explicit Dynamic path/type rosters. The same
writer also admits the W132 paired integer widths, Float32/64 and Bool fields
and W133 bare Date/Date32 fields;
this example deliberately keeps its original fields. Object V3,
Dynamic V3, one-bucket shared MAP, LZ4 and plain adaptive marks are required.
The example includes a Dynamic type spill, a shared path, an absent path and
a short final granule. Capacities are declared in `ObjectDocumentSchema`;
path/type roster inference is not implemented. Publication is process-atomic
and exclusive on macOS, not a power-loss durability or server-lifecycle
guarantee. See the [general JSON frontier](../docs/JSON_GENERAL_STORAGE_FRONTIER.md)
for the exact qualified surface and stock runtime.

## Read-only ClickHouse data-root examples

These examples read local files under a ClickHouse data root (`metadata/` and
`store/`). They do not connect to a server, execute SQL, or provide a
server-consistent snapshot. Use an immutable, quiescent local copy.

List databases, tables, materialized views, DDL columns, named projection
declarations, and physical part candidates:

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

`OfflineTable#kind` distinguishes `:table` from `:materialized_view`;
`#metadata_ddl` returns the bounded persisted ATTACH text, and `#projections`
returns named, opaque projection definitions. These accessors return metadata,
not executed SELECT results. The explicit `scan_projection_typed` API can read
physical projection subparts only when every resolved parent has a validated
child; it does not choose projections automatically or fall back to base rows.
The separate `materialize_view_part` API writes a detached part for the exact
same-database `TO ... SELECT k, v FROM ...` identity-MV profile with `k UInt64`
and `v String`. It provides no INSERT trigger or view-freshness guarantee. See
the [W87/W88 boundaries](../docs/EMBEDDED_MERGETREE_FRONTIER.md).
An MV's `engine` is `MaterializedView`, even when its DDL declares an inner
`MergeTree` target; its direct part and row scans are rejected. If the MV has
no explicit column list, `#columns` is empty rather than inferred from SELECT.

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
Computed `ALIAS` columns are not materialized. Whole normalized JSON columns
have the separately bounded Object path below, not arbitrary JSON admission.

Read normalized whole-JSON documents from an offline Atomic catalog:

```sh
crystal run examples/read_object_catalog.cr -- /var/lib/clickhouse lab events payload
```

```crystal
document = catalog["lab"]["events"]["payload"].values.first.as(CrystalClick::ObjectDocument)
document.paths.each { |path| puts "#{path}: #{document.value_for(path).type.name}" }
```

The result owns immutable flattened path/value documents, including typed,
Dynamic and shared-MAP values. W129 originally qualified UInt64/String;
W132 also qualifies declared integer widths, Float32/64 and Bool through this API;
W133 adds bare Date/Date32 with nominal identity and lossless raw day codes.
The profile remains normalized hashed Wide Object V3/Dynamic V3, one shared MAP bucket, LZ4 and
plain adaptive marks. Ordinary String versions 0/1 are supported; selected
compressed marks and other JSON layouts are rejected. The example requests
1,000 rows, 16 MiB of String payload and 100,000 recursive cells. The Object
materializer additionally applies a 64 MiB aggregate logical accounting limit,
covering retained owners and accounted reader workspace across parts. This
is neither an RSS limit nor a pre-decode transient-memory ceiling: a complete
decoded mark is measured and admitted before any of its documents are retained.
Use a quiescent input directory; no concurrent snapshot or server Active-state
claim is made. Mixed Object/scalar typed delivery has the separate W130
contract below; neither path admits arbitrary JSON. See the
[general JSON frontier](../docs/JSON_GENERAL_STORAGE_FRONTIER.md).

Read a physical row window and inspect whole UInt64-PK candidate granules:

```sh
crystal run examples/read_object_table.cr -- \
  /var/lib/clickhouse lab events pk payload 0 100 10 20
```

```crystal
table = catalog["lab"]["events"]
table.scan_typed(["pk", "payload"]) do |batch|
  keys = batch.values_for("pk")
  documents = batch.object_documents_for("payload")
  keys.each_with_index { |key, index| puts "#{key}: #{documents[index].paths}" }
  nil
end
```

W130 routes selected literal normalized Object roots through full typed scans,
physical-row windows and explicit whole candidate granules. Multiple selected
Object roots remain separately bound and ordered. The example prints raw leaf
type/hex values and labels candidate rows `keep` or `reject` using the exact
application residual; a PK candidate is not an exact matching row.

The current Object profile admits W132's declared integer widths, Float32/64,
Bool and String plus W133 bare Date/Date32, hashed Wide Object V3/Dynamic V3,
one-bucket MAP, Default serialization metadata, LZ4,
ordinary String 0/1 and plain adaptive marks. BASIC/COMPACT discriminators do
not mean Compact parts. Whole-Object projection reads remain rejected.
Batch slices are callback-scoped; immutable document handles can be retained.
The shared 64 MiB current-mark logical owner budget is measured after the
complete selected Object mark is decoded. It does not bound decoder workspace,
pre-decode transients, RSS, or caller retention. `.values` retains its separate
aggregate cross-part materialization limits. Use an immutable local copy;
no Active-state or snapshot guarantee follows.

Admitted recursively named, nonempty `Tuple` columns use
`read_offline_column_values.cr`, not the Object-specific example above.
Their scalar and Nullable-scalar terminal surface is described in the
[nested Tuple frontier](../docs/NESTED_TUPLE_FRONTIER.md). Additional field
orders/arities return `WideTupleRow` values:

```crystal
row = catalog["lab"]["events"]["payload"].values.first.as(CrystalClick::WideTupleRow)
row.fields.each { |field| puts "#{field.name}: #{row[field.name].inspect}" }
```

The exact legacy spelling `Tuple(a UInt64, b String)` still returns native Crystal
`Tuple(UInt64, String)` values. Other admitted shapes use the nominal row,
not a union of every possible Crystal Tuple arity. `max_tuple_cells:` can
tighten the 1,000,000-cell hard ceiling; numeric and empty String cells count,
and the cumulative String budget includes every String leaf. Named row access
copies only the requested String bytes. Retaining one row can retain its
entire owned decoded mark; it is not a detached row allocation or an RSS bound.
A tighter catalog String limit is checked while accumulating returned rows,
after the current mark has been decoded; it is not a transient-memory ceiling.
Typed streaming uses `batch.tuple_rows_for("payload")` for these non-exact
profiles. Its slice is callback-scoped, but a copied row handle safely retains
owned backing. Use an immutable source: all selected Tuple child schedules
are checked before callbacks, while payload checks remain lazy per mark.
Unnamed/empty Tuples, Nullable containers, arbitrary recursive containers,
and Compact/Sparse/unknown metadata profiles are not admitted by this API.

One outer `Array` around that admitted named Tuple tree returns
`WideArrayTupleRow` handles. Index an outer row to access its `WideTupleRow`
elements; typed batches expose `array_tuple_rows_for("payload")`. Catalog
`max_tuple_cells:` counts flattened elements times Tuple leaves, not outer
rows times leaves. The three exact legacy Array(Tuple) spellings retain
their existing specialized return types. Retaining an element or outer row
can retain its decoded mark. Lazy direct mark iteration retains the selected
schedule and one current decoded mark; it is not a no-payload-I/O or RSS
ceiling. Inner Array/Map/LowCardinality/Variant/Dynamic/JSON composition
remains outside this profile.

One BASIC `Map(K, Tuple(...))` wrapper around the same named Tuple tree,
in the qualified two-column Wide/LZ4 profile with one sorted UInt64 primary key,
returns `WideMapTupleRow` handles. Keys use admitted non-Nullable scalar leaf
descriptors; entries are ordered and duplicate keys are not collapsed:

```crystal
row = catalog["lab"]["events"]["payload"].values.first.as(CrystalClick::WideMapTupleRow)
row.each do |key, value|
  puts "#{key.inspect}: #{value.fields.map { |field| value[field.name] }.inspect}"
end
```

Typed batches expose `map_tuple_rows_for("payload")`; direct part reads use
`read_map_tuple_mark_range` or `each_map_tuple_mark_range`. The paired writer
is `WidePartWriter.write_uint64_map_tuple_part`: pass outer PK rows, a
per-row entry-count vector, a key leaf named `keys`, and Tuple leaves in schema
order. Empty Maps still occupy outer rows. Catalog cell limits count flattened
entries times value leaves, and String limits include key bytes and value bytes
hidden beneath NULL. Row handles retain their decoded backing; this is not an
RSS bound. WITH_BUCKETS, Nullable keys/containers and other inner containers
remain rejected. See the [Map(Tuple) frontier](../docs/MAP_TUPLE_COMPOSITION_FRONTIER.md)
for the exact physical profile and qualification scope.

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
`Date`, `Date32`, and their Nullable forms display their lossless raw
epoch-day codes, not formatted calendar dates. `DateTime` and
`Nullable(DateTime)` display raw epoch-second codes. `DateTime64(p)` and
`Nullable(DateTime64(p))` display raw ticks with an explicit `[p=N]`
precision label on non-NULL cells, because the column header shows only the
name. Nullable cells display `NULL` separately from raw zero. The viewer
also displays `Bool` as `true`/`false`, `Enum8/16` as signed backing codes,
and `Decimal32/64/128/256` as signed raw scaled integers with an `[s=N]` scale label;
their BASIC Nullable forms keep `NULL` distinct from zero. It does not resolve
Enum labels or convert Decimal values to text with a decimal point. The viewer
performs no timezone or calendar conversion; none of these semantic types is
an equality-filter type.
It displays `UUID`, `IPv4`, and `IPv6` values as text; their BASIC Nullable
forms show `NULL` separately from zero-valued entries. Address and UUID
columns are not equality-filter types in this example.
Non-NULL Strings are quoted and escaped; only their first 256 source bytes are
retained for display. Longer values carry a `[truncated]` prefix. Equality
uses raw typed values, not truncated display text. `LowCardinality(String)`
cells use the same bounded escaped preview, but the example does not offer
equality filtering for that declared type. Each filtered page examines one
bounded *physical* window, so it may show no matching rows even though
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
