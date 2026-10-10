# Recursive Dynamic declaration handoff frontier

Status: W249 VERIFIED / root adversary ROBUST within the finite target below.
Root observed the behavioral RED before authorizing production edits.
Baseline: `a5a02c8a4b9d317d5266814683df3871fbe66dc5`, initially clean.
The overall legal-type, MV/projection and subsequent performance goal remains open.

## Problem and factual anchors

The generic Dynamic writer, reader, role planner and physical binder already
recurse through Array, nominal Nested, Tuple and Map. Public table/offline
consumers recheck `DynamicBulkColumnDeclaration`, whose borrowed Object grammar
forces String Map keys and disables declared Dynamic beneath Nested. Its
one-root Nested adaptation does not solve that contextual mismatch.

Recursive composition is the implementation strategy, not a deferred codec
per Cartesian product. The distinction is between single-value serialization
and persisted bulk streams: Array changes the child occurrence domain through
offsets, LowCardinality owns a dictionary, and each Dynamic site owns its
structure/actual roster and shared overflow. A generic recursive plan must carry
those states and occurrence axes. Knowing every leaf does not by itself qualify
every physical version or legal constructor edge, but an already-bound child
does not need another wrapper-specific value codec.

Fresh separate upstream shallow snapshot:
`fe0f91b6c3de9e1efa33a1bce4ca9bcbfb4c509d` (2026-10-10T09:01:51Z).
Nested, Array, Tuple, Map, Dynamic and their examined serializer/metadata sources
are unchanged from `f25eb93a0b890a3b87df05eb34e2af1f933b4089`.
`DataTypeNested.cpp:51-75` recursively factories named children and preserves
the custom nominal name; `DataTypeMap.cpp:152-155` excludes Nullable and
LowCardinality(Nullable) keys, not non-String keys.

The separately pinned stock runtime is 26.10.1.1201, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, executable SHA256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
An isolated stock probe accepted root Nested, Array(Nested), Tuple(Array(Nested)),
recursive Nested and Map(UInt64, Nested), all with declared Dynamic. It preserved
nominal declarations, wrote/read empty and populated/null/mixed-type rows, and
returned CHECK TABLE=1. This proves stock legality for those witnesses, not local
interoperability or every legal Map key.

Tuple serializer metadata and physical tuple descendants are different axes.
Stock Tuple `createSerializationInfo` exposes child metadata; Array/Nested/Map
use generic metadata. The stock probe matches the existing Tuple-only metadata
validator. Do not widen that validator just because physical traversal recurses.

## Intended admission laws

Reuse the existing bounded borrowed-slice recursive declaration preflight with
an explicit Dynamic-owner profile, separate from the unchanged Object default.
Preserve inherited root depth and bounded descriptor/metadata/name work. Remove
product-specific root Nested rewriting. Syntax acceptance is not physical
admission.

The admission profile is immutable preflight state and must survive borrowed
source revalidation, accounting and materialization. Its default remains the
existing Object/JSON grammar. The standalone Dynamic owner charges its own root
before preflight accounts descendants; Object field callers already represent
that root and must not be charged twice. Extreme inherited depths must fail as
budget errors before Int32 child-depth arithmetic can overflow. The obsolete
root-only adapter's oversized-source nil result becomes the shared preflight's
explicit byte-budget error; syntax refusal and Object default outcomes stay
unchanged.

The neutral type-name reader is not a safe drop-in at this boundary: it fixes
parsing at root depth one and converts budget failures to nil. W211's declaration
contract includes raised budget failures and descriptor/name accounting before
proportional materialization. A shared profile on the existing preflight preserves
those laws without copying a parser or weakening the Object default. This is a
design pivot based on the inspected budget tests, not a claim that neutral syntax
cannot be made reusable in a future broader parser refactor.

- Recurse through otherwise legal core constructors. Preserve the nominal Nested
  tag and nonempty named Tuple child rather than rewriting persisted identity to
  an equal-shaped Array(Tuple).
- Use the core Map key predicate plus the existing admitted static key-codec
  capability, not Object's String-only policy. Numeric UInt64 keys are a required
  witness. Dynamic keys stay unqualified in this slice; this is a local state
  admission boundary, not a claim that ClickHouse forbids their declaration.
- Require a Dynamic-bearing, non-JSON descriptor. Preserve exact bare Dynamic's
  legacy dispatch, illegal Nullable/LC/Variant edges, and separate nominal state,
  QBit and Geo owner guards. This slice does not bypass those owners merely
  because their syntax is known to the neutral parser.
- Each Dynamic occurrence still requires its exact structure/actual roster and
  a complete collision-free physical plan. Array/Nested transport parent rows
  through offsets; Tuple preserves per-field state; Map retains key/value axes.
  Existing BASIC Map is the physical target, not bucketed Map qualification.
- Preserve canonical spelling, inherited depth and aggregate node/edge/metadata
  and rendered-name limits. Budget exhaustion must remain a refusal, not a reset
  at each Nested or child. Object/JSON declaration grammar is unchanged.
- Preserve selected full-grid validation, logical retained-value budgets,
  later-mark state replay, staged readback and exclusive N-column publication.
  No new codec, fixed two-column loop or `WidePart.open_typed` widening.

Guard-only/rejected: JSON-containing nominal Dynamic trees, unsupported nominal
owners, illegal core constructor edges, unsupported physical versions/Compact
parts, incomplete/colliding structures, malformed grids, destination overwrite.
No claim of all Dynamic actual-type families, bucketed Map, arbitrary keys or
partitions, native projection/MV writing, unique heap/RSS or performance closure.

## Risk, rollback and verification plan

Risk: CAUTION (persisted-format/public consumer admission). Rollback: only owned
uncommitted edits, or one verified atomic local feature commit; no push or remote
history/source/runtime mutation. Strongest failure: local writer and reader agree
on a wrong occurrence axis or nominal descriptor. The discriminator is reciprocal
stock parts with independent literal values and actual Dynamic types.

1. Add one reusable W249 fixture/helper and a falsifier spec. With production
   frozen, direct recursive Dynamic write/read must pass while declaration/public
   table/offline admission fails for Nested below wrappers and numeric Map keys.
2. Replace the contextual declaration gate, reusing bounded canonical preflight;
   keep Object grammar and stock Tuple metadata ownership unchanged. Update the
   obsolete W211 root-only refusal/budget tests, not their retained guard intent.
3. Run exact affected spec rosters in DEBUG and RELEASE with the unchanged
   600-second/12-GiB process-tree and 50-percent free-memory guard. Partition a
   compile roster rather than increase limits if compiler RSS hits the guard.
4. Build the helper in both modes. Run isolated reciprocal native cells for
   single/sized String profiles: library N-column part to stock ATTACH/CHECK,
   exact schema/values/actual types; stock Wide part to direct, table and offline
   `.values`/window consumers. Reject malformed declaration/structure/grid and
   verify publication/budget/legacy-routing regressions.
5. Root inspect the intended diff and raw native outputs, run hostile checks,
   sync status/landmarks with observed commands and residuals, then commit only
   exact feature paths after DoD. Same-lineage review is correlated evidence.

The frozen RED command is `crystal spec spec/dynamic_recursive_handoff_w249_spec.cr`
under the guard above, before production edits. Its required discriminator is a
passing direct recursive control and a failing declaration/public handoff, not
a fixture compile failure. Final DEBUG and RELEASE use the same ordered roster,
partitioned into these two nine-file batches without increasing memory limits:

```text
spec/dynamic_recursive_handoff_w249_spec.cr
spec/dynamic_table_consumer_w211_spec.cr
spec/dynamic_table_budget_w211_spec.cr
spec/dynamic_bulk_part_w203_spec.cr
spec/multi_column_part_writer_w245_spec.cr
spec/multi_column_tuple_dynamic_w246_spec.cr
spec/static_binary_bulk_table_w247_spec.cr
spec/static_nested_handoff_w248_spec.cr
spec/storage_read_budget_w245_spec.cr

spec/object_recursive_w140_root_spec.cr
spec/object_document_schema_w140_spec.cr
spec/object_recursive_consumers_w140_spec.cr
spec/object_declared_low_cardinality_w146_spec.cr
spec/object_declared_variant_w151_spec.cr
spec/object_declared_nested_w236_spec.cr
spec/object_recursive_dynamic_w159_spec.cr
spec/object_recursive_dynamic_w159_adversary_spec.cr
spec/object_declared_dynamic_w158_adversary_spec.cr
```

The DoD signal is zero failures/errors/pending and exit 0 in both modes,
both helper builds, four reciprocal native cells with exact nominal schemas,
literal values and Dynamic actual types, and root hostile controls. The
[root-owned evidence index](../.landmark/evidence/dynamic-recursive-handoff-w249.json)
records expanded executed commands, pins, outcomes and residuals. The index is
not proof by itself. Evidence decays if the parser, admission policy, recursive
plans, consumer metadata, runtime/profile pins or relevant guards change.

## Observed discriminator before production changes

Root executed the exact one-spec DEBUG gate under the planned guard and flags
(`--single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace --verbose`).
It ran four examples: one failure, one error, zero pending, exit 1. The direct
nominal Nested+Dynamic control passed for single/sized String profiles and the
descriptor/rendered-name budget control passed. The recursive declaration
example failed when Array(Nested(...)) returned nil. All five direct value
readers in the public-consumer example succeeded before table admission threw
`UnsupportedFormatError: unsupported exact typed column`. This separates an
already-composing core codec from a missing declaration/public handoff.

## Observed implementation and qualification

The Dynamic declaration owner now selects an explicit `DynamicBulk` profile
on the shared bounded preflight. It no longer rewrites only root Nested into
Tuple. Profile propagation is immutable and revalidated before accounting or
materialization. Default `ObjectJson` behavior is unchanged. No new value codec,
physical plan, serializer metadata rule or per-product class was introduced.

The frozen 18-file roster passed 52 + 65 = 117 examples in DEBUG and the same
117 in RELEASE, zero failures/errors/pending and exit 0 in all four batches.
Both helper builds, seven-file Crystal formatting and final Ruby syntax passed.
Production/fixture/helper/spec hashes remained frozen through these gates and
the final native cells; only two observed harness defects were corrected.

Four fresh DEBUG/RELEASE x single/sized String native cells passed. Six-column
parts carry the UInt64 key and five independent recursive families: root
Nested+Dynamic+LC(Nullable(String)), Array(Nested), Tuple(Array(Nested)), recursive
Nested, and BASIC Map(UInt64, Nested). Six Dynamic sites exercise Int64, String
and NULL, including shared overflow and an empty first mark. P=[2,2,1,EOF0].
Library-written parts pass stock ATTACH/CHECK=1 and exact ordered nominal schema,
literal values and actual-type traces. Stock-written parts pass CHECK=1 and
library direct/full-table/window/candidate-mark/offline `.values` reads. The
offline Atomic catalog is a byte-identical synthetic copy, not a discovery or
server Active-state certificate.

Root independently rechecked raw arguments, exits, stdout/stderr hashes,
CHECK rows, schemas, literal values and all six Dynamic type traces rather than
trusting summary status. Sixteen native calls and eight helper calls are
qualified. Actual bytes and file identities of all 208 generated files / 32,021
bytes per mode agree exactly: single 94 / 14,487; sized 114 / 17,534. ATTACH adds
only `invalidated_system_columns.txt` with exact `_block_offset\n_block_number\n`
bytes; every original generated file remains unchanged. Native calls use one
thread and the existing 536,870,912-byte limit, beneath the process-tree guard.

Executed hostile checks preserve Object defaults, reject a metrics-correct
preflight under the wrong profile before charging, revalidate borrowed source,
reject illegal Nullable/LC/Variant edges and unsupported Dynamic Map keys,
preserve exact aggregate budgets, and reject extreme inherited depth before
Int32 overflow. Publication, read-budget and existing corrupt-grid/state guards
passed in the affected roster. Same-lineage Luna review is correlated; stock
reciprocity and root raw inspection supply separate executable evidence.

Two initial native attempts are preserved but not qualification: Ruby 2.6 lacks
`filter_map` (no native call ran), then test settings selected non-adaptive `.mrk`
without EOF. The latter had a successful library ATTACH/read but did not reach
the reciprocal library read. Matching the existing adaptive Wide target fixed
the test settings; assertions were not weakened. An initial root audit used an
incorrect 4-GiB expected argv limit; inspection confirmed the existing stricter
512-MiB limit, and the corrected read-only audit passed unchanged native output.

Residual scope: adaptive Wide/BASIC only, selected Int64/String actual families,
ordinary single/sized String and single-stream shared overflow. This does not
qualify every static Map key, nominal JSON-containing declaration, historical
or new serialization version, bucketed Map, Compact part, projection/MV native
interop or unique heap/RSS. The public preflight profile is a selector, not
unforgeable provenance; same-size canonical borrowed edits intentionally mean
the current source. No all-types, whole-suite or performance closure is claimed.
