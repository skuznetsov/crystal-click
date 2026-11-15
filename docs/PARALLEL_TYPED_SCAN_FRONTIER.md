# Parallel typed scan and read comparison

The sequential reference is `main` at
`09d3d955f0b3cd37d1e114525d4f7e16d7a9e4f5`.

## Scan contract

`TypedPartTable#scan_typed_parallel` assigns nonempty physical marks of
selected immutable Wide and Compact parts to workers in round-robin order.
It accepts 1–32 workers, capped by the number of those marks.
`OfflineTable#scan_typed_parallel` uses the same catalog resolution and DDL
checks as `scan_typed`. A request for one worker uses the existing serial
scan. With execution contexts enabled, a single nonempty mark also takes
this path. The threaded path admits exact
`UInt8`–`UInt64`, `Int8`–`Int64`, `Float32`, and `Float64` columns in ordinary
parts with Crystal execution contexts enabled. It rejects projection children
and flattened `Nested` bindings.

Each worker decodes on its own system thread with private reader state. The
calling fiber consumes one physical mark at a time in source order, with the
same batch boundaries and offsets as `scan_typed`. Other workers can decode
their next assigned mark during each callback. A worker has at most one
outstanding batch and may reuse its buffers when the callback returns.
Workers on one Compact part share its cumulative transport budget across
reader admission and decoding. Its file, record, decoded-byte, and result-byte
allowances apply across the complete worker group.
Operation exit waits for the workers after normal completion, early exit,
and decoder or callback failures. Keep selected part files stable for the
lifetime of the reader and use a separate reader for each concurrent scan.

### Direct Compact UInt64 batches

An ordinary exact `UInt64` column in an admitted Compact MRK3 or MRK4
part uses the existing serialization profile, substream roster, and row
grid checks. For each selected mark, its physical interval must contain
exactly `rows * sizeof(UInt64)` logical bytes. The checked compressed-range
reader verifies the touched frames and charges the same shared transport
budget. All selected columns are validated for the mark before its first
callback. Wrapped types and projection children use their established
decoders.

On little-endian hosts, scans selecting only admitted ordinary `UInt64`
columns borrow typed slices from one slab per worker. The slab grows on
demand and can be reused across marks and parts. A worker keeps the current
mark in it through the last callback's acknowledgement. Complete LZ4 and
ZSTD frames decode straight into the selected column's slice after
checksum verification. Partial frames and Delta/ZSTD use a separate reusable
decode workspace, followed by a copy of the selected interval. Transport
and aggregate mark limits still apply. If the current mark's materialization
allowance accommodates only the detached result, the scan uses that path.
Mixed selections dispatch to the per-column readers. Callers must copy values
they retain beyond the callback.

When all selected columns are ordinary `UInt64` on a little-endian host,
table admission builds one mark grid and one `data.bin` frame index per
part. Full, window, and candidate-mark scans open one read-only `data.bin`
mapping per part read.
The scan checks the mapped headers against the admitted index and verifies
each accessed frame's checksum before decompression. The transport budget
charges the mapping and header pass once per scan and accumulates decode
work and result bytes across selected ranges and workers. The mapping stays
valid through the last scheduled worker's read. Cancellation and failure
join the workers before closing any remaining mappings.

Guard checks cover both mark layouts, exact batch offsets and values,
checksum corruption, inconsistent interval width, and budget exhaustion
before a callback sees the affected mark. The slab tests also cover
reentrant serial calls and distinct worker storage across parts. Reverting
the slab change restores the detached range buffers from `d46b678`.

## Comparison contract

- Scan the same ClickHouse-generated local Wide and Compact part files, with
  positive and negative checks for both layouts. Pin the reference revision,
  tool versions, codecs, types, mark layout, and worker counts. Bound scratch
  storage to one disposable work directory.
- Time the same external request-to-complete-response interval with a monotonic
  clock and preconnected loopback HTTP sockets. Warm the shared fixture and
  alternate the two engines' order across repeated samples. The processes are
  already running and the part metadata is loaded before the timer.
- Match output and compressed-block checksum policy within each layout. Use
  `checksum_on_read=0` on ClickHouse for Wide and `checksum_on_read=1` for
  Compact. The pinned Crystal Wide path checks framing and sizes. The Compact
  path also verifies the data-frame checksum. Check the exact decoded sequence
  and part identity outside the timed interval. Each engine retains its own
  decode, bounds, and scheduling implementation.

The reduction consumes both `UInt64` columns. It returns six `UInt64`
values in a 48-byte RowBinary response. The values are the count, key sum,
value sum, sum of the bitwise XOR, value minimum, and value maximum. Crystal
runs the reducer on the calling fiber. The native query runs through the
server's query pipeline. Each Crystal request uses a fresh selected-part reader
prepared outside the timer, so the Compact transport budget belongs to one
scan. The timed request includes any per-worker reader creation in Crystal
and per-query planning in ClickHouse, along with the read, reduction, and
loopback HTTP request and response. Native query-result, query-condition,
uncompressed, and deserialization-prefix caches are disabled. The OS page
cache is warm.

### Compressed-block checksum control

The official ClickHouse 26.10.1.1201 binary has SHA-256
`5bb43958f4c0806cc363b84b9858e7206e56ac80263a24acc704271322e531ae`.
On disposable 2,048-row LZ4 parts, changing just the first compressed frame's
checksum byte made `checksum_on_read=1` fail with `CHECKSUM_DOESNT_MATCH`.
`checksum_on_read=0` preserved `(count(), sum(id), sum(value))` at
`(2048, 2098176, 6294528)`. Wide MRK2 had four frames in the modified stream.
Compact MRK3 and MRK4 each had eight in `data.bin`. `CHECK TABLE` reported
success on every original part and a failed result row on every modified
part. Its exit status was zero even when its result reported a mismatch.
On the modified Wide part, the Crystal typed scan produced the original
aggregate. The Crystal Compact typed scan raised `CorruptPartError` with
`compressed frame checksum mismatch` on the same single-byte fault.

### Compact pilot budget cutoff

The first 524,288-row fixture had 64 data marks of 8,192 rows. On Compact
MRK3, a fresh serial reader stopped at row 196,608 with
`compressed stream file-byte limit exceeded`. Three fresh baseline exports
and three candidate one-worker exports each returned the exact first
3,145,728 bytes of the input sequence before the cutoff. The baseline's
reduction endpoint reported the underlying exception before sending a response.

The Compact `data.bin` was 5,303,170 bytes. In that campaign, each selected
column's mark read charged that entire file size against the cumulative
256 MiB transport budget. A 16-mark fixture of the same size reached
`Compact typed carriers exceed aggregate materialization limit` at 32,768
rows per mark. The four-worker reader with a shared budget also rejected the
64-mark pilot with `compressed stream file-byte limit exceeded`. The paired
campaign uses 131,072 rows in 16 marks of 8,192 rows with a fresh Crystal
reader for each request.

## Measured reads

The campaign ran on an Apple M2 Max with 8 performance cores, 4 efficiency
cores, and 64 GB RAM, using macOS 26.6.2 arm64 and Crystal 1.22.3 with
LLVM 23.1.5. Both Crystal workers were built with `--release`. The parts
were on the same external APFS SSD. The run shared the host with desktop
and background processes.

Each engine scanned the same physical part for a layout. The native server
wrote both parts from the same 131,072-row sequence of two `UInt64` columns
(2 MiB decoded). Each layout has 16 equal 8,192-row marks and a zero-row
terminal mark. The fixture set `max_compress_block_size=4096` and used LZ4.
Wide used MRK2 and 1,386,725 bytes of compressed column files. Compact used
MRK3 and a 1,325,955-byte `data.bin` with one 64 KiB decoded frame per column
and data mark.

Times are median and median absolute deviation in milliseconds. Each row
contains two warmup pairs and 15 timed pairs. The ratio divides the Crystal
median by the ClickHouse median from the same series.

| Part | Crystal source | Workers | Crystal, ms | ClickHouse, ms | Ratio |
| --- | --- | ---: | ---: | ---: | ---: |
| Wide | Reference `main` | 1 | 7.530 ± 0.152 | 2.039 ± 0.150 | 3.69× |
| Wide | Parallel scan build | 1 | 7.836 ± 0.228 | 2.109 ± 0.046 | 3.72× |
| Wide | Parallel scan build | 4 | 4.159 ± 0.255 | 1.575 ± 0.101 | 2.64× |
| Compact | Reference `main` | 1 | 61.674 ± 0.744 | 2.726 ± 0.190 | 22.62× |
| Compact | Parallel scan build | 1 | 63.410 ± 2.148 | 2.627 ± 0.268 | 24.14× |
| Compact | Parallel scan build | 4 | 66.223 ± 2.910 | 2.025 ± 0.177 | 32.70× |

Within the new Crystal build, the four-worker Wide median was 1.88× faster
than the one-worker median. The Compact four-worker median was 4.4% higher,
with overlapping sample ranges. The result covers warm-cache full reads of
this fixture, including aggregation and loopback HTTP.

`EXPLAIN PIPELINE` showed four `ReadPool` streams for each four-thread
ClickHouse query. Two trials per layout and worker count reported respectively
one and four distinct thread IDs with positive `read_rows` in
`system.query_thread_log`. The rows summed to 131,072 in every trial. The
query logged 2,097,152 logical read bytes. `merge_tree_min_read_task_size=4`
was common to all timed queries. In the untimed four-worker Crystal witness,
the caller observed four isolated worker contexts and all 16 marks in order.

`CHECK TABLE` returned a successful result row for each layout. The file
manifest hashes stayed identical across every pair series. Both engines'
complete ordered RowBinary exports matched the fixture byte for byte before
timing, and every measured response matched the independent six-value
oracle. The measured aggregate values were
`(131072, 8589869056, 282726979812208, 282726959309866, 18944, 4294945879)`.

| Evidence | SHA-256 |
| --- | --- |
| Fixture RowBinary | `5103eb0b689c92f3ebe4c23ae58816b4d120b12d5a543c2e274a58a547a075b5` |
| 48-byte reduction | `2f4e9f8b0da83ff03781c162a511f160dd0441c250c2f2c71d38e6950e96bc15` |
| Wide part file manifest | `2e55e9cbe502047752b136e25b707f68d72f183e365f0d7052a6278ce0bafc45` |
| Compact part file manifest | `80f5aaa885eae58e7e5d6888b28977888706d7100e91c5adcc7cb9309929c62a` |
| Crystal reference worker binary | `fe2d083bce098fe5753178970cb21aac8dcd17c28f61fbda3aa6977cf3a03309` |
| Crystal candidate worker binary | `de5bc91780259384bc26c871b29937fee360cc3c4ac143232263ddc9f25f1d8c` |

### Compact scan profile

The November 15, 2026 run profiled `4fcf1e1` on an Apple M2 Max with Crystal
1.22.3 `--release` (LLVM 23.1.5, Boehm 8.2.12) and the same official ClickHouse
26.10.1.1201 binary (Clang 22.1.8, jemalloc). The regenerated part matched
the complete Compact file manifest above. Its `data.bin` contains 32 LZ4
frames of 64 KiB decoded each, one frame per selected column and data mark.

The uninstrumented comparison used four warmup pairs and 21 timed pairs per
worker count with the same preconnected HTTP boundary and checksums enabled
in both engines. Both complete RowBinary exports and all aggregate responses
matched the oracle. `CHECK TABLE` passed and the part manifest stayed fixed.

| Workers | Crystal median ± MAD, ms | ClickHouse median ± MAD, ms | Ratio |
| ---: | ---: | ---: | ---: |
| 1 | 56.355 ± 1.084 | 2.748 ± 0.234 | 20.51× |
| 4 | 61.601 ± 2.946 | 2.087 ± 0.221 | 29.52× |

The four-worker Crystal median was 9.3% higher, with overlapping observed
sample ranges. Separate logged queries read 1,325,955 compressed bytes in 32
blocks at both ClickHouse thread counts. At four threads, each reader logged
32,768 rows, totaling 131,072 rows. The Crystal witness observed four isolated
execution contexts with ordered delivery of all 16 data marks.

Separate eight-second macOS `sample` captures used the uninstrumented worker
at 1 ms intervals with repeated checked aggregate requests. Four-worker
stacks repeatedly parked at `__psynch_mutexwait` under `BinaryValue.new`,
`GC_malloc_kind`, and `GC_generic_malloc_many`. That Boehm refill path takes
the allocator lock and can trigger a collection. A parked stack can be
waiting for another thread's collection, and thread snapshots do not give
a wall-time percentage. [Boehm allocator source][boehm-refill].

The allocation controls used one scan per fresh Release process over the
same warm file pages. They ran 12 timed rounds with one request per setting
in rotating order, reversed every other round. The connection and part
preparation preceded timing, and every aggregate still matched the oracle.
The probe read `GC_get_heap_usage_safe` and collection event counters
around the request. The allocation totals include a small telemetry cost.
These are distinct from the steady worker medians above.

| Crystal runtime mode | 1 worker, ms | 4 workers, ms | Allocated per scan, 1 / 4 workers |
| --- | ---: | ---: | ---: |
| Boehm, collection enabled | 65.152 ± 2.136 | 75.129 ± 4.451 | 112.018 / 113.881 MiB |
| Same binary after `GC.disable` | 56.472 ± 0.751 | 60.539 ± 2.562 | 112.021 / 113.894 MiB |
| `-Dgc_none` (libc malloc) | 53.975 ± 0.947 | 27.282 ± 1.128 | — |

The times are median ± MAD. At one and four workers, Boehm recorded median
collection counts of 20 and 15 per scan. The median sums of the durations
from collection start to end were 15.038 and 12.017 ms. The disabled mode
recorded zero collections in every scan with a similar allocation volume.
Disabling collections improved the four-worker time in all 12 rounds.
Its four-worker median was still 7.2% above the one-worker median, slower
in 10 of 12 rounds. With libc, four workers reduced the median by 1.98× and
had lower latency in all 12 rounds. The build switches the allocator and
runtime thread registration as well as disabling reclamation. Each process
exited after one scan to bound unreclaimed memory. A separate two-second
capture across three checked four-worker scans with `GC.disable`
found the same `BinaryValue.new` allocator mutex stacks with zero collection
events. The controls expose both collection and contention in the Boehm
allocation path. GC mode also changes heap growth and reuse, so the wall-time
differences combine these effects.

On `4fcf1e1`, Crystal decoded 262,144 owned `BinaryValue` leaves for these two
columns, visited them for materialization accounting and typed-carrier checks,
and copied their values into packed `Array(UInt64)` buffers. The ClickHouse
build's `SerializationNumber` deserializes the fixed-width data through
`readBig` into a contiguous `ColumnVector` backing array. Those routes
present different amounts of work to LLVM before machine-code generation.
[Crystal fallback decode and accounting](../src/crystal_click/compact_part_table.cr),
[Crystal typed conversion](../src/crystal_click/binary_value_typed_batch_adapter.cr#L101),
[ClickHouse bulk numeric deserialization][ch-serialization-number].

The instrumented Release probe timed these regions over 20 checked
requests per worker count after a separate smoke request. The outer scan
and the reduction run on the caller. Timers inside parallel readers sum
elapsed time across workers, including contention. Their values can
overlap and exceed end-to-end latency. The instrumented HTTP medians were
54.368 and 73.400 ms. Nearby unpaired checks with the stock worker gave
56.056 and 70.746 ms (10 and 8 requests, respectively). Run-to-run variation
limits attribution of these differences to instrumentation.

| Timed region | 1 worker, median ms | 4 workers, median ms |
| --- | ---: | ---: |
| Outer scan including reduction | 54.150 | 73.098 |
| Compact read windows | 7.195 | 16.447 |
| Normalize Compact streams | 6.559 | 18.038 |
| Decode streams into `BinaryValue` | 24.988 | 200.430 |
| Estimate typed carrier materialization | 4.201 | 8.926 |
| Install typed batch carriers | 3.685 | 7.968 |
| Caller reduction | 0.075 | 0.123 |

Each request decoded exactly 32 frames and 2 MiB of values. The frame
decode timer within read windows was 4.123 and 4.621 ms summed,
respectively. The scan rebuilt the full 32-header frame index for each
column and mark. That produced 32 index builds at one worker and 40 at
four, including the additional reader admission work. At four workers,
reopening readers summed to 4.613 ms and acknowledgement waits summed to
4.226 ms. The ordered caller spent 72.840 ms receiving batches. The
decoder accumulated the largest increase in worker elapsed time, and
the caller's reduction was small on this fixture.
[Compact range transport](../src/crystal_click/compressed_mark_reader.cr#L281),
[Parallel scan handoff](../src/crystal_click/typed_part_table_parallel_scan.cr#L108).

[boehm-refill]: https://github.com/ivmai/bdwgc/blob/v8.2.12/mallocx.c#L284-L320
[ch-serialization-number]: https://github.com/ClickHouse/ClickHouse/blob/d9bcb5ab007f0f6299f7f973f2642245bab3d028/src/DataTypes/Serializations/SerializationNumber.cpp#L320-L335

### Direct UInt64 comparison

The direct reader and its `bd0ee29` baseline used Crystal 1.22.3
`--release -Dparallel_scan_bench` with Boehm enabled. Both read the same
Compact MRK3 file manifest as the earlier profile, on the same Apple M2 Max
and official ClickHouse 26.10.1.1201 binary. Each series used four warmup
pairs and 21 timed pairs under the comparison contract above. The ClickHouse
medians come from their corresponding Crystal series.

| Workers | Baseline Crystal, ms | Paired ClickHouse, ms | Direct Crystal, ms | Paired ClickHouse, ms |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 58.666 ± 3.571 | 2.603 ± 0.254 | 7.105 ± 0.119 | 1.886 ± 0.038 |
| 4 | 55.007 ± 1.183 | 1.848 ± 0.172 | 4.742 ± 0.138 | 1.398 ± 0.041 |

The direct reader reduced Crystal's median by 8.26× at one worker and 11.60×
at four. Within the direct build, four workers reduced the median by 1.50×.
The direct medians were 3.77× and 3.39× the paired ClickHouse medians.
These are warm aggregate request times for this one part on a shared
host. The full ordered exports, all timed aggregates, and the before/after
part manifests matched. The native thread-log probes saw one and four read
threads; the four-worker Crystal witness saw four isolated contexts.

| Evidence | SHA-256 |
| --- | --- |
| Baseline worker binary | `e3b3d57cab411da9266d6c5ddc592f66c3d01fa0b6e9ce790276d59a40c52773` |
| Direct worker binary | `a943e7cdc7603a2f31be96806184cba8c3f7da706604753512e29995d82ee710` |
| Direct source diff against `bd0ee29` | `ff5eb6bf5d12212ae88bf9cc3b719e0e1f41491e3c2370f51ec42587f9150257` |

In separate Release processes with Boehm enabled, the same probe read
`GC.stats.total_bytes` and `GC.prof_stats.gc_no` around one checked scan and
reduction. It excluded initial table open and response packing. Each cell
contains six fresh processes and reports the median. The allocation volume
includes the probe's own small runtime cost.

| Workers | Baseline allocated, MiB | Direct allocated, MiB | Baseline collections | Direct collections |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 111.96 | 4.20 | 22.5 (21–24) | 7 (6–7) |
| 4 | 113.85 | 6.05 | 16 (14–16) | 5.5 (5–7) |

The direct path removes both per-row allocation and the intermediate
materialization passes. The latency comparison combines their effects.

### Reusing Compact decode storage

The reusable slab was compared with the detached range buffers from
`d46b6781f11241350cbc635dfe465eeef65169cc`. Both Release builds used Crystal
1.22.3 and Boehm 8.2.12 on an Apple M2 Max with macOS 26.6.2. The native arm
used the same ClickHouse 26.10.1.1201 binary with `checksum_on_read=1`.
All three read the same MRK3 LZ4 part with two `UInt64` columns and 131,072
rows in sixteen 8,192-row marks. Its ten-file manifest has SHA-256
`80f5aaa885eae58e7e5d6888b28977888706d7100e91c5adcc7cb9309929c62a`.
The slab holds 128 KiB per worker for this fixture. Each selected range
coincides with a complete frame and needs no decode scratch.

The timing uses the request boundary above and rotates the three arms in
each worker-count track, with four warmup rounds and 21 timed rounds. A
fresh slab is allocated within each scan. The ordered exports and every
timed 48-byte response matched, and the part manifest matched before and
after the run. The four-worker probes observed four Crystal execution
contexts and four native read threads. Numbers are median ± MAD on a
shared host.

| Workers | Detached Crystal, ms | Slab Crystal, ms | ClickHouse, ms |
| ---: | ---: | ---: | ---: |
| 1 | 7.767 ± 0.208 | 6.460 ± 0.190 | 2.419 ± 0.219 |
| 4 | 5.301 ± 0.302 | 4.163 ± 0.224 | 1.807 ± 0.109 |

The slab build was faster in all 21 paired rounds at each worker count.
Median latency fell by 16.8% at one worker and 21.5% at four. At four
workers, the slab build took 2.30× the native median for this workload.

The allocation probe samples `GC.stats.total_bytes` and
`GC.prof_stats.gc_no` around one checked scan and reduction. It includes
slab and worker setup and excludes the initial table open and response
packing. The table shows medians from six fresh Release processes per
build and worker count, with the observed ranges for collections.

| Workers | Detached allocated, MiB | Slab allocated, MiB | Detached collections | Slab collections |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 4.21 | 0.31 | 7 (7–7) | 0 (0–0) |
| 4 | 6.04 | 2.53 | 6 (5–8) | 2 (2–2) |

The allocation volume fell by 92.5% and 58.2%, respectively. The latency
result combines storage reuse with the removal of the frame-to-result
copy. This part exercises the complete LZ4 frame path.

| Evidence | SHA-256 |
| --- | --- |
| Detached HTTP worker | `a5531cbfc6055e5b3ce129831a7c6a05425616e01f5802cfc3d1fcb4f6e9b14f` |
| Slab HTTP worker | `ebda159a1855692af28184a4d5d948a74137d62d3fb52919b6921d82b4569fb3` |
| Detached Boehm probe | `e0691b3cdc0edeffac2e6861005f405dbda325e15a1027301932183fe88a2d89` |
| Slab Boehm probe | `0f88fb070f0ebef69c55bdd9ca41ae764a531d4cbe4d2f05f7b9891e265bbff1` |
| Slab `src/` diff against `d46b678` | `1a9fc20532df5f2c815d673b793b6b481ab6da961aa590630ffb147ef999b1bf` |

### Sharing the Compact mapping and frame index

The reference is the slab build at `2467485e11374cff8f504300297a7add9056b974`.
Both builds use the same HTTP worker source, Crystal 1.22.3, and
`--release -Dparallel_scan_bench` with Boehm enabled. The run used the same
131,072-row Compact MRK3 LZ4 part and ClickHouse 26.10.1.1201 binary as the
slab comparison, on an Apple M2 Max with macOS 26.6.2.

The three arms rotate through four warmups and 21 timed rounds at each
worker count. Each timed request runs the scan and reduction on warm page
cache through a preconnected loopback HTTP socket. Crystal prepares a
fresh selected-part reader outside the timer. The scan mapping and worker
startup are included in the timer. Numbers are median ± MAD on a shared
host.

| Workers | Slab reference, ms | Shared mapping and index, ms | ClickHouse, ms |
| ---: | ---: | ---: | ---: |
| 1 | 6.463 ± 0.141 | 5.079 ± 0.093 | 2.639 ± 0.199 |
| 4 | 4.025 ± 0.257 | 2.629 ± 0.231 | 1.644 ± 0.109 |

The shared path was faster in all 21 paired rounds at each worker count.
Median latency fell by 21.4% and 34.7%, respectively. Both Crystal builds
used four execution contexts in their four-worker probes. The native arm
sets `max_threads` to the configured count. The final diagnostics observed
one and four positive-read threads in their respective tracks. An earlier
`max_threads=4` diagnostic observed two positive-read threads in one trial.

Every timed response matched the exact 48-byte reduction. All full ordered
exports matched the independent RowBinary fixture, block for block.
ClickHouse used `checksum_on_read=1`, and `CHECK TABLE` returned success
before and after timing. The ten-file part manifest stayed unchanged.

A separate acquisition test used two MRK3 parts with eight data marks and
two selected columns per part. The reference mapped and indexed each part
16 times during a one-worker scan and 24 times during a four-worker scan.
The shared path builds one index per part at admission and opens and
closes one scan mapping per accessed part at either worker count.

| Evidence | SHA-256 |
| --- | --- |
| Slab reference HTTP worker | `e84409748367bb1d62cc4b3bbc814b6b5f51d3c68b44975026f013f5110d33da` |
| Shared mapping HTTP worker | `7a3232850b01cbdd1bf6140fa9ae7d8f57fa5025810b639ccfa0e03d79c762fe` |
| Shared mapping `src/` file manifest | `35734103f7dbfebca1f643c4ea2b51327207e840b94989e82b37da0d3b1cf40c` |
| Full ordered RowBinary export | `5103eb0b689c92f3ebe4c23ae58816b4d120b12d5a543c2e274a58a547a075b5` |

### Profile of the shared Compact scan

This run used `c7d1cbd9f4e8189ebe0d22007481c1ebc536bdaa` and the same
131,072-row Compact MRK3 part, toolchain, and pinned ClickHouse binary as
above. The ten-file part manifest SHA-256 was
`80f5aaa885eae58e7e5d6888b28977888706d7100e91c5adcc7cb9309929c62a`.
Both Crystal builds used `--release -Dparallel_scan_bench` with Boehm
enabled. One served the ordinary worker. The other added monotonic clocks
and counters in a disposable source copy. Profile snapshots were fetched
after each timed round.

Each worker count had four warmups and 24 timed rounds per arm on
preconnected loopback sockets with warm file pages. All six possible
orders of the three arms occurred four times among the timed rounds.
The timer ran from POST to receipt of the full 48-byte reduction.
All 144 timed responses matched the expected bytes. Ordered exports
before and after timing matched the independent 2 MiB fixture at every
mark. ClickHouse used `checksum_on_read=1`, `CHECK TABLE` succeeded, and
the part files retained their hashes.

| Workers | Stock Crystal, ms | Profiled Crystal, ms | ClickHouse, ms | Stock / ClickHouse |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 4.915 ± 0.097 | 4.896 ± 0.157 | 2.228 ± 0.130 | 2.21× |
| 4 | 2.363 ± 0.143 | 2.440 ± 0.106 | 1.367 ± 0.045 | 1.73× |

Values are median ± MAD. The median paired profile-to-stock latency
ratio was 1.010 at one worker and 1.014 at four. At both counts the
paired shift was smaller than the MAD of the paired differences.

The profile below reports medians in milliseconds. A worker sum adds
elapsed intervals of all workers within one request. A maximum takes the
largest worker total within that request. Worker intervals can overlap
both other workers and the caller. Each profile verified 32 CityHash
checksums and decoded 32 complete LZ4 frames into 2,097,152 bytes. The
caller processed 32 batches of 4,096 rows. Every request mapped `data.bin`
once and checked its geometry against the admitted frame index.

| Profiled Crystal stage | 1 worker, ms | 4 workers, ms |
| --- | ---: | ---: |
| Scan and reduction | 4.766 | 2.303 |
| CityHash, worker sum | 0.809 | 0.902 |
| LZ4 decode, worker sum | 3.776 | 3.952 |
| CityHash and LZ4 together, maximum worker | 4.585 | 1.233 |
| Shared mmap and geometry check | 0.040 | 0.043 |
| Six reductions in the caller's batch loop | 0.071 | 0.289 |
| Worker reader admission, maximum worker | — | 0.692 |
| Caller launch, acknowledgement sends, and joins | — | 0.072 |
| Caller waiting for the next ordered batch | — | 1.914 |
| Worker waiting for batch acknowledgements, maximum worker | — | 0.283 |

The CityHash clock covers hashing the frame header and payload. Reading
and comparing the stored checksum stays outside that clock. The LZ4
clock covers `LZ4.decode_into`, including its validation and match copies.
Together they account for 96% of the one-worker scan and reduction.
The LZ4 decoder alone takes more elapsed time than the whole native
one-thread request. Disassembly of the stock ARM64 build shows byte
loads in `CityHashV1.fetch64` and a byte-copy loop for LZ4 matches.
The pinned ClickHouse build uses word loads in CityHash and its native
LZ4 decoder implements block match copies.

Four Crystal contexts each decoded eight frames. Context launch took
0.021 ms on the caller. The 0.692 ms reader admission includes opening
each worker's private reader with the shared part context and transport
budget. The caller received its first batch after 1.085 ms, versus 0.339
ms with one worker. Its receive waits overlap the worker opens and
decoding. Those waits and the worker acknowledgement waits measure
backpressure and data readiness along with channel delivery.

The reduction loop uses eight-row NEON iterations in both Crystal
binaries. At four workers the same loop took 0.289 ms across the 32
batches. The cause of the elapsed-time increase from 0.071 ms remains
unresolved. Thread CPU clocks at the scan boundaries measured a median
4.766 ms on the serial caller and 6.900 ms across the four workers plus
0.504 ms on the parallel caller. Boehm was enabled for all arms of the
Crystal comparison. The profile leaves collector time unattributed.

The native diagnostics ran separately with `log_query_threads=1`,
`log_processors_profiles=1`, and a 1 ms CPU sampling period set by the
HTTP request before SQL parsing. There were 16 profiled queries and
six processor-log on/off control queries at each count. The 44 results
matched the same 48 bytes. Each query read all 131,072 rows and 32
compressed blocks with checksum verification enabled. All diagnostic
queries with `max_threads=4` had four threads with positive row and
compressed-byte counts in `system.query_thread_log`.

| Native processor elapsed time | 1 thread, ms | 4 threads, ms |
| --- | ---: | ---: |
| `MergeTreeSelect`, sum | 1.140 | 1.445 |
| `MergeTreeSelect`, maximum | 1.140 | 0.389 |
| `AggregatingTransform`, sum | 0.091 | 0.119 |
| `AggregatingTransform`, maximum | 0.091 | 0.036 |

These medians use the per-query sum or maximum from
`system.processors_profile_log`. `MergeTreeSelect` covers the native read
including checksum and decompression. The four native partial aggregations
run on their own streams. The Crystal loop performs all reductions in the
calling fiber. Native processor waits and expression work are separate
from the table values. LZ4 appeared in 11 of 36 CPU stacks at one thread
and eight of 37 at four. No sampled stack named CityHash. The short
trace series locates decoder work but leaves native checksum and decode
wall times unresolved.

| Evidence | SHA-256 |
| --- | --- |
| Stock Crystal HTTP worker | `8af824701cb5d739f9e665e779cd7a496c695dda3c50e5b2a722acef4830e24a` |
| Profiled Crystal HTTP worker | `e17fbadfe1cd0ab1de2205d185cb770cac52e016070f04ebaeed92458a389450` |
| Compact `data.bin` | `dca9d56af3a75be50c7c3608e2549dc87a66466db98ebc8ed6bb74c88d33c334` |
| Expected 48-byte RowBinary reduction | `2f4e9f8b0da83ff03781c162a511f160dd0441c250c2f2c71d38e6950e96bc15` |

### Bounded LZ4 match copies

The decoder copies a disjoint match in one block. For an overlapping
match, it copies one period from the earlier output and expands the
initialized prefix in growing blocks. Each copy uses disjoint source and
destination ranges inside the validated output. Exact-size destination
slices need no padding.

The reference was `b20028de7662b38ef617e48b760c7ac3fd26497b`. The candidate
changed only `src/crystal_click/lz4.cr` in the benchmark source tree. Both
workers used Crystal 1.22.3, LLVM 23.1.5, and Boehm with
`--release -Dparallel_scan_bench` on the same M2 Max. The Compact MRK3 part
and official ClickHouse 26.10.1.1201 binary had the same hashes as in the
shared-scan profile. The part contains 32 LZ4 frames and 2 MiB of decoded
`UInt64` data. Of its 262,033 LZ4 matches, 241,016 have length five or
seven bytes. Only 37 overlap, all at distance one.

Each track used four warmups and 24 timed rounds per arm, with each of the
six arm orders occurring four times. A monotonic timer measured POST to
receipt of the complete response over preconnected loopback HTTP sockets.
Both Crystal readers were prepared outside the timed requests. ClickHouse
used the same reduction with `checksum_on_read=1` and `max_threads` set to
the track's worker count. Query result, query condition, uncompressed,
and deserialization-prefix caches were disabled.
All 216 timed responses matched the independent 48-byte reduction.
Ordered 2 MiB exports from all three arms matched before and after every
track. `CHECK TABLE` returned success and all ten part files kept their
hashes. Both Crystal arms rejected an altered reduction and reported four
isolated contexts in each four-worker track. Separate native diagnostics
at each count observed the requested number of reading threads and all
32 compressed blocks.

| Workers | Series | Scalar Crystal, ms | Block-copy Crystal, ms | ClickHouse, ms | Block copy / ClickHouse |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 1 | Initial | 4.953 ± 0.100 | 4.517 ± 0.066 | 2.121 ± 0.123 | 2.13× |
| 4 | Initial | 3.103 ± 0.238 | 2.916 ± 0.270 | 1.886 ± 0.170 | 1.55× |
| 4 | Repeat | 2.374 ± 0.122 | 2.410 ± 0.170 | 1.365 ± 0.038 | 1.76× |

Values are median ± MAD. At one worker the median fell by 8.8%, with a
median paired reduction of 0.450 ms and 24 wins in 24 pairs. At four
workers, the effect remained within pair-to-pair variation. The initial
series gave a median paired reduction of 0.017 ± 0.268 ms and the repeat
gave 0.096 ± 0.271 ms. Each had 13 wins in 24 pairs. The host snapshots
before these series showed 51.75% and 92.68% CPU idle, respectively. Both
Crystal arms had large latency outliers in the initial series.

The nine focused LZ4 examples passed for the scalar reference and the
candidate. Replacing the match loop with one whole-region copy failed
five of those examples. The 57 related compressed-block, Compact, and
typed-scan examples passed. A separate Release check compared 1,309
liblz4-generated blocks and three large-offset cases against expected
bytes, then compared both decoders on 20,000 arbitrary inputs, including
errors and writes to the destination and guard bytes.

| Evidence | SHA-256 |
| --- | --- |
| Scalar Crystal HTTP worker | `e34bedd282005fe2af7d0d9a9f25f9fc7c011b65218c63e432290fc4ae3d9f90` |
| Block-copy Crystal HTTP worker | `72fb08bcbea3a31a86d2c6f62cd4b241b6fcb3db9f60091922049b6c4d11c285` |

### Short disjoint LZ4 matches

After checking the output interval and match distance, the decoder handles
disjoint matches of four through seven bytes with two exact four-byte
copies. The payload ranges start at offsets zero and `match_length - 4`.
Their union covers the match, and the validated distance places the whole
source before the destination. Individual copies stay inside each range
and accept unaligned addresses. The ARM64 Release build lowers this branch
to two 32-bit loads and two stores.

The focused specs cover all four widths, adjacent and separated matches,
one-byte overlap, and exact output slices with canaries. A separate
Release check put exact slices next to inaccessible memory pages at
either end. Both decoders passed 160 valid cases and rejected another
160 cases whose output slices were one byte too short, with no writes
past the preceding literals.

The comparison used `70cba7b493715d9231c5588f1ce76d72d881941a` as the
block-copy reference and changed only the decoder in the candidate
build. The Compact part retained the ten-file manifest hash above. An
independent liblz4 decode matched all 32 frames against the fixture.
The short disjoint path covers 261,980 of the part's 262,033 matches (99.98%).

Both Crystal 1.22.3 builds used `--release -Dparallel_scan_bench` with
Boehm on the M2 Max. The pinned ClickHouse 26.10.1.1201 build ran with
`checksum_on_read=1`. Each worker count used the same preparation and
timer boundaries as the bounded-copy comparison, with four warmups per
arm and 24 rounds balanced across the six arm orders.

| Workers | Block-copy Crystal, ms | Short-copy Crystal, ms | ClickHouse, ms | Short copy / ClickHouse |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 4.622 ± 0.071 | 3.711 ± 0.088 | 2.531 ± 0.153 | 1.47× |
| 4 | 2.460 ± 0.101 | 2.238 ± 0.064 | 1.831 ± 0.051 | 1.22× |

Values are median ± MAD. At one worker the median paired reduction was
0.906 ms (19.4% median paired change), with 24 wins in 24 pairs. At four
workers it was 0.271 ms (10.7%), with 22 wins in 24 pairs. Each of the
six order groups favored the short-copy build at both worker counts.
These results are for this part's match distribution and warm requests.

All 144 timed responses matched the independent 48-byte reduction.
Every ordered 2 MiB export matched before and after timing, `CHECK TABLE`
passed, and the part file hashes remained identical. Separate ClickHouse
diagnostics read all 32 frames at both counts and observed one and four
threads with positive row and compressed-byte counts, respectively.
The LZ4, checksum, and typed-scan regression run passed 69 examples.

| Evidence | SHA-256 |
| --- | --- |
| Block-copy Crystal HTTP worker | `552b54d1700a33b7ef45e806799cb647183cdac66b6785fba535c36634723ea0` |
| Short-copy Crystal HTTP worker | `03ec849329b2d075dc1876a6ff87a5ab1ed9ba03e8c3f5e267a385cf8fc64397` |

## Reproduce the comparison

Run from the repository root with Python 3, Crystal, and the pinned
ClickHouse binary. Use a disposable directory on the external SSD. The six
server ports starting at 35100 and the Crystal worker port must be free.

```sh
bench_ch=/path/to/clickhouse
bench_work=$(mktemp -d /opt/mldata_ssd/tmp/crystal-click-compare.XXXXXXXX)
bench_reference=09d3d955f0b3cd37d1e114525d4f7e16d7a9e4f5
bench_fixture="$bench_work/native"
bench_manifest="$bench_fixture/fixture-manifest.json"
mkdir -p "$bench_work/tmp" "$bench_work/cache"

git worktree add --detach "$bench_work/reference" "$bench_reference"
cp benchmarks/parallel_scan_http_worker.cr "$bench_work/reference/benchmarks/"
TMPDIR="$bench_work/tmp" CRYSTAL_CACHE_DIR="$bench_work/cache" \
  crystal build --release "$bench_work/reference/benchmarks/parallel_scan_http_worker.cr" \
  -o "$bench_work/reference-worker"
TMPDIR="$bench_work/tmp" CRYSTAL_CACHE_DIR="$bench_work/cache" \
  crystal build --release -Dparallel_scan_bench benchmarks/parallel_scan_http_worker.cr \
  -o "$bench_work/candidate-worker"

python3 -B scripts/parallel_scan_benchmark.py native-start \
  --root "$bench_fixture" --clickhouse-bin "$bench_ch" --wide-port 35100 --compact-port 35103
python3 -B scripts/parallel_scan_benchmark.py prepare \
  --root "$bench_fixture" --wide-port 35100 --compact-port 35103 \
  --rows 131072 --mark-rows 8192
```

Run `native-probe` for both layouts and both thread counts. This checks
actual reads separately from timing.

```sh
for bench_layout in wide compact; do
  for bench_threads in 1 4; do
    python3 -B scripts/parallel_scan_benchmark.py native-probe \
      --manifest "$bench_manifest" --layout "$bench_layout" --threads "$bench_threads"
  done
done
```

Start a Crystal worker for each track. The example runs the four-worker
Compact track. For the one-worker candidate, set `bench_threads=1`. For the
reference pair use `bench_threads=1`, `bench_mode=baseline-serial`, the
`reference-worker` binary, and `bench_revision="$bench_reference"`. Run
all three tracks with each layout. The original track order was Wide
reference, Compact candidate 1, Wide candidate 4, Compact reference,
Wide candidate 1, and Compact candidate 4.

```sh
bench_layout=compact
bench_threads=4
bench_mode=parallel
bench_bin="$bench_work/candidate-worker"
bench_revision=$(git rev-parse HEAD)
bench_part=$(python3 -B -c 'import json, sys
with open(sys.argv[1]) as manifest:
    print(json.load(manifest)["layouts"][sys.argv[2]]["part"]["path"])' \
  "$bench_manifest" "$bench_layout")
TMPDIR="$bench_work/tmp" "$bench_bin" --layout "$bench_layout" --part "$bench_part" \
  --workers "$bench_threads" --port 35900 &
bench_worker=$!
```

After the worker prints `READY`, run the timing track and stop the worker.
The JSON contains the raw paired samples, checks, and summary statistics.
The Compact profile comparison used only the two parallel-mode Compact
tracks, with `--warmups 4 --repeats 21` at revision `4fcf1e1`.
For the direct UInt64 comparison, build `bd0ee29` and the direct-reader
revision with `--release -Dparallel_scan_bench` using their own benchmark
worker source. Run both Compact tracks at each revision with
`--mode parallel --warmups 4 --repeats 21` against the same manifest.
For the slab comparison, use `d46b678` as the reference and build both
revisions with the same flags. Keep one prepared HTTP worker per revision
and rotate the two Crystal requests and the ClickHouse request in each round.
For the shared-mapping comparison, use `2467485` as the reference with the
same flags, HTTP worker source, fixture, and three-way rotation.
Use `c7d1cbd` with `--warmups 4 --repeats 24` for the stock tracks of the
shared scan profile. Stage profiling requires a separate instrumented
worker with elapsed clocks around `verify_frame_checksum!`'s CityHash
call, `LZ4.decode_into`, the reducer loop, the shared map admission, and
the parallel worker boundaries listed above. Fetch stage results outside
the request timer. For the native diagnostic, enable `trace_log` and
`processors_profile_log` on a disposable server. Set
`query_profiler_cpu_time_period_ns=1000000` and
`query_profiler_real_time_period_ns=0` as HTTP parameters. Join the
diagnostic logs by query ID after `SYSTEM FLUSH LOGS`.

For the LZ4 comparison, build `b20028d` and the block-copy revision with
`--release -Dparallel_scan_bench`. Use the Compact fixture and both worker
counts. Start a prepared HTTP worker for each revision and connect both
workers and ClickHouse before the warmups. For each count, run four warmups
per arm and four copies of each three-arm permutation. This run shuffled the
24 measured orders using Python `random.Random(20261115 + workers)`, starting
from `itertools.permutations(("stock", "block_copy", "clickhouse"))`. Call
`/prepare` on the Crystal arm outside each timed request, and use
`settings_sql(workers, 1)` and `checked_request_ns` from the benchmark
script. Preserve all samples when recomputing paired differences.
For the short-match comparison, use `70cba7b` and the short-copy revision
with the same schedule. Substitute `("baseline", "candidate", "clickhouse")`
for the three arm names.

```sh
python3 -B scripts/parallel_scan_benchmark.py bench \
  --manifest "$bench_manifest" --layout "$bench_layout" --crystal-port 35900 \
  --mode "$bench_mode" --threads "$bench_threads" --warmups 2 --repeats 15 \
  --crystal-binary "$bench_bin" --source-revision "$bench_revision" \
  --output "$bench_work/$bench_layout-$bench_mode-$bench_threads.json"
kill "$bench_worker"
wait "$bench_worker" || true
```

After all tracks, stop the two benchmark servers, remove the detached
worktree, and remove the disposable directory after saving any results.

```sh
python3 -B scripts/parallel_scan_benchmark.py native-stop --root "$bench_fixture"
rm "$bench_work/reference/benchmarks/parallel_scan_http_worker.cr"
git worktree remove "$bench_work/reference"
python3 -B -c 'import shutil, sys; shutil.rmtree(sys.argv[1])' "$bench_work"
```

## Regression checks

```sh
crystal spec spec/typed_part_table_parallel_scan_spec.cr \
  spec/offline_catalog_spec.cr spec/lazy_window_reader_spec.cr \
  spec/multicolumn_table_scan_spec.cr \
  spec/compact_mark_file_adapter_w274_integration_spec.cr \
  spec/storage_read_budget_w245_spec.cr
crystal spec -Dwithout_mt spec/typed_part_table_parallel_scan_spec.cr
```

The focused suite passed 89 examples. The `-Dwithout_mt` run passed six
examples and exercised the one-worker scan and execution-context guard.

For the direct reader, run `crystal spec spec/compact_typed_w260_spec.cr`
and repeat with `-Dwithout_mt`. The combined reader, writer, projection,
recursive carrier, and transport regression run passed 120 examples. The
direct Compact suite passed 22 examples with `-Dwithout_mt`.

For the slab, the reader, writer, projection, recursive carrier, and
transport suites passed 165 examples. The Compact typed and parallel scan
suites passed 30 examples with `-Dwithout_mt`. The added guards cover slab
lifetime, capacity accounting, exact-fit fallback, partial frames, and
checksum rejection before a write to the failing frame's destination.

For the shared mapping, `spec/compact_parallel_scan_mapping_spec.cr` passed
three examples. It counts mapping opens, closes, and frame-index builds and
checks cleanup when a worker never reaches a mapped part. The related
parallel, Compact typed, writer, mark adapter, mmap, Dynamic, and offline
transform suites covered 86 passing examples. The offline transform suite
uses a physically resolved `TMPDIR` for its path equality check. The mapping,
parallel, mmap, and W124 transport specs passed 31 examples with
`-Dwithout_mt`.

## Falsifiers

- An ordered scan must match serial rows, batch coordinates, and batch size
  limits on mixed parts and when one part is split across workers.
- A callback failure or a worker failure must release outstanding buffers and
  join the workers. A subsequent scan of valid parts must still succeed.
- An ordinary `UInt64` Compact scan must build no additional frame index and
  map each accessed `data.bin` exactly once. Aborting at an earlier part must
  close a later part's mapping even if an assigned worker never acquired it.
- Splitting Compact marks between workers must keep a cumulative per-part
  transport limit. For the shared `UInt64` path, file and header work is
  charged per mapping and selected range work accumulates across workers.
- The benchmark must reject an incorrect aggregate and changed part bytes.
  Worker probes confirm the Crystal execution contexts and record the number
  of ClickHouse threads that read rows at each `max_threads` setting.

Revert the parallel scan change to remove the opt-in path. Keep the sequential
reference timings as evidence for their pinned revision and runtime.
