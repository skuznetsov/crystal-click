# Lazy Window Reader Plan

Status: functional reader slice verified; optional UI and performance work
remain. Governing boundary:
[LAZY_WINDOW_READER_FRONTIER.md](LAZY_WINDOW_READER_FRONTIER.md).

Risk: CAUTION (new public reader API and row provenance). Rollback: one atomic
feature commit after verification; before that, revert only this task's exact
paths. Do not change the default I/O backend or file-format limits.

Definition of done: focused window specs pass in debug and release, the full
Crystal spec suite passes in debug and release, `crystal tool format --check`
and `git diff --check` pass, and a small example reads the same visible rows
as the existing typed scan. A performance improvement is not part of this
functional DoD.

## Steps

1. `spec/lazy_window_reader_spec.cr`: first add failing tests for an intra-mark
   window, mark and part crossings, last/empty/invalid windows, typed String
   and Nullable values, physical provenance, callback exceptions, and a
   skipped corrupt payload. Expected first signal: the new API is absent.
2. `src/crystal_click/wide_part_table.cr`: add a bounded typed window method
   using checked physical row intervals. Reuse the existing selected-mark
   typed materialization, skip disjoint payloads, and crop callback slices
   and offsets. Preserve `scan_typed` and candidate-scan behavior. Guard:
   focused old typed, multipart, and candidate specs remain green.
3. `src/crystal_click/offline_catalog.cr`: expose the same operation through
   the catalog after the existing DDL/source/type validation. Keep synthetic
   system tables and non-MergeTree engines outside this first slice. Guard:
   mismatch and unsupported-path tests fail before callback exposure.
4. `examples/read_typed_window.cr` and any optional UI adapter: show bounded
   page retrieval without calling `.values` or retaining borrowed slices.
   A `crystal_tui` sample must remain optional and must not add a core shard
   dependency. Guard: only the viewport plus bounded overscan is retained.
5. Inspect allocation and I/O traces for adjacent and distant windows before
   changing workspace lifetime or adding `pread`. Report first-window latency,
   allocation, and RSS separately; keep optimizations proposed if no
   discriminating measurement is available.

Steps 1–3 and the command-line example in step 4 are complete. The optional
TUI adapter and step 5 are deferred. The existing `crystal_tui` `DataTable`
retains every row, so virtual paging needs an example-local custom widget or
a row-source interface; it must not hold a reader callback open while idle.
No allocation or I/O improvement is claimed.

Consumer inventory: `rg -n 'scan_typed\(|scan_typed_candidate_marks\(|part_mark_row_counts|WidePartTable\.open_selected_typed' src examples spec`
finds direct callers in `embedded_merge_tree_table.cr`, `offline_catalog.cr`,
examples, and typed/JSON/Nullable/PK specs. The plan adds a new method and
reuses private scan machinery; it does not change those public signatures.

Premortem: cropping a materialized mark can report the mark's offset instead
of the first exposed row; windows across caller-ordered parts can duplicate or
omit a row; a viewport can accidentally retain borrowed slices; and a
"skipped" mark can still be decoded by a whole-table scan helper. The tests
above target these failures directly. The strongest fallback check is parity
against an independently collected full typed scan on the public fixtures.

Adversary: inspect the diff for accidental reads of skipped payloads,
unchecked interval arithmetic, changed preflight timing, unbounded retained
rows, and misleading memory/performance claims before committing.
