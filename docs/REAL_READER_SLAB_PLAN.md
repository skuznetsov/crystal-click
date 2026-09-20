# Real Reader Slab Integration Plan

Status: **IMPLEMENTATION VERIFIED; REAL-WORKLOAD BENCHMARK GATE PASS (SCOPED ROBUST)**.

Risk: **CAUTION**. The slice adds public owning reader methods, a byte-chunk
append path, and a retained multi-column benchmark boundary, but does not
change existing Array or borrowed-reader behavior, decoder behavior, mmap
behavior, or the default slab shift. Manifest integrity remains scoped to the
macOS regular-local path; hostile transient swap/restore and non-macOS
portability are not claimed.

Rollback: revert the bulk optimization change containing the source, focused
specs, and synchronized frontier evidence. Treat benchmark/runner hardening as
a separate measurement surface; review its fail-closed manifest and privacy
boundaries independently if that surface is reverted.

Definition of done:

- [x] the initial focused RED (undefined `concat_le_bytes`) is closed; focused
  slab-reader specs pass in debug and release: 21 examples, 0 failures in each;
- [x] existing Array and borrowed-reader suites plus the full repository suite
  pass in the current debug and release runs: 108 examples, 0 failures in each;
- [x] manifest-focused suite passes: 11 examples, 0 failures;
- [x] format, shell syntax, and diff checks pass;
- [x] public smoke benchmark preserves parity and reports
  `threshold_met=false`; it is not performance evidence;
- [x] manifest v2 uses a bounded 64 KiB JSON/stat+snapshot path, stdin child
  delivery, strict schema/bounds, an absolute non-root fixture, and an
  aggregate fixture digest without persisting private identifiers/results in
  repository artifacts;
- [x] the retained private workload has three exact `UInt64` columns, 3,917,920
  rows each, and 94,030,080 decoded bytes (about 89.67 MiB);
- [x] all controlled tracks record harness-observed expected row counts and
  aggregate checksums, plus parity/geometry/threshold/immutability guards,
  across seven paired repetitions at shifts 12, 14, 16, 18, and 20 in each
  cache regime (70 observations per regime, 140/140 overall, RSS available);
- [x] post-fix natural shift-18 countercheck preserves parity: 14/14
  observations, Array/slab medians 147.585/118.007 ms, ratio median 0.799585
  with range 0.7681..0.8342; GC metrics were available and RSS was unavailable
  only for this countercheck because of a time-metadata warning;
- [x] any performance observation is limited to the declared
  fixture/cache/host/current-Array-growth-policy scope;
- [x] adversary trail is recorded: first manifest review **VULNERABLE** for
  unbounded hashing, bounded stat+snapshot fix, then **ROBUST** only within the
  macOS regular-local-manifest and immutable-fixture scope; generalized/cold-
  cache/default-shift winners remain rejected.

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
4. **Completed — manifest and runner hardening.** Manifest v2 is bounded to
   64 KiB, parsed as strict JSON with bounded nesting/columns/names/rows/derived
   bytes, and requires an absolute non-root fixture. The caller file is checked
   with `stat`, captured as one bounded in-memory snapshot, hashed, and sent by
   stdin to validation, warmup, and timed children. The runner rechecks the
   snapshot and an aggregate fixture-tree digest around observations. Repository
   artifacts record no private fixture identifiers (path, names, raw values,
   exact checksums) or result payloads; transient local operational
   paths/metadata are outside this claim. Its only cache labels are
   `warm_shared` and `natural_unknown`; it makes no cold-cache claim.
5. **Completed — correctness/smoke.** Public fixtures and the private
   150,414-row Tokenomics single-column sample preserve parity. Tokenomics had seven
   paired observations but is explicitly too small for a performance verdict;
   its median Array/slab-shift-12 times were 3.502458/3.745792 ms and its GC
   bytes were 8,542,048/3,716,944.
6. **Completed — controlled fixture.** The reproducible generator produced a
   temporary-only 10,000,000-row `value=number` Delta(8)/ZSTD(1) `.cmrk2`
   fixture with compressed marks: benchmark roll checksum
   `3960830973137314304`, compressed data 3,874,486 bytes, compressed marks
   14,186 bytes, and 80,000,000 bytes (76.3 MiB) of decoded data. The fixture
   and raw results were not committed.
7. **Historical context — synthetic one-column measurements.** The earlier
   deterministic public 10M one-column fixture remains useful for comparison,
   but is not the retained real-workload gate. Seven paired repetitions at
   shifts 12, 14, 16, 18, and 20 in each cache regime passed row/checksum
   parity with RSS available. Times and paired ratios (slab/Array) were:

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
   solely to bulk byte append. The small Tokenomics sample was slower previously;
   the default shift remains unchanged and no adaptive policy is admitted.
8. **Completed — retained multi-column real-workload gate.** The final
   workload is one private Wide part with three exact `UInt64` columns,
   3,917,920 rows per column, and 94,030,080 decoded bytes (about 89.67 MiB).
   Independent ClickHouse checksums were used per column, but the fixture path,
   column names, raw values, and exact private checksum values are intentionally
   not recorded in repository artifacts. Seven repetitions covered shifts 12,
   14, 16, 18, and 20 in both `natural_unknown` and `warm_shared`: 70
   observations per regime and **140/140 overall**. RSS was available for all
   observations. The 140/140 result certifies only harness-observed expected
   row counts, aggregate checksums, and the row/parity, geometry, threshold,
   and fixture-immutability guards; it is not exhaustive value-by-value
   validation or cryptographic proof. The public smoke result remains
   `threshold_met=false`; it is not performance evidence.

   The table reports `Array median / p95` and `slab median / p95` in
   milliseconds. p95 is the nearest-rank value over seven paired observations;
   `slab/Array` is median / p95 and `slab-vs-shift12` is the median slab ratio:

   | regime | shift | Array ms | slab ms | slab/Array | slab-vs-shift12 |
   | --- | ---: | ---: | ---: | ---: | ---: |
   | `natural_unknown` | 12 | 145.355 / 149.929 | 124.564 / 126.912 | 0.849 / 0.869 | 1.000 |
   | `natural_unknown` | 14 | 146.138 / 152.567 | 120.092 / 126.514 | 0.823 / 0.867 | 0.964 |
   | `natural_unknown` | 16 | 145.951 / 154.387 | 115.793 / 116.708 | 0.784 / 0.819 | 0.930 |
   | `natural_unknown` | 18 | 146.117 / 147.812 | 109.801 / 119.048 | 0.751 / 0.817 | 0.881 |
   | `natural_unknown` | 20 | 148.421 / 172.024 | 110.308 / 110.792 | 0.745 / 0.755 | 0.886 |
   | `warm_shared` | 12 | 145.517 / 148.994 | 123.589 / 125.741 | 0.859 / 0.865 | 1.000 |
   | `warm_shared` | 14 | 145.778 / 148.242 | 118.448 / 122.078 | 0.807 / 0.840 | 0.958 |
   | `warm_shared` | 16 | 146.267 / 149.527 | 115.041 / 118.344 | 0.789 / 0.813 | 0.931 |
   | `warm_shared` | 18 | 146.717 / 152.324 | 109.341 / 116.309 | 0.742 / 0.808 | 0.885 |
   | `warm_shared` | 20 | 147.558 / 148.914 | 110.407 / 118.393 | 0.751 / 0.809 | 0.893 |

   Matched per-rep latency ratio ranges (`slab/Array`) were natural shift 12
   `.8308..0.8692`, natural shift 14 `.7757..0.8669`, warm shift 12
   `.8188..0.8655`, and warm shift 14 `.8005..0.8404`. Across the current
   matrix, global matched per-rep slab/Array ratios were RSS
   `0.449087..0.797326`, GC bytes `0.392571..0.401681`, and GC collections
   `1.235294..4.466667`. These are ratio claims only; no absolute RSS unit claim
   is made. Exact tail waste, computed as `(capacity - retained_values) /
   capacity`, was shift 12 `0.049798%`, shifts 14/16/18 `0.362142%`, and shift
   20 `6.589508%`. Shift 18 is the strongest median candidate in this workload,
   but the benchmark
   gate is **PASS / ROBUST** only for this host, workload, and the two named
   cache labels. It is not a default/adaptive-policy decision, cold-cache
   evidence, or a general winner claim.

   Historical geometry context: the prior one-column 10M fixture used 9,766
   slabs / 16,384 directory entries at shift 10, 2,442 / 4,096 at shift 12,
   and 611 / 1,024 at shift 14. Thus the proposed 1,024-entry directory exactly
   covered the 10M shift-14 case, with 10,624 unused values (about 83 KiB).
9. **Completed — adversary/closure.** The first manifest review was
   **VULNERABLE** because unbounded manifest hashing made validation cost
   unbounded. The bounded `stat` + one in-memory snapshot fix, stdin delivery
   to validation/warmup/timed children, strict v2 JSON/schema bounds, and
   aggregate fixture digest were re-reviewed **ROBUST** only for a macOS
   regular local manifest and immutable fixture. A hostile transient
   swap/restore between checks and non-macOS portability remain explicit
   nonclaims. Big-endian execution is untested; no leak, long-lived-workload,
   or cryptographic ClickHouse checksum claim is made.

Premortem: the most likely false win is a cache/order or fixture-shape artifact;
the guards are bounded manifest snapshotting, subprocess isolation, rotated
order, independent per-column checksums, aggregate fixture digest, seven paired
repetitions, two named cache labels, p95 reporting, and refusal to generalize
from one private part. Allocation volume fell in the retained run, but GC cycle
count rose and shift-20 tail capacity is materially higher; both are explicit
trade-offs. Shift 18 remains a workload-local candidate only. The next
transition is additional diverse real parts, codecs, and query shapes with
repeatability checks before any default or adaptive-shift decision.
