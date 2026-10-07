# Recursive Nested specialized storage frontier — W201

Status: VERIFIED within the executed finite recursive bulk corpus and four
stock-created Nested/Array(Tuple) LC+String profiles in each mode.
Baseline: `792c00a98901bc8ee9f0d28b5439005fae0d15c4`.
Risk: CAUTION (recursive storage admission). Rollback: one scoped local commit;
no push and no changes to the pinned ClickHouse checkout or executable.

## Contract

Compose nominal Nested with the existing LowCardinality, Variant and Dynamic
storage owners. Nested owns the outer sizes and an implicit named Tuple;
every sibling field uses the same flattened-element domain. Reuse the Array
cardinality transformation, leaf codecs, dictionary state and Dynamic site
plans rather than adding a serializer for each type product. Preserve the
nominal descriptor, escaped stream paths, aggregate caller budget and explicit
String profile in both directions.

The previous blanket guard rejected even unrelated specialized siblings.
Removing it alone is insufficient: the LowCardinality staging and occurrence
census still have Array-only branches. This is an implementation boundary,
not evidence that ClickHouse forbids these Nested fields.

Admission: the shared recursive logical bulk read/write and physical planners
now compose otherwise-admitted Nested+LC/Variant/Dynamic descriptors. The
executed corpus includes ordinary/shared Dynamic values, a Nested+LC actual
arm and Object per-path composition. This is not qualification of every legal
recursive product or every native layout. The stock probe below covers LC
and direct String siblings, not native Variant/Dynamic parts.

Rejected/unqualified: existing illegal Nullable/Variant/LC child edges,
JSON-as-Dynamic-actual and QBit wrapper guards, legacy Dynamic layouts,
arbitrary dictionary schedules, flattened sibling Nested groups and general
Compact complete parts. A bulk certificate does not widen the narrower
top-level Wide Nested writer or prove arbitrary-schema complete-part support.
Those remaining public storage adapters, full types and MV/projections stay
required. Performance and memory optimization remain deferred.

Recursive composition must carry a storage context, not only a value codec:
the child occurrence domain, stream identity/profile, prefix/body lifetime,
site state and one cumulative budget. A container transforms that context and
delegates to its child owner. Empty ranges and selected windows remain part
of the contract. This is the modularization boundary; a Cartesian registry
of composite serializers would duplicate the existing leaf implementations.

## Anchors and consumers

The clean depth-one source reference is
`/Users/sergey/SrcArchives/clickhouse-2026-10-05-depth1-ef037e60`, revision
`ef037e60fc7f5654c8c80eefb8be82e3c56f9a67`, unbuilt. Executed stock is separately
pinned to 26.10.1.1201, build `d9bcb5ab007f0f6299f7f973f2642245bab3d028`, binary SHA256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
`SerializationArray.cpp:352-395` delegates the transformed child range and
still calls the child serializer for an empty element range to form Compact
marks. `SerializationLowCardinality.cpp:230-267` retains dictionary state and
explicitly handles skipped granules and runs of empty arrays.
`DataTypeNested.cpp:51-75,234-249` constructs an Array of the named Tuple
and retains the nominal custom name; it has no blanket specialized-field
restriction. `flatten_nested=0` preserves that column. The default flattening
normalization is a different storage contract, not covered by this slice.

The bounded consumer search was
`rg -n 'reject_unqualified_specialized_bulk!' src spec`: eight call sites in
BinaryBulkTypePlan (one), BinaryBulkPhysicalPlan (three),
BinaryDynamicBulkPlan (three), ObjectSharedPathCodec (one), plus the owner.
The ordinary bulk, Dynamic physical and Object per-path walkers already pair
Array and Nested. Missing LC branches are in
BinaryBulkLowCardinalitySiteEncoder and
BinaryBulkLowCardinalityOccurrenceSchedule. Legacy refusal assertions need
replacement with positive composition and retained illegality/corruption
checks, not wholesale deletion of their adversarial coverage.

## Execution and falsifiers

1. Inspect source legality and the complete consumer inventory. The existing
   14-file Nested/specialized baseline passed 105 examples, zero failures,
   errors or pending, actual guarded exit 0 before any production edits.
2. Root runs the new minimal positive
   `spec/binary_nested_specialized_w201_spec.cr` on unchanged production.
   Expected RED: runtime refusal of a legal Nested+LowCardinality value,
   not a compiler or fixture error.
   Observed: one example, one runtime error, guarded actual exit 1;
   `BinaryBulkTypePlan` reached the blanket `UnsupportedFormatError` for
   `Nested(label LowCardinality(Nullable(String)))` before encoding.
3. Extend existing LC staging/census to the shared Nested element domain and
   remove only the now-covered blanket guards. Do not reset budgets at a
   container/site boundary or erase Nested identity into Array(Tuple).
4. Root runs focused and affected rosters serially in DEBUG and RELEASE.
   Include both String profiles, empty element marks, later windows, shared
   and ordinary Dynamic arms, nested wrappers and unrelated LC siblings.
5. Qualify the physical contract against fresh retained stock-native observations,
   with independent literal values and raw command/file provenance. If a
   complete public Object-part path is exercised, require native ATTACH/CHECK
   plus independent direct-path reads; otherwise keep that claim unqualified.
6. Attack malformed sizes, truncated/extra LC values, wrong site grids,
   nominal substitution, budget boundaries and nonzero-origin reads. Seed a
   defect in the new census branch and require the unchanged test to reject.

Strongest failure: encoder and decoder agree on an incorrect flattened LC
schedule, especially after an empty mark. Independent size/count literals,
stock reads and a deliberately altered size lane must discriminate it.
Stop and revise the contract if the stock source/layout contradicts the
Array/implicit-Tuple carrier law; do not weaken the oracle to obtain green.

## Verification boundary

The same exact 144-file affected roster, including all nine new W201 examples,
passes 944 DEBUG and 944 RELEASE examples, zero failures/errors/pending, actual
serial guarded exits 0. The final 949-file source/spec identity is
`5aec2b7e12764bf791d9a8c43e748a56bc4cf7e48a9e8d2948982685494f3b05` and remained
unchanged across both suites, helper builds and stock probes. Earlier focused
nine-example DEBUG checkpoints predate one additional off-window shape
assertion; the final affected runs are the certificate for the final spec.

Fresh prebuilt DEBUG and RELEASE helpers each decode four stock-created Wide
profiles: Nested and Array(named Tuple), each with LC(Nullable(String)) plus
a direct String sibling under single_stream/with_size_stream. Eight literal
rows form four real marks [2,2,2,2]; system.parts reports five marks including
the final index mark. Full, first-empty, later-populated, final-populated and
zero-end windows preserve nominal type, NULL, empty/default and repeated keys.
The actual hashed data/mark file roster matches payload roles plus the PK lane.
Root authenticates 32 independent native literal observations per mode, raw
process exits and capture digests; all 80 stock part files per mode remain
unchanged. Native values and helper physical role/window reports agree across
modes. These are stock-to-kernel reads, not library-written complete parts.

String propagation is a separate contract: Array/Tuple forwards the selected
profile, but SerializationLowCardinality.cpp:158-161 selects its dictionary
serializer with default settings. The independent direct String sibling proves
the additional string_sizes lane, rather than assuming the LC dictionary
inherits that profile.

The unchanged nine-example spec rejects a seeded removal of the new Nested LC
census branch: five runtime errors, actual exit 1; the production branch was
restored before the final suites. Independent malformed size/index counts,
an off-window malformed size lane, tiny byte-budget and existing illegal
Nullable/JSON/QBit boundaries are exercised. Root additionally rejects six
mutated native/report records (duplicate pins/parts, wrong native literal,
bad profile/row/window census). A prebuilt helper given an altered literal
manifest rejects the wrong expected NULL state at the first populated mark,
actual exit 1, without changing any source part bytes.

Scoped hostile verdict: ROBUST for the executed kernel corpus and native LC
profiles. Correlated Luna reviews are not independent evidence. Exact commands,
roster, hashes and retained capture paths are indexed in
`.landmark/evidence/nested-specialized-bulk-w201.json`; temporary captures must
be refreshed if absent. Remaining qualifications include the public top-level
Nested writer, native specialized complete-part writes/ATTACH/CHECK, wider
dictionary/legacy/Compact/flattened layouts, exact specialized budget boundary
and LC-inside-Variant-arm cases. No full-suite, all-types, performance or
repository-wide class-decomposition claim is made.

All compiler/native jobs run serially through the unchanged
`/Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh`, with
`COGNI_RUN_SAFE_MIN_FREE_PCT=50 RUN_SAFE_PASSTHROUGH_STDIO=1`, timeout 600 seconds,
process-tree limit 12288 MiB, `TMPDIR=/private/tmp`, isolated Crystal cache and
the selected Xcode SDK. Crystal uses `--single-module --threads 1
--link-flags=-fuse-ld=ld --error-trace`; RELEASE adds `--release`.
Native children retain their actual exit status and use the existing bounded
supervisor. A metadata/checksum-only result is not semantic compatibility.

DoD: the declared 144-file affected roster, including the focused corpus,
passes both modes with actual exits 0; the source/native contract agrees with
literal and retained observations;
the seeded schedule defect fails; format and `git diff --check` pass; root
hostile review is ROBUST within the tested contract. Record exact final
commands, rosters and residuals when these checks have actually run.
Evidence decays after relevant source, child legality, state, layout, caller
budget, fixtures, native/runtime or transport changes. The full active goal
is not complete until all types, MV/projections and the later speed gate are
established.
