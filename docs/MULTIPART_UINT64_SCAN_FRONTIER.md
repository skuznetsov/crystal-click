# Multi-part UInt64 Scan Frontier SDD

Document status: **implemented and verified for the admitted surface**.

This slice adds a read-only source over a filesystem snapshot containing
multiple immutable Wide parts. It composes the existing exact `UInt64`
`WidePart` reader and its borrowed scratch scan. It does not infer ClickHouse
part lifecycle state from directory presence.

The caller is responsible for presenting an immutable root for the lifetime
of `open` and subsequent scans. Discovery, metadata reads, size checks, and
later mmaps are not an atomic filesystem snapshot. Any mutation of the root,
part directories, or selected files invalidates the open-time evidence and
requires reopening the source.

## Admitted surface

- Parse modern part names
  `<partition_id>_<min_block>_<max_block>_<level>[_<mutation>]` using the same
  field order as `MergeTreePartInfo`. In this slice `partition_id` is one or
  more ASCII alphanumeric or `-` bytes (therefore never `_`), block numbers
  are signed decimal `Int64`, and level/mutation are decimal `UInt32`.
  ClickHouse's legacy level `UInt32::MAX` is normalized to `999999999` for
  comparison while the original physical name remains available.
- Discover only immediate child directories of an explicit root.
- Ignore reserved and clearly unrelated names. A part-like malformed name, or
  a valid part name that is a symlink, non-directory, unreadable, corrupt, or
  unsupported, fails the whole open operation.
- Reject a symlink root, an empty discovered set, more than 1,024 parts, and
  part names longer than 255 bytes.
- Reject patch parts and any two parsed parts whose block ranges overlap in
  the same partition, including containment and equal ranges. A plain
  directory snapshot is not authoritative enough to select the active member.
- Sort normal parts deterministically by partition id, minimum block, maximum
  block, level, mutation, and name. This is scan order, not SQL `ORDER BY`.
- Open every discovered part for one exact `UInt64` column before scanning.
- Require a bounded ClickHouse v4 `checksums.txt`, parse its compressed-v3
  payload, require entries for the selected `.bin` and mark file, and compare
  their declared physical sizes with the opened files. Report this narrowly as
  `ChecksumVerification::SizeChecked` on the multi-part source.
- Scan complete parts through one caller-owned non-empty writable
  `Slice(UInt64)`. Each callback receives immutable part metadata plus a
  borrowed values slice. Values are stable only until the callback returns or
  the next refill begins.
- Expose bounded part count and total row count computed from the opened
  readers. Checked aggregate row count may not exceed 100,000,000,000.

The sealed public shape is:

```crystal
source = CrystalClick::WidePartSet.open(root, column)
source.scan_into(scratch) do |batch : CrystalClick::UInt64ScanBatch|
  # batch.values is borrowed
end
```

`UInt64ScanBatch` contains `part_index`, `part_name`, `part_path`, parsed
`part_info`, `mark_index`, `mark_row_offset`, `part_row_offset`,
`source_row_offset`, and `values`. `WidePart#scan_uint64_marks_into` is the
one-pass primitive used underneath; it yields the same mark-local and
part-local offsets plus a borrowed slice. A batch never crosses a mark or part
boundary. `source_row_offset` is the offset of the first batch value in the
administrative concatenation order.

## Rejected surface

- Inferring ClickHouse `Active`, `Outdated`, detached, mutation, transaction,
  replica, or Keeper state from directory names.
- Recursion, Compact parts, projections, old-format part names, patch parts,
  remote disks, object storage, hard-link identity checks, or concurrent
  directory/file mutation guarantees.
- Partition pruning, primary-key pruning, PREWHERE/WHERE, expressions,
  aggregation, joins, SQL row ordering, or parallel execution.
- Cryptographically verifying the hashes recorded in `checksums.txt` or the
  16-byte checksum prefix on compressed frames. Individual composed
  `WidePart` readers retain `ChecksumVerification::Unverified`; only the
  multi-part source reports selected-entry `SizeChecked` metadata.
- Stable retained chunks, library-owned chunk arrays, or a claim of
  allocation-free codec decoding.
- Applying delete masks, lightweight deletes, mutation commands, projections,
  or transaction metadata. A parsed nonzero mutation suffix is retained only
  as physical-name metadata and does not establish lifecycle state.

## Design laws

1. A non-reserved valid-looking child cannot be silently skipped after
   discovery. As in ClickHouse startup discovery, the `tmp*` namespace is
   reserved before part-name parsing, even if a suffix resembles a part name.
2. All readers are opened before the first value callback, so structural or
   metadata failure cannot expose a prefix from earlier parts.
3. Overlap is ambiguous without lifecycle authority and therefore fails
   closed; containment is not treated as evidence that the containing part is
   active.
4. Callback part metadata must describe the reader producing that callback.
5. The existing `WidePart` limits, codec rules, mmap lifetime, mark semantics,
   and progressive per-part decode errors remain unchanged.
6. A callback exception is propagated unchanged when mmap cleanup succeeds.
7. Deterministic part order is an administrative scan contract only.
8. `SizeChecked` proves selected-entry presence and physical length only; it
   is not content integrity or a committed-part certificate.
9. Root entries named `detached`, `moving`, `format_version.txt`, or starting
   with `tmp` are reserved and ignored. Names with fewer than three `_`
   separators are unrelated and ignored. Every other name is part-like and is
   parsed exactly: malformed part-like names fail closed, and a parse-valid
   name is mandatory and cannot be skipped because of its filesystem type.
10. Ranges are inclusive `[min_block, max_block]`; same-partition overlap is
    `left.min_block <= right.max_block && right.min_block <= left.max_block`.
    Parsing and aggregate additions are checked before conversion.
11. Open-time structural and size evidence is valid only while the caller's
    root remains immutable. Reopen after any mutation; this API does not pin a
    ClickHouse transaction or filesystem snapshot.

## Falsifiers

- Valid names with and without mutation parse into exact bounded fields;
  malformed, overflowed, reversed, patch, and underscore-containing partition
  ids are rejected.
- Unrelated root entries are ignored, while a valid-name symlink or file is a
  hard error.
- Shuffled creation order produces the same scan order and exact concatenated
  values.
- Cross-partition equal block ranges are accepted; any same-partition overlap
  is rejected before callbacks.
- A later corrupt part makes `open` fail before callbacks; a corruption found
  only during decoding may still expose the documented progressive prefix.
- Tiny scratch storage crosses mark/frame/part boundaries without losing,
  duplicating, or reordering values. No callback crosses a mark or part
  boundary, and all four offsets advance exactly with emitted values.
- Missing, duplicate, traversal-like, truncated, oversized, or wrong-size
  selected checksum entries fail before scanning; valid v4 fixture checksums
  produce only the `SizeChecked` status.
- Existing single-part suites remain green.

## Rollback and next frontier

Rollback is one atomic commit containing the parsers, source, focused specs,
and these two documents. The next independent storage-hardening frontier is
cryptographic checksum verification; it must not retroactively strengthen the
size-only claims of this slice. The performance roadmap can proceed separately
to reusable decode buffers and the minimal execution pipeline.
