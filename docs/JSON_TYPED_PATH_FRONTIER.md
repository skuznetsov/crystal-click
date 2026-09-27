# JSON Typed-Path Projection Frontier

Document status: bounded typed-path reading and one exact writer shape verified
against pinned ClickHouse 26.7.1.1315, the public reader fixture, and the
W24 524-example debug/release suites. General JSON document reading and
writing are not claimed.

Current frontier: expose only explicitly declared, scalar typed paths of a
top-level ClickHouse `JSON` column as virtual columns in the existing offline
Wide-part scanner. This is a projection, not a JSON document reader.

## W24 verified bounded writer: one typed-path Object V3 shape

This compatibility step adds a writer for one sorted `UInt64` key and the
exact `JSON(a UInt64, b String)` payload already represented by the stock
reader fixture. Its input values are positional pairs of declared path values;
there is no arbitrary-document or dynamic-key input. In this shape ClickHouse
materializes absent declared paths as their scalar defaults, so the writer
records normalized values rather than claiming to preserve presence. The
public method name and tests make that restriction visible.

The admitted physical target is a staged, checksummed Wide/LZ4 part with
independent plain adaptive `.mrk2` streams for the key, `object_structure`,
`a`, `b.size`, `b`, and all three empty shared-data streams. The V3 structure
contains zero dynamic paths, one shared-data bucket, and empty shared-path
statistics. The writer checks its own staged stream bytes and marks, then
passes a pinned stock ClickHouse `ATTACH PART`, exact typed-path RowBinary and
whole-object normalized-value reads, and `CHECK TABLE`. A self-readback is
insufficient because the Crystal reader checks only the V3 prefix of
`object_structure` and does not interpret shared data.

Risk: CAUTION; the likeliest failure is a plausible typed-path read from a
malformed structure/shared stream that stock ClickHouse rejects or interprets
differently. Rollback is one W24-only local commit; no existing server data
root is a write target. A failing writer test preceded implementation; the
focused and full debug/release suites, all pinned writer oracles, fixture
check, format, and diff checks followed. Negative checks require
rejection before publication for invalid names, unequal rows, unsorted keys,
and a pre-existing destination. Evidence expires on producer version,
Object serialization settings, codec/mark format, or writer/reader changes.

Guard-only after W24: general `JSON`, dynamic paths, nonempty shared data,
whole-document input or arbitrary reconstruction, other typed-path schemas,
Nullable/recursive paths, Compact parts, and performance claims. The next
type-parity track should generalize typed paths and then address Map/Nested;
MV and projections follow type parity rather than being inferred from it.

W24 implementation path: `spec/wide_part_writer_json_typed_spec.cr` first
recorded the missing writer API as RED; `src/crystal_click/wide_part_writer.cr`
then emits and validates the eight streams with no changes to reader acceptance;
`scripts/check_json_typed_writer_oracle.sh` independently compares a produced
part against stock ClickHouse. Inventory search
`rg -n 'write_uint64_|write_typed_payload_streams|json_typed_path' src spec`
locates writer entry points and the three existing reader/catalog consumers.
The spec covers staged metadata, marks, binary String bytes, short final
granules, and pre-publication failures; the oracle guards against the
reader's intentionally partial structure validation.

Observed W24 evidence at the diff atop `6be7716` on 2026-09-27: the focused
writer spec was RED for the absent API, then passed 3 examples. The full
debug and release suites each passed 524 examples, and all 18 pinned oracle
scripts passed. The W24 oracle attached two Crystal-produced parts to pinned
ClickHouse 26.7.1.1315: mixed values with three granules and a short final
granule, and an all-empty `b` stream. Exact full and key-range typed-path
RowBinary, normalized whole-object JSONEachRow, Object V3 bytes, plain
adaptive marks, and `CHECK TABLE` passed. Invalid names, unequal rows,
unsorted keys, oversized String granules, and an existing destination were
rejected without publishing or replacing a part. The public fixture shape,
Crystal format, shell syntax, and diff checks passed.

The first stock `CHECK TABLE` falsified a plausible part: its
`object_structure.mrk2` existed but was omitted from `checksums.txt`, though
`ATTACH PART` and reads succeeded. The writer now checks an exact staged
checksum and file inventory before publication. A second stock oracle and
the independent hostile pass found no further concrete defect. Adversary
verdict: **ROBUST within this exact schema, Wide/LZ4/plain-adaptive-mark
layout, pinned build, and tested inputs**; byte-for-byte equivalence to a
stock-generated part, arbitrary JSON semantics, and other versions remain
unverified. Refresh this evidence on producer version, serialization setting,
codec/mark format, or writer/reader changes.

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
