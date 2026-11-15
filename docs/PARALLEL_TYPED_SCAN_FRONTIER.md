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
allowances apply across the complete worker group. Reopening the part per
worker consumes some of that budget before decoding starts.
Operation exit waits for the workers after normal completion, early exit,
and decoder or callback failures. Keep selected part files stable for the
lifetime of the reader and use a separate reader for each concurrent scan.

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

The Compact `data.bin` was 5,303,170 bytes. On this path, each selected
column's mark read charges that entire file size against the cumulative
256 MiB transport budget. A 16-mark fixture of the same size reached
`Compact typed carriers exceed aggregate materialization limit` at 32,768
rows per mark. The four-worker reader with a shared budget also rejects the
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
terminal mark. The benchmark used LZ4 with a 4 KiB maximum compressed block
size. Wide used MRK2 and 1,386,725 bytes of compressed column files. Compact
used MRK3 and a 1,325,955-byte `data.bin`.

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

## Falsifiers

- An ordered scan must match serial rows, batch coordinates, and batch size
  limits on mixed parts and when one part is split across workers.
- A callback failure or a worker failure must release outstanding buffers and
  join the workers. A subsequent scan of valid parts must still succeed.
- Splitting Compact marks between workers must keep a cumulative per-part
  transport limit. A higher worker count must still reject the 64-mark pilot.
- The benchmark must reject an incorrect aggregate and changed part bytes.
  A four-worker result requires observed concurrent work on both engines.

Revert the parallel scan change to remove the opt-in path. Keep the sequential
reference timings as evidence for their pinned revision and runtime.
