# Recursive QBit storage frontier

## Static Variant composition — W232

Document status: VERIFIED within the finite W232 scope (2026-10-08).
Scoped adversary verdict: ROBUST; not an all-product/layout qualification.
Production baseline is the clean W231 commit
`c39fe85527e01217df15924510a7aac1efebeb89`. The active compatibility objective
is unchanged. Memory/performance work remains deferred.

Problem at baseline: leaf serde is already reusable, but the complete-part QBit
schedule expressed only root and Array/Map occurrence axes. A Variant arm has
one physical child occurrence per selecting discriminator, not per parent row.
Removing the constructor guard alone would let plane shape checks use the
wrong row domain. This is a missing composition boundary, not a missing QBit
codec or a requirement to implement every type product separately.

### Implemented admission and invariants

- Admit source-valid static Variant alternatives containing the existing QBit
  static grammar, including ordinary Array/Tuple/BASIC Map/Nested and eligible
  Nullable(Tuple) composition. Preserve canonical arm ordering and NULL's
  `0xff` discriminator. Direct Nullable, Variant and Dynamic alternatives keep
  their existing ClickHouse constructor restrictions.
- Reuse the existing normalized Variant roster, descriptor/scalar/RowBinary
  visitors, physical binder, bulk encoder/decoder, staged writer and typed
  consumers. Extend only the static leaf-site roster and one complete-part
  occurrence scheduler; do not introduce a codec for each product.
- A Variant adds a discriminator-derived sparse axis. Tuple and Nullable
  preserve the incoming axis; Array and BASIC Map derive a child axis from
  sizes. Empty selected containers are not NULL. All-null and unused-arm marks
  still require complete grids and zero child payload.
- Validate every relevant discriminator byte across the complete part before
  reader publication, then validate all QBit plane, size and nullable grids
  against their actual axes. A late unselected shape defect must reject early
  and EOF selections before callbacks. Shape checks do not authenticate all
  unselected value payloads.
- Preflight the retained per-mark axis/count workspace before allocating it.
  Read each relevant discriminator or shared size lane once in parent-first
  order, consuming the existing shared inspection/shape transport budget.
  Existing LC replay is a separate operation-scoped phase; this slice does not
  claim a unified LC/QBit census or an RSS/throughput guarantee.
- Preserve narrower Dynamic actual-product, JSON/Object, LowCardinality(QBit),
  aggregate-argument, Compact/sparse/custom and unqualified-version guards.
  Neutral descriptor acceptance does not grant those consumers admission.

### Definition of Done and execution plan

Risk: CAUTION (serialization and complete recursive physical schedules).
Rollback: exact owned local diff from the clean baseline; one atomic local
commit only after the relevant checks pass, with no remote push.
Source and runtime remain independently pinned as recorded by W231.

1. Execute a bounded stock-only persistence probe for root Variant(QBit),
   Array(Variant(QBit)) and Variant alternatives with Array/Tuple/Map QBit.
   Require Wide/BASIC persistence, exact CHECK success and independently
   authored literal RowBinary. Source constructor acceptance alone is not DoD.
2. Before production changes, root executes new
   `spec/variant_qbit_recursive_composition_spec.cr`,
   `spec/recursive_qbit_variant_parts_w232_spec.cr` and
   `spec/recursive_qbit_variant_transport_w232_spec.cr` against the baseline.
   Expected RED is missing-capability assertion failures, not build errors.
3. Luna owns disjoint kernel/admission, physical-schedule/part tests and native
   helper/harness surfaces. Root owns all serial guarded jobs and independent
   review. Widen shared normal/wire admission and sites, then add the sparse
   Variant axis to the existing complete scheduler. Touch other consumers only
   if an executed RED exposes a concrete missing route.
4. Run the new and affected recursive/QBit/Variant/owner-guard specs in DEBUG
   and RELEASE. Expected GREEN: nonzero examples, zero failures/errors/pending.
   Retain nominal identity, limits, LC/Dynamic/JSON/Object and projection controls.
5. Execute paired stock-authored and library-written native profiles in both
   modes. Require exact declarations, full/middle/zero/EOF typed reads, native
   ATTACH/CHECK and independent literal RowBinary, followed by a separate raw
   audit. Attack unselected late discriminators, sparse plane and size deltas,
   shared-lane replay, workspace bounds and CHECK-record acceptance.
6. Inspect final hashes/diff and evidence scope, reconcile current status and
   frontier, then commit only exact relevant paths. The overall goal stays open.

The strongest failure mode is a plane schedule using root rows for a sparse
Variant arm. The cheapest discriminators are an unused arm in a late mark and
an independently malformed late shape lane, while the first selected window
remains intact. Stop and narrow the proposal if stock persistence contradicts
the source contract; do not relabel metadata or relax guards to force a pass.

### Observed anchors before production changes

The fresh stock-only probe persists all three proposed profiles with six rows
each, three logical two-row marks and four physical marks including the
terminal mark. They have 11, 12 and 30 plain-mrk2 physical lanes respectively.
Exact CHECK output and independently authored full/per-mark RowBinary agree.
Root separately inspected all 29 raw process-success statuses. An earlier
capture stopped at a harness-only inaccessible-method error and is retained
as inconclusive; it is not edited into passing qualification.

The kernel-only unchanged-production RED executes three examples with three
missing-admission assertion failures and zero errors/pending. Its initial
test-helper overload compile error was corrected before this behavioral RED.
The part/transport RED executes seven examples with seven missing-admission
assertion failures and zero errors/pending after repairing the fixture's
constructor-initialization boundary. Production changes begin only after both
behavioral RED signals. This does not yet qualify the library's new storage path.

### Executed results and qualification boundary

The same 66 affected spec files pass 470 examples in each of DEBUG and RELEASE,
partitioned into six serial cohorts per mode. The three new specs pass a
16-example focused DEBUG gate and are included in both final cohort rosters.
The final 15 owned Crystal paths pass formatting; both native scripts pass
host Ruby 2.6 syntax checks. This is an affected roster, not the whole suite.

Fresh native captures and separate raw audits pass three fixed profiles in
each mode: `Variant(QBit(Int8, 9), UInt64)`, its Array wrapper, and
`Variant(Array(QBit(Int8, 9)), Map(String, QBit(Int8, 9)),
Tuple(q QBit(Int8, 9), n UInt8))`. Each mode has 26 stock and 28 helper/native
raw process records. Stock parts are read through public typed full, middle,
zero-selected-mark and EOF APIs; library parts are written through the existing
staged publisher, read back, and directly attached to fresh native tables.
Exact nominal declarations, independent literal RowBinary, complete grids and
exact successful CHECK output agree. All 130 generated files match by actual
bytes, names, size and SHA-256 across modes (17,808 bytes per mode).

The four late-corruption controls cover an invalid unselected discriminator,
wrong sparse plane cardinality, and Array/Map-arm size deltas. Omitting the
complete schedule produces four assertion failures, not build errors; exact
reader restoration passes the same four controls. Counting-source and workspace
controls require unique shape lanes to consume the shared transport budget
once and reject the extra per-arm count workspace before shape reads.
Each final raw audit rejects six coherent stock/native CHECK-zero,
CHECK-with-message and status-label forgeries despite green top-level metadata;
exact raw-file restoration recovers PASS after every attack.

Neutral static descriptor/scalar acceptance is not runtime or physical
admission. The pinned Variant constructor permits source-valid QBit and JSON
siblings, but mixed runtime-owned sibling persistence is not qualified here.
Existing Dynamic actual-product, Object typed/shared, borrowed-envelope,
LowCardinality(QBit), aggregate-argument and unsupported physical-layout guards
remain separate. Count/QBit sibling alternatives reuse their existing owners;
QBit as a Count argument remains rejected. Basic child codecs are reused;
wrapper state, discriminator mode and versioned physical paths still need
their own qualification. Shape checks do not authenticate unselected payloads,
and logical workspace caps are not an RSS/performance result.

Inconclusive attempts remain separate: a zero-row test used an invalid
`max_rows: 0` API before switching to zero selected marks; an old admission
assertion retained the superseded Array/Variant guard; the native helper had
an iterator-to-JSON compile error, basename/root-prefix mismatch and bare Map
key fixture mismatch. The first complete native invocation set then stopped
at finalization because recorder collections hold status-only records, not
the returned invocation path. These isolated test/capture defects were fixed
without widening production guards, and final captures used fresh roots.
Earlier failures were not relabelled as passing compatibility evidence.

The evidence index retains exact guarded commands, both helper hashes, 88
selected input hashes, independently pinned source/runtime identities and
regenerable temporary raw roots:
[W232 evidence packet](../.landmark/evidence/recursive-qbit-variant-w232.json).
These are selected owner/spec/helper/harness inputs, not every transitive
compiler input. Refresh after owner/consumer, fixture/auditor, source/runtime or
profile changes. The packet is an index to executed evidence, not proof by
JSON structure. General MV/projection execution/writing, broad facade
decomposition and the overall compatibility objective remain open.

## Static product composition — W231

Document status: VERIFIED within the finite W231 scope (2026-10-08).
Scoped adversary verdict: ROBUST; not an all-product/layout qualification.
Baseline: `79fa1b806056fd26c45bc7e1ff2eb028c799ad34`.
Current frontier: multiple static QBit leaf sites inside recursively composed
Array, Tuple, Map keys/values, nominal Nested and eligible Nullable(Tuple) owners.
This is one shared leaf-codec integration, not a serializer per type product.
Bounded context: quiescent Wide/LZ4/Default/plain-mrk2 parts, BASIC Map and
Nullable serialization, exact nominal declarations and staged publication.
Memory/performance and the overall compatibility objective remain open.

The current pinned stock runtime accepted all four wrapper families in a
fresh Memory-table constructor probe. That establishes constructor acceptance,
not persisted MergeTree support. The source pin remains
`0ca8150d9b1d0886edb2e3b4ab65eebb768d0357`; source and runtime builds differ.
An additional stock INSERT SELECT probe persisted
`Map(QBit(Int8, 3), UInt64)` with one nonempty and one empty row and exact
`CHECK TABLE` success. The initial Values-expression parse failure was
inconclusive; only the valid INSERT SELECT probe supports this anchor.

### Admission and design laws

- Preserve the existing dedicated root/direct-Nullable owners and W230 Array
  behavior. Admit additional static products only after paired storage tests.
- A static QBit site is identified by its exact structural path and nominal
  carrier/dimension/stride, not by the physical plane width alone.
- Tuple preserves its incoming occurrence axis. Array and BASIC Map add a
  sizes-derived child axis; nominal Nested shares its Array-of-Tuple axis.
  Nullable does not filter hidden physical defaults out of child counts.
- Enumerate every leaf site and account for the cumulative roster/scratch
  before allocation. Reuse the existing QBit bit-plane codec; do not duplicate
  transposition, default generation or scalar RowBinary logic.
- Validate the complete shape of every site before reader publication and
  callbacks, including first-window and EOF scans. Shared ancestor size lanes
  must not replay their complete index/payload independently for each leaf.
  Inspection and shape reads consume one open-time transport budget.
- Keep Variant, runtime Dynamic/JSON/Object, LC(QBit), QBit aggregate arguments,
  Nullable(Array/Map/Nested), Compact/sparse/custom serializers
  and alternate unqualified physical versions guarded. Source-valid rejected
  products are library guards, not claims of ClickHouse invalidity.

### Executed Definition of Done

Risk: CAUTION (serialization, recursive admission and complete part schedules).
Rollback: exact local diff from the clean baseline, followed by one atomic
local commit after verification; no push. Root owns all serial guarded jobs
and hostile review. Luna owns disjoint implementation/test/harness surfaces.

1. Add `spec/recursive_qbit_static_products_w231_spec.cr` and
   `spec/recursive_qbit_static_parts_w231_spec.cr` against unchanged production.
   Run the root-owned guarded DEBUG commands and require actual missing-
   admission assertion failures, not compilation or infrastructure errors.
2. Widen the shared static admission/site owner, descriptor and bulk visitors;
   integrate a complete path-keyed occurrence schedule and exact declaration
   routing into staged publication, typed full/windows and owned values.
3. Run both new specs and the enumerated affected QBit/recursive/consumer
   roster in DEBUG and RELEASE. Expected signal: nonzero example counts with
   zero failures/errors/pending and retained runtime/aggregate guards.
4. Build helpers and execute paired stock-authored/library-written native
   profiles for independent siblings, a no-Array leaf, shared Nested/Array
   ancestors, Map keys/values and nullable hidden defaults. Require exact nominal
   declarations and literal full/window/empty RowBinary, ATTACH/CHECK success,
   separate raw audit, and an executed hostile CHECK/shape defect control.
5. Inspect the final source state and evidence scope, update this frontier and
   current status, then commit exact relevant paths only after the signals pass.

The main falsifier is a second sibling with an independent late-mark size
corruption that leaves the first site's early window intact: opening and EOF
scanning must reject before callbacks. Other controls cover unequal sibling
counts, shared size-lane read counts, null hidden defaults, role/name/scratch
limits, physically equal but nominally different leaves and retained guards.
Stop rather than relaxing a guard if stock persistence contradicts the
source-derived contract. Performance, general MV/projection execution/writing
and full all-layout compatibility remain open, not redefined as this slice.

### Observed qualification

- Unchanged-production admission RED: 13 examples, 12 assertion failures,
  zero errors. A separate mixed-value identity RED has two failures in two
  examples. These distinguish missing admission/identity from a build failure.
- The final focused DEBUG roster passes 58 examples. The same 62 affected files,
  partitioned into six serial cohorts, pass 448 examples in each of DEBUG and
  RELEASE with zero failures/errors/pending. This is not a whole-suite run.
- Both fresh paired native captures and separate read-only raw audits qualify
  eight profiles and 139 raw process records per mode (66 stock, 73 evidence).
  Independent unequal/empty sibling Arrays, direct and nullable QBit siblings,
  Array-of-Tuple, nominal Nested, Map keys, Map values and Nullable(Tuple) hidden
  defaults preserve their exact declarations. No metadata is relabelled to
  bypass a nominal guard. Stock reads, typed full/middle/zero/EOF windows,
  library publication, native ATTACH/CHECK and literal native full/middle/zero
  RowBinary agree. All 572 generated files match across modes by actual bytes,
  relative names, size and SHA-256 (75,570 bytes per mode).
- Omitting the complete static schedule causes both new checksummed late-size
  controls to fail: second sibling and Nullable(Tuple) ancestor. Restoring the
  exact reader bytes makes both pass. Shape preflight precedes callbacks even
  for an early or EOF selection. Shared size lanes are inspected/read once;
  inspection and shape reads consume the same open-time transport budget.
- An initial raw audit failed closed because its schema omitted the recorder's
  `label`. The auditor now requires that field and its exact expected value.
  Fresh captures bind the corrected auditor; old captures are not edited into
  passing evidence. Each final audit rejects six coherent stock/native CHECK
  zero/message and status-label attacks, then passes after exact restoration.
- Recursive QBit-bearing value identity covers the whole mixed subtree,
  retaining raw-bit and nominal metadata, including NaNs and nested JSON,
  Variant and Nullable values. Ordinary non-QBit roots keep existing identity.
- The wider descriptor graph exposed missing inferred exception edges at
  Count argument-guard rescue sites under Crystal 1.21.0. Typed and untyped
  lexical probes and LLVM `call`/`invoke` inspection discriminate the symptom;
  an explicit `@[Raises]` on the existing policy restores both catches without
  widening Count admission. Fresh-cache and multi-module probes refuted those
  explanations. The exact compiler-internal cause is not established.
- Final formatting passes for all 24 changed Crystal files. All 80 frozen
  source/spec/helper/harness inputs and both helper binaries retain their
  qualified hashes. Only the auditor Ruby file changed after helper builds;
  the final native captures were regenerated after that correction.

Known logical workspace is preflighted as `(unique_sizes + 2) * marks * 8`
bytes before the per-mark UInt64 vectors are allocated. This does not include
all allocator overhead and is not an RSS guarantee. Complete size/plane shape
checks do not authenticate unselected QBit or NULL payloads.

Evidence and exact commands: [W231 packet](../.landmark/evidence/recursive-qbit-static-w231.json).
The pinned source has 18 relevant file hashes; the stock runtime is separately
pinned at 26.10.1.1201, build `d9bcb5ab007f0f6299f7f973f2642245bab3d028`.
No latest-master/runtime correlation or all-version claim follows.

Continuation: retain static composition and inspect one concrete remaining
runtime Dynamic/Variant/JSON, dictionary or physical-version boundary before
widening it. An unqualified type product is not necessarily missing leaf serde.
General MV/projection execution/writing, other AggregateFunction state leaves
and broad facade decomposition remain open. Refresh qualification after owner,
consumer, helper, harness, source, runtime or profile changes; absent temporary
raw roots require regeneration, not trust in the evidence index alone.

## Previous Array-chain qualification — W230

Document status: VERIFIED within the finite W230 scope (2026-10-08).
Scoped adversary verdict: ROBUST; not an all-product qualification.
Baseline: `ac628f8a90c5c50e6ca9bfb204e64f65e9220b8a`.
Current frontier: static Array chains over existing QBit leaf codecs.
Bounded context: quiescent Wide/LZ4/Default/plain-mrk2 parts, exact nominal
type declarations, complete reader/writer and typed consumer integration.
Memory/performance work remains deferred.

## Anchor and admission

The pinned stock executable (26.10.1.1201, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`)
created and checked one six-row `Array(QBit(BFloat16, 16))` Wide part.
Three two-row marks contain 2, 0 and 3 flattened QBit occurrences. Stock
`CHECK TABLE` returned `all_1_1_0\t1\t\n`. Its 18 data/mark pairs have hashed
filenames: the key, Array sizes and sixteen QBit planes. Serialization metadata
is version 1, propagates nested versions, uses String version 1 and has no
custom column serializers.

The source snapshot is independently pinned at
`0ca8150d9b1d0886edb2e3b4ab65eebb768d0357`; it is not that executable's build.
`SerializationArray.cpp:352-397` passes flattened child ranges and invokes the
child even when an Array range is empty. `SerializationQBit.cpp:421-464`
delegates bulk lifecycle to the existing FixedString tuple planes.

Already admitted: bare QBit and direct Nullable(QBit), with their existing
nominal scalar and dedicated part owners. This slice admits Array chains
ending in bare QBit or direct Nullable(QBit), using a static per-site roster in
the existing recursive bulk visitors. It does not create a serializer for
each wrapper product.

Rejected surface remains load-bearing: Tuple/Map/Nested/Variant static QBit,
QBit-bearing Dynamic actual containers, JSON typed/shared container widening,
LowCardinality(QBit), Nullable(Array(...)), borrowed persisted-envelope QBit,
Compact/sparse/custom serializers and unqualified physical versions. Existing
direct Dynamic/Object QBit owners retain their independent closed contracts.
Source-valid wrappers not admitted here remain library guards, not claims of
ClickHouse invalidity. Native MV/projection writing and query execution are
not part of this slice.

## Design laws

1. Reuse QBit's nominal raw-bit leaf and plane transpose codec. Array supplies
   its own sizes and flattened occurrence domain at every level.
2. Static sites are keyed by structural path and exact QBit metadata. Plane
   order is numeric group-major, never lexical filename order.
3. Plane byte counts belong to child occurrences, including Nullable slots,
   not outer rows or only non-null children. All plane lanes at a site must
   agree; sizes must consume exactly those occurrences. Empty child marks and
   an entirely empty child part remain meaningful schedules.
4. Validate and charge role/name/offset grids, selected occurrence bytes and
   per-type scratch before allocation. Frame-relative physical offsets are
   not required to be plane-width aligned; normalized plane deltas are.
5. Keep root/direct-Nullable fast paths and unrelated value identity semantics
   unchanged. Recursive QBit Array equality/hash must handle zero, one and
   multiple children without losing exact nominal type or raw-bit identity.
6. Public typed scans, windows and owned column values use the same exact
   static declaration admission and complete-part reader. No silent fallback
   to primitive Array readers, parent-row schedules or base projection rows.
7. Neutral declaration and DynamicStructure parsing describes metadata; it
   does not grant storage admission. Count's shared argument policy, JSON,
   Object and complete Dynamic readers/writers retain their narrower gates.
8. Complete size preflight must not replay an entire marks/frame index for
   every mark. Read each bounded size lane once, with aggregate transport work
   limits and checked schedule storage, while retaining complete late-mark
   shape checks. The reader's inspection and shape phases must consume the
   same operation budget. This is a structural work bound, not a throughput
   claim.

The shape pass retains bounded complete Array-size windows, not QBit payloads.
Its three UInt64 accounting vectors require 24 bytes per mark within the codec
byte limit. Physical-lane inspection and size-lane reads share one consumptive
transport budget, including repeated file/header work. Aggregate size-lane
full-window results must fit `max_result_bytes` (64 MiB by default), a narrower
boundary than independently resetting that budget for every mark. Detached
transport accessors may transiently copy/overlap buffers; these logical limits
are not an RSS or allocator guarantee.

## Execution order and Definition of Done

Risk: CAUTION (serialization and public recursive admission).
Rollback: exact local atomic commit from the clean baseline; no remote push.
Likeliest failure: a root QBit plane schedule accidentally uses Array parent
row counts, or an empty mark hides incomplete lanes.

1. Add descriptor/RowBinary/value-identity and complete-part consumer RED
   tests before production edits. Root executes the focused roster through the
   unchanged guarded runner, one worker and isolated cache.
2. Add one-file admission/site owners; integrate path-keyed sites into shared
   planning, encoder and decoder while retaining root controls and guards.
3. Route recursive static declarations through the existing complete-part
   publication and typed-reader adapter, including offline owned values.
4. Root runs the focused and enumerated affected rosters in DEBUG and RELEASE.
   Expected signal: zero failures/errors/pending; unchanged dedicated QBit,
   Dynamic/Object QBit and ordinary Array controls remain green.
5. Build native helpers in both modes and qualify eight finite stock/library
   profiles: four carriers at dimension 9, BFloat16 explicit stride 16/8,
   Array(Nullable(QBit)), Array(Array(QBit)) and wholly empty Array(QBit).
   Expected signal: literal exact full/middle/empty/EOF RowBinary, nominal
   declarations, stock reads, library publication and native ATTACH/CHECK
   success. Separate raw audit reconstructs expectations and re-inventories
   actual part files; a coherent successful-exit CHECK forgery must reject.
6. Inspect final diff, execute strongest hostile schedule/nominal/budget
   controls, update status/landmarks/evidence, then commit exact relevant paths
   only if the declared signals pass.

Concrete executed commands, frozen source hashes, the complete affected roster
and temporary evidence paths are indexed in
[the W230 evidence packet](../.landmark/evidence/recursive-qbit-w230.json).

## Falsifier roster and stop rules

- Literal Array descriptor and RowBinary round trips, signed zero/NaN payloads,
  empty/multi-element equality and consistent hashes.
- Parent rows [2,2,2] versus child counts [2,0,3], all-empty middle mark,
  entirely empty child parts and two independent Array-size levels.
- Nullable null slots retain child planes; hidden defaults remain bounded.
- Missing/truncated/extra plane or sizes, cross-plane count disagreement,
  shape/occurrence mismatch and wrong nominal carrier/dimension/stride reject.
- Small metadata/payload/depth budgets reject before unbounded allocations.
- Existing root/Nullable QBit, Array(UInt64), Dynamic/Object and rejected-wrapper
  controls preserve their contracts.
- Direct Count nominal constructors must retain the same QBit prohibition as
  its DataType factory after the neutral recursive name parser is widened.
- No callback on malformed complete schedules, including EOF windows.
- A counting transport falsifier distinguishes one complete read per size
  lane from per-mark full-index replay; a small retention budget rejects
  before the corresponding allocation/read. An exact inspection-byte cap
  rejects subsequent size reads instead of silently resetting the budget.
- Raw native CHECK result zero or nonempty failure message rejects even after
  coherent capture hashes and green summary fields are rewritten.

If stock persistence disagrees with the source-derived wrapper contract, do
not relax a production guard to make the harness green. Diagnose the physical
envelope and narrow or pivot the proposed admission. All-product, full-suite,
latest-master and performance claims remain outside this qualification.

## Observed qualification and continuation

The same 54 affected spec files pass 353 examples in DEBUG and RELEASE, with
zero failures, errors or pending examples. The final focused DEBUG roster
passes 92 examples. All 33 changed Crystal files pass formatting checks and
the 35-file code/spec/helper/harness freeze matches after qualification.

Both fresh native captures qualify eight profiles: Int8/BFloat16/Float32/
Float64 at dimension 9, BFloat16 dimension 16 with explicit stride 8,
Array(Nullable(QBit(BFloat16, 16))), two Array levels over QBit(Int8, 3), and
wholly empty Array(QBit(BFloat16, 16)). Each mode records 74 stock-source and
81 evidence processes. Separate raw audits pass exact CHECK success, literal
full/middle/empty/EOF RowBinary, nominal declarations and actual part files.
All 484 generated files match across modes by name, size, SHA-256 and bytes.

Root-observed falsifiers rejected per-mark complete-index replay (five reads
instead of two) and the open-time transport-budget reset (a byte cap that
inspection alone exhausted still admitted shape rereads). Direct Count
constructors also needed their retained QBit guard after neutral metadata
parsing widened. The final controls are green. A temporary omitted-schedule
seed fails the first-window late-corruption test; exact source restoration
precedes final evidence. Both final audits reject CHECK-zero and nonempty
CHECK-message forgeries for stock and library-attached parts, then pass after
exact raw-file restoration.

This qualifies wrapper composition, not new QBit leaf serde or execution.
The native witness covers one and two Array levels and these finite metadata
choices, not every admitted depth/parameter/layout. Opening validates complete
shape, not unselected QBit payload integrity. Transient buffer overlap remains
possible; no memory or throughput improvement is claimed. Temporary raw roots
are regenerable caches, not proof when absent. Refresh dependent claims after
owner, consumer, fixture, harness, source or runtime changes.

Next work should qualify a concrete remaining leaf or physical-state boundary,
not manufacture a codec for every recursive product. Multi-site Tuple/Map/
Nested/Variant QBit admission, broader runtime JSON/Dynamic/LC layouts and
remaining AggregateFunction states remain separate open frontiers. MV/projection
writing/execution and broad facade decomposition are also open; performance
remains deferred.
