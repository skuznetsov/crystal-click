# Table class decomposition

## Contract

This is a behavior-neutral extraction from baseline `85fb22c`, not a new
type, storage profile or performance change. The public entrypoint remains
`require "crystal_click"`; public names remain in `CrystalClick`.

First slice: move seven existing numeric Map row/slice owners and the existing
`WidePartTableBatch` struct into owner-named files under
`src/crystal_click/wide_part_table/`. Move the existing aliases into a separate
alias-only file. Keep the scan facade and its private nested implementation
types in `wide_part_table.cr`; do not turn them into public types as a shortcut.
Preserve all method bodies, constructor signatures, comments, bounds and
visibility. In particular, Map slices must retain their original Array owner,
and Batch's `column_index` must remain private.

Risk: CAUTION (shared table facade). Rollback: the exact diff against `85fb22c`,
followed by an atomic local commit after checks pass. No push is authorized.
The strongest failure modes are a missing alias/require dependency, lost Slice
ownership and changed exact-type accessor admission.

## Responsibilities and loading

| Owner | Responsibility |
| --- | --- |
| `wide_part_table_type_aliases.cr` | Existing typed Array/Slice union aliases only |
| `WidePartNumericMapSliceBase` | Common erased slice boundary |
| `WidePartNumericMapSlice(K, T)` | Typed slice plus strong original Array owner |
| `WidePartNumericMapRowsBase` | Row/entry/byte accounting and slicing interface |
| Four concrete Map row owners | Existing scalar/Array and nullable-leaf accounting |
| `WidePartTableBatch` | Existing typed batch values, provenance and accessors |
| `WidePartTable` | Part selection, mark alignment, windows, budgets and callbacks |

The umbrella loader explicitly requires aliases, slice base/concrete slice,
rows base/concrete rows, Batch, then the scan facade. Existing Array(Map)
owners and column adapters retain their loading paths. This slice does not
promise standalone loading of arbitrary internal owner files.

## Verification and anchors

Root owns checks, compiler jobs and Git; Luna owns only the mechanical
production extraction. Existing user changes are not included.

Before extraction, the new source-ownership validator exits 1 because the eight
owner files and alias file do not exist and the facade still owns those types.
The new six owner tests plus unchanged W53 table control pass seven DEBUG
examples with no failures, errors or pending; actual child and unchanged
resource guard exit 0 (free-memory preflight 81%).

Structural DoD:

```sh
ruby scripts/check_table_class_ownership.rb --baseline 85fb22c
git diff --check
```

Observed: eight single-owner extracted files, one alias-only file, a single
top-level scan facade, ordered umbrella requires, nine byte-identical class
bodies and unchanged aliases. This is a bounded source check, not a parser,
runtime or whole-library compatibility certificate.

Runtime DoD uses the same 19 selected specs in DEBUG and RELEASE, divided into
seven disjoint serial cohorts after the failed larger RELEASE attempt. The
repartitioned sealed driver is
`/private/tmp/crystal-click-table-decomposition.l7S0nG/run_table_gates_r2.rb`:

```sh
ruby /private/tmp/crystal-click-table-decomposition.l7S0nG/run_table_gates_r2.rb
```

The exact rosters are retained here so the temporary driver is not the only
record of coverage. Paths are relative to the repository root:

```text
C1
spec/wide_part_numeric_map_owner_spec.cr
spec/wide_part_table_w53_spec.cr
spec/wide_part_array_map_owner_w134_spec.cr

C2
spec/wide_part_table_w76_spec.cr
spec/offline_catalog_w76_spec.cr

C3
spec/wide_part_table_w77_spec.cr
spec/offline_catalog_w77_spec.cr

C4
spec/wide_part_table_w78_spec.cr
spec/wide_part_table_w79_spec.cr

C5
spec/wide_map_tuple_w108_consumer_spec.cr
spec/offline_catalog_w95_tuple_values_spec.cr

C6
spec/aggregate_count_table_w177_spec.cr
spec/aggregate_count_offline_w177_spec.cr
spec/qbit_reader_consumers_w103_spec.cr

C7
spec/multicolumn_table_scan_spec.cr
spec/lazy_window_reader_spec.cr
spec/wide_part_table_projection_w87_spec.cr
spec/offline_catalog_projection_w87_spec.cr
spec/offline_tui_page_source_spec.cr
```

Each child uses the unchanged 600-second / 12,288-MB / 50%-free guard, isolated
Crystal cache, Xcode SDK, `--single-module --threads 1
--link-flags=-fuse-ld=ld --error-trace`; RELEASE adds `--release --no-debug`.
The observed compiler is Crystal 1.21.0 (2026-07-16), LLVM 22.1.8, default
target `aarch64-apple-darwin25.6.0`.
The driver checks nonzero example counts, zero failures/errors/pending,
actual child and guard exits/signals, immutable Crystal code inputs and public/
stock fixtures. Count's conditional tests must run with the existing stock
fixture root set; an absent fixture is a failure, not a smaller green roster.

The selected consumers cover flat and nested numeric Maps, nullable leaves,
Map(Tuple), Tuple `.values`, Count, QBit, multipart/window scans, explicitly
selected projections and TUI page sources. They are regression witnesses, not
new native format qualification or full-suite coverage.

Root executed a seeded owner-copy mutation (`@owner = @owner.dup`) in the Slice
constructor. The unchanged six owner tests fail five original-owner identity
assertions; the empty-row accounting control passes. Actual child and guard
exits are 1, with no signal and no changed inputs during the run. The record is
`/private/tmp/crystal-click-architecture-r1.shwDws/table-r1-ownercopy-red.json`;
its log SHA256 is
`82d97ca9727b804ce07b7190bf328af389413a751f0f76d9fd01528593ad956c`.
Root removed the mutation and independently checked exact restoration of
`wide_part_numeric_map_slice.cr`, SHA256
`5c60808d437d8533119a8aa1972a51a971d86c2f96843a648d3ee8c0bda009ee`.
The structural DoD passes again after restoration.

The first driver uses three cohorts and passes 21/11/79 DEBUG examples (111
total), zero failures/errors/pending and actual child/guard exits 0. Its first
RELEASE cohort is stopped by the unchanged memory guard: process-tree RSS
12,589,056 KB exceeds 12,288 MB after approximately 252 seconds. Guard and
driver exit 1; no child summary/status record survives the process-tree stop.
The attempt is not counted as a green RELEASE gate. Its driver results remain
in `/private/tmp/crystal-click-table-decomposition.l7S0nG/results.json`.

The r2 driver mechanically checks that its seven cohorts preserve the original
19-spec union and still uses the same limits. All fourteen final gates pass:

| Cohort | DEBUG examples | RELEASE examples |
| --- | ---: | ---: |
| C1 | 13 | 13 |
| C2 | 4 | 4 |
| C3 | 4 | 4 |
| C4 | 4 | 4 |
| C5 | 7 | 7 |
| C6 | 25 | 25 |
| C7 | 54 | 54 |
| Total | 111 | 111 |

Every actual child and guard exits 0, with no signal and zero failures, errors
or pending. Root independently executes
`ruby /private/tmp/crystal-click-table-decomposition.l7S0nG/reconcile_r2.rb`
and compares all fourteen result records, exact commands, example counts and
log hashes. All gates use the same 987 Crystal input hashes, which match live
files. Both fixture manifests and the independently rehashed live inventory
agree on 1,407 files. The owner-copy RED record/log and exact Slice restoration
also reconcile. Structural DoD and `git diff --check` pass again.

Evidence records: `results_r2.json`, `fixtures_r2_before.json` and
`fixtures_r2_after.json` under the same temporary driver directory; child
records/logs use labels `table-r2-c1-debug` through `table-r2-c7-release` under
`/private/tmp/crystal-click-architecture-r1.shwDws`. The identical fixture
manifest SHA256 is
`8b9dc3a08192af64ac6111e574a52fa9e8c866d3ede5eab72f05070fc41973c3`.

Scoped Adversary verdict: ROBUST for this behavior-preserving eight-owner
extraction, unchanged aliases/facade bodies and selected regression witnesses.
The seeded ownership failure is detected; constructor/accessor visibility and
loading order remain unchanged. This does not certify all library profiles,
fresh-source native compatibility, performance or the remaining refactor.

## Remaining architecture work

Moving Batch does not make its roughly 2,000-line implementation small.
Next slices should separate cohesive typed batch storage/accessors, table
materializers and part/schema admission, preserving private boundaries. The
large `WidePart` reader and `WidePartWriter` still require decomposition;
offline catalog/table classes remain separate work. Do not mix these moves
with new type admission or performance tuning.

One proposed next seam is Batch's compositional row-handle storage, not yet
implemented. Root checks fields at `wide_part_table_batch.cr:50-52`, the
install/access block at `1464-1534` and all four constructor paths: three
allocate all three hashes (`116-118`, `184-186`, `252-254`), while `366-368`
retains the injected Tuple store and allocates only the other two. A new
collaborator must preserve this injected store and the shared Array(Tuple)/
Nested store, borrowed slices, private helper visibility and existing exact
schema/row-count guards. W95 Tuple, W108 Map(Tuple), W171 Nested and W174
negative/empty Nested controls are candidate witnesses for that separate
slice; this extraction's regression results do not pre-qualify it.

Refresh this evidence after relevant production bodies, loading paths,
compiler/SDK, selected tests or fixtures change. If temporary gate records
disappear, rerun the declared checks instead of treating a recorded hash or
this document as proof. If the temporary driver disappears, reconstruct the
seven declared serial rosters with the same mode flags, resource guard,
isolated caches, stock fixture prerequisite and input/fixture checks.
