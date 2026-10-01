# CrystalClick Modularization Frontier

Document status: W89 implemented and verified on the combined W88+W89 source;
W90 Array(Map) plan owners, W91 payload owners and W94 bounded Tuple owners
are verified below. The larger reader/writer modularization remains future work.
W95 high-level Tuple consumers are verified within their bounded profile in
`COMPOSITIONAL_TUPLE_FRONTIER.md`; their three new concrete owners remain
separate from the large existing facades.
The October 1 catalog owner extraction is verified below; it preserves the
existing API and behavior, not a completed responsibility-level architecture.
W96 adds one closed numeric identity/width owner and extends the existing
Tuple owners; its compatibility certificate is separate in
`NUMERIC_TUPLE_FRONTIER.md`. It does not close the larger facade refactor.
W97's Bool extension uses those same Tuple owners with separate semantic Bool
dispatch; its bounded compatibility certificate is in `BOOL_TUPLE_FRONTIER.md`.
Bool is not added to the numeric identity owner or a per-combination Tuple class.

W98 reconciles the existing Bool value-domain policies under one shared owner;
its qualified RED and executed bounded compatibility certificate are recorded in
`BOOL_SEMANTICS_FRONTIER.md`. This is not completion of the facade refactor.

W99 extends named flat Tuple leaves to UUID/IPv4/IPv6 through one nominal
identifier owner/file and the existing Tuple reader/writer/model owners.
Focused DEBUG/RELEASE (162 examples each), full DEBUG (1,279 examples), the
new bidirectional stock oracle and seven unchanged regression oracles passed.
Root's scoped adversarial verdict and residual limits are recorded in
`IDENTIFIER_TUPLE_FRONTIER.md`; the larger facade refactor remains open.

W100 extends the same named-flat Tuple contracts to the raw temporal family.
Its six immutable value structs each have their own file, with one cohesive
temporal identity/parameter owner. The compatibility evidence and exclusions
are tracked separately in `TEMPORAL_TUPLE_FRONTIER.md`. Focused DEBUG/RELEASE
(259 examples each), full DEBUG (1,348 examples), the bidirectional temporal
oracle and eight unchanged regression oracles passed. Root's scoped verdict
is ROBUST; this is not completion of the larger facade refactor.

W103 adds paired scalar/Nullable QBit through twelve concrete owners, each
with its own source file. Its type, owned raw value, plane codec, physical
reader/validator, table adapter, writer input/infrastructure/orchestrator and
offline materialization boundaries are described in `QBIT_FRONTIER.md`.
Focused DEBUG and RELEASE each passed 41 combined QBit/PK examples; full DEBUG
passed 1,433 examples. The bidirectional 80-profile QBit stock oracle, its
3000-row split-plane control and five existing regression oracles passed.
Root's scoped verdict is ROBUST in `QBIT_FRONTIER.md`; this is not the full
facade refactor.

W104's timezone-qualified DateTime/DateTime64 extension is verified within its
pinned seven-shape profile: focused DEBUG/RELEASE each passed 431 examples,
full DEBUG passed 1,695, both 297-profile stock-oracle phases and six regression
oracles passed.
Its new declaration and timezone admission owners each have their own file;
the sealed scope, executed gates and residual limits are in
`TIMEZONE_TEMPORAL_FRONTIER.md`.
It does not claim completion of the larger facade refactor.

W105 adds one immutable `WideTupleLeafType` schema owner and one immutable
`ScalarNullMap` storage owner, each in its own file, for nullable scalar fields
inside named-flat Tuple. It preserves the closed raw carriers rather than
adding a per-family Cartesian set of `Array(T?)` buffers. Reader, writer and
table/catalog consumers use the same schema/mask contract. Focused DEBUG and
RELEASE each passed 537 examples; full DEBUG passed 1,719. Bidirectional stock
qualification, both timezone phases and ten unchanged Tuple/temporal/QBit
regression scripts passed. The scoped certificate, accessor migration and
logical-budget/RSS distinction are in `NULLABLE_TUPLE_FRONTIER.md`.
The larger facade decomposition remains open.

W106 introduces an immutable recursive named-Tuple schema node, recursive
serialization-metadata validator, and writer statistics/node-statistics owners,
each in its own file. The existing leaf buffers and codecs remain unchanged;
schema topology and physical path naming have one shared authority. Its paired
qualification and remaining exclusions are recorded in
`NESTED_TUPLE_FRONTIER.md`: focused DEBUG/RELEASE each passed 550 examples,
full DEBUG passed 1,732, and the new bidirectional stock oracle plus W105,
W104 and ten unchanged stock regression gates passed on frozen source.
This is not the full facade decomposition.

W107's bounded paired profile is verified in
`ARRAY_TUPLE_COMPOSITION_FRONTIER.md`. Its twelve new concrete production
owners each have one file: plan, ragged schedule, result/row handles, reader,
table/catalog adapters, writer input/orchestrator, shared leaf-mark schedule,
leaf dispatch and physical-value comparison. Physical outer-row marks are
adapted to flattened Tuple elements without copying scalar decoders; W106 and
W107 share the leaf stream writer. Focused DEBUG passed 581 examples; the
same 55 RELEASE inputs passed in disjoint 24/24/7-file batches (581 total);
full DEBUG passed 1,751. Paired W105/W106/W107 stock phases, all five affected
Tuple family stock scripts and the 297-profile W104 writer phase passed.
This is not a claim that the large facades or resource lifetimes have been
decomposed, nor a combined/full RELEASE certificate.

W108 adds ten concrete production owners, each with one file: Map(Tuple)
plan, ragged schedule, owned column data, row handle, reader, table adapter,
offline materializer, writer input and orchestrator, plus a shared internal
Tuple leaf decoder. The existing Tuple reader and Map keys delegate to that
one decoder; the leaf stream writer exposes one internal explicit-path seam
instead of duplicating a codec/width table. The new Map row identity and
outer/entry axes remain separate from Array(Tuple).

The scoped certificate is in `MAP_TUPLE_COMPOSITION_FRONTIER.md`: focused
DEBUG 25, regression DEBUG 82, the same 22 inputs split into two RELEASE
batches (31 + 51), full DEBUG 1,776, five-profile reader and writer stock
phases, six predecessor phases and five affected leaf-family stock scripts
passed. Root's scoped hostile verdict is ROBUST. This is not a combined/full
RELEASE, current-master executable, RSS or full architecture certificate.
The remaining facade counts are reader 15,585 lines, writer 25,920, table
6,889, catalog 1,560 and extracted OfflineTable 3,637. These are navigation
counts, not evidence of reduced coupling or performance. Cohesive physical
stream lifetime/policy, codec dispatch, staging and table responsibility
decomposition remains open.

W109 adds paired scalar Point through nine concrete owners, each in its own
file: raw value, exact type descriptor, serialization profile, physical reader,
table adapter, offline materializer, writer input, statistics and orchestrator.
It shares Float64 decoding, Tuple leaf framing, checksums and staging authority
instead of introducing a second codec or disguising Point as an unnamed Tuple.
Its bounded certificate is verified in `GEO_TYPES_FRONTIER.md`: final focused
and regression DEBUG/RELEASE each passed 83 examples, full DEBUG passed 1,793,
and both four-profile stock phases passed exact raw-bit/metadata/mark/PK,
fresh ATTACH CHECK=1 and literal full/selected RowBinary checks. Root's scoped
hostile verdict is ROBUST. The facade line counts at this fingerprint are
reader 15,764, writer 25,958, table 6,980, catalog 1,560 and OfflineTable 3,651.
The large facades still need responsibility-level decomposition; one owner
per file does not prove lower coupling or performance.

## Catalog owner decomposition (2026-10-01)

Status: VERIFIED within the source-owner extraction and executed gates below.
Baseline is `5c291c8117a3cec72cb51f84dde73ac0d73a6e77`.
The original `offline_catalog.cr` has 5,395 lines and combines column-value
aliases, three public metadata structs, table access, column selection,
database navigation and catalog discovery/DDL parsing. The first extraction
separates those existing owners; it does not introduce new types, change
serialization, or claim that the table/catalog responsibilities are fully
decomposed.

Risk: CAUTION (large mechanical move and aggregate require integration).
Rollback is the exact owner-file extraction and require changes; no data,
dependency, publication or remote-history operation is involved. Preserve the
separate proposed Map(Tuple) frontier rather than mixing it into this commit.

Plan:

1. Keep `OfflineCatalog` in `offline_catalog.cr`; move its private
   `DatabaseLocation` model to `offline_catalog/database_location.cr` with
   identical namespace and visibility.
2. Give `OfflineColumn`, `OfflineProjection`, `OfflinePartCandidate`,
   `OfflineTable`, `OfflineColumnSelection`, and `OfflineDatabase` one file
   each under `src/crystal_click/`. Move aliases to `offline_column_value.cr`.
3. Preserve declarations, comments and method bodies, allowing only enclosing
   namespace/require integration and boundary blank lines. Keep metadata-only
   lookup, lazy scans, owned value materialization, candidate-versus-Active
   semantics and all bounds unchanged.
4. Integrate the aggregate require graph, then compare the reconstructed
   owners with the baseline. The strongest failure mode is a dropped private
   method, visibility change or missing require hidden by a focused test.
5. Execute the seven focused catalog/MV/projection/TUI specs in DEBUG and
   RELEASE, full DEBUG, and the W86/W87/W88 stock oracles. Check format and
   staged diff hygiene, inspect the exact diff, and make one local commit.

The original aggregate import in `src/crystal_click.cr` is unchanged.
`offline_catalog.cr` remains the compatibility entry point and requires the
seven public/alias owners plus the private nested `DatabaseLocation` owner.
`OfflineCatalog` now occupies 1,560 lines; the moved `OfflineTable` still
occupies 3,615 lines and is not a responsibility-level decomposition.

Executed certificate (2026-10-01, Crystal 1.21.0, ClickHouse 26.7.1.1315):

- Baseline seven-file DEBUG: 113 examples, zero failures/errors/pending.
- Post-extraction same seven files in DEBUG and RELEASE: 113 examples each,
  zero failures/errors/pending, exit 0.
- Full DEBUG: 1,751 examples, zero failures/errors/pending, exit 0. The linker
  emitted a non-fatal duplicate `-lc` warning. Full RELEASE was not executed.
- W86 stock metadata oracle: persisted MV/table kinds, exact DDL and named
  projection metadata agree with stock-generated files, exit 0.
- W87 stock projection oracle: both child parts and the four-row catalog scan
  agree with ClickHouse; the incomplete projection set rejects before
  callbacks, exit 0. Stock `CHECK TABLE` returned 1 for both source parts.
- W88 stock MV oracle: stock trigger control and Crystal detached identity
  recomputation pass; the generated part passes stock `ATTACH PART`,
  `CHECK TABLE` and exact source/target row comparison, exit 0.
- Complete source reconstruction from all eight extracted files and the
  remaining catalog matches every nonblank baseline line, including comments,
  constants, declarations and visibility. A seeded identifier drift is
  rejected by that guard. Blank-line normalization is not a behavioral proof.
- `crystal tool format --check` on all nine source files and diff hygiene pass.

The focused inputs are `spec/offline_catalog_spec.cr`,
`spec/offline_catalog_w86_spec.cr`,
`spec/offline_catalog_projection_w87_spec.cr`,
`spec/wide_part_table_projection_w87_spec.cr`,
`spec/offline_mv_materialization_w88_spec.cr`,
`spec/offline_catalog_w95_tuple_values_spec.cr`, and
`spec/offline_tui_page_source_spec.cr`. From the repository root, the executed
commands used `crystal spec --single-module --link-flags=-fuse-ld=ld` with
those inputs, then the same invocation with `--release`, and finally the
DEBUG invocation without explicit spec paths. Stock commands were
`bash scripts/check_offline_schema_w86_oracle.sh`,
`bash scripts/check_projection_w87_oracle.sh`, and
`bash scripts/check_mv_materialization_w88_oracle.sh`.

Heavy gates ran serially through
`/Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh`, with a 600-second
limit, 8 GiB focused/stock limit (32 GiB full DEBUG), and a 50% free-memory
floor. Both `CLICKHOUSE` and `CLICKHOUSE_BIN` selected
`/Users/sergey/.local/bin/clickhouse`; Crystal was
`/opt/homebrew/bin/crystal`. The isolated cache was
`/private/tmp/crystal-click-catalog-refactor-cache`; stock scripts used their
own temporary caches. The host SDK was MacOSX26.5 and the system linker
override above was retained. No current-master binary qualification is claimed.

Frozen source fingerprint: SHA-256 of the newline-terminated
`shasum -a 256` manifest, in the plan order (catalog, aliases, column,
projection, candidate, table, selection, database, private location), is
`5fc3cdf73efc848fc9fd769a3856f94f5b56ee6779f4de6b9d4d784d98b6076b`.
All nine paths are under `src/crystal_click/`; the remaining catalog and
eight owner files are the complete production scope of this extraction.

Root's scoped adversarial verdict is ROBUST: reconstruction and its seeded
negative control address lost bodies/declarations; aggregate compilation,
runtime tests and stock probes address require integration and observable
regressions. A Luna read-only static review also found no visibility or import
widening; that correlated review alone is not independent runtime evidence.
This certificate expires on affected source, require graph, compiler, binary
or fixture/profile changes; rerun the affected identity and behavioral gates.

Further responsibility extraction remains open: offline DDL parsing,
selected-value materialization, physical-stream lifetimes, leaf codecs and
reader/writer orchestration. One owner per file alone does not prove lower
coupling, lower memory use, better throughput or full ClickHouse compatibility.

## W104 ownership boundary

`DateTimeColumnType` owns exact temporal family, precision, timezone provenance
and the six existing scalar/Nullable/Array shapes. `TimezoneName` owns a copied
admitted token; the private `ClickHouseTimezoneCatalog26_7_1_1315` owns the
versioned pinned name manifest. Each concrete class has one source file.
Persisted parsing is strict, while catalog-only parameter normalization is a
separate entry point. No host timezone lookup or duplicate temporal codec is
introduced.

Named-flat Tuple field/plan/leaf owners retain the scalar descriptor and
share it through owned row/column snapshots. Raw DateTime value structs are
unchanged: timezone provenance belongs to the schema, not each raw value.
The plan bills the actual field slot and retained descriptor independently
of physical width. This logical budget is not a peak-RSS certificate.

Reader, writer and high-level consumer facades use the shared recognizers;
their existing mark/checksum/stream-lifetime and publication infrastructure
remain in place. The new owners and Tuple snapshots defend their String
exports, but older facade String exports are not universally hardened here.
Whole-facade decomposition, generic recursive types and performance remain
open. Adding three class files is not evidence of lower coupling or faster
execution.

## Next proposed lifecycle extraction

Adjacent artifact-integrity residual observed during W107 static review:
`wide_part_writer/tuple_part_writer.cr#validate_staged_part` verifies the exact
checksums entry set and expected metadata contents, but does not compare the
complete `Dir.children(stage)` inventory. This is also present at predecessor
`63e03b4`; W107's `ArrayTuplePartWriter` does perform that complete comparison.
No ordinary extra-file injection path or payload/mask/schema-check bypass was
found. This is not a universal staged-artifact certificate for the older Tuple
writer. A separate hardening slice must first seed an unexpected unchecksummed
stage file, establish its observed disposition, then qualify rejection and
scratch-only cleanup before changing that publication boundary.

Status: PROPOSED, not implemented or verified. At the qualified W104 source the
four facades still contain 15,422 reader, 25,821 writer, 6,759 table and 5,371
catalog lines. These navigation counts do not measure coupling or performance.

The narrow next responsibility is staged stream-file lifetime, not another
codec or a mechanical relocation of whole facades. In
`WidePartWriter.validate_staged_array_map_array_numeric_part`, data and mark
files are opened before the cleanup region. In
`validate_staged_array_map_bool_leaf_streams`, the values pair and optional
null pair are likewise acquired before `begin/ensure`. A later open error can
therefore bypass explicit closure of earlier acquired handles. This is a
source-level failure path; runtime leak qualification remains open.

Proposed owner: one `StagedStreamFileSet` class in
`src/crystal_click/wide_part_writer/staged_stream_file_set.cr`. It owns only
ordered acquisition and closure, including partial acquisition and a failing
validation block. Validators depend on this owner; the owner depends only on
standard file I/O, not the writer, reader, table or catalog. Path/hash selection,
stream order, frame/mark/sentinel checks, metadata, staged readback and exclusive
publication stay with their existing owners. Cleanup must attempt every owned
handle and must not mask the original open or validation error.

Risk: CAUTION (resource lifetime and exception propagation). Rollback: only the
new owner, the two call sites, aggregate require, and directly related tests.
Before production, establish a discriminating partial-acquisition failure
probe rather than treating a missing future class as behavioral RED. The owner
contract then needs tests for failure at each acquisition position, validation
failure, success, handle closure and preservation of the original error.
DoD also retains `spec/wide_part_writer_w83_spec.cr`, W84 and W85 writer specs,
their stock writer oracle modes, full DEBUG, format and diff checks. No type,
codec, metadata, publication or performance widening belongs in that commit.
After this slice, physical reader lifetime, leaf codecs, table scan adapters
and catalog parsing/navigation remain separate larger extractions.

## W103 ownership boundary

`QBitType` owns the closed element identity and dimension/stride grammar;
`QBitColumnType` owns bounded physical planning and logical materialization
charges. `QBitValue` owns exact raw element bytes, with defensive export and
raw-bit equality. `QBitPlaneCodec` alone owns transpose/untranspose bit order.
These are four separate files, not a new per-carrier class hierarchy.

`QBitSerializationProfile`, `QBitStreamValidator` and
`WidePart::QBitReader` own physical profile admission, metadata-only schedule
validation and selected-range decoding in three files under `wide_part/`.
The lower reader never depends on a table adapter. The separate
`QBitColumnAdapter` consumes that lower-layer contract, and
`QBitValuesMaterializer` bounds the actual offline union slot
charge before allocating `.values`. Neither adapter owns a second plane codec.

The writer's `QBitPartWriteInput`, `QBitPartInfrastructure` and
`QBitPartWriter` each have one file under `wide_part_writer/`. Input capture,
physical callbacks and stage orchestration remain separate. The writer uses
the existing bounded frame/marks/checksum/exclusive-publication helpers via
narrow facade delegates and validates real staged bytes before publish; the
test seam cannot replace its validator. QBit does not enter the named-Tuple
leaf union or imply arbitrary recursive compositions.

The existing four facades still own shared infrastructure and orchestration.
Physical-stream lifetime/validation ownership, cohesive leaf-codec extraction,
table/catalog orchestration and the older Array(Map) intermediate-file-open
cleanup concern remain open. New owner files and shorter navigation paths do
not establish reduced coupling, lower peak RSS or improved throughput.

## W100 ownership boundary

`DateValue`, `Date32Value`, `DateTimeValue`, `DateTime64Value`, `TimeValue`
and `Time64Value` retain nominal identity rather than relabeling UInt16,
Int32, UInt32 or Int64. Scaled values carry validated precision with their
raw ticks. `src/crystal_click/wide_tuple_temporal_type.cr` owns the closed
declarations, exact parameters, physical widths, actual owned slot sizes,
raw/precision equality, buffer compatibility and qualified raw-zero storage
default predicate. Calendar conversion and byte encoding do not belong to
this owner; temporal values do not enter `WideTupleNumericType`.

`WideTupleLeafColumn` retains exact metadata even for empty temporal buffers;
the existing plan owns streams and aggregate charges. `TupleReader` and
`TuplePartWriter` receive one temporal callback each and reuse the existing
primitive LE codecs through narrow facade adapters. The writer takes one
owned values snapshot, validates every row/precision before staging and
checks exact nominal values during staged readback. Table/catalog continue
through `WideTupleColumnData` and the single `WideTupleRow`; no production
table/catalog edits, per-arity class or Cartesian combination union are added.

At the frozen W100 production source, reader/writer facades contain 15,301
and 25,359 lines, with table/catalog at 6,638 and 5,309. These navigation
counts are not evidence of lower coupling, lower memory or faster execution.
The larger facade decomposition, physical-stream lifetime/validation owner,
cohesive leaf-codec extraction and table/catalog orchestration remain open.
The older Array(Map) intermediate-file-open cleanup concern and bounded
Tuple readback allocation are unchanged. Each future extraction still needs
a behavior-preserving contract and one concrete owner per file.

## W99 ownership boundary

`src/crystal_click/wide_tuple_identifier_type.cr` owns the closed UUID/IPv4/
IPv6 identity set, exact widths, raw-bit equality and zero-default predicate.
The nominal wrappers do not enter `WideTupleNumericType`. The root require
graph loads their shared owner after scalar wrappers and before Tuple plan/
value owners. Leaf buffers retain exact wrapper arrays; the existing plan
owns streams/charges and the existing reader/writer orchestrators keep their
separate identifier callbacks. Scalar payload encoding and LE/BE primitives
remain the original physical owners, not duplicated Tuple serializers.

`WideTupleColumnData` and the single `WideTupleRow` already consume the owned
leaf contract. Table/catalog need no parallel identifier dispatch, new
per-arity class, Cartesian combination union or production edits. This is a
bounded owner-contract extension, not general recursive type admission.

At the frozen W99 production source, reader/writer facades contain 15,244 and
25,326 lines; table/catalog remain at 6,638 and 5,309. The facades grew through
narrow adapters and are not decomposed by this slice. Navigation counts do
not prove performance or lower coupling. Physical-stream lifetime/validation,
cohesive leaf-codec ownership and table/catalog orchestration remain open,
with one concrete owner per file and behavioral gates for each extraction.
The older Array(Map) intermediate-file-open cleanup concern and bounded
Tuple readback allocation are unchanged.

## W98 ownership boundary

`src/crystal_click/bool_value_codec.cr` owns UInt8-to-Bool semantic decoding,
canonical Bool-to-UInt8 encoding, and owned bulk decoding. Root, nullable,
Array, Array(Map), Variant and named-Tuple consumers delegate to this one
module/file; null-map and discriminator policies remain with their structural
owners. Bool stays outside the numeric identity owner.

The writer reuses bounded per-mark frame/mark/sentinel validation rather than
adding whole-stream reads. Tuple orchestration receives the actual Bool raw
validator through its existing infrastructure owner. Those staging helpers
still live in the large writer facade; they are not a new decomposed physical
stream subsystem. File-size reduction and independent ownership of the full
reader/writer/table/catalog remain open, separately from W98's value-domain
compatibility certificate. Focused DEBUG/RELEASE (168 examples each), full
DEBUG (1,259 examples), the new nine-profile bidirectional oracle and five
unchanged stock oracles passed; root's scoped adversarial review is ROBUST.
These gates and residual risks are recorded in `BOOL_SEMANTICS_FRONTIER.md`.

At the frozen W98 source, the reader/writer facades still have 15,195 and
25,295 lines, with table/catalog at 6,638 and 5,309. These navigation counts
do not establish performance or lower coupling. The next architectural slices
remain physical-stream lifetime/validation ownership, cohesive leaf codecs and
table/catalog orchestration, one concrete owner per file with behavior-preserving
contracts. In particular, W98 does not close the older Array(Map) validator's
intermediate-file-open cleanup concern or Tuple's bounded readback allocation.

## W97 ownership boundary

`WideTupleLeafColumn` owns native Bool buffers alongside, but nominally separate
from, numeric and String buffers. `WideTupleTypePlan` owns one-byte Bool stream
planning and logical charges. `TupleReader` and `TuplePartWriter` orchestrate
their existing bounded stream infrastructure, while narrow private facade
delegates provide nonzero-aware reading and the existing canonical Bool codec.
`WideTupleRow` remains the single table/catalog row representation. No new
production class or import-order change is needed for this extension.

At the historical W97 source, reader/writer facades contain 15,223 and 25,134 lines; table
and catalog remain at 6,638 and 5,309. W97 does not claim to have decomposed
these facades. A next compatibility slice should reconcile root/Array/container
Bool's strict 0/1 read policy with the stock-supported nonzero domain, then
give the shared Bool leaf policy a cohesive owner with its own file. Broader
leaf-codec, physical-stream-context, metadata and table orchestration ownership
remains open. File counts and shorter files alone do not prove lower coupling.

## W96 ownership boundary

`src/crystal_click/wide_tuple_numeric_type.cr` owns the exact primitive numeric
identity set, widths, raw-bit equality and bounded default predicate in one
module/file. It is not a second byte codec. `WideTupleTypePlan` consumes that
contract, `WideTupleLeafColumn` owns concrete typed buffers, and the existing
`TupleReader`/`TuplePartWriter` owners orchestrate them through narrow private
delegates to existing scalar payload codecs. `WideTupleRow` remains one nominal
row representation for table and catalog consumers rather than an arity/type
Cartesian union.

The root require graph loads the numeric owner after the primitive wrapper
types and before Tuple plan/value owners. Legacy UInt64/String overloads and
exact-pair APIs remain guarded. Source ownership and shared payload dispatch
are architectural facts; only W96's executed tests/oracles establish its
bounded behavioral compatibility. Same-lineage static reviews are correlated.

The final W96 reader and writer facades still have 15,200 and 25,122 lines;
table and catalog have 6,638 and 5,309. These counts expose the remaining
navigation burden, not a performance metric or proof of coupling. Continue
with owner-by-contract slices and one concrete type per source file; do not
replace them with a mechanical multi-class file split or mix deferred memory
optimization into compatible-type admission.

## Problem and boundary

At `26ab2a2`, `wide_part_writer.cr` has 25,905 lines, `wide_part.cr` 14,989,
`wide_part_table.cr` 6,583, and `offline_catalog.cr` 5,283. File count alone
does not establish modularity: extraction must give each class one source file
and separate a responsibility with an independently checkable contract.
The committed W88 MV materializer owns `offline_catalog.cr` and its tests;
W89 must not mix with that storage behavior change.

## W89 admitted design

Move the bounded ClickHouse type-expression grammar out of the body of
`wide_type_plan.cr`. Create one source file each for `WideTypePlan::Node`,
`WideTypePlan::Parser`, and the new `WideTypeExpression` facade. Retain the
original nominal Node/Parser identities, not just aliases: public reflection
and diagnostics can observe their canonical names. The parser handles syntax,
parse limits, and AST construction only. `WideTypePlan` continues to own
physical substreams and exact admission policy, and keeps its existing
`.parse` method as a delegate to `WideTypeExpression`. The facade may expose
aliases back to the original Node/Parser types. Require node, parser, facade,
then `wide_type_plan.cr` in `src/crystal_click.cr`. Each concrete type owns its
methods in one file; the `WideTypePlan` namespace is reopened only to declare
its nested types.

Reject for W89: newly admitted ClickHouse types, changed parse trees or
limits, generic codec dispatch, changed on-disk bytes, changed public typed
table accessors, performance claims, and a mechanical redistribution of the
large reader/writer modules into multi-class files. These need separate
behavioral and compatibility slices.

Guard-only next boundary: the W80-W85 `Array(Map)` physical-plan builders in
`wide_part_writer.cr`: `array_map_string_uint64_physical_plan`,
`array_map_string_physical_plan`, `array_map_numeric_physical_plan`,
`array_map_array_physical_plan`, and
`array_map_array_numeric_physical_plan`. They form a roughly 661-line cluster
of private plan descriptors, builders, and axis comparison, separate from the
public writer facade and byte serializers. Extracting cohesive builders into
one class per file could remove plan ownership from the 25,905-line writer
without changing on-disk bytes. This needs its own exact stream/role/axis
falsifiers, W80-W85 writer/type-plan specs, available stock ClickHouse oracles,
and a separate commit; it is not admitted by W89's green parser tests. Moving
the already-small map-row adapters out of `wide_part_table.cr` is lower risk but
mostly improves navigation, not class responsibility. The borrowed batch
view, reader leaf codecs, and writer serializers need later owner-by-contract
slices. Do not treat lower lines-per-file as proof of lower coupling.

## Falsifiers and execution plan

Risk: CAUTION. The strongest failure is a changed AST nominal identity or
require order that silently changes exact admission. A first implementation
that moved the definitions under `WideTypeExpression` passed 35 focused and
1,115 debug examples, but hostile review found its aliases changed canonical
type names. That route is rejected despite green tests; preserve the original
`WideTypePlan::Node` and `::Parser` definitions in separate files. Rollback is
the isolated W89 commit; do not bundle W88 behavior with W89 refactoring.

Before editing, compare the W67/W69-W71 parse and admission specs on the
same source state. The bounded consumer search found no external use of
`WideTypePlan::Node` or `::Parser` in `src/`, `spec/`, or `scripts/`;
`WideTypePlan.parse` has one production call in its shadow plan and five
spec callers. Retain nominal names because absence of in-repo callers does
not prove public API freedom. After extraction, run the same focused specs,
the relevant reader spec, full debug and release suites, Crystal format,
and `git diff --check`. A no-codegen compile and direct AST type-identity plus
canonical-name checks are additional guards; neither replaces runtime specs.
The expected signal is identical parser output and admission, no new supported types,
and zero regression failures. Review the final diff specifically for
accidental semantics edits or circular requires before an atomic commit.

This evidence decays if Crystal's parser/reflection semantics, the type plan,
its callers, or the root require graph changes.

## W89 observed result

The syntax tree and parser now each have their own file; the new
`WideTypeExpression` facade has a third file. `WideTypePlan.parse` delegates
without changing the parser's 4,096-byte, 64-depth, or 512-node limits. A
hostile review found and rejected an initial implementation that changed the
canonical `WideTypePlan::Node` and `::Parser` names despite green tests. The
corrected implementation retains those nominal identities, guarded by the
new spec. The final adversarial verdict was ROBUST within the aggregate
`require "./crystal_click"` API. Direct internal-file imports were not found
in this repository and are outside that verdict.

The isolated worktree passed 35 focused examples and 1,115 full debug and
release examples, all with zero failures. After integrating over W88, full
debug and release each passed 1,125 examples with zero failures or errors;
the pinned ClickHouse MV part oracle also passed. Crystal format and staged
diff checks passed. These are regression and compatibility signals, not a
performance result, generic type-admission proof, or evidence that the larger
reader/writer classes have been modularized.

## W90 design and execution boundary

Move the five existing private `WidePartWriter::ArrayMap*PhysicalPlan` structs
into one file per struct under `src/crystal_click/wide_part_writer/`. Each
struct owns a `.build` factory and the exact stream, role, semantic path,
width, storage mode, cardinality, and mark-axis checks previously performed
by its writer helper. Retain the structs' nominal identities and value
semantics. The public writer facades call these factories, and the existing
serializers continue consuming the same descriptors. Numeric factories take
the expected leaf width computed by the existing writer width policy; they
must compare it with the planned stream width. A two-line axis comparator
may remain private in each owner rather than adding a shared base class.

Admitted change: responsibility and source-file ownership only. Rejected:
new types, relaxed admission, changed serializer bytes, new public accessors,
codec dispatch, performance claims, or replacing the structs with heap objects.
Risk is CAUTION; rollback is the atomic W90 commit. The strongest failure is
a check disappearing during extraction while ordinary round-trip tests stay
green. Guard it with role/order/width/axis negative cases at the owner boundary,
in addition to the existing W80-W85 exact-byte and admission tests. All five
builder helpers and descriptors have only writer-local consumers at `bff96b5`;
`numeric_width` is shared with other writer families and remains in place.

Execution order:

1. Record the W80-W85 writer/type-plan baseline and identify negative cases
   for altered stream order, role, leaf width, and count/mark axes.
2. Extract the five descriptor/factory files, update the aggregate require
   graph and writer-local calls, and remove the old helpers from the writer.
3. Run the focused specs, pinned stock ClickHouse oracles for the affected
   families, full debug and release suites, Crystal format, and diff checks.
   Expected signal: unchanged exact bytes and admission, rejection of malformed
   plans, and zero regressions. Review every moved predicate before committing.

The source inventory and certificates decay when physical-plan construction,
writer admission, serializer consumers, Crystal type semantics, or the pinned
ClickHouse profile changes. Reader codecs, serializers, and table adapters
remain separate future responsibility slices.

## W90 observed result

The five private plan structs now own their factories and validation in five
separate files. Their canonical names and struct value semantics are retained.
The public writer delegates to those factories; the byte serializers are
unchanged. Numeric leaf-width policy remains in the writer and is passed to
the relevant factory rather than duplicated. The writer decreased from
25,905 to 25,241 lines; this is an ownership/navigation result, not a measure
of performance or proof that the entire writer is modular.

The frozen implementation passed 37 focused W80-W85 writer/type-plan/owner
examples and full debug and release suites of 1,132 examples each, with zero
failures or errors. The release suite completed on 2026-09-30 UTC; its test
execution took 20.35 seconds, excluding compilation, and is not a reader
benchmark. New negative tests reject changed stream count/order, role, storage
mode/axis, leaf width, mark-row axis, and nested cardinality axes. A compiler
reflection check guards the nominal names and struct semantics without
exposing a production test hook.

All six pinned `26.7.1.1315` W80-W85 oracles passed in full reader+writer mode,
including stock-produced reads, exact selected streams/marks, full/key-range
RowBinary, and Crystal-produced parts checked/attached by ClickHouse. The
new W83 shell wrapper defaults to full mode and rejects an invalid mode or
an unpinned executable. W80 and W82 default to stock-only mode, so their full
checks require explicit mode flags; W85 is invoked through Bash because its
tracked wrapper is not executable.

Scoped hostile review found no removed validation predicate or changed
serializer and returned ROBUST for the aggregate import boundary. Direct
imports of internal files and future factories supplied with an incorrect
numeric width are outside that verdict. Root independently reviewed the
source diff and ran full debug, release, and stock-oracle checks. Same-lineage
review is correlated evidence, not an independent compatibility proof.

Observed checks use the following environment on this host:

```sh
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
export CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w88-cache
export CLICKHOUSE_BIN=/Users/sergey/.local/bin/clickhouse
export TMPDIR=/private/tmp
crystal spec --link-flags='-fuse-ld=ld'
crystal spec --release --link-flags='-fuse-ld=ld'
W80_ORACLE_MODE=full bash scripts/check_array_map_string_uint64_w80_oracle.sh
W81_ORACLE_MODE=full bash scripts/check_array_map_numeric_w81_oracle.sh
W82_ORACLE_MODE=full bash scripts/check_array_map_string_values_w82_oracle.sh
W83_ORACLE_MODE=full bash scripts/check_array_map_bool_values_w83_oracle.sh
W84_ORACLE_MODE=full bash scripts/check_array_map_array_w84_oracle.sh
W85_ORACLE_MODE=full bash scripts/check_array_map_array_w85_oracle.sh
```

Crystal format, shell syntax, and `git diff --check` passed. These checks do
not admit new types, prove compatibility with September master, establish
matched ClickHouse performance, or close the larger class-architecture task.
Evidence decays under the W90 source/profile changes listed above.

## W91 payload-owner result

The next neutral slice extracted four private concrete owners, one file each:
reader `WidePart::StringPayloadDecoder`, writer `WidePartWriter::LeafStreamWriter`
and `::StreamEncoding`, and the existing `::ChecksumRecord` struct. String
assembly is shared by the exact Tuple and scalar reader; actual UInt64/String
payload method bodies moved out of the writer, whose old entrypoints delegate.
Schema/physical admission, range policy, budgets and stage lifecycle remain
in place. The writer is still 25,045 lines and reader 14,982; this is a small
ownership improvement, not closure of the larger architecture task.

The frozen source passed 72 focused and 1,145 full debug/release examples, with
zero failures/errors, plus the pinned Tuple, typed and basic writer oracles.
Scoped hostile review returned ROBUST at the aggregate import boundary; root
also checked mechanical body parity and executed the runtime checks. Exact
commands, source/profile lineage, residual Tuple metadata/EOF gaps and evidence
decay are recorded in [the W91 seal and result](COMPOSITIONAL_TUPLE_FRONTIER.md).

## W94 bounded Tuple owners

The new named UInt64/String-leaf Tuple path has eight concrete owners, one
file each: `WideTupleField`, `WideTupleTypePlan`, `WideTupleLeafColumn`,
`WideTupleColumnData`, private `WidePart::TupleReader`, and private
`WidePartWriter::TuplePartWriter`, `::TuplePartWriteInput` and
`::TuplePartInfrastructure`. Schema metadata and owned columnar buffers are
separate from reader orchestration, write preflight/staging and narrow adapters
to existing infrastructure. The existing facades retain root physical-policy
checks and old public APIs; the new path delegates actual orchestration rather
than reopening the facade with another large method body.

This is a new bounded admission slice, not a behavior-neutral extraction or
closure of the modularization task. The reader is still 15,135 lines, writer
25,101, table 6,583 and catalog 5,283. Existing type-specific serializers,
physical-stream policy and table/catalog adapters need later cohesive owner
boundaries; moving their text alone would not reduce coupling.

Root executed 37 focused examples in debug and release and 1,180 full examples
in each mode, all with zero failures/errors/pending. The unchanged pair and new
composition oracles passed against ClickHouse 26.7.1.1315, including stock reads
and stock ATTACH/CHECK of library-written parts. Scoped ownership, aggregate
budget and lazy-frame adversary checks are ROBUST within this profile, not for
all types or current master. Exact APIs, paths, commands, measured refutations,
ownership/lifetime policy, evidence decay and the next high-level value-mapping
boundary are recorded in [the W94 seal and result](COMPOSITIONAL_TUPLE_FRONTIER.md).
No new type, metadata profile, public generic Tuple API, arbitrary-table writer
or performance claim is admitted by this extraction.

## W95 high-level Tuple consumer owners

The high-level integration adds three concrete owners, one file each:
`WideTupleRow` retains an owned columnar mark and checked row index;
private `WidePartTable::TupleColumnAdapter` owns mark charge and row conversion;
private `OfflineTable::TupleValuesMaterializer` owns row accumulation and
all-leaf cell/String accounting. The facades contain dispatch and delegate
calls, not another copy of the Tuple codec or one native union per arity.

The initial selected-schedule adapter pass was removed after its premise was
refuted: the existing typed-open owner already compares every physical
stream's complete mark-row schedule. Preserve that eager metadata boundary
and the separate lazy per-mark payload contract. This is a bounded API
expansion, not completion of the one-class-per-file architecture for the
older reader, writer, table batch or catalog definitions. Verification,
refutations, ownership limits and evidence decay are recorded in
[the W95 seal and results](COMPOSITIONAL_TUPLE_FRONTIER.md).

Observed gates: 53 focused DEBUG and RELEASE examples each, 1,196 full DEBUG
examples, both pinned Tuple oracles (including high-level scans and catalog
values for seven stock/library profiles), example no-codegen, format, shell
syntax and diff checks all passed. Full RELEASE was not run for this slice.
The scoped hostile verdict is ROBUST for the new owners and bounded consumer
contract, not for full type support, all monolith extraction or performance.

## W101 parameterized Tuple owner boundaries

The named-flat Tuple extension adds twelve concrete owners, one file each:
`FixedStringValue`, `Enum8Value`, `Enum16Value`, `Decimal32Value`,
`Decimal64Value`, `Decimal128Value`, `Decimal256TupleValue`,
`WideTupleEnumDefinition`, `WideTupleFixedStringType`, `WideTupleEnumType`,
`WideTupleDecimalType` and `WideTupleSchemaParser`. The separate
`wide_tuple_parameterized_type.cr` file contains their closed descriptor alias,
not another concrete class. Existing Tuple field, leaf, column, row and
consumer owners retain their responsibilities; exact schema identity does not
belong to the primitive numeric owner or one union per Tuple arity.

The parser owns bounded named-flat source extraction and quoted Enum syntax.
Type owners retain exact N, map or P/S metadata. Nominal structs own detached
values, and the immutable Enum definition is shared once per leaf. Reader
orchestration aggregates descriptor/slot/FixedString-payload charges before
fixed-width range validation can decompress data. The writer shares the
existing fixed-width stream framing through a typed block, not a new per-row
callback object. These are bounded new capability owners, not a wholesale
behavior-neutral facade extraction or a memory/performance claim.

The reader remains 15,385 lines, writer 25,516, table 6,638 and catalog 5,309.
The old facade decomposition, recursive/nullable composition and broader
physical profiles remain open. Exact tests, source/binary lineage, hostile
review scope and evidence decay are recorded in
[the W101 frontier and result](PARAMETERIZED_TUPLE_FRONTIER.md).

Observed W101 gates: 222 focused DEBUG and RELEASE examples each, 1,384 full
DEBUG examples and fourteen pinned oracle launchers passed, with final
format/syntax/diff checks. Scoped hostile review is ROBUST for the new owners
and admitted profile. Full RELEASE, current-master runtime and the larger
facade architecture are not established by these results.

## W102 shared Decimal descriptor owners

The standalone Decimal precision extension adds two concrete struct owners,
one file each: `DecimalType` owns exact P/S identity, bounded canonical leaf
parsing and the four physical-width bands; `DecimalColumnType` owns only the
six admitted column shapes and catalog-only DDL normalization. The existing
`WideTupleDecimalType` embeds the same immutable leaf descriptor and retains
its public nominal-value, buffer and cached-name contract. This removes a
duplicate precision/width law without forcing Tuple wrappers into raw scalar
or Array APIs.

Reader, writer, typed-table and offline-catalog facades delegate schema
identity to these owners. Physical codecs, stream lifetime, selected-mark
policy, budgets and staging remain under their existing owners. The new
descriptor stores P/S only and derives width/name; this does not establish
allocation, RSS or throughput improvement. Full facade decomposition and
arbitrary recursive type composition remain open.

Root executed 144 focused DEBUG and RELEASE examples each, 1,404 full DEBUG
examples, the 72-core-profile bidirectional Decimal oracle with separate raw,
statistics and empty/null controls, and ten unchanged regression oracles.
All passed within the pinned physical profile; scoped hostile review is
ROBUST. Full RELEASE and current-master executable parity remain unqualified.
Exact source/runtime lineage, RED evidence, commands and residual boundaries
are tracked in [the Decimal precision frontier](DECIMAL_PRECISION_FRONTIER.md).

The reader is still 15,206 lines, writer 25,582, table 6,616 and catalog 5,315.
Those are navigation counts, not coupling or performance measurements. The
next cohesive extraction boundaries remain physical-stream lifetime/validation,
leaf codecs, staging/read-write orchestration and table/catalog adapters, one
concrete owner per file with behavior-preserving gates. This bounded W102
change does not complete that larger architectural work.
