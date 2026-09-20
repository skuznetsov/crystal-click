# MMap Data Source Slice Plan

Implementation status: completed and VERIFIED within the supported-Unix,
immutable-local-part scope. Recorded evidence is focused 62 examples with 0
failures, full debug 65/0, full release 65/0, format/diff pass, and final
adversary verdict ROBUST.

## Scope and non-goals

The selected Wide-part `.bin` route now maps the entire already-size-bounded
file once per `read_mark_range` operation, from offset zero, with
`PROT_READ|MAP_PRIVATE`. The public API and decode semantics are unchanged.
Marks, metadata, codec dispatch, checksum status, size limits, and target
symlink rules remain on their existing paths.

Only the compressed-input heap copy is removed. Decoder, Delta reconstruction,
`IO::Memory`, and `Array(UInt64)` allocations remain. This plan makes no
performance claim, adds no persistent mapping, and provides no Windows or
non-Unix `File.read` fallback.

Concurrent truncate/replacement remains outside the contract: an immutable
local part is required, and a mapped race may produce `SIGBUS`.

## Implemented contract

The implementation is equivalent to:

```text
prechecked_size = File.size(@data_path)
MMapDataSource.with_file(@data_path, prechecked_size, MAX_DATA_FILE_BYTES) do |data|
  decode the existing frames from data with their unchanged global offsets
end
```

Inside `with_file`, the supported-Unix path:

1. Opens the selected path read-only with `File.open`.
2. Uses `file.info` to require a regular descriptor and a nonzero size equal
   to the prechecked size and within the existing bound.
3. Calls the private zero-field `NativeBackend` once with offset `0` and the
   full validated size. The native source uses `PROT_READ|MAP_PRIVATE` and
   checks `MAP_FAILED`.
4. Creates a read-only callback `Bytes` view, runs the decoder callback, and
   unmaps in `ensure` before the descriptor closes.

The callback `Bytes` is a borrow enforced by the block/lifetime contract, not a
compiler-level stable-borrow feature. `WidePart` consumes it only inside the
callback and does not store or return it. No page-size discovery, arbitrary
page-aligned span calculation, or frame/header mapping is part of this design;
offset zero and one complete file extent are the admitted route.

If cleanup succeeds, the original callback exception is re-raised unchanged.
If callback and cleanup both fail, `MMapCleanupError` retains both errors. A
cleanup-only failure is surfaced through the existing typed error boundary.

## Implementation record

- `src/crystal_click/mmap_data_source.cr` contains the Unix-gated backend,
  regular-file/size revalidation, read-only callback view, `MAP_FAILED` check,
  `munmap` cleanup, and `MMapCleanupError`. Unsupported platforms fail
  explicitly.
- `src/crystal_click/wide_part.cr` retains the precheck and existing frame
  loop, but routes selected `.bin` input through one `MMapDataSource.with_file`
  callback. Global frame offsets and range/sentinel checks remain unchanged.
- `spec/mmap_data_source_spec.cr` injects a recording backend for map shape,
  descriptor ordering, size/error handling, read-only callback behavior,
  cleanup, simultaneous callback/cleanup failure, and source-shape guards.
- The source guard proves the data route has no `File.read(@data_path)`, calls
  the mmap source, contains the native private/read-only flags, and does not
  add writable/shared flags. This is source/seam evidence, not a raw syscall
  trace.

## Verification record

- Focused mmap and integration specs: **62 examples, 0 failures**.
- Full suite, debug build: **65 examples, 0 failures**.
- Full suite, release build: **65 examples, 0 failures**.
- `crystal tool format --check`: **pass**.
- `git diff --check`: **pass**.
- Final adversary review of the bounded claim: **ROBUST**.

## Falsifier results

| Falsifier | Result and evidence | Claim boundary |
| --- | --- | --- |
| Exactly one map/unmap, offset zero, full size, descriptor open | **PASS** in the injected recording backend | Does not claim a raw kernel syscall trace |
| Read-only/private input | **PASS**: callback view reports read-only; source guard finds `PROT_READ`/`MAP_PRIVATE` and rejects writable/shared flags | Does not claim decompression/output zero-copy |
| Regular-file and size revalidation | **PASS**: focused suite covers empty, changed, oversized, non-regular, and mapping-error cases | Supported Unix only |
| Decoder/callback exception cleanup | **PASS**: unmap is observed before descriptor close and occurs once | Mapping remains callback-scoped |
| Callback plus cleanup failure | **PASS**: `MMapCleanupError` retains both causes | Cleanup error does not erase callback error |
| Callback error with successful cleanup | **PASS**: original `CorruptPartError` and `IO::Error` remain unchanged | Typed exception identity preserved |
| Full/range parity | **PASS** in focused 62/0 for LZ4, direct ZSTD, Delta/ZSTD, multi-column selection, ranges, sentinels, and malformed inputs | Existing fixture semantics |
| Structural route | **PASS**: no data-path `File.read`, mmap route and native flags present | Metadata/mark reads remain allowed |
| Full regression | **PASS**: debug 65/0 and release 65/0 | Current supported-Unix checkout |
| Format/whitespace | **PASS**: format and diff checks | Current checkout |
| Concurrent mutation | **Rejected**, not a supported success case | Immutable part required; SIGBUS possible |

## Residual risk, rollback, and adversary boundary

The remaining risks are deliberately outside the verified claim: concurrent
mutation, Windows/other unsupported platforms, persistent mappings, raw
kernel-level tracing, and any performance or allocation improvement. A future
change to any of those requires a new frontier decision and falsifiers.

Rollback remains one atomic implementation commit containing source,
integration, specs, and these docs; revert it as a unit. This documentation
update does not stage or commit. Within the stated supported-Unix immutable-part
scope, the final adversary verdict is **ROBUST**.
