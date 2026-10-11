# Compact physical context frontier

Document status: W259 VERIFIED; root adversary ROBUST within the qualified
plain-mark physical-window target (2026-10-10). Typed Compact remains unqualified.
Baseline: `ef4980eaf70b207df8a2190d4da774ebf515967e`.
Current frontier: a schema-neutral physical reader for actual top-level Compact
parts, not a new typed codec or a Compact writer. The full types, MV/projection
and subsequent performance goal remains ACTIVE.

## Factual anchor

The root-executed baseline created one seven-column Wide part and actual
Compact `.mrk3` and `.mrk4` parts with the independently pinned stock runtime
26.10.1.1201, build `d9bcb5ab007f0f6299f7f973f2642245bab3d028`.
All three passed stock CHECK, exact full/middle rows and schema checks. The
public library read the Wide control. On `.mrk3` it rejected the absent
`columns_substreams.txt`; on `.mrk4` it searched for nonexistent Wide streams.
The qualified behavioral RED is in
`/private/tmp/crystal-click-w259-baseline-confirmed.EN2VYw/summary.json`.
Earlier helper compilation or assertion failures were instrumentation failures,
not evidence of a format incompatibility.

The comparison source `ed30948f095ecb70679986d7d60e27ad770ae27a` schedules each
Compact granule as per-column prefix/body/suffix. Its `.mrk4` sidecar roster
comes from a dry run of those lifecycle hooks against the sample column:
prefix, empty-range body, then suffix. The getter records unique stream names
in first-seen order; live Compact writing records a mark on each getter call.
This is not generic `enumerateStreams` order. Tuple children, for example,
are traversed within each lifecycle phase rather than completing all phases
for one child before the next. `.mrk3` records only the first getter coordinate
for each column. The terminal record uses physical EOF coordinates and zero rows.
Array still invokes its child serializer for zero child occurrences: equal
coordinates cannot be discarded as duplicate marks. Source anchors are
`MergeTreeDataPartWriterCompact.cpp:180-209,306-398,422-441` and
`SerializationArray.cpp:352-395`, `MergeTreeDataPartWriterOnDisk.cpp:634-685,727-744`,
`SerializationTuple.cpp:766-861`, `ISerialization.h:396-403` and
`ColumnsSubstreams.cpp:40-52`. Dry-run/live callback-roster equality is not
a universal serializer-interface invariant: the physical interval law below
is qualified against the observed monotone grid and matching fixture roster,
not arbitrary Dynamic/Object/custom serializers. This source is a comparison snapshot, not
asserted executable build provenance or an assertion of latest upstream.

## Design laws and admitted surface

1. `CompactPartPhysicalContext.open(part_path, budget)` validates a complete
   plain `.mrk3` or `.mrk4` grid and retains the supplied consumptive
   `CompressedStreamBudget`. `read_window(column_name, first_mark, mark_count)`
   returns ordered physical shards, not decoded column values. There is no
   type or fixture-name allowlist.
2. Always read `checksums.txt`, `columns.txt`, `count.txt`, `data.bin` and
   exactly one of `data.mrk3` or `data.mrk4`. Reject ambiguous or unsupported
   mark layouts. `.mrk3` uses the exact `columns.txt` order and has one
   whole-column slot per granule. A substreams sidecar is not required and
   cannot fabricate nested boundaries. `.mrk4` requires
   `columns_substreams.txt` with the exact matching column order and ordered
   flattened substreams. No sorting, name coalescing or equal-coordinate
   deduplication may change physical slot identity.
3. Reuse the private Wide metadata parser through narrow public structural
   forwarding methods on `WidePart`: `parse_columns_metadata(text)`,
   `parse_columns_substreams_metadata(text, columns)` and
   `parse_count_metadata(text, max_rows)`. Do not copy quoted-name grammar or
   relax existing Wide selected-type validation. Structural parsing preserves
   file order, unique columns, unique streams within each column, exact
   version/count/line boundaries and no trailing input. The same stream name
   in different columns remains distinct slots (shared Nested offsets are not
   a global-name uniqueness law; `ColumnsSubstreams.cpp:40-52`). Keep the
   4-MiB file, 64-KiB line, 4096-column and 65536-total-stream
   bounds; count text is at most 32 bytes.
4. Add a detached `PartPhysicalInput` and `PartStreamSource#physical_input`
   using the existing exact checksum-sized resolver. An additive constructor
   may snapshot an already parsed PartChecksums without rereading it. Preserve the old
   Object-specific method and all old transport entrypoints unchanged.
   A scalar `checksum_size_declaration(name)` may provide optional sidecar
   size declarations without exposing the retained checksum Hash.
5. `PartMetadataFileReader` reads bounded regular sidecars, rejecting unsafe
   basenames, links, missing/non-regular files, size changes and I/O errors.
   Check file caps and consume file bytes before allocation. Read and preflight
   binary checksums.txt through this owner before parsing or source construction;
   a non-regular checksum file must not reach legacy File.read. Metadata need
   not appear in checksums: real stock `columns.txt` and substreams sidecars
   do not. If a declaration exists, require its exact physical size. This is
   declared-size validation, not whole-file checksum authentication.
6. For N physical slots, each adaptive record has `16*N+8` bytes. Validate
   complete width/count before proportional allocation, charge every slot
   coordinate, and require positive bounded real mark rows whose checked sum
   equals count.txt. Require an explicit terminal record with zero rows and
   every coordinate `(data_size, 0)`. Convert all coordinates through a
   validated compressed frame index; require monotone granule-major/slot-major
   logical positions, retaining equal positions and exact EOF. The first
   slot begins at logical zero. Reject truncated/trailing/overflowing grids.
7. A slot ends at the next physical slot in the same granule, or at the first
   slot of the next granule for the last slot. `.mrk3` exposes that column
   interval as one shard; `.mrk4` exposes all of the selected column's slots
   in order, including zero-byte shards. Validate selections by subtraction,
   not overflowing addition. A zero-length selection at EOF is valid; past
   EOF, negative indices and unknown columns are hard errors.
8. Add `CompressedMarkReader.read_ranges(data_path, expected_data_size,
   ranges : Array({Int64, Int64}), budget)`. Rebuild and validate the frame
   index inside callback-scoped mmap. Each tuple is a logical half-open
   `{start, end}` interval, not `{offset, length}`. Preflight aggregate output and touched
   decoded work before allocation; authenticate and decode each touched frame
   once per operation with the existing checksum/decode helpers. Preserve
   range order and duplicates. Charge range/slot descriptors before proportional
   allocation, including zero-byte ranges and the selected slot-roster clone
   for a zero-mark window. Insufficient descriptor capacity fails before any
   window file work. Do not accept a caller-supplied mutable index.
9. Context and output owners expose detached columns/roster/coordinate data.
   No mmap slice or mutable retained frame/grid collection escapes. Windows
   expose mode, column, first_mark and row_offset; ordered granules expose
   mark, row_offset, row_count and shards; shards expose slot_index,
   stream_name (nil for `.mrk3`), logical_start/end and owned bytes. Snapshot
   mutation must not change retained context or window data. slot_index is
   the global flattened physical mark-slot index, never a per-column ordinal.
10. A single borrowed budget spans metadata, index construction and every
    window; failure does not reset consumed work. It bounds file/record/
    decoded/output work, not total process RSS or arbitrary caller snapshot
    copies. Encoded checksums.txt bytes are charged, but its legacy decoder and
    entry parser retain separate 64-MiB/65536-entry caps rather than participating
    in the transport decoded-work counter. Payload authentication covers touched compressed frames only;
    inspecting a grid does not authenticate untouched payloads. Assume a
    quiescent offline part, not concurrent server mutation. The caller-selected
    directory ancestry is trusted: existing path-string guards are not
    component-wise no-follow traversal. A trailing-slash or `/.` directory
    alias can bypass a final directory symlink test; this inherited limitation
    is not qualified as an access-control guarantee.

Rejected/not newly admitted: compressed mark files, nonadaptive marks,
nonterminal grids, zero-domain empty compressed parts, typed Compact
prefix/body/suffix decoding, new serializer versions, Compact writing,
general Dynamic/JSON/aggregate-state products, parent projection-manifest
authentication, native MV SQL execution and speed parity. Existing guards
remain guards, not evidence that these capabilities are implemented.

## Minimal physical access

```crystal
context = CrystalClick::CompactPartPhysicalContext.open(part_path)
column_name = context.columns.first[0]
window = context.read_window(column_name, 0, 1)
window.granules.each do |granule|
  granule.shards.each do |shard|
    bytes = shard.bytes # Owned snapshot; not a decoded column value.
  end
end
```

Selection uses mark indices, not row offsets or primary-key predicates. This
does not replace typed table `.values`; serializer lifecycle decoding is the
next frontier.

## Execution plan, risk and falsifiers

Risk: CAUTION (persistent-format, shared transport and public API).
Rollback: revert only the resulting qualified local atomic feature commit.
No push or unrelated staging is authorized.
Pre-mortem: a Wide assumption silently changes Compact callback order, drops
an empty Array child boundary, or resets a reused budget. The raw stock byte
oracle, equal-coordinate synthetic cases and consumptive-budget adversary
are the discriminators.

1. Luna owns the new physical classes, narrow parser/source/transport seams
   and require registration. Keep one owner per file. Root owns this SDD and
   closure ledgers. Another Luna owns focused/adversary specs and helper;
   a third owns the independently parsed native runner. Agents do not run
   heavy commands; root executes all native/build/test operations serially.
2. Focused falsifiers are full/first/middle/last windows in both modes, every
   ordered slot, empty shards with Q=0 and Q different from outer P,
   zero-length EOF windows and detached lifetime/mutation. Hostile cases
   include wrong width/count/row sum/order/EOF, malformed or duplicate roster,
   unsafe files, truncated/corrupt selected frames, negative/overflow/outside
   selections and exhausted reused budgets. No partial window may escape.
3. Run `spec/compact_physical_context_w259_spec.cr` and
   `spec/compact_physical_context_w259_adversary_spec.cr` in DEBUG and RELEASE.
   Run the sealed affected roster below in both modes. Command:
   `crystal spec SPEC_PATHS --single-module --threads 1
   --link-flags=-fuse-ld=ld --error-trace --verbose` (add `--release`). Expected:
   all executed examples pass with zero failures/errors/pending and exit 0.
4. Build `scripts/check_compact_physical_context_w259.cr` in both modes into
   distinct supplied executables. Run
   `ruby scripts/probe_compact_physical_context_w259.rb --helper EXECUTABLE
   --evidence-root FRESH_DIRECT_CHILD_OF_PRIVATE_TMP` in each mode. Preserve
   stock CHECK/exact full and middle rows/schema and positive typed Wide
   control. Add an independent raw LZ4/frame/mark projection oracle for every
   physical column window in actual `.mrk3` and `.mrk4` parts. Do not construct
   expected bytes with the production physical reader. The typed Compact
   rejection remains explicit and is not the physical reader's GREEN signal.
5. All heavy commands use unchanged `run_safe.sh`: 50% minimum free RAM,
   one Crystal worker, 12 GiB process-tree cap. Native subprocesses retain
   version/build/SHA pins, deadline, exit/signal/stderr gates and bounded
   captures. A timeout is not a format rejection. Split cohorts if necessary
   without dropping named files or relaxing limits.
6. Root independently inspects changed owners and actual evidence and performs
   hostile review. Only after DoD passes, update this banner, PROJECT_STATUS,
   LANDMARKS and a scoped evidence packet, then make one exact-path local
   atomic commit. Full goal stays ACTIVE; no performance conclusion is made.

### Sealed affected regression roster

All files are under `spec/`. The additive transport/source seams preserve old
callers; the parser bridge reuses the existing private parser. These cohorts
test those consumers, not the entire repository suite.

- Transport/metadata: `compressed_mark_transport_w124_spec.cr`,
  `compressed_mark_transport_w124_root_spec.cr`,
  `compressed_mark_positions_w194_spec.cr`, `physical_stream_plan_w125_spec.cr`,
  `wide_part_metadata_parser_refactor_spec.cr`, `object_file_reader_w126_root_spec.cr`.
- Recursive consumers: `binary_bulk_w122_spec.cr`,
  `binary_bulk_physical_prefix_w151_spec.cr`,
  `binary_dynamic_bulk_values_w155_spec.cr`,
  `binary_dynamic_bulk_values_w155_adversary_spec.cr`,
  `binary_dynamic_bulk_shared_context_w155_spec.cr`,
  `object_shared_advanced_profile_w195_spec.cr`,
  `static_binary_bulk_table_w247_spec.cr`.

## Observed qualification

The exact 15-file sealed roster passes 149 examples in each DEBUG and RELEASE
mode, zero failures/errors/pending, exit 0. This is not the full repository
suite. Both helpers build from the frozen Crystal sources. Formatting passes
for the 18 changed Crystal files; the runner and root auditor pass Ruby syntax.
All heavy commands retain the same 50%-free preflight, one Crystal worker and
12-GiB process-tree ceiling.

Two fresh native cells create and CHECK the Wide control plus actual Compact
`.mrk3` and `.mrk4` parts with eight literal rows, seven columns and real mark
rows `[2,2,2,2]` plus EOF. An independently authored Ruby raw LZ4/frame/mark
oracle, not the production Crystal reader, compares all 70 per-column
full/first/middle/last/EOF physical windows per mode. Empty Array child streams
remain visible. The typed Wide control passes; typed Compact retains its exact
baseline refusal. This slice is stock physical reading, not reciprocal Compact
writing or typed table values.

Root checks actual process exits/I/O/deadlines, exactly one runtime pin and
raw CHECK=1 for all three tables, complete SHA-bound file inventories and
the unchanged captures. Each mode has 62 files / 14,643 bytes; all file bytes
and helper reports agree between modes. Thirteen finite corrupt-report/raw
CHECK controls reject per mode, then the original positives still pass. Sixteen
separate CHECK-parser/LZ4 negative controls and three positives pass. Root uses
the runner oracle to audit actual captures: this is distinct from production
Crystal, not a second independently implemented Ruby codec. Ruby does not
independently compute CityHash; stock CHECK and SHA identities are separate
evidence. Same-lineage Luna review is correlated, not independent confirmation.

A root-observed behavioral RED showed a zero-mark window could clone its
selected roster before charging slot descriptors. The repair preflights and
reserves the complete descriptor charge before that clone or file work; the
new falsifier is GREEN in both final 149-example runs. Initial compiler,
test-fixture and temporary-auditor mistakes were repaired as instrumentation,
without reclassifying them as format evidence or altering original captures.

See [root evidence](../.landmark/evidence/compact-physical-context-w259.json)
for exact commands, pins, source identities and local capture references.
Temporary captures can be lost; the packet is an index, not proof by field
presence. No exhaustive corruption, arbitrary serializer-layout, RSS or speed
claim is made. Directory ancestry remains trusted and parts must be quiescent.

## Continuation and decay

After this physical slice, connect finite typed Compact codecs to the proven
granule/column/substream context and qualify stock read/write reciprocity.
Do not report raw shard access as table value compatibility. Refresh evidence
when parser/transport/budget/Compact owners or the runtime/source pins change,
or before widening mark/serializer profiles. Temporary raw evidence paths
are local scratch, not durable proof by their names alone.
