# Reusable Decode Workspace Implementation Plan

Implementation status: **completed + VERIFIED** within the declared
synchronous decode-workspace scope. Final adversary verdict: **ROBUST**.

Plan risk: **CAUTION** — this changes the decompression hot path and adds a
borrowed public codec result while preserving existing owning APIs.

Rollback: revert the one atomic decode-workspace commit. No data, fixture,
format, or dependency migration is admitted.

## Definition of done

Commands:

```text
CRYSTAL_CACHE_DIR=/private/tmp/crystal_click_decode_workspace_focused \
  crystal spec spec/decode_workspace_spec.cr --link-flags="-fuse-ld=ld" --error-trace

CRYSTAL_CACHE_DIR=/private/tmp/crystal_click_decode_workspace_relevant \
  crystal spec spec/lz4_spec.cr spec/compressed_block_spec.cr \
  spec/delta_zstd_spec.cr spec/streaming_scan_spec.cr \
  spec/multipart_uint64_scan_spec.cr --link-flags="-fuse-ld=ld" --error-trace

CRYSTAL_CACHE_DIR=/private/tmp/crystal_click_decode_workspace_debug \
  crystal spec --link-flags="-fuse-ld=ld" --error-trace

CRYSTAL_CACHE_DIR=/private/tmp/crystal_click_decode_workspace_release \
  crystal spec --release --link-flags="-fuse-ld=ld" --error-trace

crystal tool format --check
git diff --check
```

Expected signals:

- The focused test records an initial compile-time RED for the absent
  workspace API, then passes same-size reuse, growth/reuse, borrowed-lifetime,
  in-place overlap, owning-compatibility, and exact-value checks.
- Existing relevant and full suites retain zero failures in debug and release.
- Formatting and diff checks pass.
- Source inspection finds one operation-local workspace in the Wide-part frame
  loop and no workspace instance/global state.

These signals establish structural storage reuse and compatibility. They do
not establish fewer total allocations for an arbitrary query, fewer GC
cycles, or a throughput improvement.

Observed signals:

- Initial RED: compile-time failure for absent `DecodeWorkspace`.
- Focused workspace suite: **4/0**.
- Relevant codec/streaming/multipart suite: **41/0**.
- Full debug suite: **129/0**.
- Full release suite: **129/0**.
- Formatter and diff checks: pass.

## Steps

### 1. RED workspace contract

Path: `spec/decode_workspace_spec.cr`.

Added focused tests that call the sealed `DecodeWorkspace` and
`decode_frame_into` API against public LZ4, ZSTD, and Multiple fixtures. The
initial missing-API failure was captured before production edits.

Adversary: pointer equality alone is insufficient; pair it with exact decoded
values, logical lengths, growth behavior, in-place overlap safety, borrowed
overwrite, and owning-result stability.

### 2. Destination-oriented codec primitives

Paths: `src/crystal_click/lz4.cr`, `src/crystal_click/zstd.cr`.

Added exact-size writable-destination decoding while retaining the existing
allocating wrappers. Preserve every current bounds, trailing-frame, output-size,
and typed-error check.

Adversary: reject an implementation that slices an undersized destination,
allocates before checking the declared limit, or accepts extra ZSTD frames.

### 3. One-buffer frame workspace

Path: `src/crystal_click/compressed_block.cr`.

Implemented one high-water buffer, borrowed exact-length views, and
`decode_frame_into`. Route direct codecs into the buffer. For the exact
Multiple chain, decode nested ZSTD into the same buffer, validate the complete
Delta stage before mutation, then reconstruct forward in place with the write
cursor eleven bytes behind unread input. Keep `decode_frame` owning and let
`decode_all` consume borrowed outputs synchronously.

Adversary: exercise a Multiple frame whose intermediate length exceeds final
length, including wraparound values, then decode another frame through the
same workspace. Reject any overwrite of unread differences or stale logical
length.

### 4. Operation-local Wide-part integration

Path: `src/crystal_click/wide_part.cr`.

Created one workspace immediately around the existing sequential physical-frame
loop and called `decode_frame_into`. Each output is consumed within the existing
synchronous callback before the next frame. Do not change mmap, mark offsets,
row checks, callback semantics, or reader instance state.

Adversary: exact Delta ranges with nonzero local offsets, later-frame
corruption, callback exceptions, and two independent readers must behave as
before.

### 5. Gates, adversary review, and atomic commit

The DoD commands pass. Inspect the exact diff and attack the ownership, size,
and concurrency boundaries. Update the SDD and this plan with observed signals
only after they run. Stage only owned implementation, specs, and docs; commit
them as one feature.

The strongest expected failure is in-place Delta overwriting unread
differences, or a reusable output escaping into an owning API. Either result is
**BROKEN**, not a performance tradeoff.

Final adversary result: **ROBUST**. Validation precedes workspace growth and
Delta mutation; the read cursor remains eleven bytes ahead of the write cursor;
read-only native destinations fail before decode; the scan workspace is local
to one operation; and owning APIs retain independent storage. Caller-forged
native pointers and externally overlapping input/output remain rejected/out of
scope.
