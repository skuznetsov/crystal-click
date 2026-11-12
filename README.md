# crystal-click

`crystal-click` reads and writes ClickHouse MergeTree data parts from Crystal.
Open a local ClickHouse Atomic catalog to inspect tables and parts, read typed
column batches, and prune granules by primary key. Apply row filters and
transformations in Crystal code. The library also writes standalone Wide and
Compact parts and provides a small embedded MergeTree table.

## Quick start

To build the examples, install Crystal `>= 1.21.0`, GNU Make, and a linkable
system `libzstd`. Run the following write examples on macOS, where the
exclusive atomic publisher uses `renamex_np`.

Clone the public repository and build a self-contained standalone part
example. The writer creates a part inside a temporary directory.

```sh
git clone https://github.com/skuznetsov/crystal-click.git
cd crystal-click
make example-write_w15_decimal_part
tmp_root="$(mktemp -d)"
build/examples/write_w15_decimal_part "$tmp_root/decimal-part"
```

The example writes a `UInt64` key and `Decimal32(2)` payload. The readback
prints the canonical type and raw scaled integers.

```text
Decimal(9, 2): [123, -456, 0]
```

The embedded table example also runs without external data. It creates a new
Crystal-owned table below a temporary directory, inserts two parts, merges
them, reopens the table, and scans the rows.

```sh
make example-embedded_merge_tree_table
tmp_root="$(mktemp -d)"
build/examples/embedded_merge_tree_table "$tmp_root/table"
```

The first output line contains generated part names and the destination. The
scan then prints four tab-separated rows with keys `1`, `2`, `3`, and `3`.
Their values are `alpha`, `beta`, an empty string, and `é`.

Keep standalone and embedded output directories outside ClickHouse server data
roots. Each destination must be unused.

## Install and use as a library

Add the shard to an application's `shard.yml`, then install dependencies with
Shards.

```yaml
dependencies:
  crystal-click:
    github: skuznetsov/crystal-click
    branch: main
```

```sh
shards install
```

The public entry point is `require "crystal-click"`. This small program reads
a bounded row window from two `UInt64` columns in a local table. Save it as
`reader.cr` in the consuming application.

```crystal
require "crystal-click"

unless ARGV.size == 7
  STDERR.puts "usage: reader DATA_ROOT DATABASE TABLE LEFT_UINT64 RIGHT_UINT64 START_ROW MAX_ROWS"
  exit 2
end

start_row = ARGV[5].to_u64
max_rows = ARGV[6].to_i
left_column = ARGV[3]
right_column = ARGV[4]
table = CrystalClick::OfflineCatalog.open(ARGV[0])[ARGV[1]][ARGV[2]]

table.scan_typed_window([left_column, right_column], start_row, max_rows) do |batch|
  left = batch.values_for(left_column)
  right = batch.values_for(right_column)
  left.each_with_index do |value, index|
    puts "row=#{batch.source_row_offset + index.to_u64} #{left_column}=#{value} #{right_column}=#{right[index]}"
  end
end
```

Run it with a quiescent local data root, database, table, two declared UInt64
columns, a starting row offset, and a positive row limit.

```sh
crystal run reader.cr -- /path/to/immutable/clickhouse-data-root analytics events left right 0 100
```

Build `read_typed_window` to run the same scan from the checkout.

```sh
make example-read_typed_window
build/examples/read_typed_window /path/to/immutable/clickhouse-data-root analytics events left right 0 100
```

Examples load the checkout source directly. See the [examples guide](examples/README.md)
for their complete argument lists, profiles, and operational limits.

## Read and write profiles

Compatibility depends on the part format, column types, serialization, codec,
and mark layout. Each reader and writer has its own supported combinations.
The profiles document the ClickHouse builds and layouts used for native
`ATTACH PART`, `CHECK TABLE`, and readback where those checks were exercised.

| Surface | Profile reference |
| --- | --- |
| Wide table reads | [Wide table reader](docs/TABLE_READER_FRONTIER.md), [ragged columns](docs/WIDE_RAGGED_SELECTED_METADATA_FRONTIER.md), and [compressed marks and ZSTD](docs/COMPRESSED_MARKS_ZSTD_FRONTIER.md) |
| Wide part writes | [Schema-aware Wide writer](docs/SCHEMA_WIDE_PART_WRITER_FRONTIER.md) |
| Compact typed reads | [Compact reader profiles](docs/COMPACT_TYPED_READER_FRONTIER.md) |
| Compact part writes | [Compact writer profiles](docs/COMPACT_PART_WRITER_FRONTIER.md) |
| Offline table scans and part resolution | [Offline catalog](docs/OFFLINE_CATALOG_FRONTIER.md) and [MergeTree part resolution](docs/OFFLINE_MERGETREE_PART_RESOLUTION_FRONTIER.md) |

Wide readers have profiles for adaptive `.mrk2` and compressed `.cmrk2`
marks. Compact parts share `data.bin` across columns, with qualified
`.mrk3`, `.mrk4`, `.cmrk3`, and `.cmrk4` layouts. The linked profiles give
the supported combinations for the following type families.

- Fixed-width signed and unsigned integers, including raw `Int128`, `UInt128`,
  `Int256`, and `UInt256` carriers, `Float32`, `Float64`, and `BFloat16`.
- `String`, `FixedString`, temporal values, UUID, IPv4, IPv6, Decimal
  coefficients, Bool, and declared Enum8/Enum16 mappings.
- Recursive Array, Tuple, Map, Nullable, LowCardinality, and flattened
  `Nested` compositions for explicitly admitted schemas.
- Specialized `Variant`, `Dynamic`, JSON/Object, QBit, and Geo paths with
  API-specific storage and type profiles.
- Selected serialized `AggregateFunction` states and raw storage values for
  supported `SimpleAggregateFunction` declarations.

Useful family references include [Decimal precision](docs/DECIMAL_PRECISION_FRONTIER.md),
[identifiers](docs/IDENTIFIER_TUPLE_FRONTIER.md), [temporal tuples](docs/TEMPORAL_TUPLE_FRONTIER.md),
[recursive Tuples](docs/NESTED_TUPLE_FRONTIER.md), [Array of Tuple composition](docs/ARRAY_TUPLE_COMPOSITION_FRONTIER.md),
[Variant binding](docs/VARIANT_PHYSICAL_BINDING_FRONTIER.md), [Dynamic table consumers](docs/DYNAMIC_TABLE_CONSUMER_FRONTIER.md),
[JSON/Object storage](docs/JSON_GENERAL_STORAGE_FRONTIER.md), [recursive Compact JSON and Dynamic](docs/COMPACT_RECURSIVE_DYNAMIC_FRONTIER.md),
[QBit](docs/QBIT_FRONTIER.md),
[Geo types](docs/GEO_TYPES_FRONTIER.md), [SimpleAggregateFunction](docs/SIMPLE_AGGREGATE_FRONTIER.md),
and [AggregateFunction sum states](docs/AGGREGATE_FUNCTION_SUM_FRONTIER.md).

## Offline Atomic catalog and scans

Open an immutable, quiescent copy of a single-disk Atomic data root.
`OfflineCatalog.open(data_root)` reads `metadata/` and `store/`. Use
`catalog.databases` and `database.tables` to enumerate metadata, or index
by name. `table.part_candidates` lists physical parts with row counts and
partition IDs (`part.info.partition_id`).

For scans of stored MergeTree rows, the resolver chooses maximal covering
parts and rejects partial overlaps, ambiguous duplicates, and transactional
metadata. The full physical inventory remains available. The resolved set
describes the files selected for this scan. Server `Active` state requires
the server's own catalog.

The synthetic `system.part_candidates` table exposes the physical inventory
through the same indexing API. Its `rows` column comes from `count.txt`.

```crystal
data_root = "/path/to/immutable/clickhouse-data-root"
catalog = CrystalClick::OfflineCatalog.open(data_root)
candidate_rows = catalog["system"]["part_candidates"]["rows"].values
candidate_rows.each { |row_count| puts row_count }

table = catalog["analytics"]["events"]
left_values = table["left"].values(max_rows: 10_000_u64)
```

`.values` returns an owned array for a supported column and raises if the
complete result exceeds its limits. See the [physical column profile](docs/OFFLINE_PHYSICAL_COLUMN_VALUES_FRONTIER.md)
and [synthetic candidate profile](docs/OFFLINE_PART_CANDIDATE_VALUES_FRONTIER.md).

`OfflineTable` supports typed scans and bounded windows. Window limits bound
rows delivered to callbacks. The reader may decode complete marks that
intersect a window. For a table with `ORDER BY pk` and `UInt64` columns
`pk` and `metric`, select candidate granules and apply the inclusive key
predicate inside the callback.

```crystal
table = catalog["analytics"]["metrics"]
table.scan_uint64_pk_candidates(
  ["pk", "metric"],
  lower_bound: 100_u64,
  upper_bound: 200_u64
) do |batch|
  keys = batch.values_for("pk")
  values = batch.values_for("metric")
  keys.each_with_index do |key, index|
    puts "#{key}\t#{values[index]}" if 100_u64 <= key && key <= 200_u64
  end
end
```

Scan callbacks receive borrowed slices. Copy data you intend to retain after
the callback returns.

For direct part use, `TypedPartTable.open_selected_typed(parts, columns)` opens
a caller-selected ordered list of compatible Wide and Compact part paths. Its
`scan_typed` and `scan_typed_window` methods provide aligned batches over that
explicit list. The preflight checks selected schemas and rejects overlapping
part identities within a partition.

## Materialized views and projections

The offline catalog exposes persisted materialized-view targets and SELECT
text. In an exclusively owned offline copy, `materialize_view_part` handles
the qualified identity SELECT shape. `transform_materialized_view_part`
uses a caller-supplied Crystal transformation and writes Wide output by
default. Pass `mark_format:` and return a `CompactPartTransformOutput` to
write Compact output for the supported target schema. Both operations take
one source part and publish a detached part under the declared target. The
caller chooses when to recompute and attach it. See the [MV metadata profile](docs/MATERIALIZED_VIEW_METADATA_FRONTIER.md)
and [transform profile](docs/MATERIALIZED_VIEW_TRANSFORM_FRONTIER.md).

`OfflineTable#projections` exposes declared projection metadata. For a table
with a physical Wide or Compact projection `p` containing a `UInt64` column
`pk`, call `scan_projection_typed_window` with the projection name and row
range. The reader matches each selected child's checksum manifest to its
parent before yielding rows. Offsets follow the child's marks, and batches
identify the parent part.

```crystal
table.scan_projection_typed_window("p", ["pk"], 0_u64, 64) do |batch|
  batch.values_for("pk", UInt64).each { |key| puts key }
end
```

Compute projection rows in your application and pass them as `projections:`
to either part writer's `write_uint64_columns`. Use
`WidePartProjection.precomputed` or `CompactPartProjection.precomputed`
for each child. Children keep their own mark grids and are published with
the parent in one directory rename. See the
[projection window profile](docs/PROJECTION_WINDOW_FRONTIER.md) and
[projection publication profile](docs/PROJECTION_PUBLICATION_FRONTIER.md).

## Standalone parts and embedded storage

`WidePartWriter` and `CompactPartWriter` create complete standalone parts for
their supported profiles. Write to a new destination outside a running server's
data root, then manage attachment separately. Exclusive atomic publication
currently uses Darwin `renamex_np` to publish the complete part directory in
one step.

`EmbeddedMergeTreeTable` is a separate Crystal-owned local table built from
bounded immutable parts in one partition. Use a sorted `UInt64` key with a
`String` payload or the separate profile for declared scalar JSON paths.
It supports insert, adjacent-part merge, reopen, and typed scans. Store it
outside ClickHouse server data roots. Its publication also uses the Darwin
publisher.
See the [embedded table profile](docs/EMBEDDED_MERGETREE_FRONTIER.md).

## Build and verify

The Makefile discovers standalone programs under `examples/*.cr`. Use
`make help` to list them, or build one by its source basename.

```sh
make help
make examples
make example-read_typed_window
make examples BUILD_DIR=build/release CRYSTAL_FLAGS=--release
make clean BUILD_DIR=build/release
make clean
```

`make example-<basename>` builds one top-level example to
`$(BUILD_DIR)/examples/<basename>`. `BUILD_DIR` defaults to `build` and
accepts paths with spaces. Set `CRYSTAL` to choose a compiler. Use a separate
build directory for each compiler flag set. `make clean` removes example
and TUI binaries and their debug sidecars from the specified build directory.

The optional `make tui` target builds
`$(BUILD_DIR)/examples/offline_tui`. It needs an external `crystal_tui/src`
directory on `CRYSTAL_PATH` and is excluded from `make examples`.

```sh
CRYSTAL_PATH="/path/to/crystal_tui/src:$(crystal env CRYSTAL_PATH)" make tui
build/examples/offline_tui /path/to/immutable/clickhouse-data-root
```

If LLD reports an Xcode TAPI parsing error on macOS, use Apple's linker for
the build.

```sh
CRYSTAL_FLAGS="--link-flags=-fuse-ld=ld" make example-list_atomic_catalog
```

Run the standalone catalog spec with Crystal.

```sh
crystal spec spec/offline_catalog_spec.cr
```

The full spec suite also requires native ClickHouse captures. See the
[Compact JSON reader profile](docs/COMPACT_JSON_READER_FRONTIER.md) for the
authenticated W263 fixture selected by `CRYSTAL_CLICK_W263_EVIDENCE_ROOT`.

## Architecture and further reading

`OfflineCatalog` and `OfflineTable` resolve local metadata and parts.
`TypedPartTable` dispatches to Wide and Compact readers and reports batches in
selected part order with table-wide row offsets. Format-specific code handles
stream and mark locations. Typed codecs decode column values, including
supported recursive substreams. Writers build and validate a staged part
before publishing it.

- [Table class decomposition](docs/TABLE_CLASS_DECOMPOSITION.md) describes
  public entry points and reader ownership boundaries.
- [Offline catalog frontier](docs/OFFLINE_CATALOG_FRONTIER.md) describes
  local metadata discovery and candidate resolution.
- [Examples guide](examples/README.md) lists runnable examples and arguments.
- [ClickHouse format references](docs/CLICKHOUSE_REFERENCE.md) and
  [source references](docs/CLICKHOUSE_SOURCE_REFERENCE.md) record upstream
  format anchors.
- [Project status](docs/PROJECT_STATUS.md) tracks current qualification and
  remaining compatibility work.
- [Performance backlog](docs/PERFORMANCE_BACKLOG.md) records measurements
  and deferred optimization work.

## License

`crystal-click` is licensed under the [Apache License 2.0](LICENSE).
