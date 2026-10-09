# Object shared JSON composition frontier — W240

Document status: VERIFIED within the eight finite shared-layout/String profiles
and tested guard boundaries; root adversary verdict ROBUST within scope.
Baseline at the start of this slice: `d217f75` rejected JSON-bearing values
in Object shared MAP/Copy envelopes and ordinary JSON per-path Data bodies.
Recursive JSON descriptor/scalar serde and Dynamic JSON child Object owners
already exist. This is an owner/layout integration gap, not a new leaf grammar
or a request for a serializer for every wrapper product.

## Current execution checkpoint

Local checks at the current production source state pass 611 examples per mode:
512 in the 85-file main roster and 99 in thirteen isolated JSON/Dynamic control
files, in both DEBUG and RELEASE. These are 98 selected files, not the whole
suite. The grouped Proc-alias compiler symptom also reproduces on a clean W239
baseline; isolated execution preserves coverage without claiming a compiler fix.
The current helpers are `helper-debug` and `helper-release` under
`/private/tmp/crystal-click-w241-carrier-helpers.jL3VSH`; both guarded builds pass.

All four DEBUG/RELEASE x frame32/frame64 seal captures complete all eight
coordinator profiles with both native negative effects observed. All four
complete raw audits and adversarial self-tests pass with final auditor SHA
`2751fc87f72522e2ec70821c7c8b7bc646fd03a92dc672ab8df2f25b29635a34`.
Coordinator success alone is not raw-byte qualification.
All 336 files in the eight positive and two negative generated parts match by
actual bytes across modes at both frame sizes: 224,893 bytes per mode at frame32
and 183,845 at frame64. The input envelope is not a part file and is excluded.
Incomplete roots and the older complete coordinator capture
`/private/tmp/crystal-click-w241-debug32-rerun6.fDRM8s` remain retained rather
than counted as native format refusals or final certificates.

Root independently calibrated the actual generated CREATE/ATTACH/CHECK/schema/
active-PART/query joins and exact original-to-attached file bytes. The only
native-added file is `invalidated_system_columns.txt` with exactly
`_block_offset\n_block_number\n`. Sixteen actual stock/generated physical-layout
controls and missing-lane negatives pass. Focused advanced binding checks now
address auditor-only namespace and empty-array assumptions. Final qualification
also authenticates exact compact-summary projections and genuine process
failure observations; no production codec was changed by these harness repairs.

Retained discriminators and decisions:

- The Object reader has four real marks [2,2,2,2]; physical mrk2 also has its
  zero-row EOF sentinel. Empty terminal reads are (4,0), not a fifth granule.
- Ordinary BinaryValue equality is identity. The helper uses an exact
  recursive structural comparator; an independent ADVANCED/s0 probe rejects a
  same-length nested String mutation without changing global equality.
- Table-wide metadata contains pk and doc; Object-reader roles are doc-only.
  Visitation order and map insertion order are not physical wire contracts.
- Reused W240 String-s1 stock sources have pk UInt8; fresh s0 sources and all
  generated parts have pk UInt64. Schema validation is role/profile-specific,
  not a loose type union. Roles, source writes, active paths and query tables
  are authenticated before dependent checks.
- The low-level selected-path carrier is Dynamic(max_types=254), whereas
  native SQL exposes Dynamic with the Object schema's default cap32. Only the
  closed unhinted outer carrier is projected once. Exact selected-path actual
  descriptors/caps and values are compared; no SQL wrapper type equality is
  claimed.
- The canonical stock empty arr values are Array(Nullable(String)), while
  populated values are Array(JSON(...)). A per-path occurrence need not use a
  JSON arm. Stock registers that non-JSON empty-array actual; the prepared
  generated writer leaves it in SharedVariant instead. Dynamic's registered
  arms can also outlive one mark's used values. Registry membership, occurrence
  counts and prefix callbacks are separate contracts, not interchangeable
  observations.

Nested stock Dynamic child actual types inside Array(JSON) are not independently
cross-checked against native SQL or a separate physical descriptor parser.
The helper reports stock v Int64 and the prepared generated plan reports v
UInt8, but normalized JSON equality does not establish this child-type fidelity.
Do not describe the native oracle as a complete nested type-tree comparison.
The generated explicit child descriptor and helper assertions are distinct
evidence from an independent nested Dynamic child-type oracle.

The closing signal is four successful complete raw audits, not just the local
paired codec or coordinator matrix. Auditor-only repairs include explicit key
domains, exact emitted negative inventory/query projections and distinguishing
the actual server Copy read
exception from an infrastructure failure. Reopened records retain additional
columns/layout, wrapper-type, bounded-window and zero-selection checks; a
compact summary is joined through its exact emitted fields, not equated to the
whole raw-parser result. Both negative effects must be observed for
qualification; an internally consistent inconclusive capture is not a pass.
The curated [W240/W241 evidence index](../.landmark/evidence/object-shared-json-w240.json)
records exact gates, source/runtime/helper pins, capture roots and decay rules.
It is an index to observed evidence, not proof by its fields alone. Earlier
coordinator captures predate the final classifier-only coordinator source; all
four were re-audited with the final auditor. No immutable cryptographic
execution-provenance claim is made.

Next falsifier: qualify a still-guarded prepared JSON-bearing actual with nested
Dynamic sites through an exact physical child binding/occurrence oracle and
independent native direct/full/bounded reads before widening prepared admission.
The independent stock nested Dynamic child-type oracle remains a separate gap.
No remote push, all-product claim or memory/performance improvement is claimed.

## Target and retained boundaries

Qualify and then compose legal JSON-bearing shared values in Object V3 across
MAP, MAP_WITH_BUCKETS, ADVANCED and ADVANCED_CHUNKED. Read stock-authored parts
and publish library-authored parts that stock can ATTACH, CHECK and read.
For advanced layouts, both whole-Object Copy and selective per-path Data need
coverage; enabling only the scalar Copy helper does not admit this target.

The bounded target is quiescent Wide/LZ4/plain-mrk2 storage with explicit
serialization profiles. Default borrowed-value APIs retain their existing
rejections. A shared-JSON opt-in must not accidentally admit Dynamic, Variant,
LowCardinality, AggregateFunction, QBit or Custom owners in a context where
they were previously guarded. Existing independently admitted Copy/Dynamic
policies remain separate. Illegal type trees are not implementation gaps.

No function engine, Compact MergeTree-part promise, all-type-product claim,
performance/RSS claim, broad facade refactor or remote push is included.
Memory/performance remains deferred; the overall objective remains ACTIVE.

## Source and existing owners

Inspected separate depth-one ClickHouse source:
`f25eb93a0b890a3b87df05eb34e2af1f933b4089`,
`/private/tmp/crystal-click-w238.4nQqSo/clickhouse`.
Native qualification uses a separate pinned runtime, not a build of that source:
`26.10.1.1201`, build `d9bcb5ab007f0f6299f7f973f2642245bab3d028`,
SHA256 `bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.

- `DataTypeObject.cpp:848-856` accepts zero dynamic paths;
  `1429-1464` describes arrays of objects as Array(JSON) at Dynamic paths.
- `SerializationObjectHelpers.cpp:18-71` materializes each shared path as a
  dense Dynamic column with defaults for absent outer rows.
- `SerializationObjectSharedData.h:31-74` distinguishes the four layouts and
  the purposes of advanced per-path Data and whole-column Copy.
- `SerializationObjectSharedData.cpp:375-420` delegates path bodies to ordinary
  Dynamic serialization with Compact framing, Object V3, inherited nested
  shared-data version, and callback-ordered substream marks.

Existing Crystal integration seams:

- `BinaryValueCodec`, `BinaryJsonValueCodec`: recursive scalar envelopes;
  borrowed defaults are narrower than specialized Dynamic child helpers.
- `ObjectDocumentSharedCodec`, `ObjectSharedMapCodec`, and
  `ObjectSharedCopyCodec`: distinct shared-envelope callers and framing budgets.
- `BinaryBulkEncoder` / `BinaryBulkDecoder` and
  `BinaryDynamicBulkJsonObjectWriter` / `BinaryDynamicBulkJsonObjectReader`:
  recursive bulk traversal and exact JSON-leaf Object bindings already exist.
- `ObjectSharedPathCodec` / `ObjectSharedPathTapeReader`: Compact per-path
  prefix/body callback order; JSON bodies are currently rejected explicitly.
- `ObjectSharedAdvancedChunkCodec`: cross-checks Copy against dense Data rows;
  its JSON equality branch currently needs an inherited-budget audit.

## Recursive composition versus physical layout qualification

Container products must reuse child serde. `BinaryValueCodec` already recurses
through Array, Tuple, Map, Nullable and Nested values; bulk discovery also walks
child descriptors. A product such as `Array(Tuple(JSON, UInt8))` is not a new
leaf wire grammar. Containers nevertheless own cardinality, substream routing,
prefix/body/suffix state and mark coordinates. An empty Array must still preserve
the required child callback schedule. LowCardinality dictionaries and sparse
Variant arms need their own state and row-domain transformations.

Qualifying a scalar envelope does not qualify the corresponding columnar part
layout. W240 reuses the established leaf codecs and composes those physical
owner contracts; it does not add a serializer for each product.

One remaining implementation asymmetry is a JSON-bearing Dynamic actual with
a non-JSON nested-Dynamic sibling, for example `Tuple(JSON, Array(Dynamic))`.
`ObjectSharedAdvancedJsonActualPlan` rejects it explicitly. Generic paired path
serde passed an isolated executable probe with an explicit JSON leaf binding,
a nested String Dynamic site, a populated and an empty child Array, and NULL
outer Dynamic. Its independent comparator rejected a changed nested String.
The probe is `/private/tmp/crystal-click-w240-recursive-json.67ge3n/probe.cr`;
the guarded DEBUG command returned exit 0. Two earlier attempts failed only in
the probe import and zero-child container comparator, before useful closure.
Neither the combined native shape nor the public physical path reader has been
qualified. This is an open layout/admission question, not a proven native type
prohibition or a reason to remove the prepared writer guard without that proof.

## Design obligations before production edits

1. Reuse child serde; do not add Array(JSON), Tuple(JSON), or other per-product
   serializers. A container owns routing, cardinality and state, not a duplicate
   child grammar.
2. Distinguish scalar inline JSON from columnar Object substreams. Ordinary
   JSON arms require exact child bindings and prefix/body state, not a call to
   the scalar row encoder substituted into a column stream.
3. Carry one operation budget, inherited depth, complete physical occurrence
   grid, selected mark domain and serialization profile through every bridge.
   An Array expands child occurrences; a Variant selects sparse child rows.
4. Preserve exact prefix/body/suffix callback order and physical names.
   A late-first path, empty child batch, or unused arm must not reset state or
   turn physical row counts into parent row counts.
5. Keep advanced Copy and Data consistent with bounded structural comparison.
   Neither successful whole-column reconstruction nor forced SharedVariant
   writing alone proves ordinary JSON-arm Data support.
6. Put any new cohesive owner in its own file; avoid unrelated facade changes.

## Ordered discriminators and DoD

1. Stock-only qualification: run
   `ruby scripts/probe_object_shared_json_w240.rb --clickhouse RUNTIME --evidence-root EMPTY_DIRECT_CHILD_OF_PRIVATE_TMP`
   under the existing serial resource guard. Expected: all four persisted
   layouts, exact runtime pins, CHECK=1, and exact direct/full logical values.
   Direct-only and full-Object queries must run in distinct restarted processes;
   inspect actual physical stream rosters rather than only requested settings.
2. Before production edits, execute a behavioral RED at the identified shared
   MAP/Copy and ordinary JSON-arm path-Data seams. A compiler/process/SQL error
   is inconclusive, not the required compatibility refusal.
3. Seal the concrete child-binding/tape design and exact changed paths, then
   implement scalar opt-in and physical composition with disjoint ownership.
4. Run focused and affected DEBUG/RELEASE specs serially. Expected: no failures,
   errors or pending examples; existing borrowed and mixed-owner guards stay
   closed. Exact commands/spec roster must be recorded before admission.
5. Paired native qualification must read stock parts and independently ATTACH,
   CHECK and read generated parts, including full, middle and empty terminal domains,
   explicit String profiles, empty/pathless rows, and a late-only Array(JSON)
   path. Verify actual Data/Copy agreement and native ordinary JSON rosters.

Strongest failure mode: full-Object/Copy succeeds while selective ordinary JSON
Data is absent or mismatched. Guard: separate direct-only restarted queries and
checksum-valid corruption of only late Data, preserving Copy. Also exercise
late Copy truncation, nested depth/work caps and retained borrowed rejections.

Production risk: CAUTION (persistent serialization). Rollback: one coherent
local feature commit after its DoD passes; preserve unrelated work and never
discard the baseline. No production file is changed by the stock-only probe.

## W240 scalar-envelope implementation seal

Status: design-sealed after the executed runtime RED; physical per-path Data
remains guard-only until its binding/tape design is sealed separately.

- `BinaryValueCodec` gains the named paired
  `encode_shared_json_envelope(value, budget, reserved_wire_bytes = 0)` and
  `decode_shared_json_envelope(bytes, budget)` entry points. Their sole admission
  delta from borrowed persisted envelopes is JSON, including already supported
  static container descendants. `encode_borrowed` / `decode_borrowed` keep their
  signatures and rejection policies. Existing Dynamic, Variant, LowCardinality,
  AggregateFunction and QBit exclusions remain exclusions in the new MAP context.
  Preserve existing Custom behavior rather than inventing a new blanket fence.
- `ObjectSharedMapCodec` and `ObjectDocumentSharedCodec` use that named pair;
  the bucket owner already delegates to the latter. Keep existing complete-lane
  decode charging, envelope-root depth, document encode wire reservations and
  cumulative shared-budget accounting. MAP's existing incremental reservation
  policy is unchanged; this is not a new RSS or allocation-efficiency claim.
- `ObjectSharedCopyCodec` keeps its independently admitted specialized Dynamic
  child helper and adds only `allow_json: true`. Existing Custom, aggregate and
  recursive QBit/Variant policies must not change as a side effect.
- Kernel ownership: these four production files and new
  `spec/object_shared_json_envelope_w240_spec.cr`. Other workers must not edit
  them. The existing W240 integration RED remains the shared final discriminator.

### Hidden JSON descendants: guard refinement

The first executed focused DEBUG roster passed all new scalar examples but
retained two obsolete W192 JSON-refusal expectations: 61 examples, 2 failures,
0 errors/pending. Root updated those two exact Copy specs to assert admitted
JSON descriptor/value roundtrip and retain the unsupported-actual adversary
with AggregateFunction(count). The same roster then passed 61/61.

Source review exposed a different policy hole: generic descriptor summaries
do not traverse JSON's typed metadata or runtime path descriptors. The root
authored `spec/object_shared_json_envelope_w240_adversary_spec.cr` constructs
legal existing scalar JSON runtime paths containing Array(Variant),
Array(Dynamic) and Array(LowCardinality). Its corrected scalar control verifies
exact descriptor/value consumption by decode/re-encode, not generic owner
identity equality. The write and read refusals all failed: 6 examples,
6 assertion failures, 0 errors/pending, exit 1. This is a behavioral admission
falsifier; the initial identity-equality control was invalid and is not evidence
of a serde defect.

The narrow shared MAP envelope policy must cover every serialized DataType
node, including JSON metadata and inline runtime path descriptors. Seal the
following refinement before edits:

- Add one cohesive `BinarySharedJsonEnvelopePolicy` owner in
  `src/crystal_click/binary_shared_json_envelope_policy.cr`. It rejects exactly
  Dynamic, Variant, LowCardinality, AggregateFunction and both QBit wire tags;
  JSON, ordinary static containers and the existing Custom alias behavior are
  not blanket-rejected.
- Append a default-off internal selector to `BinaryCodecContext`, enabled only
  by the named shared JSON envelope pair. Call the policy at the existing
  recursive `BinaryDataTypeCodec.write_to` / `read_from` node boundary. This
  reuses existing depth/work/wire accounting rather than running a separate,
  reset-budget traversal or scanning only generic descriptor children.
- The default descriptor/scalar codecs, borrowed defaults and specialized
  Copy/Dynamic helpers retain their current policies. Copy's independently
  admitted Variant/LowCardinality behavior must not acquire MAP's narrower
  exclusions. Unsupported wire ownership remains UnsupportedFormatError,
  not fabricated corruption; malformed framing remains CorruptPartError.
- Kernel ownership expands only to `binary_codec_context.cr`,
  `binary_data_type_codec.cr`, the new policy file and a new focused hidden
  typed-metadata/control spec. Root retains the admission falsifier and the
  two legacy W192 expectation updates. No physical owner may edit these paths.

DoD: execute the root hidden-descendant falsifier plus the focused envelope,
descriptor/scalar/JSON and retained MAP/Copy guard roster in DEBUG and RELEASE.
Expected: zero failures/errors/pending and unchanged ordinary scalar JSON
controls, exact envelope counters/reservations and Custom baseline. Rollback
remains the single coherent W240 feature diff; no partial completion is sealed.

The bounded `rg` caller inventory found MAP envelope calls at
`object_shared_map_codec.cr:91,148`, document calls at
`object_document_shared_codec.cr:71,151`, and Copy calls at
`object_shared_copy_codec.cr:111,221`; bucket and high-level document owners
delegate to these codecs. Negative tests retain each original policy and shared
work/depth/wire limits. Positive tests include Array(JSON), a deeper static
wrapper, independently framed decode, and JSON present only in a late entry.

Root DoD before combining with the physical feature: serial DEBUG/RELEASE
`crystal spec spec/object_shared_json_envelope_w240_spec.cr` plus the exact
affected envelope/Object/Copy guard roster, with the established single-module,
one-thread and macOS linker flags. Expected: zero failures/errors/pending.
Final W240 closure still requires all integration RED cases, actual public
reader/writer consumers, native paired parts, Data/Copy controls and hostile
review; the scalar seal cannot substitute for that capability.

## W240 physical Data implementation seal

Status: design-sealed; implementation and paired native checks still open. The
scalar-envelope candidate passed the exact 25-spec descriptor/scalar/JSON and
MAP/Copy guard roster in DEBUG and RELEASE: 170 examples each, zero
failures/errors/pending. This does not establish physical Data compatibility.

### Prepared writer policy and inherited context

- Add `ObjectSharedAdvancedJsonActualPlan` and
  `ObjectSharedAdvancedJsonWritePolicy` as separate cohesive owner files. An
  actual plan holds one exact immutable `BinaryDataType` and descriptor-relative
  JSON child plans, e.g. `[0]` for Array(JSON). Snapshot roster/path arrays and
  do not expose mutable internal arrays. Bound and validate unique exact actual
  descriptors, unique complete JSON leaf paths and exact child JSON types.
  The policy accepts `max_ordinary_types` in 1..254, default 16. Match types by
  structural equality, not SQL display names. Policies never supply reader
  bindings.
- For each shared path in each physical chunk, only observed policy-prepared
  JSON actuals enter that chunk's ordinary Dynamic roster. Deduplicate and
  canonicalize through the existing DynamicStructure owner, then rederive the
  exact JSON keys/arm indices and rebind prepared descriptor-relative plans.
  Reject unprepared JSON actuals or an exceeded ordinary cap. Non-JSON values,
  including the native empty Array(Nullable(String)) carrier, stay spilled.
  Nil policy preserves the existing Dynamic(max_types=0), all-spill route.
- Add immutable `ObjectSharedNestedSerializationContext` with inherited
  `shared_data_version`, optional `target_chunk_rows`, and child String
  profile (Compact remains fixed by the tape). `for_write` requires a positive
  target; `for_read` leaves it unknown (`nil`). Carry it through child Object
  encode/decode. Writer version/target must not silently fall back to defaults;
  readers consume actual persisted row schedules and never infer a target.
  No independent operation budget or physical occurrence grid may be created.

### Paired tape APIs and public consumers

- Extend the no-statistics Dynamic bulk plan with exact JSON bindings and a
  loader-based decoding sibling. Reuse the existing JSON bulk child owners and
  StorageOccurrenceGrid. Add `ObjectSharedPathJsonTapeCodec` for exact inline
  prefix/body/suffix callback order and `ObjectDocumentInlinePlanReader` for
  bounded child metadata discovery. Readers derive bindings from each actual
  inline prefix and child metadata, not a single caller-supplied global roster.
  Prefix/body callback capture is separate from value decoding: reuse the
  existing `BinaryDynamicBulkJsonObjectReader` physical-child loader after its
  `BinaryDynamicJsonObjectSchedule` census supplies the explicit
  `StorageOccurrenceGrid`. Never infer child occurrences from a convenient
  lane or replace parent physical rows with expanded Array child counts.
- The first inline child-plan frontier retains the existing Object typed-field
  declaration grammar and admits child root/typed Dynamic actuals only when
  they do not themselves require further JSON child bindings. Further
  JSON-bearing Dynamic actuals are explicitly guarded on both the prepared
  writer and persisted-prefix reader until complete recursive metadata binding
  discovery is qualified. This is not a missing scalar grammar or a claim that
  nested JSON is globally illegal. Direct typed JSON fields are not a shortcut
  around the existing persisted Object declaration grammar.
- Nested advanced shared streams need their own Compact callback assembly,
  not the existing Wide physical bucket byte layout. The pinned source at
  `SerializationObjectSharedData.cpp:746-907` groups all chunk prefixes, then
  Data, metadata and suffixes per bucket, followed by stream-then-chunk Copy.
  Add a cohesive `ObjectSharedAdvancedInlineCodec` using existing chunk/path
  and Copy owners. Carry any metadata-coordinate relocations explicitly into
  the enclosing Data assembly; zero marks or presumed single-frame storage
  are not a substitute for observed compressed-stream coordinates. The paired
  reader must validate bounded callback extents and reconstruct exact child
  Copy/chunk domains, including nonempty stock child shared paths. Qualification
  of root selected-path Data does not imply selective nested child reads.
- Add named `ObjectSharedPathCodec` paired entry points
  `encode_with_json_children_with_budget(type, structures, rows, budget,
  leaf_bindings, nested_context, profile)` and
  `decode_with_json_children_with_budget(data, events, row_count, type, budget,
  nested_context, profile)`. Legacy signatures and unbound-JSON guards remain.
- Forward optional `shared_json_policy` and positive
  `shared_target_chunk_rows` (default 1) through
  `WidePartWriter.write_uint64_object_pair` -> ObjectPartWriter ->
  ObjectDocumentColumnWriter -> ObjectSharedAdvancedDocumentCodec -> chunk
  codec. Opt-in version-3 qualification uses target 2; existing callers keep
  their prior chunk schedule by default. Both explicit String 0/1 profiles are
  tested. The shared lanes' separate existing profile restrictions remain.
- Add `ObjectColumnReader#read_shared_path_marks(path, first_mark, mark_count)`
  returning marks -> dense Dynamic values. Advanced selection must consume
  only the requested path's value Data, without decoding root Copy payloads or
  reconstructing the full Object. Part inspection may still resolve root Copy
  names and physical sizes. MAP selection may decode shared MAP lanes; it is not a selective
  physical Data promise. Full advanced reads keep Data/Copy agreement checks.
- Replace unbudgeted JSON owner equality in the advanced Copy/Data comparison
  with recursive bounded structural comparison using that operation's budget.
  Scalar encoded-byte equality is not a substitute for columnar agreement.

### Disjoint ownership and verification

Core worker owns `binary_dynamic_bulk_plan.cr`,
`binary_dynamic_bulk_json_object_writer.cr`, `object_shared_path_codec.cr`,
`object_shared_path_tape_reader.cr`, `object_document_codec.cr`,
`object_document_column_lane.cr`, and the new context, policy, actual-plan,
tape-adapter files. The column-lane expansion is one
bounded inline-fragment export reusing existing framing adapters under the
same operation budget/grid; existing physical encode methods remain unchanged.
Core worker also owns only the new
`ObjectDocumentColumnWriter.inline_fragments_at_child_site` wrapper in
`object_document_column_writer.cr`, using its private existing lane binder and
the lane exporter without compression. Previously prepared physical-writer
edits in that file stay frozen and are preserved.
Do not reopen this class from the new tape file. New
core test: `spec/object_shared_path_json_tape_w240_spec.cr`.
Root owns only the exact require additions for these new owners in
`src/crystal_click.cr`, the adapted integration RED, and independent policy
adversaries in `spec/object_shared_json_prepared_policy_w240_adversary_spec.cr`.
The latter checks detached path/roster snapshots, complete unique unused-leaf
coverage, exact typed child schema, canonical-index shifts between chunks,
absent late bindings, preparation caps and the read-side target guard.

Physical consumer worker owns `object_shared_advanced_chunk_codec.cr`,
`object_shared_advanced_document_codec.cr`,
`wide_part_writer.cr`, `wide_part_writer/object_part_writer.cr`,
`object_document_file_reader.cr`, `object_column_reader.cr`, and, if required
for bounded selection, `object_shared_physical_bucket_decoder.cr`. New consumer
test: `spec/object_shared_json_w240_physical_spec.cr`. This worker also owns the
new `object_document_inline_plan_reader.cr` and, if separate result state is
needed, `object_document_inline_prefix.cr`. It derives child bindings from the
actual descriptor and persisted callback prefixes, then feeds the existing
Object decoder; the core worker retains generic container traversal and tape
assembly. The workers coordinate that interface before either consumes it.
The consumer worker's prior `object_document_column_writer.cr` changes remain
part of this slice, but it does not edit that file while the core worker owns
the narrow inline binding wrapper.
Neither worker edits the
scalar policy or root-owned RED/adversary specs. Harness worker owns only the
three new W241 probe/helper/reconciler scripts.

DoD: serial guarded DEBUG and RELEASE of the integration RED, new tape/physical
specs and exact affected Dynamic/Object/advanced guard roster, followed by
`probe_object_shared_json_interop_w241.rb` and its independent reconciler.
Expected: no test failures/errors/pending; authenticated stock-to-Crystal and
generated-to-stock results for four layouts x String 0/1; actual ordinary JSON
Data arms and raw shared versions/chunk schedules; full/middle/last/EOF read
domains; missing/late/empty child controls; separate restarted native direct
and full queries. The stock untyped inferred JSON and generated explicitly
typed JSON child witnesses are separate from their common logical-value oracle.
Root typed Array(JSON) declarations are not admitted as a fixture shortcut.

Strongest falsifiers: changing canonical arm indices across chunks, late-first
child prefix at zero prior occurrences, callback name/order/offset corruption,
trailing body bytes, a capped nested traversal, checksum-valid late Data-only
mutation with Copy unchanged, and late Copy-only truncation with Data unchanged.
Path-only reads must be unaffected by corrupted Copy; full reads must reject
disagreement. Independently audit files/digests and raw metadata; forged status,
digest, missing Data lane and wrong-version packets must fail reconciliation.
Risk remains CAUTION; rollback is the coherent feature diff/commit only after
this declared DoD passes. No remote push or whole-type-product claim is included.

Generated qualification fixture: the root has no typed or ordinary Dynamic
paths and remains JSON(max_dynamic_paths=0). Nonempty `arr` actuals use
Array(JSON(v UInt8, max_dynamic_paths=1, max_dynamic_types=1)), with typed `v`
and one ordinary String Dynamic child path `s`. The pk-8-only `late` actual
uses the distinct Array(JSON(v UInt8, max_dynamic_paths=2,
max_dynamic_types=1)), with typed `v` and ordinary String Dynamic child path
`late_only_child`. These different exact descriptors have separate prepared
plans. Empty `arr` stays Array(Nullable(String)); mixed/label primitive values
and the logical rows match stock. Stock and generated key storage types are
UInt8 and UInt64 respectively; each actual schema is checked independently.
The W240 stock summary's SHA256 was independently rechecked as
`8b0375c94007d123170362a647dc8b95578fc54daf8f66bac2f0ad047c24cf70`.
All four actual inventories declare String=1 and nested-version propagation;
reuse still requires the paired auditor's complete file/artifact checks.

### Write directive versus persisted read schedule

Left context: shared Object writer; `target_chunk_rows` is a requested schedule
parameter, not an observation. Right context: shared Object reader; actual
`chunk.num_rows` records determine decoding. Relation: overlaps, not identical.
Evidence: pinned SharedData.cpp:386 propagates the writer setting and 719-740
uses it to partition rows; 598-625 and 1103-1169 deserialize row counts without
that setting. The last chunk can merge a small remainder, so it cannot identify
the original target. Allowed use: writer inheritance and raw schedule checks.
Disallowed use: guessed target/default as a reader precondition or an observed
wire property. Keep the public read API three-argument; a nil read-side target
is unknown, not zero. Refresh this bridge if the upstream format/decoder or
these context consumers change.

Ceiling-only writer scheduling is refuted by the pinned source algorithm.
It uses floor division, retains a nonzero remainder at least `target / 2`
(integer division), and otherwise merges it into the last chunk. Pending
schedule falsifiers include rows=9/target=4 -> [4,5], 10/4 -> [4,4,2],
5/2 -> [2,2,1], and zero/one-row domains. Reader admission depends on actual
saved rows, not agreement with an inferred writer target.

## Continuation

The original integration RED spec had SHA256
`4869c18b11d82713d9004834fb3480a089ffcdf14dfcd3e25d1ebd830b52d428`.
After sealing the physical API, root updated only its final ordinary-JSON Data
case to use the named exact-binding writer/prefix-discovering reader and retain
legacy encode/decode refusals as controls. The earlier runtime RED describes
the original spec, not compilation of the new API against the old baseline.

Root observations at production baseline `d217f75`, 2026-10-09:

- Stock qualification passed all four requested profiles with twelve successful
  native invocations: write/CHECK, a restarted direct-only read, and a separate
  restarted full-Object read per profile. Status:
  `all_stock_profiles_observed`, `profiles=4/4`, exit 0. Raw capture:
  `/private/tmp/crystal-click-w240-stock-rerun.T9COXO/summary.json`.
  This establishes the tested native values/profiles, not Crystal compatibility,
  nested-child selective reads, or every JSON-bearing type tree.
- The tests-only behavioral RED compiled and ran: 10 examples, 0 assertion
  failures, 8 runtime errors, 0 pending, exit 1. The scalar JSON/Array(JSON)
  envelopes and empty/pathless controls passed. Seven shared-envelope cases
  reached the existing JSON admission refusals. The ordinary Dynamic Array(JSON)
  child-binding roundtrip passed before its ObjectSharedPath integration reached
  the unbound-JSON bulk-plan refusal. This is an actual runtime RED, not a
  compiler or process failure. Production remains unchanged; the diagnostic
  spec is intentionally not a green-suite completion claim.

Executed commands used the existing serial `run_safe.sh` wrapper with
`COGNI_RUN_SAFE_MIN_FREE_PCT=50`, an isolated temporary Crystal cache and SDKROOT:

```sh
run_safe.sh ruby 240 12288 scripts/probe_object_shared_json_w240.rb --clickhouse /private/tmp/crystal-click-w216-runtime-recovery.DmL9Kw/clickhouse-stripped --evidence-root /private/tmp/crystal-click-w240-stock-rerun.T9COXO
run_safe.sh /opt/homebrew/bin/crystal 600 12288 spec spec/object_shared_json_w240_red_spec.cr --single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace
```

Refuted probe assumptions: its initial combined SELECT could let full doc
reconstruction satisfy direct path expressions; those reads now use distinct
processes. Numeric JSON quoting is pinned, not normalized away. The first run's
empty-array oracle incorrectly expected Array(Nothing)/Array(JSON). Captured
direct values were exactly `[]` with `Array(Nullable(String))`; the JSON path
inference documentation and `FormatFactorySettings.h:577-603` support that
carrier under the default incomplete-type inference policy. The corrected
oracle requires this exact empty carrier and still requires Array(JSON) for
nonempty object arrays. Exact parser-branch tracing is unavailable in the partial
source snapshot, so the settings explanation is narrower than a parser proof.

Next transition: complete the sealed child-binding/tape and physical-consumer
implementation, then refresh the integration RED and affected debug/release
rosters. Scalar envelopes alone have passed their declared checks. Paired
Crystal/stock interoperability and hostile late corruption controls remain
open. Do not replace the existing child serde with per-product serializers or
relax borrowed-default guards to make the RED pass.

Refresh after relevant source/runtime, codec, binding, consumer or harness
changes. Temporary evidence is regenerable, not a success signal when absent.

### Inline callback-order correction

The proposed reuse of Wide `LaneBinder` append order as an inline callback
schedule is refuted by the pinned source. `SerializationObject.cpp:336,488-506`
writes Object metadata, then sorted typed-path recursive prefixes, then each
sorted Dynamic path's metadata and recursive Variant prefixes. Its body at
917-943 writes typed paths first, Dynamic paths second and shared data last.
`SerializationDynamic.cpp:190,322` and `SerializationVariant.cpp:204,223`
confirm that metadata and descendant prefixes belong to that recursive prefix
pass. A sorted physical filename roster also cannot determine this schedule.

The Wide binder remains the authority for physical lane byte/name binding,
not callback order. The core worker owns a narrow shared inline-order/helper
owner and writer phase correction; the consumer worker owns the persisted
prefix-to-plan reader and a factored Object metadata header reader if needed.
Both use the source-exact order. Inline `StatisticsMode::NONE` metadata ends
before its statistics offset; it must not export the Wide flag/suffix. Tests
must distinguish native order from a mutually compatible but incorrect paired
writer/reader. Advanced coordinate relocation and the four-layout native DoD
remain open, even if the MAP checkpoint compiles and passes local round-trips.

The nested Compact framing does not imply resetting String serialization.
`DataTypeString.cpp:38` selects its serializer from
`SerializationInfoSettings.string_serialization_version`;
`SerializationDynamic.cpp:323,1310` propagates its retained serialization-info
settings to actual-type serializers. `SerializationObjectSharedData.cpp:418`
reuses that Dynamic serializer while changing bulk framing settings. The child
String profile therefore remains inherited when serialization-version
propagation is enabled, as pinned by this fixture and generated metadata.
`DataTypeObject.cpp:180-189` explicitly switches typed-path and Dynamic
serializers between propagated settings and defaults using that flag.
Compact Variant discriminator framing, explicitly enabled at line 381,
is a separate setting. This checkpoint does not claim the unpropagated
String1 combination.

This inheritance applies to ordinary typed fields and Dynamic actuals, not to
the internal shared MAP's path/value carrier. `SerializationObjectSharedData.cpp:48`
constructs that carrier with `getDefaultSerialization()`;
`IDataType.cpp:456` uses default `SerializationInfoSettings`, whose String
version is SINGLE_STREAM (`SerializationInfoSettings.h:23`). Nested MAP0/1
shared lanes therefore retain String0 independently of the ordinary String
profile. A separate adversary must distinguish these two carrier contexts.

The existing immutable `ObjectDocumentPlan` constructor retains an additional
default-limits model-validation fence. The inline reader must preflight and
charge all raw descriptors, paths, sites and owned byte fragments against the
inherited operation budget and descriptor depth before constructing this model.
That model fence may conservatively reject a caller's larger custom limits;
it does not authorize replacing or resetting the decode-operation budget.
Relaxing this constructor fence is outside the intermediate MAP checkpoint.

### Advanced coordinate planning constraint

Nested Compact marks address the containing shared Data stream, not each
child fragment. An inline tape must retain fixed-width coordinate bindings
as `{coordinate_field_raw_offset, target_raw_offset}` and shift both through
the child/path/bucket assembly before resolving transport positions.

The current `CompressedMarkWriter` emits literal-only LZ4 frames
(`measure_frames`, `physical_frame_size`, `write_lz4_frame`). Its frame boundaries and physical sizes
are content-independent: `measure_frames` and `physical_position` therefore
can plan positions before fixed-width patches without compression/rewrite
iteration. Any planning API must share those exact private calculations with
the encoder and check planned positions against the final actual frames.
This is a specific writer-contract property, not a property of general LZ4.
Introducing match compression or content-dependent frame boundaries invalidates
this planning route until a streaming or dependency-ordered relocation owner
is independently qualified. A one-frame test is insufficient for a multi-frame
compatibility claim. No advanced inline implementation or native qualification
is established by this design inventory.

### Isolated literal-coordinate planner checkpoint

On 2026-10-09, root executed the ten examples from
`spec/compressed_literal_position_plan_w240_spec.cr` in an isolated temporary
snapshot, loading only the frozen production planner and its transport owners.
This avoided compiling the still-incomplete JSON integration; it is not a
full-library green-suite observation. DEBUG and RELEASE each returned
10 examples, zero failures/errors/pending, exit 0. Coverage includes empty/EOF,
partial/full/multiple frames, literal extension thresholds 14/15/16 and
269/270/271, same-size coordinate patches, query-domain rejection, read-direction
rejection, cumulative budgets and partial-frame compressed-size caps.

Probe sensitivity was checked against a separate temporary source copy: root
changed the common `physical_position` implementation to add one byte to each
non-EOF compressed frame start. Both planner and encoder used that same mutant,
so paired position equality still passed. The actual `CompressedFrameIndex`
then rejected the coordinates as not naming a frame boundary (one example,
one expected error, exit 1). A separate literal-position oracle also detected
the incorrect starts 1/31/61 instead of 0/30/60 (one example, one expected
assertion failure, exit 1). Production files were not mutated.

Executed with the same serial resource guard, 600-second and 12288-MiB limits:

```sh
run_safe.sh /opt/homebrew/bin/crystal 600 12288 spec /private/tmp/crystal-click-w240.HS9ANz/planner_isolated_w240_spec.cr --single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace
run_safe.sh /opt/homebrew/bin/crystal 600 12288 spec /private/tmp/crystal-click-w240.HS9ANz/planner_isolated_w240_spec.cr --single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace --release --no-debug
run_safe.sh /opt/homebrew/bin/crystal 600 12288 spec /private/tmp/crystal-click-w240.HS9ANz/planner_mutant_w240_spec.cr --single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace -- --example 'keeps plans valid after same-size'
```

This checkpoint does not admit advanced inline Object storage, nested mark
relocation, arbitrary LZ4 compression or native ClickHouse compatibility.
Refresh after any relevant planner, encoder, framing, budget or index change.

### Intermediate MAP inline checkpoint (not admission)

On 2026-10-09, the first fully compiled inline integration roster returned
37 examples, 3 assertion failures, 7 errors, 0 pending, exit 1. It included the
integration RED, prepared-policy, literal callback-order, raw Object-prefix,
inherited-depth and JSON path-tape specs. This is an observed runtime failure,
not a completed MAP or four-layout capability. Earlier compile failures are
not compatibility falsifiers.

The failures separated three boundaries:

- SharedData.cpp:397 disables VariantElement escaping for callback names.
  Canonical physical plan names still escape type-name components. Inline
  callbacks and canonical plan keys therefore need separate coordinates,
  including Variant/Dynamic components inside the child. Tuple separators
  retain ISerialization.cpp:340-350's `%2E` escaping in both domains; globally
  unescaping a filename is not a legal adapter.
- Static Variant inline discriminators require Compact mode 1, independently
  of ordinary Wide mode 0. LowCardinality dictionaries have a distinct
  UInt64(1) prefix callback; their normalized decoder offsets begin at byte 8,
  not byte 0. The candidate adapters preserve the existing Wide lane path.
- Two depth-test expectations were invalid: a one-actual Dynamic roster also
  contains SharedVariant, and an actual String descriptor at depth 5 fits a
  depth-5 limit. The corrected discriminator exercises callback traversal with
  the retained actual-origin depth instead of demanding a spurious refusal.

Root added a source-literal callback-name/readback discriminator combining
typed Variant(Array(UInt8), String), root Dynamic(Array(UInt8)), Tuple(String)
and LowCardinality(String) inside the child. It distinguishes raw actual type
names from escaped Tuple names and checks dictionary value reconstruction.
The corrected tests and candidate adapters have not yet been executed at this
checkpoint. They must pass before any intermediate MAP claim is admitted.
Nested advanced layouts remain explicitly guarded and the declared paired
four-layout, two-String-profile DoD remains open.

An independent name/ownership falsifier then exposed a supported String field
named `dict`: its unprefixed `.child.dict` lane was incorrectly sent through
the LowCardinality adapter by a basename-only predicate. Root's isolated test
compiled and returned one example, zero assertion failures, one
UnsupportedFormatError, zero pending, exit 1. The narrow correction additionally
requires the existing explicit eight-byte prefix binding. The same isolated
command then returned one example, zero failures/errors/pending, exit 0:

```sh
run_safe.sh /opt/homebrew/bin/crystal 600 12288 spec /private/tmp/crystal-click-w240.HS9ANz/inline_dict_name_isolated_w240_spec.cr --single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace
```

The repository adversary retains that literal String control, and the framing
spec also rejects an unsupported four-byte prefix. The isolated green does
not establish dictionary reconstruction, the complete callback schedule or
native interoperability; those remain in the unexecuted integrated roster.

Refresh this checkpoint after relevant callback naming, framing, plan-depth,
dictionary-grid or test-oracle changes. Its runtime counts describe only the
recorded pre-correction source state.

### Integrated naming and fixture discriminator

The test-only private binder observer still declared the old three-argument
facade and hid the optional shared-budget argument when loaded beside the new
inline entry point. This, not a compiler-cache defect, caused the repeated
arity error. Root preserved the optional budget and forwarded it explicitly
through `previous_def` in `object_column_lane_binder_refactor_spec.cr`.

The resulting 13-spec runtime returned 66 examples, 1 assertion failure,
8 errors, 0 pending, exit 1. The literal name oracle rejected the internal
`root` leaking into empty-column callback names. A separate inherited-depth
oracle rejected counting the inferred actual descriptor origin twice. The
existing W193 nested Dynamic control also rejected using escaped type names
to consume its raw callback tape. These are executed behavioral falsifiers.

After the narrow callback-root/depth/legacy-name corrections and valid fixture
repair, the same roster returned 66 examples, 0 assertion failures, 5 errors,
0 pending, exit 1. The wire-name literal, retained nested Dynamic control,
actual-depth boundary, MAP physical projection and source-exact scheduling
checks passed. Three JSON readbacks still rejected an unescaped physical
prefix; two advanced physical cases stopped at a fixture's child MAP0 versus
inherited v2/v3 mismatch. Neither run establishes MAP tape readback or final
four-layout interoperability.

Fixture repair does not relax production guards: an explicitly typed JSON
row includes `v=UInt8(0)`, and zero logical child rows use a positive physical
parent row count (E=0/P=1). P=0 remains a refusal control. Child plans must
match the inherited shared version and bucket count.

The independent inline framing roster passed DEBUG and RELEASE separately:
3 examples each, zero failures/errors/pending, exit 0. Its scope is Compact
Variant mode 1 versus ordinary Wide mode 0, the eight-byte LowCardinality
prefix split, and the literal String field `dict` with unsupported-prefix
refusal. It does not establish complete JSON readback or native admission.

### Advanced inline assembly refinement (PROPOSED)

Pinned SharedData.cpp:162-182 and 762-885 establish exactly seven specialized
Compact callbacks per bucket, followed by three global Copy callbacks:
StructurePrefix, Data, PathsMarks, Substreams, SubstreamsMarks,
PathsSubstreamsMetadata, StructureSuffix; then Copy Sizes, PathsIndexes,
Values. V3 obtains each outer stream once and writes all chunks contiguously
through it. The generic Structure role is an alternative to specialized
Prefix/Suffix, not an eighth callback. Identical names in distinct inner
path/chunk metadata vectors do not establish a repeated outer callback.

The six-role Wide file inventory is not this Compact callback roster. Keep
Wide physical names and file counts unchanged; derive Prefix/Suffix callback
identities separately and preflight the seven-per-bucket plus three-Copy
callback count. A two-bucket Compact roster has seventeen callbacks, not the
fifteen Wide files. Canonical layout names and raw nested callback names remain
separate domains with an explicit source-order mapping.

The minimum assembly route reuses the existing chunk/path serde, six-lane
raw bucket layout and raw Copy materialization. Split interleaved Structure
records into all headers and all 48-byte suffixes, retaining explicit
relocations rather than publishing zero placeholders. A relocation names a
source callback's sixteen-byte coordinate field and a target callback's raw
offset. Path tape assembly rebases it to the exact path; the containing Data
owner then rebases it to its global logical domain, plans literal-LZ4
positions, patches before compression and verifies the actual position map.
Nested roles must never be independently compressed and transplanted.

On read, retain the authenticated containing Data resolver and narrow extent
through each physical path and callback slice. Per-role logical lane views
translate compressed coordinates through that resolver and reject positions
outside the relevant role extent. Recombine headers and suffixes for the
existing bucket parser; reuse Copy shape/extent parsing and Data/Copy
agreement under the same operation budget. Detached advanced child bytes
without that coordinate context remain unsupported.

Before admitting production changes, execute the new literal callback
discriminator at the currently guarded inline entry. Final verification must
force 32/64-byte containing frames, nonzero nested bases, multiple v3 chunks,
multiple buckets, empty/late paths, and reject local-zero/independent-lane
coordinate mutants. The existing paired four-layout/two-String-profile DoD
and restart checks remain unchanged and open. Refresh this design after
upstream callback order, coordinate resolution or compression framing changes.

### Advanced inline implementation seal — measured RED

The root-executed 14-spec checkpoint on 2026-10-09 15:32 UTC returned
71 examples, zero assertion failures, six errors, zero pending, exit 1.
All six errors reached the intended Compact coordinate-relocation guard:
two public selected-Data cases and four new v2/v3 inline cases. The retained
MAP tape readbacks, raw/canonical name oracle, W193 nested Dynamic control,
depth boundary, empty/late bucket schedules and literal callback roster ran
past their earlier failures. This is an intermediate checkpoint, not native
admission. A preceding compile-only failure was an accidental writer reference
to a reader-only callback variable; it supplied no behavioral evidence.

The next CAUTION slice may implement advanced inline assembly under the same
four-layout/two-profile boundary. Rollback is the exact W240-owned patch set
relative to `d217f75cf1c7f7df941740dc6f2290317a01c1a9`; do not discard any
unrelated work or publish a partial completion commit.

Writer ownership: factor raw assembly in
`object_shared_physical_bucket_encoder.cr` and the encode-only portion of
`object_shared_advanced_copy_layout.cr`; add small named raw-layout,
relocation and inline-writer owners. Wire write-only changes through
`object_document_column_writer.cr`, `object_document_inline_callback_order.cr`,
`object_shared_path_json_tape_codec.cr` and `object_shared_path_codec.cr`.
Keep existing callback tuples compatible or provide an explicit sidecar;
unresolved relocations must not be silently exported as final coordinates.

Reader ownership: add an authenticated containing-Data coordinate context,
preserve it in `object_shared_path_streams.cr` and
`object_shared_path_tape_reader.cr`, factor the decode-only bucket/Copy cores,
and add a dedicated advanced-inline decoder. Integrate it through
`object_document_inline_prefix.cr`, `object_document_inline_plan_reader.cr`,
`object_document_inline_body_materializer.cr` and the existing selected/full
Data consumers. Serialize handoffs for files shared with writer ownership.

The coordinate context is created from an authenticated lane owner and an
already validated path interval, not a caller boolean, fabricated index or
unchecked base. Retained path/tape/callback bytes must match that authenticated
Data interval, not only its length; charge comparisons to the same read budget.
Callback slices retain exact intervals. A concatenated role
requires an ordered interval map unless source and captured schedule prove
one contiguous interval. Reject gaps, overlap, wrong-role positions, overflow,
out-of-extent marks and invalid boundaries; accept a terminal coordinate only
at that role's validated terminal. Preserve E=0/P>0 and reject P=0.

DoD: rerun the 14-spec roster plus the new coordinate and relocation
adversaries in DEBUG and RELEASE with every example passing, then the affected
guard roster and paired native matrix already
declared above. The harness must independently demonstrate multiple 32/64-byte
containing frames, nonzero nested coordinate bases, two v3 chunks and two
buckets. Reject local-zero and independent-lane coordinate mutants with an
independent source-literal oracle, in addition to existing checksum-valid
Data-only disagreement and truncated-Copy controls. Standalone detached
advanced bytes without authenticated coordinate provenance remain rejected;
no new type grammar, transport budget, Compact part support or performance
claim is admitted by this seal.

The intermediate 14-spec command (repository cwd; RELEASE adds
`--release --no-debug`) is:

```sh
env COGNI_RUN_SAFE_MIN_FREE_PCT=50 CRYSTAL_WORKERS=1 \
  RUN_SAFE_PASSTHROUGH_STDIO=1 TMPDIR=/private/tmp \
  CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w240.HS9ANz/crystal-cache \
  SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk \
  /Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh \
  /opt/homebrew/bin/crystal 600 12288 spec \
  spec/object_shared_json_w240_red_spec.cr \
  spec/object_shared_json_prepared_policy_w240_adversary_spec.cr \
  spec/object_document_inline_schedule_w240_adversary_spec.cr \
  spec/object_structure_inline_prefix_w240_adversary_spec.cr \
  spec/object_shared_path_json_tape_w240_spec.cr \
  spec/object_shared_json_w240_physical_spec.cr \
  spec/object_shared_path_w193_spec.cr \
  spec/object_shared_path_low_cardinality_w196_spec.cr \
  spec/object_column_lane_binder_refactor_spec.cr \
  spec/compressed_literal_position_plan_w240_spec.cr \
  spec/object_document_inline_depth_w240_adversary_spec.cr \
  spec/object_document_inline_framing_w240_spec.cr \
  spec/object_shared_json_name_domains_w240_adversary_spec.cr \
  spec/object_shared_advanced_inline_w240_adversary_spec.cr \
  --single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace
```

The independent minimal-import relocation adversary ran on 2026-10-09
15:49 UTC: six examples, one assertion failure, zero errors/pending, exit 1.
The failure demonstrates that duplicate or partially overlapping sixteen-byte
coordinate fields were not rejected. Ownership snapshots, callback identity,
missing identities and exact source/target extent controls passed. The next
writer patch must reject overlapping source fields before compression; this
RED does not establish advanced inline readback or native admission.
The earlier invocation stopped at a private class-helper compile error and
supplied no behavioral evidence. The discriminator is
`spec/object_shared_inline_relocation_w240_adversary_spec.cr`; run it with the
same guarded Crystal command options above, then retain it in the final roster.

The same minimal-import relocation adversary passed on 2026-10-09 16:02 UTC:
six examples, zero failures/errors/pending, exit 0. This verifies the local
callback identity, extent, ownership and overlap controls only; the containing
Data patcher, advanced inline reader and paired native admission remain open.

The Ruby coordinate parser's synthetic calibration also passed under the
resource guard on 2026-10-09 15:54 UTC. Its two seeded coordinate mismatches
are parser-only controls, not mutations of a captured part or native rejection
evidence. The captured-wire calibration and complete paired matrix are still
required.

By 2026-10-09 16:15 UTC, root refreshed that parser-only calibration: exit 0.
The coordinator and reconciler also passed Ruby syntax checks. The W241
coordinator now accepts only `--frame-bytes 32|64` (default 32), retains that
request through its strict helper envelopes, and requires an independently
native-decompressed full containing Data frame of the requested size. Both
eight-profile runs remain required; parameter plumbing is not native evidence.

The captured-wire negative calibration uses the mandatory StructureSuffix
PathsMarks field, which exists even for an empty child shared bucket. It
replaces that sixteen-byte field with `[0,0]` and with a valid first-frame
local-looking coordinate in decoded capture clones, preserving the original
frame descriptors and callback extents. The same source-literal auditor must
reject both clones after binding them to the changed decoded bytes. These
controls are not on-disk mutations or native rejection claims; checksum-valid
Data-only disagreement and truncated-Copy controls remain separate obligations.

### Retained stock invocation-record authentication refresh

On 2026-10-09 16:20 UTC, the read-only retained-stock refresh rejected the
first invocation record: the summary contained `binary_sha_before`, while its
per-invocation JSON artifact did not. Root compared both records independently;
this was their sole key/value difference. The recorder lineage explains it:
`scripts/check_array_json_parts_w185.rb` writes the JSON artifact inside
`execute_record`, then `run_clickhouse` adds the pinned pre-invocation SHA to
the returned in-memory record. W240 later serializes that enriched record in
its summary. The captured part and invocation artifacts were not changed.

The reconciler now admits exactly that source-established summary-only field
with the pinned runtime SHA. All base keys and values still require exact
artifact equality. Root reran the original rejected command by 16:26 UTC:
exit 0, all four retained layouts authenticated. The strict enrichment controls
also passed: the valid enrichment was accepted; a forged pre-invocation SHA,
a missing base field, and an extra artifact field were rejected. This repairs
the evidence reader, not the part reader, and does not establish the pending
eight-profile native interoperability runs.
