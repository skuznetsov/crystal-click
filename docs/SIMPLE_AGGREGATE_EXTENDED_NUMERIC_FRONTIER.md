# SimpleAggregateFunction extended numeric paired frontier — W164

## State and scope

Status: VERIFIED within the finite paired profile below. Baseline:
`a61aa14`. The full goal remains paired ClickHouse storage types and MV/projection
support before memory/performance optimization. This slice completes the raw
numeric carrier family for the nine canonical W163 functions; it does not
complete SimpleAggregateFunction, aggregate states or aggregate execution.

Risk: CAUTION (serialization admission and semantic writer/readback dispatch).
Rollback: revert the eventual atomic W164 commit; preserve unrelated work.
Root owns serial guarded jobs and independent review. Luna owns disjoint core,
runtime and native-oracle files. No dependency, remote, production-server or
performance change is authorized by this slice.

## Anchors and admitted frontier

Fresh comparison source is the unbuilt shallow checkout
`/Users/sergey/SrcArchives/clickhouse-2026-10-04-depth1-41b7bd50`, commit
`41b7bd50051cc2017fe5ca5505fb35c9dc620000`. Executed stock is separately pinned
to `26.10.1.1201`, build `d9bcb5ab007f0f6299f7f973f2642245bab3d028`, binary SHA256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.

The existing W163 nominal and column-plan owners admit ten standard carriers.
The generic logical codecs already encode raw wide integers and BFloat16, but
that is not evidence for nominal public SimpleAggregateFunction part consumers.
W163's literal 270-query stock probe includes these five additional carriers;
W164 refreshes their 90 function/carrier/shape constructions independently.

`DataTypeCustomSimpleAggregateFunction.cpp:151-165` requires aggregate result
type to equal child storage after LC removal. `AggregateFunctionSum.cpp:20-48`
uses nearest-field types for sum and the same child for sumWithOverflow.
`Core/Field.h:222-240` keeps UInt128/256 and Int128/256 unchanged but promotes
BFloat16 to Float64. `AggregateFunctionBitwise.cpp:343-353` dispatches integers.

| Additional child | any, anyLast, min, max, sumWithOverflow | sum | groupBitAnd/Or/Xor |
| --- | --- | --- | --- |
| UInt128, Int128, UInt256, Int256 | yes | yes | yes |
| BFloat16 | yes | no | no |

The extension adds 41 scalar pairs, 82 with outer Nullable. Together
with W163 this is 118 scalar pairs / 236 scalar-and-Nullable profiles. This is
a finite matrix, not a claim about all functions, parameters, aliases or types.

Exact identity is `{canonical function, exact child carrier, outer shape}`.
UInt128/Int128 use Crystal primitive values. UInt256/Int256 use their existing
distinct low/high raw-limb structs; BFloat16 uses BFloat16Value raw bits, not
Float32 arithmetic or UInt16 semantic accessors. Existing UInt64 defaults and
selector hooks remain unchanged. Primitive APIs stay closed to nominal wrappers.

Rejected/guard-only: BFloat16 sum and bitwise pairs, unsupported functions,
parameters, arity, inner Nullable/LC, Bool, Decimal and other semantic carriers;
additional recursive whole-part products, Compact and aggregate state layouts.
Some of these are legal CH profiles outside this certificate. Existing W163
admission remains unchanged. No aggregate calculations are performed.

## Execution plan and falsifiers

1. Write new W164 descriptor/value/bulk and public part specs, then execute
   actual RED on unchanged production. Compiler failure is not the RED signal.
2. Extend the existing owners in `binary_simple_aggregate_type.cr`,
   `simple_aggregate_column_type.cr` and `binary_data_type.cr`. Reuse the existing
   `binary_data_type_codec.cr` recursive child codec without editing it.
   Preserve borrowed budgets and exact child tags.
3. Extend the five semantic carriers in `wide_part.cr`, `wide_part_writer.cr`,
   `wide_part_writer/typed_mark_readback.cr`, `wide_part_table.cr` and
   `offline_table.cr`. Inventory branch precedence before edits: BFloat16 and
   raw-wide branches must not reject valid wrappers or erase ordinary identity.
4. Run focused DEBUG and affected RELEASE tests serially with isolated caches,
   SDK 26.5, Crystal 1.21, host linker and a root-owned resource guard.
5. Execute the new stock oracle against all 82 additional independently authored
   scalar/Nullable parts: actual ATTACH/CHECK, exact types and independent literal
   full/middle/empty RowBinary windows. Read a separately stock-authored Wide part.
6. Attack signed/unsigned 128- and 256-bit confusion, BFloat16/UInt16 confusion,
   high-limb truncation, raw NaN/negative-zero/subnormal bits, primitive accessors,
   null maps/placeholders, staged readback selectors and pre-publication refusal.
   CHECK-valid nominal/value mutants must fail the original unchanged oracle.
7. Root reconciles actual logs, input hashes, test membership and intended diff;
   perform hostile review and make one exact-path local commit after green DoD.

DoD commands: focused `crystal spec` for the new W164 core/wide specs plus W163,
W161, W162 and existing raw-wide/BFloat16 writer/consumer guards; affected
disjoint RELEASE groups; `scripts/check_simple_aggregate_w164.sh`; formatter,
syntax and `git diff --check`. Positive evidence requires executed nonzero
examples, zero failures/errors/pending, actual process and resource-guard exit 0,
and unchanged before/after inputs. Exact commands/counts are recorded only after
execution. Source construction alone is not a complete-part certificate.

Strongest likely failure: a correct descriptor is routed through an ordinary
wide-integer/BFloat16 branch, which either refuses valid staged readback or
silently reinterprets an equal-width child. Literal multi-limb bytes, exact wrong
carrier refusals and independent stock value/type oracles discriminate it.

## Continuity and decay

Current frontier: W164 core/runtime/native qualification passes in its finite
matrix; other aggregate carriers and state families remain open. Evidence root:
`/private/tmp/crystal-click-w164.0rWaKa`. No broad completion is claimed.

Any changed carrier law, source, serializer, semantic dispatch, staged selector,
stock executable or evidence input reopens its affected certificate. Fresh
source and executed binary remain separate provenance. Remaining aggregate
families, broader layouts, MV/projections and overall modularization remain
open; memory/performance is deferred.

## Observed probes before implementation

The root-owned pinned-stock construction probe executed all 90 literal
function/carrier/shape declarations: 82 accepted, eight rejected, zero
eligibility mismatches. This confirms the 41 additional scalar pairs and their
outer Nullable forms, not complete-part interoperability. The source checkout
remains unbuilt and distinct from this executable.

`core-red` executed the new four descriptor/value/bulk examples on unchanged
production: four expected missing-admission runtime errors, exit 1, zero pending;
all 300 before/after inputs match. The root gate's RED expectation and resource
guard exit 0. The earlier combined `focused-red` did not execute examples:
Crystal 1.21 LLVM validation reported `GEP into unsized type` in generic reader
closures. That compiler-only failure is excluded from behavioral evidence.
The four executed failures authorize implementation; public runtime paths still
require their actual post-implementation tests and independent stock oracle.

The initial post-implementation focused DEBUG gate passes 59 examples, including
an exact-restored semantic reader gate after a four-failure carrier-bypass
control. The first eight affected RELEASE groups pass 765 examples. These are
intermediate results, not final-source certificates: the ninth group executes
51 examples and exposes two genuine regressions in the existing W35/W36
inferred-writer refusal tests. Adding five carriers to `typed_type_name` widened
the public inferred writer because that map was shared with SAF preflight.
The corrective boundary is to retain the original inferred map and use the
existing exact SAF carrier owner for semantic preflight. Do not revise the
legacy refusal tests to accept the unintended widening. All final positive
gates must run again after the correction; failed/intermediate jobs are not
counted as final positive evidence.

## Final execution certificate (2026-10-05)

Root executes `final-focused-green` and `final-focused-restored`: each passes
60 DEBUG examples in the same ten unique specs, with zero failures/errors/pending,
actual child exit 0 and resource-guard exit 0. The compiler arguments are:

```sh
crystal spec \
  spec/simple_aggregate_w164_core_spec.cr \
  spec/simple_aggregate_w164_wide_spec.cr \
  spec/simple_aggregate_w163_core_spec.cr \
  spec/simple_aggregate_w163_admission_red_spec.cr \
  spec/simple_aggregate_w163_wide_spec.cr \
  spec/simple_aggregate_w161_wide_spec.cr \
  spec/simple_aggregate_w161_guards_spec.cr \
  spec/staged_typed_numeric_validator_w162_spec.cr \
  spec/wide_part_writer_typed_mark_readback_spec.cr \
  spec/interval_w160_guards_spec.cr \
  --single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace
```

All compiler/native jobs run serially under the existing root-owned
`cogni-ml/scripts/run_safe.sh` guard (600 seconds, 12288 MB, minimum free memory
50%), Crystal 1.21/LLVM 22.1.8, SDK 26.5, isolated caches and `TMPDIR=/private/tmp`.
The RELEASE command has the same compiler flags plus `--release --no-debug`.
Its 82 unique specs run in eleven disjoint groups. Each group has actual child
and guard exit 0, zero failures/errors/pending and unchanged inputs:

| Group | Executed examples | Spec stems (`spec/<stem>_spec.cr`) |
| --- | ---: | --- |
| 1 | 55 | simple_aggregate_w161_admission_red, simple_aggregate_w161_core, simple_aggregate_w161_guards, simple_aggregate_w161_recursive, simple_aggregate_w161_wide, interval_w160_admission_red, interval_w160_core, interval_w160_guards |
| 2 | 95 | interval_w160_recursive, interval_w160_wide, binary_value_codec_w117, binary_scalar_types_w119, binary_bulk_w122, physical_stream_plan_w125, binary_low_cardinality_w141, binary_low_cardinality_storage_w142 |
| 3 | 66 | binary_low_cardinality_bulk_w143, binary_low_cardinality_float_bulk_w144, binary_low_cardinality_physical_w145, binary_variant_value_w147, binary_variant_value_w147_adversary, binary_variant_bulk_w148, binary_variant_bulk_w148_adversary, binary_variant_physical_w149 |
| 4 | 68 | binary_variant_physical_w149_adversary, binary_bulk_physical_prefix_w151, binary_dynamic_descriptor_w152, binary_dynamic_value_w153, binary_dynamic_bulk_plan_w154, binary_dynamic_bulk_plan_w154_adversary, binary_dynamic_bulk_values_w155, binary_dynamic_bulk_values_w155_adversary |
| 5 | 43 | binary_dynamic_bulk_shared_context_w155, binary_dynamic_physical_w156, binary_dynamic_physical_w156_adversary, binary_dynamic_statistics_offsets_w157, wide_part_writer_typed, wide_part_writer_nullable_temporal, wide_part_writer_typed_mark_readback, wide_part_writer_metadata_w150 |
| 6 | 283 | wide_part_writer_datetime, wide_part_writer_date, nullable_temporal_scan, datetime_scan, fixed_numeric_scan, timezone_temporal_admission_w104, timezone_temporal_consumers_w104, timezone_temporal_writer_w104 |
| 7 | 94 | offline_catalog, multicolumn_table_scan, streaming_scan, object_document_schema_w131, object_document_schema_w140, object_declared_low_cardinality_w146, object_low_cardinality_consumers_w146, object_declared_variant_w151 |
| 8 | 61 | object_variant_consumers_w151, object_recursive_dynamic_w159, object_recursive_dynamic_w159_adversary, object_temporal_w139_root, object_recursive_consumers_w140, wide_part_writer, simple_aggregate_w163_core, simple_aggregate_w163_admission_red |
| 9 | 52 | simple_aggregate_w163_wide, staged_typed_numeric_validator_w162, wide_part_writer_bool_canonical_w98, wide_part_writer_decimal_precision_w102, simple_aggregate_w164_core, simple_aggregate_w164_wide, wide_part_reader_w35, wide_part_reader_w36 |
| 10 | 50 | wide_part_reader_w37, wide_part_reader_w38, wide_part_reader_w39, wide_part_reader_w49, wide_part_reader_w62, wide_part_writer_w62, wide_part_table_w62, wide_part_reader_w16 |
| 11 | 6 | wide_part_writer_w16, decimal_precision_consumers_w102 |

Total RELEASE: 873 examples. This is affected regression coverage, not the
entire repository test suite. The original W35/W36 inferred-writer refusal
tests remain unchanged. Root confirms `typed_type_name` is byte-identical to
baseline `a61aa14`; the array writer's inference map is also unchanged.
Semantic preflight now uses `SimpleAggregateColumnType.storage_name` directly,
checking actual shape and exact carrier before creating any stage. All five
new carriers, both scalar and Nullable, retain inferred-writer rejection with
an empty destination parent. Explicit raw-wide/BFloat16 writers retain their
existing public behavior.

The deliberate `final-carrier-bypass` control removes only the two exact
storage equality conditions in the private semantic reader gate. Six examples
execute with four expected failures, zero errors/pending and actual child exit 1;
the RED wrapper and guard exit 0. Two same-width substitutions become accepted,
and two UInt64 reinterpretation controls reach the wrong downstream error.
Root restores the guard exactly (SHA256
`8f861cbe8a73e5c753f56c0b411cde70bc5d46eef06205d18aa03289c2e35d79`)
before every final positive RELEASE/native gate. The restored DEBUG rerun passes.

`scripts/check_simple_aggregate_w164.sh` runs with root-owned
`W164_EXECUTE_AS_ROOT=YES`, the pinned stock executable and a fresh direct
`/private/tmp` child. The actual retained pair root is
`/private/tmp/crystal-click-w164.native-1-0rWaKa`. Two opt-in native-fixture
examples execute, with zero failures/errors/pending and actual child/guard exit 0.
All 82 independently library-authored complete Wide/LZ4 parts pass stock
ATTACH/CHECK, exact SQL types, six rows, four marks and full/middle/empty literal
RowBinary. A separately stock-authored 83-column Wide part is read by Crystal.
The new certificate covers these 82 profiles, not 236 newly executed stock parts.

Root independently recomputes, without loading the Crystal fixture or the
worker-authored Ruby oracle, all 246 library RowBinary windows, three native
windows and 83 binary type descriptors. CHECK success is checked as all three
raw fields: exact part path, `is_passed=1`, empty `message`; the final tab is
required, matching `InterpreterCheckQuery.cpp:77-93`. Two additional CHECK-valid
mutants are rejected by the original unchanged oracle: metadata-only
min/UInt256-to-max identity drift (only `columns.txt` differs), and one raw
UInt128 value bit. CHECK validity alone does not establish correct values/types.

Root reconciliation checks actual summaries, unique RELEASE membership,
before/after hashes and current inputs against every final gate. All 1,121
source/spec/script inputs agree (294 source, 446 spec, 381 script files).
Final manifest SHA256:
`704110cb5316a2116f2451491e72fed94771589039a765e1c9c48c294547554a`.
Curated local evidence is in `final-focused-*`, `final-carrier-bypass`,
`final-release-01` through `final-release-11`, `native-1` and
`reconciliation.json` beneath the evidence root above. Formatter check for the
fourteen affected Crystal files, Ruby and Bash syntax, and `git diff --check`
pass. Temporary caches, parts and raw logs are not committed.

Scoped hostile verdict: ROBUST for this finite stored-value profile. Source
review by Luna is corroborated by root-run regression, seeded guard removal,
independent literal/type recomputation and stock qualification; model agreement
is not an independent proof. No aggregate execution, arbitrary state layout,
general JSON/MV/projection support, complete facade refactor or performance
improvement follows. Refresh on any changed admitted law, serializer, carrier
mapping, selector/dispatch, input manifest or stock executable.
