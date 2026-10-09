# AggregateFunction Min/Max state frontier (W237)

Status: VERIFIED within the finite W237 state/composition/native profile;
root hostile verdict ROBUST within that scope (2026-10-09).
Baseline: clean `45eda6bc4f687a53d0648b7caab0dd8a6a96b950`.
The overall objective remains compatible read/write types and MV/projections,
then memory/performance and the original <=10 percent slowdown target.

## Problem and scope

Count, the finite Sum family and Avg already have state leaves. Min/Max are
genuinely missing state grammars, not a missing serializer for every enclosing
Array/Tuple/Map/Nested/Variant/Dynamic product. They are relevant to stored
aggregate columns and materialized-view targets. Existing recursive state-leaf
routing and physical publication should be reused.

Source candidate: `/Users/sergey/SrcArchives/clickhouse-2026-10-07-depth1`,
revision `0ca8150d9b1d0886edb2e3b4ab65eebb768d0357`.
`AggregateFunctionsMinMax.cpp` selects a unary parameterless single-value
aggregate, requires comparable arguments and rejects Dynamic/Variant anywhere
in the argument tree. `SingleValueData.h` selects fixed numeric/date,
specialized String, Field-backed generic or column-backed generic storage.
`SingleValueData.cpp` owns their distinct encodings. Source shape is not native
persistence evidence; runtime is separately pinned by the existing W224
recorder and must be verified before widening admission.

Implemented admission: nominal version-zero `AggregateFunction(min, T)` and
`AggregateFunction(max, T)` for source-valid already implemented comparable
static arguments, including lawful dispatch Nullable/LowCardinality shells.
Argument descriptors remain metadata; stored aggregate states remain opaque
owned bytes, not finalized values. Reuse child value serde for generic bodies,
but do not infer Field/column equivalence for unqualified owners.

Remaining rejected/guard-only: other functions or combinators, parameters,
unsupported versions, noncomparable arguments, Dynamic/Variant inside argument
types, invalid Nullable/LowCardinality shells and unqualified JSON/QBit or
aggregate-state argument owners. Existing outer-container admission must not
widen solely because a new aggregate leaf exists. No aggregate execution,
MV execution, new engine, performance or all-layout claim is part of this slice.

## Design laws and risk

- Numeric single-value state is a presence byte and, when present, the original
  carrier width, not Sum's promoted accumulator and not a fixed-width stride.
- String state has historical signed Int32 length including a terminating NUL;
  no-value differs from a present empty string. Qualify exact accepted legacy
  length/terminator behavior before asserting canonical-only compatibility.
- Generic state delegates child serialization after its own presence byte.
  Reuse existing leaf/container codecs with one operation budget and exact
  cursor consumption; no new codec per argument product or hidden budget reset.
- Nullable argument framing and the inner single-value presence are separate
  source/runtime questions. Observe both empty and populated states before
  implementing the rule. LowCardinality dispatch is not an aggregate dictionary
  stream and must preserve the nominal argument declaration.
- State validation/default/read/write must agree; windows must not consume
  adjacent states or reinterpret arguments as physical child columns.
- One new responsibility per file; preserve public facades, state ownership,
  existing function identity and earlier Count/Sum/Avg rejection boundaries.
- Public raw-state construction checks the complete frame byte size before
  ownership copying, then validates Generic child traversal under the same
  standalone limits. Scalar/bulk reads and writes retain their enclosing
  context, depth and shared budget; no fresh default revalidation occurs there.
  This is not an RSS bound or a full standalone descriptor-tree traversal.

Risk: CAUTION (persistent serialization). Likeliest failure: an incorrect
presence/length rule silently shifts later rows or marks. Guard: independently
packed native-produced state bytes, adjacent empty/populated variable states,
sentinel columns, later-mark reads and both-direction ATTACH/CHECK/RowBinary.
Rollback: exact owned changes from the clean baseline, one local atomic commit
only after the relevant DoD passes. No push, history rewrite or production data.

## Execution order and Definition of Done

1. Inventory admission/type-name/state/default and recursive/bulk consumers.
   Root independently checks the highest-risk upstream contracts.
2. Stock discriminator before production edits: isolated version/build/SHA pin,
   source-generated empty/populated `minState`/`maxState`, exact declarations,
   stock Wide persistence and independent literal RowBinary over multiple marks.
   Process/timeouts/plumbing failures are not semantic type refusals.
3. Run compile-valid focused tests against unchanged production; require actual
   missing-admission/state failures with passing existing-function controls.
4. Add only the qualified state/admission owners and existing dispatch hooks.
   Tests cover exact bytes, boundary/truncation/trailing/length faults, shared
   budgets, nominal descriptor/default preservation and recursive reuse.
5. Stock-to-library public reads and library-to-stock ATTACH, CHECK=1, exact
   full/middle/empty RowBinary. Compare actual generated files across modes.
6. Run focused and affected historical tests in DEBUG and RELEASE, syntax,
   formatting and exact diff checks; zero failures/errors/pending and nonzero
   examples. Root alone runs heavy jobs, serial under the existing run_safe.sh,
   minimum-free50%, CRYSTAL_WORKERS=1, bounded time/memory and isolated caches.
7. Hostile review and a sensitivity falsifier before scoped closure. Retain raw
   commands/pins/results and rejected residuals; update this frontier and
   LANDMARKS plus the project-status banner after evidence exists.

Stop and attribute native or source disagreements instead of loosening the
oracle. Temporary raw captures are regenerable evidence caches, not proof when
absent. Refresh after codec/policy/consumer/harness/fixture/compiler/source/
runtime/profile changes. No whole-suite or full-goal completion is claimed.

## Observed result and remaining boundary

The same 37 selected files pass 208 examples in each of DEBUG and RELEASE,
with zero failures, errors or pending. Before production edits, the original
10-example probe compiled and produced eight missing-admission errors while
two earlier-function controls passed. A later root hostile probe produced an
actual assertion failure: the public raw String-state constructor accepted a
complete frame one byte over its default byte limit. The final constructor
checks the complete frame before ownership copying; tiny exact/one-short
Fixed, String, Generic and nullable-Generic controls and the real default-limit
probe pass. This bounds framed bytes and Generic body traversal, not RSS or
all standalone descriptor-tree work.

Native qualification uses 46 persisted profiles (23 declarations times
min/max), five keys `11,22,33,44,55` and three data groups `2,2,1`.
Native `system.parts.marks=4` includes a terminal record. The stock recorder
retains 123 actual ClickHouse processes: 119 successes and four expected
Code 43 Dynamic/Variant argument refusals, no signals/timeouts/spawn errors.
Six nullable-all-NULL source controls and six accepted legacy String spellings
distinguish outer presence and canonicalization. Four LowCardinality(String)
or LowCardinality(Nullable(String)) constructor controls and twelve empty-Tuple
source-state controls are not additional persisted profiles.

Each final mode runs five fresh native processes plus one separate helper.
Library readers consume actual stock parts; the writer publishes 46 parts
accepted by native ATTACH, exact clean `CHECK=1` and independent full/middle/
zero RowBinary. Physical full/first/middle/final-short/EOF and typed full/window/
owned-value consumers pass. Separate raw audits reconstruct declarations,
SQL, process outcomes, part inventories and expected bytes. All 552 generated
files match across modes by actual names and bytes: 57,234 bytes per mode.
The final auditor rejects seven in-memory coherent CHECK/status/exit/signal/
timeout/spawn false-success probes and passes genuine/restored records; those
probes do not mutate or authenticate the original capture files. Final exact
Crystal formatting and both Ruby 2.6 syntax checks pass.

One failed initial attachment was a harness error, not a state-codec refusal.
The parser accepts `ATTACH PART ... FROM ...`, but `MergeTreeData` interprets
`FROM` as a detached directory name and rejects `/` (Code 79). The final runner
observes the isolated table's data path, verifies an exact copy into `detached`,
attaches by part name and reconciles native-added invalidated-column metadata.
No state codec or literal oracle was relaxed to repair that plumbing.

Source is pinned to the October 7 checkout above, not asserted as the latest
October 9 upstream. Native `26.10.1.1201`, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, has a separate lineage. The packet
records hashes, commands, raw paths and exact qualification scope:
[W237 evidence index](../.landmark/evidence/aggregate-minmax-w237.json).

Remaining work is legal stateful-owner/layout intersections, other aggregate
state leaves, MV/projection analysis and writing, and large-facade decomposition.
Ordinary recursive child serde is already reused; a new Cartesian-product
serializer is not the plan. No all-type, all-depth, all-layout, aggregate/MV
execution, whole-suite, memory/performance or overall-goal closure is claimed.
