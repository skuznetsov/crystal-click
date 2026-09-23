# String and Nullable Wide-Part Scan Frontier

Document status: implemented and verified for the exact layouts below against
the checked-in ClickHouse-produced fixture and local debug/release suites.

This implementation extends the exact-type, callback-scoped offline Wide
MergeTree scan beyond primitive numeric columns, one physical serialization
shape at a time. It is not a claim of general ClickHouse type support.

## Factual anchor

At pinned ClickHouse source `066ea77c`, `SerializationString.cpp` has distinct
`SINGLE_STREAM` and `WITH_SIZE_STREAM` paths. The latter stores per-row
little-endian `UInt64` sizes in a separate stream and raw characters in the
regular stream. A ClickHouse-produced `26.7.1.1315` fixture independently
decodes to sizes `[0, 5, 3, 4, 0]` and raw bytes `alpha`, `a\0b`, `tail`
concatenated: zero-size empty strings are valid, and no per-row terminator is
stored in this observed layout. Do not infer the on-disk representation from
an in-memory `ColumnString` representation.
`MergeTreeSettings.cpp` defaults top-level String to
`with_size_stream` when serialization info is `with_types`; nested String is
not affected by that setting. `SerializationNullable.cpp` in basic mode writes
a `UInt8` null map and nested element stream separately. The previous Crystal
reader accepted exactly one selected physical stream and assumed fixed-width
values, so merely adding type names would have been incorrect.

A local ClickHouse `26.7.1.1315` Wide-part probe with top-level `String label`
and `Nullable(UInt64/Int16/Float32)` confirms `columns_substreams.txt`
physical names `label.size`, `label`, and a `.null` plus nested value stream
for each nullable column, each with its own data and mark file. This probe
describes these exact layouts, not all versions of either type.

## Admitted surface

- Exact top-level `String` with separate `.size` and regular streams as
  demonstrated by a public ClickHouse-produced Wide-part fixture; preserve
  arbitrary bytes, including empty values and embedded NUL, without implicit
  UTF-8 conversion.
- Exact `Nullable(T)` for fixed-width primitive numeric `T` only with basic
  `.null` and nested-element streams validated and aligned per mark.
  A null bit must produce `nil`, never a fabricated numeric value.
- A typed table/offline scan over selected columns, retaining exact DDL/part
  type checks, physical part/mark/row offsets, overlap refusal, selected file
  metadata validation, and callback-scoped value lifetimes. Existing numeric
  and `UInt64` entry points stay compatible.

The public entry points are `WidePart.open_typed`,
`WidePartTable.open_selected_typed`/`scan_typed`, and
`OfflineTable#scan_typed`. A batch exposes `strings_for(column)` and
`nullable_values_for(column, CrystalType)` in addition to existing numeric
accessors. String sizes and raw data, and Nullable null maps and nested values,
are read using each physical stream's own marks. Selected String raw bytes are
bounded to 64 MiB per table mark across all selected String columns (and per
direct String range); this is a raw-byte bound, not a total heap-allocation
bound. Selected checksum entries are checked for file sizes, not content hashes.

For example, after opening a supported offline catalog, caller-side filtering
stays in Crystal code:

```crystal
table = CrystalClick::OfflineCatalog.open("/path/to/clickhouse/data").table("db", "events")
table.scan_typed(["label", "maybe_u64"]) do |batch|
  labels = batch.strings_for("label")
  values = batch.nullable_values_for("maybe_u64", UInt64)
  labels.each_with_index do |label, index|
    next unless label == "alpha"
    puts values[index]
    # Consume borrowed slices here; do not retain them after the callback.
  end
end
```

## Rejected and guard-only surface

- Reject other String serialization versions or layouts until separately
  tested; reject malformed size streams, length overflow, truncated or excess
  raw bytes, missing or duplicate streams, and inconsistent marks before
  exposing affected rows. Check the bounded `serialization.json` version and
  String serialization version as well as the physical substream shape.
- Reject `Nullable(String)`, nested/composite types, sparse null maps,
  `LowCardinality`, `FixedString`, decimals, UUID, Date/DateTime aliases,
  arrays, maps, tuples, and implicit casts in this slice.
- Compact parts, mutable/live server state, actual `system.*` table semantics,
  and automatic active-part selection remain out of scope.

## Falsifiers and stop rules

Risk tier: CAUTION. Rollback: a single feature commit. DoD: a checked public
ClickHouse fixture, focused tests, full debug/release specs, formatter, and
diff check. The strongest likely failure is accepting aligned marks while
mis-pairing a String size stream or Nullable null map with its values.

The implementation followed a red test against the missing typed API, checked
the producer's physical substream names, and tests row/mark alignment and
corruption rejection. The checked-in fixture has four columns, eight physical
substreams, five rows in three marks, including empty and embedded-NUL strings
and null/non-null boundaries. Focused specs additionally exercise exact type
rejection, malformed sizes, null-map bytes, selected checksum sizes, two-part
offsets, overlap refusal, and an aggregate two-String raw-byte limit. The
synthetic corruption cases are not presented as valid ClickHouse parts.

Verification at this source state: fixture `--check`, `crystal spec`, and
`crystal spec --release` pass; the two full suites each report 187 examples,
zero failures. `crystal tool format --check` and `git diff --check` pass.
Adversary verdict: ROBUST for this exact, immutable Wide-part fixture scope;
unsupported serialization variants remain deliberately rejected.

As with the prior numeric scan, earlier callbacks may have run before
corruption in a later mark is discovered; the scan is not transactional.
Selected checksum-entry size checks do not verify file-content hashes.

Evidence decays if the ClickHouse serialization version/defaults, part metadata
format, fixture producer, or shared reader changes. Refresh source and fixture
evidence before widening support.

## Next frontier: JSON

This slice does not read JSON. In pinned `SerializationObject.cpp`, JSON/Object
stream enumeration starts with an object-structure stream, then typed paths,
dynamic paths, and shared data. `SerializationObjectSharedData.h` describes
several shared-data representations, including bucketed and advanced chunked
forms. Thus a `JSON` type name is not enough to identify one byte layout.
The first useful follow-on is a separately version-gated fixture and reader
for explicitly typed paths whose nested primitive types are already supported.
Dynamic paths, shared data, and whole-object reconstruction need their own
format and correctness probes; until then they must fail closed.
