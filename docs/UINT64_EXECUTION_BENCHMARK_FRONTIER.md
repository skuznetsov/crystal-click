# UInt64 Execution Benchmark Frontier

Document status: **four-track harness and bounded controlled campaign VERIFIED**.

This frontier measures four equivalent scalar aggregate routes over one
immutable Wide `UInt64` part whose generated values are exactly `0..rows-1`:

```text
owning Array read + reduce
borrowed WidePartSet#scan_into + reduce
WidePartSet#aggregate_uint64
ClickHouse local count/sum/min/max query over an attached copy of the same streams
```

The harness is a bounded decode-and-aggregate measurement aid. It is not a
whole-engine benchmark, a SQL compatibility claim, or a claim that one route
wins on every host.

## Workload and evidence boundary

- The input is one public or generated single-column Wide part with column
  `value UInt64`, an independently checked `count.txt`, and the deterministic
  sequence `0..rows-1`.
- Smoke mode uses the committed public 200,000-row part and is explicitly
  `performance_observations_eligible=false`.
- Controlled mode requires at least 64 MiB decoded (`rows * 8`) and defaults to
  seven repetitions with two bounded scratch sizes. A generated 10,000,000-row
  part from the existing fixture generator satisfies this threshold.
- The runner derives expected count, sequence sum, minimum, and maximum before
  starting observations. Every route must match all four values before its
  observation is accepted.
- An untimed Crystal preflight compares every decoded value with its physical
  zero-based position. When ClickHouse is admitted, an independent untimed
  `_part_offset` query performs the same exact-sequence check. This rejects
  reordered payloads that share count/sum/min/max.
- The source and staged copy are tree-digested before the run and rechecked
  around every observation. When the ClickHouse track is admitted, the `.bin`
  and `.mrk2`/`.cmrk2` stream digest of its active attached part must equal the
  source stream digest. A mutation, copy mismatch, or malformed result fails
  the run.

Staging the physical part, creating the ClickHouse table, attaching the part,
and opening Crystal metadata are outside the timed interval. The Crystal timer
covers its route's decode and reduction. The ClickHouse timer is the engine's
reported query elapsed time. Those boundaries are close enough for a bounded
execution-path comparison but are not identical lifecycle measurements.

## Measurement contract

Each timed Crystal observation starts a fresh `--release` subprocess; each
ClickHouse observation starts a fresh `clickhouse local` process against the
already attached table. Track order rotates across repetitions and scratch
matrix positions so a fixed first/last-track effect is not mistaken for a route
property. The only cache labels are:

- `warm_shared`: a separate child reads the same workload before each timed
  child;
- `natural_unknown`: no dedicated warmup runs immediately before a timed child.
  Staging and untimed sequence preflights may affect the cache, so its state is
  deliberately unspecified.

The runner never flushes caches and emits `cold_cache_claim=false`.

Each Crystal child emits one compact structured JSON record containing:

- track, cache label, bounded scratch size, exact aggregate parity, and positive
  `elapsed_ns`;
- `gc_total_bytes_delta`, `gc_collections_delta`, and
  `gc_metrics_available`;
- `retained_rows` and `container_state` (`array_owned`,
  `borrowed_scratch_only`, or `aggregate_result_only`).

The shell runner adds `/usr/bin/time` maximum RSS only when its output is
reliably parsable. Missing RSS is reported as unavailable, never fabricated.
For ClickHouse, GC and retained-row fields are unavailable and the separate
`query_elapsed_ns` field records `--time`. The matrix scratch value balances
ordering and sample count; it is not a ClickHouse parameter, and the owning
Array route also does not consume it.

Elapsed time, GC, and RSS are vector measurements for orientation. They are not
collapsed into a single score and are not release gates for a performance
winner. Correctness parity and fixture immutability are the hard gates.

## Admitted, rejected, and guard-only surface

Admitted:

- one scalar `UInt64` column and one physical Wide part;
- owning Array, borrowed `scan_into`, `aggregate_uint64`, and verified local
  ClickHouse tracks;
- exact count/sum/min/max parity for the declared generated sequence;
- bounded caller scratch, fresh release children, rotated order, and the two
  cache labels;
- local GC/RSS instrumentation with explicit availability states;
- ClickHouse local version `26.7.1.1315`, exact `UInt64` aggregate output, and
  byte-identical data/mark streams after `ATTACH PART`.

Rejected:

- cold-cache claims, cross-host rankings, statistical confidence intervals, or
  a universal throughput/GC winner;
- private fixture identifiers, values, paths, checksums, or raw workload
  payloads in committed benchmark documentation;
- SQL parsing, planning, predicate pushdown, multiple columns, parallelism,
  distributed execution, nullable semantics, or exact widened sums.

Guard-only / pending:

- other ClickHouse versions, unidentified fixture codecs, or unrecognized mark
  formats. `BENCH_CLICKHOUSE_TRACK=required` fails closed; `auto` records why
  the track was omitted, and `off` deliberately disables it.

## Falsifier roster

| Falsifier | Required signal | Current state |
| --- | --- | --- |
| Focused RED | Missing benchmark module makes the focused spec fail | Captured before implementation |
| Four-track parity | All tracks match independent count/sum/min/max | Natural and warm smoke plus controlled PASS |
| Same physical bytes | ClickHouse active `.bin` and marks digest equals source | Smoke and controlled PASS |
| Exact sequence | Crystal positional scan and ClickHouse `_part_offset` query both find `0..rows-1` | Smoke and controlled PASS |
| Compressed-marks DDL | Generated `.cmrk2` part attaches without guessed syntax | Initial literal `\n` failure captured; corrected controlled PASS |
| Borrowed boundary | Tiny/non-dividing scratch preserves parity | Focused spec PASS at 73 slots |
| Fresh process/order | Four tracks occur in each rotated repetition | 56 observations per controlled cache regime PASS |
| Retention declaration | Array retains rows; borrowed/pipeline retain no rows | Focused spec and smoke PASS |
| Mutation guard | Source/staged digest mismatch aborts before acceptance | Runner enforces |
| RSS qualification | Unparsable `/usr/bin/time` RSS is marked unavailable | Smoke observed unavailable, no invented value |
| Proxy discipline | Smoke is ineligible, no winner/cold claim is emitted | PASS |

## Verification scope and decay

Observed locally on the current checkout:

- focused benchmark spec: **4 examples, 0 failures, 0 errors**;
- full debug and release suites: **141 examples, 0 failures, 0 errors** each;
- natural and warm smoke runner: **4 fresh observations each, exact parity,
  same physical streams, verified output**;
- smoke rows: 200,000 and 1,600,000 decoded bytes;
- smoke output explicitly reports `performance_observations_eligible=false`,
  `performance_winner_claim=false`, and `cold_cache_claim=false`.

The controlled campaign used Crystal 1.21.0 and ClickHouse local 26.7.1.1315 on
macOS 26.6.2, with one generated 10,000,000-row Delta+ZSTD part (80,000,000
decoded bytes). Each cell contains seven observations; times below are medians
in milliseconds:

| Cache label | Scratch matrix | Array | Borrowed | Pipeline | ClickHouse query |
| --- | ---: | ---: | ---: | ---: | ---: |
| `natural_unknown` | 4096 | 120.886 | 123.851 | 104.858 | 75.000 |
| `natural_unknown` | 8191 | 122.945 | 124.499 | 106.527 | 76.000 |
| `warm_shared` | 4096 | 122.594 | 124.032 | 104.647 | 76.000 |
| `warm_shared` | 8191 | 123.043 | 124.488 | 105.186 | 76.000 |

Across the four cells, pipeline elapsed time was 14.4-15.6% below borrowed and
13.3-14.6% below the owning Array route. Every paired repetition preserved both
relations. Median Crystal GC deltas were 65,888 bytes and zero collections for
borrowed/pipeline, versus 432,766,880 bytes and 8-9 collections for Array.
ClickHouse query medians were 27.4-28.7% below pipeline, but this is only a
scoped execution-path comparison because the timer authorities and excluded
setup layers differ. RSS was unavailable, so no RSS conclusion is admitted.

The warm 4096 cell contained isolated Array and borrowed maxima of 166.094 ms
and 185.110 ms, versus medians of 122.594 ms and 124.032 ms. Medians and the
paired ordering survived, but seven samples per cell are enough only for this
bounded observation, not confidence intervals or a universal ranking. The
Array and ClickHouse routes do not consume the scratch value; differences
between their scratch-matrix cells are noise/order, not a parameter effect.

Evidence must be refreshed when the fixture producer, Wide-part format,
Crystal/GC or ClickHouse version, host, benchmark code, or reader/pipeline
semantics change. These measurements describe only the named workload, host,
and cache label.
