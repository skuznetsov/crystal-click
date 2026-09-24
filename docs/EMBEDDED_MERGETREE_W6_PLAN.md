# Embedded MergeTree W6 Reclamation and Crash-Window Plan

Status: implemented and verified at the W6 diff on parent `a1e515c`.
Governed by the W6 section of `EMBEDDED_MERGETREE_FRONTIER.md`.

## Scope, risk, and rollback

Risk: CAUTION. W6 changes the lifetime of persistent historical part files and
the reader lock duration. It applies only to a caller-created Crystal-owned
`EmbeddedMergeTreeTable` root; no existing user table is reclaimed by tests or
examples. Reclamation is explicit, not background. Rollback is one W6 feature
commit; a table already reclaimed cannot regain deleted history by code
rollback, so current active part bytes must remain unchanged.

Consumer inventory at `a1e515c`:
`rg -n 'EmbeddedMergeTreeTable|part_paths|scan_typed|reclaim_obsolete' src spec examples scripts`
finds the embedded facade, its focused spec and example, the synthetic
ClickHouse merge oracle, and generic reader callers. No production caller in
`src` currently borrows `EmbeddedMergeTreeTable.part_paths`; the example and
oracle use returned paths immediately. W6 must preserve the facade's active
path selection, make scan-held paths safe through callbacks, and document raw
`part_paths` as unpinned.

## Steps and falsifiers

1. Add RED focused cases in `spec/embedded_merge_tree_table_spec.cr` for
   covered historical corruption or absence, active corruption refusal,
   unchanged active rows across explicit reclamation, idempotent retry after
   marker-first interruption, retained uncovered orphans and their next block
   reservation, and cleanup at the 2,048-entry capacity boundary. The first
   expected failure is the absent `reclaim_obsolete!` API or the old inventory
   rejection of covered history, not an unrelated compiler error. Guard:
   compare exact row sequences and active paths before and after GC.
2. In `src/crystal_click/embedded_merge_tree_table.cr`, resolve marker-name
   intervals before physical validation, validate only selected maximal
   active parts, and keep rejecting malformed/equal-range/partial marked
   overlaps. Pin `scan_typed` through callback completion with the shared
   lock; add a scoped borrowed-path callback for direct reader users. The
   pre-mortem is a GC deleting a path after inventory but before a scan maps
   it. Guard: a separate-process reader paused in a callback must delay GC,
   then finish its exact rows before GC may delete source paths.
3. Implement explicit `reclaim_obsolete!` under the exclusive lock. Delete
   covered marker directories before covered physical directories; sweep
   covered unmarked physical remnants and recognizable stale writer stages.
   Never delete active or uncovered physical orphans; these reserve identity
   while no durable allocator watermark exists. Guard: interrupt GC after a
   marker deletion, reopen, rerun GC, and confirm the active rows and paths
   never change. No directory-count-expanding quarantine is allowed.
4. Add test-only compile-time process barriers at stage creation, part
   publication before marker, marker before return, and GC marker-first
   deletion. In a dedicated fault-injection spec build, kill child processes
   at each barrier and assert the before/after snapshot, orphan set, retry
   identity, and GC recovery. Production builds must contain no runtime
   environment-triggered kill or pause hook. These probes do not establish
   power-loss durability or exactly-once insert behavior.
5. Update `docs/EMBEDDED_MERGETREE_FRONTIER.md` and `examples/README.md` with
   the evidenced W6 surface and remaining limits. Run focused debug/release
   specs, fault-injection specs, full debug/release suites, both pinned
   ClickHouse physical oracles, formatting, shell syntax, and diff checks.

## Definition of Done

At the final source state: exact rows and active paths are unchanged by
reclamation; a reader whose callback is in progress survives concurrent GC;
active corruption fails while covered corruption is reclaimable; a killed
writer stage can be removed at capacity; pre-marker and post-marker process
deaths have the specified visibility; marker-first GC is retryable; existing
W3/W5 physical oracles remain green. Broader suites and formatting must pass.
Any change to deletion order, lock lifetime, inventory selection, or writer
publication reopens this evidence. No claim is made about power loss, external
path borrowers without a scoped lease, uncovered orphan reclamation, or
cross-process exactly-once retry.

```sh
CC=/usr/bin/clang CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w6-cache crystal spec spec/embedded_merge_tree_table_spec.cr
CC=/usr/bin/clang CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w6-cache crystal spec -D crystal_click_test_failpoints spec/embedded_merge_tree_table_spec.cr spec/embedded_merge_tree_fault_spec.cr
CC=/usr/bin/clang CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w6-cache crystal spec
CC=/usr/bin/clang CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w6-cache crystal spec --release
bash scripts/check_wide_part_writer_oracle.sh
bash scripts/check_embedded_merge_oracle.sh
crystal tool format --check src/crystal_click.cr src/crystal_click/embedded_merge_tree_table.cr src/crystal_click/wide_part_writer.cr src/crystal_click/test_failpoints.cr spec/embedded_merge_tree_table_spec.cr spec/embedded_merge_tree_fault_spec.cr
bash -n scripts/check_embedded_merge_oracle.sh
git diff --check
```

Observed signals: 26 focused table examples; 30 fault-flag combined examples;
299 full-suite examples in each of debug and release, all with zero failures.
Both pinned ClickHouse oracle scripts and the format, shell-syntax, and diff
checks passed. The strongest recovered counterexample was a covered symlink
or file remnant after its marker was removed: inventory now tolerates it only
when a validated active interval covers the canonical name, and GC unlinks
the entry without following a symlink target. Active and uncovered suspicious
entries still fail closed. A separate test simulates one file already removed
from a covered historical part after marker removal, then reopens and finishes
reclamation; no SIGKILL is injected inside `rm_r` itself.
