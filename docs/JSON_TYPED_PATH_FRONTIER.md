# JSON Typed-Path Projection Frontier

Document status: bounded typed-path reading and writing verified against
pinned ClickHouse 26.7.1.1315. W24's exact two-path writer remains supported;
W72 adds arbitrary nonempty lists of the reader's simple scalar typed paths.
General JSON document reading and writing are not claimed.

The next reusable Object/Dynamic/shared-data track is recorded separately in
`JSON_GENERAL_STORAGE_FRONTIER.md`. Its initial physical capture does not widen
the W24/W72 admission or certify whole-document reader/writer compatibility.

Current frontier: expose only explicitly declared, scalar typed paths of a
top-level ClickHouse `JSON` column as virtual columns in the existing offline
Wide-part scanner. This is a projection, not a JSON document reader.

## W72 design seal: declared scalar typed-path writer parity

Status: implemented and verified within the bounded W72 scope below. The reader already
accepts simple top-level identifier paths with `String` or one of the ten
primitive fixed-width numeric types. W72 admits a writer for an arbitrary
nonempty, bounded list of those declared paths, supplied as homogeneous
per-path columns in any order, with row count matching a sorted
`UInt64` key. The writer must preserve each path's name-to-type-to-values
association while canonicalizing both `columns.txt` declarations and physical
typed streams by path name as ClickHouse does. It must emit independent
streams and marks and retain the W24 empty-dynamic
Object V3 structure and shared-data streams. Missing values are supplied as
already-normalized scalar defaults; this is not a presence-preserving API.

Guard-only: untyped/dynamic paths, nonempty shared data, whole-document input,
arbitrary document reconstruction, nested/dotted paths, `Nullable`, recursive
path types, Compact parts, alternate Object serializers, and any claim that
all JSON types are supported. W24's exact entry point remains supported. The
likeliest failure is metadata/stream ordering or numeric-width mismatch that
passes a partial Crystal self-read yet stock ClickHouse misinterprets. Risk is
CAUTION; rollback is one isolated W72 feature commit, with no server data root
as a write target.

Falsifier first: a mixed-width three-path declaration such as
`JSON(a Int16, b Float32, c String)` must be RED through a new public writer
API, then tested with multiple marks, empty and binary String values, and
pre-publication rejection of mismatched rows, duplicate/invalid names, wrong
declared types, oversized granules, and destination collisions. Independently
produce that schema with pinned ClickHouse 26.7.1.1315 to establish its
`object_structure`, substream order, and defaults; reverse-test a
Crystal-produced part using `ATTACH PART`, exact typed-path and whole-object
reads, and `CHECK TABLE`. The DoD is focused specs, full debug/release specs,
all pinned writer oracles, the new stock reverse oracle, formatter, and
`git diff --check`. A stock failure narrows the admitted family instead of
inventing compatibility. Evidence expires on ClickHouse producer version,
Object serialization settings, codec/mark format, or relevant code changes.

Execution plan (one W72 feature commit):

1. `spec/wide_part_writer_json_typed_general_spec.cr`: establish RED for the
   missing public API, exact mixed-width bytes/marks, and rejected input with
   no published destination. The expected RED signal is an undefined writer
   method, not a green test that never exercised the new format.
2. `src/crystal_click/wide_part_writer.cr`: add descriptor-driven validation,
   stream emission, metadata, and independent staged checks. The existing W24
   method and its consumers remain unchanged. Inventory:
   `rg -n 'write_uint64_json_typed|json_typed_(columns|substreams|serialization)|json_typed_paths|object_structure|object_shared_data' src spec scripts`.
   It finds the public W24 writer and specs, reader parser/stream resolver,
   JSON fixture generator, and the W24 reverse oracle; none may silently
   change their existing admitted behavior.
3. `scripts/check_json_typed_general_writer_oracle.sh`: inspect a stock
   three-path producer part and reverse-attach a Crystal-produced part to
   pinned ClickHouse, checking typed-path and whole-object values plus
   `CHECK TABLE`. Existing `scripts/check_json_typed_writer_oracle.sh` remains
   a regression guard for W24.
4. Run the focused, full debug/release, and all pinned writer-oracle checks;
   then conduct a hostile review of path ordering, all stream marks and
   checksums, frame limits, declaration/value mismatches, default semantics,
   and staged publication. A self-read is not a substitute for step 3.

Pre-implementation stock probe on pinned ClickHouse 26.7.1.1315: a Wide
`JSON(z String, a Int16, m Float32)` part with five rows and granularity two
canonicalizes `columns.txt` to `JSON(a Int16, m Float32, z String)` and lists
physical typed streams `a,m,z.size,z`, after
`object_structure` and before the three shared-data streams. Its decoded
`object_structure` is the same 13 bytes as W24
(`04000000000000000001010100`); this count belongs to dynamic paths, not
declared typed paths. The `Int16` and `Float32` streams have two- and
four-byte values, and `String` uses UInt64 lengths with zero bytes for empty
values and preserves an embedded NUL. This probe does not verify a
Crystal-produced part. Pinned source
`src/DataTypes/Serializations/SerializationObject.cpp:163-179,317-331`
separately supports sorted typed-path traversal and the dynamic-path count.

Observed W72 evidence on 2026-09-28: the focused spec first failed for the
missing public descriptor/API, then passed 5 examples. The full debug and
release suites each passed 931 examples, 0 failures/errors/pending. The new
reverse oracle, `scripts/check_json_typed_general_writer_oracle.sh`, attached
a Crystal-written `JSON(z String, a Int16, m Float32)` Wide part to pinned
ClickHouse 26.7.1.1315, verified exact full and key-range typed-path
RowBinary, normalized whole-object JSONEachRow, canonical sorted metadata,
Object V3 bytes and marks, exact checksum/file inventory, and `CHECK TABLE`.
It also rejected malformed names, duplicate paths, mismatched rows/types, and
unsorted keys without publication. The prior W24 JSON oracle passed; all 63
other pinned `check_*_oracle.sh` scripts also passed. `crystal tool format
--check` on the changed Crystal files, `bash -n` on the new oracle, and
`git diff --check` passed. The focused spec additionally checks a >64 MiB
String granule, reserved structure stream collision, key/JSON name collision,
canonical declaration order independent of input order, and bit preservation
for Float32 `-0`, non-finite, and NaN payload values. These local bit checks
do not by themselves certify whole-object JSON rendering of non-finite values
on other ClickHouse versions. The stock reverse oracle directly exercises
Int16, Float32, and String together; the remaining numeric widths share the
existing fixed-width serializer but are not individually covered by that
durable oracle. This is not dynamic-path JSON, arbitrary document input, or
MV/projection support. Refresh on producer version, Object serializer
settings, codec/mark layout, or relevant reader/writer changes.

The first hostile pass found a real one-byte length undercount for a
multi-path `columns.txt` declaration at the reader's 64 KiB line limit.
A new boundary spec reproduced writer publication of a reader-rejected line
before the fix. The guard now counts per-path spaces, inter-path separators,
and the terminating LF exactly; the over-limit case rejects before staging,
while an exact-limit line publishes and opens in the Crystal reader. The
focused spec, both JSON reverse oracles, full debug/release suites, and all
other pinned oracles were rerun after the fix. This establishes the bounded
reader limit, not stock ClickHouse acceptance of a 64 KiB path name.

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
