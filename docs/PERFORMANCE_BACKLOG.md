# Performance Backlog

Status: **deferred; no performance code changes in this task**.

Scope: one generated 10,000,000-row Wide `UInt64` Delta+ZSTD part, measured at
baseline revision `8e59ec6` before the table-reader change. These observations
do not describe arbitrary parts, other hosts, or a general ClickHouse workload.

## Pinned baseline measurement

The controlled harness used Clang, the scalar Delta backend,
`natural_unknown` cache labeling, seven repetitions, and 4,096-value scratch.
It accepted 28 observations with exact Crystal and ClickHouse positional
sequence checks, matching aggregate results, byte-identical physical streams,
and an unchanged fixture. The final-source medians and observed ranges were:

| Route | Median | Observed range |
| --- | ---: | ---: |
| Owning Array | 131.328 ms | 124.308–140.064 ms |
| Borrowed scan | 98.008 ms | 95.532–108.867 ms |
| Crystal `aggregate_uint64` route (`pipeline`) | 97.503 ms | 95.187–101.833 ms |
| ClickHouse SQL query | 82 ms | 80–85 ms |

The ClickHouse number is **not timer-equivalent** to the Crystal numbers. The
Crystal timer surrounds its decode-and-reduce route after setup; ClickHouse
reports query elapsed time for a fresh process against an already attached
part. The cache label is not a cold-cache guarantee. Keep these as scoped
observations, not a direct speed ratio or a claim about the source of any gap.
The [borrowed-scan frontier](BORROWED_UINT64_SCAN_FRONTIER.md#scoped-chunk-fill-evidence)
also records the final-source chunk-fill comparison for that baseline. Earlier
benchmark tables describe still earlier source snapshots. Refresh this campaign
before attributing a performance effect to the new table reader.

## What the source establishes

- The current Delta+ZSTD path reuses an operation-local decode workspace,
  decompresses ZSTD into it, reconstructs Delta in place, yields validated
  decoded byte spans, bulk-copies those spans into caller-owned UInt64 scratch
  on little-endian hosts, and reduces typed values. See
  [compressed_block.cr](../src/crystal_click/compressed_block.cr#L203),
  [wide_part.cr](../src/crystal_click/wide_part.cr#L83), and
  [uint64_execution_pipeline.cr](../src/crystal_click/uint64_execution_pipeline.cr#L21).
- The default scalar Delta decoder already reads and writes UInt64 words with
  little-endian helpers. Replacing byte assembly alone is therefore not an
  established opportunity. The full path still writes reconstructed Delta
  values before the scan copies them to scratch and the aggregate consumes
  them; whether fusing these steps helps is unmeasured.
- `ZSTD.decode_into` checks that the payload is exactly one ZSTD frame with
  `ZSTD_findFrameCompressedSize` before decompression
  ([zstd.cr](../src/crystal_click/zstd.cr#L23)). Crystal currently skips the
  16-byte ClickHouse compressed-block checksum, and the part metadata check is
  size-only ([compressed_block.cr](../src/crystal_click/compressed_block.cr#L80),
  [part_checksums.cr](../src/crystal_click/part_checksums.cr#L50)). The pinned
  ClickHouse source enables compressed-block checksum verification by default
  ([CompressedReadBufferBase.h](https://github.com/ClickHouse/ClickHouse/blob/066ea77cf4221959f9f8dc615f6ce776521b52ff/src/Compression/CompressedReadBufferBase.h#L25-L33),
  [CompressedReadBufferBase.cpp](https://github.com/ClickHouse/ClickHouse/blob/066ea77cf4221959f9f8dc615f6ce776521b52ff/src/Compression/CompressedReadBufferBase.cpp#L255-L256)).
  This policy difference is real; its cost has not been isolated in the final
  source run.
- Frame-output reuse is already implemented per scan. The workspace grows to a
  validated high-water size and is reused for later frames
  ([decode workspace frontier](DECODE_WORKSPACE_FRONTIER.md)). Further pooling
  or buffer retention has no measured benefit yet.
- Slabs, `struct`, and `StaticArray` can change allocation and layout, but the
  measured borrowed/pipeline routes already use reusable typed scratch for
  output. No current-source test attributes the remaining time to GC or proves
  that a different array representation would help. Keep representation changes
  as profiled experiments rather than an assumed route to ClickHouse parity.
- The earlier inline-assembly NEON experiment was slower than typed scalar on
  its measured host ([Delta NEON experiment](DELTA_NEON_EXPERIMENT.md)). This is
  a negative result for that kernel, not a current-source measurement or a
  verdict on a different LLVM-generated vector kernel.

These facts identify work in the path, not measured bottleneck shares. The
current harness does not report separate ZSTD, Delta, copy, and aggregate
timings. No GC or RSS conclusion is carried into this backlog.

## Prioritized falsifiers

| Priority | Candidate and evidence status | Probe that can reject it | Continue only if |
| --- | --- | --- | --- |
| P0 | **Checksum and timer comparability** — known measurement limitation; cost unmeasured. | Define a matched compressed-block verification policy for both paths, or keep the ClickHouse comparison explicitly non-equivalent. Separately time Crystal's frame-size validation as an opt-in measurement mode while retaining production validation. Re-run the same 10M fixture and harness checks. | The comparison uses the same integrity work and timer boundary, or is reported only as two distinct route observations. No speed-gap claim is admitted while policies differ. |
| P1 | **Typed/fused Delta decode → aggregate** — source-visible intermediate output and copy; speedup is a hypothesis. | Compare a type-safe unaligned UInt64 kernel and a fused prefix-sum/reducer against current scalar source. Preserve little-endian semantics, wraparound, tails, nonzero mark offsets, exact positional sequence, aggregates, and fixture digests. Use paired full-path runs; a decoder-only microbenchmark is supporting evidence only. | The full 10M path improves repeatably under the same harness and the current decoder remains the fallback. Typed loads alone do not qualify without a measured full-path win. |
| P2 | **Small C/FFI control, one call per frame** — language-boundary effect unmeasured. | First compare the Crystal reducer with a tiny native scalar reducer over the same decoded frame, calling across FFI once per compressed frame/chunk and never per row. Then test a fused frame kernel only if that control isolates useful headroom. Keep exact-value and mark-boundary checks. | The full route wins after FFI overhead and still passes the same parity and fixture-integrity gates. Do not wrap the full ClickHouse reader or promote C as a backend from a microbenchmark. |
| P3 | **NEON / LLVM vectorization** — the existing inline-assembly NEON kernel lost to typed scalar on its measured host; a different current-source kernel is unproven. | On little-endian AArch64, compare scalar with an LLVM-generated or revised vector prefix-sum kernel. Inspect generated assembly to confirm the intended vector operations, then run the controlled full path with identical integrity checks. | Assembly confirms the candidate and paired end-to-end runs improve. Stop if only a synthetic kernel improves, generated code is scalar, or the full path regresses. The existing experiment is a kernel-specific negative result, not evidence of a universal SIMD win. |
| P4 | **Additional buffer reuse** — frame-output workspace and caller scratch already exist; remaining benefit is unknown. | First measure allocations and time by stage. Change reuse only where the profile identifies repeated allocation or copying; compare exact output and borrowed-buffer lifetime/overwrite behavior. | A scoped full-path benefit is repeatable and the change preserves operation-local ownership, bounds, and cleanup. Do not add global pooling or longer-lived aliases without a separate contract. |

P0 is a measurement gate, not an acceleration candidate. P1–P4 are proposed
experiments only; this backlog does not authorize implementing them.

## Stop and rollback conditions

- Stop immediately if values, positional sequence, aggregate parity, mark
  provenance, fixture immutability, or existing corruption rejection changes.
- Stop an optimization if its gain disappears in paired full-path runs, depends
  on asymmetric checksum work, or exists only in a microbenchmark while the
  official path is unchanged or slower.
- Keep experimental kernels opt-in and preserve the current scalar path as the
  rollback target. Do not change the default backend until correctness gates
  and repeatable final-source measurements both pass.
- Re-run the controlled evidence when the fixture producer, host, Crystal or
  ClickHouse version, timer boundary, codec path, or relevant source changes.
