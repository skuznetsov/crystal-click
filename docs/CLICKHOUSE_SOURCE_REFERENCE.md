# ClickHouse Source Reference

## Current source snapshot (2026-10-04, third refresh)

Use `/Users/sergey/SrcArchives/clickhouse-2026-10-04-depth1-b94acbe3`
for new source comparisons. Root cloned public `ClickHouse/ClickHouse` master
with `--depth 1 --single-branch --branch master --no-tags` after observing
upstream HEAD `b94acbe318f8459ac88b35647f4e2293d8e225db`.
The checkout has that revision, committer timestamp `2026-10-04T07:12:25Z`,
one reachable commit, shallow status `true`, and a clean working tree.
Existing checkouts were not modified; submodules were not initialized.

Freshness recheck at `2026-10-04 12:36 UTC`: a new public upstream
`git ls-remote ... refs/heads/master` returns the same `b94acbe3` revision.
Root rechecks local HEAD, shallow status and the clean working tree. No
duplicate clone is needed while the inspected upstream HEAD is unchanged;
this is a time-scoped source observation, not an executable qualification.

Root ran recursive `git diff --no-index --stat` against `7f568d60` separately
for `src/DataTypes`, `src/Columns`, `src/Storages/MergeTree`, `src/Compression`
and `src/Formats`. All five returned exit 0 with no differences. This is an
exact content comparison of these directories, not an exhaustive compatibility
audit or a claim about shallow-history ancestry. The snapshot is unbuilt;
existing executable certificates retain their separate runtime identities.
Refresh on relevant source changes. The reserved-descriptor and version/profile
limitations below still apply.

## Previous source snapshot (2026-10-04, second refresh)

Use this separate checkout for new source comparisons:

`/Users/sergey/SrcArchives/clickhouse-2026-10-04-depth1-7f568d60`

- Upstream: `https://github.com/ClickHouse/ClickHouse.git`, branch `master`.
- Revision: `7f568d607755c5dcebd48d8eacb17ad745d34c21`.
- Committer timestamp: `2026-10-04T05:25:42Z`.
- Cloned with `git clone --depth 1 --single-branch --branch master --no-tags`.
  Root's pre-clone and post-clone `git ls-remote` lookups both returned this
  revision for `refs/heads/master`.
- Root observed shallow repository `true`, one reachable commit, branch
  `master` and a clean working tree. Submodules were not initialized; existing
  checkouts were not modified. The clone ran under the serial memory guard.
- This is a source reference, not a built or qualified executable. Retained
  runtime certificates keep their separate build identities.

Root independently repeated recursive `git diff --no-index --stat` comparisons
against `37a251ff`: `src/DataTypes` (including `Serializations`), `src/Columns`,
and `src/Storages/MergeTree` each returned exit 0 with no differences. This is
working-tree content comparison, not a shallow-history ancestry claim. Other
directories and current-master executable behavior were not qualified here.
The inspected Dynamic serializer and descriptor table therefore retain the
same source anchors within this comparison window.

Type-family continuity still does not imply exclusively additive wire-format
changes. The current descriptor table explicitly reserves removed Time/Time64
timezone tags 0x33/0x35. Persisted structure versions, settings, framing and
supported products require separate reader/writer evidence. Refresh this
record on relevant upstream or local-source changes.

## Previous source snapshot (2026-10-04)

Use this separate checkout for new source comparisons:

`/Users/sergey/SrcArchives/clickhouse-2026-10-04-depth1-37a251ff`

- Upstream: `https://github.com/ClickHouse/ClickHouse.git`, branch `master`.
- Revision: `37a251ffa2805b33201486306db980bfa96d73e7`.
- Committer timestamp: `2026-10-04T01:24:02Z`.
- Cloned with `git clone --depth 1 --single-branch --branch master --no-tags`.
  Root's pre-clone and post-clone `git ls-remote` lookups both returned this
  revision for `refs/heads/master`.
- Root observed shallow repository `true`, one reachable commit, branch
  `master` and a clean working tree. Recorded submodules remain uninitialized;
  none were fetched. Existing checkouts were not modified.
- This is a source reference, not a newly built or qualified executable. The
  pinned runtime certificates retain their separate build identities.

### Source comparison: 37a251ff vs 9007d227

Root executed recursive `git diff --no-index --stat` comparisons:

| Directory | Observed result |
| --- | --- |
| `src/DataTypes/Serializations` | Exit 0; identical contents. |
| `src/DataTypes` | Three changed files, 173 insertions, 3 deletions; exit 1. |
| `src/Columns` | Four changed files, 156 insertions, 10 deletions; exit 1. |
| `src/Formats` | Only `ProtobufSerializer.cpp` changed, one insertion/deletion; exit 1. |
| `src/Storages/MergeTree` | 49 changed files, 1,047 insertions, 254 deletions; exit 1. |
| `src/Compression` | Two changed headers, 8 insertions; exit 1. |

The inspected DataTypes change adds a paired recursive type-replacement
utility through Nullable/LC/Array/Map/Tuple/Variant and refactors DateTime
argument lookup. `DataTypeVariant`, `DataTypeObject`, the descriptor encoding
table and all serializer sources are unchanged in this window. The inspected
LC change adds batch in-memory String serialization and referenced-value
sizing; it is not a new persisted dictionary/index serializer.
`MergeTreePartition.cpp` changes the source of the sample block used for
partition text, including patch-part handling. The wider MergeTree diff is
not an exhaustive lifecycle, pruning or physical-format compatibility audit.

These comparisons establish source continuity only for the stated paths and
revisions. They do not qualify a current-master executable, widen the Object
frontier, prove all physical layouts or establish performance. Refresh this
record when relevant sources or upstream HEAD change. Type-family continuity
is not a promise of exclusively additive descriptor or serialization changes;
the reserved Time descriptor example below remains a concrete counterexample.

## Previous source snapshot (2026-10-03, second refresh)

Use this separate checkout for new source comparisons:

`/Users/sergey/SrcArchives/clickhouse-2026-10-03-depth1-9007d227`

- Upstream: `https://github.com/ClickHouse/ClickHouse.git`, branch `master`.
- Revision: `9007d227b64a3f8b667fc5258ceb2923f3cf477d`.
- Committer timestamp: `2026-10-03T08:25:05Z`.
- Cloned with `git clone --depth 1 --single-branch --branch master --no-tags`.
  Root's pre-clone and post-clone `git ls-remote` lookups both returned this
  revision for `refs/heads/master`.
- Root observed shallow repository `true`, one reachable commit, branch
  `master`, and a clean working tree. All 154 recorded submodules were
  uninitialized; none were fetched.
- Existing checkouts were not changed. No executable from this revision was
  built or qualified; retained runtime certificates keep their original
  executable identities.

### Source comparison: 9007d227 vs f86ca42b

Root executed recursive `git diff --no-index --stat` comparisons against the
earlier October 3 snapshot below and inspected the changed DataTypes and
MergeTree hunks:

| Directory | Observed result |
| --- | --- |
| `src/DataTypes/Serializations` | Exit 0; identical contents. |
| `src/DataTypes` | One new test file, 42 insertions; exit 1. |
| `src/Columns` | Exit 0; identical contents. |
| `src/Formats` | Exit 0; identical contents. |
| `src/Storages/MergeTree` | Two changed files, 24 insertions, 14 deletions; exit 1. |
| `src/Compression` | Two changed files, 13 insertions; exit 1. |

`DataTypes/tests/gtest_data_type_fixed_size_value.cpp` checks that a registered
type claiming an unambiguous fixed-size representation supplies its memory
size. It adds a test, not a new type or serializer.
`MergeTreeDataPartWriterWide.cpp` now rounds compression-buffer sizes to whole
fixed-size values when the stream provides a type. This can change compressed
block boundaries; unchanged scalar serialization does not imply identical
physical framing. The new helper in `CompressionFactory.cpp:343-350` and its
header declaration comprise the Compression diff: the helper rounds down to a
multiple of the fixed value size, with a minimum of one whole value. The other
changed MergeTree file, `MergeTreeSettings.cpp`, changes
setting descriptions, not their values.

These observations establish continuity only in the compared directories and
between the stated revisions. They do not admit new Object schemas/layouts,
qualify the current-master executable, or establish performance. Refresh this
record when relevant sources or upstream HEAD change.

### Descriptor continuity boundary

Root also inspected `src/DataTypes/DataTypesBinaryEncoding.h:62-77` for W147.
The table explicitly reserves 0x33/0x35 after timezone-bearing Time/Time64
descriptors were removed; it does not promise only additive descriptor changes.
W147 preserves these reserved-tag refusals. Source construction, logical wire
encoding and persisted part framing are separate compatibility surfaces, and
each qualification retains its source and executable identities.

## Earlier October 3 source snapshot (f86ca42b)

Use this separate checkout for new source comparisons:

`/Users/sergey/SrcArchives/clickhouse-2026-10-03-depth1-f86ca42b`

- Upstream: `https://github.com/ClickHouse/ClickHouse.git`, branch `master`.
- Revision: `f86ca42b6e90eadb97f7481638ff04ca1ee8e71f`.
- Committer timestamp: `2026-10-03T04:32:37Z`.
- Cloned with `git clone --depth 1 --single-branch --branch master --no-tags`.
  Root's pre-clone lookup and the post-clone `git ls-remote` both returned
  `f86ca42b6e90eadb97f7481638ff04ca1ee8e71f` for `refs/heads/master`.
- Observed shallow repository `true`, reachable commit count `1`, branch
  `master`, and clean working tree (`git status --short --branch` reported
  `## master...origin/master`). `git submodule status --recursive` showed
  uninitialized (`-`-prefixed) entries; submodules were not initialized.
- Existing source checkouts were not modified. This is a source reference, not
  a newly built executable or a replacement for any pinned runtime certificate.

## Latest snapshot comparison (2026-10-03 vs 2026-10-02)

Compared the October 3 checkout above against:

`/Users/sergey/SrcArchives/clickhouse-2026-10-02-depth1-101871ba`

Root repeated recursive `git diff --no-index --stat` comparisons for each
source-directory pair after independently checking the checkout identity:

| Directory | Result |
| --- | --- |
| `src/DataTypes/Serializations` | Exit 0; identical contents. |
| `src/DataTypes` | Exit 0; identical contents. |
| `src/Columns` | Exit 0; identical contents. |
| `src/Storages/MergeTree` | Exit 1 because differences were found: 34 files, 699 insertions, 429 deletions. |

The full `DataTypes/Serializations` and `DataTypes` trees are unchanged in this
source window. Thus the Object/Dynamic type declarations, serializer source,
structure-version handling, and shared-data layout code in those trees are
identical; the `Columns` tree is identical too. This establishes source
continuity only within those directories. It does not establish global parser,
JSONExtract admission, reader/writer compatibility, or executable behavior.

Inspected MergeTree differences relevant to type interpretation and part
handling:

- `src/Storages/MergeTree/MergeTreeIndexJSONSubcolumnHelper.cpp:15,51-66,158`
  now collects JSON index argument types and declines to match a subcolumn
  that reaches inside a declared typed path. This avoids using a path index
  whose granule paths do not include values inside that typed path. It changes
  index matching/pruning, not Object serialization or type admission.
- `src/Storages/MergeTree/KeyCondition.cpp:6755-6778,6835,7288` and
  `MergeTreeDataSelectExecutor.cpp:2399` add nested-NULL detection for Tuple,
  Array, and Map key fields and widen affected bounds so a comparison-order
  mismatch cannot make a matching granule appear empty. This is primary-key
  range analysis, not a type or serializer change.
- `MergeTreeData.cpp:6897-6901` now keeps UNIQUE KEY parts on Full storage
  rather than selecting Packed storage; the source comment ties this to
  `SSTIndexWriter` requiring Full parts. `IMergeTreeDataPart.cpp:2265` also
  handles Compact-part default-codec detection through the shared data file.
  `DataPartStorageOnDiskFull.cpp` and `DataPartStorageOnDiskPacked.cpp` add
  transaction undo handling. These are part-storage/lifecycle changes; they do
  not indicate a changed Object shared-data layout.

These comparisons do not widen admitted Object/JSON types. They also do not
qualify an executable from `f86ca42b`; the existing source and runtime
certificates retain their original identities.

## Previous October 2 source snapshot (2026-10-02; W128-W133)

Retain this checkout for its existing W128-W133 source certificates and as the
comparison baseline for the October 3 snapshot:

`/Users/sergey/SrcArchives/clickhouse-2026-10-02-depth1-101871ba`

- Upstream: `https://github.com/ClickHouse/ClickHouse.git`, branch `master`.
- Revision: `101871ba6da8221c7cf30ac3a04bc1063106f412`.
- Commit timestamp: `2026-10-02T15:23:23Z`.
- Cloned with `--depth 1 --single-branch`.
- Root observed shallow repository `true`, reachable commit count `1`, and a
  clean working tree. Post-clone `git ls-remote` returned the same upstream HEAD.
- Existing source checkouts were not modified. Submodules were not initialized.

This checkout is a source reference, not a newly built executable. Retain the
runtime identities and executed compatibility certificates below.

## Previous October 2 snapshot

Retain this checkout for the existing W121-W127 source certificates:

`/Users/sergey/SrcArchives/clickhouse-2026-10-02-depth1-31d2addb`

- Upstream: `https://github.com/ClickHouse/ClickHouse.git`, branch `master`.
- Revision: `31d2addbabda0d8e14ffd325fc0a9106528aa1c7`.
- Commit timestamp: `2026-10-02T12:39:11Z`.
- Cloned with `--depth 1 --single-branch --branch master --no-tags`.
- Root observed shallow repository `true`, reachable commit count `1`, and a
  clean working tree. Post-clone `git ls-remote` returned the same upstream HEAD.
- Upstream moved between the initial remote lookup and cloning; the folder was
  renamed to match the revision actually downloaded, not the earlier lookup.
- Existing source checkouts were not modified. Submodules were not initialized.

Those certificates remain tied to their original source/runtime identities.

## Earlier October 2 snapshot

Retain this separate checkout as the source reference for the W117-W120
certificates:

`/Users/sergey/SrcArchives/clickhouse-2026-10-02-depth1-0c68f01a`

- Upstream: `https://github.com/ClickHouse/ClickHouse.git`, branch `master`.
- Revision: `0c68f01a75a913b1aa5e132b41a80642260c3009`.
- Commit timestamp: `2026-10-02T06:27:25Z`.
- Cloned with `--depth 1 --single-branch --branch master --no-tags`.
- Root observed shallow repository `true`, reachable commit count `1`, and a
  clean working tree. A second `git ls-remote` after cloning returned the same
  upstream HEAD; the verification was performed on 2026-10-02 around 08:30 UTC.
- Existing source checkouts were not modified. Submodules were not initialized.

This is a source reference, not the build provenance of the executable oracle.
The retained W115-W120 oracle is ClickHouse `26.10.1.1201`, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`. Its executed certificates keep
their original source/runtime identities in `JSON_GENERAL_STORAGE_FRONTIER.md`.

## Earlier October 2 snapshot comparison (31d2addb vs 101871ba)

Root executed recursive `git diff --no-index --stat` comparisons of the
`31d2addb` and `101871ba` source trees:

- `src/DataTypes/Serializations`: identical contents (exit 0, no diff output).
- `src/DataTypes`: five added fuzzer files, 521 added lines; this does not widen
  this library's physical type profiles.
- `src/Columns`: seven changed files, including a batch-serialization signature
  change from `VectorWithMemoryTracking<char *> &` to `std::span<char *>` and
  fuzzers. Root inspected the `ColumnString.cpp` and `IColumn.h` diffs.
- `src/Storages/MergeTree`: three changed files. Root inspected the changes:
  settings/documentation comments and removal of a derived-query-context
  fallback for pinned storage snapshots in `MergeTreeData.cpp`. Do not infer
  execution or MV behavior continuity from unchanged serializers.

The source reference is fresh as of the recorded lookup, not a claim about
future upstream HEAD. No executable from `101871ba` was built or qualified.

## Earlier October 2 comparison

Root executed recursive `git diff --no-index --stat` comparisons of the
`0c68f01a` and `31d2addb` source trees. `src/DataTypes` (including all its
serializers), `src/Columns`, and `src/Storages/MergeTree` have identical file
contents: each comparison returned exit 0 and no diff output. This establishes
continuity only in those scopes between these two snapshots; no current-master
binary was built or qualified.

The October 2 `101871ba` source separates Object structure versions from shared-data
layout selection (`SerializationObject.cpp:302-311,413-430` and
`SerializationObjectSharedData.h:29-71`), and Dynamic has its own structure
version grammar (`SerializationDynamic.cpp:145-153`). Shared layouts determine
different streams, marks and Wide/Compact chunk ordering. Projection reads use
their own part granularity and indexes (`MergeTreeDataSelectExecutor.cpp:3102-3126`).
Adding or retaining a logical type does not establish all these physical
profiles. These are source observations, not executable qualification.

## Comparison to the previous reference

Previous checkout:
`/Users/sergey/SrcArchives/clickhouse-2026-10-01-depth1-935de744`, revision
`935de7442d7890eb5631372e4ad6f66faaf35f90`.

Root executed recursive `git diff --no-index` comparisons of the two trees:

- `src/DataTypes`: only `DataTypeEnum.cpp` and `DataTypeEnum.h` changed,
  adding 22 lines for `isUnknownEnumElement`. The added function checks whether
  a String names an existing Enum element; it does not change serialization.
  The binary type encoding and all serializers in this directory are identical.
- `src/Columns` and `src/Formats`: identical file contents.
- `src/Storages/MergeTree/MergeTreeSettings.cpp`: identical file contents.
- `src/Storages/MergeTree`: 13 files changed, with 171 insertions and 51 deletions.
  Do not infer engine-wide continuity from the unchanged type codecs. Root
  inspected changes to temporary-part removal policy and condition-cache
  probing in `MergeTreeDataSelectExecutor` separately.

An exit code of 1 from `git diff --no-index` means differences were found, not
that the comparison failed. These comparisons establish source continuity in
the named directories; they do not establish full reader/writer compatibility,
current-master executable behavior, or performance.

## Compatibility policy

Type identity and scalar binary descriptors are not a substitute for the
physical serialization profile. Object/Dynamic versions, shared-data layouts,
serializer settings, marks, compression and selected-row coordinates remain
separate admission boundaries. Keep the pinned source SHA and the tested
runtime identity distinct in new evidence.

Refresh this reference when upstream moves or a relevant source file changes.
Source continuity alone does not widen admitted types or promote the
W117-W119 binary kernel, W118 MAP block or W120 structure metadata into
whole-JSON part support.
