# AggregateFunction Sum-family frontier (W223)

Status: VERIFIED within the finite root-column scope; scoped verdict ROBUST.
Current baseline: `57584d50b5842ed9d826cbe08ccf9f976167830b`.
Context: immutable ClickHouse aggregate states, not aggregate execution or SQL functions.

## Factual anchor and missing capability

At the baseline, AggregateFunction wire tag `0x25` admitted only Count.
The root-executed `aggregate_sum_w223_admission_red_spec.cr` reported
two examples, one assertion failure and no errors: a literal
`AggregateFunction(sum, UInt8)` descriptor is rejected, while Count's VarUInt
control passes. This is a behavior RED on an existing API, not a compile RED.

Source reference: ClickHouse `0ca8150d9b1d0886edb2e3b4ab65eebb768d0357`,
`/Users/sergey/SrcArchives/clickhouse-2026-10-07-depth1`. Runtime witness:
26.10.1.1201, build `d9bcb5ab007f0f6299f7f973f2642245bab3d028`, SHA256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
These are separate source/runtime pins, not a claim that they are the same build.

Source anchors: `AggregateFunctions/AggregateFunctionSum.cpp:20-84`,
`AggregateFunctionSum.h:269-281,417-431,456-464,580-599`,
`Helpers.h:10-23,161-175`, `Core/Field.h:199-241`,
`DataTypes/DataTypeDomainBool.cpp:11-15`, `DataTypeInterval.h:15-42`,
`DataTypeNumberBase.h:53`, `DataTypeEnum.h:12-38`,
`AggregateFunctionFactory.cpp:76-129`,
`Combinators/AggregateFunctionNull.h:221-257`, and
`DataTypes/DataTypeAggregateFunction.cpp:349-359`.

## Design-sealed surface

- Exact nominal AggregateFunction descriptor owner, shared tag `0x25`, empty
  parameters and version zero. Existing Count signatures, wire representation,
  carrier and public APIs remain compatible and exact-Count guarded.
- Root `sum`, `sumWithOverflow`, and `sumKahan` states for all 15 numeric
  dispatcher leaves, Bool, Enum8/16, Decimal32/64/128/256 and all 11 Intervals.
- Argument metadata may be bare or Nullable. Numeric/BFloat16/Bool/Interval
  arguments may also be LowCardinality or LowCardinality(Nullable). Decimal
  and Enum LowCardinality arguments remain refused by the source type law.
- Ordinary sum promotes small integers to 64 bits and BFloat16/Float32 to
  Float64, retaining wide integer widths. Enum uses signed storage. Decimal
  sum uses a 128-bit coefficient except Decimal256, which stays 256-bit.
  Overflow uses the dispatched input storage width. Numeric Kahan stores two
  Float64 words. Decimal/Interval Kahan canonicalizes to ordinary sum.
- Nullable argument states store a presence byte, followed by nested state
  only when present. The aggregate value itself is not an ordinary NULL.
- Paired root-column part writing/reading through shared BinaryBulk owners,
  borrowed typed-table BinaryValue batches and owned offline column `.values`.
  Existing Count-specific key-pair admission is not generalized implicitly.
- Native qualification target: quiescent Wide/LZ4/Default/plain-mrk2 parts,
  real [2,2,1] mark grid, exact declaration, stream roster and state bytes;
  both stock-authored reads and library-authored ATTACH/CHECK/read witnesses.

## Rejected and guard-only surface

Nonzero versions, parameters, other AggregateFunction families/combinators,
Nothing arguments, nonnumeric containers, Nullable(LowCardinality), and outer
Array/Tuple/Map/Nullable/LC/Variant/Dynamic/JSON wrappers of aggregate states
remain rejected. General recursive aggregate-state physical composition is a
later qualification, not inferred from this one-lane root layout. Aggregate
execution, finalization, MV/projection writing and performance are non-goals.
Projection reads may reuse the selected child's existing generic table route;
no parent/child row-domain equivalence or new native projection claim is implied.

## Design laws and strongest failure

Declared arguments are immutable descriptor metadata, not value children or
extra physical lanes. Preserve explicit LC metadata even though the factory
normalizes LC for state dispatch. A State expression's return declaration is
not evidence to erase LC from explicit DDL. Aggregate state width is not
argument width and must not enter ordinary `fixed_width` scalar dispatch.

The state carrier owns validated canonical wire bytes. It must not reuse Bool,
Enum or Decimal value constraints: stock overflow Bool for three true inputs
is byte `03`, and an Enum accumulator can be outside its declared enum codes.
Preserve raw IEEE bits and Kahan compensation. Count keeps its established
UInt64 little-endian carrier and VarUInt wire encoding behind exact dispatch.

The strongest likely failure is tag-only dispatch silently treating a Sum
state as Count. Guard every Count accessor/codec/profile and cached summary
against exact function metadata; preserve general unsupported-composition
guards separately. Budget argument edges without introducing value edges.

## Execution plan, rollback and DoD

Risk: CAUTION (serialization/shared identifier). Rollback: one atomic local
feature commit, exact-path staging; no remote writes. Existing tree was clean
before the root-authored admission RED. No dependency changes are planned.

1. Core descriptor/state owners and wiring: `binary_data_type.cr`,
   `binary_data_type_codec.cr`, `binary_value.cr`, `binary_value_codec.cr`,
   `binary_codec_context.cr`, `binary_type_name_budget.cr`, neutral name reader,
   BinaryBulk type/physical/encoder/decoder/default owners, loader, and new
   one-class-per-file aggregate descriptor/state/declaration owners.
   Inventory: bounded `rg` over `TAG_AGGREGATE_COUNT`, `aggregate_count`, and
   `contains_aggregate_count` enumerated nominal, value, budget, physical,
   Count reader/writer and public consumer seams. No distinct Sum wire tag.
2. Thin paired writer and static table/offline adapters reuse shared bulk
   publication/materialization. Preserve Count-only routes and SAF policies.
   New nominal adapter(s) own admission; no Sum-specific batch return union.
3. Core and physical/public negative tests, then external stock/native
   qualification with independent literal expectations and bounded processes.
4. Root diff/source review, exact regression roster, DEBUG/RELEASE checks,
   scoped adversary verdict and evidence/status update before local commit.

Commands run by root only, serialized under `run_safe.sh` with minimum free
memory 50 percent. Crystal uses `--single-module --threads 1
--link-flags=-fuse-ld=ld`. DoD: focused W223 specs plus affected Count/SAF/
BinaryBulk/budget/table/offline regressions pass in DEBUG and RELEASE with no
pending examples; prebuilt W223 native helper and runner pass both directions
and exact window/consumer assertions. A report/audit, where used, must inspect
raw process status and pins and reject an executed seeded inconsistency.
Exact commands, counts and native roster are recorded only after execution.

Falsifiers: UInt8 sum width versus argument width; Enum/Bool overflow outside
value constraints; Kahan second word/raw bits; all-null flag-only state;
truncation/trailing bytes/noncanonical presence; malformed arity/params/version;
Count accessor on Sum; exact LC metadata mismatch; lane/grid/sparse/nominal
substitutions; table/offline budget and projection child-path controls.

Stop and narrow the slice if native physical metadata differs from the shared
profile. Do not relax source identity or physical guards to make an oracle pass.
Passing a finite native branch roster is not all-layout/product qualification.

## Observed qualification

The 55 affected specification files pass 291 examples in each of DEBUG and
RELEASE, in eight serial cohorts per mode, with zero failures/errors/pending.
This includes the six W223 files and the prior Count/SAF/bulk/budget/table/
offline/projection regression roster; it is not a whole-repository test claim.

Fresh native runs per mode pass 43 stock-authored reads and 43 library-authored
ATTACH/CHECK/exact-state reads: 42 Sum-family branch witnesses plus one Count
control. Each mode also passes a separate 78-case stock construction census
(33 sum, 33 overflow, 12 targeted Kahan). Full, middle-key and empty native
RowBinary windows agree with independent literal bytes. Public typed batches
and owned offline column values preserve exact nominal state identity.

Both separately executed raw audits pass all 984 successful invocation records
per mode. An inconsistent exit-status seed rejects despite the unchanged green
summary. A second seed retains exit zero, the exact part name and a coherent
stdout hash reference, but changes CHECK's result bit to zero; the audit rejects
the exact three-field TSVRaw result. Restoring all original file hashes returns
the audit to green. All 1,293 frozen source/spec/tooling inputs still match.

Qualification exposed tooling defects, not production admission refusals:
unsupported helper Array#to_slice, omitted Count stream-roster evidence,
two-versus-three-field CHECK expectations, substring process-label collisions,
construction-ID casing, and a Sum metadata expectation incorrectly applied to
the legacy Count writer. The corrected controls retain distinct exact metadata
profiles; no production guard was relaxed to obtain a native pass.

The ordinary OfflineTable.scan_typed/window facade is not admitted for Sum by
this slice. Use column `.values` or the generic WidePartTable typed batch route.
The projection child-path control is synthetic; no native projection writer,
freshness, provenance, full catalog discovery, mutable-part, performance,
peak-RSS or complete production payload-hash claim is made.

Details and actual command/log/pin references:
[W223 evidence packet](../.landmark/evidence/aggregate-function-sum-w223.json).

## Continuation

Next discriminator: a stock outer Array(AggregateFunction(sum, UInt8)) part with
uneven/empty arrays and a short final mark, to separate reusable state codecs
from the enclosing wrapper's row-domain/stream schedule before widening guards.
Other aggregate families still require their function-specific state laws.
Refresh evidence when serializers, nominal admission, physical contexts,
consumer ownership, source/runtime pins or helper artifacts change. The full
types/MV/projection goal remains active; memory/performance stays deferred.
