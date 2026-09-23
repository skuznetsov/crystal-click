# Borrowed UInt64 Scan Frontier SDD

Document status: **completed + VERIFIED** within the supported-Unix,
immutable-part borrowed-scratch scope.

Current frontier: the bounded, callback-scoped scan for a selected Wide-part
`UInt64` stream is implemented. The caller supplies writable
`Slice(UInt64)` storage. The reader fills that storage, yields a sub-slice, and
reuses the storage after the callback returns. Existing `read_uint64` and
`read_uint64_mark_range` remain public, owning, and all-or-error.

Bounded context: the existing Unix mmap-backed `.bin` route in
`src/crystal_click/wide_part.cr`, with the current mark, frame, codec, size,
and error semantics. This is an output-ownership slice; it is not a codec
streaming implementation. The scoped chunk-fill measurements below do not
promote a universal performance result.

Verification gates are passing for this scope: the current focused
borrowed-scan suite is 14/0, and the full debug and release suites are each
149/0. The focused suite includes exact partial-mark parity with a tiny
non-dividing scratch. Formatting and diff checks pass. A separate controlled
campaign measured the chunk-fill candidate on one verified immutable generated
10,000,000-row Delta+ZSTD fixture; those scoped observations are recorded
below and are not universal or ClickHouse-equivalent performance claims.

## Scoped chunk-fill evidence

The scalar release HEAD and candidate were interleaved for seven paired runs
on the verified immutable generated fixture. Medians are milliseconds, shown
as HEAD -> candidate; every paired candidate observation won in the listed
route.

| Route | Scratch values | Median ms | Paired wins |
| --- | ---: | ---: | ---: |
| UInt64 execution pipeline | 4,096 | 109.308 -> 97.809 | 7/7 |
| UInt64 execution pipeline | 8,191 | 110.149 -> 97.853 | 7/7 |
| Borrowed scan | 4,096 | 128.868 -> 96.762 | 7/7 |

An owning-Array typed-load probe was inconclusive (4/7 paired wins) and was
removed from the final candidate. The final-source ClickHouse-track harness
accepted all 28 observations with exact Crystal/ClickHouse sequence parity,
byte-identical physical streams, and an unchanged fixture. Its pipeline median
was 97.503 ms; the ClickHouse-reported SQL median was 82 ms (range 80-85 ms).
The timer boundaries and integrity policies differ, so this is not an isolated
reader-kernel gap.

## Sealed API and ownership boundary

The admitted public signature is:

```crystal
def scan_uint64_mark_range_into(
  column : String,
  first_mark : Int,
  mark_count : Int,
  scratch : Slice(UInt64),
  & : Slice(UInt64) -> Nil
) : Nil
```

The caller owns a writable, non-empty scratch slice. `scratch.size` is the
maximum number of values in one callback; no separate chunk-size parameter is
admitted. `Slice(UInt64).new(n)` is a supported caller-side allocation. The
reader does not allocate an `Array(UInt64)` per chunk.

Each yielded slice is a borrowed sub-slice of `scratch`. Its backing storage is
valid while the caller keeps the scratch owner alive, but its contents are only
stable until the callback returns or the next refill begins. The callback must
consume synchronously. A caller that needs retention must copy the values into
caller-owned storage.

The reader never stores or returns the scratch or a yielded sub-slice. Crystal
cannot prevent a callback from retaining a borrowed slice, so the lifetime is
an API contract, not a compiler-enforced borrow. This design prevents a
library-owned mmap or codec view from escaping the lexical scan operation.

Callback exceptions are unchanged when mmap cleanup succeeds. If unmap also
fails, `MMapCleanupError` retains the original callback error and cleanup
error. Decoder or mark errors after earlier callbacks may expose a valid
prefix before raising; this is intentional progressive-delivery semantics.
The existing owning `read_*` methods do not expose such a prefix.

## Admitted surface

- `scan_uint64_mark_range_into` validates the same column and mark ranges as
  `read_uint64_mark_range`.
- Empty scratch is rejected with `BoundsError` before mapping or decoding.
- Chunks are emitted in logical row order, with no empty callback. The final
  chunk may be shorter than `scratch.size`.
- The implemented scan uses one private frame/range core shared with
  `read_uint64_mark_range`; the owning path decodes scalar values, while the
  borrowed path bulk-copies validated little-endian byte spans into the
  caller's aligned `UInt64` scratch. Big-endian builds retain scalar decoding.
- A selected frame's byte base need not be UInt64-aligned: only validated byte
  offsets and lengths are multiples of eight. The bulk copy treats the source
  as byte-aligned input and writes only to caller-owned `UInt64` storage.
- The core retains the current mmap operation, global compressed offsets,
  frame boundaries, EOF/non-EOF sentinel rules, output bounds, and typed
  errors.
- A physical frame is fully decoded before mark-local decompressed offsets are
  applied, including Delta/Multiple frames.
- Existing `read_uint64_mark_range` collects into its final owning array only;
  it no longer needs the selected `IO::Memory` aggregate or
  `selected.to_slice`.
- Existing `read_uint64`, direct LZ4, direct ZSTD, Delta/ZSTD, Multiple, and
  multi-column selected-stream behavior remain unchanged.
- Callback errors are unchanged when mmap cleanup succeeds. If unmap also
  fails, `MMapCleanupError` retains the original callback error and the
  cleanup error.

## Rejected surface

- Stable retained chunks from one reusable scratch buffer.
- A reusable scratch slice returned from the method or stored by `WidePart`.
- Per-chunk `Array(UInt64)` allocation in the borrowed API.
- `Slice(UInt64)` construction from an unowned/escaping raw pointer by the
  library, or any `to_unsafe`-based escaped slice in production code.
- Reentrancy or concurrency using the same scratch buffer. The callback must
  not invoke this scan recursively with that buffer, and no thread-safety
  guarantee is added.
- All-or-error semantics for the progressive callback API. A transactional
  stream would require prevalidation or a second decode and is outside this
  slice.
- Zero-copy decompression, caller-provided codec output buffers, or codec
  streaming state.
- Persistent mappings, changed mmap extent/flags, mark-format changes,
  checksum verification, Windows support, or a non-Unix fallback.
- Any throughput, latency, GC, RSS, page-fault, or allocation-count claim
  beyond the controlled fixture, build, scratch-size, and timer scope below.

## Guard-only future

- A retention-oriented owning-chunk API may copy each yielded chunk, but it is
  a different ownership contract and is not part of this slice.
- `LZ4.decode_into`, `ZSTD.decode_into`, and Delta scratch reuse may be
  considered only as a separate codec frontier with buffer-capacity and
  nested-stage falsifiers.
- Same-scratch reentrancy detection may be considered only if it can be added
  without weakening concurrent-read behavior or introducing hidden global
  state.

## Design laws

1. The caller owns the scratch storage; `WidePart` owns no output buffer beyond
   the callback scope.
2. A yielded sub-slice aliases the caller's scratch. The next refill may
   overwrite it, so the callback is the lifetime boundary for stable content.
3. The implementation may mutate scratch only before yielding a chunk. It must
   not rely on values after the callback returns.
4. The scan must not expose `Bytes`, mmap-backed input, or codec output to the
   callback.
5. Existing public reads collect locally and return only after the full scalar
   core completes. Any later exception discards their partial local array.
6. Selected byte spans must remain bounded and 8-byte aligned by byte count;
   their source pointer need not be UInt64-aligned. The exact selected byte
   count and row count must be checked before successful return.
7. Decoder/frame allocations are unchanged and remain explicitly outside the
   borrowed-output guarantee.
8. Correctness, aliasing, cleanup, and error evidence precede performance
   claims.

## Falsifier roster

| Falsifier | Observed signal | Boundary |
| --- | --- | --- |
| Initial RED | Before implementation, the focused spec failed because `scan_uint64_mark_range_into` was undefined | Historical TDD signal |
| Full LZ4 scan | **PASS**: small scratch (257 values) reconstructs the exact existing full result | Public Unix fixture |
| Direct ZSTD scan | **PASS**: exact values and row count; no empty chunks | Existing direct ZSTD fixture |
| Delta/ZSTD scan | **PASS**: exact UInt64 wraparound and ranges with nonzero local offsets | Existing Delta fixture |
| Multi-column scan | **PASS**: selected target only, with exact full/range parity | Existing multi-column fixture |
| Empty/read-only scratch | **PASS**: both are rejected before decode; writable scratch succeeds | Caller-owned buffer contract |
| Aliasing | **PASS**: retained first sub-slice aliases scratch and observes later overwrite; copied values remain stable | Borrowed, not owning, content |
| Callback exception | **PASS**: original callback error is unchanged when cleanup succeeds; cleanup failure is typed with both errors | Callback lifetime |
| Later corruption | **PASS**: streaming scan records a valid prefix, then raises the typed corruption error | Progressive delivery only |
| Existing read parity | **PASS**: `read_uint64*` returns the same exact arrays and remains all-or-error | Public compatibility |
| Tiny partial-mark refill | **PASS**: marks 1..3 match owning positional output with scratch size 5 and a 2-value tail | Chunk fill / mark split |
| Byte-span fill alignment | **PASS**: bulk fill copies through byte pointers into caller-owned `UInt64` storage without requiring a UInt64-aligned source base | Source alignment boundary |
| Source route guard | **PASS**: data scan contains no selected `IO::Memory` aggregate, `selected.to_slice`, or `Array(UInt64).new(expected_bytes)`; mark loading remains allowed | Structural evidence only |
| Owning-array allocation guard | **VULNERABLE (historical)**: source guard failed with 11 examples and 1 failure when owning output used untrusted `expected_bytes`; current fix grows `Array(UInt64).new` from decoded scalars | Final adversary **ROBUST** |
| Bounds and alignment | **PASS**: invalid mark offsets, byte counts, and scratch size fail closed | Existing typed limits |
| Repository regression | **PASS**: focused 14/0, full debug 149/0, full release 149/0; scoped benchmark evidence is recorded above | Current supported-Unix checkout |

The source guard is not a substitute for behavior tests. The passing verification
gates do not prove zero-copy decompression or any performance result outside the
scoped campaign above. The final adversary recheck returned **ROBUST** within
the declared scope.

## Stop rules and rollback

- Stop if any fixture loses exact values, if mark-local Delta ranges are sliced
  before full-frame reconstruction, or if existing reads expose a partial
  result.
- Stop if the callback receives an empty chunk, a slice outside scratch, or a
  slice whose contents are read after the next refill as if stable.
- Stop if callback/decoder failures skip mmap cleanup or replace the original
  callback error.
- Stop if implementation requires a reusable codec buffer, a new mmap route,
  or a concurrent/reentrant contract.
- Rollback is one atomic implementation commit containing the `WidePart`
  change, focused specs, and these docs; revert that commit as a unit.

## Ledger and implementation seal

- Source owner: `src/crystal_click/wide_part.cr` only for the first slice;
  `src/crystal_click/compressed_block.cr`, `lz4.cr`, and `zstd.cr` stay outside
  the implementation boundary.
- Focused spec owner: `spec/streaming_scan_spec.cr`; it covers the admitted
  fixture and ownership/error boundary without fixture or public API
  broadening.
- Existing mmap owner: `src/crystal_click/mmap_data_source.cr` remains the
  operation-scoped input source and is not redesigned here.
- Design status: **sealed**.
- Implementation status: **completed + VERIFIED** within the declared scope;
  final adversary verdict **ROBUST**.
- Next local track: retain the measured chunk-fill result only within the
  fixture, build, scratch-size, and timer scope above; keep codec buffer reuse
  and any broader performance claim outside this frontier.
