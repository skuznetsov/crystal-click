# General JSON Storage Frontier

Current frontier (2026-10-03): W128 checkpoint `1c5bab4` qualifies complete
library-owned normalized Object parts; W129 adds bounded whole-Object catalog
materialization; W130 adds mixed Object/scalar typed-table batches, physical
windows and bounded UInt64-PK candidate delivery. W132 extends W131 `02dd99f`
to paired declared integer widths, Float32/64 and Bool alongside String,
qualified in both directions for String 0/1 × BASIC/COMPACT. W133 adds bare
declared Date/Date32 with separate calendar and raw-carrier evidence. W135 adds
bare declared UUID/IPv4/IPv6 through the existing fixed-value/bulk owners,
qualified for the same eight native/library profile cells with independent
nominal/text/byte-order evidence. The exact
admitted profiles and executed gates are in their sections below. These do not widen
physical layouts, the one-Object writer or projection reads.
This is not general JSON schema/layout compatibility or completed arbitrary
table integration. Older scalar JSON projections retain their existing
contract; see `JSON_TYPED_PATH_FRONTIER.md`.

W115-W127's retained historical certificates cover stock capture and physical
qualification, the reusable type/value kernel, shared-MAP and recursive bulk
codecs, Object/Dynamic structure and sparse schedules, flattened documents,
compressed transport/plain marks, stream binding, file-backed reading and
fresh unpublished column files. Each certificate is scoped to its own source,
runtime, profile and executed gates; a logical codec does not independently
admit a whole part. W128 closes normalized schema-sidecar synthesis and staged
whole-part publication without borrowing stock files. W129 is the separate
catalog adapter, not an inherited W128 runtime certificate.

The target is a reusable Object/Dynamic/shared-data engine with cohesive
owners, not another exact declaration registered in the existing facades.
General layouts, additional declared typed-field families and compositions,
and broader MV/projection support remain open.
Performance work remains parked.

## Source anchor and compatibility boundary

The separate shallow source reference for the certificates below is
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
That reference's DataTypes, Columns and MergeTree directories are
byte-for-byte equal to that earlier reference; the serializer anchors below
remain applicable. This is source comparison, not a new executable qualification.
Keep the initial capture/literal source and runtime identities intact.
See `CLICKHOUSE_SOURCE_REFERENCE.md` for newer source-only comparisons; they
do not retarget these executed certificates to a different source or runtime.

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

Legacy scalar-path production anchors: `WidePart.json_typed_paths` parses simple
declared scalar paths, not JSON settings or arbitrary paths; that adapter does
not admit whole JSON. Its typed-path reading validates the Object V3 prefix but does
not decode the remaining shared structure. Its writer substitutes already
normalized scalar defaults and emits empty dynamic/shared data. Existing Dynamic
profiles require empty SharedVariant rows/statistics. None of these guards
demonstrates general JSON support. The separately qualified normalized whole-
Object owners and public consumers are recorded in W128-W133 below; do not
confuse either bounded path with arbitrary JSON compatibility.

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

## W122 design seal: reusable bulk children and Dynamic logical values

Status: VERIFIED within the normalized codec and executed gates below, over
`e71a967`; not all ClickHouse bulk layouts. This is a CAUTION serialization
change, not public whole-JSON admission or a performance change. Existing
facades/refusals remain unchanged. Root owns compiler/CH/Git processes; Luna
owns disjoint production, test and oracle paths. Rollback is the exact new
owners/specs/scripts and aggregate imports in one local atomic commit. Do not
push or touch the retained source/capture/runtime.

### Source anchor and admitted profile

Reference: shallow current source 31d2addbabda0d8e14ffd325fc0a9106528aa1c7,
in the separately retained 2026-10-02 checkout. Runtime remains independently
pinned 26.10.1.1201/d9bcb5ab; current-source agreement is not runtime identity.
The primary-source counterexamples to scalar-envelope reuse are:

- SerializationArray.cpp:156-199,352-394: position-independent UInt64 LE lengths
  per array occurrence, then a distinct flattened-child cardinality.
- SerializationNullable.cpp:114-177: explicit null map and nested payload of
  equal cardinality, including NULL rows. ColumnNullable.cpp:257-270,294-303
  and applyNullMap preserve the possibility of nondefault hidden payloads.
- SerializationNothing.cpp:33-48 and SerializationTuple.cpp bulk empty-tuple
  branches: one ASCII `0` byte per occurrence, not an absent/zero-width stream.
- SerializationVariant.cpp child loop: zero-occurrence arms still visit their
  nested serializers. Per-stream Wide marks are byte coordinates; adaptive
  mark row fields remain outer-table rows, not sparse child counts.
- SerializationDynamic.cpp shared statistics and ColumnDynamic.cpp:720-733:
  SharedVariant is a bulk String lane of typed single-value envelopes. Ordinary
  arm payloads do not repeat their type per row.

The normalized profile admits every currently constructible BinaryDataType
shape: fixed raw nominal leaves, String, Bool, Nothing, Array, Nullable, named
and unnamed Tuple (including empty), and Map, recursively. BinaryBulkProfile
explicitly chooses uniform String single-stream length+bytes or the retained
stock WITH_SIZE_STREAM layout: UInt64 LE raw byte lengths on `.string_sizes`
and concatenated raw bytes on `.data`, with no terminator. Empty sizes are legal;
embedded NULs remain data. Each stream has its own grid. Array uses
position-independent lengths; explicit
Nullable null map with canonical 0/1 flags; canonical ASCII `0` placeholders.
Active fixed leaves retain exact bytes, including float/identifier bits.
Nothing and empty-Tuple decoders intentionally restrict placeholders to this
writer profile; generic CH readers merely ignore their bytes. Nonminimal
VarUInt, noncanonical null flags, implicit-null-map, sparse/custom serialization,
mixed per-leaf String profiles, cumulative network offsets and missing physical-stream
inference are outside this profile. Physical adapters must establish the
profile rather than guess it from SQL type names.

Logical NULL does not retain hidden nested bytes. Encoding it writes a
canonical nested default: zero fixed bytes, empty String/containers, false
Bool, NULL Nullable, and the per-occurrence Nothing/empty-Tuple placeholder.
This matches a logical-value rewrite, not a physical-lossless rewrite. Decoder
still validates selected hidden nested payloads and their cardinality before
discarding them. Nullable(Nothing) permits only logical NULL; a selected zero
null flag cannot manufacture a non-null Nothing value.

### Owners, coordinates and laws

- BinaryBulkStream owns detached bytes and one offset grid, with initial 0 and
  a terminal byte-size offset. Repeated offsets are legal. The grid has K+1
  records for K outer marks; each recursive child stream has the same grid
  length, even when its occurrence count is zero. Offsets are decompressed
  bytes, not compressed marks, outer rows, ranks or element counts.
- BinaryBulkStreams owns K and an exact role-to-stream set. Roles are internal
  structural paths: `root.data`, `.sizes`, `.elements`, `.nulls`, `.nested`,
  `.string_sizes`, `.field.N`. Map uses sizes plus key/value child roles under elements.field.0
  and elements.field.1. Tuple fields use ordinal roles, never escaped SQL names.
- BinaryBulkCodec encodes Array(Array(BinaryValue)) granules and decodes using
  explicit per-mark root occurrence counts. Those counts are supplied by the
  parent, never copied from physical adaptive mark row fields. Whole grids,
  role sets and range/count domains are validated; only selected body extents
  are read. Selected zero-count bodies must be empty. No range getter copies
  an unselected lane.
- DynamicValueStreams owns the W121 discriminator stream and a complete set
  of canonical ordinary-arm bulk stream owners plus SharedVariant bulk String.
  DynamicValueCodec derives child counts from selected W121 schedules, parses
  all selected children/shared envelopes before returning any logical rows,
  and gathers by per-mark ranks. Selected-window arm offsets are never used as
  part-wide physical positions. Encoder routes exact nominal roster matches
  to ordinary arms and other admitted non-Nullable/non-Nothing values to shared
  envelopes. Top-level Nothing NULL becomes tag255 and consumes no child.
- Strict SharedVariant envelope admission rejects top-level Nothing/Nullable.
  This is our normalized producer restriction, not a claim that every CH
  insertion path rejects such envelopes. Nested Nullable remains admitted.
  A shared envelope whose nominal type also occurs in the ordinary roster is
  accepted: merges can retain it there. A logical rewrite may reroute it to an
  ordinary arm. Equal display names are not equal nominal descriptors; Decimal
  width is retained even when the SQL name omits it.
- Every codec supports a correctly directed borrowed BinaryCodecBudget. One
  parent budget spans discriminator, descriptor, stream/grid metadata, recursive
  child values, shared envelopes and assembly; no reset per mark/arm. Preflight
  count-derived collections before allocating, reject overflow/domain errors
  as typed failures, and charge selected physical bytes exactly once. Logical
  node/edge work can include canonical default materialization and assembly.
  Detached public model construction/getters are caller-owned and outside
  codec budgets; these are not RSS/allocation/performance certificates.
  Input value descriptor trees are validated before computing their names,
  including descriptors that will spill. Every assembled output row, including
  tag255 NULL, is charged. Temporary shared envelopes reserve previously pending
  frames and minimum outer framing through `encode_borrowed`'s additive
  `reserved_wire_bytes` parameter; exact framing is checked before the String
  copy and final bulk emission charges its wire bytes once. A growing VarUInt
  prefix can consume up to nine extra temporary bytes before rejection, still
  within the remaining logical byte ceiling; this is not an RSS guarantee.
  Invalid Dynamic caller selection retains W121's ArgumentError, while malformed
  selected bytes are CorruptPartError. Bulk count/range domain failures are
  CorruptPartError on read and UnsupportedFormatError on write.

### Falsifiers, plan and Definition of Done

First execute a missing-API RED with independent Array(Nullable(String)) literal
lanes, empty arrays, hidden NULL default, and nonzero-origin selection. Then
implement disjoint bulk and Dynamic owners, one class per file; helpers may be
split further instead of growing legacy reader/writer/table facades.

Required independent tests: literal columnar Tuple/Map order; all fixed nominal
widths/raw bits; Nothing/Nullable(Nothing)/Tuple() placeholders; repeated marks
and zero-arm granules; empty Array versus empty child lane; malformed final
selected child fails before return; unselected malformed body is not parsed;
extra/missing roles, malformed terminal/grid, impossible counts/overflow,
ownership mutation, strict shared envelope admission, direction/cross-call
budget exhaustion and exact/minus-one budget thresholds. Use a seeded removed
cardinality guard and restore it before positive gates.

DoD commands (same serial guard/toolchain/50% floor as W121): focused W117-W122
specs in non-release and RELEASE; full non-release `crystal spec --no-debug
--single-module --link-flags=-fuse-ld=ld --error-trace`; new W122 retained-stock
oracle and unchanged W116-W121 oracles, format, shell syntax and diff hygiene.
The stock oracle must use independently literal logical rows, real child marks
normalized from compressed/decompressed coordinates, full and nonzero-origin
windows, and production-encoded child/discriminator bytes+marks in isolated
copied parts with actual ATTACH/CHECK=1 and full/PK-selected semantic readback.
Wrong literal values, child counts, marks/bytes and CHECK=0 controls must be
observably rejected. Paired local roundtrip alone is insufficient.

Fail closed or narrow the evidence if retained stock profiles are different
from the admitted normalized profile; do not silently synthesize physical
marks from discriminator counts. Entire document assembly, general Object
layout, staged writer publication, remaining type families, MV/projections and
the final speed target remain open. Refresh on owner/API/profile/producer/
runtime/toolchain/coordinate/budget/comparator changes.

### Executed W122 evidence and replay (2026-10-02)

Root independently executed the final frozen owners/specs/oracle under the
same serial guard, 50% minimum-free-memory floor and pinned toolchain as W121.
Compiler: Crystal 1.21.0 / LLVM 22.1.8 / AArch64, SDK MacOSX26.5, TMPDIR
`/private/tmp`, isolated caches. Limits: 600 seconds; focused/oracle 8,192 MiB,
full suite 32,768 MiB. Source anchor is the separate shallow 31d2addb checkout;
runtime is the independently pinned 26.10.1.1201/d9bcb5ab build, not that HEAD.

Observed signals:

- Qualified missing-API REDs: undefined BinaryBulkStream, BinaryBulkProfile and
  DynamicValueCodec against independently authored lane/value tests. An earlier
  incorrectly ordered guard invocation (exit127) was not counted as a RED.
- Model checkpoint: two examples passed; this did not admit physical formats.
- Initial implementation compile RED exposed a Crystal suffix-assignment scope
  error in default construction; the regular-if repair was tested. Root's first
  runtime pass had two reference-identity assertions, an incorrect expected
  Dynamic selection exception, and a read-only String-slice mutation in the test
  itself. Only those test assumptions changed. The later >127-byte envelope
  control first reversed COMPACT count/format fields in its literal; correction
  follows the independently established W121 grammar, not a serializer change.
- Final focused DEBUG and RELEASE: 111 examples each, zero failures, errors or
  pending. This includes fixed nominal/raw widths, recursive roles, both String
  profiles, hidden NULL validation/defaults, empty/repeated marks, ownership,
  late selected corruption, unselected bad bodies and direction/domain checks.
- The exact aggregate read ledger for a Shared Bool plus NULL is 16 nodes,
  15 edges, 15 wire bytes; write is 14/12/15. Each minus-one axis rejects.
  A 128-byte typed String envelope after a pending Bool frame exercises the
  two-byte outer VarUInt: 144 total bytes passes; 143 rejects on read/write.
  Same-name Decimal32/Decimal64 values retain their nominal backing width and
  route the non-roster width to SharedVariant.
- Seeded removal of the decoder's final per-lane consumption check made the
  independent Array-cardinality test fail (one example, one failure: expected
  CorruptPartError but nothing raised). The original check was restored before
  all final positive gates.
- Full non-release suite with symbolic debug info disabled: 2,030 examples,
  zero failures/errors/pending; guard exit0 after approximately 176 seconds.
  The existing test-only deprecated `blocking` warning remains. Full RELEASE
  was not executed; focused RELEASE was.
- Final W122 stock oracle: both retained source/fresh-ATTACH profiles decoded
  every dynamic path over full and nonzero-origin marks1..2. Four isolated
  copied parts (dynamic_paths and typed_mixed, each BASIC/COMPACT) replaced
  production discriminator and every ordinary/shared child stream plus its
  real physical marks. Every copy passed actual ATTACH and exact CHECK=1,
  independently literal full and PK3..6 semantic readback, inventory/schema,
  unchanged metadata, exact mode-dependent discriminator bytes/marks and
  unchanged child bytes/marks. Selected counts come from W121 schedules, not
  adaptive physical mark row fields.
- The first W122 stock attempt rejected typed_mixed's unordered shared-path
  statistics because the new oracle incorrectly demanded sorted literal bytes.
  No production code changed. The repaired comparator uses W116's existing
  independently authored complete-statistics semantic check and additionally
  requires byte equality with the independently qualified retained fresh-ATTACH
  stream. Wrong Object-statistic, byte, value, count, mark and CHECK=0 controls
  reject. These are comparator controls, not stock-server corrupted-part tests.
- Unchanged W116-W121 stock regressions all exited0. W116 still qualifies the
  public whole-JSON refusal; W117/W119 qualify their own typed scalar vectors,
  W118 its own MAP lanes, and W120/W121 their own isolated authored copies.
  None widens W122 to every physical shape merely by passing.
- Final exact-path Crystal format check, W122 shell syntax and diff hygiene
  exited0. The root-owned seed is restored; no scratch, generated part, cache
  or downloaded runtime is included in the repository change.

Core replay commands, wrapped serially in the existing `run_safe.sh` guard:

```sh
crystal spec spec/binary_value_codec_w117_spec.cr spec/object_shared_map_w118_spec.cr \
  spec/binary_parameter_owners_w119_spec.cr spec/binary_scalar_types_w119_spec.cr \
  spec/object_dynamic_structure_w120_spec.cr spec/object_dynamic_structure_w120_budget_spec.cr \
  spec/dynamic_discriminator_w121_spec.cr spec/dynamic_discriminator_w121_budget_spec.cr \
  spec/*w122*_spec.cr --single-module --link-flags=-fuse-ld=ld --error-trace
# Repeat this focused command with --release.
crystal spec --no-debug --single-module --link-flags=-fuse-ld=ld --error-trace
W115_CAPTURE_ROOT=/private/tmp/crystal-click-json-w115.6qs6Kq \
  CLICKHOUSE_BIN=/private/tmp/crystal-click-w112-runtime.u0Jn1f/clickhouse \
  CRYSTAL_BIN=/opt/homebrew/bin/crystal W122_KEEP_TMP=1 \
  bash scripts/check_dynamic_values_w122.sh
```

Run unchanged `check_json_w116.sh`, `check_binary_w117.sh`,
`check_object_shared_map_w118.sh`, `check_binary_w119.sh`,
`check_object_dynamic_structure_w120.sh`, and
`check_dynamic_discriminator_w121.sh` under the same guard/environment.
Format all changed Crystal files, `bash -n scripts/check_dynamic_values_w122.sh`
and `git diff --check` are the hygiene gates; these cannot replace runtime tests.

Logs: `/private/tmp/crystal-click-w122-root.zfnNGq/`: missing-API REDs,
`models-checkpoint.log`, `bulk-focused-debug.log`, `focused-debug-first.log`,
`focused-debug-repaired.log`, `focused-debug-budget.log`,
`seed-cardinality-red.log`, `focused-debug-final.log` (literal correction RED),
`focused-debug-final-restored.log`, `focused-release-final.log`,
`full-debug-no-symbols.log`, `stock-w122.log` (statistics-order comparator RED),
`stock-w122-repaired.log` (positive), `regression-w116.log` through
`regression-w121.log`, `format-check-final.log`. Final retained W122 store:
`/private/tmp/crystal-click-json-w122.mqUlrW`; cache:
`/private/tmp/crystal-click-json-w122-cache.Pv71UP`. Temporary evidence can decay;
refresh from the independent literals and a qualified W115 capture if absent.

Final stock oracle SHA-256:
`2323939f5b770ce8c36c60d99568ae170cf704340a38db86d52a30abccd04ffd`
(`check_dynamic_values_w122.cr`),
`84f3195e6308c73c0421a346c218ce21714cd6c1cf35978e9469aa756dd426d3`
(`check_dynamic_values_w122.sh`),
`8bbc2685b2f9ff3d970ac24d0f3904f9fe456312c1aa782feb81e6b4839f9119`
(`w122_bulk_vectors.cr`). Git supplies the exact owner/spec lineage and rollback.

Luna's static adversary result is correlated, not independent runtime evidence.
Root's scoped verdict is ROBUST for the declared normalized codec and captured
stock profiles, backed by owned literals, boundary tests, the restored guard
seed and real stock copies. Residuals: borrowed slices are publicly mutable by
convention; caller-owned detached construction is outside budgets; hidden NULL
bytes are normalized rather than losslessly preserved; pending frame reservation
is a bounded logical allowance rather than an allocation/RSS certificate.
No general Object/JSON document, arbitrary Dynamic/LC/Variant nested kernel,
public part-writer, all physical serializer profiles, MV/projection or speed
claim follows.

Active return pointer: bind typed paths, Dynamic lanes and shared-MAP rows into
bounded Object document assembly, then pair compressed physical adapters and
staged writer integration. Next falsifier: mixed typed/dynamic/shared documents
over a nonzero-origin window with a malformed last selected path; reject before
publishing any document. One budget must span metadata, paths, discriminators,
children, shared envelopes and document assembly. MAP_WITH_BUCKETS and advanced
shared layouts need their own paired stock gates rather than a MAP alias.
Remaining recursive/type families and MV/projection coverage precede memory
and throughput optimization. The overall goal is active, not completed or
blocked. Owner/API/profile/runtime/toolchain/coordinate/budget/comparator
changes reopen dependent evidence.

## W123 design seal: flattened Object documents over paired MAP lanes

Risk: CAUTION (serialization and a new logical API). Rollback: the clean W122
commit `3bcdefc`; no existing facade routing, declaration admission, source
checkout or retained fixture is modified. This slice composes existing owners
rather than extending the legacy WidePart/WidePartWriter monoliths.

Source anchor: shallow source `31d2addbabda0d8e14ffd325fc0a9106528aa1c7`.
`ColumnObject.cpp:294-322` returns flattened path/value fields: every typed
path, non-null Dynamic paths and decoded shared envelopes. Missing and NULL
Dynamic values are intentionally indistinguishable. `SerializationObject.cpp:
1130-1166` reads all three lanes and checks consistent row counts, then repairs
some Dynamic/shared duplicates. W123 does not implement that repair policy.
`SerializationObjectSharedData.cpp:45,133-143` delegates to the shared type's
default serializer. Its `serialization_map` variable is not its nominal type:
`DataTypeObject.cpp:900-905` specifies `Array(Tuple(paths String, values String))`.
String values contain the binary nominal-type/value envelopes, not JSON text.
`SerializationObjectSharedData.cpp:48` selects default serialization independently
of the settings propagated to typed/Dynamic paths (`DataTypeObject.cpp:189-193`).
The retained stock shared lanes are single-stream Strings even where Dynamic
String children use WITH_SIZE_STREAM. A uniform Object-wide String profile is
therefore refuted by the exact retained inventory; it is not a codec alias.
JSON textual
dot expansion/escaping belongs to `SerializationJSON`, not this storage API.

Admitted:

- `ObjectDocument` owns detached raw String path identities and nominal
  `BinaryValue` fields. Paths are byte-sorted for traversal; empty paths,
  embedded NUL, invalid UTF-8 and `a`/`a.b` remain distinct identities. This is
  a flattened storage document, not a JSON::Any tree or JSON text parser.
- `ObjectDocumentPlan` binds supplied Object/Dynamic metadata to an exact,
  disjoint typed schema. `ObjectDocumentStreams` owns that metadata, exact
  typed and Dynamic lane sets, shared bulk MAP and the full outer row grid.
  Metadata constructors are detached input ownership, not a budgeted decoder.
- Paired `ObjectDocumentCodec.encode/decode`, with additive `*_with_budget`
  plumbing, compose one operation budget through metadata, descriptor trees,
  path/grid records, typed bulks, Dynamic discriminators/arms, shared envelopes
  and final document assembly. No reset per mark/path/child. W118 remains
  unchanged; marked shared MAP uses W122 bulk named-Tuple Array. `profile:`
  selects typed/Dynamic String layout; separate `shared_profile:` defaults to
  single-stream and explicitly selects shared layout. An abstract WITH_SIZE
  shared profile is not claimed to match the retained stock producer.
- Encoding requires every typed field, including a typed Nullable NULL, with
  exact nominal descriptor equality. It does not synthesize missing typed
  defaults or cast values. Every supplied Dynamic/non-typed Nothing NULL is
  normalized to absence. Missing Dynamic values become discriminator NULL.
  Non-typed top-level Nullable is outside the canonical profile, as in W122.
- Object V3, one MAP bucket and Dynamic V3 only in this composition slice.
  Metadata statistics are supplied/preserved, not recomputed or proved by this
  codec. The eventual staged writer must own fresh metadata/statistics.
- Every structural grid and exact lane roster is checked, even for an empty
  selected window. Full outer row counts must agree with every Dynamic mark.
  Only selected bodies are decoded; unselected body bytes are not certified.
  Every selected child and shared envelope is validated before documents are
  returned. Shared paths must be strictly byte-sorted and cannot equal any
  typed or Dynamic roster path, even where the Dynamic value is NULL.
- Writer argument/unsupported failures and malformed-reader failures remain
  explicit. Invalid selection arguments are rejected before indexing. Output
  is an all-or-error returned value, not incremental callbacks/publication.
- Raw-byte Dynamic path membership must not repeatedly traverse/copy the full
  roster for every typed or shared field. Reuse the immutable Object roster's
  retained uniqueness index through one non-copying predicate; constructors
  remain detached input ownership. A pinned allocation guard must distinguish
  this from the prior quadratic name-copying route. This closes a resource-work
  guard, not the parked throughput/performance frontier.

Rejected/not admitted: legacy Object/Dynamic versions in this orchestrator,
bucketed/advanced shared data, implicit duplicate repair, JSON textual rendering
or parsing, escaping/collapsing dots, schema inference, default synthesis,
LC/Variant/Object nested into the W117 descriptor kernel, compressed-file
adapter, public whole-JSON facade admission and staged part publication.
No full-JSON, all-type, MV/projection or speed claim follows.

Plan / ownership:

1. Root: independent missing-API RED and mixed literal/window falsifier before
   production changes; living frontier and root-only serial compiler/stock/Git.
2. Luna models/tests: one file each for ObjectDocument, ObjectDocumentPlan,
   ObjectDocumentStreams; bounded adversary specs. No compiler/stock processes.
3. Luna codec: ObjectDocumentCodec plus a small shared-envelope owner if useful;
   additive borrowed-budget seams in ObjectDynamicStructureCodec. Reuse W122
   typed/Dynamic/bulk work. Shared pending envelopes must be bounded before
   retaining framed String copies; charge final wire bytes exactly once.
4. Luna stock source/oracle: independently authored documents/streams from the
   retained W115/W116 literals, full and nonzero-origin reads, production-
   authored JSON lanes copied only into fresh isolated parts; exact actual
   ATTACH, CHECK=1 and full/pk3..6 stock queries, both discriminator modes.
5. Root: inspect diff, hostile guards/seed, focused debug/release, full nonrelease
   suite, stock gate and unchanged W122 regression; exact format/diff hygiene,
   evidence seal and atomic local commit. No push or performance work.

Strongest likely failure: valid child streams disagree about outer rows/path
ownership, or a late invalid envelope is silently discarded. First falsifier:
mixed typed/dynamic/shared literals over marks 1..2 with a malformed final shared
value; no documents returned. Guards also attack duplicate ownership, a wrong
last Dynamic row count on an empty window, trailing bytes, aggregate byte/node/
edge limits across individually valid children, descriptor validation before
recursive name/default work, and String profile mismatch. Local round trips
cannot substitute for independent literal or real stock gates.

DoD: guarded focused W117-W123 specs in debug and release, guarded full
`crystal spec --no-debug --single-module --link-flags=-fuse-ld=ld --error-trace`,
new W123 stock oracle and unchanged W122 stock oracle, formatter/shell syntax/
`git diff --check`, proportionate hostile verdict and an exact atomic commit.
Expected signals: zero failures/errors, explicit stock CHECK=1 and literal full/
selected results. Source/runtime/profile/owner/budget/comparator changes reopen
the corresponding certificate. Temporary evidence must be regenerated if lost.

### Executed W123 evidence and continuation (2026-10-02)

Root executed the gates on the frozen additive diff over `3bcdefc`, with
Crystal 1.21.0/LLVM 22.1.8, the SDK and serial resource guard used by W122.
The 50% free-memory floor was unchanged; no worker ran compiler/stock processes.
The five new owners and two additive metadata/predicate seams are indexed in
`MODULARIZATION_FRONTIER.md`. This is a logical document certificate, not a
completed compressed-part adapter or staged writer.

- Qualified missing-API REDs named ObjectDocumentPlan and ObjectDocumentCodec.
  Independent root literals mix typed UInt64, Dynamic String/NULL and shared
  Bool/Int64 over three marks, including a nonzero-origin window and a malformed
  final shared envelope. Exact aggregate read-byte limits are 113 full / 91
  selected; minus-one limits reject. BASIC writer bytes and grids match those
  independent literals, not just its own decoder.
- Three root guard REDs exposed a late outer-grid budget check, zero-row real
  Object marks and misclassification of a recognized unsupported shared profile.
  Removing the restored two-line full-grid budget admission caused exactly one
  targeted failure; restoration passed the final gates. K=0 remains admitted.
- The bounded same-lineage hostile review found repeated quadratic Dynamic
  roster scans/name copies. Root's qualified allocation RED measured 32,102,384
  bytes for a 1,000-by-1,000 typed/Dynamic plan. The existing immutable roster
  uniqueness set is now retained and queried without copies; the pinned guard
  passes below 2 MiB. Exact raw-byte identities and input/getter detachment pass.
  This is a Crystal/Boehm allocation discriminator, not RSS or throughput evidence.
- Final focused W117-W123 DEBUG and RELEASE each passed 131 examples; full
  non-release `spec --no-debug` passed 2,050. All had zero failures/errors/pending.
  Full RELEASE was not executed. The full run retains the existing duplicate
  lib-c linker warning and deprecated blocking-argument warning in W113's spec.
- Final W123 stock gate directly decoded both source and attached retained
  parts for both captured profiles. Four fresh isolated copied parts (two
  profiles x BASIC/COMPACT) replaced every JSON metadata/value lane with
  production-authored streams. Each passed actual ATTACH/CHECK=1, independent
  bytes/grids, manifest/schema checks and full/pk3..6 semantic readback.
  PK and other table/part sidecars are borrowed; this is not a whole-part writer.
  Object-wide uniform String layout was refuted, not weakened into an alias:
  typed/Dynamic Strings use WITH_SIZE_STREAM, shared Strings use default layout.
- Wrong-byte/statistic/outer-row/CHECK=0 comparator controls passed. These
  instrument controls are not claims that ClickHouse rejected malformed parts.
  The unchanged W122 oracle also passed both retained roles and all four
  authored ATTACH/CHECK=1/full/selected cases. Crystal format, shell syntax and
  diff hygiene passed; the five legacy part/table/catalog facades are unchanged.

Replay: use the sixteen focused W117-W122 spec paths plus the three new paths
`spec/object_documents_w123_root_spec.cr`,
`spec/object_documents_w123_adversary_spec.cr`,
`spec/object_documents_w123_spec.cr`; the exact root invocations are retained
in this chat's command evidence.
Invoke Crystal through the serial guard with DEBUG / `--release`, isolated
caches, `--single-module --link-flags=-fuse-ld=ld --error-trace`, guard 600/8192.
Full suite: the same command with `spec --no-debug`, guard 600/32768.
For stock replay use W122's environment, `W123_KEEP_TMP=1` and
`scripts/check_object_documents_w123.sh`; then unchanged W122 with its flag.
Source/runtime identities at the top are separate: this runtime was not built
from the shallow source SHA. Keep the retained W115 source store quiescent.

Root logs: `/private/tmp/crystal-click-w123-root.vdfkpL`; isolated cache root:
`/private/tmp/crystal-click-w123-cache.chjRUy`. W123 retained store/cache:
`/private/tmp/crystal-click-json-w123.nN6bb6` /
`/private/tmp/crystal-click-json-w123-cache.fWhH1m`. W122 regression store/cache:
`/private/tmp/crystal-click-json-w122.vxVoXa` /
`/private/tmp/crystal-click-json-w122-cache.FUMQPC`.
Final log SHA-256 identities, relative to the root log directory:

- `focused-debug-final.log`: `b22530ce1d5758036586b0fee9b6f48cb59fd9614b94febc7ec725125b4d4d18`
- `focused-release-final.log`: `71e533d3d51da36f62be86fab3f7737e5ecb53b55b266cbb4681d1ac36dd0153`
- `full-nonrelease-final.log`: `ffe2aa96882365368398c15d30c72063e88399a9cd085cfd5d181f743f2b4375`
- `stock-w123-final.log`: `8def8d617ebc52141e0a0e8382e0a6d0b4b5db0d3ab259b44cc2f7dfec80fc82`
- `regression-w122-final.log`: `4e2fcc245c56cfd202a85cecd3017d9bbfb5ca5816032034887edf8486862c2c`

Root scoped adversary verdict: ROBUST for executed default-bounded normalized
document laws and the two captured producer profiles. Independent literals,
source inspection, seeded guard and actual stock execution supplement Luna's
correlated implementation/review. No all-types, all JSON layouts, fresh-master
executable, public part writer, allocator/RSS, raised-limit stack or speed claim.
Borrowed slices retain their internal read-only convention; detached model
construction/getters are not an operation-budget/RSS guarantee. Supplied
metadata statistics are preserved, not synthesized or validated against rows.

Continuation: the overall all-types/MV/projection/performance goal remains
active. Next frontier is paired compressed physical adapters and fresh
metadata/staged publication; first falsifier is library-owned full/nonzero-window
part I/O without borrowing already serialized JSON lanes or statistics.
Bucketed/advanced/legacy Object, remaining recursive type compositions and
MV/projection coverage remain open. Large-facade extraction is also unfinished.
No performance work or push is authorized by this checkpoint. Owner/profile,
producer/build, toolchain, budget, comparator or relevant source changes reopen
this certificate; lost temporary artifacts require replay, not citation alone.

## W124 design seal: paired compressed mark transport (2026-10-02)

Status: design-sealed over `80ab0c2`. Risk: CAUTION (file-format transport and
mapping lifetime). Rollback: only the new transport owners/imports/specs/oracle
and these two living frontier documents. Legacy part facades remain unchanged.
W123 assembles normalized documents but its oracle still acquires lanes using
whole-file decompression. This transport removes that prerequisite; it does not
replace the pending metadata/schema/path-binding and staged-publication work.

Source anchors at shallow `31d2addbabda0d8e14ffd325fc0a9106528aa1c7`:
`MergeTreeDataPartWriterWide.cpp:466-476` writes compressed offset, in-frame
offset and adaptive outer rows; `:508-511` obtains the two byte coordinates;
`:847-865` writes serialization suffixes before the final mark.
`SerializationVariant.cpp:199-212` writes the eight-byte discriminator mode
prefix before row values. W116 independently pins repeated empty-arm marks and
metadata prefix/suffix marks. Row fields never infer arm occurrences or bytes.

Admitted implementation target:

- Explicit `.bin` and plain adaptive `.mrk2` paths and expected file sizes.
  A complete K+1 grid ends in rows=0; every real mark has positive outer rows
  within Int32. Repeated lane positions are legal, including all-empty lanes.
  Compressed marks, non-adaptive marks and missing terminal inference remain
  rejected. Whole-24-byte-record input is interpreted as the requested plain
  grid; header-shaped row-count bytes do not authorize a format switch.
  Non-grid-sized compressed candidates are recognized with bounded header
  work and rejected. Ambiguous/divisible malformed content is rejected by
  complete plain-grid validation, not claimed to be perfectly format-detected.
  This is not automatic part/profile discovery.
- Reader maps one bounded regular, non-symlink file at a time using the
  existing callback-scoped MMapDataSource. Empty `.bin` is valid only when the
  complete grid is at (0,0) and prefix size is zero. No mapping/workspace slice
  may escape the operation. Returned windows own their bytes and grids.
  A zero-domain grid (only its terminal) requires exact empty data. The unpaired
  `read_all`/`encode_all` operations reject empty input because they have no grid
  to certify the empty lane; an empty requested window over real marks is valid.
- Whole-stream header indexing establishes real frame boundaries, sizes and
  absolute logical positions without decompressing unselected frames. Validate
  every mark, even for an empty selection: exact first (0,prefix), monotonic
  absolute positions and terminal at true logical EOF. Both last-frame-end and
  physical-EOF coordinates denote the same terminal. Frame-end/next-frame-zero
  aliases are compared in logical coordinates, never by unrelated lane counts.
  Real marks may also name physical EOF when an arm's last occurrence precedes
  the remaining outer granules. Wide.cpp:502-512 flushes before mark capture;
  :646-676 records that position with positive outer rows, while Variant.cpp
  :326-339,377-382,406-411,512-517 invokes zero-occurrence arm serializers.
- Only frames intersecting the prefix or selected body are checksum-verified
  and decompressed. An end coordinate at the next frame's zero does not touch
  that frame. An unselected payload checksum is not whole-file integrity proof.
  Existing LZ4/ZSTD/Multiple decoder profiles remain the method authority;
  unknown methods are unsupported, malformed headers/checksums are corrupt.
- A selected window retains original first-mark identity, selected outer rows,
  prefix bytes and local Kselected+1 offsets starting at prefix size. No fake
  complete-part grid or arm-count synthesis. The parent creates local W123
  streams and preserves caller window identity separately. Metadata streams
  have a bounded all-bytes reader because their suffix is globally required.
- Paired writer takes exact raw bytes, K+1 offsets and K outer row counts,
  with explicit prefix size. It produces owned literal-LZ4 `.bin` and plain
  `.mrk2` bytes, framing independently of marks. Terminal is canonical physical
  EOF. Empty lanes, repeated marks and frame crossings are preserved; no files
  are published. The selected frame size must contain the complete prefix in
  frame zero. The first real mark remains (0,prefix), even for a prefix-only
  lane, while the terminal uses canonical physical EOF. Metadata prefix/suffix
  semantics remain the caller's authority.
- A direction-checked CompressedStreamBudget is shared across all lanes of an
  operation, not reset per role. It bounds aggregate file bytes, mark/header
  records, decoded-frame work and retained results separately. Preflight known
  counts and sizes before allocating grids, mappings or decode workspaces;
  reserve each touched frame once, including prefix/body overlap, before any
  selected decode. These are logical transport bounds, not allocator/RSS or
  live-filesystem snapshot guarantees. Expected sizes do not prevent same-size
  concurrent mutation; admitted input is a quiescent trusted part tree.
  The admitted Multiple(Delta width=8/skip=0, ZSTD) chain also preflights its
  visible nested ZSTD header: intermediate output must equal final output plus
  the nine-byte Delta header and two parameter bytes. Decoded work includes
  both intermediate and final output, preventing a small outer size from
  authorizing a larger hidden workspace. Other nested codec lists are unsupported.

Production API/ownership (one concrete owner per file under `src/crystal_click`):
CompressedStreamLimits, CompressedStreamBudget, CompressedFrameDescriptor,
CompressedFrameIndex, CompressedMarkWindow, CompressedMarkFiles,
CompressedMarkReader and CompressedMarkWriter. Public entry points:

```
CompressedMarkReader.read(data_path, marks_path,
  expected_data_size: Int64, expected_mark_size: Int64,
  first_mark: Int = 0, mark_count: Int? = nil, prefix_size: Int = 0,
  budget: CompressedStreamBudget = <read budget>) -> CompressedMarkWindow
CompressedMarkReader.read_all(path, expected_size: Int64,
  budget: CompressedStreamBudget = <read budget>) -> Bytes
CompressedMarkWriter.encode(bytes, offsets, rows_per_mark,
  prefix_size: Int = 0, frame_bytes: Int = 4096,
  budget: CompressedStreamBudget = <write budget>) -> CompressedMarkFiles
CompressedMarkWriter.encode_all(bytes, frame_bytes: Int = 4096,
  budget: CompressedStreamBudget = <write budget>) -> Bytes
```

Limits default to file bytes 256 MiB, mark bytes 64 MiB, compressed/decompressed
frame bytes 64 MiB each, aggregate records 1,000,000, decoded bytes 64 MiB and
result bytes 64 MiB. All constructor limits are nonnegative, supported size
domains are checked, and budgets are consumptive even on a failed operation.
Reader selection errors are ArgumentError; malformed transport is
CorruptPartError; recognized unadmitted formats/resource write limits are
UnsupportedFormatError. Wrong budget direction is ArgumentError.

Consumer inventory: `rg` over src/spec/scripts finds no current owner with
these eight names. New imports and W124 tests/oracle are the only consumers;
existing W123 APIs, String profile split, grammar and standalone budgets do
not change. Integration uses explicit existing W122/W123 role vectors, not
production-inferred source expectations.

Plan/falsifiers:

1. Root's independent missing-writer RED has executed: undefined
   CompressedMarkWriter, not an unrelated toolchain error. Add literal multi-
   frame/nonzero-window and corrupt-boundary controls before trusting roundtrip.
2. Luna implements the eight new transport owners; root owns imports and all
   compiler/stock processes. A separate Luna owns W124 specs/oracle. No worker
   runs compilers, stock binaries, Git writes or additional agents.
3. Guard full grids outside selection, equivalent frame boundaries, empty
   lanes, prefix/body overlap, selected-only decompression, terminal/trailing
   data, checksum corruption, detached result lifetime, expected size/symlink
   refusal and aggregate limits across multiple roles. Strongest failure:
   a mark points into a payload or a touched frame allocates before reservation.
4. Stock oracle composes W123 documents from production file-backed full and
   nonzero windows for retained profiles. Reframe every JSON lane with the
   production writer in fresh isolated copies and assert actual ATTACH/CHECK=1,
   independent raw bytes/marks and full/pk3..6 readback. Borrowed metadata
   statistics/sidecars are explicit; no fresh complete part writer claim.

DoD: serial guarded W117-W124 focused debug/release, guarded full non-release
spec suite, W124 stock oracle and unchanged W123 regression, exact-path Crystal
format, shell syntax and diff hygiene; root hostile review before atomic commit.
Use W123's pinned toolchain/runtime and unchanged 50% free-memory floor.
Do not promote all JSON layouts/types/MV/projections or performance from this
transport certificate. Next frontier remains library-owned physical bindings,
fresh Object/Dynamic statistics/schema metadata and staged whole-part writing.

### W124 executed certificate and continuation

Executed on October 2 over `80ab0c2`, with eight new production owners, eight
aggregate imports, two specs, one oracle/wrapper and the two living frontier
documents. The new owners total 1,099 lines (56/75/28/112/44/20/452/312 in the
API inventory order above); this is a navigation count, not a coupling or
performance measurement. No existing part/table/catalog facade was rerouted.
The design seal remains the admitted boundary, not an all-format certificate.

Root executed these gates on the finalized production source:

- Independent missing-writer RED: undefined `CompressedMarkWriter`, before
  production implementation. Root's literal multi-frame tests then detected
  three real contract defects: a valid plain mark grid with a header-shaped
  row count was misclassified as compressed; a short final frame was charged
  as an unused full frame; and a prefix-only first mark used physical EOF
  instead of `(0,prefix)`. Each was repaired and retained as a regression.
- Focused W117-W124 plus compression/mmap/checksum DEBUG and RELEASE:
  201 examples each, no failures/errors/pending. Final-source DEBUG was replayed
  after the independent oracle repair. The 31 new transport examples include
  22 root-authored cases with independent frame/mark literals.
- Full non-release: 2,081 examples, no failures/errors/pending, with
  `--no-debug --threads 1 --single-module`. Only symbolic debug information is
  disabled; non-release checks remain enabled. Full RELEASE was not executed.
  The first default multi-module run was stopped by the unchanged guard after
  its process-tree FD counter reached 4,025; it produced no test result. The
  successful replay retained the 50% free-memory floor and all guard limits.
  No foreign process was stopped or guard weakened. One pre-existing deprecated
  File argument warning remains in the full suite.
- W124 stock oracle: retained W115 source/fresh-ATTACH parts decode into exact
  independent flattened documents, for both full and nonzero mark windows.
  Four newly isolated part copies, `dynamic_paths`/`typed_mixed` times
  BASIC/COMPACT, have every JSON lane reframed by the production writer.
  Actual stock ATTACH, exact `CHECK TABLE` result=1, full reads and PK3..6
  semantic readback all passed. Independent frame walks and logical-coordinate
  mapping supplement roundtrips; wrong bytes, altered Object statistics,
  wrong frame offsets and CHECK=0 comparator controls all reject.
- The unchanged W123 oracle passed all four authored-stream copied-part
  ATTACH/CHECK=1 cases and retained-source document checks on this source state.
- Exact-path Crystal formatting, shell syntax and diff hygiene passed.

The stock gate initially failed because the oracle required canonical byte
ordering of retained Object shared-path statistics. Current source stores
those entries in `UnorderedMapWithMemoryTracking` (`ColumnObject.h:29`) and
iterates them unsorted (`SerializationObject.cpp:452-458`). The repaired oracle
uses W116's independent semantic roster/statistics parser only for retained
Object/Dynamic metadata; duplicate/trailing entries and altered values still
reject. Transport output must independently match the captured decompressed
bytes exactly. All scalar/data lanes and writer-authored canonical metadata
retain exact literal-byte checks. No production parser was loosened to satisfy
this oracle. Root also caught and repaired missing profile plumbing in that
oracle before the positive execution.

The runtime/toolchain identities are those recorded above: separate shallow
source `31d2addb`, pinned 26.10.1.1201 build `d9bcb5ab`, Crystal 1.21.0/LLVM
22.1.8 on AArch64 and MacOSX26.5 SDK. Stock execution is not a build of the
fresh reference checkout. Evidence is indexed under
`/private/tmp/crystal-click-w124-root.mg98sP`: `missing-api-red.log`,
`root-focused-types-fixed.log`, `transport-counterexamples.log`,
`transport-debug.log`, `focused-debug-final.log`, `focused-release.log`,
`full-nonrelease.log` (guard stop), `full-nonrelease-single.log`,
`stock-w124.log` (oracle RED), `stock-w124-final.log` and
`stock-w123-regression.log`. Final W124 part/cache roots are
`/private/tmp/crystal-click-json-w124.vyVOd1` and
`/private/tmp/crystal-click-json-w124-cache.mKEx1T`; unchanged W123 replay roots
are `/private/tmp/crystal-click-json-w123.2mIjTY` and
`/private/tmp/crystal-click-json-w123-cache.uEEUto`. Retained source input is
`/private/tmp/crystal-click-json-w115.6qs6Kq`. These temporary artifacts are an
evidence index, not durable proof if they disappear; replay the guarded specs
and `scripts/check_compressed_mark_transport_w124.sh` plus the unchanged
`scripts/check_object_documents_w123.sh` with the pinned identities.

Root's scoped hostile verdict is ROBUST for detached explicit-path transport,
complete-grid validation, selected-only checksum/decode and consumptive logical
limits within the declared codec profile. Independent literals, source anchors,
negative controls and executed stock cases supplement correlated Luna work.
Constructors/getter copies and jointly live document/transport allocations are
not an RSS certificate. Files must remain quiescent; expected sizes do not
defend against same-size concurrent mutation. Unselected payload hashes are
deliberately not verified. The writer emits literal LZ4, not a compression-ratio
or speed improvement. Sidecars/schema/count/statistics are borrowed in copied
part oracles, not freshly synthesized or published by a complete writer.

Continuation: the overall all-types/MV/projection goal remains active, with
performance parked. Next is library-owned type/path/role binding over these
physical adapters, then fresh Object/Dynamic metadata/statistics and staged
whole-part publication. First falsifier: a general library-owned full/nonzero
window without an oracle-authored role map, followed by fresh writer output
without borrowed statistics/sidecars. Legacy/bucketed/advanced shared layouts,
remaining recursive compositions, Compact parts, broader MV/projection support
and large-facade responsibility extraction remain open. Owner/profile,
coordinate/budget, producer/build, toolchain or comparator changes reopen this
certificate. No push or performance promotion follows from this checkpoint.

## W125 design seal: generic physical stream binding

Design-sealed on October 2 over `99b47d6`. The next admitted move removes
fixture-authored role maps from physical transport consumers, not from the
independent oracle expectations. Risk is CAUTION: a plausible-looking wrong
filename can silently select another lane. Rollback is the clean base commit;
the existing facades and W124 owners remain unchanged. No push is authorized.

### Source and contract

The source reference is `31d2addb` above. Root inspected
`ISerialization.cpp:302-457`, `SerializationDynamic.cpp:108-135`,
`SerializationVariant.cpp:124-169`, `DataTypeMap.cpp:120-140`,
`SerializationMap.cpp:652-671`, `DataTypeObject.cpp:900-904`, and
`escapeForFileName.cpp:8-30`. Luna's initial claim that Dynamic value arms
descend under `.dynamic_structure` was refuted by the push/pop sequence and
captured filenames; the corrected sibling placement is load-bearing.

Four concrete owners, each in its own production file:

- `physical_stream_name.cr`: bytewise uppercase percent escaping, bounded
  concatenation, and the existing `StreamName.hash` alias. It never unescapes a
  hashed name or guesses which filename representation a part selected.
- `physical_stream_plan_context.cr`: operation-local descriptor/edge/record/name
  bounds shared across the complete Object plan. This is a logical work/name
  bound, not an RSS guarantee or a budget for payload/transport/checksums.
- `binary_bulk_physical_plan.cr`: generic recursive descriptor and explicitly
  supplied String profile to exact logical-role/rendered-name bindings.
- `object_document_physical_plan.cr`: typed path, Dynamic structure/arm and
  shared-MAP bindings over an explicit `ObjectDocumentPlan`. No captured path
  or arm roster belongs in production.

`BinaryBulkPhysicalPlan.new(type, column_name, profile: ..., limits: ...)`
accepts a raw column name. `stream_names` returns a detached role-to-rendered-
basename Hash; `stream_name_for(role)`, `data_file_for(role, hashed: false)`
and `marks_file_for(role, hashed: false)` return detached names. An internal
shared-context factory takes an already escaped prefix for Object children.
It must validate that prefix rather than accepting filesystem separators.

`ObjectDocumentPhysicalPlan.new(column_name, plan, profile: ...,
shared_profile: ..., limits: ...)` supplies `object_structure_stream`,
`dynamic_structure_stream(path)`, `discriminator_stream(path)`, `typed(path)`,
`dynamic_arm(path, arm_name)`, `shared`, and a detached sorted `stream_names`
roster. Lookup failures do not guess an alternative. All logical names across
metadata, discriminators, typed, Dynamic and shared lanes must be unique;
collisions reject before a plan is returned. Input rosters are already detached
by the existing models; getter results cannot mutate retained bindings.
Completed plan getters do not depend on later consumption of their shared
construction context. Returned snapshots and fixed-extension filename copies
are outside the retained-binding byte counter, not an RSS certificate.

Naming preserves ArrayElements depth across Tuple/Nullable/Map descendants:
Array sizes are `.sizeN`, Nullable is `.null`, String sizes are `.size`, tuple
fields escape the entire `.<field>` (including its separator), unnamed fields
are one-based, BASIC Map fields are `keys`/`values`. Object paths escape only
their raw path after a literal separator; Variant arms escape their SQL type
name after a literal separator. Dynamic structure/discriminator/arms are
siblings. Shared MAP is the existing `Array(Tuple(paths String, values String))`,
not a generic Map substitution. Empty lane payloads do not erase their binding.

The profile fixes no shared Nested offsets, escaped Variant arms, stored lanes
only, non-specialized prefixes/suffixes, BASIC Map, Object V3 wire=4 with one
MAP bucket/shared version=0, and Dynamic V3. String profile is explicit and
uniform within each supplied recursive bulk plan; shared String profile is
separate. Serializer-version propagation/default selection is not inferred
from a SQL type. Existing descriptor admission is unchanged.

Bounds must walk descriptor depth/nodes and count-derived role collections
before allocating proportional rosters. Opaque column/path/field bytes and
percent expansion must be checked before constructing names. Dynamic type
display-name production needs a conservative metadata-aware size preflight
before recursive rendering. Charge actual retained role/rendered-name bytes
and logical records to the shared context; conservative temporary-name
preflights may reject otherwise valid inputs under unusually tiny limits.
The Object-wide context is consumptive and incremental: each contributing
descriptor/name/role collection is bounded before its own materialization.
A later invalid child can reject after bounded earlier children were built;
none are returned or published. This is not a whole-schema zero-allocation
rejection guarantee. Dynamic descriptor preview must stop at the remaining
node/element bound during traversal, not count an entire excessive tree first.
Caller/profile errors use ArgumentError, unsupported collisions/bounds use
UnsupportedFormatError. No model-constructor or getter-copy RSS claim follows.

Rejected: shared Nested offsets, bucketed Map/Object, legacy Object, advanced or
chunked shared layouts, automatic schema/serializer discovery, filename alias
auto-resolution, new recursive type admission, direct catalogue/facade routing,
whole-part integrity, fresh statistics/sidecars, staged publication and speed
claims. W124 selected windows do not expose complete source row grids; a future
Object file reader must solve cross-lane full-domain alignment explicitly rather
than treat selected rows as the full source domain. Structure marks include a
prefix-only repeated coordinate and statistics suffix before terminal EOF;
they are not ordinary value-lane windows.

### Execution and falsifiers

1. Root's missing-API RED is qualified at
   `/private/tmp/crystal-click-w125-root.0lO25q/missing-api-red-unsandboxed.log`:
   undefined `BinaryBulkPhysicalPlan`. The initial sandboxed attempt was stopped
   by process-group isolation, not by a test failure. Guard limits remain intact.
2. Luna implements the four owners; root owns aggregate imports, independent
   literal specs and resource-heavy commands. A second Luna owns a separate
   stock/capture oracle and supplementary specs. Neither runs a compiler/CH,
   mutates Git, changes unrelated files, or reverts another worker's edits.
3. Focused DEBUG/RELEASE: new plans plus W117-W124 specs, compression, mmap and
   checksums. Expect no failures/errors/pending. Literal expectations include
   nested Array(Tuple(Array(Nullable(String)))), BASIC Map, escaped raw bytes,
   unnamed fields, Dynamic sibling placement, empty arms, both String profiles,
   arbitrary non-fixture paths and multi-lane filename collisions.
4. The W125 oracle compares all derived bindings against the independently
   authored W116/W122 inventories; it uses the production bindings for complete
   full/nonzero-window Object assembly over retained stock parts and for all
   output lane placement in isolated copied-part ATTACH/CHECK=1/full+PK reads.
   Wrong-name/role/CHECK=0 controls must demonstrably reject. This remains a
   copied-sidecar oracle, not fresh whole-part output.
5. Replay the unchanged W124 stock oracle and full non-release suite under the
   unchanged 50% free-memory guard, one compiler/CH workload at a time, single
   module/thread for the full suite. Formatting, shell syntax and diff hygiene
   must pass before one exact-path atomic local commit.

The strongest failure modes are array-level reset, double escaping or a raw
dot treated as a separator, Dynamic metadata prefix leakage, profile inference,
and two distinct logical roles producing the same physical name. Exact literal
maps, complete independent retained inventories, non-fixture plans and seeded
comparator failures are the guard checks. A bounded naming certificate does not
close the subsequent complete file-backed reader or all-layout compatibility.

### W125 execution evidence and continuation

Implemented on October 2 over `99b47d6`, without changes to any W124 transport
owner or legacy part/table/catalog facade. Four new production owners total
775 lines (131/75/289/280 in the inventory order above). Root owns the 21 new
literal/negative examples and all compiler/stock/Git commands; Luna owns the
four production files and a separate stock oracle. Luna's static review is
correlated, not independent runtime evidence.

Executed on the finalized production source:

- Qualified missing-API RED: undefined `BinaryBulkPhysicalPlan`. The initial
  sandboxed resource-guard attempt returned 75 because process-group isolation
  was unavailable; it is not a test RED. The successful retry retained all
  limits, including the 50% free-memory floor.
- Focused W117-W125 plus compression/mmap/checksum DEBUG and RELEASE each
  passed 210 examples, with no failures/errors/pending. Root's 21 new examples
  cover exact recursive names, both String profiles, non-fixture Object paths,
  Dynamic metadata siblings, tuple/path collisions, missing lookups, empty
  Nothing lanes, raw percent versus structural syntax, detached mutable-byte
  snapshots, malformed escaped prefixes and aggregate/depth/metadata bounds.
- Four W125 stock copied-part cases (`dynamic_paths`/`typed_mixed` times BASIC/
  COMPACT discriminator encoding) passed actual ATTACH, exact `CHECK TABLE`=1,
  full and PK3..6 stock readback and production full/nonzero-window Object
  assembly. Here COMPACT names discriminator encoding, not Compact parts.
  Production W125 bindings choose every JSON lane's input/output filename;
  complete W116 inventories and W122 role maps independently qualify them
  before transport. Wrong-role, wrong-name and CHECK=0 controls all reject.
- The unchanged W124 stock oracle passed its four ATTACH/CHECK=1/readback
  cases on this source state.
- Full non-release passed 2,102 examples with no failures/errors/pending:
  `crystal spec --no-debug --threads 1 --single-module
  --link-flags=-fuse-ld=ld --error-trace` under the serial resource guard,
  timeout 600 seconds, memory limit 32,768 MiB and unchanged 50% free-memory
  floor. Symbolic debug information alone is disabled; non-release checks
  remain enabled. The guard returned exit 0 after approximately 186 seconds.
  One pre-existing deprecated File argument warning remains. Full RELEASE
  was not executed.
- Exact-path Crystal `tool format --check` over the four owners, aggregate
  import, new spec and oracle passed; shell syntax and final diff hygiene
  passed. No unrelated user changes, guard weakening or foreign-process
  termination was needed.

Root rejected a public prevalidated-prefix bypass during review; the final
factory accepts only validated escaped syntax through a private value token.
Descriptor preview now stops at the remaining shared node/element limit before
descending, rather than counting an excessive complete tree first. Opaque
Tuple fields and Object paths are measured through byte accessors before their
copies/percent expansions. Dynamic SQL-name bounds include fields, Enum labels
and timezones. Completed filename getters remain usable after their shared
construction context is fully consumed. These guards do not imply a whole-
schema zero-allocation rejection or model/getter RSS bound.

Two execution failures were not compatibility falsifiers: the first detached-
snapshot test attempted to mutate Crystal's read-only `String#to_slice` view;
root changed the test to mutate heap-backed `to_unsafe` bytes. The larger
focused build then exposed Crystal's definite-initialization requirement;
both constructors now explicitly assign the Hash returned by `build_bindings`.
All positive focused/stock gates above ran after these repairs.

Source, pinned stock runtime and toolchain identities remain those above:
separate shallow source `31d2addb`, stock 26.10.1.1201 build `d9bcb5ab`,
Crystal 1.21.0/LLVM 22.1.8/AArch64 and MacOSX26.5 SDK. Root replayed recursive
source comparisons of DataTypes, Columns and MergeTree between `0c68f01a`
and `31d2addb`; each returned exit 0 with no diff output. That is scoped source
continuity, not a freshly built current-master runtime certificate.

Temporary evidence index: `/private/tmp/crystal-click-w125-root.0lO25q`,
including `missing-api-red-unsandboxed.log`, `first-debug.log`,
`focused-debug.log`, `focused-debug-fixed.log`, `focused-release.log`,
`stock-w125.log`, `stock-w124-regression.log` and
`full-nonrelease-single.log`, with `format-check-final.log` for final formatting.
W125 retained part/cache roots are
`/private/tmp/crystal-click-json-w125.msh17X` and
`/private/tmp/crystal-click-json-w125-cache.E7OAmC`; W124 replay roots are
`/private/tmp/crystal-click-json-w124.vg7GqO` and
`/private/tmp/crystal-click-json-w124-cache.HSEVBB`. These pointers are an index,
not proof if temporary artifacts disappear. Replay focused specs, full
non-release specs and `scripts/check_physical_stream_plans_w125.sh` plus
the unchanged `scripts/check_compressed_mark_transport_w124.sh` under the
serial unchanged resource guard and pinned identities.

Root's scoped hostile verdict is ROBUST for the admitted raw/escaped naming,
recursive level/profile semantics, exact generic role binding, global Object
collision refusal and consumptive logical construction limits. Independent
literal expectations, current source anchors, seeded comparator failures and
executed stock cases supplement the correlated Luna review. The construction
budget is incremental and bounds logical descriptors/records plus charged
retained role/rendered-name bytes; it does not account for all lookup-key,
model-constructor, getter-copy or transient/RSS allocations. Late invalid
children may reject after earlier bounded plans were allocated, without
returning or publishing any partial plan. W124's quiescent-file and selected-
only checksum/decode boundaries remain unchanged. Oracle schema/statistics/
sidecars are borrowed in isolated copies, not freshly synthesized whole parts.

Continuation: the next boundary is a complete library-owned file-backed Object
reader, including metadata discovery and cross-lane full source-grid alignment.
W124 selected rows cannot stand in for that source grid. Structure lanes have
repeated prefix coordinates and a statistics suffix, not ordinary value marks.
Then synthesize fresh Object/Dynamic statistics/schema sidecars and stage a
whole part without borrowing those files. Legacy/bucketed/advanced JSON,
remaining recursive/type profiles, Compact parts, broader MV/projections and
large-facade extraction remain open. W125 does not change descriptor admission,
serializer defaults/propagation, alias auto-resolution, publication, whole-part
integrity, concurrent-mutation safety or performance. The overall goal remains
active and optimization parked. Changes to owner/API/imports, profile/naming/
budget semantics, source/runtime/toolchain or comparators reopen this evidence.

## W126 design seal: normalized Object file reader

Design-sealed on October 2 over `9e3ec4b`. Risk is CAUTION: fixture-derived
prefixes or selected row grids can conceal incorrect physical metadata and
unselected lane misalignment. Rollback is that clean commit; legacy facades
remain untouched. No push is authorized. Source is `31d2addb`; executable
qualification will use the separately pinned runtime above, not current master.

Admitted: an explicit Wide/SUFFIX, Object V3 wire=4, one-bucket MAP=0,
Dynamic V3 file reader, with caller-supplied raw column name, typed-path schema,
uniform explicit bulk String profile, separate shared String profile, and
explicit hashed/unhashed filename policy. Dynamic paths and alternatives come
from actual complete metadata files, never a fixture inventory. Ordinary bulk
lanes have zero prefix; Dynamic discriminators have an eight-byte mode prefix.
Full physical adaptive rows are outer rows, not sparse arm/Array child counts.
The existing selected discriminator schedules derive those child counts.

Source correction: `SerializationObject.cpp:431-483` and
`SerializationDynamic.cpp:270-321` put the V3 statistics flag in the suffix for
SUFFIX mode. The physical metadata prefix ends BEFORE that flag. PREFIX and
PREFIX_EMPTY put it in the prefix and are not admitted here. Root inspected
the decisive source branches; this supersedes the rejected after-flag offset
hypothesis before implementation. All real metadata marks must point to the
parser-measured before-flag offset; terminal marks point to complete logical
EOF including statistics. Every metadata/value/discriminator lane must have
the same complete outer row grid, even for a zero-length selection.

Owners, one class/module per file:

- `compressed_mark_grid.cr`: detached complete rows/logical positions and
  prefix/EOF coordinates. `CompressedMarkReader.inspect` validates plain marks
  and compressed frame headers without decoding or authenticating payloads.
  It accepts an optional expected prefix, otherwise derives the first logical
  position through the validated frame index. Metadata prefixes can span
  frames; a nonzero first compressed offset and frame-end aliases are legal.
  Root independently inspected Wide writer SUFFIX selection at
  `MergeTreeDataPartWriterWide.cpp:560-578`, shared outer-row emission at
  `:457-475` and suffix-before-terminal ordering at `:851-864`. Existing `read` and
  `read_all` behavior is preserved.
- Existing Object/Dynamic structure codecs gain additive
  `read_with_statistics_offset(context)` returning the decoded complete model
  and relative before-flag offset. Existing `read_from` delegates unchanged.
- `part_stream_source.cr`: internal checksum-sized, explicit-alias stream
  resolution and physical acquisition. It owns its checksum snapshot; callers
  cannot mutate retained entries. Size validation is not a file-hash claim.
- `object_document_file_reader.cr`: metadata discovery, exact suffix/grid
  validation, generic W125 binding, selected W124 acquisition and W123
  composition. Public `read(part_path, column_name, typed_schema, first_mark:,
  mark_count:, profile:, shared_profile:, hashed:, limits:, transport_limits:)`
  returns owned documents grouped by selected granule, rebased locally.

Operation-local codec and transport budgets are consumptive. Discovery and
composition metadata parses, grid inspection and selected acquisition are all
charged even when work repeats. The complete source mark roster is bounded
before proportional collections; selected-only rows cannot replace that guard.
Existing `PartChecksums` has its own bounded parsing envelope, not a combined
operation/RSS budget. Filename/model/getter copies are not an RSS certificate.
Trusted quiescent directories are required; this is not a concurrent snapshot.
All metadata frame checksums and touched value-frame checksums are verified;
untouched value payload checksums and whole-file hashes are not.

Rejected/guard-only: PREFIX/PREFIX_EMPTY metadata, legacy/bucketed/advanced
Object layouts, Compact parts, compressed marks, schema/serializer default
inference, automatic alias resolution, fresh statistics/sidecars, publication,
active-set recovery, existing public facade/catalog routing and performance
claims. Descriptor admission remains W117-W125's admitted normalized grammar.
This slice is not the complete JSON or all-types goal.

Plan and DoD:

1. Root adds independent literal specs and executes the missing-API RED before
   production edits. Consumer inventory: `rg` over `src/crystal_click`, `spec`
   and `scripts` found existing structure callers in paired metadata codecs
   and W120 specs, transport callers in W124/W125 specs/oracles, and document
   consumers in W123-W125. Additive APIs avoid migrating those callers.
2. Luna owns transport/grid/metadata changes; another Luna owns resolver/reader;
   a third owns a separate stock oracle. Root owns imports, independent specs,
   docs, serial guarded compiler/CH commands and Git. Workers must not revert
   others' changes, run resource-heavy commands, write Git or spawn agents.
3. Focused DEBUG and RELEASE must pass. Falsifiers include exact suffix flag
   boundary, nonzero/zero selection, outside-window row mismatch, malformed
   terminal/metadata coordinates, empty sparse arms, arbitrary escaped names,
   explicit aliases, missing/size-mismatched/symlink files, budget exhaustion,
   detached lifetimes and selected-only checksum scope.
4. The new pinned stock oracle invokes the production file reader using only
   part path, raw column, typed schema and profiles. Independently authored
   expectations may qualify source bytes but must not assemble reader inputs.
   Full/nonzero/zero windows over both captured profiles and discriminator
   modes must match W123 documents. Replay unchanged W125 stock checks.
5. Full non-release suite, exact-path formatting, shell syntax and diff hygiene
   must pass under the unchanged serial 50%-free-memory guard before one exact
   atomic local commit. A scoped hostile review must attack full-domain
   alignment and metadata discovery before promoting this seal to VERIFIED.

## W126 execution certificate and continuation

Status: VERIFIED over `9e3ec4b` within the preceding design seal. Root executed
the final focused DEBUG/RELEASE, stock and full-suite DoD below and returned
ROBUST within this explicit profile. Correlated Luna static reviews are support,
not the basis for that verdict. No broader JSON admission or performance claim
follows.

The normalized reader now accepts a part directory, raw column name, explicit
typed-path schema, String profiles and filename policy. It discovers complete
Object/Dynamic metadata, checks all source outer-row grids and exact SUFFIX
boundaries, then acquires and decodes locally rebased selected streams. Complete
metadata frames and touched value frames are authenticated; untouched value
payloads and whole-file checksum hashes remain outside this certificate.
`CompressedMarkReader.inspect` is header/grid inspection, not payload integrity.
No old part/table/catalog facade is routed to the new reader.

Independent root falsifiers use literal-only LZ4 frames and raw adaptive records,
not a production writer round trip. They cover arbitrary escaped raw names,
explicit aliases, repeated metadata positions before the statistics flag,
multi-frame prefixes and equivalent frame-boundary coordinates, empty sparse
lanes with positive outer rows, selected/nonselected checksum scope, malformed
terminal/metadata coordinates, off-window row mismatches including zero
selection, missing/size-changed/symlink lanes, detached result lifetimes and
consumptive limits. Nineteen root examples supplement the unchanged 210-example
focused baseline. Three independent seeded guard checks are qualified REDs:

- Bypassing only the unhashed name preflight reached part lookup instead of
  rejecting the oversized basename; restoring the guard returns the intended
  early `UnsupportedFormatError`. The 4096-byte bound is the checksums parser's
  admitted basename bound, not an assertion about the host filesystem's
  `NAME_MAX`. A long logical column and typed path remain readable with short
  hashed basenames. Logical-name and physical-basename bounds are not identical.
- Bypassing only the source-roster charge let a 16-mark/zero-selection input
  with `max_elements: 15` reach missing value lookup instead of the intended
  codec element limit. An earlier three-mark probe also failed, but at the
  separate physical-plan limit; it was sharpened rather than treating that
  confounded error as the strongest discriminator.
- The original later-metadata mutation also made coordinates non-monotone;
  generic transport could reject it without exercising metadata validation.
  Root changed all subsequent real marks together, preserving monotonicity.
  Bypassing only the exact real-mark statistics-boundary check then accepted
  the corrupt later mark, producing the intended test failure. The first-mark
  after-flag case still exercises the separate prefix boundary. All production
  guards were restored before final focused and full-suite commands; the stock
  commands consumed the same restored production source.

Root repaired Crystal grammar/API errors found by compilation: optional-index
assignment, double block shorthand, abstract callback argument type and Hash
capacity constructor spelling. The literal tests initially compared value
object identity; observed matching type/payload bytes prompted semantic
`as_uint64`/`as_string` assertions. These failed compile/instrument checks are
not compatibility results. The original missing-API RED remains qualified.

Executed final-source gates:

- Focused DEBUG: 229 examples, zero failures/errors; focused RELEASE: the same
  229 examples, zero failures/errors.
- Unchanged W125 oracle: four fresh isolated copied-part ATTACH cases, actual
  asserted CHECK=1, complete and PK `3..6` stock document readback.
- W126 oracle: production file-reader full four-granule, middle two-granule and
  terminal zero windows over those same four fresh W125 stores; independent
  W123 document expectations and stock full/PK readback agree. Its seeded wrong
  document, regrouped granule and CHECK=0 comparators reject the intended faults.
  W126 itself reopens already attached stores; it does not claim another fresh
  ATTACH or fresh metadata publication. BASIC/COMPACT label discriminator
  encodings here, not MergeTree part layout: all four parts are Wide.
- Full non-release after the sharpened metadata falsifier: 2,121 examples,
  zero failures/errors/pending, symbolic debug information disabled. Its one
  existing deprecated `File.new` argument warning in W113 is unrelated to this
  slice. Exact nine-path Crystal formatting, wrapper shell syntax and diff
  hygiene passed. Full RELEASE was not run.

Evidence directory: `/private/tmp/crystal-click-w126-root.OnYJkD`. Final logs are
`focused-debug.log`, `focused-release.log`, `w125-stock-regression.log`,
`w126-stock-reader.log` and `full-nonrelease.log`. Qualified controls are
`missing-api-red.log`, `name-guard-seeded-red.log` and
`source-roster-k16-seeded-red.log` and `metadata-boundary-seeded-red.log`.
Historical failed frontend/comparator probes
and the confounded three-mark roster probe are retained separately. Fresh stock
stores are `/private/tmp/crystal-click-json-w125.sNifcC`, derived from retained
`/private/tmp/crystal-click-json-w115.6qs6Kq`. The W126 wrapper removes only its
own successful compiler cache; the root logs and W125 stores are retained.
Removing these temporary paths decays replay availability, not source coverage.

Replay uses the SDK, Crystal and pinned ClickHouse identities at the top of
this document. All compiler/runtime jobs are serial under
`COGNI_RUN_SAFE_MIN_FREE_PCT=50` and `RUN_SAFE_PASSTHROUGH_STDIO=1`, using
`/Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh`. Focused specs are
the W125 25-file roster plus `spec/object_file_reader_w126_root_spec.cr`, with
`--single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace`; RELEASE
adds `--release`. Full non-release uses `crystal spec --no-debug --threads 1
--single-module --link-flags=-fuse-ld=ld --error-trace`. Stock commands, each
through the same guard with `/bin/bash`, are:

```sh
W115_CAPTURE_ROOT=/private/tmp/crystal-click-json-w115.6qs6Kq \
  W125_KEEP_TMP=1 CRYSTAL_BIN=/opt/homebrew/bin/crystal \
  CLICKHOUSE_BIN=/private/tmp/crystal-click-w112-runtime.u0Jn1f/clickhouse \
  bash scripts/check_physical_stream_plans_w125.sh
W115_CAPTURE_ROOT=/private/tmp/crystal-click-json-w115.6qs6Kq \
  W125_OUTPUT_ROOT=/private/tmp/crystal-click-json-w125.sNifcC \
  CRYSTAL_BIN=/opt/homebrew/bin/crystal \
  CLICKHOUSE_BIN=/private/tmp/crystal-click-w112-runtime.u0Jn1f/clickhouse \
  bash scripts/check_object_file_reader_w126.sh
```

The full goal remains active, with optimization parked. The confirmed next
frontier is fresh paired Object/Dynamic statistics and schema-sidecar synthesis,
then normalized whole-part staging without borrowing source metadata. The next
discriminator must have stock CH ATTACH/CHECK=1/readback consume those fresh
outputs, and the W126 production reader independently consume them. Statistics
mode, descriptor/schema identity, String profile and filename policy remain
explicit. Legacy/bucketed/advanced JSON, other recursive/type profiles, Compact
parts, facade/catalog integration, broader MV/projections and the large-facade
refactor remain open. No full RELEASE, allocator/RSS, performance or current-
master executable claim is admitted. Changes to source/owners/imports, metadata
offsets, grid/budget/naming semantics, source/runtime/toolchain, oracle inputs or
comparators reopen the corresponding gates. Trusted quiescent part directories
remain a premise; no active-set or concurrent-mutation snapshot is established.

## W127 design seal: fresh document statistics and unpublished column files

Design-sealed on October 2 over `4632f59`. W126 discovers paired metadata and
reads normalized Wide JSON files; W123 still serializes caller-provided counts.
The next bounded move derives fresh counts from the explicit plan and documents
and composes every JSON file pair in production. This is CAUTION: wire formats,
metadata identity and aggregate budget ownership cross several owners. Rollback
is the parent revision; no source part or public catalog is mutated by the API.

Admitted contract:

- `ObjectDocumentStatistics.recompute(plan, granules, limits)` and
  `recompute_with_budget(plan, granules, budget)` return a fresh
  `ObjectDocumentPlan`. Explicit typed/path/type rosters are preserved; every
  preexisting statistic is ignored. No path/type admission or JSON text parsing
  is inferred. Object V3 wire version 4, shared MAP version 0, one bucket only.
- Object dynamic counts exclude absent fields and Nothing/NULL. Dynamic counts
  use canonical ordinary-plus-SharedVariant positions, exact descriptor routing
  as in the value encoder, and exclude NULL. Shared Dynamic type-name counts
  retain the first 256 distinct names; Object shared-path counts retain the first
  10,000 non-NULL unknown paths. Previously retained names continue counting
  after saturation. These are suffix/direct statistics, not merge top-K.
  Granule/row order and document raw-byte path order define encounter order.
- Traversal, descriptor metadata, path/type names and proportional counters are
  checked before corresponding copies or rendered SQL-name allocations. A
  single writing `BinaryCodecBudget` covers statistics and subsequent logical
  encoding. Repeated traversal is charged honestly, not called fused work.
- `ObjectDocumentColumnWriter.encode(column_name, plan, granules, mode:,
  profile:, shared_profile:, hashed:, frame_bytes:, limits:,
  transport_limits:)` returns an owned `ObjectDocumentColumnFiles`, exposing
  the fresh plan, physical bindings, complete filename roster and detached file
  bytes. It has no input part/filesystem source and performs no publication.
  It uses W125 role bindings and W123 value encoding, never fixture bindings.
- Complete Object/Dynamic metadata, discriminators, typed/ordinary/shared lanes
  receive K real adaptive marks plus terminal EOF. Every lane's row fields use
  outer document counts even for sparse alternatives. Metadata real marks repeat
  the exact position BEFORE the statistics flag; terminal includes all counts.
  Empty real granules and a zero-granule physical column are rejected.
- An explicit `CompressedMarkWriter.encode_metadata` accepts a prefix spanning
  frames and translates all real positions through the frame layout. Ordinary
  `encode` and its stricter frame-zero prefix grammar remain unchanged.
  One consumptive transport budget covers all file pairs. Profiles, naming and
  bounds remain explicit; no memory/performance improvement is claimed.

Source anchors in shallow `31d2addbabda0d8e14ffd325fc0a9106528aa1c7`:
`SerializationObject.cpp:927-997`, `ColumnObject.cpp:2160-2177`,
`SerializationDynamic.cpp:529-553,594-646`, `ColumnDynamic.cpp:1700-1722`,
`ColumnObject.h` (10,000 retained shared names), and `ColumnDynamic.h` (256).
The pinned oracle executable remains build `d9bcb5a`, not current master.

DoD: root literal statistics/grid/budget tests must first reject the old surface;
focused DEBUG/RELEASE and unchanged W123-W126 tests pass; a fresh stock-created
same-schema/rows Wide shell has EVERY JSON data/mark pair replaced by this
production writer, checksums regenerated, then actual ATTACH/CHECK=1, full and
PK-window stock readback, and W126 full/nonzero/zero-window reads agree with
independently authored documents/counts. Run the complete non-release suite
serially under the unchanged 50% free-memory guard. Hostile guards cover poisoned
old counts, descriptor-name collisions, cap continuation, multi-frame metadata,
sparse outer-row marks, aggregate limits and detached ownership.

Fresh shell schema/count/PK/index/column-statistics sidecars are borrowed from
that newly stock-created matching shell, not W115/W125 captures. Schema-sidecar
synthesis, automatic roster selection, whole-part staging/atomic publication,
catalog/facade integration, legacy/bucketed JSON, Compact parts, other profiles,
MV/projection execution and optimization remain open. A successful column oracle
does not imply those capabilities. Changes to routing, names, counts, profiles,
budgets, metadata marks, runtime/source/toolchain or comparators reopen this gate.

## W127 executed checkpoint (2026-10-02)

Status: VERIFIED within the unpublished-column contract above. Root's scoped
hostile verdict is ROBUST after the recorded budget-order failures were closed;
Luna static review is correlated supporting evidence, not independent proof.
The source parent is `4632f59`; the current shallow source and pinned runtime
identities at the top of this document remain distinct.

The production API now derives fresh Object/Dynamic counts from an explicit
plan and flattened documents, then emits every normalized JSON column file
pair. No preexisting statistics or fixture metadata is consumed. Metadata real
marks repeat the before-statistics position across compression frames; sparse
lanes retain outer document row counts. Statistics and logical encoding share
one consumptive budget; all compressed pairs share one transport budget.
Filename count is checked through the cached collision-checked scalar before
requesting a detached roster. Sizing and copy passes are charged separately.
These are logical work/retained-output bounds, not allocator or RSS guarantees.

Root authored thirteen independent literal/negative examples, supplemented by
six owned statistics/file-roster examples. They cover poisoned old counts,
same-SQL-name/different nominal descriptors, the first-256/first-10,000 caps
with retained-name continuation, early huge-name rejection, literal frame/mark
coordinates, sparse outer rows, detached output, aggregate budgets and filename
limits. Test discrimination was qualified, not inferred from a green run:

- `root-red.log`: missing statistics API, compiler exit 1. The original tee
  pipeline's outer shell status was zero; it is not the RED signal.
- `seed-nominal-route-final.log`: removing nominal descriptor equality fails
  the independent Decimal32/Decimal64 count expectation, not a compiler check.
- `seed-codec-budget-reset-latest.log`: resetting the codec ledger before
  logical encoding makes the aggregate-limit test fail with no expected error.
- `red-sizing-work.log`: a zero-node grid probe reaches the forbidden document
  getter before rejection. The sizing pass now admits and charges traversal.
- `red-file-roster.log`: a poisoned oversized scalar roster reaches the
  detached-name getter. The writer now checks cached count before that getter.
- `red-roster-sizing-work.log`: both zero-node and zero-element roster probes
  reach the forbidden size getter. Known sizing work is now admitted before
  either size loop, charged on visits, and followed by separate copy admission.

All injected production faults were restored before final gates. Review first
returned VULNERABLE on uncharged sizing and late roster checks; the extra
roster-size challenge found the same defect in a second traversal after an
initial scoped ROBUST review. The corrected ordering passes the literal probes
and the final shared-budget test. Model agreement alone did not close the gate.

Two oracle comparator errors were repaired, not attributed to production:
later discriminator marks need not repeat the first prefix coordinate, and
the short typed-mixed Object prefix need not cross a frame. The final instrument
derives the exact Object pre-statistics coordinate independently from its
authored raw path roster and fixed literal-frame layout, including frame-zero
and cross-frame cases. The root literal EOF expectation was corrected from
76 to 77 bytes: a full 16-byte literal frame is 43 bytes, the final 8-byte frame
34. Historical failed frontend/comparator probes are not compatibility passes.

Final-source gates, executed by root:

- Focused DEBUG and RELEASE: 248 examples each, zero failures/errors/pending.
- W127 fresh shell oracle: four isolated dynamic-paths/typed-mixed ×
  BASIC/COMPACT-discriminator cases. EVERY JSON `.bin`/`.mrk2` pair is from
  the production writer; fresh matching schema/count/PK/index/column-statistics
  sidecars remain borrowed. Checksums are regenerated, stock ATTACH succeeds,
  the actual CHECK result is asserted as 1, and full plus PK `3..6` stock
  documents agree with independent expectations. W126 separately agrees on
  full, nonzero-origin middle and terminal-zero windows over all four stores.
  Wrong-document, wrong-grid and CHECK=0 controls reject their intended faults.
  All parts are Wide; BASIC/COMPACT are discriminator encodings, not part layout.
- Unchanged W125 oracle: four fresh copied-part ATTACH/actual CHECK=1/full+PK
  cases. Unchanged W126 oracle: reader full/middle/zero windows over those same
  newly generated stores plus stock CHECK=1/full/PK readback.
- Full non-release: 2,140 examples, zero failures/errors/pending, symbolic
  debug information disabled. The unchanged W113 deprecated `File.new`
  argument warning and the linker's duplicate `-lc` warning remain.
  Neither is a test failure. No full RELEASE run or performance result.
- Exact nineteen-path Crystal format, wrapper shell syntax and diff hygiene
  pass. No source fixture, installed server store or public facade is mutated.

Evidence root: `/private/tmp/crystal-click-w127-root.rjYfTn`. Final logs are
`focused-debug.log`, `focused-release.log`, `stock-w127.log`,
`w125-stock-final.log`, `w126-stock-final.log`, and `full-nonrelease.log`.
Final W127 stores: `/private/tmp/crystal-click-json-w127.qzUcHw`.
Final W125 regression stores: `/private/tmp/crystal-click-json-w125.x0Xq8A`,
derived from `/private/tmp/crystal-click-json-w115.6qs6Kq`.
An earlier 2,138-example full run preceded the last roster fix; its tail briefly
overlapped a short RED probe due to a scheduling error. It is retained as
`full-nonrelease-before-roster-fix.log`, not final evidence. All final compiler/
runtime commands were strictly serial under the unchanged 50% free-memory
floor. Removing the temporary roots decays replay availability.

Replay uses Crystal 1.21.0/LLVM 22.1.8, the SDK and pinned CH binary above,
`COGNI_RUN_SAFE_MIN_FREE_PCT=50`, `RUN_SAFE_PASSTHROUGH_STDIO=1`, and the
same `cogni-ml/scripts/run_safe.sh`. Compiler guard limits are 600s/32768 MiB;
stock wrappers use 900s/32768 MiB with `/bin/bash` as guarded executable.
Focused specs are the W126 26-file roster plus
`spec/object_column_writer_w127_root_spec.cr`,
`spec/object_statistics_w127_spec.cr`, and
`spec/object_column_writer_w127_spec.cr`, with
`--single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace`.
RELEASE adds `--release`; full non-release adds `--no-debug` instead.
Stock replay, each separately through that same parent guard:

```sh
W127_KEEP_TMP=1 CRYSTAL_BIN=/opt/homebrew/bin/crystal \
  CLICKHOUSE_BIN=/private/tmp/crystal-click-w112-runtime.u0Jn1f/clickhouse \
  bash scripts/check_object_column_writer_w127.sh
W115_CAPTURE_ROOT=/private/tmp/crystal-click-json-w115.6qs6Kq \
  W125_KEEP_TMP=1 CRYSTAL_BIN=/opt/homebrew/bin/crystal \
  CLICKHOUSE_BIN=/private/tmp/crystal-click-w112-runtime.u0Jn1f/clickhouse \
  bash scripts/check_physical_stream_plans_w125.sh
W115_CAPTURE_ROOT=/private/tmp/crystal-click-json-w115.6qs6Kq \
  W125_OUTPUT_ROOT=/private/tmp/crystal-click-json-w125.x0Xq8A \
  CRYSTAL_BIN=/opt/homebrew/bin/crystal \
  CLICKHOUSE_BIN=/private/tmp/crystal-click-w112-runtime.u0Jn1f/clickhouse \
  bash scripts/check_object_file_reader_w126.sh
```

The whole goal remains active with optimization parked. Confirmed next:
schema-sidecar synthesis and normalized whole-part staging without borrowed
metadata, followed by the public facade/catalog boundary. Its next falsifier
must stock-ATTACH/CHECK=1/read both the fresh metadata and data, and independently
read them through W126. Automatic path/type roster selection, legacy/bucketed/
advanced JSON, Compact parts, other recursive/type profiles, broader MV/
projection execution and the legacy-facade refactor remain open. No all-type,
full JSON-facade, current-master executable, allocator/RSS or speed claim is
admitted. Source/owner/import, routing/count/name/profile/budget/mark, toolchain,
runtime/source or oracle-input/comparator changes reopen the dependent gate.
Trusted quiescent input directories remain a premise, not an active-set or
concurrent-mutation snapshot certificate.

## W128: library-owned normalized whole parts

Design-sealed and verified on 2026-10-02 over `9d87293`, within the bounded
contract and executed certificate below. This is not full JSON compatibility.
The missing boundary is complete part construction, not another column codec.
No source part path, stock sidecar, captured bytes or stock-generated key stream
is an input to this writer or its positive whole-part oracle.

The bounded surface is an immutable, unpartitioned Wide part containing a
nondecreasing UInt64 key and one normalized Object V3/SUFFIX, Dynamic V3,
one-bucket MAP column. It uses hashed filenames, plain adaptive marks, LZ4,
uniform outer granules (a short final granule is legal), and an explicit schema
and descriptor roster. BASIC and COMPACT discriminator encodings are not
Compact *parts*. `ObjectDocumentSchema` owns declared capacities and detached
typed fields; this first whole-part schema admits UInt64/String typed fields
only. It checks exact nominal typed-schema agreement and dynamic path/type
capacities before encoding. Automatic roster inference, SKIP clauses, arbitrary
typed declarations, partition expressions, compound keys and server lifecycle
integration remain rejected or outside this API.

The additive `WidePartWriter.write_uint64_object_pair` facade delegates to a
cohesive private `ObjectPartWriter`. `ObjectPartMetadata` composes columns,
substreams, count, codec, metadata version and serialization metadata from
owned inputs. Existing shared key/index/checksum/publication owners are reused.
Metadata version is explicit (default zero), not borrowed from a stock table.
The ordinary bulk String profile binds the persisted String serialization
version: SINGLE_STREAM is zero and WITH_SIZE_STREAM is one, propagated to
nested ordinary serializers. Whole-part shared MAP is fixed to SINGLE_STREAM;
an explicit WITH_SIZE_STREAM shared profile is rejected before encoding or
staging. The column-only W127 transport has a wider profile selector, which
does not imply stock-compatible whole-part admission.
The checksum readback uses one aggregate read-direction transport budget after
the column encoder's separate aggregate write-direction budget; these are
phase-specific logical bounds, not a single RSS ceiling.
Stock optimizer statistics (`statistics.packed` / `statistics_*.stats`) are
deliberately omitted; Object/Dynamic suffix statistics are still freshly
recomputed by W127 and are not the same capability.

Source anchors at `101871ba6da8221c7cf30ac3a04bc1063106f412`:
`MergedBlockOutputStream.cpp:407-499` emits count, persisted serialization
info, optional optimizer statistics and plain metadata/checksums;
`ColumnsSubstreams.cpp:207-224` defines the text grammar;
`MergeTreeDataPartWriterOnDisk.cpp:716-737` and `ISerialization.cpp:441-457`
persist escaped physical substream names, not decoded dotted logical paths;
`MergeTreeDataPartWriterWide.cpp:882` and `MergeTreeWriterStream.cpp:331-349`
retain compressed/raw checksum metadata even for an empty data lane;
`DataTypeObject.cpp:240-305` renders capacities and sorted typed paths;
`DataTypeString.cpp:38` and `SerializationString.cpp:286-327` bind persisted
String serialization settings to the physical stream profile;
`SerializationObjectSharedData.cpp:43-48` constructs MAP with its independent
default serialization (SINGLE_STREAM), not ordinary nested String settings;
`IMergeTreeDataPart.cpp:1297-1320,1393-1404,1434-1441` admits the no-optimizer-
statistics path. Wide substream metadata can be tolerated/ignored by stock,
and CHECK does not establish serialization counters or PK semantics: independent
expectations are mandatory, not an ATTACH/CHECK-only completion claim.

Risk: CAUTION (new file-format publication surface). Rollback: revert the one
W128 feature commit, retaining `9d87293` and the W127 column API. Most likely
failure: internally consistent bytes/checksums attach while schema, roster,
row grid, defaults or primary index disagree with the authored input.
Guard: literal/model-derived metadata, complete inventory, PK/index and mark
checks, with seeded metadata/counter/index defects proving sensitivity.
Preflight failures must leave no staging directory, and publication must not
replace an existing file, directory or dangling symlink. No power-loss or
concurrent-input snapshot guarantee is added.

Execution plan / ownership:

1. Root: missing-API RED and independent
   `spec/object_part_writer_w128_root_spec.cr`; imports, facade wiring and
   frontier/status evidence. Root alone executes serial resource-guarded gates.
2. Luna schema/metadata: `src/crystal_click/object_document_schema.cr`,
   `src/crystal_click/wide_part_writer/object_part_metadata.cr` and
   `spec/object_document_schema_w128_spec.cr`; no shared facade/import edits.
3. Luna writer: `src/crystal_click/wide_part_writer/object_part_writer.cr` and
   `spec/object_part_writer_w128_spec.cr`; no shared facade/import edits.
4. Luna oracle: `scripts/check_object_part_writer_w128.cr` and `.sh`; empty
   stock target tables only, fresh production whole parts, no shell copying.

Declared DoD: missing API RED; focused DEBUG and RELEASE specs; complete
non-release suite; pinned `26.10.1.1201` actual ATTACH/CHECK=1/full/PK-window
SQL plus W126 full/middle/terminal-zero reads on dynamic-paths and typed-mixed
documents in both discriminator modes. A library-generated nonempty part must
have an exact planned file set with no optimizer statistics; every sidecar and
key/JSON pair must be generated from library-owned inputs. Independent tests
must detect wrong count, substream roster, serialization counters and primary
index even when stock would tolerate them. An additional single-stream typed
String part tests empty,
embedded-NUL and UTF-8 values, zero keys and a short final granule against stock.
The newest source checkout is a grammar reference, not the qualified runtime
build. Full public table/catalog
Object dispatch remains the next separately qualified boundary.

### W128 executed bounded certificate

Root, not a worker, ran all compiler and ClickHouse jobs strictly serially
under the unchanged 50% free-memory guard. The pinned runtime is
`/private/tmp/crystal-click-w112-runtime.u0Jn1f/clickhouse`, version
`26.10.1.1201`, build `d9bcb5ab007f0f6299f7f973f2642245bab3d028`, executable
SHA-256 `bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
The newer shallow source revision `101871ba6da8221c7cf30ac3a04bc1063106f412`
is a grammar reference, not this runtime's build revision.

Observed signals on the frozen production inputs:

- Initial qualified missing-API RED: the independent root spec could not
  resolve `ObjectDocumentSchema` before implementation.
- Focused DEBUG and RELEASE: 55 examples each, zero failures/errors/pending.
  Independent root cases cover literal columns/substreams/inventory/index,
  zero-key default counters, embedded NUL, a shared Dynamic type spill,
  short final granules, nested shared values, untyped Nothing NULL normalized
  to absence, schema ownership and preflight rejection without residue.
  Existing destinations and dangling symlinks are preserved.
- Full non-release: 2,163 examples, zero failures/errors/pending, symbolic
  debug information disabled. The unchanged W113 deprecated blocking-argument
  and duplicate `-lc` linker warnings remain; no full RELEASE result is claimed.
- Final `scripts/check_object_part_writer_w128.sh`: five new isolated parts,
  four dynamic-paths/typed-mixed cases in BASIC and COMPACT discriminator modes
  and one typed-String SINGLE_STREAM case. Every pre-ATTACH file, key and JSON
  stream is generated by the library. Stock creates only an empty target
  table: no INSERT, captured part, copied shell or borrowed sidecar.
  Actual ATTACH and CHECK=1, exact full/PK SQL and W126 full/middle/terminal-zero
  reads pass in all five cases. All parts are Wide.
- Independent authored expectations validate complete file inventory,
  columns/substreams, count, exact key defaults/rows and String version,
  primary-index bytes, every lane's raw bytes and complete mark grid. A separate
  v4 checksum-envelope parser checks recorded raw hash/size, including empty
  compressed lanes. Deliberately poisoned input statistics are recomputed.
  Wrong count, inventory/substream roster, default/row counters, String version,
  primary index, document/grid and CHECK=0 controls reject through the same
  positive predicates. ATTACH success alone is not the metadata certificate.
- Standalone `examples/write_object_document_part.cr` passed: three authored
  documents in two granules, including shared `extra.flag`, a Dynamic spill
  and an absent path, read back through the explicit file reader.
- Ten exact Crystal paths pass formatting; wrapper shell syntax and
  `git diff --check` pass. No installed server store, source fixture or other
  public type/facade admission is changed.

The first root focused run had test-expectation defects, not a production
RED: the literal expected shared paths/values used unescaped dots, and the
ownership attack attempted mutation through a read-only `String#to_slice`.
The corrected expectation matches the fresh stock source; an explicit unsafe
pointer attack tests detached ownership without treating String mutation as
a supported API. Earlier stock-oracle compile attempts exposed a nested-tuple
macro parse and unsupported `delete_prefix`/`delete_suffix` methods. These
oracle-only errors were corrected and the entire stock gate rerun after
formatting; neither failed attempt is a runtime compatibility certificate.

Replay toolchain: Crystal 1.21.0 / LLVM 22.1.8, macOS AArch64,
`SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`,
`TMPDIR=/private/tmp`. Set `COGNI_RUN_SAFE_MIN_FREE_PCT=50` and
`RUN_SAFE_PASSTHROUGH_STDIO=1`; use
`/Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh` as the serial
parent guard, 600s/32768 MiB for Crystal and 900s/32768 MiB for stock wrappers.
Focused inputs under `spec/` are:

```text
object_document_schema_w128_spec.cr
object_part_writer_w128_spec.cr
object_part_writer_w128_root_spec.cr
object_column_writer_w127_spec.cr
object_column_writer_w127_root_spec.cr
object_statistics_w127_spec.cr
object_file_reader_w126_root_spec.cr
```

Run `crystal spec` with those inputs and
`--single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace`;
RELEASE adds `--release`. Full non-release uses the full suite with those
flags and `--no-debug`. Stock replay, through the separate serial parent guard:

```sh
W128_KEEP_TMP=1 CRYSTAL_BIN=/opt/homebrew/bin/crystal \
  CLICKHOUSE_BIN=/private/tmp/crystal-click-w112-runtime.u0Jn1f/clickhouse \
  bash scripts/check_object_part_writer_w128.sh
```

Root evidence: `/private/tmp/crystal-click-w128-root.QWqhcy`, logs `red.log`,
`focused-debug.log`, `focused-release.log`, `full-nonrelease.log`,
`stock-w128-final.log`, `example.log` and `format-final.log`.
Failed oracle attempts remain separately named `stock-w128.log` and
`stock-w128-attempt2.log`; `stock-w128-attempt3.log` is the successful
pre-format run. The final isolated stock store root is recorded in
`stock-w128-final.log`; removing temporary roots decays replay availability.

Root adversary verdict: ROBUST within the declared explicit normalized
profile, supported by independently authored metadata/bytes, falsifier
predicates and actual stock reads, not Luna agreement. Public Object table/
catalog integration, automatic roster discovery, more typed schemas,
bucketed/advanced or legacy layouts, Compact parts, partitions/compound keys,
server lifecycle, concurrent-input snapshots and power-loss durability remain
open. No all-type, current-master executable, full RELEASE, allocator/RSS or
speed claim follows. Refresh affected gates after owner/import, schema/roster,
name/profile/default/count/mark/budget, oracle comparator/input, toolchain,
source/runtime or publication-policy changes. Optimization stays parked and
the whole goal remains active; the next capability falsifier is explicit
public table/catalog dispatch without silent layout or schema widening.

## W129: normalized Object catalog materialization (2026-10-02)

Status: VERIFIED only within the sealed profile and executed certificate below;
no runtime certificate is inherited from W128.
This admitted slice makes `catalog[db][table][column].values` consume
normalized Object documents. Mixed `WidePartTable` typed batches/windows and
PK candidate delivery are the following separately qualified adapter boundary.
The full all-types, MV/projection and eventual stock-speed objective remains
active; this slice does not replace it.

Admitted: the W128 schema subset (UInt64/String typed paths, declared Dynamic
capacities, canonical ASCII dotted/quoted paths), normalized hashed Wide
Object V3/Dynamic V3, one shared MAP bucket, LZ4, plain adaptive marks,
ordinary String versions 0/1 and independent shared SINGLE_STREAM Strings.
The new schema parser canonicalizes option order but rejects duplicate options
or raw paths, unknown options, SKIP clauses and other typed declarations.
The old scalar JSON virtual-path grammar remains unchanged.
Both the existing writer schema constructor and the new parser enforce the
stock maximum of 1,000 typed paths, independently of caller codec limits.
That declaration ceiling does not waive the existing codec/transport limits.

`ObjectDocumentFileReader.inspect` must share the existing metadata and
complete physical-grid validation, without payload-window reads or document
decode. An immutable descriptor exposes its plan, row count and detached grid
and stream-name copies. A separate `ObjectColumnReader` binds actual part
declarations, count, selected substream roster, codec and serialization profile
to a supplied schema; it applies schema capacity checks even for an empty
selection. The catalog parses its own DDL and opens every candidate before
allocating the result. Returned documents own immutable recursive values.
Retained rows, bytes, recursive cells and String payload have aggregate bounds
across marks and parts. Limits are logical-work/construction bounds, not RSS.
Each complete decoded mark is measured and admitted atomically before any of
its documents are appended to the retained result. A failed admission leaves
all budget counters unchanged. The aggregate logical peak combines retained
owners with an accounted reader workspace; it is not an allocation-before-
decode guard, a decoder-transient heap ceiling or a process-memory limit.
Reader/codec limits still apply independently while decoding the current mark.
Recognized selected hashed `.cmrk2` marks are explicitly unsupported, without
fallback; a missing admitted `.mrk2` file remains corruption. Compressed marks
on unrelated columns do not choose the selected Object profile.

Rejected: unqualified JSON schemas/layouts, Compact parts, advanced/bucketed
shared data, implicit stream/profile fallback, server Active-state claims,
concurrent-input snapshots and stronger checksum/hash claims. Inputs must be
quiescent. Per-mark reads may repeat metadata/grid parsing; optimization stays
parked. No decoding of unrelated scalar payloads or PK inference is admitted.

Risk: CAUTION (shared reader refactor plus catalog admission). Rollback is the
clean `1c5bab4` checkpoint plus the exact-path atomic feature commit; no user
changes, source checkout or installed data store are modified. Likeliest
failure: schema/profile/capacity or a later part's grid is trusted rather than
checked, or per-mark budget resets admit an oversized retained result.

Plan and ownership:

1. Root: qualified missing-API RED, independent root specs, exact imports,
   thin catalog dispatch/closed value union and evidence/status updates.
2. Luna reader: shared preflight in `object_document_file_reader.cr`, new
   descriptor and `object_column_reader.cr` owners plus reader specs.
3. Luna catalog: separate `object_document_schema_parser.cr`, thin schema
   factory, `offline_table/object_values_materializer.cr` and catalog specs.
4. Luna oracle: `scripts/check_object_catalog_w129.{cr,sh}` and small example;
   fresh isolated stock/library data only. Root alone runs heavy jobs serially.

Consumer inventory: `rg` over `ObjectDocumentFileReader`, `OfflineColumnValue`,
`materialize_selected_values` and JSON schema helpers identified the explicit
file-reader callers, the catalog's single materialization entry, closed value
union and old virtual-path dispatcher. No general WidePart type admission is
widened by this slice.

DoD: focused DEBUG/RELEASE specs (including existing W126-W128 readers/writers),
full non-release suite, actual pinned stock CHECK=1/read interoperability in
fresh isolated roots, exact-path format, shell syntax and `git diff --check`.
Guards: malformed/duplicate/unknown schema; semantic DDL/part disagreement;
count, selected roster, profile and capacity mismatch; corrupted later-part
grid; inspect without payload decode; retained ownership and aggregate
cross-mark/cross-part String/cell/byte budget. Empty tables must validate DDL,
not silently return an empty unsupported result. Root hostile review must
test the strongest applicable counterexamples before a scoped VERIFIED claim.

### W129 executed bounded certificate

Lineage: final W129 source over clean W128 checkpoint `1c5bab4`, with frozen
Luna production/oracle changes independently inspected and exercised by root.
All heavy jobs ran serially under
`/Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh`, with the 50%
free-memory preflight and a 32,768 MiB process-tree ceiling. Crystal jobs used
600-second timeouts; fresh stock wrappers used 900 seconds. Crystal 1.21.0,
LLVM 22.1.8, AArch64, SDK MacOSX26.5, `--single-module --threads 1` and the
system linker were used. No production input or existing ClickHouse checkout
was modified.

Root evidence directory: `/private/tmp/crystal-click-w129-root.7pIM6S`.
Fresh W129 stock/library/catalog root:
`/private/tmp/crystal-click-object-catalog-w129.9IgpCQ`.
Fresh W128 regression root: `/private/tmp/crystal-click-json-w128.C3SsNn`.
These temporary roots were deliberately retained as local evidence, not
committed fixtures or durable availability guarantees.

The source reference is the separate clean depth-1 checkout
`/Users/sergey/SrcArchives/clickhouse-2026-10-02-depth1-101871ba`, revision
`101871ba6da8221c7cf30ac3a04bc1063106f412`. The runtime oracle is separately
pinned to ClickHouse 26.10.1.1201, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, Mach-O SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
The source checkout is not that executable's provenance and no executable
from current master has been built or qualified.

Root observed:

- The initial missing-API probe failed at `parse_declaration`, before any new
  catalog capability claim (`red.log`). Later root tests qualified two actual
  typed-path-ceiling failures: constructor and parser accepted 1,001 fields
  while the 1,000-field positives passed (`typed-path-limit-red.log`). The
  shared constructor and parser now both enforce the stock ceiling, even
  with larger caller codec limits. An independent read-only stock CAST probe
  accepted exactly 1,000 typed fields and rejected 1,001 with Code 36 and the
  stock maximum message (`stock-typed-paths-gate.log` and its two child logs).
  Source anchors are `DataTypeObject.h:20` and `DataTypeObject.cpp:874-875`.
- A separate root pending-mark admission probe failed to compile because
  `charge_documents` did not exist (`batch-admission-red.log`). Final code
  measures the complete pending mark and commits counters only after all
  limits pass. Root tests cover failed aggregate owner/workspace admission,
  unchanged counters and a valid smaller retry, plus UInt64-overflow and
  one-shot base-reservation controls.
- Final focused DEBUG passed 86 examples (`focused-debug-final-2.log`),
  covering all ten Object W126-W129 spec files listed below. Final focused
  RELEASE added the complete offline catalog file and passed 133 examples
  (`focused-release-final.log`). The separate legacy compressed-mark test
  also passed. The earlier `focused-debug-final.log` ran only one example:
  a `:line` filter on one input applied globally. It is not the 86-example
  certificate; root reran the complete unfiltered inputs.
- Final full non-release suite passed 2,194 examples, zero failures/errors/
  pending (`full-nonrelease-final.log`, `--no-debug`). This is not full RELEASE.
  The initial full run exposed the valid compressed `.cmrk2` legacy fixture,
  not incomplete Object metadata. The final guard rejects that selected
  profile explicitly as unsupported. Scalar virtual-path reads and dotted-
  name ambiguity remain unchanged; a missing admitted plain `.mrk2` file is
  separately tested as corruption.
- Eight fresh bidirectional cases passed (`stock-w129-final.log`): native
  INSERT and fully library-created parts, each across ordinary String 0/1
  and BASIC/COMPACT discriminator serialization. Every case has seven rows
  with mark grid `[2, 2, 2, 1]`, typed UInt64/String, Dynamic Int64 and shared
  String/Int64/Bool spill values, including NUL and UTF-8. Actual stock
  CHECK TABLE returned the exact successful part row, full SQL and `k` 3..6
  SQL matched semantic documents and typed String bytes, and library parts
  were actually ATTACHed. Production `ObjectColumnReader` full/middle/zero
  selections and synthetic Atomic catalog `.values` matched those independent
  expectations. Altered count, capacities, ordinary String profile, physical
  row grid and catalog DDL were rejected as `CorruptPartError`; detached-byte
  mutation controls did not alter rematerialized results.
- The new example passed against the retained native catalog and printed
  seven owned documents with raw leaf type/hex diagnostics
  (`example-w129-final.log`). It reads an existing catalog; it creates no table.
- The unchanged W128 writer oracle created five fresh fully library-owned
  parts and passed actual stock ATTACH/CHECK=1/full/PK SQL and production
  reader full/middle/zero checks (`stock-w128-regression-final.log`). The
  unchanged W126 program also passed four retained-stock profiles and its
  wrong-document, wrong-grid and CHECK=0 comparator controls
  (`stock-w126-regression-final.log`). That latter gate is retained-part
  reader evidence, not a fresh publication certificate.
- Exact-path Crystal format checks, shell syntax and `git diff --check`
  passed. The compiler emitted the existing deprecated `File.new` argument
  warning in a staged-stream spec and duplicate-libc linker warning; there
  were no compilation or test failures in the final gates.

Executed spec inputs and replay commands (run serially with the guard and
environment above; `CRYSTAL_BIN=/opt/homebrew/bin/crystal`,
`CLICKHOUSE_BIN=/private/tmp/crystal-click-w112-runtime.u0Jn1f/clickhouse`):

```sh
crystal spec --single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace \
  spec/object_catalog_w129_root_spec.cr spec/object_catalog_w129_spec.cr \
  spec/object_column_reader_w129_spec.cr spec/object_file_reader_w126_root_spec.cr \
  spec/object_column_writer_w127_root_spec.cr spec/object_column_writer_w127_spec.cr \
  spec/object_statistics_w127_spec.cr spec/object_document_schema_w128_spec.cr \
  spec/object_part_writer_w128_spec.cr spec/object_part_writer_w128_root_spec.cr
# RELEASE used these ten files plus the whole spec/offline_catalog_spec.cr.
crystal spec --no-debug --single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace
W129_KEEP_TMP=1 bash scripts/check_object_catalog_w129.sh
W128_KEEP_TMP=1 bash scripts/check_object_part_writer_w128.sh
W126_W115_CAPTURE_ROOT=/private/tmp/crystal-click-json-w115.6qs6Kq \
W126_W125_OUTPUT_ROOT=/private/tmp/crystal-click-json-w125.msh17X \
  crystal run --single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace \
  scripts/check_object_file_reader_w126.cr
crystal run --single-module --threads 1 --link-flags=-fuse-ld=ld \
  examples/read_object_catalog.cr -- \
  /private/tmp/crystal-click-object-catalog-w129.9IgpCQ/catalog/stock_single_stream_basic \
  lab events payload
bash -n scripts/check_object_catalog_w129.sh
git diff --check
```

Root's scoped hostile-review verdict: ROBUST for normalized Object catalog
admission and the explicit logical retention policy. The strongest attacks
were later-part grid/capacity drift, cross-part String-budget reset, partially
charged pending marks, empty-table unsupported schemas, same-byte-size unknown
String versions, selected compressed marks, missing plain marks and false
payload-authentication claims. Each relevant refusal or bounded positive has
an executed test; whole-part interoperability uses actual stock CHECK/read
output, not model agreement. Luna's static adversary review found no remaining
blocking delta under this scope; it is correlated review, not a separate
runtime certificate.

Residual limits: quiescent source required; no server Active-state proof,
hash authentication, concurrent snapshot, arbitrary JSON typed declarations,
advanced/bucketed/legacy Object layouts, Compact parts, mixed table delivery,
general MV/projection closure, complete facade decomposition, allocator/RSS,
pre-decode transient-memory ceiling or throughput result. Complete-mark
measurement occurs after that mark is decoded. Selected compressed marks are
a guarded missing capability, not implemented support.

This certificate decays on schema/parser/roster/default/profile/count/grid,
transport, budget accounting, imports/dispatch, oracle comparator, toolchain,
runtime/source or publication-policy changes. Rerun affected positive and
negative gates before reuse; fail closed rather than inferring compatibility.
The next capability falsifier is mixed normalized Object/scalar typed-batch
delivery with windows and bounded UInt64 PK pruning. The all-types/MV/
projection objective remains active and optimization stays parked.

## W130 mixed Object table delivery — bounded verified profile

Source anchor: clean W129 checkpoint `2097a88`. Root's qualified initial
probe opens a library-owned three-row `pk UInt64, payload JSON(...)` part
through `WidePartTable.open_selected_typed`; it reaches the selected-column
admission guard and raises `UnsupportedFormatError`. This is the capability
gap, not an unexplained compiler failure. Evidence:
`/private/tmp/crystal-click-w130-root.hIaVRq/red.log`.

Admitted surface under the executed certificate below:

- Base Wide tables containing selected literal normalized Object roots,
  alone or mixed with existing selected typed columns. More than one selected
  Object root is supported without cross-wiring schemas or documents.
- The exact W129 UInt64/String declaration and physical-layout profile;
  no new JSON declaration, wrapper, serializer or transport is implied.
- Full typed batches, exact physical-row windows in caller part order, and
  explicit whole candidate granules. `object_documents_for(column)` returns
  callback-scoped slices of immutable owned document handles; retaining a
  document handle is valid, retaining the borrowed slice is not promised.
- Offline table typed scans/windows bind canonical whole-Object schemas to
  catalog DDL. UInt64 PK candidates admit the existing UInt64/QBit selections
  plus these literal Object roots, still requiring the key and an exact
  application residual predicate. This does not add arbitrary typed PK
  selections or change old scalar virtual-path identity rules.

Design laws and rejected surface:

- Every selected reader, part count, schema, checksum roster and full physical
  mark grid is validated before any callback. Count and per-mark alignment,
  caller part/column order, provenance and zero-length bounds remain exact.
  Skipped window/candidate payloads are not decoded; metadata remains eager.
- Current-mark logical admission is shared across all selected variable-sized
  column owners. Object preflight may charge only a conservative handle-array
  minimum; complete decoded pending document ownership must be charged
  atomically before any callback. Never charge the descriptor's whole-part
  `logical_read_bytes` as a current-mark requirement or reset the shared
  budget per Object column. This is not a decoder-workspace, allocator, RSS,
  pre-decode transient-memory or caller-retention ceiling.
- Exact Object selection uses `ObjectColumnReader`, not a permissive scalar
  reader fallback. Scalar-key-only reads must not start semantically parsing
  unrelated Object declarations. Canonical Object comparison must not weaken
  existing literal scalar or virtual typed-path binding.
- Whole-Object projection child delivery remains explicitly rejected until
  separately stock-qualified. Existing non-Object projection behavior is
  unchanged. Other W129 unsupported JSON layouts and compressed marks remain
  rejected; no new Active-state, snapshot, payload-hash, MV, performance or
  general table-writer claim is made.

Risk: CAUTION (public typed dispatch, ownership and aggregate admission).
Rollback: one local atomic commit; before committing, discard only known W130
edits if the gates fail, preserving all unrelated work. No remote mutation.

Implementation ownership:

1. Table owner: `wide_part_table.cr`, a cohesive
   `wide_part_table/object_column_adapter.cr`, and focused table specs;
   reuse the existing recursive Object accounting rather than duplicate it.
2. Part/catalog owner: a minimal `wide_part.cr` hook delegating to the separate
   `wide_part/selected_json_metadata_probe.cr` owner, and `offline_table.cr`
   DDL/PK binding, plus focused catalog specs. Preserve unrelated scalar reader
   behavior and explicit projection rejection.
3. Oracle owner: new `check_object_table_w130.cr/.sh` and
   `examples/read_object_table.cr`. Root owns the independent spec, imports,
   frontiers, execution, review and exact-path commit.

Definition of Done / falsifiers (root-only serial guarded jobs):

- Focused DEBUG and RELEASE specs plus the complete non-release spec inventory:
  zero failures, errors or pending. Prefer a combined-process suite, but if the
  unchanged resource guard refuses its compilation, run disjoint serial groups
  containing every spec file. Record inventory, group/example totals and the
  rejected combined-build routes; do not certify combined-process behavior from
  sharded execution. Exercise full/batched/zero/window/candidate delivery,
  caller order/provenance, retained handles, wrong accessors, later-part
  schema/grid drift, empty-table unsupported declarations, multiple Object
  aggregate admission, skipped corrupt payload and projection rejection.
- Fresh pinned stock native cases: two three-row parts, physical `[2,1]`
  grids, two selected JSON roots, ordinary String 0/1 and BASIC/COMPACT
  discriminator profiles. Compare full and inclusive PK SQL against authored
  expectations; compare whole candidate granules separately, then residual
  rows against SQL. Assert actual grids/index schedules, not assumed shapes.
- Fresh library-owned one-Object writer part: actual stock ATTACH, successful
  CHECK row, full/PK SQL, mixed table batches/windows/candidates. The writer
  still authors only one Object column; the native route qualifies multiple
  selected roots. Wrong-document/grid/CHECK comparator controls must reject.
- Existing W129 catalog and W128 writer gates remain green, exact-path format,
  shell syntax and diff checks pass, and root's scoped hostile review is
  ROBUST before a material VERIFIED claim. No throughput promotion.

### W130 executed bounded certificate

Lineage: final W130 source over clean `2097a88`. Luna owned the implementation
and oracle; root independently inspected, added the adversarial contract and
ran every heavy gate serially. The W129 source/runtime distinction is unchanged:
the separate clean depth-1 source is `101871ba6da8221c7cf30ac3a04bc1063106f412`
at `/Users/sergey/SrcArchives/clickhouse-2026-10-02-depth1-101871ba`; the actual
stock binary remains 26.10.1.1201, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
No executable from the new source checkout was built or qualified.

Evidence directory: `/private/tmp/crystal-click-w130-root.hIaVRq`.
Final fresh W130 root: `/private/tmp/crystal-click-object-table-w130.Iw0gp0`;
W129 regression: `/private/tmp/crystal-click-object-catalog-w129.kw3mMY`;
W128 regression: `/private/tmp/crystal-click-json-w128.zkbcxz`.
Temporary roots were deliberately retained, not committed or guaranteed durable.
The guard, Crystal/LLVM/SDK identity and time/memory ceilings match W129 above;
combined builds and grouped fallback never relaxed its 50% free-memory or
1,000-open-file thresholds. No production data was mutated.

Root observed:

- Final focused DEBUG: 16 examples, zero failures/errors/pending
  (`focused-debug-final.log`). Final adjacent RELEASE: 133 examples, likewise
  green (`focused-release-final.log`). The three new spec files cover all
  current W130 tests; RELEASE adds ten complete adjacent spec files listed
  below, not filtered individual examples.
- All 346 non-release spec files passed as 15 disjoint serial groups of at most
  24 files: 2,210 examples, zero failures/errors/pending
  (`full-nonrelease-shards-2.log`, 492 seconds). A single-module combined build
  was killed at the 50% memory guard before tests (`full-nonrelease.log`). A
  single-thread multi-module combined build reached the guard's FD threshold
  before tests (`full-nonrelease-multimodule.log`, observed 4,148 open files).
  That threshold event alone does not diagnose an FD leak. Grouped execution
  covers every spec file but does not establish combined-process interaction
  behavior or full RELEASE.
- Four fresh native two-Object profiles passed ordinary String 0/1 × BASIC/
  COMPACT. Each has two three-row Wide parts with actual `[2,1]` Object grids
  and primary keys/sentinels `[1,3,3]`, `[4,6,6]` checked before candidate use.
  Authored documents include declared UInt64/String, Dynamic Int64 and shared
  String/Int64/Bool, NUL and UTF-8. Full SQL yields six rows; inclusive key
  range 3..4 yields two exact rows versus five whole candidate rows. Full and
  cross-part window scans, selected-column and explicit reversed-part order,
  provenance, multiple JSON owners and exact residuals match authored values.
- One fresh fully library-owned Object part was actually ATTACHed; stock
  CHECK returned the successful part row and full/PK SQL matched. Its real
  `[2,1]` grid and `[1,3,3]` index were checked before table candidates. This
  qualifies the existing one-Object writer, not a multi-Object writer.
  Wrong-document, wrong-grid and CHECK=0 controls were rejected. Final oracle
  evidence is `stock-w130-final-4.log`, at the final formatted script state.
- In disposable native catalog copies, an unselected sibling JSON schema was
  changed to unadmitted Float64. Selected `payload` plus key still matched all
  authored rows; selecting the sibling was refused. Metadata was restored in
  `ensure`. This is a selection-scope attack, not a stock ATTACH claim for the
  deliberately mutated copies.
- Eight fresh W129 bidirectional catalog cases and five fresh W128 complete
  writer cases remained green (`stock-w129-regression-final.log`,
  `stock-w128-regression-final.log`). These exercised actual stock CHECK/full/
  PK reads and library ATTACH, not only process exit codes.
- The example passed on the retained qualified native catalog
  (`example-w130-final.log`): physical window keys 3,4,5; candidate keys
  1,2,3,4,5; residual keep 3,4. An independent output check required exactly
  three window rows, five candidates, two keeps and three rejects.
- Exact-path Crystal formatting, shell syntax and diff checks passed. Existing
  duplicate-libc and deprecated `File.new` argument warnings remain unchanged.

Corrections from measured failures, not hidden successful-route substitutions:

- The first focused compiler run exposed an Iterator where the public API
  requires an Array; the table owner now explicitly builds the Array.
- Root's dotted-name adversarial fixture initially used canonical whole-Object
  DDL outside the unchanged legacy virtual-path grammar. It safely refused
  before the intended ambiguity branch. The corrected fixture uses admitted
  `JSON(t UInt64)` at that old boundary; no parser widening occurred.
- The first oracle compilation found NamedTuple `part.name/path` accessor
  errors missed by static review; they were changed to indexed access. Static
  agreement was not promoted over this actual compiler failure.
- The next native run produced Sparse metadata for its all-zero partition
  column, outside W129's Default-only profile. The fixture now explicitly
  sets `ratio_of_defaults_for_sparse_serialization=1` and independently checks
  actual serializer kinds before opening the reader. Source anchor:
  `src/Storages/MergeTree/MergeTreeSettings.cpp:95-110` in the fresh checkout.
  The production guard was not weakened. Sparse siblings remain unqualified.

Replay inputs (with the same serial guard/environment as W129):

```sh
crystal spec --single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace \
  spec/object_table_w130_spec.cr spec/object_offline_table_w130_spec.cr \
  spec/object_table_w130_root_spec.cr
# RELEASE adds these whole files:
# object_catalog_w129_spec.cr, object_column_reader_w129_spec.cr,
# object_catalog_w129_root_spec.cr, object_document_schema_w128_spec.cr,
# object_part_writer_w128_spec.cr, object_part_writer_w128_root_spec.cr,
# offline_catalog_spec.cr, lazy_window_reader_spec.cr,
# wide_part_table_projection_w87_spec.cr, offline_catalog_projection_w87_spec.cr
# All are under spec/; use the same command with --release.
# Full inventory: rg --files spec -g '*_spec.cr' | LC_ALL=C sort
# Run consecutive non-overlapping groups of at most 24 with
# crystal spec --no-debug --single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace.
W130_KEEP_TMP=1 bash scripts/check_object_table_w130.sh
W129_KEEP_TMP=1 bash scripts/check_object_catalog_w129.sh
W128_KEEP_TMP=1 bash scripts/check_object_part_writer_w128.sh
crystal run --single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace \
  examples/read_object_table.cr -- \
  /private/tmp/crystal-click-object-table-w130.mt1sta/catalog/native_single_stream_basic \
  lab events pk payload 2 3 3 4
bash -n scripts/check_object_table_w130.sh
git diff --check
```

Final production SHA-256 fingerprints (`source-fingerprints.log`):

```text
6cf5f1090dba245402e78828052c865f79319505b111c2bf025879aebd7acefa  src/crystal_click.cr
ea4a387a8999f5720f0622f808092fe18b6ad5c9802f18dc06cb33ca7d75719d  src/crystal_click/wide_part.cr
dad256360989c3cfd6ee0fcd68610d431b14d21086e6e60d8d5393d9c0812790  src/crystal_click/wide_part/selected_json_metadata_probe.cr
49b0b91e95be80eebb0138c7d718eb2a87be96653021545c3d2fa79b7c1bfbcf  src/crystal_click/wide_part_table.cr
4d0d18ae41884136aee2155c6c095875515279118d637b4faf64272ebe2e2d90  src/crystal_click/wide_part_table/object_column_adapter.cr
11ee991d4fedcfeb012d5ad3886d0803bb4eeac9d7f6659df9d5f04a7c855129  src/crystal_click/offline_table.cr
```

Root's scoped hostile verdict: ROBUST for this normalized table-delivery
contract. Strongest executed attacks: later-part schema/full-grid drift before
callbacks, skipped corrupt selected payload, callback exception identity,
Object-only vacuous scalar admission, unsupported empty-table DDL, selected/
unselected schema isolation, whole-Object projection refusal, atomic complete
pending-document charge and shared remaining budget across Object lanes.
Metadata parsing and per-mark admission have separate class owners; root also
reviewed their connection to the table's shared mark lifecycle. Luna's static
review is correlated support, not an independent runtime certificate.

Residuals: exact W129 declarations/layouts only; Default metadata, quiescent
inputs, metadata-only selected checksum roster/size validation, no payload-hash
authentication or server Active/snapshot proof. Skipped value payload stays
lazy but metadata is eager and may repeat. Complete Object marks are measured
after decoding: no workspace/transient/RSS/caller-retention ceiling or speed
claim. Whole-Object projections, generic table/multi-Object writing, all paired
types and complete MV/projection coverage remain open. The large-facade
decomposition is unfinished. This grouped test certificate is not a successful
combined-process suite.

Decay: schema/parser/roster/default/profile/count/grid, owner accounting,
imports/dispatch, comparator, runtime/source/toolchain or publication changes.
Refresh the affected positives and negatives before reusing the claim. Next
falsifier: separately pair a declared `Int64` Object lane with signed extremes
in native and library-owned stock parts; Dynamic/shared Int64 evidence does
not close that typed lane. Optimization remains parked; the overarching goal
stays active.

## W131 declared Int64 Object lane — pre-implementation design seal

Anchor: clean W130 `4b18812`. The normalized schema constructor and parser
admit UInt64/String only; the reusable binary and fixed-width bulk owners
already represent signed Int64. Existing Dynamic/shared Int64 evidence is not
a declared typed-field certificate. Fresh source reference `101871ba` delegates
Object typed paths to their nested serializers (`DataTypeObject.cpp:184`,
`SerializationObject.cpp:913`); `SerializationNumber.cpp:299` uses little-endian
numeric binary encoding. Runtime qualification remains pinned separately.

Requested transition: add nominal Int64 to the shared normalized Object schema
owner and parser, paired for complete part writing and file/column/catalog/table
reading. Retain exact nominal schema-plan identity, canonical declaration byte
preflight, all W129/W130 admission/ownership guards and legacy virtual-path
behavior. No Float64, wrapper, new layout, Compact part, projection or MV
admission follows from this lane. General compatibility remains the objective;
this is one implementation checkpoint, not a replacement completion criterion.

Risk: CAUTION (serialization admission). Rollback: one atomic local commit over
the clean anchor. Likeliest failure: signed extremes survive a local round-trip
but fail stock interpretation, or the shorter `Int64` name invalidates exact
canonical byte preflight. Guard with independently authored signed values and
actual stock CHECK/full/PK SQL in both directions, not just codec symmetry.

Execution order: root runs a new positive Int64 declaration test RED before
production edits; Luna changes only the two schema owners and focused specs;
a separate Luna owns the fresh bidirectional stock oracle. Root owns additional
adversarial consumer specs, guarded serial execution, docs and the local commit.
Consumer inventory: `rg -n 'ObjectDocumentSchema|TAG_INT64|int64|fixed_width'
over `object_document*`, `object_column*`, `binary_bulk_physical_plan.cr` and
`wide_part_writer/object_part_writer.cr` identifies the shared schema/parser,
generic fixed-width bulk and complete writer consumers. W130 adapters reuse the
schema parser and therefore require signed catalog/table integration checks.

DoD: focused DEBUG and adjacent RELEASE tests; fresh native and fully owned
writer parts covering signed minimum/maximum, negative/zero/positive values,
multiple marks with short tail, full/middle/zero reads, catalog and typed-table
windows/candidates; actual CHECK=1 and full/PK SQL; schema/type mismatch,
unsupported Float64/wrapper, bad signed payload and comparator controls. Run
the complete non-release spec inventory in disjoint guarded serial groups if
the combined route remains resource-refused, explicitly without a combined
process certificate. Format/shell/diff checks and root hostile verdict must
pass before admission or commit. Optimization remains parked.

## W131 declared Int64 Object lane — executed certificate (2026-10-02)

Status: VERIFIED only for this bounded normalized Int64 contract over W130
`4b18812`. The overarching paired-types/MV/projections goal remains active;
this certificate is not general JSON compatibility or architecture completion.

The only changed production owners are `object_document_schema.cr` and
`object_document_schema_parser.cr`. Both admit nominal Int64 alongside
UInt64/String. Canonical byte preflight now explicitly distinguishes the
five-byte Int64 name from the six-byte UInt64/String names; unsupported tags
have no sizing fallback. Exact schema/plan/value identity remains mandatory.
The existing fixed-width bulk encoder/decoder supplies signed eight-byte
little-endian transport. No per-declaration class, duplicate codec, new facade
dispatch or unsupported wrapper admission was introduced.

Qualified profile: one declared Int64/UInt64/String Object beside a sorted
UInt64 key; hashed Wide, Object V3/Dynamic V3, explicit rosters, one-bucket
shared MAP, LZ4, plain adaptive `.mrk2` and `primary.idx`, Default metadata.
Native and fully library-owned parts each cover all four combinations of
ordinary String 0/1 and BASIC/COMPACT discriminators. These modes do not mean
Compact parts. The independent five-row input includes Int64 MIN/-1/0/1/MAX,
NUL/non-ASCII String bytes, Dynamic Int64 and shared String spill. Actual
mark counts `[2,2,1]`, primary keys/sentinel `[1,3,5,5]` and PK=4 candidate
mark `[1]` are inspected before table delivery is checked.

Every case executes stock CHECK=1 and exact full/PK SQL plus independently
authored signed RowBinary bytes. File/column readers have explicit full,
middle and zero windows. Synthetic Atomic catalog `.values` checks retained
ownership; typed-table callbacks check the independently copied part path,
mark/row provenance, physical window and complete candidate keys `[3,4]`
with application residual keeping only `4`. Returned documents remain
normalized values, not original JSON text.

Source reference: fresh shallow `101871ba6da8221c7cf30ac3a04bc1063106f412`.
Nested typed serializers and numeric LE anchors are recorded in the design
seal above. This is source-only evidence, not a current-master binary build.
Executed runtime remains 26.10.1.1201, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, executable SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
The oracle actually verifies version, build and executable digest.

Root-executed gates, serially under the unchanged resource guard:

- Qualified RED before production edits: five independent consumer examples
  failed only at the expected Int64 schema refusal (`red.log`).
- Focused DEBUG: 18 examples, zero failures/errors (`focused-debug.log`).
- Adjacent RELEASE: 143 examples, zero failures/errors (`adjacent-release.log`).
- Complete non-release inventory: all 348 `_spec.cr` files, 15 disjoint groups
  of at most 24, 2,220 examples, zero failures/errors and exit 0
  (`full-nonrelease-shards.log`). This is not a combined-process or full
  RELEASE certificate.
- Fresh final W131: eight bidirectional matrix cells plus five deliberately
  failing comparators; exit 0 (`stock-w131-matrix.log`). Parts are retained
  under `/private/tmp/crystal-click-object-int64-w131.wWvdqH`.
- Unchanged fresh stock regressions: W130 five cases, W129 eight and W128
  five, each exit 0 (`stock-w130-regression.log`, `stock-w129-regression.log`,
  `stock-w128-regression.log`). Their retained roots are respectively
  `/private/tmp/crystal-click-object-table-w130.j6Qy1x`,
  `/private/tmp/crystal-click-object-catalog-w129.WGcerk` and
  `/private/tmp/crystal-click-json-w128.fJCjGe`.
- Exact-path Crystal formatting, shell syntax and diff checks passed.

Root logs live under `/private/tmp/crystal-click-w131-root.rAleXM`; they are
temporary evidence, not committed artifacts or a substitute for replay.
The existing frontier certificate is the durable fallback: this repository
has neither `docs/landmark-evidence-packet-template.md` nor
`scripts/validate-landmark-graph.sh`. No packet-shape validation is claimed.

Measured failure and review corrections remain visible:

- Initial stock run compiled and passed CHECK/full/PK/RowBinary and four
  controls, then falsely rejected `serialization.json` with `columns: []`.
  Fresh CH `SerializationInfo.cpp:432-442,506-510,551-568` confirms that
  missing per-column information means Default. Only the oracle assertion
  changed; production guards were not weakened. The final helper permits
  empty records but its seeded Sparse control still fails. Failed evidence
  remains in `stock-w131-final.log` and the retained `uDG0Uu` root.
- Static review found callback path comparison used only resolver output.
  The oracle now also checks it against the independently authored copy
  destination before callbacks. Root reviewed and executed that path check.
- The first corrected run passed six cases (`stock-w131-corrected.log`,
  retained `Qm70ww` root), but writer coverage was diagonal. Root required
  both remaining writer combinations; the final eight-case run supersedes
  that narrower matrix claim without hiding it.

Replay uses the W130 serial guard/environment: free-memory floor 50%, Crystal
1.21.0/LLVM 22.1.8, SDKROOT MacOSX26.5.sdk, TMPDIR `/private/tmp`, isolated
cache, single module/thread and `--link-flags=-fuse-ld=ld`. Crystal gates use
600s/32768 MiB; shell oracles 900s/32768 MiB. Do not widen the guard to turn a
refusal into a PASS.

```sh
crystal spec --single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace \
  spec/object_document_schema_w131_spec.cr spec/object_int64_w131_root_spec.cr \
  spec/object_document_schema_w128_spec.cr
# RELEASE uses the same command plus --release and these twelve whole files:
# object_table_w130_spec.cr, object_offline_table_w130_spec.cr,
# object_table_w130_root_spec.cr, object_catalog_w129_spec.cr,
# object_column_reader_w129_spec.cr, object_catalog_w129_root_spec.cr,
# object_part_writer_w128_spec.cr, object_part_writer_w128_root_spec.cr,
# offline_catalog_spec.cr, lazy_window_reader_spec.cr,
# wide_part_table_projection_w87_spec.cr, offline_catalog_projection_w87_spec.cr
# All are under spec/. Full inventory and grouped command are unchanged W130.
W131_KEEP_TMP=1 bash scripts/check_object_int64_w131.sh
W130_KEEP_TMP=1 bash scripts/check_object_table_w130.sh
W129_KEEP_TMP=1 bash scripts/check_object_catalog_w129.sh
W128_KEEP_TMP=1 bash scripts/check_object_part_writer_w128.sh
bash -n scripts/check_object_int64_w131.sh
git diff --check
```

Frozen SHA-256 identities for the changed owners and final oracle:

```text
66d8bde07a518b6872e8b977c9e4142f4bbf0905470312af17a4b9633ba3bfaa  src/crystal_click/object_document_schema.cr
2eb8e0ccf0d2e6563378e5fddc46fc78ec55a9b03fab1cee0a788f1b57e0500b  src/crystal_click/object_document_schema_parser.cr
22efb19f0fa72dd9efc15e515e7e508af19413a9ec94cd5865cf8e699e1dbec8  scripts/check_object_int64_w131.cr
f4f821084cb6672af3cb7d62669461d93b2715b907c1c8cd332bdcd615e3a02d  scripts/check_object_int64_w131.sh
```

Root's scoped hostile verdict: ROBUST for this declared Int64 profile.
Executed attacks include exact constructor/parser budget boundaries, signed
versus unsigned schema/plan/value mismatch, refusal before writer publication,
later-part signedness drift before callbacks, corrupt selected versus skipped
signed frames, and wrong document/grid/CHECK/signed-byte/Sparse controls.
Luna implementation and static review are correlated support, not independent
runtime certification. Root inspected the owner diff and oracle and ran the
compiler/stock evidence himself.

Residuals: only Int64/UInt64/String declared fields; no Float64, typed wrappers,
new Object/shared layouts, Compact/Sparse parts, whole-Object projection reads,
arbitrary table/multi-Object writing, server Active/snapshot proof, whole-part
payload-hash authentication or RSS/pre-decode/caller-retention bound. Broader
types, MV/projections and the large-facade refactor remain open; optimization
stays parked. Decay on schema/bulk/reader/writer/adapter admission, profile,
limits, comparator, runtime/source/toolchain or publication changes; refresh
the affected positives and negatives. Next typed-lane falsifier: paired
Float64 with independently expected raw bits for signed zero, NaN and infinity,
not a textual JSON-number round-trip. This is a proposed next test, not support.

## W132 declared numeric Object family — pre-implementation design seal

Anchor: clean W131 `02dd99f`. Current normalized schema/parser admit nominal
Int64, UInt64 and String; the existing fixed-width binary/bulk owners already
represent the other numeric widths. Logical representation is not sufficient
evidence for public Object part admission. Fresh shallow source `101871ba`
uses nested typed serializers (`SerializationObject.cpp:1333-1376`), whose
numeric column binary path reads/writes raw little-endian words
(`SerializationNumber.cpp:316-327`). `JSONExtractTree.cpp:2656-2690` admits
the integer widths, Float32/64 and Bool's nominal UInt8-backed JSON node.

Requested transition: paired declared UInt8/16/32/64/128/256,
Int8/16/32/64/128/256, Float32/64 and Bool, plus existing String, through the
same normalized whole-part, file/column, catalog and table owners. Add one
cohesive `ObjectTypedFieldType` policy file, shared by constructor/parser,
instead of per-type codecs/classes or repeated whitelists. Preserve nominal
identity, exact declaration-byte preflight, roster/capacity limits, ownership
and existing fail-closed admission. No wrapper, identifier, temporal, Decimal,
Enum, container, new layout, Compact part, projection or MV widening.

Measured rejection before implementation: stock CREATE refuses a declared
BFloat16 field with code 43, `JSON serialization doesn't support the return
type schema: BFloat16`. `DataTypeObject.cpp:199-232` calls the JSON extraction
tree builder; that builder has no BFloat16 branch and throws at
`JSONExtractTree.cpp:2828-2834`. Standalone BFloat16 support does not override
this Object schema gate. BFloat16 remains a negative admission test.

Root's isolated pinned-runtime probe passed Float32/64 +/-0, +/-infinity,
quiet and signaling NaN payloads through raw Object RowBinary INSERT,
independent exact RowBinary comparison and CHECK=1. Evidence:
`/private/tmp/crystal-click-w132-root.LJh1iC/probe-float-final.log` (exit 0).
Earlier logs retain the BFloat16 rejection, clickhouse-local stdin schema
inference refusal and stale generated-file tail. The corrected probe uses
an exact isolated `FROM INFILE` path and truncates generated binary output;
none of those attempts changed production code or established part support.

Risk: CAUTION (serialization admission). Rollback: one atomic local commit
over `02dd99f`, with no remote push. Strongest failure: local raw-bit symmetry
or UInt8/Bool coercion masks a stock nominal/wire mismatch; broader names also
break canonical byte accounting. Guard with independently authored boundary
bytes, exact stock type labels, actual CHECK/full/PK SQL and raw RowBinary,
constructor/parser byte cutoffs, wrong-nominal values and drift-before-callbacks.

Ownership: Luna owns new schema/root consumer specs; another Luna owns the
single policy owner, two schema owners, require wiring and necessary old
negative-test sentinel replacements, only after root executes qualified RED.
A separate Luna owns `scripts/check_object_numeric_w132.cr` and `.sh`; root
reviews, runs every compiler/stock job serially under the resource guard,
updates certificates/navigation and commits exact relevant paths.

DoD: focused DEBUG and adjacent RELEASE tests; complete non-release spec
inventory in disjoint guarded groups (not a combined-process certificate);
four native and four fully library-owned whole parts covering the complete
String 0/1 x BASIC/COMPACT matrix in both directions; actual profile/grid,
CHECK=1, full/PK SQL, exact raw numeric RowBinary and type labels;
file/column full/middle/zero reads, independently copied catalog provenance,
mixed-table windows and UInt64-PK whole-granule candidates with residuals.
Author each integer width's signed/unsigned limits without production codecs;
include float signed-zero/infinity/NaN words and Bool false/true distinct from
UInt8. Seed numeric-byte/type/CHECK/grid/document/Sparse comparator failures.
Format/shell/diff checks and root hostile verdict must pass before the new
roster is admitted or committed. General paired types/MV/projections remains
the active goal; optimization and stock speed parity remain unclaimed.

## W132 declared numeric Object family — executed certificate (2026-10-03)

Status: VERIFIED only for this bounded normalized profile over W131 `02dd99f`.
Admitted declared fields are UInt8/16/32/64/128/256, Int8/16/32/64/128/256,
Float32/64, Bool and String. These are 16 nominal types, 13 newly admitted in
Object beyond Int64/UInt64/String. BFloat16 remains refused by the independently
measured stock schema gate in the design seal; standalone scalar support does
not override that gate. General paired types/MV/projections remains active.

Production adds one `ObjectTypedFieldType` module/file, consumed by schema
construction, parser token resolution and canonical declaration sizing. Its
static names are resolved before the existing byte charge without allocating
a general type name. Constructor/parser share the closed nominal policy;
there is no sizing fallback for an unsupported tag. Fixed-width bulk owners,
writer, file/column readers and catalog/table adapters are reused unchanged.
Old rejection sentinels for newly admitted numeric types now use BFloat16;
this is not removal of the unsupported-type guard.

The qualified profile remains one Object root beside one sorted UInt64 key,
hashed Wide, Object V3 (wire version 4)/Dynamic V3, explicit rosters, one-bucket
shared MAP, LZ4, plain adaptive `.mrk2` and `primary.idx`, Default metadata.
Both native and fully library-owned parts cover ordinary String 0/1 ×
BASIC/COMPACT discriminators; COMPACT here is not a Compact part. Shared MAP
Strings retain the existing single-stream profile. The independently authored
seven rows include every integer width's unsigned/signed boundaries and
asymmetric words, Float32/64 positive/negative zero and infinity, quiet and
signaling NaN payloads, NUL/Unicode Strings, Dynamic Int64 and shared String
spill. Actual grids `[2,2,2,1]`, primary keys/sentinel `[1,3,5,7,7]` and PK=6
candidate mark `[2]` are inspected.

Stock accepts Bool input bytes 0/1/2/128/255 as false/nonzero-true and preserves
their raw codes in native RowBinary. Crystal's logical Bool reader accepts
the same truth values; its writer canonicalizes true to byte 1. The oracle
therefore compares native raw codes separately from canonical library output,
not a false whole-input byte-identity claim. Bool and UInt8 remain nominally
distinct. Floats are compared by raw words, not Float equality or JSON text.

Source reference: clean shallow `101871ba6da8221c7cf30ac3a04bc1063106f412` in
`/Users/sergey/SrcArchives/clickhouse-2026-10-02-depth1-101871ba`. Qualification
uses the separate pinned Mach-O runtime
`/private/tmp/crystal-click-w112-runtime.u0Jn1f/clickhouse`, version
`26.10.1.1201`, build `d9bcb5ab007f0f6299f7f973f2642245bab3d028`, SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
No executable from the new shallow source has been built or qualified.
Crystal is 1.21.0, LLVM 22.1.8/AArch64 with the macOS 26.5 SDK.

Root-owned evidence directory: `/private/tmp/crystal-click-w132-root.LJh1iC`.
Each compiler/stock job ran serially under `cogni-ml/scripts/run_safe.sh` with
minimum free memory 50%, maximum RSS 32,768 MiB and its existing FD guard.
That guard is not a no-leak/RSS bound for the library.

- `red.log`: four new schema examples; three expected old-whitelist errors
  before production edits, one unsupported-type guard passes.
- `focused-debug.log`: the first consumer run exposed two fixture/API errors:
  a bulk role must be `root.data`, and table `max_rows=0` is an existing refusal,
  not an empty-read API. Fixtures were corrected, with EOF emptiness tested
  separately; production APIs were not widened.
- `focused-debug-corrected.log`: 26 DEBUG examples, zero failures/errors, exit 0.
- `adjacent-release.log`: 151 examples in the 17 selected adjacent spec files,
  zero failures/errors, exit 0.
- Full inventory: 350 unique sorted spec files in 15 designated disjoint groups,
  2,228 examples, zero failures/errors. Count groups 1..5 (750 examples) from
  `full-nonrelease-shards.log`, completed before interruption, and groups 6..15
  (1,478 examples) from `full-nonrelease-resumed.log` (exit 0). The interrupted
  invocation did not finish: root validated and stopped only its orphan process
  group 16606 after the guard parent was lost, then conservatively resumed at
  group 6. Original groups 6..8 are retained but not counted. This is not a
  successful combined-process suite or a successful entire first invocation.
- `stock-w132.log`: first oracle exits 1 at its synthetic Atomic metadata's
  unquoted column definitions. Actual stock metadata uses backticks; only the
  oracle fixture was corrected. No catalog grammar or production code changed.
- `stock-w132-corrected.log`: all four native and four library-owned matrix
  cells, actual CHECK=1/full/PK SQL, exact numeric RowBinary/type labels,
  file/column full/middle/zero reads, independently copied catalog values and
  ownership/reread, table windows and candidate provenance/residuals pass.
  Six seeded comparator failures (document byte, nominal type, Sparse metadata,
  grid, CHECK result and numeric RowBinary) are rejected; outer exit 0.
- Fresh `stock-w131-regression.log`, `stock-w130-regression.log`,
  `stock-w129-regression.log` and `stock-w128-regression.log`: 8/5/8/5 existing
  matrix cells pass, all outer exits 0. W130's obsolete Float64 negative
  sentinel was replaced by BFloat16; the other three scripts are unchanged.

Retained fresh oracle roots: W132
`/private/tmp/crystal-click-object-numeric-w132.vkbvGo`; W131
`/private/tmp/crystal-click-object-int64-w131.pvozsH`; W130
`/private/tmp/crystal-click-object-table-w130.5k5h2G`; W129
`/private/tmp/crystal-click-object-catalog-w129.XlBhfn`; W128
`/private/tmp/crystal-click-json-w128.zcLwVJ`. The failed W132 fixture root
`/private/tmp/crystal-click-object-numeric-w132.hRPovW` is retained separately.
Raw output is evidence, not instructions. This existing frontier is the curated
evidence index; the optional packet template/graph validator is absent in this
checkout, so no structural-validator pass is asserted.

DoD command forms (run through the serial resource guard, 600 seconds for
focused specs and 900 seconds for wrapper/full-inventory runners; isolated
caches):

```sh
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk TMPDIR=/private/tmp
export CRYSTAL_BIN=/opt/homebrew/bin/crystal
export CLICKHOUSE_BIN=/private/tmp/crystal-click-w112-runtime.u0Jn1f/clickhouse
export COGNI_RUN_SAFE_MIN_FREE_PCT=50 RUN_SAFE_PASSTHROUGH_STDIO=1
# Prefix compiler commands with:
# /Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh "$CRYSTAL_BIN" 600 32768
# Prefix wrapper commands with the same guard and /bin/bash 900 32768.
crystal spec --single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace \
  spec/object_document_schema_w132_spec.cr spec/object_numeric_w132_root_spec.cr \
  spec/object_document_schema_w131_spec.cr spec/object_int64_w131_root_spec.cr \
  spec/object_document_schema_w128_spec.cr
# Adjacent RELEASE: the five files above plus object_table_w130_spec.cr,
# object_offline_table_w130_spec.cr, object_table_w130_root_spec.cr,
# object_catalog_w129_spec.cr, object_column_reader_w129_spec.cr,
# object_catalog_w129_root_spec.cr, object_part_writer_w128_spec.cr,
# object_part_writer_w128_root_spec.cr, offline_catalog_spec.cr,
# lazy_window_reader_spec.cr, wide_part_table_projection_w87_spec.cr,
# offline_catalog_projection_w87_spec.cr. All under spec/; add --release.
# Inventory: rg --files spec -g '*_spec.cr' | LC_ALL=C sort;
# consecutive disjoint groups of at most 24 with the same flags + --no-debug.
W132_KEEP_TMP=1 bash scripts/check_object_numeric_w132.sh
W131_KEEP_TMP=1 bash scripts/check_object_int64_w131.sh
W130_KEEP_TMP=1 bash scripts/check_object_table_w130.sh
W129_KEEP_TMP=1 bash scripts/check_object_catalog_w129.sh
W128_KEEP_TMP=1 bash scripts/check_object_part_writer_w128.sh
crystal tool format --check src/crystal_click.cr \
  src/crystal_click/object_typed_field_type.cr \
  src/crystal_click/object_document_schema.cr \
  src/crystal_click/object_document_schema_parser.cr \
  spec/object_document_schema_w132_spec.cr spec/object_numeric_w132_root_spec.cr \
  spec/object_document_schema_w128_spec.cr spec/object_document_schema_w131_spec.cr \
  spec/object_catalog_w129_spec.cr spec/object_catalog_w129_root_spec.cr \
  spec/object_offline_table_w130_spec.cr spec/object_table_w130_root_spec.cr \
  scripts/check_object_numeric_w132.cr scripts/check_object_table_w130.cr
bash -n scripts/check_object_numeric_w132.sh
git diff --check
```

Frozen production, new spec and final oracle SHA-256 fingerprints:

```text
5bfbfc8e9c3d260d9a826c09e6a901512cb70aa715870251586402706ed4c70c  src/crystal_click.cr
cc66086d6d98c83cdc22416f0d0316841e25fcc7c256ff88b21aa8a6bd7e656a  src/crystal_click/object_typed_field_type.cr
b0d343a2fcf3979c2be0d4362e885475aa9e6b1a706a586a8e23ee3069e07b2e  src/crystal_click/object_document_schema.cr
0145f148ca50f952cd05e59faa67a3dc72ba72d42361cc989839a92539377e50  src/crystal_click/object_document_schema_parser.cr
803fb20ddecae8b91f809aa11da830cdf590b36f61a69c300ae02ff1119f9d8f  spec/object_document_schema_w132_spec.cr
e08c8604d18918aa2ff519461388e7782cc91c021b966bb9c82d3fee4ad978fa  spec/object_numeric_w132_root_spec.cr
3a4257b4b6dd275a11d6563670d64afb2bb8bb0ac5a95e2b826cd3eedce30a40  scripts/check_object_numeric_w132.cr
686afa88faec55de9ef9ac19e5a6a6e2ec8eaef9880f26ea5279c2e194d83eae  scripts/check_object_numeric_w132.sh
```

Root's hostile verdict: ROBUST within the declared profile. Attacks include
every admitted type's exact canonical budget cutoffs, unsupported-wrapper
refusal, Bool/UInt8 and signed/unsigned plan/value mismatch, wrong-nominal
writer refusal before publication, later-part nominal drift before callbacks,
native versus canonical Bool bytes, exact float payloads and all six comparator
controls. Root reviewed the owner/oracle diff and ran the real compiler/stock
checks; Luna's implementation and static inventory are correlated support.

Residuals: no temporal/identifier/FixedString/Decimal/Enum/wrapper/container
Object widening, new layouts, Compact/Sparse parts, arbitrary table/multi-Object
writing, whole-Object projection reads or broader MV/projection execution.
Quiescent inputs and existing metadata/checksum-roster validation remain the
boundary, not server Active/snapshot proof or whole-part payload authentication.
No decode-workspace/transient/RSS/caller-retention bound, facade-refactor closure
or stock-speed claim follows. Decay on policy/schema/bulk/adapter admission,
profile/limits, comparator, publication, runtime/source/toolchain or loss of
retained evidence; refresh the affected positives and negatives.

Next proposed falsifier: declared Date/Date32 in both native and library-owned
Object parts, asymmetric raw day codes including negative Date32, exact
bytes/RowBinary, calendar interpretation and stock CHECK. Fresh source admits
both at `JSONExtractTree.cpp:2698-2701`; existing fixed-width carriers alone do
not establish Object compatibility. No W133 production change is admitted here.

## W133 declared Date/Date32 Object pair — pre-implementation design seal

Anchor: clean W132 `e043be7`. Fresh source `101871ba` admits both through
`DateNode` (`JSONExtractTree.cpp:2698-2701`); their binary serializers inherit
`SerializationNumber<UInt16>` and `<Int32>`. Existing Crystal primitive/fixed
bulk carriers preserve those raw words, but Date and UInt16, and Date32 and
Int32, remain different nominal types. No calendar API or Crystal JSON-text
ingestion is implied by raw Object storage support.

Root's pinned-stock probe passed before production changes:
`/private/tmp/crystal-click-w133-root.0hMLsY/probe-dates.log`, exit 0.
Stock JSON date-string inputs produce independently expected calendar dates,
nominal types and little-endian words, including day 513, -513 and -25567.
An independent raw Object RowBinary probe also preserves Date32 Int32 MIN/MAX
with CHECK=1. Those extremes are carrier transport evidence, not claims about
meaningful calendar formatting outside the stock calendar domain. Both probes
use isolated tables; runtime provenance remains separate from the shallow
source reference.

Transition: admit only bare Date/Date32 in the shared Object typed-field policy,
paired across the existing whole-part, file/column, catalog and table owners.
Retain exact declaration-byte budgets, schema/plan/value identity, immutable
ownership and all current profile/publication guards. Refuse DateTime/Time,
parameterized temporal declarations, wrappers, containers, BFloat16 and new
layouts in this lane. The complete types/MV/projections goal stays active;
performance is parked, not replaced by this smaller checkpoint.

Risk: CAUTION (serialization admission). Rollback: one local atomic commit
over `e043be7`, no push. Strongest failure: Date32 is treated as unsigned, or
Date/Date32 silently lose nominal identity to UInt16/Int32; local byte symmetry
would hide stock calendar disagreement. Guard with independent date-string
native inputs, exact day/byte/type/RowBinary and calendar SQL expectations,
raw signed extremes, wrong-nominal writer refusal and later-part drift before
callbacks. Do not weaken the existing `max_rows=0` or metadata quotation API.

Ownership/order: Luna owns two new schema/consumer spec files and the necessary
W132 Date negative-sentinel replacement. Root runs qualified RED before extending
that Luna's ownership to only `object_typed_field_type.cr`. A separate Luna owns the new
W133 stock oracle/wrapper, reusing W132's bounded instrumentation but adapting
all input/expected-value paths to dates. Root reviews all changes, runs every
compiler/stock job serially under the resource guard, updates the frontier,
project/modularization/example navigation and makes the scoped local commit.
No agent may run a compiler/ClickHouse job, change dependencies or push.

DoD: focused DEBUG and adjacent RELEASE; the complete unique non-release spec
inventory in designated disjoint guarded groups; four fresh native and four
fully library-owned String 0/1 × BASIC/COMPACT cells, actual CHECK/full/PK SQL,
exact raw typed RowBinary/types/calendar values, file/column full/middle/zero,
independently copied catalog ownership/reread, table windows and PK granule
candidates/residuals. Add exact constructor/parser budget boundaries, nominal
Date/numeric mismatches, prepublication and pre-callback guards, and seeded
byte/type/grid/CHECK/Sparse comparator failures. Fresh W132 and W130 stock
regressions, formatting/shell/diff hygiene and root hostile review must pass
before admission/commit. If carrier and calendar behavior differ, state and
test that boundary rather than changing date expectations to match output.

## W133 declared Date/Date32 Object pair — executed certificate (2026-10-03)

Status: VERIFIED within the design-sealed normalized profile over W132
`e043be7`. The broader types/MV/projections goal remains active; optimization
is parked. Production changes only the shared policy's two nominal entries.
Existing primitive/fixed bulk, whole-part, file/column, catalog and table
owners are reused; no new codec, facade branch or calendar API was added.
The old Date rejection sentinel now tests still-refused DateTime.

The admitted profile is one Object root beside a sorted UInt64 key, hashed
Wide, Object V3 (wire version 4)/Dynamic V3, explicit rosters, one-bucket shared
MAP, LZ4, plain adaptive `.mrk2`/`primary.idx`, Default metadata. Four native
and four fully library-owned cells cover String 0/1 × BASIC/COMPACT. COMPACT
is a discriminator profile, not a Compact part. Seven independently authored
calendar fixtures include Date day codes 0, 1, 513, 65535, 256, 10000, 365 and
Date32 -25567, -513, -1, 0, 1, 120529, 513, with asymmetric little-endian
words, NUL/Unicode/empty String, Dynamic Int64 and shared String spill.
Native JSONEachRow input uses independent calendar strings, not library bytes.
Actual grids `[2,2,2,1]`, keys/sentinel `[1,3,5,7,7]` and PK=6 candidate mark
`[2]` are checked; complete candidate rows 5/6 require the application residual.

Date/UInt16 and Date32/Int32 remain nominally distinct in schema, plan, value,
writer prepublication and later-part pre-callback checks. Separate native and
library-origin raw Date32 Int32 MIN/MAX cases check CHECK=1, types, exact hex,
typed RowBinary and Object reads. Those two cases are raw transport evidence,
not the main consumer matrix or meaningful calendar-range qualification.
The calendar witnesses do not establish a universal date-domain theorem.

Source is the clean shallow `101871ba6da8221c7cf30ac3a04bc1063106f412`
reference in `/Users/sergey/SrcArchives/clickhouse-2026-10-02-depth1-101871ba`.
Root compared DateNode, UInt16/Int32 serializers and direct declared Object
binary delegation (`SerializationObject.cpp:1365-1376`). Runtime qualification
uses the separate pinned `/private/tmp/crystal-click-w112-runtime.u0Jn1f/clickhouse`:
26.10.1.1201, build `d9bcb5ab007f0f6299f7f973f2642245bab3d028`, SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
No executable from the newer source reference was built or qualified.
Crystal 1.21.0, LLVM 22.1.8/AArch64 and macOS 26.5 SDK are the tested toolchain.

Root-owned evidence: `/private/tmp/crystal-click-w133-root.0hMLsY`.
Compiler/stock jobs ran serially under `cogni-ml/scripts/run_safe.sh` with
minimum free memory 50%, 32,768 MiB guard and its existing FD guard; these are
host checks, not a library memory/no-leak certificate.

- `probe-dates.log`: independent calendar and raw-extrema stock probes pass,
  outer exit 0, before production admission.
- `red.log`: four schema examples, three expected old-whitelist errors and
  one passing unsupported-type guard before the two policy entries were added.
- `focused-debug.log`: 34 examples, zero failures/errors, outer exit 0.
- `adjacent-release.log`: 159 examples in 19 adjacent files, zero failures/errors,
  outer exit 0. These two runs precede whitespace-only consumer-spec formatting;
  final-source inventory below includes that formatting.
- `full-nonrelease-shards.log`: all 352 unique sorted spec files in 15 disjoint
  groups of at most 24, 2,236 examples, zero failures/errors, outer exit 0 in
  one completed runner invocation. Not a combined-process or full RELEASE suite.
  Existing duplicate-library and deprecated `blocking` warnings remain.
- `stock-w133.log`: first oracle exits 1 after the eight calendar cells and
  seven negative controls pass; raw-extrema input wrongly included a Dynamic
  descriptor before the direct declared-field payload. No production failure
  or passing entire invocation is asserted. Only the fixture was corrected,
  with an independent exact 40-byte input guard; root also corrected that
  guard's hex letter-case mismatch before rerunning.
- `stock-w133-corrected.log`: all eight calendar cells pass actual CHECK=1,
  full/PK SQL, calendar/day-code/type/hex and exact typed RowBinary. File/column
  full/middle/zero, independently copied catalog ownership/reread, table
  windows and PK provenance/residuals pass. Seven seeded mismatches (date
  byte, Date/UInt16, Date32/Int32, Sparse metadata, grid, CHECK, RowBinary)
  are rejected. Both separate raw-extrema cases pass; outer exit 0.
- Fresh unchanged `stock-w132-regression.log` and `stock-w130-regression.log`:
  8/5 stock cells and their negative controls pass, both outer exits 0.

Retained roots: corrected W133 `/private/tmp/crystal-click-object-dates-w133.HN7N59`;
failed fixture `/private/tmp/crystal-click-object-dates-w133.ZTLH8B`; W132
`/private/tmp/crystal-click-object-numeric-w132.9tGHIs`; W130
`/private/tmp/crystal-click-object-table-w130.gUbVKV`. This frontier is the
curated index, not proof by fields or a structural-validator pass.

Replay: use the SDK/TMPDIR/toolchain/guard environment in W132's command block,
isolated caches, 600 seconds for focused specs and 900 for wrappers/inventory.
Focused files are W133 schema/root, W132 schema/root, W131 schema/root and
W128 schema specs under `spec/`, with the same single-module/one-thread/linker
flags. Adjacent RELEASE adds the W130 table/offline/root, W129 catalog/column/
root, W128 writer/root, offline catalog, lazy window and W87 table/catalog
projection specs. Complete inventory is `rg --files spec -g '*_spec.cr' |
LC_ALL=C sort`, consecutive groups of at most 24 with `--no-debug`.
Run `W133_KEEP_TMP=1 bash scripts/check_object_dates_w133.sh`, then unchanged
W132 numeric and W130 table wrappers with their KEEP_TMP variables set to 1.
Final formatting, wrapper `bash -n` and `git diff --check` must pass before commit.

Frozen final production/spec/oracle SHA-256:

```text
2057f9b5df1288512f90915e140cfaca3bf32c7fe2be9dde6f09c27d486502ed  src/crystal_click/object_typed_field_type.cr
af0c6592bfe19203b8cfeacb53448586d02fffc1ed36eda2bd6c5670e04363d3  spec/object_document_schema_w132_spec.cr
b2a8d0c2e683463c9e0154dff2e36cb2a45c4505f644e2f389788266fe662bde  spec/object_document_schema_w133_spec.cr
d50ed1ae28bebe083f1c72fcdedf8693d2ffb3aecaf1078b9cfd6794bc8aaaef  spec/object_dates_w133_root_spec.cr
2c0dd6477b2a5addf1d29ca011a4d2cfc1adafbc2788e0f793a0d604d7603d61  scripts/check_object_dates_w133.cr
73a35cf0d352d75f24efe3821e6c6ea8a5fb0ad5a7035c12b818848e031591a3  scripts/check_object_dates_w133.sh
```

Unchanged schema/parser/import and W132/W130 oracle fingerprints are those in
their executed certificates. Evidence log SHA-256 in the order above:

```text
41663e528c68091f72e932a7627687674a9955eeb0b77fc6652a34652c06ab93  probe-dates.log
475d1be423bfd7813dfe9504f1e4d986ebd212dad3660301604215c84d0a6808  red.log
a40bde8a570e99123ad570f6e97d6b43b6a7163bc8db8529748705d4ef6bae6f  focused-debug.log
c97837d426a9982ce6251d6782ad590200f2cf75aec1d2f8ce299cd3e2cbc6ac  adjacent-release.log
1e83ff3336a9d7bb9750972e90e6a146fc4fab5dc23df9c4eb9fb0d23fd70f39  full-nonrelease-shards.log
17731612b96d91440e9ef9e16e098f8eef76bd41bb15cf66549cdb0839e3f845  stock-w133.log
5a3badaecb0f2e2039948a6930a8ee47b234cce93c9e10c9cd3da5e4ecb66114  stock-w133-corrected.log
100f3ff5f0aebd6c1484dd1b38d909d9d25e4f4c5ada9a928e980c3342eeacea  stock-w132-regression.log
c37494054605a7a63d846bc9ddde878caab3183e257ceb2774591a3441fd0120  stock-w130-regression.log
```

Root hostile verdict: ROBUST within the declared profile. Root reviewed the
diff and independent stock source/probe, executed the compiler/stock gates,
and challenged signed-carrier/calendar conflation, nominal aliases, exact
budget cutoffs, wrong-nominal publication, later-part drift, ownership,
candidate/residual semantics and comparator sensitivity. Luna's implementation
and static inventory are correlated support, not independent runtime evidence.

Residuals: no DateTime/Time, wrappers, containers, BFloat16, identifiers,
FixedString/Decimal/Enum, new Object layouts, Compact/Sparse parts, arbitrary
table/multi-Object writer, whole-Object projections or broader MV execution.
Quiescent local inputs, existing checksums/metadata roster validation and
logical admission budgets do not prove Active status/snapshot consistency,
payload authentication, decoder/transient/RSS/caller-retention limits, complete
facade modularity or stock-reader speed. Decay on policy/schema/bulk/adapter,
profile/limits, comparator/publication, runtime/source/toolchain or loss of
retained evidence; rerun the affected positives and negatives before reuse.

## W135 declared UUID/IPv4/IPv6 Object fields — pre-implementation seal

Anchor: clean W134 `7bc4051`. The closed Object field policy currently admits
18 nominal types; this slice proposes three bare identifier types, not
recursive declarations or an unrestricted scalar whitelist. Shared policy
consumers are the schema constructor and parser (`rg -n
'ObjectTypedFieldType' src spec scripts examples -g '*.cr'`); existing fixed
`BinaryValue` and bulk codecs already preserve their nominal descriptors and
raw payloads. Reusing those codecs is conditional on independent physical
qualification, not their width alone.

Root inspected the isolated depth-1 source `f86ca42b6e90eadb97f7481638ff04ca1ee8e71f`:
`Formats/JSONExtractTree.cpp:614-655,1257-1339,2692-2697` admits UUID/IP JSON
strings, `IO/ReadHelpers.cpp:73-135` and `Core/UUID.h` define UUID's two
little-endian UInt64 halves, and the UUID/IP serializers define UUID bulk
bytes, little-endian IPv4 and raw network-order IPv6. Object typed fields
delegate to those nested serializers. The independently pinned runtime is
still 26.10.1.1201/build `d9bcb5ab007f0f6299f7f973f2642245bab3d028`, SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`;
the fresh source was not built.

Pre-production root probe `/private/tmp/crystal-click-w135-root.HTBUPE/probe-identifiers.log`
passes native declared-field admission, zero/asymmetric/max text and nominal
types, independently authored RowBinary and actual CHECK=1. In field order
IPv4, IPv6, UUID the asymmetric bytes are `04030201`,
`20010db81234567890abcdef11223344`, and
`7766554433221100ffeeddccbbaa9988`. These are physical witnesses, not a
universal text-parser certificate or proof for new part layouts.

Design-sealed: canonical constructor/parser and exact budgets; nominal
UUID/UInt128/IPv6 and IPv4/UInt32 separation; paired declared streams and
whole-part publication; full/middle/zero file/column, owned catalog values,
table windows and UInt64-PK candidates with application residuals. Retain
Object V3/Dynamic V3/MAP/one bucket, String 0/1 and BASIC/COMPACT discriminators,
Default serialization metadata and the existing bounded quiescent-local
profile. Sparse/Compact parts, parameterized/recursive fields, broader MV or
projection execution, arbitrary schemas and performance remain rejected or
parked. No weakening of preflight, ownership, roster or serialization guards.

Risk: CAUTION (persistent-format admission). Rollback: one exact-scope atomic
commit from `7bc4051`; do not include unrelated changes. Strongest failure:
a self-consistent round-trip hiding UUID half order or IPv6 endian errors.
Guard: independent literal bytes and stock SQL/RowBinary in both directions,
plus seeded same-width alias, byte/order, serialization, grid, CHECK and
comparator mismatches that must fail.

Execution: test-only W135 schema/root specs and replace the obsolete W132 UUID
refusal sentinel with a still-rejected type; root executes a qualified RED.
Then admit only the three policy entries, with focused DEBUG and adjacent
RELEASE. Root runs the W135 stock wrapper's eight native/library cells and
negative controls, fresh W133/W132 regressions and the complete unique spec
inventory in serial non-release groups of at most 24. DoD commands are
`crystal spec` on those files with single-module/one-thread/system-linker
flags, `W135_KEEP_TMP=1 bash scripts/check_object_identifiers_w135.sh`, unchanged
W133/W132 wrappers, formatter, `bash -n` and `git diff --check`, all under the
existing resource guard. Expected signal: zero failures and actual CHECK=1,
not merely a present output or attestation field. This slice leaves the
overarching paired-types/MV/projections goal active.

## W135 declared UUID/IPv4/IPv6 Object fields — executed certificate

Executed on 2026-10-03 over W134 `7bc4051`. The production delta is exactly
three entries in `ObjectTypedFieldType`; constructor/parser, fixed values,
bulk codecs, imports, writer publication, file/column readers and table/catalog
owners are unchanged. The closed policy now admits 21 nominal types. No
per-identifier or per-combination codec class was added. Library inputs remain
raw, nominal `BinaryValue.fixed` values with a complete declared-field roster;
this is not a text UUID/IP parser or automatic default synthesis.

Qualified profile: bare declared UUID/IPv4/IPv6 alongside String, one Int64
Dynamic path and shared String spill, hashed Wide, Object V3/Dynamic V3,
one-bucket shared MAP, Default serialization metadata, LZ4 and plain adaptive
marks/index. Seven independent rows include zero, asymmetric and maximum
identifiers, IPv4 numeric/text witnesses, canonical IPv6/UUID text, embedded
NUL/UTF-8/empty Strings, four physical marks `[2,2,2,1]` and a verified primary
index sentinel. String 0/1 × BASIC/COMPACT is tested in both directions. Source
`f86ca42b6e90eadb97f7481638ff04ca1ee8e71f` and the pinned stock executable have
the distinct identities in the seal above; the current source was not built.

Root evidence: `/private/tmp/crystal-click-w135-root.HTBUPE`. Crystal 1.21.0,
LLVM 22.1.8, AArch64; SDK
`/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`, TMPDIR `/private/tmp`,
isolated caches. Compiler/stock jobs ran serially under
`cogni-ml/scripts/run_safe.sh`, minimum free memory 50%, 32,768 MiB and the
existing FD guard. These host guards are not library memory/leak certificates.

- `probe-identifiers.log`: root's pre-production native JSON probe passes
  nominal/canonical text, independent asymmetric bytes and actual CHECK=1.
- `red.log`: the unchanged policy produces three qualified errors in four
  schema examples; the unsupported-type guard passes, outer exit 1.
- `schema-green.log`: the same four examples pass after the three entries,
  outer exit 0.
- `focused-debug.log`: nine files, 43 examples, zero failures/errors, exit 0.
- `adjacent-release.log`: 21 files, 168 examples, zero failures/errors, exit 0.
- `full-nonrelease-shards.log`: all 355 unique sorted spec files, 15 disjoint
  groups of at most 24, 2,251 examples, zero failures/errors, outer exit 0 in
  one completed invocation. Root independently summed all 15 result rows.
  Not a combined-process or full RELEASE suite. Existing duplicate `-lc` and
  deprecated `blocking` warnings remain.
- `stock-w135.log`: four fresh native identifier-JSON cells and four complete
  library-owned cells pass actual CHECK=1 (ATTACH for library parts), full/PK
  nominal/canonical SQL, IPv4 numeric witnesses and independently authored
  exact RowBinary. File/column full/middle/zero reads, independently copied
  catalog ownership/reread, table windows, offsets and whole-granule PK
  candidates with exact application residuals pass; outer exit 0.
  Twelve seeded comparator controls reject wrong bytes, five same-byte
  nominal aliases, Sparse metadata, mark grid, CHECK output, IPv4 RowBinary,
  swapped UUID halves and reversed IPv6 bytes. They prove comparator
  sensitivity, not arbitrary malformed-part rejection.
- Fresh unchanged `stock-w133-regression.log` and
  `stock-w132-regression.log`: both eight-cell matrices and their 7/6 negative
  controls pass; W133's separate stock/library raw Date32 extrema also pass.
  The enclosing `regressions.log` has outer exit 0.
- Final formatter check, wrapper/runner `bash -n` and `git diff --check` pass.

Retained oracle roots: W135
`/private/tmp/crystal-click-object-identifiers-w135.7vOT3F`, W133
`/private/tmp/crystal-click-object-dates-w133.Khl0fY`, W132
`/private/tmp/crystal-click-object-numeric-w132.Rg6vGR`.
The final production/spec/oracle fingerprints are:

```text
0cb0d76d0a3844bd55665496f24d98507e3101966293173a6f3668d86d3586b3  src/crystal_click/object_typed_field_type.cr
1353587a48dfa715c652342a2b8459bf1ad08a8f69929aff515a4f904b2c392d  spec/object_document_schema_w132_spec.cr
b0a571dd320c63a45e63d25f20fcd57fa4c70858090576d0be388a4c2b8ba2c9  spec/object_document_schema_w135_spec.cr
9d72fde785bbcf28ab7db7478aa6b262a2b38c842aabe9f6fcedf04f2d4e1428  spec/object_identifiers_w135_root_spec.cr
b47b48235206c8e4fe11556f59bba5dcfed93138f139a852632cd9a229b5cd4a  scripts/check_object_identifiers_w135.cr
da53c97d676d975fe3801289ee7f8824ed8f7cf3fac3d50d53d1899c07a96d3e  scripts/check_object_identifiers_w135.sh
```

Evidence fingerprints (relative to the root evidence directory):

```text
d16ca8e605c9c8cec7e9b3ee019dfc48cbae4e7a48a905559b6ff66faa22e84b  probe-identifiers.log
12bea9ab7cb7fdbf6789af4b99457f7d6c91eb0d3e33ea27b94c61eaaa110300  red.log
f7d2685dedccc1c589a23d09d3bddd6593552bf59d7dab76560fcf0bff0790b0  schema-green.log
40eeff935240a647e97089d1490c7f39a32a361a1dae9ca1ddd466a36ba3c6a1  focused-debug.log
c13beb68462724e3958e87c690c50d0d44a77bf6346c4ecca2401b1fc5d9e8ac  adjacent-release.log
e0f114dfb0919c1814157e09734f4874577cae7dd751cef4a744e7bb3a6f947b  full-nonrelease-shards.log
7ef4beff336d2fef9b136595693824714bd1d7a4dd32637c4ba0b17b8a1cdf91  stock-w135.log
6e94ad8b1cdda95da2adbf7065391af17cec736d849707e3db0ed5288a67f61e  stock-w133-regression.log
7f3c45ebab726e8ac2e858b815f34584ea9cfc1d23465f784c745a61fc2f4178  stock-w132-regression.log
833ddbe4befc02d23b8892e7e71c13920d8a83feadc16e90313ac5bc3137e0c9  regressions.log
756dc4d23b0d2249529cb42565a52105b01bc136b563ed738b47eb1ae5b782fb  run_full_shards.sh
e43779f890bf2bab5dd9a9aa91473e086208e780aa2e28464c862717b6bb4f5b  probe_identifiers.sh
```

Replay uses the guard/toolchain environment above, single-module/one-thread/
system-linker/error-trace flags, 600-second spec and 900-second wrapper/full
guards. Focused DEBUG files are W135 schema/root, W133 schema/root, W132
schema/root, W131 schema/root and W128 schema. Adjacent RELEASE adds the
W130 table/offline/root, W129 catalog/column/root, W128 writer/root, offline
catalog, lazy window and W87 table/catalog projection specs. The retained
`run_full_shards.sh` asserts 355 unique inputs, selects consecutive disjoint
groups of 24 from `rg --files spec -g '*_spec.cr' | LC_ALL=C sort`, runs
`crystal spec --no-debug` with those flags and asserts 15 completed groups.
Run `W135_KEEP_TMP=1 bash scripts/check_object_identifiers_w135.sh`, then the
unchanged W133 Date and W132 numeric wrappers with their KEEP_TMP variables.
This frontier is a curated evidence index, not proof by recorded fields.

Root hostile verdict: ROBUST within the declared profile. Root inspected the
three-entry production diff, schema/codec identity boundaries, latest stock
source, literal fixtures and comparators, executed the independent pre-probe
and final gates, and challenged aliases, byte/half order, exact declaration
budget cutoffs, ownership, publication and candidate/residual semantics.
The consumer helper was strengthened to assert exact mark/row counts before
the final runs, and drift uses two valid library-created parts with UUID versus
IPv6, not a forged metadata-only mismatch; admission rejects before callbacks
even when the later part is unselected. Luna's implementation/static review
is correlated support, not an independent runtime certificate.

Residuals: FixedString/Decimal/Enum, other temporal and recursive declared-field
grammars, wrappers, BFloat16, new Object layouts/versions, Compact/Sparse parts,
arbitrary-schema or multi-Object writer, whole-Object projections and broader
MV execution remain open or refused. Quiescent local inputs, logical budgets
and existing metadata/checksum validation do not prove Active status, snapshot
consistency, payload authentication, transient/RSS/caller-retention ceilings,
complete facade modularity or stock-reader speed. Performance remains parked.
Decay on policy/schema/bulk/adapter, profile/limits, comparator/publication,
source/runtime/toolchain or loss of retained evidence; refresh the affected
positive and negative gates before reuse. The overarching goal remains active.
