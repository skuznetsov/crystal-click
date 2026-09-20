# Borrowed UInt64 Scan Slice Plan

Implementation status: **completed + VERIFIED** within the supported-Unix
immutable-part borrowed-scratch scope.

Plan risk: **CAUTION** — this widens the public API and changes the internal
result-ownership path while preserving existing read semantics.

Rollback: one atomic commit containing the `WidePart` implementation, focused
specs, and these two docs; revert that commit as a unit.

## Definition of done

Commands:

```text
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
CRYSTAL_CACHE_DIR=/private/tmp/crystal_click_borrowed_scan_focused \
crystal spec spec/streaming_scan_spec.cr --error-trace

SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
CRYSTAL_CACHE_DIR=/private/tmp/crystal_click_borrowed_scan_malformed_huge_mark \
crystal spec spec/streaming_scan_spec.cr --example "does not size the owning output from an untrusted huge mark row count" --error-trace

SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
CRYSTAL_CACHE_DIR=/private/tmp/crystal_click_borrowed_scan_relevant73 \
crystal spec spec/compressed_block_spec.cr spec/delta_zstd_spec.cr \
  spec/multicolumn_wide_part_spec.cr spec/mmap_data_source_spec.cr \
  spec/wide_part_spec.cr spec/streaming_scan_spec.cr --error-trace

SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
CRYSTAL_CACHE_DIR=/private/tmp/crystal_click_borrowed_scan_debug \
crystal spec --error-trace

SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
CRYSTAL_CACHE_DIR=/private/tmp/crystal_click_borrowed_scan_release \
crystal spec --release --error-trace

crystal tool format --check
git diff --check
```

Observed signals:

- Initial RED before implementation: the focused spec failed because
  `scan_uint64_mark_range_into` was undefined.
- Historical source-guard RED: **11 examples, 1 failure** because owning
  output used `Array(UInt64).new(expected_bytes)` from untrusted mark data.
- Focused borrowed-scan suite: **11 examples, 0 failures, 0 errors, 0 pending**.
- Targeted malformed-huge-mark check: **1 example, 0 failures, 0 errors, 0 pending**.
- Combined relevant suite: **73 examples, 0 failures, 0 errors, 0 pending**.
- Full debug suite: **76 examples, 0 failures, 0 errors, 0 pending**.
- Full release suite: **76 examples, 0 failures, 0 errors, 0 pending**.
- `crystal tool format --check`: pass.
- `git diff --check`: pass.

The corrective implementation uses `Array(UInt64).new` and grows only from
actual decoded scalars; the malformed-huge-mark and source guards are now
GREEN. The prior final adversary review was **VULNERABLE** because the owning
read preallocated from untrusted `expected_bytes`. The final adversary
recheck returned **ROBUST** within the declared scope.

These signals establish correctness and ownership within the declared scope.
They do not measure
allocations, GC, RSS, page faults, latency, or throughput. The structural
result is removal of the selected data-path `IO::Memory` aggregate and
per-chunk arrays from the borrowed scan; decoder/frame allocations remain
outside this claim.

## Steps

### 1. RED specification and focused implementation evidence

Path: `spec/streaming_scan_spec.cr`.

Action: the first focused run, before implementation, failed at compile time
with an undefined-method signal for
`scan_uint64_mark_range_into(column, first_mark, mark_count, scratch, &)`.
The implemented spec is now the executable ownership and codec boundary.

Consumers/inventory:

```text
rg -n "read_uint64|read_uint64_mark_range|CompressedBlock|Delta|ZSTD" \
  src spec
```

Observed consumers include the existing Wide-part, direct ZSTD, Delta/ZSTD,
and multi-column specs. No other public scanner consumer exists.

Required cases:

- LZ4 full scan with a scratch size that does not divide frame/mark sizes.
- Direct ZSTD full/range scan.
- Delta/ZSTD full/range scan, including modulo-UInt64 wraparound and nonzero
  local offsets.
- Multi-column selected target full/range scan and neighbor isolation.
- Empty scratch rejection; read-only scratch rejection if the Crystal API can
  construct one for `UInt64`.
- Chunk sizes, order, no empty callbacks, final partial chunk, and exact row
  count.
- Aliasing: a retained yielded sub-slice points into caller storage and is
  overwritten by a later refill; a caller copy remains stable.
- Callback exception propagation and cleanup.
- Later-frame corruption: a recorded prefix is permitted for the streaming
  API, followed by the typed corruption error.
- Existing `read_uint64` and `read_uint64_mark_range` exact parity and
  all-or-error behavior.

Observed signal: focused suite is 11 examples, 0 failures, 0 errors, 0
pending; the required codec, mark, ownership, progressive-prefix, parity,
and source-guard cases are present.

Adversary: reject any test that accidentally treats a borrowed sub-slice as a
stable retained chunk or uses caller-side copying as evidence of zero-copy
output.

### 2. Shared scalar/frame core — completed

Path: `src/crystal_click/wide_part.cr`, current `read_mark_range` and
`decode_uint64` region.

Action: the private scalar/frame core preserves the existing validation
preamble, mmap route, global compressed offsets, complete
`CompressedBlock` frames, local mark offsets after full-frame reconstruction,
exact selected bytes/alignment, and typed errors while yielding `UInt64`
scalars.

Consumers: `read_uint64_mark_range` and the new borrowed scratch sink.

Verification: focused, combined relevant, full debug, and full release suites
pass; source inspection confirms no mapped/codec `Bytes` crosses the callback.

Adversary result: later-frame corruption yields a progressive prefix only
through the scan callback; the owning read remains all-or-error. Nonzero
Delta mark offsets are covered so suffix-only decoding cannot pass.

### 3. Preserve owning read semantics — completed

Path: `src/crystal_click/wide_part.cr`.

Action: `read_uint64_mark_range` uses `Array(UInt64).new` and grows the final
owning array only from actual decoded scalars from the shared core. The data
path has no selected `IO::Memory` aggregate or `selected.to_slice`;
`CompressedBlock.decode_all` mark loading remains unchanged.

Verification: existing reads retain exact full/range parity and all-or-error
behavior, and the public method returns only after the core and exact
row/byte checks complete.

Adversary result: the prior final review was **VULNERABLE** because the
owning read preallocated from untrusted `expected_bytes`. The fix uses
`Array(UInt64).new` and grows only from actual decoded scalars; the targeted
malformed-huge-mark check is 1/0 and the source guard is GREEN. Final
adversary recheck remains pending.

### 4. Borrowed scratch sink — completed

Path: `src/crystal_click/wide_part.cr`.

Action: the public sink is exactly:

```crystal
def scan_uint64_mark_range_into(
  column : String,
  first_mark : Int,
  mark_count : Int,
  scratch : Slice(UInt64),
  & : Slice(UInt64) -> Nil
) : Nil
```

The caller supplies writable, non-empty storage. The sink fills it, yields
`scratch[0, count]`, and reuses it after callback return. It allocates no
per-chunk `Array` and does not use `to_unsafe` in the production scanner.
Yielded chunks are borrowed and content-stable only until callback return or
the next refill; retained values require caller copying.

Verification: focused borrowed-scan specs pass for every codec/mark fixture;
empty/read-only scratch is rejected, no empty or out-of-range sub-slice is
observed, and mmap cleanup remains scoped to the operation. Callback errors
are unchanged when cleanup succeeds; if unmap also fails,
`MMapCleanupError` retains the original callback error and cleanup error.

Adversary result: same-buffer aliasing is executable and documents the
invalid same-scratch reentrancy/concurrency case rather than promising it.

### 5. Repository gates and closure sync

Paths: `src/crystal_click/wide_part.cr`,
`spec/streaming_scan_spec.cr`, and the two new docs.

Action: run the focused, combined relevant, full debug, full release,
formatter, and diff checks from the DoD, then stage the four owned paths and
commit them as one unit.

Verification: all observed gates pass: 11/0 focused, 1/0 targeted
malformed-huge-mark, 73/0 combined relevant, 76/0 full debug, 76/0 full
release, plus format and diff passes.

Adversary boundary: source guards prove only the absence of the selected
aggregate and the intended route. They do not prove fewer GC cycles, stable
retained chunks, zero-copy decompression, or throughput improvement. Runtime
review was historically VULNERABLE because the owning read
preallocated from untrusted `expected_bytes`. The allocation fix is GREEN
under the current gates, and the final adversary recheck returned **ROBUST**
within the declared scope.

## Explicit non-claims

This plan does not admit:

- stable content after callback return;
- retention without caller copying;
- same-scratch reentrancy or concurrent use;
- codec output-buffer reuse;
- zero-copy decompression or allocation-free decoding;
- benchmark, RSS, GC, latency, or throughput improvement;
- changed mmap flags, extent, lifetime, or platform support.

Those require separate frontiers and falsifiers. The implementation slice is
completed + VERIFIED within the declared scope, with a final **ROBUST**
adversary verdict.
