# ClickHouse Source Reference

## Current source snapshot (2026-10-02, refreshed)

Use this separate checkout for new source comparisons:

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

## Latest snapshot comparison

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

The latest source still separates Object structure versions from shared-data
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
