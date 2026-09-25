# Offline TUI Equality Filter Frontier

Document status: implemented and locally verified for the immutable-root,
headless-example scope on 2026-09-25. The unfiltered viewer remains governed
by `TUI_WINDOW_VIEWER_FRONTIER.md`. This slice adds one exact equality
predicate to the optional example, not a general query API or a storage-engine
index.

## Factual anchor and reason

At the unfiltered baseline, `OfflinePageSource#load` requests a bounded
physical window through `OfflineTable#scan_typed_window` and formats all
returned rows. The viewer labels rows by assuming every row in the window is
displayed. A filter breaks that assumption. A result-count page would need
to scan an unbounded number of physical rows when matches are sparse. The
existing reader decodes intersecting marks, so window size is a bound on
logical rows requested, not necessarily on decoded mark work.

## Admitted behavior

- One equality predicate `column=value` at a time, on a selected directly
  stored `String` or `UInt64` column. `String` equality compares the raw
  borrowed string bytes before display escaping/truncation; `UInt64` equality
  compares typed values. The UI parses unsigned decimal for `UInt64`, and
  preserves every accepted character after the first `=` for `String`
  (including ordinary spaces and further `=` characters). Empty String is a
  valid value.
- Each `load(start_row)` examines only the physical interval
  `[start_row, min(total_rows, start_row + page_rows))`. The returned page
  carries an exclusive physical `end_row`, physical `row_offsets` aligned with
  its displayed rows, and the unchanged physical `total_rows`. The displayed
  row count can be zero before EOF. PageDown advances to `end_row`; PageUp
  returns to the preceding physical window. No hidden scan-ahead fills a
  page with matches.
- Changing or clearing a filter resets to physical offset zero. Invalid
  syntax, unsupported column/type, or an unparseable value leaves the
  previous filter and page intact and reports an error. A new table clears
  the filter.
- The UI offers a small edit mode: `/` from the page pane opens the filter
  input, Enter applies it, Escape cancels, and `c` clears the active filter.
  `q` while editing is input, not an app quit command. Tab and Shift+Tab are
  consumed while editing, keeping the input focused. Input is capped at 512
  source bytes and rejects terminal/C1 controls plus a defined set of
  invisible Unicode formatting characters (U+00AD, U+034F, U+061C,
  U+180B..U+180E, U+200B..U+200F, U+2028..U+202E, U+2060..U+206F,
  U+FE00..U+FE0F, U+FEFF, U+FFF9..U+FFFB) before they reach the raw-rendering
  `Tui::Input`; the adapter itself may compare arbitrary raw String bytes.
  Values containing those rejected characters cannot be entered through this
  UI. The existing unfiltered page path remains available.
- Only matched rows are formatted for display, and only while the batch
  callback is live; borrowed slices cannot escape. The existing 256-row page
  and 256-source-byte String display caps remain in force.

## Rejected and guard-only behavior

- Rejected: result-relative page numbers, match counts, global sort,
  arbitrary expression predicates, server `system.*` parity, live-root
  consistency, and any claim that equality uses the primary key or skips
  marks. This is a sample consumer of the existing reader. Unicode
  confusable/homoglyph normalization is also rejected; the input guard is not
  a general Unicode security boundary.
- Guard-only: Nullable and other numeric predicate types, multi-predicate
  expressions, filter persistence across tables, search-until-N-matches,
  decoded-mark caching, and a generic library-level filter API. Each needs
  its own type and cost contract.

## Risk, falsifiers, verification, and rollback

Risk tier: CAUTION for a user-visible paging/API semantic change, limited to
the optional example and its specs. No core reader or serialized storage
change is admitted. The strongest failure is treating an empty filtered page
as EOF or using displayed/truncated text for equality. Guard with fixtures
whose matching rows occur after a zero-hit window and whose raw String value
differs from its display representation. Also exercise `q` inside edit mode,
invalid input preservation, physical row labels, exact EOF, and switching
tables. Core specs must still pass without `crystal_tui`; optional headless
harness specs and a linked example build must pass with the local sibling
checkout. These checks do not prove live terminal interaction or performance.

The rollback is one feature commit reverting the optional page source, widget,
spec, and documentation edits. A mutable data root invalidates the underlying
viewer precondition and this filter's observations.

## Small implementation plan

1. In `spec/offline_tui_page_source_spec.cr`, add failing physical-window and
   raw typed equality probes; then change only `examples/offline_tui/page_source.cr`
   to expose the page offsets and filter. The failure signal is a nonmatching
   page incorrectly promoted to EOF, or any equality match on formatted text.
2. In `examples/offline_tui/spec/browser_spec.cr`, add failing input/navigation
   probes; then change only `examples/offline_tui/offline_table_browser_widget.cr`
   to wire the edit mode. The failure signal is `q` quitting during edit mode,
   a false row offset, or an invalid filter destroying the current page.
3. Update `examples/README.md` and the baseline viewer frontier to point to
   this bounded addition. Run the adapter spec, opt-in headless UI spec, full
   debug and release core specs, a linked optional example build, Crystal
   format checks, and `git diff --check` at the final source state. Review
   the exact diff before staging only these paths for one atomic commit.

## Verification seal and decay

At this source state, the core suite passed in debug and release mode (333
examples each, zero failures), including ten focused page-source examples.
The opt-in `crystal_tui` headless harness passed (six examples, zero failures),
the optional example linked, and Crystal formatting plus `git diff --check`
passed. The host needed `--link-flags='-fuse-ld=ld'`; the sibling TUI library
emitted `Time.monotonic` deprecation warnings. These checks cover an immutable
data root and exercised fixture types, not real-terminal interaction, every
possible input sequence, or a performance comparison.

The U+2028 paste regression failed before the input-guard correction and passed
after it. A subsequent read-only adversary pass found no remaining blocker for
the enumerated Unicode families and this headless immutable-root contract;
this verdict does not claim general Unicode or live-terminal safety.

This seal decays when the reader, catalog/part resolver, page source, widget,
TUI dependency, or fixture contract changes; rerun the core and opt-in checks
before reusing it. A data-root mutation after opening a table voids the
snapshot precondition rather than triggering an automatic refresh.
