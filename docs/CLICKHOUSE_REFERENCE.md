# ClickHouse Reference Sources and Binary Oracles

## Current source snapshot

The user requested a fresh, separate depth-1 checkout on 2026-09-29. The
reference source for new comparisons is now:

- Checkout: `/Users/sergey/SrcArchives/clickhouse-2026-09-29-depth1`
- Repository: `https://github.com/ClickHouse/ClickHouse.git`
- Branch: `master`
- Commit: `a9581941254d6113f3740a8ec125ee7519cb1bda`
- Commit time: `2026-09-29T23:09:07Z`

It was created with:

```sh
git clone --depth 1 --single-branch https://github.com/ClickHouse/ClickHouse.git /Users/sergey/SrcArchives/clickhouse-2026-09-29-depth1
```

Observed checks: `git rev-parse --is-shallow-repository` returned `true`,
`git rev-list --count HEAD` returned `1`, and `git status --porcelain=v1`
returned no changes. The older checkout at
`/Users/sergey/SrcArchives/clickhouse` was not changed. Its previously inspected
June snapshot must not be described as current master.

## Observed registration delta

Comparing literal registration names under `src/DataTypes` at the old
`4576ba3bfaca2c2b6bba3fc43dd7142f581db082` and current reference commits
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
check. `MultiPoint` is not admitted by the Crystal reader or writer yet.

## Observed serializer additions

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
