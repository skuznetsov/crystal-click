# UInt64 Delta backend experiment

This is a small, guarded comparison of the existing Delta+ZSTD `UInt64`
execution path. It extends the baseline harness and evidence boundary in
[`UINT64_EXECUTION_BENCHMARK_FRONTIER.md`](UINT64_EXECUTION_BENCHMARK_FRONTIER.md);
it does not replace that frontier or establish a whole-ClickHouse performance
claim.

## Runner interface

The verified runner accepts one allowlisted backend selector:

```text
BENCH_DELTA_BACKEND=scalar      # default; typed scalar, -Ddelta_scalar
BENCH_DELTA_BACKEND=neon        # opt-in native AArch64 path, -Ddelta_neon
BENCH_DELTA_BACKEND=byte_scalar  # byte-wise control, -Ddelta_byte_scalar
```

For every accepted run, stdout includes the requested `delta_backend`, the
effective `delta_backend_effective`, and `delta_backend_compile_flags`. On a
non-AArch64 host, the `neon` selector reports
`delta_backend_effective=scalar_fallback`; this prevents the result from being
misattributed to NEON. An unknown value fails closed before the fixture is
staged. The backend choice changes only the compile-time Delta word decoder;
the runner's sequence, aggregate-parity, fixture-immutability, cache, and
timing guards remain in force. Physical-stream comparison requires the
separately enabled ClickHouse track.

For the admitted full-pipeline campaign, run each selector with the same
generated part path:

```sh
CC=/usr/bin/clang BENCH_CLICKHOUSE_TRACK=off BENCH_CACHE_REGIME=natural_unknown \
  BENCH_REPETITIONS=7 BENCH_SCRATCH_SIZES=4096 BENCH_DELTA_BACKEND=neon \
  scripts/bench_uint64_execution_pipeline.sh /path/to/wide/part
```

Substitute `scalar` or `byte_scalar` for the other controls. For the warm
decoder-only control, run `crystal run --release -Ddelta_neon
benchmarks/delta_decode_kernel.cr` and substitute the other backend flags.

## Admitted boundary

The experiment admits one generated/public Wide part with one little-endian
`UInt64` column declared as `CODEC(Delta(8), ZSTD(1))`, whose values are the
exact generated sequence `0..rows-1`. Native/NEON results are admitted only on
little-endian AArch64, where the `neon` selector enables the inline NEON pair
kernel. On other targets, the selector is the checked portable fallback and
must not be presented as AArch64 evidence. Typed scalar and byte-scalar are
controls for this same logical contract.

Smoke mode remains harness/build validation and is not performance-eligible;
the controlled 10M-row campaign is run separately. The result is scoped to
this decode-and-aggregate path and host, not SQL planning, general ClickHouse
throughput, or a universal backend ranking.

The existing reader benchmark times decompression, part traversal, and
aggregation together. A backend difference can therefore be diluted by other
reader work; a full-pipeline timing result is not a decoder-only speed claim.
Use the separately bounded
[`delta_decode_kernel.cr`](../benchmarks/delta_decode_kernel.cr) probe when
isolating the kernel's effect. It measures a warm 64 KiB Delta block only; it
does not include mmap, ZSTD, marks, part traversal, or ClickHouse query work.

## Observations on the local AArch64 host

The 10-million-row Delta+ZSTD Wide-part campaign used the same fixture and
seven repetitions per backend. Every run passed exact positional sequence,
aggregate parity, and fixture-immutability checks. The `pipeline` medians were:

| Candidate | Pipeline elapsed time |
| --- | ---: |
| Previous HEAD control, repeated near the final candidates | 110.004 ms |
| Current typed `scalar` | 111.005 ms |
| Current `byte_scalar` | 112.384 ms |
| Current opt-in `neon` | 124.938 ms |

An earlier HEAD-control median was 105.890 ms. Its subsequent 110.004 ms
median shows host/timing drift large enough that the small scalar-versus-HEAD
difference is not resolved by this campaign. The much larger NEON slowdown is
consistent with the decode-only probe below; the earlier NEON run was
128.298 ms and the earlier scalar run was 110.047 ms. Neither result promotes
NEON as the default backend.

The warm decode-only control uses one 64 KiB Delta input, 8,192 words per
iteration, 2,000 iterations per trial, and seven trials. It threads the final
accumulator into the next iteration and validates the final output. Median
times were 69.003 ms (`byte_scalar`), 8.406 ms (typed `scalar`), and 36.717 ms
(`neon`). This isolates the pair kernel from ZSTD, mmap, marks, and reader
aggregation, but does not substitute for full-pipeline measurement. On this
host, the scalar pointer loop is substantially cheaper than the inline-asm
NEON pair loop; merely using SIMD instructions is not sufficient to win on a
loop-carried prefix sum.

## Falsifiers

- Every backend must preserve the existing exact positional sequence and
  count/sum/min/max parity checks, including fixture and physical-stream
  immutability checks.
- The focused Delta spec must continue to cover wrapping prefix sums, tails,
  unaligned buffers, and both overlap directions.
- Native promotion requires generated-assembly evidence for the expected
  AArch64 NEON instructions (for example, `llvm-objdump -d <binary> | rg
  'ld1[.]2d|st1[.]2d'`); source spelling or a passing scalar-equivalent result
  alone is insufficient.

Refresh this experiment when the fixture producer, Delta decoder, Crystal
compiler, host architecture, or runner timer boundary changes.
