# Geo types frontier

Status: VERIFIED within the W109 paired explicit scalar `Point` profile below,
relative to clean predecessor `994f20c`. Other Geo types are not admitted by
this certificate. The broader objective remains all CH types plus
MV/projections, then memory/performance qualification; this slice does not
redefine success.

## Source anchor and admission boundary

Fresh source is `/Users/sergey/SrcArchives/clickhouse-2026-10-01-depth1` at
`b762d6d7fe4b201147bdce1bd49b8fc87a8049d3`. `DataTypeCustomGeo.cpp:14-18`
registers custom `Point` over `Tuple(Float64, Float64)`. That is a source
fact, not a physical certificate. The predecessor typed dispatcher has no explicit
`Point` branch; existing named Tuple support does not preserve custom domain
identity or prove the unnamed coordinate stream recipe.

Runtime oracle is pinned ClickHouse `26.7.1.1315`, Crystal `1.21.0`. Before
production admission, independently qualify stock-created Point parts and
fresh ATTACH copies: exact declaration/substreams, raw IEEE coordinate bits,
actual adaptive mark tuples and plain PK index, serialization metadata,
stock CHECK result equal to 1, and literal full/PK-selected RowBinary.
Only a typed refusal after those controls is qualified feature RED.

Initial physical target: two-column Wide/LZ4, one nondecreasing UInt64 PK
and one exact scalar Point payload, plain adaptive mrk2/plain primary.idx.
The mixed seven-row stock source and fresh ATTACH qualification passed before
predecessor typed refusal. The exact physical leaves are `payload%2E1` and
`payload%2E2`, both width 8; mark rows are `[2,2,2,1,0]`, with raw offsets
`[0,16,32,48,56]` in the pinned single-frame fixture. The version-1 envelope
contains propagation `true`, `types_serialization_versions={"string":1}` and
ordered payload/PK Default records. Point has exactly two unnamed child
records. Literal payload/X/Y/PK defaults are 2/3/4/2 of 7. Negative zero is
not raw positive-zero default. The first metadata prediction (empty version
map and zero PK defaults) was refuted by observation and repaired as an
instrument, not counted as feature RED.

`scripts/probe_point_w109_red.sh` exited 1 only after exact source and ATTACH
inventory, schema, physical raw bits, actual marks, literal primary index,
metadata, CHECK result 1, full/selected RowBinary and seeded wrong-byte
controls passed. The final typed refusal was `unsupported exact typed column`.
All-default and expanded IEEE cases were subsequent GREEN qualification
obligations, now executed below. Sparse is not silently admitted through this
Default-only certificate.

The first GREEN all-default stock probe refuted the expected two statistics
records: with `ratio_of_defaults_for_sparse_serialization = 1`, the observed
version-1 envelope has `columns: []`. Fresh source explains that
`SerializationInfoSettings::isAlwaysDefault()` is true at ratios >= 1;
`SerializationInfoByName` then creates no records, and an absent name resolves
to Default in `getKindStack`. This is not Sparse or missing physical data.
The subsequently admitted branch is an exact empty-statistics Default branch after
all existing envelope, two-column and physical-stream guards. Partial records,
missing `columns`, unknown fields/versions and Sparse remain rejected. Stock
source and fresh ATTACH CHECK/RowBinary qualification and typed refusal preceded
the profile-owner change and the final negative guards.
The failed metadata prediction alone is an instrument refutation, not RED.
After correcting that prediction, all three stock profiles (mixed IEEE,
all-default, and key-first renamed columns) passed exact source and fresh
ATTACH controls, six actual CHECK results equal to 1, and literal full and
PK-selected RowBinary. The mixed typed reader passed; the all-default typed
reader then failed with `Point serialization requires exact payload and key
records`. This is the qualified RED for the empty-statistics Default branch.

Rejected in W109: custom Geo array/Variant forms, arbitrary containers,
Nullable Point unless stock legality and format are separately qualified,
generic unnamed Tuple admission, Compact/Sparse, unknown serializer versions,
general table writing, geographic functions/validation and performance claims.
These remain obligations toward the full objective, not permanent exclusions.

## Laws, risk and rollback

Risk: CAUTION (persisted type identity, physical format and public typed API).
Rollback: one exact local W109 commit relative to `994f20c`; no push, external
data mutation, dependency update or remote history change.

- Keep Point identity explicit in schema, typed values, table/catalog and
  writer readback. Reusing Float64 framing must not expose Point as a named
  Tuple or admit a plain Tuple under the same API.
- X/Y are raw Float64 coordinates, not finite/range-checked geographic values.
  Preserve signed zero, infinities and NaN payload bits wherever the qualified
  stock profile preserves them. Never use Float equality for raw readback.
- One concrete owner per file; reuse scalar codecs, stream lifetime and
  existing staging/checksum/publication authority rather than copying them.
- Selected structural corruption must be rejected before the first callback;
  document eager selected-boundary versus mark-local semantics explicitly.
- Bound combined selected payload/result ownership before materialization and
  writer snapshots/staging. Logical accounting is not a peak-RSS guarantee.
- Writer validates exact stage inventory/schema/metadata/marks/PK and both
  coordinate raw-bit vectors before exclusive publication; cleanup on failure.
- Caller-owned inputs and part roots must remain immutable during operations;
  shared server-directory concurrency and fsync durability are not inferred.

## Execution order and discriminators

1. Luna source and reader/writer seam inventories, read-only; root settles
   the physical/API/ownership contract before production edits.
2. Independent literal stock RED oracle covering mixed raw coordinates,
   all-default coordinates, repeated/zero external PKs, full and nonzero-origin
   selected ranges, source and fresh ATTACH. A seeded wrong expected byte must
   fail; instrument/compile failures are not feature RED.
3. Paired model/reader/writer/consumer implementation with corruption,
   selected/lazy budgets, exact identity and pre-stage/publication falsifiers.
4. Focused DEBUG and RELEASE, relevant Tuple/Map/QBit regression guards,
   full DEBUG and independent bidirectional stock GREEN; root hostile review.
5. Update the executed certificate, architecture frontier and examples, then
   atomic local commit only after declared gates pass. Do not mark the entire
   thread goal complete based on this feature.

Strongest initial falsifier: swapping coordinate stream identity or normalizing
a NaN/signed-zero raw carrier yields plausible points but wrong stored values.
The independent oracle must distinguish X from Y by asymmetric literal vectors,
including opposite zero signs and distinct NaN bits. Another falsifier is a
later selected stream/mark boundary defect delivered only after a callback;
test rejection before callbacks and retain a previously decoded value safely.

Root owns this frontier, require integration, serial compiler/ClickHouse gates,
independent diff review and Git. Reader Luna owns only reader/model/consumer
work after the contract is resolved; writer Luna only paired writer work;
oracle Luna only source investigation and independent oracle scripts. Agents
must preserve one another's edits and must not run concurrent heavy workloads.

Evidence decays on source, runtime binary, physical recipe, descriptor/codec,
selected-range lifetime/budget, metadata or staging/publication changes.
Requalify affected source, stock and negative checks before relying on it.

## Resolved API and owner plan

- Reader Luna owns `wide_point_value.cr` (`WidePointValue`, immutable x/y,
  `from_bits`, `x_bits`, `y_bits`, `same_bits?`) and `point_column_type.cr`
  (exact Point identity, two width-8 physical paths, checked combined charge).
- Reader Luna owns `wide_part/point_reader.cr`, a metadata validator if needed,
  `wide_part_table/point_column_adapter.cr`, and
  `offline_table/point_values_materializer.cr`, plus narrow reader/table/catalog
  dispatch and focused model/reader/consumer specs. Shared Float64 decoding is
  invoked through the existing codec authority, not copied.
- Public reader APIs are `read_point_mark_range`, `each_point_mark_range` and
  `point_mark_range_materialization_charge`; batch accessor is
  `point_values_for`. Catalog values retain `WidePointValue` identity.
- Reader charge includes both simultaneously live raw coordinate buffers
  (16 bytes/row), result slots (16 bytes/row), headers and selected schedule.
  Metadata-only schedule planning checks all combined per-mark charges before
  any selected payload validation, read or decode. Eager selected structural
  preflight then runs before callbacks, followed by mark-local materialization.
  The charge accessor never reads/decompresses payloads; structural validation
  does perform bounded selected I/O. Neither is a peak-RSS guarantee.
- Writer Luna owns `wide_part_writer/point_part_write_input.cr`,
  `point_serialization_statistics.cr`, `point_part_writer.cr`, narrow writer
  facade dispatch and writer specs. It reuses `TupleLeafStreamWriter.write_leaf`
  and `TuplePartInfrastructure`; Point statistics reuse the exact raw-default
  predicate, but Point schema and orchestration never impersonate Tuple.
- Public writer is `write_uint64_point_pair(destination, key_name,
  keys : Slice(UInt64), value_name, values : Slice(WidePointValue),
  rows_per_mark : Int32 = 8192)`. Snapshots and stage are created only after
  combined key/x/y, schedule, metadata and stream/frame bounds pass. Owned
  PK/X/Y snapshots remain live during staged readback, so the writer charges
  all 24 snapshot bytes/row in addition to the reader's 32 bytes/row and the
  relevant fixed/schedule charges. Counting only PK here was refuted during
  review; this conservative 56-byte/row accounting is not measured peak RSS.
- Oracle Luna owns the frozen RED pair and new GREEN pair only. Root owns
  `src/crystal_click.cr`, this SDD, admission spec, documentation and Git.

DoD commands from the repository root: guarded `crystal spec --single-module
--link-flags=-fuse-ld=ld` on the Point specs in DEBUG and RELEASE; relevant
Tuple/Map/QBit and catalog regression inputs; full DEBUG; guarded
`bash scripts/probe_point_w109_green.sh` in independent reader and writer
phases, including source/fresh ATTACH CHECK=1 and exact raw IEEE/PK profiles.
Expected GREEN is exit 0 with zero failures/errors/pending. Exact commands,
inputs and observed counts are recorded only after execution below. Root
attacks later selected boundary defects, aggregate cap-before-allocation,
exact nominal identity and staged bit/metadata/mark tampering before commit.

## Executed qualification on October 1

The implementation extends predecessor `994f20c`; unrelated production files
remain unchanged. Root ran compiler and ClickHouse gates serially after Luna
implemented the separate reader, writer and oracle responsibilities. The final
15-file production fingerprint is
`b515b2d1bb4c6a3e511f52522bdcb6c255e7fc6acabdffd905a4966e21d2c24d`.
It is SHA-256 of the newline-terminated `shasum -a 256` output for these paths,
in this order:

```text
src/crystal_click.cr
src/crystal_click/offline_column_value.cr
src/crystal_click/offline_table.cr
src/crystal_click/wide_part.cr
src/crystal_click/wide_part_table.cr
src/crystal_click/wide_part_writer.cr
src/crystal_click/wide_point_value.cr
src/crystal_click/point_column_type.cr
src/crystal_click/wide_part/point_serialization_profile.cr
src/crystal_click/wide_part/point_reader.cr
src/crystal_click/wide_part_table/point_column_adapter.cr
src/crystal_click/offline_table/point_values_materializer.cr
src/crystal_click/wide_part_writer/point_part_write_input.cr
src/crystal_click/wide_part_writer/point_serialization_statistics.cr
src/crystal_click/wide_part_writer/point_part_writer.cr
```

Final focused/regression inputs, used together in both DEBUG and RELEASE:

```text
spec/point_w109_admission_spec.cr
spec/point_w109_hostile_spec.cr
spec/point_w109_reader_spec.cr
spec/point_w109_consumers_spec.cr
spec/point_w109_writer_spec.cr
spec/wide_map_tuple_w108_consumer_spec.cr
spec/wide_part_writer_map_tuple_w108_spec.cr
spec/wide_map_tuple_w108_reader_spec.cr
spec/wide_array_tuple_w107_consumer_spec.cr
spec/wide_part_reader_compositional_tuple_spec.cr
spec/wide_part_writer_compositional_tuple_spec.cr
spec/qbit_reader_consumers_w103_spec.cr
spec/qbit_writer_w103_spec.cr
spec/offline_catalog_projection_w87_spec.cr
spec/offline_mv_materialization_w88_spec.cr
```

The executed common guarded command prefix was:

```sh
env CLICKHOUSE=/Users/sergey/.local/bin/clickhouse \
CLICKHOUSE_BIN=/Users/sergey/.local/bin/clickhouse \
COGNI_RUN_SAFE_MIN_FREE_PCT=50 RUN_SAFE_PASSTHROUGH_STDIO=1 \
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
TMPDIR=/private/tmp CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w109-cache \
PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin \
bash /Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh
```

Suffix `/opt/homebrew/bin/crystal 600 8192 spec --single-module
--link-flags=-fuse-ld=ld` followed by the 15 inputs passed 83 examples;
the same suffix with `--release` before the inputs passed 83 examples.
Both exited 0 with zero failures/errors/pending. Earlier Point-only DEBUG
and RELEASE runs each passed 17 examples before a formatting-only descriptor
change; the final 83-example runs include all those inputs on the fingerprint
above. With the same common prefix, suffix `/opt/homebrew/bin/crystal 600
32768 spec --single-module --link-flags=-fuse-ld=ld` and no input paths passed
the full DEBUG suite: 1,793 examples, zero failures/errors/pending, exit 0.
The non-fatal linker warning was duplicate `-lc`. No full RELEASE certificate
is claimed; RELEASE covers precisely the 15 listed inputs.

Suffix `/opt/homebrew/bin/crystal 600 8192 run --single-module
--link-flags=-fuse-ld=ld examples/write_point_part.cr -- NEW_PART_PATH`, using
an explicitly created private temporary parent, exited 0 and printed the
expected three raw-bit pairs over marks 0, 0 and 1: ordinary coordinates,
negative zero, and qNaN/infinity. The scratch part was removed afterward.

Suffix `/bin/bash 600 8192 scripts/probe_point_w109_green.sh reader` passed
four profiles: mixed IEEE, all-default, mixed IEEE with omitted statistics,
and key-first renamed columns. Each stock source and fresh ATTACH passed
actual CHECK=1 (eight results), exact declarations/inventory/codec/metadata,
independently calculated marks/PK bytes, seeded wrong-byte comparator controls,
and literal full/PK-selected RowBinary before typed full/selected/lazy reads.
The mixed omitted-statistics profile establishes that `columns: []` is not
an all-zero-only admission. Its ratio is 1, as for the all-default fixture.

Suffix `/bin/bash 600 8192 scripts/probe_point_w109_green.sh writer` passed
the same four profiles. Crystal emitted full Default counters even for both
ratio-1 profiles. Fresh stock ATTACH returned actual CHECK=1 (four results)
and exact full/PK-selected RowBinary, followed by typed raw-bit roundtrips.
The independent mark oracle distinguishes stock single-frame packing from
Crystal per-mark frames; byte-identical compression packing is not claimed.
Both phases exited 0. GREEN Crystal/shell SHA-256 digests are respectively
`0c15824b4812c4e3e8e6068b6552d67e1423d702287803c0e25c3ce1bac41269` and
`c15b4ff9e1c55dd5dfccf4df74cb74b506fa9a481b380d5ec57ffea23aa2b0fd`.

The frozen predecessor RED Crystal/shell digests remain respectively
`713b562ed569aff588995b98445c43ed6674945f2977bc925c1ec4f147c7821b` and
`315503a998cbe9552c7237ec05c4b95106f2b84fe5f809e5e96d4bba6710f62c`.
That historical probe is intentionally not reformatted or used as a GREEN
oracle. Final production, new specs, GREEN oracle and example pass formatter
checks; both shell scripts pass `bash -n`, and the tracked diff passes
`git diff --check`.

Two hostile-test instruments were corrected without relaxing production:
a one-byte mark shift hit the global alignment guard during open rather than
the selected-boundary guard; the aligned eight-byte shift now permits an
unselected first window and rejects the selected later mark before callbacks.
The raw-bit attack initially collapsed multiple frames, invalidating terminal
marks before readback; it now replaces only the first frame with equal encoded
size and refreshes checksums, reaching the exact raw-coordinate rejection.
The mark mutation also uses an owned byte copy rather than a read-only slice.

## Scoped hostile verdict and continuation

Root verdict: ROBUST within the declared two-column Wide/LZ4/Default/plain-mrk2
profile and immutable-input/root assumptions, at the production fingerprint
above and pinned 26.7 executable. The independent controls establish nominal
Point rather than generic Tuple admission, asymmetric X/Y bit identity,
selected/nonzero-origin and owned lazy values, metadata-only charge estimation,
cap-minus-one rejection before payload callbacks, eager selected-boundary
refusal, and successful unselected first windows. Refreshed-checksum raw-bit,
schema, mark, serialization and symlink attacks reject before publication;
preflight failures preserve the destination/siblings and failed stages clean up.
The caller's input allocations are not counted as writer-owned snapshots.

This is not a current-master executable certificate, arbitrary multi-column
Point table support, Nullable/Array(Point), other Geo or Geometry admission,
Compact/Sparse support, peak-RSS/throughput qualification, fsync durability,
live-server root authority or complete facade decomposition. Version-1
metadata with new fields such as `exact_num_defaults` requires its own
qualification rather than relaxing this exact guard by analogy.

Next type frontier: stock-first paired Geo Array profiles (`MultiPoint`,
`LineString`, `Ring` and deeper arrays), then fixed-discriminator `Geometry`.
Broader recursive-container, Variant/Dynamic, JSON shared/dynamic-data and
aggregate-state profiles remain open, followed by MV/projection expansion.
Performance remains deferred. Requalify affected commands on changes to the
reference commit, executable, physical/metadata recipe, owner/codec/dependency
source, selection/lifetime/budget contract or staging/publication authority.
