# AggregateFunction recursive static storage frontier (W224)

Document status: VERIFIED within the nine measured static recursive profiles;
scoped hostile verdict ROBUST. General products and layouts are not qualified.
Baseline: `b33b9f0bd65a2e41a1594bf38cceed850991d35b` (W223).
Context: immutable aggregate-state storage composition, not aggregation or SQL functions.

## Factual anchor and next capability

W223 qualifies finite root Count/Sum-family state columns. The W224 baseline
rejected AggregateFunction below a root in constructors, binary type/value
codecs, BinaryBulk planning and public declaration adapters. Existing Array,
Tuple, Map, Nullable and Nested codecs already own their recursive value and
physical schedules. The missing capability is contextual admission and public
routing, not a distinct serializer for every function/container product.

The comparison source is
`/Users/sergey/SrcArchives/clickhouse-2026-10-07-depth1`, revision
`0ca8150d9b1d0886edb2e3b4ab65eebb768d0357`. The separate runtime pin is
ClickHouse 26.10.1.1201, build `d9bcb5ab007f0f6299f7f973f2642245bab3d028`,
executable SHA256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
Source and runtime are not asserted to be the same build or today's master.

## Admitted recursive grammar and measured surface

- Static Array, named/unnamed Tuple, Map values with eligible ordinary keys,
  nominal Nested, and eligible Nullable(Tuple) enclosing admitted Count or
  W223 Sum-family leaves. Compose these constructors recursively, rather
  than recognizing an enumerated Cartesian list of declarations.
- Preserve exact function/argument identity, opaque state bytes and Count's
  VarUInt wire. Arguments remain recursively budgeted descriptor metadata,
  never stored value children or physical lanes.
- Reuse shared BinaryBulk publication, selected typed table batches and owned
  OfflineColumn.values. Admit ordinary OfflineTable typed callbacks/windows
  through the same generic BinaryValue route where the nominal profile permits.
- Qualify both stock-authored reads and library-authored ATTACH/CHECK/reads.
  The finite physical witness roster must exercise empty/uneven flattened
  domains, tuple sibling lanes, variable-width Count, null/default placeholders
  and short final marks; logical roundtrip is not sufficient.

## Rejected and guard-only surface

Direct Nullable(AggregateFunction) and invalid Nullable/LC constructions remain
rejected. AggregateFunction Map keys remain a library-profile guard in W224,
not a proven ClickHouse type prohibition: the pinned source's
`DataTypeMap.cpp:152-154` excludes Nullable and LowCardinality(Nullable) keys,
but does not itself exclude AggregateFunction. Measure runtime construction
separately from physical compatibility before widening that key route. Source
`DataTypeAggregateFunction.h:51` explicitly rejects direct Nullable, whereas
`DataTypeTuple.h:38` permits Nullable(Tuple). The pinned runtime separately
confirms direct Nullable(AF) and LC(AF) semantic refusals. Its empty
Memory-engine Map(AF key, UInt8) CREATE succeeds; that observation does not
qualify Map aggregate-key physical storage.

Aggregate-bearing Dynamic/JSON/Variant/LowCardinality state-envelope routes
remain guard-only and refused in this slice. Refusal is a library profile
boundary, not a claim that every such declaration is illegal in CH; Variant
alternatives and JSON typed paths can be source-legal. Other aggregate-state
families, unsupported parameters/versions, Compact, sparse/custom serializers,
mutable live parts, functions/finalization and native MV/projection writing
remain outside this slice. Memory/performance work stays deferred.

## Laws, risk and rollback

Risk: CAUTION (recursive persistent format and shared routing). Rollback:
one exact-path atomic local feature commit after DoD; no push/history rewrite.

Likeliest failure: relaxing the root guard also opens an unqualified state
envelope or mistakes aggregate argument metadata for a child row domain.
Guard checks must cover both supported recursive routes and prohibited
Dynamic/Variant/JSON/LC state sites. Count dispatch requires exact nominal
metadata, never merely shared tag 0x25.

Array/Map children use flattened element counts, not parent row counts.
Nullable physical lanes retain child placeholders even for null rows; logical
RowBinary null values can omit a child. Nested's named field and normalization
law must be measured before treating it as canonical source metadata. Marks
remain rooted in the parent row grid; container codecs own occurrence schedules.

Source `SerializationArray.cpp:352-394` writes sizes then delegates its child
with a computed nested offset/limit, including empty-domain stream access.
`SerializationAggregateFunction.cpp:58-83` delegates the state serializer.
Opaque Count and Sum leaf codecs must remain reusable in that schedule.

## Execution order and DoD

1. Freeze and execute existing-API behavioral RED:
   `spec/aggregate_recursive_w224_admission_red_spec.cr`, plus paired part
   and public consumer RED files. Distinguish assertion failures from compiler
   or fixture defects.
2. Execute an independent stock construction/physical probe before widening
   production. A crash/timeout/spawn failure is not an expected type refusal.
3. Core owner: `binary_data_type.cr`, a new one-class-per-file
   `binary_aggregate_function_recursive_admission.cr`,
   `binary_data_type_codec.cr`, `binary_value_codec.cr`,
   `binary_bulk_type_plan.cr`. Modify existing physical/encoder/decoder/default
   owners only if a concrete failing schedule requires it.
4. Public owner: AggregateFunction declaration, BinaryBulkColumnReader,
   WidePart/table/batch adapters, OfflineTable/materializer and paired writer.
   Reuse the existing public paired writer; no new return-value union.
5. Root-executed focused and affected DEBUG/RELEASE suites, fresh native
   helper/runner in both modes, exact state/window/consumer assertions and raw
   artifact audit. Execute a coherent negative audit control and exact restored
   positive control. Inspect source freeze and generated file inventories.
6. Hostile self-review, compact evidence/status update and atomic local commit
   only after the declared checks pass. Scope the result to the measured roster.

Jobs are serialized by root under
`/Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh` with minimum 50%
free memory, bounded time/memory and isolated cache. Crystal uses
`--single-module --threads 1 --link-flags=-fuse-ld=ld`.
Workers author code/source probes but never run compiler/Ruby/native jobs or git.

Expected DoD signal: zero failures/errors/pending for the affected roster in
both modes; exact pinned stock/library declaration, stream roster, real mark
grid [2,2,1] plus terminal zero, window bytes and public value identity; raw
audits reject a seeded contradiction and pass after exact restoration.
Executed commands and counts are indexed in
[the W224 evidence packet](../.landmark/evidence/aggregate-function-recursive-w224.json).

## Observed qualification and lineage

The 69-file affected roster passes 382 examples per mode, with zero
failures/errors/pending. Those broad runs precede a diagnostic-wording-only
change, formatter changes and extraction of the unchanged private admission
Frame into its own file. The final seven-file focused/Count-control roster
passes 39 examples in each mode after those changes. Both freshly built
native helpers also consume the final production file layout. This is a
composed qualification lineage, not a claim that all 69 files were rerun
after the file move or that the whole repository suite passed.

Fresh native matrices in each mode qualify these nine profiles:

- Array(Sum), plus two-level Array(Tuple(Count, Sum)) with a fully empty child mark.
- Named Tuple(Count, Sum, String), in both String serialization profiles.
- Map(UInt8, Count) and Map(UInt8, Sum).
- Nullable(Tuple(Count, Sum)), including physical default placeholders.
- Nominal Nested(Count, Sum) with flatten_nested=0; exact nominal metadata is
  observed on this runtime, not merely a normalized Array(Tuple) witness.
- Tuple(Count, LowCardinality(String)) with an aggregate-free dictionary sibling.

Each matrix observes nine stock-authored reads and nine library-authored
ATTACH/CHECK/exact RowBinary witnesses, using five rows, real marks [2,2,1]
and a terminal zero mark. Full/middle/empty windows contain 5/3/0 rows.
Each separate raw audit passes all 177 process records: 175 successful
processes and the two expected diagnostic semantic refusals, with no timeout
or spawn failure. All 146 generated part file inventories match across modes.

Executed negative controls replace one raw native CHECK success with result
zero while leaving the green summary unchanged. Both audits reject the seed;
restoring the exact original bytes/hash returns both to green. Runtime and
helper artifacts are externally pinned; summary hashes are not the authority.
The outer root process-group guard supplies the end-to-end 600-second and
memory bound; the recorder's direct-child timeout is not an equivalent bound.

Qualification uncovered tool-contract defects (directory reuse, pretty type
names, independent LC lane paths/index width, method receiver, evidence
carrier and trailing directory separator), not production serializer changes.
Failed attempts are retained separately. The final census oracle permits only
the exact canonical path or that path with one terminal separator, and still
requires exact row shape, fields, realpath confinement and full inventories.

## Evidence limits and next frontier

The generic recursion reuses existing Array/Tuple/Map/Nullable/Nested child
codecs and physical schedules. Only contextual admission, exact Count dispatch
and public routing change. Each new production type has its own file; broad
legacy facade decomposition remains open. Descriptor arguments never become
value children, and sum(UInt8) still uses its eight-byte accumulator codec.

The helper's `independent_lane_bytes` field is a BinaryBulk re-encoding of
independent expected fixtures, checked against Ruby literal lanes. It is not
an extraction of compressed lanes from either actual part. Actual-part
evidence is the exact reader values/grid/roster, complete input inventories
and native CHECK/RowBinary. `source_and_library_stream_roles_equal` is not an
audited certificate by itself. Stock public native coverage is WidePartTable;
offline owned values use synthetic catalogs containing library-authored parts.
Ordinary offline callbacks/windows, multi-part budgets and selected projection
child controls have unit evidence; new native offline projection integration
and whole stock-catalog discovery are not certified by W224.

The admission visitor's constructor cost and repeated subtree walks are not
performance-qualified. LC replay, logical ownership charges versus peak RSS,
mutable/live parts, remaining aggregate families and state envelopes stay open.
The next frontier is wrapper-specific stream/prefix/row-domain context for
remaining legal profiles, not a serializer per Cartesian type combination.
RowBinary recursion alone cannot certify MergeTree bulk layout compatibility.

## Falsifiers and continuation

- Nested descriptor depth and budget boundaries; no argument-as-value edge.
- Uneven arrays, all-empty child mark, two levels of arrays, variable Count
  width across a mark, empty/populated Map and named tuple siblings.
- Nullable tuple null/default state placeholders versus present payloads.
- Exact Count accessor on Sum; nominal function/argument substitutions.
- Wrong/missing lane, mark grid, sparse serializer or declaration, with staged
  publication preserving unrelated files on rejection.
- Public root Sum and wrapped-state callbacks/windows, borrowed batches,
  owned values and selected projection child-path controls.
- Dynamic envelope, Variant/JSON/LC state-site guard and Map key refusals.
- Raw process exit, CHECK's exact three-field TSVRaw success and artifact pins.

Stop and attribute source/runtime or normalization disagreements; do not weaken
the oracle or physical guards to manufacture a pass. Full type compatibility
and MV/projection support remain the active goal. A finite wrapper certificate
does not close all layouts or the later <=10 percent performance requirement.
