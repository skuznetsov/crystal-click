# Nested storage frontier — W171

Status: VERIFIED within the bounded unflattened Wide/LZ4 storage profile
(2026-10-05), not general Nested or complete type compatibility.
Baseline: clean `64b3573a8ff3b7607ef03ebfe6058b38a718aa69`.
Risk: CAUTION (storage admission); rollback: one scoped local commit.

## Target and boundary

Pair reading and writing one unflattened `Nested(...)` payload with one sorted
UInt64 key in Wide/LZ4 parts. Preserve the nominal Nested declaration in
metadata and owned results. Reuse W107's ragged outer-row/flattened-element
schedule, Tuple leaf codecs, aggregate bounds, staged readback and exclusive
publication; do not duplicate a decoder or writer for each child type.
The inherited named, nonempty Tuple/scalar-leaf profile and limitations apply.
Row handles may share W107's structural Array-of-records value representation,
but the retained column type must remain Nested, not Array(Tuple).

Flattened sibling Arrays (`flatten_nested=1`), shared-offset group discovery,
general Nested binary descriptor/value/bulk support, unsupported container
edges, Compact/Sparse and general MV/projection writing remain rejected in
this slice. They remain required follow-up work, not completion of all types.
Existing Array(Tuple), Tuple, MV and projection admission must not widen by
accident. Memory/performance optimization remains deferred.

## Anchors and design laws

Fresh shallow source: `e9b645ed83ad3c07b64f09fbd014e8f770d8691b`, unbuilt.
`src/DataTypes/DataTypeNested.cpp:35-75` preserves custom Nested identity over
Array(named Tuple); `DataTypesBinaryEncoding.h:58,136` assigns tag 0x2F.
Type identity is not itself a physical-layout certificate. Stock construction
and exact file/mark/RowBinary observations must establish the chosen profile
before production admission. Executed stock remains separately pinned to
26.10.1.1201, build d9bcb5ab, binary SHA256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.

Use one aggregate source/depth/node parser budget, charging the structural
Array and Tuple nodes even when their syntax is written as Nested. Preserve
escaped Tuple-edge stream naming, exact leaf identity and NULL-first semantics.
Physical marks count outer rows; payload/null/String-size streams count
flattened elements; raw String bytes are a third axis. Empty element marks
must still validate their row schedule and child boundaries.
Full writer/read ranges inherit 65,536 outer-row/element caps and a combined
logical 64 MiB bound, not an RSS guarantee. Preflight precedes copies/staging;
complete staged nominal/semantic readback precedes exclusive publication.

## Execution plan and falsifiers

1. Retain stock-only Nested flatten=0/1 and Array(Tuple) control observations
   under a fresh isolated directory. Check literal full/middle/empty outputs,
   schema, physical substreams, serializer versions and real/final mark axes.
2. Add a baseline assertion showing exact Nested admission is currently false.
   Run it unchanged before production edits; compiler/instrument errors are
   not feature RED evidence.
3. Add the bounded nominal plan/parser seam in separate cohesive owners;
   route shared physical storage consumers without widening Array-only APIs.
   Pair explicit Nested reader/writer entrypoints, then table/offline scans.
4. Run focused new and affected W106/W107 gates serially in DEBUG/RELEASE.
   Stock must ATTACH/CHECK a library-authored complete part and return literal
   full/middle/empty bytes. Reader must also consume the stock-authored part.
5. Attack nominal confusion, bad size sums/leaf axes, empty marks, malformed
   declarations and staged-readback failure/no publication. Qualify a gate
   using a seeded nominal or value defect; restore exact source afterward.

Consumer inventory: `WideArrayTupleTypePlan.for_type` consumers include
WidePart admission/metadata/stream opening, ArrayTupleReader, the staged
ArrayTuplePartWriter, table adapter and offline materializer. Keep the old
Array-only admission factory distinct from any new physical-storage factory.
Shared row-handle ownership and borrowed batch-slice lifetimes remain unchanged.

DoD: declared serial guarded Crystal spec rosters pass with zero failures,
errors and pending in both modes; actual stock child statuses are zero and
literal/metadata/mark checks match; seeded defect fails the unchanged oracle;
format and git diff checks pass. Record exact rosters and evidence paths below.
Stop/pivot if stock physical layout differs: revise the storage plan rather
than flattening away nominal identity or weakening the oracle.

## Evidence and next track

Source-law probe executed under the serial resource guard (exit 0):
`/private/tmp/crystal-click-w171.pMJBfo/nested-source-law-20261005-78412-1tiig41/manifest.json`.
The repository replay owner is `scripts/probe_nested_storage_w171_source.rb`;
the earlier scratch capture is not the final replay instrument.
All 40 captured child statuses are zero; root reconciled their retained
stdout/stderr SHA256 values. An independent literal encoder matches all 24
full/middle/empty-Nested-row/no-row RowBinary and names/types windows across
Nested flatten=0/1 and the Array(Tuple) control. Direct LZ4 decompression of
each physical size0 file gives per-row lengths `[2, 0, 1, 3, 2]`; all seven
stream mark grids have outer rows `[2, 2, 1, 0]`, including the terminal mark.
The unflattened Nested/control fourteen data/mark files are byte-identical,
but their `columns.txt` declarations differ nominally. Unflattened Nested
has six ordered payload substreams, serialization version 1, propagated
String version 1, and only the PK statistics record. Flattened siblings share
the same size0 file; this observation does not admit that separate API lane.

Baseline RED at `64b3573a`: the unchanged admission spec compiled and ran
under the serial guard: 2 examples, 1 assertion failure, 0 errors/pending.
The exact Nested witness returned false; malformed declarations remained
rejected. No production edits preceded that execution.

Paired production entrypoints are `WidePartWriter.write_uint64_nested_part`,
`WidePart.read_nested_mark_range` / `each_nested_mark_range`, and
`TypedBatch.nested_rows_for`. Table full/window scans and offline column
`.values` retain owned structural row handles and canonical nominal Nested
identity. The shared Array-only reader/writer and batch accessors still
refuse Nested. Parser source/depth/node boundaries and metadata refusals,
empty rows/element marks, later child boundaries, inconsistent flattened
cardinality and pre-publication rollback have executable checks.

The consumer guard has an actual pre-fix RED: a same-shape Array result was
accepted where the unchanged table/offline test required CorruptPartError.
After adding the guard, canonicalized legal whitespace remains accepted for
both Array(Tuple) and Nested. A temporary Nested-only bypass of staged
nominal/cardinality and leaf comparisons fails the unchanged six-example
staging spec with two intended assertion failures, no errors/pending.
The source was restored exactly (ArrayTuplePartWriter SHA256
`9f2122eab7f8ace19ce54ddff3c4d3f88085298fb0dca8e328ad1b4498a823ee`).
The final focused roster passes 86 DEBUG and 86 RELEASE examples, each with
zero failures/errors/pending and actual guard/child exit 0. An earlier
callback-count expectation was corrected from one to two mark batches; it
was an instrument failure, not a production defect or feature RED.

## Replay commands and exact focused roster

Both spec modes run serially through
`/Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh`, with the Crystal
executable `/opt/homebrew/bin/crystal`, timeout 180 seconds and process-tree
limit 8192 MiB. Environment: `COGNI_RUN_SAFE_MIN_FREE_PCT=50`,
`RUN_SAFE_PASSTHROUGH_STDIO=1`, `TMPDIR=/private/tmp`,
`SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`, and an
isolated `CRYSTAL_CACHE_DIR` for each mode. The unchanged guard requires
process-group/RSS observation; sandbox-only attempts aborted before launch
and are not counted as feature tests. Root used approved escalation rather
than weakening the guard. DEBUG uses `cache-debug`, RELEASE `cache-release`
under `/private/tmp/crystal-click-w171.pMJBfo`. Common flags:
`--single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace`; RELEASE
adds `--release`. Root observed both passing final modes in tool sessions
58289 and 53818 (approximately 48 and 105 seconds respectively).

Pass these 22 paths to `crystal spec` in either mode:

```text
spec/wide_nested_w171_admission_spec.cr
spec/wide_nested_w171_model_spec.cr
spec/wide_nested_w171_metadata_spec.cr
spec/wide_nested_w171_staging_spec.cr
spec/wide_nested_storage_w171_spec.cr
spec/wide_array_tuple_w107_admission_spec.cr
spec/wide_array_tuple_w107_metadata_spec.cr
spec/wide_array_tuple_w107_model_spec.cr
spec/wide_array_tuple_w107_reader_spec.cr
spec/wide_array_tuple_w107_leaf_matrix_spec.cr
spec/wide_array_tuple_w107_consumer_spec.cr
spec/wide_part_writer_array_tuple_w107_spec.cr
spec/wide_tuple_nested_w106_admission_spec.cr
spec/wide_tuple_nested_w106_model_spec.cr
spec/wide_part_reader_nested_tuple_w106_spec.cr
spec/wide_part_writer_nested_tuple_w106_spec.cr
spec/wide_map_tuple_w108_admission_spec.cr
spec/wide_map_tuple_w108_model_spec.cr
spec/wide_map_tuple_w108_reader_spec.cr
spec/wide_map_tuple_w108_consumer_spec.cr
spec/wide_part_table_projection_w87_spec.cr
spec/offline_catalog_projection_w87_spec.cr
```

The stock-only source capture command is:

```text
ruby scripts/probe_nested_storage_w171_source.rb
  --clickhouse /private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped
  --workdir /private/tmp/crystal-click-w171.pMJBfo
  --source-root /Users/sergey/SrcArchives/clickhouse-2026-10-05-depth1
  --source-label e9b645ed83ad3c07b64f09fbd014e8f770d8691b
```

The paired native qualification command, under the same serial guard and
common Crystal flags, is:

```text
crystal run scripts/check_nested_storage_w171_oracle.cr --
  --clickhouse /private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped
  --source-manifest /private/tmp/crystal-click-w171.pMJBfo/nested-source-law-20261005-78412-1tiig41/manifest.json
  --workdir /private/tmp/crystal-click-w171.pMJBfo
```

These multiline blocks list argv, not directly executable shell scripts.
The Crystal oracle's first compile attempt used Ruby's unavailable
`String#delete_prefix` and was corrected to installed Crystal's `lchop`.
That compiler error is not a feature RED or native compatibility evidence.

## Native qualification, adversary and residual risk

Root executed the final paired oracle under the unchanged guard (tool session
62193, exit 0, approximately five seconds, no compiler warnings). Capture:
`/private/tmp/crystal-click-w171.pMJBfo/nested-storage-w171-oracle-1791202131-17039/manifest.json`.
The public reader consumes the independently stock-authored part and the
independently library-authored part with exact nominal type, outer sizes,
leaf values and middle mark. Stock ATTACH/CHECK accepts three complete parts:
the captured stock control, the library base, and a same-shape value mutant.
Each has 5 rows, 8 flattened elements and three payload leaves
`a UInt64, b String, c Nullable(Int32)`, on the 2/2/1 outer-row schedule.
Exact metadata/file roster, seven raw streams, mark axes and checksums are
checked before ATTACH; library marks use independent compressed frames,
whereas the stock witness places marks inside one compressed frame.

All 41 retained native child statuses are actual exit 0. Root independently
read every raw command record, reconciled SQL/argv and stdout/stderr SHA256,
rehashed the pinned executable, checked the three CHECK/schema results, and
re-encoded all 25 returned RowBinary / names-and-types windows without
importing the Crystal oracle or library. They match. The CHECK-valid mutant
changes the first UInt64 element from 11 to 12; its full outputs match that
literal and differ from the unchanged base oracle. NULL masks cover two
elements; deliberately noncanonical hidden Int32 carriers remain masked.
No canonical storage bytes beneath NULL guarantee is inferred.

Scoped hostile verdict: ROBUST within this finite storage/consumer profile.
The source review is same-lineage and therefore correlated; observed baseline
RED, the pre-fix consumer RED, seeded staged-comparison failures, actual stock
whole-part execution and separate root literal reconciliation supply the
discriminating evidence. It is not evidence for every child/profile product
admitted by the inherited declaration grammar. The native fixture contains an
empty row, not an entirely empty element mark; all-empty and empty-mark cases
in this slice have library spec evidence only. No Compact, flattened shared
offsets, whole-scan atomicity, crash durability or speed/RSS improvement is
claimed. The complete types/MV/projection goal remains active.

Refresh evidence after relevant source, serializers, runtime, fixture,
planner, reader, writer or consumer changes. Next: flattened shared-offset
Nested and paired logical binary descriptor/value/bulk support; the complete
types and MV/projections goal remains active.
