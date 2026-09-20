# Real Reader Slab Integration Frontier SDD

Document status: **IMPLEMENTATION VERIFIED; PERFORMANCE CLAIM SCOPED**.

Current frontier: the opt-in owning `UInt64SlabVector` result is implemented in
the existing `WidePart` UInt64 reader. The current `Array(UInt64)` API and the
shared mmap/compressed-frame decoder remain unchanged. Correctness and
controlled measurements and the final adversary boundary are recorded below.

Bounded context: `src/crystal_click/wide_part.cr`,
`spec/real_reader_slab_spec.cr`, `benchmarks/real_reader_slab.cr`, and
`scripts/bench_real_reader_slab.sh`.

## Admitted surface

```crystal
read_uint64_slab(
  column : String = selected_column,
  slab_shift : Int = UInt64SlabVector::DEFAULT_SLAB_SHIFT,
) : UInt64SlabVector

read_uint64_mark_range_slab(
  column : String,
  first_mark : Int,
  mark_count : Int,
  slab_shift : Int = UInt64SlabVector::DEFAULT_SLAB_SHIFT,
) : UInt64SlabVector
```

Both methods construct their result internally, use the existing
`checked_mark_range` and `each_uint64_mark_range` path, and append only decoded
values. They inherit the existing mmap, mark-range, frame, codec, selected-byte,
and alignment checks. A decoder error does not expose a partial vector.

The existing `read_uint64`, `read_uint64_mark_range`, and borrowed scratch API
remain unchanged. They must not be routed through `to_a` or another extra owning
copy.

## Evidence recorded

- The implementation calls `checked_mark_range` and
  `each_uint64_mark_range` directly; it does not reserve from claimed rows or
  copy an Array into slabs.
- Focused debug/release checks: 8 examples, 0 failures in each build. Full
  debug/release suite: 92 examples, 0 failures in each build. Format, Bash, and
  diff checks pass. The 200,000-row smoke benchmark preserves Array/slab
  parity.
- The private 150,414-row Tokenomics `input` column preserves parity across
  seven paired observations, but is too small for a performance verdict. Its
  median Array/slab-shift-12 observations were 3.502458 ms / 3.745792 ms and
  8,542,048 / 3,716,944 GC bytes.
- A deterministic 10,000,000-row `value=number` Delta(8)/ZSTD(1) fixture with
  compressed marks was generated in a temporary directory only; it was not
  committed. The generator is reproducible. The independent benchmark roll
  checksum is `3960830973137314304`, compressed data is 3,874,486 bytes,
  compressed marks are 14,186 bytes, and decoded data is 80,000,000 bytes
  (76.3 MiB).
- Controlled runs used seven paired repetitions at shifts 10, 12, and 14 in
  both `natural_unknown` and `warm_shared`; every row/checksum parity check
  passed and RSS was available. The runner does not flush caches, so there is
  no cold-cache result.

Paired ratios below are slab/Array (lower is faster):

| cache regime | shift 10 | shift 12 | shift 14 |
| --- | ---: | ---: | ---: |
| `natural_unknown` | 0.9845 (0.8319..1.2592) | 0.9557 (0.9214..1.0151) | 0.9478 (0.8364..0.9661) |
| `warm_shared` | 1.0108 (0.9728..1.0278) | 0.9696 (0.9353..1.0184) | 0.9293 (0.9008..0.9703) |

For the measured 10M fixture, the default shift-12 medians were 136.615 ms
Array / 133.228 ms slab in `natural_unknown`, and 135.916 ms / 131.924 ms in
`warm_shared`. Shift 14 medians were 137.446 ms / 127.884 ms and 136.586 ms /
128.682 ms, respectively. Median GC bytes were 592,889,936 for Array,
240,362,384 for shift 12, and 240,300,224 for shift 14. Median GC cycles were
14, approximately 58, and approximately 62, respectively: allocation volume
fell while collection count rose.

Median RSS was available for every controlled observation. At shift 12,
Array/slab RSS was 320,012,288 / 121,061,376 bytes in `natural_unknown` and
243,826,688 / 121,094,144 bytes in `warm_shared`. At shift 14 it was
269,680,640 / 107,036,672 bytes and 291,061,760 / 106,807,296 bytes,
respectively.

At 10M rows, shift 10 used 9,766 slabs and grew the directory to 16,384
entries; shift 12 used 2,442 slabs and a 4,096-entry directory; shift 14 used
611 slabs and stayed within the preallocated 1,024-entry directory. Shift 14
left 10,624 unused value slots (83 KiB), so the cached directory geometry
proposed for the vector covered this full scan without directory growth.

These are measured observations, not a general performance winner claim. They
are scoped to this host, fixture, cache labels, and current Array growth policy.
The final adversary review rated the implementation **ROBUST** in the tested
scope. It rejected a general speedup claim as **VULNERABLE**: the small
Tokenomics input was slower, and the shift-12 paired ranges crossed 1.0. It
accepted the large-fixture shift-14 speedup and the lower measured GC-byte/RSS
result only in this declared benchmark scope. The evidence makes no leak or
long-lived-workload claim, and the benchmark roll is not a cryptographic
ClickHouse checksum.

## Rejected surface

- Caller-owned slab destinations, rollback, `clear`, or partial-result exposure.
- Sizing a vector or allocating slabs from claimed rows or `expected_bytes`.
- Decoder, mmap, codec-buffer, checksum-verification, or file-format changes.
- A contiguous view, stable escaped chunks, concurrency, or Array replacement.
- Publishing private Tokenomics payload or treating it as public evidence.
- A performance winner inferred from the current small fixtures or synthetic
  container benchmark.

## Falsifiers and stop rules

- LZ4, ZSTD/compressed marks, Delta/ZSTD, multicolumn selection, exact/partial
  slab boundaries, full reads, and mark ranges must match the Array result.
- A malformed large claimed row count must fail without claimed-size slab
  allocation. A later corrupt frame must preserve public all-or-error behavior.
- Returned sizes, values, chunks, slab geometry, and GC retention must be exact.
- Source guards must retain `MMapDataSource.with_file` and
  `CompressedBlock.decode_frame`; no data-path `File.read` or Array-to-slab copy.
- Stop on any row/checksum mismatch, fixture mutation, partial-result exposure,
  or regression in the existing Array/borrowed APIs.

## Measurement boundary

Current public fixtures (200,000-row LZ4/ZSTD and 4,096-row Delta/multicolumn)
and the ignored local 150,414-row Tokenomics `input` column remain correctness
and smoke inputs only. The Tokenomics run is below the performance-verdict
boundary. The private fixture may be validated locally without printing or
committing values or raw files.

A performance verdict requires a deterministic public 8,388,608-10,000,000-row
`UInt64 CODEC(Delta(8), ZSTD(1))` Wide part with compressed marks, an independent
expected checksum, and an immutable manifest. The current controlled run meets
that shape in a temporary fixture: each observation ran in a fresh release
subprocess and recorded elapsed nanoseconds, GC bytes, GC cycles, retained
rows/container geometry, and peak RSS. Track order was rotated. Report
`warm_shared` and `natural_unknown` separately; do not claim cold-cache
behavior. The fixture can be regenerated with the checked-in generator; the
timing artifacts were temporary and are not retained here.

Abstain from a winner if there are fewer than seven valid repetitions, decoded
payload is below roughly 64 MiB, rows/checksum/manifest differ, critical metrics
are unavailable, or paired results are unstable.

## Implementation seal

- RED: satisfied before implementation; both reader methods are now present.
- Observed DoD: focused correctness specs, existing full debug/release suite,
  format/Bash/diff checks, smoke benchmark parity, and the controlled
  large-fixture benchmark all pass within the evidence boundary above.
- Adversary verdict: implementation **ROBUST** within the tested scope; a
  general performance-winner claim is **VULNERABLE** and is not admitted.
  Shift-14 throughput and lower GC-byte/RSS observations remain scoped to this
  host, fixture, cache labels, and current Array implementation.
- Rollback: revert the single integration commit; existing APIs remain intact.
- Next transition: exercise representative larger real workloads and evaluate
  whether fewer/larger slabs can reduce the increased GC-cycle count without
  losing the bounded tail-overhead and directory properties.
