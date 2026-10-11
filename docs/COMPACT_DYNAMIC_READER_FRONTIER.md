# Compact Dynamic reader frontier

Document status: W262 VERIFIED / root adversary ROBUST within the finite
Default-profile, plain-mark Compact Dynamic target (2026-10-11), after the
current-reader live-baseline accounting falsifier and two-mode refresh.
Baseline: `30818166dc9651b65ad867aecfe98c13b670e74a`.
Candidate transition: immutable persisted Compact Dynamic state feeds the
existing recursive BinaryBulk decoder, without serializers for individual
container products. The next transition is context-owned Compact JSON/Object
binding. The overall types, MV/projection and subsequent performance goal
remains ACTIVE; the finite qualification below does not close that goal.

## Evidence and bounded context

At the baseline, the Compact table admitted static BinaryBulk declarations only.
`DynamicBulkColumnReader` reads independent Wide lanes, not Compact `data.bin`.
The existing Compact physical context provides bounded plain `.mrk3` / `.mrk4`
windows; its baseline typed normalizer did not bind learned Dynamic structures.
The native behavioral RED was executed before production changes.

Root executed the baseline against unchanged production HEAD in
`/private/tmp/crystal-click-w262-red2.5aFk7K`: eight fresh Compact cells
(`mrk3`/`mrk4` x String v0/v1 x Variant BASIC/COMPACT), native CHECK/schema and
literal/SharedVariant witnesses, 16 positive public UInt64 scans, and 48 exact
`UnsupportedFormatError` refusals for root Dynamic, Array(Tuple(..., Dynamic))
and Map(String, Dynamic). Both native and helper processes exited 0 with empty
stderr and no signal/timeout. The refusal is the behavioral RED; caught expected
refusals deliberately do not make the harness process fail. A prior helper
nilability build error and Ruby hex-case mismatch are instrument diagnostics,
not capability evidence. No production source changed before this observation.

Root separately parsed the retained native prefix bytes using W259's independent
Ruby LZ4/mark-coordinate oracle: 96 callbacks (8 cells x 3 sites x 4 marks), wire
version 4, first prefixes of 39/31/30 bytes and later 11-byte prefixes with absent
statistics. The bounded checker passed 3 positive framing controls and rejected
14 malformed controls; this qualifies that fixture-specific instrument, not the
production decoder. Reproduction source and command are retained at
`/private/tmp/crystal-click-w262.yYWloc/audit_native_prefixes_w262.rb` with input
`/private/tmp/crystal-click-w262-red2.5aFk7K/parts/native_manifest.json`.
The captured fixture uses one INSERT with eight rows. It observes a frozen
ordinary roster, SharedVariant values and varying prefix statistics; it does
not independently measure freezing across multiple writer input blocks.

Comparison source is separately pinned to
`ed30948f095ecb70679986d7d60e27ad770ae27a` in
`/private/tmp/clickhouse-w254-upstream.AqeqyC`. Executable provenance is the
independently pinned CH 26.10.1.1201 build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
Neither latest-upstream nor source/runtime identity is claimed.

The first candidate native GREEN attempt exposed a separate public `.values`
RED: native ATTACH DDL preserves `Dynamic(max_types = 1)`, while `columns.txt`
uses `Dynamic(max_types=1)`. Replacing `source_type` with `selected_type` alone
did not help: `WidePart.catalog_type` does not canonicalize Dynamic, so that
fallback remains raw DDL. Root's read-only diagnostic on all eight captured
tables observed the same result at all 24 selected sites: raw strict parsing
refused, bounded neutral parsing rendered the exact expected canonical name,
and the unchanged strict owner accepted that rendered name. This authorizes a
lexically bounded offline-DDL bridge, not a codec grammar relaxation.

CH freezes the first sample's Dynamic/Object structure for the part and
coerces subsequent blocks to it. A later actual type can enter SharedVariant
without creating a new ordinary stream (`MergeTreeDataPartWriterOnDisk.cpp:
634-687`, `ColumnDynamic.cpp:528-544`). Compact runs prefix(sample), body(slice)
and suffix with fresh state per granule; the first prefix has full statistics,
later prefixes have empty statistics (`MergeTreeDataPartWriterCompact.cpp:
174-206`, `SerializationDynamic.cpp:182-325`). Empty Array children still invoke
their serializers. This is a lifecycle/physical-layout obligation, not a new
scalar value encoding.

## Design-sealed target and rejected surface

The first coherent target is a selected Dynamic-bearing declaration, root or
inside already supported recursive static containers, in a quiescent Compact
LZ4 part with plain adaptive marks and Default serializer metadata. Preserve
persisted Dynamic V1/V2/V3 framing, nominal descriptors, BASIC/COMPACT Variant
discriminators, String v0/v1 propagation and SharedVariant envelopes. Qualify
only the actual native matrix and falsifiers executed at closure, not the
Cartesian product of all types and layouts.

JSON/Object structure binding is the next transition through the same prepared
context. It remains rejected in this slice, as do Compact aggregate/SAF/QBit/Geo
actual layouts, non-BASIC Map layouts, compressed marks and Compact writing.
Native-only Dynamic FLATTENED, unknown persisted versions and changing ordinary
rosters are hard errors. Existing Wide admission and static declaration gates
must remain unchanged. A guard is not a capability qualification.

No native MV SQL execution, triggers, freshness, parent projection-manifest
authentication, whole-process RSS, lazy-read or speed-parity claim is included.
Trusted directory ancestry and quiescent offline data remain assumptions.

The current global `BinaryBulkProfile` is a deliberate compatibility limit, not
a universal ClickHouse propagation law. At the separately pinned source,
`DataTypeTuple::doGetSerialization` passes settings directly to its children,
while `DataTypeDynamic::doGetSerialization` resets them when propagation is
false. Thus a valid `Tuple(String, Dynamic)` with String v1 and propagation false
can have a direct String-v1 child and Dynamic-internal String-v0 children. This
mixed tree is currently refused. The next generalization needs an effective
profile per node, not a serializer for each wrapper combination.

## Design laws

1. One selected-column owner prepares one immutable partwide actual roster and
   `BinaryDynamicBulkPlan` / physical binding. Later granules may change their
   statistics, not their ordinary descriptor roster or site identity. Never
   infer a new lane from the selected granule's values.
2. Reuse `DynamicStructureCodec` with bounded borrowed input and the existing
   parsed-structures read-budget bridge. No writer-side synthetic structure or
   fabricated statistics flag may authorize a reader plan. V3 descriptors use
   the existing CH binary DataType grammar; exact consumed framing is checked.
3. Extend the shared Compact lifecycle normalizer to traverse bound Dynamic
   sites into existing BinaryBulk lanes. Retain empty callbacks and every
   parent mark. Value semantics stay in the existing recursive decoder.
4. Bind `.mrk4` to exact ordered native callbacks, including specialized prefix
   names; `.mrk3` remains one grammar-delimited tape. No sorting, deduplication,
   invented callback boundaries or Wide mark assumptions.
5. Initially prepare/replay the bounded complete selected-column grid, including
   a zero-mark selection, so later malformed structure prefixes cannot hide.
   This is explicitly not a lazy or performance optimization.
6. Reuse the established Dynamic typed batch carrier; do not widen static
   `install_binary_bulk_values` or invent a second value representation.
7. Preserve one borrowed codec/transport budget across structure preparation,
   normalization and decoding. Preflight proportional allocations and checked
   role/grid arithmetic. Include retained prepared state and transient windows,
   lane copies and decoded values in existing logical workspace accounting.
   Failure must not reset consumed work or publish a partial batch.
8. Raw String version metadata and effective serializer selection are distinct.
   Dynamic always has an implicit SharedVariant String arm. CH drops non-default
   settings at Dynamic when nested propagation is false; with true/String v1,
   both ordinary and SharedVariant String arms use size streams. Validate the
   supported raw enum separately from nominal `contains_tag?(String)`. Keep
   existing static/metadata-envelope guards unless a separate RED authorizes a
   change. Complete prefix/grid validation is not authentication or semantic
   decoding of every future unselected value payload.
9. Keep SQL DDL spelling separate from canonical physical declarations. A new
   `OfflineDynamicBulkColumnDeclaration` may bridge insignificant whitespace
   outside quoted tokens for parameterized/recursive Dynamic-bearing DDL;
   the unchanged `DynamicBulkColumnDeclaration` remains the admission owner.
   Require lexical equality with the bounded neutral parser's rendered name
   modulo that whitespace: do not reorder Variant arms, rewrite quoted content,
   admit aliases or erase an explicit default cap. Preserve the raw catalog
   declaration and existing bare `Dynamic` route. Do not widen static/JSON DDL,
   `WidePart.catalog_type` or storage codec grammar.

## Execution and falsifiers

Risk: CAUTION (persistent serialization, shared normalizer and typed dispatch).
Rollback: revert only the eventual coherent local feature commit. No push,
dependency change, guard weakening or unrelated staging is authorized.
Pre-mortem: a selected-window planner invents an ordinary lane or skips an empty
callback, producing plausible but incorrect values. The bounded discriminator
is a stock part with later SharedVariant values and ragged empty child marks,
read through the public API. Cross-input-block writer freezing remains a
source-backed contract rather than a measured native fixture claim.

1. Luna owns new W262 specs and a small native helper/runner reusing
   `StockPartProbeSupportW191`; independent Ruby literals are the native value
   oracle. Root executes the pre-change Compact admission refusal. Compilation
   or instrumentation errors do not count as behavioral RED.
2. After RED, Luna owns `compact_dynamic_bulk_column_reader.cr`, the shared
   normalizer/cursor seams, selected profile and Compact table dispatch, plus
   narrow existing carrier/offline integration when required. Root owns this
   frontier and closure ledgers. Workers are not alone and must preserve each
   other's and the user's edits. All heavy builds/native runs remain root-owned.
3. Focused falsifiers: native `.mrk3` / `.mrk4`, root and recursive Dynamic,
   zero/unequal child occurrences, first/middle/last/empty EOF windows, null and
   SharedVariant values, stable repeated prefixes, malformed later prefixes,
   wrong callback roster, unknown/Native-only versions and exhausted reused
   budgets. Include Default metadata/profile guards and static/Wide regressions.
4. DoD: guarded `crystal spec spec/compact_dynamic_w262_spec.cr
   spec/compact_dynamic_w262_adversary_spec.cr --single-module --threads 1
   --link-flags=-fuse-ld=ld --error-trace --verbose`, DEBUG and RELEASE; exact
   affected legacy roster and `spec/offline_dynamic_ddl_w262_spec.cr` in both
   modes; final helpers built in both modes;
   guarded `ruby scripts/probe_compact_dynamic_w262.rb --mode green --crystal-helper EXECUTABLE
   --evidence-root EMPTY_PRIVATE_TMP_DIRECTORY --clickhouse PINNED_CH` on fresh native parts.
   Expected: executed examples pass without failures/errors/pending; native
   CHECK/schema/literal/window/public-consumer assertions pass; source parts
   remain unchanged. Record actual CLI, roster and counts at closure.
5. Root independently checks the intended diff, source contracts, native
   captures and strongest corruption/budget falsifiers before a ROBUST verdict
   or an atomic commit. Update `PROJECT_STATUS.md`, `LANDMARKS.md` and a compact
   evidence index only after observed verification. Do not claim a full suite,
   all-type compatibility or performance from these tests.

## Observed qualification and corrected accounting obligation

The final adversary source check identified an omitted live-reader baseline in
`CompactDynamicBulkColumnReader.ensure_prepared!`: separate checks of base +
physical and physical + normalization peak do not check their simultaneous sum.
A native-backed regression compared only normalization observations, excluding
the final decode census. Root observed RED: the reader peak minus its live
2,634-byte base was 42,681 bytes, below the independent normalizer peak of
45,315 bytes. The minimal checked observer wrapper adds that captured base to
every normalizer observation. The same assertion passed after the change, then
the exact final modes and fresh native matrices passed. Across-part
retained-cache aggregation in `TypedPartTable` remains a separate unqualified
boundary; only the single-part selected-reader aggregate is in this slice.

The exact nine-path DoD roster passed 80 examples in DEBUG and 80 in RELEASE,
zero failures/errors/pending. Both commands explicitly set
`CRYSTAL_CLICK_W262_NATIVE_MANIFEST` to the respective previously audited
DEBUG/RELEASE capture. The new native mrk3 accounting example is opt-in;
the portable roster without that environment variable contains 79 examples:

```text
spec/compact_dynamic_w262_spec.cr
spec/compact_dynamic_w262_adversary_spec.cr
spec/compact_typed_w260_spec.cr
spec/compact_typed_w260_adversary_spec.cr
spec/binary_dynamic_bulk_plan_w154_spec.cr
spec/binary_dynamic_bulk_plan_w154_adversary_spec.cr
spec/dynamic_owned_values_w220_spec.cr
spec/dynamic_bulk_part_w203_spec.cr
spec/offline_dynamic_ddl_w262_spec.cr
```

Both final helpers built from the frozen 549-production-file source index
`57df4d599f3840b590dcc50e7da8facdb88f0b35a65ab1ed81760addf18e74c7`.
The DEBUG helper SHA-256 is
`0de05818ed596fe9923f7a46ad025f0d71d0e08eb33606e2e6a5884688691ffc`;
RELEASE is
`f5e0fa8b026dfdae99dfb1c0884bf1069b75913ce96b809148c017124f36d6c5`.
Fresh native matrices were executed separately in
`/private/tmp/crystal-click-w262-green-debug-accounted.WJCrdR` and
`/private/tmp/crystal-click-w262-green-release-accounted.no1lxC`.
Each covers eight cells (`mrk3`/`mrk4` x String v0/v1 x Variant
BASIC/COMPACT), eight rows, four two-row marks plus terminal zero, root Dynamic,
Array(Tuple(Variant, Dynamic)) and Map(String, Dynamic). Native CHECK/schema,
literal/SharedVariant witnesses, full/first/middle/last/EOF-first reads,
`CompactPartTable`, `TypedPartTable` and offline `.values` assertions passed.

Root's private auditor verified actual invocation artifacts and pins, then
compared all 84 part-file pairs / 36,628 bytes across modes byte-for-byte.
Canonical helper semantics agree (SHA-256
`57baf98287ba7b3b0bf2ed68d8b6811d71a851b7fb83a2021c04600ddbc1af88`).
Pre/post closure preserved 234 regular capture files and the exact 18 native
aliases across the two roots. The original whole-root no-symlink audit rule was
refuted by ClickHouse's expected table and metadata aliases. The repaired
instrument binds each allowed alias to its manifest table or metadata UUID
directory, never enumerates through aliases, and still rejects links within
actual parts or unexpected/out-of-root links. Three positive synthetic
snapshots, five alias refusals and a raw-link-target replacement control passed.
This auditor reuses the runner oracle; it is not a second codec or independent
CityHash implementation.

Root additionally ran a private DEBUG-compiled public-API instrument against
both final captures. Rebuilt native mrk3/mrk4 copies with later Dynamic wire
version 4 -> 9 were refused before callbacks for EOF-first and empty-candidate
requests (four refusals per capture). Real prepared contexts plus injected
logical retained-byte estimates triggered the public aggregate-workspace guard
for EOF and empty requests (two refusals per capture), while individual
estimates remained below the same limit. Clean positive contexts and unchanged
original capture bytes were checked. These estimates do not allocate the
claimed bytes: this is accounting/guard qualification, not RSS, allocator
capacity or a preallocation pressure test. Actual logical retained censuses
were 86,233 and 86,251 bytes; equal values across independent stores are not
required. This is not a RELEASE-compiled corruption-instrument claim.

Two further instrument/expectation refutations are retained separately from
serde results. Native offline DDL needed the bounded whitespace bridge from
law 9, with all 24 selected sites checked and the strict owner unchanged.
The inherited W220 whitespace-only Dynamic refusal expectation was replaced
by the newly admitted route while preserving malformed/reordered/default-cap
refusals. A Ruby Float64 oracle compared little-endian wire hex with numeric
bit hex; numeric bit representation fixed the instrument, and four positives
plus three old-encoding mismatch controls passed. Fresh native runs followed
both repairs. Neither an instrument build failure nor an oracle mismatch is
promoted to a library behavioral failure.

All builds/spec/native runs used the unchanged serial 12-GiB process-tree guard
and 50% free-memory preflight; no dependency or performance change was made.
Root source inspection, the baseline-accounting RED/GREEN, public corruption/
accounting controls and raw capture closure support a ROBUST verdict within
the finite target. Same-lineage Luna review is correlated; the full suite, all
type/layout products and <=10% speed parity remain unqualified. Exact commands,
input seals, private instruments and raw
capture references are indexed in
[W262 evidence](../.landmark/evidence/compact-dynamic-reader-w262.json).

Source, test, helper, oracle, tool, metadata/profile or consumer drift, a widened
layout, or private capture loss reopens the corresponding qualification.
Refresh the exact two-mode roster, fresh native matrices and affected negative
controls. The evidence index is an index, not proof by field presence.
