# Public nominal Nested bulk part frontier — W202

Status: VERIFIED within the finite public static Nested complete-part corpus
below (2026-10-06); not all recursive products or layouts.
Baseline: `3058ac6f466fff9d735e09c82cbdc77ad86597c5`.
Risk: CAUTION (public storage API and persisted layout). Rollback: one scoped
local commit; no push, no changes to stock source or runtime.

## Contract

Add a direct BinaryValue-based two-column Wide part API for nominal Nested.
The UInt64 key owns the physical parent mark schedule. Nested owns outer sizes
and its implicit named Tuple; existing BinaryBulk owners serialize fields in
the flattened element domain. Do not require a synthetic JSON sibling, add a
serializer per type product, or widen the old typed leaf-buffer API.

Public write entry: `WidePartWriter.write_uint64_nested_bulk_part(destination,
key_name, keys, value_name, type, granules, rows_per_mark: 8192, profile:
BinaryBulkProfile.single_stream, frame_bytes: 4096, metadata_version: 0_i64,
limits: BinaryBulkCodec::DEFAULT_LIMITS, transport_limits:
CompressedStreamLimits.new)`. Values are `Array(Array(BinaryValue))`, one
array per physical mark. `type` must retain nominal Nested identity.
Public read entry: `NestedBulkColumnReader.open(part_path, column_name,
expected_type, limits, transport_limits)`; `read_marks(first, count)` returns
the selected physical marks and their BinaryValue rows.

Design-sealed surface: otherwise-admitted static Nested subtrees, including
LowCardinality and Variant, under the explicit String single/size-stream
profiles, BASIC Variant discriminators, LZ4, hashed names and uncompressed
adaptive marks. Qualification
must cover first-empty element marks, ragged records, NULL/default/repeated LC
labels, both Variant arms and NULL, full/later/final/end-zero windows.

Rejected/guard-only: Dynamic and JSON-containing subtrees; Dynamic needs its
separate structure-stream lifecycle, not just a row codec. Keep existing
illegal child, QBit, depth/element/node/byte and metadata guards. This slice
does not qualify flattened sibling Nested, arbitrary schemas, Compact parts,
legacy specialized layouts, every dictionary schedule or automatic table API
dispatch. MV/projections and all-type compatibility remain open. Memory and
performance work remains deferred.

Source anchors: the inspected, unbuilt depth-one checkout is
`/Users/sergey/SrcArchives/clickhouse-2026-10-05-depth1-ef037e60`, revision
`ef037e60fc7f5654c8c80eefb8be82e3c56f9a67`.
`DataTypeNested.cpp:51-75` resolves children through DataTypeFactory and builds
Array(named Tuple), preserving a custom nominal Nested name.
`SerializationVariant.cpp:199-223` writes the BASIC/COMPACT UInt64 mode prefix
and delegates prefixes to sparse arms. Native fixtures must explicitly set
`use_compact_variant_discriminators_serialization=0`; COMPACT remains rejected.

## Design laws and failure boundary

- Reuse BinaryBulkPhysicalPlan/Codec and the Variant physical-prefix adapter.
  A logical discriminator lane is not itself a physical CH lane.
- Every lane retains the root physical P grid. LC selected windows replay the
  complete dictionary state; Nested field counts still use the element domain.
- Each Nested encode/decode call keeps one cumulative codec budget across its
  recursion, and transport bounds accumulate across Nested value lanes. This
  is not a combined key/index/metadata or whole-part RSS cap.
- The reader assumes a quiescent part. Its stream resolver authenticates
  declared sizes and consumed compressed-frame checksums, not whole unselected
  data-file hashes. Descriptor/name and transport bounds precede their owned
  materialization; semantic codec bounds may reject after transport-bounded
  lane reads. This is not an I/O-free codec rejection or RSS certificate.
- Parse and compare the persisted declaration, exact stream roster and String
  profile. A same-shape Array(Tuple) is not a nominal Nested declaration.
  For this expected-descriptor API the source declaration must match the
  bounded canonical descriptor rendering exactly; noncanonical SQL text is
  not qualified. Do not widen the JSON-only StorageColumnSchemaParser.
- Preflight and encode before staging. Validate checksums, all lane grids,
  keys/index and public readback before exclusive publication. Failure leaves
  no destination or stage and never overwrites an existing destination.
- Keep new owners small and one class per file. Reuse the bounded metadata,
  transport, checksum and publication owners rather than duplicating serde.

Strongest failure: writer and reader agree on a wrong LC occurrence schedule
or Variant header. Native semantic reads in both directions and independent
literal values must discriminate it; CHECK alone does not.

## Execution and falsifiers

1. Capture the missing public API on unchanged production with
   `spec/nested_bulk_part_w202_spec.cr`. Expected RED is compiler/API absence,
   not a claimed runtime serde defect. Existing typed Nested API refusal and
   W201 bulk evidence are separate anchors.
   Observed: guarded actual exit 1, undefined
   `WidePartWriter.write_uint64_nested_bulk_part` at spec line 79 before
   production edits. The unchanged ten-file baseline passes 60 examples,
   zero failures/errors/pending, guarded actual exit 0.
2. Implement only the direct nominal Nested public adapter and owners. Keep
   old APIs source-compatible. Exact production ownership is recorded in the
   implementation/evidence section after the inventory is resolved.
3. Root runs the focused spec and the affected Nested/BinaryBulk/part transport
   roster serially in DEBUG and RELEASE. Expect zero failures/errors/pending
   and actual exit 0; run formatting and diff checks separately.
4. Build `scripts/check_nested_bulk_part_w202.cr` in both modes. Run fresh
   bounded `scripts/probe_nested_bulk_part_w202.rb` captures: stock-created
   Nested -> public reader, library-written Nested -> stock ATTACH/CHECK and
   independent SELECT literals, both String profiles.
5. Attack malformed off-window lanes, nominal substitution, wrong profile,
   truncated/extra values, budget boundaries and atomic failure. A seeded
   violation must be detected by the unchanged behavioral oracle.

All compiler/native work is root-serial through the existing unchanged
`/Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh` guard,
`COGNI_RUN_SAFE_MIN_FREE_PCT=50 RUN_SAFE_PASSTHROUGH_STDIO=1`, 600 seconds,
12288 MiB, isolated cache/TMPDIR and Xcode SDK. Crystal uses `--single-module
--threads 1 --link-flags=-fuse-ld=ld --error-trace`; RELEASE adds `--release`.
The native runtime and inspected source revision are recorded separately;
neither is a certificate for an unexecuted latest build.

Stop and narrow if source/native observations contradict nominal Nested's
Array-of-named-Tuple carrier law. Never erase the declaration, suppress an
illegal edge, alter the literal oracle or relax a guard to manufacture green.

## Implementation seal

Owned production paths: `src/crystal_click/nested_bulk_column_reader.cr`,
`src/crystal_click/nested_bulk_column_writer.cr`,
`src/crystal_click/wide_part_writer/nested_bulk_part_writer.cr`, plus additive
facade/requires in `src/crystal_click/wide_part_writer.cr` and
`src/crystal_click.cr`. Existing typed Nested and recursive JSON APIs remain
unchanged. The adapter delegates leaf serde to existing BinaryBulk owners;
it adds the missing direct complete-part storage envelope, not a new serializer
for each type product.

## Executed qualification

The final focused spec passes nine examples. The same exact 153 affected
files pass 989 DEBUG and 989 RELEASE examples, zero failures/errors/pending,
actual serial guarded exits 0. This is an affected regression gate, not a full
repository suite. The unchanged final 953-file src/spec identity is
`5064262ca1aa8b7b6532822bc6debf409784ec3e9e104059f6f2e21b2d28af0f`.

Fresh final helpers and native captures in both modes exercise
`Nested(label LowCardinality(Nullable(String)), choice Variant(String, UInt64),
text String)`, eight parent rows across four two-row physical marks, under
String single/size-stream profiles. Each mode reads both stock-created and
library-created parts through the public reader, ATTACHes two library parts,
and checks six native CHECK results. Independent SELECT literals authenticate
84 selected-value rows per mode (28 initial stock plus 56 attached
stock/library), not 84 distinct fixture rows. Full/first-empty/later/final and
end-zero windows are covered. Direct String and the String Variant arm add
size lanes; LC's dictionary remains on its own default String profile.

Root independently inspected the production changes, reconciled raw process
argv/SQL/output hashes and actual exits, checked nominal types and literal
NULL/default/repeated/String/UInt64 values, and rehashed all 106 published
stock/generated part files per mode. They remain unchanged. Generated part
bytes and normalized helper observations agree across DEBUG and RELEASE.
The final capture roots are
`/private/tmp/crystal-click-w202-native-debug-final.Gr50Mx` and
`/private/tmp/crystal-click-w202-native-release-final.FC2Ppo`.

The unchanged focused behavioral oracle detects a root-seeded production
defect that disables complete LC replay: nine examples, two failures, actual
exit 1. The production file was restored byte-exactly before final gates.
Malformed off-window size/index counts, LC mark boundaries, Variant physical
mode, nominal substitutions, stream rosters, budgets and atomic publication
are covered by the focused spec. Root additionally rejects 31 raw-capture or
helper-report mutations per native mode while accepting the originals.
Scoped Adversary verdict: ROBUST. Static Luna review is correlated, not an
independent compatibility certificate.

Final Crystal formatting, Ruby syntax/self-test and diff checks pass. Commands,
exact affected roster, diagnostic failures, source/runtime separation, hashes
and residual risks are indexed in
`.landmark/evidence/nested-bulk-parts-w202.json`. Scratch logs and captures are
outside Git; the packet is an evidence index, not proof by itself. Refresh this
qualification after an owner, profile, descriptor admission, runtime or
physical-format change. Missing captures require rerunning the bounded probe.

Next boundary: a direct Dynamic/JSON-containing Nested owner must carry the
per-site structure roster, prefix/body state and occurrence domain through
the public part envelope. Reuse codecs recursively; do not bypass this state
with a scalar self-roundtrip or erase nominal Nested identity. That boundary,
broader layouts, MV/projections, repository-wide decomposition and performance
remain open.
