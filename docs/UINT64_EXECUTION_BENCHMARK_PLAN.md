# UInt64 Execution Benchmark Plan

Status: **four-track implementation and bounded controlled benchmark complete**.

Risk: **CAUTION**. This adds a reusable performance-measurement harness, so
timing and allocation proxies must not be promoted to correctness or universal
performance claims.

Rollback: remove the five owned benchmark files. The harness does not alter
production reader or aggregation code, persistent data, fixture contents, or
the existing benchmark runners.

## Definition of done

Required commands:

```text
CRYSTAL_CACHE_DIR=/private/tmp/crystal_click_uint64_execution_benchmark_focused \
  crystal spec spec/uint64_execution_benchmark_spec.cr \
  --link-flags="-fuse-ld=ld" --error-trace

bash -n scripts/bench_uint64_execution_pipeline.sh

BENCH_CLICKHOUSE_TRACK=required \
  ./scripts/bench_uint64_execution_pipeline.sh --smoke

BENCH_CLICKHOUSE_TRACK=required BENCH_CACHE_REGIME=warm_shared \
  ./scripts/bench_uint64_execution_pipeline.sh --smoke

crystal tool format --check
git diff --check

crystal spec --link-flags="-fuse-ld=ld" --error-trace
crystal spec --release --link-flags="-fuse-ld=ld" --error-trace
```

Controlled campaign (requires a public/generated fixture with at least 64 MiB
decoded):

```text
scripts/generate_real_reader_benchmark_fixture.sh <fixture-dir> \
  --rows 10000000 --codec delta-zstd
BENCH_CLICKHOUSE_TRACK=required BENCH_CACHE_REGIME=natural_unknown \
  scripts/bench_uint64_execution_pipeline.sh <fixture-dir>

BENCH_CLICKHOUSE_TRACK=required BENCH_CACHE_REGIME=warm_shared \
  scripts/bench_uint64_execution_pipeline.sh <fixture-dir>
```

Expected signals:

- focused spec is green and rejects unknown tracks/cache labels, unbounded
  scratch, and mismatched independent expected values;
- smoke is verified but explicitly not performance evidence;
- every accepted route reports exact count/sum/min/max and positive elapsed
  time; Crystal additionally reports GC deltas, retained-row/container state,
  and a structured JSON record;
- the required ClickHouse smoke admits only the verified version/codec/marks
  combination, proves its active data/mark streams match the source bytes, and
  independently verifies `value == _part_offset` for every row;
- controlled mode refuses fewer than seven repetitions or less than 64 MiB;
- shell syntax, formatter, and diff checks pass.
- full debug and release suites remain green.

## Steps and evidence

1. **RED contract — complete.** The new focused spec initially failed because
   `benchmarks/uint64_execution_pipeline.cr` did not exist.
2. **Four route implementation — complete.** The Crystal harness measures
   owning `Array` read+reduce, borrowed `WidePartSet#scan_into`+reduce, and
   `WidePartSet#aggregate_uint64` over the same staged immutable part. The shell
   runner attaches the same physical streams to verified ClickHouse local and
   measures the exact equivalent aggregate query.
3. **Fail-closed acceptance — complete.** Expected values are derived by the
   shell runner from the declared `0..rows-1` contract. The child validates
   parity before emitting JSON; the runner validates every field again. Untimed
   Crystal positional scan and ClickHouse `_part_offset` preflights independently
   reject reordered fixtures with the same scalar aggregates.
4. **Process and order controls — complete.** Each timed observation invokes a
   fresh release child or ClickHouse local process. Repetitions rotate the four
   tracks, and `warm_shared`/`natural_unknown` are the only cache labels.
5. **Measurement qualification — complete.** Timer, GC, retained-container,
   scratch, and optional `/usr/bin/time` RSS fields have explicit units and
   availability states. No cold-cache claim is emitted.
6. **Controlled campaign — complete.** Natural and warm runs each accepted 56
   observations over a generated 10,000,000-row Delta+ZSTD part. All four
   tracks matched the independent aggregate, and the ClickHouse active streams
   remained byte-identical to the source. The first generated-fixture attempt
   exposed a literal `\n` in the compressed-marks DDL and failed before timing;
   the corrected DDL passed both controlled regimes.

## Adversary checks

The strongest likely failure is an implementation or parser that makes all
tracks agree on a shared aggregate oracle. The exact positional preflights in
both Crystal and ClickHouse, scalar aggregate checks, and source digest guard
attack that route. A second failure is interpreting GC/RSS as a scalar quality
score; the output keeps them as separate measurements and marks unavailable
RSS explicitly.

The ClickHouse track fails closed outside its verified version, codec, and mark
format contract. Table creation and part attachment are untimed, and the active
part's physical stream digest must match the source before observations begin.

## Residual risks

- The generated-sequence contract does not cover arbitrary UInt64 value
  distributions or multi-column workloads.
- `natural_unknown` gives no cache-state guarantee, and `warm_shared` warms via
  a separate child rather than proving a particular OS cache state.
- `/usr/bin/time` RSS depends on host permissions and format; unavailable is a
  valid result.
- Crystal `elapsed_ns` and ClickHouse `query_elapsed_ns` come from different
  timer authorities and exclude different setup layers; they support a scoped
  execution-path comparison, not a whole-process lifecycle claim.
- The controlled run has only seven observations per cell and includes a few
  bounded outliers; it supports the recorded medians, not confidence intervals.
- Results decay with host, compiler, GC, fixture producer, format, or reader
  changes and must be rerun rather than copied forward.
