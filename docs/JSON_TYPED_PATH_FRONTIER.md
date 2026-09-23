# JSON Typed-Path Projection Frontier

Document status: bounded implementation verified against the public ClickHouse
26.7.1.1315 fixture and the 191-example debug/release suites. General JSON
document reading is not claimed.

Current frontier: expose only explicitly declared, scalar typed paths of a
top-level ClickHouse `JSON` column as virtual columns in the existing offline
Wide-part scanner. This is a projection, not a JSON document reader.

## Factual anchor

In pinned ClickHouse source `066ea77c`,
`src/DataTypes/Serializations/SerializationObject.cpp:198-227` emits an
object-structure stream and then each declared typed path through its nested
serializer before enumerating dynamic paths and shared data;
`SerializationObjectTypedPath.cpp:35-50` forwards the path to that nested
serializer. A local
ClickHouse `26.7.1.1315` Wide-part probe for `JSON(a UInt64)` produced
`j.object_structure`, `j.a`, and three `j.object_shared_data.0.*` streams.
Selecting `j.a` returned the two present values and `0` for the missing
input: missing non-nullable `UInt64` is a default `0`, not `nil`. This initial
probe did not establish a stable physical row order. The fixture used
hashed physical filenames and compressed `.cmrk2` marks; the reader already
has both mechanisms, but must resolve each selected substream independently.
A second probe for `JSON(a UInt64, b String)` emitted `j.b.size` and `j.b`
beside `j.a` and the four auxiliary streams. The selected `j.a` and `j.b.size`
marks each had row groups `[2, 1]` and local decompressed offsets `[0, 16,
24]`; `j.b` had the same row groups but offsets `[0, 3, 3]` for one actual
`x\0y` value and an absent `b` that reads as an empty String. This directly
falsifies using one selected substream's byte offsets for another.

## Admitted surface for this slice

- A selected virtual name `json_column.typed_path` resolves only when that
  path is explicitly declared in the exact JSON type in table DDL and part
  `columns.txt`. If the virtual name also names a literal top-level column,
  selection fails closed as ambiguous.
- Support direct scalar primitive numeric and `String` path streams whose
  physical shapes are already implemented. A missing non-nullable path value
  uses the ClickHouse nested type's default, not invented `nil`.
- Preserve `scan_typed` callbacks, exact DDL/part type matching, part/mark/row
  offsets, selected physical file size checks, mark alignment, and existing
  direct-range/materialization bounds. Check the known JSON substream shape,
  `serialization.json` envelope, and bounded Object V3 prefix before exposing
  selected path data.

## Rejected and guard-only surface

- No whole-object reconstruction or API that returns `JSON::Any`; no dynamic
  paths, shared-data values, arbitrary subcolumns, nested JSON, arrays/maps,
  `Nullable` typed paths, or implicit casts in this slice. Shared-data streams
  may exist but are never interpreted as selected path values.
- Reject undeclared paths, unsupported path/type grammar, duplicate or
  ambiguous virtual names, unfamiliar JSON stream shapes or serialization
  envelopes, mismatched mark rows, and missing/truncated selected files.
- Compact parts, live-server `system.*` semantics, and automatic active-part
  selection remain out of scope.

## Falsifiers and implementation seal

Risk tier: CAUTION. Rollback: one atomic feature commit. The strongest failure
mode is silently using a dynamic/shared stream or wrong mark vector for an
explicit path. Write a red test before production code. A public
ClickHouse-produced fixture must include at least a typed numeric path, typed
String path, present/missing rows, an explicit ordinal, and more than one mark.
Check positional values and bytes, not only aggregates; corrupt selected data/marks and reject
unsupported declarations before callbacks. The DoD is fixture shape check,
focused specs, full debug/release specs, formatter, and diff check.

The V3 prefix gate does not validate the rest of `object_structure` or shared
data. The code admits numeric scalar path types beyond the fixture's `UInt64`,
but only `UInt64` and `String` typed paths have ClickHouse-produced positional
oracle coverage here. Selected file size checks do not verify content hashes.
Earlier callbacks may run before a later corrupt mark is encountered.
Discovery and reads assume immutable parts, not an atomic snapshot. Evidence
decays with ClickHouse serialization changes, producer version, or shared
reader changes.

Observed verification on 2026-09-23: the fixture shape check passed; focused
typed-path specs passed (4 examples); full debug and release specs each passed
(191 examples, zero failures/errors/pending); Crystal format and Git diff
checks passed. The adversarial cases reject undeclared/dynamic paths, JSON
DDL/part type mismatch, unsupported `Array` declaration, literal dotted-name
ambiguity, selected data-size change, missing `String.size` marks, and an
unsupported Object structure version before callbacks. Within that scope the
adversary verdict is **ROBUST**; outside it remains unverified.

## Bounded implementation plan

Consumer inventory: `rg -n 'scan_typed|open_selected_typed|open_typed|supports_typed_type\\?' src spec --glob '*.cr'`
shows the public typed selectors in `wide_part.cr`, `wide_part_table.cr`, and
`offline_catalog.cr`, with the pre-existing String/Nullable contract tested by
`spec/string_nullable_scan_spec.cr`. All three selector layers must agree on
virtual path identity and exact type; old direct-column scans must remain
unchanged.

1. Add a public fixture and a focused red test in
   `spec/json_typed_path_scan_spec.cr` for `j.a` and `j.b`, including missing
   values and multiple marks. Verify expected bytes against ClickHouse.
2. Add strict JSON declaration/stream resolution in `wide_part.cr`; guard
   ambiguous or undeclared paths and the selected stream's mark/checksum
   boundaries before decoding.
3. Route virtual names through `wide_part_table.cr` and `offline_catalog.cr`;
   test DDL/part mismatch and zero callbacks on opening failures.
4. Run fixture `--check`, focused and full debug/release specs, format, and
   diff checks. If the producer shape or defaults differ, narrow the admitted
   surface rather than teaching the reader to guess.
