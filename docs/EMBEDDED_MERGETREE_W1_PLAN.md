# Embedded MergeTree W1 Implementation Plan

Status: W1 implemented and verified within the bounded SDD scope. Governed by
`EMBEDDED_MERGETREE_FRONTIER.md`.

## Objective and ownership

Create one ClickHouse-compatible immutable Wide part from two `UInt64`
columns, then independently attach and query it with the pinned
`clickhouse local` build. This is the first physical writer slice, not a
mutable table API or a merge operation.

The new code owns only the destination directory it creates. Tests use
synthetic values in fresh temporary directories. Existing fixtures, private
Tokenomics data, source archives, and live ClickHouse paths are read-only.
Rollback is by reverting the coherent W1 feature commit after verification;
there is no remote push in this task.

Risk: CAUTION. A syntactically plausible but subtly invalid part can poison a
later table operation. The strongest counterexample is a part that passes
Crystal self-readback but fails stock ClickHouse `ATTACH` or returns shifted
rows at a mark boundary.

## Small steps and discriminating signals

1. **Format oracle and RED probe.** Inventory the actual two-column public
   fixture and ClickHouse source tag `v26.7.1.1315-stable` for required
   files, compressed frame checksums, mark/index layout, and
   `checksums.txt`. Add `spec/wide_part_writer_spec.cr` to request a
   two-column part and check
   exact values, multiple marks, final sentinel, and no publication for
   invalid inputs. Run it once before production code; the expected signal
   is a missing writer/API failure, not an unrelated compiler failure.
2. **Primitive encoders.** Add only the checksum/hash and LZ4 block-writing
   support needed by W1 under `src/crystal_click/`. Test deterministic bytes
   against source-backed vectors or a freshly produced ClickHouse block,
   including the empty and block-boundary cases. Do not assume an LZ4 payload
   that our decoder accepts is a valid ClickHouse frame.
3. **Part assembly and publication.** Add
   `src/crystal_click/wide_part_writer.cr` and require it from
   `src/crystal_click.cr`. Emit exact `UInt64` little-endian data, `.mrk2`,
   `primary.idx`, required metadata, and versioned part checksums. Validate
   equal lengths, nonempty values, nondecreasing primary keys, safe distinct
   names, row/granule/byte limits, and absent destination before staging.
   Close and validate staged files before a same-filesystem rename; clean up
   only uniquely owned staging paths on failure.
4. **Independent ClickHouse consumer.** Add
   `scripts/check_wide_part_writer_oracle.sh`. It must create its own
   `mktemp` ClickHouse-local `--path`, create the matching MergeTree table,
   derive its `data_paths` from `system.tables`, copy only the generated
   synthetic part into that table's `detached/all_1_1_0`, execute
   `ALTER TABLE ... ATTACH PART 'all_1_1_0'`, compare exact sorted
   `(pk, value)` rows and a bounded key-range result, and require a clean
   `CHECK TABLE`. This attach procedure was first checked against the
   existing public fixture; that proves the oracle setup, not the new
   writer. A stock ClickHouse rejection is a red gate even if the Crystal
   reader passes.
5. **Adversarial closure.** Probe a same-size one-byte `primary.idx` mutation
   and require `CHECK TABLE` to report failure; exercise a second mark
   boundary, a short final granule, forced post-assembly publish failure,
   and a same-destination writer race. A full scan is not a content-hash
   integrity oracle. Inspect the complete diff and confirm it contains
   neither private data nor unrelated edits. Only then update the SDD record
   and commit exact W1 paths.

## Definition of Done

At the final source state, run `crystal spec spec/city_hash_v1_spec.cr
spec/wide_part_writer_spec.cr --link-flags='-fuse-ld=ld'`,
`scripts/check_wide_part_writer_oracle.sh`,
`crystal spec --link-flags='-fuse-ld=ld'`, `crystal tool format --check`,
and `git diff --check`. Run the full suite in release too. Expected signals:
all relevant tests pass; ClickHouse returns every expected pair, passes clean
`CHECK TABLE`, and fails that check after raw-index mutation; failure probes
leave no published part; an adversarial review finds no blocker within W1.
The SDD records the command results and pinned ClickHouse version.

If the oracle cannot attach this part or its behavior differs from the pinned
source, stop widening scope. Preserve the failing synthetic artifact only in
a temporary local test directory long enough to diagnose the mismatch; do not
commit a supposedly compatible fixture or claim success from self-readback.

## Follow-on, not part of W1

Type-by-type writers, a durable active-part manifest, an insert API, merging,
recovery, and execution filtering require new admitted slices and tests. Do
not start them merely because W1's local checks pass.
