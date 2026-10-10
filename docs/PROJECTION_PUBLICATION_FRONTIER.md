# Precomputed projection publication frontier (W256)

Status: VERIFIED / root adversary ROBUST within the finite W256 target.
Current frontier: caller-precomputed, non-nested Wide projection children are
published with their parent; SQL materialization and general MV execution remain
unimplemented. Qualification date: 2026-10-10.
Baseline: `fdb644a2faa66be7ab7b0ec9ecfaacd267ea8d4f` (clean tree).
Context: caller-owned materialization and physical part publication, not SQL
projection evaluation or proof of equivalence to a SELECT definition.

## Source law and admission

Reference: official shallow ClickHouse checkout
`/private/tmp/clickhouse-w254-upstream.AqeqyC`, revision
`ed30948f095ecb70679986d7d60e27ad770ae27a`. This is not the runtime build.
Runtime oracle: 26.10.1.1201, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, executable SHA256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.

`MergedBlockOutputStream.cpp:233-239` folds each finalized projection into the
parent checksums as `<name>.proj`. Its size is the sum of the child checksum
entries, not directory size or all sidecar bytes. Its hash is zero-key CH
SipHash-128 over sorted entries: LE UInt64 filename byte length, filename bytes,
LE low/high file hash. `MergeTreeDataPartChecksum.cpp:99-105,333-361` and
`SipHash.h:70-90,196-202` specify those laws. It uses CH's ordinary `0xff`
finalization, not reference SipHash-128. `checkDataPart.cpp:436-438` recomputes
the child summary. A locally readable child does not establish this contract.

Admitted surface:

- An explicit `WidePartProjection.precomputed` owner and optional
  `projections:` to `WidePartWriter.write_uint64_columns`. The owner retains
  its bounded ASCII name, detached UInt64 keys, value-column owners and an
  independent rows-per-mark schedule. It has no raw-file injection interface.
- Reuse the generic N-column writer and all existing per-column admissions.
  Parent and child can have different keys, column order and row/mark counts.
  The caller must supply the correctly computed projection data and matching
  table DDL. Physical validity cannot certify semantic provenance or freshness.
- Stage every child under the unpublished parent, validate each through the
  normal typed writer, register its exact summary, then atomically publish the
  complete parent. No child may be published independently of the parent.
- Share operation-wide planning, codec, transport and readback budgets across
  the parent and all children. Bound projection count, names and total checksum
  roster; reject duplicate names, unsafe paths, symlinks and collisions.
- Keep plain-file selected-entry validation size-only. The staged writer uses
  explicit `.proj` child-summary validation; directory inode size is never a
  proxy. Existing public selected-projection reads still do not authenticate
  the parent's `.proj` entry; that reader-integrity seam remains open.

Rejected / non-guarantees:

- Nested projections, arbitrary directories/file bytes, empty child parts,
  non-UInt64 primary-key writer profiles and unadmitted column owner layouts.
- Projection SELECT parsing/computation, aggregate execution, automatic
  materialization, data-equivalence certification, optimizer policy, server
  Active/freshness semantics, Compact writing or MV capability widening.
- General cross-version compatibility, every type/product inside projections,
  performance/RSS claims or the global <=10% speed target.

## Observed qualification and falsifiers

The same ordered 29-file affected roster passes 84 + 79 = 163 examples in each
DEBUG/RELEASE mode, zero failures/errors/pending. Both separately built helpers
and two fresh reciprocal native cells pass against the sealed 17-file
source/spec/runner hash roster. The evidence index records the executed commands,
compiler/helper/runtime pins, capture digests and refresh boundary:
[root-owned W256 evidence](../.landmark/evidence/projection-publication-w256.json).
This is not a full-repository test-suite result.

The finite native schema is `id UInt64, score UInt64, label String,
items Array(UInt16)`. It includes NUL/UTF-8/empty strings and ragged arrays.
The projection uses `score` as its key, a different declaration/sort order,
and a different row grid: parent and stock child [2,2,2]+EOF, library child
[3,3]+EOF. Stock reads through the public consumers and library ATTACH,
CHECK=1, exact schema and literal RowBinary reads succeed in both modes.
Forced reads return the projection rows, and the executed EXPLAIN contains
exactly one `ReadFromMergeTree` node whose description is `by_score`.
`optimizeUseNormalProjection.cpp:822` sets that description; the optional
analysis `Projections` array in `ReadFromMergeTree.cpp:6331-6363` is not the
projection-use witness. Merely seeing the name in analysis is insufficient.

Root independently decodes 12 streams per parent/child pair across the four
stock/library pairs, recomputes the sorted checksum-summary input and ordinary
CH SipHash-128, and checks the exact parent summary entry. All 40 generated
files / 4,715 bytes per mode agree by actual bytes. Twelve missing/size/hash
summary controls reject. Native capture replay independently checks process
status, pinned argv/artifacts, raw CHECK and six complete literal rows for
each of five queries per cell. Eighteen forged-green nonzero-exit, six raw
CHECK=0 and ten false projection-plan controls reject; original acceptance is
rechecked and captures remain unchanged. These are audit acceptance controls,
not exhaustive production corruption coverage.

Behavioral RED witnesses are retained: the old flat parent/child writer omits
the parent summary; temporarily removing the final child-path guard admits a
path one byte over the reader limit. Final tests cover detached input ownership,
invalid/duplicate names, collisions/symlinks, independent grids and row counts,
shared write/read budget exhaustion and exception cleanup without publication.
The exact 4096/+1 path probe tests preflight, not OS path-length portability.
The numeric-array prerequisite below passes both admitted String-version
profiles; unknown versions, false propagation, Sparse and duplicate/missing/
extra substreams remain rejected before callbacks.

Corrected harness diagnostics are excluded from qualification. In particular,
Ruby 2.6 JSON parsing retagged a binary capture owner's encoding without changing
its bytes; the root auditor now parses a duplicate and compares the untouched
owner. The corrected full audit, a matching-byte positive and one-byte-change
negative pass. No production source change was needed for that diagnostic.

## Next local track

Keep type/layout qualification and the selected-reader parent-summary integrity
seam explicit. The next MV execution slice should scan one selected source part
through existing DDL/type preflight, invoke a caller-owned Crystal transform,
and publish schema-bound detached output only after successful completion.
Filtering and recomputed output keys must be observable; wrong target schema
or a callback failure after partial processing must leave no destination.
This is proposed, not implemented, and cannot certify SQL equivalence,
provenance, freshness or trigger semantics. Broad facade decomposition and the
full goal remain IN_PROGRESS/ACTIVE; memory/performance stay deferred.

## Plan, guards and rollback

Risk: CAUTION (persistent directory/checksum envelope and writer API).
Rollback: one exact-path local feature commit; no dependency or remote change.
Strongest failure: Crystal reads a synthetic child but CH treats it as broken
or ignores it because the parent entry or child summary is missing/wrong.

Consumer inventory: `rg` over `write_uint64_columns`,
`WidePartPublisher.write`, `WidePartPublicationInput.prepare`, and `finish64`
found the generic operation, the legacy two-column publisher caller, W245-W255
helpers/fixtures, and W190 SipHash vectors. Preserve default no-projection
behavior and the two-column publisher path. The existing W217 synthetic-child
and W229 stock-authored-reader fixtures do not prove reciprocal publication.

1. Run a real baseline falsifier using the existing flat writer for parent and
   child. It demonstrates that recursive composition alone omits the parent
   checksum entry. Record the failed assertion before production edits.
2. Add one-file projection input and summary owners; extend generic operation
   and publisher only at the publication boundary. Retain the current codecs.
3. Execute focused API/hash/budget/cleanup tests plus affected writer, checksum,
   selected-projection and SipHash regressions in DEBUG and RELEASE.
4. Build a separate helper in both modes. Generate a stock normal projection,
   read it, and generate a library parent/child with deliberately different
   sort order and granule schedules. ATTACH, CHECK and exact parent/child reads
   must succeed; an executed forced projection plan must identify the child.
5. Hostile controls: wrong/missing summary, rejected names/duplicate children,
   post-input mutation, destination conflict, budget exhaustion and no leaked
   staging directories. Root independently checks raw summary bytes and native
   capture status; a fabricated green summary with nonzero process status fails.

DoD commands: root-only serialized guarded `crystal spec` with
`CRYSTAL_WORKERS=1`, `--threads 1 --single-module` in DEBUG and RELEASE;
guarded separate helper builds; bounded native runner with the pinned executable.
Use the unchanged `run_safe.sh` minimum-free-memory gate of 50%, timeout 600s,
memory 12288MiB. CH child thread=1, memory<=512MiB, bounded timeout/termination.
Expected: zero failures/errors/pending; correct child summary and native
ATTACH/CHECK=1/exact schema and values/actual projection-use witness.

Stop or narrow if native metadata, summary or use differs. Do not weaken the
oracle, guards or semantics contract to obtain a green result. Qualification
decays on writer, checksum/hash implementation, source/runtime or fixture drift.
The full goal remains ACTIVE and performance remains deferred.

## Necessary consumer guard repair

The first focused DEBUG run compiled after a nullable exception-message test
fix, then reported 28 examples, zero assertion failures and two errors. One
was a read-only String-slice test assumption. The other was a real consumer
gap: the legacy numeric-array reader rejected an always-Default, four-column
part emitted by the generic writer. It required global String version 1 and
a two-column schema, even though the selected `Array(UInt16)` contains no
String and its data/size streams do not depend on unrelated columns.

Source anchor: `SerializationInfo.cpp:432-442,505-509,742-770` makes an empty
statistics roster mean Default for omitted columns;
`DataTypeArray.cpp:61-66` selects its nested serialization;
`SerializationArray.cpp:352-397` emits sizes and delegates element serde.
The global String versions admitted by this library remain 0 and 1.

Admit the smallest prerequisite repair only for already-supported primitive
numeric arrays: accept those two known global String versions and an empty
Default statistics roster in a bounded multi-column schema with a UInt64
key candidate. Preserve the existing public numeric-array representation,
non-numeric family/version guards, explicit serializer-kind checks, exact
physical roster, row schedule and corruption checks. Do not route legacy
values through the generic BinaryValue accessor or admit Sparse layouts.

The existing failed W256 consumer test is the falsifier. Final gates must
cover both profiles and rejected unknown versions, false propagation and
Sparse metadata. This prerequisite does not establish all recursive products
or change the projection-materialization non-guarantees above.

The next executed focused gate exposes a second legacy numeric-array adapter
gap: the generic writer emits the exact roster in sorted filename order,
whereas the legacy reader expects size-first decoding order. ClickHouse emits
size-first through `SerializationArray.cpp:273-292` and its writer's callback
roster. `ColumnsSubstreams.cpp:227-260` reads the listed names; Wide reader
lookup resolves a substream by name (`MergeTreeReaderWide.cpp:1197-1219`).
This supports exact set comparison for separate Wide files, not Compact.

Admit order normalization only for the same exact supported primitive numeric
arrays: after the existing uniqueness check, require equal complete name sets
and return the canonical reader order. Keep column order, count/parser bounds,
and duplicate/missing/extra-name rejection. The failing public read is the
falsifier; add those roster negatives plus the reciprocal stock-order witness.
