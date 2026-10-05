# Nested logical binary frontier (W172)

Current frontier: VERIFIED within the bounded ordinary logical profile. W171 pairs a
bounded unflattened Nested Wide-part profile. W172 implements the paired
reusable logical descriptor/value/ordinary-bulk profile without widening
the complete-part writer profile.

## Contract and source anchor

The clean, shallow, unbuilt source checkout is
`/Users/sergey/SrcArchives/clickhouse-2026-10-05-depth1`, revision
`e9b645ed83ad3c07b64f09fbd014e8f770d8691b`.
`src/DataTypes/DataTypesBinaryEncoding.cpp` selects the Nested custom name
before ordinary Array, writes tag `0x2f`, a VarUInt field count, then each
binary field name and recursive descriptor. It decodes with `createNested`.
`src/DataTypes/DataTypeNested.cpp:createNested` rejects an empty roster and
constructs Array(named Tuple) directly, retaining the custom Nested name.
That shape sharing is not permission to erase nominal identity.

The executed stock oracle is separate: 26.10.1.1201, build `d9bcb5ab`, binary
SHA-256 `bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
The fresh source checkout has not been built.

## Admission and exclusions

- Exact nominal descriptor, detached field metadata, nonempty named roster,
  known-type row value and descriptor/value envelope in both directions.
- One implicit named-Tuple child models the shared Array-shaped payload;
  typed Array/Tuple constructors cannot substitute for the Nested root.
  Generic child/element accessors remain structural, not nominal casts.
- Ordinary logical bulk lanes, nonzero-origin and empty mark windows, physical
  names and both existing String serialization profiles reuse the current
  Array/Tuple kernel. Synthetic shape nodes stay in the aggregate budget.
- Existing leaf/container legality remains in force. Nullable(Nested) is
  rejected because Nested has the Array carrier, not a scalar carrier.
- Products containing both Nested and LC/Variant/Dynamic are rejected by the
  ordinary bulk and physical planner, including unrelated specialized
  siblings. Dynamic actual Nested rosters are refused in both directions.
  Descriptor/row support is not a specialized bulk-product certificate.
- Flattened shared Nested offsets, arbitrary-schema complete-part writing,
  JSON/Object declaration widening, aggregation/MV/projection execution and
  performance claims remain excluded.

## Plan, risk and rollback

CAUTION: a nominal descriptor crosses row/bulk/physical contexts and can create
budget or serializer-site mismatches. First run a literal descriptor falsifier
on the unchanged implementation. Then add a cohesive Nested descriptor owner,
small explicit dispatch changes and exact literal regression tests. Reuse
existing carriers; do not duplicate leaf codecs or render/reparse type names.
Root runs heavy checks serially with the existing run-safe guard and an
isolated cache. One atomic local commit after the checks pass is the rollback
boundary; do not push or modify the pinned source/runtime.

Strongest failure: Array(Tuple) data round-trips while nominal identity,
synthetic-node accounting or a specialized child planner is lost. Guard it
with opposite-nominal values, strict budget boundaries and explicitly rejected
unqualified products. An independently authored native descriptor/row law
must distinguish the descriptor while retaining the shared payload bytes.

## Definition of done

Root executes the new focused spec plus affected descriptor, row, bulk,
physical-name and W171 storage regression specs in DEBUG and RELEASE under the
unchanged guard (`--single-module --threads 1 --link-flags=-fuse-ld=ld`).
Expected signal: zero failures, errors or pending and actual child/guard exit
0. A stock-only retained probe must match independent literal descriptor and
row bytes in both directions; root reconciles the raw commands and outputs.
Format and `git diff --check` must pass. The hostile check attacks nominal
substitution, malformed rosters, exact consumption and aggregate limits.

This certificate decays when descriptor shape, child legality, traversal
budgets, bulk roles/names, source/runtime pins or the executed code changes.
Refresh the affected literal/native checks before reusing it as evidence.
The unchanged `deb5f9a` implementation was tested with the new literal
descriptor example under the existing guard, session `89433`, isolated
`/private/tmp/crystal-click-w172.tBcA61/cache-red`. Actual result: one example,
zero assertion failures, one runtime `UnsupportedFormatError` (`0x2f` valid
but not admitted), zero pending, child/guard exit 1. This is a capability
falsifier, not a compilation error or a successful gate.

## Executed checks and evidence scope

Root owns heavy/native checks and treats the Luna implementation as candidate
evidence, not independent model agreement. Final DEBUG passes 286 examples,
zero failures/errors/pending, actual child/guard exit 0 (session `93232`).
The preceding 37 unchanged regression specs pass 274 examples. Final RELEASE
passes the same 286 examples with zero failures/errors/pending and actual
child/guard exit 0 (session `28799`). The ordered SHA roster of all 1,168
current Crystal/Ruby/shell files under src/spec/scripts is unchanged across
the RELEASE gate; aggregate SHA-256 is
`547741b8e76c11e3e5022374e593d772b523462a31c5434a0c202f66172de585`.

The main spec initially had two instrumentation errors: missing low-byte masks
in the literal Int32 helper and the wrong outer Nullable lane name. Both are
corrected without production changes. A constructor-hole hypothesis was
refuted: the existing Tuple constructor already rejects mismatched name
counts; no redundant production check was added.

A reversible hostile mutation removes only the two descriptor implicit-Tuple
`visit_node` calls. Unchanged guards fail an assertion (6 examples, one
failure, zero errors/pending, child/guard exit 1; session `68108`). Exact
descriptor source SHA restoration
`b8a13fcafc738c7753c7d56941ea2f259667bb2260160e0564f1ef2557b2a019`
then passes six guard examples (session `30343`). Final malformed-name and
Dynamic actual-roster read guards are also in the final roster. This mutation
qualifies the tested node-budget guard, not every budget guard.

The stock-only Ruby probe passes nine raw native processes against literal
descriptors and row payloads in both directions (session `27492`). Raw argv,
SQL, stdin, stdout, stderr, status and hashes are retained at
`/private/tmp/crystal-click-w172.tBcA61/nested-binary-w172-20261005-30924-ha0n8c/manifest.json`.
Earlier attempts failed on instrument incompatibilities (system Ruby lacks
`filter_map`; a FORMAT stdin INSERT cannot have an immediate semicolon);
those attempts are not positive evidence.
`scripts/check_nested_binary_w172_source.cr` independently reconciles nine
statuses, six exact native input/output buffers and two nominal descriptors
with library-authored bytes and decoded record fields (session `84779`,
child/guard exit 0), without trusting manifest check booleans.
The finite native rows have lengths 2/0/1 and UInt64/String/Nullable(Int32)
leaves with NULL/non-NULL values. This is not universal child grammar or
arbitrary-schema complete-part qualification.

The root stock-part checker passes six exact payload lanes, every K+1 offset
and four nominal windows at mark ranges 0/3, 1/1, 1/2, 3/0 (session `78091`,
child/guard exit 0). It verifies the runtime and stock part roster hashes.
The final formatted checker also passes in RELEASE (session `43956`,
child/guard exit 0), with the same six lanes and four windows.
Input is the retained W171 stock-created flatten=0 part manifest at
`/private/tmp/crystal-click-w171.pMJBfo/nested-source-law-20261005-78412-1tiig41/manifest.json`.
Library specs additionally cover recursive Nested, ordinary Array/Tuple/Map
wrappers, both String profiles, hidden Nullable(Tuple(Nested)) defaults,
zero-row marks, empty windows, malformed descriptors and nominal substitution.
Entirely empty marks/children and recursive products have library evidence,
not fresh native whole-part qualification.

The 34-line `BinaryNestedType` invariant owner has its own file and reuses
existing bulk leaf/carrier visitors. Reader/writer/table facades stay unchanged
at 16,221/25,676/7,175 lines. Overall modularization remains open.
No performance or memory claim is made. Flattened shared offsets, additional
JSON/Dynamic/Variant layouts, AggregateFunction states, broader SAF and general
MV/projection execution/storage remain open.

Scoped hostile verdict: ROBUST for the declared ordinary logical profile
and finite native witnesses. Descriptor identity, raw row payload, physical
lanes/offsets and the tested refusal/budget guards agree. This does not close
specialized Nested bulk products, flattened shared groups, every recursive
native storage product, arbitrary-schema part writing or the whole roadmap.
Git is the lineage/rollback boundary; changed code, pins, traversal legality,
roles/names or missing captures decay this certificate and require refresh.

## Reproduction

Every Crystal check uses the unchanged
`/Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh` guard,
timeout 180 seconds, RSS ceiling 8192 MiB,
`COGNI_RUN_SAFE_MIN_FREE_PCT=50 RUN_SAFE_PASSTHROUGH_STDIO=1`,
`SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`,
`TMPDIR=/private/tmp`, and an isolated `CRYSTAL_CACHE_DIR` under
`/private/tmp/crystal-click-w172.tBcA61`.
Guard invocation is `/bin/bash <guard> /opt/homebrew/bin/crystal 180 8192
spec <roster> --single-module --threads 1 --link-flags=-fuse-ld=ld
--error-trace`, adding `--release` for RELEASE. Timeout/RSS arguments are
consumed by the guard, not passed to Crystal. Exact 39-file roster:

- `spec/binary_bulk_physical_prefix_w151_spec.cr`
- `spec/binary_bulk_w122_spec.cr`
- `spec/binary_dynamic_bulk_plan_w154_adversary_spec.cr`
- `spec/binary_dynamic_bulk_plan_w154_spec.cr`
- `spec/binary_dynamic_bulk_shared_context_w155_spec.cr`
- `spec/binary_dynamic_bulk_values_w155_adversary_spec.cr`
- `spec/binary_dynamic_bulk_values_w155_red_spec.cr`
- `spec/binary_dynamic_bulk_values_w155_spec.cr`
- `spec/binary_dynamic_descriptor_w152_red_spec.cr`
- `spec/binary_dynamic_descriptor_w152_spec.cr`
- `spec/binary_dynamic_physical_w156_adversary_spec.cr`
- `spec/binary_dynamic_physical_w156_red_spec.cr`
- `spec/binary_dynamic_physical_w156_spec.cr`
- `spec/binary_dynamic_statistics_offsets_w157_adversary_spec.cr`
- `spec/binary_dynamic_statistics_offsets_w157_spec.cr`
- `spec/binary_dynamic_value_w153_red_spec.cr`
- `spec/binary_dynamic_value_w153_spec.cr`
- `spec/binary_low_cardinality_bulk_w143_spec.cr`
- `spec/binary_low_cardinality_float_bulk_w144_spec.cr`
- `spec/binary_low_cardinality_physical_w145_spec.cr`
- `spec/binary_low_cardinality_storage_w142_spec.cr`
- `spec/binary_low_cardinality_w141_spec.cr`
- `spec/binary_nested_w172_guards_spec.cr`
- `spec/binary_nested_w172_spec.cr`
- `spec/binary_parameter_owners_w119_spec.cr`
- `spec/binary_scalar_types_w119_spec.cr`
- `spec/binary_value_codec_w117_spec.cr`
- `spec/binary_variant_bulk_w148_adversary_spec.cr`
- `spec/binary_variant_bulk_w148_spec.cr`
- `spec/binary_variant_physical_w149_adversary_spec.cr`
- `spec/binary_variant_physical_w149_spec.cr`
- `spec/binary_variant_value_w147_adversary_spec.cr`
- `spec/binary_variant_value_w147_spec.cr`
- `spec/low_cardinality_binary_codec_spec.cr`
- `spec/wide_nested_storage_w171_spec.cr`
- `spec/wide_nested_w171_admission_spec.cr`
- `spec/wide_nested_w171_metadata_spec.cr`
- `spec/wide_nested_w171_model_spec.cr`
- `spec/wide_nested_w171_staging_spec.cr`

Native invocation is `/bin/bash <guard> /usr/bin/ruby 180 8192
scripts/probe_nested_binary_w172_source.rb --source-root
/Users/sergey/SrcArchives/clickhouse-2026-10-05-depth1 --source-revision
e9b645ed83ad3c07b64f09fbd014e8f770d8691b --clickhouse
/private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped
--workdir /private/tmp/crystal-click-w172.tBcA61` with the same memory/stdout
guard environment. Root checkers use `crystal run
scripts/check_nested_binary_w172_source.cr -- <native manifest>` and
`crystal run scripts/check_nested_binary_w172_bulk.cr -- <stock manifest>`,
with Crystal flags above before `--`. Captures are retained, not committed;
missing/changed captures require a fresh probe.
