# Compact JSON scan benchmark

The fixture contains 8,192 rows per Compact part, with four positive marks of
2,048 rows and a terminal mark. It uses plain `.mrk4`, LZ4, root JSON v3, and
Advanced shared data with two buckets. `doc` has declared `UInt32`, `String`,
and `Nullable(UInt32)` paths and two dynamic paths. The fixture stays within
its dynamic path limit, so the shared buckets carry no overflow paths. The
complete storage schema also contains `events Array(Tuple(a UInt64, b String))` and
`attrs Map(String, Array(Nullable(UInt64)))`. The direct comparison selects
`id, doc`. Use `--shared-overflow` to generate the second fixture, in which
five extra paths cause three paths per row to use Advanced SharedData.

The fixture generator exports `id, toJSONString(doc) ORDER BY id FORMAT
RowBinary` from ClickHouse with checksumming enabled. All runners validate
every sample byte for byte against this oracle after measuring the read and
serialization stages. At each worker count, the driver flips a checksum byte
after each runner opens a disposable copy and requires the first scan to fail.

## Reproduction

Run from the repository root. Use a disposable directory on the external SSD
and six free loopback ports. `bench_ch` is the ClickHouse 26.10.1.1201 binary.
`bench_cpp` is the C++ `readRows` runner built at ClickHouse
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

mkdir -p "$bench_work/baseline-src" "$bench_work/baseline-cache"
git archive 9b5e65a src benchmarks/compact_json_scan_probe.cr | \
  tar -x -C "$bench_work/baseline-src"
TMPDIR="$bench_work/tmp" CRYSTAL_CACHE_DIR="$bench_work/baseline-cache" \
  crystal build --release -Dpreview_mt -Dexecution_context \
    "$bench_work/baseline-src/benchmarks/compact_json_scan_probe.cr" \
    -o "$bench_work/crystal-baseline"

python3 -B scripts/compact_json_scan_benchmark.py \
  --part "$bench_work/fixture/0_1_1_0" \
  --oracle "$bench_work/fixture/0_1_1_0.rowbinary" \
  --crystal-bin "$bench_work/crystal-probe" --crystal-backend columnar \
  --baseline-crystal-bin "$bench_work/crystal-baseline" --baseline-crystal-backend columnar \
  --cpp-bin "$bench_cpp" \
  --scratch "$bench_work" --output "$bench_work/summary.json"
```

Repeat fixture generation against a fresh benchmark server with
`--shared-overflow` and `--output "$bench_work/overflow-fixture"` to
measure SharedData overflow. Use that directory's part and RowBinary in
the comparison. Run the comparison a second time with
`--native-read-allocations` and a separate report path for native allocation
counts on macOS with `ENABLE_LIBRARIES=OFF`.

For a Crystal-only comparison, supply `--baseline-crystal-bin` and omit
`--cpp-bin` and `--native-read-allocations`. Both binaries go through the
same schedule, RowBinary, and post-open checksum checks. Set the revision in
`git archive` to `76e0f24` for the scalar cursor and Bool payload comparison,
`04b421f` for the declared `Nullable(UInt32)` slice baseline, `05ee0c7` for
the Data String slice baseline, `e2571d1` for the Copy String slice baseline,
`2dee2ae` for the Dynamic binding baseline, or `86b3225` for the empty child
storage baseline.

The public callback and source-binding checks use both fixture directories.

```sh
CRYSTAL_CLICK_COLUMNAR_JSON_FIXTURE_ROOT="$bench_work" \
  TMPDIR="$bench_work/tmp" CRYSTAL_CACHE_DIR="$bench_work/cache" \
  crystal spec --release -Dpreview_mt -Dexecution_context \
    spec/compact_shared_advanced_json_columnar_spec.cr \
    spec/compact_shared_advanced_json_part_plan_spec.cr \
    spec/object_shared_advanced_direct_columns_w263_spec.cr \
    spec/binary_dynamic_bulk_values_w155_spec.cr \
    spec/binary_dynamic_bulk_shared_context_w155_spec.cr \
    spec/binary_bulk_w122_spec.cr
```

With one worker every runner reads `[0,1,2,3]`. With four workers each gets one
mark. All runners retain readers and worker threads within a process. Crystal
prepares one authenticated plan per read and shares it between workers.
The `shared` route retains owned `ObjectDocument` instances and copied IDs.
The `columnar` route retains one reusable path-column buffer and companion
column buffers per assigned mark. The probe warms these buffers before the
measured reads. It rechecks the source on the coordinator once per completed
mark batch in the read timer. The public columnar API uses the same decoder
and validates the source immediately before each ordered callback. The C++
runner calls `IMergeTreeReader::readRows` into reusable typed columns with synchronous
`pread` and no shared uncompressed, mark, or prefix caches. The comparison
driver rotates runner orders, verifies worker assignments, and hashes the
part files before and after the run. Worker and part startup are recorded
separately. The native workers construct their `IMergeTreeReader` instances
during preparation and reuse them for each timed read.

The read timer includes dispatch, decompression, and production of the retained
output. Serialization follows on the coordinator and has a separate timer.
Both runners clear the output before the next scan and time this reset
separately. The driver records
process-wide Boehm allocated-byte and collection deltas during the read, plus
separate deltas spanning both timed Crystal stages.
The optional native diagnostic counts successful system allocator requests
and their requested bytes in the read interval across the process. It
includes `realloc` requests and captures allocator traffic from all workers.
Boehm bytes and system requested bytes use their respective allocator
accounting. The timing run leaves the native observer disabled.

## Dynamic substream binding results

The bulk reader binds Dynamic discriminator, scalar arm and SharedVariant
String cursors to slices for the current mark. The arm record also holds the
canonical path, the actual type and the seed key for a recursive JSON leaf.
The reader charges the original path work at each use and checks that each
cursor consumed its complete slice. Composite arm values use the recursive
decoder.

Both `columnar` runners used Crystal 1.22.3 Release, LLVM 23.1.5 and Boehm
8.2.12 on an Apple M2 Max with macOS 26.6.2 and background activity. The
`2dee2ae` baseline and the candidate alternated within eight blocks of two
warmups and six timed scans per build, part and worker count. Both fixtures
matched the previous `data.bin`, `data.mrk4` and ordered RowBinary hashes.
The read timer includes the part plan, decoding and all of the source checks.
The combined timer adds coordinator serialization.

| Compact part | Workers | Read p50 / p95, ms before → after | Boehm read allocations p50 / p95, MiB before → after | Read + serialize p50 / p95, ms before → after |
| --- | ---: | ---: | ---: | ---: |
| No overflow | 1 | 9.709 / 10.211 → 9.608 / 10.150 | 21.410 / 21.424 → 21.408 / 21.423 | 15.624 / 17.301 → 16.915 / 17.867 |
| No overflow | 4 | 19.325 / 21.809 → 18.968 / 21.387 | 21.419 / 21.440 → 21.414 / 21.441 | 25.572 / 29.195 → 25.631 / 27.888 |
| SharedData overflow | 1 | 36.579 / 43.241 → 27.623 / 30.321 | 92.270 / 92.298 → 66.793 / 66.817 | 54.534 / 62.813 → 43.112 / 47.841 |
| SharedData overflow | 4 | 82.960 / 87.999 → 53.432 / 57.558 | 92.281 / 92.310 → 66.811 / 66.827 | 100.441 / 106.509 → 69.082 / 73.548 |

On overflow, all 48 paired reads were faster at each worker count. Read
p50 fell by 24.5% with one worker and 35.6% with four. Read allocation
p50 and p95 fell by 27.6% at both worker counts. The four-worker read
median was 1.93× the one-worker median after the change, down from 2.27×.

Without overflow, read allocation medians stayed near 21.4 MiB. A repeat
with the same 48-sample schedule put read p50 / p95 at 9.645 / 10.710 →
9.522 / 10.360 ms with one worker and 18.822 / 21.427 → 18.868 / 21.450 ms
with four. The initial one-worker combined median rose by 8.3%, mostly in
serialization. In the repeat it fell by 1.5%, from 16.613 to 16.366 ms.

All 384 primary timed scans, 128 warmups and the no-overflow repeat matched
ordered RowBinary and the selected marks. Both builds at both worker counts
rejected a post-open checksum mutation on each part. The overflow SharedData
Data frame mutation also failed with one and four workers, and the candidate
rejected a one-byte change in a RowBinary oracle of the original length.
The 79 targeted Release examples include between-batch source changes,
validly encoded Copy/Data mismatches, and an exact-budget regression that
rebinds repeated Dynamic arms across marks under both String profiles.

| Evidence | SHA-256 |
| --- | --- |
| `2dee2ae` columnar Release runner | `7713139325ab2cd3bce527c973a04531178fdeadf18e1178e5b8980a5df818ec` |
| Dynamic binding columnar Release runner | `b1793f05a3ad08199fe3ea9f403ff5a312b73cf2d0e3f2d861414777f06f4754` |

## Shared empty child storage results

`BinaryValue` reuses one private empty child array for values with no
children. It still takes ownership of scalar bytes and copies nonempty child
arrays. Calls to `elements` return detached arrays, including empty ones.
In a separate Release probe retaining 25,000 String values with four-byte
payloads and one shared type descriptor, Boehm allocated 64 fewer bytes per
retained value, from 248.04 to 184.04 bytes.

Both runners used the `columnar` backend on Crystal 1.22.3 Release with
LLVM 23.1.5 and Boehm 8.2.12 enabled. The Apple M2 Max and macOS 26.6.2
host had background activity. The `86b3225` baseline and the candidate
ran in alternating order with eight blocks, two warmups, and six timed
scans per block for each part and worker count. The part manifests and
RowBinary hashes matched the previous fixtures. All 384 timed scans and
128 warmups matched ordered RowBinary.
Both runners at both worker counts rejected a post-open checksum mutation
on each part. The driver also rejected an oracle with one changed byte and
the original length.

| Compact part | Workers | Baseline read p50 / p95, ms | Shared empty array read p50 / p95, ms | Read allocations p50, MiB before → after | Combined p50 / p95, ms before → after |
| --- | ---: | ---: | ---: | ---: | ---: |
| No overflow | 1 | 10.645 / 11.976 | 9.825 / 10.640 | 23.980 → 21.409 | 17.962 / 19.329 → 16.603 / 17.876 |
| No overflow | 4 | 21.784 / 26.607 | 19.486 / 23.921 | 23.992 → 21.417 | 29.433 / 34.584 → 25.990 / 31.790 |
| SharedData overflow | 1 | 40.673 / 43.236 | 36.553 / 39.789 | 98.845 → 92.275 | 57.488 / 65.644 → 54.624 / 60.969 |
| SharedData overflow | 4 | 87.850 / 96.692 | 80.576 / 86.224 | 98.860 → 92.288 | 104.091 / 114.093 → 98.737 / 105.022 |

Read p50 fell by 7.7–10.6% and p95 by 8.0–11.2%. The median paired read
time change was negative in 31 of 32 blocks. Median read collections
on the overflow part moved from three to two at one worker and stayed at
two at four workers. Overflow serialization p50 rose from 16.810 to 17.831
ms at one worker and from 16.219 to 18.513 ms at four workers. The combined
median fell by about 5% at both worker counts. Four workers still took 2.20×
the one-worker read median on that part. The ClickHouse measurements below
are from the earlier campaign.

The four targeted Release suites passed 40 examples, including ownership of
empty child arrays, the two fixture-backed scans, validly encoded Copy and
Data disagreements, and source changes between callbacks.

| Evidence | SHA-256 |
| --- | --- |
| `86b3225` columnar Release runner | `3dbf629fa6700c307967f581e2b638bd33d7e3262749370351a1da0b7e8efe28` |
| Shared empty child storage Release runner | `e44c352bcc79dd77693b4faf28e82b6e506c7b4be543aa5e0259a8afdf889185` |

## Direct SharedData columnar results

Both Crystal binaries use the `columnar` backend. The baseline is `9b5e65a`.
The direct decoder appends SharedData Copy values into sparse columns bound
by the chunk dictionary and verifies them against the independently decoded
per-path Data. It compares sparse presence and exact values before delivery.
Path records, substream events, and per-path decode results use value types.

Both readers verify the compressed frames they read. For this full-column
MRK4 read, ClickHouse uses the mark-seek callback to skip the per-path Data
and populates SharedData from Copy. The Crystal read timer includes the
per-path Data comparison, part plan construction, and the source rechecks at
mark boundaries. RowBinary equality is checked after the read timers. The
read latencies describe the work of each engine with its validation path.
[ClickHouse Compact reader](https://github.com/ClickHouse/ClickHouse/blob/d9bcb5ab007f0f6299f7f973f2642245bab3d028/src/Storages/MergeTree/MergeTreeReaderCompact.cpp#L258-L277),
[SharedData serializer](https://github.com/ClickHouse/ClickHouse/blob/d9bcb5ab007f0f6299f7f973f2642245bab3d028/src/DataTypes/Serializations/SerializationObjectSharedData.cpp#L1548-L1770).

The runs used an Apple M2 Max, macOS 26.6.2, Crystal 1.22.3 Release with
LLVM 23.1.5 and Boehm 8.2.12 enabled, and the pinned `readRows` built with
Clang 23.1.5 Release and the macOS system allocator. Each pass had 48 timed
scans per reader, part, and worker count, interleaved in eight blocks of
six scans on a workstation with background activity. Across both parts,
all 576 measurements and 192 warmups per pass matched the RowBinary bytes
in mark order. The twelve post-open checksum mutations per pass were
rejected. The `data.bin`, `.mrk4`, and RowBinary hashes matched the previous
fixtures. Combined latency takes percentiles of the sum of read and
serialization times for each native sample. Crystal measures the contiguous
interval from plan construction through serialization, which also includes
the post-read GC counter snapshots and mark ordering.

| Compact part | Reader | Workers | Read p50 / p95, ms | Serialize p50 / p95, ms | Combined p50 / p95, ms |
| --- | --- | ---: | ---: | ---: | ---: |
| No overflow | Crystal baseline | 1 | 11.364 / 12.973 | 6.908 / 8.749 | 18.138 / 20.988 |
| No overflow | Crystal direct | 1 | 11.124 / 12.444 | 6.810 / 8.490 | 18.001 / 19.559 |
| No overflow | ClickHouse `readRows` | 1 | 0.412 / 0.462 | 5.987 / 6.195 | 6.400 / 6.591 |
| No overflow | Crystal baseline | 4 | 25.725 / 37.350 | 6.499 / 7.642 | 32.451 / 44.136 |
| No overflow | Crystal direct | 4 | 24.161 / 33.197 | 7.786 / 9.636 | 31.689 / 41.847 |
| No overflow | ClickHouse `readRows` | 4 | 0.198 / 0.379 | 6.010 / 6.187 | 6.222 / 6.576 |
| SharedData overflow | Crystal baseline | 1 | 50.644 / 60.342 | 19.804 / 24.002 | 70.477 / 84.345 |
| SharedData overflow | Crystal direct | 1 | 41.082 / 45.492 | 17.248 / 20.080 | 58.544 / 62.993 |
| SharedData overflow | ClickHouse `readRows` | 1 | 0.857 / 0.917 | 61.228 / 62.576 | 62.093 / 63.861 |
| SharedData overflow | Crystal baseline | 4 | 105.793 / 112.103 | 20.232 / 26.879 | 126.013 / 133.548 |
| SharedData overflow | Crystal direct | 4 | 88.828 / 102.159 | 16.757 / 20.668 | 106.001 / 118.844 |
| SharedData overflow | ClickHouse `readRows` | 4 | 0.333 / 0.686 | 61.223 / 63.899 | 61.632 / 64.458 |

| Compact part | Workers | Boehm baseline, MiB | Boehm direct, MiB | ClickHouse requested, MiB | ClickHouse requests |
| --- | ---: | ---: | ---: | ---: | ---: |
| No overflow | 1 | 25.50 / 25.51 | 23.98 / 24.00 | 0.71 / 0.71 | 1066 / 1066 |
| No overflow | 4 | 25.51 / 25.53 | 23.99 / 24.02 | 0.71 / 0.71 | 1017 / 1035 |
| SharedData overflow | 1 | 109.37 / 109.39 | 98.84 / 98.87 | 1.77 / 1.77 | 1648 / 1648 |
| SharedData overflow | 4 | 109.39 / 109.40 | 98.86 / 98.89 | 1.77 / 1.77 | 1584 / 1610 |

The allocation table reports p50 / p95 for the read interval in the
separate diagnostic pass. On the overflow part, read p50 fell by 18.9% and
16.0%, and p95 fell by 24.6% and 8.9%, at one and four workers respectively.
Median Boehm bytes fell by 9.6%, and median read collections dropped from
three to two at both worker counts. Without overflow, median Boehm bytes
fell by 5.9% and both worker counts still had one median collection. These
changes measure the direct decoder and value-type records together.

At four workers, direct Crystal read p50 took about 2.17× its one-worker
time on both parts, while `readRows` sped up by 2.08× without overflow and
2.57× with overflow. Median Crystal plan construction took 2.58–2.59 ms
without overflow and 6.01–6.20 ms with overflow. On overflow at one worker,
the combined Crystal median was 58.544 ms versus 62.093 ms for `readRows`
with serialization. ClickHouse's RowBinary materialization took 61.228 ms
of that time at the median. For the read interval alone, the Crystal
median was 47.95× the `readRows` median on that part and worker count.

The targeted Release run passed 85 examples, including exact RowBinary on
both fixture parts, v2 and multi-chunk v3 with split callback windows, and
independent Copy and Data streams that disagree in value or presence. The
shared-data suite passed all 255 examples in Debug, including rejection of
a fresh decode budget before binding columns from a prepared source.

| Evidence | SHA-256 |
| --- | --- |
| Crystal columnar baseline Release runner | `c13b95480a2cedcd0faa61bdc0896816cc0fcdd8161c9c63b4e670f627509096` |
| Crystal direct SharedData Release runner | `99182c5f43fcee70f242caa064968697828944e7be096162921d8400b5678d87` |
| Pinned ClickHouse `readRows` Release runner | `ac6fe44953b7ce40f9c0cdf81f3fb821d4936cccfb333e504b311f2f9e41e3c1` |

## Previous columnar results

Apple M2 Max, macOS 26.6.2, Crystal 1.22.3 Release with LLVM 23.1.5 and
Boehm 8.2.12 enabled. ClickHouse `readRows` used Clang 23.1.5 Release and
the macOS system allocator. Each fixture, reader, and worker count used
eight fresh processes with two warmups and six measured scans each. Each
pass checked all 576 measured reads and 192 warmups against the ordered
RowBinary export and rejected the six post-open checksum mutations.

The `shared` and `columnar` modes used the same Crystal executable. The
times below come from the pass with the native allocation observer off.

| Compact part | Reader | Workers | Read p50 / p95, ms | Serialize p50 / p95, ms | Combined p50 / p95, ms |
| --- | --- | ---: | ---: | ---: | ---: |
| No overflow | Crystal shared | 1 | 17.508 / 23.624 | 10.481 / 15.607 | 27.867 / 36.542 |
| No overflow | Crystal columnar | 1 | 11.708 / 14.044 | 7.597 / 10.695 | 19.007 / 26.191 |
| No overflow | ClickHouse `readRows` | 1 | 0.426 / 0.508 | 6.042 / 8.804 | 6.474 / 9.631 |
| No overflow | Crystal shared | 4 | 36.569 / 41.564 | 10.566 / 14.964 | 47.857 / 63.108 |
| No overflow | Crystal columnar | 4 | 25.949 / 33.305 | 6.915 / 8.893 | 32.556 / 41.448 |
| No overflow | ClickHouse `readRows` | 4 | 0.250 / 0.655 | 6.035 / 6.481 | 6.283 / 7.065 |
| SharedData overflow | Crystal shared | 1 | 65.526 / 79.997 | 27.612 / 38.405 | 92.117 / 118.403 |
| SharedData overflow | Crystal columnar | 1 | 53.121 / 68.312 | 21.585 / 27.160 | 74.907 / 93.970 |
| SharedData overflow | ClickHouse `readRows` | 1 | 0.873 / 1.378 | 61.314 / 64.823 | 62.177 / 65.769 |
| SharedData overflow | Crystal shared | 4 | 131.891 / 146.965 | 28.485 / 32.760 | 161.129 / 174.984 |
| SharedData overflow | Crystal columnar | 4 | 109.682 / 125.752 | 20.474 / 22.702 | 130.074 / 148.391 |
| SharedData overflow | ClickHouse `readRows` | 4 | 0.343 / 0.606 | 61.312 / 62.501 | 61.678 / 62.965 |

The separate allocation pass measured the read interval with both runtimes
using their configured allocators. MiB and request counts are p50 / p95.

| Compact part | Workers | Boehm shared, MiB | Boehm columnar, MiB | ClickHouse requested, MiB | ClickHouse requests |
| --- | ---: | ---: | ---: | ---: | ---: |
| No overflow | 1 | 33.48 / 33.50 | 25.50 / 25.51 | 0.71 / 0.71 | 1066 / 1066 |
| No overflow | 4 | 33.48 / 33.53 | 25.51 / 25.53 | 0.71 / 0.71 | 1014 / 1033 |
| SharedData overflow | 1 | 123.73 / 123.75 | 109.37 / 109.40 | 1.77 / 1.77 | 1648 / 1648 |
| SharedData overflow | 4 | 124.25 / 124.27 | 109.39 / 109.42 | 1.77 / 1.77 | 1568 / 1614 |

Columnar read p50 fell by 17–33% and p95 by 14–41%. The median Boehm byte
count fell by 24% without overflow and by 12% with overflow. Median read
collections stayed at one without overflow and rose from two to three with
overflow. Columnar read p50 with four workers was 2.22× the one-worker
value without overflow and 2.06× with overflow. ClickHouse read p50 improved
by 1.71× and 2.55×, respectively. With serialization included, columnar
Crystal p50 was 2.94× and 5.18× the ClickHouse times without overflow, and
1.20× and 2.11× with overflow.

Median plan time inside the Crystal columnar read was 2.61–2.68 ms without
overflow and 6.07–6.09 ms with overflow. The `9b5e65a` baseline creates
`BinaryValue` leaves and temporary per-row SharedData entries during decoding.
The plans and rechecks are part of the timed Crystal
read. The figures apply to these warm, retained one-part scans.

The two fixtures matched the historical `data.bin` and RowBinary hashes below.
The no-overflow `data.mrk4` matched as well. Both fixture-backed public API
checks and the synthetic admission, source binding, and lifecycle checks passed
in the columnar and part-plan Release specs (18 examples).

| Evidence | SHA-256 |
| --- | --- |
| Crystal shared and columnar Release runner | `a80aff198b7e81cd661d937ced861199e85e48f082f0a7acaec13074369a6437` |
| Pinned native `readRows` runner | `373dde216e82b75d5ffe183e2dfbe16094ef4d24b20f92aa34d71e63336e4c17` |
| Overflow `data.mrk4` | `b5c2c2f6072c7c8c727cc1e73f191a55c16e5cdf0b2a6e4acaf4f1edf07ca27b` |

## Previous shared plan results

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

### Boehm and decoder stack samples

The uninstrumented `87bf8da` Release runner scanned the two hash-matched
fixtures with Boehm enabled. On macOS, `/usr/bin/sample PID 2 1 -file FILE`
sampled the retained runner three times per part and worker count. For each
file, a fresh interactive `columnar` runner completed two warmups and up to
24 `scan` commands while the sampler ran. Each scan passed the ordered
RowBinary check. The stack denominator is the number of sampled stacks in
`ObjectDocumentCodec.decode_core_with_budget` on the named JSON workers. It
excludes the idle workers, main thread, and Boehm marker threads. Fractions
are inclusive and can overlap. Blocked threads contribute to these counts.

| Compact part | Workers | JSON decode stacks | In Boehm | In a Boehm mutex wait | In a collection stack | Under `BinaryValue.new` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| No overflow | 1 | 444 | 45.9% | 3.4% | 16.4% | 31.1% |
| No overflow | 4 | 3,589 | 89.9% | 71.2% | 2.1% | 52.3% |
| SharedData overflow | 1 | 2,059 | 47.5% | 1.6% | 13.2% | 18.6% |
| SharedData overflow | 4 | 12,040 | 88.1% | 65.6% | 1.5% | 17.0% |

With four workers, 2,551 of 2,557 mutex-wait stacks without overflow and
7,881 of 7,900 with overflow lacked a collection frame. The no-overflow
stacks mostly waited in `GC_generic_malloc_many`, which refills per-thread
free lists. On overflow, `BinaryBulkDecoder.child_path` appeared in 23.7%
of the one-worker decode stacks and 49.9% of the four-worker decode stacks.
At four workers it was an ancestor of 4,399 mutex waits outside collection.
In that revision, the Dynamic bulk row loop rebuilt stream names and looked
up discriminator and arm cursors on each value. The stack fractions measure
sampled thread occupancy. Use elapsed measurements for collector pauses
and wall-time changes.

### What the ClickHouse reader does

The pinned native Compact reader installs a substream mark-seek callback. For
the entire Advanced SharedData column, it reads the per-chunk path dictionaries,
seeks past flattened per-path Data and its metadata, and reads Copy offsets,
path indexes, and serialized values directly into column buffers. Ordinary
declared and Dynamic paths also deserialize directly into their destination
columns, with one serializer call per path per granule. The native reader can
defer interpreting SharedData scalar payloads until a consumer needs them.
[Compact mark seeks](https://github.com/ClickHouse/ClickHouse/blob/d9bcb5ab007f0f6299f7f973f2642245bab3d028/src/Storages/MergeTree/MergeTreeReaderCompact.cpp#L256-L267),
[Advanced SharedData](https://github.com/ClickHouse/ClickHouse/blob/d9bcb5ab007f0f6299f7f973f2642245bab3d028/src/DataTypes/Serializations/SerializationObjectSharedData.cpp#L1550-L1766),
[ordinary JSON paths](https://github.com/ClickHouse/ClickHouse/blob/d9bcb5ab007f0f6299f7f973f2642245bab3d028/src/DataTypes/Serializations/SerializationObject.cpp#L1126-L1163).

The Copy storage route also serves full-document reads. For a named path,
Advanced SharedData can seek to the corresponding Data spans. At the query
plan level, eligible `LIMIT` queries carry row indexes through filtering or
sorting and fetch the deferred columns for the selected rows. The full
`id, doc` `readRows` schedule here retains every row.
[SharedData path selection](https://github.com/ClickHouse/ClickHouse/blob/d9bcb5ab007f0f6299f7f973f2642245bab3d028/src/DataTypes/Serializations/SerializationObjectSharedData.cpp#L1476-L1485),
[query-plan lazy materialization](https://github.com/ClickHouse/ClickHouse/blob/d9bcb5ab007f0f6299f7f973f2642245bab3d028/src/Processors/QueryPlan/Optimizations/optimizeLazyMaterialization.cpp#L748-L787).

At `87bf8da`, Crystal decoded each Copy value into a `BinaryValue`. The reader
independently decodes per-path Data into temporary Dynamic values and compares
exact types, values, and presence before yielding a batch. Ordinary typed and
Dynamic columns still construct per-value objects. The part plan reopens source
metadata and rehashes its authenticated frame set before delivering a batch. These
checks cover valid-checksum Copy/Data disagreements and in-place source
changes as well as failed compression checksums. Moving decode and comparison
to bound column buffers can reduce object churn while preserving these checks.
[Crystal Copy decoder](../src/crystal_click/object_shared_copy_codec.cr#L190-L246),
[Copy/Data check](../src/crystal_click/object_shared_advanced_chunk_codec.cr#L630-L697),
[source validation](../src/crystal_click/compact_static_json_advanced_part_plan.cr#L259-L283).

### Native compressed-frame coverage

An isolated ClickHouse 26.10.1.1201 server attached the exact two fixtures.
With `checksum_on_read=1` it selected one part and four marks per query. Each
ordered `id, toJSONString(doc)` RowBinary result matched the reference bytes.
The SQL profile counters below are query-wide. A single data reader appeared
in the thread log with `max_threads=4`. The
[direct `readRows` results](#direct-shareddata-columnar-results) provide the
previous worker-matched timing comparison.

| Compact part | Crystal `data.bin` blocks | Crystal inflated bytes | Native query blocks | Native query inflated bytes |
| --- | ---: | ---: | ---: | ---: |
| No overflow | 8 | 471,803 | 12 | 475,459 |
| SharedData overflow | 16 | 1,557,142 | 16 | 1,265,710 |

The frame headers and MRK4 substream offsets account for the difference. Each
overflow mark contains one full 73,772-byte inflated frame entirely inside
`doc.object_shared_data.1.data`. The other frame containing the end of Data
also contains Copy. Excluding only the four Data-only frames gives 12 blocks
and 1,262,054 inflated bytes from `data.bin`, a reduction of 295,088 bytes.
The remaining query-wide counters add the same four blocks, 3,494 compressed
bytes and 3,656 inflated bytes on both parts. Skipping Data therefore saves
deserialization and also avoids inflating those four whole frames in this
layout. Substream placement determines the physical savings.

On a disposable overflow part after open, flipping the checksum byte at
`data.bin[30030]` in the first Data-only frame left the native RowBinary and
compressed counters identical. Flipping `data.bin[0]` in the first retained
ID frame raised native checksum error 40. Crystal rejected the Data-only
mutation at both worker counts. The controls restored the original part
hashes. The native counters measure decoding of compressed blocks. An OS
buffered read can still cover the bytes of a skipped block.

### Instrumented stage counters

Use an isolated source copy for the diagnostic hooks. The `columnar` backend
accepts one or four workers. `none`, `first`, and `all` select 0, 1, or 4
marks. The full-window read and initial source validation happen during
part plan preparation. The source recheck timer includes that validation
and each validation after worker output. Checksums and LZ4 are nested within
those stages. Path timers live in individual worker slots. Use the slowest
worker per scan for elapsed stage comparisons and the sum for aggregate worker
work. Run the stock binary alongside the instrumented binary to measure the
effect of instrumentation on elapsed time.

```sh
mkdir "$bench_work/diagnostic-src"
git archive HEAD src benchmarks/compact_json_scan_probe.cr | tar -x -C "$bench_work/diagnostic-src"
python3 -B scripts/instrument_compact_json_probe.py "$bench_work/diagnostic-src"
TMPDIR="$bench_work/tmp" CRYSTAL_CACHE_DIR="$bench_work/cache" \
  crystal build --release -Dpreview_mt -Dexecution_context \
    -Dcompact_json_scan_diagnostic \
    "$bench_work/diagnostic-src/benchmarks/compact_json_scan_probe.cr" \
    -o "$bench_work/diagnostic-probe"

for bench_fixture in fixture overflow-fixture; do
  bench_part="$bench_work/$bench_fixture/0_1_1_0"
  python3 -B scripts/compact_json_scan_benchmark.py \
    --part "$bench_part" --oracle "$bench_part.rowbinary" \
    --crystal-bin "$bench_work/diagnostic-probe" --crystal-backend columnar \
    --baseline-crystal-bin "$bench_work/crystal-probe" --baseline-crystal-backend columnar \
    --scratch "$bench_work" --output "$bench_work/$bench_fixture-phases.json"
  for bench_workers in 1 4; do
    for bench_selection in none first; do
      "$bench_work/diagnostic-probe" columnar "$bench_part" \
        "$bench_part.rowbinary" "$bench_workers" "$bench_selection" retained 1 7
    done
  done
done
```

An empty result in Crystal still runs the whole-grid JSON validation. An empty
native schedule issues no `readRows` calls. For nonempty schedules, both
readers authenticate the frames they decode. The shared Crystal plan verifies
the authenticated source before releasing each retained batch.

### Baseline stage measurements

Both Crystal binaries were built from `87bf8da` using Crystal 1.22.3
Release, LLVM 23.1.5 and Boehm 8.2.12 on an Apple M2 Max. The full selections
used eight alternating blocks of two warmups and six timed scans. All 384
timed reads and 128 warmups matched ordered RowBinary, the assigned marks,
and the retained worker IDs. Eight post-open first-frame mutations failed
with checksum errors. The diagnostic runner also rejected an oracle of the
original length with one changed byte. The `none` and `first` controls each
used seven timed scans after one warmup per part and requested worker count.
These controls matched the corresponding RowBinary prefix.

| Compact part | Workers | Stock read p50 / p95, ms | Stock read + RowBinary p50 / p95, ms | Boehm read MiB / collections, p50 |
| --- | ---: | ---: | ---: | ---: |
| No overflow | 1 | 9.901 / 10.659 | 16.936 / 18.146 | 21.411 / 1 |
| No overflow | 4 | 17.395 / 19.813 | 24.492 / 28.021 | 21.420 / 1 |
| SharedData overflow | 1 | 36.780 / 39.005 | 54.874 / 59.746 | 92.269 / 2 |
| SharedData overflow | 4 | 76.629 / 81.539 | 95.032 / 101.230 | 92.286 / 2 |

Instrumented read medians moved by −0.58% to +2.05% across the paired cells.
Use these instrumented medians for stage attribution. The coordinator wait
includes active worker work. Its difference from the slowest worker's elapsed
time was 0.013–0.020 ms when comparing the cell medians.

| Compact part | Workers | Shared plan | Source checks | CityHash | LZ4 | Dispatch | Wait for worker results |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| No overflow | 1 | 2.631 | 0.963 | 0.123 | 0.132 | 0.003 | 6.694 |
| No overflow | 4 | 2.640 | 1.004 | 0.123 | 0.133 | 0.008 | 14.283 |
| SharedData overflow | 1 | 6.017 | 1.015 | 0.148 | 0.187 | 0.003 | 30.364 |
| SharedData overflow | 4 | 6.107 | 1.064 | 0.149 | 0.185 | 0.010 | 69.297 |

Times above are p50 in milliseconds, and the stages overlap. The part plan
includes LZ4 and the first source check. CityHash includes the initial frame
checks and the hashes inside all later source checks. The full scan validates
the source five times and rehashes 40 or 80 frames by fixture. Every selection
inflates the full 8 or 16 frames once. The empty selection took 3.04–3.47 ms
without overflow and 7.77–8.22 ms with overflow, with no value decoding on
the workers.

| Compact part | Workers | Slowest worker | Ordinary path decode | SharedData Copy decode | SharedData Data decode | Copy/Data equality |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| No overflow | 1 | 6.681 | 5.806 | 0.110 | 0 | 0 |
| No overflow | 4 | 14.267 | 13.801 | 0.028 | 0 | 0 |
| SharedData overflow | 1 | 30.344 | 8.241 | 5.289 | 12.277 | 3.415 |
| SharedData overflow | 4 | 69.279 | 6.682 | 17.520 | 42.127 | 1.914 |

Times are p50 in milliseconds from the slowest worker in each sample. Ordinary
path decode times exclude appending the values to the output. The overflow
case decodes and compares 24,576 SharedData cells across the part. The `first`
case has one active worker for either requested worker count. On overflow its
Data decode takes 4.20–4.25 ms for one mark and rises to 42.13 ms on the slowest
worker when four workers decode one mark each. The allocation volume across
all marks barely changes by worker count. The wait stacks show where much
of this concurrency cost lands. See the follow-up
[Dynamic substream binding results](#dynamic-substream-binding-results).

| Evidence | SHA-256 |
| --- | --- |
| Stock `87bf8da` Release runner | `7bb7195263ebc64a3e54b00748f53c60e0c4663075a5f74c2b9aaed4baf155db` |
| Stage diagnostic Release runner | `7129028350b16d92edf2fc145d8103d7317c82454ae7a9234caf5d90df52363d` |

### Overflow profile after Dynamic binding

The follow-up profiled `d0f23a3` on the same 8,192-row overflow part, with
the same `data.bin`, `data.mrk4`, and ordered RowBinary SHA-256 values as
the [binding comparison](#dynamic-substream-binding-results). Both runners
used Crystal 1.22.3 Release, LLVM 23.1.5, and Boehm 8.2.12 on the shared
Apple M2 Max host. Eight alternating blocks gave 48 timed scans and 16
warmups per runner and worker count. The driver verified exact RowBinary,
mark assignments, retained worker IDs, and the original part hashes.

| Workers | Stock read p50 / p95, ms | Stock read + RowBinary p50 / p95, ms | Read allocation p50 / p95, MiB | Read collections p50 / p95 |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 28.627 / 33.902 | 44.875 / 50.866 | 66.794 / 66.809 | 1 / 2 |
| 4 | 49.806 / 53.880 | 66.387 / 71.413 | 66.805 / 66.833 | 1 / 2 |

| Workers | Diagnostic read | Slowest worker | Ordinary path decode | SharedData Copy decode | SharedData Data decode | Copy/Data equality |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 29.203 / 37.735 | 21.659 / 29.360 | 7.700 / 13.524 | 5.443 / 7.833 | 3.426 / 5.958 | 3.275 / 5.471 |
| 4 | 50.037 / 56.331 | 42.977 / 48.339 | 14.610 / 21.026 | 18.437 / 21.870 | 7.620 / 10.634 | 1.831 / 2.622 |

Times are p50 / p95 in milliseconds. Stage timers report elapsed time for
the slowest worker in each scan, including allocator waits. Diagnostic read
p50 was 2.0% and 0.5% higher than stock and p95 was 11.3% and 4.5% higher
at one and four workers, respectively. Each diagnostic scan inflated 16 LZ4
frames, rechecked those frames five times, and decoded and compared 24,576
path rows. The `first` control used one active worker for either request, one
warmup, and seven timed scans. Copy medians were 2.871 and 2.894 ms. On
the same mark with all four workers active, Copy took 17.738 ms and Data
took 6.400 ms compared with 1.727 ms for Data in the four-worker `first`
control.

Three fresh two-second `/usr/bin/sample PID 2 1` captures per worker count
sampled the stock binary. Each runner completed two warmups and 24 checked
scans. The denominator counts stacks in
`ObjectDocumentCodec.decode_core_with_budget` on `compact-json-worker-*`
threads. The wait count uses a
`__psynch_mutexwait` leaf under a Boehm frame and the pthread mutex path.

| Workers | Decode stacks | Boehm mutex waits by capture | Boehm mutex waits, pooled | In a collection stack, pooled |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 1,315 | 2/441, 1/433, 2/441 | 5/1,315 (0.4%) | 130/1,315 (9.9%) |
| 4 | 9,974 | 2,155/3,157, 2,360/3,481, 2,267/3,336 | 6,782/9,974 (68.0%) | 162/9,974 (1.6%) |

At four workers, 6,625 mutex samples were under `GC_generic_malloc_many`,
the thread-local free-list refill. Of the 6,782 wait samples, 6,767 had no
collection frame on that thread. The visible Copy value decode frame
accounted for 3,213 waits, and the per-path Data decode frame for 1,107.
The stack counts measure thread occupancy. The elapsed stage timers include
time spent waiting. Relative to the earlier `87bf8da` profile, Data fell
from 42.127 to 7.620 ms at four workers across runs, and Copy had the
largest stage median in the new four-worker profile.

Both runners at both worker counts rejected post-open checksum mutations at
`data.bin[0]` and `data.bin[30030]` and a one-byte change to the same-length
RowBinary oracle. Thirteen focused Release examples in
[`object_shared_advanced_direct_columns_w263_spec.cr`](../spec/object_shared_advanced_direct_columns_w263_spec.cr)
and [`compact_shared_advanced_json_part_plan_spec.cr`](../spec/compact_shared_advanced_json_part_plan_spec.cr)
passed, covering valid but disagreeing Data streams, missing Copy cells,
and source changes between callbacks.

| Evidence | SHA-256 |
| --- | --- |
| Stock Release runner | `41ae3224113d20d36cfc640818b37070cd3c7892496791942823e3a00561ea49` |
| Diagnostic Release runner | `d3cdbac6a51496c12d6dd007ecc3eb2a39af56ec24ab27d8fc1c5fffd4875dab` |
| Matched timing report | `1ce3affc98a012679581b8b09f1e4eafbbe623cce5304e1049f65ca8f6cd5f13` |

### SharedData Copy String slices

The columnar reader borrows top-level primitive `String` payloads from the
prepared Copy values lane. It bounds each length prefix and payload by the
declared envelope, then compares presence, type, length and bytes with
the per-path Data before delivery. Other Copy types use the recursive codec.
`with_cell_at` exposes read-only bytes during the callback. `value_at` and
`snapshot` give the caller owned values. The prepared lane accounts for
the borrowed payload and the column accounts for the inline cell slot.

Both `columnar` runners read the same 8,192-row overflow part used in the
preceding profile. The `e2571d1` baseline and the updated build used Crystal
1.22.3 Release with `-Dpreview_mt -Dexecution_context`, LLVM 23.1.5, and
Boehm 8.2.12 on the shared Apple M2 Max host. The read timer includes plan
preparation, decoding, Copy/Data comparison and source checks. The combined
timer adds ordered RowBinary serialization. The updated serializer escapes
borrowed String bytes directly with the Crystal JSON builder. Both runners
reuse their worker threads within a block and verify the ClickHouse
26.10.1.1201 oracle after every sample.

Eight interleaved blocks used two warmups and six timed scans per build and
worker count. Each of the 192 timed scans matched the 1,922,070-byte
RowBinary oracle and the same four positive marks. Times and allocated
bytes are per scan. The read allocation counters include all workers.

| Workers | Read p50 / p95, ms before → after | Read + serialize p50 / p95, ms before → after | Boehm read allocation p50 / p95, MiB before → after | Boehm read collections p50 / p95 before → after |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 28.219 / 31.084 → 21.424 / 22.813 | 43.731 / 48.406 → 35.436 / 38.152 | 66.791 / 66.811 → 50.294 / 50.314 | 1 / 2 → 2 / 2 |
| 4 | 53.429 / 58.486 → 39.418 / 46.385 | 70.274 / 76.586 → 54.457 / 61.033 | 66.807 / 66.836 → 50.310 / 50.336 | 1 / 3 → 2 / 4 |

All eight block read medians improved at each worker count. The updated
read was faster in 48 of 48 matched pairs with one worker and 47 of 48
with four. Read allocation p50 fell 24.7% at each worker count. Allocation
p50 through serialization fell from 99.804 to 82.556 MiB with one worker
and from 99.821 to 82.573 MiB with four. The four-worker read median was
1.84 times the one-worker median after the change. The median of the
slowest worker's elapsed decode interval was 31.890 ms at four workers,
compared with 14.281 ms for one worker decoding all four marks. This probe
measures retained worker dispatch and one result per worker. The public
callback scan acknowledges each batch window separately.

A two-block control on the no-overflow fixture gave 12 scans per build
and worker count. Read allocation medians stayed within 0.003 MiB of
baseline. Read p50 / p95 moved from 9.499 / 10.259 to 9.413 / 9.809 ms at
one worker and from 18.384 / 21.264 to 18.641 / 20.509 ms at four. Combined
p50 rose from 25.367 to 25.933 ms at four workers. The short control has
mixed paired latency results on the shared host. The inline cell adds
16 bytes per slot even for owned values, and the workspace bound charges
the actual slot width.

Both builds at both worker counts rejected post-open checksum mutations
at `data.bin[0]` and `data.bin[30030]` on the overflow part, plus a one-byte
change to the same-length RowBinary oracle. All 30 focused Release examples
passed, including both ClickHouse fixture cases through the public callback
API. The specs cover unusual String bytes, a VarUInt truncated at the
envelope boundary, byte budgets, validly encoded Copy/Data type and payload
disagreements, retention across batch reuse, and source checks between
callbacks.

| Evidence | SHA-256 |
| --- | --- |
| `e2571d1` Release runner | `3621af0c8ee86833824bc2f316a37d4d603fe382c230b0303fbaf479f878b529` |
| Copy String slices Release runner | `913532d9165e055cece07ac46e40faeb7649a61b202b0fa794dd6325eab70493` |
| Matched overflow report | `9dd98f0eda1c324735c921f257e3770eb14a2c0a84e7bc328f8ca0a5abf68973` |
| No-overflow control report | `4cf8a41aede33d6fa9a694f62cd194dc38d6a7605ab906b3e8c91800ad662018` |

### Overflow profile after Copy String slices

The stock and stage-diagnostic Release runners used `05ee0c7` on the same
8,192-row overflow part and four 2,048-row marks as the preceding profile.
ClickHouse 26.10.1.1201 regenerated matching `data.bin`, `data.mrk4`, and
ordered `id, toJSONString(doc)` RowBinary SHA-256 values. Both runners used
Crystal 1.22.3, LLVM 23.1.5, and Boehm 8.2.12 on Apple M2 Max with macOS
26.6.2 and `-Dpreview_mt -Dexecution_context`.

Eight interleaved blocks gave 48 timed scans and 16 warmups per runner and
worker count. All 192 timed outputs matched the 1,922,070-byte RowBinary
oracle byte for byte. Read time includes part preparation, columnar decode,
Copy/Data comparison and source checks. The combined timer also includes
ordered RowBinary serialization. Verification of the serialized bytes follows
each sample. The allocation counters cover the read interval across the
whole process.

| Workers | Stock read p50 / p95, ms | Stock read + RowBinary p50 / p95, ms | Read allocation p50 / p95, MiB | Read collections p50 / p95 |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 23.107 / 26.456 | 37.990 / 43.895 | 50.291 / 50.313 | 1 / 2 |
| 4 | 40.569 / 53.668 | 55.883 / 69.400 | 50.313 / 50.342 | 1.5 / 4 |

| Workers | Diagnostic read | Slowest worker | Ordinary path decode | Copy decode | Data decode | Copy/Data equality |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 23.772 / 27.305 | 15.592 / 17.524 | 8.160 / 9.775 | 1.323 / 1.572 | 3.950 / 6.138 | 0.708 / 0.968 |
| 4 | 40.832 / 46.512 | 32.734 / 37.431 | 18.111 / 24.137 | 0.306 / 0.705 | 13.168 / 15.978 | 0.334 / 0.599 |

Stage times are p50 / p95 in milliseconds for the slowest worker in
each scan and include time waiting on the allocator. Percentiles across
stages describe separate distributions. Diagnostic read p50 was 2.9% above
stock with one worker and 0.6% above with four. The four-worker diagnostic
p95 was 13.3% lower than stock in this shared-host run. Use the stock read
series for latency comparisons and the diagnostic series to locate work.
Each diagnostic scan inflated 16 LZ4 frames, checked their source five
times, and decoded and compared 24,576 SharedData path rows.

Copy decode p50 moved from 18.437 to 0.306 ms on the slowest of four
workers across the two profiles. Data verification and ordinary decode
now dominate the worker's measured phases. Data decode includes the
path cursor setup and value construction. Ordinary decode includes
declared typed and promoted Dynamic paths. At four workers, the largest
ordinary path medians were `dynamic_flag` at 4.973 ms and `rank` at
4.625 ms. These phases include allocator waits, and the profile does not
attribute allocated bytes to individual paths.

The one-mark `first` control used one active worker for either request
count and matched the first 479,497 bytes of the full oracle. With four
workers requested, seven control scans gave Copy, Data, and ordinary
decode medians of 0.296, 1.435, and 2.362 ms. Worker 0 processed the same
mark in the four-active-worker run at 0.304, 11.661, and 18.955 ms,
respectively. The control compares the same logical mark with one or four
workers active. It uses a separate timing series on the shared host.

Three fresh two-second `/usr/bin/sample PID 2 1 -file FILE` captures per
worker count sampled the stock binary. Each runner completed two warmups
and 24 checked scans. Counts use exclusive stack weights on named
`compact-json-worker-*` threads under
`ObjectDocumentCodec.decode_core_with_budget`. A Boehm wait is a
`__psynch_mutexwait` leaf with pthread mutex and libgc ancestors.

| Workers | Decode stacks | Boehm mutex waits by capture | Boehm mutex waits, pooled | In a collection stack, pooled |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 891 | 1/293, 3/288, 7/310 | 11/891 (1.2%) | 138/891 (15.5%) |
| 4 | 4,970 | 1,091/1,652, 1,032/1,505, 1,228/1,813 | 3,351/4,970 (67.4%) | 136/4,970 (2.7%) |

At four workers, 3,098 of the 3,351 waits were under
`GC_generic_malloc_many`, the thread-local free-list refill. One wait
included a collection frame. Visible Data decoder frames accounted for
1,568 waits, ordinary decode frames for 793, and Copy decoder frames for
two. Inlining leaves some stacks without a visible owning stage. These
percentages describe sampled worker occupancy. The stock read median and
p95 were 1.76 and 2.03 times the one-worker times.
[Boehm free-list refill](https://github.com/bdwgc/bdwgc/blob/v8.2.12/include/gc_inline.h#L87-L104).

Both runners at both worker counts rejected post-open checksum mutations
at `data.bin[0]` and at `data.bin[30030]` in a Data-only frame, and
rejected a one-byte change to the same-length RowBinary oracle. The
original part hashes were restored after each mutation. All 19 focused
Release examples passed, including validly encoded Copy/Data type and
payload disagreements, absent Copy cells, and source validation between
split-batch callbacks.
[Direct column checks](../spec/object_shared_advanced_direct_columns_w263_spec.cr),
[part plan checks](../spec/compact_shared_advanced_json_part_plan_spec.cr).

The first candidate to measure is a checked Data cursor for scalar
`String` arms. Consume discriminators and sizes in row order and compare
borrowed Data bytes with the existing Copy cells before delivery. This can
remove temporary Dynamic wrappers, child arrays, and String payload copies.
Keep exact presence, type, budget, and source validation and use the
recursive decoder for other layouts. If a path needs reusable scratch,
store row or type indexes, byte offsets, and lengths in a bounded
worker-local array of structs. Keep the prepared lane alive while borrowing
bytes from it.
[Data verification](../src/crystal_click/object_shared_advanced_chunk_codec.cr#L630-L735),
[Data path decoder](../src/crystal_click/object_shared_path_codec.cr#L241-L343).

Ordinary fields have the largest remaining phase on this fixture. Start
with the `Nullable(UInt32)` `rank` path and scalar arms of `dynamic_flag`.
Write primitive values, presence bits, and type tags into reusable column
buffers. The existing Copy cell already stores a struct inline, and
the field column already reuses its backing arrays. Removing the
per-occurrence `BinaryValue` and its owned payloads targets the remaining
allocation hot path. Measure allocated bytes and four-worker read p95
against the same marks and verification again after each change.
[Ordinary decode and column append](../src/crystal_click/object_document_codec.cr#L1049-L1120),
[columnar cells](../src/crystal_click/compact_json_columnar_cell.cr#L5-L16).

| Evidence | SHA-256 |
| --- | --- |
| Stock Release runner | `61160c1bc5b32bcc13b508c891de1a184b4563378bb510ba1f8cfabffd97b896` |
| Diagnostic Release runner | `86456a7e0370e3eb7bc681499f93d197ba4a5cbf27f4c8ca18ba34469121b773` |
| Matched timing report | `fbdb2dcc96929acdb217a712f216dca86de88b4785ee0f37dc67170fa581f9a6` |

### SharedData Data String slices

The columnar verifier reads exact Dynamic `String` values as read-only
slices of the normalized Data lanes. It compares presence, type, and bytes
with the retained Copy cells before the batch callback. For these values,
it constructs neither an owned String `BinaryValue` nor a Dynamic wrapper.
Both the ordinary String arm and exact String inside SharedVariant use
the existing tape reader, length checks, and codec accounting. All other
actuals keep the recursive value decoder. The comparison result holds its
lane owner until verification completes. It charges the actual size of
the temporary row slots to the columnar workspace budget.
[Data verifier](../src/crystal_click/object_shared_advanced_chunk_codec.cr),
[Dynamic decoder](../src/crystal_click/binary_bulk_decoder.cr).

The measured Compact part carries 8,192 rows across four positive marks.
The three overflow paths on each mark all use ordinary sized String
streams, for 24,576 values. The SharedVariant String branch is exercised
by a separate spec. The baseline `05ee0c7` has the same production code
as `1d9375e`. Both stock columnar runners use Crystal 1.22.3 Release,
LLVM 23.1.5, and Boehm 8.2.12 on Apple M2 Max with macOS 26.6.2.

In each cell the retained runners alternated within eight blocks, with
two warmups and six timed scans per build per block. The read includes
part-plan preparation, decode, and source checks. The combined measurement
adds RowBinary serialization. All 192 timed outputs matched the ordered
ClickHouse RowBinary export byte for byte. Background jobs remained active
on the host.

| Workers | Read p50 / p95, ms before → after | Boehm read allocations p50 / p95, MiB before → after | Read + serialize p50 / p95, ms before → after |
| ---: | ---: | ---: | ---: |
| 1 | 20.988 / 24.511 → 18.945 / 23.606 | 50.290 / 50.315 → 39.929 / 39.947 | 34.081 / 38.365 → 34.199 / 41.853 |
| 4 | 35.743 / 42.430 → 26.101 / 29.555 | 50.305 / 50.332 → 39.947 / 39.977 | 49.114 / 57.647 → 40.513 / 45.268 |

The candidate read faster in 42 of 48 pairs at one worker and in all
48 at four workers. Read allocations fell by 20.6% at both worker counts.
The median number of collections during the read was 2 → 3 at one worker
and 2 → 1 at four. The four-worker read median fell from 1.70× to 1.38×
the one-worker median. With serialization included, p95 rose 9.1% at
one worker and fell 21.5% at four workers.

Three separate `/usr/bin/sample PID 2 1 -file FILE` captures per build and
worker count used fresh retained runners. Each runner completed two warmups
before launching the sampler and issued 24 RowBinary-checked scans while
the sampler was alive. The denominator counts samples on named
`compact-json-worker-*` threads in
`ObjectDocumentCodec.decode_core_with_budget`. A mutex wait has a
`__psynch_mutexwait` leaf and both pthread mutex and Boehm frames.

| Workers | Boehm mutex waits / decode samples before → after | Waits in free-list refill before → after | Waits with a visible Data decoder frame before → after |
| ---: | ---: | ---: | ---: |
| 1 | 7/596 (1.2%) → 12/618 (1.9%) | 7 → 12 | 2 → 0 |
| 4 | 4,623/6,416 (72.1%) → 3,283/4,744 (69.2%) | 4,445 → 3,184 | 1,783 → 38 |

The percentages describe sampled worker occupancy. At four workers, 97.0%
of the remaining mutex samples include `GC_generic_malloc_many`, which
refills the thread-local free list. Four of the 3,283 remaining mutex
samples include a collection frame. Data attribution requires a visible
path decoder frame, so inlining can affect that count.

At both worker counts, both stock runners rejected post-open mutations
at `data.bin[0]` and `data.bin[30030]`, the latter in a Data-only frame.
They also rejected an otherwise identical RowBinary oracle with one
byte changed. The part and oracle used for measurement match their
original hashes.

The grouped Release run passed all 50 examples with both native
fixtures enabled. The direct SharedData checks reject valid Data whose
type or value disagrees with Copy, and reject nonminimal VarUInt and
trailing bytes in the SharedVariant String envelope. The mixed ordinary
String, UInt64, and absent rows match the baseline codec budget counters.
[Direct SharedData checks](../spec/object_shared_advanced_direct_columns_w263_spec.cr),
[callback checks](../spec/compact_shared_advanced_json_columnar_spec.cr).

| Evidence | SHA-256 |
| --- | --- |
| `05ee0c7` stock Release runner | `d9e327f5c2461aa6dcd22f5f60c526d052e2cddb1b1a3eaa9b21c6a13964804b` |
| Data slice stock Release runner | `bc42a9a62e54d95495cda992d9237ce802b76b2f9050546cb5c3a1ba0427190c` |
| Matched timing report | `b2815f8bbd17b6a02ef51aab9710076f751245e05b5bc750d6bbdce1c27aaebd` |
| Twelve raw stack profile checksums, sorted by capture path | `1d8e435f9aee30901da15fdb7f7bc08366871d8a53777264cbe3b41ce21dfa40` |
| Twelve rejection controls report | `78ea633a9d9cd1acf6e1da9fe078476532a5cc635b19eda3a6aea7983731c36c` |
| Ordered ClickHouse RowBinary export | `3495978197741a4e241a2201bd92030afbb7590588bccb2ab3da107b1059d62b` |

### Declared Nullable(UInt32) slices

The columnar scan decodes declared `Nullable(UInt32)` paths such as `rank`
into reusable `Slice(UInt32)` values and a byte-per-row NULL map. It consumes
the physical payload even where the map is `1`. The direct decoder uses the
same role and mark grid validation and charges the same nodes, elements, and
wire bytes as recursive Bulk decoding. Both slices expose the active callback
window. A snapshot copies that window into its own buffers, and callers can
still materialize individual cells through `value_at`.
[Direct decoder](../src/crystal_click/binary_bulk_decoder.cr),
[callback API](COMPACT_TYPED_READER_FRONTIER.md#borrowed-columnar-json-batches).

The stock `04b421f` and slice runners use the same retained worker schedule on
the four-mark, 8,192-row SharedData overflow fixture. Both use Crystal 1.22.3
Release, LLVM 23.1.5 and Boehm 8.2.12 on an Apple M2 Max with macOS 26.6.2.
Each build and worker count contributed 48 timed scans across eight
interleaved blocks, with two warmups per build per block. The probe retains
one output arena per assigned mark for ordered serialization. Read time
includes the complete part plan and source checks. The combined measurement
adds RowBinary serialization, which reads `rank` through the new typed views
on the slice runner. All 192 timed results matched the ClickHouse
26.10.1.1201 RowBinary export byte for byte. Background jobs remained active
on the host.

| Workers | Read p50 / p95, ms before → after | Boehm read allocations p50 / p95, MiB before → after | Read + serialize p50 / p95, ms before → after |
| ---: | ---: | ---: | ---: |
| 1 | 19.616 / 22.059 → 16.627 / 19.340 | 39.927 / 39.949 → 35.600 / 35.621 | 35.341 / 42.840 → 30.693 / 36.419 |
| 4 | 26.659 / 29.984 → 21.934 / 25.546 | 39.945 / 39.977 → 35.614 / 35.641 | 42.207 / 48.111 → 36.432 / 42.390 |

The slice runner read faster in 45 of 48 pairs at one worker and in 44 of
48 at four. Median observed read allocation fell 4.33 MiB, or 10.8%, at
both worker counts. The four-worker read median was 1.32× the one-worker
median on this part.

Three fresh `/usr/bin/sample PID 2 1 -file FILE` captures per build and worker
count issued 24 RowBinary-checked scans each after two warmups. Count only
decode samples on named `compact-json-worker-*` threads with an
`ObjectDocumentCodec.decode_core_with_budget` frame. A Boehm mutex wait
has a kernel `__psynch_mutexwait` leaf with pthread mutex and Boehm frames.

| Workers | Boehm mutex waits / decode samples before → after | Waits in free-list refill before → after |
| ---: | ---: | ---: |
| 1 | 15/711 (2.1%) → 4/608 (0.7%) | 14 → 4 |
| 4 | 3,379/4,929 (68.6%) → 2,534/3,769 (67.2%) | 3,278 → 2,440 |

These proportions describe sampled worker occupancy. At four workers,
96.3% of the remaining Boehm mutex samples have a `GC_generic_malloc_many`
frame, which refills the thread-local free list.

Both builds rejected mutations at `data.bin[0]` and `data.bin[30030]`
after opening the part, including the Data-only frame at offset 30030.
Both also rejected a same-length RowBinary oracle with one byte changed.
These twelve rejection controls used disposable copies.

The grouped Release suite passed all 54 examples with both native fixtures.
The direct decoder matched recursive values and budget counters, including
consumption of a nonzero nested payload under NULL. The tests cover malformed
lanes, read-only split views, buffer reuse, detached snapshots, and rejection
of Copy/Data disagreements in value, type, and presence.
[Columnar scan and lane checks](../spec/compact_shared_advanced_json_columnar_spec.cr),
[Direct SharedData checks](../spec/object_shared_advanced_direct_columns_w263_spec.cr).

| Evidence | SHA-256 |
| --- | --- |
| `04b421f` stock Release runner | `92bf8899fdbe712cd990baf37321e000a499b7dc3d83a45f66aed018095281c8` |
| Declared `Nullable(UInt32)` slice runner | `b54ccef5679ac17ca1df3f2831835c05695cfa37ad32b99e0c0b84b7cbc71c95` |
| Matched timing report | `a828e1cd7f914c78b968affa18906fedf8338c7ccfbd51d106c421a5021e35e7` |
| Newline-separated raw stack profile checksums, sorted by capture path | `4487b1e6a7f481ba24bf919d12aa79960c28678dd170c30f62d28454bcd42d47` |
| Twelve rejection controls report | `6c5eacc0554d130263c33d2502738478575762884c77afbf678f210f5034f3ca` |
| Grouped Release spec output | `1aeee0eae56b4cc234baf45690a23ac1a4e2cce711d0c370d629ec77b3ab04d5` |
| Ordered ClickHouse RowBinary export | `3495978197741a4e241a2201bd92030afbb7590588bccb2ab3da107b1059d62b` |

### Ordinary scalar cursors and Bool storage

The bulk decoder binds each ordinary scalar root's data and optional
String sizes cursors once per nonempty mark. Decoded Bool values reuse
the validated type descriptor and the canonical read-only byte for
their value. Each cell keeps its own `BinaryValue` identity, and
`bytes` returns a detached copy. Stream extent checks and codec budget
receipts are preserved.
[Bulk decoder](../src/crystal_click/binary_bulk_decoder.cr),
[scalar regression checks](../spec/binary_bulk_w122_spec.cr).

The matched Release comparison against `76e0f24` uses the same four
marks, 8,192 rows, and retained worker schedule on the SharedData overflow
part, with Crystal 1.22.3, LLVM 23.1.5, and Boehm 8.2.12 on an Apple M2
Max with macOS 26.6.2. The data, marks, and ordered RowBinary export match
the earlier overflow fixture hashes. Each build and worker count contributed
48 timed scans across eight interleaved blocks with two warmups per build
per block. Read time includes preparing the authenticated part plan and
validating source checksums between batches. All 192 timed scans matched
the ordered ClickHouse 26.10.1.1201 RowBinary export byte for byte.

| Workers | Read p50 / p95, ms before → after | Boehm read allocations p50 / p95, MiB before → after | Read + serialize p50 / p95, ms before → after |
| ---: | ---: | ---: | ---: |
| 1 | 16.030 / 17.447 → 13.462 / 14.659 | 35.598 / 35.623 → 29.973 / 29.991 | 29.431 / 32.595 → 26.120 / 28.349 |
| 4 | 23.505 / 32.474 → 15.957 / 19.882 | 35.616 / 35.638 → 29.987 / 30.025 | 36.952 / 45.886 → 29.004 / 34.313 |

Read time improved in all 48 pairs at both worker counts. Median Boehm
read allocation fell about 15.8%. The four-worker read median was 1.19×
the one-worker median on this part, compared with 1.47× before the change.
Median read collections stayed at one per scan at both worker counts.

The stack profile interleaves three fresh captures per build and worker
count. Each uses `sample PID 2 1` after two warmups and sends 24 scans
after the sampler announces startup. The retained readers check every
scan against RowBinary. Only `compact-json-worker-*` stacks under
`ObjectDocumentCodec.decode_core_with_budget` count toward decode samples.
Mutex samples have a kernel `__psynch_mutexwait` leaf below pthread
mutex and Boehm frames.

| Workers | Boehm mutex waits / decode samples before → after | Waits in free-list refill before → after |
| ---: | ---: | ---: |
| 1 | 14/534 (2.6%) → 4/380 (1.1%) | 14 → 4 |
| 4 | 2,633/3,892 (67.7%) → 1,315/2,001 (65.7%) | 2,523 → 1,191 |

At four workers, Bool descriptor construction accounted for 620 baseline
wait samples. The per-row String and scalar role interpolation helpers
accounted for 410. Both signatures fell to zero in the updated captures.
There were 972 remaining wait samples with a direct
`BinaryValue.new` caller in bulk decode and 179 under the validated
Bool factory. These counts describe sampled worker occupancy for equal
scan workloads. The timing comparison measures elapsed time separately.

Both builds rejected post-open checksum corruption at `data.bin[0]` and
at `data.bin[30030]`, which belongs to a Data-only frame. Both also rejected
a same-length RowBinary oracle with one changed byte at each worker count.
All twelve controls used disposable copies, and the measured part and
oracle still matched their original hashes.

All 60 grouped Release examples passed with both native fixtures enabled.
The suite checks Copy/Data disagreement in value, type, and presence, and
the new scalar tests cover exact budgets, selected mark windows, malformed
lanes, canonical Bool bytes, and detached byte access. On `76e0f24`, the
focused suite failed only at the new assertion for Bool descriptor reuse.

| Evidence | SHA-256 |
| --- | --- |
| `76e0f24` stock Release runner | `478a232e9dbbf4a47c7c58009169ee101f5d45c6434562515002dcbd17463862` |
| Bound scalar Release runner | `2d41aa08e9ee177f23d60c6f9462d6d8ae73ed352573cad2fd756f5385b8c858` |
| Matched timing report | `2dbd0ffc6e80275feccb32ec5f8034d91595f2f3737b5632753f564e17c9e28f` |
| Newline-separated raw stack profile checksums, sorted by capture path | `8e90a431108204af6e261cdca376af89159273423acb2394b6360cc8bdd1de08` |
| Twelve rejection controls report | `6e2c4603fcca661bd68859d48c0ec814f1234cf9bc74d522996a3a9c36c4adc0` |
| Grouped Release spec output | `58303ce8638124c6b893d2d0161cd70139fe48c2e3479605ecbb5266552df1f0` |
| Ordered ClickHouse RowBinary export | `3495978197741a4e241a2201bd92030afbb7590588bccb2ab3da107b1059d62b` |

### Filter-first Advanced root JSON scan

The eager route prepares and decodes all four marks and evaluates the
predicate on the decoded UInt64 companion. The filter-first route reads
that companion first, retains the matching offsets, and prepares and
decodes only the JSON marks with matches. Both decode a full JSON mark
whenever the route visits it. Both verify the frame checksums and compare
SharedData Copy and Data for the JSON they decode.

The main comparison returns 2,048 rows per scan under two predicates.
The range `2048 <= id < 4096` leaves one mark, while `id % 4 == 0`
leaves matches in all four marks. An empty result and an unfiltered
result also exercise the endpoints. The reference is the ordered native
RowBinary export filtered using the same UInt64 predicate.

The retained probe runs both routes on the same part reader in each block.
Both routes keep worker threads and output buffers warm and build a fresh
authenticated plan per scan. The read interval includes the predicate,
source capture and decoding, worker dispatch and collection, and the
source recheck before each mark is delivered. Measure RowBinary serialization
after the read interval and compare every result byte-for-byte with the
ClickHouse export. Each cell uses eight blocks of six measured pairs with two
warm-up pairs per block and alternating route order. Report the sample median
and nearest-rank p95. The latency build uses Crystal 1.22.3 and LLVM 23.1.5 in
Release with Boehm enabled on an Apple M2 Max running macOS 26.6.2.

| Predicate | Matching rows | Requested workers | JSON marks after filtering | Eager p50 / p95 (ms) | Filter-first p50 / p95 (ms) | LZ4 frames, eager → filter-first |
|---|---:|---:|---:|---:|---:|---:|
| Empty | 0 | 1 | 0 | 15.938 / 17.928 | 0.639 / 0.911 | 16 → 4 |
| Empty | 0 | 4 | 0 | 16.503 / 25.651 | 0.639 / 1.331 | 16 → 4 |
| One mark | 2,048 | 1 | 1 | 14.581 / 15.795 | 3.941 / 5.143 | 16 → 7 |
| One mark | 2,048 | 4 | 1 | 17.013 / 18.661 | 5.166 / 5.801 | 16 → 7 |
| Spread across marks | 2,048 | 1 | 4 | 14.549 / 19.171 | 14.749 / 16.511 | 16 → 16 |
| Spread across marks | 2,048 | 4 | 4 | 17.649 / 21.976 | 17.821 / 20.169 | 16 → 16 |
| All rows | 8,192 | 1 | 4 | 13.855 / 14.830 | 14.139 / 15.012 | 16 → 16 |
| All rows | 8,192 | 4 | 4 | 15.873 / 18.561 | 16.283 / 18.354 | 16 → 16 |

The one-mark case reduced read p95 by 67.4% and 68.9% and won all 48 pairs
at each worker count. It used one active JSON worker at both settings.
When every mark survived, the filter-first route raised the median by
1.0–2.6% on this part. The p95 difference for the spread predicate changed sign
between runs. Each of the four key frames is separate from the three JSON
frames per mark on this fixture. The separate diagnostic build counts
completed LZ4 calls across the read interval, including plan preparation.

Every timed pair matched the independently filtered ClickHouse 26.10.1.1201
RowBinary bytes. The native controls also rejected a touched frame with a bad
checksum and a Copy/Data disagreement with a newly valid checksum. Both
controls ran with one and four requested workers. The Copy/Data control
preserved the original MRK4 coordinates and rejected before the first batch.

| Evidence from this run | SHA-256 |
|---|---|
| Stock timing probe | `87b921037426955437eaa166b73ab80304847f13296477ba399ed574b613c85e` |
| LZ4 diagnostic probe | `cdb4f1960cef39425b3d855f162e78af55e307f0043550107aac8cd24592bca5` |
| Raw report with 768 timed samples and 16 diagnostic entries | `07667da5d3bee9189f83f31964a8c1c2eb707c8376d45089b71e0d5c28d3fdb0` |
| Grouped Release output | `59acebf49033143aff0cbf3d0e3836d359ce8d7687d768683981674522a201ed` |

Generate the `overflow-fixture` with the ClickHouse binary and
`--shared-overflow` from [Reproduction](#reproduction). The filter driver
pins the `data.bin`, `.mrk4`, and RowBinary hashes from that fixture. Build
the regular probe and a separate copy with the frame decode counter.

```sh
TMPDIR="$bench_work/tmp" CRYSTAL_CACHE_DIR="$bench_work/cache" \
  crystal build --release -Dpreview_mt -Dexecution_context \
    benchmarks/compact_json_filter_scan_probe.cr -o "$bench_work/filter-probe"

mkdir "$bench_work/filter-diagnostic-src" "$bench_work/filter-run"
git archive HEAD src benchmarks/compact_json_filter_scan_probe.cr \
  scripts/support/compact_physical_context_w259_fixture.cr | \
  tar -x -C "$bench_work/filter-diagnostic-src"
python3 -B scripts/instrument_compact_json_probe.py \
  "$bench_work/filter-diagnostic-src" --lz4-only
TMPDIR="$bench_work/tmp" CRYSTAL_CACHE_DIR="$bench_work/cache" \
  crystal build --release -Dpreview_mt -Dexecution_context \
    -Dcompact_json_scan_diagnostic \
    "$bench_work/filter-diagnostic-src/benchmarks/compact_json_filter_scan_probe.cr" \
    -o "$bench_work/filter-diagnostic-probe"

bench_part="$bench_work/overflow-fixture/0_1_1_0"
python3 -B scripts/compact_json_filter_scan_benchmark.py \
  --part "$bench_part" --oracle "$bench_part.rowbinary" \
  --probe "$bench_work/filter-probe" \
  --diagnostic-probe "$bench_work/filter-diagnostic-probe" \
  --scratch "$bench_work/filter-run" --output "$bench_work/filter-report.json"
```

The grouped Release check also includes the prepared part-plan, physical
capture, and transport regression controls. Set `bench_work` to the fixture
root containing both `fixture` and `overflow-fixture`.

```sh
CRYSTAL_CLICK_COLUMNAR_JSON_FIXTURE_ROOT="$bench_work" \
  TMPDIR="$bench_work/tmp" CRYSTAL_CACHE_DIR="$bench_work/cache" \
  crystal spec --release -Dpreview_mt -Dexecution_context \
    spec/compact_shared_advanced_json_columnar_spec.cr \
    spec/compact_shared_advanced_json_part_plan_spec.cr \
    spec/compact_part_physical_window_capture_spec.cr \
    spec/compact_physical_context_w259_spec.cr \
    spec/compact_physical_context_w259_adversary_spec.cr \
    spec/object_shared_advanced_direct_columns_w263_spec.cr \
    spec/binary_dynamic_bulk_values_w155_spec.cr \
    spec/binary_dynamic_bulk_shared_context_w155_spec.cr \
    spec/binary_bulk_w122_spec.cr
```

### Previous shared-plan diagnostics

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
