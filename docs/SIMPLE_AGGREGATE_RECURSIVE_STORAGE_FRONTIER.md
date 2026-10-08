# SimpleAggregateFunction recursive storage frontier (W222)

Document status: VERIFIED within the finite root-SAF-column scope below;
scoped adversary verdict ROBUST. Broader recursive products remain open.
Baseline: `85a4c85102a0f31db5890457995c21a21bdeb6be` (W221).
Bounded context: nominal SAF declarations and their recursive child storage;
not aggregate evaluation or `AggregateFunction` state serialization.

## Current declared surface

The admitted baseline is the finite W221 scalar/nullable surface described in
[SIMPLE_AGGREGATE_NULLABLE_FRONTIER.md](SIMPLE_AGGREGATE_NULLABLE_FRONTIER.md).
Its eleven canonical functions reuse existing child codecs. W222 does not
invalidate those witnesses or promote them to arbitrary recursive support.

Implemented grammar with the finite native witnesses recorded below:

- Collection storage for the existing eleven functions where stock CH admits
  the exact declaration and the library already supports the child layout.
- `sumMap`, `minMap`, `maxMap`, `groupArrayArray`, `groupArrayLastArray`,
  `groupUniqArrayArray`, `groupUniqArrayArrayMap`, `sumMappedArrays`,
  `minMappedArrays`, `maxMappedArrays`, and `timeSeriesGroupArray`. Mapped-array
  factory aliases are accepted by stock CH and canonicalize to the three Map
  identities; the library consumes their canonical declarations.
- Exact canonical function parameters, where required, with bounded parsing
  and binary descriptor representation rather than silently dropping them.

An allowlist entry, factory spelling, canonical function identity, supported
storage tree, and supported physical profile are separate facts. The pinned
source contains twenty-two allowlist spellings; aliases may canonicalize to
another entry. W222 must measure that relationship instead of counting names
as independently implemented serializers. The measured count is nineteen
canonical identities, including the prior eleven and eight new identities.

Still rejected until separately evidenced: arbitrary aggregate parameters,
result/storage type mismatches, unsupported child layouts or metadata,
unchecked dynamic type rosters, and recursive names beyond configured budgets.
No SQL aggregate execution is introduced. Non-Count `AggregateFunction`
states, remaining JSON/Dynamic layouts, MV/projection writing and broader
facade decomposition remain open. Memory/performance work stays deferred.

## Design laws and primary anchors

Comparison source (not claimed to be the runtime build):
`/Users/sergey/SrcArchives/clickhouse-2026-10-07-depth1`, commit
`0ca8150d9b1d0886edb2e3b4ab65eebb768d0357`.

Pinned runtime: ClickHouse `26.10.1.1201`, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, executable SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.

1. `DataTypeCustomSimpleAggregateFunction.cpp:31-65,151-169` checks the
   resolved function's canonical name, takes its first argument as storage,
   requires its result to equal `removeLowCardinality(storage)`, and installs
   a custom name with no custom serializer. The child codec remains the
   storage owner; SAF adds nominal and admission obligations.
2. Recursive serde is not recursive admission. Aggregate result promotion,
   nullable behavior, factory combinators, arity and parameters can invalidate
   an otherwise serializable child tree.
3. Physical/public owners should compose the existing recursive child owner.
   Do not introduce a serializer class for every function/type product.
4. Preserve exact nominal identity through declaration, descriptor, staged
   publication, reader dispatch, borrowed batches and detached `.values`.
   Legacy scalar APIs keep their existing narrower value contracts.
5. Bound bytes, depth, nodes, fields and parameters before expensive name
   materialization/allocation. Logical budgets do not claim peak-RSS bounds.
6. Source-derived acceptance is a hypothesis until the independently pinned
   runtime agrees. Disagreement requires attribution, not oracle weakening.
7. Reusing a child codec does not certify its parent read schedule. LC can
   require full-domain replay; JSON/Dynamic can require specialized structure
   owners. Such children stay physical guard-only until the chosen owner and
   known replay/container budget are exercised. Current table limits account
   active-reader/per-mark logical workspace, not every retained table grid or
   transient descendant allocation.

## Execution order and falsifiers

Risk: CAUTION (recursive admission and persistent binary/part metadata).
Rollback: preserve baseline and use an exact-path atomic commit after DoD;
no remote push or history rewrite is authorized by this slice.
Likeliest failure: a storage-compatible codec is exposed for a declaration
that stock CH rejects, canonicalizes differently, or serializes under a
different stream/context schedule.

1. Inventory the complete eleven remaining source spellings and current
   recursive family rules, including aliases, positive required parameters,
   parameter/arity negatives, and result-promotion counterexamples.
2. Freeze an independent finite construction matrix. Record literal SQL,
   argv, process outcome, nominal result, specific expected refusal, and
   runtime/source pins in a fresh evidence root. A crash, timeout or probe
   defect is not a type refusal.
3. Establish behavioral RED through existing descriptor/declaration/value
   APIs for measured candidate declarations before production changes.
4. Implement cohesive admission/parser/parameter owners and child composition
   with a bounded consumer inventory. Preserve prior nominal and wire contracts.
5. Run focused and affected DEBUG/RELEASE specs, then fresh stock-authored
   read and library-authored ATTACH/CHECK witnesses with literal full, middle,
   final-short and empty-window values. Pair reader and writer evidence.
6. Attack alias/parameter identity, row domains, child stream schedules,
   staged descriptor/payload substitutions and evidence-sidecar inconsistency.
   Audit raw artifacts; a green summary alone is not a completion signal.

All compiler/native/Ruby jobs are serialized by root through the existing
`cogni-ml/scripts/run_safe.sh` with at least 50% free system memory and bounded
time/memory. Workers may author code and inspect sources, but do not execute
these jobs. No guard bypass or unrelated process intervention is permitted.

## Executed admission falsifier

Before production changes, root ran the existing-API seed spec on the W221
baseline through the declared memory/time guard:

```text
crystal spec spec/simple_aggregate_recursive_w222_admission_red_spec.cr
  --single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace
```

Observed: exit 1, five examples, three behavioral failures, zero errors or
pending. Constructor `anyLast(Array(Int16))`, the first recursive declaration
in its loop, and `groupArrayLastArray(5)` parsing fail their positive admission
assertions. Scalar and negative/budget controls pass. This is measured RED,
not a compiler failure or a certificate for every loop member. Raw log:
`/private/tmp/crystal-click-w222-matrix.oWGPOF/admission-red-debug.log`.

DoD is not yet satisfied. The complete stock construction roster, broader
spec/native commands, observed counts, adversary outcome and residual refusals
will be recorded after execution. No W222 behavior is admitted by this
document alone.

## Qualified construction basis and implementation plan

Root executed the frozen construction probe in a fresh root:
`/private/tmp/crystal-click-w222.CinMPZ`. Its 89 cases comprise 74 strict
witnesses (42 accepted, including five exact binary headers; 32 specifically
refused), and 15 exploratory declarations. All strict outcomes matched, with
zero probe failures. Exploratory outcomes were 13 constructed, one aggregate
refusal and one separate Nothing table-storage refusal; these are not promoted
to the strict certificate. The earlier root `crystal-click-w222.uZ26XA` is
retained as a failed probe run: wrong UInt64 oracle tag and diagnostic/refusal
ordering expectations were corrected from source before the fresh run.

Source factory aliases `sumMappedArrays`, `minMappedArrays`, `maxMappedArrays`
collapse onto canonical `sumMap`, `minMap`, `maxMap`. The library's declaration
and descriptor parsing remains canonical-only; aliases are not new nominal
identities. The supported parameter representation in this slice is a bounded
zero-or-one positive UInt64 Field, not arbitrary CH Field serde. Exact SQL
construction and descriptor witnesses do not qualify physical part schedules.

Risk remains CAUTION. Rollback is the W221 baseline plus one coherent exact-path
commit after DoD. No push is part of this slice. The strongest failure mode is
logical admission leaking into an unsupported physical profile or widening a
legacy scalar/Count/Object consumer. Guard checks retain those refusal surfaces.

1. **Logical owner**: extend `binary_simple_aggregate_type.cr`,
   `binary_data_type.cr`, `binary_data_type_codec.cr`,
   `binary_type_name_budget.cr`, and, only if necessary,
   `binary_codec_context.cr`. Add cohesive parameter and admission classes,
   plus a bounded neutral recursive type-name reader. Coordinate
   `src/crystal_click.cr` require ordering. The parsed-child constructor must
   validate an existing immutable child tree, not render and reparse it.
   Keep old enum ordinals, scalar constructors/helpers and zero-parameter wire
   bytes stable. Preserve ordered exact parameter identity in names/hash/wire.
2. **Non-widening adapters**: keep `simple_aggregate_column_type.cr` explicitly
   scalar/outer-nullable, and preserve Count argument admission if shared
   syntax is extracted from `binary_aggregate_count_argument_name_reader.cr`.
   Do not widen `ObjectRecursiveDeclarationText`. The bounded consumer
   inventory is the SAF descriptor/constructor/codec/name budget, Bulk
   declaration/support, public batch/offline adapters, legacy typed storage
   plans and Count argument parser (`rg` over these identifiers).
3. **Physical owner**: update `simple_aggregate_bulk_column_declaration.cr`
   and measured public dispatch in `wide_part.cr` and
   `wide_part_table/binary_bulk_column_adapter.cr` only as required. Keep an
   explicit static-profile predicate distinct from logical admission.
   LC/JSON/Dynamic/Variant/QBit and unqualified child metadata stay physical
   guard-only; no new per-product serializer is introduced.
4. **Paired falsifiers**: use the existing-API admission seed and
   `simple_aggregate_recursive_w222_part_spec.cr`, add matrix-derived
   parameter/identity/budget negatives, and stock-authored parts plus
   library-authored ATTACH/CHECK counterparts. Literal values, empty children,
   exact descriptor identity and first/middle/final-short/empty windows must be
   compared independently of production admission tables.
5. **Verification**: run the focused and bounded affected spec roster in
   DEBUG and RELEASE, serialized through the resource guard; expected signal
   is zero failures/errors/pending. Run fresh native paired evidence and raw
   artifact audit, then a proportionate hostile review. A passing synthetic
   child round trip alone cannot close the physical/public claim.

The paired baseline RED also compiled and executed through the guard:
`crystal spec spec/simple_aggregate_recursive_w222_part_spec.cr` with the same
single-module/thread/link flags. Observed exit 1: nine examples, zero assertion
failures, nine admission exceptions, zero pending. All stop before publication
because the recursive declarations are not admitted. Raw log:
`/private/tmp/crystal-click-w222-matrix.oWGPOF/paired-red-debug.log`.

## Stock-authored physical witness basis

Root inspected and executed `scripts/probe_simple_aggregate_physical_w222.rb`
through the serialized guard in fresh root
`/private/tmp/crystal-click-w222-physical.jmter1`. The frozen 39-profile roster
passed CREATE, RowBinary INSERT, source `CHECK TABLE`, exact `system.columns`,
`toTypeName`, `columns.txt`, part/grid checks and independent literal full,
middle and empty RowBinary comparisons. It includes mapped-array aliases,
positive caps, nested Array, Map/Array, named Tuple and Array(named Tuple),
three time-series products, prior nullable controls and both explicit String
serialization profiles. Source copies are byte-inventoried after quiescence.

Observed raw inventory: 119 process records, all exit 0; no signals, timeouts
or spawn failures. All 39 physical profiles matched; no construction mismatch,
physical mismatch or probe failure. This is a finite witness basis, not an
exhaustive Cartesian qualification or a library read/write certificate.

The first physical probe root `crystal-click-w222-physical.d813h3` is retained.
It stopped before any CH process because its manifest asserted 37 profiles
while actually defining 36. The corrected roster adds the intended capped
numeric Array and capped Map(String, Array(UInt8)) products (both String
modes), rather than weakening the existing assertions to manufacture green.

The paired native and unit DoD is now executed below. This source witness by
itself is not used as the library compatibility certificate.

## Result-identity adversary

The shared codec must not erase Tuple field identity. Root traced
`AggregateFunctionSumMap.cpp:119-174` (unnamed result Tuple) and
`DataTypeTuple.cpp:234-249` (element names participate in equality), then ran
four bounded stock processes in fresh root
`/private/tmp/crystal-click-w222-named-counterexample.V4ITd9`.
`sumMap`, `minMap` and `maxMap` with storage
`Tuple(keys Array(Int32), values Array(Int64))` each refused with Code 36,
exit 36, specifically reporting incompatible result/storage types. `anyLast`
with the same storage succeeded and described the nominal type (the runtime
canonically quotes reserved field `values`). The logs retain all four outcomes.

Thus arbitrary named mapped-array Tuples must not inherit the unnamed-result
admission rule; named Tuple identity under `anyLast` remains separate. The
single-argument TimeSeries factory also preserves its input tree rather than
constructing an unnamed result (`AggregateFunctionTimeSeriesGroupArray.h:185-188`). This is a
logical result law, not a reason to duplicate Tuple serializers.

## Implemented composition and executed unit gate

The neutral recursive name reader, function-specific admission owner and typed
parameter owner each have their own file. The private Count grammar reader is
replaced by the shared neutral reader; its adapter preserves the previous Count
argument policy rather than inheriting the broader SAF admission policy.
Existing child codecs own the bytes. The SAF declaration adapter owns nominal
identity and the finite static-profile admission, not a serializer per product.

The descriptor now represents nineteen canonical function identities. The pinned
source's twenty-two factory spellings include three mapped-array aliases; those
spellings are not three extra canonical identities. Required/optional positive
UInt64 parameters use the stock Field/VarUInt wire representation and participate
in names, equality, hash and parser budgets. Unsupported parameter count is
rejected before reading or reserving its metadata. A truncated otherwise legal
parameter remains corruption, not an admission refusal.

Root executed the same 49 unique spec files in seven serialized cohorts in each
of DEBUG and RELEASE: 261 examples per mode, zero failures, errors or pending.
Per-cohort counts are 25, 52, 43, 45, 36, 23 and 37. This is the bounded affected
roster, not the repository-wide suite. Raw logs are
`/private/tmp/crystal-click-w222-matrix.oWGPOF/final-{debug,release}-{0..6}.log`.
The unit input freeze is `source-freeze.sha256` in that same root. Subsequent
helper/runner fixture corrections are separate from those compiled spec inputs.

The physical/public claim is deliberately **root-SAF-column scoped**. Generic
low-level descriptors can represent, for example,
`Array(SimpleAggregateFunction(anyLast, Array(UInt8)))`; these nested-SAF shapes
are not covered by the 39-profile paired native matrix. The root declaration
guard is not a universal guard for every arbitrary enclosing descriptor. Such
representability neither qualifies that physical product nor proves it corrupt.
Legacy scalar accessors and Count admission remain narrower than the recursive
bulk `BinaryValue` route.

## Paired native qualification and adversary

Root built separately pinned DEBUG/RELEASE helpers with single-module, single
thread and macOS linker flags, then executed fresh paired matrices:

| Mode | Evidence root | Helper SHA-256 |
| --- | --- | --- |
| DEBUG | `/private/tmp/crystal-click-w222-bulk.aK9o9n` | `4390d48fb49aedc8a3b09709bcc7746780c3c11400b89ca709e17f5e5c157a19` |
| RELEASE | `/private/tmp/crystal-click-w222-bulk.n1d8XE` | `6def2f6f75ca01f7ebfc892d730d5c7c272aeb172da513e5fb960abfd5db05a3` |

Each mode passed all 39 stock reads, 39 library writes/reads, public borrowed
batch and detached `.values` comparisons, and 39 stock ATTACH/CHECK witnesses.
Reader windows are full, first, middle, final-short, first-zero and EOF-zero;
the public schedule is exactly `[[0,0,2],[1,2,2],[2,4,1]]`. Stock independently
compares full, middle and empty RowBinary output against literal fixture bytes
(117 windows per mode). Each paired root has 43 actual successful subprocess
records: two runtime pins, the helper, target creation, and 39 native cases.

A separately executed read-only audit passed both roots with externally
measured helper hashes. It reconciles raw argv/status/stdout/SQL, nominal types,
literal RowBinary bytes and complete inventories. All original part files stay
unchanged; ATTACH adds only the exact source-backed
`invalidated_system_columns.txt` auxiliary with two permitted names. Cross-mode
comparison found all 626 generated file entries equal for the 39 profiles.
The pinned helper asserts exact recursive public values internally; audit of
its report is not independent re-execution of those Crystal assertions.

Root changed one native process status from success/exit 0 to failure/exit 13
while leaving the green summary and matrix bytes unchanged. The audit exited 1
at that raw process. Exact hash restoration returned the audit to exit 0.
The parameter-count/budget/truncation discriminator, named-Tuple result-law
counterexample and affected legacy/Count regressions also passed. Luna's static
review is same-lineage/correlated; root checked source, ownership seams, actual
commands, raw records, inventories and the executed negative independently.

Qualification defects are retained, not counted as type refusals: helper Tuple
fixture returned an Iterator instead of Array; an initial root had the wrong
fixed prefix; runner confused original/copy paths and presumed stock's empty
`detached/` absent; audit expected a missing SQL-sidecar newline and a missing
`system.parts.path` trailing separator. These corrections affect only test
infrastructure. No production guard was relaxed to obtain native green.

Source lineage: the 26-entry unit freeze matches all production/spec inputs.
Only the helper, runner and auditor changed afterward and were executed in
their corrected states. The final 1,278-file source/spec/script freeze is
`/private/tmp/crystal-click-w222-matrix.oWGPOF/source-freeze-final.sha256`, SHA-256
`0a8e79722886243b050fdabadeebfefd7c36fd76f4eac2fdef8526c09d22f0e9`;
root verified every entry. Exact commands, raw roots and diagnostic lineage are
indexed in [the W222 evidence packet](../.landmark/evidence/simple-aggregate-recursive-w222.json).

This does not close arbitrary nested-SAF low-level products, LC/Nested/JSON/
Dynamic/Variant/QBit children, outer-Nullable collection physical storage,
Compact parts or other mark/compression/serialization layouts, arbitrary
function/parameter/storage domains, aggregate evaluation or non-Count state
formats. Existing static owners assume quiescent parts and logical budgets,
not payload-hash authentication, peak RSS or faster execution. Full catalog
discovery, MV/projection semantics/writing and broad facade decomposition remain
open. The full goal is active; memory/performance remains deferred.

Evidence decays when relevant admission/codec/physical/context/public owners,
fixture/oracle tools, runtime binary or source reference change. Refresh the
affected unit roster and raw native/audit gates before reusing the scoped
compatibility claim. Revert the coherent W222 commit for local rollback; no
remote push or history rewrite is part of this slice.
