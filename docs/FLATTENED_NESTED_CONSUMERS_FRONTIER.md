# Flattened Nested consumers frontier — W174

Status: VERIFIED within the explicit consumer boundary (2026-10-05).
Baseline: clean `6f4f548`.
Risk: CAUTION (explicit table/catalog schema admission).
Rollback: one scoped local commit; no push. Performance remains deferred.

## Boundary and authority

Admit an explicit typed table binding for the W173 physical profile: exactly
one simple UInt64 key followed by the declared direct scalar/Nullable Nested
siblings, in declaration order, with the exact shared root.size0 references.
The caller supplies key, group and nominal type. Every selected part must
match that same key and declaration, including group-only and key-only
selection. Reuse the part factory's complete metadata envelope and root/key
row/mark-axis validation before returning the table; do not reimplement its
physical parser or relax ordinary readers.

Public table route:
`WidePartTable.open_selected_flattened_nested_typed(parts, columns, key_name,
group_name, type_name)`. Selection contains only the key and/or nominal root.
Full typed scans, bounded row windows and typed candidate-mark scans reuse
the existing Nested adapter and nominal `nested_rows_for` accessor.

Public offline route: `table.with_flattened_nested(group_name)` returns a
separate bound read-only view. It requires an exact two-column, non-ALIAS DDL
roster `[key UInt64, group Nested(...)]`, exact MergeTree table kind and the
supported simple UInt64 ORDER BY key. It derives the declared type from DDL,
copies the binding and DDL inputs, and does not mutate the ordinary catalog
table. Existing typed scans/windows, column `.values` and UInt64-PK candidate
scans route through the explicit table factory. Candidate scans include the
key and return whole candidate granules, not exact predicate results.
The legacy physical `scan_uint64` and `scan_numeric` routes must explicitly
refuse this bound view; use `scan_typed` for key-only reads with the group
envelope preflight intact. Ordinary unbound tables retain their old behavior.

The binding is authority for a nominal client view, not proof that stock DDL
originally used Nested. Offline candidates are not server Active proof.
Assume stable immutable parts during opening/reading, as W173 does. Eager
metadata/schema/mark checks do not certify all leaf payloads or whole-scan
callback atomicity. Values remain bounded owned materializations; transient
batch views retain their existing callback lifetime contract.

Rejected: implicit dotted-name inference, sibling-only DDL as nominal proof,
unknown/dotted/duplicate selections, other key names/types, mixed unrelated
columns, multiple groups, recursive container leaves, independent offsets,
Compact/Sparse, MV data execution, new projection context mapping, general
table writing, concurrent rewrite snapshots and performance admission.
Ordinary table/catalog/projection APIs remain unchanged and closed to this
flattened context. The W173 paired part writer is unchanged.

## Source anchor and existing consumers

Source checkout is clean/shallow/unbuilt at
`/Users/sergey/SrcArchives/clickhouse-2026-10-05-depth1`,
`e9b645ed83ad3c07b64f09fbd014e8f770d8691b`. Executed stock remains separately
pinned to 26.10.1.1201 build d9bcb5ab and SHA256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
W173's source laws and finite physical evidence are inherited, not expanded.

Executed baseline: the independently stock-authored retained flat1 part at
`/private/tmp/crystal-click-w171.pMJBfo/nested-source-law-20261005-78412-1tiig41/stores/nested-flat1/store/21d/21d594ac-eac8-4bcf-bc8e-4c25d2081226/all_1_1_0`
is refused by `WidePartTable.open_selected_typed([part], ["pk", "nested"])`
with `UnsupportedFormatError: duplicate physical stream name`. Root guarded
session `4712` compiles and exits 0 only after observing that expected refusal.
This is behavioral RED, not a missing API/compile failure.

Bounded inventory: `rg` on the selected table factories, constructor dispatch,
Nested adapter/accessors and offline reader factories found:

- `wide_part_table.cr:2437-2445,6716-6865`: ordinary and projection factories,
  eager all-part construction, per-part axes and cross-part selected sources.
- `wide_part.cr:1598-1624`: explicit W173 factory already validates root/key,
  but its returned selected schema does not expose a complete table roster.
  An explicit expected key avoids treating group-only selected-schema equality
  as a complete cross-part identity certificate.
- `wide_part_table/array_tuple_column_adapter.cr:3-54`: existing Nested charge,
  read and install seams; no new materializer/accessor is required.
- `offline_table.cr:65-144,1390-1445,1574-1621`: bounded owned `.values`, PK
  index candidate construction, typed reader and DDL/source comparisons.
- Projection factory/scan paths stay ordinary; no base context propagation.

## Plan and falsifiers

1. Capture actual baseline refusal on the independently stock-authored flat1
   part through the ordinary table route, not a missing-method compile error.
2. Add a small immutable table-context owner and a dedicated typed factory.
   Bind the expected key through W173 even when it is unselected; reuse eager
   all-part construction and existing scan kernels.
3. Add a separate offline DDL-binding owner/view and narrow dispatch seams.
   Validate exact DDL before returning the view; do not change catalog inference
   or MV/projection semantics. Snapshot caller/view schema inputs.
4. Root runs focused and affected serial guarded DEBUG/RELEASE rosters, a
   retained stock part consumer probe, then a reversible expected-key bypass
   against an unchanged guard. Reconcile exact values independently of a
   script PASS label; restore source before final verification/commit.

Strongest failure: a group-only read accepts a second part with an unexpected
key, or a DDL binding silently admits sibling Arrays instead of nominal Nested.
Guards: wrong expected key; second-part key/roster/mark defect before callbacks;
key-only invalid serializer; mutation of caller binding inputs; wrong DDL
type/order/key/alias/kind; ordinary API refusals; nominal accessor separation;
full/nonzero/empty/end windows, row/cell bounds, PK candidate granules and
detached `.values` ownership. Existing W173 guards retain shared-offset laws.
Include a single-field Nested control for the legacy numeric route: there is
no repeated shared-offset name to accidentally enforce the context refusal.
Deliberate caller/getter corruption uses `String#to_unsafe` only on owned
copies: Crystal 1.21 `String#to_slice` is read-only and `dup` returns self.
The flag `OfflineColumn#key_candidate_column` means an unmodified declaration,
not actual ORDER BY membership; the separate parsed key is authoritative.

Root's additional behavioral RED uses `Nested(a UInt64)` with keys `[1, 2]`,
row sizes `[1, 0]` and element `[9]`. The bound view's legacy `scan_numeric`
accepts before the fix: seven guard examples, one actual assertion failure
(`Expected UnsupportedFormatError but nothing was raised`), zero errors/pending,
child/guard exit 1. The ordinary numeric route validates its selected key and
does not use the explicit context; a single sibling has no duplicated size0
reference to accidentally reject that route. Add the entry refusal only on
bound views, directing callers to the contextual `scan_typed` path.

DoD commands: unchanged resource guard, serial `crystal spec <declared roster>`
in DEBUG and RELEASE, retained-stock consumer script, `tool format --check`
on exact edited Crystal files, and `git diff --check`. Expected signals:
zero failures/errors/pending and actual child/guard exit 0; independent literal
keys/Nested values/window/candidate outputs match; seeded bypass produces an
assertion failure and exact restore passes. Root independently reviews Luna's
diff and attacks the boundary before a scoped VERIFIED claim.

Refresh this certificate after any relevant context/DDL/parser/reader/table/
adapter/fixture or source/runtime change. Broader type, MV/projection and
architecture frontiers remain open.

## Executed evidence — 2026-10-05

Final root-owned gates pass **212 DEBUG and 212 RELEASE examples**, with
zero failures/errors/pending and actual child/guard exit 0. Each mode uses
the same 37 unique spec files in two disjoint groups; the ten new W174
examples are included, not added again. Names below mean `spec/<name>.cr`.

1. Core — 109 examples, 26 specs:

   - `wide_flattened_nested_consumers_w174_spec`
   - `wide_flattened_nested_consumers_w174_guards_spec`
   - `wide_flattened_nested_w173_spec`
   - `wide_flattened_nested_w173_guards_spec`
   - `wide_nested_w171_admission_spec`
   - `wide_nested_w171_model_spec`
   - `wide_nested_w171_metadata_spec`
   - `wide_nested_w171_staging_spec`
   - `wide_nested_storage_w171_spec`
   - `wide_array_tuple_w107_admission_spec`
   - `wide_array_tuple_w107_metadata_spec`
   - `wide_array_tuple_w107_model_spec`
   - `wide_array_tuple_w107_reader_spec`
   - `wide_array_tuple_w107_leaf_matrix_spec`
   - `wide_array_tuple_w107_consumer_spec`
   - `wide_part_writer_array_tuple_w107_spec`
   - `wide_tuple_nested_w106_admission_spec`
   - `wide_tuple_nested_w106_model_spec`
   - `wide_part_reader_nested_tuple_w106_spec`
   - `wide_part_writer_nested_tuple_w106_spec`
   - `wide_map_tuple_w108_admission_spec`
   - `wide_map_tuple_w108_model_spec`
   - `wide_map_tuple_w108_reader_spec`
   - `wide_map_tuple_w108_consumer_spec`
   - `wide_part_table_projection_w87_spec`
   - `offline_catalog_projection_w87_spec`

2. Catalog — 103 examples, 11 specs:

   - `offline_catalog_spec`
   - `offline_catalog_w27_spec`
   - `offline_catalog_w28_spec`
   - `offline_catalog_w29_spec`
   - `offline_catalog_w95_tuple_values_spec`
   - `lazy_window_reader_spec`
   - `wide_part_table_w95_tuple_spec`
   - `wide_tuple_row_w95_spec`
   - `pk_candidates_spec`
   - `offline_mv_materialization_w88_spec`
   - `part_checksums_spec`

The exact serial command is `env COGNI_RUN_SAFE_MIN_FREE_PCT=50
RUN_SAFE_PASSTHROUGH_STDIO=1
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
TMPDIR=/private/tmp /bin/bash
/Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh /usr/bin/ruby
180 8192 /private/tmp/crystal-click-w174.ENwqcL/run_gate.rb
<core|catalog>-<debug|release>-final-v2 <debug|release> <exact spec paths above>`.
The runner invokes `/opt/homebrew/bin/crystal spec` with isolated caches,
`--single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace`;
RELEASE adds `--release`.

Root's independent `reconcile_gates.rb` checks actual raw log summaries,
child statuses, exact commands/membership, log digests and all 939 current
Crystal source/spec/script/example input hashes. Inputs are unchanged during
each gate and equal the final source state. Final record SHA256s:

- `core-debug-final-v2.json`:
  `8c9c5a6ab7ba45c9f5d44af13f35d82f78a9036990c268346007cc0fe8539fd3`.
- `catalog-debug-final-v2.json`:
  `078218bf69555b32c2a46577cfe76cf6477351f7bea6885aaa74b7f24711cc9e`.
- `core-release-final-v2.json`:
  `2b8ba9bc238dd5a223c9e3b630537efee0ceeaf3320223c7b5659eade1d6454b`.
- `catalog-release-final-v2.json`:
  `31d5db20391a4787ced76e5b6dd51c850b9bc5300a80a0d4e45ec2129d916b03`.

Root deliberately bypasses the expected key in the context owner against the
unchanged example `binds the expected key on every selected part before
group-only callbacks`: one example, one assertion failure, zero errors/pending,
child/guard exit 1. Exact restoration passes one example with child/guard
exit 0. The restored owner SHA256 is
`29e7508e808417579811cb749c8207d8b55a31ab27a53a8de17c6c1077f42152`;
the unchanged main spec SHA256 is
`751e91f5a73fbe2914104d57a6c219c112cf9473926feb58f5502d50cd6ca8fa`.
The earlier single-field numeric-route RED is a separate production defect
control, not part of the positive totals. Its final example also checks
ordinary numeric key reading and contextual typed key/root reading.

The final retained-stock consumer command uses the same serial guard at
180 seconds/8192 MiB around
`/usr/bin/ruby /private/tmp/crystal-click-w174.ENwqcL/run_consumer_final.rb`.
That runner executes `crystal run
scripts/check_flattened_nested_consumers_w174_probe.cr` with the same compiler
flags and an isolated cache, then `-- --consumer <retained part above>
/private/tmp/crystal-click-w174.ENwqcL/stock-consumer-final.json`.
Actual Crystal child and guard exit 0. Before/after checks reconcile all
23 original file names/kinds/sizes/SHA256s against the original manifest
`d750895dda6325942ca62a32d74d5aa1e4a3b50425d172138ac2d278a414805d`.
All 939 compiler inputs remain unchanged and match the final gates.

Root's independent `reconcile_consumer.rb` compares literal keys, Nested
elements, nominal types, sources, exact DDL, owned values and full/nonzero/
empty/end/candidate windows: **255 checks**, exact match. For bounds 23..31
the keys are `[22, 31]`, intentionally conservative whole-granule candidates.
The result SHA256 is
`fab790d5b538c7169162bfd632ad045f7efd3d4361b5b26c35579f20dda69a3c`;
the consumer command/status/input record SHA256 is
`6c5b24d52750e00f1f725a1bb4bee80d39ecaeaf4c8c22ca3698cb8107032bf1`.
This reads a previously stock-authored part; no fresh stock ATTACH/CHECK,
writer qualification or execution of the unbuilt source checkout is counted.
W173's paired writer certificate is unchanged and inherited.

Exact eight-file `crystal tool format --check` and `git diff --check` pass.
The two new cohesive owners have 57/46 lines; the reader/writer/table/offline
facades remain 16,284/25,705/7,222/4,049 lines. This is a bounded capability
separation, not proof of complete modularization or better performance.

Scoped adversary verdict: **ROBUST** for the explicit table/offline binding
and its stated refusal/ownership boundaries. Stock evidence is one finite
three-leaf profile, not all admitted leaf products; all-zero element marks
retain library-only evidence. Ordinary key-only physical reads can still
succeed on a single-field flattened part: it is the explicit bound view's
legacy-route bypass that is closed, not all physical-key reading.
Hash/size evidence does not establish eager payload validation or callback
atomicity. General discovery, recursive/specialized Nested products, broad
MV/projection contexts and arbitrary-schema writing remain open.

This certificate is scoped to the declared inputs and stable immutable parts.
Refresh it after changes to the context/DDL/parser/reader/table/adapters,
fixture, source/runtime or toolchain. Temporary logs/scripts are replay aids
and may decay; if missing, rerun the recorded commands and literal controls
rather than trusting counts or stored digests alone.
