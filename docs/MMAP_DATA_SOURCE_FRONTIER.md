# MMap Data Source Frontier SDD

Implementation status: completed and VERIFIED within the supported-Unix,
immutable-local-part scope. Verification recorded here is focused 62 examples
with 0 failures, full debug 65/0, full release 65/0, format/diff pass, and a
final adversary verdict of ROBUST.

## Sealed frontier

`WidePart#read_mark_range` now replaces the selected `.bin` whole-file heap
copy with one operation-scoped, read-only `MAP_PRIVATE` mapping of the entire
already-size-bounded regular file, at offset zero. `File.size` remains the
precheck; the mapping source opens the descriptor read-only, revalidates
`file.info` and the regular-file/size conditions, and unmaps before closing
the descriptor. Existing public APIs, global decoder offsets, range behavior,
marks, metadata, size limits, and target symlink rules remain unchanged.

The bounded context is local immutable ClickHouse Wide-part physical data.
Only the selected `.bin` compressed-input path changes. Concurrent replacement
or truncation, which can make a mapped read `SIGBUS`, is outside the contract.
Windows and a non-Unix `File.read` fallback are also outside this frontier.

## Evidence anchors

- `src/crystal_click/wide_part.cr` invokes `MMapDataSource.with_file` around
  the existing `CompressedBlock.decode_frame` loop; the data route contains no
  `File.read(@data_path)`.
- `src/crystal_click/mmap_data_source.cr` has a compile-gated Unix backend with
  a private zero-field `NativeBackend`. Its native source contains
  `PROT_READ` and `MAP_PRIVATE`, checks `MAP_FAILED`, and reports `munmap`
  failure.
- The mapping source opens the descriptor, requires `file.info.file?`, and
  rejects zero, oversized, or changed sizes before invoking the backend.
- The injected backend observation recorded exactly one map and one unmap for
  an operation, with offset `0`, full file size, and the descriptor open for
  both calls. This is a seam observation, not a raw-kernel syscall trace.
- The callback receives a read-only `Bytes` view. The borrow is an
  enforce-by-contract callback lifetime: `WidePart` decodes and copies
  selected output inside the callback and does not store or return the mapped
  view.
- Callback failure is re-raised unchanged when cleanup succeeds. If callback
  and cleanup both fail, `MMapCleanupError` retains both errors. Cleanup runs
  before descriptor close.
- Metadata and mark loading still use their existing file-read paths. They are
  not silently routed through this input source.

The source guard plus injected backend are the limit of mapping-call evidence:
this record does not claim an observed kernel syscall trace, resident-page
behavior, or a performance result.

## Meaning of zero-copy

| Boundary | Admitted meaning | Explicitly not admitted |
| --- | --- | --- |
| Compressed input | The pre-decode whole-file heap copy is removed; the decoder receives a read-only `Bytes` view over mmap-backed compressed input for the callback lifetime | Zero-copy disk I/O, eager/non-eager residency guarantee, or zero-copy decompression |
| Decoder | Existing LZ4, ZSTD, and Delta code and frame limits remain in use | Allocation-free decompression or Delta reconstruction |
| Result | Existing `IO::Memory`, `Array(UInt64)`, and public ownership behavior remain in use | Allocation-free output or output lifetime tied to the map |
| Lifetime | One map is owned by one callback-scoped operation and is released before descriptor close | Persistent, cached, stream-lifetime, or `WidePart`-lifetime mapping |

## Admitted surface

- Supported Unix only: open the already-resolved regular `.bin` read-only,
  revalidate its nonzero size against the prechecked size and the existing
  `MAX_DATA_FILE_BYTES` bound, then map the complete file once at offset zero.
- Use `PROT_READ` and `MAP_PRIVATE`; no writable or shared mapping is admitted.
- Keep the existing decoder loop, global frame offsets, EOF/non-EOF sentinel
  rules, full/range behavior, and codec dispatch unchanged.
- Preserve `WidePart.open`, `read_uint64`, `read_uint64_mark_range`,
  `row_count`, `mark_count`, `data_path`, `mark_path`, and
  `checksum_verification` without API or semantic changes.
- Preserve LZ4, direct ZSTD, Delta/ZSTD, selected multi-column behavior,
  malformed-input errors, per-frame/output/row limits, marks, metadata, and
  target symlink rejection.
- Surface map/open/revalidation/unmap errors through the existing typed error
  boundary. Preserve the callback error if unmap succeeds; retain both errors
  in `MMapCleanupError` if cleanup also fails.

## Rejected or guard-only surface

- `File.read(@data_path)` or an equivalent pre-decode heap copy in the data
  route; metadata and mark reads are not part of this prohibition.
- `MAP_SHARED`, writable mappings, mutable input, per-frame/header mappings,
  persistent mappings, or a mapping that escapes the callback.
- Zero-copy decompression, zero-copy Delta reconstruction, allocation-free
  output, or elimination of decoder/Crystal allocations.
- Any performance, memory, throughput, or latency improvement claim before a
  controlled benchmark. The passing tests do not constitute a benchmark.
- Windows support, a non-Unix fallback, or a portability claim beyond the
  supported Unix compile branch.
- Graceful behavior under concurrent truncate/replace; the immutable-part
  precondition is required and a SIGBUS-prone race is explicitly rejected.
- Page-size discovery, frame-relative mapping, or page-alignment tuning as a
  claimed feature. The admitted call uses offset zero and the complete file;
  no separate page-size API is part of the implementation.

## Design laws

1. The precheck and the descriptor revalidation both reject zero or oversized
   data; a changed size is rejected before mapping.
2. One full-file mapping is created for the operation. The existing decoder
   consumes the same global offsets and does not receive a new cursor model.
3. The callback `Bytes` view is read-only by construction and borrowed by
   contract. `MMapDataSource` does not store or return it, and `WidePart` does
   not retain it; Crystal cannot prevent another callback from retaining the
   borrowed view contrary to that contract.
4. `ensure` unmaps before the enclosing file scope closes. A successful cleanup
   preserves the original callback exception; simultaneous cleanup failure is
   typed as `MMapCleanupError` with both causes retained.
5. Only the selected `.bin` data source changes. Marks, metadata, codecs,
   decoded-output ownership, checksums, API, limits, and symlink policy stay
   on their existing paths.
6. The native source is Unix-gated and has no non-Unix heap-read fallback.
7. Correctness and cleanup evidence precede any future performance discussion.

## Falsifier and verification roster

| Falsifier | Observed signal | Scope/limit |
| --- | --- | --- |
| One-operation map shape | Injected backend observed exactly one map/unmap with offset `0`, full size, and the descriptor open | Backend seam; not a kernel syscall trace |
| Read-only/private route | Callback `Bytes` is read-only; source guard finds `PROT_READ` and `MAP_PRIVATE`, and no `PROT_WRITE`/`MAP_SHARED` | Source and seam evidence |
| Regular descriptor and size revalidation | Focused suite passes regular-file, empty, changed-size, oversized, and mapping-error cases | Supported Unix path |
| Cleanup on decoder/callback error | Unmap occurs before close; original callback error is unchanged when cleanup succeeds | Callback-scoped lifetime |
| Simultaneous callback and cleanup failure | `MMapCleanupError` retains the callback and cleanup errors | Typed error boundary |
| Full/range codec integration | Focused 62/0 covers LZ4, direct ZSTD, Delta/ZSTD, multi-column selection, range/sentinel/error behavior | Existing fixture semantics |
| Structural route | Source guard proves `WidePart` calls the mmap source, has no `File.read(@data_path)`, and native flags/backend shape are present | Does not prove raw syscall behavior |
| Repository regression | Full debug 65/0 and full release 65/0 | Current supported-Unix checkout |
| Formatting and whitespace | `crystal tool format --check` and `git diff --check` pass | Current checkout |
| Concurrent mutation | No safety/graceful-recovery claim is admitted | Immutable local part required; SIGBUS remains possible |

## Rollback and residual boundary

The implementation rollback is one atomic commit containing the source,
integration, focused specs, and these docs; revert that commit as a unit. This
documentation update does not stage or commit. The final adversary verdict for
the stated supported-Unix immutable-part claim is **ROBUST**. Any benchmark,
Windows backend, concurrent-mutation guarantee, persistent lifetime, or
decoder/output allocation change requires a new frontier decision.
