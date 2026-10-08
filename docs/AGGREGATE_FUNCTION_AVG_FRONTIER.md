# AggregateFunction Avg frontier (W227)

Status: VERIFIED within 148 finite quiescent root Wide profiles; scoped
adversary verdict: ROBUST. Other aggregate families/layouts remain open.
Baseline: `0402a6bbfd8512105589acb8b1500a75780dbadc`.
Context: immutable serialized states, not aggregate execution or finalization.

## Anchor and missing capability

The baseline generic AggregateFunction leaf admits Count and the W223 Sum
family. Its non-Count state plan assumes fixed-width bodies. Avg is refused by
the constructor and binary descriptor decoder. Existing W224-W226 recursive
wrappers already delegate aggregate leaves to that owner; they do not need
independent serializers for each product of wrappers and argument types.

Source: `/Users/sergey/SrcArchives/clickhouse-2026-10-07-depth1`, revision
`0ca8150d9b1d0886edb2e3b4ab65eebb768d0357`. Runtime: 26.10.1.1201,
build `d9bcb5ab007f0f6299f7f973f2642245bab3d028`, SHA256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
These are separate pins, not a same-build or continuing-latest-master claim.

Source laws: `AggregateFunctionAvg.cpp:21-96`,
`AggregateFunctionAvg.h:164-169,237-274,465-486`, `Core/Field.h:199-241`,
`base/base/Decimal_fwd.h:33-39`, `DataTypes/IDataType.h:430-470`,
`DataTypeDomainBool.cpp:11-15`, `DataTypeLowCardinality.cpp:68-111`,
`AggregateFunctionFactory.cpp:76-129`,
`Combinators/AggregateFunctionNull.h:221-257`, and
`DataTypes/Serializations/SerializationAggregateFunction.cpp:58-95`.

## Admitted surface

- Canonical `avg`, one nominal argument, no parameters, descriptor version 0.
  All source-valid numeric widths, BFloat16, Bool, Decimal32/64/128/256,
  Date/Date32/DateTime/Time/DateTime64/Time64 and all 11 Interval units are
  included. This is a whole leaf family, not a UInt8-only implementation.
- Argument shells: bare and Nullable; LowCardinality and
  LowCardinality(Nullable) for source-eligible numeric/Bool, unscaled temporal
  and Interval leaves. Exact scale, timezone, Decimal precision and wrapper
  spelling remain nominal metadata. Arguments do not become value children.
- Numerator: little-endian 64-bit promoted small integer/float carriers;
  128-/256-bit wide integers retain their width. Decimal32/64/128 and scaled
  DateTime64/Time64 use a 128-bit coefficient; Decimal256 uses 256 bits.
  Unscaled temporal and Interval use their promoted 64-bit carrier.
- Denominator: canonical bounded UInt64 VarUInt, 1..10 bytes. There is no
  generic state-length prefix. Each row boundary follows this parser.
- Nullable argument: one aggregate presence byte; absent is exactly `00`,
  present is `01 || numerator || denominator`. It is not scalar Nullable
  framing, and arbitrary accumulator bits are not scalar Bool/Enum values.
- Paired root Wide writer/reader, typed batches and offline column `.values`.
  Existing static/Variant/Dynamic composition routes reuse the same leaf.
  Their integration requires behavioral controls; no new wrapper grammar is
  inferred from adding Avg to nominal admission.

## Rejected, guard-only and non-goals

Enum8/16, Nothing, String and container arguments are outside Avg's source
factory. LC Decimal/scaled-temporal and repeated/invalid argument shells remain
rejected. Nonzero descriptor versions, parameters and other aggregate function
families/combinators are not admitted by this slice.

JSON aggregate actuals, legacy fixed-union Dynamic codecs, borrowed shared
envelopes and Map keys keep their existing explicit guards. Sparse/Compact or
other physical serialization versions are not admitted implicitly. Projection
reads must retain selected-child schema/row domains; this slice does not claim
native projection coverage, MV/projection writing, optimizer behavior, general
MV execution, aggregate arithmetic or performance. The full user goal remains
active, with memory/performance work deferred until types and MV/projections.

## Failure model and falsifiers

The strongest failure is continuing to advance each Avg row by a fixed stride,
silently consuming the next row when denominator length changes. Opposite
failure: treating arbitrary state bytes as a length-prefixed scalar. Both must
fail with adjacent empty/127/128/16384/UInt64-max states and later-mark reads.

Other falsifiers: truncated/overlong/nonminimal/overflow count; trailing bytes;
invalid nullable presence; flag-only absence versus initialized empty body;
exact/one-short scalar and shared lane budgets; descriptor arity/version/params;
same-width nominal substitution; Bool's custom UInt8 identity versus Enum's
separate source-invalid TypeIndex; Count and Sum regression; nested arrays,
Variant/Dynamic ordinary/shared branches, hidden JSON/helper guards; corruption
before public callback and selected short-final-mark domains.

## Execution plan and DoD

Risk: CAUTION (shared serialization and admission). Rollback: one local atomic
feature commit against the baseline; exact path staging, no remote writes or
history rewriting. Existing root-owned PROJECT_STATUS freshness changes are
preserved. No dependency changes or broad facade refactor are planned.

1. Execute the compiling behavioral RED in
   `spec/aggregate_avg_w227_core_spec.cr`, and fixed independent stock
   avgState prerequisites before changing production admission.
2. Admission/descriptor: `binary_aggregate_function_admission.cr`,
   `binary_aggregate_function_type.cr`, `binary_data_type_codec.cr`. Preserve
   Count/Sum identities and add a separate one-class-per-file Avg layout owner.
3. State framing: `binary_aggregate_function_state_plan.cr`,
   `binary_aggregate_function_state_codec.cr`, the new Avg layout and loader.
   Bounded `rg` for `state_width`/`minimum_state_bytes` found plan+codec and
   BinaryBulk minimum preflight consumers, plus existing Sum specs. Preserve
   fixed-width Sum compatibility; variable-width Avg must not expose a false
   fixed-state width. No per-wrapper serializer or generic blob fallback.
4. Consumers/specs/helper use existing BinaryBulk and publication owners.
   `spec/aggregate_avg_w227_consumers_spec.cr`,
   `scripts/check_aggregate_avg_w227.cr`,
   `scripts/recheck_aggregate_avg_w227.rb` and independent raw audit.
5. Root independently reviews the diff/source, runs affected DEBUG/RELEASE
   regressions and native qualification, attacks raw CHECK/status/byte evidence,
   then updates status/evidence and commits only after the declared DoD passes.

All compiler/native/audit jobs are serialized by root through `run_safe.sh`,
minimum free memory 50%, one Crystal worker and isolated cache. Crystal flags:
`--single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace`.
DoD: focused and affected regressions pass DEBUG and RELEASE without pending
examples; source-valid signature census and paired stock/library root Wide
fixtures pass exact nominal bytes and [2,2,1] mark windows; independent raw audit
passes, rejects an executed false-positive CHECK seed, and passes after exact
restoration. Actual commands, case counts and results are recorded only after
execution, not inferred from this plan.

Stop on a source/runtime law mismatch or unsupported physical layout; preserve
the observation and revise the implementation, not the oracle or source guards.
Finite physical witnesses do not claim every Cartesian wrapper/layout product.

## Executed qualification (2026-10-08)

The pre-implementation RED compiled: five examples, four errors at the old
Avg admission/descriptor boundary and a passing Count/Sum control. Independent
stock avgState prerequisites passed before production widening. Source review
corrected Bool's custom UInt8 identity and Decimal alias canonical spelling;
neither Enum admission nor argument metadata was weakened to match a fixture.

The same 58 affected spec files pass 346 examples in DEBUG and RELEASE, with
zero failures, errors or pending examples. Root added all nine seven-bit count
transitions, adjacent Nullable present/absent/sentinel controls for 8/16/32-byte
numerators, malformed counts and compressed-frame rejection before callback.
Existing Sum retains its fixed-width API; Avg explicitly refuses that API.

Fresh native DEBUG and RELEASE runs each qualify 148 exact nominal profiles:
136 base signatures over 37 source-valid leaf kinds plus 12 scale/timezone
witnesses. Each records 13 computed avgState probes and 162 raw processes:
160 successes and two expected Enum construction refusals, no timeout or spawn
failure. Stock and library parts have five rows, [2,2,1] marks plus terminal
zero, Wide/LZ4/Default/plain-mrk2, exact opaque state bytes, public mark windows,
typed reads and detached owned values. Stock accepts every library part with
ATTACH/CHECK=1 and exact full/middle/zero RowBinary. These root witnesses are
not native qualification of every outer wrapper or every metadata parameter.

Both independent raw audits pass. A successful-exit CHECK-zero forgery with a
matching matrix and green summary is rejected in each mode, followed by exact
restoration and a passing audit. Hostile review also exposed an auditor-only
inventory gap: a same-length attached checksums.txt byte flip with coherently
updated inventories/matrix hash was initially accepted. The auditor now compares
actual library file entries with actual attached entries, excluding only the
known added invalidation sidecar. The identical forgery then rejects in DEBUG
and RELEASE; exact restoration passes. File equality does not certify empty
directory topology, and the externally supplied helper hash relies on root's
recorded build provenance.

All 1,776 generated part files match between modes by actual bytes, relative
path, size and SHA-256. This is an additional control, not the compatibility
oracle. Final format checking passes 13 Crystal files; both Ruby syntax checks
and the 15-file source-freeze check pass. DEBUG/RELEASE specs use unchanged final
production/spec bytes; native helpers use the final formatted helper. The
auditor-only guard was added after DEBUG capture, then that untouched capture
was re-audited with executed attacks and exact restoration.

Harness failures were not semantic refusals: Ruby module receivers, invalid
test-generated part basename, and conflated logical root.data role versus
physical v stream name. They were corrected in the harness and native runs
restarted on fresh roots without reducing the 148-case corpus or library guards.
The implementation has one new Avg layout owner in its own file; existing
recursive consumers reuse it without per-product serializers.

Raw commands, pins, logs and restoration results are indexed in
[the scoped W227 evidence packet](../.landmark/evidence/aggregate-function-avg-w227.json).
Refresh after admission, state grammar, bulk/consumer dispatch, fixture/helper,
source or runtime changes. If temporary raw roots disappear, regenerate the
recorded qualification rather than treating this index as a replacement proof.
The full storage/MV/projection goal remains active; performance stays deferred.
