# SimpleAggregateFunction numeric paired frontier — W163

## State and scope

Status: VERIFIED within the finite numeric paired profile below. Baseline:
`c0d4c51`. This is a capability extension, not
an aggregate executor or a performance change. W161's UInt64 certificate
remains historical; this document does not retroactively widen it.

The objective remains all paired ClickHouse storage types and MV/projection
support before memory/performance optimization. This atomic slice adds ten
already-supported standard numeric storage carriers to the exact canonical,
unary, zero-parameter SimpleAggregateFunction profile. Wider raw integers and
BFloat16 are the following slice, not invalid ClickHouse types.

Risk: CAUTION (descriptor admission, public semantic read/write dispatch).
Rollback: revert the eventual atomic W163 commit; until committed, restore
only W163-owned edits. Do not discard unrelated work. No dependency change,
remote write, server mutation, format version, or performance claim is admitted.

## Anchors and discriminating evidence

Fresh shallow source: `/Users/sergey/SrcArchives/clickhouse-2026-10-04-depth1-41b7bd50`,
commit `41b7bd50051cc2017fe5ca5505fb35c9dc620000`. It is unbuilt.
Executed pinned stock is separately `26.10.1.1201`, source build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, binary SHA256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.

`DataTypeCustomSimpleAggregateFunction.cpp:151-165` resolves the function,
checks its canonical supported identity, and requires result type to equal
the argument storage type after LowCardinality removal. `AggregateFunctionSum.cpp:20-48`
separates normal nearest-field result widening from same-type sumWithOverflow.
Bitwise functions admit integer dispatch, not floating carriers.

Root's independent literal stock probe tests nine functions × fifteen
carriers × scalar/outer Nullable. Its resource guard exits 0: 270 profiles,
236 accepted, 34 rejected, zero source-matrix mismatches. Logs and literal
queries: `/private/tmp/crystal-click-w163.5aikgZ/stock-matrix/`; runner:
`/private/tmp/crystal-click-w163.5aikgZ/probe_matrix.rb`. A successful type
construction is not whole-part storage qualification.

## Admitted matrix

| Function | UInt8/16/32 | UInt64 | Int8/16/32 | Int64 | Float32 | Float64 |
| --- | --- | --- | --- | --- | --- | --- |
| any, anyLast, min, max, sumWithOverflow | yes | yes | yes | yes | yes | yes |
| sum | no | yes | no | yes | no | yes |
| groupBitAnd, groupBitOr, groupBitXor | yes | yes | yes | yes | no | no |

This is 77 scalar function/carrier pairs and 154 with the outer Nullable
shape. `sum(UInt8)` is not silently converted to UInt64; the requested
storage declaration is invalid in ClickHouse. Floating bitwise types are
also invalid. Legal UInt128/256, Int128/256 and BFloat16 profiles remain
unqualified library consumers for this slice.

The exact identity is `{canonical function, exact child carrier, outer shape}`.
Names, equality, hash and descriptor bytes retain all coordinates. Raw
payloads use the child's existing little-endian fixed-width serializer; the
wrapper is not an aggregate state and does not execute aggregation.

Public writer pairs retain UInt64 PKs and accept typed child slices. New
generic semantic mark readers and batch accessors retain the type gate.
Existing UInt64 semantic entry points and inherited readback selector hooks
retain their signatures and require the exact UInt64 carrier. Primitive
numeric readers/accessors stay closed to nominal wrappers. Table windows and
offline catalog column `.values` dispatch through the same exact carrier.

## Rejected, guard-only and unchanged boundaries

- Unknown functions, aliases, parameters, n-ary declarations, Bool, String,
  Decimal, temporal/enum carriers, nested Nullable and LC children remain
  unsupported by this profile; some are legal CH types outside this certificate.
- General AggregateFunction states, JSON/Object arms, recursive public whole-part
  products, Compact layouts and aggregate MergeTree execution remain separate.
- String serialization v1, nullable BASIC v0, exact metadata/substream checks,
  K+1 marks, bounded range selection, checksums, PK validation and staging
  publication/cleanup remain unchanged. No per-column serializer widening.
- Scalar values including floating raw bits are transported, not normalized;
  stock INSERT floating normalization is not equated with stored-value transport.
- Descriptor/name/node and child bulk budgets remain borrowed and bounded.
  Logical budget tests do not certify process RSS or allocation counts.

## Implementation and falsifier sequence

1. On unchanged production, execute new literal descriptor/value specs and a
   public whole-part writer/reader spec. Observe actual RED on the old UInt64
   restriction, not a compiler-only failure or an unrelated guard.
2. Extend the cohesive nominal descriptor and column-plan owners. Preserve
   default UInt64 constructors. Centralize the finite function/carrier law;
   binary decode and factories consume it without weakening parameter/arity guards.
3. Add semantic generic readers and typed writer/readback integration. Guard
   exact carrier before bytes/staging; retain legacy selector dispatch. Update
   table/offline adapters without widening primitive APIs.
4. Run focused DEBUG and affected RELEASE specs under root-owned serial
   `run_safe.sh`, isolated caches, SDK 26.5 and the host linker. Require actual
   executed example counts, zero failures/errors/pending and unchanged input hashes.
5. Qualify all 154 profiles with independent stock-authored and library-authored
   complete Wide parts. Require actual ATTACH/CHECK, exact type names and
   independently assembled full/middle/empty RowBinary bytes.
6. Attack same-width carrier confusion, function identity, invalid sum/bitwise
   pairs, wrong primitive/legacy accessors, nullable placeholder/null-map checks,
   empty/direct-zero distinctions and unselected-mark metadata rejection.
   Two CHECK-valid nominal/value mutants must fail the unchanged stock oracle.
7. Root reconciles actual logs, input hashes and intended diff, performs hostile
   review, then makes one exact-path local commit. No push is authorized here.

Affected commands include `crystal spec` for
`spec/simple_aggregate_w163_core_spec.cr`, `spec/simple_aggregate_w163_wide_spec.cr`,
the existing W161 core/guards/recursive/admission/wide specs, W162 selector and
staging guards, and affected numeric/nullable/table/catalog/codec suites. Native
DoD is `scripts/check_simple_aggregate_w163.sh` with an explicit pinned stock
binary and an owned fresh scratch directory. Exact commands and observed
counts are recorded below only after execution.

Strongest failure mode: widening parsing while UInt64-only consumers silently
reinterpret a same-width signed/float carrier, or accept a CH-invalid
function/carrier pair. Exact semantic accessors, independently literal wire
bytes and CH CHECK/type/RowBinary comparisons discriminate those cases.

## Continuity and evidence decay

Current frontier: this finite numeric paired slice passes focused DEBUG,
affected RELEASE and independent whole-part qualification at the reconciled
input state. Next capability lane is raw UInt128/256, Int128/256 and BFloat16
carriers, not aggregate execution. Root owns serial jobs and docs; Luna workers
own separate core, runtime and oracle/test paths. Model reports alone are
hypotheses. The all-types/MV/projection objective remains active.

Any source, serializer profile, canonical-function law, carrier map, public
dispatch, staged selector, stock executable or evidence input change invalidates
the corresponding certificate until its affected DoD is rerun. No full-types,
full-architecture, MV/projection-complete or <=10% performance closure follows
from this slice.

## Observed evidence (W163)

On unchanged production, the new core spec executes four examples with three
errors from the old unsupported type plans; the admission spec executes eleven
examples with nine failures and one error. Both Crystal processes exit 1 and
the RED expectation guards exit 0. These are actual test failures, not
compiler-only failures.

Focused DEBUG subsequently executes 62 examples with zero failures/errors/
pending and unchanged inputs. A final 62-example DEBUG rerun after the native
test-helper correction also passes on the reconciled input state. A first
attempt's invalid test-part directory
name is corrected separately; that failed attempt is not counted positive.
Temporary exact-carrier bypasses produce one expected failure each in the
five-example runtime spec, separately for scalar and outer Nullable. Exact
reader restoration matches SHA256
`8f861cbe8a73e5c753f56c0b411cde70bc5d46eef06205d18aa03289c2e35d79`
and five restored examples pass. No bypass remains in production.

The first native attempt passes native source construction but stops on a
Crystal test-helper `Hash#fetch` API compile error. It is not positive
reader/writer evidence. After the test-only fallback-block correction,
`native-2` passes: two actually executed native-fixture examples,
154 independent library-authored whole parts accepted by stock ATTACH/CHECK,
exact function/carrier/Nullable identity, six rows/four marks/Wide per part,
and literal full/middle/empty RowBinary comparisons. Its guard exits 0 and
all 738 source/spec/script inputs are unchanged.

Root's separate bit-shift byte encoder and binary-header decoder confirm all
462 library windows, three native windows and every one of the 155 binary
type descriptors. Both mutants are independently confirmed stock-CHECK-valid:
the min-to-max copy changes only `columns.txt` with identical raw values;
the value mutant changes exactly the intended first UInt64 bit. Neither
passes the unchanged exact identity plus literal value oracle.

Native evidence is retained under
`/private/tmp/crystal-click-simple-aggregate-w163.native-2/results/`;
outer manifests and actual counted logs are under
`/private/tmp/crystal-click-w163.5aikgZ/native-2/`. Root's reconciliation command:

```sh
/usr/bin/ruby /private/tmp/crystal-click-w163.5aikgZ/reconcile_native.rb \
  /private/tmp/crystal-click-simple-aggregate-w163.native-2
```

This is not qualification against a binary built from the fresh shallow source,
nor a complete-inventory test or performance claim. The executed runtime pins
above and the finite matrix are part of the certificate's assumptions.

## Final affected gates and hostile closure

Nine disjoint RELEASE groups execute 785 examples across 68 unique specs:
55/95/66/68/43/283/94/61/20. Every Crystal process and resource guard exits 0,
with zero failures/errors/pending and unchanged before/after inputs.
`focused-final` executes 62 DEBUG examples. The native gate executes two
additional fixture examples; its 154 complete parts are not counted as 154
Crystal examples. RED, compiler-only failure, fixture-error and bypass attempts
are excluded from positive counts.

Root independently reconciles actual log summaries, group membership, final
file hashes and native/regression input agreement. The regression union has
366 inputs; all 738 native source/spec/script inputs match the final files.
Exact commands, complete before/after manifests and logs are retained under
`/private/tmp/crystal-click-w163.5aikgZ/{release-01,...,release-09,focused-final,native-2}/`.
The root reconciliation command is:

```sh
/usr/bin/ruby /private/tmp/crystal-click-w163.5aikgZ/reconcile_gates.rb
```

Compiler: Crystal 1.21.0 / LLVM 22.1.8, aarch64 macOS, SDK 26.5, host linker
`--link-flags=-fuse-ld=ld`, single module, one compiler thread, isolated
debug/release/native caches. Every job runs serially under `run_safe.sh`, with
50% free-memory preflight and bounded time/RSS. The actually executed RELEASE
command is the guarded `run_release.rb INDEX` for indexes 0 through 8; it uses
the following exact inventory in consecutive groups of eight (last group four):

```text
spec/simple_aggregate_w161_admission_red_spec.cr
spec/simple_aggregate_w161_core_spec.cr
spec/simple_aggregate_w161_guards_spec.cr
spec/simple_aggregate_w161_recursive_spec.cr
spec/simple_aggregate_w161_wide_spec.cr
spec/interval_w160_admission_red_spec.cr
spec/interval_w160_core_spec.cr
spec/interval_w160_guards_spec.cr
spec/interval_w160_recursive_spec.cr
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
spec/simple_aggregate_w163_core_spec.cr
spec/simple_aggregate_w163_admission_red_spec.cr
spec/simple_aggregate_w163_wide_spec.cr
spec/staged_typed_numeric_validator_w162_spec.cr
spec/wide_part_writer_bool_canonical_w98_spec.cr
spec/wide_part_writer_decimal_precision_w102_spec.cr
```

Scoped hostile verdict: ROBUST. The independent stock eligibility probe,
literal descriptor/child bytes, exact same-width carrier refusals, non-vacuous
bypass controls, retained staged selectors, actual ATTACH/CHECK and unchanged
type/value mutant oracles support this finite stored-value profile. Luna's
same-lineage static review is correlated and does not replace root's executed
primary evidence. General SimpleAggregateFunction, AggregateFunction states,
all current/legacy CH formats, architecture completion, MV/projections and
performance remain outside this closure. One exact-path local atomic commit
seals the code/spec/docs state; no push is performed.
