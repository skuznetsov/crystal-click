# Embedded MergeTree W4 Implementation Plan

Status: verified on the bounded W4 frontier. Governed by
`EMBEDDED_MERGETREE_FRONTIER.md`.

## Scope, risk, and rollback

Risk: CAUTION. This adds a persistent table-visibility rule, not another
physical serialization. The new API owns only a caller-chosen, previously
absent Crystal table root. It must not mutate `OfflineCatalog`, an existing
ClickHouse store, or a preexisting part. Rollback is one W4 feature commit;
leave any user-created data root untouched. No push is in scope.

The API is a bounded `EmbeddedMergeTreeTable.create/open`, `insert`,
`part_paths`/orphan inventory, and typed scan for one named `UInt64` key and
one named `String` value. `manifest.json` fixes version and schema;
`committed/<part-name>/` is an empty atomic marker. Only marked parts are
readable. The writer lock protects cooperating inserts on a local filesystem.
The root is not a ClickHouse server table and has no server Active semantics.

The existing consumers were enumerated with
`rg -n 'EmbeddedMergeTreeTable|write_uint64_string_pair|WidePartTable\.open_selected_typed' src spec examples scripts`:
there is no current embedded-table consumer; the String writer is used by
writer specs/oracle, while `WidePartTable.open_selected_typed` is used by
offline and focused read paths. W4 adds a new facade and require line; it
does not change the writer or reader contracts.

## Small steps and falsifiers

1. Add `spec/embedded_merge_tree_table_spec.cr` with RED compile/runtime
   expectations for create, insert, scan, reopen, NUL/UTF-8/empty String
   values, stable block names, and no mutation of an existing root. The
   initial signal should be the missing W4 API, not an unrelated compile
   failure.
2. Implement `src/crystal_click/embedded_merge_tree_table.cr` and require it
   from `src/crystal_click.cr`. Stage and exclusively publish a bounded root
   manifest/layout; validate every fixed entry and symlink boundary on open.
   Pre-mortem: an accidentally accepted foreign root could cause destructive
   writes. Guard: create refuses any existing target; open requires exact
   W4 manifest and layout.
3. Implement cooperating-writer locking, monotone `all_N_N_0` allocation,
   W3 part publication, and the commit-marker `mkdir`. RED probes: an
   unmarked part remains invisible after reopen; a marker without a part
   fails; two handles produce distinct names; a failed insert keeps previous
   rows and leaves no new marker. Do not adopt/delete orphans.
4. Implement read-side inventory and typed scan through the existing
   `WidePartTable`. Reject wrong schema, malformed/overlapping committed
   names, symlinks including part metadata, and unsupported extra entries.
   Explicitly open and validate each primary index; `WidePartTable` alone
   does not. Resolve the inventory under a shared lock against the exclusive
   writer so readers cannot observe a part/marker split; release it before
   row scanning. A child-reader barrier must demonstrate that an exclusive
   lock blocks inventory. Check selected stream sizes but do not claim hash
   integrity. Reject a would-be 1,025th committed part before physical
   publication.
5. Add `examples/embedded_merge_tree_table.cr` using an explicitly new
   temporary/table path. Run focused/full debug and release specs, formatting,
   diff checks, and the pinned W3 ClickHouse oracle. Review the live diff
   adversarially before the W4 commit.

## Definition of Done

At the committed source state: focused W4 specs pass, full Crystal debug and
release suites pass, existing W3 physical oracle remains green, and exact
format/diff checks pass. The recovery negative controls must demonstrate
that physical publication alone is not logical visibility and that a dangling
commit marker does not silently disappear. A changed producer version,
filesystem publication semantics, or current reader/writer invalidates the
corresponding evidence.

```sh
CC=/usr/bin/clang CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w4-cache crystal spec spec/embedded_merge_tree_table_spec.cr
CC=/usr/bin/clang CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w4-cache crystal spec
CC=/usr/bin/clang CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w4-cache crystal spec --release
bash scripts/check_wide_part_writer_oracle.sh
crystal tool format --check src/crystal_click/embedded_merge_tree_table.cr spec/embedded_merge_tree_table_spec.cr examples/embedded_merge_tree_table.cr
git diff --check
```
