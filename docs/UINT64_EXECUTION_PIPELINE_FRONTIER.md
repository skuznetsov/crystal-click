# UInt64 Execution Pipeline Frontier SDD

Document status: **completed + VERIFIED** within the declared scalar UInt64
aggregate scope. Final adversary verdict: **ROBUST**.

Current frontier: add the smallest execution slice above the existing
deterministic `WidePartSet` borrowed scan:

```text
multi-part UInt64 scan -> scalar predicate -> COUNT + SUM + MIN + MAX
```

The pipeline consumes each borrowed batch synchronously and returns one owning
aggregate result. It does not materialize selected rows.

Bounded context: one physical `UInt64` column across a caller-declared immutable
root of non-overlapping Wide parts, using the current part discovery, checksum
status, codec, mark, mmap, provenance, and scratch-lifetime contracts.

## Sealed API and semantics

```crystal
struct UInt64AggregateResult
  getter count : UInt64
  getter sum : UInt64
  getter min : UInt64?
  getter max : UInt64?

  def empty? : Bool
end

class WidePartSet
  def aggregate_uint64(
    scratch : Slice(UInt64),
    &predicate : UInt64 -> Bool
  ) : UInt64AggregateResult

  def aggregate_uint64(scratch : Slice(UInt64)) : UInt64AggregateResult
end
```

The predicate is evaluated exactly once per decoded row in existing
part/mark/row order. The overload without a block admits every row.

`count` is the number of matching rows. The current
`WidePartSet::MAX_TOTAL_ROWS` bound makes `UInt64` count overflow unreachable,
but the reducer still uses a checked increment so the invariant survives future
limit changes.

`sum` uses UInt64 modular addition. This deliberately matches current
ClickHouse `sum(UInt64)`: `NearestFieldType<UInt64>` and its accumulation state
are `UInt64`. This is not `sumWithOverflow` naming, checked arithmetic, or an
exact mathematical sum. An empty match set has `count == 0`, `sum == 0`, and
`min == nil`, `max == nil`; `empty?` is true. A nonempty zero-only set has
non-nil `min/max == 0` and `sum == 0`.

Predicate, decoder, callback, and invariant errors propagate without returning
a partial aggregate result. The lower-level scan remains progressively
observable to its own callers; the new aggregate API is return-or-error.

## Admitted surface

- All-row and block-filtered aggregation over one `WidePartSet` UInt64 column.
- One scalar pass updates count, modular sum, min, and max together.
- Caller-owned writable non-empty scratch retains its current validation and
  aliasing contract.
- Tiny and non-dividing scratch sizes, mark boundaries, part boundaries,
  direct LZ4, direct ZSTD, and exact Delta/ZSTD remain valid inputs.
- The predicate receives only a scalar value, never a borrowed batch, path,
  part name, or mutable engine state.
- No selected-value array, batch retention, or result slab is allocated by the
  pipeline.

## Rejected surface

- SQL parsing, expression trees, nullable/LowCardinality types, casts,
  three-valued logic, aliases, or SQL empty-aggregate defaults.
- Multi-column predicates, projection, GROUP BY, ORDER BY, LIMIT, joins,
  parallel scans, distributed execution, or vectorized predicate masks.
- Predicate pushdown, mark pruning, indexes, PREWHERE, partition pruning, or
  active-part discovery.
- Exact/widened/checked sum semantics. A future exact UInt128 aggregate must be
  named separately and compared against a matching ClickHouse expression.
- Retaining `UInt64ScanBatch`, its values slice, or any reference to caller
  scratch after the scan callback.
- A zero-allocation or performance-winner claim. The pipeline owns only its
  constant-size result state; decoding, predicates, and caller setup may still
  allocate.

## Design laws

1. The aggregate loop consumes `batch.values` completely before returning from
   that batch callback and never stores the batch or slice.
2. Predicate evaluation order equals the existing deterministic source order
   and occurs exactly once for every decoded row, including rejected rows.
3. Count increments only for matches and fails closed on impossible overflow.
4. Sum uses explicit `&+` modular UInt64 addition; accidental checked `+` or a
   widened hidden accumulator is a semantic bug for this API.
5. Min and max initialize from the first matching value, never from a sentinel.
6. Empty and nonempty-zero results are distinguishable through count and
   optional extrema.
7. Any exception prevents a result from being returned; no durable state is
   mutated.
8. Correctness and structural non-retention precede benchmark claims.

## Falsifier roster

| Falsifier | Required signal | Boundary |
| --- | --- | --- |
| RED API | Focused spec initially fails because `aggregate_uint64` is absent | Historical TDD evidence |
| All rows | Multi-part count/sum/min/max equals an independent expected sequence | Basic reducer |
| Deterministic predicate | Side-effect trace sees every decoded value exactly once in source order | Execution order |
| Scratch shapes | Tiny, mark-crossing, and non-dividing scratch sizes return identical aggregates | Borrowed transport |
| Empty vs zero | All-false returns `0, 0, nil, nil`; zero-only returns `count > 0, 0, 0, 0` | Initialization |
| UInt64 overflow | Matching `UInt64::MAX` values wraps through explicit modular addition exactly like ClickHouse `sum(UInt64)` | Sum semantics |
| Error atomicity | Predicate exception and later decoder corruption return no result and preserve the original typed error | Return-or-error |
| Scratch precondition | Empty/read-only scratch fails before predicate invocation | Validation order |
| Structural route | Source inspection shows scalar accumulator state, synchronous batch consumption, and no selected-value `Array`, `to_a`, retained batch, or stored borrowed slice | O(1) reducer state; structural evidence only |
| Repository regression | Focused, full debug, and full release suites pass | Current checkout |

## Stop rules and rollback

- Stop if predicate order differs from the source scan, a predicate is invoked
  twice, or a borrowed batch escapes its callback.
- Stop if sum overflow raises, silently widens, or uses a semantics not named by
  this API.
- Stop if empty extrema use `0` sentinels or cannot distinguish an empty match
  from matching zeroes.
- Stop if implementation requires modifying part discovery, decoder semantics,
  mmap lifetime, or adding shared mutable engine state.
- Rollback is one atomic pipeline commit containing implementation, focused
  specs, and these docs.

## Observed verification

- Historical RED: focused compilation failed because `aggregate_uint64` was
  absent from `WidePartSet`.
- Focused pipeline suite: **8 examples, 0 failures, 0 errors, 0 pending**.
- Relevant pipeline/multipart/streaming/Delta suite: **37 examples, 0 failures,
  0 errors, 0 pending**.
- Full debug suite: **137 examples, 0 failures, 0 errors, 0 pending**.
- Full release suite: **137 examples, 0 failures, 0 errors, 0 pending**.
- `crystal tool format --check` and `git diff --check`: pass.
- The source-order falsifier uses different Delta and LZ4 sequences and
  observes the discriminating cross-part boundary
  `[4093, 4094, 4095, 0, 1, 2]`.
- Source inspection confirms direct `yield`, scalar-only accumulator state,
  synchronous `batch.values` consumption, and no stored borrowed batch/slice.

The initial adversary verdict was **VULNERABLE** because two identical part
sequences made the original order test non-discriminating. The corrected
boundary test closes that gap. Final verdict: **ROBUST** within the sealed
frontier. Count overflow remains unreachable under the current total-row bound;
predicate allocation/throughput is unmeasured and no performance claim is
admitted.

## Ledger and seal

- Implementation owner: a new `src/crystal_click/uint64_execution_pipeline.cr`
  plus one require in `src/crystal_click.cr`; existing scan code should remain
  unchanged unless a failing invariant proves otherwise.
- Focused spec owner: `spec/uint64_execution_pipeline_spec.cr`.
- ClickHouse semantic authority at revision
  `066ea77cf4221959f9f8dc615f6ce776521b52ff`:
  `AggregateFunctionSum.cpp` selects `NearestFieldType<T>` for ordinary sum;
  `AggregateFunctionSum.h` keeps `AccumulateResultType<UInt64>` as `UInt64`.
- Design status: **sealed**.
- Implementation status: **completed + VERIFIED** within the declared scope;
  final adversary verdict **ROBUST**.
