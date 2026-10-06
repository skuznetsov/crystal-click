# JSON Binary Kernel Frontier

W181 extends the recursive scalar child grammar and separates static typed
schema from runtime admission in
[JSON_RECURSIVE_SCALAR_FRONTIER.md](JSON_RECURSIVE_SCALAR_FRONTIER.md).
It corrects W180's static Interval/BFloat16/Nullable(Nothing)/non-String Map
false admissions. Historical admission statements below are not the current
validator contract; persisted certificates are not widened by either slice.

Previous transition: W180, VERIFIED within the bounded descriptor/scalar laws,
selected regression controls and seven paired stock witnesses, over clean base
`9cf21d3`. This is not qualification of every admitted recursive value product.
The target remains full read/write type compatibility and broader MV/projection
support before performance work. This slice is a prerequisite, not closure of
general JSON or arbitrary MergeTree schemas.

## Contract and source anchor

The source reference is the separate, clean shallow checkout
`/Users/sergey/SrcArchives/clickhouse-2026-10-05-depth1-ef037e60`, revision
`ef037e60fc7f5654c8c80eefb8be82e3c56f9a67`. The runtime oracle is independently
pinned stock 26.10.1.1201 / `d9bcb5ab007f0f6299f7f973f2642245bab3d028`, SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
It is not a build of this source checkout.

Three contracts must remain separate:

1. JSON's nominal binary DataType descriptor: tag `0x30`, version byte 0,
   VarUInt max_dynamic_paths, UInt8 max_dynamic_types, typed-path descriptors,
   SKIP paths, and SKIP REGEXP strings. See
   `src/DataTypes/DataTypesBinaryEncoding.cpp:514-543,810-873`.
2. Structured scalar RowBinary: a VarUInt path count followed by flattened
   path/value pairs. Declared values omit a type envelope; other values carry
   their actual type descriptor and scalar payload. See
   `src/DataTypes/Serializations/SerializationObject.cpp:1184-1227,1314-1447`.
3. Persisted Object bulk structure, sparse dynamic occurrences and shared
   data streams. Existing qualified owners retain their own frontier in
   `JSON_GENERAL_STORAGE_FRONTIER.md`; no scalar admission widens them.

The existing `ObjectDocument` is a physical-plan input without a JSON nominal
descriptor. A new JSON row owner must not make it a nominal Tuple/Map alias or
silently replace that persisted contract.

## Admission and explicit guards

- Root JSON v0 descriptor and structured scalar only. Caps are 0..10000 paths
  and 0..254 types; defaults 1024/32 remain nominal metadata.
  These parameters select persisted dynamic/shared placement, not scalar row
  cardinality limits. Nonempty cap-zero rows remain legal in the closed value
  grammar; independent operation budgets constrain their size.
- Unique typed paths in a bounded plain ASCII identifier profile (excluding
  case-insensitive SKIP). Preserve exact child type identity; metadata is not
  a generic physical/value child list. Typed values use a closed existing
  paired scalar/container profile, enumerated in the implementation seal.
- A row owns flattened paths and immutable BinaryValue handles. The encoder
  uses deterministic local path order without claiming upstream unordered-map
  order is canonical. Dynamic Nothing NULL normalizes to absence; typed
  Nullable NULL remains a declared value.
- Runtime actual types exclude top-level Nullable even when the cap-zero
  shared representation can accept it. Root's independent stock probe returns
  DB code 36 for both NULL and non-NULL Nullable(UInt8) under default caps;
  cap-zero shared NULL disappears, while a declared Nullable typed path
  preserves its NULL. Array(Nullable(...)) remains a separate admitted child
  profile. A row-only API must not guess history-dependent Dynamic arm admission.
- All declared typed values must be explicitly supplied. Missing declared
  defaults are valid upstream behavior but outside this first row profile.
  Duplicated raw paths are refused, not silently overwritten or skipped.
- SKIP and SKIP REGEXP descriptors, nested JSON, parent containers around JSON,
  JSON as a Dynamic actual type, borrowed persisted envelopes, ordinary bulk,
  Count arguments, arbitrary Object declared JSON and text-string mode remain
  rejected. No RE2 substitute is introduced. The predecessor/end-boundary
  SKIP behavior already observed in stock must not be replaced by a guessed
  prefix rule.
- No JSON SQL-type parser, server lifecycle, part publication, MV execution,
  projection writer or performance change in this slice.

Risk: CAUTION (shared descriptor/value grammar). Rollback: exact atomic commit
over clean `9cf21d3`; no dependency or native executable changes. The likely
failure is accidental product admission or loss of nominal type/budget
identity. Every parent/borrowed/bulk entry must refuse JSON even for empty rows,
zero windows, or unused metadata.

## Plan, consumers and Definition of Done

1. Source/literal discriminators and behavioral RED admission probes before
   production changes. `spec/json_binary_kernel_w180_red_spec.cr` uses existing
   public APIs: root observed 2 examples, 2 UnsupportedFormatError errors and
   actual child/guard exit 1 on the baseline. No missing-API compile failure.
2. Cohesive owners: BinaryJsonType, BinaryJsonTypeCodec, BinaryJsonRow and a
   private scalar companion, one owner per file. BinaryDataType/BinaryValue
   retain nominal owner handles; existing private scalar visitors are entered
   through callbacks sharing the same context/depth, not fresh per-path limits.
3. Consumer inventory: bounded `rg` of BinaryDataType descriptor/name/equality,
   BinaryCodecContext, BinaryTypeNameBudget, scalar/borrowed/Dynamic envelopes,
   bulk type/physical/default plans and Object schema/plan/value consumers.
   Complete the exact propagation roster before implementation admission.
4. Focused and adjacent serial DEBUG/RELEASE specs; stock-to-library and
   library-to-stock descriptor/row witnesses with independent literal bytes,
   nominal names and real process provenance. Runtime output ordering is not
   required to equal library ordering for multi-path rows.
5. Hostile review: wrong type aliases, mutated caller/accessor storage, duplicate
   and missing paths, Nothing versus typed Nullable NULL, malformed versions,
   max+1 caps/counts, truncation/trailing bytes, exact/one-short depth/node/edge/
   byte/name budgets, empty-value product guards and a seeded failing comparator.

DoD commands are the root-owned guarded `crystal spec` roster and
`ruby scripts/check_json_binary_kernel_w180.rb` oracle. All heavy jobs are
serial under run_safe.sh, 600 seconds / 12288 MiB / min-free 50%; guard failure
is not a passing test. Preserve actual exits, signals, timeouts, hashes and
frozen input rosters. A compile/round-trip/structural check alone does not prove
stock compatibility. Exact executed commands and results belong in the seal
after they run, not in advance.

Stop/pivot: source or stock disagreement narrows admission or changes the
representation; do not delete the disagreeing cell and report full JSON. No
strong closure without the intended diff, DoD and proportionate adversary
checks. Evidence decays on changes to these owners, input grammar, limits,
source/runtime pin or guard; refresh the affected gates. Performance remains
unmeasured and parked.

## Pre-implementation discriminators

Root's four serial pinned-stock NULL probes have actual process outcomes:
default JSON with a runtime Nullable(UInt8), NULL or non-NULL, returns DB code
36; cap-zero shared NULL returns exit 0 and the empty row `00`; declared
`JSON(x Nullable(UInt8))` retains `01 01 78 01` with exit 0. Raw records are
in `/private/tmp/crystal-click-json-null-probe.pCOMLw/records.json`.

The native runner's independent-literal preflight first fails 5/6 profiles
with zero process failures: its nullable-array literal lacked the non-NULL
flag for 255. Stock accepts those bytes but returns `[null,0,null]`, not the
expected `[null,0,255]`. The corrected observed row is
`01 04 69 74 65 6d 03 01 00 00 00 ff`. The unchanged value comparator then
passes all six literal profiles; twenty process records have exit 0, no
signal/timeout. These are runner/literal checks, not Crystal-produced fixture
qualification. Preserve both outcomes:

- `/private/tmp/crystal-click-json-w180-native-preflight.qgh070/summary.json`
- `/private/tmp/crystal-click-json-w180-native-preflight-fixed.qJR2lg/summary.json`

The four cap-only profiles are empty objects and qualify no runtime value
family. A subsequent seventh literal profile adds one runtime String at zero
caps; it passes 7/7 with 23 exit-zero processes and 129 reconciled artifact/input
hashes in `/private/tmp/crystal-click-json-w180-native-seven.Icz7dU/summary.json`.
That literal preflight remains distinct from the actual Crystal-produced inputs
below. The two typed witnesses are UInt8 and Array(Nullable(UInt8)); they are
not a certificate for every admitted recursive scalar product.

## Implemented API and closed value grammar

`BinaryJsonType` owns immutable nominal caps and detached, sorted typed-path
metadata. `BinaryJsonTypeCodec` owns the v0 descriptor. `BinaryJsonRow` owns
flattened row paths and immutable value handles. The private
`BinaryJsonValueCodec` owns the structured scalar envelope and calls the existing
scalar visitors under their enclosing context/depth. Each owner has its own
file. This does not merge the older persisted `ObjectDocument` contract into
the nominal kernel.

```crystal
type = CrystalClick::BinaryDataType.json(
  max_dynamic_paths: 1,
  max_dynamic_types: 1,
  typed_paths: {"n" => CrystalClick::BinaryDataType.primitive("UInt8")},
)
row = CrystalClick::BinaryJsonRow.new(type, [
  {"n", CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[42_u8])},
] of Tuple(String, CrystalClick::BinaryValue))
value = CrystalClick::BinaryValue.json(type, row)
wire = CrystalClick::BinaryValueCodec.encode_value(value)
decoded = CrystalClick::BinaryValueCodec.decode_value(type, wire).json_row
```

The implementation admits existing fixed-width leaves (numeric, temporal,
Decimal, Enum, FixedString, UUID/IP and Interval), Bool and String, recursively
through Array, Map, Tuple and legal Nullable. Declared direct Nothing is refused;
Nullable(Nothing) can carry only NULL. Runtime top-level Nullable is refused;
Array(Nullable(...)) is a distinct legal child product. JSON, QBit, Count,
Dynamic, Variant, LowCardinality, SimpleAggregateFunction and Nested remain
outside this JSON child grammar. Paths are plain ASCII identifiers, at most
256 bytes, excluding case-insensitive SKIP; dotted/escaped path semantics are
not claimed. The 1000 typed-path ceiling is subordinate to the shared operation
budget, not a guarantee that every 1000-path graph fits default limits.

Descriptor and row metadata consume shared depth/node/edge limits before
retained copies. Copying accessors have no-copy byte-size accessors for aggregate
preflight. Known-schema scalar operations do not synthesize wire-byte charges
for a descriptor absent from the wire. Row caps are not cardinality or type-count
limits. Child BinaryValue equality retains the existing ordinary handle-identity
policy; no general semantic equality of decoded JSON trees is claimed.

## Executed implementation seal

Root ran all heavy gates serially, without relaxing the 600-second / 12288-MiB /
50-percent min-free guard. Crystal is 1.21.0 / LLVM 22.1.8 on aarch64; compiler
flags are `--single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace`,
plus `--release --no-debug` in RELEASE. Each invocation uses an isolated cache.
The common executed command form is:

```sh
env COGNI_RUN_SAFE_MIN_FREE_PCT=50 RUN_SAFE_PASSTHROUGH_STDIO=1 TMPDIR=/private/tmp \
  SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk \
  /Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh /usr/bin/ruby 600 12288 \
  /private/tmp/crystal-click-json-w180.23uZU9/run_gate.rb LABEL MODE SPEC...
```

The identical 33-spec DEBUG/RELEASE union is disjointly partitioned:

| Cohort | Specs | Examples per mode | Final record labels (DEBUG / RELEASE) |
| --- | ---: | ---: | --- |
| Focused JSON | 5 | 27 | `w180-restored-focused-debug` / `w180-restored-focused-release` |
| Dynamic controls | 10 | 63 | `w180-final-dynamic-debug` / `w180-final-dynamic-release` |
| Object core | 7 | 67 | `w180-final-object-core-debug` / `w180-final-object-core-release` |
| Recursive Object | 4 | 33 | `w180-final-object-recursive-debug` / `w180-final-object-recursive-release` |
| QBit/Count controls | 7 | 55 | `w180-final-nominal-controls-debug` / `w180-final-nominal-controls-release` |

Exact rosters, executable argv, actual child exits/signals, summaries and
input/log hashes are in each `LABEL.json` and `LABEL.log` under the scratch root.
For standalone reruns, the exact cohort specs are:

```text
Focused JSON:
spec/json_binary_kernel_w180_red_spec.cr
spec/json_binary_kernel_w180_spec.cr
spec/json_binary_kernel_w180_guards_spec.cr
spec/json_binary_kernel_w180_boundary_spec.cr
spec/binary_value_codec_w117_spec.cr

Dynamic controls:
spec/binary_bulk_w122_spec.cr
spec/binary_dynamic_descriptor_w152_spec.cr
spec/dynamic_descriptor_consumer_guards_w152_spec.cr
spec/binary_dynamic_value_w153_spec.cr
spec/binary_dynamic_bulk_plan_w154_spec.cr
spec/binary_dynamic_bulk_plan_w154_adversary_spec.cr
spec/binary_dynamic_bulk_values_w155_spec.cr
spec/binary_dynamic_bulk_values_w155_adversary_spec.cr
spec/binary_dynamic_bulk_shared_context_w155_spec.cr
spec/dynamic_structure_roster_w154_red_spec.cr

Object core:
spec/object_dynamic_structure_w120_spec.cr
spec/object_dynamic_structure_w120_budget_spec.cr
spec/object_shared_map_w118_spec.cr
spec/object_documents_w123_spec.cr
spec/object_documents_w123_root_spec.cr
spec/object_documents_w123_adversary_spec.cr
spec/object_file_reader_w126_root_spec.cr

Recursive Object:
spec/object_declared_dynamic_w158_spec.cr
spec/object_declared_dynamic_w158_adversary_spec.cr
spec/object_recursive_dynamic_w159_spec.cr
spec/object_recursive_dynamic_w159_adversary_spec.cr

QBit/Count controls:
spec/qbit_binary_kernel_spec.cr
spec/qbit_binary_kernel_object_boundary_spec.cr
spec/qbit_binary_kernel_w179_admission_spec.cr
spec/aggregate_count_arguments_w178_core_spec.cr
spec/aggregate_count_arguments_w178_parser_spec.cr
spec/aggregate_count_arguments_w178_plan_spec.cr
spec/aggregate_count_arguments_w178_admission_spec.cr
```

All ten final child and observed guard exits are 0, signals absent; totals are
245 DEBUG and 245 RELEASE examples, zero failures/errors/pending. Root independently
reconciles all final records against 996 unchanged live Crystal inputs and 1369
unchanged fixture-roster files. This is not a complete repository-suite run.
Earlier focused attempts exposed a private class-method visibility compile
error, a readonly String-slice mutation in the ownership test, and an Int64 cap
constructor compile error. Those attempts are retained, not counted as green;
the API converts caps to retained widths only after validating their domain.

### Actual paired stock witnesses

Both helper builds emit actual `BinaryDataTypeCodec` / `BinaryValueCodec`
outputs after comparing them with independent literal bytes; they do not write
the literals as encoder evidence. DEBUG and RELEASE reproduce identical manifests
and fourteen descriptor/row files (15 files total):

- `/private/tmp/crystal-click-json-w180-library-debug.onBY5e`
- `/private/tmp/crystal-click-json-w180-library-release.kk9azs`

Root executes `scripts/check_json_binary_kernel_w180.rb --library-root` against
those DEBUG bytes with evidence root
`/private/tmp/crystal-click-json-w180-library-native-final.oS2o3E`. The stock oracle passes
7/7 profiles, with 23 actual process exits 0, no signals/timeouts/process failures,
and 129 independently reconciled artifact/query-input hashes. It checks both
descriptor identity and literal decoded JSON values, not only byte round-trips.
Runtime SHA and actual two-field version/build output match before and after.
Both compiled helper modes execute `--verify-stock` on the actual captured
`stock_to_library` bytes, decode the values and re-encode them exactly. The six
helper child/guard exits and native-driver exit are 0. An earlier DEBUG stock
verification emits a short-lived-child `setpgid` permission warning; its actual
child and guard exit are still 0. Both final stock-verification calls have no such
warning. This does not certify the supervisor's containment under failure.

The finite profile IDs are `bare_json`, `caps_0_0`, `caps_0_0_runtime_string`,
`caps_1_1`, `caps_10000_254`, `typed_uint8_n` and
`typed_nullable_uint8_array_item`. Only the String, UInt8 and nullable-array cells
carry nonempty values. None is a whole JSON-part, broad recursive grammar or
fresh-source-built runtime certificate. Exact helper/driver commands and frozen
inputs are in `w180-helper-*.json` (final verification labels end in `-final`)
and `w180-library-native-final.json` at the scratch root. The native gate is
repeated after correcting only the runner's CLI profile-count help text; both
actual-library native runs pass, and the final runner hash is reconciled.

### Adversary result and recovery

Root temporarily bypasses only the early JSON guard in
`BinaryBulkPhysicalPlan.from_escaped_prefix`. The unchanged boundary spec fails
with actual child/guard exit 1: two examples, one failure, no errors/pending. The
invalid `%` prefix reaches an unrelated ArgumentError instead of the required
JSON-specific UnsupportedFormatError. Exact restoration returns the owner to
SHA-256 `90b4254e74d2774864693d2b60b3eb5b8a4bbc1d75b95d2367012a08c6e1c1f9`;
the final focused DEBUG/RELEASE gates pass after restoration. Other final input
hashes match that restored state. Record: `w180-escaped-guard-mutation.json`.
The native comparator also rejects changed/truncated/appended byte vectors in
its own self-test; this is not a seeded full-runner failure certificate.

Scoped hostile verdict: ROBUST for the tested nominal/scalar laws, early product
guards and seven finite paired witnesses. General persisted JSON, broader child
qualification, SKIP/regexp/path expansion, MV/projection execution and performance
remain open. Root's `reconcile_final.rb` checks statuses, matching rosters/hashes,
helper binaries and byte reproduction; it is an evidence-index consistency check,
not proof of semantics by itself. Refresh affected behavior/native gates if owners,
grammar, budgets, source/runtime pins or compiler/guard context change. Removal of
temporary traces requires regenerating the evidence, not assuming their old green
status.
