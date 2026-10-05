# SimpleAggregateFunction Decimal paired frontier — W169

## State, authority and problem

Status: VERIFIED within the canonical stored-value profile below (2026-10-05).
Production baseline: `f79b064`. This is not aggregation execution, all-type
completion or runtime qualification of the newly cloned source tree.
Remaining paired types and general MV/projection support precede memory/perf.
Risk: CAUTION (descriptor identity, fixed-width dispatch and staged publication).
Root owns serial guarded jobs, independent evidence reconciliation and git.
Luna owns disjoint implementation/qualification paths only after the measured
construction law and behavioral RED authorize them. No push or optimization.
Rollback: revert the atomic W169 commit; preserve unrelated changes.

Ordinary Decimal and numeric/text SAF exist, but that does not pair Decimal
SAF. Precision, scale, wire width, canonical function and outer shape must
survive the complete descriptor/value/bulk/Wide/table/offline path. A raw
integer having the same byte width is not the same capability.

## Anchors and admitted boundary

Source: clean unbuilt shallow
`/Users/sergey/SrcArchives/clickhouse-2026-10-05-depth1`, revision
`e9b645ed83ad3c07b64f09fbd014e8f770d8691b`.
Executed stock remains separately pinned to `26.10.1.1201`, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, SHA256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
`DataTypeCustomSimpleAggregateFunction.cpp:151-165` compares the aggregate
result with a factory-reconstructed storage type. Root source inspection and
Luna inventory agree that `DataTypesDecimal.cpp:34-40` equality compares the
concrete Decimal carrier and scale, deliberately ignoring precision.
`AggregateFunctionSum.h:480-488` builds the result with its carrier's maximum
precision. The source law agrees with 414 executed pinned-stock declarations:
any/anyLast/min/max and sumWithOverflow across all four canonical carriers;
sum only with Decimal128/256; no groupBitAnd/Or/Xor. Printed original P/S must
not be replaced with the result type's widened precision.
`DataTypeDecimalBase.h:180-195` requires S<=P and infers width from SQL precision;
the existing binary Decimal descriptor grammar retains wider raw coordinates.

Construction probe: `/private/tmp/crystal-click-w169.qJhVfg/probe_decimal_law.rb`
through the root resource guard, actual child/guard exit 0. P roster is
1/9/10/18/19/38/39/76; S is 0/min(3,P)/P (deduplicated), all nine functions and
both shapes. There are 254 accepted and 160 type-rejected declarations, zero
law/name mismatches, zero unexpected runtime failures. Version and
system.build_options VERSION_GITHASH match the pinned runtime. Raw SQL,
stdout/stderr and statuses are retained in `construction-decimal/`.
Root executed `spec/simple_aggregate_w169_admission_red_spec.cr` before
production edits: 5 examples, 3 assertion failures, 0 errors/pending, child
exit 1, guard exit 0, all 306 inputs unchanged. The UInt64 control and narrow
sum/bitwise/wrapper/wire-coordinate negatives pass. Compiler errors are not
counted as RED.

Frozen ownership: descriptor worker owns `binary_simple_aggregate_type.cr`,
`binary_data_type.cr`, `simple_aggregate_column_type.cr` and new W169 core specs;
runtime worker owns `wide_part.cr`, `wide_part_writer.cr`, `wide_part_table.cr`,
`offline_table.cr`, `wide_part/simple_aggregate_column_reader.cr`, new dedicated
Decimal storage-plan/staged-validator files, their root requires, and W169
runtime specs. Qualification worker owns W169 script/support/native-fixture
spec paths only. Root owns this SDD/status, execution and reconciliation.
No ordinary Decimal inference, generic MV materialization or public primitive
admission is authorized by this slice.

Admitted complete-part surface: source/stock-eligible canonical unary,
non-parametric functions with bare canonical `Decimal(P, S)`, all four
ordinary Decimal widths, scalar and outer Nullable. Native witnesses must
include width boundaries and non-maximal precision, not only aliases whose
precision equals the family maximum. The descriptor kernel additionally
preserves explicit wire-width identity; a noncanonical wire descriptor must
not silently acquire SQL-normalized physical admission.

The API accepts canonical P=1..76 and S=0..P. Any/anyLast/min/max and
sumWithOverflow admit all four carriers; sum admits Decimal128/256 only.
Native complete-part witnesses cover the finite 23 P/S coordinates described
above, not every possible precision/scale. Algorithmic core tests exercise
27,018 function/P/S cases (3,002 P/S pairs times nine functions); this is not
27,018 spec examples or independently qualified complete parts.

Rejected before physical admission: narrow Decimal sum, Decimal bitwise
functions, noncanonical wire-width/P coordinates and S>P. Guard-only or
unqualified: aliases, parameters, inner Nullable/LC, recursive whole-part
products, temporal SAF, AggregateFunction state serialization, Compact and
aggregation execution.
Some excluded profiles may be valid ClickHouse types; they need their own
paired certificate. Existing 118 numeric pairs and four-function text law,
ordinary Decimal accessors and inferred writer admission must not widen.

## Design laws and falsifiers

- Reuse existing Decimal leaf descriptors/codecs and value carriers; retain
  exact precision/scale/width/function/shape. No class per function/type pair.
- Binary width and printed SQL precision are distinct coordinates. Probe
  stock normalization rather than treating equal display names as identity.
- Validate declared Decimal parameter range before staging; retain raw signed
  coefficient bits without adding an unproved abs(value)<10^P restriction.
  Validate each completed
  mark through the exact public semantic reader before publication.
- Nullable consumes its full nested fixed-width payload, even beneath NULL;
  whole-intersecting-mark budgets precede callbacks and visible windows.
- Primitive/ordinary Decimal accessors refuse nominal SAF wrappers. Exact
  SAF APIs remain separate from inferred typed-writer dispatch.
- Strongest failure: lost Decimal parameters or physical width, hidden by
  same-width integer roundtrips. Asymmetric literal RowBinary, metadata-only
  same-width precision/scale mutants and primitive-accessor negatives must
  discriminate it. CHECK acceptance alone does not compare original values.

## Executed order and DoD

1. Read exact CH function/result/equality laws and run pinned stock construction
   probes. Retain raw SQL/stdout/stderr, acceptance and canonical descriptors.
2. Run behavioral RED through existing APIs on unchanged production. Compiler
   errors do not count as behavioral failure; existing unsupported admission
   must be observed by executed assertions.
3. Freeze the eligible law and exact file ownership; implement paired core and
   public runtime consumers using cohesive existing/dedicated owners.
4. Execute focused DEBUG and bounded affected RELEASE regressions, including
   existing Decimal, numeric/text SAF, table/offline and staged-readback guards.
5. Execute independent stock-authored and library-authored complete Wide/LZ4
   fixtures, actual ATTACH/CHECK, exact types and full/middle/empty RowBinary.
6. Root seeds separate scalar/Nullable semantic-guard bypasses, requires
   unchanged tests to fail, restores exact source, reruns green and performs
   hostile self-review.
7. Reconcile actual counts, disjoint rosters, hashes and intended diff; update
   this SDD and PROJECT_STATUS, then commit exact paths locally, no push.

DoD signal: nonzero actual executed tests with zero failures/errors/pending,
actual child/guard exit 0, unchanged inputs, source/stock identities separated,
literal whole-part controls and a scoped ROBUST hostile verdict. Exact rosters
and commands below are reconciled from executed gates, not planned counts.
Root runs one compiler/native job at a time through `run_safe.sh`, isolated
caches, one Crystal compiler thread and the host linker. Formatter, Ruby/Bash
syntax and `git diff --check` are additional structural checks, not substitute
compatibility evidence. Scratch root: `/private/tmp/crystal-click-w169.qJhVfg`.

## Implemented consumers and architecture

The public reader has exact `read_simple_aggregate_decimal{32,64,128,256}_raw_mark_range`
and `read_nullable_simple_aggregate_decimal{32,64,128,256}_raw_mark_range`
methods. Callers provide function/P/S; returned coefficients are Int32, Int64,
Int128 or Decimal256Value, with the matching nullable shape. Explicit pair
writers have corresponding `write_uint64_simple_aggregate_decimal{width}_pair`
and `write_uint64_nullable_simple_aggregate_decimal{width}_pair` methods.
They take raw coefficient slices, function, scale and named precision.
Batch accessors, table windows and offline column `.values` use the exact
descriptor rather than substituting the child's raw integer name.

One 119-line `SimpleAggregateDecimalStoragePlan` owns exact declaration/carrier
admission. One private 171-line `StagedSimpleAggregateDecimalPartValidator`
owns public semantic readback, row comparison, marks and primary index checks.
Each has its own file; neither retains readers/buffers/callbacks after return.
Existing fixed-width codecs, metadata/checksums and publication owners are
reused. This is new capability ownership, not a behavior-neutral extraction
certificate. Reader/writer/table facades remain 16,134/25,536/7,095 lines;
the overall responsibility-level decomposition remains unfinished.

## Final executed evidence

Three disjoint groups pass in both DEBUG and RELEASE: 206 examples per mode,
33 unique specs per mode. Every counted positive child and resource guard
exits 0, with zero failures/errors/pending and unchanged inputs. Names below
denote `spec/<name>.cr`; the DEBUG and RELEASE rosters are identical.

1. **Core/runtime — 52 examples, nine specs:**
   `simple_aggregate_w169_admission_red_spec`, `simple_aggregate_decimal_w169_spec`,
   `wide_part_simple_aggregate_decimal_w169_spec`, `simple_aggregate_w168_core_spec`,
   `simple_aggregate_w164_core_spec`, `simple_aggregate_w163_core_spec`,
   `simple_aggregate_w161_guards_spec`, `simple_aggregate_w161_recursive_spec`,
   `binary_parameter_owners_w119_spec`.
2. **Decimal/writer regressions — 53 examples, ten specs:**
   `decimal_column_type_w102_spec`, `decimal_precision_consumers_w102_spec`,
   `decimal_precision_admission_w102_spec`, `wide_part_writer_decimal_precision_w102_spec`,
   `wide_part_writer_typed_spec`, `wide_part_writer_typed_mark_readback_spec`,
   `wide_part_writer_leaf_seam_spec`, `wide_part_writer_plan_owners_w90_spec`,
   `staged_typed_numeric_validator_w162_spec`, `writer_infrastructure_refactor_root_spec`.
3. **SAF/catalog/projection/MV consumers — 101 examples, 14 specs:**
   `simple_aggregate_w161_core_spec`, `simple_aggregate_w161_wide_spec`,
   `simple_aggregate_w163_wide_spec`, `simple_aggregate_w164_wide_spec`,
   `simple_aggregate_w168_wide_spec`, `binary_value_codec_w117_spec`,
   `binary_bulk_w122_spec`, `bulk_nominal_w122_spec`, `offline_catalog_w76_spec`,
   `offline_catalog_w77_spec`, `offline_catalog_projection_w87_spec`,
   `wide_part_table_projection_w87_spec`, `offline_mv_materialization_w88_spec`,
   `offline_tui_page_source_spec`.

The independent native gate executes two examples, not an absent opt-in suite.
Pinned stock constructs one 255-column Wide/LZ4 part (UInt64 key plus 254
accepted Decimal SAF profiles) from literal RowBinary. Crystal reads all 254
profiles through public table windows, using bounded selected-column groups.
Library-owned writers independently generate 254 complete parts. Stock
ATTACH/CHECK accepts each, exact type/row/mark metadata matches, and all 762
full/middle/empty RowBinary windows match independently retained signed
literal coefficients. All 160 refused profiles leave empty output parents.
Six asymmetric rows include full signed-carrier extrema; nullable row four is
NULL. Raw coefficient bits are preserved even outside text-domain 10^P bounds;
this does not claim text INSERT casting or aggregation semantics.

Three intentional parts pass stock CHECK but fail the unchanged original
oracle: same-width P=19->20, S=3->4, and first coefficient 0->1. Metadata-only
controls change only columns.txt; the coefficient control retains the exact
nominal type. Root independently recomputes the laws, descriptor bytes, SQL,
process statuses, complete-part metadata, literal windows and mutant diffs,
without importing production or the worker oracle: 7,778 checks over 2,319
raw process statuses match. CHECK is not an original-value/type certificate.

Separate scalar and Nullable comparison-loop bypasses each produce the
intended assertion: six examples, one failure, zero errors/pending, child
exit 1, guard exit 0. Neither compiler errors nor arbitrary nonzero statuses
count as RED. The validator is restored to SHA256
`519a969d606e2a7ba385d61ab961596fc7ee5590b85b4a962ea05410dccca2d4`;
the final restored runtime rerun passes all six examples. Final root
reconciliation confirms all 344 positive/native source/spec/support/page/script
inputs match current files and both modes have the same disjoint roster.
An earlier macro-local compile failure and pre-final candidate runs are
excluded from the positive and behavioral-control counts.
Root also passes Crystal format checks for the exact changed source/spec
paths, `ruby -c scripts/recheck_simple_aggregate_w169.rb`,
`bash -n scripts/check_simple_aggregate_w169.sh` and `git diff --check`.

Commands/evidence: scratch root `/private/tmp/crystal-click-w169.qJhVfg`;
native root `/private/tmp/crystal-click-w169.native-qJhVfg-1`.
Each compiler group ran:

```sh
env COGNI_RUN_SAFE_MIN_FREE_PCT=50 RUN_SAFE_PASSTHROUGH_STDIO=1 \
  SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk TMPDIR=/private/tmp \
  /bin/bash /Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh \
  /usr/bin/ruby 600 12288 /private/tmp/crystal-click-w169.qJhVfg/run_gate.rb \
  <fresh-label> <debug|release|red> <exact spec paths from the roster above>
```

The runner uses `/opt/homebrew/bin/crystal spec --single-module --threads 1
--link-flags=-fuse-ld=ld --error-trace`, with isolated caches; RELEASE adds
`--release --no-debug`. Final labels are `core-runtime-debug`,
`decimal-writer-debug-fixed`, `saf-consumers-debug`, `core-runtime-release`,
`decimal-writer-release`, `saf-consumers-release`,
`scalar-comparison-bypass-red`, `nullable-comparison-bypass-red`, and
`restored-runtime-debug`. The last three select only the runtime spec.
Before/after hash maps, actual logs and child results are retained per label.

Native uses the same guard/environment with `1200 12288
/private/tmp/crystal-click-w169.qJhVfg/run_native_gate.rb native-part-gate
/private/tmp/crystal-click-w169.native-qJhVfg-1`. That wrapper executes
`scripts/check_simple_aggregate_w169.sh` with root authority, pinned executables
and a fresh native root. Read-only independent reconciliation commands are
`/usr/bin/ruby /private/tmp/crystal-click-w169.qJhVfg/reconcile_native_root.rb`
and `/usr/bin/ruby /private/tmp/crystal-click-w169.qJhVfg/reconcile_final_gates.rb`.

Scoped hostile verdict: ROBUST for this exact canonical stored-value frontier,
not all type/layout products, stock reader speed, or the unbuilt e9 source.
Staged certification checks visible values/NULL semantics, marks/index,
metadata and raw lengths, not content hashes or canonical bytes beneath NULL.
The W88 MV regression remains the UInt64/String identity profile; it is not
a Decimal SAF MV certificate. W169's independently typed projection-child
read is not general projection generation or planning. No benchmark or
power-loss/crash-recovery certificate is claimed.

## Continuity and refresh

W169 is closed within its admitted profile. Next SAF lane is temporal
carriers, requiring separate construction/result-type laws before admission;
AggregateFunction states, shared Nested offsets, broader physical products,
general MV/projections and architectural decomposition remain open.
Source or binary drift, changed Decimal/SAF codecs, nominal dispatch, budgets,
staged selectors, settings or toolchain reopens the affected certificate.
Temporary evidence may decay: missing logs/fixtures require rerunning the
recorded roster and native oracle, not trusting counts. Overall
all-type/MV/projection/performance goal stays active; memory/perf is deferred.
