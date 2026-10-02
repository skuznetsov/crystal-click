# General JSON Storage Frontier

Status: W115 stock capture and W116 independent physical/type qualification
executed on 2026-10-02. The precise missing-capability RED is qualified, not
resolved. General JSON
document reading/writing is not admitted. W24/W72 declared scalar projections
remain the only paired JSON capability; see `JSON_TYPED_PATH_FRONTIER.md`.
The target is a reusable Object/Dynamic/shared-data engine, not another exact
declaration registered in the existing facades. Performance work remains parked.

## Source anchor and compatibility boundary

The separate shallow reference checkout is
`/Users/sergey/SrcArchives/clickhouse-2026-10-01-depth1-935de744`, revision
`935de7442d7890eb5631372e4ad6f66faaf35f90`. Its source informs the design; it
is not the build provenance of the runtime oracle. The initial runtime is
ClickHouse 26.10.1.1201, build `d9bcb5ab007f0f6299f7f973f2642245bab3d028`,
Mach-O SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
Its measured outputs must not be described as current-master executable evidence.

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

Use one concrete owner per file for distinct responsibilities, not per schema
combination. Reuse bounded frame/mark access and primitive leaf codecs; keep
generic Variant admission closed. Separate the Object envelope/path dictionary,
binary DataType/value decoding, Dynamic lane schedules, shared-data layout,
owned nominal document values, document reader, and staged writer orchestration.
Schema parsing must preserve JSON parameters and typed declarations; admitting
only a spelling of bare `JSON` is not a substitute for these physical profiles.

The first production codec must handle the binary DataType descriptor followed
by that type's single-value serialization, shared by Dynamic SharedVariant and
Object MAP values. Bulk column serializers are not substitutes for that scalar
grammar. Require bounded recursive decoding, exact cursor consumption, nominal
type identity and floating-point raw-bit preservation. Its first falsifiers
include indistinguishable JSON text for differently typed empty arrays,
truncated or noncanonical type/value encodings, trailing bytes and exhausted
depth/element/byte limits. This codec alone will not admit whole-document JSON;
dictionary, lane/rank, mark and shared-data schedule owners remain necessary.

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
