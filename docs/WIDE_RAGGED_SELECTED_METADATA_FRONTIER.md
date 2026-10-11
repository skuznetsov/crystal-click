# Wide ragged selected-column metadata frontier

Document status: W261 VERIFIED; root adversary ROBUST within the finite
canonical-stock/common-profile selected-column target. Ten-column stock
behavioral RED was observed at baseline
`7996476d260bf7507d326fed54b90642b3ec2e6b` before production integration.
The complete types, MV/projection and subsequent performance goal remains
ACTIVE. This slice repairs reader admission, not type semantics or speed.

## Anchor and scope

The existing Wide Array(Tuple) and Map readers already own typed public row
carriers, flattened element/entry schedules and leaf decoding. At the baseline,
their private metadata validators imposed a unique external UInt64 sibling;
generic Array(Tuple) and Map(Tuple) also imposed a two-column physical schema.
These are inherited fixture/writer profiles, not recursive serde laws. W261
reuses the bounded common metadata owner before the unchanged legacy path.

At the baseline, a root-built selected-read probe on the prior stock W260
nine-column Wide part read its eight ordinary control rows, then rejected
`seq Array(Tuple(...))` before any callback with `Array(Tuple) serialization
requires one UInt64 key and one selected payload`. Its `lookup Map(String,
Array(Nullable(UInt64)))` read succeeded: this part has only one external
UInt64. Do not generalize that RED to every Map family. The new witness adds
a second UInt64 and independently tests each affected Map route.

The new witness was captured at
`/private/tmp/crystal-click-w261-native-baseline.lWZO3s`. Stock schema, literal
native values, CHECK TABLE and the four two-row marks plus EOF passed. At the
unchanged production baseline, direct `u`, `side`, `tup`, `lc` and `v` reads
matched their literals. `seq` rejected the two-column Array(Tuple) profile;
`mapped`, `simple` and `lookup` rejected the unique external UInt64 sibling
restriction. Both selected table facades rejected `seq`. The baseline probe
exit 0 means `baseline_red_captured`, not reader GREEN. Earlier harness setup
failures never reached the reader and are not behavioral RED evidence.

Comparison source: `ed30948f095ecb70679986d7d60e27ad770ae27a` in
`/private/tmp/clickhouse-w254-upstream.AqeqyC`. Runtime provenance is separate:
stock 26.10.1.1201, build `d9bcb5ab007f0f6299f7f973f2642245bab3d028`,
executable SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
No claim of latest upstream or source/runtime equivalence is made.

## Design laws and boundaries

1. Reuse `SelectedColumnSerializationMetadata.proven?` for the exact existing
   common WITH_TYPES envelope: four parsed object keys, version 1, propagated versions true,
   exactly String version 1, sparse Default records with validated names and
   counts. A selected declaration binds to its physical type. No schema-size,
   sibling-key or fixture-column-name allowlist replaces that proof.
2. Apply the bounded proof to already admitted generic Array(Tuple) and all
   Map types already recognized by `validate_map_serialization`. Do not add
   new type grammar, reinterpret an unsupported Map as BASIC, or bypass the
   selected type predicate. A false proof follows the existing bounded legacy
   validator; detected parse/type/count corruption hard-fails and is never
   retried as another profile. This is not raw duplicate JSON member rejection.
3. Array/Map common metadata proof is not child-state or physical proof.
   Base-shaped SerializationInfo does not certify flattened cardinalities,
   BASIC Map topology, String prefixes, payload frames or marks. Preserve
   existing type plans, expected physical roster, LZ4/checksum/complete-grid
   validation, nullable masks, ragged schedules and materialization budgets.
4. These name-bound readers compare the exact unique selected substream set,
   independent of listing order, then use canonical reader order. Missing,
   duplicate or extra streams still reject. Sibling metadata and schema remain
   validated; an unselected String/Tuple is not a UInt64 key. Physical column
   block order remains the existing columns.txt contract.
5. Retain `WideArrayTupleRow`, `WideMapTupleRow` and existing ordinary Map
   carriers. Do not route these already typed columns through BinaryBulk to
   hide admission errors. Full, mark-window and EOF reads, mixed selection
   without pk, batch accessors and offline `.values` retain their contracts.
6. Unsupported versions, Sparse/custom metadata, Map WITH_BUCKETS and unknown
   layouts remain refusals. Legacy version/profile behavior is not widened.
   Compact JSON/Dynamic lifecycle, general writers, MV/projection execution,
   aggregate-state breadth and performance work are independent frontiers.

## Sealed qualification witness

An ordinary ten-column Wide table, LZ4/plain adaptive mrk2, eight deterministic
rows and four two-row marks plus terminal EOF:

```
pk UInt64
u UInt64
side String
seq Array(Tuple(id UInt64, details Tuple(note Nullable(String), score UInt32)))
mapped Map(String, Tuple(meta Tuple(note Nullable(String), id UInt64), score Nullable(Float64)))
simple Map(UInt64, Nullable(UInt64))
lookup Map(String, Array(Nullable(UInt64)))
tup Tuple(n UInt64, s String)
lc LowCardinality(String)
v Variant(String, UInt64)
```

Array row sizes `[0,0,2,0,0,0,1,2]`; Map(Tuple) entry sizes
`[0,0,3,0,0,0,1,2]`; independently ragged simple/lookup Maps. Include ordered
duplicate keys, nulls, embedded NUL and Unicode strings, distinct siblings
and zero-occurrence flattened intervals. Pin WITH_TYPES, propagated nested
versions, String v1 and BASIC Map. Check actual layout/schema/grid/CHECK TABLE
and ordered native JSONEachRow against independent literals, not values
derived from a self-writer or observed native output.

## Execution ownership and plan

Risk: CAUTION (persistent-format and typed consumer admission).
Rollback: exact-path local atomic feature commit, or preserve the clean
baseline while inspecting unstaged changes. No unrelated changes, remote
push, history rewrite, dependencies or runtime guard changes are authorized.
Pre-mortem: an early successful metadata proof silently skips a physical
layout or changes a typed carrier. Counter with stock bytes, public literal
checks, independent physical corruption and retained legacy fixtures.

1. Luna owns the W261 native support files:
   `scripts/probe_wide_ragged_selected_metadata_w261.rb`,
   `scripts/check_wide_ragged_selected_metadata_w261.cr`,
   `scripts/support/wide_ragged_selected_metadata_w261_fixture.cr` and
   `spec/wide_ragged_selected_metadata_w261_native_spec.cr`.
   The harness captures separate baseline admissions and ordinary controls;
   build/setup/process failures are not serializer RED evidence.
2. A second Luna owns minimal `src/crystal_click/wide_part.cr` hooks and
   `spec/wide_ragged_selected_metadata_w261_spec.cr`. Prepare falsifiers first;
   root observes RED before authorizing production edits. Coordinate shared
   fixture usage without overwriting other work. Root owns the SDD, independent
   adversary checks, docs/evidence and all build/spec/native execution.
3. Root seals the exact affected roster before execution: the W105-W108
   22-file roster, W258's enumerated 26 legacy regression paths plus its two
   focused/adversary files, existing Map reader/table/writer/plan/offline
   consumers W52-W54 and W61-W73, legacy W51/W55, and the numeric/array Map
   owner specs. Deduplicate paths; test no implicit glob or entire-suite claim.
4. Root executes focused and affected tests in DEBUG and RELEASE, serialized
   with unchanged run_safe.sh (minimum free 50%, one Crystal worker, 12 GiB).
   Command: `crystal spec EXPLICIT_PATHS --single-module --threads 1
   --link-flags=-fuse-ld=ld --error-trace --verbose` (add `--release`). Split
   cohorts if needed without dropping paths. Expected: actual examples pass,
   zero failures/errors/pending; fixture-gated compile-only is not coverage.
5. Root builds the W261 helper in both modes, then invokes
   `ruby scripts/probe_wide_ragged_selected_metadata_w261.rb --binary
   PINNED_RUNTIME --helper PREBUILT_HELPER --evidence-root FRESH_PRIVATE_TMP`.
   No builds inside the Ruby probe; all native jobs have bounded isolated
   paths, timeouts, threads and memory. Capture executable/version/build,
   actual exits/bytes, part file closure and before/after hashes. Require
   exact typed literals through direct, table/window/EOF and offline paths.
6. Guard checks: sparse and explicit Default metadata including supported
   Tuple siblings; malformed records, duplicate/unmapped record names, wrong counts and
   exact flags; unproven envelope and unsupported Map versions; reordered
   valid streams versus missing/duplicate/extra streams; wrong grids, corrupt
   payload and exact String/Tuple budget boundaries. Require failures before
   callbacks where the preflight contract promises that boundary.
7. Root hostile self-review attacks the broadest admission claim, false-proof
   legacy boundary, untouched later mark corruption and duplicate Map order.
   Another Luna review is correlated candidate evidence, not independence.
   After observed DoD, update this banner, `docs/PROJECT_STATUS.md`,
   `LANDMARKS.md` and `.landmark/evidence/wide-ragged-selected-metadata-w261.json`;
   stage exact relevant paths and make one local atomic feature commit.

## Observed result and qualification boundary

The production change is limited to 33 diff lines in `wide_part.cr`: reuse the
common proof for admitted generic Array(Tuple)/Map types, bind selected physical
streams by their exact unique name set, and validate actual UInt64 siblings
with canonical filename escaping. No leaf codec, public carrier, mark law,
writer, Compact lifecycle or new type grammar changes.

All 100 sealed existing spec paths pass 430 examples in each DEBUG/RELEASE
mode, zero failures/errors/pending, in 20 DEBUG and 12 RELEASE commands. Both
new W261 spec paths execute against fresh stock parts. The final four-path
focused command passes 22 examples per mode: 13 W261 examples plus nine old
W107/W108 examples repeated from the legacy roster. Thus 102 distinct spec
paths establish 443 distinct examples per mode, with 452 final executed
examples including the nine repeats. Diagnostic or intermediate runs are not
added to those counts. This is not the full repository suite.

Both final formatted helpers build. Fresh native DEBUG and RELEASE cells pass
the exact ten-column schema, raw CHECK TABLE result, full/middle literal rows,
full/window/EOF typed reads, mixed selection without pk, both selected table
facades, offline `.values` and exact logical String/Tuple budget boundaries.
Per cell: 85 stock files / 12,722 bytes and 38 plain `.mrk2` streams; all stock
bytes agree between modes. Final roots are
`/private/tmp/crystal-click-w261-final-debug.jmUfkP` and
`/private/tmp/crystal-click-w261-final-release.CIXu3R`.

The auditor's 64 mocked negative controls pass. Root separately runs two
actual-capture positives and 20 in-memory negative controls (ten per capture):
process exit, digest, coherently changed raw CHECK, ordered duplicate Map
values, stock schema, helper EOF/budget claims, inventory omission, coherently
changed late mark rows and escaped stream identity. All original 96 input
paths per capture remain unchanged. This audit reuses the runner oracle and
is not a second native codec, fresh corrupted-native-part execution, or
exhaustive corruption proof. Non-PK hashed mark names are counted but not
independently assigned one-to-one logical identities by the Ruby auditor;
selected reader checks and stock CHECK TABLE remain separate evidence.

Focused physical falsifiers also change only the late decompressed coordinate
of an Array(Tuple) UInt32 child (+4 bytes) and a Map(Tuple) UInt64 child (+8).
Both full and suffix windows reject before callbacks in both modes. Root's
initial hypothesis that `.mrk2` third coordinates should use flattened child
counts was refuted: all 38 stock streams use `[2,2,2,2,0]`, and pinned CH
`MergeTreeDataPartWriterWide.cpp:472-481` writes outer `rows_in_mark` to every
substream. Ragged child displacement belongs to the first two coordinates and
payload schedules, not the third coordinate.

## Retained diagnostics and non-guarantees

- The inherited W55 reordered-roster expectation fails at exact baseline HEAD
  in an isolated archive (five examples, one failure). Its test-only repair
  now asserts exact full/late values for a valid reordered roster, while the
  missing-stream refusal remains. Do not classify this as a W261 production
  regression or silently remove the guard.
- Earlier harness/auditor setup errors (nullable literal getter, overwritten
  helper provenance, Ruby 2.6 `filter_map`, escaped-name assumptions, lambda
  arity, byte-identical UTF-8/binary comparisons and standalone eval flags) are
  diagnostics, not serializer RED evidence. Final formatting of two support
  files caused a rebuild, fresh captures and repeated focused/audit checks.
  The retained behavioral RED capture has weaker helper-source provenance than
  GREEN captures; missing before/after fields are not manufactured.
- Crystal JSON parsing collapses repeated object member names last-wins. Root's
  standalone parser probe observes this for `version` and String-version keys.
  The metadata proof checks parsed objects, not raw duplicate members; no
  duplicate-key refusal is claimed. Pinned CH uses Poco JSON, but its duplicate
  semantics are not established from the available vendored worktree. This
  residual narrows the corruption claim; it does not certify raw ambiguity.
- Selected-column proof is not complete declared-type validation of every
  unselected non-UInt64 sibling's physical roster. The native oracle checks
  fixture tags/literals and byte closure, not an exclusive stdout grammar.
  Source and runtime pins are separate. Parts must be quiescent and directory
  ancestry trusted; logical budgets are not total heap/RSS or caller snapshots.
- Arbitrary metadata versions/products, Sparse/custom layouts, Map WITH_BUCKETS,
  context-owned Compact JSON/Dynamic, broader aggregate/SAF/QBit/Geo products,
  Compact writing/compressed marks, parent `.proj` authentication, general
  key/partition derivation and native MV SQL/trigger/freshness remain open.
  Existing bounded caller-run MV/projection seams are not those capabilities.
  Memory/performance and <=10% parity remain deferred and unqualified.

All 545 production Crystal sources remain at the same sealed state for the
final mode qualifications. The 102 spec paths plus four harness/support files
are indexed at closure. Root's scoped verdict is ROBUST after the observed
DoD and adversary controls; correlated Luna review is candidate evidence only.
The curated [root evidence](../.landmark/evidence/wide-ragged-selected-metadata-w261.json)
indexes actual commands, hashes, raw capture locations and scope, not proof by
field presence. Source/test/harness/oracle/tool/profile drift or capture loss
reopens dependent claims: refresh affected exact-mode tests and native/audit
checks. Next frontier: context-owned remaining layouts and parent projection
composition, before any performance work. Full goal remains ACTIVE.

## Sealed affected regression paths

The following 100 existing spec paths are the deduplicated affected roster
sealed before production edits. Add the two W261 focused/native spec paths;
fixture-dependent native specs run only with the captured stock part supplied.
This roster is not the full repository suite.

```
spec/multi_column_part_writer_w245_spec.cr
spec/offline_catalog_w53_spec.cr
spec/offline_catalog_w54_spec.cr
spec/offline_catalog_w63_spec.cr
spec/offline_catalog_w68_spec.cr
spec/offline_catalog_w69_spec.cr
spec/offline_catalog_w70_spec.cr
spec/offline_catalog_w71_spec.cr
spec/offline_catalog_w73_spec.cr
spec/offline_catalog_w95_tuple_values_spec.cr
spec/static_binary_bulk_table_w247_spec.cr
spec/static_recursive_selected_metadata_w258_adversary_spec.cr
spec/static_recursive_selected_metadata_w258_spec.cr
spec/storage_read_budget_w245_spec.cr
spec/wide_array_tuple_w107_admission_spec.cr
spec/wide_array_tuple_w107_consumer_spec.cr
spec/wide_array_tuple_w107_leaf_matrix_spec.cr
spec/wide_array_tuple_w107_metadata_spec.cr
spec/wide_array_tuple_w107_model_spec.cr
spec/wide_array_tuple_w107_reader_spec.cr
spec/wide_map_tuple_w108_admission_spec.cr
spec/wide_map_tuple_w108_consumer_spec.cr
spec/wide_map_tuple_w108_model_spec.cr
spec/wide_map_tuple_w108_reader_spec.cr
spec/wide_part_array_map_owner_w134_spec.cr
spec/wide_part_numeric_map_owner_spec.cr
spec/wide_part_reader_compositional_tuple_spec.cr
spec/wide_part_reader_nested_tuple_w106_spec.cr
spec/wide_part_reader_tuple_empty_eof_spec.cr
spec/wide_part_reader_tuple_metadata_spec.cr
spec/wide_part_reader_w21_spec.cr
spec/wide_part_reader_w22_spec.cr
spec/wide_part_reader_w23_spec.cr
spec/wide_part_reader_w27_spec.cr
spec/wide_part_reader_w28_spec.cr
spec/wide_part_reader_w30_spec.cr
spec/wide_part_reader_w31_spec.cr
spec/wide_part_reader_w32_spec.cr
spec/wide_part_reader_w33_spec.cr
spec/wide_part_reader_w34_spec.cr
spec/wide_part_reader_w51_spec.cr
spec/wide_part_reader_w52_spec.cr
spec/wide_part_reader_w53_spec.cr
spec/wide_part_reader_w54_spec.cr
spec/wide_part_reader_w55_spec.cr
spec/wide_part_reader_w56_spec.cr
spec/wide_part_reader_w61_spec.cr
spec/wide_part_reader_w62_spec.cr
spec/wide_part_reader_w63_spec.cr
spec/wide_part_reader_w64_spec.cr
spec/wide_part_reader_w65_spec.cr
spec/wide_part_reader_w66_spec.cr
spec/wide_part_reader_w68_spec.cr
spec/wide_part_reader_w69_spec.cr
spec/wide_part_reader_w70_spec.cr
spec/wide_part_reader_w71_spec.cr
spec/wide_part_reader_w73_spec.cr
spec/wide_part_table_low_cardinality_cache_spec.cr
spec/wide_part_table_w53_spec.cr
spec/wide_part_table_w54_spec.cr
spec/wide_part_table_w61_spec.cr
spec/wide_part_table_w62_spec.cr
spec/wide_part_table_w63_spec.cr
spec/wide_part_table_w64_spec.cr
spec/wide_part_table_w68_spec.cr
spec/wide_part_table_w69_spec.cr
spec/wide_part_table_w70_spec.cr
spec/wide_part_table_w71_spec.cr
spec/wide_part_table_w73_spec.cr
spec/wide_part_table_w95_tuple_spec.cr
spec/wide_part_writer_array_tuple_w107_spec.cr
spec/wide_part_writer_map_tuple_w108_spec.cr
spec/wide_part_writer_nested_tuple_w106_spec.cr
spec/wide_part_writer_nullable_tuple_w105_spec.cr
spec/wide_part_writer_w52_spec.cr
spec/wide_part_writer_w53_spec.cr
spec/wide_part_writer_w54_spec.cr
spec/wide_part_writer_w61_spec.cr
spec/wide_part_writer_w62_spec.cr
spec/wide_part_writer_w63_spec.cr
spec/wide_part_writer_w65_spec.cr
spec/wide_part_writer_w66_spec.cr
spec/wide_part_writer_w68_spec.cr
spec/wide_part_writer_w69_spec.cr
spec/wide_part_writer_w70_spec.cr
spec/wide_part_writer_w71_spec.cr
spec/wide_part_writer_w73_spec.cr
spec/wide_tuple_nested_w106_admission_spec.cr
spec/wide_tuple_nested_w106_model_spec.cr
spec/wide_tuple_nullable_w105_admission_spec.cr
spec/wide_tuple_nullable_w105_consumers_spec.cr
spec/wide_tuple_nullable_w105_lazy_spec.cr
spec/wide_tuple_nullable_w105_model_spec.cr
spec/wide_tuple_parameterized_consumers_w101_spec.cr
spec/wide_tuple_parameterized_reader_budget_spec.cr
spec/wide_type_plan_w67_spec.cr
spec/wide_type_plan_w69_spec.cr
spec/wide_type_plan_w70_spec.cr
spec/wide_type_plan_w71_spec.cr
spec/wide_type_plan_w73_spec.cr
```
