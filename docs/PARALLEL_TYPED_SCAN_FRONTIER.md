# Parallel typed scan and read comparison

The sequential reference is `main` at
`09d3d955f0b3cd37d1e114525d4f7e16d7a9e4f5`.

## Scan contract

`TypedPartTable#scan_typed_parallel` assigns nonempty physical marks of
selected immutable Wide and Compact parts to workers in round-robin order.
It accepts 1–32 workers, capped by the number of those marks.
`OfflineTable#scan_typed_parallel` uses the same catalog resolution and DDL
checks as `scan_typed`. A request for one worker runs the scan on the caller.
With execution contexts enabled, a single nonempty mark also takes this
path. The threaded path admits exact
`UInt8`–`UInt64`, `Int8`–`Int64`, `Float32`, and `Float64` columns in ordinary
parts with Crystal execution contexts enabled. It rejects projection children
and flattened `Nested` bindings.

Each worker decodes on its own system thread with private decode state. The
calling fiber consumes one physical mark at a time in source order, with the
same batch boundaries and offsets as `scan_typed`. Other workers can decode
their next assigned mark during each callback. A worker has at most one
outstanding batch and may reuse its buffers when the callback returns.
Workers on one Compact part share its cumulative transport budget across
reader admission and decoding. Its file, record, decoded-byte, and result-byte
allowances apply across the complete worker group.
Operation exit waits for all scan work after normal completion, early exit,
and decoder or callback failures. Keep selected part files stable for the
lifetime of the reader and use a separate reader for each concurrent scan.

For the admitted ordinary, direct `UInt64` Compact path on little-endian
hosts, the workers borrow the table's selected column bindings and mark grid
for that physical context. Each worker owns its decode workspace. Other
selections open independent readers on the workers.

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

### Wide reader admission

An ordinary parallel Wide scan of direct primitive numeric columns with
`.mrk2` marks shares the admitted part metadata, stream mark offsets, and
read-only data mappings between workers. Admission validates the selected
columns and their common row grid. A touched part opens one mapping per
selected data file and closes them after its last assigned worker finishes.
Each worker keeps its decode storage private and checks its selected data
ranges. The part files must stay immutable for the reader's lifetime.

A retained `TypedPartTable` also reuses admitted Wide metadata and mark
indexes across sequential calls to `scan_typed_parallel`. Each call opens
its own data mappings and uses exclusively owned decode storage. Open a new
reader when the selected parts or columns change. The catalog convenience
methods open a new reader for each call.

### Direct Wide UInt64 batches

When every selected part is ordinary Wide `.mrk2` and every selected
column is a direct `UInt64`, the parallel typed scan uses the checked
Wide mark-range reader on each worker, including the one-worker path.
Each worker reuses one frame decode workspace and writable storage for the
selected columns, sized to its largest assigned mark. Every selected part
passes backend preflight before the first callback. The worker validates the
full range for every selected column before publishing the first batch from
that mark. The callback receives `Slice(UInt64)` views over the corresponding
rows with the same batch limits, source order, and coordinates as the
general typed scan. The worker keeps the current mark through its last
callback acknowledgement. A direct batch stores the window into the
worker's selected slices and uses the admitted column metadata. The
ordinary `values_for` accessors read that window without constructing
per-batch slice arrays or the generic typed-carrier maps.

Repeated scans can borrow typed value and decode buffers from four
process-wide workspace slots. Each idle slot retains at most 512 KiB of
buffer payload. Busy slots and additional workers use scan-local buffers.
Oversized workspaces are dropped when released. Mappings belong to each
scan.

This path inherits the ordinary Wide data-frame verification policy.
The checked range reader validates frame sizes and boundaries and the exact
logical width of each mark. With `SizeChecked` admission the reader also
checks persisted file sizes.

### Retaining parallel workers

Repeated direct Wide UInt64 scans can lease one bounded group of isolated
workers and their channels for requests of two to four workers with two
or more nonempty marks. One-worker scans run on the caller. A busy group,
a larger request, or a selection outside the direct Wide UInt64 path uses
the existing scan-owned workers.
The lease covers the entire batch and acknowledgement exchange. Every
dispatched job releases its resources before the caller closes the residual
scan mappings and returns the group. The group holds no part images or user
callbacks between scans.

Admission requires a matched before-and-after scan on the pinned Wide
part, plus reuse across different readers and worker counts, reentrancy
while a callback has writable slices, and successful reuse after callback
failure, early exit, and decoder corruption. Reverting this slice restores
the scan-owned execution contexts and channels from `9b08b1e`.

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

### Direct reader comparison contract

The direct comparison uses the same generated Wide MRK2 and Compact MRK3
parts, two ordinary `UInt64` columns, and an explicit ordered list of
complete positive marks. Both runners read the same contiguous slices of
that list with one or four workers and verify the compressed data frame
checksums during the scan.

Startup admits the immutable part and allocates the output buffers. Crystal
Wide retains its selected column readers and one mapping per selected
column across commands. Its one-time admission timer covers opening the
readers and validating the selected mark grid. The mapping timer covers
opening the data image before the first scan. The worker preparation timer
covers Wide's typed scratch allocation, decode workspace initialization, and
parallel worker readiness before `READY`. The decode workspace allocates
its byte storage on the first frame that needs it. ClickHouse retains the
storage context and builds fresh reader cursors for each scan. Crystal
Compact prepares a fresh typed table, mark grid, frame index, and transport
budget for each scan. Per-scan preparation
is timed separately. The scan timer covers dispatch and waiting for workers,
checksum verification, decompression, typed batches, and one copy of each
batch into the ordered output buffers. For scan-owned workers it includes
their startup and joins.
It includes stream opens and closes performed within that interval.
ClickHouse calls `IMergeTreeReader::readRows` once per selected mark and
continues the reader across consecutive marks. It uses synchronous `pread`
with asynchronous mark loads and reader caches disabled. Crystal Wide
workers borrow the same read-only data views through each scan. Crystal
Compact uses one mapping per part and a decode workspace per worker, then
yields batches of at most 4,096 rows. Each runner validates the complete
output against the column-major fixture oracle after stopping the timer.
Parent-side checks require the same observed marks per worker and unchanged
part files. Warmups populate the OS page cache. Two-runner comparisons
alternate order. Comparisons that include a second Crystal binary cycle
through the six runner orders.

Before timing, both runners must admit a part whose first compressed frame
differs by one checksum byte, then report a checksum error on `scan`. The
original parts must produce exact values. This gate qualifies data-frame
checksum coverage for the measured paths and fixture. The HTTP comparison
above uses its own Wide checksum policy.

Use a disposable ClickHouse source checkout at
`d9bcb5ab007f0f6299f7f973f2642245bab3d028` with its build dependencies.
Include the benchmark target at the end of the checkout's root
`CMakeLists.txt`, then build `clickhouse-read-rows` with the native
ClickHouse toolchain in Release mode. Use build and source paths without
spaces or shell metacharacters for the upstream build scripts. Run these
commands from the CrystalClick repository root. `bench_work` is a disposable
scratch directory, `bench_fixture` is the native fixture directory created
by `native-start` and `prepare` below, and `ch_src` is the source checkout.
Set `ch_clang` and `ch_clangxx` to the ClickHouse toolchain's compiler paths.
Stop the fixture servers before timing to exclude their background work.

```sh
printf '\ninclude("%s/CMakeLists.txt")\n' \
  "$PWD/benchmarks/clickhouse_read_rows" >> "$ch_src/CMakeLists.txt"
cmake -S "$ch_src" -B "$bench_work/ch-build" -G Ninja \
  -DCMAKE_C_COMPILER="$ch_clang" -DCMAKE_CXX_COMPILER="$ch_clangxx" \
  -DCMAKE_BUILD_TYPE=Release -DENABLE_TESTS=OFF \
  -DENABLE_BENCHMARKS=ON -DENABLE_LIBRARIES=OFF
cmake --build "$bench_work/ch-build" --target clickhouse-read-rows

mkdir -p "$bench_work/read-rows-tmp" "$bench_work/read-rows-cache"
TMPDIR="$bench_work/read-rows-tmp" CRYSTAL_CACHE_DIR="$bench_work/read-rows-cache" \
  crystal build --release benchmarks/read_rows_scan.cr -o "$bench_work/read-rows-crystal"

python3 -B scripts/parallel_scan_benchmark.py native-stop --root "$bench_fixture"
python3 -B scripts/read_rows_benchmark.py \
  --manifest "$bench_fixture/fixture-manifest.json" --scratch "$bench_work" \
  --crystal-bin "$bench_work/read-rows-crystal" \
  --cpp-bin "$bench_work/ch-build/clickhouse-read-rows" \
  --warmups 6 --repeats 32 --output "$bench_work/read-rows.json"
```

The report includes binary and part hashes, selected marks, p50 and p95 for
per-scan preparation, scan time, and their per-sample sum. It records Wide
reader admission and data mapping once per retained Crystal process. In
retained-worker mode it also records the worker preparation and the elapsed
time to `READY`.
ClickHouse storage context startup precedes the measured intervals. To test
gaps in the mark sequence, use
`--marks 0,2,4,7,8,10,13,15` on the 16-mark fixture.

Clang 23.1.5 on macOS required warning demotions scoped to three source files
with the pinned ClickHouse checkout. Add these CMake lines after the `dbms`
target is declared if that compiler treats the same diagnostics as errors.

```cmake
set_source_files_properties("${CMAKE_SOURCE_DIR}/src/Interpreters/executeQuery.cpp"
    TARGET_DIRECTORY dbms PROPERTIES COMPILE_OPTIONS "-Wno-error=unused-function")
set_source_files_properties("${CMAKE_SOURCE_DIR}/src/Interpreters/FileCache/FileCache.cpp"
    TARGET_DIRECTORY dbms PROPERTIES COMPILE_OPTIONS "-Wno-error=unreachable-code")
set_source_files_properties("${CMAKE_SOURCE_DIR}/src/Storages/MergeTree/MergeTreeData.cpp"
    TARGET_DIRECTORY dbms PROPERTIES COMPILE_OPTIONS "-Wno-error=unused-variable;-Wno-error=unused-parameter")
```

### Direct reader measurements

The initial run used CrystalClick at
`dfa0072cbbf8722d5a28c3a6d25705f59efd2ec5`, where the Wide benchmark opened
a pair of column readers per worker. It used an Apple M2 Max, macOS 26.6.2
arm64, and the external APFS fixture with a warm page cache. The ClickHouse
C++ runner linked the pinned source in Release mode with Clang 23.1.5 and
`ENABLE_LIBRARIES=OFF` (jemalloc disabled).
The Crystal runner used Crystal 1.22.3 `--release`, LLVM 23.1.5, and Boehm
8.2.12. Both read 131,072 rows of two `UInt64` columns in 16 marks of
8,192 rows, with identical files and mark assignments for each layout and
worker count. The decoded output per scan was 2 MiB.

Each track used six warmup pairs and 32 alternating measured pairs. The
scan p50 is the median and p95 is the 31st value in each sorted set of 32
samples. The total p50 is the median of each sample's preparation plus scan.
Times are in milliseconds.

| Part | Workers | Crystal scan p50 / p95 | ClickHouse scan p50 / p95 | Crystal total p50 | ClickHouse total p50 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Wide | 1 | 1.7855 / 2.1300 | 1.0075 / 1.0993 | 2.0868 | 1.0188 |
| Wide | 4 | 0.8595 / 1.0152 | 0.4717 / 0.5825 | 1.9173 | 0.4931 |
| Compact | 1 | 1.5450 / 2.2028 | 1.1464 / 1.2195 | 2.0440 | 1.1527 |
| Compact | 4 | 0.6805 / 0.8197 | 0.4296 / 0.4878 | 1.1514 | 0.4420 |

| Part | Crystal 1-to-4 scan speedup | ClickHouse 1-to-4 scan speedup | Crystal 1-to-4 total speedup | ClickHouse 1-to-4 total speedup |
| --- | ---: | ---: | ---: | ---: |
| Wide | 2.08× | 2.14× | 1.09× | 2.07× |
| Compact | 2.27× | 2.67× | 1.78× | 2.61× |

Every sample matched the ordered oracle. All first-frame checksum controls
passed. A second control flipped a checksum in mark 13. Both runners read
the exact selected rows when the mark was excluded and failed when it was
assigned to the fourth worker. A wrong output oracle also rejected clean
scans. A separate run on eight nonconsecutive marks passed for both layouts
and worker counts. Both part manifests matched before and after timing.

| Evidence | SHA-256 |
| --- | --- |
| ClickHouse readRows runner | `d1ce604c7f0a5a29d6d579103f908d68d7050ec07eac0208fe595e8b2d97183c` |
| Crystal direct reader runner | `0cd29d622a8c614638556200032d56a9aa7cbbda96366d36d39d246905c1e8d9` |
| Full-mark column-major oracle | `24c35659e776fe4a17d8686e55e5365348b0987f172fd657990216cef48b8b89` |
| Wide part file manifest | `2e55e9cbe502047752b136e25b707f68d72f183e365f0d7052a6278ce0bafc45` |
| Compact part file manifest | `80f5aaa885eae58e7e5d6888b28977888706d7100e91c5adcc7cb9309929c62a` |

### Wide shared admission comparison

Build a baseline from `dfa0072cbbf8722d5a28c3a6d25705f59efd2ec5` with the
same Crystal release flags as the current runner. Use the same fixture and
ClickHouse target as above.

```sh
git worktree add --detach "$bench_work/crystal-baseline" \
  dfa0072cbbf8722d5a28c3a6d25705f59efd2ec5
(
  cd "$bench_work/crystal-baseline" &&
  TMPDIR="$bench_work/read-rows-tmp" CRYSTAL_CACHE_DIR="$bench_work/read-rows-cache" \
    crystal build --release benchmarks/read_rows_scan.cr -o "$bench_work/read-rows-baseline"
)
python3 -B scripts/read_rows_benchmark.py \
  --manifest "$bench_fixture/fixture-manifest.json" --scratch "$bench_work" \
  --crystal-bin "$bench_work/read-rows-crystal" \
  --crystal-baseline-bin "$bench_work/read-rows-baseline" \
  --cpp-bin "$bench_work/ch-build/clickhouse-read-rows" \
  --layout wide --workers 1 --workers 4 --warmups 6 --repeats 36 \
  --output "$bench_work/wide-shared.json"
git worktree remove "$bench_work/crystal-baseline"
```

The comparison used the same Wide part and ClickHouse binary hashes as the
initial run. All three Release runners scanned marks 0 through 15, with
8,192 rows per mark and 131,072 rows of two `UInt64` columns. The fixture was
on the external APFS SSD with a warm OS page cache. Each worker track used
six warmup rounds and 36 recorded rounds. Each of the six runner orders
occurred six times in the recorded rounds.

Both Crystal versions prepare their selected readers inside the preparation
timer. ClickHouse retains the loaded storage part context and constructs
fresh readers inside that timer. Each total sample is its own preparation
plus scan. Times are in milliseconds.

| Runner | Workers | Prepare p50 | Scan p50 / p95 | Total p50 / p95 |
| --- | ---: | ---: | ---: | ---: |
| Crystal baseline | 1 | 0.2896 | 1.8000 / 2.1306 | 2.0907 / 2.4755 |
| Crystal shared | 1 | 0.2551 | 1.7926 / 2.1035 | 2.0626 / 2.3945 |
| ClickHouse readRows | 1 | 0.0086 | 1.0121 / 1.0931 | 1.0246 / 1.1268 |
| Crystal baseline | 4 | 1.0222 | 0.7396 / 0.9557 | 1.7635 / 2.0054 |
| Crystal shared | 4 | 0.2458 | 0.7302 / 0.9465 | 0.9909 / 1.2204 |
| ClickHouse readRows | 4 | 0.0195 | 0.4744 / 0.5077 | 0.4917 / 0.5280 |

| Runner | 1-to-4 scan p50 speedup | 1-to-4 total p50 speedup |
| --- | ---: | ---: |
| Crystal baseline | 2.43× | 1.19× |
| Crystal shared | 2.46× | 2.08× |
| ClickHouse readRows | 2.13× | 2.08× |

With four workers, shared admission improved preparation p50 by 4.16× and
total p50 by 1.78×. The observed scan p50 moved by 1.3%. Each of the three
runner positions gave preparation p50 between 0.996 and 1.031 ms for the
baseline and between 0.245 and 0.259 ms for the shared reader. The shared
Crystal scan took 1.54× the ClickHouse scan p50 with four workers, or 2.02×
including the per-scan preparation in both runners.

All 216 recorded scans matched the complete ordered oracle. Part-file hashes
were unchanged and all first-frame corruption controls passed. A separate
four-worker control flipped a checksum in mark 13. All three runners read
the exact rows when the mark was skipped and rejected the scan when the
fourth worker was assigned that mark. All three also rejected a wrong oracle.
The Release suite passed 48 examples. The `-Dwithout_mt` suite passed 12.
The admission spec checks single parsing of both selected
mark files and metadata for each of two distinct parts, exact values and batch
coordinates, a mixed numeric selection, and malformed metadata rejection.

| Evidence | SHA-256 |
| --- | --- |
| Crystal baseline runner | `7349305c0b818ec907b2384cd180d44be628996a030d23551add13f7428b6866` |
| Crystal shared runner | `3b4652c094d92fbd0670b9f33b569034765c6ec6de328a7fa64326a9010b3626` |
| Wide shared benchmark report | `306c9ede439fce802063bada0ab2bdc7b01fc7207f57b6e0e63d3e4589b92b95` |

### Wide stage profile

The profile uses the same direct storage read and ordered oracle as the
Wide shared admission comparison. Use one Release control and one
instrumented Release binary per engine. The driver interleaves all four
arms and retains preparation, scan, and per-worker stage samples. It
independently walks the LZ4 frame headers between each selected pair of
MRK2 boundaries and checks both the checksum and decode counts per worker.
It also checks typed and ordered output byte counts, exact output, and
checksum failure on the single-byte corruption control.

| Stage | Crystal Wide scan | ClickHouse Wide readRows |
| --- | --- | --- |
| Transport syscall | `mmap` and `munmap` | `pread` |
| File lifecycle | Data file size, open, descriptor stat, and close | Cached-path descriptor open and close, and observed descriptor stats |
| Checksum | `CityHashV1.hash128` | `CityHash_v1_0_2::CityHash128` |
| LZ4 | Token decode loop | Native LZ4 decoder call |
| Materialization copy | Decoded byte slices into the typed scratch | Copies from the decompressed buffer into the typed column |
| Ordered output copy | Typed scratch into the benchmark output | Typed column into the benchmark output |

The two transport clocks cover different system calls. Crystal counts mapped
lengths, and ClickHouse counts bytes returned by `pread`. A file-backed
mapping can fault on first access in a later stage. The copy counters
cover the two explicit boundaries above. Direct decode into the destination
is already in LZ4 and has a separate byte counter on the native arm.
The [native probe reference](../benchmarks/clickhouse_read_rows/PROFILE.md)
gives the exact source scopes. The additional Crystal dispatch timer covers
five type checks in each frame loop, a subset of reader control flow.

Each worker interval spans entry into its scan body through its exit,
including the reader cleanup in that body. The report retains stage sums
across all workers and stages along the last-finishing worker. For each
sample, scan wall time is time outside the worker envelope plus the delay
until the last-finishing worker starts, followed by that worker's body.
The worker body includes measured stages and a remainder. The caller's
launch and join clocks overlap worker activity. Join includes waiting for
workers, and the remainder includes uninstrumented work, scheduling delays,
and parts of the measurement overhead. Medians of individual stages can
come from different samples.

For retained Crystal workers, the profile's `launch_ns` measures dispatch
and `join_ns` measures the completion barrier. It records worker setup
separately and joins the retained contexts when the session ends.

Wide mapping work inside a scan appears in `shared_mmap`. Its open and
close intervals fall outside the workers' envelope. For scan-owned images
the validator checks one map and unmap per stream and the physical byte
lengths. For retained images it checks the startup counts and byte lengths
in `retained_mmap` and zero mapping work inside the scan. Both cases require
zero worker-side mmap calls. The stage results below used per-worker maps.

For Crystal, build a second runner with `-Dread_rows_profile`. On the
ClickHouse side, save the uninstrumented executable first, apply the
benchmark probes to the disposable pinned checkout, and enable the profile
option for the incremental build. Keep the same Release flags for each pair.
Set `ch_runner` to the executable produced by the configured CMake target.

```sh
cp "$ch_runner" "$bench_work/read-rows-clickhouse-control"
python3 -B benchmarks/clickhouse_read_rows/apply_profile_patch.py "$ch_src"
cmake -S "$ch_src" -B "$bench_work/ch-build" -DCLICKHOUSE_READ_ROWS_PROFILE=ON
cmake --build "$bench_work/ch-build" --target clickhouse-read-rows

TMPDIR="$bench_work/read-rows-tmp" CRYSTAL_CACHE_DIR="$bench_work/read-rows-cache" \
  crystal build --release -Dread_rows_profile benchmarks/read_rows_scan.cr \
  -o "$bench_work/read-rows-crystal-profile"

python3 -B scripts/read_rows_benchmark.py \
  --manifest "$bench_fixture/fixture-manifest.json" --scratch "$bench_work" \
  --crystal-bin "$bench_work/read-rows-crystal" \
  --crystal-profile-bin "$bench_work/read-rows-crystal-profile" \
  --cpp-bin "$bench_work/read-rows-clickhouse-control" --cpp-profile-bin "$ch_runner" \
  --layout wide --workers 1 --workers 4 --warmups 8 --repeats 48 \
  --output "$bench_work/read-rows-wide-profile.json"
```

#### Measurements

The campaign used the byte-identical Wide part from the shared admission
comparison on the same Apple M2 Max host with a warm OS page cache. Both
runners scanned marks 0–15, with 8,192 rows per mark and two `UInt64`
columns. Each run had eight warmup rounds and 48 measured rounds per
worker count, with each of the 24 runner orders appearing twice. A second
campaign reversed the worker-count order.

Crystal reopened the shared metadata and mark indexes in its preparation
timer. The native harness retained its loaded part context across requests
and constructed fresh readers in the same timer. The native reader used
`pread` with its usual descriptor cache and with prefetch disabled.

Control binaries, in milliseconds. The total is calculated per sample before
taking its quantiles.

| Runner | Workers | Prepare p50 | Scan p50 / p95 | Total p50 / p95 |
| --- | ---: | ---: | ---: | ---: |
| Crystal | 1 | 0.269 | 1.792 / 2.061 | 2.074 / 2.307 |
| ClickHouse `readRows` | 1 | 0.016 | 1.023 / 1.139 | 1.038 / 1.156 |
| Crystal | 4 | 0.246 | 0.742 / 0.974 | 0.993 / 1.228 |
| ClickHouse `readRows` | 4 | 0.020 | 0.481 / 0.542 | 0.501 / 0.566 |

The 1-to-4 scan p50 speedup was 2.42× in Crystal and 2.12× in ClickHouse.
Including preparation, the speedup was 2.09× and 2.07×, respectively.
Reversing the worker-count order gave scan p50s of 1.791 ms and 0.788 ms
in Crystal, and 1.047 ms and 0.474 ms in ClickHouse. The matching speedups
were 2.27× and 2.21×.

Instrumented stage p50, in microseconds on the last-finishing worker in each
sample. This is the sole worker in the one-worker track.

| Worker stage | Crystal 1 | ClickHouse 1 | Crystal 4 | ClickHouse 4 |
| --- | ---: | ---: | ---: | ---: |
| Transport syscall | 16.3 | 67.8 | 13.0 | 48.7 |
| File lifecycle | 34.0 | 59.9 | 59.6 | 2.9 |
| CityHash128 | 277.2 | 77.9 | 79.4 | 20.6 |
| LZ4 | 1,210.9 | 678.6 | 316.2 | 177.5 |
| Materialization copy | 40.9 | 2.4 | 11.3 | 0.6 |
| Ordered output copy | 30.9 | 41.1 | 8.1 | 11.1 |
| Five Crystal type checks per frame | 31.0 | — | 9.6 | — |
| Other worker time | 165.3 | 124.6 | 64.1 | 167.6 |
| Worker body | 1,841.8 | 1,063.8 | 600.6 | 441.3 |

| Four-worker orchestration, p50 µs | Crystal | ClickHouse |
| --- | ---: | ---: |
| Outside the worker envelope | 21.8 | 35.8 |
| Last finisher's start delay relative to first start | 13.3 | 11.4 |
| Caller launch | 28.2 | 29.4 |
| Caller join, including waiting | 614.6 | 461.4 |

The two copy paths have different byte volumes. The native `readBig` loop
decoded 480 of the 512 frames directly into the typed columns, totaling
1,966,080 bytes. The remaining 131,072 bytes were copied from decoded buffers.
Crystal copied the full 2,097,152 decoded bytes into typed scratch. Both
harnesses copied the same 2,097,152 bytes into their ordered outputs.

Crystal mapped both column files per worker. The total mapped length was
1,386,725 bytes with one worker and 5,546,900 bytes with four. ClickHouse
returned 1,387,541 and 1,922,841 bytes from its `pread` calls, respectively.
The four-worker sum of lifecycle timers had a median of 288.1 µs in Crystal
and 80.5 µs in ClickHouse. Descriptor ownership can pass between ClickHouse
workers, so opens and closes balance across the scan even when individual
worker counts differ. The native probe observed four opens and four closes
in every one-worker sample and four to six of each with four workers. The
native descriptor stat hooks were idle on this fixture.

The reversed order reproduced the LZ4 and checksum gaps. At one worker the
paired profile-to-control scan ratios were 1.024–1.027 for Crystal and
1.031–1.037 for ClickHouse. With four workers the Crystal profile scan p50
was 0.673–0.682 ms and the control was 0.742–0.788 ms. The four-worker paired
ratios were 0.958–0.984 in Crystal and 1.009–1.032 in ClickHouse. Use the
instrumented results for stage attribution and the control results for total
latency and scaling.

All 768 recorded scans across the two campaigns matched the ordered oracle.
Both profile arms checked and decoded exactly 512 physical frames per scan,
with 128 per worker in the four-worker track. All first-frame checksum
controls passed. In a separate gapped scan, each runner gave the exact
selected rows when corrupt mark 13 was excluded, then rejected its checksum
when the mark was assigned to worker four. All four rejected a wrong output
oracle. The default Release parallel-scan specs passed 11 examples. The
Release LZ4 and mmap specs built with the profile flag passed 23 examples.

| Evidence | SHA-256 |
| --- | --- |
| Wide part file manifest | `2e55e9cbe502047752b136e25b707f68d72f183e365f0d7052a6278ce0bafc45` |
| Full-mark column-major oracle | `24c35659e776fe4a17d8686e55e5365348b0987f172fd657990216cef48b8b89` |
| Crystal control | `42254b66d7bdf7c9dc905203acced4586982746378f8c65d47b3d76de99e6950` |
| Crystal profile | `2a1d865f444fab47197d16aa1a4a6c3ac5dd1a026d140f29086e10289c2cbb5c` |
| ClickHouse control | `b0afd28ac3d810f1e7c5a43e070f85e47403f8da48de645d41951c33a97497bd` |
| ClickHouse profile | `e703fea5dc1de7dacebf90f717ec0cc47ad1903fa9f6b4c631fabc47e9eb1026` |
| Stage profile report | `d49c5642f41bf3b5801317fe5ff0af45ed42e81792decba6411c5d0f1588b66a` |
| Reversed-order report | `64082fbc3e32073aafdfe23dc87cf4a3e633b774a35d65058219d5953794d9fe` |

### Wide LZ4 padded copies

Checked reads of ordinary Wide `UInt64` streams use eight-byte copies for
short LZ4 literals and matches. Each stream's reusable decode workspace
reserves seven bytes past the logical frame end. A literal load requires
eight bytes inside the exact compressed frame. A match load requires a
distance of at least eight, so its source is initialized and disjoint from
the store. Long runs and short-distance matches use the bounded copy helpers.
Wide verifies CityHash128 before decoding and exposes the declared number of
decoded bytes to the mark reader.

An instrumented Crystal A/B used the same 512 physical LZ4 frames in every
sample, with 128 frames per worker in the four-worker track. Each track used
six warmup rounds and 24 alternating measured rounds. Median LZ4 time
summed across workers fell from 1.164 to 0.954 ms with one worker and from
1.263 to 1.029 ms with four. These sums measure decoder work across the group.

The uninstrumented comparison uses the same Wide MRK2 part as the stage
profile above. It reads two `UInt64` columns over 16 marks of 8,192 rows with
warm file pages. The Release runners are Crystal baseline `35849f1`, Crystal
with padded copies, and ClickHouse `readRows` at
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`. Per worker count, each of the six
runner orders occurs once during the six warmup rounds and eight times during
the 48 measured rounds. The second run reverses the order of the worker-count
tracks. All runs used an Apple M2 Max and the external APFS SSD. Crystal
1.22.3 and the native compiler both used LLVM 23.1.5. The native runner
retains the storage context and uses synchronous `pread` with jemalloc
disabled. Total time adds each sample's preparation and scan intervals.
Times are in milliseconds.

| Worker order | Workers | Runner | Prepare p50 | Scan p50 / p95 | Total p50 / p95 |
| --- | ---: | --- | ---: | ---: | ---: |
| 1 → 4 | 1 | Crystal baseline | 0.2398 | 1.7409 / 2.1593 | 1.9832 / 2.4512 |
| 1 → 4 | 1 | Crystal padded | 0.2438 | 1.4912 / 1.8001 | 1.7547 / 2.0818 |
| 1 → 4 | 1 | ClickHouse `readRows` | 0.0094 | 0.9957 / 1.1332 | 1.0039 / 1.1451 |
| 1 → 4 | 4 | Crystal baseline | 0.2343 | 0.7727 / 0.9091 | 0.9854 / 1.1565 |
| 1 → 4 | 4 | Crystal padded | 0.2323 | 0.5822 / 0.8418 | 0.9486 / 1.0884 |
| 1 → 4 | 4 | ClickHouse `readRows` | 0.0173 | 0.4643 / 0.5277 | 0.4837 / 0.5499 |
| 4 → 1 | 4 | Crystal baseline | 0.2439 | 0.7448 / 0.9408 | 1.0000 / 1.2083 |
| 4 → 1 | 4 | Crystal padded | 0.2431 | 0.7452 / 0.8817 | 0.9645 / 1.1611 |
| 4 → 1 | 4 | ClickHouse `readRows` | 0.0177 | 0.4621 / 0.5398 | 0.4818 / 0.5611 |
| 4 → 1 | 1 | Crystal baseline | 0.2203 | 1.6889 / 1.9524 | 1.9162 / 2.2265 |
| 4 → 1 | 1 | Crystal padded | 0.2277 | 1.4509 / 1.7746 | 1.6765 / 2.0033 |
| 4 → 1 | 1 | ClickHouse `readRows` | 0.0091 | 0.9521 / 1.0675 | 0.9634 / 1.0783 |

The one-worker scan p50 fell by 14.1–14.3% across the two runs. The
four-worker scan p50 fell by 24.7% in the first run and was nearly equal in
the reversed run. Its p95 fell by 6.3–7.4% and its preparation-plus-scan
p50 fell by 3.6–3.7% across both runs. The median of paired baseline-to-padded
scan ratios was 1.17× in both one-worker tracks and 1.09–1.14× in the
four-worker tracks.

From one to four workers, padded Crystal scan p50 improved 2.56× in the
first run and 1.95× in the reversed run. ClickHouse improved 2.14× and
2.06×. Padded Crystal took 1.50–1.52× the ClickHouse scan p50 at one worker
and 1.25–1.61× at four. With preparation included, the ratios were
1.74–1.75× and 1.96–2.00×.

All 576 timed scans matched the exact ordered oracle, with identical mark
assignments and unchanged part files. The first-frame corruption controls
passed. All three runners returned the expected gapped scan with corrupt
mark 13 excluded, rejected the scan with that mark on worker four, and
rejected an incorrect output oracle. A malformed LZ4 match was rejected
before decompression with a stale checksum and during decompression after
the checksum was recomputed. The focused Release specs passed 83 examples.
The padded decoder also matched `liblz4` on 4,096 independently compressed
blocks with guard pages bounding the exact input and the padded output.

| Evidence | SHA-256 |
| --- | --- |
| Wide part file manifest | `2e55e9cbe502047752b136e25b707f68d72f183e365f0d7052a6278ce0bafc45` |
| Full-mark column-major oracle | `24c35659e776fe4a17d8686e55e5365348b0987f172fd657990216cef48b8b89` |
| Crystal baseline | `6c680afb67c431504703cd0461f3a94d3bf6641e6a69a39b56afa789d6d61d74` |
| Crystal padded | `ba43ef869ea23b9790b6b28f7d113181b493fc32e33b66aaa93abd72b0602a00` |
| ClickHouse `readRows` | `bdb72a790a8c196569f8c968d4309d9b68b97ce4e003ec7cb740be0097c522ac` |
| 1 → 4 report | `2861c4a226168b81c3cdec330443cf598445ccf98adb5ed59288ee4ecd8acdf2` |
| 4 → 1 report | `d7dcb559166dfae5e408285d4ce4fd294f0b5f5bd75bf9d295f844c38885c2bc` |
| Crystal LZ4 profile report | `7fb239626af96e1e64b43b26820c28f499a317d3a14a3a7d187beb445204e0c9` |

### Wide shared data mappings

The direct Wide `UInt64` runner opens both column files once per scan.
Each worker borrows the same read-only views and checks its selected
compressed frames with private decode storage. The scan interval includes
both opening the mappings and closing them after workers finish.

The comparison uses the same pinned ClickHouse `readRows` build
configuration, Wide MRK2 fixture, and 16 positive marks as the padded-copy
comparison. The Crystal baseline is `2a12eb1`, which already includes
the padded LZ4 decoder. The three uninstrumented Release runners each
read 131,072 rows from the same two `UInt64` streams, with the same
ordered output and checksum checks. The driver uses six warmup and 48
measured rounds per worker count. It balances all six runner orders and
reverses the order of the worker counts in a second run. To reproduce,
pass the baseline binary with `--crystal-baseline-bin` and select
`--layout wide --warmups 6 --repeats 48`.

The runs used warm file pages on an Apple M2 Max and external APFS SSD.
Crystal 1.22.3 and the native Release build used LLVM 23.1.5. ClickHouse
retains the storage context constructed before the timing loop and reads
with synchronous `pread`. Crystal preparation includes opening the
selected readers and parsing their marks. Total time adds each sample's
preparation and scan intervals. Times are in milliseconds.

| Worker order | Workers | Runner | Prepare p50 | Scan p50 / p95 | Total p50 / p95 |
| --- | ---: | --- | ---: | ---: | ---: |
| 1 → 4 | 1 | Crystal baseline | 0.2186 | 1.3989 / 1.6842 | 1.6311 / 1.9077 |
| 1 → 4 | 1 | Crystal shared mmap | 0.2229 | 1.3615 / 1.6007 | 1.6059 / 1.9042 |
| 1 → 4 | 1 | ClickHouse `readRows` | 0.0064 | 0.9165 / 1.0528 | 0.9226 / 1.0676 |
| 1 → 4 | 4 | Crystal baseline | 0.2261 | 0.7048 / 0.8323 | 0.9367 / 1.0748 |
| 1 → 4 | 4 | Crystal shared mmap | 0.2301 | 0.6381 / 0.7873 | 0.8548 / 1.0330 |
| 1 → 4 | 4 | ClickHouse `readRows` | 0.0159 | 0.4379 / 0.4814 | 0.4554 / 0.4988 |
| 4 → 1 | 4 | Crystal baseline | 0.2200 | 0.7065 / 0.8209 | 0.9265 / 1.0423 |
| 4 → 1 | 4 | Crystal shared mmap | 0.2189 | 0.6743 / 0.7781 | 0.8916 / 1.0000 |
| 4 → 1 | 4 | ClickHouse `readRows` | 0.0160 | 0.4357 / 0.5069 | 0.4526 / 0.5266 |
| 4 → 1 | 1 | Crystal baseline | 0.2187 | 1.4220 / 1.7533 | 1.6515 / 1.9955 |
| 4 → 1 | 1 | Crystal shared mmap | 0.2217 | 1.4407 / 1.7295 | 1.6687 / 1.9531 |
| 4 → 1 | 1 | ClickHouse `readRows` | 0.0083 | 0.9409 / 1.0985 | 0.9502 / 1.1050 |

With four workers, scan p50 fell by 4.6–9.5%, scan p95 by 5.2–5.4%,
and total p50 by 3.8–8.8%. Median paired baseline-to-candidate ratios
were 1.056× and 1.080×. With one worker the paired ratios were 0.998×
and 1.004×. The one-to-four worker scan speedup was 2.13–2.14× with shared
mmap and 2.09–2.16× with `readRows`. Crystal scan p50 was 1.49–1.53× the
native time with one worker and 1.46–1.55× with four workers. Including
preparation, those ratios were 1.74–1.76× and 1.88–1.97×.

The separate profiles counted pairs of mappings and unmaps below. Each
candidate scan mapped 1,386,725 bytes in total. All recorded checksum and
LZ4 counts agreed with the independently counted physical frame geometry.

| Selected marks | Workers | Baseline mmap pairs | Shared mmap pairs | Checksum and LZ4 calls each |
| --- | ---: | ---: | ---: | ---: |
| 16 consecutive marks | 1 | 2 | 2 | 512 |
| 16 consecutive marks | 4 | 8 | 2 | 512 |
| 8 gapped marks | 1 | 14 | 2 | 256 |
| 8 gapped marks | 4 | 16 | 2 | 256 |

All 576 timed scans matched the exact ordered oracle. Part manifests
matched before and after both campaigns, and every first-frame corruption
control failed with a data checksum error. In a separate gapped scan,
each runner returned the selected rows while excluding corrupt mark 13,
then reported a checksum error when that mark was assigned to worker four.
All three rejected a one-byte change to the output oracle.

The focused Wide, Compact, mmap, and LZ4 specs passed 81 examples. They
cover scan-owned lifetimes, callback cancellation and exceptions, and
partial mapping setup failure. The parallel mapping specs passed
13 examples with `-Dwithout_mt`. The Wide metadata admission specs
passed five examples, including a mixed primitive numeric selection.

| Evidence | SHA-256 |
| --- | --- |
| Wide part file manifest | `2e55e9cbe502047752b136e25b707f68d72f183e365f0d7052a6278ce0bafc45` |
| Full-mark column-major oracle | `24c35659e776fe4a17d8686e55e5365348b0987f172fd657990216cef48b8b89` |
| Crystal baseline | `101b223562679b6f517b8840373e99f219cc61c563a2abe21807e34fa19ffd95` |
| Crystal shared mmap | `e147d61348ecd90784a12c2aa828984a504994d2275205eba4bdff19d33ea3e2` |
| ClickHouse `readRows` | `e225dcf04ef451b064bff9f6b24eafa050eb28021bc6f7748f6f26d6c3b30ab9` |
| Crystal baseline profile | `8e000ca3b699c61658d3614df3fac58fe4e6b30f1d917756ed8aeb990452c9a4` |
| Crystal shared mmap profile | `fa0024f97e5c553a96db957613cd2f7d9bc173e6ac0014ced0b4f02800b4ec9b` |
| 1 → 4 report | `00888a9eae3bbe6d44c4b339c61e13599628c9cba7f81a0fdd126c4ca0a898ee` |
| 4 → 1 report | `2e0f9671c354b2310132cf4f6b0bac8eba2e533235da646a341d40dc3d7579cb` |

### Retaining Wide metadata across scans

Crystal `8d67d01` keeps the same validated Wide column readers for all
`scan` commands in one process. Reader admission parses part metadata and
the two selected `.mrk2` indexes and validates their row grid before
`READY`. Each scan maps the two data files, checks the compressed frames,
and materializes the selected rows with its own worker state.

Compare a Release build from `8d67d01` with `d2ff8c4`, which already shares
data mappings within one scan and admits the columns again for each scan
after its startup validation. Pass `d2ff8c4` with
`--crystal-baseline-bin` and use `--layout wide --require-admission --warmups 6
--repeats 48`. Set `--workers 4 --workers 1` for the reversed worker order.
The driver verifies consistent one-time
admission and zero per-scan reader preparation for the retained runner.
The ClickHouse runner loads the storage context before `READY`, prepares
fresh worker cursors for each scan, and uses synchronous `pread` with
the reader mark cache disabled. Each scan time includes checksum checks
and materialization in order, with bytewise oracle validation after the
timer stops.

The comparison on an Apple M2 Max used the same Wide MRK2 part file
manifest and oracle as the shared-mapping comparison. It read marks 0–15
and 131,072 rows of `pk` and `value`, both `UInt64`, on warm OS file pages.
The uninstrumented Release binaries used Crystal 1.22.3 and ClickHouse
`d9bcb5ab` with LLVM 23.1.5. Each worker order used six warmups and 48
measured rounds per worker count, balanced across all six runner orders.
The table pools the two worker orders, giving 96 samples per runner and
worker count. Times are in milliseconds. Each total adds that sample's
preparation and scan intervals.

| Workers | Runner | Prepare p50 / p95 | Scan p50 / p95 | Prepare + scan p50 / p95 |
| ---: | --- | ---: | ---: | ---: |
| 1 | Crystal `d2ff8c4` | 0.2291 / 0.2843 | 1.4948 / 1.7849 | 1.7409 / 2.0383 |
| 1 | Crystal retained | 0.0000 / 0.0000 | 1.4982 / 1.7398 | 1.4982 / 1.7398 |
| 1 | ClickHouse `readRows` | 0.0070 / 0.0139 | 0.9736 / 1.0478 | 0.9821 / 1.0590 |
| 4 | Crystal `d2ff8c4` | 0.2416 / 0.2843 | 0.6731 / 0.7988 | 0.9010 / 1.0678 |
| 4 | Crystal retained | 0.0000 / 0.0000 | 0.6620 / 0.7897 | 0.6620 / 0.7897 |
| 4 | ClickHouse `readRows` | 0.0172 / 0.0238 | 0.4316 / 0.4970 | 0.4491 / 0.5176 |

One-time Crystal admission took 0.3763–0.4084 ms across four fresh
processes. The driver verified the same reported duration in all 54
responses from each process. The pooled repeated preparation-plus-scan
p50 fell by 13.9% with one worker and 26.5% with four. Scan-only p50
varied between worker orders and remained within 2% of the pooled
Crystal baseline at both worker counts. Crystal scan p50 was 1.54× and
1.53× native for one and four workers, respectively. Increasing the
worker count cut scan p50 by a factor of 2.26 in both runners.

All 576 timed scans matched the oracle and observed the assigned mark
ranges. The part file manifest was unchanged after each campaign. All
first-frame checksum controls failed as expected. On disposable copies,
removing the `.mrk2` files after a successful scan left later retained
scans bytewise correct. The baseline failed to reopen the indexes. The
retained runner rejected a truncated index during admission. All three
runners detected a checksum change at mark 13 between scans when reading
that mark with one and four workers. Scans excluding the corrupted mark
still matched their oracle, and all three runners rejected a modified oracle.

The retained `TypedPartTable` regression checks W1/W4/W1 sequential scans
against the expected row batch coordinates and values. The Wide admission
spec passed five examples in Release mode and five with `-Dwithout_mt`.
In separate instrumented runs, two successive scans each with one and four
workers opened and closed two mappings per scan and checked 512 frame
checksums. The Compact direct runner returned exact results on two calls
and reported per-scan preparation on both.

| Evidence | SHA-256 |
| --- | --- |
| Wide part file manifest | `2e55e9cbe502047752b136e25b707f68d72f183e365f0d7052a6278ce0bafc45` |
| Full-mark column-major oracle | `24c35659e776fe4a17d8686e55e5365348b0987f172fd657990216cef48b8b89` |
| Crystal baseline | `efe909d10f27df5ed323b39f973590eff23884b63b00ab48188c43e033b91a0c` |
| Crystal retained | `8e01826fa848d24bafc9809fffd50d89a8c08226d9f21cd659cdbd8b872ba59e` |
| ClickHouse `readRows` | `7b418b6b770f72ba9b5ab593a33855de2b2f2ebd46058245b0d96bab7424eac8` |
| Benchmark driver | `1f34446b669d2d9134e2861fbcd69d1e8386e4d2b58d2146ec538fe6f2b8d3b7` |
| 1 → 4 report | `921870e4c994cb38d899f1c832251f2d0e9ef4e769b1cee14e23ecce134ce776` |
| 4 → 1 report | `8972d936197931a9c744508f7411dbd38a9e661498014c268968b7e9b57a242f` |

### Retaining Wide data mappings across scans

Baseline `8d67d01` already retains the admitted Wide metadata and marks.
A retained data image belongs to one runner session over the same immutable
part, with one mapping per selected file. Workers borrow its bytes during
each scan and keep their decode state private. The image closes after the
last worker joins on shutdown or error. The existing table facade scopes
ordinary parallel scans to their own mappings.

The retained image uses `PROT_READ | MAP_SHARED`. In the macOS APFS test,
a resident `MAP_PRIVATE` view continued to return the original checksum
byte after a same-inode write and `fsync`. The read-only shared view returned
the updated byte. The session assumes the part files keep their lengths
and identities. The corruption probe writes a single checksum byte to
the same inode and preserves the file length.

Time metadata admission and image opening separately from scan latency.
Compare uninstrumented Release binaries against the pinned native
`readRows` runner on the unchanged 16-mark Wide part. A secondary control
opens and closes `MAP_SHARED` views on every scan to isolate the effect of
lifetime from the mapping flags. Both worker orders must preserve exact
mark coverage, bytewise output, and checksum errors. Repeated scans must
avoid new mappings and recheck all selected frames. Reverting the runner
change restores scan-owned mappings.

Run the direct benchmark command above with the `8d67d01` Release baseline
and the retained-mapping Release candidate. Add `--crystal-baseline-bin`,
`--layout wide --require-retained-mmap --warmups 6 --repeats 48`, and run
both `--workers 1 --workers 4` and `--workers 4 --workers 1`. For the
same-flag control, rebuild `8d67d01` with `MAP_SHARED` in the offset-zero
`mmap` call in `MMapDataSource.open_mapped_file`. That build still maps and
unmaps both streams per scan.

The Apple M2 Max comparison used Crystal 1.22.3 and uninstrumented
ClickHouse `d9bcb5ab` built with LLVM 23.1.5. Each arm read the same
warm-cache Wide MRK2 part, marks 0–15 with 8,192 rows per mark, and both
`UInt64` columns. All six runner orders were balanced in each track. Each
row of the table pools 96 timings across the two worker orders. Times are
milliseconds. Total is computed by adding preparation and scan per sample.

| Workers | Runner | Prepare p50 / p95 | Scan p50 / p95 | Total p50 / p95 |
| ---: | --- | ---: | ---: | ---: |
| 1 | Crystal `8d67d01` | 0.0000 / 0.0000 | 1.5733 / 1.8039 | 1.5733 / 1.8039 |
| 1 | Crystal retained mmap | 0.0000 / 0.0000 | 1.4267 / 1.6538 | 1.4267 / 1.6538 |
| 1 | ClickHouse `readRows` | 0.0086 / 0.0166 | 1.0154 / 1.1098 | 1.0238 / 1.1251 |
| 4 | Crystal `8d67d01` | 0.0000 / 0.0000 | 0.6891 / 0.8733 | 0.6891 / 0.8733 |
| 4 | Crystal retained mmap | 0.0000 / 0.0000 | 0.5130 / 0.7419 | 0.5130 / 0.7419 |
| 4 | ClickHouse `readRows` | 0.0174 / 0.0241 | 0.4589 / 0.5092 | 0.4763 / 0.5300 |

One-time metadata admission took 0.360–0.453 ms and opening both mappings
took 0.032–0.055 ms across the candidate's four primary processes. Opening
the mappings leaves page faults to the first reads. The baseline maps and
unmaps inside the scan timer. Candidate unmapping happens after the scan
sequence. The native storage context is loaded before `READY`. Its per-scan
preparation measures cursor creation. The scan includes releasing the
reader cursors before the oracle check.

Retaining mappings lowered scan p50 by 9.3% at one worker and 25.6% at
four. The same-flag control lowered p50 by 7.6% and 14.7%, respectively.
Across the four campaigns, the candidate-to-native scan p50 ratio ranged
from 1.40× to 1.43× at one worker and from 1.09× to 1.21× at four. In the
primary pooled comparison, going from one to four workers sped up the
median scan by 2.28× for the baseline, 2.78× for the candidate, and
2.21× for `readRows`.

All 1,152 timed scans passed the exact row oracle and mark partition checks.
Every first-frame corruption control reported a checksum error. Both
Crystal arms and `readRows` detected an in-place checksum change at mark
13 between gapped scans at one and four workers. Each returned exact rows
when the selected marks excluded the damaged frame and rejected a modified
output oracle. The retained Crystal runner could read its admitted files
after both data paths were renamed on a disposable copy. `8d67d01` failed
when it tried to open those paths again. The original part manifest
remained unchanged throughout.

A diagnostic runner observed both mappings close on quit, EOF, invalid
command, startup failure, and checksum failure. An injected cleanup failure
left both the checksum and cleanup diagnostics available.

Separate profile runs used six warmup pairs and 12 measured pairs per
worker count. The median of the per-scan open and close interval sums was
90.8 µs at one worker and 74.3 µs at four for `8d67d01`. The candidate
opened two mappings covering 1,386,725 bytes at startup. Every measured
scan had zero mapping work and checked and decompressed all 512 selected
frames. The focused Wide and Compact mapping specs passed 10 examples in
Release mode and eight with `-Dwithout_mt`.

| Evidence | SHA-256 |
| --- | --- |
| Wide part file manifest | `2e55e9cbe502047752b136e25b707f68d72f183e365f0d7052a6278ce0bafc45` |
| Full-mark column-major oracle | `24c35659e776fe4a17d8686e55e5365348b0987f172fd657990216cef48b8b89` |
| Crystal `8d67d01` | `044c357c010fb26eff0bdc06b5c20acd9b0007fb1049ed7ae7e3b76b929d1cfb` |
| Crystal retained mmap | `9292f5d0434a8e1b7d28b133d84b21bdf9af877e90ea76a00c648b1e16d3210b` |
| Crystal scan-owned MAP_SHARED control | `3d67a4c76fa6e05ab5345cd15605cd9ea5613a02a5ef28156c77d17feb173503` |
| ClickHouse `readRows` | `0a8fa83318635e32c92178517fd4114ac0ac7887e9ecd279dc19fd5040415114` |
| Crystal `8d67d01` profile binary | `f161a958204821aed2686b04e5b84e545009779c64f17aa3ca043d261ef4956d` |
| Crystal retained mmap profile binary | `e62f18457178bb718b672a63555eab41359b17de52528e65489fb1e0da363790` |
| Benchmark driver | `47893c52529197be3afd002620dd76f0ca24313bc1d15f7e22d6e7642ac08959` |
| Primary 1 → 4 report | `9038082844e6452e9bbd07a890210a59c67ecc294e07414451fcd8370af35340` |
| Primary 4 → 1 report | `2c81a7cd5d32c2b2535ac1d22e49821e96c055b4dad0ea697489d60e78a966d2` |
| Same-flag 1 → 4 report | `ba5948fc90d3d6615b3dc3fa336f162df3cb1d42c00c7ade782ac9512e30f2e4` |
| Same-flag 4 → 1 report | `c685936e0830bf38a656733f5e2ba8274d5b748a227f5cb073c9590c85564c94` |

### Retaining Wide workers and scan buffers

The direct Wide runner admits one immutable part, fixed mark partitions,
and one output range per worker for the session. The one-worker path keeps
its scratch in the caller. The parallel path starts its workers before
`READY`. Each worker keeps its own typed scratch and decompression storage
across requests. It derives frame and mark positions again on every scan.
The caller verifies the complete ordered output after all workers finish.
Every scan checks the selected frame checksums again.

The runner accepts one scan at a time. A startup, scan, or protocol failure
ends the session. All started workers must stop and join before the runner
closes its data image. A failed scan must drain the dispatched work before
shutdown so that workers can finish reading their mappings. Reverting the
runner change restores fresh workers and scratch per scan.

Use the direct benchmark command above with the `7d339bd` Release baseline
and the retained-worker Release runner. Add `--crystal-baseline-bin`,
`--layout wide --require-retained-workers --warmups 6 --repeats 48`, and run
both `--workers 1 --workers 4` and `--workers 4 --workers 1`. Compare the
uninstrumented runs for p50 and p95. For a separate diagnostic run, use
`--warmups 1 --repeats 1` and replace the baseline option with
`--crystal-profile-bin` pointing to the retained runner built with
`-Dread_rows_profile`. The diagnostic checks direct scratch and decode
buffer addresses and capacities, worker counts, mapping counts, and
selected frame coverage on each repeated scan.

Measure worker setup before `READY`, alongside metadata admission and
mapping setup. Each of these three durations is measured once per process.
The scan timer includes dispatch and completion waiting for retained
Crystal workers. The native runner measures cursor creation separately on
every request. Its scan includes W4 thread launch and joins and reader resets.
Both runners verify the ordered output after their scan timer stops.

The Apple M2 Max run used Crystal 1.22.3 and ClickHouse `d9bcb5ab` with
LLVM 23.1.5. Each runner scanned the same warm-cache Wide MRK2 part at
marks 0–15. Each mark has 8,192 rows and two `UInt64` columns. Each
worker order used six warmups and 48 measured scans per runner and worker
count, balanced across the six possible runner orders. Each table row
pools 96 measurements. Times are in milliseconds. Total adds the
preparation and scan times within each sample before computing percentiles.

| Workers | Runner | Prepare p50 / p95 | Scan p50 / p95 | Total p50 / p95 |
| ---: | --- | ---: | ---: | ---: |
| 1 | Crystal `7d339bd` | 0.0000 / 0.0000 | 1.3994 / 1.6595 | 1.3994 / 1.6595 |
| 1 | Crystal retained workers | 0.0000 / 0.0000 | 1.3927 / 1.5800 | 1.3927 / 1.5800 |
| 1 | ClickHouse `readRows` | 0.0077 / 0.0127 | 0.9887 / 1.0755 | 0.9984 / 1.0848 |
| 4 | Crystal `7d339bd` | 0.0000 / 0.0000 | 0.5894 / 0.7673 | 0.5894 / 0.7673 |
| 4 | Crystal retained workers | 0.0000 / 0.0000 | 0.3949 / 0.6853 | 0.3949 / 0.6853 |
| 4 | ClickHouse `readRows` | 0.0172 / 0.0224 | 0.4572 / 0.5261 | 0.4741 / 0.5452 |

Retaining workers and scratch reduced Crystal's four-worker scan p50 by
33.0% and p95 by 10.7% relative to `7d339bd`. At four workers the candidate
scan p50 was 13.6% lower than the native runner's and p95 was 30.3% higher.
Both worker orders gave those directions. At one worker, retaining
scratch changed Crystal's scan p50 by less than 1%. Its scan p50 was
40.9% higher than the native runner's. Going from one to four workers sped
up the median scan by 3.53× for retained Crystal workers, 2.37× for the
Crystal baseline, and 2.16× for `readRows`.

The retained runner's one-time metadata admission took 0.369–0.437 ms and
mapping setup took 0.034–0.046 ms across all four candidate processes.
Preparing the inline worker took 4.7–5.3 µs. Starting the four workers
and allocating their typed scratch took 134.3–162.4 µs. Each worker range
has two process observations. The decoder backing buffer grows during the
first scan, which the latency campaign counts as a warmup.

| Workers | Crystal `7d339bd` start to `READY` | Crystal retained workers start to `READY` | ClickHouse `readRows` start to `READY` |
| ---: | ---: | ---: | ---: |
| 1 | 5.237–5.486 ms | 5.932–5.978 ms | 10.627–11.460 ms |
| 4 | 5.087–5.728 ms | 5.321–6.357 ms | 10.077–11.887 ms |

All 576 timed scans matched the ordered oracle and assigned marks. The
part manifest was unchanged and all first-frame checksum controls failed
as expected. The separate candidate profile verified 512 frame checksums
and 512 LZ4 decodes on each repeated scan, including 128 per worker in
the four-worker track. It observed two retained mappings and zero mapping
operations during the scans. Each worker kept a distinct scratch buffer of
8,192 `UInt64` values and a decode buffer of 4,103 bytes with the same
addresses across requests. The four contexts started once and remained
active throughout the profile session.

At both worker counts, all three runners rejected a same-inode checksum
mutation between two scans that selected mark 13. Gapped scans that omitted
mark 13 returned the exact selected rows before and after the same mutation.
All three runners rejected an oracle with one altered byte. The candidate's
Compact smoke scans at both worker counts returned all 131,072 rows and
reported per-scan preparation.

The focused worker spec checked thread and backing storage reuse and
blocked one worker while another failed to verify that the scan drains
every completion before raising. A separate diagnostic runner observed
all started contexts stop before closing the mappings on quit, EOF,
invalid commands, partial worker startup failure, and an in-session
checksum failure. An injected mmap cleanup failure preserved both error
diagnostics. The Release mapping, streaming, LZ4, and compressed block
specs passed 50 examples.

| Evidence | SHA-256 |
| --- | --- |
| Wide part file manifest | `2e55e9cbe502047752b136e25b707f68d72f183e365f0d7052a6278ce0bafc45` |
| Full-mark column-major oracle | `24c35659e776fe4a17d8686e55e5365348b0987f172fd657990216cef48b8b89` |
| Crystal `7d339bd` | `ed6b2aa0cdf5e06a0b80dcfeb178abcb687700e1f54d7c0664b8690cb0560d85` |
| Crystal retained workers | `f98a5246b5c2946e788cc170cc5799ae6ebd84193a1610a843170c0fcf34f617` |
| Crystal retained workers profile | `b2bf1a5ad14c1a9731d25740b4749af61b7639a93c987ec0b3ae80ab88f34f74` |
| ClickHouse `readRows` | `86f1823a7d2e051e9cce9608e9058dc60c7c366b0e5d629fcf045736680a47fa` |
| Benchmark driver | `e3ab11714f4327d22c39aecb1d5fdd08db56e49a41a283f84f0f1d72829d1b47` |
| 1 → 4 report | `9af0eff907bac129969663102eebbd2e6fae833065d6f8310f7e9f334a5798c9` |
| 4 → 1 report | `9ec61138281cf3eee81b8f058d151203598d6088f9ab95f32d73fe37aef9b25d` |
| Candidate profile report | `c39cbcda4d25c6d072b33ace15a55269db684376ca9d1492917b3509632add33` |
| Wide integrity probes and Compact smoke report | `8390ed783282e1f15f373de028dc17fff99e1de64e38be8fd55a8160375bc4c5` |

### Four-worker Wide scan tail

The retained-worker `8c79d1b` and ClickHouse `d9bcb5ab` Release runners
read the same warm-cache Wide MRK2 part described above. The 16 marks
were partitioned into four consecutive ranges of four marks. Each scan
verified 512 compressed LZ4 frames and materialized 131,072 rows of two
`UInt64` columns. The benchmark checked the complete ordered output after
the timer. Both runners rejected a modified frame checksum on a separate
copy, and the measured part manifest stayed unchanged.

Run the direct benchmark command with `--layout wide --workers 4
--require-retained-workers --warmups 12 --repeats 240` and the two plain
binaries. Two blocks alternated runner order and started with opposite
runners. The second block enumerated the benchmark driver's runner
permutations in reverse. Times below are in microseconds. The p95 is the
228th sorted sample in each block. Fresh native cursor preparation was
separate from the scan, with a median of 14.1–15.6 µs. Crystal retained
its metadata, mappings, and worker state for the entire session.

| First runner | Crystal scan p50 / p95 | ClickHouse scan p50 / p95 | Crystal p95 excess |
| --- | ---: | ---: | ---: |
| Crystal | 406.6 / 718.0 | 499.0 / 540.5 | 177.5 |
| ClickHouse | 396.8 / 659.0 | 461.1 / 497.8 | 161.2 |

Two additional blocks ran the same plain Crystal binary with normal
Boehm behavior and with `GC_DONT_GC=1` set at process startup. The
setting suppresses collection in Boehm 8.2.12. Each mode had a fresh
process with 12 warmups and 240 measured scans. The blocks reversed the
mode order. They used back-to-back requests to one reader at a time.
[Boehm startup setting](https://github.com/bdwgc/bdwgc/blob/v8.2.12/misc.c#L1048-L1054)

| First mode | Default scan p50 / p95 | Collection suppressed p50 / p95 | p95 drop |
| --- | ---: | ---: | ---: |
| Default | 382.5 / 645.2 | 396.4 / 423.2 | 222.0 |
| Suppressed | 383.4 / 671.7 | 394.0 / 424.6 | 247.0 |

Suppressing collection reduced p95 by 34–37% in these two blocks. Every
one of the 12 slowest default scans in each block had a zero-based request
index divisible by nine, counting warmups. This control changes the
process-wide heap lifecycle and ran at a different request cadence from
the two-engine comparison.

A three-arm control interleaved the same two Crystal modes and the plain
native runner. The suppressed arm set `GC_DONT_GC=1` in a wrapper before
executing the byte-identical Crystal binary. The six runner orders each
occurred 40 times after 12 warmups. Scan p50/p95 were 385.2/678.8 µs for
default Crystal, 398.6/427.4 µs for suppressed Crystal, and 434.0/477.0 µs
for native `readRows`. The intervention reduced Crystal p95 by 251.4 µs
in that block and put it 49.6 µs below the native p95. Collection suppression
was a bounded diagnostic run.

Two separate LZ4 profile blocks interleaved the Release and instrumented
binaries from both engines. Each of the 24 orders occurred five times in
the 120 measured rounds, after 24 warmups. Each profiled worker verified
and decoded exactly 128 frames. Stage values below are medians on the
last-finishing worker in each sample. The middle 10% and slowest 5% are
selected by outer scan time within each engine's profile. Each range gives
the two block medians in microseconds.

| Profiled stage | Middle 10% | Slowest 5% |
| --- | ---: | ---: |
| Crystal LZ4 | 260.6–261.6 | 263.7–265.8 |
| ClickHouse LZ4 | 176.5–177.5 | 177.8–178.6 |
| Crystal last worker body | 397.1–398.4 | 834.5–857.0 |

The median Crystal LZ4 stage was about 1.47× the native stage, with a
small rise in the slowest scans. Most of the increase in those scans
was in the remainder of the last worker's body. In the same slow-scan
bands, the median time from scan start to last-finishing worker start
was 9.4–10.6 µs in Crystal and 22.3–31.2 µs in ClickHouse. From that
worker's finish to the timer stop, it was 3.2–4.3 µs in Crystal and
19.6–20.2 µs in ClickHouse. The Crystal profile emitted a JSON trace
after each scan and added work between timed requests. The plain
Release timings above provide the comparison for latency percentiles.

A separate Crystal Release trace stored Boehm events and worker timestamps
in fixed native buffers outside the GC root set. It exported the buffers
after the session, and every recorded scan interval matched the regular
runner timer. A forced collection inside the scan produced a pause in
the trace. The control with collection disabled produced zero events. The
pause interval runs from `GC_EVENT_POST_STOP_WORLD` to
`GC_EVENT_PRE_START_WORLD`. The enclosing interval from
`GC_EVENT_PRE_STOP_WORLD` to `GC_EVENT_POST_START_WORLD` includes stopping
and resuming threads. [Boehm event boundaries](https://github.com/bdwgc/bdwgc/blob/v8.2.12/alloc.c)

Two trace blocks used 12 warmups and 240 measured scans per mode and
reversed mode order. In each block, 26 default scans overlapped a pause,
including all 12 slowest scans. Default p95 was 647.9 and 652.4 µs. With
collection disabled during each scan, p95 was 424.0 and 418.0 µs and no
scan overlapped a pause. The table gives the two block medians for the
last-finishing worker under default GC behavior, in microseconds.

| Trace interval | Middle 10% | Slowest 5% |
| --- | ---: | ---: |
| Scan start to worker start | 7.5–7.6 | 7.8–8.1 |
| Dispatch to worker start | 6.2–6.3 | 6.2–6.3 |
| Worker body, elapsed | 369.9–370.3 | 649.4–650.0 |
| Worker body, thread CPU | 368.1–369.4 | 388.6–395.9 |
| Worker finish to scan timer stop | 4.0–6.3 | 3.8 |
| Worker body overlapping a fully stopped world | 0 | 192.9–207.9 |

The enclosing stop/resume interval overlapped 226–237 µs of the last
worker's body in the slowest scans. It includes the fully stopped
interval above. Dispatch and completion delays stayed small at the tail.
LZ4 was slower throughout the Crystal profile, and the matched GC
intervention and worker trace identify collection as the main source of
the observed p95 gap. The measurements cover this warm-cache fixture on
one M2 Max under varying background load, with Crystal 1.22.3, Boehm
8.2.12, and a ClickHouse Release build with jemalloc disabled. Re-run the
paired controls after changes to runtime, worker count, part geometry, or
request cadence.

Two preliminary comparison blocks used the instrumented native binary
after a rebuild replaced the default output path. The first table uses
only the corrected blocks with the saved plain binary.

| Evidence | SHA-256 |
| --- | --- |
| Plain Crystal runner | `f2bf2d17975980776192e385ef2a035f03b84086686ea64b3754d1abc55d4454` |
| Plain native runner | `cee70910c484dc8aa0ae64879b04f3da28ba887c6ac3bbb96481bc16c45e6f8b` |
| Plain comparison, Crystal first | `2526fd3ad9a8dbd0cf9f2718467d5e950cd5e939f4c26e3f7dedbdf57761c34d` |
| Plain comparison, ClickHouse first | `6212c1aaa92cbb7d33c754fd78374357bd51426848b792e538319568132de6b3` |
| Plain Crystal GC control report | `f65e20b29c42b87e1db50fc5fedac1c00a2253894a79d104329b54123d9e9c89` |
| Interleaved three-arm report | `da770cc10c78f49ac15e74ea41ce813771b9d84104f305dd27f772d140df8b34` |
| LZ4 stage analysis | `8508744aedb35c6bc194691f5ce5f4d9d2ca3e565820bdd1f87289f4db7fb288` |
| Quiet trace runner | `686310ac93695bb581980351ac5fedfef95c5187a48297f2c3815df8675428a8` |
| Default quiet trace, first block | `0cdfd85482096cda39de035aad187db83592996b4ed20f27105cf7fd828c02e8` |
| Default quiet trace, second block | `0d5a3b761fec8b3e28155f06ae98b776d68a13f3ceafbd6ec43e0ea02bd243ea` |

### Wide frame-policy allocations

The direct Wide `UInt64` reader skips composite type classification when
checking empty-payload and frame codec policy. The shared decoder classifies
other column types once per range and applies their policy to every frame.
The frame loop uses the existing checksum policy and enforces codec,
alignment, and mark boundaries.

A standalone Release probe on `3e0be10` measured process allocation
counters after warmup across 20,000 calls per case using an existing
`UInt64` type string. The `Array(Map)` probe allocated about 368 bytes
per call, including temporary prefixes and a parsed type expression.
The `AggregateFunction(count)` probe allocated about 48 bytes per call
constructing codec limits. The checks ran on every frame of the direct
scalar scan, where both returned false. Together they account for about
208 KiB of allocations for 512 frames. The no-op control allocated zero
bytes over the same iteration count.

The comparison used the same Wide MRK2 part, all 16 data marks, four
workers assigned four consecutive marks each, and checksum verification
for all 512 LZ4 frames. Each scan returned 131,072 rows of two `UInt64`
columns. The driver compared all 2 MiB of ordered output with the
independent oracle after each scan. Both Crystal runners retained
metadata, mappings, worker threads, and scratch buffers for the session.
Native `readRows` was rebuilt from ClickHouse `d9bcb5ab` in Release mode
with jemalloc disabled. Its per-request preparation median was 17.2–19.3 µs
and stayed outside the scan timer. The native scan timer included launching
and joining its workers. The test ran with warm filesystem caches on the
same M2 Max and SSD, using Crystal 1.22.3 and Boehm 8.2.12.

Each block compared the plain Release binaries for Crystal `3e0be10`,
the change above, and native `readRows`. Boehm collection was enabled
for both Crystal runners. The driver used `--layout wide --workers 4
--require-retained-workers --warmups 12 --repeats 240`. A scratch copy
applied the retained-worker check to both Crystal arms and reversed
the permutation order for the reverse blocks. Each of the six runner
orders occurred 40 times. Two confirmation blocks followed the initial
pair because several slow rounds were shared across runners. All four
blocks are shown in chronological order. Times are in microseconds and
p95 is the 228th sorted sample in each block.

| Block | Crystal before p50 / p95 | Crystal after p50 / p95 | ClickHouse p50 / p95 |
| --- | ---: | ---: | ---: |
| Forward | 421.417 / 757.208 | 358.353 / 546.791 | 503.938 / 889.709 |
| Reverse | 409.438 / 674.875 | 351.708 / 386.042 | 489.313 / 582.375 |
| Confirmation, reverse | 417.271 / 705.833 | 355.459 / 474.375 | 503.229 / 694.500 |
| Confirmation, forward | 414.583 / 747.167 | 353.354 / 390.250 | 495.959 / 550.042 |

Paired p95 fell 28–48% from the Crystal baseline and was 29–39% below
native `readRows` on this part. The four blocks show the variation in
warm-cache tail latency on the shared host.

Separate Boehm traces reversed the Crystal runner order across two
blocks, again using 12 warmups and 240 measured scans per runner. The
mean allocation per scan divides the sum of process-wide
`GC.stats.total_bytes` deltas within measured scan intervals by 240.
Boehm synchronizes the underlying heap usage snapshot.
[Boehm heap usage counters](https://github.com/bdwgc/bdwgc/blob/v8.2.12/include/gc.h#L654-L702)

| First runner | Mean allocated bytes per scan, before / after | Scans overlapping a stopped-world interval, before / after |
| --- | ---: | ---: |
| Before | 218,827 / 1,386 | 26 / 0 |
| After | 218,876 / 1,383 | 26 / 0 |

The baseline pauses covered all 12 slowest scans in each trace. The
median overlap among paused scans was about 0.2 ms. The updated
runner recorded a startup collection and zero collections during the
measured requests in each trace. Collection stayed enabled throughout.
A separate forced-collection process verified that the trace captures
the interval from `GC_EVENT_POST_STOP_WORLD` to
`GC_EVENT_PRE_START_WORLD`. [Boehm event boundaries](https://github.com/bdwgc/bdwgc/blob/v8.2.12/alloc.c)
An isolated probe measured about 960 bytes across the eight stream-name
escapes made by each scan.

A separate profile confirmed 128 checksum verifications and decodes per
worker and stable mappings and scratch buffers across repeated scans.
All three plain runners rejected a mutated checksum when mark 13 was
selected and returned the exact rows when it was skipped. This included
an adjacent selected mark whose end offset is the corrupt frame's
header. The wrong-oracle control failed in each runner and the
measured part manifest stayed unchanged. The focused Release suites
passed 55 scan and transport, 31 reader and type, and 70 Wide type
and codec examples in three runs.

| Evidence | SHA-256 |
| --- | --- |
| Wide part file manifest | `2e55e9cbe502047752b136e25b707f68d72f183e365f0d7052a6278ce0bafc45` |
| Full-mark column-major oracle | `24c35659e776fe4a17d8686e55e5365348b0987f172fd657990216cef48b8b89` |
| Crystal `3e0be10` Release runner | `e469a22259bdf60245383ab6de4b5cc674821cc3d63f6c62bf51f519d3d2cbf5` |
| Updated Crystal Release runner | `fc91809cc128d06aac90ceef44b11edaddff6eca6987ced47c2035fedf1d365f` |
| Rebuilt native `readRows` Release runner | `fd433bd1882cdfe4b294d6031b8b361985e486886eed48f084bd76c3bee10962` |
| Benchmark driver | `4632292bc12e55523be591e2109cc540ba0aa3fe595a4fdd0f79179f81493bfc` |
| Forward report | `47ba86738bb568f49c6c24f13b5d563e77589d6e98207f3a85c80a593762d734` |
| Reverse report | `bc7003e4e5eff3eb35bfc8e67effcbe5535259bebe82ae6d285eacba3e08a6b2` |
| Confirmation reverse report | `36ac4aa2321552c4c082b3e7b2b1a163c02cb910acb70fc0e1064985149cf377` |
| Confirmation forward report | `f967f49f193270ea8e0ea51fd288b2e3ba81f302a3938d876b557585759cac09` |
| GC trace, baseline first block | `a9a6bef9298d84b06c01954136eb64f16ff23bcb0057773e09b17e8a6bbfc0ad` |
| GC trace, updated first block | `2ad66e3b9ca715408744819d48b3e04af912c8719e1af11ba239002aa3312baf` |
| GC trace, baseline second block | `1062e4ef4c2de8016e75066e22f237746b1ec786e8169e7769dc318d2e57b818` |
| GC trace, updated second block | `3c237d9ac276767d26c5f5351cf5c299b67ae33763a16ff63098ee512e1c8dd4` |
| GC trace, forced positive control | `1a8b11ad59973207c66c6a86458bf71e4a7c3ea170ee1b929bf8b2a07e0dbc57` |

### Wide steady-state scan allocations

The preceding 240-scan traces reported 1,383–1,386 Boehm-accounted
bytes per scan. On the `0a1fc08` baseline, the longer traces below
sampled Boehm's synchronized process counters at the scan boundaries
and interposed `GC_malloc`, `GC_malloc_atomic`, and `GC_realloc` to
attribute requested sizes to callers. The two counters measure allocator
accounting and requested payload sizes, respectively.
[Boehm profiling counters](https://github.com/bdwgc/bdwgc/blob/v8.2.12/include/gc.h#L779-L831)

| Scan allocation source | Requested bytes per scan | Change |
| --- | ---: | --- |
| Eight physical stream-name escapes | 772 | Use the stream name already resolved and validated at Wide reader admission. |
| Wide worker job closure | 104 | Construct the job once during worker preparation. |
| Four worker waits | About 96 | Use a one-job command slot and a stack record for the blocking wait. |

The final allocation comparison used two blocks of 24 warmups and 1,200
measured scans per arm, reversing the initial arm order in the second
block. The accepted diagnostic companion used `crystal build --release
--threads 1` and its DWARF reported `DW_AT_APPLE_optimized(true)`. An initial
companion built with `--debug` had disabled optimization and its trace
was discarded. The allocator probe and per-scan synchronized counters
were separate from the plain timing campaign.

| Block | Requested bytes per scan, baseline / updated | Boehm-accounted bytes per scan, baseline / updated | In-scan collections, baseline / updated |
| --- | ---: | ---: | ---: |
| Baseline first | 972.487 / 1.133 | 1,211.533 / 1.000 | 0 / 0 |
| Updated first | 972.847 / 1.167 | 1,205.573 / 2.200 | 0 / 0 |

The updated runner recorded zero `GC_malloc` and `GC_realloc` calls in
all 2,400 measured scan intervals. It recorded 34 and 35 atomic allocations
of 40 bytes, all symbolized to `Fiber::ExecutionContext::Monitor#run_loop`.
There were zero allocations in 1,166 and 1,165 of the 1,200 scan intervals,
respectively. Boehm's counters account for thread allocation buffers in
batches, so their per-interval deltas differ from the requested sizes.
GC was enabled at entry, READY, every scan boundary, and exit. The probe's
positive control requested 5,632 bytes and independently observed 6,032
Boehm-accounted bytes.

The command slot is used by the direct benchmark's isolated workers on
Darwin with Boehm and Crystal 1.22 or newer. The pool holds each worker's
scratch and decoder through join and retains the running job until every
dispatched completion is drained. The native wait passes only condition,
mutex, and status through the callback. A forced collection caught a
buffer address change in the initial native-wait variant with stack-local
worker state. The regression spec collects between jobs and verifies that
both buffer addresses survive.
[Boehm blocking callback contract](https://github.com/bdwgc/bdwgc/blob/v8.2.12/include/gc.h#L1485-L1501)

Release checks passed 69 reader and codec examples and three worker-pool
examples in both plain and profiled builds. A separate worker stress check
ran 800 jobs per pass with forced collections while workers waited and
while a job was active. It checked buffer identity and contents, error
drain, and reuse after failure.

The reader and worker-pool verification commands were

```sh
crystal spec --release --threads 1 \
  spec/wide_part_spec.cr spec/multicolumn_wide_part_spec.cr \
  spec/wide_part_schema_binding_w257_spec.cr \
  spec/wide_parallel_metadata_admission_spec.cr \
  spec/wide_parallel_scan_mapping_spec.cr \
  spec/wide_part_numeric_map_owner_spec.cr spec/compressed_block_spec.cr
crystal spec --release --threads 1 spec/read_rows_scan_worker_pool_spec.cr
crystal spec --release --threads 1 -Dread_rows_profile spec/read_rows_scan_worker_pool_spec.cr
```

All runners read the same regenerated Wide MRK2 part. The archived
source RowBinary and full-mark oracle hashes reproduced exactly. The
new physical file-set hash differs from the preceding campaign's hash.
ClickHouse 26.10.1.1201 generated the fixture and passed `CHECK TABLE`.
Each scan covered all 16 marks of 8,192 rows with four workers and
verified the checksums of 512 LZ4 frames. The runner compared 2 MiB
of ordered output byte for byte with the oracle after each scan.
All three runners rejected a corrupted frame checksum in selected mark
13, returned the exact rows when that mark was omitted, and rejected an
altered oracle.

Timing used plain Release builds on an Apple M2 Max with warm filesystem
caches. Both Crystal runners used Crystal 1.22.3 and Boehm 8.2.12 with
collection enabled. They retained admission metadata, mmap regions, and
worker contexts. Native ClickHouse `readRows` was built from `d9bcb5ab`
using Clang 23.1.5 with jemalloc disabled. It used `pread` and timed
starting and joining its four workers. Its per-request reader preparation
was measured separately from the scan. Crystal's one-time preparation
was reported before the measured scans.

The initial plain comparison used four fresh-process blocks in chronological
forward, reverse, forward, and reverse order. Each arm completed 24 warmups
and 1,200 measured scans per block. Each of the six runner permutations
occurred 200 times. A scratch driver required stable positive
`worker_prepare_ns` on both Crystal arms and reversed the permutation
schedule in alternating blocks. Times below are microseconds. Each p95 is
the 1,140th sorted sample within its block.

| Block | Crystal `0a1fc08` p50 / p95 | Updated Crystal p50 / p95 | ClickHouse p50 / p95 |
| --- | ---: | ---: | ---: |
| Forward | 361.438 / 1,161.417 | 361.125 / 1,191.333 | 496.729 / 1,358.541 |
| Reverse | 356.291 / 398.875 | 356.209 / 404.375 | 479.853 / 553.750 |
| Forward | 356.812 / 424.875 | 355.521 / 417.083 | 477.938 / 594.292 |
| Reverse | 360.584 / 615.333 | 359.021 / 623.083 | 494.416 / 887.792 |

The updated p95 varied from 1.83% lower to 2.58% higher than the Crystal
baseline and was 12.31–29.82% lower than native `readRows` in these blocks.
The measurements leave the p95 effect of removing the residual
allocations unresolved. The first block's p95 was elevated for all three
arms. Native per-request preparation p50 ranged from 15.25 to 16.29 µs.
Crystal's one-time reader, mapping, and worker preparation ranged from
0.597 to 0.768 ms in the updated runner.

The initial plain driver inherited its launch environment. A final
four-block confirmation started each driver with `env -u GC_DONT_GC`
and saved the explicit command. It used the same binaries, fixture,
scan boundaries, balanced runner orders, 24 warmups, and 1,200 measured
scans per arm. All checksum controls and per-scan oracles passed again.

| Confirmation block | Crystal `0a1fc08` p50 / p95 | Updated Crystal p50 / p95 | ClickHouse p50 / p95 |
| --- | ---: | ---: | ---: |
| Forward | 359.500 / 670.292 | 356.979 / 662.792 | 498.646 / 881.458 |
| Reverse | 358.833 / 683.333 | 358.812 / 687.333 | 491.042 / 887.959 |
| Forward | 358.250 / 536.584 | 355.166 / 544.292 | 490.250 / 769.458 |
| Reverse | 357.709 / 547.708 | 356.042 / 552.750 | 490.063 / 760.958 |

In this confirmation, updated p95 varied from 1.12% lower to 1.44% higher
than the Crystal baseline and was 22.59–29.26% lower than native
`readRows`. Native preparation p50 ranged from 15.58 to 16.29 µs.
Crystal's one-time preparation ranged from 0.561 to 0.667 ms.
Pooling the four confirmation blocks gives 4,800 measured scans per arm.
Pooled p50 / p95 were 358.500 / 603.208 µs for the Crystal baseline,
356.833 / 601.167 µs for updated Crystal, and 492.563 / 838.083 µs for
native `readRows`. The pooled p95 is the 4,560th sorted sample.

| Evidence | SHA-256 |
| --- | --- |
| Wide part file manifest | `ec6d0eaad8680ced27b2c3a8178902a37f1143332e4dba1902d339d79764f1dc` |
| Source RowBinary | `5103eb0b689c92f3ebe4c23ae58816b4d120b12d5a543c2e274a58a547a075b5` |
| Full-mark column-major oracle | `24c35659e776fe4a17d8686e55e5365348b0987f172fd657990216cef48b8b89` |
| Frozen `0a1fc08` Release runner | `fe7c1a8b9b3da11ed159bb139451263695bc760e62f099a631b8b6cb1b0ec1ca` |
| Updated Crystal Release runner | `e0c5fcc09cdc0fbd467a4f3011729cbbbc3253c21e0a2dea7f69e160883f2f47` |
| Native `readRows` Release runner | `2e2680b959d52b435fb2a77c7af571297447effc38b767f62f1897eca9d58749` |
| Native compiled Gitlink input audit | `adc78e12c215475c33f9bb66c20c24e693fdf755f68f98cd556667056b220219` |
| Scratch benchmark driver | `9536788882971e1564b053b5c5bb106b2bd0b554bbdbe6c20be4bf141ba6b766` |
| Forward report, first block | `91190a45304c8f8052df85763eb8a79b561e75ac7aefbdd9b141d7f68aea1b01` |
| Reverse report, second block | `e73fd82fe209cec22f7cc8129ea0259afa804ef65c84fea40e022c8b981f5bd8` |
| Forward report, third block | `bd0a87d6649f36da694981564c28aba7d0be57fc8f64e0f5497785a8a057d1d1` |
| Reverse report, fourth block | `bb563e4e6a6460b6310e925d263c8f43cbbde2affa078c3340282fd3b0a15501` |
| Optimized allocation diagnostic runner | `1e822ed05829496f1bf9aecb5ed04650bca2f33faa6544c64e4dbfa7a4450b58` |
| Optimized allocation comparison, two blocks | `19086a79fcf6a325dd51c599e1c9ba94b6c45a215d65806962a1204bc9323f30` |
| Explicit-environment confirmation commands | `34ad05669dc74d3166d9dfa7dd8b5cde0168b78abbeefa9e08c6dc4872db31a1` |
| Confirmation forward report, first block | `57d0ec2fe18d79f97b49f6483814a36124f0c4335357f8e47cfed3d273b378c6` |
| Confirmation reverse report, second block | `9c2cc2fdd62ef4c1adff1e8f98af72230744fc288173826b8669ee43e67265b9` |
| Confirmation forward report, third block | `f09a75392c8ad215146ea3bf754aa4394e72aae71ca505bcefdb2070c8f727d9` |
| Confirmation reverse report, fourth block | `0310a16e64783da4dc2afc60b328976612c52035f2d486fe2ff2fdbb41408ec0` |

### Public Wide UInt64 scan measurements

Each Crystal `--release` process opened one `TypedPartTable` and reused
it across calls to `scan_typed_parallel`. The baseline was `eda882a`.
The restored ClickHouse 26.10.1.1201 Wide part has the same file manifest
as the Wide mmap comparison and passed `CHECK TABLE`. It contains `pk`
and `value` as `UInt64`, with 131,072 rows in 16 marks of 8,192 rows each.

The timer covered the scan, including preflight, mappings, workers, and
copying the 32 ordered 4,096-row batches into a preallocated destination.
The initial table open and the byte-for-byte comparison against ClickHouse
RowBinary values ran outside the timer. Both versions reported
`SizeChecked`, returned the exact bytes and coordinates, and rejected a
size-preserving corruption of the adjacent LZ4 frame header.

The Apple M2 Max run used macOS 26.6.2, Crystal 1.22.3, and Boehm 8.2.12
with `GC_DONT_GC` unset. Each worker count and version had 24 warmups and
480 measured scans across four blocks with alternating pair order.
Latency uses nearest-rank percentiles from the plain builds. A separate
Release run measured `GC.stats.total_bytes` deltas after a known 1 MiB
allocation verified the counter in each process.

| Workers | Baseline p50 / p95 (ms) | Updated p50 / p95 (ms) | Baseline allocation p50 / p95 (bytes) | Updated allocation p50 / p95 (bytes) |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 3.441 / 3.744 | 1.684 / 1.934 | 10,574,272 / 10,583,808 | 267,760 / 274,704 |
| 4 | 2.073 / 2.618 | 0.930 / 1.236 | 10,587,024 / 10,602,592 | 684,640 / 696,640 |

Updated p95 was lower in all four blocks for each worker count. It fell
48.35% with one worker and 52.80% with four on this part. Median bytes
allocated per scan fell 97.47% and 93.53%, respectively.

`crystal spec spec/typed_part_table_parallel_scan_spec.cr` passed ten
examples. The `-Dwithout_mt` run passed nine. The checks cover writable
callback-scoped slices, nested scans and forced GC inside a callback,
callback failures followed by successful retries, and invalid adjacent
and final Wide frame headers. The Wide mapping and metadata-admission
specs passed twelve examples covering shared mappings, stable multi-part
coordinates, and mapping release after a stopped callback.
An `OfflineTable` probe matched serial values and coordinates for 17,001
rows with `workers: 1` and observed zero callbacks for an empty table.

| Evidence | SHA-256 |
| --- | --- |
| Wide part file manifest | `2e55e9cbe502047752b136e25b707f68d72f183e365f0d7052a6278ce0bafc45` |
| Full-mark column-major oracle | `24c35659e776fe4a17d8686e55e5365348b0987f172fd657990216cef48b8b89` |
| Shared public scan driver source | `915ba91130ca50614221743461e2ae1beba35282a1214b2fd0c20111f4dff480` |
| Plain run samples | `9c06270c3389511f6440fb2189dc3a220f236fd42df420cf5c2a673eea86ebfb` |
| Allocation run samples | `f4627aa2083d2deec87f565840ac0e436c8537ac878efaba0f14dac22c1843db` |

### Allocations in repeated public Wide UInt64 scans

The comparison starts at `9d0c47e` and uses the same ordinary Wide
`.mrk2` part as the preceding measurement. Two exact `UInt64` columns
cover 131,072 rows, 16 marks, and 512 LZ4 frames. The baseline allocated
about 3,809 bytes per generic numeric batch in an isolated construction
probe. Its generic batch maps and per-batch slice vectors were rebuilt
32 times per scan. Constructing 1,000 direct callback windows registered
zero Boehm bytes in the same isolation. A separate probe measured about
135,491 bytes per fresh worker workspace, including its typed lanes and
frame buffer.

The direct path now constructs a callback window over the current mark
and borrows an exclusive workspace. The idle pool holds at most four
512 KiB payloads. This fixture needs 135,184 payload bytes per slot, or
540,736 bytes after warming four workers. A nested or concurrent scan
uses fresh storage when it finds a busy slot. The limit applies to idle
buffer payload, with object headers and allocator rounding accounted for
separately.

The matched comparison used the same public API, batch size, SSD part,
and ClickHouse 26.10.1.1201 oracle. `CHECK TABLE` returned `1` before
timing. Each measured scan included preflight, mappings, worker startup,
and ordered copies into preallocated arrays. Every scan checked its 32
batch coordinates and compared all returned values with the native
RowBinary export. Table open and the value comparison ran outside the
timer. Both versions reported `SizeChecked` and rejected corruption of a
selected mark offset on a disposable copy.

The Apple M2 Max run used macOS 26.6.2, Crystal 1.22.3, and Boehm 8.2.12
with `GC_DONT_GC` unset. Each series used 24 interleaved warmups and
480 measured scans per arm, in four blocks of 120 with alternating
pair order. Nearest-rank latency percentiles come from plain Release
builds. Four-worker latency pools both series for 960 scans per arm with
opposite starting orders. A separate Release diagnostic series measured
`GC.stats.total_bytes` deltas after verifying the counter with a 1 MiB
positive control in each process.

| Workers | Baseline p50 / p95 (ms) | Updated p50 / p95 (ms) | Baseline allocation p50 / p95 (bytes) | Updated allocation p50 / p95 (bytes) |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 1.646 / 1.924 | 1.608 / 1.719 | 267,760 / 275,552 | 2,608 / 8,608 |
| 4 | 1.063 / 1.671 | 0.840 / 1.425 | 684,576 / 695,952 | 13,104 / 23,280 |

Median allocated bytes fell 99.0% with one worker and 98.1% with four.
The first scan in each diagnostic process paid for the workspace buffers.
Its allocations went from 268,192 to 138,096 bytes with one worker and
from 695,824 to 559,888 bytes with four. In that comparison, each parallel
call still created its worker contexts and channels.
Isolated probes measured approximately 11 KiB of Boehm allocation for
four context and channel pairs together.

On the host with background activity, p95 fell 10.7% with one worker,
with lower p95 in all four blocks. It fell 14.7% in the pooled
four-worker samples, with lower p95 in six of eight blocks. The other two
blocks had approximately 23% higher p95 after the change.

`crystal spec spec/typed_part_table_parallel_scan_spec.cr spec/wide_parallel_scan_mapping_spec.cr spec/wide_parallel_metadata_admission_spec.cr`
passed 24 examples. The same command with `-Dwithout_mt` passed 22.
These cover callback-scoped writable slices, same-worker-count nested
scans with forced GC, callback failure and `break`, the retained payload
limit, legacy batch construction, and failure before publishing a mark
with a malformed adjacent or final frame.

| Evidence | SHA-256 |
| --- | --- |
| Candidate changed-source manifest | `e7a2d78f261082e8413ee2794af6d9aa9fac9d230cac11cf6da868d5f3242c77` |
| Shared public scan driver source | `0e95d62d2a40f61dfa2936fa0c07d57f9aad607d6926ae3f4b6fff79a62d2283` |
| Paired runner source | `c50cb5a8b2d6d1fc93d25c18246025b6c8a92b5e9d3e2789b122327a45a642e2` |
| Plain run, one worker | `3e2aa1c1399370cf9e778c41deddada452071003f84281c219245091c5fb7254` |
| Plain run, four workers, first series | `a53a5447d843953c5d6438950021778e21cf711f2918e05d2de14aa7c8a1f754` |
| Plain run, four workers, second series | `dfa25bd312cded64c8b2011b960186c58d66c494f7151437cde97f7476664075` |
| Allocation run, one worker | `b7d6ed121f56f63de05d2b4f5b62187183e5b734b2e84be2568c3f31378e1325` |
| Allocation run, four workers | `62ad9774076238de26e399ed9a86adaca4478222ff7100ea56b28140a06f763c` |

### Worker reuse in repeated public Wide UInt64 scans

The baseline is `9b08b1e`. Both Release builds scan the same Wide
`.mrk2` part as above, with two `UInt64` columns, 131,072 rows, 16
marks, and 512 LZ4 frames. ClickHouse 26.10.1.1201 returned `1` from
`CHECK TABLE`. Both builds admitted the part as `SizeChecked` and
rejected the same size-preserving frame-header corruption after 14
successful batches at both worker counts.

The timer covers `scan_typed_parallel`, including per-scan admission,
mapping, worker setup or dispatch, and copying all 32 ordered
4,096-row batches into preallocated arrays. The runner opens the table
outside the timer and compares both columns against the complete
ClickHouse RowBinary oracle after every scan. The oracle comparison
rejects an intentionally changed value.

The Apple M2 Max host ran macOS 26.6.2, Crystal 1.22.3, LLVM 23.1.5,
and Boehm 8.2.12 with `GC_DONT_GC` unset. Each series has 24 interleaved
warmups and four 120-scan blocks per arm. Block order alternates. At
four workers, each metric pools both series with opposite starting
orders for 960 scans per arm. The one-worker control has 480 scans
per arm per metric. Latencies are nearest-rank percentiles from plain
Release builds. Separate Release builds measure `GC.stats.total_bytes`
deltas and verify the counter with a 1 MiB positive control in each
process.

| Workers | Baseline p50 / p95 (ms) | Updated p50 / p95 (ms) | Baseline allocation p50 / p95 (bytes) | Updated allocation p50 / p95 (bytes) |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 1.565 / 1.696 | 1.571 / 1.693 | 2,160 / 9,776 | 2,080 / 9,793 |
| 4 | 0.797 / 1.277 | 0.758 / 1.131 | 13,136 / 21,712 | 5,808 / 13,440 |

Four-worker median allocation fell 55.8% and p95 allocation fell 38.1%.
The pooled median latency fell 5.0% and p95 fell 11.4%. The two W4
latency series saw p95 move from 1.185 to 1.211 ms and from 1.287 to
1.059 ms, respectively, with an unrelated VM active on the host.
First-call latency rose from 0.909 to 1.148 ms in one series and from
1.151 to 1.298 ms in the other. Those first calls include lazy pool
startup and are separate from the warm samples.

`crystal spec spec/typed_part_table_parallel_scan_spec.cr spec/wide_parallel_scan_mapping_spec.cr spec/compact_parallel_scan_mapping_spec.cr spec/wide_parallel_metadata_admission_spec.cr`
passed 28 examples. The same suite with `-Dwithout_mt` passed 24.
The checks witness actual worker and channel identities across calls,
ordered batch coordinates, nested and concurrent scans, and recovery
after callback exit and decoder failure. An independent stress probe
completed 150 stop-and-retry cycles with worker counts one through five
and forced GC in 15 nested and concurrent cases. Injecting a stale job
tag during the final drain retired that slot and left the other
workers available for the next successful scan.

| Evidence | SHA-256 |
| --- | --- |
| Wide part file manifest | `2e55e9cbe502047752b136e25b707f68d72f183e365f0d7052a6278ce0bafc45` |
| Full-mark column-major oracle | `24c35659e776fe4a17d8686e55e5365348b0987f172fd657990216cef48b8b89` |
| Candidate source tree manifest | `b475266922ec6795007933d9275c463a382f09b800de1601a5ac24b3692e61de` |
| Shared public scan driver source | `620517a6bbff293e98e43aa8db06f257a874f72664d51b6d01932f53a5e8db57` |
| Paired runner source | `1fe46525e38951f2f39418789ae8c0f3fb036cb0c0e2f2d7db616e303df446a7` |
| Latency, one worker | `8a46b698919f319e19fc96f979acffb41d8d0e4058ea0cc174fea98ef51577c7` |
| Latency, four workers, first series | `230cc4ecc5eba5239feb94b089629429a9a47e1168619ce30852d4c5a3a1eb5c` |
| Latency, four workers, second series | `d77cc4475abec0d7239a1b5514acbff80e914cae69664f5ae3bcb83692af471d` |
| Allocation, one worker | `b0375677cb817e7c7dee3b82c291dab66ab8327016b29d97e1e8d7fa0933b91a` |
| Allocation, four workers, first series | `769c3890d052de26e90aecdcf81d803bf1b138eae9d90338c123e4bc7893961c` |
| Allocation, four workers, second series | `907c9571c23c54a4187553858dd6f8bbe3cf572e29c0e9f8a6f0c1a5a3ea9055` |

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

### Fixed-width frame copies and prepared readers

CityHash v1 reads little-endian 32- and 64-bit words from checked spans.
Fixed-width copies accept unaligned input and compile to native loads on
ARM64. LZ4 inlines length decoding and copies literals of one to four bytes
at their exact widths after checking both ranges. Three bytes use a two-byte
copy and a one-byte copy. The Release disassembly confirms the width of
those loads and stores. The frame checksum still runs before decoding into
the slab.

The mapping spec counted four `columns.txt` reads after admission for one
part scanned by four workers at `233783e`. With prepared reader reuse it
counts zero, one `data.bin` mapping, and zero additional frame-index builds.
The codec suites passed 21 examples in Debug and Release. The mapping and
parallel scan suites passed 11 examples in Debug and Release, and nine
with `-Dwithout_mt`. The affected codec, transport, Compact, Wide, and
catalog regression run passed 269 examples.

The three Crystal builds used `233783ec27b3930be7d01678a40eee6d4a93494e`
as the reference, adding the codec changes in `e0f72f9` for the second arm
and reader reuse for the third. All used Crystal 1.22.3, LLVM 23.1.5, and
Boehm with `--release -Dparallel_scan_bench` on the M2 Max. The pinned
ClickHouse 26.10.1.1201 binary read the same Compact MRK3 fixture with 131,072 rows,
16 marks, and 32 LZ4 frames across two `UInt64` columns. The fixture and
oracle hashes match the shared-scan profile above.

Each worker count used four warmups per arm and 48 timed rounds, with
each of the 24 arm orders appearing twice. The request timer and cache
and checksum settings followed the comparison contract. All 384 timed
responses matched the independent 48-byte oracle. The ordered 2 MiB
exports and ten part file hashes matched before and after both tracks.
`CHECK TABLE` passed and the native diagnostic observed one and four
threads reading rows at the respective settings.

| Workers | Reference, ms | Codec changes, ms | Codec changes and reader reuse, ms | ClickHouse, ms |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 3.704 ± 0.088 | 1.667 ± 0.070 | 1.672 ± 0.062 | 2.249 ± 0.142 |
| 4 | 2.197 ± 0.132 | 1.717 ± 0.151 | 1.017 ± 0.157 | 1.715 ± 0.113 |

Values are median ± MAD. The combined build took 45% and 46% of the
reference median at one and four workers, respectively. At four workers,
reader reuse saved a paired median of 0.819 ± 0.160 ms over the codec
build and won 46 of 48 pairs. At one worker, which uses the serial path,
the paired median difference was under 0.001 ms (24 wins in 48 pairs).
The combined build won all pairs against ClickHouse at both counts. These
results apply to warm reads of this part and this reduction.

| Evidence | SHA-256 |
| --- | --- |
| Reference Crystal HTTP worker | `971ca414b728e811b4c39ade95fd9e792ae9ff0c6bc273f9986b706e9e53382a` |
| Codec-only Crystal HTTP worker | `e33a1925fdde3f019c3b55f987cf1dc5cc74ff6f14769cf8d6afc920dcc60afc` |
| Combined Crystal HTTP worker | `918b23ab82bee8b41a98c84b6eec2dc7ce1533e65a121d18ad6a9701ae95367e` |

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
For the fixed-width comparison, use `233783e`, `e0f72f9`, and the revision
with prepared-reader reuse.
Build and prepare each as above. Shuffle two copies of all 24 permutations
of `("clickhouse", "combined", "kernels_only", "stock")` with the same seed.
Run four warmups per arm and verify ordered exports before and after each
worker-count track.

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
  map each accessed `data.bin` exactly once. Its workers must reuse the
  admitted column metadata. Aborting at an earlier part must close a later
  part's mapping even if an assigned worker never acquired it.
- An admitted parallel Wide scan must map each selected data file once per
  touched part, including when workers read disjoint mark ranges. A failed
  mapping open, a worker error, or a stopped callback must release every
  mapping opened by that scan.
- An admitted Wide `UInt64` scan must validate the complete mark range for
  every selected stream before exposing its first batch. A malformed frame
  visited at the mark boundary must fail before that callback, including
  when the first selected column has already decoded successfully.
- A nested Wide `UInt64` scan of the same table with the same worker count
  must leave the enclosing callback's slices writable and intact. Batch
  coordinates and column metadata must still identify the original batch
  after later callbacks and subsequent scans.
- The checked direct Wide runner must reuse the admitted columns, mark
  indexes, and data image, then close the image when the runner exits. Each
  scan must return the same selected rows and detect a data-frame checksum
  error introduced between scans on a disposable test part.
- Splitting Compact marks between workers must keep a cumulative per-part
  transport limit. For the shared `UInt64` path, file and header work is
  charged per mapping and selected range work accumulates across workers.
- The benchmark must reject an incorrect aggregate and changed part bytes.
  Worker probes confirm the Crystal execution contexts and record the number
  of ClickHouse threads that read rows at each `max_threads` setting.

Revert the parallel scan change to remove the opt-in path. Keep the sequential
reference timings as evidence for their pinned revision and runtime.
