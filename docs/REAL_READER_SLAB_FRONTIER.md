# Real Reader Slab Integration Frontier SDD

Document status: **VERIFIED / SCOPED ROBUST; IMPLEMENTATION UNCHANGED**.

Current frontier: the opt-in owning `UInt64SlabVector` result is implemented in
the existing `WidePart` UInt64 reader. The current `Array(UInt64)` API and the
shared mmap/compressed-frame decoder remain unchanged. The new slab path moves
decoded bytes in chunks before materializing them into slabs; correctness,
manifest hardening, the retained multi-column real-workload gate, and the
completed multi-workload campaign are recorded below. The benchmark evidence is
scoped to the declared host/workload/cache labels; no policy change is admitted.

Campaign status: **VERIFIED / SCOPED ROBUST; IMPLEMENTATION UNCHANGED** within
the declared host, workload, cache-label, manifest, and immutable-fixture
scope. This is not a general performance, cold-cache, or policy claim.

Bounded context: `src/crystal_click/wide_part.cr`,
`src/crystal_click/uint64_slab_vector.cr`,
`spec/real_reader_slab_spec.cr`, `benchmarks/real_reader_slab.cr`, and
`benchmarks/real_reader_slab_manifest.cr`,
`spec/real_reader_slab_manifest_spec.cr`, and
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

## Controlled manifest boundary

The retained multi-column benchmark uses manifest **v2**. The caller's JSON is
checked with a bounded `stat` plus a single in-memory snapshot: files larger
than 64 KiB are rejected, the bounded snapshot is hashed, and the same bytes
are sent over stdin to validation, warmup, and timed children. JSON parsing
rejects duplicate/unknown fields, bounds nesting, columns, names, rows, and
derived decoded bytes. The fixture must be absolute and non-root. The runner
also computes an aggregate SHA-256 fixture-tree digest over sorted relative
file/digest pairs and rechecks it around observations.

Repository artifacts record no private fixture identifiers (fixture path,
column names, raw values, exact private checksums) or private result payloads.
This privacy statement is limited to repository artifacts; transient local
benchmark files may contain operational paths or metadata and are not covered.
The retained repository evidence is the bounded schema, aggregate integrity
signal, and aggregate benchmark metrics.

The first manifest adversary review was **VULNERABLE**: unbounded hashing of a
caller-controlled manifest could make validation cost unbounded. The bounded
`stat` + snapshot fix was then re-reviewed **ROBUST** within the scope of a
macOS regular local manifest and an immutable fixture. This does not claim to
close a hostile transient swap/restore between checks, and non-macOS portability
is unverified.

## Evidence recorded

- Earlier intermediate evidence recorded the focused slab specs at **21/0** in
  debug and release and the full suites at **97/0**, followed by a **108/0**
  full-suite run; those counts remain historical snapshots. The initial RED was
  a focused compile failure because `concat_le_bytes` was undefined. Release
  evidence used the host's system linker override; the default `ld64.lld`
  rejects the installed Xcode TAPI files.
- Current fixture-generator focused specs pass **3/0**, reader/slab focused
  specs pass **20/0**, manifest-focused specs pass **11/0**, and the current
  full debug and release suites each pass **111/0**. Format, Bash, and diff
  checks pass. Public smoke parity is verified, but its manifest reports
  `threshold_met=false`; it is not a performance result.
- The implementation does not reserve from claimed rows or copy an Array into
  slabs. The slab reader consumes byte chunks from the existing frame traversal;
  the Array and borrowed paths still decode scalar values.
- The 200,000-row smoke benchmark preserves Array/slab parity while remaining
  below the controlled performance threshold.
- The private 150,414-row Tokenomics single-column sample preserves parity across
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
  passed the harness-observed expected row-count, aggregate-checksum, and guard
  checks, and RSS was available for every observation. This is not exhaustive
  value-by-value validation or cryptographic proof. The runner does not flush
  caches, so there is no cold-cache result.
- The post-fix natural shift-18 countercheck passed **14/14** independent
  row/checksum parity observations. Its Array/slab medians were **147.585 /
  118.007 ms**, with a slab/Array ratio median of **0.799585** and range
  **0.7681..0.8342**. GC metrics were available; RSS was unavailable only for
  this countercheck because of its time-metadata warning.

### Historical synthetic one-column measurements

The following older public 10M one-column results remain as historical context;
they are not the current retained real-workload campaign. Ratios are slab/Array
(lower is faster). Times are median milliseconds; ranges are the seven paired
ratios for that shift.

| shift | natural Array/slab ms | natural ratio | warm Array/slab ms | warm ratio |
| --- | ---: | ---: | ---: | ---: |
| 12 | 146.189 / 128.856 | 0.8854 (0.8709..0.9282) | 145.949 / 128.748 | 0.8815 (0.8667..0.9029) |
| 14 | 141.088 / 123.919 | 0.8787 (0.8461..0.8851) | 143.168 / 121.899 | 0.8454 (0.8180..0.9878) |
| 16 | 146.482 / 121.789 | 0.8281 (0.8178..0.8488) | 142.961 / 118.480 | 0.8249 (0.8208..0.8624) |
| 18 | 143.679 / 114.708 | 0.7996 (0.7703..0.8224) | 143.498 / 114.761 | 0.8089 (0.7900..0.8201) |
| 20 | 145.506 / 114.165 | 0.7908 (0.7742..0.8117) | 139.834 / 114.100 | 0.8063 (0.7796..0.8232) |

The same historical observations provide the following medians. GC bytes and RSS are
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
The small Tokenomics sample was slower previously; the default slab shift is
therefore unchanged and no adaptive policy is admitted. The benchmark roll is
not a cryptographic ClickHouse checksum and makes no leak or long-lived-workload
claim.

### Historical retained multi-column real-workload gate

The final workload is one private Wide part with three exact `UInt64` columns,
3,917,920 rows per column, and 94,030,080 decoded bytes (about 89.67 MiB).
Each column had an independently derived ClickHouse checksum. This document
intentionally omits the fixture path, column names, raw values, and exact
private checksum values.

There were seven repetitions for each of five shifts (12, 14, 16, 18, 20) in
each cache regime: 70 observations per regime and **140/140 overall**. RSS was
available for all observations. The 140/140 result certifies only
harness-observed expected row counts, aggregate checksums, and the slab
geometry, threshold, and fixture-immutability guards; it is not exhaustive
value-by-value validation or cryptographic proof. The public smoke threshold
result remains `threshold_met=false` and is not performance evidence.

The table reports `Array median / p95` and `slab median / p95` in milliseconds;
p95 is the nearest-rank value over the seven paired observations. Ratios are
`slab/Array median / p95`; `slab-vs-shift12` is the median slab latency ratio.

| regime | shift | Array ms | slab ms | slab/Array | slab-vs-shift12 |
| --- | ---: | ---: | ---: | ---: | ---: |
| `natural_unknown` | 12 | 145.355 / 149.929 | 124.564 / 126.912 | 0.849 / 0.869 | 1.000 |
| `natural_unknown` | 14 | 146.138 / 152.567 | 120.092 / 126.514 | 0.823 / 0.867 | 0.964 |
| `natural_unknown` | 16 | 145.951 / 154.387 | 115.793 / 116.708 | 0.784 / 0.819 | 0.930 |
| `natural_unknown` | 18 | 146.117 / 147.812 | 109.801 / 119.048 | 0.751 / 0.817 | 0.881 |
| `natural_unknown` | 20 | 148.421 / 172.024 | 110.308 / 110.792 | 0.745 / 0.755 | 0.886 |
| `warm_shared` | 12 | 145.517 / 148.994 | 123.589 / 125.741 | 0.859 / 0.865 | 1.000 |
| `warm_shared` | 14 | 145.778 / 148.242 | 118.448 / 122.078 | 0.807 / 0.840 | 0.958 |
| `warm_shared` | 16 | 146.267 / 149.527 | 115.041 / 118.344 | 0.789 / 0.813 | 0.931 |
| `warm_shared` | 18 | 146.717 / 152.324 | 109.341 / 116.309 | 0.742 / 0.808 | 0.885 |
| `warm_shared` | 20 | 147.558 / 148.914 | 110.407 / 118.393 | 0.751 / 0.809 | 0.893 |

Matched per-rep latency ratio ranges (`slab/Array`) were natural shift 12
`.8308..0.8692`, natural shift 14 `.7757..0.8669`, warm shift 12
`.8188..0.8655`, and warm shift 14 `.8005..0.8404`. These ranges are
supplementary to the median/p95 table and do not widen the gate beyond the
declared workload and cache labels.

Across the current matrix, global matched per-rep slab/Array ratios were RSS
`0.449087..0.797326`, GC bytes `0.392571..0.401681`, and GC collections
`1.235294..4.466667`. These are ratio claims only; no absolute RSS unit claim is
made. Exact tail waste, computed as `(capacity - retained_values) / capacity`,
was shift 12 `0.049798%`, shifts 14/16/18 `0.362142%`, and shift 20
`6.589508%`. Shift 18 is the strongest median candidate in this workload, but
remains a candidate only:
the benchmark gate is **PASS / ROBUST** for this host, workload, and the two
named cache regimes. It is not a default or adaptive-policy decision, a cold
cache result, or a general winner claim.

For historical geometry context, the prior one-column 10M fixture used 9,766
slabs / 16,384 directory entries at shift 10, 2,442 / 4,096 at shift 12, and
611 / 1,024 at shift 14. The user-proposed 1,024-entry directory exactly
covered the 10M shift-14 case, leaving 10,624 unused values (about 83 KiB).

## Measured campaign — implementation unchanged

Status: **VERIFIED / SCOPED ROBUST; IMPLEMENTATION UNCHANGED** within the
declared host, workload, cache-label, manifest, and immutable-fixture scope.
The campaign closes the admitted measurement slice only. It does not promote a
default shift, adaptive policy, source change, cold-cache result, or general
winner.

The campaign used 14 admitted invocations and 980 unique observations (70 per
invocation); all declared row, checksum, geometry, threshold, and fixture
immutability guards passed. The escalated canary is admitted; the sandbox
canary is excluded. Host GUI noise was observed in a canary, and a retained
outlier remains in the aggregate evidence rather than being silently trimmed;
matched-pair medians remained discriminating.

### A–D best-shift summary

The four anonymized retained workloads span the admitted real-part shape
matrix. Gaps are shift-18 slab median latency versus that regime's best shift.

| workload | natural best | warm best | shift 18 vs best, natural | shift 18 vs best, warm |
| --- | ---: | ---: | ---: | ---: |
| A | 20 | 18 | +1.463573% | 0% |
| B | 18 | 18 | 0% | 0% |
| C | 18 | 18 | 0% | 0% |
| D | 16 | 18 | +2.650768% | 0% |

For this campaign, each paired ratio is computed per matched observation as
`slab_elapsed / array_elapsed`. With seven matched observations, nearest-rank
p95 is the maximum ratio (rank 7); it is not the ratio of slab p95 latency to
Array p95 latency.

At shift 18, slab/Array median latency ratios across A–D cells were
`0.723242..0.793787`; across all A–D matrix cells they were
`0.723242..0.866610`. Paired latency p95 ratios across all A–D cells were
`0.751065..1.164694` (shift 18 rows: `0.751065..0.823574`). These are a
vector of observations, not a scalar winner.

### Resource and tail trade-offs

Overall matched RSS max ratios (slab/Array, natural/warm) were:

| workload | natural | warm |
| --- | ---: | ---: |
| A | 0.562759 | 0.559788 |
| B | 0.781814 | 0.771023 |
| C | 1.008334 | 1.001399 |
| D | 0.994493 | 0.967432 |

These are ratios only; no absolute RSS unit claim is made. Aggregate GC-byte
median ratios ranged `0.378266..0.407006` (paired minimum fields
`0.372790..0.401260`; maximum fields `0.401680..0.480011`). GC-collection
median ratios ranged `1.904762..3.600000` (paired minimum fields
`0.809524..1.312500`; maximum fields `3.166667..4.857143`). GC bytes,
collection counts, and p95 latency are non-scalar trade-offs. Shift-20 tail
waste across A–D was `6.589508%..43.166208%`; shift-18 tail waste was
`0.362142%..16.361872%`.

### Public codec controls and policy boundary

The public direct-LZ4, direct-ZSTD, and Delta(8)+ZSTD controls all selected
shift 20; shift 18 remained within `0.399159..1.023979%` of each control's
best shift. They are attribution controls only, not real-data generalization.
The shift-18 >5% falsifier did not trigger. The adaptive-policy criterion
failed: no two repeatable workload classes preferred different shifts by more
than 5% in both regimes via pre-read static shape while beating the best fixed
shift under the constraints. Therefore the default shift, adaptive policy, and
source remain unchanged.

The final campaign adversary verdict is **ROBUST** within the declared host,
workload, cache-label, manifest, and immutable-fixture scope. Fixture checks are
structural and do not prove full semantic decoding. Hostile TOCTOU, cold-cache,
non-macOS, general-performance, default-shift, and adaptive-policy claims remain
explicit nonclaims.

The cache labels remain `warm_shared` and `natural_unknown`/process-fresh; no
`cold_cache` label is admitted. The read-only macOS eviction probe still found
that `F_NOCACHE`, `MAP_NOCACHE`, and `MADV_DONTNEED` did not evict mapped pages.
`MAP_SHARED` + `MS_INVALIDATE` + `mincore` can at most support a future
`os_page_cache_invalidated` label through a separate mmap frontier;
storage/controller cache remains unknown, and purge/global flush remains
rejected. No hostile transient swap/restore or non-macOS portability claim is
made.

Rollback remains measurement-only: remove the campaign workload/control
artifacts and evidence without changing the reader/API or prior results. The
privacy boundary remains repository artifacts only: omit private fixture
identifiers, paths, column names, raw values, exact private checksums, and
private result payloads; transient local paths and metadata are not claimed
absent.

## Rejected surface

- Caller-owned slab destinations, rollback, `clear`, or partial-result exposure.
- Sizing a vector or allocating slabs from claimed rows or `expected_bytes`.
- Decoder, mmap, codec-buffer, checksum-verification, or file-format changes.
- A default-shift change or adaptive shift policy based on the current fixture;
  the general/default-shift winner remains rejected.
- A cold-cache claim, a general real-workload winner, or a policy decision from
  this campaign's anonymized workloads and its two named cache regimes.
- Big-endian correctness as a verified capability; the fallback is present but
  untested on this host.
- A guarantee against a hostile process that swaps and restores the manifest or
  fixture between integrity checks, or a non-macOS portability guarantee.
- A contiguous view, stable escaped chunks, concurrency, or Array replacement.
- Publishing private Tokenomics payload or treating it as public evidence.
- Persisting private fixture identifiers (fixture path, column names, raw
  values, or exact private checksums) or result payloads in repository
  artifacts. Transient local operational paths/metadata are outside this
  privacy claim.
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
- Manifest validation must retain the v2 stdin snapshot, 64 KiB/JSON/schema
  bounds, absolute non-root fixture check, and aggregate fixture digest. A
  repeat of unbounded manifest hashing is a stop condition.
- Stop on any row/checksum mismatch, fixture mutation, partial-result exposure,
  regression in the existing Array/borrowed APIs, unstable paired latency, or
  RSS/GC-byte growth that cannot be explained by tail capacity. A hostile
  transient swap/restore or non-macOS portability failure reopens the scope
  boundary rather than being silently promoted.

## Measurement boundary

Current public fixtures (200,000-row LZ4/ZSTD and 4,096-row Delta/multicolumn)
and the ignored local 150,414-row Tokenomics single-column sample remain correctness
and smoke inputs only. The Tokenomics run is below the performance-verdict
boundary. The private fixture may be validated locally without printing or
committing values or raw files.

A historical performance gate used a deterministic public
8,388,608-10,000,000-row `UInt64 CODEC(Delta(8), ZSTD(1))` Wide part with
compressed marks, an independent expected checksum, and an immutable manifest.
Those synthetic results remain above for context. The current retained
real-workload evidence above used one private three-column Wide part. The
completed campaign expands the measurement to four anonymized real workloads
plus public codec controls, with immutable fixtures, aggregate integrity
signals, and no source/API change. Each observation ran in a fresh release
subprocess and recorded elapsed nanoseconds, GC bytes, GC cycles, retained
rows/container geometry, threshold state, and peak RSS. Track order was
rotated. Report `warm_shared` and `natural_unknown` separately; do not claim
cold-cache behavior. No private raw fixture or timing artifact is retained in
the repository.

Abstain from a winner if there are fewer than seven valid repetitions, decoded
payload is below roughly 64 MiB, rows/checksum/manifest differ, critical metrics
are unavailable, paired results are unstable, manifest/fixture immutability is
not established, or the claim is widened beyond the declared
fixture/host/cache scope. The measured campaign is scoped to this macOS host,
four anonymized real workloads, public codec controls, and the two named cache
regimes; the final adversary verdict is scoped **ROBUST** as stated above.

## Implementation seal

- RED: the initial focused compile failed on undefined `concat_le_bytes`; the
  implementation now closes that missing method, the overlap-safe copy is
  source-guarded, and the focused checks pass.
- Observed DoD: current fixture-generator focused specs (3/0), reader/slab
  focused specs (20/0), manifest focused specs (11/0), current full debug and
  release suites (111/0 each), format/Bash/diff checks,
  public smoke parity with `threshold_met=false`, the retained multi-column
  140/140 observation matrix, the campaign's 14 admitted invocations and 980
  unique observations (70 each), and manifest/fixture integrity checks pass
  within the evidence boundary above.
- Adversary status: the first manifest review was **VULNERABLE** for unbounded
  manifest hashing. After the bounded stat+snapshot fix, the repeat review is
  **ROBUST within the declared macOS regular-local-manifest and immutable-
  fixture scope**. Residual hostile transient swap/restore and non-macOS
  portability are explicit non-claims. The final campaign adversary verdict is
  **ROBUST within the declared scope**; its fixture checks are structural and
  do not prove full semantic decoding. Hostile TOCTOU, cold-cache,
  non-macOS, general-performance, default-shift, and adaptive-policy claims
  remain rejected. Big-endian execution remains untested.
- Rollback: revert the bulk optimization change containing the source, focused
  specs, and synchronized docs. The benchmark/runner hardening is a separate
  measurement surface; its fail-closed manifest and privacy boundaries must be
  reviewed independently if that surface is reverted. Existing APIs remain
  intact.
- Current transition: the campaign is **VERIFIED / SCOPED ROBUST / IMPLEMENTATION
  UNCHANGED** within the declared scope. No default-shift or adaptive-policy
  decision is admitted.
