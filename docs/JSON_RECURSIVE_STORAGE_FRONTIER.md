# Recursive JSON storage frontier

Status: PROPOSED complete storage composition; W189's declared typed-Dynamic
COMPACT extension is separately qualified in
[OBJECT_TYPED_DYNAMIC_COMPACT_FRONTIER.md](OBJECT_TYPED_DYNAMIC_COMPACT_FRONTIER.md)
and supersedes the typed-Dynamic BASIC restriction recorded historically below.
W188's COMPACT child extension,
W187's common recursive Array/Tuple
part/table path, W186's Tuple-with-JSON path, W185's dedicated normalized Array(JSON)
path and W184's internal paired occurrence-grid foundation are VERIFIED within
their executed scopes below.
Baseline: `4464ef3`. W182 scalar admission remains unchanged. No new generic
Crystal JSON bulk admission or admission beneath every persisted wrapper.
W183's finite stock physical discriminator is verified below; it does not
complete the storage-admission DoD.

## W188 implementation seal: COMPACT Dynamic discriminators below Array

Status: VERIFIED within the finite executed scope below. Baseline: clean
`a3213f8247d5343bbc521902f553368e5a93704c`. Extend W187's BASIC child admission
with the mode-specific COMPACT body contract. Extend the
existing recursive Array/Tuple owner and existing Object/Dynamic codecs;
do not introduce a serializer for each type combination.

Risk: CAUTION (persisted serialization and staged publication). Rollback:
one atomic local feature commit of exact owned paths after DoD; retain native
inputs and probe captures in task-owned `/private/tmp` directories. No push,
source-data mutation, performance optimization or Compact-part admission.
COMPACT here means Variant/Dynamic discriminator mode, not the part format.

Design laws:

- Preserve physical root mark rows `P`, per-Array parent occurrences `Q`,
  child occurrences `C`, structural site identity and inherited Array level.
  The discriminator's logical mark rows are `C`; physical `.mrk2` rows stay `P`.
- A child stream has one UInt64 mode prefix. For `C=0`, both BASIC and COMPACT
  emit no per-mark discriminator body. For `C>0`, BASIC emits `C` tags;
  COMPACT emits the child count, a supported format and uniform/plain tags.
  Every COMPACT declared count must equal `C`, with exact body extent.
- Empty marks keep repeated offsets. Do not synthesize a COMPACT zero-count
  frame. This source-derived law is qualified by the stock/library captures
  below: pinned `SerializationArray.cpp:380-394` passes the
  derived child range, and `SerializationVariant.cpp:326-345` returns before
  writing a discriminator body when the range is empty.
- Thread the selected mode through Object and Dynamic child encoding. Read
  mode from the stream prefix; do not infer it from the enclosing declaration
  or reset state at an Array edge. A shared mode-aware body validator must
  cover the complete in-memory child stream and physical writer lane binding,
  including zero selections, before rows are exposed. The file reader retains
  W187's complete physical-grid / selected-payload contract; zero selection
  does not authenticate every unselected discriminator body or arm payload.
- Keep root no-grid positive-mark rules and the separate declared typed
  Dynamic BASIC restriction. This slice qualifies untyped Dynamic paths in
  the admitted Object profile, not every typed Dynamic or JSON layout.

Likeliest failure: treating discriminator byte length as logical row count,
or writing a zero-child COMPACT frame that stock does not write. Guards:
`C=[0,1,3,0]`, uniform and mixed Int64/NULL/String groups, repeated Arrays,
independent equal-nominal JSON sites, full/middle/zero windows, malformed
inner counts, formats, extents and terminal marks, plus unchanged BASIC and
typed-Dynamic refusal controls.

Execution plan and ownership:

1. Root executes new existing-API child behavioral RED on unchanged production
   and a stock-default-equivalent COMPACT source-part witness. A compiler
   failure is not a behavior signal. The native source must CHECK successfully,
   and its actual discriminator bytes must qualify the mode and group formats.
2. Core worker owns `dynamic_discriminator_codec.cr`, `dynamic_value_codec.cr`
   and the new direct child spec. Object worker owns Object codec, column
   writer, lane and file-reader integration. Recursive/native worker owns
   recursive plan/reader, persisted specs and the existing W187 paired scripts.
   All preserve other workers' edits; root owns serial execution and this seal.
3. Root runs focused and affected regression specs in DEBUG and RELEASE,
   rebuilds both helpers, and executes paired stock read plus library write /
   native ATTACH/CHECK/exact-schema/literal checks in COMPACT and BASIC modes.
   Reuse the bounded native runner and BASIC fixture; do not duplicate it.

DoD commands: guarded serial `crystal spec` and helper `crystal build` with
600 seconds, 12 GiB, >=50% free memory, one compiler thread, host linker and
isolated caches; existing Ruby paired runner with explicit `--dynamic-mode`
and pinned native binary (one thread, 512 MiB query cap, 10-second deadline,
two-second grace). Require actual child/guard exits zero, empty-group extents
zero, both positive group formats observed, authored full/middle literals,
no zero-selection callback, and no publication on the tested corrupt inputs.
Root reconciles captures and source/input hashes and performs hostile review
before any admission or commit. Current oracle pins and finite profiles are
not a proof of fresh-master execution or the entire type Cartesian product.

### W188 executed evidence and continuation (2026-10-06)

On unchanged production, six direct child examples produce two assertion
failures and four runtime BASIC-only refusals. The Object RED is two examples,
one runtime refusal; its first compiler-error attempt is retained but is not
behavioral evidence. A stock-only source witness CHECKs both Array/Tuple
profiles and captures the actual COMPACT mode before the old prebuilt helper
reports the expected reader refusal. The original native expectation wrongly
retained an untyped NULL path on read: preserve NULL INSERT input, but compare
against a separately authored canonical read value that omits the path.

The shared `DynamicDiscriminatorBodyValidator` validates the persisted mode,
minimal bounded VarUInt count, format and exact extent without a tag-vector
allocation. Child encoding forwards its chosen mode through existing Dynamic
and Object owners. The common recursive plan removes two BASIC-only fences;
its read-side roster plan does not predict or override the persisted mode.
Root positive-mark guards, the dedicated W185 BASIC-only writer and declared
typed-Dynamic BASIC-only guards remain unchanged.

Root executes the same 69 selected spec files: **404 DEBUG and 404 RELEASE
examples**, zero failures/errors/pending, actual child and guard exits 0.
Focused direct/Object and recursive cohorts also pass. Obsolete BASIC-only
refusal expectations were replaced by plan and round-trip controls; failing attempts
remain distinguishable from final evidence. All 1,085 Crystal/Ruby inputs,
including 363 production sources, have identical pre/post fingerprints.

Both rebuilt helpers qualify one-Array and repeated-Array
`Tuple(JSON,JSON,UInt64)` parts in COMPACT and retained BASIC mode. Stock creates
and CHECKs source parts; the library reads full/middle/zero windows and public
table rows, writes counterparts, then stock ATTACH/CHECKs them and returns exact
schemas and authored full/middle literals. COMPACT fixtures use typed `t UInt8`,
two actual Int64/String alternatives, genuine NULL input and nonempty shared
MAP data. Each stock **and library** discriminator lane has header mode 1,
`C=[0,1,3,0]`, offsets `[8,8,11,16,16]`, extents `[0,3,5,0]`, singleton format 1
and mixed format 0; raw physical mark rows stay `[2,2,2,2,0]`.

Root separately reconciles each COMPACT mode's eleven actual process records,
24 output/SQL captures, eight utility input captures, 220 stream-file hashes
and 48 native literal rows. Each BASIC mode has three processes, eight captures,
196 stream-file hashes and 48 native literal rows. Actual raw mark bytes and
decompressed stock/library discriminator literals are checked independently.
All **126 COMPACT** and **114 BASIC** generated library files match between
DEBUG and RELEASE; BASIC's 114 files also match the previous W187 output.
Two-frame coordinate normalization passes a synthetic-header control and
rejects four adversarial cases. This is a runner test, not a native multi-frame
compression witness. Utility decompression has no query-memory setting: bound
input to 64 KiB and aggregate header-declared output to 1 MiB before launching,
under the 12 GiB outer guard and ten-second process deadline.

Source-only reference remains clean shallow `ef037e60fc7f5654c8c80eefb8be82e3c56f9a67`;
executed stock is separately pinned 26.10.1.1201,
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`. Evidence, exact selected paths,
commands, hashes, retained failures and root reconciliation are indexed in
[json-child-compact-w188.json](../.landmark/evidence/json-child-compact-w188.json).

Scoped adversary verdict: **ROBUST** for these normalized hashed Wide/LZ4,
plain-mrk2, Object-v3/one-bucket-MAP profiles and the tested guards. File reads
validate the full physical grid but authenticate selected payloads only; an
empty selection does not prove all unselected body/tag/arm bytes are valid.
Logical budgets do not cap RSS or decoder workspace. Remaining frontier:
declared typed-Dynamic COMPACT, further persisted wrapper/state composition,
other JSON layouts, remaining types, MV/projections and class decomposition.
Compact parts and performance remain unqualified; the larger goal is incomplete.
Refresh after codec/grid, naming, state, metadata or profile changes; removal of
temporary evidence invalidates its links. Parts must stay immutable during reads.

## W187 implementation seal: common Array/Tuple composition

Status: VERIFIED within the finite executed scope below. Baseline: clean
`52ab3adcc3190f5d79acb2e887c05ee59955c1f3`. Extend the common recursive owner
with one Array operation, reusable below/above Tuple and repeated Array edges.
JSON-free subtrees retain their existing BinaryBulk physical admission laws.
JSON leaves retain their Object owners and independent structural site plans.
The dedicated W185 API remains compatible; it is not silently replaced.

Risk: CAUTION (serialization, metadata, public values and publication).
Rollback: exact task-owned paths in one atomic local feature commit; retain
all stock inputs and generated evidence under task-owned `/private/tmp` roots.
No push, source-data writes, benchmark or performance optimization.
Likeliest failure: a correct total child count is assigned to the wrong mark
or parent Array, or inherited Array levels alias a sibling's physical path.
Guard: mixed zero-child marks, unequal per-row sizes, repeated Arrays, two
equal nominal JSON sites with disjoint actual state, full/middle/zero windows,
same-total schedule redistribution, malformed sizes and exact stream rosters.

Design laws: every Array edge owns an independently checked size schedule and
structural site ID; Tuple preserves the incoming occurrence domain. All lanes
retain the physical root mark-row fields while codecs consume logical child
occurrences, including zero groups. Object prefix/data/suffix state belongs to
its site, not an Array element. Wrapper nodes/edges are preflighted from checked
selected occurrence schedules before leaf materialization. Existing shared
codec/name/transport boundaries must not reset at a wrapper edge. This does
not establish full cross-domain accounting or RSS bounds.

The Array frame keeps three coordinates distinct: positive root physical rows
`P`, incoming logical parent occurrences `Q` (possibly zero below an Array),
and checked child occurrences `C`. Its size lane contains exactly `Q` UInt64
lengths per mark; children consume `C`, while physical marks always retain `P`.
The next Array receives `Q=C` without replacing `P`. A same-total redistribution
of lengths between parents within a mark can be a valid different Array value;
do not claim that such a transformation is intrinsically corrupt. Inconsistent
mark totals, nested incoming counts and leaf extents are the rejecting guards.

Source-only corroboration at the unchanged `ef037e60` reference:
`SerializationArray.cpp:255-295,297-327,330-340,352-396` composes size levels,
child state and flattened ranges, including zero-child calls;
`SerializationTuple.cpp:832-862` passes the child range unchanged to fields.
Native evidence remains a separate executed-binary requirement. The qualified
profile explicitly propagates nested serialization versions; default behavior
must not be inferred from the top-level String/Object setting alone.

Dynamic mode is another inherited serialization coordinate. The reference
`MergeTreeSettings.cpp:298` defaults
`use_compact_variant_discriminators_serialization` to true, and
`SerializationVariant.cpp:211` selects COMPACT/BASIC from it. W187's child seam
is BASIC-only: its paired runner explicitly disables that setting locally.
The earlier stock-only layout witness did not establish BASIC behavior.
W185/W186 settings remain unchanged; default COMPACT child admission is still
guarded, not silently converted. Array-containing structural writer plans
require the caller to choose BASIC before payload encoding or staging.

Baseline behavioral RED: root executed `recursive_array_schema_w187_spec.cr`
against unchanged production `52ab3ad`: four examples, three runtime
`UnsupportedFormatError` errors, zero assertion failures/pending, actual
child/guard exit 1. Common Array(JSON), Array(Tuple(JSON,JSON,UInt64)) and repeated
Array edges are refused; ordinary Tuple admission/JSON-free refusal control
passes. This is not a missing-method or compilation failure. Log:
`/private/tmp/crystal-click-w187-recursive-array.yjTt9U/schema-red.log`, SHA-256
`bfd0c835e74f902d1762b7b5284a9b7df25409822cda40753e94692d77c13699`.

Execution/ownership: root first executes the common-schema behavioral RED on
the baseline, then seals the precise seam after Luna's source inventory.
Schema/value/plan/writer/files and publisher belong to the composition worker;
reader/table/metadata belong to the consumer worker;
Object site/grid seam, paired scripts and hostile source review belong to the
bridge worker.
New components have separate files; root owns this SDD, serial builds, native
oracle, evidence reconciliation and commit. Preserve all other agents' edits.

DoD: guarded serial focused and affected regression `crystal spec` runs in
DEBUG and RELEASE (600 seconds, 12 GiB, >=50% free memory, one compiler thread,
host linker, isolated caches); paired helper builds and stock CREATE/INSERT/
CHECK plus library ATTACH/CHECK/exact-schema/full/middle literal checks in both
modes. Require actual child/guard exits zero, no callback for zero selections,
no publication on tested malformed shape/grid/cap/roster inputs, and retained
ordinary Tuple/W185 controls. A parser-only or in-memory round trip cannot
qualify persisted/public Array/Tuple support.

Executed DoD: the same 66 selected spec files pass 392 DEBUG and 392 RELEASE
examples, zero failures/errors/pending; both actual child/guard exits are 0.
The final gates follow all production and fixture fixes. The 1,081 Crystal/Ruby
input digest and 362-file production-source digest stay unchanged across these
gates. Four new spec files contain 21 examples, including repeated Arrays,
all-empty children, LowCardinality replay through an empty mark for a middle
window, same-total valid size redistributions, exact frame caps, refreshed-
checksum nested-Q corruption with no callback, and unchanged narrower offline
UInt64-PK candidate refusal. Zero selection validates complete schedules but
does not authenticate every unselected payload.

Both rebuilt helper modes read stock and library-written
`Array(Tuple(JSON,JSON,UInt64))` and
`Array(Array(Tuple(JSON,JSON,UInt64)))` parts. Each has eight root rows, four
two-row marks and leaf occurrence counts `[0,1,3,0]`; the repeated profile's
inner Array receives parent counts `[0,2,3,0]`. Two equal nominal JSON sites
have independent Int64/String Dynamic paths and nonempty shared MAP data.
Direct readers and public typed-table full/middle/zero scans match authored
literals. Pinned stock accepts both library parts with ATTACH/CHECK and returns
the exact schemas and authored full/middle rows. Per mode, root independently
checks all three process records, eight capture hashes/sizes, 196 stream-file
hashes/sizes, 48 native literal row records and every raw physical mark-row
field. The 114 generated library files and helper profile values match between
DEBUG and RELEASE. This is finite two-profile evidence, not an exhaustive
Cartesian-product certificate or fresh-master runtime build.

Adversary verdict: ROBUST for these executed profiles and guards. Same-lineage
Luna review is correlated; root's source checks, executed guards, independently
authored literals and pinned native runtime are the qualifying evidence. The
shared size-byte preflight precedes the complete size payload read; root-grid
discovery inspects frame metadata without payload decoding. This does not
establish RSS bounds. Retained failed attempts include staged Array-as-Bulk
comparison, an invalid fixture part name, stock-default COMPACT refusal, and
test-only Array-rank/empty-compressed-lane mistakes; none is reclassified as a
successful format witness. Commands, pins, hashes, repairs and continuation:
[json-array-tuple-parts-w187.json](../.landmark/evidence/json-array-tuple-parts-w187.json).

Map/Nullable/Variant/Dynamic enclosing JSON, other JSON profiles, Compact and
compressed marks, MV/projection completeness and <=10% performance parity
remain open. Re-run affected gates on path, state, grid, codec, metadata or
profile changes. The full thread goal and deferred optimization order remain
unchanged.

## W186 implementation seal: recursive Tuple storage with JSON sites

Status: VERIFIED within the finite executed scope below. Baseline: clean `fdb8d57`. This step
implements an exercised recursive stored-column owner, not a serializer or row
class for each Cartesian product. Existing W185 admission remains unchanged.

The admitted target is a Tuple tree whose JSON leaves delegate to the
existing Object owners and whose JSON-free subtrees delegate to the existing
bulk owners. Each JSON site preserves its exact nominal declaration and has an
independent actual Object/Dynamic plan keyed by structural occurrence address.
JSON-free Bulk leaves remain subject to their existing physical admission
profiles; this is not a promise that every scalar-supported subtree can be
persisted here. In particular, a standalone Dynamic Bulk sibling retains its
existing physical guard, while Dynamic within admitted Object sites keeps its
qualified Object serialization path.
The public logical owner is `StorageColumnValue`, paired with an immutable
`StorageColumnSchema` tree. JSON leaves retain `ObjectDocument` and exact
`ObjectDocumentSchema`; JSON-free subtrees retain existing `BinaryValue` and
`BinaryDataType`. The scalar `BinaryJsonRow` path grammar is narrower than the
persisted Object schema (notably dotted/quoted typed paths), so it is not a
lossless substitute and its semantics remain unchanged. Required typed fields,
typed Nullable NULL, untyped Nothing/absence, caps and runtime tags must retain
their declared semantics. Structural site IDs belong to the composition plan,
not to shared nominal descriptors or duplicated per-row filename strings.

Tuple edges preserve the row domain and Array level while deriving qualified
escaped field prefixes. Parent metadata is resolved once; its declared stream
roster must equal the union of child-site streams. Reader and writer must use
the same structural plan. Array/Map/Nullable/Variant edges enclosing JSON stay
rejected in this step until their own cardinality and state transformations are
implemented and exercised. This does not narrow the existing Object inner
grammar or globally relax the scalar bulk JSON guards.

Risk: CAUTION (serialization, public materialization and staged publication).
Rollback: one atomic local feature commit from the clean baseline; generated
native stores and parts remain task-owned `/private/tmp` evidence. No push.
Likeliest failure: equal nominal JSON siblings alias actual state, or a literal
column prefix is escaped twice when used as a structural child prefix. Guard:
two equal-schema JSON sites with disjoint actual dynamic paths and nonempty
shared data, plus an escaped-field naming control and full mark-grid checks.

Execution order and ownership:

1. Root executes a stock CREATE/INSERT/CHECK discriminator and the old typed
   table API's behavioral refusal before production changes. A compilation
   failure does not count as the missing behavior signal.
2. Core Object physical/read/write owners gain prefix-aware site entry points;
   root and W185 Array entry points retain their admission and error precedence.
3. A generic recursive column plan/reader/writer/files owner composes Tuple
   edges and delegates existing leaves. The part publisher and typed table
   adapter actually consume it; no unused foundation is a completion signal.
4. Root executes focused and affected regression specs, then paired stock and
   library part checks against independently authored full/middle row literals.

Ownership paths: core `object_document_physical_plan.cr`,
`object_document_file_reader.cr`, `object_document_column_writer.cr` and any
Object-site bridge/context owner; integration `recursive_storage_column_*.cr`,
`wide_part_writer`, `wide_part_table`, its batch/adapter and central require;
native `scripts/check_recursive_json_tuple_parts_w186.{cr,rb}` and behavioral
RED helper. New classes have separate files. Root owns this spec and evidence.

DoD: guarded serial `crystal spec` runs on the W186 composition/public specs
and affected Object, ArrayObject, bulk, Tuple and table regressions in DEBUG
and RELEASE; guarded helper builds in both modes; the W186 Ruby paired runner
using the pinned stock binary and an empty task-owned evidence root. Expected:
actual child/guard exits 0; stock parts read through the public table; library
parts pass ATTACH/CHECK, exact schema and literal full/middle reads; independently
bound siblings, nested Tuple and zero selections behave correctly. Writer
preflight rejects malformed rosters, key/granule grids, unpersistable shared
profiles and existing destinations without publication. Direct-reader node and
edge caps reject selected materialization; table ownership accounting rejects
before callback exposure. These are distinct checks, not a public-table tiny-cap
proof or whole-scan atomic payload validation.
Root reviews the actual diff and attacks naming/state/cardinality assumptions
before admitting the slice. Heavy jobs retain 600s/12GiB/50%-free bounds, run
serially with one compiler thread, isolated caches and the host linker.

Source-shape evidence is pinned to `ef037e60fc7f5654c8c80eefb8be82e3c56f9a67`;
native evidence must identify the separately pinned executed build. Untested
profiles, Compact/compressed marks, broader JSON wrappers, full cross-domain
budget/RSS bounds, MV/projection completeness and performance parity remain
open. The full thread objective is unchanged; optimization remains deferred.

Inherited runtime depth is checked before writer site encoding and before
reader results are exposed. On reads, the guard runs after delegated leaf
decoding; an over-depth value may already have been materialized when rejected.
This does not establish inherited-depth admission before every child allocation.

## W186 executed scope and continuation

Public composition boundary:

- `StorageColumnSchema.parse` retains the exact root source and canonical
  declaration, structural Tuple tree, Object leaf schemas and Bulk subtree types.
- `RecursiveStorageColumnPlan` binds independent Object plans by structural site
  ID and collision-checks the union of logical/hashed/file names before payloads.
- `RecursiveStorageColumnWriter.encode` and
  `RecursiveStorageColumnReader.open(...).read_marks(...)` compose existing
  Object/Bulk owners rather than adding a codec for each type combination.
- `WidePartWriter.write_uint64_recursive_pair` publishes a checksummed staged
  part after exact readback. Typed batches expose callback-scoped
  `recursive_values_for(column)` slices. Ordinary Tuple/scalar dispatch and
  W185's dedicated Array(JSON) path remain qualified by their existing controls.

Root executed 296 affected regression examples plus 51 ordinary Tuple, bulk and
table controls per mode during integration, with zero failures/errors/pending.
The first 296 ran before whitespace-only formatting of four production files;
the 51 controls ran afterwards. The final reader-only change reserves all
selected StorageColumnValue nodes and Tuple child edges before site decoding.
After that change, all six W186 specs ran again: 24 DEBUG and 24 RELEASE examples,
zero failures/errors/pending, actual child/guard exits 0. Earlier regression
cohorts cover unchanged production paths, not identical final source bytes.
No full-repository suite or performance benchmark was run.

Local coverage includes a persisted nested Tuple(JSON, UInt64), a JSON sibling
of a JSON-free Tuple containing LowCardinality(String), Variant and UInt64,
middle/zero mark windows, retained LC state, eleven separately addressed JSON
sites, dotted-field/prefix collisions, malformed factories, missing site plans,
unpersistable shared profiles, key/granule grid failures and no overwrite/stage
on tested writer failures. Atomic materialization-budget failure is tested on
the owner primitive; no public-table configurable tiny-cap proof is claimed.

The old typed API compiled against the clean baseline and refused a genuine
stock-written Tuple(JSON, JSON, UInt64) with `unsupported exact typed column`.
A later hostile review found that the new reader initially omitted the outer
StorageColumnValue nodes/edges from the shared codec budget. Independent node
and edge cap tests both failed behaviorally while open, zero-window and generous
literal controls passed; the selected-shape preflight fixes that bypass. A split
test's undefined local variable and an incorrect `.dictionary` filename oracle
were invalid probes, corrected without changing their intended behavior. These
failed runs are retained but never counted as passing evidence.

Final DEBUG and RELEASE helpers each read freshly stock-written parts through
both direct and public table APIs, write their own library part, and require
pinned stock ATTACH/CHECK, exact schema and independently authored full/middle
row literals. The native witness is a direct named Tuple with two equal nominal
JSON schemas, disjoint observed Dynamic paths and nonempty shared-MAP values;
nested Tuple and LC/Variant composition have local tests, not this native witness.
Each part has eight parent rows, four real marks and a zero-row terminal mark.
Object V3, BASIC Dynamic, one-bucket shared MAP, global String size-stream
version 1, hashed Wide/LZ4 and plain `.mrk2` are the finite native profile.
All six native/helper invocations exit 0 without signal, timeout or capture
error. Root reconciles 196 captured/stream hashes and compares helper values and
all 46 generated `.bin`/`.mrk2` stream files between build modes; equality of
all other metadata file bytes is not inferred from this comparison.

Final 1,073 Crystal/Ruby inputs have aggregate SHA-256
`ae45b8a6c7422f45ac4b6a75ed4e411514c3754d493fcf8d855afb2a2391ecb0`
(sorted relative-path/SHA-256 pairs, JSON encoding). That input set was unchanged
during final focused gates, helper builds and paired native runs. Formatter,
Ruby syntax and diff-whitespace checks pass. Resource bounds remain unchanged.
New schema/value/plan/reader/writer/files, table adapter and part metadata/publisher
owners have separate files; the larger table-facade decomposition remains open.

Scoped hostile verdict: ROBUST for this normalized Tuple slice and its tested
guards. Luna source reviews are correlated same-lineage evidence; root's executed
stock oracle, literal checks and hash reconciliation supply the external
discriminator. Curated evidence:
[json-tuple-parts-w186.json](../.landmark/evidence/json-tuple-parts-w186.json).

Next frontier: generalize wrapper operations using the existing occurrence-grid
foundation, preserving each wrapper's cardinality, null/discriminator state,
Array level and stream path; first reuse the qualified Array(JSON) behavior in
the common recursive planner. Admit only combinations legal in stock ClickHouse.
Remaining JSON layouts, full cross-domain metadata/name/codec/transport accounting,
Compact/compressed marks, MV/projection completeness and performance parity stay
open. Parts must remain immutable during reads. Refresh the affected gates after
codec, naming, metadata, state/grid or profile changes; removal of retained
temporary evidence invalidates its file links. The full thread goal is unchanged.

## Why scalar recursion is not the missing abstraction

The shared descriptor/value visitors already compose nominal JSON through
Array, Tuple, Map, Nullable, Variant, Nested and selected Dynamic values.
W182's finite paired scalar evidence is in
[JSON_NESTED_SCALAR_FRONTIER.md](JSON_NESTED_SCALAR_FRONTIER.md).
An implementation per Cartesian product of types is neither required nor
the intended design.

Persisted recursion needs a child serializer plus its occurrence-specific
state and physical context. Existing Object owners already encode/decode
typed, dynamic and shared lanes, but represent a root Object column:

- `ObjectDocumentPlan` supplies explicit actual Object/Dynamic rosters.
- `ObjectDocumentCodec` requires a nonempty real row group at every mark.
- `ObjectDocumentPhysicalPlan` binds Object lanes to physical stream names.
- `ObjectColumnReader` checks a root-column outer row/mark grid.

Consequently an Array wrapper cannot simply pass flattened JSON elements
to these root APIs. A real outer mark may contain only empty arrays and have
zero JSON elements. Parent mark row counts and child value counts are different
quantities. A root `BinaryJsonRow`/`ObjectDocument` representation adapter alone
does not implement this storage composition.

## Design laws

1. Use one recursive operation per wrapper, not one codec per composite type.
2. A JSON site retains its exact nominal descriptor/caps, explicit actual
   Object/Dynamic rosters and a full structural occurrence address. Equal
   nominal types at different sites do not imply equal actual state.
3. Prefix, data and suffix share a site's state. A structure prefix belongs
   to the nested column/site for the part, not to each array element or row.
4. Keep the physical outer mark grid separate from the number of values
   reaching a child. Array/Map offsets and Variant/Dynamic selections determine
   those child counts; empty child ranges are legal when the parent is real.
5. Physical stream naming must receive the enclosing path and array level.
   Concatenating a root Object filename prefix is not sufficient evidence.
6. Target for complete composition: metadata discovery, actual rosters, child
   values and generated names consume one enclosing bounded operation budget.
   A JSON edge cannot reset it. W185 shares a codec budget for parent/child grid,
   statistics and values, but names/rosters, part metadata and compressed
   transport retain separate bounded contexts. It does not close this full
   cross-domain budget law or establish a process-RSS bound.
7. Reuse the current Object structure/value owners behind a site-aware seam.
   Do not globally relax root mark validation to admit empty child groups.
8. Keep schema admission, serialization profiles and runtime state separate.
   In particular, nested Map serialization-info propagation is not the same
   setting as ObjectStructure/shared-data versions.

## W185 implementation seal (VERIFIED within the finite scope below)

Baseline: clean `3ecec3f`. This vertical step composes `Array(JSON)` in
normalized hashed Wide/LZ4 parts with plain adaptive marks, using the existing
Object V3 / one-bucket shared MAP owner. This is an execution step toward the
full type/MV/projection objective, not a replacement objective or a claim that
every JSON layout is supported. Performance remains deferred.

The inner `ObjectDocumentSchema` retains its exact caps and supported typed
field grammar. Existing root codecs, supported typed fields and strict root
nonempty-mark validation must remain intact. Do not add a separate serializer
for each Cartesian product or infer an actual dynamic roster from nominal caps.

Public composition boundary:

- `ArrayObjectColumnWriter.encode`: granules -> parent rows -> Object documents;
  an owned file roster composes outer sizes with the existing child lanes.
- `ArrayObjectColumnReader.open`: exact inner schema plus literal Array wrapper;
  `read_marks` restores one document array per parent row, including empty rows.
- `WidePartWriter.write_uint64_array_object_pair`: full checksummed staged part
  publication, canonical `Array(inner JSON)` metadata and staged reopen.
- Typed table batches expose `array_object_documents_for(column)`; no scalar-reader
  fall-through, projection admission or implicit flattening.

Risk: CAUTION (serialization and public table materialization). Rollback:
one isolated atomic feature commit from the clean baseline; retained stock
parts are read-only and every generated part/store is task-owned temporary data.
Likeliest failure: child counts have the correct sum but are distributed across
the wrong marks/parent rows. Guard: derive the complete child schedule from
checked serialized sizes before value callbacks; attack same-total redistribution,
zero child marks, nonzero origins, truncation, suffixes, caps and path/state collisions.

Execution order / ownership:

1. Root observes an existing-public-API behavioral refusal on a stock-written
   W183 ArrayJSON part before production edits. A probe compilation error is
   not the behavioral RED.
2. Core owners thread site/array level and checked occurrence coordinates through
   existing Object state, statistics, physical plan and reader/writer composition.
3. Part publisher and table adapter consume the composed column rather than
   duplicating its serializers; new owners have their own files.
4. Independent authored row literals drive paired stock/library whole-part tests.

DoD commands: resource-bounded `crystal spec` on W185 core/public/integration
specs plus affected root Object/bulk/table regressions, in DEBUG and RELEASE;
resource-bounded builds of the W185 Crystal oracle helper in both modes;
`ruby scripts/check_array_json_parts_w185.rb` with the pinned stock executable,
built helper and an empty task-owned `/private/tmp` evidence directory. Expected:
all selected specs pass, stock-written mixed/all-empty parts reopen through
Crystal, library-owned parts pass stock ATTACH/CHECK and exact schema/full/middle
reads, and public table batches preserve per-parent arrays. A nonempty shared
MAP witness must prove the nested `size1` path, not only empty file inventories.
The native gate must record actual exit/signal/timeout status under the existing
resource bounds. Root performs diff review and hostile checks before admission.

Rejected surface remains: other JSON physical layouts, Compact parts, compressed
marks, generic persisted JSON under every wrapper, unqualified projections and
MV execution. The existing root supported grammar is not narrowed to make the
first finite native witness easier. Unexecuted or partial gates leave W185 open.

## W185 executed scope and continuation

Root executes the same 46 selected specs in six serial cohorts per mode:
296 DEBUG and 296 RELEASE examples, zero failures/errors/pending, all twelve
actual child/guard exits 0. The nine new examples cover public publication and
typed batches, full/middle/zero windows, all-empty child groups, unchanged
overwrite targets, exact schema caps, wrapper depth, Unicode type labels,
rebased typed/shared names, retained LowCardinality dictionary state and two
separately bound runtime Dynamic paths. A same-total `.size0` redistribution
with refreshed checksums is rejected before a callback for a late selected
mark; this is not whole-scan atomic validation of every inner payload.

Both helper modes consume newly stock-written mixed/all-empty ArrayJSON parts
and a root JSON control. Mixed child counts are `1,0,2,0` while every stream's
physical mark rows remain `2,2,2,2,0`. Nonempty shared String values prove
`a.object_shared_data.size1`, not merely an empty filename inventory. Each
mode writes its own complete library part; pinned stock ATTACH/CHECK, exact
schema, full rows and a middle PK range match independently authored literals.
All six recorded native/helper processes exit 0 without signal, timeout or
capture error. Root reconciles 134 captured/runtime/stream hashes and compares
actual helper values plus all 22 library files byte-for-byte between modes.
This is a finite stock compatibility witness, not every typed/runtime product.

The final 1,053 Crystal/Ruby inputs have aggregate SHA-256
`4040dc35c5455f83d201fc426dba29a0df8969d506421f1803d1aa3c8bb0efce`
(sorted relative-path/SHA-256 pairs, JSON encoding). The 600-second/12-GiB
guard and 50% free-memory preflight are unchanged; heavy jobs run serially
with one compiler thread. The new example builds and reads all eight stock
rows with the correct per-parent child counts. Formatter, Ruby syntax and
diff-whitespace checks pass. No full-repository suite or benchmark was run.

The behavioral baseline compiled and refused the stock ArrayJSON through the
old typed table path. Retained failed attempts include an invalid initial probe,
Crystal compile/test errors during integration, a Ruby 2.6 `filter_map` runner
error and a real root-reader error-precedence regression caused by metadata
extraction. The latter is fixed by validating the source declaration before
parsing the substream roster; the old W129 assertion is unchanged. These failed
runs are not counted as green. Final gates were repeated after formatting.

Architecture: separate Array reader/writer/files, part metadata/publisher and
table adapter owners compose existing Object serializers. The shared
`ObjectColumnPartMetadata` parser is extracted without changing root admission.
This does not complete the larger table-facade decomposition.

Read/materialization limits count logical work and containers, not peak RSS,
transient decoder workspace or caller retention. A selected read still checks
the complete parent-size schedule and may hit whole-part logical caps. The
table adapter uses its default schema caps; this is not an unbounded lazy
reader. Parts must be immutable throughout selection and reading.

Scoped hostile verdict: ROBUST for this normalized BASIC ArrayJSON slice,
selected regression guards and finite paired stock witnesses. Luna's read-only
review is correlated same-lineage evidence; root's executed native oracle and
literal/hash reconciliation provide the external discriminator.
Curated evidence: [json-array-parts-w185.json](evidence/json-array-parts-w185.json).
Usage: [read_array_json_w185.cr](../examples/read_array_json_w185.cr).

Next frontier: general persisted site/state/profile composition beneath the
remaining wrappers; nested JSON physical layouts, full cross-domain accounting,
Compact/compressed marks, additional JSON shared-data/path semantics and broader
MV/projection compatibility remain open. Performance is deferred. Refresh the
affected gates after codec, naming, metadata, state/grid or runtime-profile
changes; deleting retained temporary evidence also invalidates its file links.

Risk for future production widening: CAUTION (serialization and mark/state ownership).
Rollback: an isolated atomic feature commit; no source parts or remote changes.
Likeliest failure: conflating outer rows with flattened child occurrences, or
sharing a structure state between two sites with the same nominal type.

## Admitted and rejected surfaces

Existing normalized root Object V3 / one-bucket shared MAP remains separately
qualified. Existing W182 nominal scalar composition remains qualified only
within its own evidence. Generic bulk planners, persisted Object declarations,
borrowed Dynamic and unqualified consumers retain their recursive JSON guards.

W185 admits the dedicated canonical `Array(JSON(...))` typed column path in
normalized hashed Wide/LZ4 parts with plain adaptive marks, Object V3,
one-bucket shared MAP, BASIC child Dynamic mode and the existing supported
inner Object grammar. Its finite stock witness uses typed `t UInt8` and shared
String values; it does not restrict the overall full-type/MV/projection
objective or qualify every recursive product.

No new Compact, bucketed/ADVANCED shared JSON, SKIP/REGEXP, Map version, projection,
MV execution or performance claim follows from this probe.

## Source anchors and runtime distinction

Source-only reference: clean shallow, unbuilt
`ef037e60fc7f5654c8c80eefb8be82e3c56f9a67` at
`/Users/sergey/SrcArchives/clickhouse-2026-10-05-depth1-ef037e60`.

- `SerializationArray.cpp:297-327,352-395`: child prefix/suffix/data use the
  enclosing settings under ArrayElements; the empty-range branch still invokes
  nested serialization.
- `SerializationTuple.cpp:794-832`: prefix/suffix recursion delegates to each
  child while retaining a separate state vector entry per Tuple occurrence.
- `DataTypeDynamic.h:24`, `DataTypeVariant.h:43`,
  `DataTypeNullable.cpp:32-35`: not every nominal Cartesian product is legal
  in stock ClickHouse; recursive composition preserves its type admission laws.
- `SerializationObject.cpp:712-842`: ObjectStructure prefix state is cached
  using the current full substream path, before typed/dynamic/shared recursion.
- `MergeTreeDataPartWriterWide.cpp:568-585,590-615,864-868`: runtime Object/Dynamic
  settings, prefix and suffix are part of the Wide write context.
- `DataTypeArray.cpp:59-64`, `DataTypeDynamic.cpp:62-67`,
  `DataTypeVariant.cpp:203-220`, `DataTypeObject.cpp:185-194`: type-level Map
  serialization-info propagation is conditional. `MergeTreeSettings.cpp:425-428`
  and `MergeTreeDataWriter.cpp:1004-1015` govern its default and persisted info.

Executed stock is separate:
26.10.1.1201 / `d9bcb5ab007f0f6299f7f973f2642245bab3d028`, executable SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
The source audit alone does not qualify runtime filenames, marks or Crystal I/O.

## W183 executed physical discriminator

Three stock-written normalized Wide parts each contain eight outer rows,
four real two-row marks and one final zero-row mark. Exact authored schema,
ordered rows and `CHECK TABLE` output match in every profile. Five separately
supervised stock compressor invocations match primitive bytes to authored
literals; no Crystal codec produced those expected bytes.

| Profile | Decoded per-row Array sizes | Decoded `a.t` UInt8 values | `a.t` mark addresses |
|---|---|---|---|
| mixed ArrayJSON | `0,0,0,1,2,1,0,0` | `7,11,13,17` | `(0,0),(0,0),(0,1),(0,4),(0,4)` |
| all-empty ArrayJSON | eight zeroes | empty | five `(0,0)` addresses |
| root JSON control | not applicable | `1,2,3,4,5,6,7,8` | `(0,0),(0,2),(0,4),(0,6),(0,8)` |

Addresses are `(compressed-block offset, decompressed offset)` observations
for these small single-block lanes, not a universal packing rule. The mixed
child counts per real outer mark are `0,1,3,0`, derived from decoded lengths
and checked against typed-lane addresses. Mark row fields remain the outer
`2,2,2,2,0` grid; they must not be read as JSON element counts.

The ArrayJSON roster includes `a.object_structure`, `a.size0`, `a.t`,
`a.object_shared_data.size1`, and escaped shared-path/value lanes. Root JSON
uses shared `size0` instead. The all-empty part retains the structure and
five marks per stream while its typed/shared value files are empty. Structure
and shared-data payloads are inventoried only; they are not decoded by this
probe. Requested table settings are recorded, not an effective-settings audit.
The root control qualifies its own primitive lanes and provides a shared-size
array-level naming comparison. It does not prove Object state independence:
the full-path state law above is source-derived, and a runtime test with two
equal nominal sites and different rosters remains open.

Executed command (use a new empty direct child of `/private/tmp` to repeat):

```sh
env COGNI_RUN_SAFE_MIN_FREE_PCT=50 RUN_SAFE_PASSTHROUGH_STDIO=1 \
  TMPDIR=/private/tmp \
  SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk \
  /Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh \
  /usr/bin/ruby 600 12288 scripts/probe_json_array_storage_w183.rb \
  --evidence-root /private/tmp/crystal-click-json-array-storage-w183.BAXu3S
```

Actual guard exit 0; all eight native processes exit 0 without signal,
timeout or captured I/O error. Local queries use one thread and 512 MiB;
compressor calls use one thread and at most 64 KiB of captured compressed input,
without claiming a query-memory setting. The outer runner uses 600 seconds,
12 GiB and the unchanged 50% system-free-memory preflight (observed 83%).

Root independently reconciles 72 captured native/stream hashes, five decoded
literal payloads, typed/size mark addresses and rebased shared-stream names.
Eight seeded controls reject empty/wrong/malformed marks, duplicate stream
names, cross-profile paths, evidence overwrite, a successful utility returning
wrong bytes, and post-run executable hash drift. These do not mutate native
parts or invoke native processes. Ruby syntax and these checks pass; no Crystal
source changed, so no Crystal regression suite was rerun.

The curated index is [evidence/json-array-storage-w183.json](evidence/json-array-storage-w183.json).
Native summary SHA-256:
`50a3a03f7fda921d62ec66db943ad4bceff66f494c93cbd18b53ce20bea7d47f`.
Root receipt is `/private/tmp/crystal-click-w183-root-checks.UUegmb/receipt.json`
(`4322c1909730848a11bc02e89ecbcd4f07cadd50eba7311c62046f14951cfade`).
Its verifier is `check.rb` in the same directory, SHA-256
`8c1dcb814bcbbeb458ceeb381670076adc86e71188a655cad445781c741e88ad`.

Two failed runner attempts are retained: `PkA7Z3` ran one successful CH query
but exposed Ruby 2.6's missing `filter_map` and a legitimate catalog symlink;
`kWa3P9` ran three successful queries but exposed a nil prefix read on empty
stream files. The final probe fixes those runner errors. They are not evidence
of unsupported ClickHouse types. Scoped hostile verdict: ROBUST for the finite
native layout discriminator and probe guards, not Crystal storage support.

## Execution order and falsifiers

### W184 paired occurrence-grid foundation (2026-10-06)

The implemented foundation separates physical outer rows from logical child
occurrences in one immutable `StorageOccurrenceGrid` owner. Its complete real
mark grid has positive Int32 physical row counts and nonnegative Int32 child
counts; the terminal record is implicit. A child count may exceed its physical
row count (Array fan-out). It is not a nominal type descriptor or a complete
structural site/state plan, and counts supplied by a caller do not prove their
derivation from Array offsets or Variant selections.

Explicit borrowed-budget child entry points reuse Object, Dynamic and
discriminator owners. They validate the complete grid even for an empty
selected window, admit zero child groups only through this explicit context,
and retain the existing root API's nonempty-real-mark behavior. Child
discriminators are BASIC-only for this step: zero children emit no body bytes,
but their mode prefix and all mark coordinates remain present. COMPACT child
composition stays refused; root BASIC/COMPACT behavior stays unchanged.

The paired physical lane seam validates discriminator rows against child
counts while emitting adaptive mark row fields from positive physical counts.
Repeated offsets are legal for zero child ranges. A mismatch, a nonempty body
for zero BASIC children, an invalid terminal, or a backward offset is rejected.
This seam does not admit root-named Object lanes as ArrayJSON filenames.
Ordinary bulk lanes must come from the codec's checked row groups. Their
generic byte offsets alone cannot prove a type-specific number of values in
each range; this seam is not an arbitrary fabricated-payload validator.

Implementation ownership: `src/crystal_click/storage_occurrence_grid.cr`,
the explicit child entry points in `object_document_codec.cr`,
`dynamic_value_codec.cr` and `dynamic_discriminator_codec.cr`, the lane seam in
`object_document_column_lane.cr`, and registration in `src/crystal_click.cr`.
Focused tests live in `spec/storage_occurrence_grid_w184_spec.cr` and
`spec/object_child_occurrences_w184_spec.cr`. Existing part/table/schema guards
are not widened. Rollback is one atomic local feature commit.

First behavioral falsifier: run the stock-observed `0,1,3,0` child grid through
the pre-existing root owner on baseline `4464ef3`; it must expose the current
nonempty-group refusal rather than a missing-method compilation error. The
permanent child tests must then admit that grid through the explicit new seam
while the original root rejection tests still pass.

Root executed that baseline discriminator before production edits. The existing
UInt8 bulk codec emits authored bytes `7,11,13,17` and offsets `0,0,1,4,4` for
the same groups; the root Object owner then raises
`Object document real marks must contain at least one row`. Actual guard/child
exit is 1 in
`/private/tmp/crystal-click-w184-occurrences.i3E4Ar/baseline-red3.log`.
The root API is supposed to retain this refusal after the child seam is added.
The two earlier attempts failed at probe authoring (absolute Crystal require,
then private `BinaryValue.new`), not at the behavioral boundary; their logs
are retained and do not count as the RED signal.

Foundation DoD: actual guarded DEBUG and RELEASE execution of the two new
specs together with W121 discriminator/budget, W122 Dynamic/adversary, W123
Object/root/adversary and W127 column/lane regressions. Require exact authored
typed/discriminator bytes and coordinates, full/nonzero-origin/empty windows,
all-empty children, detached grids, shared budget exhaustion, mismatches and
malformed lane guards. Hostile review must distinguish this internal paired
foundation from generic recursive JSON part/table admission. Physical tests
must reopen compressed lanes with the existing reader; in-memory round trips
alone do not close this foundation DoD.

The pinned source corroborates the finite BASIC rule:
`SerializationVariant.cpp:199-223,314-345` writes the mode prefix, then returns
from a zero-size child bulk range before emitting any discriminator body.
This is source corroboration, not a new executed stock Dynamic witness.

Root executed 26 selected specs in three disjoint serial cohorts per mode:
foundation 64, physical 52 and composition 65 examples. All 181 DEBUG and 181
RELEASE examples pass with zero failures/errors/pending and six actual
child/guard exits 0. Runs use Crystal 1.21.0, the unchanged 600-second/12-GiB
guard and >=50% free-memory preflight (83% observed), isolated caches,
`--single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace`, and
`--release --no-debug` only in RELEASE. No native runtime is executed in W184.

The tests reopen both mixed and all-empty compressed typed/discriminator file
pairs, inspect complete physical grids and check literal bytes/offsets. They
also reject equal-total redistributed counts, malformed terminals and child
COMPACT mode, preserve the root refusal, observe one budget identity across
Object -> Dynamic -> discriminator, and prove a low transport budget rejects
before the Variant prefix adapter is called (with a positive control).
Root's separate authored probe checks NULL versus empty groups, a nonzero-origin
window, an empty-selection mismatch, literal discriminator bytes and manually
decoded `.mrk2` row fields `2,2,2,2,0`, then reopens the compressed files.

After formatter normalization of one conditional's indentation, root repeats
all six final cohorts and the separate authored probe. One complete immutable
manifest contains 847 source/spec files and 1,192 fixture files, with no excluded
child spec. It matches after every final cohort and the final probe; all
production inputs are identical across these final gates. Earlier successful
runs and their manifests remain historical evidence, not extra final examples.
The format check passes for all eight changed/new code and spec files.
Two foundation attempts failed at test-authoring compilation only
(module/class observer declaration, then nonexistent `File.binwrite`); neither
counts as behavioral evidence. Their logs remain alongside the successful gates.
Scoped hostile verdict: ROBUST for this internal BASIC foundation. Luna's
same-lineage static review is correlated; root's actual executions and separate
literal/raw-mark probe supply behavioral checks. This is not the complete
repository suite, stock whole-part interoperability or performance evidence.
Exact roster, commands, hashes, failed attempts and scope:
[json-child-occurrences-w184.json](evidence/json-child-occurrences-w184.json).

Continuation:

1. Derive child grids from checked Array offsets/Variant selections instead
   of trusting caller-supplied counts; bind each full structural site to its
   nominal caps, actual rosters, state and serialization profile.
2. Add site-aware names/array levels, metadata discovery and binding. Adapt
   whole-column statistics, whose root nonempty-grid rule is still intact.
3. Integrate paired complete-part reader/writer and table consumers while
   retaining unqualified early storage guards. Keep owners in separate files.
4. Qualify library-owned parts with stock ATTACH/CHECK and literal full/middle
   reads; independently stock-written parts must reopen through Crystal.
5. Attack zero children, mismatched offsets/counts, truncated/suffixed lanes,
   two equal nominal JSON sites with different actual rosters, caps, shared
   budgets and unsupported layouts. Include part/table consumers, not only a
   scalar re-encode or a role-name plan.

DoD for storage admission: paired complete parts and actual table reads,
relevant DEBUG/RELEASE regressions, preservation of rejected consumers and a
scoped hostile review. The native probe alone cannot satisfy this DoD.

Decay: wrapper paths, Object/Dynamic state ownership, mark interpretation,
serialization settings, runtime pins or consumer admission changes require
refreshing the affected source/probe and paired I/O evidence.
