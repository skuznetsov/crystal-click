# Real Reader Slab Integration Plan

Status: **IMPLEMENTATION VERIFIED; PERFORMANCE CLAIM SCOPED**.

Risk: **CAUTION**. The slice adds public owning reader methods and performance
evidence, but does not change existing reader behavior.

Rollback: one atomic commit containing the source, focused specs, benchmark,
runner, and synchronized frontier evidence.

Definition of done:

- [x] focused slab-reader specs pass in debug and release: 8 examples, 0
  failures in each;
- [x] existing Array and borrowed-reader suites plus the full repository suite
  pass in debug and release: 92 examples, 0 failures in each;
- [x] format, shell syntax, and diff checks pass;
- [x] smoke benchmark preserves parity on the 200,000-row public fixture;
- [x] all controlled tracks validate the independent row count and benchmark
  roll checksum across seven paired repetitions per shift and cache regime;
- [x] any performance observation is limited to the declared
  fixture/cache/host/current-Array-growth-policy scope;
- [x] proportionate adversary review: implementation ROBUST in tested scope;
  generalized speedup rejected as VULNERABLE.

## Steps

1. **Completed — focused specs.** `spec/real_reader_slab_spec.cr` covers LZ4,
   compressed-mark ZSTD, Delta/ZSTD wraparound, multicolumn selection, exact
   and partial slab boundaries, invalid inputs, corruption, untrusted row
   claims, GC retention, and Array parity. Debug and release each report 8/0.
2. **Completed — source slice.** `WidePart` adds only the two internally-owned
   methods. They validate through `checked_mark_range`, avoid claimed-size
   reservation, and append directly from `each_uint64_mark_range`; existing
   Array and borrowed methods are unchanged.
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
7. **Completed — measurements.** Seven paired repetitions at shifts 10, 12,
   and 14 in each cache regime all passed row/checksum parity, with RSS
   available. Natural paired slab/Array ratios were 0.9845, 0.9557, and 0.9478
   (shift-10 range 0.8319..1.2592); warm ratios were 1.0108, 0.9696, and
   0.9293. At shift 12, Array/slab medians were 136.615/133.228 ms natural
   and 135.916/131.924 ms warm. At shift 14 they were 137.446/127.884 ms
   natural and 136.586/128.682 ms warm. Median GC bytes were
   592,889,936 Array, 240,362,384 slab shift 12, and 240,300,224 slab shift
   14; median GC cycles were 14, about 58, and about 62. Median RSS was
   320,012,288/121,061,376 (shift 12 natural), 243,826,688/121,094,144
   (shift 12 warm), 269,680,640/107,036,672 (shift 14 natural), and
   291,061,760/106,807,296 bytes (shift 14 warm).
   Geometry also separated the configurations: shifts 10, 12, and 14 used
   9,766/2,442/611 slabs and directory capacities 16,384/4,096/1,024.
   Shift 14 therefore stayed inside the preallocated 1,024-entry directory
   while wasting only 10,624 value slots (83 KiB) at the tail.
8. **Completed — adversary/closure.** The implementation is **ROBUST** within
   the tested correctness scope. A generalized speedup claim is **VULNERABLE**
   and rejected: the small Tokenomics input was slower and shift-12 paired
   ranges crossed 1.0. The lower measured GC-byte/RSS result and shift-14
   throughput result remain admitted only for the declared 10M fixture, host,
   cache labels, and current Array implementation. No leak, long-lived-workload,
   or cryptographic ClickHouse checksum result is claimed.

Premortem: the most likely false win is a cache/order or fixture-size artifact;
the guard is subprocess isolation, rotated order, independent checksum, two
cache labels, the unstable shift-10 natural range, and refusal to generalize
from the small Tokenomics fixture. Allocation volume fell in the controlled
run, but GC cycle count rose; that tradeoff remains an explicit follow-up.
