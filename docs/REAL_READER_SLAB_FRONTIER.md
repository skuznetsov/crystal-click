# Real Reader Slab Integration Frontier SDD

Document status: **IMPLEMENTATION VERIFIED; PERFORMANCE CLAIM SCOPED; ADVERSARY REVIEW COMPLETE (SCOPED ROBUST)**.

Current frontier: the opt-in owning `UInt64SlabVector` result is implemented in
the existing `WidePart` UInt64 reader. The current `Array(UInt64)` API and the
shared mmap/compressed-frame decoder remain unchanged. The new slab path moves
decoded bytes in chunks before materializing them into slabs; correctness and
controlled measurements are recorded below. The final adversary review is
complete and robust within the declared reader/vector scope; the residual
rejected surface remains explicit.

Bounded context: `src/crystal_click/wide_part.cr`,
`src/crystal_click/uint64_slab_vector.cr`,
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
mark-range/frame validation through a byte-chunk traversal, and append only
decoded values. `UInt64SlabVector#concat_le_bytes(Bytes)` validates that the
input size is a multiple of eight and that the checked append size fits before
mutating or allocating. It copies synchronously and retains no source bytes:
little-endian builds use overlap-safe `move_from` for the raw byte copy,
protected by a source regression guard, while the explicit big-endian fallback
decodes each value. The fallback is not covered by the current host
verification. A decoder error does not expose the partial local vector.

The Array and borrowed scanner paths retain their scalar `UInt64` callback
path. No decoder, mmap, compression, or file-format behavior changed.

The existing `read_uint64`, `read_uint64_mark_range`, and borrowed scratch API
remain unchanged. They must not be routed through `to_a` or another extra owning
copy.

## Evidence recorded

- The initial RED was a focused compile failure because
  `concat_le_bytes` was undefined. After the implementation and overlap-safe
  copy fix, the focused slab specs pass **21/0** in debug and release, and the
  full suites pass **97/0** in debug and release. Release evidence used the
  host's system linker override; the default `ld64.lld` rejects the installed
  Xcode TAPI files.
- The implementation does not reserve from claimed rows or copy an Array into
  slabs. The slab reader consumes byte chunks from the existing frame traversal;
  the Array and borrowed paths still decode scalar values.
- Format, Bash, and diff checks pass. The 200,000-row smoke benchmark preserves
  Array/slab parity.
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
- Controlled runs used seven paired repetitions at shifts 12, 14, 16, 18, and
  20 in both `natural_unknown` and `warm_shared`: **140/140** observations
  passed the independent row/checksum checks and RSS was available for every
  observation. The runner does not flush caches, so there is no cold-cache
  result.
- The post-fix natural shift-18 countercheck passed **14/14** independent
  row/checksum parity observations. Its Array/slab medians were **147.585 /
  118.007 ms**, with a slab/Array ratio median of **0.799585** and range
  **0.7681..0.8342**. GC metrics were available; RSS was unavailable only for
  this countercheck because of its time-metadata warning.

Paired ratios below are slab/Array (lower is faster). Times are median
milliseconds; ranges are the seven paired ratios for that shift.

| shift | natural Array/slab ms | natural ratio | warm Array/slab ms | warm ratio |
| --- | ---: | ---: | ---: | ---: |
| 12 | 146.189 / 128.856 | 0.8854 (0.8709..0.9282) | 145.949 / 128.748 | 0.8815 (0.8667..0.9029) |
| 14 | 141.088 / 123.919 | 0.8787 (0.8461..0.8851) | 143.168 / 121.899 | 0.8454 (0.8180..0.9878) |
| 16 | 146.482 / 121.789 | 0.8281 (0.8178..0.8488) | 142.961 / 118.480 | 0.8249 (0.8208..0.8624) |
| 18 | 143.679 / 114.708 | 0.7996 (0.7703..0.8224) | 143.498 / 114.761 | 0.8089 (0.7900..0.8201) |
| 20 | 145.506 / 114.165 | 0.7908 (0.7742..0.8117) | 139.834 / 114.100 | 0.8063 (0.7796..0.8232) |

The same observations provide the following medians. GC bytes and RSS are
Array/slab; RSS is shown in MiB. GC cycle count is orientation, not a value
substitute for end-to-end latency or allocation volume.

| shift | slabs / capacity / directory | tail unused slots | GC bytes | GC cycles | RSS natural MiB | RSS warm MiB |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 12 | 2,442 / 10,002,432 / 4,096 | 2,432 | 592,889,936 / 240,362,384 | 15 / 58 | 282.73 / 115.38 | 283.55 / 115.92 |
| 14 | 611 / 10,010,624 / 1,024 | 10,624 | 592,889,936 / 240,300,224 | 14 / 62 | 226.34 / 101.03 | 282.75 / 101.86 |
| 16 | 153 / 10,027,008 / 1,024 | 27,008 | 592,889,936 / 240,423,968 | 14 / 54 | 305.27 / 92.91 | 290.09 / 92.94 |
| 18 | 39 / 10,223,616 / 1,024 | 223,616 | 592,889,936 / 241,995,008 | 14 / 24 | 226.34 / 103.47 | 283.33 / 103.50 |
| 20 | 10 / 10,485,760 / 1,024 | 485,760 | 592,889,936 / 244,091,696 | 14 / 17 | 288.78 / 110.70 | 226.36 / 110.70 |

These are measured observations, not a general performance-winner claim. They
are scoped to this host, fixture, cache labels, and current Array growth policy.
Correctness and end-to-end latency are primary; RSS and GC bytes are constraints,
while GC cycles and tail capacity are explicit trade-off signals. The older
overlapping baseline files had different host/order conditions, and one was
slab-only, so no exact cross-run delta is attributed to the bulk-byte change.
The small Tokenomics input was slower previously; the default slab shift is
therefore unchanged and no adaptive policy is admitted. The benchmark roll is
not a cryptographic ClickHouse checksum and makes no leak or long-lived-workload
claim.

## Rejected surface

- Caller-owned slab destinations, rollback, `clear`, or partial-result exposure.
- Sizing a vector or allocating slabs from claimed rows or `expected_bytes`.
- Decoder, mmap, codec-buffer, checksum-verification, or file-format changes.
- A default-shift change or adaptive shift policy based on the current fixture;
  the general/default-shift winner remains rejected.
- Big-endian correctness as a verified capability; the fallback is present but
  untested on this host.
- A contiguous view, stable escaped chunks, concurrency, or Array replacement.
- Publishing private Tokenomics payload or treating it as public evidence.
- A general performance winner or an exact cross-run gain attributed solely to
  byte bulk append.

## Falsifiers and stop rules

- LZ4, ZSTD/compressed marks, Delta/ZSTD, multicolumn selection, exact/partial
  slab boundaries, full reads, and mark ranges must match the Array result.
- A malformed large claimed row count must fail without claimed-size slab
  allocation. A later corrupt frame must preserve public all-or-error behavior.
- Returned sizes, values, chunks, slab geometry, and GC retention must be exact.
- The focused byte-append RED must remain closed: malformed byte alignment and
  size overflow must fail before mutation or allocation, and the overlap-safe
  little-endian copy must retain its source regression guard.
- Source guards must retain `MMapDataSource.with_file` and
  `CompressedBlock.decode_frame`; no data-path `File.read` or Array-to-slab copy.
- Stop on any row/checksum mismatch, fixture mutation, partial-result exposure,
  regression in the existing Array/borrowed APIs, unstable paired latency, or
  RSS/GC-byte growth that cannot be explained by tail capacity.

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
are unavailable, paired results are unstable, or the claim is widened beyond
the declared fixture/host/cache scope.

## Implementation seal

- RED: the initial focused compile failed on undefined `concat_le_bytes`; the
  implementation now closes that missing method, the overlap-safe copy is
  source-guarded, and the focused checks pass.
- Observed DoD: focused correctness specs (21/0 debug and release), full suites
  (97/0 debug and release), format/Bash/diff checks, smoke parity, the
  controlled large-fixture benchmark, and the post-fix shift-18 countercheck
  pass within the evidence boundary above.
- Adversary status: **ROBUST within the declared reader/vector scope**. The
  overlap-safe little-endian path, source regression guard, focused/full
  parity, and post-fix countercheck introduce no observed blocker. Big-endian
  execution remains untested, benchmark claims remain fixture/host/cache
  scoped, representative real workloads remain open, and a general/default-
  shift winner remains rejected.
- Rollback: revert the bulk optimization commit. It changes source, focused
  specs, and synchronized docs; the benchmark and runner pre-existed and are
  not modified by this commit. Existing APIs remain intact.
- Next transition: exercise representative real workloads before deciding
  whether to change the default shift or admit an adaptive policy.
