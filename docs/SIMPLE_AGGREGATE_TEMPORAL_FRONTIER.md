# SimpleAggregateFunction temporal paired frontier — W170

## State and authority

Status: VERIFIED within the canonical temporal stored-value profile below
(2026-10-05), not all SAF or aggregation execution. Production baseline:
clean `4fcb223a492491003bac5c79f6d23990d492d437`. The preceding W169 Decimal
slice changed authoritative state and passed its declared gates. The overall
all-type/MV/projection goal remains active; memory/performance stays deferred.
Risk: CAUTION (nominal identity, temporal parameters, fixed-width dispatch,
and staged publication). Root owns serial guarded execution, independent
verification and local git. Luna owns disjoint inventories/implementation
only within the measured construction law. No push authority.
Rollback: restore only owned W170 edits before a coherent commit, or revert
the eventual atomic W170 commit; preserve unrelated work.

## Factual anchor and admitted boundary

Source: clean shallow unbuilt
`/Users/sergey/SrcArchives/clickhouse-2026-10-05-depth1`, revision
`e9b645ed83ad3c07b64f09fbd014e8f770d8691b`.
Executed stock is separately pinned to `26.10.1.1201`, VERSION_GITHASH
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, executable SHA256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
Existing ordinary temporal descriptors, raw leaf codecs and explicit writers
did not establish temporal SAF support at the baseline.
`BinaryDataType.simple_aggregate` then refused the temporal tags; the SAF
grammar accepted only eligible numeric/text/Decimal children.
Its public numeric raw-width gates must stay
closed to temporal wrappers.

Admitted families: Date, Date32, DateTime with exact optional timezone,
DateTime64 with exact scale/optional timezone, Time and Time64 with exact scale.
Complete-part shapes: scalar and outer Nullable. The nine existing
canonical unary non-parametric SAF functions are probed against each family;
no function eligibility is inferred merely from raw integer width. Existing
timezone-name admission is reused, not silently expanded to every system zone.
The accepted construction law is frozen from source plus actual pinned-stock
construction. Generalized scale/zone admission and finite native witnesses
remain distinct.

Root executes the stock construction matrix and independently reconciles its
raw SQL/stdout/stderr/status files without importing the worker oracle:
36 temporal forms x 2 shapes x 9 functions = 648 declarations; 288 exact
accepted descriptors, 360 non-signaled Code 43 type refusals, plus 2 Code 43
forbidden-Time-timezone controls. Both actual runtime pins and executable
hashes match. All 368 raw processes reconcile; child and guard exit 0.
Final frozen-runner replay:
`/private/tmp/crystal-click-w170.LLRxwh/law-stock-2`; independently reconciled
again with identical outcomes. Runner SHA256 before/after is
`a891beae39deaff1c7777ae4f9e3533d4a3b4a666fa89b1370dda1661e863a53`.
The earlier `law-stock-1` run also reconciles but is not the final runner-input
certificate. Source remains clean/shallow at the pinned revision.
Forms are Date/Date32/Time, bare DateTime plus UTC/Berlin/32-byte-zone witnesses,
bare DateTime64 and Time64 at every scale 0..9, and DateTime64 at scales 0/3/9
with each zone witness. The only temporal SAF functions admitted by this law
are any/anyLast/min/max; sum/sumWithOverflow/groupBitAnd/Or/Xor stay refused.
Construction evidence alone does not qualify binary or complete-part I/O;
the separate paired execution below supplies that evidence within its scope.

Source anchors: `DataTypeCustomSimpleAggregateFunction.cpp:158-165` checks
aggregate-result equality against the factory-reconstructed child;
`DataTypeDateTime.cpp:33-38` ignores timezone and
`DataTypeDateTime64.cpp:57-62` compares scale but ignores timezone. The library
deliberately retains exact original zone tokens even where stock equality is
coarser. SingleValue construction is shared by any/min/max; sum's numeric
dispatch and bitwise's integer-only dispatch do not admit temporal families.
`registerDataTypeDateTime.cpp:453-494` rejects Time/Time64 timezone parameters.
The actual probe pins `enable_time_time64_type=1` and UTC session timezone.

Admitted now: previously verified W163/W164 numeric, W168 text and W169 Decimal
profiles, plus W170 temporal any/anyLast/min/max, scalar or outer Nullable.
Rejected temporal functions: sum/sumWithOverflow/groupBitAnd/Or/Xor.
Guard-only future:
inner Nullable/LC, recursive whole-part SAF products, aliases/function parameters,
AggregateFunction state serialization, Compact and aggregation execution.
Ordinary temporal/primitive accessors and inferred writer admission must not
widen as a side effect. General MV materialization and projection generation
are separate frontiers.

## Laws and discriminating evidence

- Preserve exact function, nominal temporal family, scale, timezone token,
  carrier signedness/width and outer nullability across descriptor/value/bulk,
  public Wide writers/readers, batches/windows and offline column `.values`.
- Canonical scalar-child parsing may contain a comma for DateTime64's timezone;
  that does not permit extra function arguments, malformed leaves, inner wrappers
  or ordinary unbounded recursive SQL parsing.
- Temporal readback must pass an exact semantic gate before raw bytes are read.
  Same-width primitive reinterpretation is a refusal test, not an alternative API.
- Validate payload and parameters before staging. Reopen completed marks through
  public semantic readers before publishing. Consume nested nullable bytes even
  beneath NULL and retain whole-intersecting-mark budgets before callbacks.
- One cohesive declaration/storage-plan owner and one staged-validation owner
  per responsibility, not one class per function/family pair. Keep fixed-width
  codec, metadata/checksum, resource and publication owners separate.

Strongest likely failure: DateTime64 scale or timezone disappears while same-width
integer values still roundtrip. Native/library parts must use independent raw
literal coefficients and exact type metadata. CHECK-valid same-width nominal
and value mutations must fail the unchanged original oracle. A reversible
staged-comparison bypass must fail unchanged tests for scalar and Nullable.
Timezone-bearing names at the inherited maximum length test parser bounds;
malformed/unknown zones, out-of-range scales, foreign families/carriers and
ordinary primitive/temporal accessors provide guard checks.

## Execution order and Definition of Done

1. Inspect exact source factory/result/equality laws. Inventory the core and
   public consumers before changing shared grammar or dispatch. Root executes
   an independently retained stock construction probe in an isolated scratch
   directory; actual type errors are distinguished from runtime failures.
2. Add baseline behavioral admission tests using existing APIs. Root requires
   assertion RED with a positive old-profile control, not compiler failure.
3. Freeze the admitted/refused law and exact file ownership, then implement
   paired core and public consumers, reusing ordinary temporal leaf owners.
4. Root executes focused DEBUG and bounded affected RELEASE regressions with
   nonzero example counts, zero failures/errors/pending, actual child/guard
   exit 0 and unchanged source/spec/support inputs.
5. Independently authored stock and library complete Wide/LZ4 parts must pass
   ATTACH/CHECK, exact descriptor/type metadata and full/middle/empty RowBinary
   checks. The new source snapshot is not claimed runtime-qualified.
6. Root attacks identity, dispatch and staged validation, restores exact source,
   reruns green and reconciles counts, rosters and hashes. Update this SDD and
   PROJECT_STATUS before an atomic local commit; no push.

Root runs one compiler/native process group at a time through
`/Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh`, isolated Crystal
caches, `--single-module --threads 1 --link-flags=-fuse-ld=ld`; RELEASE adds
`--release --no-debug`. Scratch root: `/private/tmp/crystal-click-w170.LLRxwh`.
Exact observed commands/counts and a scoped hostile verdict are recorded after
execution. Format/Ruby/Bash/diff checks are structural additions, not native
compatibility evidence. If source laws and runtime disagree, freeze or narrow
only the unresolved admission pending a discriminating probe; do not count
arbitrary nonzero status as type rejection.

## Continuity

Baseline falsifier executed on unchanged production: guarded `run_gate.rb
baseline-red red spec/simple_aggregate_w170_admission_red_spec.cr` observes
6 examples, 3 intended assertion failures, 0 errors/pending, Crystal child 1
and guard 0. UInt64 and Decimal128 controls pass. All 309 hashed source/spec/
support/page inputs are unchanged. The failures are temporal construction,
long-zone scalar construction and the 89-byte outer-Nullable parser; they are
not compilation failures. This proves the baseline gap, not the implemented
feature's native compatibility.

The chosen design adds one shared `TemporalStorageType` leaf owner, using the
existing exact DateTime/DateTime64 grammar and one Time64 scale grammar, rather
than duplicating leaf parsing between the binary descriptor and runtime plan.
Raw carrier readers/batches explicitly name `temporal_raw`; the full temporal
child name remains a required argument. They do not convert zones/calendars or
perform aggregation. Public inferred writers and numeric SAF APIs keep their
existing primitive storage-name map; the private explicit writer pipeline
gets separate temporal preflight, stream and staged-validation gates.

Frozen ownership: Luna core owns `temporal_storage_type.cr`,
`binary_simple_aggregate_type.cr`, `binary_data_type.cr`,
`simple_aggregate_column_type.cr`, optional `binary_data_type_codec.cr`,
and W170 admission/core specs. Luna consumers owns the new temporal SAF plan
and private staged validator, `wide_part.cr`, `wide_part_writer.cr`,
`wide_part_table.cr`, `offline_table.cr`, `wide_part/simple_aggregate_column_reader.cr`,
and W170 runtime/staging/projection specs. Luna oracle owns W170 support,
native specs and paired qualifier scripts. Root owns loader requires, docs,
guarded execution, independent attacks/reconciliation and local git.
All workers preserve others' edits and run no compiler/native/git-write jobs.

## Observed closure and limits

The three new cohesive owner files are `temporal_storage_type.cr` (108 lines),
`simple_aggregate_temporal_storage_plan.cr` (140), and
`wide_part_writer/staged_simple_aggregate_temporal_part_validator.cr` (167).
The private staged owner is stateless and retains no slices, callbacks or
resources after return. Reader/writer/table facades remain
16,174/25,647/7,152 lines. These new capability owners are not a certificate
of a behavior-neutral extraction or completed architecture cleanup.

Root-owned final gates pass 503 DEBUG and 503 RELEASE examples. Each mode
uses the same 43 unique specs in three disjoint groups; names below denote
`spec/<name>.cr`:

1. **Core — 302 examples:** `simple_aggregate_w170_admission_red_spec`,
   `simple_aggregate_temporal_w170_spec`, `simple_aggregate_w168_core_spec`,
   `simple_aggregate_decimal_w169_spec`, `simple_aggregate_w164_core_spec`,
   `simple_aggregate_w163_core_spec`, `simple_aggregate_w161_guards_spec`,
   `simple_aggregate_w161_recursive_spec`, `binary_parameter_owners_w119_spec`,
   `timezone_temporal_model_w104_spec`, `timezone_temporal_admission_w104_spec`.
2. **Runtime — 80 examples:** `wide_part_simple_aggregate_temporal_w170_spec`,
   `wide_part_simple_aggregate_decimal_w169_spec`,
   `timezone_temporal_consumers_w104_spec`, `timezone_temporal_writer_w104_spec`,
   `wide_part_writer_nullable_temporal_spec`, `nullable_temporal_scan_spec`,
   `wide_part_writer_leaf_seam_spec`, `wide_part_writer_typed_spec`,
   `wide_part_writer_typed_mark_readback_spec`,
   `wide_part_writer_plan_owners_w90_spec`,
   `staged_typed_numeric_validator_w162_spec`, `staged_stream_file_set_w113_spec`,
   `staged_typed_string_validator_w165_spec`, `staged_fixed_string_validator_w167_spec`.
3. **Consumers — 121 examples:** `simple_aggregate_w161_core_spec`,
   `simple_aggregate_w161_wide_spec`, `simple_aggregate_w163_wide_spec`,
   `simple_aggregate_w164_wide_spec`, `simple_aggregate_w168_wide_spec`,
   `binary_value_codec_w117_spec`, `binary_bulk_w122_spec`, `bulk_nominal_w122_spec`,
   `offline_catalog_w76_spec`, `offline_catalog_w77_spec`,
   `offline_catalog_projection_w87_spec`, `wide_part_table_projection_w87_spec`,
   `offline_mv_materialization_w88_spec`, `offline_tui_page_source_spec`,
   `decimal_column_type_w102_spec`, `decimal_precision_admission_w102_spec`,
   `decimal_precision_consumers_w102_spec`, `wide_part_writer_decimal_precision_w102_spec`.

Every positive child/guard exits 0, with zero failures/errors/pending and
unchanged inputs. `final-{core,runtime,consumers}-{debug,release}` are the exact
scratch labels. Each command is the serial environment/guard above, followed
by `/usr/bin/ruby 600 12288 /private/tmp/crystal-click-w170.LLRxwh/run_gate.rb
<fresh-label> <debug|release> <exact spec paths in that group>`.
The runner invokes `/opt/homebrew/bin/crystal spec` with the flags above and
`--error-trace`; it hashes all current source/support plus selected specs,
`spec_helper.cr` and the offline page adapter before/after execution.

The paired native gate is `native-final-frozen`, output root
`/private/tmp/crystal-click-w170-native.LLRxwh-5`. The same serial guard invokes
`/usr/bin/ruby 1200 12288 /private/tmp/crystal-click-w170.LLRxwh/run_native_gate.rb
<fresh-label> <fresh native output root>`; it calls the committed
`scripts/check_simple_aggregate_w170.sh` with explicit opt-in runtime/root.
Both actual native spec examples pass, with zero failures/errors/pending,
child/guard exit 0 and 315 unchanged inputs. Pinned stock produces one
289-column Wide/LZ4 part (UInt64 key plus 288 temporal profiles), with five
rows and 2/2/1 marks plus EOF sentinel. Exact schemas, binary descriptors and
full/middle/empty raw windows match. The independently library-authored 288
complete parts pass stock ATTACH/CHECK and all 864 literal RowBinary windows.

Three CHECK-valid mutants are rejected by the unchanged exact/literal oracle:
UTC-to-Berlin metadata, DateTime64 scale 3-to-4 metadata, and same-type raw
value 0-to-1. Root independently recomputes leaves, profiles, descriptors,
literal bytes, SQL membership, logs and statuses without importing the worker
oracle/support: 10,360 checks over all 322 raw native processes. The separately
reconciled construction law has 650 checks over all 368 raw processes. The
180 scalar refusal controls in the native descriptor fixture are not the
360 actual scalar/Nullable construction-law refusals or extra native parts.

Separate scalar and Nullable staged-comparison bypasses each yield five
examples, one intended assertion failure, zero errors/pending, Crystal child
1 and guard 0. Both fail because an injected mark-1 semantic mismatch no
longer raises `CorruptPartError`; unchanged tests detect lost validation.
Labels: `scalar-comparison-bypass-red-v2` and `nullable-comparison-bypass-red`.
Exact owner restoration is hash-checked after each mutation;
`restored-runtime-debug` passes five examples. The first scalar mutation
inverted the guard instead of bypassing it (four errors), so it is excluded
from seeded or positive evidence. Earlier fixture/runner candidate failures
(mutable String slice, generic cast/override, missing fixture parent,
binary-output scan, 16-column adapter cap and existing detached directory)
are likewise not counted as positive gates.

Root reconciles all current positive rosters, actual logs/statuses, both
intended seeds and restored green: 5,247 checks, 358 unique current
source/spec/support/page/script inputs. Format, Ruby/Bash syntax and diff
checks are structural additions, not native proof. Correlated Luna static
review supports the independent source/byte/control evidence but does not
add an independent executed gate. Scoped hostile verdict: ROBUST for the
declared canonical logical stored-value profile.

This API preserves raw codes/ticks and exact leaf tokens; it performs no
calendar/timezone conversion or aggregation. Canonical scales 0..9 and the
inherited bounded timezone grammar are admitted; stock witnesses cover the
36 listed coordinates, not every timezone or physical layout. Default
serialization, Wide/LZ4 scalar/outer-Nullable parts are qualified here, not
Compact, inner Nullable/LC, recursive whole-part SAF, aliases/parameters or
AggregateFunction states. Size/presence checks are not content-hash validation;
semantic readback does not certify canonical placeholder bytes underneath
NULL. Whole intersecting marks are decoded before callbacks, but callbacks
from earlier marks may escape before a later mark fails: scans are not atomic.
Fixed-width temporal budgets are statically bounded by the inherited
65,536-row/mark and 16-column caps; no dedicated overflow mutation is counted.
Existing MV/projection regressions are bounded consumer checks, not general
MV execution or projection-generation compatibility. The fresh e9 source
checkout remains unbuilt and separate from the executed d9 runtime.

Current frontier: broader paired type/layout/SAF and MV/projection support,
plus responsibility-level architecture cleanup. The next bounded neutral
ownership candidate is Array-numeric staged validation; it is not implemented
by this capability slice. Memory/performance stays deferred. No stock-reader
speed parity or all-type percentage is claimed.
Changes to source/binary, temporal codecs/grammar, SAF dispatch, staging,
settings or toolchain invalidate the corresponding certificate. Missing
temporary evidence requires replay, not promotion of historical counts.
