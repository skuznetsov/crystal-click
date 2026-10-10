# Schema-aware Wide part writer frontier

Document status: W246 VERIFIED / root adversary ROBUST within its finite
target (2026-10-10); W245 remains historically qualified within its own scope.
This is not all-type/layout or whole-goal closure.
W245 baseline: `dcb445d6864298e64be22e0dc71b3c5b240e8a65`.
Bounded context: synchronous creation of one new quiescent local Wide part.

## Qualified transition: W246 recursive Tuple Dynamic publication

Baseline: `6bcf7e0be1324a7bd385cd421e7fa22731620458`, initially clean.
The preceding source probe is progress: it refutes the proposed need to invent
a new child serializer or mandatory Tuple statistics entry before admitting
the existing JSON-free Dynamic-bearing root Tuple codec in the N-column writer.

The W245 adapter rejected root Tuple before building its existing Dynamic plan.
Its stated metadata rationale is too strong. In pinned ClickHouse
`f25eb93a0b890a3b87df05eb34e2af1f933b4089`,
`SerializationInfo.cpp:432-443` permits an empty always-Default info map;
`Block.cpp:1132-1144` falls back to the declared type's serializer;
`DataTypeTuple.cpp:334-345` builds child serializers recursively. Our
`ObjectColumnPartMetadata` likewise requires `subcolumns` only on a present
selected Tuple entry, not on an omitted entry. A present incomplete entry must
continue to reject. Source inspection is not new stock ATTACH qualification.

W246 removes only that root-Tuple guard. Current additional admission:
the existing JSON-free Dynamic-bearing root Tuple descriptor grammar through
`WidePartColumn.dynamic_bulk`, using the same recursive codecs, physical plan,
shared operation budgets, always-Default metadata and exclusive publisher.
Finite qualification includes named and unnamed root Tuples together,
independent Dynamic sites, an Array child with empty parent marks and later
populated occurrences, NULL and overflow/shared values and both ordinary String
profiles. DynamicBulkColumnWriter uses the existing BASIC physical discriminator
prefix; the operation's Object/JSON mode option does not select a COMPACT bulk
Dynamic layout. Qualification inspects the actual prefix and does not infer a
layout from that option. No serializer per product.

Preserved refusals: JSON in this Dynamic adapter; unsupported nominal children,
layout/profile combinations, incomplete explicit Tuple metadata, collisions,
mismatched grids, incompatible or exhausted budgets and target overwrite.
No broader JSON grammar, Compact parts, arbitrary keys/partitions, MV/projection
writes, memory/performance or crash-durability claim is introduced.

Risk: CAUTION (persistent-format admission). Rollback: one scoped local commit;
no push or history rewrite. Strongest failure: child registries or occurrence
coordinates are exchanged while scalar JSON still looks correct. Guard check:
compare exact Dynamic actual types, tuple field order, Array child counts and
selected late granules, not just JSON values or self-roundtrip success.

Executed plan and DoD:

1. Add `spec/multi_column_tuple_dynamic_w246_spec.cr` plus a small shared fixture
   and `scripts/check_multi_column_tuple_dynamic_w246.cr`. Root runs the focused
   spec against the baseline and records the exact W245 refusal (RED).
2. A bounded `scripts/probe_multi_column_tuple_dynamic_w246.rb` uses the existing
   guarded raw-process capture owner. First exercise the legacy pair publisher
   with omitted Tuple metadata and stock ATTACH/CHECK/exact types. This is a
   format falsifier, not N-column admission evidence.
3. Remove only the refuted root-Tuple guard; reuse existing owners. Replace the
   old W245 Tuple expected-refusal assertion with admitted readback while
   retaining its Nested nominal refusal. No new explicit metadata tree is
   warranted unless the stock probe disproves default reconstruction.
4. Root runs focused and affected Dynamic/publication regressions in DEBUG and
   RELEASE under run_safe (50% free-memory gate, one worker, isolated cache).
   Expected: zero failures/errors/pending. Build both helpers and execute the
   native String0/String1 BASIC-bulk matrix in both build modes. Expected:
   ATTACH, CHECK=1, exact schema/values/actual types and complete-part inventories.
5. A separately run read-only audit and hostile output/type/metadata controls
   must reject wrong-type/same-value, missing/swapped children, CHECK0 and
   incomplete provenance. Record source/helper/runtime pins and exact commands;
   synchronize this frontier, project status and landmarks before one atomic
   local commit. Whole-goal completion remains unproven and ACTIVE.

Observed seal: RED rejects at the original W245 root-Tuple guard. With that
guard intact, the legacy pair publisher passes stock ATTACH/CHECK=1 in both
String profiles while omitting the selected Tuple entry. These are historical
pre-change falsifiers, not live-source N-column qualification.

After removal, the same 33 affected spec files pass 215 examples per mode,
zero failures/errors/pending; both helper builds, five-file formatting and
Ruby syntax pass. Four final N-column cells (DEBUG/RELEASE x ordinary String0/1,
actual BASIC bulk Dynamic, frame32) and their independently executed raw audits
pass. Sixteen stock calls establish CHECK=1, exact schema, Dynamic actual types,
five parent rows, six ordered Array children and one active four-mark Wide part.
All 98 generated files / 14,083 bytes per mode agree by actual bytes. Seven
root in-memory authenticated-raw replay mutations reject through real guards
with restored acceptance and a fresh final audit. They are not immutable
execution provenance or a complete forged-capture cryptographic audit.
See the [W246 evidence index](../.landmark/evidence/multi-column-tuple-dynamic-w246.json).

Stop rules: preserve the refusal if stock behavior disproves the omitted-entry
path; do not weaken metadata, nominal-type, budget or publication guards to get
green. Requalify after relevant source, compiler, profile, fixture/helper,
runtime or capture changes.

## Problem and boundary

Column codecs already compose admitted recursive types. The baseline complete
part envelope was largely a UInt64 key plus one value column, so adding another
container-specific writer does not remove the architectural limitation.
W245 generalizes publication, not the type grammar or execution engine.

The public target is `WidePartWriter.write_uint64_columns(destination, key_name,
keys, columns, ...)`, where `columns` is `Array(WidePartColumn)`. Typed factories
on `WidePartColumn` select the existing owners:

- `binary_bulk(name, type, granules)` for admitted static BinaryBulk trees;
- `dynamic_bulk(name, type, structures, granules, ...)` for prepared Dynamic;
- `object(name, schema, plan, granules, ...)` for root JSON/Object documents;
- `recursive(name, schema, object_plans, granules, ...)` for the existing
  JSON-bearing Tuple/Array schema and optional occurrence-specific Dynamic plans.

One global `profile`, shared-Object profile, Object/JSON discriminator mode,
frame bound and operation limit set belong to the writer call. Dynamic bulk
retains its existing BASIC discriminator layout independently of the Object
mode option; passing COMPACT is not evidence of a COMPACT bulk output. LZ4 is fixed. Factories
do not admit arbitrary
raw files, opaque unknown aggregate states, or an unvalidated nominal type.
Root Object inputs may override the advanced shared-JSON policy and target
chunk size explicitly; an omitted override inherits the operation option.
Recursive inputs require the existing single-stream shared-MAP profile;
the global ordinary String profile still permits versions 0 and 1. Metadata
records that ordinary version, not an independently sized shared-MAP profile.
Recursive inputs also reject a non-default shared-JSON policy or target chunk
size until the existing root/child physical-site owners have a qualified
complete handoff. An accepted option must never be silently ignored.
Implementation owners must remain small classes in separate files. Existing
pair APIs remain source compatible; shared publication machinery must not be
duplicated per type or per container product.

Root Object input keeps its explicit `ObjectDocumentSchema`: a physical plan's
prepared runtime paths cannot determine the nominal JSON caps. The writer must
validate the schema/plan association rather than infer a declaration from rows.
Static physical representability is not sufficient nominal admission. Existing
SAF, aggregate-state, QBit, Nested and Geo declaration owners remain authoritative;
an unsupported adapter must refuse rather than silently widen their grammar.

## Admitted surface and finite qualification

The implemented envelope accepts typed inputs through the four factories
above, subject to each existing owner's exact admission. Native qualification
is narrower: four value columns, with all four existing column owners
exercised in one native-readable part; a sorted nonempty UInt64 key; common
parent mark rows `[2, 2, 1]` and an EOF record with zero rows; Wide/LZ4/plain
`.mrk2`; exclusive new-directory publication on macOS. Static aggregate states
remain exactly those already admitted by their state-layout owners.

Rejected: duplicate key/value names, cross-column logical or physical stream
collisions (including hashed filenames), mismatched parent grids, unsorted or
empty keys, unsupported descriptors/layouts, mixed global String versions,
out-of-budget operations, existing destinations and symlinks.
Root Tuple Dynamic inputs now reuse the existing Dynamic plan through the
W246 adapter with always-Default `columns: []`. The earlier explanation that
the reader requires an explicit selected-subcolumn entry was refuted: only a
present selected Tuple entry requires child metadata. The named/unnamed finite
qualification above removes that conservative guard, not a missing serializer.
Recursive BinaryBulk leaves containing Nested must also pass the existing
WideNestedTypePlan nominal owner. A JSON-bearing parent does not admit an
otherwise unqualified Nested child layout.

Guard-only future: semantic sharing of flattened Nested offset lanes. Identical
names cannot be independently encoded and silently deduplicated. The initial
surface retains bounded ASCII column identifiers and rejects collisions.

Non-goals: arbitrary PK/partition metadata, Compact publication, Sparse or
custom codecs, INSERT-triggered MV execution, projection writing, SQL functions,
live-server mutation, durability/fsync guarantees, performance or RSS promises,
and widening all old table/TUI/borrowed-reader admission gates.
Cleanup is synchronous exception cleanup, not crash recovery: a killed process
may leave its stage for later inspection/removal.

## Design laws and execution order

1. Validate destination, all column names, descriptors, parent grids, global
   profiles and operation bounds. Prepare every column's canonical declaration
   and complete physical stream/file roster before encoding or creating a stage.
2. Reject cross-column collisions, roster/count overflow and metadata limits.
   Distinguish outer parent rows P from flattened child occurrences Q.
3. Reuse each column owner's recursive serializer. Share one writing codec
   budget and one transport budget across all value columns, including any
   Dynamic preparation charged inside the operation. Do not reset a full
   operation allowance for each column. Validation is a separate bounded phase;
   its shared read-direction counters cover compressed value-lane inspection,
   checksum decoded-byte passes and typed value decoding, not only an
   after-the-fact byte sum or a fresh allowance for every value column.
   The key stream, primary index, common checksums metadata and columns/
   serialization metadata parsing retain their existing fixed per-file limits
   outside these aggregate read counters. Typed readers may reparse that
   common envelope. This slice does not claim aggregate accounting for all
   part-validation work; the broader claim was refuted by source review.
   Recursive reader descriptor reparsing and its physical name contexts retain
   their existing per-plan bounds; this slice does not claim one aggregate
   read-side name-planning allowance or a process/RSS bound.
   Static nominal-admission constructors retain their existing bounded
   auxiliary descriptor traversals. The new operation charges its canonical
   descriptor, retained metadata and value encoding, but does not claim one
   aggregate allowance for every redundant legacy admission/planning walk.
4. Collect detached encoded pairs and check every planned roster and P-grid.
   Emit one `columns.txt`, `columns_substreams.txt`, `serialization.json`, key
   stream, primary index and checksums envelope. No fabricated key-only sparse
   statistics: always-Default metadata may use `columns: []` with one global
   String version and propagation to nested types.
5. Stage once under the destination parent. Validate the exact file/checksum
   roster, metadata, key/index/grid and all value columns through their existing
   typed readers, including every granule and exact nominal declarations.
6. Publish once through the existing exclusive rename owner. On a catchable
   exception after stage ownership transfers, clean up only that stage; never
   replace a target. Process termination is not an exception-cleanup guarantee.

Source comparison: shallow ClickHouse `f25eb93a0b890a3b87df05eb34e2af1f933b4089`
at `/private/tmp/crystal-click-w238.4nQqSo/clickhouse`. Exact source anchors are
`SerializationInfo.cpp` (`SerializationInfoByName` constructor/writeJSON),
`SerializationInfoSettings.h` (`isAlwaysDefault`), `ISerialization.cpp`
(`getFileNameForStream` and shared Nested offsets), `SerializationArray.cpp`
(`enumerateStreams`) and `MergeTreeDataPartWriterWide.cpp` (per-column stream
registration and common granularity). This source is not the runtime build.

Native oracle: `26.10.1.1201`, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, executable SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.

## Falsifiers and verification

- Interface RED before production changes: compile/execute the new focused
  spec against the baseline; distinguish a missing API from a format failure.
- `spec/multi_column_part_writer_w245_spec.cr`: exact union roster, ordered
  declarations, shared outer grid and EOF, typed full/granule readback, String
  profiles, nominal admission, aggregate logical/transport bounds, mismatched
  grids, duplicate names, and exclusive-target/stage-cleanup refusals.
- Native helper/probe: one part containing static, Dynamic, root Object and
  recursive JSON columns; ATTACH to a matching MergeTree, exact schema and
  ordered typed values/aggregate result, one active part and `CHECK TABLE = 1`.
  Preserve raw process argv/stdin/stdout/stderr/exits and actual generated and
  attached file inventories. A roundtrip through our reader is not this oracle.
- Root adversary: wrong-type/same-value, incomplete or exchanged column roster,
  successful-exit CHECK-zero, aggregate-budget bypass and overwrite controls.
- Run the focused specs and affected existing writer/recursive/Dynamic/static
  regressions in DEBUG and RELEASE, serially with run_safe, 50% minimum free
  memory, one compiler worker and isolated caches. Build/run both native helpers.
  Record exact commands, source state and observed counts in the evidence index;
  no whole-suite claim without execution.

Stop rules: preserve refusal if a nominal owner or native oracle disagrees;
do not weaken collision, profile, budget or publication guards to get green.
Rollback: uncommitted scoped edits or one local atomic commit; no remote push.

## Small implementation plan

1. Add the focused interface/behavior spec and fixture helper; root records RED.
2. Introduce typed column inputs/prepared artifacts and N-column metadata;
   generalize one shared publication owner and preserve existing pair adapters.
3. Thread optional shared budgets through reusable column encoders without
   changing existing defaults. Add aggregate-operation and negative guards.
4. Root executes gates, stock-reader oracle and hostile controls. Update this
   frontier, project status and evidence index; commit exact relevant paths.

## Observed implementation seals

The common operation, typed inputs, metadata, lane bindings, exact value
comparison and staged publisher have cohesive own-file owners. The old
two-column bulk publisher delegates to the common publisher; public pair
entry points remain. Existing recursive codecs are reused, not duplicated
for every wrapper product. This is not completion of broad facade decomposition.

Root executed the same 69 selected spec files in both DEBUG and RELEASE:
414 examples per mode (141 legacy, 204 static/state owners, 62 JSON controls,
seven focused), zero failures/errors/pending. Final formatting covers all 32
changed Crystal files. Both final helper builds and both Ruby syntax checks
pass. This is an affected-surface gate, not execution of the entire suite.

All eight final-source DEBUG/RELEASE x String0/String1 x Object/JSON mode
BASIC/COMPACT captures and their separately executed raw audits pass. W246
source inspection corrects the earlier description of this matrix: the mode
option reaches the Object/JSON owner, but the bulk Dynamic owner emits BASIC
independently. These cells do not qualify COMPACT bulk Dynamic or Compact part
publication. Each capture has one
five-row library-written Wide part with UInt64 key plus:

- static `Tuple(label LowCardinality(String), total AggregateFunction(sum, UInt8))`;
- root `Dynamic(max_types=1)`;
- root JSON with a declared String field and inferred Dynamic path;
- `Array(Tuple(JSON(..., t UInt8), Dynamic(max_types=1)))`.

Stock ATTACH/CHECK=1, exact schema, ordered values and recursive actual/leaf
types, aggregate finalization=1497 and one active five-row/four-mark Wide part
are observed across 40 stock calls. Parent rows are `[2,2,1]` plus EOF0;
recursive child occurrences are `[0,2,3]`. The String profiles have 27/31
physical mark files respectively. The generated inventories match by actual
bytes across modes in every profile: 264 files / 38,584 bytes per mode.
This is library-write -> stock-read, not reciprocal stock-write qualification.

All 28 auditor controls pass in each final capture. Root separately executes
ten semantic refusals plus genuine/restored acceptance against a fresh capture:
same-value wrong types, wrong child occurrence, omitted/extra output, CHECK0
with successful exit, swapped active path and incomplete owner roster reject.
The shared decoded-byte refusal is exercised before publication and removes
the owned stage. These are scoped checker/guard controls, not immutable
cryptographic execution provenance or crash-recovery evidence.

Refutations and corrections retained:

- W246 source inspection refutes the mandatory root-Tuple metadata rationale:
  omitted statistics use recursively declared serializers; only a present Tuple
  entry requires child metadata. The W245 refusal was conservative admission,
  not a missing recursive codec. The W246 transition above qualifies its removal.
- The W245 mode labels describe the operation's Object/JSON option. Its root
  bulk Dynamic stream remains BASIC, so the historical matrix is not evidence
  for a COMPACT bulk Dynamic implementation.
- A W230 expected-refusal test already fails on the unchanged baseline because
  W233 admits that Dynamic actual. Its exact-child positive assertion is
  updated; the invalid Nullable(Array) negative control remains.
- A first Nested guard fixture failed in parsing a reserved unquoted field
  name, not in nominal admission. The renamed fixture now reaches the exact
  Nested-owner refusal; the parser failure is not counted as a guard pass.
- Recursive shared-MAP String1 is not admitted by the existing owner. W245
  refuses it before staging; global ordinary String1 remains independent.
- Aggregate read accounting for all part-validation work was refuted. Law3
  names the value-lane counters and the fixed/per-plan work outside them.
- ATTACH moves the detached source. Its recorded snapshot is historical;
  current generated/pre-attach/active bytes and exact detached-source absence
  are independently checked. A residual directory or symlink rejects.
- The first formatted-source native attempt stopped before any stock call
  because the harness required exact whitespace in `FRAME_BYTES = 32`.
  Both source-pin guards now admit formatter spacing but reject wrong values,
  expressions, prefixes, commented-only and duplicate assignments. That
  capture is inconclusive; all eight final captures use the corrected guards.
- A killed process can leave its stage. Only synchronous catchable-exception
  cleanup is qualified; no SIGKILL cleanup, fsync or crash recovery is claimed.

The [W245 evidence index](../.landmark/evidence/schema-wide-part-w245.json)
records final source/helper/runtime pins, exact commands and capture paths.
Requalify after source, compiler, codec/consumer, fixture/helper, runtime or
oracle changes, or capture loss. Infrastructure failure is inconclusive.
The overall type/MV/projection objective stays ACTIVE. Arbitrary keys/partitions,
unqualified type layouts/state families/owner handoffs and MV/projection writes
remain subsequent frontiers; memory/performance remains deferred. No push.

Interface RED observed on the baseline: the root-run guarded focused spec exits
1 with `undefined constant CrystalClick::WidePartColumn`. This is missing-API
evidence, not native format rejection. The default sandbox run could not isolate
its process group (exit 75); the approved rerun kept run_safe, the 50% free-memory
guard and all workload limits enabled.
