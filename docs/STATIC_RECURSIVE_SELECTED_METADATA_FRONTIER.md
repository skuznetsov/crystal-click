# Static recursive selected-column metadata frontier

Document status: W258 VERIFIED; root adversary ROBUST within the finite declared Wide selected-column target.
Baseline: `24ff9a4e30dcf3c3f502ae672b768649b9d9bd85`.
Current frontier: remove unrelated whole-table shape constraints from the
metadata admission of already supported static typed columns. Preserve their
typed public batches and owned offline values. The full types, MV/projection
and subsequent performance goal remains ACTIVE.

## Factual anchor and scope

The existing Array, named scalar Tuple, LowCardinality(String) and Variant
readers have codecs and public typed carriers, but their legacy metadata
validators often require exactly one UInt64 key/value pair. This is not a
wire-format law. A root-owned stock nine-column Wide/Compact probe produced a
valid WITH_TYPES envelope with `columns: []`, propagated nested versions and
String version 1. Selected Wide reads of these four families stopped at the
legacy whole-part shape guards; this is separate from the top-level Compact
reader gap. Earlier fixture/harness failures are not behavioral evidence.

At comparison source `ed30948f095ecb70679986d7d60e27ad770ae27a`,
`SerializationInfoByName::getKindStack` returns Default for an absent column
record (`SerializationInfo.cpp:506-510`). `IDataType::createSerializationInfo`
uses the base Default info, while `DataTypeTuple` builds recursive child info.
This does not make an absent metadata file, absent global settings, unknown
layout or malformed record valid. The comparison source is distinct from the
executed ClickHouse build `d9bcb5ab007f0f6299f7f973f2642245bab3d028`.

## Design laws

1. Add one own-file selected metadata owner at
   `src/crystal_click/wide_part/selected_column_serialization_metadata.cr`.
   Integrate it at the existing four family validators in `wide_part.cr`;
   do not change table dispatch to return generic BinaryValue for these types.
2. A proof binds the exact selected declaration and physical column names.
   It never requires a unique UInt64 sibling, a record for every column, or a
   fixed schema/column-count/fixture roster. Existing table key requirements
   remain separate from direct selected-column metadata admission.
3. The new proof admits the existing exact envelope: required four keys,
   version 1, propagated versions true, and exactly `{"string":1}`. Reuse the
   existing file/link/change checks, 4-MiB metadata and 4096-column bounds.
   String version 0 and other existing legacy profiles retain their bounded
   legacy validation; they are not newly admitted by this proof.
4. `columns` is an explicit sparse array. Each present record has a unique
   name in `columns.txt`, mandatory kind/default/row fields, valid counts and
   the part's row count. A missing selected entry means implicit Default
   inside this validated envelope. Optional `exact_num_defaults` is boolean.
5. Prove Default records with known info grammar. Non-Tuple records have
   shallow base info; explicit supported Tuple records require schema-ordered
   recursive child info using the existing bounded Tuple plan/validator.
   Unsupported Tuple schemas, kinds or additional metadata shapes are not
   proof of compatibility. Validate bounded common fields and schema identity
   before classifying a record outside the proof surface.
6. Distinguish a proven profile, a well-formed but unproven profile (at most one
   existing legacy metadata validation), and corruption (hard fail, never
   retry another codec). Invalid JSON/types/counts, duplicate or unmapped names
   are corruption. A valid but unsupported serializer kind is not mislabeled
   as data corruption. No broad exception catch may turn corruption into a
   successful legacy admission.
7. Preserve exact typed carriers, checksum/stream roster, complete mark grid,
   prefix/version, budget and materialization checks. No codecs are duplicated.
   This is a semantic admission repair, not a performance optimization.
8. The selected physical roster is bound by exact unique stream identity, not
   the listing order in `columns_substreams.txt`. Canonicalize an admitted
   roster for the existing reader bindings. An unselected sibling is not a
   UInt64 key merely because the selected family once used a two-column
   fixture; retain its existing schema/uniqueness/checksum guards instead.

## Admitted, rejected and guard-only surfaces

Admitted before W258: existing bounded typed profiles and W247's separate
generic static fallback, with their already qualified finite stock witnesses.
W258's new selected metadata proof is qualified within the finite witnesses below.

Finite qualification witnesses together in an ordinary seven-column Wide
table: pk UInt64, a second UInt64, an independent String, Array(Nullable(UInt64)),
Tuple(n UInt64, s String), LowCardinality(String), Variant(String, UInt64).
Use eight rows and four two-row marks plus EOF; the first Array mark is empty.
Exercise nulls, duplicate LC values, both Variant arms, mixed caller order,
full/nonzero windows and offline `.values`. This is a witness set, not a
product or seven-column admission allowlist.

Rejected/not widened: unknown serializer versions/kinds/layouts, arbitrary
Dynamic/JSON/Nested combinations, new leaf types, general key/partition laws,
MV SQL execution, parent projection-manifest authentication and actual
top-level Compact read/write. These remain independent frontier obligations.

## Execution plan, falsifiers and DoD

Risk: CAUTION (persistent-format and public typed consumer admission).
Rollback: revert only the resulting verified local atomic feature commit.
Preserve unrelated changes; no push or remote history operation is authorized.
Pre-mortem: relaxing a shape guard silently bypasses serializer metadata or
changes the selected value carrier. Counter it with direct public/offline
behavioral tests, malformed metadata and retained old profiles.

1. Luna owns
   `scripts/support/static_recursive_selected_metadata_w258_fixture.cr` and
   `spec/static_recursive_selected_metadata_w258_spec.cr`. Root runs the
   existing-API RED before any production edits. Use the normal N-column
   writer's unmodified envelope and literal independent logical expectations.
2. After observed RED, Luna owns the new metadata owner, minimal family hooks,
   require registration, the existing Tuple validator's optional exact flag
   support, and the selected-stream identity/sibling-role repair falsified by
   the first GREEN attempt. Root reviews the diff and the source-bound proof independently.
   Consumer inventory: the four private family validators in `wide_part.cr`,
   the public table's `open_selected_typed`, and offline typed materialization;
   Tuple child validation is shared with existing Tuple tests.
3. Root runs the focused spec in DEBUG and RELEASE, then a sealed enumerated
   affected roster in both modes under unchanged `run_safe.sh` (minimum free
   50%, one Crystal worker, 12 GiB; serialize cohorts if required). Command:
   `crystal spec spec/static_recursive_selected_metadata_w258_spec.cr
   --single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace --verbose`
   (add `--release` for RELEASE). Expected: executed cases pass, zero pending.
4. Guard cases: sparse Default sibling/selected entries, recursive Tuple info,
   optional exact flags, reordered/renamed/extra physical siblings; reject
   duplicate/unmapped names, malformed fields/counts/flags, wrong Tuple shape,
   unsupported versions/kinds, corrupt selected streams and grid mismatch.
   Preserve old pair fixtures, typed accessors and version-0 legacy behavior.
5. Root builds both native helpers and runs bounded stock-write/library-read
   and library-write/stock ATTACH/CHECK/exact-row witnesses. Runtime, schema,
   actual bytes/exits and generated file closure are captured independently;
   self-read alone is not stock compatibility. Native helpers and probe paths
   will be sealed before execution, not invented after seeing a result.
6. Hostile self-review follows the feature. Update this banner/falsifiers,
   `docs/PROJECT_STATUS.md`, `LANDMARKS.md` and a scoped root evidence packet
   only after executed evidence exists. Stage exact relevant paths and make
   one local atomic commit after the declared DoD passes.

### Sealed affected regression roster

Run these enumerated cohorts in DEBUG and RELEASE, serialized under the same
guard as the focused tests. This covers the changed family admission owners,
the shared Tuple child validator, retained generic Array(Tuple) boundary,
public/offline typed carriers and schema-wide publication. It is not a claim
to have run the entire repository suite.

- Array: `wide_part_reader_w21_spec.cr`, `wide_part_reader_w27_spec.cr`,
  `wide_part_reader_w28_spec.cr`, `wide_part_reader_w30_spec.cr`,
  `wide_part_reader_w31_spec.cr`, `wide_part_reader_w32_spec.cr`,
  `wide_part_reader_w33_spec.cr`, `wide_part_reader_w34_spec.cr`,
  `wide_part_reader_w51_spec.cr`, `wide_array_tuple_w107_metadata_spec.cr`.
- Tuple: `wide_part_reader_w23_spec.cr`,
  `wide_part_reader_tuple_metadata_spec.cr`,
  `wide_part_reader_compositional_tuple_spec.cr`,
  `wide_part_reader_tuple_empty_eof_spec.cr`,
  `wide_part_reader_nested_tuple_w106_spec.cr`,
  `wide_tuple_parameterized_consumers_w101_spec.cr`,
  `wide_tuple_nullable_w105_consumers_spec.cr`,
  `wide_part_table_w95_tuple_spec.cr`,
  `offline_catalog_w95_tuple_values_spec.cr`.
- LC/Variant and integration: `wide_part_reader_w22_spec.cr`,
  `wide_part_table_low_cardinality_cache_spec.cr`,
  `wide_part_reader_w56_spec.cr`, `multi_column_part_writer_w245_spec.cr`,
  `storage_read_budget_w245_spec.cr`, `static_binary_bulk_table_w247_spec.cr`,
  `wide_array_tuple_w107_consumer_spec.cr`.

All paths above are under `spec/`. If a cohort reaches the unchanged resource
limit, split it without dropping any named file. The root hostile test is
`spec/static_recursive_selected_metadata_w258_adversary_spec.cr`; run it with
the focused spec in both modes.

### Sealed native qualification commands

Build `scripts/check_static_recursive_selected_metadata_w258.cr` under the
same DEBUG/RELEASE Crystal guard into separately named supplied executables.
Its CLI is `roundtrip STOCK_PART LIBRARY_PART`. The probe never compiles code:

```
ruby scripts/probe_static_recursive_selected_metadata_w258.rb \
  --binary /private/tmp/crystal-click-w216-runtime-recovery.DmL9Kw/clickhouse-stripped \
  --helper PREBUILT_W258_HELPER \
  --evidence-root FRESH_DIRECT_CHILD_OF_PRIVATE_TMP
```

Use a different fresh evidence root for each mode. Reuse the bounded stock
process owner, version/build and health gates. Execute only the seven-column
Wide witness in this qualification; the prior Compact diagnostic is not a
success claim. The probe captures `invocations/native_source` and
`invocations/native_attach_check` stdin/argv/stdout/stderr/status artifacts,
`parts/all_1_1_0` and `summary.json`. Required signals: stock source actual
Wide kind, eight rows, four real two-row marks plus EOF, typed helper full,
middle and EOF plus offline reads, reciprocal ATTACH/CHECK=1 and native exact
rows compared with independently fixed literal expectations. Capture exits,
tool pins, schema, generated file closure and hashes; a self-read or count
alone is insufficient.

### Observed baseline falsifier

Before production edits, the root executed the focused spec at baseline
`24ff9a4e30dcf3c3f502ae672b768649b9d9bd85` under the sealed guard. Terminal
exit was 1: nine examples, zero assertion failures, eight metadata-admission
errors, zero pending. The ordinary key/u/side positive control passed. Each
of the four typed families and each independent offline `.values` case failed
at its legacy two-column guard. This is behavioral RED, not a compile/setup
failure. Production implementation was authorized by this observed falsifier;
no GREEN or native qualification was claimed at that stage.

### Observed downstream falsifiers

The first root-owned focused DEBUG attempt exited 1 with 22 examples,
zero assertion failures and 14 errors. Twelve behavioral errors distinguished
two downstream assumptions from metadata admission: an exact stream roster
was compared by listing order, and Tuple/Variant treated every unselected
sibling as a plain UInt64 key. Two other errors were fixture mutations that
used literal filenames instead of the writer's hashed stream names; those
were setup failures, not wire-format counterexamples.

After the bounded stream-identity/sibling-role repair, a second DEBUG command
executed the focused and hostile specs with 24 examples. The positive cases
passed, but terminal exit remained 1: two real assertion failures and one
mutation setup error. The behavioral falsifiers were an earlier unproven
top-level record hiding a later malformed Tuple child, and an earlier
unsupported Tuple child hiding a later missing common field. Both returned
UnsupportedFormatError instead of the required CorruptPartError. The remaining
setup error attempted to modify a read-only String slice; clone the test
buffer before mutating marks. These are discriminating failures, not GREEN;
recursive common-field validation must complete over the bounded known schema
before unsupported-profile classification can end admission.

The next root-owned DEBUG run executed 26 examples and exited 1 with one
assertion failure and one behavioral error (zero pending). Earlier recursive
and stream/grid counterexamples passed. A fresh falsifier showed that the
public Tuple plan already accepts `Tuple (n UInt64, s String)`, but the new
proof inferred Tuple identity from the narrower literal `Tuple(` prefix. It
incorrectly proved shallow explicit info without required Tuple children and
rejected valid recursive info for that admitted spelling. Bind known Tuple
identity to the existing bounded type plan, while retaining an unproven
result for unsupported Tuple schemas. This does not widen the type grammar.

### Observed sealed specification gates

The final frozen production state passes all 28 sealed spec files in each
DEBUG/RELEASE mode: 26 focused/hostile, 71 Array, 46 Tuple and 37 integration
examples, totaling 180 per mode, zero failures/errors/pending. This is not
the full repository suite. The retained generic Array(Tuple) metadata and
consumer cases pass in both modes.

Two legacy assertions were superseded by actual admitted behavior, not removed
without a replacement: named `Tuple(b String, a UInt64)` reads exact named
values while its specialized UInt64/String pair accessor still refuses it;
an exact reordered Variant substream roster reads full and nonzero windows,
while an unadmitted arm type and a missing stream still refuse. Both affected
cohorts were rerun in DEBUG and RELEASE after these corrections.

### Native harness diagnostics, not compatibility certificates

The first native attempt stopped before any ClickHouse invocation because a
runtime-hash wrapper was missing. The next source invocation exited 0 with
CHECK=1, but the oracle rejected TSV `\\N` for Variant None. SQL now emits hex
of `ifNull(toJSONString(v), 'null')`; the global hex parser remains strict.
A canonical JSON null control passes; three bounded negative controls reject
raw TSV null, malformed JSON and a nonnull payload carrying the None tag.

Later source/helper captures exposed two harness path errors: `library_part`
is not an admitted MergeTree part basename, and a trailing slash in the stock
part path caused the helper's byte-offset calculation to remove the first
character of every relative filename. Use `parts/all_1_1_0` and a normalized,
checked directory prefix without loosening public-name or inventory guards.
The latter capture has source and helper exit 0 and complete logical reports,
but the incomplete inventory proof is not reciprocal native qualification.
Two sandbox attempts exited 75 because the unchanged process guard could not
observe process-group isolation through `ps`; they are environment diagnostics.
Subsequent guarded execution uses the platform-approved outside-sandbox path,
with the same 50% free-memory floor, one worker and 12-GiB ceiling.

The first independent root auditor also joined a trailing-slash stock path
with another slash. Its 41 entries and all size/hash pairs matched, but its
relative-name comparison failed. Normalize and check the auditor's directory
prefix, preserve the failed log, and rerun against the original captures;
neither the library nor native captures changed for this correction.

### Observed reciprocal native and adversary gates

Both sealed DEBUG and RELEASE helpers build and their fresh native cells
exit 0. Each cell has three actual successful processes, no signal/timeout,
and empty stderr: stock creation/readout, library typed read/write, and native
ATTACH/CHECK/readout. Raw stock and attached-library schema and full/middle
literal rows agree with independent expectations; CHECK returns 1. Public
typed full/middle/EOF reads and owned offline values retain their exact carriers.

Root separately audits raw argv/stdin/stdout/stderr/status captures and the
complete actual file inventory, including all 16 mark streams per part.
Stock parts have 41 files / 6,081 bytes; generated parts have 40 files /
6,517 bytes. Every mark file has five 24-byte records; the key grid is
`[2,2,2,2,0]`. All 40 generated files agree by actual bytes between modes;
stock-versus-library byte identity is not required or claimed.

Fourteen controls over actual captures reject forged-green nonzero exits,
raw CHECK=0 and omitted existing file entries, after original acceptance.
Original captures remain unchanged. A further 14 bounded mocked oracle
refusals and three Variant None refusals pass with positive controls.
These checks qualify this finite compatibility target, not exhaustive
production corruption handling or the entire repository suite. Root's scoped
verdict is ROBUST; same-lineage Luna review is correlated, not independent.
See the [curated root evidence](../.landmark/evidence/static-recursive-selected-metadata-w258.json)
for executed gates, source/runtime distinction, hashes and retained diagnostics.

## Continuation and evidence decay

The sealed DoD passes within the stated target. Selected-column admission does
not validate the declared type of every unselected non-UInt64 sibling's roster.
This repair does not qualify arbitrary recursive products or top-level Compact.
Refresh evidence after metadata admission, Tuple validation, codec/layout,
consumer, helper/oracle or tool changes, or capture loss. Same-lineage Luna
review is correlated evidence. Logical value budgets do not certify RSS.
After this consumer seam, return to the stock Compact event/mark framing
falsifier; do not replace the full goal with this narrower feature.
