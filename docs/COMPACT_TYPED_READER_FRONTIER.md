# Compact typed reader frontier

Document status: W260 VERIFIED within the finite static Compact/plain-mark
typed-reader target; root adversary ROBUST within scope (2026-10-11).
Baseline RED at `62f0e2cdf320d0900a91aebe470a38b127a68981` is retained below.
The complete types, MV/projection and subsequent performance goal remains
ACTIVE. This slice is typed reading of existing Compact parts, not Compact
writing, new type semantics or speed qualification.

## Anchor and discriminating evidence

W259 provides detached physical windows for actual top-level Compact parts
with plain adaptive `.mrk3` or `.mrk4` marks and an explicit zero-row EOF
record. Its raw shards are not typed values. `BinaryBulkColumnReader` still
owns Wide role-addressed `.bin`/`.mrk2` inputs; putting a Compact path into
that reader is not a transport adapter.

The root built `scripts/check_compact_typed_w260.cr` at the baseline and ran
the resulting executable against the W259 independently captured native
parts. The Wide control passed literal full/middle values and the exact
`[2, 2, 2, 2]` real-mark row grid. The same existing typed API rejected:

- `.mrk3`: `columns_substreams.txt is required for multi-column parts`;
- `.mrk4`: `selected numeric stream files not found`.

The helper exited 1. Its first compilation failure was a helper rescue-path
type error, repaired before this run; it is not the behavioral RED.
Native parts are under
`/private/tmp/crystal-click-w259-native-debug-sealed.inObat/stores/native/store/`:
Wide `ec1/ec15f773-1409-4713-b1a7-8c1cb96688bf/all_1_1_0`,
mrk3 `d47/d47b9550-241a-42b6-8cd7-4140e1b81b2f/all_1_1_0`, and
mrk4 `ede/ede94186-d8e5-4766-8a2a-d64ae9a9696d/all_1_1_0`.
These captures are the initial discriminator, not a substitute for fresh
W260 qualification.

Comparison source: `ed30948f095ecb70679986d7d60e27ad770ae27a` in
`/private/tmp/clickhouse-w254-upstream.AqeqyC`. Runtime provenance is separate:
stock 26.10.1.1201, build `d9bcb5ab007f0f6299f7f973f2642245bab3d028`,
executable SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
No assertion of latest upstream or source/runtime equivalence is made.

## Target contract and composition laws

1. Keep `WidePartTable.open_selected_typed` genuinely Wide. Introduce
   `TypedPartTable` as the format-neutral selected-column facade and
   `CompactPartTable` as the Compact backend. Route the offline catalog's
   ordinary `.values`, typed scans and MV source input through the facade.
   Preserve resolved candidate order, global part indices and source-row
   offsets, bounded callback batches, full/window/candidate-mark semantics
   and existing public value/accessor representations. A primitive Compact
   column must not silently become a collection of `BinaryValue` objects.
2. Preflight metadata, selected declarations, compatible schemas, complete
   row grids and the complete requested mark schedule for every candidate
   before the first callback. Mixed Wide/Compact candidates must not admit
   an unsupported later part after emitting earlier rows. Metadata preflight
   is not authentication of every untouched payload frame.
3. Use a shared recursive lifecycle normalizer, not fixture-name dispatch
   or a new serde implementation for every wrapper. For each column and
   granule, fresh state runs all prefixes, then recursive bodies, then
   suffixes. Tuple phases traverse all children in declared order. Array
   derives Q from its P position-independent element counts; Nullable has
   P null bytes and P nested values including null rows; Variant derives
   Q_i from P discriminators. Retain zero-occurrence child events and empty
   intervals. A whole-column mrk3 tape needs grammar-derived boundaries;
   mrk4 binds the exact physical callback roster, not sorted logical roles.
4. Normalize admitted physical events into existing `BinaryBulkStreams`
   and reuse `BinaryBulkTypePlan`, `BinaryBulkPhysicalPlan` and the existing
   decoder/leaf codecs. Root fixed-width scalars and recursive static
   String/FixedString/Array/Nullable/Tuple/Map BASIC/Nested/LowCardinality/
   Variant shapes are descriptor-driven through the existing canonical
   static declaration and codec gates, not an allowlist of the seven native
   fixture columns. This does not widen the codec's existing type ceiling.
   Qualify only the layouts actually exercised by the sealed checks below.
5. Select String v0 single-stream or v1 with-size-stream from bounded,
   validated serialization metadata. v1 has P UInt64 sizes and concatenated
   bytes; v0 has VarUInt length and bytes per value. Nested propagation must
   be explicit or follow a proven legacy default. Reject unknown versions,
   sparse/custom/bucketed profiles and malformed metadata rather than
   guessing a layout from payload plausibility. The existing selected-Wide
   metadata proof is not a general Compact version validator.
   `serialization.json.columns` is an optional per-column record roster,
   not a complete schema roster: the source omits always-default records.
   Validate present names/counts/shapes without requiring schema equality.
   Default Tuple records always carry subcolumns; `exact_num_defaults` is
   optional and absent means false, including recursively nested records.
6. Variant prefixes declare BASIC=0 or COMPACT=1 independently of its
   discriminator body. Normalize BASIC P bytes and COMPACT's
   VarUInt(P)/PLAIN-or-repeated-ID envelope to P local discriminator bytes;
   validate counts, mode, IDs and arm order. Visit each arm even at Q_i=0.
   Native qualification must include a repeated-ID granule, an empty arm
   and a null-only granule, not only the W259 mixed-arm PLAIN case.
7. The admitted Compact LC profile has prefix UInt64 version 1, no global
   dictionary, additional keys and dictionary update, empty DictionaryKeys
   body and no suffix dictionary. Validate per-granule occurrence counts,
   widths, inline keys and IDs with the existing LC storage codec. Build
   the normalized dictionary lane as one version header with every mark
   offset at 8; retain each index record. Complete-grid replay/validation
   remains required by the existing decoder even though this profile has
   no prior global-dictionary state. Other LC flags/layouts are guards,
   not newly admitted capability. Do not discard nested LC sites.
8. Add one type-directed `BinaryValueTypedBatchAdapter` for existing scalar,
   String, Nullable, Array, Tuple, Map, LC and Variant batch carriers; reuse
   that conversion recursively. Existing generic-static columns retain
   their established `BinaryValue` representation. Do not weaken a batch
   accessor's exact type checks to hide missing conversion.
9. Add a format-neutral bulk-reader seam for the generic-static `.values`
   materializer's two-pass preflight/read operation. Preserve ownership,
   logical read/materialization budgets, row/type/grid validation and
   retained reader/workspace accounting for both backends. New copies,
   expanded discriminators and synthesized lanes need budget preflight;
   a reused consumptive budget cannot reset after a failed operation.
   Dispatch itself uses the bounded regular-file metadata reader; it cannot
   invoke an earlier unbudgeted `checksums.txt` read. Compact selected logical
   payload bytes are the checked sum of selected per-mark slot intervals,
   not terminal-minus-first spans that include interleaved other columns.
   Before admitting Compact generic-static `.values`, attach the materializer's
   workspace preflight to known normalizer allocations and retain the measured
   peak through descendant admission. Physical bytes alone do not bound a
   repeated COMPACT discriminator's expanded tags, especially below Array/Map
   where Q can greatly exceed P. Charge the actual derived occurrence count,
   normalized lane builder/build/stream copies and retained offset containers;
   reject before the allocation that would exceed the logical workspace bound.
   Preflight descriptor-derived role/name-plan and callback-cursor setup with
   a nonallocating census before constructing those owners, and retain that
   allowance in subsequent observations. Account array capacity and possible
   reallocation overlap, not only the populated byte/offset counts. The census
   must not render type names, allocate child rosters or charge the borrowed
   codec budget a second time.
   Keep the existing two-argument bulk read and Wide behavior unchanged.
   Before typed mark materialization, preflight the sum of every selected
   reader's known retained workspace, including unvisited readers that are
   already live. Charge that baseline once, then add per-column transient
   peaks and decoded owners without charging each retained baseline again.
   An aggregate baseline that cannot fit must reject before the first payload
   read, not only before the first user callback.
   Census retained metadata at its stored owners without calling detached
   getters. Include the lookup Hash, each per-column Array and its reference
   slots, the flat roster references, copied input names/paths and normalizer
   column String. Count logical cardinalities; conservatively repeated alias
   or shared-budget charges are allowed. This baseline model excludes reader
   construction, the shared parsed descriptor graph, the whole multi-part
   facade, caller copies and allocator capacity. It is not an all-heap cap.
   Add a nonallocating `CompactPartPhysicalWindow#mark_count` accessor so the
   normalizer can preflight its detached granule copy without cloning the
   complete window merely to count it. This does not expose mutable owners.
10. Keep existing Wide flattened-Nested and projection ownership routes
    intact. Explicitly reject Compact where those existing owners cannot
    yet bind its layout. Context-owned Dynamic/JSON, aggregate states,
    SimpleAggregateFunction, QBit and custom Geo keep their existing owners
    and are not smuggled through the static Compact gate. Their Compact
    bindings and projection/MV composition remain later frontiers.
    Preserve the existing table/catalog refusal for bare `Nothing`: its
    presence in the binary grammar is not stored-column admission. The shared
    generic-static consumer predicate must reject that root before empty-part
    materialization; do not remove `Nothing` from recursive descriptor/codecs.
    This is not a universal storable-type validator. The lower-level Wide
    `BinaryBulkColumnReader` and its format-neutral bulk wrapper retain their
    existing codec grammar, including root `Nothing`; Compact requires an
    established typed carrier. Recursive `Nothing` predicate forms remain
    locally admitted but are not native stored-profile qualifications.

Inherited assumptions: quiescent offline parts and trusted caller-selected
directory ancestry. Outputs own their bytes/values; no mmap slice escapes.
Logical budgets bound measured work/retained structures, not total RSS or
arbitrary caller copies. Payload authentication covers touched compressed
frames only. Compressed marks, nonadaptive/nonterminal grids, Compact writing,
native MV SQL execution and speed parity are not newly admitted.

## Source anchors and strongest falsifier

The comparison source creates fresh Compact state per column/granule and
calls prefix/body/suffix in `MergeTreeDataPartWriterCompact.cpp:174-228`.
`SerializationTuple.cpp:794-862` separates child phases;
`SerializationArray.cpp:329-395` preserves zero-child callbacks;
`SerializationNullable.cpp:114-137` keeps null and nested counts aligned;
`SerializationMap.cpp:756-784,1335-1365` distinguishes BASIC from bucketed;
`SerializationString.cpp:506-521,928-1002` defines the two String profiles;
`SerializationLowCardinality.cpp:72-171,271-314,534-626` defines prefix,
flags and additional-key records; and
`SerializationVariant.cpp:199-246,301-357,417-523` plus
`SerializationVariant.h:54-70,178-182` define both discriminator envelopes.

Highest-risk assumption: recursive value grammar alone describes physical
boundaries. Its cheapest counterexamples are a Tuple with two prefix-owning
children, an empty Array of LC/Variant, a repeated COMPACT discriminator and
a non-admitted LC global flag. mrk3 and mrk4 must agree with independent
native literal values for those cases. Metadata, profile and requested-schedule
mismatches must reject before callbacks; malformed later payloads may reject
after earlier valid marks have been emitted. Observed monotone physical windows are not a
universal serializer-interface guarantee.

## Small implementation plan and ownership

Risk: CAUTION (persistent formats, recursive lifecycle and public read routing).
Rollback: revert only the resulting qualified local atomic feature commit.
No push, history rewrite, unrelated staging or guard weakening is authorized.

1. Core Luna owns new single-class files for Compact serialization profile,
   lifecycle/event normalization, lane builder, granule cursor, bulk reader
   and Compact table, plus require registration and the narrow physical
   context metadata getters. Facade/source Luna owns `TypedPartTable`, its
   entry owner, the format-neutral bulk seam and the narrow integrations:
   `src/crystal_click/offline_table.cr`,
   `src/crystal_click/offline_table/static_bulk_values_materializer.cr`,
   `src/crystal_click/offline_part_transform_input.cr`.
   Preserve existing Wide-only owners. Report exact new paths before
   test imports are sealed; do not perform unrelated facade decomposition.
2. Test Luna owns `spec/compact_typed_w260_spec.cr`,
   `spec/compact_typed_w260_adversary_spec.cr`, reusable W260 support,
   `scripts/check_compact_typed_w260.cr` and
   `scripts/probe_compact_typed_w260.rb`. It may reuse W259 raw fixture and
   stock probe support without modifying the sealed W259 scripts/specs.
   Root owns this SDD, status/landmarks and closure evidence. The source-grammar
   Luna now exclusively owns `src/crystal_click/binary_value_typed_batch_adapter.cr`
   and additive carrier installers in
   `src/crystal_click/wide_part_table/wide_part_table_batch.cr`.
   Its shared seam is `BinaryValueTypedBatchAdapter.install(batch, column,
   type, values, expected_rows)`. Coordinate rebasing must return the mutated
   batch struct to its caller; carrier hashes alone do not establish scalar
   field mutation. Agents are not alone and must preserve each other's edits.
3. Root serially executes all builds/tests/native processes under
   `COGNI_RUN_SAFE_MIN_FREE_PCT=50`, `CRYSTAL_WORKERS=1`, a 12-GiB
   process-tree guard and bounded timeouts. No unguarded substitute is valid.

## Definition of Done and qualification boundary

Before qualification, seal the exact affected spec roster and native matrix
here. Minimum checks:

- DEBUG and RELEASE focused/adversary specs: lifecycle phase order,
  P/Q/Q_i, zero children, malformed/trailing envelopes, LC flags/IDs,
  metadata/roster mismatches, reused/exhausted budgets, detached ownership,
  public scalar/container carrier preservation, mixed candidate preflight,
  full/first/middle/last/EOF/windows and complete candidate-mark schedules.
  A tiny physical Array/Variant tape with Q much larger than P must exercise
  the Compact normalization workspace hook: an adequate bound passes exact
  values, and an insufficient bound rejects before expanded tags/lane copies
  are allocated. This is a logical-workspace check, not a process-RSS claim.
- Existing affected Wide, catalog, static-materialization, PK and MV-source
  regressions; no full-suite claim without a full-suite run.
- Fresh stock CHECK, exact schema and independent literal full/window values
  for native Wide control plus Compact mrk3/mrk4, String v0/v1 and Variant
  BASIC/COMPACT, including repeated/null/empty-child cases and a separately
  composed schema. Catalog `.values` and UInt64-PK granule filtering must
  traverse the public format-neutral route, not only a direct codec helper.
- Guarded commands: `crystal spec SPEC_PATHS --single-module --threads 1
  --link-flags=-fuse-ld=ld --error-trace --verbose` (also `--release`);
  `crystal build scripts/check_compact_typed_w260.cr` with the same build
  flags and separate DEBUG/RELEASE executables; then
  `ruby scripts/probe_compact_typed_w260.rb --helper EXECUTABLE --root
  EMPTY_CAPTURE_ROOT --clickhouse PINNED_EXECUTABLE`. Expected: all executed
  assertions pass, zero pending/errors/failures, exit 0, matching independent
  native literals and complete process/capture provenance.
- Root inspection and hostile self-review after implementation; fix findings
  or narrow the claim before the local feature commit. Same-lineage agent
  agreement is not independent proof. Performance remains deferred.

Evidence becomes stale after changes to production/support/qualification
code, tool or runtime provenance, admitted metadata/profile laws or the sealed
commands. Refresh the affected checks; fail closed on unknown physical layouts.

## Sealed native matrix and public seam

The public factories are
`TypedPartTable.open_selected_typed(parts : Array(String), columns : Array(String))`
and `CompactPartTable.open_selected_typed(parts, columns)`. Both expose the
existing selected-reader metadata and scan signatures and yield
`WidePartTableBatch`. The generic materializer uses
`TypedBinaryBulkColumnReader.open(path, column, type)` with matching row/grid/
declaration/read contracts and backend-specific retained-workspace accounting.
The current public Wide constructor of `OfflinePartTransformInput` remains
valid; the new typed facade is an additive accepted source.

Production files are `compact_serialization_profile.cr`,
`compact_binary_bulk_normalizer.cr`, `compact_binary_bulk_lane_builder.cr`,
`compact_binary_bulk_granule_cursor.cr`, `compact_binary_bulk_column_reader.cr`,
`compact_part_table.cr`, `typed_part_reader_entry.cr`, `typed_part_table.cr` and
`typed_binary_bulk_column_reader.cr`, all under `src/crystal_click/`.
The narrow existing physical-window change is
`src/crystal_click/compact_part_physical_window.cr` (nonallocating count only).
The Compact bulk reader's public open arguments match the existing codec/
transport limits and optional borrowed budgets, not only default budgets.

The fresh native matrix has 11 parts: one Wide control, eight Compact schema-A
cells (`a_mrk3_s0_vbasic`, `a_mrk3_s0_vcompact`, `a_mrk3_s1_vbasic`,
`a_mrk3_s1_vcompact` and the four corresponding mrk4 cells), and two schema-B
cells (`b_mrk3`, `b_mrk4`, String v1 and Variant COMPACT). Each has eight parent
rows and four two-row real marks, plus EOF. Helper CLI:
`roundtrip WIDE_PART MANIFEST.json`; manifest format is
`compact_typed_w260_manifest_v1` with ten Compact label/path entries.
It also requires `catalog_root` and `mv_source` with label
`a_mrk3_s0_vbasic` and an isolated `target_path`. The helper must traverse the
actual offline `w260_mv` source owner using one-row batches, verify exact
`pk`/`s` values and mark/global offsets, execute a caller-defined Crystal
transform, then read the resulting detached Wide output part with literal
`id`/`value` values. This is a Compact-source composition check, not native
MV SQL execution or Compact writer qualification. The runner supplies local
MV/target metadata; no production server state is changed.

Schema A (nine columns): `pk UInt64`, `s String`, `n Nullable(UInt64)`,
`arr Array(Nullable(UInt64))`,
`pair Tuple(left String,right String,code UInt64)`,
`seq Array(Tuple(label String,value Nullable(UInt64)))`,
`lookup Map(String,Array(Nullable(UInt64)))`, `lc LowCardinality(String)`,
`v Variant(String,UInt64)`. Literal keys are 7101..7108. The fixture separately
declares expected root strings, null scalars, three-field tuples, variable/
empty arrays, map entries, duplicate/empty LC keys and Variant rows. It includes
repeated-string and repeated-UInt64 discriminator granules, a null-only granule
and a mixed-arm granule, with empty child marks both first and in the middle.

Schema B (three columns): `pk UInt64`, `label String`,
`pair Tuple(l Array(LowCardinality(UInt64)),v Array(Variant(String,UInt64)))`.
Keys are 8101..8108; tuple children have Q=0 on real marks 0 and 2 and different
positive occurrence counts later. This tests prefix-owning siblings in a
single column, not just separate LC and Variant columns. Invalid LC-inside-
Variant declarations are not substituted for this valid composition.

All cells explicitly request plain adaptive marks, uncompressed primary
index, LZ4, with-types serialization metadata, propagated nested versions and
Map BASIC. The runner independently checks actual files, stock CHECK, exact
schema, full/middle literal values and helper values; requested settings alone
do not establish the resulting format. Unknown runtime settings or SQL/schema
construction errors are instrumentation failures, not format falsifiers.
The stock Wide control retains all nine schema-A columns in native schema and
literal checks. Its Crystal typed control selects the existing seven-column
contract (`pk`, `s`, `n`, `arr`, `pair`, `lc`, `v`): the inherited multi-column
Wide `Array(Tuple)` and Map owner restrictions are not widened by W260. Every
Compact schema-A cell still selects and checks all nine columns; schema B
still selects and checks all three. The initially overbroad Wide helper
selection rejected at its existing guard, rather than establishing a Compact
format failure. Full/window/candidate callback coordinates and direct source
names, exact single runtime-pin markers and unchanged copied source-part
inventories are required alongside value correctness.
Root must inspect the final SQL/constants and seal the exact affected spec
paths before executing qualification. Counts or roster-only green signals
cannot stand in for value correctness.

## Sealed affected spec roster

The following 84 paths form the final affected regression/falsifier roster,
fixed before root-Nothing-guard qualification. Run it in DEBUG and RELEASE, with zero
failures, errors or pending examples. This is not a full repository suite.
The extra context-owned consumer paths check that the format-neutral
materializer seam does not change the existing Wide ownership routes.
The unchanged 12-GiB process-tree guard stopped the combined 67-file DEBUG
compilation before any examples ran; that attempt is inconclusive. Execute
the complete ordered roster below in serial cohorts of at most three files,
with one compiler worker and the same guard in both modes. Cohort union must
equal the sealed roster without omissions or duplicates.

### Diagnostic lineage before the final guard seal

The chronology below records earlier input states. Required/pending statements
are stage-local; final guard-source qualification supersedes their green
signals. Earlier failures and instrumentation corrections remain diagnostics.

The first final native helper exposed a public carrier seam failure:
`Array(Nullable(UInt64))` filled only the dedicated batch map, while offline
`.values` uses the generic nullable-numeric accessor. Root reproduced that
exact exception in a test-only two-row witness before the repair. The same
retained slice now fills both established maps, matching the Wide route;
exact nominal/row-count guards and the generic BinaryValue rejection remain.
The focused RED had 17 examples with one error; focused GREEN had 17 examples
with zero failures/errors/pending. A filtered zero-example invocation is
instrumentation-only. Fresh full native and affected-roster qualification
are still required; focused GREEN is not a substitute.

The next fresh native attempt passed the repaired carrier and rejected a
stale PK oracle. `scan_uint64_pk_candidates` returns conservative whole
granules, not exact matching rows. The existing predecessor rule selects
marks `[0, 1, 2]` for bounds `[7103, 7106]` (schema B: `[8103, 8106]`),
with callback sizes `[2, 2, 2]` and the first six fixture keys. The helper
and runner now assert that schedule separately from the caller-side exact
predicate, which retains four keys. Root independently read the 40-byte
`primary.idx` as `[7101, 7103, 7105, 7107, 7108]` and inspected the existing
pruning law. No production pruner was changed; the failed attempt is not
native qualification. Fresh DEBUG/RELEASE qualification remains required.

The following fresh attempt passed `.values` and the repaired PK oracle,
then rejected the helper's MV target metadata: two rows per output mark
were requested against an undeclared, default 8192-row target granularity.
This is a target-binding guard, not evidence of a Compact source failure.
The harness must declare matching admitted target settings and preserve
its exact source/output witnesses before native qualification can pass.

A subsequent hostile review found an unclosed typed-scan workspace seam:
`CompactPartTable#materialize_mark` called the two-argument reader overload,
which discards the Compact transient-workspace observer. Retained BinaryValue
checks alone do not enforce the shared mark allowance during physical-window
copying and lane normalization. Root independently confirmed the call path
against the observer-aware static `.values` materializer. Root observed a
deterministic typed-scan RED: 18 focused examples, one failure, zero errors
or pending; the expected `CorruptPartError` was not raised. A spec-only
injected conservative byte estimate on a tiny valid physical fixture
discriminates observer propagation without a large allocation. The narrow
repair passes the three-argument observer, checks retained workspace plus
each observed extra against the shared allowance, and retains the monotone
extra peak through decoded-owner and remaining-column accounting. The sum
of per-column peaks is deliberately conservative, not minimal RSS. The same
focused command now passes all 18 examples with zero failures, errors or
pending. Neither run qualifies all decoder allocations or process RSS.
Fresh native DEBUG/RELEASE and the complete 83-file roster remain required.
Partial cohort passes at the earlier source state do not qualify the repair.

The next helper run reached MV output construction, where the existing writer
correctly rejected one eight-row String granule against the two-row target.
The harness now supplies four two-row granules and asserts the exact readback
grid. No production writer rule changed. A subsequent complete helper report
exposed a Ruby field-roster assertion whose expected list was not sorted;
the exact five-field roster is now canonicalized, with all value and coordinate
assertions retained. Root replay accepts the captured positive report and
rejects both a missing field and an extra field. These diagnostic captures and
replays do not replace fresh native qualification.

Root also found instrumentation-only failures in the temporary raw-capture
auditor: exact helper argv retained a native trailing path separator that the
canonical summary path omits, an unbound helper-record local interrupted its
pin check, and a native-literal negative control failed to discriminate its
intended mutation. These attempts are not successful audit evidence. Original
captures and production sources remain unchanged during auditor repair.
The first stored whole-roster hash display was truncated; root recorded a
complete 103-path hash roster before repeating the early qualification checks.
Only complete identities and observed successful reruns may support closure.

The repaired raw auditor accepts both earlier native captures and rejects all
28 in-memory negative controls per cell (56 total), without changing captures.
The native literal control changes only the pinned String field and preserves
field count, line count and the original terminator; its no-op and duplicate-
terminator instrumentation defects are not counted as successful controls.
This audit reuses the runner's exact oracle; it is not a second native decoder.

Final public-seam hostile review reported a VULNERABLE boundary:
the typed materializer charges retained reader workspace only as it visits
each column, although all selected reader contexts are already resident. Root
observed the behavioral RED on a tiny valid two-column part: each spec-injected
retained estimate is individually below the allowance, but their sum exceeds
it. The old implementation refuses before callbacks after invoking the first
reader once; the test requires refusal before any reader invocation. The
focused run has 14 examples, one failure, zero errors/pending and exit 1.
This synthetic logical estimate does not allocate a large payload or establish
an RSS bound. The narrow repair charges the resident baseline once before
result allocation or decoding, then retains transient peaks and decoded-owner
charges. A below-limit positive injects 24 MiB into each reader and verifies
one exact row, one callback and two reads; recharging the baseline would reject
it. Root's focused two-file GREEN passes all 20 examples with zero failures,
errors/pending and exit 0; the affected Crystal format check also passes.
The complete input seal, both native cells and all 83 affected spec paths
must still be refreshed. Earlier successful source-state checks do not
qualify this repair.

A subsequent retained-metadata census review found two distinct limitations:
the reader estimate calls detached `columns`/`roster` getters before budget
preflight, and it omits the persistent per-column Hash/Array lookup index and
the physical input's copied path/name Strings. These are known structural
owners, not allocator-capacity or RSS measurements. A spec-only clone-counter
falsifier produced a runtime RED before any census repair: 16 examples, one
failure, zero errors/pending, exit 1; the columns getter was called twice after
the open-time snapshots were excluded. The direct-owner repair removes those
census snapshots and includes the known index/ref/String owners. Two isolated
index cardinality checks cover mrk3 one/sixteen columns and mrk4 two/one slots.
Root's focused two-file GREEN has 23 examples, zero failures/errors/pending,
exit 0; all 24 affected Crystal paths pass formatting. A complete 106-path
source seal now covers the final census inputs; fresh whole-roster and native
qualification is still pending. The resident-baseline arithmetic remains
separately qualified by its focused checks; an all-retained-object-graph
claim is not admitted. The logical model does not bound reader construction,
the shared parsed type-descriptor graph, the whole multi-part facade, caller
snapshots or allocator capacity.

At the final census seal, the first nine DEBUG cohorts pass 251 examples.
The next six-file compile is killed by the unchanged 12 GiB process-tree
guard before any examples run; this is an inconclusive resource diagnostic,
not a decoder-test failure. Root reduces all remaining DEBUG/RELEASE groups
to at most three files without raising the guard or changing the sealed
83-path roster. The earlier same-seal passing cohorts remain valid; final
qualification must account for each path exactly once in each mode.

The next context-owned consumer cohort exposes a preexisting selected-column
guard failure, not a W260 factory regression: `Nothing` on an empty table
returns an empty `.values` result instead of the W220 `UnsupportedFormatError`.
The final-census cohort has 24 examples, one failure, zero errors/pending,
exit 1. Root's isolated exact-HEAD archive control reproduces the same assertion
with 10 examples, one failure, zero errors/pending, exit 1. The preceding
noncanonical `Array( Dynamic )` refusal passes; root's initial whitespace
hypothesis is refuted by numbered source and the control. No assertion is
weakened. The general static fallback admits the bare root before any reader
is opened. Pinned `DataTypeNothing.h` inherits `IDataTypeDummy`; the latter's
`cannotBeStoredInTables()` returns true. A narrow root-tag consumer guard is
the prerequisite repair; recursive grammar and internal serde stay unchanged.
Its risk is CAUTION (shared consumer admission), rollback is the exact feature
commit, and the DoD includes the unchanged W220 refusal, an explicit shared-gate
control, and fresh affected DEBUG/RELEASE/native checks at the new source seal.
Earlier census-seal passes remain diagnostic, not qualification of this repair.

The first focused guard check passes all ten unchanged W220 examples but
fails the new adversary's contradictory Dynamic-parser assertion: 16 examples,
one failure, zero errors/pending, exit 1. Exact legacy `Dynamic` intentionally
returns nil from that specialized parser while its established typed route
is admitted. Only the new assertion is corrected. The focused rerun passes
16 examples, zero failures/errors/pending, exit 0. Source hostile review finds
the lower-level Wide bulk factory still accepts the broader codec grammar;
the contract above is explicitly scoped to table/catalog admission, not every
public codec factory or a recursive native-storable-type validator.

The final source seal includes 21 production paths, three fixture/helper/runner
paths and 84 specs (108 identities). The new root-Nothing prerequisite adds
`wide_part.cr` plus the existing `static_nested_handoff_w248_spec.cr`, which
directly exercises its generic admission predicate. Re-run all 84 paths once
in each mode as serial cohorts of at most three files, with the unchanged guard;
no earlier-state cohort is promoted to this final qualification.

## Final guard-source qualification

At the 2026-10-11 05:35:27 UTC seal, all 108 production/support/spec identities
remain unchanged. The exact 84-path command roster completes in both modes:
28 DEBUG and 46 RELEASE serial cohorts, 392 executed examples per mode,
zero failures/errors/pending. Two fixture-gated paths are compile-only as
explained below, not fresh native Count/SAF consumer qualification.

Both fresh final helpers build. Fresh DEBUG and RELEASE stock cells each pass
the exact 11-part native matrix, public values/coordinates, catalog values,
UInt64-PK candidates and caller-run Compact-source/Wide-target composition.
Root's raw-capture audit passes two positives and 56 negatives, leaves both
original captures unchanged, and confirms equal native bytes and helper
semantics between modes. Each cell has 174 native files / 60,888 bytes and
105 copied source files / 50,868 bytes. The auditor reuses the pinned runner's
oracle; it is not an independent native serializer.

The rebuilt root normalizer probe also passes both earlier pinned native
mark modes and authored String-v0, ordered-Tuple and explicit-zero-child
controls, plus reordered/omitted/trailing-tape refusals and the consumptive
borrowed-budget check. All 25 affected Crystal paths pass formatting.
This is not an all-layout, all-heap, full-suite, Compact-write, native-MV-SQL
or speed-parity claim. Final refresh confirms all 108 input hashes plus nine
tool/runtime/helper/summary identities and the pinned comparison revision.
The repeated actual-capture audit passes unchanged originals and all controls.
The intended diff contains only W260 paths. See the
[curated root evidence](../.landmark/evidence/compact-typed-reader-w260.json);
JSON syntax/field validation is not itself behavioral proof.

The original final RELEASE cohort 20 (`wide_part_table_w77`, `w78`, `w79`)
hit the unchanged process-tree guard before examples: 12,586,336 KB above
12,288 MiB after approximately 219 seconds, exit 1. This is inconclusive,
not a decoder failure or green coverage. At 2026-10-11 06:51:50 UTC the
command roster was revised without source/profile/guard changes: the first
19 RELEASE cohorts (57 paths, 258 examples) remain qualified at the same
108-input seal; the remaining 27 paths run as singletons. Final coverage
contains each of the exact 84 paths once per mode: 28 DEBUG and 46 RELEASE
cohorts, with zero failures, errors or pending examples. The killed command
is retained as a diagnostic and excluded from green coverage.

The singleton tail exposed an evidence boundary hidden by bundled counts:
`aggregate_count_offline_w177_spec.cr` exits 0 with zero examples unless
`W177_STOCK_ROOT` is configured. A source scan of the exact 84-path roster
finds one other fixture gate, `W221_PART_ROOT` in the native SimpleAggregate
consumer spec. These commands do not configure either fixture. Zero-example
invocations are compile-only, not behavioral consumer qualification; the
packet must identify them separately rather than infer execution from an
aggregate green count. Other synthetic/local Count and SAF regressions remain
distinct evidence. W260 does not claim fresh native Count/SAF consumer checks.

- `spec/binary_bulk_discriminator_framing_w189_spec.cr`
- `spec/binary_bulk_physical_prefix_w151_spec.cr`
- `spec/binary_bulk_w122_spec.cr`
- `spec/binary_low_cardinality_storage_w142_spec.cr`
- `spec/compact_physical_context_w259_adversary_spec.cr`
- `spec/compact_physical_context_w259_spec.cr`
- `spec/offline_catalog_projection_w87_spec.cr`
- `spec/offline_catalog_spec.cr`
- `spec/offline_catalog_w27_spec.cr`
- `spec/offline_catalog_w28_spec.cr`
- `spec/offline_catalog_w29_spec.cr`
- `spec/offline_catalog_w53_spec.cr`
- `spec/offline_catalog_w54_spec.cr`
- `spec/offline_catalog_w60_spec.cr`
- `spec/offline_catalog_w63_spec.cr`
- `spec/offline_catalog_w68_spec.cr`
- `spec/offline_catalog_w69_spec.cr`
- `spec/offline_catalog_w70_spec.cr`
- `spec/offline_catalog_w71_spec.cr`
- `spec/offline_catalog_w73_spec.cr`
- `spec/offline_catalog_w76_spec.cr`
- `spec/offline_catalog_w77_spec.cr`
- `spec/offline_catalog_w78_spec.cr`
- `spec/offline_catalog_w79_spec.cr`
- `spec/offline_catalog_w80_spec.cr`
- `spec/offline_catalog_w81_spec.cr`
- `spec/offline_catalog_w82_spec.cr`
- `spec/offline_catalog_w83_spec.cr`
- `spec/offline_catalog_w84_spec.cr`
- `spec/offline_catalog_w85_spec.cr`
- `spec/offline_catalog_w86_spec.cr`
- `spec/offline_catalog_w95_tuple_values_spec.cr`
- `spec/offline_materialized_view_transform_w257_spec.cr`
- `spec/offline_materialized_view_w228_spec.cr`
- `spec/offline_mv_materialization_w88_spec.cr`
- `spec/recursive_storage_array_w187_spec.cr`
- `spec/recursive_storage_column_w186_spec.cr`
- `spec/recursive_storage_compact_w188_spec.cr`
- `spec/recursive_storage_reader_budget_w186_spec.cr`
- `spec/recursive_storage_table_w186_spec.cr`
- `spec/recursive_storage_values_budget_w186_spec.cr`
- `spec/static_binary_bulk_table_w247_spec.cr`
- `spec/wide_part_table_low_cardinality_cache_spec.cr`
- `spec/wide_part_table_projection_w87_spec.cr`
- `spec/wide_part_table_w53_spec.cr`
- `spec/wide_part_table_w54_spec.cr`
- `spec/wide_part_table_w59_spec.cr`
- `spec/wide_part_table_w61_spec.cr`
- `spec/wide_part_table_w62_spec.cr`
- `spec/wide_part_table_w63_spec.cr`
- `spec/wide_part_table_w64_spec.cr`
- `spec/wide_part_table_w68_spec.cr`
- `spec/wide_part_table_w69_spec.cr`
- `spec/wide_part_table_w70_spec.cr`
- `spec/wide_part_table_w71_spec.cr`
- `spec/wide_part_table_w73_spec.cr`
- `spec/wide_part_table_w76_spec.cr`
- `spec/wide_part_table_w77_spec.cr`
- `spec/wide_part_table_w78_spec.cr`
- `spec/wide_part_table_w79_spec.cr`
- `spec/wide_part_table_w80_spec.cr`
- `spec/wide_part_table_w81_spec.cr`
- `spec/wide_part_table_w82_spec.cr`
- `spec/wide_part_table_w83_spec.cr`
- `spec/wide_part_table_w84_spec.cr`
- `spec/wide_part_table_w85_spec.cr`
- `spec/wide_part_table_w95_tuple_spec.cr`
- `spec/static_nested_handoff_w248_spec.cr`
- `spec/dynamic_recursive_handoff_w249_spec.cr`
- `spec/dynamic_owned_values_w220_spec.cr`
- `spec/recursive_qbit_static_parts_w231_spec.cr`
- `spec/recursive_qbit_parts_w230_spec.cr`
- `spec/aggregate_count_offline_w177_spec.cr`
- `spec/aggregate_recursive_w224_consumers_spec.cr`
- `spec/aggregate_variant_w225_consumers_spec.cr`
- `spec/aggregate_variant_w225_adversary_spec.cr`
- `spec/aggregate_sum_w223_consumers_spec.cr`
- `spec/aggregate_avg_w227_consumers_spec.cr`
- `spec/simple_aggregate_bulk_consumers_w221_native_spec.cr`
- `spec/simple_aggregate_recursive_w222_part_spec.cr`
- `spec/geometry_recursive_w239_consumers_spec.cr`
- `spec/object_offline_table_w130_spec.cr`
- `spec/compact_typed_w260_spec.cr`
- `spec/compact_typed_w260_adversary_spec.cr`
