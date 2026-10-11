# Compact JSON/Object reader frontier

Document status: W263 native baseline RED qualified; coordinate prerequisite
VERIFIED within its focused scope; Object reader and native GREEN pending
(2026-10-11).
Baseline: `efb84e8d96a378e4833b8ca63a9f5fa16743d78e` (W262).
Current transition: bind persisted JSON/Object sites to the existing recursive
Compact lifecycle, Object codecs and public selected-column consumers. The full
types, MV/projection and subsequent memory/performance objective remains ACTIVE.
This transition does not redefine completion or establish <=10% speed parity.

## Factual anchor and scope

The baseline admits static Compact BinaryBulk and context-owned Compact Dynamic
columns with plain adaptive marks. `BinaryDataType` can represent root JSON and
JSON beneath Array/Tuple, but representation is not physical admission.
`StaticBinaryBulkColumnDeclaration` and `BinaryBulkPhysicalPlan` reject JSON;
`CompactDynamicBulkPrefixTraversal` also rejects JSON before traversal. The
Compact facade dispatches only static and Dynamic readers. Its static batch
adapter does not install a generic JSON-bearing value column.

Existing Object codecs and independently bound recursive JSON sites are reused.
The missing capability is Compact structure-prefix/body/suffix framing and its
connection to the column's Object site context, not a serializer for each
container product. A bound JSON leaf must not be treated as an ordinary opaque
scalar, and a parser-only change cannot qualify it.

Comparison source is the separate shallow checkout
`/private/tmp/clickhouse-w254-upstream.AqeqyC`, revision
`ed30948f095ecb70679986d7d60e27ad770ae27a`. The separately pinned executable is
CH 26.10.1.1201, build `d9bcb5ab007f0f6299f7f973f2642245bab3d028`, SHA256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
Neither latest-upstream nor source/runtime identity is claimed.

## Admitted baseline, design-sealed target and rejected surface

The existing W262 and Wide qualifications remain unchanged. This document does
not admit new behavior until the native behavioral RED, implementation, focused
regressions and actual capture adversary checks have run.

The target is selected root JSON and already representable recursive Array/Tuple
JSON columns in quiescent Compact LZ4 parts with plain `.mrk3` or `.mrk4` marks.
Reuse existing typed paths, inferred Dynamic paths, SharedVariant envelopes and
shared-data value ownership. Bind each JSON/Dynamic site independently even when
two sites have the same nominal SQL type. Empty and unequal child occurrence
grids are required witnesses, not optional optimizations.

Persisted Object V1/V2 MAP and V3 MAP, MAP_WITH_BUCKETS, ADVANCED and
ADVANCED_CHUNKED are all target layouts. Compact does not force MAP. The
implementation must have a general shared-layout boundary; an easier MAP-only
route must not replace the reachable source layouts. Qualification at closure
must name the actual executed matrix rather than extrapolate to all products.

Preserve the current homogeneous effective BinaryBulk profile boundary. String
v0/v1, enabled nested propagation and Variant BASIC/COMPACT are matrix axes;
arbitrary mixed per-node effective profiles remain a separate required track.
Native-only Object STRING/FLATTENED, unknown wire versions, changing frozen
rosters and missing or conflicting site identities remain hard errors.

Compressed Compact marks, Compact writing, non-BASIC Map layouts, remaining
aggregate/SAF/QBit/Geo physical products, native MV SQL/triggers/freshness and
parent projection-manifest authentication are not admitted by this slice. These
remain work toward the original goal, not exclusions from that goal.

## Source-backed design laws

1. Container recursion carries physical context, not only child values.
   Array changes parent-row to element-occurrence coordinates; Tuple retains
   separate field sites. Dynamic actual arms have their own selected occurrence
   grids. No JSON site may borrow another site's structure or row count.
2. Compact freezes the sample's topology for a part. Each granule creates fresh
   serialization state and executes prefix(sample), body(actual slice), suffix.
   Statistics can differ between granules; the frozen wire version, path/arm
   roster, bucket configuration and physical site identity cannot drift.
3. Object structure precedes sorted typed paths, sorted Dynamic paths and shared
   data. V1's compatibility count, V2 framing and V3 shared mode/bucket metadata
   remain owned by the existing Object structure codecs.
4. V1/V2 shared data use MAP. V3 selects the configured layout; Compact retains
   configured buckets even when shared data is empty. Both regular and zero-level
   settings must be controlled when creating stock test parts.
5. ADVANCED_CHUNKED Compact is stream-then-chunks, not Wide chunk-then-streams.
   Its structure/data/path metadata and copy streams must be reconstructed using
   the actual Compact callback schedule before existing logical Object decoding.
   The fixture must contain multiple chunks in a mark to discriminate the two.
6. `.mrk3` starts one top-level-column window; `.mrk4` records stream-getter
   callbacks. Empty children still execute relevant serializer callbacks. A
   canonical stream inventory alone is not the observed callback order.
7. Context preparation and complete selected-column grid validation happen
   before publishing a reader or invoking a user callback, including EOF-first
   and empty selections. Do not silently fall back to another codec or backend.
8. Reuse existing codecs, declaration owners and public facade semantics.
   BinaryJsonRow/BinaryValue is the internal recursive value seam, not a new
   requirement for every public carrier. Preserve root ObjectDocument,
   Array(JSON) ObjectDocument arrays, recursive StorageColumnValue and legacy
   scalar/String/Variant APIs. New owners are one class per file, with an
   explicit physical-framing responsibility rather than per-wrapper serde.
9. Preserve checked logical budgets and account live reader state plus temporary
   normalization ownership. This is not allocator/RSS accounting, cross-part
   cache qualification, lazy access or a performance optimization.
10. Static Object sites beneath Array/Tuple receive the same Compact prefix
    statistics settings as the root. Parse their full PREFIX/PREFIX_EMPTY
    structure, not the stats-free inline Dynamic-JSON prefix. Preserve the
    statistics offset and validate the complete bytes; differing per-granule
    statistics do not constitute frozen-roster drift.

Decisive source anchors at the pinned revision:

- `SerializationArray.cpp:255-328,352-394`: recursive paths, state and empty
  child callbacks.
- `SerializationTuple.cpp:766-860`: independent child states and recursion.
- `SerializationObject.cpp:299-311,399-429,432-507,904-1032`: versions, shared
  layouts, prefix/body/suffix ordering and frozen paths.
- `SerializationObjectSharedData.cpp:743-937`: Compact four-phase chunked
  layout versus the distinct Wide order.
- `MergeTreeDataPartWriterCompact.cpp:174-206,321-369`: fresh granule state and
  actual mark-getter schedule.
- `MergeTreeDataPartWriterOnDisk.cpp:634-746`: frozen sample and zero-row
  callback inventory.
- `MergeTreeIOSettings.cpp:104-109`: zero-level settings and Compact buckets.
- `DataTypeObject.cpp:180-189`: effective child serialization settings.

## Falsifier roster and execution order

1. Before production changes, build a public-API baseline helper and execute
   fresh stock parts. Native CHECK/schema/literal observations and an ordinary
   UInt64 positive control must pass while root and recursive Compact JSON
   reads produce the existing exact UnsupportedFormatError. Expected caught
   refusals are behavioral RED, not a failed harness process.
2. Target native matrix: six Object/shared choices (V1 MAP, V2 MAP, V3 MAP,
   V3 MAP_WITH_BUCKETS, V3 ADVANCED, V3 ADVANCED_CHUNKED) x plain mrk3/mrk4 x
   String v0/v1 x Variant BASIC/COMPACT: 48 cells. Couple the legacy Object
   compatibility cases to their persisted Dynamic versions explicitly; keep
   the global V1 override off. Validate actual persisted layouts rather than
   assuming requested settings establish the format. A native refusal or
   surprising layout is a discriminator, not permission to delete a cell.
3. Each cell should contain eight parent rows in four two-row granules, typed
   scalar/String paths, learned Dynamic paths and genuine shared spill values.
   Include independent JSON child sites and empty/unequal Array occurrence
   counts. Set the advanced chunk target low enough to expose multiple chunks
   within a mark. Independently specified literals must not be generated by
   the production codec or inferred from the decoded result.
4. After implementation, qualify full/first/middle/last windows, EOF-first,
   public CompactPartTable and TypedPartTable scans and offline column `.values`
   against those same independent values. Retain the UInt64 control.
5. Run focused Object, Compact static/Dynamic, carrier/admission and facade
   regression specs in DEBUG and RELEASE under the unchanged resource guard.
   State exact executed files/examples; do not claim the full suite.
6. Root adversary checks attack native version/roster drift, wrong independent
   child grids, empty callback schedules, chunk order, truncated/missing shared
   streams, foreign site binding and logical accounting. Mutate only isolated
   copies and authenticate the unchanged native originals before and after.
7. Fresh final DEBUG/RELEASE captures must have stable source/runtime pins and
   agree on native bytes and helper semantics. Structural manifests are only
   evidence indexes, not behavior or compatibility proofs.

## Plan, risk and rollback

Risk: CAUTION (serialization, physical topology and public reader admission).
Rollback: the clean baseline commit plus one atomic local feature commit; no
remote/history mutation and no unrelated changes. Root owns the SDD, integration,
heavy guarded builds/native execution, independent source checks and closure.
Luna Max owns disjoint implementation and harness paths. All workers preserve
others' changes and do not launch unguarded or concurrent heavy processes.

Production ownership is the existing Compact normalizer/prefix/context boundary,
an own-file JSON column reader and its facade/admission/carrier wiring. Exact
new owner names and affected consumer inventory are sealed before code changes.
Reuse the existing Object site/grid adapters rather than adding a second value
codec or process runner.

The next sealed production step is coordinate provenance, not JSON admission:

- Retain the whole-file `CompressedFrameIndex` in `CompactMarkIndex` and expose
  saved-pair resolution through `CompactPartPhysicalContext`. Account the
  retained descriptor array in the grid's logical workspace census. Frame
  headers alone do not authenticate payloads; selected detached shard bytes
  retain the existing physical reader's authentication responsibility.
- Add `ObjectSharedInlineCoordinateContext` as the shared callback-provenance
  contract and `CompactObjectSharedInlineCoordinateContext` as a Compact owner.
  Keep `ObjectSharedInlineDataCoordinateContext` as the Wide implementation.
  A Compact path consists of ordered source intervals from detached physical
  shards, with explicit site ownership. Resolve pairs in the original whole
  `data.bin` domain, then narrow to the exact path and callback. Do not rebase
  saved pairs, construct a pretend Wide lane or infer site identity from SQL
  type equality.
- Generalize the context types in callback slices, path streams/tape/codec,
  role read views and the advanced inline decoder/copy layout. The bounded
  consumer search `rg -n 'ObjectSharedInlineDataCoordinateContext|resolve_path_position|local_position_for_absolute|absolute_path_offset' src spec scripts -g '*.cr'`
  found these consumers plus the concrete Wide bucket-decoder constructor and
  W240 coordinate tests. Preserve the concrete Wide API used by those tests.
- A role asks each captured callback for its callback-local pair coordinate.
  Only the final role segment admits its terminal; empty segments and a pair
  inside another site or role must not silently pass. Validate provenance
  bytes without copying/rebasing them into an artificial coordinate domain.
- Root owns the require graph and integration; the coordinate worker owns the
  named coordinate classes, mark index/physical context and enumerated context
  consumers, plus a focused coordinate falsifier spec. This step leaves all
  public JSON admission guards unchanged. Root executes the failing test and
  the existing W240/W259/W262 regression cohort before proceeding.

Static JSON site identities remain separate from actual Dynamic keys. The
context/framer/carrier implementation seal will enumerate their exact files
before those owners change. Offline materialization must use one logical
budget for retained output plus active physical/normalizer/decoder/carrier
workspace; independent per-stage caps do not establish that invariant.

Harness ownership: `scripts/probe_compact_json_w263.rb`,
`scripts/check_compact_json_w263.cr`,
`scripts/support/compact_json_w263_fixture.cr` and a focused W263 spec. Reuse
`StockPartProbeSupportW191`, its bounded executor, native file inventory and
independent literal assertions. Existing W262 harness inputs remain unchanged.

DoD commands are root-owned, serial invocations of the existing `run_safe.sh`
guard: Crystal helper builds and exact spec cohorts in DEBUG/RELEASE with
`CRYSTAL_WORKERS=1`, `--threads 1`, the existing SDK/link flags and a fresh
task-local cache; then the prebuilt-helper Ruby native probe in baseline and
green modes. The expected signal is the actual baseline refusal followed by
literal-correct public reads for every qualified native cell, passing named
regressions and a root adversary verdict ROBUST within the declared scope.

The strongest failure mode is applying a Wide Object lane order to Compact,
especially CHUNKED and empty child callbacks, while same-codec tests still pass.
The stock-authored multi-chunk/native public-API matrix is the guard against it.
If a probe fails to discriminate, repair the instrument before promoting a
capability. A valid physical mismatch changes the design, not the success bar.

## Ledger and implementation seals

At closure update this banner, `docs/PROJECT_STATUS.md` and `LANDMARKS.md`, then
store a curated source-linked evidence index. There is no root TODO.md or
CHANGELOG.md at the baseline. No memory-folder update is authorized.

Implementation seal: coordinate provenance prerequisite implemented and
qualified; remaining owners pending. Native RED: qualified within the matrix
below. Native GREEN and final JSON hostile review: pending. Next required
discriminator: general Compact Object context binding, including full-statistics
prefixes and actual multi-chunk callback schedules. Remaining
types/layouts, MV/projections and measured performance parity remain required
after this finite slice.

Coordinate prerequisite RED: the guarded DEBUG invocation of
`spec/compact_object_shared_coordinate_w263_spec.cr` on the unmodified production
baseline exited 1 at line 44: `CompactPartPhysicalContext.logical_position` does
not exist. This is the expected missing-API compile RED, not a behavioral
coordinate qualification. The spec additionally defines descriptor accounting,
non-contiguous source intervals, foreign-site and callback-boundary rejection,
byte validation, and final versus non-final empty endpoint falsifiers. Detached
shards have a public constructor at the baseline; valid offsets alone do not
authenticate fabricated or foreign-part payloads.

Coordinate prerequisite GREEN: four focused examples pass. The exact 12-path
W240/W259/W260/W262 plus W263 coordinate cohort passes 90 examples in each
DEBUG and RELEASE, zero failures/errors/pending, under the unchanged serial
180-second / 12-GiB guard. Root inspection and the executed negative controls
give ROBUST within the saved-pair/piecewise-path scope, not a Compact JSON read
claim. Binding verifies each shard's exact slot, saved grid interval and
freshly authenticated payload; empty intervals remain distinct. The retained
frame descriptors and shard payload/name owners are counted by logical size,
not allocator capacity or RSS. Only a final callback terminal admits a source
endpoint; pair coordinates alone are not a universal callback-identity theorem.
The exact commands, hashes and limitations are indexed in
[coordinate evidence](../.landmark/evidence/compact-object-coordinate-w263.json).

Core-reader RED: the guarded DEBUG internal-reader test exits 1 at
`spec/compact_static_json_internal_w263_spec.cr:89` because
`CompactStaticJsonBulkColumnReader` does not exist. Its selected stock files
were live-checked against the existing 48-part manifest (504 file hashes).
This is a missing-API compile discriminator, not JSON decoding evidence.
The corrected multi-chunk collector still needs its own successful build and
actual native execution; Ruby syntax alone does not qualify its observations.

Native baseline evidence:
`/private/tmp/crystal-click-w263-baseline-six-layouts.bniER3/summary.json`.
The guarded native probe and helper both exited 0. Root independently checked
48 unique labels, 192 real granules and exactly six observed persisted triples
`[wire_version, shared_version, buckets]`: `[0,0,1]`, `[2,0,1]`, `[4,0,1]`,
`[4,1,2]`, `[4,2,2]`, `[4,3,2]`, each in 32 granules. Both facades read the
UInt64 control correctly in every cell. The exact JSON column/API product
produced 384 expected reader refusals; recursive offline wrappers produced
144 expected refusals. This establishes missing behavior, not JSON read
compatibility or actual multi-chunk coverage at every selected child site.
The helper SHA256 is
`344beb7b25abad3f85bad436549bfe8de4c7a38b3a03337d4ad007b006e07f93`.

Instrument refutations before that qualifying run: the initial native JSON
literal oracle expected UInt64 for inferred small positive integers, while
native observation and `JSONExtractTree.cpp:2390-2428,2488-2520` establish
Int64 for this fixture. A later 48-label capture physically covered only four
layouts because prefix matching collapsed MAP_WITH_BUCKETS and
ADVANCED_CHUNKED into shorter names. Exact-label selection, an independent
literal six-layout oracle and seeded collision checks replace that instrument.
Neither earlier capture qualifies the complete six-layout target.

Separate bounded coordinate discriminator:
`/private/tmp/crystal-click-w263-coordinate-final.xxoHaq/summary.json`.
Two native root-JSON mrk4 parts (ADVANCED and CHUNKED) produced 36 saved pairs
that resolve inside their original whole-file intervals, including empty
data/copy roles. The CHUNKED witness contains bucket chunk counts `[1,1]`.
This is a source-coordinate anchor only, not the 48-cell read qualification.

Instrument preflight (not native RED or layout qualification): two bounded
invocations of the pinned CH executable on 2026-10-11 accepted canonical
JSON/Array(JSON) declarations and exposed the nine named Object/Dynamic/String,
bucket/chunk/Variant/propagation settings. They did not create, CHECK or inspect
the 48-cell part matrix. Before baseline execution the fixture was corrected
to have three inferred paths competing for two Dynamic paths, and the helper
was corrected to scan EOF before any nonempty window. Persisted shared-path
spill, Dynamic SharedVariant and actual layout/chunk witnesses remain required;
requested settings alone do not satisfy them.
