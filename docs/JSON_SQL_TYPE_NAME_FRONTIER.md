# JSON SQL type-name frontier

## W251: VERIFIED within the finite legacy JSON handoff target

The full objective remains legal ClickHouse read/write type compatibility and
MV/projection support before memory or performance optimization. W250 is
progress, not closure: it commits persisted Dynamic V1/V2 metadata framing.
This slice connects an existing nominal JSON descriptor to the common SQL-name
parser and its physical consumers. It must not become a metadata-only closure
when the existing Object/Dynamic physical owner can exercise the handoff.

Baseline observation: clean `8dd4f558880d4d7f33fae8f95bd6bee23b7e1772`. The neutral
`BinaryRecursiveDataTypeNameReader` has no JSON branch, while `BinaryJsonType`
and `BinaryTypeNameBudget` already render and meter canonical JSON names.
Dynamic V1/V2 serialize ordinary alternatives as StringBinary SQL names, so
otherwise-representable JSON actuals fail the shared legacy roster boundary.
Recursive serde and Object child physical composition already exist.

Primary source comparison: official shallow checkout
`/private/tmp/clickhouse-w249-upstream-P7bxRQ`, revision
`fe0f91b6c3de9e1efa33a1bce4ca9bcbfb4c509d`. `DataTypeObject.cpp:236-297`
renders defaults as bare JSON and otherwise emits non-default type/path caps
followed by sorted typed paths. Its factory at `:809-890` accepts a broader
grammar, including SKIP and regexp, than this local descriptor can represent.
`SerializationDynamic.cpp:245-268,431-459` writes/reads legacy alternatives
as SQL names; `DataTypesBinaryEncoding.cpp:514-541,810-871` owns the separate
binary JSON descriptor. The current sparse snapshot omits parser/quoting
helpers; older lexical corroboration is not a current-source qualification.
No quoted-path or SKIP admission relies on that older snapshot in this slice.
The separately pinned
runtime is ClickHouse 26.10.1.1201, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, SHA256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
The comparison snapshot is not the runtime's build-source identity.

## Admitted design and retained boundaries

- Parse every canonical SQL name representable by the existing BinaryJsonType
  owner: defaults, admitted cap bounds, unique plain typed paths and the current
  recursive typed descriptor grammar. Preserve exact descriptor equality;
  containers recurse through the same parser. Legacy roster parsing borrows
  one consumptive operation budget, including recursive typed declarations.
- Retain canonical-only admission. Unknown/repeated options, duplicate paths,
  trailing input, noncanonical names, child layout aliases and metadata/depth/
  aggregate-limit failures must not be normalized into different descriptors.
- Preserve V3 binary descriptor behavior and every existing value/physical
  constructor guard. A parseable descriptor is not permission to bypass an
  unbound Object owner or admit an illegal container.
  Root consumer review found a previously implicit Count admission boundary:
  its syntax-only argument parser now recognizes JSON, but the Count factory
  explicitly rejects JSON arguments. The direct BinaryAggregateCountType owner
  delegates to ArgumentPolicy, which must retain that rejection explicitly.
  Keep logical syntax acceptance separate from state/storage admission; do not
  narrow the neutral or syntax-only parser to hide the consumer mismatch.
- Keep plain path semantics unchanged. BinaryJsonType currently has no SKIP or
  SKIP REGEXP fields, and supports neither dotted nor quoted paths. Accepting
  those strings while discarding their semantics would violate identity.
  Their complete descriptor/value/path-policy implementation remains a required
  later frontier, not an assertion that full JSON is supported here.
- No new per-container serializer, layout, state family, projection/MV API,
  dependency or performance change in this slice. No generic Crystal Regex
  substitution for ClickHouse RE2 behavior.

## Ownership and plan

Risk: CAUTION (shared language and persisted metadata admission). Rollback is
the scoped diff and one atomic local feature commit after DoD. Preserve source
parts, user checkouts and unrelated changes; no push or history rewrite.

1. Test owner: Luna's local-parser worker owns
   `spec/json_sql_type_name_w251_spec.cr`; the consumer worker may add
   `spec/json_dynamic_legacy_handoff_w251_spec.cr` if needed. Root first executes a behavioral RED against the
   baseline parser using existing APIs and literal legacy metadata. A compile
   failure, absent new API or unsupported SKIP fixture is not the required RED.
2. Production owner: Luna's source worker owns
   `src/crystal_click/binary_recursive_data_type_name_reader.cr`.
   Use one cohesive JSON grammar companion in its own file if complexity needs
   separation; root owns require wiring. Typed descriptors call the existing
   recursive visitor with inherited depth and the same operation budget, not
   fresh per-field allowances. No unrelated facade refactor is bundled.
   A focused regression RED precedes the explicit JSON fence in
   `src/crystal_click/binary_aggregate_count_argument_policy.cr`, owned by the
   same worker. This preserves the old Count state frontier rather than adding
   a new aggregate family. Its logical ArgumentNameParser is not changed.
3. Physical/native owner: Luna's consumer worker reuses the W210 Object/Dynamic composition and W220
   owned-value support. It owns `scripts/check_json_sql_type_name_w251.cr`
   and `scripts/probe_json_sql_type_name_w251.rb`, not another
   value serializer. Explicitly carry V1/V2 versions and complete statistics
   through parent and child structures. Native captures must observe actual
   physical versions, not merely a CREATE setting. The bounded native matrix is
   V1/single_stream and V2/with_size_stream, root and Array(Dynamic) fixtures,
   separately in DEBUG and RELEASE. It is not the full version/profile product.
4. Root executes serial guarded focused and affected DEBUG/RELEASE rosters,
   helper builds and reciprocal native captures. Inputs are frozen during each
   workload. Independent literal schema/values/type metadata, raw process/files,
   statistics offsets and marks distinguish interoperability from self-round
   trips. Root then attacks the result and records a local atomic commit.

## Falsifiers and Definition of Done

Strongest failure: a parser produces a superficially matching JSON name while
dropping caps/path metadata, resetting child budgets or selecting the wrong
Object child stream/row domain. A matching library writer/reader can hide this.

Required scoped tests include canonical default/zero/extreme caps, multiple
typed paths in canonical order, recursive JSON descriptors, duplicate settings/
paths, invalid ranges/names, exact and one-short aggregate budgets, inherited
depth and existing unsupported path/SKIP/value/layout fences. Literal V1/V2
prefix/full metadata must retain exact canonical JSON descriptor identity,
mandatory statistics framing, relative offsets and exact consumption.

The physical witness must contain nonempty JSON actuals, typed Nullable NULL,
an unused JSON arm and a recursive occurrence domain P != Q, with an empty first
mark and later populated JSON. Reuse the existing common owners. Both library
write -> stock ATTACH/CHECK=1/exact schema/values/types and stock write -> library
direct/public/owned reads are required within the declared native matrix.
Malformed or unbound children must reject before publication/callback, including
empty selections. Matrix limits must be explicit rather than an all-products
claim. Any newly discovered real consumer blocker must be implemented or left
IN_PROGRESS, not hidden by using only a convenient low-level reader.

DoD command forms: root-owned `crystal spec <exact affected roster>` and helper
builds under run_safe.sh (600 seconds, 12288 MiB, min-free 50%, one worker), with
`--single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace`, additionally
`--release --no-debug` in RELEASE. Native runs retain the existing 512 MiB/
one-thread process settings. Expected signal: zero failures/errors/pending,
actual guarded exit 0, exact native observations and reconciled raw artifacts.
Exact executed commands, pins and outcomes follow execution, never speculation.

## Observed implementation and evidence

The baseline tree was clean. Source/local/consumer inventories identified the
common parser as the legacy JSON roster blocker, rather than missing leaf serde.
Root observed the initial qualified behavioral RED against unchanged baseline
production: three examples, one failure (bare JSON parses as nil), two errors
(valid legacy canonical JSON names rejected), no pending, guarded exit 1.
The test compiled and ran; a missing API or compiler failure is not counted.
Initial test SHA256 is
`df84cf6194fd865b8834f66c0ce2e4d753314d939abce43d9b11c9cf0c1e24d4`;
baseline parser SHA256 is
`d5ebd2f24a66451dfe5193ca18cd6c8c8bdeec0341e6c74863c95d4ac2bbe670`.
The second behavioral RED exposed both comma-loop whitespace handling and the
previously implicit Count storage fence: nine examples, five failures, two
errors, no pending, guarded exit 1. The final implementation adds a cohesive
JSON grammar method to the existing parser and explicitly retains Count's
`contains_json?` rejection. No production owner, value codec, stream layout or
dependency was added. The syntax-only Count parser may recognize JSON without
admitting JSON to Count state storage.

The identical ordered 22-file affected roster is split into two groups. Each
mode passes 70 + 63 = 133 examples, zero failures/errors/pending. Final DEBUG
and RELEASE helper builds pass. Six-file formatting, Ruby syntax and diff
checks pass as final cosmetic gates. Exact root-executed commands, source
pins, result signals and exclusions are indexed in
[the W251 evidence packet](../.landmark/evidence/json-sql-type-name-w251.json).
The packet is an index to observed evidence, not proof from field presence.

Four fresh reciprocal native cells qualify DEBUG/RELEASE times V1/single and
V2/sized String, with root Dynamic and Array(Dynamic) fixtures in each cell.
Eight native and four helper calls establish library-written ATTACH/CHECK=1,
exact nominal schema/literal values/actual types, then stock-written direct,
public table, mark-window, candidate and synthetic owned-offline library reads.
This does not include stock re-emission. Array parent rows P=[2,2,2] differ
from the Dynamic occurrence domain Q=[0,3,2]; JSON has two selected occurrences
and a separately persisted zero-occurrence arm. Parent and nested JSON counter
structures carry actual V1/V2 metadata and mandatory unflagged statistics.

Root reconciled all 40 raw Dynamic structures against literal rosters/counts,
minimal framing, prefix offsets, compressed stream coordinates and raw `.mrk2`
rows [2,2,2,0]. Semantic grids have three real marks; their fourth position is
the EOF sentinel, not another populated mark. Actual DEBUG/RELEASE generated
bytes agree: single 126 files / 21,456 bytes, sized 138 / 23,429, total 264 files
/ 44,885 bytes per mode. Source/generated/attached snapshots remain bound to
the raw process records. ATTACH's sole extra metadata file has exact source-
derived bytes; it is not blanket extra-file compatibility.

Four in-memory forged helper reports reject at their intended root raw guards
after the valid baseline passes: changed statistics, an occurrence census
substituted for the physical P grid, prefix coordinate and terminal coordinate.
The physical regression tests also reject missing/unbound unused JSON children
before publication and corrupted unused children before callbacks, including
empty selections and EOF. Root verdict: ROBUST within this finite target;
same-lineage model review is correlated, not independent proof.

Excluded diagnostics: one initial native capture used an incorrect semantic
grid expectation (four versus three real marks); one new spec referenced a
different file's private fixture and failed compilation; preliminary root
auditor assumptions about runtime path, absent environment records and the
metadata roster were corrected against raw evidence. None counts as a passing
qualification cell. The final raw records do not attest the child's complete
environment or an immutable execution/link closure. Pinned root builds bind
these helpers to observed sources, not arbitrary binary provenance.

## Residual boundaries and continuation

Pre-existing standalone `parse_canonical` uses separate budgets for parsing
and final canonical rendering; both are individually bounded, not a single
consumptive operation. W251's aggregate-budget claim is limited to the borrowed
`parse_canonical_with_budget` legacy roster path. Unifying the standalone
accounting is a separate follow-up, not silently bundled into this grammar fix.

Quoted/dotted JSON paths and SKIP/RE2 semantics need descriptor and physical
path-policy support, not merely acceptance of their SQL names. Other persisted
layouts/actual families, general MV/projection writes, key/partition metadata
and broad facade decomposition remain open. This is not full JSON/all-product,
whole-suite, native Compact, stock-root discovery, server Active-state or
memory/performance qualification. Continue with a source-backed bounded
descriptor/context frontier rather than another serializer per combination.

Refresh after parser/descriptor/budget/consumer/helper/fixture/oracle/compiler/
runtime changes or loss of referenced captures. Full JSON path/SKIP semantics,
other type/layout/state families, general MV/projections and facade decomposition
remain required. Memory/performance is deferred; overall goal ACTIVE.
