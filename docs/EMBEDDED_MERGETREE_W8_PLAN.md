# Embedded MergeTree W8 Recorded Index Hash Plan

Status: implemented and verified at the W8 diff on parent `df4a547`. Governed by
the W8 section of `EMBEDDED_MERGETREE_FRONTIER.md`.

## Scope, risk, and rollback

Risk: CAUTION. A trusted-looking but wrong index can silently omit rows from
a primary-key candidate scan. W8 compares the recorded ClickHouse physical
file hash with the exact bytes decoded from each active raw `primary.idx` on
the Crystal-owned embedded candidate path. It changes no stored part bytes,
default size-only checksum API, offline catalog behavior, or full-scan API.
Rollback is the single W8 feature commit; W7 candidate scanning remains
available at its earlier, narrower integrity contract.

Consumer inventory at `df4a547`: `rg -n 'PrimaryKeyIndex\.open\(|PartChecksums\.entry\(|\.file_hash\b|ChecksumVerification' src/crystal_click spec examples`
finds embedded inventory and candidate calls, one offline-catalog call, three
writer readbacks, and the existing checksum-verification enum/reader getters.
Only the embedded candidate call opts into recorded-hash checking. Retaining
the parsed hash must not promote `ChecksumVerification::SizeChecked` elsewhere.

## Steps and falsifiers

1. In `spec/embedded_merge_tree_pk_range_spec.cr`, create a synthetic table
   with a multi-mark part, replace its `primary.idx` by a same-length,
   monotone but false index, and require `CorruptPartError` before any callback
   even when the corrupted schedule selects no marks. Repeat with a later
   active part after an earlier part could have emitted a callback. First run
   this as RED: the existing W7 path accepts the altered index.
2. In `spec/part_checksums_spec.cr`, pin little-endian extraction of the
   recorded 128-bit physical hash using a writer-produced index, and keep a
   size-only API control. A malformed or truncated hash remains a parse
   failure. Do not use private table values or paths.
3. In `src/crystal_click/part_checksums.cr`, retain the two little-endian
   `UInt64` words from each v4 checksum entry. In
   `src/crystal_click/primary_key_index.cr`, add an explicit opt-in check of
   `CityHashV1.file_hash` over the already-read bounded physical index bytes;
   reject mismatch before decoding keys or returning a schedule. In
   `src/crystal_click/embedded_merge_tree_table.cr`, opt in only from
   `scan_uint64_pk_candidates`, which already preflights all active parts.
   Guard: no generic `ChecksumVerification` promotion, no second index read,
   and no callback before a later-part mismatch.
4. Update `examples/README.md` and the W8 SDD status to the evidence actually
   obtained. Run focused PK/checksum specs, full debug and release suites,
   W6 fault specs, both pinned ClickHouse physical oracles, formatter, and
   diff checks. Adversarially inspect the modified parser byte order, default
   call behavior, and assumptions about an intact `checksums.txt`.

## Definition of Done

At the final source state, unchanged writer-produced indexes retain W7's
candidate/residual rows. Both first- and later-part same-size monotone index
corruptions fail before any callback; parsed recorded hash matches the
writer's physical-file hash; legacy size-only callers remain size-only. This
detects inconsistent index bytes when `checksums.txt` is intact, not malicious
coordinated rewriting, arbitrary file corruption, or power-loss failures.

```sh
CC=/usr/bin/clang CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w8-cache crystal spec spec/part_checksums_spec.cr spec/embedded_merge_tree_pk_range_spec.cr
CC=/usr/bin/clang CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w8-cache crystal spec -D crystal_click_test_failpoints spec/embedded_merge_tree_table_spec.cr spec/embedded_merge_tree_fault_spec.cr
CC=/usr/bin/clang CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w8-cache crystal spec
CC=/usr/bin/clang CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w8-cache crystal spec --release
bash scripts/check_wide_part_writer_oracle.sh
bash scripts/check_embedded_merge_oracle.sh
crystal tool format --check src/crystal_click/part_checksums.cr src/crystal_click/primary_key_index.cr src/crystal_click/embedded_merge_tree_table.cr spec/part_checksums_spec.cr spec/embedded_merge_tree_pk_range_spec.cr
git diff --check
```

Expected signal: each command exits zero. A seeded same-size corruption must
fail the focused test without checking an unrelated structural condition;
the unmodified control must stay green. Changes to index serialization,
checksum envelope parsing, or the pinned ClickHouse version reopen the W8
evidence.

Observed signal: the first-part behavioral test was RED before source changes
(`11 examples, 1 failure`: the false monotone index raised no error). After
the opt-in hash check, focused specs passed 20/20, including a later-part
pre-callback failure, default size-only behavior, truncated-hash parsing,
old `Entry.new` positional compatibility, and both Crystal-writer and public
ClickHouse fixture hash agreement. Full debug and release suites each passed
314/314; the W6 fault-flag regression passed 30/30; both pinned ClickHouse
physical oracles passed. The example typechecked, and source/spec formatting
and diff-whitespace checks passed. These checks establish only the scoped
recorded-index consistency behavior, not a cryptographic or complete-part
integrity guarantee.
