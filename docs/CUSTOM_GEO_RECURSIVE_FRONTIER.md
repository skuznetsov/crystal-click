# Nominal Custom Geo composition frontier — W238

Status: VERIFIED within the finite profiles below (2026-10-09).
Baseline `e33eec811840ce24499c3e6438036134977ff7e6`.
This is the general descriptor/value/physical composition lane, not another
specialized Point or Geo reader. Root hostile verdict: ROBUST within scope.

## Contract and factual anchor

The fresh, separate, depth-one ClickHouse checkout is
`/private/tmp/crystal-click-w238.4nQqSo/clickhouse`, revision
`f25eb93a0b890a3b87df05eb34e2af1f933b4089` (2026-10-09 08:08:30 UTC).
The runtime remains separately pinned to `26.10.1.1201`, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`; source is not runtime provenance.
`DataTypeCustomGeo.cpp`, `DataTypesBinaryEncoding.cpp` and `IDataType.cpp`
are byte-identical to the previously pinned October 7 checkout.

`DataTypesBinaryEncoding.cpp:71-90,508-513,804-808` emits Custom tag `0x2c`
plus the exact name and resolves that name through DataTypeFactory. It does
not emit an expanded Tuple/Array descriptor. `DataTypeCustomGeo.cpp:12-19,
209-280` registers seven static aliases without custom serialization;
`IDataType.cpp:449-457` falls back to the decorated type's serialization.
Their nominal names remain distinct even where storage bodies are equal.

| Nominal Custom name | Exact immediate storage body |
| --- | --- |
| Point | Tuple(Float64, Float64) |
| MultiPoint, LineString, Ring | Array(Point) |
| MultiLineString | Array(LineString) |
| Polygon | Array(Ring) |
| MultiPolygon | Array(Polygon) |

At the baseline the descriptor codec recognized but refused `0x2c`; generic
scalar serde had no Custom visitor. Dedicated Point/Geo part APIs already
existed. The missing behavior was recursive reuse with nominal identity, not missing
Float64/Tuple/Array algorithms. Current static BinaryBulk table routes are
family-admitted (SAF, aggregate states and QBit), not an arbitrary type parser.

## Admitted target

- Closed-whitelist `BinaryDataType.custom(name)` and one immutable
  `BinaryCustomGeoType` owner; no caller-supplied name/body pairing.
- `BinaryValue.custom(type, body)` retains a nominal Custom wrapper and one
  exact immutable underlying value. Descriptor wire is name-only; scalar and
  bulk bodies recursively reuse existing Tuple/Array visitors, without a new
  serializer per wrapper product.
- Seven aliases at the root and beneath ordinary static Array/Tuple/Map-value/
  nominal Nested/Variant and lawful Nullable edges. Point is Tuple-backed and
  can be Nullable; array-backed aliases cannot. LowCardinality of a Geo body
  remains invalid. Unrelated stateful/runtime siblings retain existing policy.
- Hidden expansion nodes, edges and depth are accounted before materializing
  decoded aliases, under the caller's shared budget. Names, roles, physical
  binding and values retain their existing aggregate bounds.
- A separate Custom Geo bulk declaration/part adapter reuses the existing
  shared static publisher and BinaryBulk reader. Existing bare Point/Geo typed
  return types stay unchanged; newly admitted recursive forms return
  BinaryValue through the established static-bulk table/catalog lane.
  Direct BinaryBulk opens also admit all seven bare aliases. The table route
  deliberately excludes a bare Custom root so its established specialized
  Point/Geo consumers retain their return types.
- Paired reader/writer parity for the admitted physical profile: quiescent
  Wide, LZ4, Default/BASIC, ordinary plain `.mrk2`, sorted UInt64 key plus one
  value column. The parent mark axis is independent of nested Geo element axes.
  The public writer defaults to nested String version 1. Bare aliases require
  that profile to retain their legacy typed consumers; bare Point uses the
  accepted empty always-Default statistics roster. Recursive products may also
  use the existing inline String profile under explicit qualification.

## Rejected / guard-only

Arbitrary Custom names or serializers, Geometry's fixed-order Variant owner,
Nullable(array-backed Geo), LowCardinality(Geo), implicit nominal collapse,
and unqualified Dynamic/JSON/Object/aggregate-argument ownership are not
admitted by this slice. Existing specialized Geometry behavior is preserved.
Mixed-owner guards must not be widened merely because the neutral parser now
recognizes Custom. This new part family refuses LowCardinality, Dynamic, JSON,
SimpleAggregateFunction, AggregateFunction and QBit mixtures; those need their
own future qualification. Map Geo values require ordinary scalar keys. No
Compact/sparse/new-version, general multi-column table
publication, projection writing/execution, live-MV freshness or throughput
claim follows from this change.

## Plan, risk and rollback

Risk: CAUTION (serialization and shared recursive consumer boundaries).
Rollback: exact local working-feature commit from the clean baseline; no push.
Strongest likely failure: name-only descriptors silently lose alias identity,
or Custom's implicit Tuple/Array resets budgets / creates incorrect bulk role
paths and nested element counts. Preserve legacy bare typed APIs explicitly.

1. Add literal name-only descriptor/scalar RED tests before production changes.
   Probe known aliases, equal-body unequal-name controls and exact/one-short
   hidden-expansion depth/nodes/edges. Enumerate shared tag visitors with
   `rg -n 'TAG_SIMPLE_AGGREGATE|TAG_NESTED|case type.tag' src/crystal_click`.
2. Kernel owner: `binary_custom_geo_type.cr`, `binary_data_type.cr`, descriptor
   codec, recursive name reader/name budget, `binary_value.cr` and scalar codec.
   Propagate only the nominal wrapper and existing child traversal.
3. Bulk owner: role/type plan, encoder/decoder/defaults and physical binding.
   Reuse child roles without emitting a Custom prefix or extra physical lane.
   Add matching complete-part declaration adapter; preserve runtime guards.
4. Public consumers: shared writer, WidePart selected declaration, table
   adapter and owned `.values`. Existing bare Geo consumers are regression
   controls, not silently replaced by BinaryValue.
5. Stock falsifier: inspect actual Native binary descriptors and persisted
   Geo parts; paired stock-to-library and library-to-ATTACH/CHECK=1 plus literal
   full/middle/empty RowBinary. Observe exact schemas, roles and row axes.
   A checksum-valid later nested shape defect must reject before callbacks.

## Definition of done / residual

Root executed the same 78 affected spec files in DEBUG and RELEASE: 438 examples
per mode, zero failures/errors/pending. The focused gate previously passed 30
examples; the later public typed-admission regression adds one example in the
final cohort. Formatting checks passed for 41 changed Crystal files; all five
Ruby scripts passed Ruby 2.6 syntax checks, and `git diff --check` passed.

The stock capture has 13 persisted profiles and 60 actual native process records:
54 successes, four expected Code 43 constructor refusals and two expected Code
50 unknown-type/descriptor refusals. Both final modes read those stock parts,
publish 13 parts, and pass native ATTACH, exact CHECK=1, nominal schema and
independent full/middle/empty RowBinary. Each final mode has five fresh native
records plus a separate helper; separate raw-output audits pass. The helper's
direct BinaryBulk reads cover all 13 profiles. Owned `.values`, `scan_typed`,
middle windows and EOF cover the six recursive profiles; bare legacy typed
consumers are local regression controls, not extra native helper coverage.
All 230 generated part files match by actual bytes: 27,478 bytes per mode.

Three checksum-valid late Array/String/Variant shape controls fail before any
first/EOF callback; exact restoration and shared-result-budget controls pass.
The public gate initially rejected Nullable(Point) despite working direct and
owned-value readers; one-example RED failed before the exact dispatch fix.
The old W109 negative assertion was updated only for the two newly qualified
forms; malformed names and Nullable(Geometry) remain rejected. AggregateFunction
and QBit sibling-owner admission leaks exposed by two RED failures are guarded.

Both final auditors reject all six in-scope coherent false-success mutations;
genuine and restored controls pass after each case. The seventh, coordinated
rewrite of every generated/attached/snapshot copy and matching inventory witness,
is accepted in both modes. This is an explicit limit: consistency and selected
hashes are not cryptographic execution provenance. The copy harness admits only
14 exact root-confined relative Atomic housekeeping links; audited parts and
sidecars still reject symlinks. Compile/call-site, missing Ruby roster and
initial housekeeping-copy failures were harness plumbing, not successful native
compatibility certificates. Raw failed captures are retained separately.

Evidence and exact reproduction commands:
[W238 evidence index](../.landmark/evidence/custom-geo-recursive-w238.json).
Logical bounds are not allocator/RSS or speed claims. The helper emits three
File.real_path deprecation warnings; no compiler defect or whole-suite closure
is claimed.

W238 does not close all types/layouts. Next candidates remain Geometry Custom,
other aggregate state grammars, ordinary JSON-bearing shared-path actuals,
typed Object/Nested runtime seams and a staged parent-plus-projection writer
with independent child axes and parent directory checksums. General table
publication is a dependency of that broader writer target, not an optimizer.
Memory/performance follows compatibility; the overall goal remains ACTIVE.
Refresh after relevant source/runtime/compiler/codec/admission/consumer/oracle
changes or loss of temporary captures.

The structural census validates every mark before publication without retaining
full-column lane bytes or decoded value trees. Its one-mark windows share the
original codec and transport budgets. The current transport re-resolves and
re-indexes paired files for each window and can repeat cross-mark frame decoding;
large parts may exhaust consumptive file/record/decode limits sooner than an
indexed session would. Refusal is conservative, not a reset of those limits.
Transport-session reuse and large-part scaling are outside this certificate.
