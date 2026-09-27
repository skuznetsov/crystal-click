# W22 bounded LowCardinality(String) payload plan

Status: implemented and verified within the pinned W22 boundary. Source:
`EMBEDDED_MERGETREE_FRONTIER.md`, W22. Risk: CAUTION (wrong dictionary state
can yield valid-looking but incorrect String rows). Rollback: one W22-only
local feature commit; no push or mutation of an existing ClickHouse data root.

1. Keep the pinned stock producer fixtures for shared-global `0x500/0x100`
   and per-granule `0x600` forms, including exact substreams, dictionary and
   index bytes, adaptive marks, metadata, full/sparse results, and
   `CHECK TABLE`. Do not infer handmade-part acceptance from stock-to-stock
   probes.
2. Write focused failing specs before production changes for exact type
   admission, dictionary prefix/mark handling, full and keyed mark ranges,
   binary/empty/repeated Strings, dictionary and selected-row byte bounds,
   malformed flags/counts/IDs/trailing bytes, and scalar accessor isolation.
3. Add the exact reader paths in `src/crystal_click/wide_part.cr` and typed
   batch propagation in `src/crystal_click/wide_part_table.cr`. Admit only
   the two observed UInt8/version-1 forms. Load the shared dictionary before
   resolving any selected range; treat per-granule additional keys as local.
   Keep the generic first-mark rule unchanged and validate `.dict` separately.
   Bound and cache one whole-part validation pass (65,536 marks, 64 MiB decoded
   index, 64 MiB decoded dictionary, 262,208 compressed frames per stream),
   then read selected marks without an
   all-marks pass for each granule.
4. Add a named paired writer API in `src/crystal_click/wide_part_writer.cr`.
   Reserve the default empty String at dictionary ID 0 even when no input row
   is empty. Emit only one shared dictionary and `0x500` then `0x100` index headers,
   with exact streams/marks, checksums, matching aggregate-index preflight, staged readback,
   and exclusive publication. Verify stock acceptance independently.
5. Propagate decoded Strings through the offline catalog and bounded TUI
   display; keep equality filters restricted to exact `String` and `UInt64`.
   Do not widen the embedded transactional table validator.
6. Run a pinned bidirectional stock/Crystal oracle for both reader forms and
   the writer form, including full/key-range RowBinary, `ATTACH PART`,
   `CHECK TABLE`, and isolated corruption controls, including an all-nonempty
   writer input. Re-run full debug/release
   specs, focused catalog/TUI specs, earlier type oracles, formatter, shell
   syntax, and Git diff checks. Record the evidence and residual scope in
   the SDD before the local commit.

Definition of Done: the reader returns exact positional and keyed Strings
from both observed stock forms; the Crystal shared-dictionary part attaches
to stock ClickHouse, returns exact full/key-range rows, and passes
`CHECK TABLE`; negative tests fail before bad publication; full regression
and prior-type oracle gates pass. The stock producer probe alone and a green
Crystal self-readback are insufficient.

Observed gate: the full debug and release suites each passed 513 examples;
all 16 pinned stock/Crystal oracle scripts passed, including the W22
bidirectional oracle; formatter, shell syntax, and diff checks passed. The
reader specs additionally reject recomputed-checksum semantic corruptions
and mark-record counts above 65,536 before constructing mark arrays. A
typed table scan releases the LC cache after each part on normal and
exceptional exits; direct `WidePart` instances retain their own cache. This
does not guarantee immediate RSS reduction after GC eligibility. Refresh the
certificate on ClickHouse producer, stream format, reader/writer, or platform
changes.
