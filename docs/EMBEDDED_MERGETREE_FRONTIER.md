# Embedded MergeTree Storage Frontier SDD

Document status: active design. W1 and W2 are verified on this macOS host
against the pinned ClickHouse build. Embedded table ownership and merging
remain future frontiers.

## Purpose and bounded contexts

The long-term goal is a Crystal library that can read, filter, write, and merge
local MergeTree data without a ClickHouse server. It is not a replacement for
ClickHouse SQL, replication, or background scheduling. Three boundaries must
not be conflated:

1. **Physical part compatibility:** bytes emitted by Crystal can be read by a
   pinned stock ClickHouse build, and the current Crystal reader can read them.
2. **Embedded table ownership:** Crystal chooses the visible parts, rejects
   ambiguous or overlapping states, and publishes new parts atomically.
3. **Execution:** callers select columns and use typed values/filters in
   Crystal. SQL parsing, joins, and a general expression engine are not
   required.

The active frontier is boundary 1. Existing readers and the offline catalog
provide useful inputs to boundaries 2 and 3, but they do not make a mutable
MergeTree table exist.

## Completed slice W1: bounded Wide-part writer

Admit an experimental API that writes a new, immutable Wide part containing
exactly two named `UInt64` columns: a sorted primary-key column and a payload
column. The caller supplies equal-length column values and a fixed positive
row count per mark. The part uses the already-supported LZ4 data framing,
plain adaptive `.mrk2` marks, a raw `primary.idx`, and a single partition.
On this host's case-insensitive filesystem, physical stream basenames follow
ClickHouse's SipHash128 naming rule; logical names remain in the metadata.
The writer creates a complete directory only at a previously absent path;
it never edits an existing part or a live ClickHouse data directory. Exclusive
atomic publication currently uses Darwin `renamex_np`; other platforms fail
closed rather than claiming equivalent semantics.

Acceptance requires all of the following:

- Crystal reads every value and the expected mark ranges from the new part.
- The pinned `clickhouse local` build can attach the part in an isolated
  temporary table, return the exact values and a key-range result, and pass
  `CHECK TABLE` for all recorded part checksums.
- A same-size one-byte mutation of the attached part's raw `primary.idx` makes
  `CHECK TABLE` report failure. Self-readback and `ATTACH` alone are
  insufficient integrity evidence.
- Invalid schema, unsorted keys, mismatched lengths, and unsupported sizes
  fail before publishing a part. A failed write leaves no published part.

The public test data are deterministic and synthetic. Private Tokenomics
parts, values, hashes, paths, and diagnostics are not writer fixtures and
must not appear in committed artifacts or test output.

## Completed slice W2: bounded Nullable(UInt64) payload

Admit one additional experimental entry point that writes the same sorted
`UInt64` key column and a `Nullable(UInt64)` payload column. Keep W1's
immutable Wide part, LZ4, fixed rows per mark, exclusive Darwin publication,
and primary-index rules. The payload uses ClickHouse's BASIC Nullable shape:
one null-map byte per row (`0` or `1`) and one little-endian `UInt64` value per
row, including a deterministic zero placeholder beneath each null. The two
streams have independent `.mrk2` files and checksums but identical row counts
and mark boundaries. Declare both physical substreams in
`columns_substreams.txt` and emit `serialization.json` version metadata for
the current Crystal reader (the pinned ClickHouse loader can default BASIC
without this file).

Before assembly, reject mismatched lengths, bad names, unsorted keys, or byte
counts exceeding current reader frame/file/mark limits. After assembly, read
back every value and mark with the Crystal typed reader. Independently attach
the synthetic part to an isolated table in pinned ClickHouse local, compare
null-vs-zero and key-filtered results across multiple marks and a short final
granule, and require `CHECK TABLE`. Mutate one Nullable stream after attachment
and require `CHECK TABLE` to fail. This is compatibility evidence only for the
tested version and shape, not a generic Nullable writer promise.

W2 rejects other payload types, non-UInt64 keys, arbitrary schemas,
table-level inserts, merges, and performance claims. A Nullable stream that
self-reads but stock ClickHouse rejects is a W2 falsifier. A failure must
leave no published part.

## Rejected and guard-only surfaces

Rejected for W1: mutation of existing parts, table-level `INSERT`, merges,
replication, transactions across tables, SQL, Compact parts, compressed
marks, composite codecs, `Nullable`, `String`, JSON, projections, deletes,
TTL, and arbitrary partition expressions. No performance claim is admitted.

Guard-only follow-on slices, in dependency order:

1. Continue generalizing physical serialization to the types the reader
   actually supports, one stock-ClickHouse differential fixture per type and
   substream shape. Reader support does not imply writer support. Recheck
   physical stream naming on case-sensitive filesystems before claiming
   cross-filesystem compatibility. String requires a separate reader frontier:
   pinned ClickHouse can emit a zero-byte regular data stream for an all-empty
   String column, while this reader currently rejects that valid shape. Do
   not call a String writer complete by excluding all-empty marks.
2. Add an embedded table manifest/recovery rule and a minimal insert API that
   publishes a validated immutable part without claiming server-equivalent
   active-part discovery.
3. Add a bounded merge operation and crash-recovery probes, then filtering
   and primary-key pruning through the existing Crystal scan API.

Content-integrity verification in the Crystal reader is not part of W1 or W2: it
currently validates selected file sizes, not the recorded 128-bit file hashes.
An unfiltered ClickHouse `SELECT` validates consumed compressed frames but
does not substitute for `CHECK TABLE` on raw files such as `primary.idx`.

Each follow-on changes this SDD and gets its own falsifier before code. The
writer must not silently widen accepted types or choose an undocumented
ClickHouse part variant.

## Design laws and failure policy

1. Unknown metadata, type, codec, mark layout, checksum variant, or part-name
   state fails closed.
2. Little-endian encoding, byte counts, offsets, and row counts are checked
   for overflow and exact agreement. A final zero-row mark is a boundary,
   not another data granule.
3. Physical compatibility is established by the independent ClickHouse
   consumer, not inferred from source resemblance or Crystal self-readback.
4. A write is staged on the destination filesystem and published with one
   exclusive rename only after every output file is closed and validated.
   On failure, clean up only the uniquely owned staging directory. This is a
   process-level atomicity claim, not crash durability: W1/W2 do not `fsync`
   every file and parent directory.
5. The public API remains explicitly experimental despite W1/W2 oracle passes.
   Optimization follows correctness and measured allocation/throughput data.

## Falsifier roster

- A Crystal-written part that self-reads but stock ClickHouse rejects refutes
  physical compatibility.
- A multi-mark case in which the second mark or final sentinel returns a
  wrong row refutes mark/index alignment.
- A same-size mutation to raw `primary.idx` that a full scan may overlook
  must fail the oracle's `CHECK TABLE`; a damaged compressed frame that is
  read must fail its frame check. W1 does not claim the Crystal reader detects
  every same-size corruption.
- Empty, mismatched-length, unsorted, duplicate-name, path-like-name, and
  over-limit inputs must fail without a published destination.
- A forced mid-write failure must leave the destination absent and must not
  remove or change any pre-existing path.
- A producer-version or format-layout change invalidates the compatibility
  certificate until the oracle and focused specs are rerun.

## Verification and decision record

Initial anchor: the existing public two-column `UInt64` fixture and reader
cover LZ4 Wide parts with plain `.mrk2`; the full Crystal suite passed 242
examples before W1 edits. The pinned oracle is ClickHouse local
`26.7.1.1315`. The matching source is available as tag
`v26.7.1.1315-stable` (`b8c42106e2a0`); its default checksums-envelope
codec is LZ4, matching the 26.7 public fixture. The newer shallow source
`066ea77cf` instead defaults to ZSTD and is not the version authority for
W1.

W1 evidence at the implementation source state: 13 focused examples passed;
the full Crystal suite passed 255/255 in both debug and release; formatting,
shell syntax, and diff whitespace checks passed. The independent pinned
ClickHouse oracle attached the synthetic part, returned all five exact rows
and the expected key-range rows, passed clean `CHECK TABLE`, and rejected a
same-size one-byte `primary.idx` mutation through `CHECK TABLE`. The writer's
failure probes cover invalid input, absent parent, failed post-assembly
publication with no staging residue, and two writers racing for one target.
This certificate is scoped to two `UInt64` columns, LZ4 Wide parts, Darwin
publication, the pinned ClickHouse version, and the tested synthetic shapes.
It decays on a producer-version, format, platform, or writer/reader change;
refresh it by rerunning the focused, full, and external oracle checks.

W2 evidence at parent `5158b9a` plus the W2 implementation diff: 10 focused
writer examples passed; the full Crystal suite passed 259/259 in both debug
and release with Crystal 1.21.0, `/usr/bin/clang`, and a writable temporary
cache. Formatting, shell syntax, and diff whitespace checks passed. The
independent official ClickHouse local `26.7.1.1315` oracle attached the
synthetic Nullable part, returned the five exact null-vs-zero rows and the
expected key-range rows, passed clean `CHECK TABLE`, then returned
`CHECKSUM_DOESNT_MATCH` after a byte in the `payload.null.bin` compressed-frame
checksum was flipped. This negative control proves detection of that physical
stream corruption, not rejection of every malformed decoded null flag. The
writer's local probes include an all-NULL part, multi-mark short-final layout,
invalid inputs, and failed exclusive publication without staging residue.
Adversarial review found no blocker within this scope. This certificate is
limited to a sorted `UInt64` key and BASIC `Nullable(UInt64)` payload, LZ4 Wide
parts, Darwin publication, and the pinned ClickHouse version. It decays on a
producer-version, format, platform, or writer/reader change; refresh it with
the focused, full, and external oracle checks.

Risk tier: CAUTION, because malformed serialization can create convincing
but unusable persistent data. Rollback is the respective W1 or W2 feature commit;
there will be no push or write into existing ClickHouse data roots. The
strongest likely failure is a subtle frame/checksum or mark/index mismatch
that our reader tolerates and ClickHouse rejects. The stock-ClickHouse attach,
read, and `CHECK TABLE` gates are mandatory for W1/W2 verification.
