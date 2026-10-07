# Wide-part Table Reader Frontier

Document status: the initial UInt64 slice below is implemented and verified;
later typed consumers are tracked in their own scoped frontier documents.

Current addition (W211): selected admitted Dynamic-bearing columns reuse the
existing physical recursive reader through
`WidePartTableBatch#dynamic_bulk_values_for(column) : Slice(BinaryValue)` in
typed scans. This does not widen `scan`'s UInt64-only contract, numeric-only
scans or projection admission. The outer slice is callback-borrowed. Complete
schedules and cumulative logical mark ownership remain guarded, including
empty selections. Exact scope and executed gates:
[DYNAMIC_TABLE_CONSUMER_FRONTIER.md](DYNAMIC_TABLE_CONSUMER_FRONTIER.md).

Initial public frontier: provide a bounded, row-aligned multi-column `UInt64` scan
over an explicit caller-ordered list of local Wide-part paths. Crystal code
may filter values in an ordinary loop. This is a storage reader, not a SQL
engine or a table-catalog integration.

## Admitted surface

```crystal
table = CrystalClick::WidePartTable.open_selected(parts, ["left", "right"])
table.scan(batch_rows: 4096) do |batch|
  # batch.values_for("left") and batch.values_for("right") are aligned slices.
end
```

- The caller selects the part paths and exact column names. Paths are copied
  into an immutable, caller-ordered scan plan; no root discovery or active-part
  inference is performed.
- Each selected column must be an exact `UInt64` column supported by
  `WidePart`. The caller's column order is retained.
- Every selected column in every part is opened before the first callback.
  Per part, row totals and the complete ordered sequence of mark row counts
  must agree. Compressed offsets are not compared across columns.
- Same-partition part-name intervals are inclusive. Any selected pair that
  overlaps is rejected, regardless of part level or apparent lifecycle state.
  This guard prevents a known-invalid double-counting combination; it does not
  infer which part is Active.
- Selected `.bin` and mark checksum entries must exist and their declared
  physical sizes must match the files. The reported status is
  `ChecksumVerification::SizeChecked`; hashes are not verified.
- Each callback batch stays within one part and one mark, and carries
  `part_index`, `part_name`, `part_path`, `mark_index`, `mark_row_offset`,
  `part_row_offset`, and `source_row_offset`. Source offsets follow the
  caller's part order and are administrative concatenation offsets, not SQL
  ordering.
- `values_for(name)` returns the selected column slice for the same rows.
  Slices are borrowed and must not be retained after the callback returns.
- Bounds are explicit: at most 1,024 parts, 16 columns, 65,536 marks per
  selected column, 65,536 rows in one materialized mark, 4,096 rows in a
  callback batch, 1,000,000 total selected marks, and 100,000,000,000 total
  rows. At the maximum column and mark sizes, one materialized mark contains
  up to 8 MiB of UInt64 payload arrays.

## Minimal Crystal filter

This example runs from the repository root against the public two-column
fixture with `crystal eval '<code below>'`. The fixture is copied under a
valid MergeTree part name because its committed directory is named `part`.
Programs normally pass already-valid part paths selected by their caller.

```crystal
require "./src/crystal_click"
require "file_utils"

root = File.tempname("crystal-click-table-reader-example")
Dir.mkdir(root)
part = File.join(root, "p-1_0_0_0")
begin
  FileUtils.cp_r("test/fixtures/public/wide_two_uint64/part", part)
  table = CrystalClick::WidePartTable.open_selected([part], ["left", "right"])
  table.scan do |batch|
    left = batch.values_for("left")
    right = batch.values_for("right")
    left.each_with_index do |value, index|
      if value % 2_u64 == 0
        puts "#{value}\t#{right[index]}"
      end
    end
  end
ensure
  FileUtils.rm_rf(root)
end
```

The `if` is ordinary caller code; the reader provides no filter DSL, expression
language, function registry, or query planner.

## Authority and consistency boundary

The caller must keep every supplied part and selected file immutable for the
reader's lifetime. Opening readers and validating sizes is not an atomic
filesystem snapshot. Equal row totals and mark-row sequences establish
row-alignment shape only; they do not establish equal payload contents,
matching hashes, a committed snapshot, or protection from concurrent
mutation. A decode or payload-corruption error discovered during `scan` can
occur after earlier batches have already reached the callback.

The API also cannot prove that the listed parts belong to one logical table,
replica, schema epoch, or consistent ClickHouse snapshot—even when names and
selected types match. The caller supplies that authority and must select a
mutually compatible set. The overlap check is only a fail-closed guard against
known same-partition interval overlap; there is no Active/Outdated discovery or
inference.

`PartChecksums` validation checks selected-entry presence and file lengths;
it does not verify checksum hashes or compressed-frame contents. These limits
remain true when the API reports `SizeChecked`.

## Rejected surface

- SQL, query parsing, filters inside the reader, functions, joins, aggregation,
  sorting, partition pruning, or query planning;
- root discovery, catalog access, Active/Outdated inference, mutation or
  replica state, and implicit selection of replacement parts;
- proof that the paths share a table identity, schema epoch, or atomic
  snapshot;
- Compact parts, remote/object storage, unsupported types/codecs, and
  cryptographic checksum/hash verification;
- retained callback slices, concurrency guarantees, or performance claims.

## Guard-only future

- Schema/table identity can only be admitted with an explicit caller-supplied
  authority token or another independently validated source of identity.
- Snapshot or concurrent-mutation guarantees require an atomic snapshot,
  immutable object identity, or equivalent mechanism; matching mark shapes are
  insufficient.
- Additional types, codecs, query operators, and lifecycle discovery each
  require a separate frontier and falsifiers; this reader does not anticipate
  their runtime behavior.

## Design laws

1. Validate all paths, selected columns, readers, selected checksum entries,
   row totals, and full ordered mark-row sequences for all parts before the
   first callback.
2. Preserve caller part and column order. Parsed part names are used only for
   bounds, patch rejection, and the same-partition overlap guard.
3. Never compare compressed offsets between selected columns; only row totals
   and ordered mark-row counts establish the admitted alignment shape.
4. Mark and aggregate row limits bound scan offsets before wrap-add arithmetic
   (`&+`) computes callback provenance. Each WidePart also validates that its
   mark rows sum to its declared row count.
5. Callback slices are valid only for the duration of the callback. Callers
   that retain values must copy them.
6. Callback exceptions propagate unchanged. Errors discovered while decoding
   payloads during scan may follow already-delivered batches.
7. `SizeChecked` means selected-entry presence and physical size only.

## Falsifier roster

| Probe | Required signal |
| --- | --- |
| Public two-UInt64 fixture with variable 8,192-row marks | Exact aligned pairs and direct Crystal `if` filtering; no batch exceeds the configured limit |
| Same total rows but changed mark-row sequence in a selected column | Typed failure before any callback |
| Corrupt or unsupported later selected part | Open fails before callbacks from earlier parts |
| Shuffled, non-overlapping explicit part paths | Callback part order and source offsets follow caller order |
| Inclusive same-partition overlap | Open rejects the pair; different partitions and non-overlapping intervals remain eligible |
| Duplicate path/column, malformed name, selected part symlink, or exceeded bound | Typed rejection |
| Callback raises | The callback exception escapes unchanged |
| Mutated payload after open or checksum hash mismatch | No content-integrity or atomic-snapshot guarantee is claimed |

## Fixture and verification

The public fixture is generated and checked with:

```text
bash scripts/generate_table_reader_fixture.sh --check
```

It contains two `UInt64` columns named `left` and `right`, 17,001 rows, and
variable plain `.mrk2` mark rows `[8192, 8192, 617]`. The generator pins
ClickHouse local `26.7.1.1315`; ordinary specs consume only the committed
fixture and do not require ClickHouse.

Verification record:

- Focused table-reader specs: 5 examples, 0 failures or errors.
- Full Crystal debug suite: 154 examples, 0 failures or errors.
- Full Crystal release suite: 154 examples, 0 failures or errors.
- `crystal tool format --check`, generator `bash -n`, fixture `--check`, and
  `git diff --check`: passed.
- The documented Crystal filter example ran against the public fixture and
  emitted 8,501 even-valued rows.

These results verify the current local source and committed public fixture;
they do not certify compatibility with arbitrary ClickHouse parts, a stable
snapshot, payload hashes, or performance.

Evidence becomes stale if the reader bounds, callback lifetime, mark layout,
checksum semantics, or fixture producer/schema change. Re-run the focused and
full suite plus fixture shape check after such a change.

## Implementation seal

- Slice: explicit ordered paths and selected `UInt64` columns for row-aligned
  Crystal callbacks.
- Source/spec: `src/crystal_click/wide_part_table.cr`,
  `spec/multicolumn_table_scan_spec.cr`, and the two-column public fixture.
- Falsifiers: mark-sequence mismatch before callbacks, overlap rejection,
  multi-part order/provenance, invalid inputs, and callback error propagation.
- Boundary: immutable caller-selected files and paths; no atomic snapshot,
  identity proof, payload-hash verification, SQL, or performance claim.
- Next local track: decide from user demand; performance and query operators
  remain deferred.
