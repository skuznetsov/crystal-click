# UInt64 Slab Vector Implementation Plan

Status: **COMPLETED + VERIFIED** for the bounded standalone,
non-concurrent, callback-scoped and synthetic benchmark slice. Final
adversary verdict: **ROBUST** within that scope.

Plan risk: **CAUTION** — this adds a public container, uses GC-managed raw
pointers, and defines a borrowed read-only callback lifetime.

Rollback: revert one coherent source/spec/benchmark/docs change. Preserve
unrelated working-tree changes. No staging or commit is part of this update.

## Observed definition of done

The initial RED was the missing `UInt64SlabVector` constant/method. After
implementation:

- Focused spec: **8/0** in debug and release.
- Full repository suite: **84/0** in debug and release.
- Benchmark smoke: 10,003 rows, checksum `17327423495062737796`, and slab
  geometry `3/12288/1024` (`slab_count/capacity/directory_capacity`).
- Controlled unsandboxed release benchmark: 10,000,000 rows, 7 repetitions,
  scratch 4096, shifts 10/12/14, separate subprocess per track, checksum
  `4410372177809615872` for every track, and RSS available.

The first adversary review was **VULNERABLE** because a negative-sized
`Slice(UInt64)` was silently accepted. The implementation now rejects negative
slice sizes before dereference and uses overlap-safe `move_from` for bulk
copies. The final adversary review is **ROBUST** within the declared
standalone, non-concurrent, callback-scoped and synthetic benchmark scope.

## Completed steps

### 1. RED spec and consumer inventory — completed

Paths: `spec/uint64_slab_vector_spec.cr`,
`src/crystal_click/uint64_slab_vector.cr`, and
`src/crystal_click.cr`.

The focused spec was established before the source existed and produced the
expected undefined constant/method RED. It now covers defaults, shifts 4..20,
positive directory capacity, lazy empty operations, append and slab-boundary
ordering, directory growth beyond 1024 descriptors, checked indexing, scalar
iteration, read-only chunks, GC reachability, explicit owning `to_a`, and the
negative-sized-slice regression.

Adversary result: the negative-sized `Slice(UInt64)` case exposed a real
pointer-safety bug. The guard and overlap-safe copy are now covered; the final
adversary review is **ROBUST** within the declared scope.

### 2. Geometry, directory, and GC ownership — completed

Path: `src/crystal_click/uint64_slab_vector.cr`.

Implemented fixed geometry and getters: default shift 12, size 4096, mask
4095, safe shifts 4..20, and positive `initial_directory_capacity`. The
directory is `Array(SlabRef)` with manually tracked exact capacity, zero live
entries initially, default reservation 1024, growth beyond 1024, and a
`1 << 20` maximum initial-capacity guard. On a 64-bit host the default
descriptor reservation is about 16 KiB and the guarded maximum about 16 MiB;
neither allocates data slabs.

Each actual slab uses `Pointer(UInt64).malloc(slab_size)` and remains
GC-managed. `SlabRef` retains the pointer and finalized used count, while the
active tail pointer/index/used count is cached separately. Size, slab count,
capacity, and directory-growth arithmetic are checked.

Verification: constructor, lazy-allocation, GC, and >1024-descriptor cases
pass in the focused 8/0 gate and full 84/0 gates.

### 3. Append, concat, checked access, and iteration — completed

Path: `src/crystal_click/uint64_slab_vector.cr`.

Implemented `push`, `<<`, `concat(Slice(UInt64))`, checked `[]`, `each`, and
explicit `to_a`. Actual append is the only data-slab allocation trigger.
Values remain ordered across full and partial slabs; `to_a` is an owning copy.
Bulk concatenation uses overlap-safe `move_from`.

Verification: focused and full debug/release suites pass, including exact
boundary samples and independent-array parity.

### 4. Borrowed read-only chunks — completed

Path: `src/crystal_click/uint64_slab_vector.cr` and the focused spec.

`each_chunk` yields non-empty, read-only slices over used slab portions. The
slice is valid only during its callback; the vector does not retain it. No
concurrent or reentrant mutation guarantee is added.

Verification: chunk order, sizes, read-only status, partial tail behavior,
and GC reachability pass in focused and full debug/release gates.

### 5. Controlled release benchmark — completed for synthetic input

Paths: `benchmarks/uint64_slab_vector.cr` and
`scripts/bench_uint64_slab_vector.sh`.

Tracks are Array-direct, Array-stream-control, Slab-stream, and Slice-sink.
The runner builds release code, runs each track in a separate process, checks
rows and a deterministic checksum, and records elapsed time, GC bytes/cycles,
and `/usr/bin/time -l` RSS when available.

Aggregate medians from the controlled run:

| Track | n | Median | P95 | GC bytes | Peak RSS | GC cycles |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Array-direct | 21 | 33.461 ms | 38.039 ms | 412.656 MiB | 175.594 MiB | 8 |
| Array-stream-control | 21 | 37.198 ms | 41.640 ms | 412.344 MiB | 175.641 MiB | 8 |
| Slab-stream, shift 10 | 7 | 30.935 ms | 50.423 ms | 76.915 MiB | 121.406 MiB | 16 |
| Slab-stream, shift 12 | 7 | 25.101 ms | 27.660 ms | 76.444 MiB | 90.234 MiB | 15 |
| Slab-stream, shift 14 | 7 | 23.974 ms | 24.975 ms | 76.384 MiB | 82.484 MiB | 14 |
| Slice-sink | 21 | 15.063 ms | 16.874 ms | 0 MiB | 3.219 MiB | 0 |

Shift 14 was best by median here; shift 10 had an unstable/high P95; default
shift 12 was solid. This is synthetic container-ingestion evidence only.
It is not evidence for a ClickHouse reader, codec reuse, or general speedup;
the non-owning Slice-sink is not directly comparable to owning tracks.

### 6. Closure — completed + VERIFIED

Correctness and controlled benchmark evidence are recorded above. The final
adversary review after the negative-slice fix is **ROBUST** within the declared
standalone, non-concurrent, callback-scoped and synthetic benchmark scope.
The frontier status is **COMPLETED + VERIFIED** within that bounded scope.

## Future track and explicit non-claims

The next implementation track is a real-reader/codec integration benchmark,
with its own fixture, checksum, ownership, and performance gates. It must not
be smuggled into this container frontier.

This plan does not admit replacement of `Array(UInt64)`, implicit contiguous
storage, insertion/deletion/pop/clear/reserve, unmanaged memory, retained
chunks, concurrent mutation, codec or mmap reuse, or a general performance
claim. Benchmark numbers remain a vector of observations with an explicit
abstention path if checksums, process isolation, GC/RSS/time collection, or
repeatability fail.
