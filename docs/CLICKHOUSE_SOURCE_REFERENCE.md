# ClickHouse Source Reference

## Current source snapshot (2026-10-05, seventh refresh)

Use `/Users/sergey/SrcArchives/clickhouse-2026-10-05-depth1` for new comparisons.
Root cloned public HEAD with `--depth 1 --single-branch --no-recurse-submodules`;
pre/post-clone upstream lookups and the checkout agree on
`e9b645ed83ad3c07b64f09fbd014e8f770d8691b`. The checkout is clean, shallow,
has one reachable commit, and records committer timestamp
`2026-10-05T03:53:24Z`. Older source directories remain untouched.

Direct content comparison against `41b7bd50` finds six changed existing files
in the bounded DataTypes/Columns/Compression/Formats/MergeTree roster, with
no additions or deletions: `SerializationDynamic.cpp` (3 added lines),
`ColumnDynamic.cpp` and `ColumnObject.cpp` (32 added lines), and
`IMergeTreeDataPart.cpp`, `MergeList.h`, `ReplicatedFetchList.h` (57 insertions,
8 deletions). Compression, Formats and the AggregateFunctions tree are
content-identical. The descriptor header/codec and inspected SAF/String/
FixedString owners are unchanged.

Root inspected all six diffs after Luna's read-only inventory. The delta adds
data-driven recursion guards, compatible single-source Object statistics
reuse, recovery of present-empty part metadata files, and current-only
merge/fetch cancellation. Replicated/required column recovery remains gated
on an existing empty columns file and validating substream metadata; absent
columns files do not receive that exception. This comparison finds no wire
encoding change, but changes in refusals and metadata recovery are meaningful.
The unchanged enum still reserves removed timezone-bearing Time tags
`0x33`/`0x35`; DateTime/DateTime64 timezone tags remain `0x12`/`0x14`.
These historical removals are not new deltas between the two snapshots.

This is source-inspection evidence, not runtime qualification. The new tree
is unbuilt; the executed oracle remains separately pinned at build `d9bcb5ab`.
Refresh after relevant source changes; neither a type-family name nor an
unchanged binary descriptor proves every physical profile is compatible.

## Previous source snapshot (2026-10-04, sixth refresh)

Use `/Users/sergey/SrcArchives/clickhouse-2026-10-04-depth1-41b7bd50`
for new source comparisons. Root observed public master revision
`41b7bd50051cc2017fe5ca5505fb35c9dc620000` and cloned with
`--depth 1 --single-branch --branch master --no-tags` under the serial memory
guard (exit 0). The checkout has that revision, committer timestamp
`2026-10-04T23:03:16Z`, one reachable commit, shallow status `true`, and a
clean working tree. Existing checkouts were not modified; submodules were
not initialized. Freshness is time-scoped, not a promise that master stays put.

Root compared contents against `895d13ea`: serializers, Columns and
Compression are identical (each recursive diff exit 0). Explicit comparisons
of `DataTypeInterval.cpp`, `DataTypesBinaryEncoding.cpp` and `IntervalKind.h`
also return exit 0. DataTypes has 31 changed files (529 insertions,
235 deletions), chiefly explicit child access and the new TypeTree traversal
and rewrite API. The inspected AggregateFunction diff changes recursive
version rewriting, not its serializer. MergeTree has seven changed files
(24 insertions, 47 deletions); the inspected changes replace child traversal
in index/filter checks and shared-column descriptions. Formats changes
JSONUtils traversal (two files, three insertions, five deletions).

This bounded source audit does not qualify all recursive semantics or lifecycle
behavior. The checkout is unbuilt. W160's Interval wire/serialization anchors
remain unchanged in this comparison window; executable whole-part evidence
still names its separately pinned stock build. Type-family continuity does
not establish that versions, framing, settings or accepted products are
exclusively additive.

Concrete descriptor counterexample: the current
`src/DataTypes/DataTypesBinaryEncoding.h:61-75` explains that timezone-bearing
Time/Time64 types were removed and reserves 0x33/0x35 to avoid reinterpreting
old encodings. Preserving reserved codes is backward-compatibility policy,
not continued admission of every historical type/profile. QBit's separate
0x36/0x37 encodings likewise require canonical stride handling, not simply
counting type-family names.

W160's executed whole-part certificate is in
[INTERVAL_FRONTIER.md](INTERVAL_FRONTIER.md): all eleven scalar and Nullable
kinds pass a separately pinned stock runtime, including CHECK-valid nominal
and value mutants rejected by unchanged literal oracles. It is not runtime
qualification of this unbuilt checkout.

## Previous source snapshot (2026-10-04, fifth refresh)

Use `/Users/sergey/SrcArchives/clickhouse-2026-10-04-depth1-895d13ea`
for new source comparisons. Root cloned public master with
`--depth 1 --single-branch --branch master --no-tags` under the serial memory
guard (exit 0). Both upstream lookups returned
`895d13ea4ce8abb811b3b1b3d51b23a466a342a9`; the checkout has that revision,
committer timestamp `2026-10-04T17:26:48Z`, one reachable commit, shallow
status `true`, and a clean working tree. Existing checkouts were not modified;
submodules were not initialized.

Root ran recursive `git diff --no-index --stat` against `db9010c9` for five
directories. `src/DataTypes` (including all serializers), `src/Columns` and
`src/Compression` returned exit 0 with identical contents. MergeTree has one
changed file (7 insertions, 3 deletions): the inspected `checkKeyExpression`
diff adds offending names/types to existing rejection messages. Formats has
two changed files (47 insertions): the inspected diff adds
`getFormatSettingsHash`, not a persisted type serializer. These are bounded
working-tree content comparisons, not a history-ancestry, executable,
lifecycle or performance qualification. This snapshot is unbuilt; retained
stock runtime certificates keep their separate build identity.

### Declared Dynamic Object integration source anchors

Root inspected the current source independently after Luna's bounded audit:
`DataTypeObject.cpp:865-877` passes a declared path type to `DataTypeFactory`
without a Dynamic exclusion. The direct MergeTree regression
`tests/queries/0_stateless/03214_json_typed_dynamic_path.sql:3-17` uses
`JSON(a Dynamic)` with scalar and array-valued rows and both Wide and Compact
parts. This is source evidence, not an executed qualification of this library
or of a declared `Array(Dynamic)` path.

`ISerialization.cpp:369-408` gives the child metadata basename
`json.a.dynamic_structure`; `ObjectData` contributes no filename segment.
`SerializationObject.cpp:971-1007` delegates typed-path suffixes to their
nested serializer, while `SerializationDynamic.cpp:529-554` writes the child
statistics to its own DynamicStructure. Object and child statistics are
distinct sites. Both V3 structure versions use wire value 4, whereas value 3
is Native-only FLATTENED (`SerializationObject.h:41-57`,
`SerializationDynamic.h:40-52`). W158 must preserve exact child rosters,
first-parse results and per-child relative statistics offsets; no Object type
admission changes follow from this audit.

Refresh after relevant source changes; do not clone an unchanged snapshot
solely because a goal turn resumed. Type-family continuity is not exclusively
additive wire-format evolution: the current descriptor table still reserves
removed timezone-bearing Time tags 0x33/0x35. Versions, settings, framing and
recursive products need separate paired reader/writer evidence.

### Recursive declared Dynamic comparison — W159 preparation

Root inspected this snapshot's recursive stream delegation independently:
`SerializationArray.cpp:255-294` emits sizes and delegates ArrayElements;
`SerializationTuple.cpp:766-791` delegates each declared field;
`SerializationMap.cpp:652-674` delegates BASIC to the nested
`Array(Tuple(K,V))` representation, while other versions add bucket metadata.
This motivates explicit BASIC settings for both zero-level and merged Map
parts in the finite W159 qualification. A physical path such as
`root.elements.field.1` is not a descriptor-depth coordinate: a Map value is
one logical child edge, despite those three path components.

Root also executed bounded stock grammar and input-shape probes under the
resource guard (exit 0). The retained executable is ClickHouse 26.10.1.1201,
build `d9bcb5ab007f0f6299f7f973f2642245bab3d028`, SHA256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`;
it is not built from this source checkout. Factory probes admit declared
Array/Tuple/Map Dynamic and legal Nullable/Tuple and Variant/Array wrappers.
The six-row MergeTree input-shape probe accepts empty arrays/maps and NULL
Dynamic children. Literal queries observe Int64 Array/Map alternatives,
String spills with shared-data marker 1, and distinct Tuple-left Int64 and
Tuple-right String alternatives; NULL has type `None` and marker 0.

Probe inputs and outputs are retained under
`/private/tmp/crystal-click-w159.huxO5J/stock-shape-probe.sql`,
`stock_shape_probe.rb`, and `shape-separated-{0,1,2}.{stdout,stderr}`.
The command is the resource guard wrapping `/usr/bin/ruby`, 60 seconds,
4096 MiB, and that runner. An initial combined-query JSONEachRow framing
error was an instrument failure, corrected by separate create/insert/query
processes. These probes establish grammar and stock input shapes only, not
library serialization, complete-part interoperability, or performance.
Refresh after the source serializers, executable, settings or fixture change;
W159's paired completion requires its separate declared frontier gates.

The subsequent root-owned W159 complete-part oracle passes under that same
separately pinned executable. It checks a stock-authored part and independently
library-authored Wide parts with declared Array/Tuple/Map/direct Dynamic sites,
explicit Int64/String rosters, exact metadata names and absent-statistics
offset 10, six rows and three real plus one terminal mark. Actual stock
ATTACH/CHECK, full/middle literal/type queries and an unchanged-oracle
42-to-43 mutant control pass. The retained run is
`/private/tmp/crystal-click-object-recursive-dynamic-w159.lL5TDe`; scope and
library gates are in
[OBJECT_RECURSIVE_DYNAMIC_FRONTIER.md](OBJECT_RECURSIVE_DYNAMIC_FRONTIER.md).
This finite V3/MAP/BASIC profile is not executable qualification of the new
source checkout or general JSON layout compatibility.

## Previous source snapshot (2026-10-04, fourth refresh)

Use `/Users/sergey/SrcArchives/clickhouse-2026-10-04-depth1-db9010c9`
for new source comparisons. Root observed public master HEAD
`db9010c9dd7cc78968fb077c967b915fc6166a7b` at 17:47 UTC and cloned with
`--depth 1 --single-branch --branch master --no-tags` under the serial memory
guard (exit 0). The checkout has that revision, committer timestamp
`2026-10-04T16:40:46Z`, one reachable commit, shallow status `true`, and a
clean working tree. A post-clone upstream lookup returns the same revision.
Existing checkouts were not modified; submodules were not initialized.

Root independently ran recursive `git diff --no-index --stat` against
`b94acbe3` for five directories. `src/DataTypes`, `src/Columns`,
`src/Formats` and `src/Compression` each returned exit 0 with no differences.
`src/Storages/MergeTree` returned exit 1: 32 changed files, 3,399 insertions,
126 deletions, including new `ColumnsCache` files/tests and substantial Wide
reader changes. This is content comparison, not an exhaustive lifecycle,
cache, physical-format or performance qualification. W157 separately checks
the Dynamic suffix and Wide real/final-mark ordering: the Wide writer is
unchanged, and no relevant mark-law drift was found in the bounded audit.
The snapshot is unbuilt; retained executable certificates keep their separate
build identity.
Freshness is time-scoped and must be rechecked after relevant upstream changes.
The reserved-descriptor and version/profile limitations below still apply.

## Previous source snapshot (2026-10-04, third refresh)

The previous comparison used
`/Users/sergey/SrcArchives/clickhouse-2026-10-04-depth1-b94acbe3`.
Root cloned public `ClickHouse/ClickHouse` master
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
