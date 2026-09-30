# Identifier and Address Tuple Leaf Frontier

Status: W99 is VERIFIED within the bounded profile and executed gates below.
Clean predecessor:
`85b9b2891d5a1a78f8f303da73d510c38a78b00c`.
The full type/MV/projection goal remains active. Memory/performance work is
deferred and the matched ClickHouse slowdown target remains unproved.

## Problem and architectural boundary

Scalar and Array paths already expose nominal `UUIDValue`, `IPv4Value` and
`IPv6Value` wrappers, but compositional named Tuples reject their type names.
This whole identifier/address family can extend the existing linear owned
leaf-buffer contract without inventing raw-integer tags or Cartesian Tuple
classes. Parameterized temporal, Decimal and Enum leaves need their own exact
metadata/value contract; that work is not replaced by this family.

Reference source is the separate shallow ClickHouse checkout at
`a9581941254d6113f3740a8ec125ee7519cb1bda`. Runtime evidence must be pinned
separately to ClickHouse 26.7.1.1315. Source inspection is not a current-master
runtime certificate.

Admitted within the executed gates: named, nonempty, nonrecursive Tuple leaves `UUID`,
`IPv4` and `IPv6`, arbitrarily ordered/repeated with the existing admitted
numeric, Bool and String leaves, under the existing parser, field, stream,
mark, row and aggregate logical-byte bounds. Preserve full nominal wrapper
identity and reject primitive integer or other wrapper substitutions of equal
width. Reader, writer and the existing single `WideTupleRow` table/catalog
representation must support the same family together.

Reject: new temporal/Decimal/Enum contracts, Nullable/nested/unnamed/empty
Tuples, Sparse/Compact or new metadata layouts, arbitrary-table writing,
implicit conversions, new unguarded raw APIs, loss of byte identity,
performance claims, and a new ClickHouse executable installation. These are
library frontier limits, not claims that ClickHouse rejects those shapes.

Design laws: use one cohesive `WideTupleIdentifierType` owner/file for the
closed identities, widths, raw equality and default predicate; do not insert
semantic wrappers into `WideTupleNumericType`. Reuse existing little-/big-
endian scalar primitives and nominal wrapper encoders through the existing
private Tuple infrastructure. Each new concrete owner has one source file.
No per-arity native Tuple union or per-combination serializer class.

Risk: CAUTION (persisted serialization and public owned value unions).
Rollback is one coherent local W99 commit after verification, from the clean
predecessor; preserve unrelated work, no push/history rewrite. Strongest
failure: equal-width UUID/IPv6 values are conflated, byte order is reversed,
or primitive UInt32 can relabel an IPv4 buffer. Attack with asymmetric high/
low words and octets, high-bit/extreme/zero values and nominal mismatch tests.
Metadata/default counts, all-default parts and budget charges must also be
qualified against actual stock observations rather than primitive assumptions.

## Execution order and ownership

1. Root seals the boundary, inventories the shared consumers, and records a
   stock-created existing-API RED before production edits. The probe must
   independently qualify CHECK, schema/substreams, physical bytes, RowBinary
   and an existing numeric/Bool/String positive read. Compilation, fixture or
   metadata-instrument failures do not authorize production changes.
2. Reader/model owner: `wide_tuple_identifier_type.cr`,
   `wide_tuple_leaf_column.cr`, `wide_tuple_type_plan.cr`,
   `wide_part/tuple_reader.cr` and narrow adapters in `wide_part.cr`;
   `wide_tuple_column_data.cr` / `wide_tuple_row.cr` only if their closed
   contracts require it. Own model/reader specs and superseded type-plan
   rejection assertions. Root owns the aggregate require graph.
3. Writer owner: `wide_part_writer/tuple_part_write_input.cr`,
   `tuple_part_infrastructure.cr`, `tuple_part_writer.cr` and narrow adapters
   in `wide_part_writer.cr`; own the identifier Tuple writer spec. Validate
   every field/row/budget before the stage factory and exact staged payload
   identity before exclusive publication. Preserve Bool raw-byte guards.
4. Oracle/consumer owner: historical `probe_identifier_tuple_w99_red.cr`,
   `check_identifier_tuple_oracle.cr` / `.sh`, and
   `identifier_tuple_consumers_w99_spec.cr`. Exercise direct/ranged reads,
   full/window/candidate table scans, source and writer catalog values and
   stock ATTACH/CHECK. Root runs all guarded heavy workloads serially.
5. Root reviews the combined diff and probes the strongest counterexample,
   records actual gates/remaining gaps, performs exact-path hygiene and makes
   one local atomic commit only after the declared gates pass.

Workers are not alone in the tree and do not revert each other's work. No
worker runs compiler, tests, stock oracles or Git writes. Existing scalar
codec semantics, structural metadata/mark/checksum/null/tag guards, bounded
allocation, owned copies and exclusive publication remain unchanged.

## Falsifiers and Definition of Done

- Before production: stock-created `Tuple(value UUID)`, `Tuple(value IPv4)`
  and `Tuple(value IPv6)` must pass independent stock controls, then expose
  current typed-reader rejection using the existing API. The existing admitted
  Tuple control must pass. Independently observe default metadata under the
  exact existing physical profile, including all-default values.
- Model/reader/writer/consumer focused specs plus W94-W98 Tuple, ownership,
  numeric/Bool, plan, legacy pair and scalar identifier guards, DEBUG and
  RELEASE: zero failures/errors/pending. Include wrong nominal buffers,
  unsupported later leaves, malformed/empty-argument aliases, owned copies,
  aggregate budget overflow, zero stage calls on invalid input, later corrupt
  payload and mark schedule controls.
- `bash scripts/check_identifier_tuple_oracle.sh`: all three identities in
  mixed/reordered/repeated, identifier-only and all-default profiles, multiple
  and short final marks, exact independent complete physical and full/selected
  RowBinary bytes in both directions. Stock source values must be used for
  writer inputs. A seeded wrong-byte expectation must reject. Preserve exact
  existing profile admission rather than widening it to pass fixtures.
- Existing `check_uuid_oracle.sh`, `check_ipv4_oracle.sh`,
  `check_ipv6_oracle.sh`, `check_numeric_tuple_oracle.sh`,
  `check_bool_semantics_oracle.sh`, `check_compositional_tuple_oracle.sh` and
  `check_tuple_oracle.sh`: unchanged, zero failures.
- Full DEBUG `crystal spec --single-module --link-flags=-fuse-ld=ld`, changed
  Crystal-file format checks, shell syntax and staged diff hygiene: zero
  failures/errors/pending. Full RELEASE is not a declared gate or claim.

All heavy phases use the inspected external `cogni-ml/scripts/run_safe.sh`,
fresh 50% host free-memory admission/floor, 600 seconds and 8192 MiB focused/
oracle or 32768 MiB full DEBUG. No shared watchdog or unrelated process is
changed. These resource envelopes are not library benchmarks or leak proofs.

Root's hostile review must attack identity/endian confusion, sampled metadata
assumptions, incomplete dispatch, lost guards, budget width accounting, false
independent oracles and lazy callback ordering. Same-lineage review is
correlated support. Byte-level stock checks are the differently constructed
fallback to self-roundtrip. Stop the affected sub-boundary on mismatching
metadata/bytes; do not silently relax guards.

Evidence decays on identity/codec/dispatch/ownership, admission, budget, mark,
metadata or import changes, fixtures, compiler semantics or pinned executable
changes. The wider goal cannot be closed by this family certificate.

## Current evidence and next signal

At `85b9b28`, the owned Tuple Value/Buffer aliases contain numeric primitives,
Bool and String only. `WideTupleTypePlan` delegates widths to the primitive
owner and rejects the three semantic wrapper names. Table/catalog use the
single nominal row/leaf representation rather than their own payload codecs.
Writer `numeric_width` and `write_typed_numeric_le` already handle UUID/IPv4/
IPv6 separately; existing scalar stage validators compare their nominal raw
halves/network-order words. This is inspected implementation evidence, not
stock default-policy evidence.

Root observed the initial six-example existing-API spec RED on unchanged production using the
guarded DEBUG command `crystal spec spec/wide_tuple_identifier_w99_spec.cr
--link-flags=-fuse-ld=ld`: 6 examples, 4 failures, 0 errors/pending. The three
single-identifier admissions and mixed/repeated admission failed as expected;
the existing primitive/Bool/String and malformed-alias controls passed.
This plan-level RED does not replace the qualified stock fixture gate. The
spec was subsequently extended for post-change ownership and negative cases.

Root then ran `crystal run scripts/probe_identifier_tuple_w99_red.cr
--link-flags=-fuse-ld=ld` through the same 600-second/8192-MiB watchdog with
fresh store `/private/tmp/crystal-click-w99-red.lNmNaR`. The stock executable
was exactly 26.7.1.1315. The admitted UInt64/String and separate Bool controls
passed. All three identifier mixed fixtures passed stock CHECK, schema and
substream inventory, marks `[2, 2, 1, 0]`, complete asymmetric physical bytes
and independent full/selected RowBinary. All three all-zero fixtures also
passed CHECK and explicit zero RowBinary, and their metadata was observed.
Only then did the existing typed-open API reject UUID, IPv4 and IPv6 with the
exact `unsupported exact typed column` error. Final 3/3 rejection marker and
exit 1 were the qualified RED, not an instrumentation failure. Production
was unchanged for this run.

Each mixed single-identifier fixture had one zero and four nonzero values:
root and child metadata reported `kind: Default`, `num_defaults: 1`,
`num_rows: 5`. All-zero fixtures forced ratio 1.0, retained complete bin/mrk2
streams and reported `columns: []`, version 1, propagation true and string
serialization version 1. This did not observe an AlwaysDefault profile and
does not admit Sparse or new metadata. Default predicates may therefore use
zero raw halves/word for these nominal wrappers, without asserting that every
stock `num_defaults` count is exact under other settings or source versions.
The forced ratio-1.0 observation has nonzero keys 1 through 5 and all-zero
payloads; `columns: []` is not inferred from every table value being default.
Writer metadata emission remains the existing explicit Default records with
counted root/leaf defaults. Actual stock ATTACH/CHECK, not this source
observation alone, must qualify those writer records.

The first post-change focused DEBUG compile exposed an existing numeric
staged-readback guard that excluded only String/Bool from the widened leaf
value union. It now positively admits exactly the existing numeric identities
before raw-bit comparison; UUID/IP remain in their separate nominal branch.
That compile failure is typing evidence, not a behavioral compatibility RED.

The first compiled focused run had 162 examples, zero assertion failures and
one new test-fixture error: candidate ranges were passed to an API that
requires one increasing mark-index list per selected part. The fixture now
uses `[[0, 2]]` for the single part; production selection semantics were not
changed. The next DEBUG and RELEASE runs each passed all 162 examples, with
zero failures/errors/pending. Root also executed changed-Crystal-file format
checks, `bash -n scripts/check_identifier_tuple_oracle.sh` and
`git diff --check`, all with exit zero. The final focused DEBUG and RELEASE
runs also each passed all 162 examples after root strengthened each
validly-checksummed identifier mutation to require the exact staged payload
mismatch error.

The first full DEBUG run completed 1,279 examples with two benchmark-fixture
failures: its generator resolves `CLICKHOUSE`, while the oracle environment
provided only `CLICKHOUSE_BIN` and excluded the executable directory from
`PATH`. Both failures reported an unavailable executable, not a Tuple payload
assertion. The retry supplies both variables with the same pinned executable;
no generator or production behavior is changed to bypass the failing gate.
The corrected full DEBUG run passed 1,279 examples, zero failures/errors/pending,
with the same guarded source and pinned executable (108-second total workload;
35.44-second reported spec execution). Full RELEASE was not run or claimed.

Before the new stock run, root's oracle review corrected a copied-catalog-part
path comparison and made the seeded wrong-byte control invoke the actual byte
comparator and require its specific mismatch exception. Those are harness
repairs, not evidence of production compatibility. The expected byte encoders
do not call the reader/writer payload codec.

The final `bash scripts/check_identifier_tuple_oracle.sh` passed all three
profiles on 26.7.1.1315: mixed/reordered/repeated identifiers with UInt64,
Bool and binary String; identifier-only; and all-zero identifier leaves with
ratio 1.0. It observed exact complete physical bytes and mark rows
`[2, 2, 1, 0]`, complete/full and key-range stock RowBinary, independent
physical-mark ranges, source-to-writer inputs, real ATTACH/CHECK and full/
window/candidate table and source/writer catalog consumers. The seeded wrong
expectation was rejected by the actual byte comparator. Writer all-zero
explicit Default records counted five defaults per identifier/root and zero
key defaults, and stock retained/read those records after ATTACH/CHECK.

All seven unchanged regression oracles passed: UUID, IPv4, IPv6, numeric
Tuple, nine-profile Bool semantics, compositional Tuple and legacy Tuple.
Scalar oracle text controls provide a separately constructed nominal-value
fallback to the new oracle's independent LE/BE/RowBinary encoding.

Root's combined-diff adversarial verdict is ROBUST within this declared
profile. The executed checks cover exact nominal identity, asymmetric endian
bytes, copied ownership, repeated/reordered fields, wrong buffer/schema
matches, later unsupported leaves, row alignment and logical-budget rejection
before staging, full mark-schedule validation before callbacks, corruption,
and the exact staged identifier-payload mismatch guard. The seven unchanged
oracles check preservation of the earlier scalar, numeric, Bool and legacy
contracts. Worker reviews are correlated support, not independent evidence;
the stock physical/RowBinary/ATTACH/CHECK observations provide a differently
constructed compatibility check.

Residual limits:

- The new corruption test directly invokes the actual staged validator on a
  validly checksummed mutation. It does not inject that failure through the
  public writer and independently demonstrate failure-cleanup behavior.
  Existing publication/ensure cleanup is unchanged, not newly certified by
  this mutation test.
- UUID and IPv6 have the same raw width. An external persisted schema change
  can reinterpret those bytes; nominal API checks do not authenticate DDL.
- The 64-MiB admission is a logical materialization charge, not peak RSS,
  allocation efficiency, a leak certificate or a performance result.
- This certificate is pinned to 26.7.1.1315 and the existing Wide/LZ4/plain-
  mark profile. It does not certify current-master metadata additions, Sparse,
  Compact, recursive/parameterized Tuple leaves or arbitrary-table writing.
- Large facades and the prior Array(Map) intermediate-open cleanup concern
  remain open in `MODULARIZATION_FRONTIER.md`.

## Continuation boundary

Active goal remains full type read/write compatibility and MV/projection
support before memory/performance work. W99 is a coherent local commit from
the predecessor above; its recorded evidence belongs to that implementation,
not every subsequent source state. The commit identity is recorded in Git.
No push, executable installation or change to the old ClickHouse checkout
is part of this slice.

Return pointer: inventory the existing temporal/Decimal/Enum semantic value
contracts for compositional Tuple leaves, then qualify stock-created existing-
API rejection with exact parameter metadata, physical bytes and owned-value
requirements before widening a union. Preserve parameters and nominal identity
rather than relabeling raw integers. Recursive type compatibility and remaining
MV/projection writes follow under separate falsifiers. In-scope reversible
implementation and local commits remain authorized; remote/history actions
require a new explicit request. Refresh the relevant compatibility gates if
the evidence decay triggers above fire.

## Reproduction on this host

Run from the repository root, serially. The executable paths below are the
observed local tools, not a requirement to install another binary. Both
ClickHouse variables are needed because the legacy fixture generator and
the stock oracles use different environment names.

```bash
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
export TMPDIR=/private/tmp
export CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w99-cache
export CLICKHOUSE=/Users/sergey/.local/bin/clickhouse
export CLICKHOUSE_BIN="$CLICKHOUSE"
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
export COGNI_RUN_SAFE_MIN_FREE_PCT=50
w99_guard=/Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh
w99_specs=(
  spec/wide_tuple_identifier_w99_spec.cr
  spec/wide_part_writer_identifier_tuple_w99_spec.cr
  spec/identifier_tuple_consumers_w99_spec.cr
  spec/wide_tuple_type_plan_spec.cr
  spec/wide_tuple_column_data_ownership_spec.cr
  spec/wide_tuple_row_w95_spec.cr
  spec/wide_tuple_numeric_w96_spec.cr
  spec/wide_tuple_numeric_model_w96_spec.cr
  spec/numeric_tuple_consumers_w96_spec.cr
  spec/wide_part_writer_numeric_tuple_w96_spec.cr
  spec/wide_tuple_bool_w97_spec.cr
  spec/wide_tuple_bool_model_w97_spec.cr
  spec/wide_part_writer_bool_tuple_w97_spec.cr
  spec/bool_tuple_consumers_w97_spec.cr
  spec/wide_part_writer_compositional_tuple_spec.cr
  spec/wide_part_reader_compositional_tuple_spec.cr
  spec/wide_part_table_w95_tuple_spec.cr
  spec/offline_catalog_w95_tuple_values_spec.cr
  spec/wide_part_reader_tuple_metadata_spec.cr
  spec/wide_part_reader_tuple_empty_eof_spec.cr
  spec/wide_part_writer_tuple_spec.cr
  spec/bool_value_codec_spec.cr
  spec/bool_semantics_w98_spec.cr
  spec/wide_part_writer_bool_canonical_w98_spec.cr
  spec/wide_part_reader_w17_spec.cr
  spec/wide_part_writer_w17_spec.cr
  spec/wide_part_reader_w18_spec.cr
  spec/wide_part_writer_w18_spec.cr
  spec/wide_part_reader_w19_spec.cr
  spec/wide_part_writer_w19_spec.cr
)
bash "$w99_guard" /opt/homebrew/bin/crystal 600 8192 spec \
  "${w99_specs[@]}" --link-flags=-fuse-ld=ld
bash "$w99_guard" /opt/homebrew/bin/crystal 600 8192 spec \
  "${w99_specs[@]}" --release --link-flags=-fuse-ld=ld
for w99_oracle in \
  check_identifier_tuple_oracle check_uuid_oracle check_ipv4_oracle \
  check_ipv6_oracle check_numeric_tuple_oracle check_bool_semantics_oracle \
  check_compositional_tuple_oracle check_tuple_oracle; do
  bash "$w99_guard" /bin/bash 600 8192 "scripts/${w99_oracle}.sh" || exit
done
bash "$w99_guard" /opt/homebrew/bin/crystal 600 32768 spec \
  --single-module --link-flags=-fuse-ld=ld
```

The historical RED probe is intentionally not part of this post-change
recipe: its expected rejection belongs to the unchanged predecessor.
