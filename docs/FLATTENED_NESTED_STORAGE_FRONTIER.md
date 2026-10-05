# Flattened Nested storage frontier — W173

Status: VERIFIED within the explicit bounded part profile (2026-10-05).
Baseline: clean `927d9f7`; risk: CAUTION (metadata/storage admission).
Rollback: one scoped local commit. Performance work remains deferred.

## Boundary and authority

Pair an explicit flattened-Nested reader and complete-part writer for one
sorted UInt64 key and one named group of direct scalar/Nullable leaves in
Wide/LZ4 storage. The caller supplies the group name and nominal Nested type.
This is a client view binding, not proof that the original DDL was Nested:
ClickHouse can expose arbitrary matching dotted Arrays as a Nested view.

Admit only simple identifier roots/fields, exact sibling declaration order,
one canonical shared `<root>.size0` reference per sibling block, and the
inherited bounded W171 leaf grammar. Normalize metadata only in memory;
never rewrite a stock part. Reuse its ragged reader, leaf codecs, limits,
staging, readback and exclusive publication.

The part is assumed stable during opening and reading. This API does not add
a concurrent-rewrite snapshot guarantee or infer server Active state.

Ordinary Array/open APIs, implicit dotted-name inference, recursive Tuple
children, independent sibling offsets (`share_nested_offsets=false`),
escaped/dotted names, unrelated extra columns, Compact/Sparse, and table/
offline/MV/projection context mapping remain rejected. Table integration is
the next separate slice, not evidence supplied by this part-level API.

## Source and measured baseline

Fresh source checkout, unbuilt:
`/Users/sergey/SrcArchives/clickhouse-2026-10-05-depth1`,
`e9b645ed83ad3c07b64f09fbd014e8f770d8691b` (clean, shallow).
Source laws: `NestedUtils.cpp:35-77,467-519,585-623` splits at the first dot,
synthesizes Nested views and validates equal sibling sizes;
`ColumnsDescription.cpp:544-602` flattens nominal fields;
`ISerialization.cpp:302-358,421-457` distinguishes escaped value names from
the shared first-level size stream. Substream metadata alone is not a
sibling-equality or nominal-provenance certificate.

Executed stock is separately pinned to 26.10.1.1201, build d9bcb5ab, SHA256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
Retained W171 flat1 manifest:
`/private/tmp/crystal-click-w171.pMJBfo/nested-source-law-20261005-78412-1tiig41/manifest.json`.
It has three physical Array siblings, nine references to seven unique
streams (including PK), five rows and outer mark schedule `[2,2,1,0]`.
The independently stock-authored part fails the baseline ordinary public
reader: `UnsupportedFormatError: array column serializer fields are
unsupported` (root guarded session 84019, exit 1). The earlier absolute
require compile error was instrumentation failure, not capability RED.

## Plan and guard laws

1. Add one cohesive flattened storage-plan owner. Validate the original
   column and substream rosters before synthesizing `[pk UInt64, root Nested]`.
   Deduplicate only the exact shared-size references; do not relax the ordinary
   parser's duplicate rejection.
2. Add an explicit context reader factory and writer facade. Even PK-only
   selection validates the entire group serialization envelope. Check key/
   root mark-row axes before callbacks or writer publication.
3. Reuse the existing ArrayTuple writer, with a context selecting metadata
   and staged reader factories. A single row-size vector establishes sibling
   equality by construction; preflight checks every leaf's cardinality.
4. Execute focused and affected gates serially in DEBUG/RELEASE. Root runs
   the native paired oracle and independently reconciles retained commands
   and literal output, then attacks one unchanged guard with a seeded bypass.

Falsifiers: wrong/dotted root, missing/extra/reordered/wrong-type siblings,
wrong or arbitrary duplicate substream, bad serializer when only PK is
selected, inconsistent key/group mark vectors, malformed cardinality before
staging, empty rows/element marks, no publication after failed staged readback,
and ordinary APIs remaining closed. A same-shape changed leaf must remain
stock CHECK-valid yet disagree with the independent fixed literal oracle.

DoD: zero failures/errors/pending in declared serial guarded DEBUG/RELEASE
spec rosters; actual native ATTACH/CHECK statuses zero, exact metadata/file
roster/decoded streams/mark axes and full/middle/empty literal bytes match;
seeded bypass fails the unchanged guard, exact restoration passes; format
and git diff checks pass. Fresh source and executed binary identities must
remain distinct. Refresh evidence after any relevant planner, reader,
writer, serializer, consumer, fixture, source or runtime change.

## Public part API and retained boundaries

`WidePart.open_flattened_nested(path, group_name, type_name, selected_column = nil)`
returns the explicitly bound nominal root by default; selection may name only
that root or its UInt64 key. `read_nested_mark_range` and
`each_nested_mark_range` retain their existing nonempty direct-mark contract:
a zero-count range raises `BoundsError`. An empty Nested row or an entire
zero-element mark is different and remains readable. PK-only opening validates
the full group envelope, file bindings and mark axes, not every sibling value.

`WidePartWriter.write_uint64_flattened_nested_part(destination, key_name,
keys, group_name, type_name, row_sizes, columns, rows_per_mark = 8192)` shares
the existing ArrayTuple preflight, physical writing, staged semantic validation
and exclusive publication. One row-size vector generates all sibling offsets.
The new 249-line `FlattenedNestedStoragePlan` owns the exact physical roster,
shared-size exception and virtual schema. Its small detached Binding value
stays with that owner. The facades add dispatch/context seams only; this is not
a behavior-neutral extraction or an overall modularization certificate.

## Executed evidence

Root-owned DEBUG and RELEASE each pass 99 examples across the same 24 specs
below, with zero failures/errors/pending and child/guard exit 0 (sessions
`40191` and `84441`). The ordered SHA roster of 1,171 current Crystal/Ruby/shell
inputs under src/spec/scripts is unchanged across the RELEASE gate; aggregate
SHA256 is `a4be791ea03725795ff034d7a53020a1cd4be77fc6ea4697c50c66b6b42d876e`.
Initial private-receiver compilation failures, unqualified
exception, empty direct-mark expectation, ordinary-key baseline and omitted
terminal mark were implementation/instrument issues, not passing evidence.
They were corrected without widening any existing direct-mark or ordinary
reader boundary.

The flattened native oracle passes actual stock ATTACH/CHECK for the retained
stock part, independently library-authored base and same-shape value mutant.
Exact columns/substreams, seven payload and seven mark files, decoded raw lanes
and mark offsets match the fixed fixture. Stock uses intra-frame marks and the
library separate compressed frames; byte-identical compressed stock/library
output is not claimed. Hidden Int32 bytes under NULL also deliberately differ.
The root's separate literal encoder reconciles all 66 zero native statuses,
50 exact RowBinary/RowBinaryWithNamesAndTypes windows and three CHECK results,
rehashing retained SQL/output and the executable independently of the Crystal
oracle's PASS summary. Sibling columns and explicit named Array(Tuple)
reconstruction cover full/middle/empty-row/no-row windows. This reconstruction
does not claim a nominal Nested SQL output header.

Flattened evidence (root session `91653`):
`/private/tmp/crystal-click-w173.WoT454/nested-storage-w171-oracle-nested-flat1-1791207870-58114/manifest.json`.
The unchanged default unflattened mode also passes, independently reconciled
as 41 zero statuses, 25 exact binary windows and three CHECK results (session
`3653`), retained at
`/private/tmp/crystal-click-w173.WoT454/nested-storage-w171-oracle-nested-flat0-1791207925-58898/manifest.json`.
Both manifests retain raw argv, SQL, actual exit status, output paths/hashes and
source/runtime pins. The pre-existing flat0/flat1 shared-size comparison stays
unconditional; broader flattened comparisons are opt-in.

The stock CHECK-valid mutant changes the first UInt64 value from 11 to 12.
It matches its independently encoded changed value but differs from the
unchanged base oracle in both sibling and reconstructed outputs. Separately,
temporarily replacing only the key/root mark-axis comparison with `unless
true` makes the unchanged guard fail: one example, one assertion failure,
zero errors/pending, child/guard exit 1 (session `89438`). Exact restoration of
`wide_part.cr` SHA256
`862e3040e119a9af66f7baf3770d42bd396900b8e3d45d88cca2bdc46a5a144a`
then passes that guard (one example, exit 0, session `51702`). No bypass is
retained. Same-shape staged nominal/value defect hooks also reject publication
and preserve existing destination contents in the positive spec roster.

The native witness has exactly UInt64/String/Nullable(Int32) children and
lengths 2/0/1/3/2. The broader inherited direct-leaf grammar, wholly empty
element marks and empty-first/nonempty-later marks have library spec coverage,
not universal native whole-part qualification. No table/offline mapping or
performance admission follows from this certificate.

Scoped hostile verdict: ROBUST for the declared envelope/offset/axis/nominal
and staging boundaries, backed by root review, executed guards, native literal
comparisons and the seeded bypass. The Luna review is correlated evidence,
not independent model replication. Format checks and `git diff --check` pass.
Reader/writer/table facades remain 16,284/25,705/7,175 lines; the overall
architecture refactor is unfinished. Table/offline context mapping is the next
separate capability slice. Refresh this certificate after changes to any
relevant plan/parser/reader/writer/consumer/fixture or source/runtime pin.

### Replay commands and spec roster

All root compiler/native jobs are serial, with the unchanged guard, 180-second
and 8192-MiB limits, isolated caches, SDKROOT
`/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` and TMPDIR
`/private/tmp`. The invocation prefix is:

```sh
env COGNI_RUN_SAFE_MIN_FREE_PCT=50 RUN_SAFE_PASSTHROUGH_STDIO=1 \
  SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  TMPDIR=/private/tmp CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w173.WoT454/cache-debug \
  /bin/bash /Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh \
  /opt/homebrew/bin/crystal 180 8192
```

Append `spec` and the exact `spec/<name>.cr` roster below, then
`--single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace`.
RELEASE uses `cache-release` and additionally `--release`.

```text
wide_flattened_nested_w173_spec
wide_flattened_nested_w173_guards_spec
wide_nested_w171_admission_spec
wide_nested_w171_model_spec
wide_nested_w171_metadata_spec
wide_nested_w171_staging_spec
wide_nested_storage_w171_spec
wide_array_tuple_w107_admission_spec
wide_array_tuple_w107_metadata_spec
wide_array_tuple_w107_model_spec
wide_array_tuple_w107_reader_spec
wide_array_tuple_w107_leaf_matrix_spec
wide_array_tuple_w107_consumer_spec
wide_part_writer_array_tuple_w107_spec
wide_tuple_nested_w106_admission_spec
wide_tuple_nested_w106_model_spec
wide_part_reader_nested_tuple_w106_spec
wide_part_writer_nested_tuple_w106_spec
wide_map_tuple_w108_admission_spec
wide_map_tuple_w108_model_spec
wide_map_tuple_w108_reader_spec
wide_map_tuple_w108_consumer_spec
wide_part_table_projection_w87_spec
offline_catalog_projection_w87_spec
```

For native replay, use the same prefix with `cache-native` and append:

```sh
run scripts/check_nested_storage_w171_oracle.cr \
  --single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace -- \
  --flattened \
  --clickhouse /private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped \
  --source-manifest /private/tmp/crystal-click-w171.pMJBfo/nested-source-law-20261005-78412-1tiig41/manifest.json \
  --workdir /private/tmp/crystal-click-w173.WoT454
```

Omit `--flattened` for the default unflattened regression. The root-side
independent reconciliation is retained in
`/private/tmp/crystal-click-w173.WoT454/reconcile_native.rb`; invoke `ruby`
with each resulting manifest as its sole argument. Missing scratch/runtime/
source evidence requires a fresh pinned capture, not trust in this index.
