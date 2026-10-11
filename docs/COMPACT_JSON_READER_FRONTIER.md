# Compact JSON/Object reader frontier

Document status: W263 six-layout/multi-chunk native baseline RED qualified; coordinate prerequisite
VERIFIED within its focused scope; advanced inline preparation prerequisite
VERIFIED; complete Object reader and native GREEN pending
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

### Next core implementation seal

The coordinate prerequisite is committed as
`820050f761a7f388d89fbd5a9a1820c304229eec`. The missing internal-reader API RED
permits the next bounded checkpoint; it does not permit public admission.
The keyless prefix and schedule seam are sealed as follows:

- New own-file owners: `object_document_callback_prefix.cr`,
  `object_document_callback_prefix_reader.cr`,
  `object_document_callback_body_materializer.cr`,
  `compact_static_json_site_manifest.cr`,
  `compact_json_object_role_schedule.cr`,
  `compact_json_object_site_framer.cr`,
  `compact_static_json_prepared_context.cr`,
  `compact_static_json_bulk_column_reader.cr`.
- Existing affected owners: `object_document_inline_prefix.cr`,
  `object_document_inline_plan_reader.cr`,
  `object_document_inline_body_materializer.cr`, `object_document_codec.cr`,
  `object_shared_advanced_inline_decoder.cr`. The inline callback-order owner
  may gain only the narrow role-provider seam required to preserve its existing
  Wide caller behavior. Root owns `src/crystal_click.cr` and this frontier; the core
  worker owns the named implementation files. Root owns integration/requires,
  native-literal specs, serial test execution and final review; test changes
  need a separate ownership assignment and must not relax the literals.
- Extract a keyless common parsed prefix owner. The old inline prefix retains
  its real `BinaryDynamicJsonLeafKey`; its PrefixMap and child Dynamic maps
  remain keyed only by actual Dynamic sites. Static IDs must never be fake
  Dynamic arm keys. The shared builder accepts an explicit statistics context:
  old inline parsing remains prefix-only, while static Compact reads preserve
  complete structure/statistics bytes and offsets. Do not duplicate value serde.
- Extract shared role materialization from the existing inline materializer.
  A Compact provider must bind the actual full mrk4 roster and grammar-consume
  mrk3 tapes, including empty callbacks, full prefix/body/suffix lifecycle and
  stream-then-chunks order. Do not feed an invented Wide event registry or
  contiguous coordinate lane into the old callback-order algorithm. Advanced
  bucket/Copy decoders consume the original site-owned piecewise coordinates.
- The first internal GREEN is the existing test over three native root JSON
  version/layout witnesses, including V3 ADVANCED_CHUNKED with multiple chunks
  and full statistics. All selected marks prepare before EOF-first returns.
  Root runs the guarded test and the affected legacy Object/Compact regressions
  before widening to internal recursive Array/Tuple coverage. The full 48-cell
  recursive/public/offline target remains mandatory, not replaced by this
  checkpoint. Facade and OfflineColumnValue admission changes are not yet
  authorized; the static/Dynamic public rejection guards stay intact.

The bounded consumer search is
`rg -n 'ObjectDocumentInlinePrefix|ObjectDocumentInlinePlanReader|ObjectDocumentInlineBodyMaterializer|ObjectSharedAdvancedInlineDecoder' src spec -g '*.cr'`.
It identifies the inline path codec/tape callbacks, Object codec loader,
callback-order owner, advanced decoder and the existing W240 framing/tape
regressions. Preserve those callers; any additional shared-owner edit requires
an explicit inventory and seal rather than silent scope growth.

### Parser-owned callback-source extension

Root's consumer/source inventory establishes a circular dependency in the
preframed tape API: `take(name)` needs the next event offset, while Compact mrk3
discovers that offset by parsing the current prefix. The existing Compact
cursor already exposes prepaid borrowed remainders and checked parser-offset
commit. The exact, already-preframed source checkpoint below does not implement
the separate Compact grammar/source contract; public admission is still rejected.

- Add `object_shared_path_callback_source.cr`. Expand existing owners only in
  `object_shared_path_tape_reader.cr`, `object_shared_path_codec.cr`,
  `object_shared_path_json_tape_codec.cr` and `object_structure_codec.cr`.
  These are core-worker paths in addition to the preceding seal. No change to
  `compact_binary_bulk_granule_cursor.cr` is required by this contract.
- `with_self_delimited(name, parser)` borrows input and receives the parser's
  exact consumed count. The preframed reader must validate name/order/start
  before invoking the parser, pass only the current event span, and commit
  only after successful exact consumption. A failed parser, negative count,
  partial event or out-of-span count must not advance the tape. Same-source
  parser re-entry, including legacy and fixed reads, rejects before consumption;
  this is a single-owner reservation, not concurrency synchronization.
- `take_exact(name, size)` enforces the complete fixed callback extent;
  discriminator and LowCardinality prefixes still require exactly eight
  bytes. Empty callbacks remain explicit events. No unconstrained `take(name)`
  is introduced for an unlabelled mrk3 tape.
- The Compact owner uses the existing complete-granule precharge once, borrows
  from its cursor, commits only grammar-observed bytes, and binds each logical
  role to its retained site. Named mrk4 begin/finish checks must reject wrong
  roles and trailing bytes. Body slices need grammar-derived or already
  validated exact boundaries too; the common slice accessor must not become a
  shortcut that consumes the remaining mrk3 tape or invents Wide offsets.
- Thread the source through the already sealed Object prefix consumers and
  the JSON-tape body capture seam. Compact supplies its own role schedule;
  existing inline/Wide consumers retain their event registry and order. Static
  IDs remain keyless, while actual Dynamic JSON leaves retain real scoped
  `BinaryDynamicJsonLeafKey` values.
- `ObjectStructureCodec.read_with_statistics_offset` may gain a defaulted
  descriptor-relative depth argument. Existing one-argument callers preserve
  depth 1; nested callers must not reset or skip the current depth guard.
  The complete statistics context must also reach the existing full Dynamic
  prefix codec when inherited PREFIX/PREFIX_EMPTY settings require it. Retain
  explicit NONE contexts for separate per-path embedded serializations rather
  than applying complete-prefix parsing indiscriminately.

The source anchors for inherited statistics are
`SerializationObject.cpp:432-507`, `SerializationDynamic.cpp:271-326` and
`SerializationVariant.cpp:218-224` at the pinned comparison revision.
`SerializationObjectSharedData.cpp:375-420` independently establishes the fresh
Compact per-path profile with explicit NONE at line 388. Do not infer the same
prefix propagation through LowCardinality: its nested dictionary values are
serialized later from the suffix (`SerializationLowCardinality.cpp:271-312`).
The current 48-cell capture contains no JSON-valued ordinary Dynamic arm, so
that recursive context branch still needs a separate native witness before a
compatibility claim. The bounded additional consumer
search is `rg -n 'ObjectSharedPathTapeReader|decode_prefix_type_with_observer' src spec -g '*.cr'`.

Risk is CAUTION: a relaxed commit could silently hide bytes, while a wrong
statistics context could consume the next callback. Rollback is the existing
coordinate/baseline commits and one exact-path local checkpoint; no push.
Root owns `spec/object_shared_path_callback_source_w263_spec.cr`. Its guarded
DEBUG RED exits 1 at the missing source-contract require before implementation
(`d00936`); this is a missing-API discriminator, not a behavioral result.
The spec now also pins a literal full Object statistics prefix at inherited
depth 3 and refusal at depth 4 under a depth-3 limit without advancing the
callback. Ten source cases, eight lifecycle cases and five generalized-decoder
contract cases now pass with affected W240/W259/W260/W262/W263 regressions in
DEBUG and RELEASE. The unchanged three native root witnesses remain the next
internal-reader gate, not an executed source-checkpoint qualification. No
declaration/facade/carrier admission is authorized.

### Preframed common-prefix checkpoint — 2026-10-11

VERIFIED / root adversary ROBUST within the single-owner, already-framed source
and existing inline-regression scope. The exact 18-file cohort passes 131
examples in each DEBUG/RELEASE mode, zero failures/errors/pending, under the
unchanged serial 180-second / 12-GiB guard. Formatting and diff checks pass.
This is not the full suite or a native Compact JSON reader GREEN.

Own-file callback source, keyless prefix and prefix reader reuse the existing
recursive Object/Dynamic traversal. Independent literal prefixes exercise full
Object statistics, inherited descriptor depth and inferred Dynamic statistics.
Static sites use nil Dynamic keys; actual Dynamic JSON leaves keep their real
scoped keys. Existing Inline callers retain their registry-backed four-argument
advanced decoder path. Both generalized body consumers reject a foreign
physical-plan instance before plan/grid/body access, even when canonical roots
match; successful Complete static body materialization is not qualified.

Root observed behavioral REDs for inherited statistics, lifecycle guards,
caller-budget preflight, three foreign-owner paths and parser re-entry. The
caller-owned node budget is now charged before taking an event. A rejected
nested parser cannot clear the outer reservation; duplicate-name callbacks
remain separate ordered events. A diagnostic-only matcher failure was corrected
separately and is not a second behavioral finding. Correlated Luna review is
supporting evidence; root executed the falsifiers and final mode refresh.

Important remaining obligations:

- The current source requires an exact callback extent. A raw mrk3 remainder
  is not admitted. The next Compact framer must accept bounded grammar-observed
  consumption, retain only the consumed prefix bytes and enforce mrk4 exact
  named extents. Existing `ensure_consumed` calls must not accidentally treat
  the remaining whole mrk3 tape as one prefix.
- Complete static Object/Dynamic statistics offsets must reach body metadata;
  the generalized materializer still has prefix-only checks and offsets. Its
  wider signature and early owner refusal do not prove a successful static read.
- Parser budgets and metadata changes are not rolled back. Older TapeReader
  slice/LowCardinality budget failures can occur after event consumption; discard
  the enclosing failed operation, rather than assuming a general retry contract.
- Retained internal arrays remain mutable references, not immutable or linear
  ownership proof. No thread synchronization, allocation/RSS, lazy-access,
  performance, public admission or native compatibility claim is added.

Return pointer: [curated checkpoint evidence](../.landmark/evidence/compact-object-callback-prefix-w263.json).
Refresh the exact cohort and affected falsifiers after source/test/profile/
consumer drift or scope widening. Next: the sealed Compact framer/prepared
reader, three actual native roots including multi-chunk SharedData, then the
unchanged 48-cell recursive/public/offline target. Full goal ACTIVE; no push.

### Executable root-reader continuation — 2026-10-11

Risk: CAUTION. Rollback: prerequisite commit
`300dccb5bc86c6896ce25cc43baaaf859a8decd2`, followed by one coherent local
root-reader commit only after its declared gate passes; no push. The existing
unfinished native specs remain outside the prerequisite commit.

Root refreshed the exact internal-reader missing-API RED at that revision
(`290fa7`, exit 1 at `CompactStaticJsonBulkColumnReader`). This is a compile
discriminator, not behavioral/native compatibility evidence. The pinned
runtime, 48-cell summary and native manifest hashes still match the baseline.

1. **Grammar framing and prefix retention.** Core worker owns the sealed
   Compact manifest, role-schedule and site-framer files. Extend only the
   necessary shared prefix seams in `object_document_inline_plan_reader.cr`
   and `object_shared_path_codec.cr`: parsing returns its consumed count and
   retains that exact prefix span. Preframed sources still require exact
   event consumption; the distinct Compact source bounds mrk3 grammar counts
   and mrk4 named extents. Preserve same-source parser reservation. Consumers
   are inventoried with `rg -n 'with_self_delimited|take_exact'` over those
   prefix owners, TapeReader/JsonTapeCodec/InlinePrefix and the source spec:
   two self-delimited production call sites plus fixed discriminator/LC lanes.
   Guard: a prefix cannot swallow body bytes or discard named trailing bytes.
2. **Complete body metadata.** Core worker owns the sealed common body
   materializer and the indispensable existing materializer/Object codec seams.
   Preserve actual Object/Dynamic statistics offsets instead of assigning the
   end of a Complete prefix. Root's three stock-literal cases must decode via
   existing value serde and original site-owned coordinates, including real
   multi-chunk SharedData; no fake Wide registry or per-layout value decoder.
   Guard: prefix-only Inline callers and their inherited-depth refusals remain
   unchanged in the exact 18-file cohort.
3. **Prepared internal root reader.** Core worker owns the sealed prepared
   context and bulk-reader files. Reuse existing Compact precharge/cursor/grid
   mechanisms once, prepare every selected mark even at EOF, and report retained
   plus active logical workspace to the observer. Root integrates requires and
   executes `spec/compact_static_json_internal_w263_spec.cr` with
   `CRYSTAL_CLICK_W263_EVIDENCE_ROOT=/private/tmp/crystal-click-w263-multichunk-baseline.b1p2QS`
   in guarded DEBUG and RELEASE, followed by the unchanged 18-file cohort.
   Expected: all three root cases, eight literal rows and four marks per case,
   EOF-first validation and workspace assertions pass; zero failures/errors/
   pending. This is finite internal admission, not the full 48-cell target.

Root independently observed the selected native prefix bytes (`e7987a`, exit 0)
after checking the summary/manifest pins and the 10/11/11-file inventories. A
bounded Ruby/Fiddle LZ4 walk accepted 36 frames per file and compared actual
saved mark/roster intervals to the capture report. Object statistics offsets
are 22/21/23 for wire 0/2/4; note Dynamic offsets are 17/16/10 and sample
Dynamic offsets are 16/15/10. The first Object prefix retains `[8,8]` and
`zz_overflow:8`; first note/sample Dynamic prefixes retain `[0,8]` and `[4,4]`
plus `Float64:4`, respectively. These are part statistics, not two-row granule
counts. Legacy later prefixes contain `000000`; wire-4 later prefixes contain
the single empty-statistics flag `00`. The mrk3 sequential prefix ends at byte
102 on the first mark and byte 80 on later marks, before their bodies. This
refutes the earlier granule-derived Dynamic count expectation. The raw probe
checked exact LZ4 output lengths and stored-file SHA-256, not CityHash itself,
value decoding, reader admission or source/runtime identity. Retention tests
must use these observed offsets/tails rather than merely matching JSON values.

Pre-mortem: a convenient raw-remainder or rebased-lane shortcut could produce
correct-looking rows while losing callback/coordinate provenance. Root must
check exact role/extent/grid owners and add a discriminating negative before
claiming root-reader GREEN. Full recursive/public/offline admission, remaining
types/MV/projections and subsequent performance work remain deferred to their
own gates. Source and local inventory agents are read-only; root runs all heavy
commands serially under the unchanged 50%-free, 180-second / 12-GiB guard.

The next CHUNKED metadata prerequisite is separately design-sealed: add
`object_shared_chunk_structure_read_span.cr` and a span-returning seam in
`object_shared_chunk_structure_codec.cr`, preserving the existing
`read_split_records` caller contract and budget charges. Each span records the
parser-observed start/end within the one original StructurePrefix callback;
it is not a separate physical callback or a rebased coordinate domain. The
bounded `rg -n 'read_split_records' src spec -g '*.cr'` inventory finds the
physical bucket decoder and the W240 split-budget spec. Root owns requires,
execution and closure; the source worker now owns only these two production
files. Its initial test-first spec is root-owned for the added counterexamples
and final runs. Before
production edits, root must observe its missing-API RED. The focused DoD is
the new literal two-record span/truncation/budget falsifiers plus the existing
W240 split-budget cases passing in DEBUG and RELEASE; the root-reader gate
still requires all three native cases. Strongest failure: manufactured
one-header-per-callback boundaries hide the actual stream-then-chunks order.
This seam preserves the single callback and exact observed intervals; it does
not admit CHUNKED values or public JSON by itself. Rollback remains `300dccb`.

The span prerequisite is now VERIFIED / root adversary ROBUST within this
metadata seam. Root observed missing-API compile RED before the worker edits;
six independent-literal/span/truncation/budget examples plus the three existing
split-budget examples pass in the final affected 20-file cohort: 140 examples
in each serial DEBUG/RELEASE mode, zero failures/errors/pending. Multibyte
VarUInt controls distinguish byte positions from field/row counts. An actual
caller-prepaid prefix charge survives; the suffix adds once and an exhausted
aggregate byte budget rejects before record nodes. One generic parser retains
the old result capacity and post-preflight allocation point without span
wrappers on the legacy path. The source/test hashes are unchanged across the
two final runs. Separately uncommitted root-reader seams were loaded by the
cohort and are indexed, not included in the narrow metadata commit. See
[the scoped span evidence](../.landmark/evidence/object-shared-chunk-spans-w263.json).
No root-reader case, public admission, physical authentication of a manually
constructed span, full suite, allocation/RSS or speed result follows from this.

The next advanced-reader prerequisite is a structural/value phase split, not
new root admission. Risk: CAUTION; rollback anchor: `8cdd102` with the pending
MAP-reader edits preserved separately. After root observes the new API RED in
`spec/object_shared_advanced_inline_preparation_w263_spec.cr`, the source
worker may factor `ObjectSharedAdvancedInlineDecoder.prepare_inline` and
`decode_prepared`, adding one `ObjectSharedAdvancedInlinePrepared` owner and
only the indispensable inline physical-bucket preparation seam. The core MAP
worker retains the document materializer and static reader ownership; no
overlapping edits or simultaneous builds are admitted. Root has now observed
the corrected, self-contained spec's missing-`prepare_inline` compile RED
(`d6f3c2`, exit 1); the earlier private-helper diagnostic (`15d1cf`) is excluded
from the behavior discriminator. The three production files above are the
source worker's exclusive ownership; the test, requires and execution remain
root-owned.

Preparation must route the exact captured role/pair/slice schedule, preserve
the original authenticated coordinate context and suffix pairs, retain each
parser-local StructurePrefix span, and validate all raw bucket/Copy extents.
One prepared holder covers one outer mark; whole-file EOF qualification
requires every mark's holder before any selected value decode. Neither
`ObjectDocument`, `BinaryValue` nor `advanced_shared_rows` is an admitted
preparation output. `decode_prepared` reuses the existing chunk value serde;
the old `decode` path delegates through both phases without widening layouts.
The holder binds the exact read-operation budget identity; decoding with a
fresh budget must reject before values rather than reset cumulative ceilings.
Cross-operation cached-holder reuse is not admitted by this seam and requires
its own budget-rebinding design. Raw Copy/path data retained for value decoding
must be detached from mutable captured input; post-preparation Copy input
mutation must not change the prepared decode result.

Root's cross-source adversary observed a valid value substitution through a
public raw-artifact `seal` factory (`0b7e58`: expected refusal, no exception;
source A contained `first` and the substituted source B decoded `worst`).
Replacing only Copy was correctly rejected by the existing per-path equality
check; that partial attack does not establish the provenance failure. The
repair admits only a source-input factory, invoking the validated raw parser
before a private artifact-to-holder boundary. The same attack must now fail
compilation on private `seal` access, separately from positive runtime tests.
The negative compile witnesses are selected with `-D w263_raw_state_mint_attack`
and `-D w263_raw_state_constructor_attack`; both must fail with their exact
private-access diagnostic, not an unrelated compiler error. Neither is counted
as a passing runtime example. The partial advanced holder
workspace census is removed rather than promoted to a full accounting claim.

The parallel MRK4/MAP staging reader must share one request budget across
preparation and every selected mark, including its implicit-budget path.
Prepared raw streams must not be publicly returned: retained owners expose
mutable borrowed slices. A budgeted context decode delegator may return only
newly decoded documents; prefix metadata getters remain detached snapshots.
Standalone workspace observations are estimates, not enforcement of a
combined transient-memory ceiling or RSS. These guards do not admit MRK3,
advanced shared data, the other two mandatory native roots or public/offline
JSON integration.

The distinguishing test is a well-framed semantic payload error: preparation
accepts its raw extents, then value decoding rejects it. Framing, callback,
roster and saved-pair corruption must instead reject during preparation. A
manufactured relocated-tape test certifies this phase boundary, not native
Compact physical provenance. This prerequisite is now VERIFIED / root adversary
ROBUST within the declared inline scope. Its clean staged-source export excludes
the separately pending MAP reader and prefix seams: five focused examples plus
the existing 140-example affected cohort pass in root-owned serial DEBUG/RELEASE
runs (145 examples per mode, zero failures/errors/pending). Source hashes remain
unchanged; both private-access negative compile guards also discriminate at this
snapshot. Missing-API RED is not behavior evidence. See the
[phase-split evidence](../.landmark/evidence/object-shared-advanced-preparation-w263.json).
The mandatory three stock-native roots and full 48-layout target remain open
until their own gates pass.

Static JSON site identities remain separate from actual Dynamic keys. Offline
materialization must use one logical
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
The corrected multi-chunk collector now builds in DEBUG and passes a fresh
48-cell native baseline. This does not close the internal reader RED or admit
any public JSON column.

Current multi-chunk baseline evidence:
`/private/tmp/crystal-click-w263-multichunk-baseline.b1p2QS/summary.json`.
Root's guarded helper build and native baseline both exit 0. Independent live
audit checks all 504 captured file sizes/hashes, the raw runtime pin, 48 actual
successful CHECK results and 384 native literal rows. The same six persisted
triples occur in 32 granules each; UInt64 controls and the complete 384/144
public/offline refusal products remain intact.

For every CHUNKED cell, the collector compares the actual mrk3 whole-column
tape to the ordered mrk4 shards. Five distinct Object sites (root, docs,
tagged.doc, pair.left, pair.right) retain full structure statistics and actual
split chunk records. Each site has a real multiple-chunk mark. The 160 reported
site/mark entries contain 736 one-row chunk records; paired mark-format reports
share the same mrk4 schedule witness and are not independent observations.
Outer Array sizes are decoded from the named persisted UInt64 callbacks and
checked against separate literal per-parent vectors, including empty and
unequal children. Root's three isolated report-contract seeds reject a
same-total reordered size vector, merged chunk records and a reordered Object
callback roster. These are auditor sensitivity checks, not production-reader
corruption tests.

The old runtime directory disappeared before this fresh capture. The official
immutable artifact was recovered to
`/private/tmp/crystal-click-w263-runtime-recovery.B9uAPX`; carrier, expanded and
stripped sizes/hashes match the existing pin exactly. No version substitution,
source/runtime equivalence or latest-upstream claim is made. The qualified
baseline and recovery identities are indexed in
[native baseline evidence](../.landmark/evidence/compact-json-w263-native-baseline.json).

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
