# Count Wide-part frontier (W176)

Status: VERIFIED within the three explicit Wide/LZ4 profiles below
(2026-10-05). Overall types, MV/projections and architecture work remain
IN_PROGRESS. Memory/performance is deferred.

## Problem and admitted boundary

W175 provides nominal Count descriptors and raw state codecs, but not complete
parts. W176 writes only an explicit Wide/LZ4 pair with a sorted UInt64 key and
one scalar state column of one of these exact canonical signatures. Its Count
reader requires that two-column schema; opening the Count column alone does
not prove that the UInt64 sibling is an ORDER BY key or has sorted values.
The admitted signatures are:

- `AggregateFunction(count)`
- `AggregateFunction(count, UInt64)`
- `AggregateFunction(count, Nullable(UInt64))`

The public state carrier retains its nominal `BinaryDataType`; it is not a
UInt64 column, finalized aggregate result, or general aggregate executor.
Count state wire bytes are minimal VarUInt, not eight fixed-width bytes. The
nullable argument signature still has one state data stream, no null-map.
Reader/writer admission must be paired. Selected mark ranges must consume
exact states without crossing mark boundaries; each row requires at most ten
bytes. A public call materializes at most 65,536 selected rows; larger parts
must be read in bounded mark ranges. A zero-mark public call raises
`BoundsError`; the low-level decoder admits zero rows with an empty lane.
Count must not enter generic fixed-width, String, borrowed, Dynamic,
recursive product, table or offline-materialization routes accidentally.

## Factual anchors

Baseline: `18f66a8`, clean before W176 work. Fresh unbuilt CH source:
`/Users/sergey/SrcArchives/clickhouse-2026-10-05-depth1-095fae58`, commit
`095fae5865df96627496345209d6bbf2013121f3`. This is not the executed runtime.
`SerializationAggregateFunction.cpp:58-110` delegates column scalar/bulk state
serialization to the function, unlike String-framed Field serialization.
`AggregateFunctionCount.cpp:101-123` and `AggregateFunctionCount.h:111-132`
serialize Count with VarUInt. The generic CH Count argument domain is broader
than this intentionally closed local profile.

Executed stock runtime: 26.10.1.1201, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, executable SHA256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
Root's isolated probe at `/private/tmp/crystal-click-w176-stock.v1hJ3j`
observed 19 successful processes with pre/post executable hash checks. For
each signature stock authored a five-row Wide/LZ4 part via independently
literal RowBinary states: keys 7,13,22,31,50; counts 0,127,128,16384,MAX.
Exact RowBinary, finalizations, nominal columns metadata and CHECK all agree.
Three data marks have rows 2/2/1 plus a terminal mark. The state lane has 17
bytes, not 40. These temporary witnesses are reproducible inputs, not a
permanent claim about arbitrary AggregateFunction or the fresh source build.
The first probe failed because its Ruby stdout retained text encoding during
binary equality; the corrected probe compares binary strings in a fresh store.

## Risk, rollback and strongest failure modes

CAUTION: widening persistent-format admission. Use small dedicated Count
classes, one per file, and minimal facade delegation. Existing closed gates
remain for all other AggregateFunction shapes. Rollback is the atomic local
commit or the exact scoped diff; do not touch unrelated work or external data.

The strongest failure modes are a UInt64 alias with incorrect byte offsets,
mark-local under/over-read, same-count/different-signature staged acceptance,
or CHECK-valid parts whose values differ. Guards must reject nonminimal,
overflowed or truncated states, wrong nominal type, incompatible metadata,
bad marks and Count compressed-frame checksums before exclusive publication. The
existing `PartChecksums.validate_selected_entries` checks file presence and
size only, not arbitrary file hashes. The new writer generates hash records
from its output buffers, checks staged metadata/index/mark-local values and
uses native CHECK as a separate whole-part checksum oracle in the tested
fixtures; this is not a new general hash-verification API. Same nominal type with
changed values is a separate falsifier: stock CHECK alone cannot detect it.
The selected Count path verifies each traversed frame's bounded CityHash128
prefix before method dispatch/decompression. Other reader profiles and the
public whole-file checksum-verification status are not widened.

## DoD and rejected scope

Before implementation, root runs the public Count admission assertion RED
with a passing primitive key control against the stock-authored parts.
After implementation root runs the exact affected Crystal roster in DEBUG
and RELEASE under the serial memory guard, with immutable input snapshots.
It must establish all three nominal signatures, exact full and selected mark
state counts, empty-window policy, state boundary values, wrong-type refusal,
corruption refusal, stage cleanup and exclusive destination behavior.

Native reciprocal gate: stock-created parts read exactly in Crystal;
Crystal-created parts ATTACH and CHECK in isolated stock stores, with exact
nominal metadata, full/middle/empty RowBinary and finalized counts. A
same-type value mutant must remain CHECK-valid but fail the unchanged literal
value oracle. An executed staged nominal/equality guard bypass must produce
an expected assertion failure, followed by restored-source green gates.

No table/catalog support, Count inside products, outer Nullable, parameters,
nonzero serialization versions, other argument types, Compact parts,
aggregate execution, compound keys, general MV/projections or performance
claim is admitted. Logical Count remains strict minimal VarUInt even though
stock readers accept some noncanonical encodings. Overall goal stays active.

Refresh after Count owners, Wide gates, metadata/mark policies, staged
validation, selected specs or runtime changes. Next frontier after this slice
is explicit table/window/offline consumers, independently qualified; do not
infer their readiness from part support.

## Implementation plan and ownership

1. Reader worker owns `wide_aggregate_count_storage_plan.cr`, a dedicated
   bounded Count state reader, a narrow Count serialization profile,
   `wide_part.cr` delegation and
   `spec/aggregate_count_w176_reader_spec.cr`. Closed nominal parsing and
   byte-boundary checks precede typed values. Table source is not widened.
2. Writer worker owns `aggregate_count_column_stream_writer.cr`, a dedicated
   staged Count validator, `wide_part_writer.cr` entrypoint and
   `spec/aggregate_count_w176_writer_spec.cr`. Existing private stage, index,
   checksum and exclusive publication helpers retain their visibility.
3. Root owns loader, admission spec, independent native oracle, source review,
   all serial gates, evidence calibration and exact-path local commit.

Observed initial gate: `w176-admission-red`, four examples, three exact Count
assertion failures, passing UInt64 control, zero errors/pending, child/guard
exit 1. No production admission was inferred from a compile failure.

Executed focused gate (DEBUG then RELEASE, separate empty writer-output roots):
`crystal spec spec/aggregate_count_w176_admission_spec.cr
spec/aggregate_count_w176_reader_spec.cr spec/aggregate_count_w176_writer_spec.cr
spec/aggregate_count_w175_admission_red_spec.cr
spec/aggregate_count_w175_core_spec.cr spec/wide_part_spec.cr
spec/wide_part_writer_spec.cr spec/part_checksums_spec.cr
spec/wide_part_writer_typed_mark_readback_spec.cr
spec/wide_part_writer_metadata_w150_spec.cr` with
`--single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace`; RELEASE
adds `--release --no-debug`. Set `W176_STOCK_ROOT` to the independently authored
stock fixture root and `W176_PART_ROOT` to a fresh output root. Expected signal:
all examples pass, zero errors/pending, actual exit 0 and unchanged source
snapshots. Root uses `run_gate.rb` through the 50%-free/12-GB/600-s serial
guard; no competing compiler or native process runs.

Native DoD: `ruby scripts/recheck_aggregate_count_w176.rb EMPTY_TMP_EVIDENCE_DIR
LIBRARY_PART_ROOT` through the root serial guard. It creates fresh stock
fixtures and attaches all three library parts plus a same-type value control;
every command must succeed and literal metadata/part axes/value/window checks
must agree. A source-only invocation has already passed 31 stock processes at
`/private/tmp/crystal-click-w176-capture.xmPlEQ`; this is not writer evidence.

## Observed qualification and continuation

Public APIs are `WidePart#read_aggregate_count_mark_range(column, first_mark,
mark_count, expected_type)` and
`WidePartWriter.write_uint64_aggregate_count_pair(destination, key_name, keys,
value_name, type, values, rows_per_mark: ...)`. Values are owned nominal
`BinaryValue` Count states, not finalized UInt64 columns. The writer validates
sorted input keys and exact nominal states before staging; staged semantic
readback, metadata/axes/index checks and exclusive publication retain their
existing private lifecycle.

Root's final `w176-final-debug` and `w176-final-release` records each contain
89 examples, zero failures/errors/pending, actual child/guard exit 0 and no
changed code inputs. The exact ten-spec roster above and all input hashes
match across modes. Records/log hashes reconcile with restored source under
`/private/tmp/crystal-click-architecture-r1.shwDws`. The final stock fixture
root is `/private/tmp/crystal-click-w176-reciprocal.dQXCc0`; separate output
roots are `/private/tmp/crystal-click-w176-final-debug.kOzJ26` and
`/private/tmp/crystal-click-w176-final-release.jfKdyr`. All four DEBUG/RELEASE
output parts, including the value mutant, are byte-identical. This is an
affected-roster certificate, not a full-project test-suite or benchmark claim.

Root executed two reciprocal native runs with independent fresh stores:
71 successful processes each, 142 actual statuses total, with captured-output
hash and pre/post runtime-pin reconciliation. The records are
`/private/tmp/crystal-click-w176-reciprocal.dQXCc0/summary.json` and
`/private/tmp/crystal-click-w176-release-native.KH635o/summary.json`.
Each covers three stock parts, three library nominal profiles and one library
value mutant through ATTACH/CHECK, exact schema/part axes, full/middle/empty
RowBinary and finalized counts. ATTACH can normalize server metadata; this
does not certify an unbuilt source snapshot or arbitrary pre-ATTACH layouts.
An actual Ruby equality assertion against `value-mutant-full.stdout` and the
unchanged independent literal baseline exits 1: 128 differs from 129 although
CHECK succeeds. The native script is the reproducible oracle, not the temporary
record path itself.

Executed corruption/guard controls:

- The Count frame-checksum test first fails because no exception is raised:
  `w176-frame-checksum-red`, 88 examples, one expected failure and one unrelated
  invalid-directory-name fixture error, actual child/guard exit 1. The fixture
  now uses `all_1_1_0`. The guarded restored gates above have zero errors.
- `w176-staged-bypass-red`, the reader/writer specs only: 20 examples, exactly
  two failures, zero errors/pending and child/guard exit 1 when observed nominal
  identity and value comparison are temporarily bypassed. Both unchanged
  assertions detect the forbidden publication.
- `w176-mark-boundary-bypass-red`, the same two specs: 20 examples, exactly one
  failure, zero errors/pending and child/guard exit 1 when whole-range decoding
  replaces per-mark decoding. A moved internal boundary with refreshed outer
  hashes must be refused even though total bytes/rows are unchanged.

Exact restoration is checked by source hashes: WidePart
`e4b105b78fb031be09383573de863daa8ebc010a76c95ab1b52ea45e1e7ca4ec`,
staged validator
`dd6dbc6a0d09ddf60f4d3e91f1e5bd6347cd9247e912abe75495ffdc9a21a069`.
The first focused compile attempt exposed a spec-only `Array#to_slice` misuse;
it was repaired before executed assertions, not counted as a semantic RED.
Exact-path formatting, Ruby syntax and diff checks pass. Root's scoped
adversary verdict is ROBUST; Luna's source review is supplementary and
correlated. No general whole-part hash or reader key-provenance claim follows.

The next frontier is explicit Count table/window/offline consumers with
paired metadata and refusal guards. Other aggregate states, broader type
products, general MV/projections and large facade decomposition remain open.
Refresh this certificate on the owner/gate/spec/runtime changes named above;
rerun the declared commands if temporary evidence is unavailable.
