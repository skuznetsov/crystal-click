# Object Advanced Shared Storage Frontier

Document status: W191 verified metadata prerequisite and capture; persisted
ADVANCED/CHUNKED storage is not admitted.
Baseline: `c99c9cf` (W190), clean tree at entry, 2026-10-06.
The full read/write types and MV/projections goal remains open. Performance is
deferred until those capabilities are implemented and qualified.

## Required capability and current boundary

Extend the existing recursive Object storage owners to read and write Object
V3 shared ADVANCED (version 2) and ADVANCED_CHUNKED (version 3) in normalized
Wide parts. Preserve the existing MAP and MAP_WITH_BUCKETS bytes and public
APIs. A stock-to-Crystal reader without the corresponding stock-readable writer
is an intermediate result, not completion of this capability.

Currently admitted storage remains W190's finite MAP/MAP_WITH_BUCKETS profiles;
see [OBJECT_SHARED_BUCKETS_FRONTIER.md](OBJECT_SHARED_BUCKETS_FRONTIER.md).
Versions 2/3 remain rejected by the persisted document owners during this
investigation. Compact parts, automatic roster inference, projection envelope
writing, MV dependency execution and performance claims are not added here.

The stock-authored physical capture now provides a discriminator:
root JSON and Array(JSON), explicit ADVANCED versus ADVANCED_CHUNKED, forced
one-row chunks inside two-row physical marks, and empty shared/child controls.
The capture exposes the actual version, bucket count, stream roster,
structure records and whole-shared copy lanes. Chosen settings alone do not
establish the resulting format. This probe prepares the read/write owners; it
does not redefine the requested final state as a stock-only tool.

## Source and runtime anchors

Source: clean shallow checkout
`/Users/sergey/SrcArchives/clickhouse-2026-10-05-depth1-ef037e60`, revision
`ef037e60fc7f5654c8c80eefb8be82e3c56f9a67`.
`SerializationObjectSharedData.h` describes the per-bucket path/substream
metadata and the separate whole-shared copy lanes. `MergeTreeSettings.cpp`
declares `advanced`, `advanced_chunked` and
`object_shared_data_target_chunk_rows`; the executed probe sets the latter
to one. Exact observed layout facts are recorded below.

Runtime: the separately pinned 26.10.1.1201 executable, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
It is not a build of the source snapshot. Native failures are inconclusive
runtime/probe failures, not evidence that a format is illegal.

## Design laws and strongest failure

- Logical Object occurrences, chunk rows and physical parent mark rows are
  distinct axes. Empty Array children do not remove their physical marks.
- Bucket structures must agree on the chunk-row layout used by shared copy
  decoding. Per-chunk dictionaries cannot be replaced by a part-global roster.
- Whole-document copy lanes and per-path data/metadata are two representations
  of the same shared values. A writer must not populate only the copy and leave
  stock path reads wrong or empty.
- Compressed-file marks are transport coordinates, not logical byte offsets.
  Validate both components against their actual target streams.
- Reuse existing scalar/Dynamic serde behind explicit layout owners rather than
  introduce a serializer for each enclosing schema product.
- All new chunk/path/index/name work inherits the caller's budgets. Do not
  reset budgets per bucket or chunk, and do not interpret logical limits as RSS.
- Zero/middle selections retain metadata and complete mark-grid validation;
  selected data must be reconstructed in the original Object occurrence grid.

Likeliest failure: a whole-document round trip passes while stock's independent
path read consumes inconsistent path/substream marks. The paired writer gate
must query both representations, not just `toJSONString` of the whole Object.

## Execution and stop rules

Risk: CAUTION (persistent serialization); initial capture is non-mutating with
respect to user data and creates only task-local stock tables and artifacts.
Rollback: exact scoped Git commit after the declared gates; retain failed
capture roots rather than overwrite them.

1. Source and existing-owner inventories identify the field sequences and
   affected consumers. Luna owns heavy analysis/implementation; root owns
   guarded serial compilation, native execution and independent reconciliation.
2. Add a bounded stock capture with a clean positive control and a seeded
   mismatched field/roster/row-layout check. Run it in a fresh empty root using
   the existing pinned process supervisor and outer `run_safe.sh` guard.
3. Record actual v2/v3 bytes and decide the reusable ownership seam. Write the
   first RED behavioral specs before any production admission change.
4. Implement reader and writer owners, then affected DEBUG/RELEASE regressions
   and paired stock reads / library ATTACH-CHECK / whole and path readbacks.
5. Run hostile review, independently reconcile evidence, and qualify only the
   executed schema/layout witnesses. The larger goal remains active.

Do not relax a version guard to manufacture a passing probe. Stop and
investigate any pin, process, literal, stream-roster or mark-grid disagreement.
Evidence expires when implementation inputs, source/runtime pins, settings or
fixture profiles change; refresh in a new empty root and preserve old failures.

## W191 prerequisite plan

The next implementation is a reusable single-bucket, single-chunk metadata
owner, not a new serializer for each enclosing Array/Tuple/JSON combination.
`ObjectSharedChunkStructure` and `ObjectSharedChunkStructureCodec` each live in
their own file. A record contains a UInt64 row count, a strictly byte-ordered
unique list of opaque path strings, and three pairs of UInt64 compressed and
decoded transport offsets. Zero-row/zero-path records and nonzero offsets are
valid metadata; actual target-stream bounds belong to the eventual storage
owner. The record owns detached path bytes. Context-based read/write entry
points inherit one caller budget; complete-blob entry points reject trailing
bytes. No persisted layout guard changes in this prerequisite.

Exact files and checks:

1. `spec/object_shared_chunk_structure_w191_spec.cr`: execute the missing-API
   RED before production edits, then exact literals, truncation/trailing input,
   unsorted/duplicate paths, opaque bytes, count limits, shared-context budgets,
   detached ownership and full-width transport pairs in DEBUG and RELEASE.
2. `scripts/probe_object_shared_advanced_w191.rb`,
   `scripts/object_shared_advanced_layout_w191.rb` and
   `scripts/stock_part_probe_support_w191.rb`:
   `ruby scripts/probe_object_shared_advanced_w191.rb --self-test` must accept a
   clean control and reject seeded row-layout and dictionary-index corruption.
   A fresh-root stock capture must retain its raw process records and immutable
   part inventory, and decode actual structure/copy streams for root/Array v2
   and v3 plus empty-shared and all-empty-child controls.
3. `scripts/validate_object_shared_chunk_structure_w191.cr`: prebuild in DEBUG
   and RELEASE; decode the native structure records and return field values
   plus exactly reencoded bytes. Independently compare both helpers with the
   Ruby decoder and original bytes, not merely their exit codes.
4. Rerun the inherited 81 affected W190 specs plus the new spec in both modes.
   Existing version-2/3 schema/document/physical refusal tests must still pass.
5. `scripts/reconcile_object_shared_advanced_w191.rb` independently extracts
   records from actual decoded streams, authenticates retained process and part
   artifacts, and compares raw bytes/fields with both helper modes. Summary
   fields and a helper exit code alone do not establish stock provenance.

All compiler and native work runs serially under the existing `run_safe.sh`
guard (600 seconds, 12288 MiB tree RSS, at least 50 percent reported system
memory free); native child processes additionally retain their existing
10-second deadline and two-second TERM grace. The commit gate requires actual
terminal exit codes, independent raw-capture reconciliation, and hostile review
of this bounded metadata/probe claim. Full advanced read/write and stock path
readback remain subsequent work, not success inferred from this prerequisite.

## Observed physical facts

The fresh stock capture at
`/private/tmp/crystal-click-w191-native-final.BxiDQd` returned exit 0 with eight
successful profiles and 100 captured native/decompressor invocations. It
contains 64 combined structure records: 44 in profiles with shared paths and
20 in empty controls. Positive profiles use two buckets; empty controls have
one actual bucket despite the two-bucket setting.

Root ADVANCED has four two-row chunks per bucket; CHUNKED has eight one-row
chunks. Mixed Array(JSON) has logical chunk rows `[0,1,3,0]` in ADVANCED and
`[0,1,1,1,1,0]` in CHUNKED, while every physical lane retains parent `.mrk2`
rows `[2,2,2,2,0]`. All-empty Array controls still contain four zero-row,
zero-path records. Empty-root controls contain four two-row or eight one-row
pathless records. Empty logical data is not absence of structure metadata.

Whole-shared Copy-values are an outer binary String containing a scalar
Dynamic envelope; String values inside that envelope have their own length
prefix. The initial capture failed because the Ruby parser omitted the outer
length, not because the stock format was rejected. The failed capture at
`/private/tmp/crystal-click-w191-native.i3WMOB` is retained; the corrected parser
has literal, opaque-byte, truncation and trailing-inner-byte checks.

These are fixture observations, not admission of persisted ADVANCED storage.
Per-path payloads are captured but not semantically decoded here. Full paired
reader/writer ownership and stock whole-object plus independent path readback
remain required.

## Executed prerequisite qualification and continuation

The missing-API RED returned exit 1 before production implementation. The final
focused DEBUG gate passes 10 examples. The inherited 81 affected W190 spec
files plus the new spec pass 503 examples in each DEBUG and RELEASE run, with
zero failures/errors/pending and actual guard exits 0. Production/spec inputs
are unchanged across those final gates. The later selective helper parser and
Ruby evidence-check repairs do not alter production or spec inputs; both final
helper modes are rebuilt from the repaired source.

The two helpers consume the same 64 native records under cumulative read/write
budgets and produce identical field values and exactly reencoded bytes. Root's
separate reconciler derives those records from actual decoded streams, not the
summary's copied record fields. It authenticates the 100 retained invocation
records and their 500 artifacts, matches all 320 physical filename entries to
the actual part directories, checks 248 `.bin`/`.mrk2` size/SHA pairs plus 16
available checksums/serialization hashes and captured metadata literals, and
reconciles 92 compressed frames and 3,362 structure bytes. Of the 64 records,
27 contain paths and 37 are pathless. `primary.idx` and `statistics.packed` are
roster checked, not individually hash-certified here. This is not a general
part-integrity certificate.

Root also runs both helper modes against mismatched manifest rows, nonminimal
VarUInt, no-record and absent-profile inputs: all reject with the expected
nonzero exit and no stdout. A full-UInt64 metadata fixture with unrelated
large JSON hash numbers passes, preserving every coordinate and reencoded
byte. These ten controls produce identical mode-specific bytes/diagnostics.
The Ruby parser/reconciler seeded controls pass, including the 256/257 path
dictionary index-width boundary.

Retained failed routes distinguish harness defects from format defects:

- The first stock parser missed the outer String envelope around shared
  Dynamic values; the failed native capture remains separately available.
- The first helper used `JSON::Any` and failed on an unrelated unsigned hash
  above Int64::MAX. Selective `JSON::PullParser` skips unrelated fields and
  reads relevant numeric fields as UInt64; full-width controls now pass.
- The first reconciler conflated complete physical filenames with the smaller
  stream-file inventory. The corrected check preserves both namespaces and
  verifies the available metadata hashes/literals separately.

Scoped hostile verdict: ROBUST for the metadata-codec prerequisite after
root's executed raw-provenance reconciliation. The same-lineage source review
is correlated support, not an independent rerun. Commands, input identities,
failed routes and digest-indexed temporary artifacts are recorded in
`.landmark/evidence/object-shared-advanced-w191.json`. The repository does not
provide the standard Landmark packet template/graph validator; JSON parsing,
default-deny changed-path checks and actual reference-digest dereferencing are
the local fallback, not proof of command execution by themselves.

Next frontier: reuse the existing Dynamic/BinaryBulk codecs behind explicit
advanced chunk/bucket payload and copy-layout owners. Add reader and writer
together, retain separate physical-parent/logical-child/chunk coordinates and
caller budgets, then qualify stock-authored reads and library-authored
ATTACH/CHECK with whole-object AND independent path readback. Do not widen the
persisted version guard on the strength of this metadata prerequisite alone.
