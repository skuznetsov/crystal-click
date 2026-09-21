# Multi-part UInt64 Scan Implementation Plan

Status: **implemented and verified**. Risk: **CAUTION** because this adds public
storage API and filesystem discovery semantics.

## Definition of done

```text
crystal spec spec/streaming_scan_spec.cr spec/multipart_uint64_scan_spec.cr spec/part_checksums_spec.cr --link-flags="-fuse-ld=ld"
crystal spec --link-flags="-fuse-ld=ld"
crystal spec --release --link-flags="-fuse-ld=ld"
crystal tool format --check
git diff --check
```

Expected signal: focused and full suites pass; the focused suite proves exact
parser bounds, discovery/symlink rules, overlap rejection before callbacks,
deterministic provenance/order, scratch aliasing, and existing-reader parity.
The checksum suite proves bounded v4 parsing plus selected-entry size checks;
it does not claim hash verification.

Observed signal at the implementation source state: focused `25 examples, 0
failures`; full debug `125 examples, 0 failures`; full release `125 examples, 0
failures`; formatter and diff checks passed. These signals decay if the source,
fixtures, Crystal toolchain, or linker environment changes.

The final adversary pass returned **ROBUST** within the admitted immutable-root,
size-only checksum, and borrowed-slice lifetime boundaries. It specifically
rechecked legacy max-level normalization and ClickHouse-compatible `tmp*`
reservation after their regression coverage was added.

## Steps

1. Add a focused RED spec in `spec/multipart_uint64_scan_spec.cr`. Compose
   temporary table roots from existing public fixtures under deliberately
   shuffled modern part names; add malformed-name, overlap, valid-name file,
   and symlink cases without committing copied binary fixtures.
2. Add `MergeTreePartInfo` in
   `src/crystal_click/merge_tree_part_info.cr`. Parse decimal fields without
   permissive coercion, enforce `Int64`/`UInt32` bounds, expose deterministic
   comparison fields, and implement same-partition range overlap.
3. Add `PartChecksums` in `src/crystal_click/part_checksums.cr`. Parse the
   exact v4 header and compressed-v3 payload with count/name/output limits,
   reject duplicate or unsafe names, and expose selected-file physical-size
   validation. Add focused corruption and existing-fixture tests in
   `spec/part_checksums_spec.cr`.
4. Add `WidePartSet` in `src/crystal_click/wide_part_set.cr`. Bound and inspect
   immediate children, fail closed for valid-name non-directories/symlinks,
   reject overlaps, sort, open all readers, size-check each selected stream
   pair through `PartChecksums`, and then compose the one-pass
   mark-provenance primitive described below.
5. Add the one-pass `WidePart#scan_uint64_marks_into` primitive without
   changing existing APIs. Flush scratch at both capacity and mark boundaries;
   yield exact mark-local and part-local offsets without remapping or decoding
   a shared frame once per mark. `WidePartSet#scan_into` wraps these callbacks
   in `UInt64ScanBatch` and adds checked source offsets.
6. Export the API from `src/crystal_click.cr`; do not change codec, mmap, or
   existing `WidePart` behavior in this slice.
7. Run the focused gates, full debug and release gates, formatter, and diff
   check. Adversarially inspect path classification, integer overflow,
   checksum claim scope, pre-callback validation, provenance, and accidental
   active-part claims.
8. Stage only the owned source, spec, and docs and create one atomic commit.

Strongest expected failure: silently choosing one member of an overlapping
old/new part pair and returning duplicate or stale rows. Guard: same-partition
range overlap is rejected during `open`, before scanning.
