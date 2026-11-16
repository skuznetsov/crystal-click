# ClickHouse readRows profile mode

The profile mode adds narrow operation timers to the pinned ClickHouse source
used by this benchmark. Keep the pristine `clickhouse-read-rows` build for
control runs. Enable this mode only in a separate profiling build.

Use a disposable ClickHouse checkout pinned to
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`. Check and apply the profile patch
with the commands below.

```sh
python3 -B benchmarks/clickhouse_read_rows/apply_profile_patch.py --check-only "$CH_SOURCE"
python3 -B benchmarks/clickhouse_read_rows/apply_profile_patch.py "$CH_SOURCE"
```

Configure that ClickHouse checkout with
`-DCLICKHOUSE_READ_ROWS_PROFILE=ON`. The option is off by default. It enables
the profile fields in this runner and adds the definition only to the five
instrumented ClickHouse translation units.

## Field semantics

- `profile.launch_ns` times creating the worker threads. `join_ns` times the
  joins. These intervals can overlap worker envelopes.
- Each worker's `index` matches the same position in `worker_marks`.
  `start_ns` and `end_ns` are offsets from the outer
  `elapsed_ns` start. They enclose thread status setup and destruction, the
  read loop, ordered-output copies, and reader reset.
- `transport_ns` and `transport_calls` cover each `pread` syscall in
  `ReadBufferFromFileDescriptor::readImpl`. `transport_bytes` sums positive
  syscall return values, including frame headers, checksums, and buffer
  over-read.
- `checksum_ns` times only ClickHouse's `CityHash128` call. The checksum
  comparison is outside that timer.
- `lz4_ns` times only the `LZ4::decompress` call. `lz4_calls` counts those
  calls.
- `materialize_copy_ns` covers `CompressedReadBufferFromFile::readBig` copies
  from an existing decoded buffer into the UInt64 destination. A copy is
  timed only when the requested bytes fit in the current buffer, so it cannot
  refill or include nested I/O, checksum, or decompression work. Its byte and
  call counters report only those measured copies.
- `direct_decode_calls` and `direct_decode_bytes` count the readBig path that
  decompresses straight into the UInt64 destination. They are counters rather
  than a time because decoder time is already reported by `lz4_ns`.
- `output_copy_ns` times the two benchmark `memcpy` calls that copy each mark
  from worker-local UInt64 columns into the ordered result arrays.
- `open_ns` and `close_ns` time the actual `OpenedFile::open` and
  `OpenedFile::close` syscalls used by the cached-pread path. Descriptor-cache
  hashing, locking, allocation, and reference-counting are outside these
  timers. `fstat_ns` times the descriptor-size query wrapper in
  `tryGetFileSize` and the direct seekability `fstat`. `io_lifecycle_ns` is
  the sum of open, fstat, and close timers.

Worker intervals can overlap across threads. The outer elapsed interval also
includes control flow and other reader work. Use uninstrumented binaries for
wall-time comparisons and the profile for stage attribution.
