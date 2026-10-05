# Interval reader/writer frontier — W160

Status: VERIFIED within the executed scalar/Nullable Wide profile below;
broader recursive whole-part products remain open.
Baseline: clean `7a5a644`. Risk: CAUTION (nominal type admission and persisted
serialization). Rollback: one coherent local feature commit after the gates;
preserve unrelated work and do not push.

## Anchor and boundary

The shallow source `41b7bd50051cc2017fe5ca5505fb35c9dc620000` defines
Interval binary tag `0x22` followed by exactly one kind byte: Nanosecond,
Microsecond, Millisecond, Second, Minute, Hour, Day, Week, Month, Quarter,
Year map to `0x00..0x0A`. `DataTypeInterval` inherits `DataTypeNumberBase<Int64>`
but equality/hash retain its kind; equal physical bytes are not equal types.
Sources: `src/DataTypes/DataTypesBinaryEncoding.{h,cpp}`,
`src/DataTypes/DataTypeInterval.{h,cpp}`, `src/Common/IntervalKind.h`, and
`src/DataTypes/Serializations/SerializationInterval.h` in that checkout.
Root compared those descriptor/kind anchors and all serializers against the
previous `895d13ea` snapshot: no relevant content change (diff exit 0).

Root ran the separately pinned ClickHouse 26.10.1.1201 build `d9bcb5ab`,
SHA256 `bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`,
under the resource guard (60 seconds/4096 MiB, 50-percent free-memory floor).
Standalone IntervalSecond with values 7/-3 and Nullable(IntervalYear) plus
LowCardinality(IntervalMonth) passed CREATE/INSERT/literal SELECT/CHECK in
newly owned `/private/tmp/crystal-click-w160.QzWWWJ` directories. LC used
`allow_suspicious_low_cardinality_types=1`. A separate `JSON(v IntervalSecond)`
CREATE failed with stock code 43: unsupported JSON return schema. These are
eligibility probes, not library codec or part certificates.

Admit all eleven exact kinds together in the general binary descriptor,
logical value, normalized bulk and physical binding owners. Preserve raw
signed Int64 counts; do not convert calendar units or relabel Int64 as Interval.
Add paired scalar/nullable Wide-part read/write accessors with exact kind
metadata. Array/Tuple/Map/Variant/Dynamic/LC compositions in generic codecs
must obey their existing constructor, budget, roster and storage laws; they
do not alone qualify all public part/container shapes.

Keep Object/JSON Interval declarations and actual arms rejected, matching the
stock JSON serializer boundary. Unknown kind bytes are corrupt, truncated
kind/payload is corrupt, and unsupported unrelated tags remain unsupported.
Do not admit noncanonical aliases or make primitive Int64 readers accept
Interval. Broader Wide container integration, arbitrary-schema writing,
MV/projections, calendar arithmetic and performance are not completed here.

## Design laws and strongest failure

One cohesive immutable `BinaryIntervalType` owner/file governs kind, exact
canonical name, wire code and width. BinaryDataType retains it in equality and
hash. The shared name-budget owner must bound the longest Interval spelling
before materialization; its existing 16-byte primitive fallback is too short.
Fixed payload construction and both codec directions preserve the semantic
descriptor. Existing budgets, full mark grids and LC occurrence replay apply.

Wide-part readers/writers use explicit Interval gates and raw Int64 counts,
with no primitive numeric admission. Staged publication validates the actual
exact declaration, checksums, values, mark rows and primary index before
exclusive publication; no metadata relabeling of a generated Int64 fixture.

Strongest likely failure: same-width, same-value Month/Second metadata passes
readback or a caller observes an Int64 without the declared kind. Attack exact
kind mismatch, Int64 versus Interval, unknown/forged kinds, empty/null/default
values, signed extremes, truncated input, selected zero/middle windows and
one-short descriptor/name/value/transport budgets. Unsupported JSON admission
must stay closed after adding the new general tag.

Preserve selection context: direct Wide mark-range accessors require a
nonempty mark range and reject `mark_count = 0` with `BoundsError`, like the
existing fixed-width readers. Zero normalized-bulk selection and zero-row
table windows are separate APIs; they do not justify widening that contract.

## Execution and DoD

Sealed shared API: `BinaryIntervalType::Kind` uses the eleven wire codes;
`BinaryIntervalType.new(kind)` rejects unknown forged enum values, and
`.parse(String)` accepts only an exact bare canonical name. Its immutable
accessors are `kind`, `kind_code`, `type_name`, and `name_byte_size`.
`BinaryDataType.interval(kind)` retains `interval_type`;
`BinaryValue.interval(type, count : Int64)` and `as_interval_count` remain
separate from primitive Int64. `IntervalColumnType` owns scalar/nullable
shape. Wide APIs are `read_interval_counts_mark_range`,
`read_nullable_interval_counts_mark_range`, and writer
`write_uint64_interval_pair(destination, key_name, keys, value_name, counts,
kind, rows_per_mark = 8192)` plus its nullable counterpart.

1. Root observes RED using existing descriptor decode API on literal
   `0x22, kind` bytes for all eleven kinds, alongside supported Int64 controls.
   Native stock-authored parts qualify a public reader admission RED.
2. Luna core owns `binary_interval_type.cr`, BinaryDataType, scalar/descriptor
   codecs, BinaryValue, name budgets and LC policy. Luna Wide owner owns
   reader/writer Interval seams, dedicated cohesive helpers where needed,
   metadata/readback and consumer integration. Luna oracle owns independent
   specs and stock harnesses. Root owns this frontier, require graph, serial
   compiler/native jobs, hostile review and final commit. Workers are not alone
   and must preserve other edits; exact ownership is assigned before changes.
3. Focused DEBUG/RELEASE plus affected descriptor/value/bulk/physical and
   typed-part/readback regressions must have zero failures/errors/pending.
   Run serially via `run_safe.sh`, isolated cache, SDK26.5, Crystal1.21.0,
   host linker `--link-flags=-fuse-ld=ld`, single module/one compiler thread.
4. Independent native source parts and independently library-authored whole
   scalar/nullable parts must preserve all eleven kinds, signed counts, exact
   physical bytes/marks, actual ATTACH/CHECK and full/middle literals. Seed an
   unchanged-oracle wrong-kind or same-size value mutant so green checks alone
   cannot substitute for nominal/value compatibility.
5. Root checks unsupported JSON guards, primitive numeric refusal, publication
   rollback, format/syntax/diff/hygiene, and the final intended diff. Record
   executed scope and residual gaps before the atomic local commit.

Refresh this seal on kind/name policy, descriptor/value/bulk/physical codec,
LC policy, part metadata/readback/selection, publication, runtime/settings or
toolchain changes. Source identity is not runtime qualification. The active
goal remains complete type compatibility and MV/projections before performance;
this staged implementation does not redefine that endpoint.

## Executed certificate (2026-10-04 local / 2026-10-05 UTC)

Root's scoped hostile verdict: ROBUST for the declared boundary, after source
inspection, root-owned guarded execution, current hash reconciliation and
CHECK-valid type/value counterexamples. Luna implementation and review share
lineage and are correlated support, not independent qualification.

The baseline literal admission RED observes 12 examples, eleven Unsupported
errors for Interval descriptors and one passing primitive Int64 control, exit
1. A stock-authored public Interval reader admission separately fails with
Unsupported before integration. After integration, both controls run green
in the focused gates; the opt-in stock fixture environment is supplied, not
silently omitted.

Final DEBUG: 31 examples, six unique specs, one group. Final RELEASE: 701
examples, 57 unique specs, eight disjoint groups. Every group exits 0 with
zero failures, errors and pending. Root independently reconciles each observed
log's single result line, ordered membership, uniqueness and all 297 DEBUG /
348 RELEASE source-and-spec hashes against the final files. These inventories
are affected gates, not a new full-project run or an RSS/performance result.

The guards pin canonical grammar, longest names and exact type identity;
unknown/forged kinds and truncated descriptors/payloads; signed extrema and
zero/NULL/default counts; one-short name/node/value/transport budgets;
primitive Int64 reader/table refusal; generic recursive, LC, Variant and
Dynamic composition under their existing laws; and continued Object/JSON
Interval refusal. Wide guards reject unsupported global/string serializer
versions, per-column profiles, missing columns/serialization metadata and
corruption in a later unselected mark before any EOF-window callback. A
spec-only validator bridge rejects a same-length Hour-to-Year declaration
change before publication. That bridge is metadata-readback evidence, not a
new public failed-publication cleanup test. Root inspects the inherited
exclusive-publication/ensure path; the affected nullable-temporal writer suite
retains its public failure/destination-preservation/cleanup characterization.

The independent stock/library oracle exits 0 in a fresh owned directory:
`/private/tmp/crystal-click-interval-w160.OgRxa7`. It creates a stock-authored
Wide/LZ4 table with pk UInt64 and all eleven scalar plus eleven Nullable
Interval columns from literal Ruby RowBinary input. Stock schema/part metadata,
CHECK, full/middle/empty RowBinary and library reads of all kinds agree. The
public stock reader spec executes once more on this native part (one example,
zero failures/errors/pending).

The Crystal driver independently creates 22 canonical complete Wide parts,
each with `pk UInt64` and one exact Interval or Nullable(Interval) value column.
It checks raw signed Int64 little-endian payloads, nullable maps, stream roster,
LZ4/global metadata, `[2, 2, 2, 0]` real/final mark rows, direct full/middle reads,
table batches/windows and offline catalog column values. Direct mark_count 0
continues to raise BoundsError; EOF table windows have no callbacks. All 22
parts are actually ATTACHed and CHECKed by stock, with exact `system.columns`
types and independent literal full/middle/empty RowBinary equality. Root
separately reads and reconciles those 22 schema outputs, 22 CHECK outputs and
66 raw output windows instead of relying only on the harness summary.

Two additional whole parts pass ATTACH/CHECK but fail the unchanged original
oracle for the intended reason. The Second-to-Month mutant changes only
`columns.txt`; root verifies identical file rosters and every non-columns
file byte, identical count output, and changed declared kind. The separately
authored IntervalSecond value mutant changes only the first expected count
from Int64::MIN to Int64::MIN + 1; observed stock output matches that mutant
and differs from the unchanged original literal. Thus CHECK/file integrity
alone does not certify nominal or value compatibility. There are 24 attached
part cases including the two controls, not 24 baseline type profiles.

Native scope: Wide, uncompressed .mrk2 and primary index, LZ4, default
per-column metadata, string serialization version 1, sparse-default ratio 1,
six rows, three real plus one terminal mark, all eleven scalar/Nullable kinds,
negative/zero/extreme counts and NULL. Compact/per-column serializer profiles,
arbitrary schemas/partitions, recursive or LC complete Interval parts,
Object Interval, MV/projections and performance remain unqualified here.
Part paths and backing files are assumed immutable during reads; this does
not certify race-safe access to a live mutating server data root.

The executed runtime remains ClickHouse 26.10.1.1201 build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, executable SHA256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
Source `41b7bd50051cc2017fe5ca5505fb35c9dc620000` is separately observed,
shallow, clean and unbuilt; no source-to-executable build claim is made.

### Commands, evidence index and preparation repairs

Root serial compiler gates use Crystal 1.21.0, SDK26.5, the host linker,
isolated cache and `run_safe.sh` with 600 seconds / 12288 MiB process-tree RSS
and a 50-percent system-free-memory floor. The flags are
`spec <inventory group> --single-module --threads 1
--link-flags=-fuse-ld=ld --error-trace`; RELEASE adds `--release --no-debug`.
Groups are consecutive chunks of at most eight files in the exact inventory
below. The opt-in stock reader receives
`W160_INTERVAL_STOCK_WIDE_PART=/private/tmp/crystal-click-w160.QzWWWJ/interval-stock-wide/store/863/8639e645-e040-4900-96a9-00840cbf4669/all_1_1_0`
and uses its default `v` column. That earlier native fixture has keys
1/2/4/6/9/11 and counts 7/-3/0/42/-1/11.

The retained gate runner, manifests and logs are under
`/private/tmp/crystal-click-w160.QzWWWJ`: `run_gates.rb`,
`debug-manifest.json`, `release-manifest.json`, `debug-1.log` and
`release-{1..8}.log`. Root executes the runner as `ruby run_gates.rb debug`
then `ruby run_gates.rb release` from that retained location. These scratch
files are refresh aids, not permanent proof; the repository inventory and
arguments define the rerun if they disappear.

Executed native command from repository root:

```sh
env COGNI_RUN_SAFE_MIN_FREE_PCT=50 RUN_SAFE_PASSTHROUGH_STDIO=1 \
  SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  TMPDIR=/private/tmp W160_EXECUTE_AS_ROOT=YES \
  CRYSTAL_BIN=/opt/homebrew/bin/crystal RUBY_BIN=/usr/bin/ruby \
  CLICKHOUSE_BIN=/private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped \
  /bin/bash /Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh \
  /bin/bash 600 12288 scripts/check_interval_w160.sh
```

`W160_EXECUTE_AS_ROOT` records parent-agent job ownership, not Unix privilege.
The wrapper uses a fresh direct `/private/tmp` child, isolated cache, explicit
owned stores and exclusive evidence writes; it refuses reused/symlink roots.
It does not nest the external resource guard or clean up unrelated paths.
Native evidence is indexed by `recheck.log`, `results/ruby-oracle/pins.txt`,
`summary.txt`, numbered SQL/stdout/stderr, the two `wrong-*-oracle-rejection.txt`
files and `results/crystal/` in the retained native directory.

Final native harness hashes, independently observed after execution:

```text
4a55a34519a86b71970aec4c4491358d1adfe9bd3231a17acac6285945d8b8d7 scripts/check_interval_w160.cr
6f0955d33a0d3cbb7af5eb8a8d1d8c9a1a13c76786e62dd23b0881a4a01b6da2 scripts/check_interval_w160.sh
e7dd4d02023e1f472fd43dbeed4a1fd7f6da7751bf28fe5874ba0290a9c0da58 scripts/recheck_interval_w160.rb
```

Preparation corrected test-only unsigned-byte masking, physical role/offset
expectations, canonical part basenames and a zero-mark expectation. Harness
static review corrected fixture/marker assumptions and a tee log-creation
race; stdout is synchronized for bounded updates. The actual native oracle
passes on its first executed run. Root's extra CHECK-output reconciliation
initially expected two TSV columns; stock includes a third empty message
column, and the literal check was corrected before reconciliation passed.
These repairs are instrument evidence, not hidden production regressions.
Formatter, Ruby/shell syntax and diff/hygiene checks accompany final closure.

### Exact gate inventory

DEBUG uses the first six entries. RELEASE uses all 57 once, split after each
eighth entry; no overlapping group totals are added.

```text
spec/interval_w160_admission_red_spec.cr
spec/interval_w160_core_spec.cr
spec/interval_w160_guards_spec.cr
spec/interval_w160_recursive_spec.cr
spec/interval_w160_stock_reader_red_spec.cr
spec/interval_w160_wide_spec.cr
spec/binary_value_codec_w117_spec.cr
spec/binary_scalar_types_w119_spec.cr
spec/binary_bulk_w122_spec.cr
spec/physical_stream_plan_w125_spec.cr
spec/binary_low_cardinality_w141_spec.cr
spec/binary_low_cardinality_storage_w142_spec.cr
spec/binary_low_cardinality_bulk_w143_spec.cr
spec/binary_low_cardinality_float_bulk_w144_spec.cr
spec/binary_low_cardinality_physical_w145_spec.cr
spec/binary_variant_value_w147_spec.cr
spec/binary_variant_value_w147_adversary_spec.cr
spec/binary_variant_bulk_w148_spec.cr
spec/binary_variant_bulk_w148_adversary_spec.cr
spec/binary_variant_physical_w149_spec.cr
spec/binary_variant_physical_w149_adversary_spec.cr
spec/binary_bulk_physical_prefix_w151_spec.cr
spec/binary_dynamic_descriptor_w152_spec.cr
spec/binary_dynamic_value_w153_spec.cr
spec/binary_dynamic_bulk_plan_w154_spec.cr
spec/binary_dynamic_bulk_plan_w154_adversary_spec.cr
spec/binary_dynamic_bulk_values_w155_spec.cr
spec/binary_dynamic_bulk_values_w155_adversary_spec.cr
spec/binary_dynamic_bulk_shared_context_w155_spec.cr
spec/binary_dynamic_physical_w156_spec.cr
spec/binary_dynamic_physical_w156_adversary_spec.cr
spec/binary_dynamic_statistics_offsets_w157_spec.cr
spec/wide_part_writer_typed_spec.cr
spec/wide_part_writer_nullable_temporal_spec.cr
spec/wide_part_writer_typed_mark_readback_spec.cr
spec/wide_part_writer_metadata_w150_spec.cr
spec/wide_part_writer_datetime_spec.cr
spec/wide_part_writer_date_spec.cr
spec/nullable_temporal_scan_spec.cr
spec/datetime_scan_spec.cr
spec/fixed_numeric_scan_spec.cr
spec/timezone_temporal_admission_w104_spec.cr
spec/timezone_temporal_consumers_w104_spec.cr
spec/timezone_temporal_writer_w104_spec.cr
spec/offline_catalog_spec.cr
spec/multicolumn_table_scan_spec.cr
spec/streaming_scan_spec.cr
spec/object_document_schema_w131_spec.cr
spec/object_document_schema_w140_spec.cr
spec/object_declared_low_cardinality_w146_spec.cr
spec/object_low_cardinality_consumers_w146_spec.cr
spec/object_declared_variant_w151_spec.cr
spec/object_variant_consumers_w151_spec.cr
spec/object_recursive_dynamic_w159_spec.cr
spec/object_recursive_dynamic_w159_adversary_spec.cr
spec/object_temporal_w139_root_spec.cr
spec/object_recursive_consumers_w140_spec.cr
```

This certificate depends on the declared source anchors, implementation,
runtime/settings, fixture and toolchain. Refresh after any changed kind/name
policy, codec/LC/Object boundary, part metadata/readback/selection/publication
path, relevant upstream source or native profile. Failure reopens only the
dependent claim; the active all-types/MV/projection/performance goal is not
completed or narrowed by this scoped checkpoint.
