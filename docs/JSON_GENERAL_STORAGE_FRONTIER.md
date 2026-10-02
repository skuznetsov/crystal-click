# General JSON Storage Frontier

Status: W115 stock capture, W116 independent physical/type qualification,
W117's reusable paired binary type/value kernel, W118's decompressed
shared-MAP block codec and W119's fixed-width scalar extension were executed
on 2026-10-02. W117, W118 and W119 are VERIFIED
within their scalar/block profiles and gates below, not as a general
Object/Dynamic/MergeTree codec. The precise whole-document missing-capability
RED is qualified, not resolved. General JSON
document reading/writing is not admitted. W24/W72 declared scalar projections
remain the only paired JSON capability; see `JSON_TYPED_PATH_FRONTIER.md`.
W120's paired complete decompressed structure-metadata codecs are VERIFIED
within the source/local and V3 MAP stock gates below. W121's paired normalized
Dynamic discriminator streams and selected sparse schedules are VERIFIED within
their strict captured-writer profile below. Dynamic child value lanes,
cardinality and compressed physical mark mapping remain the next owner boundary;
metadata and discriminator schedules do not admit whole-document JSON.
The target is a reusable Object/Dynamic/shared-data engine, not another exact
declaration registered in the existing facades. Performance work remains parked.

## Source anchor and compatibility boundary

The current separate shallow reference checkout is
`/Users/sergey/SrcArchives/clickhouse-2026-10-02-depth1-31d2addb`, revision
`31d2addbabda0d8e14ffd325fc0a9106528aa1c7`. Its source informs the design; it
is not the build provenance of the runtime oracle. The initial runtime is
ClickHouse 26.10.1.1201, build `d9bcb5ab007f0f6299f7f973f2642245bab3d028`,
Mach-O SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
Its measured outputs must not be described as current-master executable evidence.
The earlier `0c68f01a75a913b1aa5e132b41a80642260c3009` reference
was compared on October 2 to the initial capture/literal-source baseline,
`/Users/sergey/SrcArchives/clickhouse-2026-10-01-depth1-935de744`, revision
`935de7442d7890eb5631372e4ad6f66faaf35f90`; the relevant serializers, binary
encoding, Columns and Formats are unchanged. See `CLICKHOUSE_SOURCE_REFERENCE.md`.
The current reference's DataTypes, Columns and MergeTree directories are
byte-for-byte equal to that earlier reference; the serializer anchors below
remain applicable. This is source comparison, not a new executable qualification.
Keep the initial capture/literal source and runtime identities intact.

Source anchors, relative to that reference checkout:

- `src/DataTypes/Serializations/SerializationObject.h:23`: MergeTree Object
  V1/V2/V3 have wire codes 0/2/4; STRING/FLATTENED are separate Native modes.
- `src/DataTypes/Serializations/SerializationObject.cpp:299`: V1/V2 force MAP;
  V3 records the shared-data version and, where applicable, bucket count after
  the sorted dynamic-path roster. Empty Wide shared data has a special
  one-bucket case; schema or configured bucket count alone is not an inventory.
- `src/DataTypes/Serializations/SerializationObjectSharedData.h:29`: shared
  wire versions are MAP=0, MAP_WITH_BUCKETS=1, ADVANCED=2,
  ADVANCED_CHUNKED=3. Advanced layouts have per-bucket path/substream metadata
  and additional whole-data copy streams; chunk order differs for Wide/Compact.
- `src/Storages/MergeTree/MergeTreeSettings.cpp:361`: current source defaults
  are Object V3, advanced shared data for merges and map_with_buckets for
  zero-level parts. The first capture explicitly forces zero-level MAP; this
  is a probe setting, not a restriction of the eventual compatibility goal.
- `src/DataTypes/Serializations/SerializationDynamic.cpp:242`: Dynamic V3
  stores binary type descriptors and optional statistics. A shared Dynamic
  payload contains binary DataType encoding followed by that type's value,
  not just a discriminator of the existing String/UInt64 profile.
- `src/Formats/JSONExtractTree.cpp:2199` and `src/Columns/ColumnObject.cpp:511`:
  initial JSONEachRow insertion visits fields in input order and claims new
  dynamic paths until the cap is full. In the mixed literal input, typed `a`
  is followed by `s`, so `s` fills the one-path budget. Frequency-based path
  selection during merges must not be substituted for this insertion rule.
- `src/DataTypes/DataTypeObject.cpp:900`: MAP shared data is
  `Array(Tuple(paths String, values String))`; each value String carries its
  binary nominal type descriptor and value, not a bulk Dynamic column.
- `src/DataTypes/Serializations/SerializationString.cpp:145` and `:630`:
  the default bulk String stream carries VarUInt byte length plus bytes;
  StringWithSizes uses a separate UInt64 size stream. Neither convention
  licenses adding a trailing NUL. An embedded input NUL is ordinary data.
- `src/DataTypes/DataTypesBinaryEncoding.cpp:383` and `:432`: scalar Array
  values require the complete recursive binary type
  descriptor before their VarUInt count and nullable element values.
- `src/DataTypes/DataTypeObject.cpp:240` and
  `src/Storages/ColumnsDescription.cpp:170`: persisted type names are canonical;
  changed JSON budgets precede sorted typed paths. Original DDL argument order
  is not the expected `columns.txt` order or a separate nominal type.
- `src/Storages/MergeTree/MergeTreeSettings.cpp:296` and
  `src/DataTypes/Serializations/SerializationVariant.cpp:211`: the default
  compact-discriminator setting writes mode 1, followed by granule formats;
  the W115 settings do not override it. BASIC mode 0 is not this capture.
- `src/DataTypes/Serializations/SerializationObject.cpp:1184`: default whole
  JSON RowBinary is flattened path/value encoding, with dynamic type tags;
  it is not a length-prefixed JSON string. Typed/dynamic path iteration is
  not an independent canonical ordering contract. Text and binary observations
  must be captured and qualified separately.

Current production anchors: `WidePart.json_typed_paths` parses simple declared
scalar paths, not JSON settings or arbitrary paths; whole JSON fails exact typed
admission. Existing typed-path reading validates the Object V3 prefix but does
not decode the remaining shared structure. Its writer substitutes already
normalized scalar defaults and emits empty dynamic/shared data. Existing Dynamic
profiles require empty SharedVariant rows/statistics. None of these guards
demonstrates general JSON support.

## W115 capture checkpoint

Risk: CAUTION for compatibility conclusions; the instrument writes only into
its own validated fresh temporary root. No installed source checkout, existing
server store, reader/writer admission, dependencies, or publication policy may
change. Rollback is the isolated instrument/documentation commit.

Capture three Wide/LZ4/plain-adaptive-mark source profiles, with granularity two:

1. Untyped JSON with sufficient dynamic-path/type budgets.
2. JSON with `max_dynamic_paths=0`, requiring nonempty shared data.
3. Declared typed path plus constrained dynamic path/type budgets, requiring
   real typed, dynamic and shared values in one part.

Use literal rows spanning at least three nonempty marks, a nonzero-origin
selection, changing numeric/String/Bool/array values, nested paths, missing/null
and empty values. One retained dynamic path must change nominal type across
marks (String, numeric and Bool); the selected window must cross a transition.
Record actual path/type introspection and any SharedVariant spill rather than
assuming the constrained budget exercised it. Capture actual physical
inventories instead of predicting them from source or equating an empty lane
with capability.

The instrument must verify its pinned binary identity, record exact schema,
actual part name, checksums/serialization metadata, decompressed stream bytes,
marks and primary index, then freshly ATTACH a copy and assert actual
`CHECK TABLE` result 1 for the exact part. Record both normalized whole-document
text and full/selected RowBinary from source and attached part. Comparator
controls must reject seeded CHECK=0 and mismatched row bytes. Physical artifacts
are observed snapshots, not independently derived literal vectors. Normalized
documents have separate literal expectations; these cannot certify nominal
DataType tags or physical layouts.

DoD command: `scripts/capture_json_w115.sh` under the existing serial resource
guard (600 seconds, 8 GiB, 50% free-memory floor), plus Crystal format, shell
syntax and diff checks. Expected signal: three captured physical profiles,
literal normalized document equality, fresh-ATTACH snapshot equality, exact
CHECK=1, and both negative comparator controls.
This is not the production-refusal RED gate and cannot turn JSON admission green.

Next discriminator: derive independent nominal-type/stream expectations from
the literal inputs and source format, freeze them in a separately named
qualifier, and establish the precise whole-document reader refusal only after
that stock qualification passes. Normalized document expectations are already
present, but source/attach equality alone can repeat the same producer mistake
and is insufficient for the later admission claim.

## Executed W115 evidence (2026-10-02)

Root executed the frozen capture instrument against the pinned runtime under
the serial guard. The source reference remains the separate depth-one checkout,
not the provenance of that executable. Reproduction command:

```sh
env SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  TMPDIR=/private/tmp COGNI_RUN_SAFE_MIN_FREE_PCT=50 \
  W115_KEEP_TMP=1 CRYSTAL_BIN=/opt/homebrew/bin/crystal \
  /bin/bash /Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh \
  /bin/bash 600 8192 \
  /Users/sergey/Projects/Crystal/crystal-click/scripts/capture_json_w115.sh
```

Observed exit 0; retained root
`/private/tmp/crystal-click-json-w115.6qs6Kq` contains the source and freshly
attached stores, literal `input.jsonl`, 48 query snapshots, and `capture.log`.
These temporary artifacts are evidence pointers, not repository fixtures;
rerun the command if they are unavailable. SHA-256:

- `capture.log`: `21579d6141707d902fd804a8aeb55e8a4c27151715b01d84aec7dacfaf555227`
- `input.jsonl`: `0093ada5170d3b7056a54f11b4601bd12c754ceaf7615bb34b08f2a721301a1b`
- `scripts/capture_json_w115.cr`: `76b11faf5f2f3d63aea088c91e387fff1aa584d61b2766103382feb447a992d8`
- `scripts/capture_json_w115.sh`: `bbb3ced94a5d28660d73a438635579807717de0e6681bd1efae6f5b383677896`
- `scripts/w115_json_semantic_vectors.cr`: `a045c100cf61330479c418765d1a30517a0d08500ef89d58e29416ad9d31e283`

All three profiles had one source part and one fresh-ATTACH part, each named
`all_1_1_0`, Wide, eight rows, and exact `all_1_1_0<TAB>1<TAB><LF>` CHECK output.
The primary-key marks were `{0,0,2},{0,16,2},{0,32,2},{0,48,2},{0,64,0}`;
selection `pk >= 3 AND pk < 7` crosses the String-to-Int64 transition at key 5.
All 12 source/attached full/selected normalized document checks passed.
Twenty-four snapshot pairs matched; 24 seeded changed-byte controls and six
seeded invalid CHECK-record controls were rejected by the same comparators.

Important observations, not newly admitted behavior:

- In `typed_mixed`, `a UInt64` normalizes null/missing keys 2 and 4 to zero;
  other dynamic null/missing paths disappear. Empty String/Array and false
  remain present. Dotted names reconstruct nested JSON; the NUL survives.
- Retained dynamic path `s` spills actual Int64 (key 5) and Bool (key 8) into
  SharedVariant with `max_dynamic_types=1`; path/type introspection confirms
  the spill. This is not merely a table containing different paths/types.
- Empty shared `arr` at key 2 is `Array(Nullable(String))`, whereas nonempty
  shared arrays are `Array(Nullable(Int64))`. Normalized JSON `[]` cannot
  distinguish those nominal types. The later physical qualifier must do so.
- Default whole-JSON RowBinary and explicit
  `output_format_binary_write_json_as_string=1` were captured separately.
  Cross-profile byte ordering is not claimed canonical.

Root executed `spec/w115_json_semantic_vectors_spec.cr` under the same guard
in DEBUG and RELEASE: eight examples each, zero failures/errors/pending.
The specs exercise wrong keys/cardinality/scalars, Bool-to-integer substitution,
missing empty values, and recursive type/presence comparison independently of
the stock snapshots. Two initial test-fixture mistakes (quoted diagnostic and
missing newline separators) were corrected before these passing runs; no
production implementation was changed. An injected wrapper process failure
with `W115_KEEP_TMP=0` returned 1 and retained its fresh temporary root/log.
The full production suite was not rerun for this instrument-only change.

Scoped adversary verdict: ROBUST for this executed capture/comparator checkpoint,
not for general JSON storage compatibility. Root inspected the instrument and
ran the positive/negative checks; a same-lineage Luna review found no document
normalization contradiction and is supplementary, not independent execution.
Effective JSON options, nominal path/type rosters, spill schedules and physical
layouts are recorded observations, not independently asserted expectations.
A future profile-normalization change could pass the document comparator;
the next qualifier must close that route before production admission.
Crystal format checks, `bash -n` and `git diff --check` passed. Reproduce through
the shell runner, which owns fresh-root creation: direct Crystal-script
invocation does not establish artifact-root freshness, and early shell root
validation failures can leave a temporary directory behind. Concurrent hostile
filesystem replacement is outside this checkpoint's guarantees.

## W116 independent physical/type qualification

The previous checkpoint changed authoritative state and produced discriminating
stock evidence, but left a false-pass route: the document comparator could
accept a changed effective JSON profile. W116 must close that route before any
whole-document production admission. This is a compatibility CAUTION step;
rollback is its isolated local commit, and all runtime probes remain inside
isolated temporary stores. Source queries target the retained W115 capture;
new artifacts and seeded mutation copies belong to a fresh W116 root.

Execution ownership and order:

1. `scripts/w116_json_physical_vectors.cr`: derive expected schema/options,
   nominal types, every payload stream and full/selected mark schedules from
   literal inputs and pinned source rules. Existing compression/hash helpers
   are transport dependencies, not a future production JSON oracle. Do not
   copy observed stream hex into expected vectors or require incidental
   unordered statistics-map order.
2. `scripts/check_json_w116.cr` and `.sh`: re-query actual part identities,
   schemas and exact CHECK=1 for source/fresh-ATTACH pairs; compare the physical
   artifacts through the independent helper. The shell runner requires an
   explicit isolated `W115_CAPTURE_ROOT`, not an ephemeral hardcoded default.
3. Only after positive stock qualification, exercise the existing public
   whole-document read API and require its precise current unsupported-type
   refusal. A transport error, missing fixture, arbitrary exception, or
   source-shape check is not the missing-capability RED signal.
4. Attack the same comparator with seeded wrong effective schema/type,
   same-size payload/discriminator changes and mark-axis corruption. Failures
   must identify the intended mismatch rather than an unrelated setup error.

DoD: run `scripts/check_json_w116.sh` with `W115_CAPTURE_ROOT` under the serial
600-second, 8-GiB, 50%-free guard; run focused comparator specs in DEBUG and
RELEASE plus Crystal formatting, shell syntax and diff checks. Expected signal:
all three physical profiles qualify against independently constructed
expectations, fresh CHECK=1 remains exact, all seeded violations are detected,
and the precise whole-document capability refusal is observed afterwards.
If an encoding remains uncertain, name it and keep qualification in progress;
do not weaken the expected profile or turn observations into a literal oracle.

This step does not reduce the goal to three declarations. It supplies the
stock-backed format falsifier for a reusable Object/Dynamic/shared-data engine.
General JSON reader/writer, other Object/shared versions, Compact layouts,
recursive compositions, MV/projections and the eventual speed target remain
required, not silently removed. The next production move must implement a
reusable owner and its failing behavioral test, not another registration branch.

## Executed W116 evidence (2026-10-02)

Root executed the final frozen qualifier under the serial guard against the
same pinned executable and retained W115 source/fresh-ATTACH pairs. W116
re-queries those independently attached stores; it does not claim another
ATTACH operation occurred in this command. Reproduction:

```sh
env SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  TMPDIR=/private/tmp COGNI_RUN_SAFE_MIN_FREE_PCT=50 \
  W115_CAPTURE_ROOT=/private/tmp/crystal-click-json-w115.6qs6Kq \
  W116_KEEP_TMP=1 CRYSTAL_BIN=/opt/homebrew/bin/crystal \
  /bin/bash /Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh \
  /bin/bash 600 8192 \
  /Users/sergey/Projects/Crystal/crystal-click/scripts/check_json_w116.sh
```

Observed exit 0; the final retained W116 root is
`/private/tmp/crystal-click-json-w116.GzWn7N`. Actual part identities and
canonical schemas were queried, not inferred from labels. Each of the three
profiles has eight rows in one source and one attached Wide part. All six
physical parts passed the independently derived schema, file inventory,
nominal type/lane model, decompressed stream, complete mark-grid and semantic
serialization-metadata checks. Stream inventories including `pk` contain
41, 5 and 12 streams for dynamic-path, shared-only and mixed profiles.
Unordered structure statistics are compared as decoded maps; their incidental
byte order is intentionally not pinned. Ordinary payload streams and all marks
are compared exactly. Actual CHECK=1 passed for all six exact parts; all 12
literal full/selected document checks passed, including keys 3 through 6.

Negative controls passed through the same comparators: 12 invalid CHECK
records, five in-memory raw changes, and 12 copied-part changes (three each
for payload, nominal discriminator/type, decompressed mark offset and schema).
Copied mutations preserve logical payload length and regenerate valid frame
and manifest checksums. Each failure must match the intended diagnostic;
an unrelated setup error cannot pass. Only after these positive and negative
checks did public `WidePart.open_typed(part, "payload")` produce the exact
`UnsupportedFormatError("unsupported exact typed column")`. This is the
qualified missing whole-document capability, not a new reader admission.

Root also executed `spec/w116_json_physical_vectors_spec.cr` in DEBUG and
RELEASE, with the Crystal executable as the resource guard's binary argument:

```sh
env SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  TMPDIR=/private/tmp \
  CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-json-w116-spec.Nv8DeH/cache-debug \
  COGNI_RUN_SAFE_MIN_FREE_PCT=50 \
  /bin/bash /Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh \
  /opt/homebrew/bin/crystal 600 8192 \
  spec --single-module --link-flags=-fuse-ld=ld \
  spec/w116_json_physical_vectors_spec.cr
```

For RELEASE add `--release` and use a separate cache. Each final run passed
13 examples, zero failures/errors/pending. Tests cover unordered Object and
Dynamic statistics, duplicate/trailing entries, selected nonzero-origin marks,
singleton String discriminator order, nominal empty-array types and canonical
VarUInt/truncation/overflow rejection. Before the VarUInt fix, root observed
the intended RED: 13 examples, exactly one failure because a nonminimal
encoding raised no mismatch. `IO/VarInt.h` in the source reference shows the
stock writer emits minimal encodings while its reader is more permissive.
This qualifier's canonical producer contract is not an assertion that every
server-accepted encoding is canonical.

Root's source review corrected independent-model mistakes before the passing
stock run: recursive Array/Nullable type tags, String byte lengths without an
added NUL, implicit SharedVariant statistics, and lexicographic global Variant
tags. In particular, `SharedVariant` sorts before a singleton `String`.
Structure data marks follow their prefix, but the terminal mark follows the
suffix (`MergeTreeDataPartWriterWide.cpp:859`); a mark-mutator setup assumption
that the initial decompressed offset was zero was also corrected. The initial
stock failures were instrument/model failures, not production regressions or
missing-capability RED signals. Captured stream hex was not substituted for
the independently modeled expectations.

Final SHA-256 evidence pointers (temporary logs must be reproduced if lost):

- `scripts/w116_json_physical_vectors.cr`: `880c4ae3251e288ae38835469ae3361b272f21c26dfe17c6edc0704e77033b2a`
- `scripts/check_json_w116.cr`: `2d2e7f1018d1903bef62cb21a18b207f8ed2c358c31e3d9bab668c4dc4c0669e`
- `scripts/check_json_w116.sh`: `4bf2ea7946dae219580c3fa32b214187b83383fb49bc36264ceebc662bc76ee8`
- `spec/w116_json_physical_vectors_spec.cr`: `13a0fd49cfa291511900015e49de5a166b412825a0f3379233a8624d5203c601`
- Final W116 `check.log`: `6d5a1f2a43d29ce1c4fd874c4382141610a28c745cb82945053232730b3d4804`
- Spec-root `debug-final.log`: `9d736cfb66cf13b79d1cbade790944b2a2d694941b5aa751038b62d758cef5f8`
- Spec-root `release-final.log`: `7333d9bab3973084eeea1a2d76d88ca7e4eeb7de1c5bc7ef9ed5a251e0359bb1`
- Spec-root `debug-varuint-red.log`: `f0c93495878ad31b32a765753bd05e9031ab255a186ef803f9209b10ae91dd32`

Scoped root adversary verdict: ROBUST for these executed fixed-profile
qualification/refusal checks, not for general JSON compatibility. Luna's
candidate implementation and same-lineage read-only review were supplemented
by root source inspection and actual positive/negative execution. The review
bounded two further exclusions: `serialization.json` equality is semantic JSON,
not canonical text or duplicate-key rejection, and helper reads do not provide
hostile child-file symlink containment. The capture stores are trusted,
quiescent isolated artifacts, not an untrusted-input security boundary.
The attached-role inventory requires `invalidated_system_columns.txt`, but its
contents and all other non-stream sidecar contents are not independent literal
compatibility assertions. No production source changed; the full production
suite was not rerun. Crystal format, shell syntax and diff checks passed.
The producer/build, settings, encoding/layout, comparator or relevant code
changes invalidate this certificate; re-run the stated commands before reuse.

## Implementation direction after qualification

### W117 paired scalar kernel: seal and executed result

Risk: CAUTION (new binary-format API). Rollback is one isolated local feature
commit; no existing part admission, dependencies, filesystem publication,
stored data, or performance behavior may change. This kernel is a prerequisite,
not closure of the general JSON/MergeTree requirement.

Admitted paired surface: Nothing descriptors; all signed/unsigned integer
widths through 256 bits; Float32/64, BFloat16, Bool, String, FixedString; recursive
Array, Nullable, named/unnamed Tuple and Map. A typed envelope contains the type
descriptor and one scalar value; a known-type scalar API omits the descriptor.
Nothing is the Dynamic NULL envelope, not an ordinary non-null scalar. Distinct
empty array types, field names, map pair order/duplicates, fixed-width raw bytes
and floating-point raw bits remain nominally distinct. String lengths count
bytes, including embedded NULs. Nullable scalar serialization carries a flag
and, only when non-null, its nested value; it is not the bulk null-map layout.

Source at `935de744`: `DataTypesBinaryEncoding.{h,cpp}` defines descriptors;
`SerializationNumber.cpp:299`, `SerializationArray.cpp:57`,
`SerializationNullable.cpp:184`, `SerializationTuple.cpp:56` and
`SerializationMap.cpp:70` define the separate scalar grammar. This snapshot
allows Nullable(Tuple), and Map keys are rejected only for Nullable or
LowCardinality(Nullable) (`DataTypeTuple.h:38`, `DataTypeMap.cpp:149`). Older
scalar-only Map-key assumptions must not become guards. Named Tuple fields
must be nonempty and unique and cannot be exactly `null`
(`DataTypeTuple.cpp:checkTupleNames`). Tags 0x33/0x35 are reserved former
Time/Time64 timezone encodings, not reusable additions: schema evolution is
not proof that every wire format is unchanged.

Ownership: `binary_data_type.cr` owns immutable nominal descriptors;
`binary_value.cr` owns detached values; `binary_codec_limits.cr` and
`binary_codec_context.cr` own aggregate logical limits and bounded wire access;
`binary_data_type_codec.cr` owns descriptor serialization;
`binary_value_codec.cr` owns scalar/envelope serialization. One concrete owner
per file, no special class per type combination. `src/crystal_click.cr` imports
these owners; no existing facade dispatch is widened. Before the change,
`rg 'Binary(DataType|Value|Codec)' src spec scripts` found no existing consumer.

Limits: maximum recursion depth, combined descriptor/value node visits,
descriptor-child/container-element charges, and total input/output wire bytes.
Check announced counts and byte lengths before allocation, and output sizes
before growth. Defaults are depth 64, 4,096 combined node visits, 1,000,000
child/container edge charges and 64 MiB of input/output wire bytes. These are
logical bounds, not an RSS guarantee. The recursive implementation does not
promise native-stack safety if a caller raises these limits. Both scalar and
descriptor decoding require exact consumption. VarUInt decoding deliberately
admits only minimal, non-overflowing encodings; this is a stricter profile than
ClickHouse's permissive stored-data reader. Structural Nullable flags are 0/1;
Bool values follow the existing nonzero-is-true policy and encode canonically.
Malformed supported encodings are corruption; unadmitted tags/types are
unsupported, never silently interpreted as another type.

Recognized but unadmitted tags are refused at the tag; their parameter/body
grammar is not validated by this checkpoint. Unknown and reserved tags are
corruption. Nullable(Nothing) admits only its NULL flag: a non-NULL flag is a
contradictory value and corruption here, not a claim of upstream exception-class
parity. A non-NULL Nullable child charges one container edge; a NULL charges
none. Child depth is preflighted before declared child-array allocation.

Rejected at this checkpoint: temporal/decimal/Enum/custom/aggregate descriptor
parameters, LowCardinality, general Variant/Dynamic/JSON scalar dispatch, Object
dictionaries, Dynamic lane schedules, shared layout orchestration and general
part/document reading/writing. They remain required later capabilities, not
removed goals. Nothing inside an empty container can be described but has no
non-null scalar payload. Unknown tags, malformed schemas and exhausted limits
must fail before callbacks or publication (neither exists in this kernel).

Execution order and DoD:

1. Write `spec/binary_value_codec_w117_spec.cr`; execute its missing-API RED
   before production changes.
2. Implement the paired generic owners. Run the focused spec in DEBUG and
   RELEASE and the production regression suite with bounded compiler guards.
3. `scripts/check_binary_w117.sh` qualifies hand-authored descriptor/scalar
   literals against the pinned stock runtime, then sends library-produced bytes
   to the independent stock reader. `RowBinaryWithNamesAndTypes` uses
   `output_format_binary_encode_types_in_binary_format=1` and reverse
   `input_format_binary_decode_types_in_binary_format=1`; this is scalar codec
   evidence, not a MergeTree part/ATTACH certificate.
4. Attack truncation at every point, trailing bytes, tenth-byte VarUInt overflow,
   nonminimal lengths, inconsistent nominal children, detached ownership,
   exact/minus-one budgets, signed zero/NaN bits, typed empty arrays, named Tuple
   metadata and composite Map keys. Seed a byte defect to qualify the independent
   comparator. Recheck whole-JSON refusal; it must remain closed.

Root executed the test-first checkpoint on 2026-10-02 with Crystal 1.21.0:
`crystal spec --single-module --link-flags=-fuse-ld=ld
spec/binary_value_codec_w117_spec.cr` under the serial resource guard. It exited
1 at the spec's first `CrystalClick::BinaryDataType` annotation with
`undefined constant CrystalClick::BinaryDataType`; the missing-API RED is
qualified. The guarded log is
`/private/tmp/crystal-click-binary-w117.GKKkIV/red.log` (reproduce if lost).
This does not establish that later test branches are correct: root separately
corrected test-instrument integer narrowing and alternating Map-accessor
assumptions before the implementation gate.

Root executed the final gates against the six frozen production owners:

- Focused DEBUG and RELEASE each passed 14 examples with zero failures/errors/
  pending. The full DEBUG suite passed 1,921 examples with the same result.
  Full RELEASE was not run. Logs are under
  `/private/tmp/crystal-click-binary-w117.GKKkIV`: `debug-final.log`,
  `release-final.log` and `full-debug-final.log`.
- The independent stock oracle passed 37 hand-authored local type/value vectors,
  36 stock-writer comparisons and 36 stock-reader/re-emission comparisons of
  library-produced bytes. Nothing's NULL envelope is local-only in this oracle.
  Its retained root is `/private/tmp/crystal-click-binary-w117.kCl1vR`.
  Runtime identity is the separately pinned 26.10.1.1201 build above, not an
  executable compiled from `935de744`. These are authored scalar vectors, not
  every possible value, nested combination, type parameter or physical part.
- The unchanged W116 gate passed against six retained source/attached parts:
  six actual CHECK=1 results, twelve CHECK negative controls, twelve independent
  full/selected document checks and the existing raw/type/mark/schema controls.
  It also confirmed exact typed whole-JSON refusal. Its new check root is
  `/private/tmp/crystal-click-json-w116.aDRAiG`; it reuses the W115 capture,
  not new W117-generated or newly attached parts.
- Crystal format, shell syntax and `git diff --check` passed. Root independently
  inspected the owners, exact scope and adversarial results. The bounded hostile
  verdict is ROBUST for this default-bounded scalar kernel; it does not certify
  general JSON, allocator/RSS bounds, raised-limit stack safety or performance.

Two targeted regressions distinguish the guards from a self-round-trip. The
Nothing-container factory test failed before the overly broad factory guard
was narrowed; ordinary nonempty Nothing payloads still fail scalar admission.
The depth-before-allocation test announced one million Tuple children with a
depth limit of one. Temporarily removing only that preflight guard produced
8,000,832 allocated bytes and failed the 2,097,152-byte ceiling. Restoring the
guard passed both final focused modes. This is a pinned Crystal 1.21.0/Boehm
allocation discriminator, not a throughput or RSS benchmark. The actual seeded
RED is `depth-seeded-red-qualified.log`; an earlier selector ran zero examples
and is not evidence. The temporary defect is absent from the production owners.

The first reverse oracle failure was instrument-only: ClickHouse's default
`print_pretty_type_names=1` made named Tuple type names multiline in TSVRaw.
The instrument explicitly sets it to zero to retain one-line canonical names;
it does not strip or normalize payload bytes. Raw oracle output is retained.
The one-byte mutation control still fails the exact row comparator.

Reproduction commands, from the repository root, use the same serial resource
guard and toolchain (one command at a time; recreate the cache root if lost):

```sh
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
export TMPDIR=/private/tmp
export COGNI_RUN_SAFE_MIN_FREE_PCT=50

env CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-binary-w117.GKKkIV/cache-debug \
  /bin/bash /Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh \
  /opt/homebrew/bin/crystal 600 8192 spec --single-module --link-flags=-fuse-ld=ld \
  spec/binary_value_codec_w117_spec.cr
env CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-binary-w117.GKKkIV/cache-release \
  /bin/bash /Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh \
  /opt/homebrew/bin/crystal 600 8192 spec --release --single-module --link-flags=-fuse-ld=ld \
  spec/binary_value_codec_w117_spec.cr
env CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-binary-w117.GKKkIV/cache-full \
  /bin/bash /Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh \
  /opt/homebrew/bin/crystal 600 32768 spec --single-module --link-flags=-fuse-ld=ld
env CRYSTAL_BIN=/opt/homebrew/bin/crystal W117_KEEP_TMP=1 \
  /bin/bash /Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh \
  /bin/bash 600 8192 scripts/check_binary_w117.sh
env CRYSTAL_BIN=/opt/homebrew/bin/crystal \
  W115_CAPTURE_ROOT=/private/tmp/crystal-click-json-w115.6qs6Kq W116_KEEP_TMP=1 \
  /bin/bash /Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh \
  /bin/bash 600 8192 scripts/check_json_w116.sh
```

Pre-mortem: a self-round-trip can agree with the same wrong grammar, or erase
nominal distinctions. Independent literal bytes plus stock producer/consumer
checks and adversarial raw-bit/type identity tests are the guard. Source/runtime
identities, settings, comparator or owner changes invalidate the certificate;
rerun the stated gates before reusing it. This result is over `2bb91f9` plus the
W117 feature's six owners, entry imports, spec and oracle, not a promotion of
older facade admissions to arbitrary composition.

### W118 MAP shared-data block: design seal

Risk: CAUTION (paired physical codec and aggregate budget reuse). Over the
W117 production state at `b906394` plus source-reference commit `1d07d28`,
add the next necessary Object boundary: a reusable
three-stream MAP block codec, not another exact JSON declaration or a raw
WidePart bypass. Rollback is one isolated feature commit. Whole-JSON reader,
part admission, staging/publication and existing filesystem policies remain
unchanged. Performance is not the target of this change.

Admit only caller-bounded, fully decompressed MAP streams: `sizes` is exactly
one LE UInt64 local pair count per outer row; `paths` and `values` are separate
concatenations of canonical VarUInt byte length plus bytes. Each value body is
one W117 binary type/scalar envelope with exact consumption. This count lane is
the captured Wide profile's position-independent encoding. With that setting
false the upstream bulk writer emits absolute offsets; stream enumeration's
sizes-column view is not proof of emitted count bytes
(`SerializationArray.cpp:156-175,255-279,329-367`). MAP is shared version 0,
delegated to Array(Tuple(paths String, values String)); bucketed, advanced and
chunked orchestration are not admitted by this codec.

API: `ObjectSharedMapCodec.decode(sizes, paths, values, row_count, limits)`
returns owned `Array(ObjectSharedMapRow)`; `encode(rows, limits)` returns
`ObjectSharedMapStreams` with detached sizes/paths/values snapshots. The rows
own ordered `ObjectSharedMapEntry` values and detached path bytes. Keep each
concrete owner in its own file: `object_shared_map_entry.cr`,
`object_shared_map_row.cr`, `object_shared_map_streams.cr`,
`object_shared_map_codec.cr`. No class per nested type combination.

Paths must be strictly sorted and unique per row using raw-byte comparison;
do not split, unescape or normalize dotted/NUL/invalid-UTF8 path bytes.
Normal Object insertion omits missing/NULL dynamic paths
(`ColumnObject.cpp:976-989`), but the physical shared-data codec must preserve
a root Nothing NULL envelope. Upstream explicitly handles such entries in
display, hashing and duplicate repair (`ColumnObject.cpp:397,1314-1323,2613`).
The initial proposed rejection was refuted by that source counterexample:
canonical document insertion policy is not the raw MAP wire grammar. Preserve
both Nothing NULL and independently typed Nullable values without silently
omitting them; future document orchestration owns that semantic policy.
A selected nonzero-origin range
uses exact caller-provided local slices and row counts; global origin, physical
marks, frame lifetimes and Object structure/statistics are not codec inputs.

Introduce one reusable `BinaryCodecBudget` owner for shared logical counters.
W117's ordinary entry points keep fresh independent budgets and their existing
contract; narrowly documented internal borrowed-envelope entry points allow
W118 to share recursive node/element charges. For this block, nodes include
outer rows, entries and every descriptor/scalar visit. Elements include outer
row edges, entry edges and W117 descriptor/container edges. Depth applies to
each envelope's recursive type/value tree. Decode charges the sum of all three
wire lanes once before copying or materializing; borrowed envelope slices are
not charged twice. Encode charges the combined final lanes before growth;
temporary envelope output must be bounded by the remaining wire allowance.
These remain logical bounds, not allocator/RSS or raised-limit stack guarantees.
The borrowed methods and context charging switches are convention-internal but
language-public Crystal plumbing, not a capability-enforced boundary. Their
preconditions require the enclosing owner to charge complete input lanes and
final framed output. The admitted ordinary codec APIs expose neither switch;
direct misuse of the plumbing is outside this certificate.

Before row/entry-array allocation, validate row_count and exact sizes-lane
length, scan checked per-row counts/sum, and prove the known minimum aggregate
node/element budget (at least rows + three nodes per entry, and row/entry
edges). Also prove the minimum lane cardinality: each path needs at least its
length byte and each value needs at least its outer length and descriptor byte.
This prevents tiny lanes with huge declared counts from allocating entry arrays
even when callers raise logical node/element limits. Reject overflow, counts outside the in-memory domain and
exhausted limits before declared-count allocation. Decode all entries and
validate ordering plus exact exhaustion of all three lanes before returning;
there are no partial callbacks. Corrupt input/budgets raise corruption;
unadmitted W117 envelope types remain Unsupported; invalid model construction
is ArgumentError and encode budget failures are Unsupported.

Consumer inventory: `rg 'BinaryCodecContext|BinaryValueCodec|ObjectSharedMap'
src spec scripts` finds the W117 owners/spec/oracle and no existing MAP block
consumer. Current JSON virtual-path admission retains only its selected typed
streams. Existing JSON writer methods hardcode empty shared streams/statistics.
Do not wire nonempty MAP bytes into those facades without later structure,
dictionary, mark/rank and publication owners.

Execution and DoD:

1. Write `spec/object_shared_map_w118_spec.cr` only; root executes a genuine
   missing-API RED before authorizing production edits.
2. Implement the paired owners and narrow shared-budget seam. Focused W118
   plus unchanged W117 specs must pass DEBUG/RELEASE; full DEBUG must pass.
3. `scripts/check_object_shared_map_w118.sh` must independently compare real
   retained W115/W116 stock streams to source-derived literals, decode them to
   authored nominal rows and encode those rows back to exact physical bytes.
   Check full and nonzero-origin selections, including empty rows/lanes,
   nominal empty arrays and embedded NUL strings. This is raw codec evidence,
   not production whole-JSON part-writer admission.
4. If practical, a test-only copied-part patch uses library-produced MAP streams
   in a fresh isolated store with regenerated framing/checksums, changes an
   existing Bool value without changing path/type statistics, then requires
   actual stock ATTACH/CHECK=1 and independent full/selected document results.
   Never mutate the retained capture; never call the copied metadata a new
   production whole-part writer.
5. Attack each lane's truncation/trailing/count mismatch, unsorted/duplicate
   paths, Nothing/typed NULL preservation, unsupported envelope types, raw path/value ownership,
   aggregate exact/minus-one nodes/elements/bytes across multiple envelopes,
   and huge count/row pre-allocation. Qualify the comparator with a byte defect.
   Re-run the unchanged W117 oracle and W116 whole-JSON refusal gate.

Pre-mortem: resetting the budget per envelope admits an unbounded block despite
small per-value limits; counting nested envelope bytes twice rejects valid
exact-boundary blocks. Independently constructed aggregate thresholds and
stock raw-byte comparisons are the discriminators. Source/runtime identities,
MAP/count encoding, stream framing, comparator or codec changes invalidate
later evidence. This seal proposes implementation, not completed capability.

### Executed W118 certificate (2026-10-02)

Status: VERIFIED for the caller-bounded, decompressed, position-independent
MAP/count profile sealed above. Subject: `1d07d28` plus the five new W118
owners, W117 context/value seams, entry imports, spec and two oracle files in
this feature commit. The existing WidePart, writer, table and catalog facade
admissions were not changed. Luna implemented the candidate and oracle; root
inspected the source/diff, corrected fixture/Crystal issues, and executed all
gates independently. The same-lineage review is correlated, not an independent
replication. Root's scoped adversarial verdict is ROBUST.

Observed evidence:

- Before production edits, the new spec produced genuine missing-API RED:
  undefined `CrystalClick::ObjectSharedMapCodec`, exit 1.
- Final focused W118 plus unchanged W117 DEBUG and RELEASE each passed
  24 examples with zero failures/errors/pending. Full DEBUG passed 1,931
  examples with zero failures/errors/pending. Existing non-fatal duplicate
  library/deprecated test-hook warnings remain. No full RELEASE was run.
- Temporarily resetting the borrowed envelope's recursive budget produced a
  qualified RED at the nested aggregate threshold: expected corruption was
  not raised with 15 nodes instead of the exact 16. Outer lower-bound
  preflight still passed, so the test distinguishes shared accounting from
  per-envelope resets. The first failed assertion ended that example; the
  seeded run does not independently certify its later edge assertion.
  Restoring the shared owner passed both exact/minus-one node and edge checks
  against the exact 16-node/12-edge aggregate.
- Temporarily removing the two minimum wire-cardinality guards produced a
  qualified RED: a tiny input declaring one million entries allocated
  8,004,112 bytes against the test's 2,097,152-byte ceiling. Node/element
  limits were deliberately raised to admit the outer lower bound. Both
  guards were restored before the final DEBUG/RELEASE/full gates. This is
  one allocation-path test, not a general RSS certificate.
- The first stock run correctly rejected an authored nominal expectation for
  `typed_mixed` pk=2: empty `arr` was written in the oracle model as
  `Array(Nullable(Int64))`, but its independent W116 literal descriptor and
  retained W115 path-type observation require `Array(Nullable(String))`.
  W116's `shared_typed_rows` explicitly uses tag `0x15` for that row. Original
  input is `arr: []`; source incomplete-type inference explains the String
  fallback, while the effective nullable identity is also measured. Only
  this authored expectation changed; production and the nominal comparator
  did not. The real oracle reproduction then passed.
- Final W118 stock qualification passed three profiles, six retained source
  and previously attached parts, twelve full/selected local windows and
  eighteen independent literal lanes. Decode matched independently authored
  nominal rows; encode of those authored rows and decoded re-emission matched
  the stock bytes. Selected pk 3..6 uses caller-local stream slices, not a new
  production granule reader. Empty rows/lanes, typed empty arrays and embedded
  NUL strings were included. A hand-literal root Nothing NULL envelope passed.
- The oracle rejected a seeded writer values-lane byte and a child symlink.
  The child guard executes before the W116 metadata helper and raw-stream
  reads. Its filesystem precondition is a quiescent trusted capture; path
  checks are not protection against concurrent renames/symlink swaps.
- The unchanged W117 stock oracle again passed 36 stock-writer vectors and
  36 stock-reader/re-emission vectors, plus its literal, raw-bit, NULL,
  corruption, snapshot and negative-comparator controls.
- The unchanged W116 qualifier again asserted six actual CHECK=1 results,
  twelve independent full/selected document checks and all its comparator
  controls. The existing exact whole-JSON refusal remains qualified RED.
  W118 itself executed no new ATTACH/CHECK. The optional test-only copied-part
  Bool patch from the seal was not run; no production whole-part JSON writer
  is claimed from raw lane equality.
- Crystal formatting, shell syntax and `git diff --check` passed. Root also
  reviewed exact exhaustion, strict raw-byte path order, ownership, aggregate
  wire charging and the convention-internal borrowed API preconditions.

Retained evidence index (not proof by presence):
`/private/tmp/crystal-click-map-w118.jsLcFw/{red,debug-final,release-final,full-debug-final,reset-seeded-red,cardinality-seeded-red,stock-w118,stock-w118-final,regression-w117,regression-w116}.log`.
Final W118 artifacts: `/private/tmp/crystal-click-object-shared-map-w118.wBvhko`;
failed nominal fixture reproduction: `crystal-click-object-shared-map-w118.vJ04yi`;
W117 regression: `crystal-click-binary-w117.B0L5yf`; W116 regression:
`crystal-click-json-w116.aKRtTr`, all under `/private/tmp`. The retained capture
remains `/private/tmp/crystal-click-json-w115.6qs6Kq` and was not mutated.

Reproduce with Crystal 1.21.0 / LLVM 22.1.8 on arm64 macOS, the pinned stock
runtime identified above, and an isolated cache. Root used the existing serial
`run_safe.sh` guard with 600 seconds / 8 GiB for focused and stock phases,
600 seconds / 32 GiB for full DEBUG, and the 50% free-memory floor. These are
correctness gates, not quiet-host performance measurements.

```sh
crystal spec --single-module --link-flags=-fuse-ld=ld \
  spec/object_shared_map_w118_spec.cr spec/binary_value_codec_w117_spec.cr
crystal spec --release --single-module --link-flags=-fuse-ld=ld \
  spec/object_shared_map_w118_spec.cr spec/binary_value_codec_w117_spec.cr
crystal spec --single-module --link-flags=-fuse-ld=ld
W115_CAPTURE_ROOT=/private/tmp/crystal-click-json-w115.6qs6Kq \
  W118_KEEP_TMP=1 bash scripts/check_object_shared_map_w118.sh
W117_KEEP_TMP=1 bash scripts/check_binary_w117.sh
W115_CAPTURE_ROOT=/private/tmp/crystal-click-json-w115.6qs6Kq \
  W116_KEEP_TMP=1 bash scripts/check_json_w116.sh
```

The default bounded scalar/block model survives the applicable attacks. It
does not certify arbitrary binary DataTypes, Object metadata/dictionaries,
Dynamic lane schedules, absolute-offset MAP mode, bucketed/advanced/chunked
layouts, physical marks/I/O, whole-document JSON integration, general Variant,
part publication, concurrent filesystem safety, caller-raised stack limits,
RSS or throughput. Source/runtime/settings, frame interpretation, comparator,
budget plumbing or owner changes invalidate dependent evidence; rerun these
gates before reusing it. Next frontier: expand the reusable scalar repertoire
and add separately qualified Object/Dynamic structure and lane schedule owners
before exposing whole-document reading or staged writing.

### W119 fixed-width scalar repertoire seal (2026-10-02)

Status: VERIFIED within the bounded descriptor/single-value profile and
executed certificate below; whole-column and whole-part admission is unchanged.
This extends W117's descriptor/single-value grammar and W118's typed MAP
envelopes toward the remaining Object/Dynamic values. It does not admit a new
WidePart dispatch, bulk serializer, whole-document JSON reader or part writer.
Risk is CAUTION (serialization/API); rollback is the exact atomic feature
commit on the clean `a5e34ab` baseline. Root owns process execution, docs and
Git; Luna supplies implementation and independently authored oracle candidates.

Source is the separate `0c68f01a75a913b1aa5e132b41a80642260c3009` checkout,
not the pinned executable's build provenance. Relevant source owners:
`DataTypesBinaryEncoding.{h,cpp}` (tags/parameters),
`DataTypeDecimalBase.h` (width-specific constructor), `EnumValues.cpp`
(nonempty bijection sorted by signed numeric code), `SerializationEnum.h`
(inherits raw numeric binary grammar), `SerializationDecimalBase.cpp`,
`SerializationUUID.cpp`, and `SerializationIPv4andIPv6.cpp` (scalar payloads).

Admit paired descriptors and raw scalar payloads for Date, Date32, implicit
and explicit-zone DateTime/DateTime64, Time/Time64, all four Decimal widths,
UUID, IPv4/IPv6, Enum8/16. Reuse the recursive Array/Nullable/Tuple/Map model;
there is no special class per combination. Keep the fixed payload in its exact
ClickHouse wire order, not a generic host-integer interpretation: UUID halves
and IPv6 bytes are especially not licensed by a width match.

Design laws:

- Preserve implicit-versus-explicit DateTime tags, including explicit UTC.
  A timezone-bearing descriptor with an empty zone normalizes to the implicit
  type, as the upstream constructor does; canonical re-emission changes its tag.
  DateTime64 and Time64 scales are 0..9. Time/Time64 have no timezone tags;
  0x33/0x35 remain reserved corruption.
- Temporal parameters have an immutable owner. Explicit zones use the existing
  `TimezoneName` profile (597 pinned names plus 114 canonical fixed offsets).
  Unknown catalog names are deliberately unsupported, not silently implicit
  UTC. This is not fresh-server timezone-catalog or alias completeness;
  refreshing/extending that profile remains required compatibility work.
- Decimal parameters have a separate immutable owner retaining width, precision
  and scale. Each width admits precision 1..its maximum and scale 0..its
  maximum (9/18/38/76). Source binary construction does not require scale <=
  precision or the narrowest width for that precision. Do not reuse the SQL
  `DecimalType` owner, which deliberately derives width and checks scale <= P.
  Equality/hash include wire tag and all parameters, even when `name` matches.
- Enum definitions own detached opaque label bytes and signed codes. Reject
  empty tables, duplicate labels/codes and out-of-width codes; empty labels
  are not empty tables. Canonical writer order is increasing signed code;
  reader accepts a valid unsorted table and normalizes it like the source.
  Raw scalar codes are not checked for membership: the upstream binary
  numeric serializer does not impose its text lookup rule here.
- Count enum entries against aggregate nodes and element charges, including
  known-type scalar APIs and borrowed MAP envelopes. Entry metadata nodes do
  not deepen the recursive type tree. Before any count-derived allocation,
  enforce the signed-code cardinality, logical budget and minimum remaining
  wire bound (one length byte plus code width per entry); a zero-byte label
  is permitted. Full byte/depth/exhaustion checks remain unchanged.
- Bad supported descriptor parameters are corruption, unknown/reserved tags
  are corruption, recognized unadmitted types remain unsupported. Model
  construction errors are ArgumentError. Do not call a valid-but-unadmitted
  timezone corrupt merely because it lies outside the pinned local catalog.

Ownership and propagation: `BinaryDataType` owns nominal composition;
new temporal, decimal and enum parameter owners each occupy one file;
a scalar-descriptor codec owner keeps leaf parameter grammar out of recursive
orchestration. `BinaryValue.fixed` and the scalar codec admit these fixed
leaves without importing SQL/text validation. `BinaryCodecContext` exposes
only the bounded remaining-input/preflight seam needed by enum decoding and
known-type metadata accounting. Before widening, root's bounded
`rg -l 'BinaryDataType|BinaryValueCodec' src spec scripts --glob '*.cr'`
enumerated ten consumers: the six existing model/context/codec/block source
owners, W117/W118 specs and their two oracle instruments. Their paired and
aggregate gates must remain green; no table/catalog facade consumer was found.

Plan and DoD (serial existing resource guard, isolated cache):

1. Add `spec/binary_scalar_types_w119_spec.cr` and execute missing-API RED
   before production edits. Include authored descriptor/payload literals,
   nominal tag/P/S/zone identity, ownership and every-prefix/trailing controls.
2. Implement the separate parameter/leaf owners and exact generic seams.
   Run W119 plus W117/W118 specs in DEBUG and RELEASE, then full DEBUG.
   Migrate only predecessor refusal controls whose scalar tags W119 now
   deliberately admits; retain distinct unsupported and corruption assertions.
   Expected signal is zero failures/errors/pending, not a throughput claim.
3. Add `scripts/check_binary_w119.{cr,sh}`. Qualify pinned-runtime stock output
   against authored literals, then make stock read library-produced bytes and
   re-emit them. Include every new family, explicit/implicit zones, scale
   boundaries, signed enum ordering and UUID/IP order. Unusual width-specific
   Decimal descriptors must have direct binary-reader evidence or be clearly
   local/source-only; do not replace an inaccessible stock case by self-roundtrip.
4. Preserve W117/W118 stock regressions. Qualify new metadata/allocation guards
   with a targeted seeded defect when practical; require a one-byte oracle
   comparator negative control. Root independently inspects candidates and
   executes gates before a scoped hostile verdict and the feature commit.

Strongest likely failure: canonical SQL names collapse a distinct binary tag or
parameter identity, or enum metadata bypasses the borrowed aggregate budget.
Falsifiers include same-name/different-width Decimal descriptors, S>P binary
parameters, explicit UTC versus implicit DateTime, unsorted/duplicate/empty
Enum tables, undeclared raw Enum codes, a raised-budget huge count with tiny
input, nested enum metadata at exact/minus-one thresholds, truncated timezone
and scale data, reserved tags, and seeded stock/comparator mismatches.
Rejected residual: LowCardinality and custom/aggregate descriptors, general
Variant/Dynamic/JSON dispatch, Object dictionaries and stream schedules, physical
marks, whole-document and whole-part integration, catalog completeness,
native-stack/RSS/performance guarantees. These remain part of the original goal.

Oracle route falsifier: root's pinned-runtime two-argument
`format('RowBinaryWithNamesAndTypes', data)` probe used the literal one-row
header/body `0101781b090201000000000000000000000000000000`. Instead of
retaining Decimal128(P=9,S=2), stock inferred `Decimal(9, 2)` and emitted four
Decimal32 rows. In fresh source, `BinaryRowInputFormat.cpp:112` converts the
decoded descriptor to `getName()`; `RowInputFormatWithNamesAndTypes.cpp:483`
reconstructs it through the SQL factory. This route loses width before value
reading and cannot qualify noncanonical binary Decimal identities. The actual
probe is retained in `/private/tmp/crystal-click-scalar-w119.vlGxM0/decimal-infer-probe.log`.
Use explicit schemas for canonical stock families. Descriptor canonicalization
and unusual width/P/S profiles remain local/source-only unless a distinct
direct descriptor-consuming runtime route is actually qualified.

### Executed W119 certificate (2026-10-02)

Subject: clean `a5e34ab` plus the four parameter/leaf owners and exact generic,
test and instrument seams described above. Root inspected the delegated
candidates and executed all commands; same-lineage source review is
supplementary, not independent runtime replication. The ordered sixteen-path
non-document source manifest, hashed with `shasum -a256 <paths> | shasum -a256`,
is `89c2fa65aa514b485e8473832f4c84f784aaedf11c5a57b90d60806b41d873ae`:
`src/crystal_click.cr`, `binary_temporal_type`, `binary_decimal_type`,
`binary_enum_definition`, `binary_scalar_type_codec`, `binary_data_type`,
`binary_data_type_codec`, `binary_codec_context`, `binary_value` (the eight
short names are `.cr` files in `src/crystal_click/`),
`spec/binary_parameter_owners_w119_spec.cr`,
`spec/binary_scalar_types_w119_spec.cr`,
`spec/binary_value_codec_w117_spec.cr`, `spec/object_shared_map_w118_spec.cr`,
`scripts/check_binary_w117.cr`, `scripts/check_binary_w119.cr` and
`scripts/check_binary_w119.sh`.

Observed gates and qualified attacks:

- Baseline W117/W118 DEBUG passed 24 examples. Spec-only W119 RED failed
  precisely on missing `BinaryDataType.datetime`, before production changes.
  A temporal return-type compile error and a test-only read-only String-slice
  mutation were repaired; the isolated three-owner spec then passed 3 examples.
  Only two predecessor refusals were migrated: newly admitted DateTime and
  Time64 tags. Recognized unsupported LowCardinality and truncated descriptor
  corruption remain separately asserted; positive predecessor vectors stay intact.
- Final focused W119/W117/W118 DEBUG and RELEASE each passed 36 examples.
  Final full DEBUG passed 1,943 examples, zero failures/errors/pending, exit 0.
  Existing duplicate-library and deprecated `blocking` warnings are non-fatal.
  Full RELEASE was not executed.
- Final W119 oracle passed 23 independently authored local type/value vectors,
  three local canonicalizations, twelve corruption controls and both one-byte
  comparator controls (descriptor parameter and UUID payload, each offset 4).
  Stock output matched literals for 22 vectors; stock separately read
  library-produced bytes with explicit schemas and re-emitted those 22 vectors.
  Quoted UTC/Enum schemas and escaped query names have renderer controls.
  The first stock reader run exposed an unescaped SQL type literal; only the
  W119 renderer was repaired, then the complete oracle passed twice.
- Empty-zone and unsorted-Enum normalization, undeclared raw Enum codes and
  Decimal256(P=1,S=9) remain local/source-only. Stock timezone evidence covers
  UTC and America/New_York, not the complete catalog. The independently
  observed Decimal inference falsifier above remains an explicit limitation.
- Three separately seeded preallocation defects were caught by the same
  allocation test, each with an otherwise discriminating input: removing
  code-domain preflight allocated 16,001,680 bytes; removing minimum-wire
  preflight allocated 1,049,424; removing aggregate-budget preflight allocated
  800,896. Each exceeded the 131,072-byte assertion and exited 1. All guards
  were restored before the final passing DEBUG/RELEASE/full gates. This proves
  those tested allocation barriers, not a general RSS or performance bound.
- Unchanged stock regressions passed: W117 36 writer and 36 reader vectors;
  W118 three profiles, six retained parts, twelve full/selected windows and
  eighteen independent lanes; W116 six actual CHECK=1 results, twelve negative
  CHECK controls and twelve semantic windows, with copied-part mutations.
  Those CHECKs concern retained stock source/attached parts, not W119-authored
  parts. W116 still qualifies the exact whole-JSON refusal.

Reproduction uses Crystal 1.21.0/LLVM 22.1.8, arm64, SDKROOT
`/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`, TMPDIR `/private/tmp`,
isolated `CRYSTAL_CACHE_DIR`, and `COGNI_RUN_SAFE_MIN_FREE_PCT=50
RUN_SAFE_PASSTHROUGH_STDIO=1`. Invoke
`/Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh` serially with
`/opt/homebrew/bin/crystal 600 8192 spec` followed by the four spec paths in
the manifest and `--single-module --link-flags=-fuse-ld=ld`; repeat with
`--release`. Full DEBUG uses `600 32768 spec` and the same flags. The oracle
uses the guard with `/bin/bash 600 8192 scripts/check_binary_w119.sh`,
`W119_KEEP_TMP=1`, `CRYSTAL_BIN=/opt/homebrew/bin/crystal`, and the pinned
`CLICKHOUSE_BIN` above. W117/W118/W116 retain their documented runner contracts.
Crystal formatting, `bash -n scripts/check_binary_w119.sh` and
`git diff --check` passed on the final candidate.

Logs are retained under `/private/tmp/crystal-click-scalar-w119.vlGxM0`;
`full-debug-final.log` SHA-256 is
`b13c96b0e01aceb9ae93615d3bd00c9c3b9b402d5fe89f47935b1414ae9fb55f`.
Final oracle artifacts are `/private/tmp/crystal-click-binary-w119.coflJ4`;
the task log root's `stock-w119-qualified.log` SHA-256 is
`4e92e008a002c4744d229a2e80d6b19c7298986d9bcc937d8f2c7d8a16febf17`.
Regression roots are `/private/tmp/crystal-click-binary-w117.rvI63g`,
`/private/tmp/crystal-click-object-shared-map-w118.Czbhm6`, and
`/private/tmp/crystal-click-json-w116.pxqH84`. Temporary artifacts are evidence
pointers, not shipped fixtures; rerun gates if unavailable.

Root hostile verdict: ROBUST for this bounded paired binary kernel, based on
executed stock, nominal-identity, budget and seeded-defect checks, not model
agreement. It does not certify bulk streams, whole JSON, library-generated
parts, all server timezone names, caller-raised stack limits, RSS or speed.
Changes to source/runtime, scalar grammar, ownership, budget propagation,
oracle schema rendering or comparison invalidate the corresponding evidence;
rerun its positive and negative gates before reuse. Next frontier: separately
qualified Object/Dynamic structure and physical lane/mark schedule owners,
with remaining recursive leaf grammars kept explicitly closed until qualified.
Large facade decomposition, MV/projections and performance remain open.

## W120 complete structure metadata

Status: VERIFIED within the bounded metadata profile and executed gates below,
over `cf4b9b1`; not whole-document JSON or a production part writer. Risk: CAUTION
for new paired serialization APIs. Anchor: fresh source `0c68f01a75a913b1aa5e132b41a80642260c3009`,
W116 independent physical vectors and W119's existing bounded descriptor kernel.
The pre-change focused W117/W118/W119 baseline passed 36 examples on October 2.
Rollback is this isolated feature's exact paths; do not modify existing facade
dispatch, retained parts, source checkouts or server stores. The existing
whole-JSON refusal remains load-bearing.

### Admitted profile and sealed design laws

- Exact, complete, fully decompressed single MergeTree structure blobs only.
  Object part versions V1/V2/V3 have codes 0/2/4. V1 preserves its ignored
  legacy maximum-path field; V1/V2 use MAP and require the complete unflagged
  positional counts plus shared map, matching current MergeTree producers and
  statistics-enabled readers. EOF after their roster is truncation in this
  complete-blob API, not admission of a standalone prefix. V3 requires its
  statistics flag (0/1), and only V3 can represent absent statistics.
- Object V3 records shared versions MAP=0, MAP_WITH_BUCKETS=1, ADVANCED=2,
  ADVANCED_CHUNKED=3. MAP has implicit one bucket; other modes have 1..256.
  Admission concerns metadata only, not any bucketed/advanced value layout.
- Dynamic V3 (code 4) concatenates up to 254 current W117-W119 binary type
  descriptors, with no length frames. The implicit SharedVariant is a spilled
  value alternative, not NULL (NULL discriminator is 255). Positional counts
  use canonical SQL-name order including SharedVariant, not descriptor wire
  order. The model preserves each descriptor's nominal identity, including
  Decimal width. Duplicate/equal-display-name alternatives are rejected as a
  no-alias profile guard rather than silently collapsed as upstream can do.
  Top-level Nothing/Nullable are outside the admitted canonical roster.
- Object decode accepts unsorted unique path rosters and preserves their order
  and corresponding counts. Encode sorts path/count pairs together. Shared
  statistics maps accept unordered entries; duplicate keys are rejected as an
  explicit stricter no-alias profile. Encode sorts those maps deterministically.
  Shared-map equality and hashing are order-independent; positional count
  arrays remain ordered and Object roster order remains representation identity.
  Canonical re-emission need not preserve noncanonical input bytes.
- Names are opaque detached String bytes (including empty, NUL and non-UTF8),
  not filename components or JSON::Any. Returned arrays, hashes and byte slices
  must not expose mutable owner storage. Absent statistics and present all-zero
  statistics are different states. Counts are UInt64 metadata estimates; no
  row-count/sum truth, prefix-vs-suffix provenance or marks are inferred.
- Prefix and suffix statistics end up in the same full structure stream.
  Parsing the complete decompressed blob does not reconstruct placement mode.
  V1/V2 statistics have no flag; V3 flag=0 must be exact EOF. Recognized
  Native-only versions are wrong-channel corruption in this MergeTree API;
  recognized older Dynamic part versions are unsupported, not corrupted.
  Unknown Object/Dynamic version codes are corruption, matching the source's
  incorrect-data branch; a recognized unadmitted profile is not the same case.
- Reuse strict minimal VarUInt and the existing depth/node/element/byte kernel.
  Domain, minimum remaining wire bytes and aggregate node/element budgets are
  preflighted before declared collection allocation. An Object plus all its
  Dynamic children shares one operation budget, including descriptors and
  statistics; no fresh per-child budget may bypass aggregate limits. Decode
  must check the complete aggregate input byte count before traversing it.
- Malformed/truncated/overflowed input, invalid flags/counts, alias guards,
  mismatched child path keys and trailing bytes raise CorruptPartError. Valid
  but unadmitted descriptor/version profiles raise UnsupportedFormatError.
  Invalid constructed models raise ArgumentError at construction. Write budget exhaustion
  remains UnsupportedFormatError, matching the kernel.

Rejected: Native/Compact or multi-header streams, compression, file access,
marks/rank schedules, actual Dynamic lanes, shared value layouts, whole JSON,
schema parsing, facade admission, generic Variant, MV/projections and performance.
Old Dynamic text-name versions remain open until a reusable nominal parser is
qualified; this slice does not remove those eventual requirements.

### Owner/API and execution plan

One owner per new file under `src/crystal_click/`:

- `StructureStatistic(name : String, count : UInt64)` and
  `StructureStatistics(counts : Array(UInt64), shared : Array(StructureStatistic))`.
- `ObjectStructure(dynamic_paths, version: 4_u64, shared_data_version: 0_u64,
  bucket_count: 1_u64, legacy_max_dynamic_paths: nil, statistics: nil)`.
- `DynamicStructure(types : Array(BinaryDataType), statistics: nil)` exposes
  canonical variant names (including SharedVariant) and its shared index.
- `ObjectStructureCodec` and `DynamicStructureCodec`: public exact `encode`
  and `decode` with BinaryCodecLimits; internal shared-budget entry points.
- `StructureStatisticsCodec`: shared bounded count/string/statistics grammar.
- `ObjectDynamicStructureSet(object, dynamics : Hash(String, DynamicStructure))`
  and `ObjectDynamicStructureStreams(object : Bytes, dynamics : Hash(String, Bytes))`.
  Keys must match the Object roster exactly in a decoded or encoded set.
- `ObjectDynamicStructureCodec.encode(set, limits)` / `.decode(streams, limits)`
  return paired owned streams/models with one aggregate budget.

Consumer inventory: `rg -l 'BinaryDataTypeCodec|BinaryCodecContext|BinaryCodecBudget|ObjectSharedMapCodec'
src spec scripts --glob '*.cr'` found six kernel files, three oracle scripts and
three focused specs, no table/facade consumer. Existing signatures need not change;
only `src/crystal_click.cr` adds imports. Root owns docs and all compiler,
ClickHouse and Git processes; Luna workers own disjoint new src/spec and script
paths and must preserve each other's work. Root independently owns
`spec/object_dynamic_structure_w120_budget_spec.cr`: fixed literal budget
counts in both directions, aggregate-byte-before-parse precedence and an
allocation-sensitive oversized-input check before detached accessor copying.

Execution: (1) author `spec/object_dynamic_structure_w120_spec.cr` only, run and
retain the missing-API RED; (2) implement the ten owners/imports; (3) execute
focused DEBUG/RELEASE and full DEBUG; (4) qualify the separate stock instrument;
(5) hostile review, record bounded evidence and exact-path atomic local commit.
No push. Proposed DoD uses Crystal 1.21.0 with the same serial resource guard,
SDKROOT, isolated caches and linker flags as W119. Focused command adds the new
two specs to W119's four paths; full DEBUG is `crystal spec` under 600s/32768MiB guard.
Oracle command is guarded `bash scripts/check_object_dynamic_structure_w120.sh`
with pinned CLICKHOUSE_BIN and W115 artifact root; it must report actual observed
gate results, not a schema/field-presence validator.

### Falsifiers and oracle boundaries

Independent literal vectors cover versions, buckets, empty rosters, absent vs
zero statistics, unsorted paths, Dynamic canonical ordering, nominal Decimal
collisions, raw names, detachment, recursive descriptors, exact/minus-one
aggregate limits, malformed/truncated/domain/minimum-wire/duplicate/trailing
controls. Strongest failure: statistics associated with the wrong type/path or
per-child budgets falsely passing an oversized aggregate operation. Guard both
with differently constructed expected counts and individually-fitting children.

New test-only scripts `check_object_dynamic_structure_w120.cr/.sh` (optional
`w120_structure_vectors.cr`) decode all ten W115 source structure streams and
their ten attached counterparts against metadata derived from the literal eight
input documents. Writer inputs must not be derived from production decode or
captured/W116 output bytes. Re-encode authored Object plus every existing Dynamic
structure into three isolated copied parts, rebuild prefix/terminal decompressed
mark offsets, compression and checksums, then ATTACH into fresh isolated stores.
Require actual CHECK=1 for each copy plus independent literal full and selected
JSON-document semantics. RowBinary source/copy equality is supplementary
differential evidence, not a literal binary oracle. Preserve W116 unchanged and
run it on untouched retained parts as the baseline. A valid permuted shared-map
case and wrong-statistics metadata-comparator control must prevent accidental
order pinning or reliance on CHECK to validate estimates. Seed at least one
expected byte/count mismatch to qualify the new comparator. Legacy Object,
bucketed/advanced metadata and no-stat cases remain source/local only unless
their actual stock gates are separately observed. CHECK of copied parts does
not admit a production library part writer.

Pre-implementation hostile correction: accepting legacy EOF-after-roster was
rejected as a complete MergeTree-part promise. Wide writes SUFFIX statistics
(`MergeTreeDataPartWriterWide.cpp:576`); Object V1/V2 emit unflagged counts in
that mode (`SerializationObject.cpp:964-997`) and the statistics-enabled reader
consumes them (`:801-829`). V3 is the explicit absent-statistics profile. A
standalone legacy prefix API is outside this slice; do not silently re-admit it.

### Executed W120 evidence (2026-10-02)

Root executed all compiler and ClickHouse gates serially with Crystal 1.21.0,
LLVM 22.1.8/arm64, the SDKROOT/TMPDIR and linker settings used in W119, a 50%
free-memory floor, isolated caches, and the pinned runtime identified above.
The ten new owners range from 46 to 171 lines, each in its own file. Only the
aggregate library imports change among existing production files; no table,
facade, physical I/O or writer-publication admission is widened.

The missing-API RED was observed at the authored `ObjectStructureCodec` call.
Earlier syntax-only probes were invalid instruments, not compatibility REDs.
Two separately exercised runtime allocation guards then failed: Object shared
statistics were reordered/copied before their budget check (3,932,880 allocated
bytes), and a foreign Dynamic roster was detached before exact-key validation
(3,934,016 bytes). Both now reject below the 131,072-byte test threshold. This
measures GC allocation for those rejecting codec operations, not RSS, total
model construction or performance. A same-cardinality 2 MiB wrong-key guard
also rejects before copying the foreign key map.

Separate qualified REDs caught unknown structure codes classified as unsupported
rather than corrupted, and order-sensitive equality for an unordered shared
statistics map. The former now distinguishes unknown/wrong-channel corruption
from recognized old Dynamic versions. The latter retains a collision-resolved
name index and uses order-independent shared-entry equality/hashing, while
positional counts remain ordered. The root-authored spec checks equal hashes,
Hash-key lookup, changed counts/names, and canonical Dynamic model round trips.
Raw-byte comparison resolves digest collisions in both duplicate detection and
equality; no literal digest-collision fixture was executed.

Final focused command inputs, with the common guard/options:

```sh
crystal spec spec/binary_value_codec_w117_spec.cr \
  spec/object_shared_map_w118_spec.cr \
  spec/binary_parameter_owners_w119_spec.cr \
  spec/binary_scalar_types_w119_spec.cr \
  spec/object_dynamic_structure_w120_spec.cr \
  spec/object_dynamic_structure_w120_budget_spec.cr \
  --single-module --link-flags=-fuse-ld=ld --error-trace
```

Root observed 54 examples in DEBUG and 54 with `--release`, all passing.
Final full DEBUG `crystal spec --single-module --link-flags=-fuse-ld=ld
--error-trace` under the 600s/32768MiB guard passed 1,961 examples. The existing
deprecated `blocking` argument and duplicate `-lc` warnings remain. Full RELEASE
was not executed. Logs are under
`/private/tmp/crystal-click-structure-w120.PEydyc`:

- `focused-debug-final.log`: SHA-256
  `e9aa897396dde5623d2db4f29ec40f8e72be70ff685d48bd883da2705fb6cde6`.
- `focused-release-final.log`: SHA-256
  `d17dd3ba71795b260e23daf3d68bd42672e024953de35d1a84cd3a0ecb909120`.
- `full-debug-final.log`: SHA-256
  `51acf51cd8ac0fc83888beedc837e8dc74bb0de69e8514406e1ed26c0e6fcb0c`.
- `stock-w120-qualified.log`: SHA-256
  `b168cab70ae56873976a844f3a008ada488b4a389cf78b808b84141a7528a860`.

Root ran `scripts/check_object_dynamic_structure_w120.sh` under the 600s/8192MiB
guard with `W115_CAPTURE_ROOT=/private/tmp/crystal-click-json-w115.6qs6Kq`,
`CLICKHOUSE_BIN=/private/tmp/crystal-click-w112-runtime.u0Jn1f/clickhouse`,
`CRYSTAL_BIN=/opt/homebrew/bin/crystal`, and `W120_KEEP_TMP=1`.
Artifacts are `/private/tmp/crystal-click-json-w120.ZPDLm0`, with the isolated
cache `/private/tmp/crystal-click-json-w120-cache.goj6Bv`. Observed gates:

- All 20 Object/Dynamic structures across six retained source/attached parts
  match independently authored metadata from the eight literal input rows.
  Root independently counted the literal path/type statistics.
- Three new isolated copies had production-encoded complete Object/Dynamic
  structure streams substituted by the test instrument, with rebuilt physical
  marks, LZ4 frames and checksums. All three freshly ATTACHed and returned actual
  CHECK=1. Source and copy full/selected `pk 3..6` documents match independent
  literal expectations; source/copy RowBinary equality is supplementary only.
- Valid permuted Object and Dynamic shared maps decode and canonically re-emit;
  absent/present-zero statistics stay distinct. A seeded byte mismatch is
  rejected. The NULL-255 control excludes NULL from SharedVariant counts, and
  the wrong-spilled-type-statistics control fails the metadata comparator.
  CHECK is explicitly not an oracle for statistical estimates.

Two preceding oracle compiles failed in the test instrument (`Tuple#sort`,
then a missing test-only LZ4 helper). They were corrected before any qualified
stock result and are not compatibility REDs. W116 itself remains unchanged;
W120 has separately named test-only framing/checksum helpers, including the
old-size guard for every unchanged compressed stream.

Root reran unchanged W116-W119 on the final source state, all passing:

- W116: six actual CHECK=1 results, twelve negative CHECK comparator controls,
  twelve literal full/selected semantic checks, copied raw/type/mark/schema
  attacks, and the precise existing whole-JSON admission refusal. Artifacts:
  `/private/tmp/crystal-click-json-w116.8zQC0V`.
- W117: 36 stock-writer and 36 stock-reader/re-emission vectors, with its
  unchanged corruption and comparator controls. Artifacts:
  `/private/tmp/crystal-click-binary-w117.QXrLyk`.
- W118: three profiles, six retained parts, twelve windows, eighteen independent
  literal lanes plus writer-byte/symlink/NULL controls. This W118 regression
  does not run another ATTACH/CHECK. Artifacts:
  `/private/tmp/crystal-click-object-shared-map-w118.wnzJXC`.
- W119: 22 vectors in each stock direction plus its local/canonical/corrupt
  controls. Artifacts: `/private/tmp/crystal-click-binary-w119.zmvhkp`.

The regression logs are `regression-w116-final.log` through
`regression-w119-final.log` in the W120 log root. Crystal format, shell syntax
and `git diff --check` passed. The ordered SHA-256 manifest of the 16 non-doc
feature paths is `23fa334ec82ebd541bbeabeb13f9e5af8aa7e7e700b3234dbce87c047d29bb07`.
Hash each of these relative paths in order with `shasum -a 256`, then hash
that command's output with `shasum -a 256`:

```text
src/crystal_click.cr
src/crystal_click/structure_statistic.cr
src/crystal_click/structure_statistics.cr
src/crystal_click/object_structure.cr
src/crystal_click/dynamic_structure.cr
src/crystal_click/structure_statistics_codec.cr
src/crystal_click/object_structure_codec.cr
src/crystal_click/dynamic_structure_codec.cr
src/crystal_click/object_dynamic_structure_set.cr
src/crystal_click/object_dynamic_structure_streams.cr
src/crystal_click/object_dynamic_structure_codec.cr
spec/object_dynamic_structure_w120_spec.cr
spec/object_dynamic_structure_w120_budget_spec.cr
scripts/check_object_dynamic_structure_w120.cr
scripts/check_object_dynamic_structure_w120.sh
scripts/w120_structure_vectors.cr
```

The feature's two doc paths
are this frontier and `MODULARIZATION_FRONTIER.md`; no generated artifacts or
unrelated paths belong in its atomic local commit. No push.

Root hostile verdict: ROBUST for the declared default-bounded metadata profile,
using the executed literal, stock, budget, detachment and seeded-defect gates.
The same-lineage static review supplements those observations, not independent
execution. Legacy Object and bucketed/advanced metadata remain source/local
qualified only; no stock execution of those layouts is inferred. Constructors,
large caller-raised limits, CPU complexity, RSS, speed, whole JSON, production
part publication and facade decomposition are outside this certificate.
Source/runtime, grammar, ownership/budget propagation or instrument/comparator
changes invalidate their dependent gates; rerun positive and negative checks.

Continuation: the user goal remains all paired types, then MV/projections,
then performance. The next confirmed return pointer is a reusable Dynamic
lane/rank/mark schedule owner, using W120 rosters and the W117-W119 scalar kernel.
Before widening, qualify mixed/spilled/NULL tags and nonzero-origin sparse ranks
against literal W115 rows, and corruption in a later selected mark before any
callback. Keep compression/physical access separate, share one aggregate budget,
and preserve exact whole-JSON refusal until document assembly is qualified.
Existing local-copy/test authority remains valid; no live-store write, push or
performance claim is authorized by this checkpoint.

### Subsequent Object/Dynamic integration

Use one concrete owner per file for distinct responsibilities, not per schema
combination. Reuse bounded frame/mark access and primitive leaf codecs; keep
generic Variant admission closed. Separate the Object envelope/path dictionary,
binary DataType/value decoding, Dynamic lane schedules, shared-data layout,
owned nominal document values, document reader, and staged writer orchestration.
Schema parsing must preserve JSON parameters and typed declarations; admitting
only a spelling of bare `JSON` is not a substitute for these physical profiles.

W117-W119 now handle a binary DataType descriptor followed by that type's
single-value serialization, reusable by Dynamic SharedVariant and Object MAP
values within their admitted grammar. Bulk column serializers are not
substitutes for this scalar kernel. Preserve its bounded recursive decoding,
exact cursor consumption, nominal identity and floating-point raw bits when
integrating it. Its qualified empty-array/type, truncation, trailing-byte and
depth/element/byte falsifiers remain load-bearing. That kernel, W118 MAP rows
and W120 metadata do not yet admit whole-document JSON; physical lane/rank,
mark and shared-data schedule owners remain necessary.

Preserve stored ClickHouse semantics, including typed defaults and dynamic
null/path normalization, rather than promising preservation of original input
JSON presence. Nominal numeric values and floating-point raw bits must not be
silently erased through `JSON::Any`. Whole-document values and typed virtual
path projections remain different APIs.

Before callbacks, validate all selected child/shared streams, sparse ranks and
mark axes with one aggregate logical-budget contract. The paired writer must
detach input, emit complete metadata/streams/marks/checksums, then reopen its
stage through the public whole-document reader and compare nominal values/raw
bits before exclusive publication. A self-read remains supplementary to stock
ATTACH, actual CHECK=1 and independent whole-document expectations.

Required later falsifiers include mixed or spilled Dynamic types, missing/NULL
versus defaults, nested/dotted/escaped paths, all-empty lanes, malformed type
dictionaries/statistics, truncation in a later selected mark before callbacks,
nonzero-origin sparse ranks and exact/minus-one aggregate budgets. Object V1/V2,
bucketed/advanced/chunked shared data, Compact parts, recursive typed paths and
general compositions remain open requirements, not silently removed goals.

Refresh the certificate after producer/build, serializer settings, type
encoding, mark/codec layout, instrument/comparator or relevant implementation
changes. RSS, crash/concurrent-filesystem guarantees and speed are not inferred
from this capture checkpoint.

## W121 paired Dynamic discriminator and sparse schedules

Status: VERIFIED within the strict normalized discriminator/schedule profile
and executed source/local/stock gates below; no whole-Dynamic/JSON admission.
The design was sealed over `74a8752`.
Execution resumed over `2e9e0c4` after the behavior-neutral LC extraction.
The prior turn was progress: commits `0626874`/`2e9e0c4`, full DEBUG 1,973
examples and the unchanged LC stock oracle passed. There is no current blocker.
Risk: CAUTION for paired serialization and selected-row coordinates. Rollback:
this slice's exact paths, without changing existing facade admission or stores.
W120 was already committed with executed gates; the full
all-types/MV/projection/performance goal remains active, not achieved.

### Boundary and design laws

The next reusable owner handles the complete decompressed discriminator stream
and its normalized absolute decompressed mark grid. It is paired: encode produces
both bytes and marks; decode validates selected marks and returns owned sparse
schedules. This is a prerequisite for actual Dynamic lane assembly, not another
schema-specific Dynamic table API. W120 supplies the immutable roster; sorted
full SQL names, including implicit SharedVariant, define global wire tag order.
Descriptor wire order and in-memory local discriminators do not define that order.
NULL=255 consumes no arm occurrence; SharedVariant is an ordinary counted arm.

Source anchors in the pinned `0c68f01a` checkout:
`SerializationVariant.h:28-47,57-77,178-182`,
`SerializationVariant.cpp:199-229,343-523,537-683,749-770`,
`DataTypeVariant.cpp:46-64`, and `ColumnVariant.h:18-36,67-68`.
Root checked the mode prefix, granule grammar and name sorting directly.
Source inference is separate from the pinned executable's measured behavior.
The current source reference is `31d2addbabda0d8e14ffd325fc0a9106528aa1c7`
in `/Users/sergey/SrcArchives/clickhouse-2026-10-02-depth1-31d2addb`.
Root verified `src/DataTypes`, `src/Columns` and `src/Storages/MergeTree`
byte-for-byte equal to `0c68f01a`; the anchors above remain source-valid.
This does not change the pinned runtime identity or widen physical admission.

- Admit BASIC mode 0 and COMPACT mode 1. The complete stream starts with its
  eight-byte little-endian mode. BASIC bodies have one global tag per row;
  COMPACT bodies have minimal VarUInt row count, format 0 (row tags) or 1
  (uniform tag). Uniform NULL is valid. Unknown modes/formats are corruption.
  The writer uses COMPACT uniform format whenever all tags agree, otherwise
  row format; valid noncanonical uniform-as-row-format input may re-emit differently.
  Minimal VarUInt and positive, exactly aligned real-mark bodies are strict
  captured-writer profile restrictions, not equivalence to the generic CH
  decoder: `VarInt.h:86-105,165-195` accepts some nonminimal representations,
  and `SerializationVariant.cpp:680-718` can skip zero-row granule starts.
  W121 deliberately rejects those inputs; relaxing this later requires its
  own source/runtime falsifiers and an explicit admission change.
- Marks are normalized decompressed byte offsets, not ClickHouse compressed
  frame coordinates. The first data mark begins at byte 8, every real mark
  has positive rows and a positive byte extent, and exactly one terminal
  mark has zero rows and offset equal to byte size. An empty stream has only
  the terminal mark at 8. Real mark rows are capped at Int32::MAX for the
  owned schedule profile. Physical `.mrk2` conversion, decompression and
  filesystem lifetime policy remain outside these owners.
- Validate the complete grid and range without copying it; parse only selected
  bodies. Selection is contiguous `first_mark`/`mark_count`, with zero count
  permitted at any in-range boundary, including the terminal position.
  Inner COMPACT row counts must equal
  their selected mark's rows, and each selected body must be exactly consumed.
  A valid grid does not attest unselected payload tags or actual child lanes.
- Each output mark keeps its original mark index and absolute outer `first_row`
  derived from the grid, detached tags, per-arm counts, mark-local sparse ranks
  (`nil` for NULL), and per-arm selected-window offsets before that mark.
  Selected-window offsets start at zero at the first selected mark. They are
  not absolute part-wide sparse ranks or child byte offsets. Consumers must
  use each child lane's own physical mark coordinates and validate cardinality
  separately before document callbacks.
- All selected schedules are validated before return; there is no callback
  API exposing an earlier schedule while a later selected mark can still fail.
  Inputs and getters detach mutable arrays/bytes. Model construction is outside
  the measured codec budget, as in W120; the codec must not copy full bytes/grid
  through accessors before preflight. `DynamicDiscriminatorStream.borrowed_slice`
  is a convention-internal mutable view used read-only by the codec; Crystal's
  public method does not enforce read-only ownership for other callers. The
  detached public getters do not make this borrowed view immutable.
- Reuse BinaryCodecLimits/BinaryCodecBudget, with convention-internal borrowed
  budget entry points in both directions. No fresh budget per selected mark or
  Dynamic child. Depth is 1. For M complete grid records (including terminal),
  K selected real marks, R selected rows and V canonical arms: nodes are
  `1 + M + R`, elements are `M + 2*R + (2*K + 1)*V`, and wire bytes are
  `8 + sum(selected body extents)`. Full encode uses all real marks and the
  same accounting. The counters cover grid scanning, row tags/ranks, each
  counts/offsets array and the V-entry running offset state.
- Preflight metadata before grid traversal/copies, row work before tag expansion,
  and complete selected wire bytes before selected slices. Encoder preflights
  row work before scanning caller arrays and exact output bytes before building
  the stream. Default schedule limits are depth 1, 1,000,000 nodes, 3,000,000
  elements and 64 MiB wire bytes, rather than silently reusing the recursive
  descriptor kernel's 4,096-node default for ordinary 8,192-row CH granules.
  Limits are logical-work bounds, not RSS or speed guarantees.
- Malformed input/grid, truncation, tag outside `[0,V)` other than 255,
  inner/outer row mismatch and read budget exhaustion raise CorruptPartError.
  Invalid caller write mode, empty real granule or tag outside the roster raises
  ArgumentError; write budget exhaustion raises UnsupportedFormatError.
  Invalid caller selection/direction raises ArgumentError before output.

Rejected/guard-only: Native/specialized-prefix and Compact-part layouts,
compressed physical mark mapping, child lane value/cardinality validation,
Object shared merging, general JSON assembly, table/facade admission, staged
part publication, MV/projections and performance. BASIC is not treated as
unsupported merely because the retained W115 capture used COMPACT. Legacy
Dynamic metadata remains governed by W120, not changed by this slice.

### Owners, execution and falsifiers

New production files under `src/crystal_click/`:
`dynamic_discriminator_mark.cr` (immutable offset/rows record),
`dynamic_discriminator_stream.cr` (detached bytes/grid, size/index accessors),
`dynamic_mark_schedule.cr` (owned selected tag/rank/count/offset record),
and `dynamic_discriminator_codec.cr` (paired grammar and shared-budget schedules).
Only the aggregate `src/crystal_click.cr` adds imports. Implemented API:
`DynamicDiscriminatorCodec.encode(structure, Array(Array(UInt8)), mode: 1_u64, limits: ...)`
returns DynamicDiscriminatorStream; `.decode(structure, stream, first_mark: 0,
mark_count: nil, limits: ...)` returns Array(DynamicMarkSchedule).
Internal `.encode_with_budget`/`.decode_with_budget` borrow a correctly directed
BinaryCodecBudget for eventual aggregate Object/Dynamic integration.

Consumer inventory: `rg -l 'VariantDiscriminatorDecoder|DynamicStructureCodec|ObjectDynamicStructureCodec|read_dynamic_.*mark_range' src spec scripts --glob '*.cr'`
found W74/W75 facade/reader/writer consumers, the existing private Variant
decoder, W120's metadata codec and its specs/oracle, and no consumer of these
new owners. Do not modify or route legacy facades during this feature.
Root owns docs, independent budget spec, all compiler/CH/Git processes and
the final claim. Luna workers own disjoint new source/spec and script paths;
they are not alone and must preserve each other's work.

Execution plan:

1. Author `spec/dynamic_discriminator_w121_spec.cr` only and let root retain a
   missing-API RED. Root then authorizes the four owners/imports.
2. Add literal BASIC/COMPACT, mixed/uniform/NULL, empty stream, selection,
   canonical order, ownership, malformed-grid/body and exact/minus-one tests.
   Root owns `spec/dynamic_discriminator_w121_budget_spec.cr`, including an
   8,192-row default-limit positive and compact expansion/copy preflight guards.
3. Author separate `scripts/w121_discriminator_vectors.cr` and
   `scripts/check_dynamic_discriminator_w121.cr/.sh`, keeping W116-W120 unchanged.
   Literal rows define expected tags/ranks and normalized offsets, not captured
   bytes or production decoder output. Read all seven streams from both source
   and attached W115 parts: fourteen exact streams, full and selected windows.
4. Encode authored tags into two isolated copied profiles in each mode, replacing
   only discriminator `.bin`/marks and rebuilding test-only frames/checksums.
   Require four actual ATTACH/CHECK=1 results and independently expected full
   documents plus selected `pk 3..8`, which covers both spilled Int64 and Bool.
   RowBinary source/copy equality is supplementary, not a literal binary oracle.
5. Execute focused DEBUG/RELEASE, full DEBUG, the new stock oracle and unchanged
   W116-W120 regressions serially through the established resource guard;
   inspect hostile findings, update this seal and modularity evidence, then
   exact-path local commit. No push. Reuse the existing SDK/pinned runtime.

DoD: add the two W121 specs to W120's six focused inputs; DEBUG and RELEASE
must pass. Full DEBUG is guarded `crystal spec --single-module
--link-flags=-fuse-ld=ld --error-trace` (600s/32768MiB). The stock wrapper uses
the pinned CH executable and retained W115 root under 600s/8192MiB. Expected
oracle signal is fourteen source/attached streams plus four new CHECK=1 copies,
literal full/nonzero-origin schedules and semantic windows, with seeded wrong
tag/rank/byte comparator controls. Format, shell syntax and diff checks remain.
The full non-release replay may omit symbolic debug information with `--no-debug`
to fit the unchanged guard; this does not disable overflow checks or substitute
a dry run. Record both the failed resource gate and the actual executed replay.

Decisive stock-backed falsifier: typed_mixed.s canonical arms are
SharedVariant=0 and String=1, NULL=255. Select marks 1..3 (pk3..8):
`[1,255] [0,255] [1,0]` means String, NULL, spilled Int64, NULL, String,
spilled Bool. Its normalized mark begins are 11,15,19; selected String ranks
and SharedVariant ranks each begin at zero despite earlier String rows.
Source literals and marks are already independently authored in
`scripts/w116_json_physical_vectors.cr:612-768`; root rechecked the tags.
Also distinguish an empty Array's outer arm occurrence from zero flattened
elements, without claiming to decode or validate the Array child here.

Strongest failure: confusing outer rows, per-mark ranks, selected-window offsets
and physical child offsets, or resetting budget per mark. Use different mark
patterns, exact/minus-one aggregate limits and a last-selected-mark corruption
after earlier marks are valid. A same-size wrong-rank comparator must reject.
Unselected-body corruption is intentionally not claimed checked by a selection;
an explicit test must distinguish that from full decoding. Any source/runtime,
mode/mark grammar, limits, coordinate contract or instrument change reopens its
dependent evidence. Whole-JSON refusal remains the capability guard.

### W121 executed certificate and continuation

Executed on October 2 over `2e9e0c4`, with only the four new owners, aggregate
imports, two specs, three oracle files and these two frontier documents changed.
The finalized production owners are 11/49/43/450 lines respectively (553 total);
these are navigation counts, not coupling or performance measurements.
Existing WidePart, writer and table implementations are unchanged.

Root-executed evidence on the restored production source:

- Missing-API RED: the authored spec failed for the absent
  `DynamicDiscriminatorMark`, before production authorization.
- Focused DEBUG and RELEASE: 77 examples each, no failures/errors/pending.
  Full non-release DEBUG with `--no-debug` (no symbolic debug information):
  1,996 examples, no failures/errors/pending. Runtime overflow checks and
  non-release semantics were not disabled. Full RELEASE was not executed.
- The original full DEBUG compilation was killed by the existing guard at
  system free memory 50% after about 85 seconds; it produced no test result.
  The successful no-symbols replay retained the same 50% floor and resource
  limits. No foreign process was stopped and the guard was not weakened.
- Root's independent exact/minus-one and instrumented preflight tests cover
  borrowed aggregate budgets, wrong budget direction, Int128 selection bounds,
  255 canonical arms (SharedVariant=254 versus NULL=255), an interior empty
  window, an 8,192-row default-limit positive, an 8 MiB unselected body and
  compact uniform expansion refusal before slicing/materialization. Logical
  budget counters do not account for owned model construction/getter copies.
- Hostile falsifiers exposed an incorrect test literal offset, an empty-stream
  trailing-byte acceptance, and selection narrowing that raised OverflowError
  for Int128::MAX. The literal and production bounds were repaired. A root
  qualified RED retained 76 examples/two failures before the final 77 positives.
- Root temporarily disabled the private VarUInt minimality guard. The W121
  specs failed (23 examples, one failure: expected CorruptPartError, none raised).
  The original guard was restored before the final focused/full/stock gates.
- The new stock oracle compares fourteen retained source/attached discriminator
  streams with independent byte/mark/tag/rank/count/offset expectations. It
  decodes full and nonzero-origin selected windows, including the spilled
  Int64/Bool and empty-Array outer-occurrence cases. This does not decode the
  child value lanes.
- Four fresh isolated copies (two schemas, BASIC and COMPACT) receive the
  production encoder's actual bytes and mark grid. Test-only LZ4/checksum surgery
  does not modify retained W115 parts. Each actual stock ATTACH and exact-part
  CHECK result is 1. Independent full documents and selected pk3..8 match;
  source/copy RowBinary equality remains a supplementary differential.
- Wrong-tag, wrong-rank, one-byte and CHECK=0 controls invoke the actual
  comparators and are rejected. Root found and qualified two script defects
  before CH ran: Array#to_slice did not compile, and a `.try` block's Nil
  iteration result falsely signaled an absent profile. Owned byte copies and
  explicit lookup repaired them without weakening expected vectors or controls.
- Unchanged W116-W120 stock regressions all exit 0. W116 preserves the exact
  whole-JSON missing-capability RED and its actual CHECK/literal negative
  controls. W118 remains a retained-lane oracle, not a new part writer.
- Final nine-file Crystal format check, wrapper syntax and diff hygiene pass.

Compiler: Crystal 1.21.0/LLVM 22.1.8/AArch64 at `/opt/homebrew/bin/crystal`;
`SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`,
`TMPDIR=/private/tmp`, isolated compiler caches. All compiler/CH workloads are
serial under `/Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh`,
50% minimum free memory, 600 seconds, focused/oracles 8,192 MiB, full 32,768 MiB.
The current source reference remains 31d2addb; the executable remains the
separately pinned 26.10.1.1201/d9bcb5ab/SHA-256 identity above. Forced Wide/LZ4,
plain adaptive marks, Object V3 and shared MAP are measured settings, not
qualification of current-master default bucketed/advanced layouts.

Replay commands, under that guard and environment:

```sh
crystal spec spec/binary_value_codec_w117_spec.cr spec/object_shared_map_w118_spec.cr spec/binary_parameter_owners_w119_spec.cr spec/binary_scalar_types_w119_spec.cr spec/object_dynamic_structure_w120_spec.cr spec/object_dynamic_structure_w120_budget_spec.cr spec/dynamic_discriminator_w121_spec.cr spec/dynamic_discriminator_w121_budget_spec.cr --single-module --link-flags=-fuse-ld=ld --error-trace
# Repeat the focused command with --release.
crystal spec --no-debug --single-module --link-flags=-fuse-ld=ld --error-trace
W115_CAPTURE_ROOT=/private/tmp/crystal-click-json-w115.6qs6Kq CLICKHOUSE_BIN=/private/tmp/crystal-click-w112-runtime.u0Jn1f/clickhouse CRYSTAL_BIN=/opt/homebrew/bin/crystal W121_KEEP_TMP=1 bash scripts/check_dynamic_discriminator_w121.sh
# Same pinned environment; execute these unchanged regressions serially:
bash scripts/check_json_w116.sh
bash scripts/check_binary_w117.sh
bash scripts/check_object_shared_map_w118.sh
bash scripts/check_binary_w119.sh
bash scripts/check_object_dynamic_structure_w120.sh
```

Logs: `/private/tmp/crystal-click-w121-root.aytqug/`, specifically
`missing-api-red.log`, `focused-int128-red.log`, `seed-nonminimal-red.log`,
`focused-debug.log`, `focused-release.log`, `full-debug.log` (guard kill),
`full-debug-no-symbols.log` (positive), `stock-w121.log` (compile RED),
`stock-w121-repaired.log` (lookup RED), `stock-w121-formatted.log` (final positive),
`regression-w116.log` through `regression-w120.log`, `format-check-final.log`.
Final retained W121 store root:
`/private/tmp/crystal-click-json-w121.KJ4njM`, cache
`/private/tmp/crystal-click-json-w121-cache.NJuYVV`. These temporary paths may
decay; replay the independent vectors against a fresh retained W115 capture if
they disappear rather than treating an old log as a new runtime observation.

Luna's static adversary result is correlated, not an independent runtime oracle.
Root's scoped verdict is ROBUST for the sealed codec path, supported by the
owned falsifiers, restored-guard seed, executed suites and actual stock copies.
Residual: the convention-internal public borrowed slice is mutable; concurrent
or external mutation safety is not claimed. Strict minimal/positive/aligned
inputs are a captured-writer restriction, not full generic-CH decode equivalence.
No physical compressed mark conversion, child cardinality, whole JSON,
production part publication, MV/projection, RSS or speed claim follows.

Active return pointer: reusable paired Dynamic child-lane/cardinality owners,
then Object/shared document assembly and staged writer integration. The next
discriminator is a nonzero-origin mixed/spilled lane window whose child counts
must agree with W121 schedules; corrupt the last selected child mark and require
failure before any document callback. Preserve one aggregate logical budget
across metadata, discriminators, child/shared values and assembly. Confirm the
physical lane mark axes instead of treating selected-window offsets as part-wide
ranks. General JSON refusal stays in force until its own paired public and
stock gates pass. Current implementation/oracle/toolchain, producer/build,
serializer settings, limits, coordinates or comparator changes reopen dependent
evidence. The all-types/MV/projection/performance goal remains active; the prior
turn and this slice are progress, not consecutive blocked goal turns.
