# Offline TUI Window Viewer Frontier

Document status: implemented and locally verified for the immutable-root,
headless-example scope on 2026-09-24. A live terminal smoke test and any
performance measurement remain outside this verification.

This optional example navigates one immutable ClickHouse data-root copy through
the existing `OfflineCatalog` and displays bounded physical-row pages from an
exact `MergeTree` table. The viewer is a consumer of `scan_typed_window`, not
a new storage engine or a query interface.

## Admitted surface

- A catalog/database/table tree on the left and a page of selected stored
  columns on the right. Database and table names come from the offline
  catalog; a table is opened when selected, not pre-scanned with its siblings.
  The example selects up to 16 directly supported typed columns and reports
  omitted columns explicitly; it does not pretend an unsupported type was
  decoded.
- The row pane retains at most one page of owned display strings. Each page
  request uses `OfflineTable#scan_typed_window` with a fixed bound no larger
  than `WidePartTable::MAX_BATCH_ROWS`. It copies or formats every value while
  the batch callback is live and never retains borrowed slices. The example
  caps a page at 256 rows and each displayed String cell at 256 source bytes
  before escaping, with an explicit `[truncated]` marker for longer values, so
  a small row count cannot hide unbounded retained text.
- Forward/backward navigation uses zero-based physical-row offsets in the
  reader's resolved part/mark order. A short or empty page means the end of
  that physical sequence. Switching tables discards the old page and resets
  the offset.
- Visible labels distinguish physical part candidates from ClickHouse server
  Active parts. Read failures remain visible rather than silently falling back
  to partial rows.
- The TUI dependency is optional: core library users and the regular spec
  suite do not need `crystal_tui` installed.

## Rejected surface

- Filtering, global sorting, SQL order, server `system.*` parity, joins, or a
  consistent snapshot of a live ClickHouse data root.
- Full-table row materialization, retained borrowed buffers, and an implicit
  scan of every table on startup.
- A claim that a page is decoded one row at a time or that paging improves
  latency/RSS without measurements. Intersecting marks are still decoded.

## Guard-only future

- A virtual-scroll widget or reusable row-source interface may replace
  explicit pages after focus, resize, and cache-invalidation tests.
- Predicate-aware filtering and sort order need a defined result-offset
  contract and bounded execution strategy before being exposed in the UI.
- `pread` and decoded-mark caching remain independent performance experiments.

## Design laws and falsifiers

1. Page offsets and row numbers refer to the same physical sequence as the
   window reader; page changes must not duplicate or skip a row.
2. The retained page is bounded by the requested page size even for String,
   nullable, and numeric values. Non-NULL String values are quoted and
   escaped, so `NULL` differs from the String `"NULL"` and embedded control
   characters cannot break the terminal layout.
3. Opening a table with no supported selected columns or a rejected part set
   reports an error; it never substitutes an unfiltered or partial scan.
4. Invalid metadata encountered during a catalog or page operation is
   surfaced. The root must remain immutable after opening: inventory is
   cached, so adding or removing a part may be missed or fail on a later page
   request. The example provides neither live-change detection nor a
   consistent snapshot of a mutable root.

Required probes: a two-page fixture with a short final page, an empty table,
String with embedded NUL/newline, nullable values, unsupported columns, and a
selection switch that drops the previous page. Probe truncation, its marker,
and bounded output on an oversized String. Compile the optional example
against the local `crystal_tui` checkout and run the regular Crystal specs
without it. A terminal smoke check establishes navigation only where the
actual UI is exercised; compilation alone does not.

Stop if the adapter needs to retain a borrowed batch, silently scans all rows,
or treats physical candidates as authoritative Active parts. The rollback is
removal of the optional example and its adapter; core reader behavior must not
change in this slice.

## Verification seal

- Regular specs, without adding `crystal_tui` to `CRYSTAL_PATH`: debug and
  release each passed 329 examples with no failures or errors.
- Opt-in headless `crystal_tui` harness passed 3 examples. The optional entry
  point passed no-codegen and linked builds against the separate local
  `crystal_tui` checkout. Both the core and UI source passed format checks.
- The adversarial inventory audit found that a post-open new part can
  remain invisible. This is not accepted as live-change detection: an
  immutable root is a precondition, and changing this frontier requires a
  fresh inventory/snapshot contract and new tests. Source changes or a TUI
  dependency upgrade invalidate this seal until the checks are rerun.
