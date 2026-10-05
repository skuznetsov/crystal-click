# AggregateFunction count frontier

Status: VERIFIED within W175's paired logical codec boundary (2026-10-05).
The whole Count feature remains IN_PROGRESS: complete-part, table/catalog,
aggregation-execution and general AggregateFunction support are not admitted.
Memory/performance remains deferred until types and MV/projections are covered.

## Anchor and admission

Baseline: `ae29054be7531308b7935c62ceb2fdf2caac34c6`.
Fresh source is clean, shallow and unbuilt at
`/Users/sergey/SrcArchives/clickhouse-2026-10-05-depth1-095fae58`, revision
`095fae5865df96627496345209d6bbf2013121f3`.
Executed stock is separately pinned to version `26.10.1.1201`, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, SHA256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.

W175 admits exactly canonical `AggregateFunction(count)`,
`AggregateFunction(count, UInt64)` and
`AggregateFunction(count, Nullable(UInt64))`, version 0, no parameters,
at the top-level descriptor/value/ordinary bulk boundary. Nominal argument
identity is preserved even though all three states share a VarUInt payload.
The state value is an owned UInt64 count, not a finalized UInt64 column alias.
No arbitrary opaque state framing or aggregate execution is inferred.

Rejected in this step: other functions, argument types, versions, parameters,
outer Nullable, recursive aggregate products, LC/Variant/Dynamic aggregate
products, JSON paths and complete-part/table/catalog admission. A descriptor
argument Nullable(UInt64) does not mean the state itself has a null map.
Future guard-only frontiers: explicit Wide/LZ4 state marks and paired writer,
then typed table/window/offline consumers; general aggregate states and broader
recursive products require their own source laws and independent witnesses.

Source anchors: `DataTypesBinaryEncoding.cpp:272-307,482-487,771-777` encodes
tag 0x25, version, function name, parameters and argument descriptors;
`AggregateFunctionCount.h:111-132` and
`AggregateFunctionCount.cpp:101-123` serialize both count implementations as
VarUInt. Factory `AggregateFunctionCount.cpp:269-276` admits zero or one
argument and no parameters; this slice deliberately narrows the argument law.
`DataTypeAggregateFunction.h:51` rejects outer Nullable. Column/RowBinary
serialization is distinct from Field serialization, which frames a String.

Root ran eight isolated stock processes before implementation. The three exact
RowBinaryWithNamesAndTypes buffers match independently authored descriptor
literals with state counts 128, 127 and nullable count 1. Empty count and 16384
produce `00` and `808001`. Outer Nullable, parameters and two arguments produce
actual non-signaled type/arity errors 43/133/42. Runtime hash is unchanged.
Raw SQL/stdout/stderr/status records are in
`/private/tmp/crystal-click-w175.zKR6SD/count-law.json`; runner `count_law.rb`.
This is finite logical byte/construction evidence, not whole-part compatibility.

## Laws, risks and plan

Risk: CAUTION (shared type/value/bulk dispatch and serialization).
Rollback: only owned unstaged edits, followed by one coherent local commit;
preserve unrelated work, no push. Root owns loader/docs, guarded tests, native
probes and Git. Luna owns the bounded codec implementation and tests.

One cohesive nominal type owner and one state codec owner, each in its own
file. Do not set `fixed_width = 8`: Count uses variable-length wire bytes.
Do not reinterpret count as UInt64 or traverse its function argument as a
physical child. Reuse existing descriptor budgets and ordinary bulk roles,
mark-window axes, aggregate wire/element budgets and exact-consumption rules.
Minimal VarUInt is the existing local profile; overflow, truncation, nonminimal
encoding, trailing bytes and budget exhaustion must refuse before delivery.

Strongest failure: the UInt64 carrier appears to roundtrip while nominal
argument identity or state framing is lost, or a newly admitted descriptor
silently widens an unqualified physical consumer. Guards must attack same-value
different descriptors, 127/128 and UInt64::MAX boundaries, zero/default state,
nonzero/empty windows, malformed lengths and all rejected entry points.

Execution order:

1. Establish stock construction/byte law and actual baseline assertion RED.
   The tightened admission probe gives 2 examples, 1 assertion failure,
   0 errors/pending, child/guard exit 1; old UInt64 control passes.
2. Inventory descriptor/value/default/type-role/physical-role/bulk visitors.
   Add paired top-level Count dispatch with explicit recursive admission guards.
   `rg -n 'decode_borrowed|encode_borrowed|decode_dynamic_bulk_child|encode_dynamic_bulk_child'
   src/crystal_click` also finds context-reset callers in DynamicValueCodec,
   ObjectSharedMapCodec and ObjectDocumentSharedCodec. The borrowed envelope
   entry rejects Count independently of recursive depth; no hidden JSON/shared
   admission follows from the top-level codec. Dynamic actual rosters reject
   Count through DynamicStructure before specialized planning/data traversal.
3. Root runs focused DEBUG/RELEASE and affected descriptor/value/bulk regressions
   through the serial guard, isolated caches, `--single-module --threads 1
   --link-flags=-fuse-ld=ld --error-trace` (release adds `--release --no-debug`).
   Require nonzero examples, zero failures/errors/pending, child/guard exit 0
   and unchanged inputs. Run reciprocal stock RowBinary with independently
   authored literal expectations; a stock construction law alone is insufficient.
4. Execute a seeded nominal/VarUInt guard bypass against unchanged assertions,
   restore exact source, rerun green. Hostile review the scoped result.
5. Record actual evidence and remaining Wide/table/catalog gap before local
   commit. Reopen this certificate on any type/state/visitor/profile change.

DoD is the paired logical boundary only. The entire Count feature remains open
until explicit complete-part and consumer frontiers pass their own paired gates.
No speed, allocation, full-type percentage or general aggregate claim follows.

## Observed W175 closure

`BinaryAggregateCountType` is a 49-line nominal owner with a closed argument
enum; `BinaryAggregateCountStateCodec` is a separate 37-line VarUInt owner.
The paired descriptor, known-type scalar/envelope and ordinary normalized
bulk dispatch retain the exact nominal descriptor. Both String profiles have
the same single Count `root.data` lane. The generic children remain empty;
descriptor arguments separately consume depth/node/edge budgets in descriptor,
type-tree, physical-plan and display-name validation. Name preflight admits
the exact 24/32/42-byte names without losing the argument metadata budget.
Existing Wire/row/mark-window/nominal checks and strict VarUInt owner are reused.

Root's first post-change DEBUG compile ran 9 examples with one assertion
failure, zero errors/pending: the new physical-name oracle expected the raw
`count-col` rather than the existing escaped `count%2Dcol`. Only that expected
literal was corrected; production escaping stayed unchanged. A rerun passed.
Root then added independent same-length wrong-function, nonzero-version,
unterminated-state and restrictive name depth/node/edge/byte-budget refusals.

Final root-owned serial guarded gates pass **191 DEBUG and 191 RELEASE
examples across the same 31 unique specs**, with zero failures/errors/pending,
actual child and guard exit 0, no signals and unchanged source/spec inputs.
The roster comprises nine Count core/admission examples, three explicit native
examples, 102 affected scalar/descriptor/bulk regressions and 77 JSON/shared/
Dynamic/Variant/prefix consumer regressions. This is a selected affected roster,
not a full-repository suite.

The opt-in native spec checks the pinned stock version/build as well as three
independently literal stock-created descriptor/state buffers. Stock RowBinary
then echoes and finalizes library-authored states for all three nominal
profiles and counts 0/1/127/128/16383/16384/UInt64::MAX. Each profile matches the
same independently literal 20-byte lane and exact finalized counts. The
eleven actual stock processes per native-spec invocation all succeed. The
stock executable SHA256 is unchanged before and after the gates. Stock accepts
`80 00` as zero, whereas the library rejects it: the compatibility claim is
canonical stock-produced bytes, not equality of all accepted malformed or
nonminimal inputs. This is RowBinary/state evidence, not ATTACH/CHECK or a
complete-part witness.

Two executed seeded controls each produce 7 examples, one expected assertion
failure, zero errors/pending and actual child/guard exit 1. Ignoring Count's
nominal equality fails the unchanged distinct-descriptor assertion; removing
the borrowed Count refusal fails the unchanged expected-rejection assertion.
Root restores exact source SHA256 values
`f3267f2ec78e68f06ebfa7c063f382d9fa8674aca277b9920d050b994a99a8e1`
(`binary_data_type.cr`) and
`1fe4504342b42952a7003addf1b8d2215e155415e458cfeb13975780051422c7`
(`binary_value_codec.cr`) before final green gates. Root reconciles final log
hashes, all code input hashes and each mutant's one intentional input delta.

Scoped root adversary verdict: ROBUST. The two controls, strict malformed
lanes, independent stock bytes and affected consumers support the admitted
logical boundary. Luna's read-only hostile review is supplementary and
correlated, not independent runtime verification. Closed WidePart typed-name
admission and OfflinePartTable's same gate remain unchanged; a low-level
physical-name plan does not qualify complete part serialization/metadata.
No Count part writer, generic aggregate execution or benchmark was added.

### Reproduction and evidence index

The exact 31-spec roster, all entries under `spec/`, is:

- `aggregate_count_w175_admission_red_spec.cr`,
  `aggregate_count_w175_core_spec.cr`, `aggregate_count_w175_native_spec.cr`.
- `binary_value_codec_w117_spec.cr`, `binary_scalar_types_w119_spec.cr`,
  `binary_parameter_owners_w119_spec.cr`, `binary_bulk_w122_spec.cr`,
  `bulk_nominal_w122_spec.cr`, `bulk_budget_w122_adversary_spec.cr`,
  `bulk_string_size_w122_spec.cr`, `simple_aggregate_w161_core_spec.cr`,
  `simple_aggregate_w163_core_spec.cr`, `simple_aggregate_w164_core_spec.cr`,
  `simple_aggregate_w168_core_spec.cr`, `binary_nested_w172_spec.cr`,
  `binary_nested_w172_guards_spec.cr`, `binary_low_cardinality_w141_spec.cr`,
  `binary_low_cardinality_bulk_w143_spec.cr`.
- `object_shared_map_w118_spec.cr`, `object_documents_w123_spec.cr`,
  `object_documents_w123_root_spec.cr`, `object_documents_w123_adversary_spec.cr`,
  `dynamic_values_w122_spec.cr`, `dynamic_values_w122_adversary_spec.cr`,
  `binary_dynamic_bulk_plan_w154_spec.cr`,
  `binary_dynamic_bulk_plan_w154_adversary_spec.cr`,
  `dynamic_structure_roster_w154_red_spec.cr`,
  `binary_bulk_physical_prefix_w151_spec.cr`,
  `object_variant_prefix_w151_adversary_spec.cr`,
  `object_variant_consumers_w151_spec.cr`, `binary_dynamic_value_w153_spec.cr`.

Root runs `crystal spec <exact roster>` with the flags and guard described
above. The native gate additionally sets
`W175_CLICKHOUSE_BINARY=/private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped`.
Without that opt-in the three native examples are absent; an 188-example
library-only run is not this DoD. Verify the executable hash before/after,
require the native version/build assertion and the exact 191-example signal.
Records/logs are `w175-final-{debug,release}.{json,log}` and
`w175-{nominal,borrowed}-mutant.{json,log}` under
`/private/tmp/crystal-click-architecture-r1.shwDws`. Earlier focused RED/core/
native/regression/consumer runs are not counted as additional independent
coverage. Temporary records are an evidence index, not permanent proof; rerun
the exact roster and native probes if they are unavailable.
Exact-path formatting and `git diff --check` pass. Refresh this certificate
after any Count descriptor/state owner, shared visitor/budget, type-name,
borrowed/Dynamic guard, profile, selected spec or pinned runtime change.

## Continuation frontier

Return pointer: this W175 logical certificate, baseline `ae29054b`; the full
goal remains active. Next is explicit paired Count Wide/LZ4 parts with a sorted
UInt64 key, all three nominal signatures, compressed mark offsets, checksums,
staged semantic readback and exclusive publication. Establish an independent
stock-authored whole-part witness and an actual public admission RED before
widening the closed WidePart/type-name gates. Native ATTACH/CHECK alone must
not replace exact row/nominal/mark-window comparison. Then qualify table,
bounded window and offline `.values` consumers separately. Empty marks,
VarUInt boundary alignment and same-value/different-nominal staged mismatches
remain high-value falsifiers. General AggregateFunction, recursive products,
broader MV/projections and overall facade decomposition remain open.
Standing authority: in-scope reversible implementation, serial root-owned
gates and atomic local commits; no push, destructive history operations or
performance optimization before the type/MV/projection frontier is covered.
