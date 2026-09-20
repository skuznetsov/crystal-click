# Real Reader Slab Integration Plan

Status: **IMPLEMENTATION VERIFIED; PERFORMANCE CLAIM SCOPED; ADVERSARY REVIEW COMPLETE (SCOPED ROBUST)**.

Risk: **CAUTION**. The slice adds public owning reader methods and a byte-chunk
append path plus performance evidence, but does not change existing Array or
borrowed-reader behavior, decoder behavior, mmap behavior, or the default slab
shift.

Rollback: revert the bulk optimization commit containing the source, focused
specs, and synchronized frontier evidence. The benchmark and runner pre-existed
and are not modified by this commit.

Definition of done:

- [x] the initial focused RED (undefined `concat_le_bytes`) is closed; focused
  slab-reader specs pass in debug and release: 21 examples, 0 failures in each;
- [x] existing Array and borrowed-reader suites plus the full repository suite
  pass in debug and release: 97 examples, 0 failures in each;
- [x] format, shell syntax, and diff checks pass;
- [x] smoke benchmark preserves parity on the 200,000-row public fixture;
- [x] all controlled tracks validate the independent row count and benchmark
  roll checksum across seven paired repetitions at shifts 12, 14, 16, 18, and
  20 in each cache regime (140/140 observations);
- [x] post-fix natural shift-18 countercheck preserves parity: 14/14
  observations, Array/slab medians 147.585/118.007 ms, ratio median 0.799585
  with range 0.7681..0.8342; GC metrics were available and RSS was unavailable
  only for this countercheck because of a time-metadata warning;
- [x] any performance observation is limited to the declared
  fixture/cache/host/current-Array-growth-policy scope;
- [x] proportionate adversary review is **ROBUST within the declared
  reader/vector scope**; big-endian execution remains untested, representative
  real workloads remain next, and generalized/default-shift winners remain
  rejected.

## Steps

1. **Completed — focused RED and specs.** The first focused compile failed
   because `concat_le_bytes` was undefined. `spec/real_reader_slab_spec.cr`
   and `spec/uint64_slab_vector_spec.cr` now cover LZ4, compressed-mark ZSTD,
   Delta/ZSTD wraparound, multicolumn selection, exact and partial slab
   boundaries, invalid inputs, corruption, untrusted row claims, byte alignment
   and pre-mutation validation, GC retention, and Array parity. Focused debug
   and release each report 21/0.
2. **Completed — source slice.** `WidePart` keeps the existing mark/frame
   validation but factors its slab traversal into byte chunks. The slab reader
   consumes those chunks through `UInt64SlabVector#concat_le_bytes(Bytes)`,
   which checks alignment and checked size before mutation/allocation, copies
   synchronously, uses overlap-safe `move_from` for raw bytes on little-endian
   hosts under a source regression guard, and has an explicit big-endian
   fallback. Existing Array and borrowed methods retain scalar `UInt64`
   traversal; no decoder or mmap behavior changed. A later error does not
   expose the partial local vector.
3. **Completed — benchmark.** Array and slab tracks time `WidePart.open` plus
   the complete owning read, then validate the live result using independent
   row/checksum inputs and emit GC/container metrics.
4. **Completed — runner.** The release runner uses fresh subprocesses, an
   immutable per-run manifest, rotated track order, parity fail-closed checks,
   and RSS collection when available. Its only cache labels are
   `warm_shared` and `natural_unknown`; it makes no cold-cache claim.
5. **Completed — correctness/smoke.** Public fixtures and the private
   150,414-row Tokenomics `input` column preserve parity. Tokenomics had seven
   paired observations but is explicitly too small for a performance verdict;
   its median Array/slab-shift-12 times were 3.502458/3.745792 ms and its GC
   bytes were 8,542,048/3,716,944.
6. **Completed — controlled fixture.** The reproducible generator produced a
   temporary-only 10,000,000-row `value=number` Delta(8)/ZSTD(1) `.cmrk2`
   fixture with compressed marks: benchmark roll checksum
   `3960830973137314304`, compressed data 3,874,486 bytes, compressed marks
   14,186 bytes, and 80,000,000 decoded bytes (76.3 MiB). The fixture and raw
   results were not committed.
7. **Completed — measurements.** Seven paired repetitions at shifts 12, 14,
   16, 18, and 20 in each cache regime passed row/checksum parity with RSS
   available. Times and paired ratios (slab/Array) are:

   | shift | natural Array/slab ms | natural ratio | warm Array/slab ms | warm ratio |
   | --- | ---: | ---: | ---: | ---: |
   | 12 | 146.189 / 128.856 | 0.8854 (0.8709..0.9282) | 145.949 / 128.748 | 0.8815 (0.8667..0.9029) |
   | 14 | 141.088 / 123.919 | 0.8787 (0.8461..0.8851) | 143.168 / 121.899 | 0.8454 (0.8180..0.9878) |
   | 16 | 146.482 / 121.789 | 0.8281 (0.8178..0.8488) | 142.961 / 118.480 | 0.8249 (0.8208..0.8624) |
   | 18 | 143.679 / 114.708 | 0.7996 (0.7703..0.8224) | 143.498 / 114.761 | 0.8089 (0.7900..0.8201) |
   | 20 | 145.506 / 114.165 | 0.7908 (0.7742..0.8117) | 139.834 / 114.100 | 0.8063 (0.7796..0.8232) |

   GC bytes and RSS are Array/slab; RSS is MiB. GC cycles are orientation,
   not a substitute for end-to-end latency or allocation volume.

   | shift | slabs / capacity / directory | tail unused slots | GC bytes | GC cycles | RSS natural MiB | RSS warm MiB |
   | --- | ---: | ---: | ---: | ---: | ---: | ---: |
   | 12 | 2,442 / 10,002,432 / 4,096 | 2,432 | 592,889,936 / 240,362,384 | 15 / 58 | 282.73 / 115.38 | 283.55 / 115.92 |
   | 14 | 611 / 10,010,624 / 1,024 | 10,624 | 592,889,936 / 240,300,224 | 14 / 62 | 226.34 / 101.03 | 282.75 / 101.86 |
   | 16 | 153 / 10,027,008 / 1,024 | 27,008 | 592,889,936 / 240,423,968 | 14 / 54 | 305.27 / 92.91 | 290.09 / 92.94 |
   | 18 | 39 / 10,223,616 / 1,024 | 223,616 | 592,889,936 / 241,995,008 | 14 / 24 | 226.34 / 103.47 | 283.33 / 103.50 |
   | 20 | 10 / 10,485,760 / 1,024 | 485,760 | 592,889,936 / 244,091,696 | 14 / 17 | 288.78 / 110.70 | 226.36 / 110.70 |

   Correctness and end-to-end latency are primary; RSS and GC bytes are
   constraints, while GC cycles and tail capacity are explicit trade-off
   signals. The older overlapping baselines had different host/order
   conditions, and one was slab-only, so no exact cross-run delta is attributed
   solely to bulk byte append. The small Tokenomics input was slower previously;
   the default shift remains unchanged and no adaptive policy is admitted.
8. **Completed — adversary/closure.** The final adversary verdict is
   **ROBUST within the declared reader/vector scope**: the overlap-safe
   little-endian copy, source regression guard, focused/full parity, and post-fix
   shift-18 countercheck introduce no observed blocker. Big-endian execution is
   untested, benchmark conclusions remain fixture/host/cache scoped, and
   representative real workloads are the next transition. A generalized or
   default-shift winner remains rejected, and no leak, long-lived-workload, or
   cryptographic ClickHouse checksum result is claimed.

Premortem: the most likely false win is a cache/order or fixture-size artifact;
the guard is subprocess isolation, rotated order, independent checksum, two
cache labels, the older overlapping baseline warning, the post-fix countercheck,
and refusal to generalize
from the small Tokenomics fixture. Allocation volume fell in the controlled
run, but GC cycle count rose and tail capacity grows with shift; both trade-offs
remain explicit follow-ups. The adversary review is now closed within scope;
the next transition is representative real workloads before any default or
adaptive-shift decision.
