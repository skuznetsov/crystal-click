# Parameterized Tuple Leaf Frontier

Status: W101 verified within the named-flat, nonnullable Wide/LZ4/plain-mark
profile below by focused DEBUG/RELEASE, full DEBUG and pinned stock oracles.
Predecessor is
`4303639b1cfd9613c4e68e97be45a90a119bcf91`.
This is progress toward full type read/write compatibility, not a replacement
for the all-types, MV/projection and later matched-performance goal.

## Scope and design laws

Advance FixedString, Enum and Decimal together through named, nonempty, flat,
nonnullable Tuple reader, writer, owned row values, table and catalog consumers.
Keep the existing Wide/LZ4/plain adaptive mark profile and sorted UInt64 key.

- FixedString(N): canonical N from 1 through 65,536, exactly N stored bytes,
  zero-padding on value construction, one raw stream and no String size stream.
- Enum8/Enum16: signed codes and a unique label/code bijection; retain the
  complete, sorted canonical definition in a shared immutable descriptor.
  Admit canonical quoted escapes for quote, backslash, b/f/n/r/t/0, empty,
  punctuation, non-ASCII and keyword-like labels. Malformed/unknown escapes,
  duplicate decoded labels or codes and undeclared row codes remain rejected.
- Decimal(P, S): every P from 1 through 76, every S from 0 through P; preserve
  both parameters. Precision bands 1..9, 10..18, 19..38 and 39..76 select
  4/8/16/32-byte signed raw coefficients. Normalize Decimal32/64/128/256(S)
  aliases to P=9/18/38/76, Decimal(P) to S=0 and bare Decimal to (10, 0).
  There is no SQL arithmetic, coefficient rescaling or text-number conversion.

The old scalar/Array Decimal max-precision and Enum escape restrictions are
separate remaining gaps, not laws to copy into the new Tuple owner. Those APIs
and the existing raw Decimal256Value ABI remain unchanged in W101.

Use one concrete owner per file: a bounded WideTupleSchemaParser for named
flat Tuple leaf source slices; distinct FixedString, Enum and Decimal type
owners; immutable nominal value structs; and one immutable Enum definition
owner. Reuse the existing shared Tuple row/result and primitive byte codecs.
Do not add Cartesian arity/type unions or put semantic values into the numeric
identity owner. Empty buffers need explicit exact metadata; detached values
retain N, the Enum map or both decimal parameters.

The new Tuple-local parser tracks parentheses and quoted/escaped bytes, with
source/depth/node bounds no weaker than 4,096 bytes, depth 64 and 512 nodes.
Do not rewrite source with regex placeholders or alter shared AST/Node/Parser.
Apply exact spelling checks to each extracted leaf, never inside Enum labels.
Existing outer Tuple whitespace behavior and old physical-plan admission must
remain unchanged. Unsupported nested and unnamed shapes remain rejected.

Private FixedString backing bytes are copied on construction and every public
raw exposure; String#dup is insufficient. Account actual wrapper slots, the
FixedString payload exactly once and shared descriptor storage once per leaf.
Reader, writer and table/catalog row materialization must agree on charges.
Logical charges are not peak RSS or a GC/performance certificate.

The public Enum definition constructor also needs a pre-copy bound: at most
509 entries (the Tuple root and Enum type/list consume three of the 512 syntax
nodes) and at most 4,096 canonical encoded declaration bytes, including quote
escapes. This prevents a direct API call from bypassing parser-owned descriptor
bounds or making an unbounded type-name copy during writer preflight. The full
Tuple source still has its separate 4,096-byte bound. Ordinary caller-owned
input arrays and unsafe pointer mutation are not bounded by this contract.
Undeclared codes from persisted Enum streams must raise CorruptPartError;
invalid public value construction remains ArgumentError.

The value API uses `FixedStringValue.new(width, value)` and
`FixedStringValue.from_raw(width, bytes)` with defensive `raw_bytes` copies.
Decimal wrappers use raw-first constructors with explicit precision and scale;
Enum wrappers retain the complete immutable definition and signed code.
The exact-leaf constructor accepts the closed Buffer union and rejects a
wrong carrier/family or semantic descriptor rather than coercing it. Equal
Enum definitions are rebound to the leaf's one immutable definition after
full comparison, so repeated equivalent input maps cannot evade accounting.
Empty-leaf descriptor evidence belongs to model tests. The writer's existing
nonempty-part preflight rejects zero keys first; that failure is not evidence
of empty-buffer descriptor comparison and needs no artificial bypass seam.

## Default and schema context bridges

Fresh reference a9581941254d6113f3740a8ec125ee7519cb1bda is inspected source,
not a built current-master executable. Runtime qualification remains pinned to
ClickHouse 26.7.1.1315 and Crystal 1.21.0/LLVM 22.1.8 on aarch64 Darwin.

Enum SQL insertion/nested-NULL default is the smallest declared code
(DataTypeEnum.cpp:88-119), but storage statistics count raw zero
(ColumnVector.h:292-313, SerializationInfo.cpp). FixedString storage default
is all N bytes zero (ColumnFixedString.cpp:61-65); Decimal storage default is
raw coefficient zero (ColumnDecimal.h). Qualify these predicates with real
plain and separate stats-enabled parts before using them in Tuple metadata.
Statistics-only Sparse fixtures do not admit a Sparse reader or writer.

At ratio=1, SerializationInfoByName construction returns without per-column
records (`SerializationInfo.cpp:432-442`, `SerializationInfoSettings.h:45`).
The pinned executable also produced `columns:[]` for the ordinary singleton
probe. Qualify its exact global version/propagation policy and complete
physical payload without inventing default counters. Mandatory separate
ratio=0.9375 statistics fixtures establish only the observed small-fixture
default predicates; they are not current-master exact-count certificates.

DataTypesDecimal.cpp:28-39 preserves P in getName but compares only scale
within a backing family. That SQL equality cannot authorize loss of exact
persisted precision: equal raw coefficients and scale at different P remain
different owned values and must be rejected against the wrong schema.
EnumValues.cpp:41-49 sorts codes; DataTypeEnum.cpp:49-79 and WriteHelpers.h
define canonical label quoting. Encoding identity is not just signed width.

## Risk, ownership and execution order

CAUTION: public value-union and persisted serialization changes. Rollback is
one coherent local commit from the clean predecessor; preserve unrelated work.
No push, runtime/dependency installation, history rewrite or old-CH mutation.

Root owns this spec, requires, combined review and every compiler/ClickHouse
execution under the external run_safe.sh watchdog, serially. Focused/oracle
envelope is 600 seconds/8 GiB; full DEBUG is 600 seconds/32 GiB; system-free
floor is 50 percent. Workers are Luna Max, not independent review evidence.

1. Model worker owns new type/value/parser owners, WideTupleTypePlan,
   WideTupleLeafColumn, WideTupleColumnData, TupleReader and narrow WidePart
   adapters; new model/plan/reader specs and necessary obsolete negative cases.
2. Writer worker owns TuplePartInfrastructure, TuplePartWriter, narrow writer
   adapters and new writer specs. Coordinate callback contracts before edits.
3. Oracle worker owns the W101 qualified RED and final bidirectional scripts
   plus shared table/catalog consumer specs. Stock fixture qualification is
   independent of the missing library parser and future value classes.

All workers initially write tests/instruments only. Root records a compiling
plan RED and stock-qualified reader RED before authorizing production changes.
Baseline compilation or fixture construction errors are not capability RED.

Observed plan RED at unchanged production predecessor: root ran the watchdog
with Crystal `spec spec/wide_tuple_parameterized_w101_spec.cr
--link-flags=-fuse-ld=ld` (600 seconds/8 GiB, free-memory floor 50 percent).
Compilation succeeded: 9 examples, 6 expected admission failures, 0 errors,
0 pending. The Decimal matrix reported all 3,002 declarations rejected;
FixedString/Enum/alias/mixed admission groups failed. Existing outer Tuple,
malformed/scope-rejection and old Array(Tuple) controls passed. The test does
not independently certify parser depth/node limits. Production remains gated
on the separate stock-qualified reader RED at that point.

Observed qualified stock RED on the same unchanged production predecessor:
root executed `run_safe.sh /bin/bash 600 8192
scripts/probe_parameterized_tuple_w101_red.sh` with the 50 percent system-free
floor. The existing UInt64/String Tuple positive control passed. Eight
singletons and one 34-leaf mixed profile passed exact canonical metadata,
complete physical stream inventories/bytes, `[2,2,1,0]` marks, stock CHECK and
independent full/key-range RowBinary. A seeded one-byte wrong expectation was
rejected. Three separate statistics profiles observed Enum raw-zero defaults
5/5, minimum-code SQL defaults 0/5, and FixedString all-zero defaults 5/5;
Sparse child bytes were not decoded or admitted. The all-zero mixed fixture
remained guard-only. All four optional native Decimal carrier extrema profiles
were accepted by stock with unchanged complete bytes. Finally, exactly the
eight singletons plus mixed were rejected by the existing reader with
`UnsupportedFormatError: unsupported exact typed column`; the probe emitted
`EXPECTED RED` and exited 1. Prior compilation, EOF-input and absent-counter
instrument failures are not feature RED evidence. Root authorized production
implementation only after this qualified result.

## Falsifiers and Definition of Done

Supplemental compiling RED before the public Enum bound and wire-error fixes:
root ran the five W101 spec files under the 600-second/8-GiB watchdog with the
50-percent free-memory floor. Compilation succeeded: 36 examples, 5 failures,
0 errors and 0 pending. Four failures established the absent canonical-byte
bound, absent pre-validation entry-count bound, and ArgumentError leakage for
undeclared Enum8 and Enum16 persisted codes. A separate consumer candidate-key
expectation failed and must be diagnosed, not counted as Enum RED. Earlier
compiler integration failures are not feature RED. Root authorized only the
two Enum guard repairs on this evidence.

The fifth failure was a refuted test expectation, not a production index bug:
PrimaryKeyIndex selects the predecessor granule at the lower fence and all
granules whose first key is within the inclusive upper fence. Keys 1..5 in
two-row marks therefore yield all five candidate rows for [3,5]. The catalog
API delegates exact row predicates to callers. Tests must preserve this raw
superset and separately assert caller filtering to [3,4,5]; explicit selected
marks [[1,2]] still return only rows [3,4,5]. No production policy is changed.

Strongest failure: correct bytes but wrong semantic descriptor, especially an
empty buffer, same-width decimal P/S or Enum map, or borrowed FixedString bytes.

- Baseline plan RED: all 3,002 Decimal P/S declarations, 145 width aliases,
  fixed-string bounds and Enum quoted-boundary cases; controls and old physical
  plans still pass. Reject malformed, over-limit and recursive/unnamed forms.
- Stock RED: existing positive control, then source-derived singleton and mixed
  fixtures pass exact columns/substreams, complete bytes/mark inventory,
  CHECK and independent full/key-range RowBinary before typed-reader rejection.
  Cover all width bands and boundary P={1,9,10,18,19,38,39,76}, S=0/P,
  FixedString binary/NUL padding and canonical Enum escapes/maps/extreme codes.
- Ownership/model: empty metadata, kind/P/S/map mismatch, mutation after input,
  returned raw mutation, detached rows, equality/hash and wrong carrier refusal.
- Writer: all preflight faults occur before staging; exact bytes, final short
  mark, checksums/defaults, unpublished cleanup and staged comparator rejection
  for altered expected raw/parameters/maps. Internal expected-input attacks
  are not on-disk payload mutation or public mid-write recovery proof.
- Bidirectional stock oracle: actual Crystal writer inputs, ATTACH/CHECK,
  physical/key windows, table/catalog full/window/candidate/value consumers;
  positive comparator control and a seeded wrong-byte expectation rejection.
- Final focused DEBUG/RELEASE, full DEBUG, unchanged temporal/identifier/
  numeric/Bool/compositional/legacy Tuple and relevant scalar regression
  oracles; formatting, shell syntax and exact-path Git hygiene.

Root records executed commands, counts and verdict below at the frozen
source for one atomic local commit. Full RELEASE and current-master
runtime compatibility are not inferred. Refresh on schema/codec/owner/parser,
fixture/binary/compiler or relevant profile changes.

+## Reproduction commands

The declared gates use the following exact focused selection and serial
watchdog envelope. The frozen RED probe is predecessor-only and is not a
post-change gate.

```sh
export CLICKHOUSE=/Users/sergey/.local/bin/clickhouse
export CLICKHOUSE_BIN=/Users/sergey/.local/bin/clickhouse
export COGNI_RUN_SAFE_MIN_FREE_PCT=50
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
export TMPDIR=/private/tmp
export CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w101-cache
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
w101_guard=/Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh
w101_crystal=/opt/homebrew/bin/crystal
w101_focused=(
  spec/bool_tuple_consumers_w97_spec.cr
  spec/identifier_tuple_consumers_w99_spec.cr
  spec/numeric_tuple_consumers_w96_spec.cr
  spec/offline_catalog_w95_tuple_values_spec.cr
  spec/temporal_tuple_consumers_spec.cr
  spec/wide_part_reader_compositional_tuple_spec.cr
  spec/wide_part_reader_tuple_empty_eof_spec.cr
  spec/wide_part_reader_tuple_metadata_spec.cr
  spec/wide_part_table_w95_tuple_spec.cr
  spec/wide_part_writer_bool_tuple_w97_spec.cr
  spec/wide_part_writer_compositional_tuple_spec.cr
  spec/wide_part_writer_identifier_tuple_w99_spec.cr
  spec/wide_part_writer_numeric_tuple_w96_spec.cr
  spec/wide_part_writer_parameterized_tuple_spec.cr
  spec/wide_part_writer_temporal_tuple_spec.cr
  spec/wide_part_writer_tuple_spec.cr
  spec/wide_tuple_bool_model_w97_spec.cr
  spec/wide_tuple_bool_w97_spec.cr
  spec/wide_tuple_column_data_ownership_spec.cr
  spec/wide_tuple_identifier_w99_spec.cr
  spec/wide_tuple_numeric_model_w96_spec.cr
  spec/wide_tuple_numeric_w96_spec.cr
  spec/wide_tuple_parameterized_consumers_w101_spec.cr
  spec/wide_tuple_parameterized_ownership_spec.cr
  spec/wide_tuple_parameterized_reader_budget_spec.cr
  spec/wide_tuple_parameterized_w101_spec.cr
  spec/wide_tuple_row_w95_spec.cr
  spec/wide_tuple_temporal_model_spec.cr
  spec/wide_tuple_temporal_spec.cr
  spec/wide_tuple_type_plan_spec.cr
  spec/wide_type_expression_spec.cr
)
bash "$w101_guard" "$w101_crystal" 600 8192 spec "${w101_focused[@]}" --link-flags=-fuse-ld=ld
bash "$w101_guard" "$w101_crystal" 600 8192 spec "${w101_focused[@]}" --release --link-flags=-fuse-ld=ld
bash "$w101_guard" "$w101_crystal" 600 32768 spec --single-module --link-flags=-fuse-ld=ld
for w101_oracle in \
  scripts/check_parameterized_tuple_oracle.sh \
  scripts/check_typed_writer_oracle.sh \
  scripts/check_temporal_tuple_oracle.sh \
  scripts/check_identifier_tuple_oracle.sh \
  scripts/check_numeric_tuple_oracle.sh \
  scripts/check_bool_tuple_oracle.sh \
  scripts/check_compositional_tuple_oracle.sh \
  scripts/check_tuple_oracle.sh \
  scripts/check_wide_array_tuple_w51_oracle.sh \
  scripts/check_wide_array_tuple_w55_oracle.sh \
  scripts/check_bool_enum_decimal_oracle.sh \
  scripts/check_fixed_string_oracle.sh \
  scripts/check_decimal128_oracle.sh \
  scripts/check_decimal256_oracle.sh
do
  bash "$w101_guard" /bin/bash 600 8192 "$w101_oracle" || exit "$?"
done
bash -n scripts/check_parameterized_tuple_oracle.sh scripts/probe_parameterized_tuple_w101_red.sh
git diff --check
```

## Executed integration results and scoped seal

The frozen production diff passed the five W101 spec files: 36 examples,
0 failures/errors/pending. The expanded 31-file Tuple/type DEBUG selection
then passed 222 examples with the same zero-fault result. Its earlier lone
failure was an obsolete W96 negative expectation for newly admitted Decimal
and Enum leaves; those two declarations were replaced with invalid precision
and unsupported Nullable(Enum), preserving the remaining rejection controls.

The 31-file RELEASE gate also passed 222 examples, zero failures/errors/pending.
The first full DEBUG attempt omitted the predecessor's `--single-module` flag
and was inconclusive: the watchdog stopped its tree at a reported 3,548 lsof
records after about 112 seconds, before any spec result. Its fixed guard
counts lsof output lines, not a proven growing descriptor leak. The retry
restored the previously admitted W100 single-module compilation recipe with
unchanged timeout, memory/free-floor and watchdog protections; no production
code or resource guard was relaxed. It passed 1,384 full DEBUG examples,
zero failures/errors/pending, with 37.45 seconds reported spec execution.
The only reported linker warning was duplicate `-lc`. Full RELEASE was not
run and is not claimed.

The new pinned bidirectional oracle passed eight singleton schemas and one
34-leaf mixed schema through stock production, Crystal reading/writing,
stock ATTACH/CHECK, complete bytes/mark boundaries, full/key-range RowBinary,
and exact nominal table/catalog consumers. Four separate native Decimal
carrier-extrema profiles passed the same reader/writer/attach path without
implying SQL precision arithmetic. Seven storage-default controls passed;
Sparse child bytes remain unadmitted. A separate 34-leaf all-zero writer part
passed mandatory root/all-child counters, bytes, self-read and stock ATTACH.
The independent byte comparator rejected a seeded one-byte wrong expectation.

The unchanged typed-writer oracle also passed all 22 scalar/Nullable shapes
and all-null/all-empty controls, including exact rows, key ranges, CHECK and
independent payload corruption. The final W101 oracle's initial nonexhaustive
helper compilation failure was repaired in the instrument only; it is not a
compatibility result or a production guard failure. All twelve remaining
declared regression launchers passed: temporal, identifier, numeric, Bool,
compositional and legacy Tuple; W51/W55 Array(Tuple); Bool/Enum/Decimal,
FixedString and Decimal128/256. Together with the new and typed-writer oracles,
fourteen distinct pinned launchers passed. No production source changed
between the focused/full gates and these regression runs.

The final static adversary review found no defect in exact identity,
ownership, empty metadata, descriptor charging or independently constructed
byte expectations, but identified a coverage gap: the initial oracle passed
canonical declarations to the writer even when stock table creation used
Decimal aliases. The instrument now passes each original input declaration
to the actual writer and requires twelve normalization leaves in the mixed
profile (eight width aliases, bare/implicit-scale Decimal and two reordered
Enum definitions). Persisted schema, full bytes and stock attachment still
use independent canonical expectations. Root reran the complete W101 oracle:
all profiles passed, including the mixed alias/bare/implicit-scale and
reordered-Enum writer normalization, exact canonical persisted schema and
real stock ATTACH/CHECK/full and key-range RowBinary. No production admission
was widened by this instrument-only change.

Final exact-path Crystal format checks, both shell syntax checks and
`git diff --check` passed. Exact-path secret-pattern hygiene found no matches;
no generated dataset, binary or new large artifact belongs to this feature.
The existing large facade files are not new generated artifacts.

Scoped final adversarial verdict: ROBUST. Root's executed tests cover wrong
empty descriptors and carriers, N/map/P/S identity, input/output mutation,
detached values and hashing; pre-stage rejection; public Enum declaration
pre-copy limits and persisted-code CorruptPartError; and aggregate fixed-byte
budget refusal before range validation or payload callbacks. Independent
stock-byte expectations, wrong-byte sensitivity, actual reader-produced
writer buffers and real attachment prevent a symmetric reader/writer mistake
from certifying itself. The static Luna review is same-lineage and correlated,
not independent runtime evidence. Internal staged-comparator tests change
expected inputs, not disk bytes; legacy payload corruption controls do not
certify arbitrary W101 fault injection or public mid-write recovery.

This seal belongs to the coherent W101 commit containing this document, on
the recorded predecessor, compiler, SDK, host and pinned binary. Refresh the
affected gates after schema/value/parser/codec/owner/budget changes, compiler
or binary changes, or physical-profile widening. A changed fresh source
reference requires reinspection; current-master runtime compatibility is
still unverified. The all-types/MV/projection/performance goal remains active.

## Residual goal boundaries

Recursive/nullable Tuple, broader Array/Map composition, remaining scalar
parameter gaps, newer metadata/JSON/Geometry formats, general MV/projection
execution/writes, facade decomposition, power-loss and the matched <=10 percent
slowdown target remain open. Memory/performance work starts only after the
requested type and MV/projection capability frontier is implemented.
