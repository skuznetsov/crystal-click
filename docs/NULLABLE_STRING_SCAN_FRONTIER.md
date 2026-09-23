# Nullable(String) Wide-Part Scan Frontier

Document status: implemented for the exact producer-observed layout below.

## Factual anchor and risk

The current exact typed reader accepts top-level `String` with a separate
`.size` stream and basic `Nullable(T)` for fixed-width primitive numeric `T`.
It rejects `Nullable(String)`. The pinned ClickHouse source is
`066ea77c`; the fixture producer is ClickHouse local `26.7.1.1315`.
`SerializationNullable.cpp:124-136` writes a `UInt8` null map and then
delegates to the nested serializer; `SerializationString.cpp:742-771` writes
row sizes and raw bytes in the size-stream form. A local seven-row Wide-part
probe observed `v.null`, `v.size`, `v` in that order, adaptive `.cmrk2`
streams, data-mark rows `[2, 2, 2, 1]`, and `serialization.json` version 1,
`propagate_types_serialization_versions_to_nested_types: true`, with
`types_serialization_versions: {"string": 1}` (basic Nullable is implicit).
Combining the two existing Crystal paths without this shape gate could
mis-pair nulls, lengths, or raw bytes.

Risk tier: CAUTION (on-disk serialization and callback-visible values).
Rollback: one scoped feature commit. The part is caller-supplied and treated as
immutable during scanning; this is not an atomic filesystem snapshot.

## Admitted behavior

- Exact top-level `Nullable(String)` in a Wide MergeTree part, only for the
  producer-observed basic Nullable null map plus String size/raw substreams,
  in the exact order `column.null`, `column.size`, `column`, with the version
  gate above.
- A `nil` null value is distinct from a present empty String. Present strings
  preserve bytes, including embedded NUL; no UTF-8 conversion or terminator
  inference is allowed.
- Direct bounded mark-range reading and mixed selected-column typed table and
  offline catalog scans, with exact DDL/part type checks. The callback batch
  has a dedicated `nullable_strings_for(column)` accessor returning a borrowed
  `Slice(String?)`.
- Every selected physical stream uses its own mark offsets and must have the
  same per-mark row counts. Selected String raw bytes, including this type,
  share the existing 64 MiB aggregate per-table-mark cap; direct reads retain
  a 64 MiB range cap. These bounds cover raw payload bytes, not total heap
  allocations for row arrays and String objects. Selected checksum entries
  are size-checked, not hashed.

For a selected offline table, caller-side filtering remains ordinary Crystal
code; the returned slice is borrowed for the duration of the callback:

```crystal
table.scan_typed(["seq", "payload"]) do |batch|
  seq = batch.values_for("seq", UInt64)
  payload = batch.nullable_strings_for("payload")
  payload.each_with_index do |value, index|
    puts seq[index] if value && value.includes?("error")
  end
end
```

## Rejected and guard-only behavior

- Reject sparse/alternate Nullable or String serialization, absent or duplicate
  selected streams, inconsistent marks, invalid null-map bytes, malformed
  lengths, and truncated/excess raw bytes. Do not fabricate a String for a
  null row or silently coerce a non-null empty String to `nil`.
- No `Nullable(String)` inside JSON typed paths, arrays, maps, tuples, or
  `LowCardinality`; no Compact parts, server-side active-part semantics,
  expression evaluation, or query language.
- An absent column added after part creation has no streams in that old part.
  It is not supported through a fabricated default-null column in this slice.
- Existing numeric, String, and nullable-numeric entry points retain their
  current exact-type contracts, including the previously public 12-argument
  typed batch constructor. A later-mark failure may follow earlier callbacks;
  the scan is not transactional.

## Falsifier and completion gate

Before production edits, the public ClickHouse-produced fixture used an
explicit `seq` order and four two-row data marks. Its positional oracle is
`["P", nil, "Q", "", "a\0b", "z", nil, "Q\0R"]`, so null, non-null empty,
non-empty, and embedded-NUL cases are independently distinguished. A red spec
failed on the missing `Nullable(String)` admission (`1 example, 1 failure`).
The strongest tested counterexample moves an encoded `P` byte under the null
row's nested slot: row 3 must still decode to `Q`. Corruption specs also
exercise invalid null-map bytes, a missing selected stream, per-mark row
count mismatch, oversized lengths, direct/aggregate byte caps, checksum-size
and serialization-version rejection, exact accessor mismatch, and zero
callbacks for opening/DDL failures. Synthetic corruptions are not claimed to
be valid ClickHouse parts. A review found that the first implementation broke
the public typed batch constructor; a compile-failing regression spec preceded
restoration of its original 12-argument signature.

Definition of Done: fixture `--check`, focused spec, full debug/release specs,
`crystal tool format --check`, and `git diff --check` at the final source
state. At this source state, `bash scripts/generate_nullable_string_fixture.sh
--check` passed; the focused spec reports 10 examples and both full suites
report 201 examples, zero failures/errors. The formatter and diff check pass.
The root separately reran the final debug and release suites (201/0 each)
after the compatibility fix. The review verdict is ROBUST within this exact
immutable Wide-part scope: its only reported compatibility regression was
reproduced red, repaired, and rechecked. Evidence decays when ClickHouse's
serialization defaults or versions, the fixture producer, or shared
stream/mark parsing changes; refresh the producer/source check then.
