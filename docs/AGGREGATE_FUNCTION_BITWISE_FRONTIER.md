# AggregateFunction bitwise state frontier (W255)

Status: VERIFIED; root adversary ROBUST within the finite declared target.
Baseline: `8119e11b35c1e0647e649fc177223e93f3573c8e` (clean tree).
Context: immutable aggregate-state storage, not aggregate execution.

## Source law and bounded change

Reference source: ClickHouse `ed30948f095ecb70679986d7d60e27ad770ae27a`,
`/private/tmp/clickhouse-w254-upstream.AqeqyC` (shallow official checkout).
Runtime oracle is separately pinned: 26.10.1.1201,
build `d9bcb5ab007f0f6299f7f973f2642245bab3d028`, SHA256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
The source checkout is not the runtime build.

`AggregateFunctionBitwise.cpp:42-103,262-269,343-359` and
`Helpers.h:91-123` define unary, zero-parameter `groupBitOr`, `groupBitAnd`,
and `groupBitXor` over exactly UInt8/16/32/64/128/256 and
Int8/16/32/64/128/256. States are one dispatched integer word: OR and XOR
initialize to zero; AND initializes to all ones. `writeBinary`/`readBinary`
serialize raw native-format words. Qualification is for the pinned
little-endian runtime, not a new cross-endian wire-format promise.

Current `SimpleAggregateFunction(groupBit*, T)` support is a scalar-storage
capability and does not admit `AggregateFunction(groupBit*, T)` state types.
At baseline, the latter were rejected by both nominal admission and wire-name
admission. Their state framing reuses the existing fixed-width owner.

Design-sealed surface:

- The three exact function names, the 12 bare integer argument descriptors,
  AggregateFunction version zero, unary arity, no parameters.
- Exact SQL-name and binary-descriptor identity; validated immutable state
  bytes whose length equals the dispatched integer width.
- Existing recursive value/bulk codecs, physical visitors and public generic
  Wide/table/offline consumers. No container-specific codec is added and no
  contextual guard is relaxed. Code-level reuse is not qualification of every
  native layout/product.
- Native qualification target: one Wide/LZ4/Default/plain-mrk2 schema containing
  all 36 root signatures and an Array(Tuple(...)) state column, six parent rows
  in three marks, ragged/empty child occurrences, asymmetric wide signed and
  unsigned patterns, and stock empty aggregate states. Both directions must
  preserve exact declarations, values/state bytes, windows and terminal marks.

Rejected / guard-only:

- Bitwise argument Nullable/LowCardinality shells, Bool, Float/BFloat, Decimal,
  Enum, temporal, IP/UUID, containers and other non-integer argument leaves.
  Existing Sum/Avg/MinMax argument profiles remain unchanged.
- Nonzero versions, parameters, non-unary signatures, new families and
  combinators. Preserve Count-specific guards and all existing contextual
  state-envelope and Map-key exclusions.
- No new Compact, MV/projection writer, SQL execution/finalization,
  memory/RSS/throughput or complete Cartesian-product compatibility claim.

## Parked branch: legacy statistics-free Object prefixes

Root source inspection discriminated the preceding candidate:
`SerializationObjectSharedData.cpp:375-391` creates fresh settings and forces
Dynamic V3, Object V3 and statistics mode NONE for nested Advanced Data tapes;
only the nested shared-data layout is inherited. Thus removing local V3-only
inline guards does not widen current stock persisted-tape compatibility.
Keep complete legacy Object statistics mandatory. Generic Native and possible
historical/foreign legacy prefixes remain unqualified; they are not declared
impossible or implemented by this slice.

## Execution plan, falsifiers and rollback

Risk: CAUTION (nominal descriptor and persistent state admission).
Rollback: one exact-path atomic local feature commit; no remote operation or
dependency change. Preserve the clean baseline and unrelated subsequent work.

1. Behavioral admission RED on the existing API, then core/recursive tests.
2. Add a small one-file integer argument policy; wire it through
   `binary_aggregate_function_admission.cr`, `binary_data_type_codec.cr`,
   `binary_aggregate_function_state_plan.cr`, and the explicit loader.
   Keep the generic state codec, writer, recursive visitor and consumers.
3. Prebuilt helper and bounded native runner for reciprocal parts; independent
   expected bytes, declarations and process-status checks, not reader/writer
   agreement alone.
4. Root source/diff review; focused plus affected regressions in DEBUG and
   RELEASE, executed hostile controls, evidence/status update and local commit.

Consumer inventory: bounded searches over `TAG_AGGREGATE_FUNCTION`,
`function_name`, `sumKahan` and aggregate state owners found the two admission
gates; the canonical SQL reader delegates to construction. Static Wide input
uses `BinaryAggregateFunctionBulkColumnDeclaration`; Dynamic/Variant/Object
owners retain their separate existing contexts. No shared wire tag is added.

Falsifiers: AND default versus zero; all 36 names/widths; asymmetric signed and
wide state bits; truncated/trailing bytes and nominal state substitution;
Count accessor on a bitwise state; rejected argument/parameter/version/arity
forms; recursive byte/depth/node budgets; ragged Array child versus parent
coordinates; null Tuple defaults; empty windows and physical EOF coordinates.
Reject a forged green native report when exit status or CHECK result differs.

DoD: root-only serialized guarded Crystal commands (`run_safe.sh`, minimum free
memory 50%, workers/threads 1, single module) run the W255 specs and declared
affected regression roster in DEBUG and RELEASE with zero failures/errors/
pending. Build a helper separately in both modes. Run the W255 native runner
with the pinned CH binary; stock-authored reads and library-authored
ATTACH/CHECK/exact-state reads must pass. Record exact commands, observed counts,
pins and adversary results only after execution.

Stop or narrow if stock state bytes or metadata differ; do not change neutral
states, declarations, process checks or physical guards merely to pass an oracle.
The global types/MV/projection goal stays active; performance stays deferred.
Refresh qualification when admission, state plans, generic consumers, physical
contexts, source/runtime pins or helper artifacts change.

## Observed qualification and continuation

The baseline admission RED compiled and ran: two examples, one failure, no
errors/pending, exit 1. The literal groupBitOr/UInt8 wire descriptor was rejected;
the existing Count control passed. Final affected gates use the same ordered
40-file roster: 137 + 102 = 239 examples in each DEBUG and RELEASE mode, zero
failures/errors/pending. This is an affected regression gate, not the whole suite.
Both final helpers build under the unchanged resource guard.

Two fresh reciprocal cells, DEBUG and RELEASE, each execute four bounded CH
calls and one prebuilt helper call. All 36 root declarations and the three
named Array(Tuple) lanes retain exact schema and raw state bytes. Six rows,
P=[2,2,2]+EOF, child counts [0,3,1,0,2,0], and Q=[3,1,2] cover actual empty
aggregates and ragged/empty arrays. Stock direct/window/public-table/offline
reads and library ATTACH/CHECK=1/raw RowBinary reads pass. Fixture operands are
quoted decimal strings before CAST: unquoted wide literals can pass through
the stock SQL parser's Float64 fallback and are not an exact bit oracle.

Root independently decodes 41 logical streams and four mark records per stream
across four stock/library parts. All 90 generated files / 18,553 bytes per mode
match by actual bytes. The 392 in-memory payload/default/coordinate controls,
ten forged-green nonzero-exit controls, and six actual raw CHECK=0 controls
reject at their intended audit guards. Positive native acceptance is rechecked
and original captures remain unchanged. These are fixed-fixture audit controls,
not 392 additional production tests or exhaustive corruption qualification.
Native CHECK provides checksum acceptance; the raw auditor does not separately
recompute compressed-frame checksums.

Corrected test expectations, the first helper compile error, temporary-root and
expired-default-runtime preflights, and the first native capture without the
runner's explicit label projection are excluded diagnostics. Final captures
were regenerated in fresh roots with the frozen runner.

See [root-owned evidence](../.landmark/evidence/aggregate-bitwise-w255.json) for
commands, pins and capture paths. Continue with remaining aggregate state
grammars/admission shells and unqualified physical products, then native MV/
projection writing and facade decomposition. This adds one leaf policy, not
one serde implementation per recursive product. The full goal stays ACTIVE;
memory/performance remains deferred and no remote push is included.
