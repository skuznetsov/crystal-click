# ClickHouse Reference Sources and Binary Oracles

## Current source snapshot

The user requested a fresh, separate depth-1 checkout, refreshed on
2026-10-01. The reference source for new comparisons is now:

- Checkout: `/Users/sergey/SrcArchives/clickhouse-2026-10-01-depth1-935de744`
- Repository: `https://github.com/ClickHouse/ClickHouse.git`
- Branch: `master`
- Commit: `935de7442d7890eb5631372e4ad6f66faaf35f90`
- Commit time: `2026-10-01T21:25:16Z`

It was created with:

```sh
git clone --depth 1 --single-branch --branch master https://github.com/ClickHouse/ClickHouse.git /Users/sergey/SrcArchives/clickhouse-2026-10-01-depth1-935de744
```

Observed checks: `git rev-parse --is-shallow-repository` returned `true`,
`git rev-list --count HEAD` returned `1`, and `git status --porcelain=v1`
returned no changes. The earlier October 1 snapshot at
`/Users/sergey/SrcArchives/clickhouse-2026-10-01-depth1`, revision
`b762d6d7fe4b201147bdce1bd49b8fc87a8049d3`, remains unchanged. The September 29 snapshot at
`/Users/sergey/SrcArchives/clickhouse-2026-09-29-depth1`, revision
`a9581941254d6113f3740a8ec125ee7519cb1bda`, and the older checkout at
`/Users/sergey/SrcArchives/clickhouse` were not changed. The latter's previously
inspected June snapshot must not be described as current master.

## October 1 evening refresh

Root observed `935de7442d7890eb5631372e4ad6f66faaf35f90` as the remote master
head, cloned into the separate path above, and confirmed that exact clean,
single-commit shallow checkout. Relative to the earlier October 1 snapshot,
`diff -qr` under `src/DataTypes` reports only `DataTypeObject.cpp` and
`Native.cpp`. The former removes beta wording from the embedded Lazy Type
Hints documentation; the latter adds a Decimal scale-lifting comment. Neither
diff changes executable code. Registration and serialization files in that
directory are otherwise identical. Focused comparisons also found unchanged
`MergeTreeDataPartWriterWide.cpp`, `MergedBlockOutputStream.cpp` and
`checkDataPart.cpp` under `src/Storages/MergeTree`.

This refresh does not widen Crystal admission or requalify the pinned binary.
The observed Geometry/Variant/Dynamic/JSON source profiles are unchanged within
this comparison; whole-server compatibility and a current-source executable
are not certified. Older source and executable certificates retain their
original revisions and tested profiles.

## Earlier October 1 comparison with September 29

This section compares `b762d6d7fe4b201147bdce1bd49b8fc87a8049d3` with
`a9581941254d6113f3740a8ec125ee7519cb1bda`, not the evening refresh directly.

Both snapshots have 68 distinct literal registrations using the extraction
below, with identical sorted name sets. This includes custom Geo registration;
it is not an alias inventory or a proof of complete physical-type support.
The Geo registration implementation and `DataTypeFactory.cpp` are identical.
`SerializationInfoSettings.{h,cpp}`, `SerializationInfo.{h,cpp}` and
`SerializationInfoTuple.*` are also identical.

The nine differing files under `src/DataTypes` were inventoried with
`diff -qr`. Relevant source-derived deltas are:

- `ISerialization.h:379` adds requested-subcolumn context; `IDataType.cpp:245`
  passes it into stream enumeration. `SerializationObject.cpp:226` narrows
  typed-path enumeration for a requested subcolumn, while full enumeration
  retains its previous sorted order. This is a stream-selection change, not
  an observed change to the written typed-path layout.
- `DataTypeAggregateFunction.cpp:210` introduces a shared window-only function
  rejection guard, also called by binary type decoding in
  `DataTypesBinaryEncoding.cpp:771`. Type names did not change, but the set
  of accepted aggregate-state declarations did.
- Nullable and Variant text parsing now uses the default `PeekableReadBuffer`
  constructor instead of an explicit one-byte initial buffer. These inspected
  call sites are not persisted-part binary serialization changes.

The inspected MergeTree settings delta expands help text for
`adaptive_write_buffer_initial_size` without changing its 16 KiB default.
Empty-part subcolumn-size accounting and alias dependency selection also
changed; no stream encoding change was identified in those paths. This is a
bounded source comparison, not a universal cross-version compatibility proof.
No current-master executable was built or substituted for the pinned oracle.

## Historical June-to-September registration delta

Comparing literal registration names under `src/DataTypes` at the old
`4576ba3bfaca2c2b6bba3fc43dd7142f581db082` and September 29 reference commits
produced 67 and 68 distinct names, respectively. The only added name is
`MultiPoint`; none were removed in this comparison. The current
`DataTypeCustomGeo.cpp` registers it as a custom type backed by `Array(Point)`
and also adds it to the `Geometry` variant.

The extraction must include `registerSimpleDataTypeCustom`, not only
`registerDataType` and `registerSimpleDataType`. For each checkout, run:

```sh
rg --files src/DataTypes -g '*.cpp' | xargs perl -0777 -ne 'while(/register(?:Simple)?DataType(?:Custom)?\s*\(\s*"([^"]+)"/sg){print "$1\n"}' | sort -u
```

This is a literal-registration comparison, not a complete alias inventory,
persisted-column support matrix, or serializer compatibility proof. A narrower
initial extraction missed the custom registration and was rejected after this
check. The paired nominal `MultiPoint` profile is now qualified separately in
`GEO_TYPES_FRONTIER.md`; this registration comparison alone does not admit it.

## Historical June-to-September serializer additions

The source-level comparison also identified these persisted-layout changes:

- `DataTypeCustomGeo.cpp` now constructs `Geometry` with fixed Variant
  discriminator order. Existing alternatives occupy 0 through 5, and
  `MultiPoint` is appended at 6. The source explicitly documents the
  persisted-discriminator compatibility constraint; cross-version part reads
  have not been executed for this feature.
- `SerializationObjectSharedData.h/.cpp` add `ADVANCED_CHUNKED = 3`. The June
  reader accepts only `MAP`, `MAP_WITH_BUCKETS`, and `ADVANCED` (versions 0-2);
  the fresh reader retains those and also accepts 3. The new shared-data format
  uses chunk-then-streams in Wide parts and stream-then-chunks in Compact
  parts. `object_shared_data_serialization_version = 'advanced_chunked'` is
  opt-in; the normal setting remains `advanced`, and zero-level parts have
  their own default. This shared-data version is distinct from the outer JSON
  serialization version. Crystal's bounded JSON profile does not admit it.
- `SerializationInfo.cpp` can now emit `exact_num_defaults: true` in
  `serialization.json`; the older checkout has no such field. Without exact
  tracking, `num_defaults` can be a sampled estimate, not a recount of the
  physical values. Crystal's pinned Tuple profile accepts bounded counts but
  rejects the new field under its exact metadata-key guard. A current-master
  metadata profile needs a separate admission test; unchanged leaf bytes do
  not establish that compatibility.

The discriminating runtime probes are an old-alternative Geometry part read
across versions, plus Wide and Compact JSON parts with forced shared paths and
the chunked setting. They require a current-capable executable; the pinned
26.7 oracle cannot establish current-master behavior. Inspection of selected
Dynamic, Variant, Tuple, and LowCardinality writer paths did not identify
another persisted-byte change, but this bounded negative search is not a
proof that every serializer or execution path is unchanged.

## Executable compatibility evidence

### Isolated W112 capable peer (bounded paired qualification)

On 2026-10-01 root downloaded the official macOS arm64 moving-master binary
linked by `https://clickhouse.com/support/platforms`, from
`https://builds.clickhouse.com/master/macos-aarch64/clickhouse`, into
`/private/tmp/crystal-click-w112-runtime.u0Jn1f/clickhouse`. No installed binary
or default symlink was replaced. The retrieved self-extracting carrier was
174,530,241 bytes; its SHA-256 was
`23b2e0292f622565b8312795c190b8af89cb0eae559b6e51ac856a7259bdbf44`.
On its first invocation the carrier expanded and replaced its own temporary
path with a 746,226,224-byte Mach-O arm64 executable, SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
The fresh source's `utils/self-extracting-executable/decompressor.cpp:508-574`
implements this Darwin copy-over followed by `execv`. Root observed the size
change, repeated the guarded version invocation successfully, and rechecked
the expanded hash afterward. The first stock wrapper run stopped at the
carrier-versus-expanded hash mismatch before compilation; that was not a
feature RED. The wrapper now gates the two known input identities and strictly
requires the expanded identity after version invocation. These locally
computed hashes pin different artifacts; neither is a publisher checksum.

Actual `local --version` is `26.10.1.1201 (official build)`.
`system.build_options` reports `GIT_HASH` and `VERSION_GITHASH` as
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`. This differs from the fresh source
checkout above. The moving URL is not a source revision identity.

Root's serial guarded query on an isolated local store exited 0:

```sql
SELECT version(),
       toTypeName(CAST([(1.,2.)], 'MultiPoint')),
       toTypeName(CAST(CAST((1.,2.), 'Point'), 'Geometry'));
```

It returned `26.10.1.1201`, `MultiPoint`, `Geometry`. An initial generic
`Tuple(Float64,Float64)` to Geometry cast was correctly rejected; the
qualification uses a nominal Point instead. This small query proves only this
executable's nominal capability. Root subsequently ran the stock-first W112
qualification and reader/writer GREEN modes: five source plus fresh-ATTACH
profiles, followed by four Crystal-written MultiPoint profiles accepted on
fresh ATTACH. Every CHECK result was asserted as `part_name\t1`, with literal
full and selected RowBinary, raw coordinate bits, topology, physical stream
bytes, marks, metadata and checksum hashes. The full executed profile and
hostile guards are recorded in `GEO_TYPES_FRONTIER.md`. This does not certify
Geometry, current-source build equivalence, arbitrary schemas or all layouts.
Pinned 26.7 predecessor certificates are unchanged and are not upgraded by
this capability probe. Refresh the retrieved byte/version/build pins before
using another peer or treating a future download as equivalent.

Existing physical-format oracles remain pinned to
`ClickHouse local version 26.7.1.1315 (official build).` at
`/Users/sergey/.local/bin/clickhouse`. Its version was rechecked after cloning.
The fresh source checkout is not a newly built or installed ClickHouse binary.

Keep these evidence scopes separate:

- Source inspection identifies current type registration, serialization
  responsibilities, layouts, settings, and candidate compatibility gaps.
- A pinned binary oracle establishes the actual read/write behavior tested
  against that specific executable and fixture profile.
- Registration alone does not establish that a type is a persisted table
  column, that Crystal supports it, or that arbitrary compositions work.
- Passing a 26.7 oracle does not establish compatibility with current master.
  A separate executable/version matrix is needed for that claim.

Do not assume that retaining a type name fixes its serialization version or
all part layouts. Inspect the relevant serializer and settings, then test the
admitted physical profile in both directions. Unsupported profiles remain
fail-closed rather than being inferred from a related type's passing oracle.

## Refresh and decay

This is an immutable comparison anchor, not an automatic update policy.
When the source reference changes, record its exact commit and recheck the
affected registration/serializer conclusions. When an oracle binary or
fixture profile changes, rerun the affected read/write checks; earlier source
or binary evidence does not silently transfer to the new version.
