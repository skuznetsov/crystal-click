# JSON recursive scalar composition frontier

Document status: W181, VERIFIED within the bounded scalar laws, selected
regressions and finite paired native witnesses below (2026-10-05).
Baseline: `f2c2e17`, the W180 nominal JSON descriptor and scalar kernel.
Context: ordinary binary DataType descriptors and structured RowBinary values.
This is not a persisted Object/MergeTree layout certificate.

## Problem and current boundary

The scalar visitor already composes Array, Tuple, Map, Nullable,
LowCardinality, Variant, Dynamic, Nested and supported SimpleAggregateFunction
children. W180's JSON field validator excludes several of these existing
owners, and its row-construction preflight does not descend their value edges.
The broad wrapper exclusion is a library profile limit, not a ClickHouse
prohibition. Static JSON schema construction has its own child admission gate;
it must not be confused with runtime tagged RowBinary values.

W181 reuses the existing paired scalar grammar at JSON typed and runtime
paths, including supported leaf types, ordinary recursive containers,
LowCardinality, Variant, Dynamic, Nested and SimpleAggregateFunction. Direct
typed QBit and Nullable(QBit) remain excluded: the pinned stock runtime rejects
their JSON schema with Code 43. Generic QBit scalar support does not override
this JSON serializer boundary. Runtime Nothing continues to mean absent path.
Static Interval, BFloat16, Nullable(Nothing) and non-String Map keys were false
admissions in W180 and are corrected here. Runtime tagged values retain their
separate profile; this correction is not a generic scalar-codec type ban.

Source anchors: `DataTypeObject.cpp:185-235` constructs `buildJSONExtractTree`
even for binary serialization. `JSONExtractTree.cpp:2656-2832` recursively
checks static schema leaves and Map(String/LowCardinality(String), ...) keys,
while its default rejects unsupported types. `SerializationDynamic.cpp:862-895`
handles tagged runtime values via `ColumnDynamic.cpp:145-166` and a Variant
roster. Top Variant, Dynamic and LowCardinality(Nullable(...)) runtime tags
remain conservatively closed here; the cap-zero shared-variant route is not
qualified. These wrappers may still occur legally inside recursive children.

## Design laws

1. Re-enter the generic scalar codec, not a codec for each type combination.
2. Preserve exact nominal descriptors, selected Variant arms, LC wrappers,
   Nested names and Dynamic actual types; round trips are checked by wire and
   explicit value accessors, not ordinary BinaryValue identity equality.
3. One operation owns all descriptor, metadata and value visits. Dynamic actual
   descriptors and their selected values consume the enclosing budget at their
   rebased depth. Row preflight must not reset budgets at wrappers or siblings.
4. Validate the complete borrowed roster before allocating retained path
   records. Existing immutable value owners are retained, not cloned per row.
5. Every represented legal child combination within this admitted grammar is
   eligible; finite native witnesses are not described as exhaustive products.
6. Scalar admission never implicitly widens borrowed, bulk, Object physical,
   detached part, catalogue or file-reader admission.

## Residual rejected surface

- Nested JSON descriptors and JSON inside Dynamic are still guarded by the
  existing root-only descriptor/constructor boundary. ClickHouse supports such
  shapes; removing this boundary requires its own complete consumer inventory.
- AggregateFunction(count) beneath JSON is still guarded by the existing
  top-level-only scalar/descriptor contract. Static typed AggregateFunction is
  also rejected by ClickHouse's JSON schema tree. Runtime tagged aggregate
  states are a distinct unqualified route. Other aggregate states are absent.
- Runtime top-level Nullable normalization, SKIP/REGEXP and non-identifier path
  semantics remain unqualified. Do not label these upstream-invalid.
- QBit actual types in Dynamic remain guarded by the existing Dynamic policy.
- Persisted JSON versions/layouts and recursive storage products, Compact parts,
  broader MV/projections and allocator/performance work are not widened here.

## Plan and falsifiers

Risk: CAUTION (serialization admission and constructor resource bounds).
Rollback: revert only this atomic change from a clean baseline; no remote write.

1. Source audit: pinned shallow source `ef037e60fc7f5654c8c80eefb8be82e3c56f9a67`;
   decisive Object scalar methods and child serializers. Executed stock runtime
   remains the separately hashed `d9bcb5ab007f0f6299f7f973f2642245bab3d028` build.
2. Add independently authored tests for the newly eligible wrappers and nested
   mixed products, then record an actual RED at the W180 baseline.
3. Change `binary_json_type.cr`, `binary_json_row.cr`, and only directly affected
   diagnostics/companions if needed. Inventory:
   `rg -n 'validate_typed_type!|preflight_value_tree!' src spec -g '*.cr'` finds
   four validation consumers (type constructor, type decoder, row constructor,
   value decoder) and the row-local preflight visitor. Review all four.
4. Execute serial guarded focused and affected DEBUG/RELEASE specs. Include
   W180 paths/caps/NULL guards, existing Dynamic/Variant/LC/Nested/SAF scalar
   controls, and unchanged physical/borrowed/part refusal controls.
5. Root-run actual library-produced descriptor/value fixtures through pinned
   stock RowBinary, consume independent stock output in the Crystal helper and
   verify exact nominal/value expectations. Preserve actual child/guard status,
   input hashes, logs and source/fixture immutability.
6. Hostile checks: one-short depth/nodes/elements, many small siblings sharing
   one budget, deep Dynamic-selected trees, NULL and empty nested children,
   wrong Variant discriminator, truncated child, suffix bytes and unqualified
   storage admission. Seed a preflight traversal defect and prove a negative
   test detects it; restore exactly before the final gates.

DoD: all selected specs pass in DEBUG and RELEASE, paired finite stock witnesses
match nominal types and values, every successful heavy child/guard exits zero
without signal/timeout, expected stock refusals retain actual Code 43 (static
schema) and Code 36 (default-cap runtime roster) records, and the strongest
tested counterexample leaves the scoped result
ROBUST. Full repository coverage, full grammar-by-layout compatibility and the
overall project goal are not established by this slice.

Heavy commands remain serial and root-owned under `run_safe.sh`, 600 seconds,
12288 MiB, min-free 50 percent, isolated Crystal caches and host linker. A guard
failure is not a semantic failure or a passing check.

## Implementation and evidence seal

The three production changes are confined to `binary_json_type.cr` (distinct
typed/runtime admission), `binary_json_row.cr` (wrapper and inline Dynamic
preflight), and the runtime admission call in `binary_json_value_codec.cr`.
No new per-combination serializers, physical owners or plan admissions exist.
The existing paired generic visitor remains the serialization owner.

An actual baseline RED at `f2c2e17` reports five examples, zero failures and five
expected admission errors, child/guard exit 1. The first expanded test draft
incorrectly expected 11 Dynamic edges and fails with the element-limit error;
the independently counted and measured exact limit is 13 (15 nodes, depth 5).
The corrected test also checks public row construction, not just encoding.
It checks a 30-array selected chain (68 nodes, 66 edges, rebased depth 33), a
shared caller-owned DAG with thousands of wire occurrences, sibling budgets,
NULL/empty values, nominal wrappers, malformed discriminators and wire tails.

Root executes the same 42 spec files in six disjoint cohorts per mode:

| Cohort | Selected controls | DEBUG | RELEASE |
| --- | --- | ---: | ---: |
| A | W181 scalar/guards; four W180 scalar/guard/boundary specs; W117 value codec | 41 | 41 |
| B | W122 bulk; W152 descriptor/consumer guards; W153 value; W154/W155 bulk, adversary and shared-context controls | 63 | 63 |
| C | W120 Object structure/budget; W118 shared map; W123 documents/root/adversary; W126 file-reader root | 67 | 67 |
| D | W158 declared Dynamic/adversary; W159 recursive Dynamic/adversary | 33 | 33 |
| E | three QBit scalar/boundary/admission specs; four W178 Count argument specs | 55 | 55 |
| F | W141 LC; W147 Variant/adversary; W172 Nested/guards; W161 SAF core/recursive | 50 | 50 |
| Total | Same 42-file union per mode | 309 | 309 |

All twelve final spec children and guards exit 0, with zero failures/errors/
pending. Each gate reconciles 1,000 unchanged Crystal inputs and 1,369 fixture
files. The exact command, roster, summary, input hashes and log hashes are in
`final-{a,b,c,d,e,f}-{debug,release}.json` under the evidence root below.
The command is `crystal spec <roster> --single-module --threads 1
--link-flags=-fuse-ld=ld --error-trace`, additionally `--release --no-debug` in
RELEASE, under the unchanged resource guard and an isolated cache per gate.

Root seeds a defect that omits the Dynamic selected actual descriptor's
preflight visit. The unchanged nine-example guard spec fails two constructor
assertions, actual child/guard exit 1. Exact restoration returns
`binary_json_row.cr` to SHA-256
`679e7d1fc736ae5b2b535ebd010d2d77bf39cd437c4a526d5acfe531cb972b77`
before the final DEBUG/RELEASE gates. This is a sensitivity check, not another
green run or independent model replication.

`scripts/check_json_recursive_scalar_w181.cr` builds actual DEBUG and RELEASE
fixture emitters. `--emit-fixtures`, `--verify-library` and `--verify-stock`
use fresh direct children of `/private/tmp`. The two actual encoder outputs
are byte-identical across all 31 files (30 descriptor/row files and one hashed
source/runtime manifest). The 15 finite positive profiles are:

- Typed: LC(String); Variant(String, UInt8), selected UInt8 and NULL; Dynamic
  selecting Array(Nullable(UInt8)); Nested(n String, v UInt8); SAF(sum, UInt64);
  Array(LC(Nullable(String))); Map(String, UInt8); Map(LC(String), UInt8).
- Runtime-tagged: LC(String); the same Nested and SAF; IntervalSecond;
  BFloat16; Map(UInt8, UInt8).

The Ruby oracle `scripts/check_json_recursive_scalar_w181.rb` imports only the
older bounded process supervisor/artifact writer. Independent literal stock
captures match exact headers, descriptors and rows. The library-to-stock route
feeds the actual library descriptor header as RowBinaryWithNamesAndTypes,
with binary input-type decoding enabled, rather than substituting a SQL schema.
Both helper modes decode captured stock bytes, check nominal/value accessors
and re-encode exactly. Runtime pin: 26.10.1.1201 / `d9bcb5ab`, SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
This is distinct from the fresh source-only `ef037e60` reference.

All 15 paired profiles pass. Seven static refusals (QBit, Nullable(QBit),
Count(UInt8), numeric-key Map, IntervalSecond, BFloat16, Nullable(Nothing)) have
actual Code 43; three runtime-top refusals (Variant, Dynamic, LC(Nullable)) have
actual Code 36. These ten expected exceptions are not successful children:
their exact messages/statuses are retained and only exact matches are removed
from the unexpected-failure counter. All 42 native processes have the expected
exit and no signal, timeout or transport error; 243 artifact/input hashes are
independently reconciled. Runtime hashes/version pins match before and after.

Final reconciliation covers 21 successful guarded top-level gates: twelve spec
cohorts, eight helper build/emit/library/stock checks, and the paired native
runner. It checks source/fixture immutability, equal mode unions, actual status,
log hashes, native artifact hashes and byte-identical actual library fixtures.
An initial scratch reconciler used Ruby's unavailable `filter_map`; replacing
it with `map.compact` permits the final actual reconciliation to exit 0.
No production/source correction was required for that tooling compatibility.

Evidence roots (local scratch; no generated fixtures/binaries committed):

- Gates and final reconciliation:
  `/private/tmp/crystal-click-json-recursive-w181.qjALX7`.
- Actual DEBUG fixtures:
  `/private/tmp/crystal-click-json-recursive-library-debug-w181.AKO76z`.
- Actual RELEASE fixtures:
  `/private/tmp/crystal-click-json-recursive-library-release-w181.CN9geq`.
- Final paired native records:
  `/private/tmp/crystal-click-json-recursive-native-w181.aulTlb`.

The first native draft exposed upstream QBit schema rejection and an incorrect
LC(Nullable) array literal; neither is counted as green. The settled source-only
audit and bounded trials distinguish static Code 43 from tagged runtime
admission and default-cap Code 36. The final scope is the 15 paired witnesses
and tested budget/guard laws, not exhaustive scalar products, physical layouts
or the full repository suite. Scoped Adversary verdict: ROBUST. Independent
execution and native comparison support this verdict; Luna's same-lineage
source review remains correlated, non-executed candidate evidence.

Decay trigger: any relevant constructor/codec/limit/admission change, oracle
binary/settings/version change, source semantic drift, or consumer widening.
Refresh the affected DEBUG/RELEASE cohorts, paired native profiles, sensitivity
test and hashes before reusing this certificate. Reject or narrow claims when
the evidence no longer composes. The next frontier remains a full consumer
inventory for nested nominal JSON and separate persisted stream/state/layout
qualification; broad MV/projections and performance remain open.
