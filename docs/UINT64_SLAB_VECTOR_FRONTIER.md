# UInt64 Slab Vector Frontier SDD

Document status: **COMPLETED + VERIFIED** within the bounded standalone,
non-concurrent, callback-scoped and synthetic benchmark scope. Final
adversary verdict: **ROBUST** within that scope.

Current frontier: `CrystalClick::UInt64SlabVector` is an owning sequence of
`UInt64` values backed by fixed power-of-two slabs. It is an experimental
container, not a replacement for `Array(UInt64)`, a contiguous result, or a
ClickHouse reader/codec path.

Bounded context: `src/crystal_click/uint64_slab_vector.cr`, its require in
`src/crystal_click.cr`, `spec/uint64_slab_vector_spec.cr`, and the standalone
benchmark in `benchmarks/uint64_slab_vector.cr` with runner
`scripts/bench_uint64_slab_vector.sh`.

## Evidence banner

- The initial RED was an undefined constant/method for the missing vector.
- The first adversary review was **VULNERABLE**: a negative-sized
  `Slice(UInt64)` was accepted and could reach pointer operations. The fix
  rejects negative sizes before dereference and uses overlap-safe
  `Pointer#move_from` for slice copies.
- Focused spec: **8 examples, 0 failures** in debug and release.
- Full repository suite: **84 examples, 0 failures** in debug and release.
- Benchmark smoke verification: 10,003 rows, checksum
  `17327423495062737796`, and slab geometry `3/12288/1024`
  (`slab_count/capacity/directory_capacity`).
- Controlled unsandboxed release benchmark: 10,000,000 rows, 7 repetitions,
  scratch size 4096, slab shifts 10/12/14, and a separate process per track.
  Every track returned checksum `4410372177809615872` and RSS was available.
  The measurements are synthetic container-ingestion evidence only.

## Contract

```crystal
CrystalClick::UInt64SlabVector.new(
  slab_shift = 12,
  initial_directory_capacity = 1024
)

getter size : Int
getter capacity : Int
getter slab_count : Int
getter directory_capacity : Int
getter slab_shift : Int
getter slab_size : Int
getter slab_mask : Int

push(value : UInt64)
<<(value : UInt64)
concat(values : Slice(UInt64))
[](index : Int) : UInt64
each(& : UInt64 ->)
each_chunk(& : Slice(UInt64) ->)
to_a : Array(UInt64)
```

`push` and `<<` append one `UInt64` and return the vector. `concat` appends a
slice in order and does nothing for an empty slice. `[]` is zero-based and
checked; negative or `index >= size` access raises
`CrystalClick::BoundsError`. `each` visits values in logical order. `to_a` is
the explicit owning copy; no implicit contiguous view or conversion exists.

The default shift is `12`, giving `slab_size = 4096` and `slab_mask = 4095`.
Only shifts `4..20` are accepted. Each slab is one
`Pointer(UInt64).malloc(slab_size)` allocation managed by the GC; there is no
manual free. The private `SlabRef` stores the slab pointer and finalized used
count. The active tail pointer, index, and used count are cached separately.
“Atomic slab” means one allocation unit, not thread-safe atomic mutation.

The descriptor directory is `Array(SlabRef)`. Its initial capacity is a
capacity reservation only: it has zero live entries before the first append,
and it grows beyond 1024 descriptors. `directory_capacity` is manually
tracked and exact. The default reservation is approximately 16 KiB of
descriptor storage on a 64-bit host, but allocates no data slab. The guarded
maximum initial directory capacity is `1 << 20`, approximately 16 MiB of
descriptor storage on a 64-bit host.

`size` counts appended values. `capacity` is the total allocated slab slots,
including unused tail slots. `slab_count` counts allocated slabs. Slabs are
allocated lazily only for actual appended values, never for claimed disk or
metadata row counts. Arithmetic for size, slab count, total capacity, and
directory growth is checked.

`each_chunk` yields each used slab portion as a non-empty, read-only
`Slice(UInt64)`. A chunk is borrowed and valid only during its callback; it
must not be retained or mutated. Concurrent or reentrant mutation and
thread-safety are outside the contract.

## Admitted surface

- Exact `UInt64` append, slice concatenation, checked indexing, scalar
  iteration, borrowed read-only chunk iteration, and explicit `to_a`.
- Fixed slab geometry and getters for live size, allocated capacity, slab
  count, exact directory capacity, shift, size, and mask.
- GC-managed slab allocation with lazy data allocation and directory growth
  past the default reservation.
- Exact ordering across full and partial slabs, including `concat` copies that
  overlap source and destination memory safely.
- Fail-closed constructor, index, negative-slice, size, capacity, and growth
  guards.

## Rejected surface for this slice

- Replacing or silently changing the existing `Array(UInt64)` API.
- An implicit contiguous `Slice(UInt64)`, `to_slice`, or escaped raw pointer.
- Insertion, deletion, `pop`, `clear`, `reserve`, arbitrary capacity control,
  or unmanaged `malloc`/`free`.
- Codec, mmap, ClickHouse reader, disk-count, or general serialization reuse.
- Concurrent mutation, thread-safety, reentrant mutation, or retained chunks.
- A general throughput, allocation, GC, RSS, or latency claim beyond the
  controlled synthetic benchmark below.

## Guard-only future

- A real reader/codec sink requires a separate integration frontier and a
  benchmark using real decoded data.
- A retention-oriented chunk API may copy values, but cannot widen the
  callback-scoped borrowed lifetime here.
- Mutation helpers or a contiguous export require new ownership and bounds
  falsifiers.

## Synthetic benchmark evidence

The runner used equal deterministic input, 10,000,000 rows, scratch size
4096, release subprocesses, and checksum validation. `n` is the number of
observations in the aggregate; slab rows are reported per shift.

| Track | n | Median | P95 | GC bytes | Peak RSS | GC cycles |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Array-direct | 21 | 33.461 ms | 38.039 ms | 412.656 MiB | 175.594 MiB | 8 |
| Array-stream-control | 21 | 37.198 ms | 41.640 ms | 412.344 MiB | 175.641 MiB | 8 |
| Slab-stream, shift 10 | 7 | 30.935 ms | 50.423 ms | 76.915 MiB | 121.406 MiB | 16 |
| Slab-stream, shift 12 | 7 | 25.101 ms | 27.660 ms | 76.444 MiB | 90.234 MiB | 15 |
| Slab-stream, shift 14 | 7 | 23.974 ms | 24.975 ms | 76.384 MiB | 82.484 MiB | 14 |
| Slice-sink | 21 | 15.063 ms | 16.874 ms | 0 MiB | 3.219 MiB | 0 |

Shift 14 had the best median in this run. Shift 10 had a high P95 and was
unstable. The default shift 12 was solid. These are observations about this
synthetic producer and container workload only; they do not establish a
ClickHouse reader, codec, or general application speedup. `Slice-sink` is a
non-owning control and is not directly comparable to owning outputs.

## Falsifier roster

| Probe | Observed signal | Status |
| --- | --- | --- |
| Constructor defaults and safe shifts | Default 12/4096/4095; shifts 4..20 accepted; invalid shifts and non-positive initial directory capacity reject | PASS |
| Lazy allocation | Empty vector and empty `concat` have zero data slabs/capacity; first actual append allocates one slab | PASS |
| Directory semantics | Initial reservation is capacity only; more than 1024 descriptors grow without rejection; exact capacity is tracked | PASS |
| Boundary and ordering | Full/partial slabs, `push`, `<<`, `concat`, `[]`, `each`, and `to_a` preserve exact values | PASS, focused 8/0 |
| Borrowed chunks | Non-empty chunks are read-only and callback-scoped | PASS, focused 8/0 |
| Negative-sized slice | First review found silent acceptance; negative guard and overlap-safe move fixed the issue | Fixed; covered by final ROBUST review |
| GC reachability | Values survive `GC.collect` | PASS, focused 8/0 |
| Repository regression | Full debug/release suites are 84/0 | PASS |
| Benchmark smoke | 10,003 rows, checksum `17327423495062737796`, slab geometry `3/12288/1024` | PASS |
| Controlled benchmark integrity | 10,000,000 rows; all tracks checksum `4410372177809615872`; RSS available | PASS, synthetic scope |
| Final adversary review | Standalone, non-concurrent, callback-scoped API plus synthetic benchmark | ROBUST within declared scope |

## Stop rules and next track

Stop if directory capacity becomes a live-entry limit, if an empty operation
allocates a data slab, if an index reads unwritten memory, if chunks are
writable or retained as stable views, if pointer memory is unmanaged, or if a
checksum/row count diverges. Stop performance interpretation if release
process isolation or GC/RSS/time evidence is missing.

The next local track is a real reader/codec integration benchmark as a
separate frontier. The current claim remains **COMPLETED + VERIFIED** only
within the declared scope, with final adversary verdict **ROBUST** there.

## Ledger and implementation seal

- Source: `src/crystal_click/uint64_slab_vector.cr` and its require in
  `src/crystal_click.cr`.
- Focused spec: `spec/uint64_slab_vector_spec.cr`.
- Benchmark: `benchmarks/uint64_slab_vector.cr` and
  `scripts/bench_uint64_slab_vector.sh`.
- Current status: **COMPLETED + VERIFIED** within the declared bounded scope;
  final adversary verdict **ROBUST**.
- Residual rejected surface: Array replacement, contiguous views, mutation
  helpers, unmanaged memory, reader/codec integration, concurrency, retained
  chunks, and general performance claims.
