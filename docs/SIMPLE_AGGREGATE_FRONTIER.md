# SimpleAggregateFunction paired frontier — W161

Status: VERIFIED within the executed finite UInt64 scalar/Nullable profile
below, not full SimpleAggregateFunction or aggregate execution support.
Baseline: clean
`8032c421a5dd6d297c1562f65cbcb1ed92b985fb`.
Risk: CAUTION (nominal type admission and persisted serialization).
Rollback: one coherent local feature commit after the observed gates; preserve
unrelated edits and do not push or rewrite history.

## Source and admitted boundary

The separate shallow source checkout at
`/Users/sergey/SrcArchives/clickhouse-2026-10-04-depth1-41b7bd50`, revision
`41b7bd50051cc2017fe5ca5505fb35c9dc620000`, defines SimpleAggregateFunction
tag `0x2e`. Its descriptor is function-name String, VarUInt parameter count,
Field parameters, VarUInt argument count and recursive argument descriptors.
Unlike AggregateFunction tag `0x25`, it has no outer version field.
`DataTypeCustomSimpleAggregateFunction.cpp` checks the resolved function
allowlist and requires its result type to equal argument zero's storage type
after removing LowCardinality. The nominal custom name delegates to the
ordinary storage serializer, not an aggregate-state wrapper. Source anchors:
`DataTypesBinaryEncoding.{h,cpp}` and
`DataTypeCustomSimpleAggregateFunction.{h,cpp}`.

Admit one finite, non-parametric, unary profile with exact storage UInt64:
`any`, `anyLast`, `min`, `max`, `sum`, `sumWithOverflow`, `groupBitAnd`,
`groupBitOr`, and `groupBitXor`. Preserve each exact canonical function name,
argument tree and nominal identity. Generic descriptor, value, normalized
bulk and physical-role planning must pair encode/decode for this profile.
Add scalar and outer Nullable public Wide-part writer/reader, table batches
and offline column values for the same profile. Wrapper serialization adds
no physical role/path prefix, but traversal and name budgets still account
for the wrapper and its child. No aggregate execution or merging is added.

Root's bounded stock eligibility probes use separately pinned ClickHouse
26.10.1.1201 build `d9bcb5ab`, not a build of the source snapshot. Native
`min(UInt8)` and `sum(UInt64)` preserve their exact names; `sum(UInt8)` fails
with code 36 because the result widens to UInt64. A table with all nine
outer Nullable profiles passes CREATE/INSERT/literal SELECT/CHECK. These are
eligibility observations, not library serialization or part certificates.

Keep nonzero parameters, zero/multiple arguments, other carriers, other
function names/case/aliases, nested AggregateFunction state arguments and
general aggregate-state serialization rejected. A stock-valid type outside
this profile remains Unsupported, not proof of an invalid ClickHouse type.
Keep Object/JSON declarations and actual arms closed unless separately
qualified. Recursive generic compositions obey their existing constructor,
LC, Variant, Dynamic, roster and budget gates; they do not alone qualify
arbitrary-schema or recursive public Wide-part products. Full family coverage,
remaining types, general MV/projections and performance remain open.
In particular, LowCardinality with a SimpleAggregateFunction child and
SimpleAggregateFunction Map keys retain the existing closed policies. Legal
UInt64-LC siblings are not widened into those distinct products. This slice
qualifies ordinary MergeTree table consumers, not AggregatingMergeTree merge
execution or table lifecycle.

## Design and ownership

Use one immutable `BinarySimpleAggregateType` owner/file for the nine function
identities, canonical names and UInt64 profile. Its public `Function` enum
names are Any, AnyLast, Min, Max, Sum, SumWithOverflow, GroupBitAnd, GroupBitOr,
GroupBitXor. `BinaryDataType.simple_aggregate(function, storage_type)` validates
exact UInt64 and stores one child plus `simple_aggregate_type`; a default
UInt64 argument is allowed. Equality/hash and bounded name rendering retain
the function. `BinaryValue.simple_aggregate(type, child)` retains its exact
nominal type and one exact UInt64 child. Its accessor must not pretend it is
a primitive UInt64 value.
`as_simple_aggregate` returns that typed child, not an untyped scalar.

`SimpleAggregateColumnType` owns exact scalar/Nullable declaration grammar.
Public readers are `read_simple_aggregate_uint64_mark_range` and
`read_nullable_simple_aggregate_uint64_mark_range`. Writer entrypoints are
`write_uint64_simple_aggregate_pair` and its nullable counterpart, receiving
the exact function enum and preserving staged metadata/readback. Table batch
accessors are `simple_aggregate_uint64s_for` and
`nullable_simple_aggregate_uint64s_for`. Primitive UInt64 APIs stay closed.
New helpers have cohesive responsibility and one class per file; do not
duplicate the staged writer or retain borrowed I/O resources.

Root owns this frontier, require graph, serial guarded compiler/native jobs,
hostile review, gate reconciliation and final local commit. Luna owners were
assigned separate nominal codec, Wide consumer and literal oracle/spec files.
Workers preserved other edits and did not run compiler/native jobs, commit or
push. Their implementation and reviews are correlated supporting evidence;
the executed results and scoped certificate below are independently checked
by root.

## Falsifiers, guards and Definition of Done

The strongest failure is silently erasing function identity: min and max have
the same UInt64 payload width, so a roundtrip or CHECK alone can miss a wrong
nominal type. Another risk is wrapper transparency resetting the recursive
budget or allowing unqualified Object/aggregate-state products.

1. Before production edits, root executes literal descriptor admission RED
   through existing decode APIs for all nine names, with primitive UInt64 as
   a passing control. Use the `0x2e` grammar from the pinned source, not new
   production encoders as expected bytes.
2. Root runs focused DEBUG and RELEASE and affected descriptor/value/bulk,
   LC/Variant/Dynamic/physical, typed writer/readback, table/catalog and Object
   refusal regressions. Use serial `run_safe.sh`, an isolated cache,
   SDK26.5, Crystal1.21.0, `--single-module --threads 1`, host linker
   `--link-flags=-fuse-ld=ld`, `--error-trace`; RELEASE adds `--release --no-debug`.
   Require exit 0, zero failures/errors/pending and an exact spec inventory.
3. A separately pinned stock oracle creates native parts with all nine
   scalar/Nullable types and independently authored literal RowBinary values.
   Public library readers must preserve exact declarations, signedness-free
   UInt64 extremes, NULL, full/middle/empty table windows and complete marks.
   Independently library-authored complete parts must stock ATTACH/CHECK and
   match exact names and literal RowBinary bytes in both directions.
4. Attack min-to-max exact metadata and a same-width value mutation with the
   unchanged oracle; CHECK-valid mutants must still be rejected. Test malformed
   function/parameter/arity/storage descriptors, truncation, one-short
   aggregate budgets, primitive-accessor refusal, late unselected mark
   corruption, staged metadata mismatch and existing failed-publication
   destination preservation/cleanup. Zero direct mark ranges remain rejected.
5. Root inspects source and intended diff, runs format/syntax/diff/hygiene
   checks, records observed scope/residual gaps and makes one exact-path local
   commit only after the declared DoD passes. No full-project or performance
   claim follows from an affected gate.

This seal expires on changes to function/argument/identity policy, codecs,
shared budgets, container/Object admission, physical plans, metadata/readback,
selection/publication, upstream source, native runtime/settings or toolchain.
Refresh affected evidence rather than using source identity as runtime proof.

## Executed certificate (2026-10-04 local / 2026-10-05 UTC)

Scoped hostile verdict: ROBUST for the nine exact canonical unary UInt64
identities and scalar/outer Nullable Wide profile only. Root inspected the
nominal codecs, recursive budgets, transparent physical roles and public
consumer/staged publication changes, then reconciled actual execution logs,
current input hashes and native binary outputs independently of Luna's
reports. This is not a full-project test, arbitrary-schema compatibility,
aggregation/merge execution, overall modularization or performance claim.

The baseline literal admission RED executes ten examples: the UInt64 control
passes and the nine independently encoded tag-0x2e descriptors raise the
previous UnsupportedFormatError (exit 1, nine errors). Final current-source
DEBUG passes 31 examples across six unique specs. Affected RELEASE passes
748 examples across the exact 64-spec inventory below, in eight disjoint
groups with counts 50/56/101/58/52/279/100/52. Every counted group exits 0 with
zero failures/errors/pending. The aggregate guard ended before a completed
eighth-group signal; a separately guarded eighth group supplies its 52-example
result. Incomplete attempts and overlapping reruns are not counted. Root
reconciles all 360 source/spec/support inputs before and after the final gates.

Guards cover function/arity/parameter/carrier admission, truncation and trailing
bytes, wrapper-plus-child node/edge/depth/name accounting, typed accessor
refusals, legal recursive codec compositions and retained closed LC-child,
Map-key and Object/JSON policies. Late unselected mark-grid corruption is
rejected before an EOF callback; this is not authentication of every unread
body byte. Direct zero-mark reads retain BoundsError; empty table/SQL windows
are distinct contracts. Staged min-to-max metadata readback refuses the wrong
nominal type. Existing public writer failure, destination-preservation and
cleanup regressions remain in the affected inventory; the private staged
bridge is not itself a publication/cleanup certificate.

Fresh native root:
`/private/tmp/crystal-click-simple-aggregate-w161.UqUkHD`.
The stock producer creates a six-row Wide/LZ4 part with all 19 exact columns
(UInt64 key plus nine scalar and nine Nullable functions), three real marks
and a terminal mark. Independent literal stock RowBinary full/middle/empty
comparisons pass. A literal binary descriptor-header spot-check covers min
and outer Nullable(min), not all nine binary headers. The opt-in public stock
reader spec actually executes two examples with all nine scalar/Nullable
functions. Table scans select three columns per function, preserving the
existing MAX_COLUMNS=16 admission rather than widening it for a fixture.

The independently library-authored eighteen complete parts pass actual stock
ATTACH/CHECK, exact system.columns names/types and 54 literal full/middle/empty
RowBinary comparisons. Values include unsigned extrema, NULL and a distinct
library-only middle value. Public direct reader, table batches/windows and
offline catalog column values are checked by the Crystal driver. A metadata-
only min-to-max copy also ATTACHes and passes CHECK: root directly compares
the complete file rosters and bytes and confirms only columns.txt differs,
with unchanged stored values. The unchanged minimum type oracle rejects it.
A separately authored first-value 0-to-1 minimum part is CHECK-valid but fails
the unchanged original literal-value oracle. This is eighteen qualified
profiles plus two mutant copies (twenty ATTACH/CHECK copies), not twenty
qualified profiles. Root independently compares actual stdout bytes against
its own literals, not just the oracle summary or rejection-marker text.

Runtime: ClickHouse 26.10.1.1201,
build `d9bcb5ab007f0f6299f7f973f2642245bab3d028`, executable SHA256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
The clean shallow source reference `41b7bd50` remains unbuilt and separate.
Root independently checks source cleanliness; the native harness checks HEAD,
runtime version/build/hash and explicit settings, not source-to-runtime build
provenance. All 363 native source/spec/script inputs match their before/after
manifests and the 360 affected-gate inputs; native exit is 0. Part files and
paths are assumed immutable during reads, not race-safe against live mutations.

### Commands and evidence index

Root uses Crystal 1.21.0, SDK26.5, isolated caches, host linker and serial
`/Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh` with a 50-percent
system-free-memory floor. Aggregate compiler/native jobs use 600 seconds /
12288 MiB process-tree RSS; the separate final eighth compiler group uses
300 seconds / 12288 MiB. Compiler arguments are
`spec <exact inventory group> --single-module --threads 1
--link-flags=-fuse-ld=ld --error-trace`; RELEASE adds `--release --no-debug`.
Expected signal: exit 0 and zero failures/errors/pending for each actual group.

Retained root runners are
`/private/tmp/crystal-click-w161.QMXBPc/{run_gates.rb,resume_gate.rb,run_native.rb}`.
The final gate evidence is in its `final-gates/`: `gate-before.json`,
`gate-after.json`, `gate-inventory.json`, `gate-results.json`, `debug-1.log`,
`release-{1..7}.log` and `release-8-resumed.log`. The incomplete release-8.log
is retained but supplies no pass signal. The native wrapper runner/log and
363-input manifests are in `native-final2/`. Root's read-only
`reconcile_final.rb` independently rechecks gate membership/counts, current
hashes, native literals and actual mutant files. Scratch artifacts are refresh
aids, not permanent proof; rerun repository specs/scripts if they disappear.

The observed native job invokes `ruby run_native.rb` under the external guard;
that retained runner captures hashes and invokes the repository shell wrapper.
Equivalent repository-only replay from the repository root:

```sh
env COGNI_RUN_SAFE_MIN_FREE_PCT=50 RUN_SAFE_PASSTHROUGH_STDIO=1 \
  SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  TMPDIR=/private/tmp W161_EXECUTE_AS_ROOT=YES \
  CRYSTAL_BIN=/opt/homebrew/bin/crystal RUBY_BIN=/usr/bin/ruby \
  CLICKHOUSE_BIN=/private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped \
  /bin/bash /Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh \
  /bin/bash 600 12288 scripts/check_simple_aggregate_w161.sh
```

`W161_EXECUTE_AS_ROOT` means parent-agent job ownership, not Unix root. The
wrapper creates a fresh direct /private/tmp child and isolated cache, refuses
existing/symlink output roots and does not nest the guard or remove evidence.
Native `recheck.log`, numbered SQL/stdout/stderr, pins.txt, summary.txt,
wrong-function/value-oracle-rejection.txt and results/crystal/ retain the
execution evidence. The three final harness hashes are:

```text
094ebe560fb3dbc6e5df9d094f2fb417460ab854803fb884b6b05066d56e4dc3 scripts/check_simple_aggregate_w161.cr
46f61b69321723ea61e7275e2e1c60c585ac90851ee95dd0c982b0dec6680ca6 scripts/check_simple_aggregate_w161.sh
3bc2fa13d818321c65e1901605d636faf862765e03f2d1dbaa0ee08bfee54f16 scripts/recheck_simple_aggregate_w161.rb
```

Preparation repaired test/oracle instruments rather than weakening production
guards: an unavailable UInt8 test constructor, physical-role expectations,
typed-child comparison instead of reference equality, an actually truncated
arity fixture, and a conservative name bound instead of assuming exact length.
The retained compile/assertion failure logs document those earlier attempts.
Native attempt CUUvci exceeded the existing sixteen-column table selection
limit; per-function three-column scans fix the fixture. Attempt OG6z36 used a
noncanonical copied part basename; its copy now retains all_1_1_0. Both failed
roots and logs are retained; the fresh UqUkHD run is the counted native result.
Root's initial independent reconciliation expected two native metadata fields
although the query also returns position; correcting that probe to all three
fields passes without changing production, native outputs or their oracle.

Final hygiene checks pass: Crystal formatter on all 31 owned Crystal files,
Ruby and shell syntax, git diff whitespace checks and a bounded credential-
pattern scan over new source/spec/script/example files. No generated binary,
native store or scratch evidence is included in the feature commit.

Remaining wider functions/carriers/parameters/aliases, general aggregate
states, recursive public part products, Compact/layout/version products,
Object/JSON wrapper admission, MV/projections and performance remain open.
The seal's decay conditions above govern refresh; a matching manifest or
commit alone does not substitute for these behavioral gates.

## Exact affected gate inventory

DEBUG uses the first six entries. RELEASE uses all 64 once, split into
consecutive groups of eight; overlapping reruns are not added to the totals.
The stock reader is opt-in: the native oracle separately supplies
`W161_SIMPLE_AGGREGATE_STOCK_WIDE_PART` and requires its two actual examples
to run. Ordinary affected gates do not silently count that native coverage.

```text
spec/simple_aggregate_w161_admission_red_spec.cr
spec/simple_aggregate_w161_core_spec.cr
spec/simple_aggregate_w161_guards_spec.cr
spec/simple_aggregate_w161_recursive_spec.cr
spec/simple_aggregate_w161_stock_reader_red_spec.cr
spec/simple_aggregate_w161_wide_spec.cr
spec/interval_w160_admission_red_spec.cr
spec/interval_w160_core_spec.cr
spec/interval_w160_guards_spec.cr
spec/interval_w160_recursive_spec.cr
spec/interval_w160_stock_reader_red_spec.cr
spec/interval_w160_wide_spec.cr
spec/binary_value_codec_w117_spec.cr
spec/binary_scalar_types_w119_spec.cr
spec/binary_bulk_w122_spec.cr
spec/physical_stream_plan_w125_spec.cr
spec/binary_low_cardinality_w141_spec.cr
spec/binary_low_cardinality_storage_w142_spec.cr
spec/binary_low_cardinality_bulk_w143_spec.cr
spec/binary_low_cardinality_float_bulk_w144_spec.cr
spec/binary_low_cardinality_physical_w145_spec.cr
spec/binary_variant_value_w147_spec.cr
spec/binary_variant_value_w147_adversary_spec.cr
spec/binary_variant_bulk_w148_spec.cr
spec/binary_variant_bulk_w148_adversary_spec.cr
spec/binary_variant_physical_w149_spec.cr
spec/binary_variant_physical_w149_adversary_spec.cr
spec/binary_bulk_physical_prefix_w151_spec.cr
spec/binary_dynamic_descriptor_w152_spec.cr
spec/binary_dynamic_value_w153_spec.cr
spec/binary_dynamic_bulk_plan_w154_spec.cr
spec/binary_dynamic_bulk_plan_w154_adversary_spec.cr
spec/binary_dynamic_bulk_values_w155_spec.cr
spec/binary_dynamic_bulk_values_w155_adversary_spec.cr
spec/binary_dynamic_bulk_shared_context_w155_spec.cr
spec/binary_dynamic_physical_w156_spec.cr
spec/binary_dynamic_physical_w156_adversary_spec.cr
spec/binary_dynamic_statistics_offsets_w157_spec.cr
spec/wide_part_writer_typed_spec.cr
spec/wide_part_writer_nullable_temporal_spec.cr
spec/wide_part_writer_typed_mark_readback_spec.cr
spec/wide_part_writer_metadata_w150_spec.cr
spec/wide_part_writer_datetime_spec.cr
spec/wide_part_writer_date_spec.cr
spec/nullable_temporal_scan_spec.cr
spec/datetime_scan_spec.cr
spec/fixed_numeric_scan_spec.cr
spec/timezone_temporal_admission_w104_spec.cr
spec/timezone_temporal_consumers_w104_spec.cr
spec/timezone_temporal_writer_w104_spec.cr
spec/offline_catalog_spec.cr
spec/multicolumn_table_scan_spec.cr
spec/streaming_scan_spec.cr
spec/object_document_schema_w131_spec.cr
spec/object_document_schema_w140_spec.cr
spec/object_declared_low_cardinality_w146_spec.cr
spec/object_low_cardinality_consumers_w146_spec.cr
spec/object_declared_variant_w151_spec.cr
spec/object_variant_consumers_w151_spec.cr
spec/object_recursive_dynamic_w159_spec.cr
spec/object_recursive_dynamic_w159_adversary_spec.cr
spec/object_temporal_w139_root_spec.cr
spec/object_recursive_consumers_w140_spec.cr
spec/wide_part_writer_spec.cr
```
