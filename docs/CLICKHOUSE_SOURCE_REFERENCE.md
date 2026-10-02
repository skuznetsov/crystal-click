# ClickHouse Source Reference

## Current source snapshot (2026-10-02)

Use this separate checkout for new source comparisons:

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
The retained W115-W117 oracle is ClickHouse `26.10.1.1201`, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`. Its executed certificates keep
their original source/runtime identities in `JSON_GENERAL_STORAGE_FRONTIER.md`.

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
Source continuity alone does not widen W117's admitted scalar types or promote
the proposed W118 MAP block into whole-JSON part support.
