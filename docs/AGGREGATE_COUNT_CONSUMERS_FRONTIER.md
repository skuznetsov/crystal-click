# Count table and offline consumers frontier (W177)

Status: VERIFIED within the explicit consumer profiles below (2026-10-05).
Baseline `b3883df`; qualification covers this atomic W177 diff. The overall
types/MV/projections and architecture goal remains IN_PROGRESS.
W176 qualifies only paired Count Wide-part reading/writing. This slice adds
consumers without widening that physical or logical type domain.

## Admitted design and rejected scope

Ordinary `WidePartTable.open_selected_typed` may select one scalar Count state
from the exact W176 two-column Wide/LZ4 profile. Full scans, physical-row
windows and caller-selected whole candidate granules retain the exact nominal
`BinaryDataType`. A dedicated batch accessor returns owned `BinaryValue` states;
its Slice is callback-borrowed, so retaining values means copying the state
handles into an Array, not retaining that Slice beyond the callback.
Primitive UInt64/String/numeric accessors remain closed. This is not finalized
Count output or aggregate execution.

Count selection eagerly admits the entire pair before callbacks: Count type,
UInt64 sibling identity, actual sibling row/mark axes, selected metadata and
cross-part identity. The hidden sibling is not exposed as a selected column.
An unselected Count column in an ordinary key-only scan does not imply this
Count-specific contract. Offline consumers additionally bind the complete
parsed table declarations and a simple UInt64 ORDER BY column; they must not
infer key provenance from a same-width sibling or serializer statistics.
Catalog `column.values` and indexed batch state values keep nominal states.
Offline PK candidate scans require the selected key and return whole granules,
not exact predicate matches. This slice does not add a TUI state renderer.
Offline parts remain candidates, not proven server-Active parts.

Rejected: other AggregateFunction functions/arguments/parameters, outer
Nullable, nested Count products, Compact, implicit finalization, general
aggregate execution, arbitrary keys/schemas, general MV/projection execution
or writes, concurrency snapshots, performance claims. Existing explicit
physical projection readers explicitly refuse Count projections in this slice.

## Guards, rollback and falsifiers

CAUTION: public typed consumers and persistent-format admission. New cohesive
Count owners use one class per file; existing facades only delegate. Rollback
is the scoped diff or atomic local commit. Highest-risk failure: a nominal
state becomes UInt64, or Count-only selection skips a different/broken sibling
in a later part and invokes a callback. Full metadata/axes preflight is eager;
selected payload decoding is bounded and retains W176 mark/checksum guards.
There is no whole-scan payload-error callback atomicity or general whole-file
hash-verification guarantee.

Falsifiers use stock-authored W176 fixtures with independent literal keys
7,13,22,31,50 and counts 0,127,128,16384,MAX. All three exact signatures must
scan and preserve type. Exercise nonzero/end/empty windows, row/accounting bounds,
selected whole granules, retained owned values, wrong-type accessors, later
part nominal/sibling/axis mismatch, DDL/key/selection refusal and unsupported
profiles. A primitive key-only control must remain green.

## Public consumer API and responsibility owners

`WidePartTableBatch#aggregate_count_states_for(column, expected_type)` requires
the exact nominal descriptor. Offline `.values` owns its returned Array and
keeps each element as `BinaryValue`, never as a UInt64 alias. For a normal
`OfflineCatalog`-produced two-column Count table:

```crystal
table = CrystalClick::OfflineCatalog.open(root)["lab"]["counts"]
type = CrystalClick::BinaryDataType.aggregate_count
table.scan_typed(["c"]) do |batch|
  batch.aggregate_count_states_for("c", type).each { |state| puts state.count_state }
end
states = table["c"].values.map(&.as(CrystalClick::BinaryValue))
```

This example uses the no-argument Count signature; argument-bearing signatures
require their own exact descriptor. `count_state` inspects the admitted state,
not generic aggregate finalization. Admission trusts the catalog's parsed DDL
fields; it does not authenticate manually forged `OfflineTable` constructor
fields against arbitrary raw metadata text.

Four classes have separate files: `WideAggregateCountPairAdmission` owns hidden
sibling admission; `WideAggregateCountTableMaterializer` owns bounded nominal
materialization; private `OfflineTable::AggregateCountOfflineAdmission` binds
parsed DDL/candidate identity; private
`OfflineTable::AggregateCountOfflineValuesMaterializer` owns retained values.
Facades keep orchestration/dispatch. A 64-byte per-state accounting charge is
a policy limit, not a measured heap or RSS ceiling.

## Plan, ownership and DoD

1. Root executes the public admission RED before production changes and owns
   this spec, loader, independent oracle, all compiler/native/Git jobs and
   evidence calibration.
2. Table worker owns Count batch/materialization owners, minimal
   `wide_part_table.cr` seams, Count sibling exposure from the profile/reader
   if required, and `spec/aggregate_count_table_w177_spec.cr`.
3. Offline worker owns dedicated Count offline admission/materialization,
   `offline_table.cr` seams and any necessary nominal value-union addition,
   plus `spec/aggregate_count_offline_w177_spec.cr`. It does not edit table
   worker paths.

Root runs affected Count, typed-table, window, offline/catalog and related
consumer regressions serially in DEBUG and RELEASE with
`W177_STOCK_ROOT=/private/tmp/crystal-click-w176-release-native.KH635o`
and `W176_STOCK_ROOT` set to the same root. Commands use `crystal spec` with
`--single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace`;
RELEASE adds `--release --no-debug`, through the 50%-free/12-GB/600-s guard.
Expected signal: exact recorded roster, zero failures/errors/pending, child
and guard exit 0, immutable code inputs. An executed nominal or hidden-axis
guard bypass must fail an unchanged negative assertion, then restored source
must pass final gates. Source review is supplementary, not independent proof.

Observed baseline `w177-admission-red`: four examples, three exact Count
admission assertion failures, passing UInt64 key-only control, zero
errors/pending, actual child/guard exit 1 and unchanged code inputs.

## Executed qualification

Root's final serial gates pass 254 DEBUG and 254 RELEASE examples across the
same 31 unique specs, zero failures/errors/pending, actual child and guard exit
0, and no input drift. The three disjoint rosters are below; each filename is
under `spec/`, and each roster is run unchanged in both modes with the flags
and stock environment above:

- Core (86 examples): `aggregate_count_consumers_w177_admission_spec.cr`,
  `aggregate_count_consumers_w177_oracle_spec.cr`,
  `aggregate_count_table_w177_spec.cr`, `aggregate_count_offline_w177_spec.cr`,
  `aggregate_count_w176_admission_spec.cr`, `aggregate_count_w176_reader_spec.cr`,
  `aggregate_count_w176_writer_spec.cr`,
  `aggregate_count_w175_admission_red_spec.cr`, `aggregate_count_w175_core_spec.cr`,
  `part_checksums_spec.cr`, `wide_part_spec.cr`.
- Consumers (117 examples): `multicolumn_table_scan_spec.cr`,
  `lazy_window_reader_spec.cr`, `offline_catalog_spec.cr`,
  `offline_catalog_w27_spec.cr`, `offline_catalog_w28_spec.cr`,
  `wide_part_table_projection_w87_spec.cr`,
  `offline_catalog_projection_w87_spec.cr`, `offline_tui_page_source_spec.cr`,
  `wide_part_table_w53_spec.cr`, `wide_part_table_w54_spec.cr`,
  `wide_part_table_w95_tuple_spec.cr`, `offline_catalog_w95_tuple_values_spec.cr`.
- Related types (51 examples): `simple_aggregate_w164_wide_spec.cr`,
  `simple_aggregate_w168_wide_spec.cr`,
  `wide_part_simple_aggregate_decimal_w169_spec.cr`,
  `wide_part_simple_aggregate_temporal_w170_spec.cr`,
  `wide_flattened_nested_consumers_w174_spec.cr`,
  `wide_flattened_nested_consumers_w174_guards_spec.cr`,
  `object_table_w130_root_spec.cr`, `object_offline_table_w130_spec.cr`.

Exact commands, input hashes and log hashes are indexed by
`w177-final-{core,consumers,related}-{debug,release}` in
`/private/tmp/crystal-click-architecture-r1.shwDws`. Root reconciles all six
records and their actual outputs against the same 962 code/test/example inputs:
inventory SHA256
`075ec955c090560bccd5d03e7193c803ffd91d5110c284d5c833b2d3378f932e`.
Exact-path formatting and `git diff --check` pass. This is the selected
functional roster, not a full-project suite or performance certificate.

The independent literal stock consumer oracle covers all three signatures,
165 two-part windows, full scans, selected/empty candidate granules, offline
PK candidates and retained detached state values. Separately, library-authored
normalized parts with different 1-row/3-row mark grids pass for each signature.
Invalid offline DDL is refused in full/window/values/PK routes both with parts
and with no candidates; valid empty catalogs remain green. A redistributed
hidden-key axis and a renamed later-part sibling each remain valid standalone
UInt64 lanes, but Count-only table construction refuses them before callbacks.
Count projection payloads and primitive numeric aliases remain refused.

Executed adversary: `w177-sibling-bypass-red` omits only the cross-part hidden
sibling-name guard and runs the unchanged table guard spec. Nine examples
produce exactly one expected assertion failure, zero errors/pending, actual
child/guard exit 1: the differently named valid key escapes admission. Root
restores the exact table SHA256
`038ab74d9b721c43758855d6bad3dbcc359e14f94e3b37c4d1f3e36625638d8a`
before all six final green gates. Root's scoped verdict is ROBUST; Luna's
read-only source review is supplementary and correlated, not independent proof.

Stock fixture lineage is W176's executed runtime 26.10.1.1201, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, executable SHA256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
Root refreshes the independent literal RowBinary and all 39 stock part files
before/after this slice: inventory SHA256
`a57ce4bcef9a89085d0173410ee92c763be81ffb38620ca598bed8f62d34d050`,
literal RowBinary SHA256
`33bcdcaac99d33bca124088a8c09e60e473700ac5ffce53345ed21bb63211d03`.
W176's existing 71 process outcomes and 142 stdout/stderr hashes were reconciled;
no new native writer run is counted for W177. Physical writer admission is
unchanged. The separate clean shallow source `095fae5865df96627496345209d6bbf2013121f3`
is unbuilt and must not be confused with this executed stock build.

Qualification refreshes when Count owners, table/offline admission, mark
policies, specs or fixture/runtime pins change. Missing temporary evidence
requires fixture regeneration with `scripts/recheck_aggregate_count_w176.rb`
and rerunning the declared gates. Overall types/MV/projections goal remains
active; memory/performance stays deferred and large facade decomposition remains open.

## Continuation

Confirmed frontier: W175-W177 pair the three exact Count signatures through
logical codecs, Wide parts and these consumers. Next useful discriminator is
a source/result-type and independently literal state inventory for other
AggregateFunction states or broader Count argument types, before admitting
another descriptor or serializer. Keep each newly admitted reader/writer
profile paired; do not infer it from a same-width carrier. General JSON/
Dynamic/Variant products, broader SAF, arbitrary-schema writing and MV/
projection inspection/storage still need their own slices. User authority
covers in-scope local implementation, Luna delegation and atomic local commits;
this slice grants no remote push or external data mutation. Recheck current
source/diff before continuing; do not reopen memory/performance yet.
