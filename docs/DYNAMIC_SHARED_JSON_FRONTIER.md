# Dynamic SharedVariant inline JSON — W213

Document status: implemented and verified within the finite W213 scope (2026-10-07).
Baseline: `515d10c7b76378575a018c09aa354a7bc9ebfae3` (2026-10-07).
The full type, MV/projection and eventual performance goal remains active.

## Boundary

Required capability: read and write JSON-bearing scalar envelopes in the
implicit SharedVariant String arm of the generic Dynamic bulk/physical/table
route. Reuse BinaryValueCodec's recursive scalar grammar and BinaryJsonValueCodec;
do not manufacture Object bulk bindings or a codec for each wrapper product.
The enclosing Dynamic nominal declaration itself remains JSON-free.

Implemented admission: legal JSON-bearing actual descriptors already accepted by
the scalar owner, at their inherited occurrence depth, using the same operation
budget. Ordinary JSON actuals still require the W212 exact Object leaf bindings.
Inline shared JSON requires no Object binding: it is a descriptor followed by
one scalar value inside a String frame. Root and outer Array(Dynamic) are the
native-qualified carriers below, not the complete layout/product space.

Retained guards: default specialized helper calls, generic borrowed envelopes,
legacy DynamicValueCodec, Object shared MAP/Copy, unbound ordinary JSON arms,
nominal JSON bulk declarations, JSON SKIP/SKIP REGEXP, unsupported versions and
CH-illegal combinations. Object path Dynamic binding composition, owned offline
values, MV/projection propagation and broader facade decomposition remain next
tracks. No performance work, functions or joins in this slice.

## Design laws and consumer inventory

- SharedVariant is a String lane containing an inline binary descriptor and
  scalar serde. With an empty ordinary roster its canonical discriminator is
  zero; Dynamic NULL is 255. JSON default/empty objects are not Dynamic NULL.
- The common scalar visitor owns wrappers and JSON callbacks. Scalar String
  framing inside an envelope is independent of the outer bulk String profile.
  Only the outer String may use the separate size stream.
- Preserve inherited depth, node/edge visits and pending final-frame wire
  reservation. The physical owner pays final wire bytes exactly once; do not
  call the root public scalar codec with a fresh budget.
- Use an explicit default-false opt-in on the specialized Dynamic child helper.
  Only the two current production BinaryBulkEncoder/Decoder SharedVariant call
  sites enable it. These public methods are internal by convention; this is
  call-site discipline, not access control. The same
  helper is used by ObjectSharedCopyCodec; its existing guard must stay closed.
- Complete P/Q grids and lane closure remain required, including empty windows.
  Selected-arm String lanes have R elements, not Q NULL placeholders. Physical
  marks retain P; raw `.mrk2` words include the terminal zero sentinel.
  Do not claim semantic validation of unselected shared payloads when the
  inherited selected-window reader does not parse those payloads.
- Staged publication compares deep JSON paths and content via the existing
  W212 comparator. Native value oracles must be independently authored, not
  copied from the library readback. JSON row path and typed descriptor path
  iteration order need not agree across implementations; exact descriptor/value
  maps must agree. Stock encodes typed paths from an unordered_map. Canonical
  library envelope bytes must still agree with an independent literal oracle.

Inventory command: `rg -n 'encode_dynamic_bulk_child|decode_dynamic_bulk_child'
src spec`. Production consumers: BinaryBulkEncoder, BinaryBulkDecoder and
ObjectSharedCopyCodec. Generic borrowed helpers additionally serve legacy
DynamicValueCodec and Object shared MAP/document owners; they are not widened.
Existing specialized-helper, W180/W182 JSON guard and W206 tests should keep
their default-call fences. W212 ordinary bound Object behavior stays unchanged.

Source anchor: shallow ClickHouse reference
`0ca8150d9b1d0886edb2e3b4ab65eebb768d0357`,
SerializationDynamic.cpp:755-779 (shared bytes already in scalar format),
SerializationObject.cpp:1184-1231 (typed paths and dynamic/shared envelopes).
The separately pinned stock executable is build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, not this source build.

## Execution and DoD

CAUTION: serialization admission. Rollback: exact scoped diff from the clean
baseline, then one atomic local feature commit after verification; no push.
Likeliest failure: a matching scalar reader/writer mistake, accidental Copy
widening, lost inherited depth, or confusing NULL with an empty JSON value.

1. Root qualifies actual stock Dynamic(0) JSON and wrapper values. Worker writes
   compiling public behavior tests; root executes the missing-capability RED
   before production changes. Compiler errors are not the feature RED.
2. Change only BinaryValueCodec and two generic shared-arm call sites; preserve
   all default-call guards. Add focused normalized/physical tests for literal
   wire bytes, typed NULL, multiple leaves, empty arrays, malformed/trailing and
   duplicate paths, inherited depth and aggregate limits.
3. Execute focused DEBUG/RELEASE and an explicitly enumerated affected corpus
   under the existing serial guard: Crystal 600s/12288 MiB, min free memory 50%.
   Expected signal: actual exit zero, zero failures/errors/pending.
4. Build immutable helpers from the tested source and run fresh paired stock
   reads plus direct library ATTACH/CHECK in both String profiles and modes.
   Exact manifest/file roster, marks, descriptor identity, shared placement and
   independent full/middle/final/EOF values must agree. Ruby outer guard is
   120s/1024 MiB; native children remain bounded to one thread/512 MiB.
5. Root hostile review executes defect seeds for wrong JSON content, profile
   framing, budget/depth inheritance or opt-in leakage. Restore exact bytes,
   rerun focused gates, record only executed evidence, and commit exact paths.

Focused command: guarded `crystal spec spec/dynamic_shared_json_w213_spec.cr
spec/dynamic_shared_json_physical_w213_spec.cr --single-module --threads 1
--link-flags=-fuse-ld=ld --error-trace`, plus `--release`.

## Entry evidence

Root's bounded stock qualifier returned the pinned version/build and successful
shared-data assertions for direct JSON, Array(JSON) and Tuple(JSON, JSON)
actuals in Dynamic(max_types=0), with typed Nullable NULL retained. Actual
guarded exit was zero. This is a scalar/shared-placement qualifier, not a
persisted-part interoperability witness.

The two initial W213 public API tests compiled on the clean W212 production
baseline and both raised the existing JSON guard in
BinaryValueCodec.encode_dynamic_bulk_child. The combined seven-example run
also exposed one pre-existing stale W180 metadata assertion, independently of
the feature RED. That assertion now admits Array(JSON) representational
metadata while requiring the unbound ordinary value plan to fail. Its five
examples pass under the unchanged compiler guard; default helper, borrowed,
legacy Dynamic and Object guards have not been removed.

The same 86-file affected corpus passes 528 examples in DEBUG and 528 in
RELEASE, with zero failures/errors/pending under the unchanged compiler guard.
The formatted last cohort was rerun in both modes. Four independent temporary
production mutations each produced exactly one assertion failure (nine examples,
zero errors/pending): encode-default opt-in leakage, decode-default opt-in
leakage, lost framing reservation and shared decode depth reset. Production
files and the complete core source hash were restored exactly.

The focused scalar suite also checks an independently authored default JSON
envelope containing an untyped Array(UInt8) path. This is local scalar-wire
evidence, not a stock-qualified runtime-array-path claim. The typed NULL scalar
visit budget and inherited outer-Array decoder depth have exact boundary tests.

Two stale W180/W182 metadata assertions were corrected: wrapped JSON descriptor
metadata is accepted, but an unbound ordinary value plan still fails. No
DynamicStructure production code was changed for these corrections.

Initial native oracle failures were not production format falsifiers: SQL
Dynamic NULL propagates to TSV `\\N`, NULL consumes no selected SharedVariant
String element, and stock typed JSON descriptor paths are unordered. The
independent oracle was corrected under the same finite matrix and caps. Stock
descriptors admit either iteration order only after exact typed-map validation;
library envelopes remain byte-exact against independently authored canonical
literals. Wrong typed-child and changed-value mutations are rejected.

## Final native evidence and remaining frontier

Fresh DEBUG and RELEASE matrices each cover four actual families in both
String profiles: direct JSON, Array(JSON), Tuple(JSON, JSON), and an outer
Array(Dynamic) carrying Array(JSON). Each mode reads eight stock parts and
directly ATTACHes/CHECKs eight library parts, with eight source CHECKs and eight
library CHECKs. Full, first, middle, final, EOF, candidate and typed-table values
agree with independent literals. All 140 generated library-part files agree
byte-for-byte across modes. Native format is Wide/LZ4/plain `.mrk2`, Dynamic v3
and noncompact Variant discriminators; these witnesses do not admit all layouts.

Root audits raw invocation records, SQL/stdout/stderr identities, immutable
helper/input/runtime hashes and complete P/Q grids. A temporary Ruby oracle
mutation changes only expected JSON counters; the stock process exits zero and
the independent value assertion rejects it. The unique-line inverse patch
restores the runner, then both fresh native matrices pass again. Inherited
compiler-sized evidence metadata was removed: the outer Ruby guard is actually
120s/1024 MiB, separately from the bounded native child. Runner declarations
are not measurements. Helper identity is retained separately from helper output.

Scoped Adversary verdict: ROBUST for this component and the executed corpus.
No all-product/layout, checksum-hash, selected-window complexity, whole-scan
callback atomicity, transient RSS, MV/projection or performance claim is made.
BinaryJsonRow's inherited fresh validation context remains an owner-accounting
gap, not an admission-depth bypass: the envelope parse uses inherited limits.
The helper opt-in remains public/internal-by-convention, not access control.

Next: Object path Dynamic JSON bindings; owned offline-column values;
projection/MV consumer propagation; remaining physical layouts and JSON
SKIP/SKIP REGEXP. Broad class decomposition and inherited owner-accounting
gaps remain open. Evidence: `.landmark/evidence/dynamic-shared-json-w213.json`.
Raw evidence is ephemeral under `/private/tmp`; refresh after scalar descriptors,
JSON grammar, shared framing, budgets, grids, consumer opt-in, runtime or layout
changes. The overall goal remains active and performance remains deferred.
