# Lazy Window Reader Frontier

Document status: functional window slice verified; performance and UI evidence
pending.

Current frontier: expose a bounded physical-row window over caller-selected
immutable Wide parts and typed columns. The reader may skip unselected marks,
but each selected mark is still decoded and materialized under the existing
per-mark bounds. This is a navigation primitive for a virtual table view, not
row-level lazy decompression or a query engine.

## Admitted surface

- `WidePartTable#scan_typed_window(start_row, max_rows, &block)` returns only
  rows in `[start_row, min(total_row_count, start_row + max_rows))` in the
  existing caller-selected part order. `OfflineTable#scan_typed_window` adds
  the same behavior after its normal DDL/type and resolved-part checks.
- `start_row == total_row_count` emits no callbacks. A start beyond the end,
  zero or oversized window, and overflowing arithmetic fail before callbacks.
  The first slice limits `max_rows` to `WidePartTable::MAX_BATCH_ROWS`.
- A callback remains within one part and one mark, carries exact physical
  provenance, and borrows values only until the callback returns. Multiple
  callbacks may cover a window that crosses mark or part boundaries.
- Only selected columns and intersecting marks have payload decoded. Mark
  inventories and selected metadata remain eagerly opened and validated as
  they are for the existing typed scan. No unselected mark is required to
  decode merely to reach a later row.
- An optional UI adapter may own only the visible rows plus bounded overscan;
  it must copy or format values before borrowed callback storage expires.

## Rejected surface

- A claim that mapping a whole `.bin` eagerly loads it into RAM, or that a
  `pread` backend is inherently faster or more lazy than the current mmap.
- Row-level lazy decoding: a selected compressed frame and the selected
  mark's typed values may be materialized even for a one-row window.
- Filtering, global sorting, filtered-result random offsets, SQL semantics,
  joins, server Active state, and a stable live-server snapshot.
- Longer-lived borrowed slices, global decompression-buffer pooling, or a
  silent increase of the existing file/frame/mark allocation limits.

## Guard-only future

- A cursor and bounded decoded-mark cache may reduce repeated navigation
  work only after ownership, invalidation, and memory-budget tests.
- The inspected `crystal_tui` `DataTable` owns an `Array(Row)`, so a virtual
  reader view needs a custom widget or a future row-source interface. No TUI
  adapter is part of this slice.
- A `pread` backend may read a complete compressed frame into reusable input
  storage, then use the same validation and decoder. It requires parity and
  measured first-window, distant-seek, and sequential-scan evidence before
  any default backend change.
- String-specific lazy value construction is separate: the current typed API
  creates String objects for the whole selected mark.

## Design laws

1. Preserve existing selected-part validation, ordered mark-row alignment,
   checksum-size boundary, immutability contract, and source offsets.
2. Compute the physical interval with checked arithmetic before delivering a
   callback. Skipping rows may inspect mark counts, but must not read the
   skipped data payload.
3. Cropped batches must report offsets of their first exposed row, not the
   beginning of the materialized mark.
4. Reuse the existing typed materialization and borrowed callback contract;
   do not retain a frame, `Slice`, or `String` array through a later refill.
5. Keep I/O backend choice independent of window/cursor semantics.

## Falsifier roster

| Probe | Required signal |
| --- | --- |
| Window begins and ends inside one mark | Exact values, size, and first-row offsets match the full scan |
| Window crosses marks or caller-ordered parts | Exact row sequence and provenance, with no duplicate or omitted row |
| Last row, one-past-end, and invalid bounds | Last row matches; one-past-end is empty; invalid bounds reject before callback |
| String, Nullable, and supported typed paths | Window equals the corresponding full-scan slice, including NULL and embedded NUL |
| Skipped mark has corrupt payload | Later disjoint window does not decode the skipped payload; a selected corrupt mark still fails |
| Callback raises | The original exception escapes unchanged |
| Existing typed/candidate scans | No behavior regression in focused and full Crystal suites |

## Stop rules and evidence

Stop or narrow the slice if window contents, provenance, borrowed lifetime,
preflight failure ordering, or corruption rejection changes. A passing
functional suite establishes correctness only for its tested fixtures; it
does not establish lower allocation, RSS, I/O volume, or latency. Performance
comparisons must record source revision, fixture, selected columns, cache
state, measured operation boundary, and memory/latency signals separately.

Implementation seal (2026-09-24): the new `WidePartTable` and `OfflineTable`
window APIs passed the focused window and catalog specs, and the full Crystal
suite passed in both debug and release builds (323 examples, 0 failures in
each). The five-row example on the public fixture matched the existing typed
scan. Format and diff checks passed. A read-only adversarial review found no
blocker within the functional window contract. These signals do not establish
lower allocation, RSS, I/O volume, or latency; those remain unmeasured.
