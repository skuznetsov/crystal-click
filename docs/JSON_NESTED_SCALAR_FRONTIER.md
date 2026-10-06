# Nested nominal JSON scalar frontier

Document status: W182, VERIFIED within the bounded scalar laws, selected
regressions and 15 paired native witnesses below (2026-10-06).
Baseline: `682765f` (W181). Context: binary DataType descriptors and structured
RowBinary values, not persisted Object or MergeTree stream layouts.

## Problem and intended admission

JSON already has a nominal immutable descriptor and row owner. The shared
descriptor/value visitors already dispatch recursively. Root-only constructor,
descriptor and Dynamic guards prevent their composition; W181's row preflight
does not visit a nested JSON owner's path metadata and values.

The implemented change is recursive composition within the represented
scalar grammar, not a serializer per combination: JSON below Array, Tuple,
Map, Nullable, Variant, existing legal wrapper products, JSON typed/runtime
paths, and Dynamic actual descriptors. Nullable(JSON) is legal upstream;
static-schema and runtime-top restrictions remain separate. Nested preserves
its nominal descriptor with `flatten_nested=0`; the default setting rewrites
the SQL file schema into separate Array fields before decoding its rows.

Unchanged rejected consumers: physical/bulk plans, Dynamic bulk actual rosters,
borrowed persisted envelopes, persisted Object declaration/document routes,
Count argument/state products and unsupported SAF storage types. Direct
LowCardinality(JSON) must follow upstream admission rather than losing its
guard by accident. No new part writer, MV/projection execution or performance
claim is made by scalar admission.

## Design laws and risk

Risk: CAUTION (serialization and recursive resource limits).
Rollback: revert this isolated atomic change after verification; no push.

1. Reuse the shared visitors and the existing owner-per-file classes.
2. Preserve JSON caps, typed declarations, nominal wrappers and selected
   Dynamic/Variant descriptors, including NULL and empty values.
3. Nested JSON path metadata, runtime descriptors and child values use the
   enclosing operation budget at rebased depths. No fresh recursive budget may
   replace an enclosing one; public construction validates before retention.
4. Parent factory admission does not widen bulk, borrowed or physical storage
   consumers. Refusal must occur before file access or output publication.
5. Finite native examples qualify their executed profiles, not all recursive
   products or the separately fetched, unbuilt ClickHouse source revision.

## Implementation plan and falsifiers

1. Inventory constructors, descriptors, values, type-name budgets, Dynamic
   selection, row preflight and persisted/bulk/borrowed gateways. Search:
   `rg -n 'TAG_JSON|contains_json|reject_json_child|json_row' src/crystal_click
   -g '*.cr'`. Record propagation before changing shared boundaries.
2. Capture an actual baseline RED from independently authored nested literal
   specs. Compare independent stock literals before implementation.
3. Change the identified nominal constructor/codec/preflight owners; reuse
   scalar callbacks. Update only superseded root-only negative assertions.
4. Run focused and affected DEBUG/RELEASE specs serially under the existing
   600-second / 12288-MiB / 50-percent min-free resource guard with isolated
   caches and the host linker. Same selected spec union in both modes.
5. Build actual library fixture emitters, feed their binary descriptors and
   values to pinned stock, then decode captured stock bytes in both modes.
6. Attack exact/one-short depth, node, element and byte limits, shared siblings,
   deep selected Dynamic/JSON chains, nested missing/duplicate paths, wrong
   nominal child types, truncation, suffixes and unqualified storage consumers.
   Seed a skipped nested traversal and require unchanged guards to detect it.

DoD: selected specs pass in both modes; paired actual-library/independent-stock
profiles preserve exact descriptors and values; child/guard statuses, runtime
pins and immutable input/log hashes reconcile; scoped hostile review is ROBUST.
Do not commit a working feature before these signals pass.

## Implemented composition and consumer boundaries

`BinaryDataType` factories, the descriptor visitor, `BinaryDynamicEnvelope`
and `BinaryValue.dynamic` no longer impose the blanket root-only JSON rule.
Array, Tuple, Map, Nullable, Variant and Nested retain their own admission
laws. LowCardinality, QBit, Count, SAF and persisted Object roster guards are
not generally relaxed. This is one visitor per wrapper, not a class or codec
for every Cartesian product of types.

`BinaryJsonType` recursively checks a nested JSON descriptor's typed paths
under static-schema rules, even when that descriptor arrives through a runtime
path. `BinaryJsonRow` preflight visits each nested owner's path metadata,
inline runtime descriptors and child values with the same enclosing budget.
Repeated references are charged per occurrence; a shared owner is not a license
to deduplicate serialized work. Aggregate path-byte preflight occurs before
retained-name copies. Public construction still budgets path metadata bytes,
not a newly promised complete serialized-value byte total. Decoder parsing
remains bounded but is not claimed allocation-free or a two-pass decoder.

Physical and borrowed consumer inventory: `BinaryBulkTypePlan`,
`BinaryBulkPhysicalPlan`, Dynamic structure/actual rosters and child bulk
codec entries, borrowed Dynamic envelopes, and persisted Object declaration,
document and file-reader routes retain early recursive JSON refusal. Empty
values and zero read windows do not bypass it. The lower-level
`BinaryBulkVariantNamePlan` may compute a JSON-containing arm's name; it does
not publish data streams, and enclosing physical plans still refuse the layout.

## Final observed gates

Both final modes execute the same 47-spec union in six disjoint serial cohorts.
Every actual child and resource-guard exit is 0; failures/errors/pending are 0.

| Cohort | Selected controls | DEBUG | RELEASE |
| --- | --- | ---: | ---: |
| A | W182 scalar/guards/shared Dynamic; W180/W181 scalar controls; W117/W119/W152 descriptor controls | 67 | 67 |
| B | Bulk and Dynamic descriptor/roster/value/shared-budget controls | 63 | 63 |
| C | Object structure/shared-map/document/file-reader controls | 67 | 67 |
| D | Declared and recursive Object Dynamic controls | 33 | 33 |
| E | QBit and Count argument/admission controls | 55 | 55 |
| F | LowCardinality, Variant, Nested and SAF controls | 50 | 50 |
| Total | 47 specs, not the full repository suite | 335 | 335 |

Commands actually executed on the final frozen code state:

```sh
/usr/bin/ruby /private/tmp/crystal-click-json-nested-w182.3EaKEV/run_final_specs.rb debug final2
/usr/bin/ruby /private/tmp/crystal-click-json-nested-w182.3EaKEV/run_final_specs.rb release final2
/usr/bin/ruby /private/tmp/crystal-click-json-nested-w182.3EaKEV/run_paired.rb
/usr/bin/ruby /private/tmp/crystal-click-json-nested-w182.3EaKEV/reconcile.rb
```

The drivers run heavy jobs serially through `run_safe.sh`, 600 seconds,
12288 MiB, min-free 50%, isolated Crystal caches, one compiler thread and the
host linker. No guard relaxation or parallel compiler/native execution.
Eight DEBUG/RELEASE helper operations (including builds) plus the stock checker
have nine actual child/guard exit-zero operations. One DEBUG verify-library
guard prints `child setpgid ... Operation not permitted`; this warning is
retained, not treated as proof of perfect process-group containment. All
observed child statuses and bounded job outcomes still reconcile.

Final reconciliation observes 1,035 immutable Crystal/Ruby code inputs and
1,369 unchanged repository fixture files, 30 byte-identical actual helper
outputs in both modes, 32 successful stock processes, 222 native artifact/input
hash checks and 407 indexed evidence files. Formatting and `git diff --check`
pass. An initial all-green DEBUG union precedes a whitespace-only formatter
correction; the final union is rerun in full at the frozen formatted state.

The finite paired roster comprises `array_json`, `tuple_json_u8`,
`nested_json_u8`, `map_string_json`, `map_json_u8`,
`nullable_json_present`, `nullable_json_null`, `variant_json_arm`,
`variant_u8_arm`, `variant_null`, `array_tuple_json_u8`,
`json_typed_child_json`, `json_typed_child_array_json`,
`json_runtime_child_json`, and `dynamic_json` (explicit `max_types=0`).
Both paths pin `flatten_nested=0`; the actual-library input is a binary
RowBinaryWithNamesAndTypes header with binary type decoding enabled, not a
substitute SQL schema. Both helper modes decode explicit nominal/value
accessors from actual stock captures and re-encode byte-exactly.

The standalone Ruby checker proves stock acceptance of supplied bytes, not
their producer provenance. Root closes the composed claim by joining actual
build/emit/verify receipts through helper hashes, identical source hashes,
fresh output directories, all 30 output hashes and the native before/after
inventory. The curated [W182 evidence index](evidence/json-nested-scalar-w182.json)
links the executed receipts; an index is not proof by itself. Repository
Landmark packet templates/graph validator are absent, so no structural-validator
success is claimed. Reproduction needs the indexed temporary artifacts or a
fresh run with new empty evidence/fixture directories.

Scoped hostile verdict: ROBUST for the shared-budget laws, preserved consumer
guards, selected regressions and these finite scalar profiles. Same-lineage
source reviews are correlated; the executed mutation, independent source laws,
literal stock probes and root receipt/hash reconciliation supply discriminating
evidence. This does not qualify all products, SKIP/REGEXP/path semantics,
remaining JSON persisted layouts, Compact parts, MV/projection execution or
performance.

## Source and probe anchors

Source-only reference: clean depth-1
`ef037e60fc7f5654c8c80eefb8be82e3c56f9a67` at
`/Users/sergey/SrcArchives/clickhouse-2026-10-05-depth1-ef037e60`.
`DataTypeObject.h:57` explicitly permits Nullable nesting. Executed stock is
separate: 26.10.1.1201 / `d9bcb5ab007f0f6299f7f973f2642245bab3d028`, SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.

Parent laws remain local: `DataTypeNullable.cpp:29-34` asks the child's
capability; JSON and Tuple permit it but Array, Map, Variant and Dynamic do not.
`DataTypeLowCardinality.cpp:30-40` unwraps Nullable and asks the leaf's
`canBeInsideLowCardinality`; JSON inherits `IDataType.h:369` false.
`DataTypeVariant.cpp:26-35` rejects only its distinct forbidden direct arms;
`DataTypeMap.cpp:152-155` excludes nullable keys, not generic JSON keys.
Static JSON schema's narrower Map key rule still applies inside typed paths.

`DataTypesBinaryEncoding.cpp:514-541,810-871` recursively visits JSON typed-path
descriptors with the enclosing complexity counter. `SerializationObject.cpp:
1184-1230` writes row path count/names and child values; Dynamic's selected
type descriptor is a separate inline value-time edge (`SerializationDynamic.
cpp:755-780,867`). These methods are not `SerializationObject.h:27-56`'s
persisted ObjectStructure, typed/dynamic paths and shared-data substreams.

The independently authored eight-example baseline spec actually runs RED:
zero failures, eight constructor/schema admission errors, child and resource
guard exit 1. No Crystal or fixture input changes during that gate. Record:
`/private/tmp/crystal-click-json-nested-w182.3EaKEV/baseline-red.json`.

Root's initial native probe matches 11 independent literal profiles, including
JSON as a Map key and direct Nullable NULL/non-NULL. The twelfth SQL Nested
profile fails with Code 33 and a normalized Array(named Tuple) header; this
attempt exits 1 and is not counted as a successful oracle run. Evidence:
`/private/tmp/crystal-click-json-nested-native-pilot-w182.UeE0QO`.

The decisive Nested control pins `flatten_nested=0`. Both explicit-schema
RowBinary input and actual-descriptor RowBinaryWithNamesAndTypes input preserve
the independent Nested descriptor and row bytes exactly. Its four native
processes and the resource guard exit 0, with unchanged runtime pins. Evidence:
`/private/tmp/crystal-click-json-nested-native-control-w182.2t6yku`.

The corrected focused guard gate executes 29 examples with zero failures,
errors or pending cases and child/resource-guard exit 0. An earlier 28-example
attempt has two failures because its DynamicBulk test input has no Dynamic
site; it tests the wrong early rejection, not a production defect. The frozen
replacement includes a legal zero-window Dynamic control at the same site.

An executed mutation skips nested JSON row preflight. The unchanged seven-case
guard selection detects it with four assertion failures, zero errors/pending
and actual child/resource-guard exit 1. Exact production restoration is checked
by SHA-256 `f212b77c73b158e019541bedec3b9b42f7d088ebb5dd6d60252eff1d4e9c594b`.
This rejects omitted aggregate traversal of typed, shared-sibling and
Dynamic-selected JSON values; it is not a performance or whole-suite claim.

Decay: constructor/codec/admission/budget changes, runtime/settings changes,
source semantic drift or consumer widening require refreshed affected gates.
The overall goal remains all paired types plus MV/projections, followed by
memory/performance comparison; this slice does not redefine that end state.
