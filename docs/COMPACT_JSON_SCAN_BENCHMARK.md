# Compact JSON scan benchmark

The fixture contains 8,192 rows per Compact part, with four positive marks of
2,048 rows and a terminal mark. It uses plain `.mrk4`, LZ4, root JSON v3, and
Advanced shared data with two buckets. `doc` has declared `UInt32`, `String`,
and `Nullable(UInt32)` paths and two dynamic paths. The fixture stays within
its dynamic path limit, so the shared buckets carry no overflow paths. The
complete storage schema also contains `events Array(Tuple(a UInt64, b String))` and
`attrs Map(String, Array(Nullable(UInt64)))`. The direct comparison selects
`id, doc`.

The fixture generator exports `id, toJSONString(doc) ORDER BY id FORMAT
RowBinary` from ClickHouse with checksumming enabled. All runners validate
every sample byte for byte against this oracle after measuring the read and
serialization stages. The driver additionally flips a checksum byte after
each runner opens a disposable copy and requires the first scan to fail.

## Reproduction

Run from the repository root. Use a disposable directory on the external SSD
and six free loopback ports. `bench_ch` is the ClickHouse 26.10.1.1201 binary.
`bench_cpp` is the uninstrumented C++ `readRows` runner built at ClickHouse
`d9bcb5ab007f0f6299f7f973f2642245bab3d028` using the
[direct reader build instructions](PARALLEL_TYPED_SCAN_FRONTIER.md#direct-reader-comparison-contract).

```sh
bench_work=$(mktemp -d /opt/mldata_ssd/tmp/crystal-click-json.XXXXXXXX)
mkdir -p "$bench_work/tmp" "$bench_work/cache"

python3 -B scripts/parallel_scan_benchmark.py native-start \
  --root "$bench_work/server" --clickhouse-bin "$bench_ch" \
  --compact-port 37840 --wide-port 37843
python3 -B scripts/compact_json_scan_fixture.py \
  --port 37840 --output "$bench_work/fixture"
python3 -B scripts/parallel_scan_benchmark.py native-stop --root "$bench_work/server"

TMPDIR="$bench_work/tmp" CRYSTAL_CACHE_DIR="$bench_work/cache" \
  crystal build --release -Dpreview_mt -Dexecution_context \
    benchmarks/compact_json_scan_probe.cr -o "$bench_work/crystal-probe"

mkdir "$bench_work/baseline-src" "$bench_work/baseline-cache"
git archive fac9472696bcb4cb84b864c2eeb26de1bbc7fc96 \
  src benchmarks/compact_json_scan_probe.cr | tar -x -C "$bench_work/baseline-src"
TMPDIR="$bench_work/tmp" CRYSTAL_CACHE_DIR="$bench_work/baseline-cache" \
  crystal build --release -Dpreview_mt -Dexecution_context \
    "$bench_work/baseline-src/benchmarks/compact_json_scan_probe.cr" \
    -o "$bench_work/crystal-baseline"

python3 -B scripts/compact_json_scan_benchmark.py \
  --part "$bench_work/fixture/0_1_1_0" \
  --oracle "$bench_work/fixture/0_1_1_0.rowbinary" \
  --crystal-bin "$bench_work/crystal-probe" --crystal-backend shared \
  --baseline-crystal-bin "$bench_work/crystal-baseline" --cpp-bin "$bench_cpp" \
  --scratch "$bench_work" --output "$bench_work/summary.json"
```

With one worker every runner reads `[0,1,2,3]`. With four workers each gets one
mark. All runners retain readers and worker threads within a process. Crystal
retains owned `ObjectDocument` instances and copied IDs across the batch
boundary. The baseline uses the typed candidate-mark API, while the shared
runner prepares a single plan per read and passes it to the retained workers.
The probe rechecks the source on the coordinator once per completed mark
batch in the read timer. The public parallel API uses the same plan and
decoders and checks the source immediately before each ordered callback on
the calling fiber. The C++ runner calls
`IMergeTreeReader::readRows` into reusable typed columns with synchronous
`pread` and no shared uncompressed, mark, or prefix caches. The comparison
driver rotates through all six runner orders, verifies worker assignments,
and hashes the part files before and after the run. Worker and part startup
are recorded separately.

The read timer includes dispatch, decompression, and production of the retained
output. Serialization follows on the coordinator and has a separate timer.
ClickHouse reports typed column reset separately. Boehm allocated bytes are a
process-wide delta spanning both timed Crystal stages. ClickHouse reads into
reusable `ColumnObject` columns. Crystal allocates owned `ObjectDocument`
rows and rechecks the current source before delivering each batch.

## Shared plan results

Warm reads on Apple M2 Max, macOS 26.6.2, Crystal 1.22.3 Release with LLVM
23.1.5 and Boehm 8.2.12 enabled. Each reader and worker count contributed 48
measured reads across eight fresh processes, with two warmups per process.
All 288 measured reads and 96 warmups returned exactly 848,918 oracle bytes
in mark order. The three post-open checksum corruption controls passed.

| Reader | Workers | Read p50 / p95, ms | Serialize p50 / p95, ms | Combined p50 / p95, ms | Boehm MiB / collections, median |
| --- | ---: | ---: | ---: | ---: | ---: |
| Crystal baseline `fac9472` | 1 | 28.986 / 31.506 | 9.341 / 10.563 | 38.267 / 41.399 | 73.54 / 3 |
| Crystal shared plan | 1 | 19.319 / 21.376 | 8.459 / 10.468 | 27.853 / 30.571 | 51.61 / 1 |
| ClickHouse `readRows` | 1 | 0.418 / 0.559 | 5.971 / 6.096 | 6.388 / 6.585 | — |
| Crystal baseline `fac9472` | 4 | 60.299 / 67.245 | 9.636 / 12.301 | 68.757 / 76.855 | 90.32 / 3 |
| Crystal shared plan | 4 | 38.135 / 44.777 | 9.185 / 10.904 | 46.687 / 53.338 | 51.63 / 1 |
| ClickHouse `readRows` | 4 | 0.197 / 0.277 | 6.008 / 6.236 | 6.225 / 6.439 | — |

The shared plan reduced Crystal read p50 by 33.4% at one worker and 36.8%
at four. Read p95 fell by 32.2% and 33.4%. Four workers still took 1.97× as
long as one at Crystal read p50, while ClickHouse read p50 was 2.12× faster.
Crystal read p50 was 46.2× and 193.7× the corresponding `readRows` latency.
With serialization included, the p50 ratios were 4.36× and 7.50×.

One plan was built inside each timed Crystal read, with a median of 2.531 ms
at one worker and 2.578 ms at four. Separate Crystal part/worker startup
medians were 1.440 and 1.604 ms. ClickHouse ATTACH medians were 13.052 and
13.091 ms, with reader/worker startup at 0.101 and 0.137 ms. ClickHouse
column reset medians were 0.015 and 0.016 ms.

A second v3 fixture used the same geometry and added five paths named
`overflow_0` through `overflow_4` to each source row. Their values were
`spill-{path_index}-{id % 43:02d}`. Three paths per row went into Advanced
SharedData. Both readers passed W1 and W4 bytewise checks on all 1,922,070
RowBinary bytes and rejected the post-open checksum mutation. The small
overflow run served as a correctness check.

| Evidence | SHA-256 |
| --- | --- |
| Crystal shared-plan release benchmark | `22206a6da4f7adbdcff6935b4629e661955690da664a27004708e978c9c718a8` |
| Crystal baseline release benchmark | `9c49d594b0e73a5cf2cd6f08d81529d857112c48dad5f9a9b5b367c517d0ad59` |
| Native uninstrumented runner | `4a820906c3dbdf9556b8bf1d5c7f3fb96cfe71b71c9e088b786069569746b2d8` |
| Overflow `data.bin` | `d99ddd6d2144615388982b267b20f14e4f56e4689f26faea922c2ab3fb5c82d5` |
| Overflow full ordered RowBinary | `3495978197741a4e241a2201bd92030afbb7590588bccb2ab3da107b1059d62b` |

The main fixture matches the `data.bin`, `data.mrk4`, and RowBinary hashes
below.

## Previous matched results

Warm single-part reads on an Apple M2 Max with macOS 26.6.2, Crystal 1.22.3
Release and Boehm 8.2.12 enabled. Each worker count used eight fresh pairs of
processes, two warmup scans and six measured scans per pair. All 192 timed
outputs, plus warmups, matched the 8,192-row ClickHouse RowBinary export.
The post-open corruption controls passed for both readers.

| Reader | Workers | Read p50 / p95, ms | Serialize p50 / p95, ms | Combined p50 / p95, ms | Boehm MiB / collections, median |
| --- | ---: | ---: | ---: | ---: | ---: |
| Crystal | 1 | 28.375 / 32.204 | 9.155 / 10.472 | 37.593 / 41.057 | 73.54 / 3 |
| Crystal | 4 | 55.733 / 68.221 | 9.616 / 11.604 | 66.410 / 77.732 | 90.32 / 3 |
| ClickHouse `readRows` | 1 | 0.415 / 0.500 | 6.014 / 6.176 | 6.403 / 6.621 | — |
| ClickHouse `readRows` | 4 | 0.193 / 0.369 | 6.033 / 6.220 | 6.225 / 6.570 | — |

The four-worker read median was 1.96× the one-worker median in Crystal and
0.47× in ClickHouse. Crystal's combined medians were 5.87× and 10.67× the
corresponding ClickHouse medians. The median Crystal worker/part preparation
was 1.425 ms at one worker and 4.054 ms at four. The native median ATTACH was
12.973/13.017 ms and reader/worker preparation was 0.091/0.151 ms. Native
output reset after serialization was 0.015/0.016 ms and is recorded separately.

| Evidence | SHA-256 |
| --- | --- |
| `data.bin` | `b1ec3b935fca8e6a3ae5c7878d5b66aadf7e108d32cf17650f638282d86d27c9` |
| `data.mrk4` | `1679893d60280a7708e6567298d244839a560922c2874d7829e40ace84785b6b` |
| Full ordered RowBinary | `23445f53dadbd87868504708018238132053838a0e0277a27254dac4c71a76b0` |
| Crystal release benchmark | `edf3e3c077305ef3adbf59b1bb780d581a4c1ce34142be11edd5e8904421ce11` |
| Native uninstrumented runner | `62d74642f949f49c811623a8fe59216cba3e42881c85b6746839189e7e0404e3` |
| Official ClickHouse fixture generator | `5bb43958f4c0806cc363b84b9858e7206e56ac80263a24acc704271322e531ae` |

## Crystal diagnostics

Use an isolated source copy and apply the diagnostic hooks. The instrumented
binary accepts one worker. `none`, `first`, and `all` select 0, 1, or 4 marks.
Preparation time encloses the full-window read, its checksum and decompression,
and the JSON plan work. The source recheck timer measures current-path
validation during preparation and after worker output. The checksum and
decompression counters count frames read for decoding. The recheck counter
counts the frames hashed by source validation. Count-only physical ranges
include empty substreams. Use the uninstrumented binaries for wall-time
comparisons.

```sh
mkdir "$bench_work/diagnostic-src"
git archive HEAD src benchmarks/compact_json_scan_probe.cr | tar -x -C "$bench_work/diagnostic-src"
python3 -B scripts/instrument_compact_json_probe.py "$bench_work/diagnostic-src"
TMPDIR="$bench_work/tmp" CRYSTAL_CACHE_DIR="$bench_work/cache" \
  crystal build --release -Dpreview_mt -Dexecution_context \
    -Dcompact_json_scan_diagnostic \
    "$bench_work/diagnostic-src/benchmarks/compact_json_scan_probe.cr" \
    -o "$bench_work/diagnostic-probe"

for selection in none first all; do
  "$bench_work/diagnostic-probe" shared "$bench_work/fixture/0_1_1_0" \
    "$bench_work/fixture/0_1_1_0.rowbinary" 1 "$selection" retained 1 7
done
```

An empty result in Crystal still runs the whole-grid JSON validation. An empty
native schedule issues no `readRows` calls. For nonempty schedules, both
readers authenticate frames they decode. The shared plan also verifies the
authenticated source before releasing retained rows.

### Shared-plan diagnostics

Every selection prepared one complete plan and read the shared physical
window once. Each window inflated 471,803 bytes across eight LZ4 frames.
With all four marks selected, the previous route prepared five times and
inflated 2,096,871 bytes across 24 decompression calls. The shared route
issued one source recheck during preparation and one before delivering
each selected mark batch. A recheck reads fresh source bytes and checks
their checksums without inflating them.

| Selected marks | Complete preparations | Transport checksum / LZ4 calls | Source rechecks / frames rechecked | Recheck time p50, ms |
| ---: | ---: | ---: | ---: | ---: |
| 0 | 1 | 8 / 8 | 1 / 8 | 0.198 |
| 1 | 1 | 8 / 8 | 2 / 16 | 0.551 |
| 4 | 1 | 8 / 8 | 5 / 40 | 1.049 |

The figures use seven instrumented scans per selection after warmup. On
the full selection, the median read was 21.869 ms and preparation was
2.689 ms. The same full-selection diagnostics recorded 0.021 ms in transport
checksums and 0.131 ms in LZ4. These are nested stages and should be read
with the separate uninstrumented timings.

### Previous repeated-preparation diagnostics

| Marks | Full preparations before → after | Checksum calls and LZ4 calls before → after | Distinct frames after | Inflated bytes before → after | Prepare median after, ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| 0 | 2 → 1 | 16 → 4 | 4 | 1,625,068 → 406,267 | 2.374 |
| 1 | 3 → 2 | 25 → 9 | 5 | 2,453,986 → 828,918 | 4.936 |
| 4 | 6 → 5 | 52 → 24 | 8 | 4,940,740 → 2,096,871 | 11.604 |

The baseline is `bbab15a`. The changes reuse authenticated source bytes
within one preparation and skip a duplicate facade preflight when one Compact
backend already gates the scan. A later malformed selected part still fails
before any multipart callback. In-place payload corruption and a corrupted
same-path replacement between callbacks were detected before the second
callback. Nested scans, empty candidate lists, and end windows keep their
validation and callback contracts.

Across seven diagnostic scans after warmup, the all-mark median read was
29.005 ms. CityHash took 0.081 ms and LZ4 took 0.520 ms within that read.
Preparation took 11.604 ms, including its share of checksum and decompression.
The profiled native reader ran eight checksum and eight LZ4 calls on all
marks (two per worker at four workers), two calls each on mark 0, and zero
calls on an empty schedule. The Crystal read still constructs and owns each
JSON row, and each Crystal worker independently executes the complete-grid
gate before its selected marks. Allocation deltas and collection counts
describe the runtime work in this test. Attributing wall time to GC pauses
requires a separate profile.

## Physical JSON path selection

Pass `--parts 8` to the fixture generator, then check the public reader with
its per-part `id, doc.tenant_id` SQL exports.

```sh
TMPDIR="$bench_work/tmp" CRYSTAL_CACHE_DIR="$bench_work/cache" \
  crystal run benchmarks/compact_json_pushdown_probe.cr -- "$bench_work/fixture"
```

The typed slice scan matched all 65,536 rows (786,432 RowBinary bytes,
SHA-256 `2411071a48c3076b4b6e49325b4ecc8590fa397b07eeb96dca7513fcad796986`).
The [reader contract](COMPACT_TYPED_READER_FRONTIER.md#selected-uint32-json-paths)
covers the declared UInt32 path and frame validation.

In a separate physical range check that coalesced selected spans per part,
both `id, doc` and `id, doc.tenant_id` touched 64 LZ4 frames across eight
parts. Both hashed 1,038,746 compressed bytes and inflated 3,774,424 bytes.
Copying only the two selected streams reduced delivered physical bytes from
3,774,424 to 786,432. These copy and frame counts describe the coalesced
transport experiment. The advantage on this packing comes from narrower
output and bypassing JSON row assembly.

## Columnar read of the events array

`CompactBinaryBulkColumnReader#read_array_tuple_uint64_string_mark` reads the
exact declaration `Array(Tuple(a UInt64, b String))` one mark at a time. It
uses the authenticated Compact window and existing recursive normalizer. The
result owns row offsets, UInt64 values, String offsets, and concatenated
payload bytes. Keep the result alive while consuming its read-only slices.
Both String layouts preserve arbitrary payload bytes. The decoder bounds the
flat output at 64 MiB and checks the lane grids, counts, and codec budget.

```sh
TMPDIR="$bench_work/tmp" CRYSTAL_CACHE_DIR="$bench_work/cache" \
  crystal build --release benchmarks/compact_array_tuple_scan_probe.cr \
    -o "$bench_work/array-probe"
"$bench_work/array-probe" "$bench_work/fixture/0_1_1_0" \
  "$bench_work/fixture/0_1_1_0.events.rowbinary"
```

Both routes read and retain the same four marks of `events` with one worker.
The legacy route reads `BinaryValue` objects and runs the typed batch
adapter. The flat route skips that intermediate representation. Both
serialize their retained results with a separate timer and compare every
output to the ordered ClickHouse RowBinary export. Each process alternates
routes through two warmup pairs and sixteen timed pairs. Boehm stays enabled
and a collection before each sample is outside the timed read.

| Route | Read p50 / p95, ms | Serialize p50 / p95, ms | Read allocated bytes, median |
| --- | ---: | ---: | ---: |
| Legacy typed adapter | 24.056 / 28.795 | 0.203 / 0.252 | 47,300,312 |
| Flat result | 2.777 / 3.053 | 0.184 / 0.200 | 8,521,528 |

All 96 timed outputs and 12 warmups across three processes matched the
8,192-row export. The read median improved 8.66× and read allocations
dropped 82.0%. The measurement selects only `events` and uses the v1 String
layout on the same host and compiler as the JSON comparison. The export
SHA-256 is `d1046c03718ac04c0b2f5ea8bbdc1489041079aeb7c65068d37699fda41baca1`.
The release probe SHA-256 is
`5f985ea9fbfcdd2d0766935a1c5e6db455368cf48d8de3f7caeaaf31bf957f3f`.
