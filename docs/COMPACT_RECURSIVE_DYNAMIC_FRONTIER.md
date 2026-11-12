# Recursive Compact Dynamic sibling frontier — W284

W284 is VERIFIED within the declared direct reader and writer boundary
described below. The hostile review verdict is ROBUST within the tested
matrix. The previous qualification was W283
(`6e893890713d09ecdb7d7909ee9a2addf80eff75`).
W284 covers recursive Compact JSON columns with a separately context-owned
JSON-free Dynamic sibling below existing Array/Tuple wrappers.

## Initial factual anchor and intended behavior

W257's existing fixture declares
`Array(Tuple(doc JSON(max_dynamic_types=1,max_dynamic_paths=1,t UInt8),sample Dynamic(max_types=1)))`.
Its Wide transform qualification does not qualify this Compact composition.
W283 composes existing static/LowCardinality/Variant Bulk codecs in recursive
Compact JSON, but that opaque owner still intentionally rejects Dynamic.
The direct expected-success probe uses the existing W257 declaration and
literal values. Its initial discriminator was an explicit admission refusal.

The implementation target is to bind Dynamic state to its canonical recursive
schema path, separately from Object contexts, and reuse existing Dynamic
structure/physical/value codecs. This is not a new per-product serde codec.
Existing explicitly owned Object-inside-Dynamic seams are not globally widened.

## Design boundary

`CompactPartColumn.json` gains a default-empty `dynamic_contexts` keyword,
mapping canonical recursive Bulk-site paths to existing immutable
`CompactDynamicWriteContext` owners. The input detaches that map; an own-file
recursive context validates its exact schema-site roster. A Dynamic site's
local actual-plan paths remain rooted at `root`. Object contexts retain their
existing meaning. Sharing an immutable context at two compatible paths is not
itself an aliasing error; missing, surplus or incompatible path bindings are.
Validate the supplied map's cardinality and canonical paths before detaching
its keys; static-only callers must reject surplus context maps without first
copying them. Context equality uses read-only iteration, not defensive-copy
accessors in the execution path.

Dynamic sites have their own site/mark adapters. Static Bulk admission and its
eight-byte LowCardinality/Variant prefix descriptor remain unchanged. Reuse
`BinaryDynamicBulkPhysicalPlan.from_escaped_prefix`, existing Dynamic codecs,
and the shared callback traversal; do not manufacture a child physical window
or duplicate a value codec. A narrowly factored traversal adapter may consume
the authenticated parent ledger, never its unauthenticated replacement.

The first implementation is bounded to a direct Dynamic Bulk leaf below the
existing recursive Array/Tuple wrappers. JSON or further Dynamic inside its
actual-arm roster remains rejected. Every actual arm must also pass the
existing recursive static Bulk grammar at the inherited Dynamic-site depth
plus one; standalone Dynamic admission is not sufficient. Other Dynamic-bearing Bulk products are
guard-only until their discovery and complete callback ownership are proved;
an existing standalone Dynamic implementation does not admit them here.

The reader reuses `CompactRecursiveJsonStaticBulkGrammar` for those actual
arms through a closed typed capture adapter. Its admission/census and static
callers do not change. A small Dynamic-root branch captures discriminator
framing and arm occurrence counts; existing static-node capture owns the arm
callbacks. Dynamic structure discovery remains a separate ledger-only prefix
cursor. The standalone normalizer is not extracted or given a fabricated child
window. Actual-arm Array/Nested size lanes join the parent's frozen mixed-body
lane count, including when their occurrence count is zero.

The shared schema-site contract exposes `dynamic_bulk_sites`,
`dynamic_bulk_site_count` and `dynamic_bulk_site(key)`. Each own-file Dynamic
site carries `key`, the already escaped `physical_prefix`, direct-Dynamic
`type`, `descriptor_depth` and `initial_array_level`. Reader and writer derive
structure callback names from the existing Dynamic physical plan. Schema DFS
must merge each site's complete learned prefix/body roster; no invented
physical names or stateful prefixes enter the static eight-byte owner.
The two `expected_event_names` overloads take default-empty
`dynamic_prefixes` and `dynamic_bodies` maps keyed by schema site. All prefixes
are merged in schema DFS before any body; each Dynamic body roster appears
at its schema DFS position. Missing or surplus phase maps are rejected.

Bounded consumer inventory:
`rg -n -g '*.cr' 'CompactJsonColumnInput\.new|CompactRecursiveJsonSchemaPlan\.new|CompactDynamicCallbackPlan\.new|CompactDynamicBulkPreparedContext\.new|CompactDynamicBulkPrefixTraversal\.new' src spec scripts`
finds the production bridges in `compact_part_column.cr`,
`compact_json_callback_plan.cr`, `compact_recursive_json_column_reader.cr`,
`compact_part_write_plan.cr`, `compact_dynamic_callback_plan.cr` and
`compact_binary_bulk_normalizer.cr`, plus W262/W263/W268/W269/W271/W277
tests/helpers. New parameters must default to the existing behavior; shared
traversal/context changes require those affected consumers in qualification.

## Design obligations

- Inventory the current public writer/reader and all changed shared consumers.
- Pin per-path actual rosters and occurrence domains. Parent rows, Array child
  occurrences, Dynamic non-NULL values and selected-arm values are not equal.
- Preserve the serializer's complete prefix phase before any body phase,
  including zero-occurrence callbacks. DynamicStructure is variable length;
  the fixed eight-byte LC/Variant prefix descriptor cannot silently own it.
- Preserve source-defined PREFIX/PREFIX_EMPTY statistics framing, exact
  canonical actual types, NULL versus SharedVariant and per-path modes.
  The pinned Compact writer explicitly selects first-mark PREFIX and later
  PREFIX_EMPTY; the same policy in the separately pinned runtime build remains
  a stock-byte discriminator until observed.
- Preserve complete-parent authentication before publishing decoded values,
  transactional parent-cursor failure behavior, exact MRK3/MRK4 extents and
  the existing String0/String1 ownership rules. A failed operation may retain
  codec-budget charges; no whole-budget rollback or reuse after failure is
  promised by the current budget owner.
- Reject unbound/mismatched contexts, unsupported actual rosters/layouts and
  Dynamic/JSON cycles before staging. Generic opaque Dynamic admission remains
  rejected unless an explicit owner establishes these obligations.

## Probe, implementation and qualification plan

Risk: CAUTION, persistent serialization and public context ownership.
Rollback: only exact W284-owned edits over the baseline commit; preserve all
other changes, W283 evidence and the three protected untracked W263 specs.

1. Add `spec/compact_recursive_dynamic_w284_entry_spec.cr` and its own-file
   fixture `spec/support/compact_recursive_dynamic_w284_fixture.cr`. Assert a
   successful public Compact write/read of the W257 values, without weakening
   existing guards. Capture the actual expected admission failure before any
   production edit. The first command is the focused entry spec under the
   unchanged guard; save exact argv and raw logs on the owned SSD root.
2. Implement the separate recursive context and Dynamic site/mark adapters;
   propagate through schema planning, JSON callback/input ownership, encoder,
   reader and writer workspace preflight. Reuse or narrowly factor shared
   Dynamic callback traversal/physical context, keeping unknown products
   fail-closed. Any additional shared API or file requires review first.
3. Add focused adversaries for wrong/missing/aliased path state, zero-Q and
   active/NULL/shared arms, first/later prefix statistics, malformed/truncated
   variable prefixes, profile/extent/authentication, cursor rollback and
   operation-budget rejection without publication.
   Run focused DEBUG and actual RELEASE, exact affected consumer cohorts and
   formatting. Seal the precise commands/roster before execution.
4. Use the unchanged pinned full CH build for fresh stock-first Compact reads
   and generated CHECK/ATTACH/reopen with literal full/middle/last/EOF values.
   Qualify supported plain MRK3/MRK4, BASIC/COMPACT discriminators and ordinary
   S0/S1 cells rather than treating a local round trip as native compatibility.
   Preserve a separate literal oracle and actual-capture negative controls.
5. ROOT reviews decisive code and raw evidence, performs hostile self-review,
   records the finite qualified boundary and makes one atomic local feature
   commit only after its DoD passes. No push.

The additive interoperability driver is
`scripts/verify_compact_recursive_dynamic_w284_interop.rb`. It composes the
frozen W284 runner's bounded process/capture primitives without modifying the
stock runner, helper or fixture, and without inheriting older matrix policy.
For each separately compiled DEBUG/RELEASE helper it must consume the eight
immutable stock captures, validate all four public-reader windows against
literal expectations, write eight independent generated parts and preserve
their inventories. Each generated part then passes a separate native empty
target creation, ATTACH/CHECK/value-window process, and reopen/CHECK/window
process. Native ATTACH may add only the previously pinned 28-byte
`invalidated_system_columns.txt` sidecar; it may not change a generated file.
Original stock captures and generated source parts remain unchanged.

The driver must also exercise a copied actual plain-MRK4 mark-coordinate
mutant through the public helper, preserving the original raw part. An offline
parser rejection, an external-inventory mismatch or a native checksum denial
does not substitute for that public-reader result. Synthetic report mutations
only qualify the report validator. Save exact rejection class/message and
scope rather than attributing an unobserved denial to Dynamic grammar.
Run the driver under the resource preflight specified below.

## Baseline falsifier

The existing-API expected-success probe compiled and ran on the baseline,
then raised `UnsupportedFormatError: Compact JSON column schema is outside
the admitted static-site subset` at `CompactPartColumn.json`, before writing.
Observed: one example, zero assertion failures, one error; process exit 1.
This is the intended behavioral RED, not a compiler or environment failure.
The single guarded run took 8.35 seconds with 1,645,314,048 bytes maximum RSS,
72-percent free memory versus the unchanged 50-percent floor, and zero swaps.
HEAD, the 619-file source census and frozen inputs were unchanged afterward.
Exact command, input hashes and raw logs:
`/opt/mldata_ssd/cache/crystal-click-w284.9Nzwqc/reports/w284-entry-red-debug.freeze.md`.

## Source caller policy

At the separate pinned source revision
`ed30948f095ecb70679986d7d60e27ad770ae27a`,
`src/Storages/MergeTree/MergeTreeDataPartWriterCompact.cpp:190-193` switches
later granules to PREFIX_EMPTY; `:226` initializes PREFIX, `:380-383` passes
`!data_written`, and `:396` records completion of the first granule.
Array `serializeBinaryBulkStatePrefix` at `SerializationArray.cpp:297-305`
and Tuple at `SerializationTuple.cpp:794-805` propagate the same settings to
their children. This establishes caller policy in that source checkout,
not merely the conditional encoding branches in `SerializationDynamic.cpp`.
The Compact-writer source SHA-256 is
`0b551c2e4efe5638fc734f854e45d78beab342ce43fffd464b6196d1eeff2072`.
The runtime build is a different revision; native prefix capture is still
required to qualify its observed first/later bytes.

## Stock-only capture, not engine qualification

The frozen stock-only command completed with exit 0 on 2026-10-16 after a
fresh 76-percent free-memory preflight. It executed eight cells:
plain MRK3/MRK4 x BASIC/COMPACT discriminators x String0/String1, each with
one native seed process and a separate reopen process. All parts contain
eight rows, four data marks and a final mark. The command took 3.96 seconds,
with 184811520 bytes maximum RSS and zero swaps. This fixture timing is not
a reader-performance result.

ROOT independently checked the raw logs against separate literal values for
32 full/middle/last/EOF windows, all 16 exact healthy CHECK rows, invocation
statuses and hashes, and all 84 listed part files. Frozen runner/helper/fixture
and runtime hashes were unchanged. The capture deliberately remains
`stock_sql_values_and_raw_part_inventory_exact_prefix_unparsed`: physical
prefix parsing, Crystal reads, generated ATTACH/reopen and actual-capture
negative controls are not qualified by this run.

The exact command is
`/opt/mldata_ssd/cache/crystal-click-w284.9Nzwqc/reports/w284-recursive-dynamic-stock-first.argv`
(SHA-256 `ee20fddba812f8349b11e1a7d9cf458b31d88a39198e255f1b6b8192e89f5249`).
Its sibling `.stdout` and `.stderr` hashes are respectively
`56b3f85d713c526453dcc46961bad8b51f90dfbabee15bbe4b207cbf5e5a84e1`
and `b6b077292123e44e6602e7f476816045ff95b6c1cc2ca8479b58a89a891837b6`.
Preserve the immutable native stores, raw logs and manifests under
`/opt/mldata_ssd/cache/crystal-click-w284.9Nzwqc/stock-first` for the subsequent
independent byte auditor and public-reader checks.

## Offline prefix audit and October compiler checkpoint

The separate read-only byte auditor and ROOT's independently rerun audit both
accepted all eight stock captures and four seeded negative controls. The
canonical report is
`/opt/mldata_ssd/cache/crystal-click-w284.9Nzwqc/reports/compact-recursive-dynamic-w284-root-audit.json`,
SHA-256 `19a885b02950e258396c01139f8d07969226d7319e41aa11eb9119659c8a220d`.
The auditor itself has SHA-256
`c3ff1e4d6a83c700914acf4e63b529b1e1a4a6d638d5165a1e62072ed9528ec6`.
It checks the pinned file inventory, bounded LZ4 decoding, exact mark geometry,
Object V3/wire-4 and Dynamic V3 prefix framing, and the shared parent cursor.
It does not recompute CityHash or qualify the Crystal reader.

Observed Dynamic statistics flags are `[1, 0, 0, 0]`, including the zero-child
third mark. The first Dynamic prefix has 22 bytes; later prefixes have 11.
The inherited child occurrence counts are `[1, 3, 0, 2]`, distinct from both
parent rows and the part-level `[SharedVariant=1, UInt64=2]` statistics.
One in-memory raw MRK4 coordinate mutation and three decoded-prefix mutations
are rejected by this independent parser. Those rejections do not substitute
for executing a copied raw mutant through the public Crystal reader.

The first integrated DEBUG bootstrap then passed its fresh 78-percent
free-memory guard but exited 1 during compilation, before any examples ran.
`CompactJsonEncodedColumn:225` called the missing
`CompactJsonCallbackPlan#callback_event_at`. This is an integration defect,
not the baseline admission RED and not a passing test. The frozen 19-example
command is `reports/w284-focused-debug.argv` under the same SSD root; its raw
stderr SHA-256 is
`1b3e77dcef97d9abe5084e832fabc2274a6ce28b261ae743c4188a587f424c74`.
The run took 1.47 seconds, with 778600448 bytes maximum RSS and zero swaps.
Execution stopped for diagnosis; any corrected source requires a new source
census, exclusive logs and a fresh guarded grant.

The missing indexed accessor is now present with explicit nonnegative bounds;
its writer adversary checks roster parity, detached-array isolation and both
out-of-range directions. This correction has not been compiled or executed.
The saved reader adversary adds three examples covering prefix-transaction
retry, incomplete/unpublished preparation and a zero-occurrence Array actual
arm. The complete focused roster is five files / 22 expected examples, not an
observed pass.

Prepared commands are `reports/w284-focused-22-debug.argv` and
`reports/w284-focused-22-release.argv`; their input freeze is
`reports/w284-focused-22.freeze.md`. The current 666-file `src` / `spec/support`
Crystal census is
`6f520f3f5de54e3bf15b2006b29a39a3d189e48f0ed597c97f784d81efaeed5a`.
ROOT independently checked the seven focused input hashes, mode flags and
absent exclusive logs. The 23-path format-check command and 28 baseline
commands are also prepared only. The latter preserve the exact W283 13-cohort,
122-path, 682-expected-example roster per mode plus separate filtered admission
commands, with only SSD scratch substitutions and declared RELEASE flags.
Command validation is not a test result. Refresh these freezes after any
formatting/source change and stop at the first unexpected execution failure.

The 2026-10-16 21:54 UTC ROOT preflight observed 39-percent system-free memory;
the 21:57 UTC recheck observed 32 percent. The next goal turn observed 33
percent. On the third consecutive resource-held goal turn, ROOT observed 75
percent at 21:58:36 UTC and granted only the saved format check. The worker's
required immediate preflight returned 38 percent and stopped before launch;
ROOT independently rechecked 36 percent at 21:59:29 UTC and confirmed both
reserved format logs were absent. The one-shot grant is consumed; no
formatter/compiler/native workload ran under it. The memory state and
preflight result applied to that checkpoint.

At that checkpoint the workers stopped before the exact-path format check.
Source/input resealing, the focused 22-example DEBUG and RELEASE runs, helper
builds, public native interoperability and affected regressions were pending.

## Focused validation checkpoint — 2026-11-12 UTC

The resource hold cleared and execution resumed with Crystal 1.22.1 / LLVM
23.1.4. The exact 23-path format check passed. The five focused specs ran 22
examples per mode with zero failures, errors or pending examples in DEBUG
and RELEASE (`--release --no-debug`). The guarded commands, source and spec
censuses and raw logs are under
`/opt/mldata_ssd/cache/crystal-click-w284.9Nzwqc/continuation-20261111.NdK4uLDi`.

The integrated runs exposed a positional Hash initializer, the missing
Object-owned UInt8 admission, and an admission-order error in both Dynamic
planners. The initializer now uses the named capacity argument. Typed Object
UInt8 uses the existing static Bulk declaration. The recursive Dynamic site
admits its actual roster at the inherited depth before the shared planner
discovers structures. Focused regressions exercise the public round trip,
late-mark preparation, bounded codec budgets and the prohibited actual arms.

## Native interoperability checkpoint — 2026-11-12 UTC

The helper fixture now obtains typed paths from the declared Object leaf. The
helper checks the UInt8 tag and payload width through the current BinaryValue
API. The independent value literals are unchanged. The stock auditor checks
the historical helper and fixture digests in the immutable summary and rechecks
the live stock runner bytes. The interop driver separately checks the current
helper and fixture used for the builds. All eight re-audited stock cells match
the prior report, and a changed historical fixture digest is rejected.

Both helper builds and the guarded interop matrix exited 0 on Crystal 1.22.1 /
LLVM 23.1.4 and ClickHouse 26.10.1.1201. Each build reads eight stock Compact
parts and writes eight parts that ClickHouse attaches, checks, reads and
checks again on reopen. All four literal windows match in both directions.
Both public readers reject the copied one-byte MRK4 coordinate mutant with
`CorruptPartError` at the exact named-callback extent check. The run records
48 native and 34 helper invocations. A separate raw-byte check confirms the
requested plain MRK3/MRK4 format, BASIC/COMPACT mode, String version and V3
first/later statistics flags for all 16 generated parts.

The build argv, logs and pins are under
`/opt/mldata_ssd/cache/crystal-click-w284.9Nzwqc/continuation-20261112.V5pQe`.
The report is `interop-20261112.Uv6kA/w284-recursive-dynamic-interop.json` under
the same task root, SHA-256
`66e53f0d342056f1822b9edb948e48de35cf29819f79df01427cfdd0e25f2c8b`.
Historical Dynamic V1/V2 statistics placement requires separate evidence.

## Affected regressions and hostile review — 2026-11-12 UTC

DEBUG and actual RELEASE each passed 682 examples across the same 122 affected
paths, plus one separately filtered W263 admission. ROOT checked the 28 passing
commands and raw summaries against the frozen roster, build modes, guard and
unchanged source/spec censuses. The original DEBUG `types_3b` failed one W217
path assertion after the row assertion passed. The resumed batch changed only
the spelling of `TMPDIR` and `CRYSTAL_CACHE_DIR` to the canonical path on the
same SSD. It passed the original 24-example cohort and all subsequent commands.
The first nine passing cohorts and the failed attempt retain their own logs.

A matching Crystal round trip could conceal an incorrect prefix order,
inherited occurrence count or zero-occurrence discriminator. ROOT checked
that the parent ledger completes before selected values are decoded. The
stock-read and generated-ATTACH directions each matched the literal windows.
Separate raw checks, using the auditor's bounded parsers, confirmed the mark
format, mode, String version and V3 first/later statistics for eight stock
and sixteen generated parts. Both public reader builds rejected the copied
MRK4 coordinate mutation. Focused cases additionally cover a zero-occurrence
first mark for an `Array(UInt64)` arm, a failed prefix parse and invalid
context or actual-arm rosters.

The [evidence packet](../.landmark/evidence/compact-recursive-dynamic-w284.json)
links the exact command, runtime, helper and capture records. Refresh the
affected qualification when those inputs, source/specs, toolchain or the
admitted grammar change.

## Execution and stop rules

Use only `/opt/mldata_ssd/cache/crystal-click-w284.9Nzwqc` for new bulk scratch,
cache and captures, with its canonical SSD path in compiler environment.
Runtime/source/helpers from W283 are preserved read-only; historical results
and defaults are never repinned by editing metadata. No download or clone is
required by this probe.

The unchanged runner is
`/Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh`, SHA-256
`ca3d326eac90731c4915883158d394e72dde766786fadf95a4241acd7f627ea4`.
Use 50-percent system-free floor, 12288 MiB, 600 seconds, one heavy process,
`CRYSTAL_WORKERS=1`, `--single-module --threads 1`, and the existing system
linker workaround. Use exclusive new command/log artifacts. A resource stop,
input drift, unexpected compiler/test failure or count mismatch stops the
batch; do not skip, lower the guard or launch a blind retry. The intended
admission RED changes the next action but is not a passing feature gate.

The initial 2026-10-16 continuation preflight observed 32-percent system-free
memory, below the unchanged 50-percent floor; native/compiler execution was
held while source edits and lightweight Ruby checks continued. A later
76-percent preflight admitted only the frozen stock-only workload recorded
above. Run the unchanged memory preflight before each heavy command and
serialize compiler and native test execution.

Remove only released regenerable scratch after checking exact ownership,
canonical parent, device and live consumers; preserve qualified captures,
runtime, source Git, helpers and raw evidence. No internal-disk bulk fallback.

## W285 public Compact reads

Design-sealed over `a06d8a2da24d77f93be3af5817b3f6cc5b098052`.
`TypedPartTable` and `catalog[db][table][column].values` share
`CompactJsonColumnAdapter.schema_for_json_declaration`. Its Dynamic exclusion
precedes the existing Compact recursive reader's schema gate.

Keep exact canonical declarations and delegate mixed JSON/Dynamic admission
to the existing reader's schema gate. Scans retain the recursive
`StorageColumnValue` carrier. The catalog materializer retains its complete
schedule preflight, candidate format checks and owned value limits.
`Tuple(JSON, Array(Dynamic(max_types=1)))` remains guard-only because the
JSON-free Array is an opaque Bulk subtree. Empty catalogs must apply the
same declaration gate. Existing physical reader and writer policies own
actual-arm, layout and context checks.

Run `spec/compact_recursive_dynamic_w285_public_dispatch_spec.cr` against
the W284 baseline. The direct reader and unsupported empty-table guard must
pass while typed scan and catalog values each fail at their admission check.
After the routing change, run the same spec in DEBUG and RELEASE with the
W284 entry, W263 public admission and existing Compact typed read controls.
Check literal values, row/tuple/String bounds and a complete-schedule
negative before publishing selected rows. Revert W285 as a single change if
the public admission or a pre-existing route regresses.

The W284 baseline compiled and ran four DEBUG examples. Direct read and
the empty-table guard passed. The typed scan and `.values` both raised
`UnsupportedFormatError` at their public admission checks. The saved
argv and logs are under
`/opt/mldata_ssd/cache/crystal-click-w285.public-dispatch-20261112/`.

The public route reuses the direct reader and its format checks. The verified
public fixture is a generated MRK3 part with two marks, COMPACT discriminator
mode, String S1, and Dynamic V3. The typed scan selects the scalar key beside
the recursive column, and `.values` materializes the exact recursive literals.
One-under limits reject the four-row result, the String inside Dynamic, and
the retained child cells. The corruption test changes a payload byte in a
compressed frame wholly within the second `trace` mark and preserves the
first mark's physical bytes. The first-row typed window and `.values` reject
that part with the frame checksum error before exposing a result.

The hostile review verified the canonical and empty-table gates and the
pre-callback checksum failure. DEBUG and RELEASE each passed 46 cohort
examples and the separately filtered W263 admission example. Exact commands,
input digests and retry logs are indexed in the
[W285 evidence](../.landmark/evidence/compact-recursive-dynamic-w285.json).

## Full-objective boundary

Remaining type/layout products, Compact MV output and projection children
have separate admission and native verification work. Memory and performance
work follows compatibility. The <=10-percent stock-reader slowdown target
remains unmeasured.
