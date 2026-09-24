# Embedded MergeTree Storage Frontier SDD

Document status: active design. W1, W2, and bounded W3 are verified on this
macOS host against the pinned ClickHouse build. Bounded W4 is verified on the
local Darwin process-atomicity frontier; merging remains future work.

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

Boundary 2 has its first bounded table-ownership slice, but merge and
power-loss recovery remain open. Existing readers and the offline catalog
provide useful inputs; the latter remains read-only and cannot infer a
server's Active state from a physical directory inventory.

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

## Bounded slice W3: regular String stream and String payload

First, admit a reader correction for a regular `String` data substream whose
file is zero bytes while its `.size` substream records zero length for every
row. This is not an empty part: the pinned producer emits positive-row marks
for the zero-byte stream and an EOF sentinel. A trailing all-empty granule
can likewise start at the physical EOF of an otherwise nonempty raw stream.
The reader may synthesize empty values only when the selected size sum is zero
and the regular data mark interval is an exact zero-byte boundary. It must
keep rejecting an absent
stream, inconsistent mark positions, positive sizes against an empty file,
and empty files for types that require data bytes. Apply the same physical
rule to the regular data substream of `Nullable(String)`; null-map validation
remains unchanged. Sparse String serialization is not admitted.

Then admit one new experimental writer entry point for a sorted `UInt64` key
and one non-nullable `String` payload. Serialize String as a little-endian
`UInt64` length per row in the `.size` stream and concatenated raw bytes in
the regular data stream. Reuse W1's LZ4 framing, plain adaptive `.mrk2`,
primary index, checksums, staging, and exclusive publication. An all-empty
payload must write a zero-byte regular stream with valid positive-row marks;
mixed empty and nonempty strings must preserve exact bytes, including NUL and
multibyte UTF-8, across mark boundaries. The writer accepts no sparse,
Nullable(String), LowCardinality, arbitrary schema, table-level insert, or
merge request.

The reader correction requires a producer-generated regular all-empty part
with sparse serialization disabled, plus a negative altered-size/mark case.
The writer requires Crystal readback and an independent pinned ClickHouse
attach, exact and key-filtered reads, clean `CHECK TABLE`, and a same-size
corruption negative check. A self-readable part that ClickHouse rejects or
misreads falsifies W3 compatibility. W3 has no performance claim. Its evidence
is limited to the tested producer/version, normal String serialization, Wide
parts, and Darwin publication; a format or implementation change reopens it.

## Completed slice W4: Crystal-owned table and committed-part recovery

Admit a separate `EmbeddedMergeTreeTable` root created only at a previously
absent path. It is not a ClickHouse server data root and is not opened through
`OfflineCatalog`. An immutable, bounded schema manifest declares exactly one
sorted `UInt64` key, one non-nullable regular `String` payload, format version
1, and the single `all` partition. The root contains `parts/` and a separate
`committed/` directory of empty per-part commit-marker directories. No
arbitrary schema, partition expression, merge, mutation, or general SQL is
admitted.

`insert` accepts nonempty equal-length key and String slices and a bounded
rows-per-mark value. Under a root-owned advisory writer lock, enumerate both
committed and orphan physical part names, choose a new monotone block number,
and call the W3 writer to stage, validate, and exclusively publish
`all_N_N_0` beneath `parts/`. Only after that succeeds may one atomic
exclusive `mkdir committed/all_N_N_0` make the part visible; `N` is a
strictly positive, monotone block number. That marker is
the process-level commit point. No marker is written on writer failure. An
error after part publication but before the marker leaves an orphan, not a
visible row; retry allocates a different block. The API returns the committed
part name, not a server-equivalent transaction or exactly-once guarantee.

`open` and each read re-enumerate committed names, reject malformed names,
symlinks (including part metadata), missing/structurally invalid committed
parts, and overlapping or wrong-schema candidates. Structural validation
includes the primary index; it does not authenticate recorded file hashes.
Then delegate row-aligned typed scanning to `WidePartTable`. Inserts refuse to
publish a 1,025th committed part because the current table reader caps part
count at 1,024 and W4 has no merge yet. Unmarked physical part directories
and recognizable writer staging directories are excluded from reads and
reported without automatic adoption or deletion. The embedded reader does
not claim content-hash integrity: current `PartChecksums` checks selected
sizes, not recorded file hashes.
Same-size tampering and a concurrent external filesystem mutator are outside
W4's guarantee. Readers hold a shared advisory lock while resolving the
physical and marker inventory, then release it before scanning immutable
parts. A reader may see the committed set before or after a concurrent
cooperating insert, but must not reject a mixed inventory snapshot; one scan
uses one resolved set of immutable parts.

W4 is process-atomic, not power-loss durable: no file/directory `fsync`
protocol, group transaction, or crash-status acknowledgment is claimed.
Advisory locks coordinate cooperating writers on a local filesystem only.
The root creation path must publish the complete manifest/layout exclusively
or leave the destination absent on ordinary failure. The recovery falsifiers
are: an unmarked published part stays invisible after reopen; a marker with
no part fails closed; two cooperating writers cannot reuse a block; malformed,
symlinked, or overlapping committed parts fail; a missing or malformed primary
index fails; a failed insert preserves previous committed rows and does not
publish a marker. The W3 physical oracle remains
the compatibility control because W4 does not change part bytes.

W4 verification on this macOS host: the focused suite passed 12/12 examples;
the full debug and release suites each passed 285/285; formatting and diff
checks passed; and the pinned W3 ClickHouse physical oracle remained green.
The read-lock falsifier first failed on an unlocked child reader and passed
after shared-lock coverage. A later change to the reader, writer, filesystem
publication behavior, or manifest format reopens the corresponding claim.

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
   cross-filesystem compatibility. W3 handles only regular String substreams;
   sparse and other String variants remain guard-only.
2. W4 admits only the bounded Crystal-owned table and committed-part recovery
   above; it does not widen `OfflineCatalog` to a mutable API.
3. Add a bounded merge operation and stronger crash-durability probes, then
   filtering and primary-key pruning through the existing Crystal scan API.

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
`v26.7.1.1315-stable` (annotated tag `b8c42106e2a0`, peeled commit
`a6156303df65`); its default checksums-envelope
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

W3 evidence at the reader commit `0b833c8` plus the String writer diff:
the original reader rejected the pinned producer's all-empty regular String
part at mark parsing; the retained public fixture has five rows, marks
`[2, 2, 1]`, and a zero-byte raw stream. Contradictory marks and positive
size requirements fail closed. Focused reader/writer specs passed 34/34, and
the full Crystal suite passed 273/273 in debug and release with Crystal
1.21.0 and `/usr/bin/clang`. Formatting, shell syntax, fixture-shape, and
diff checks passed. The independent official ClickHouse local
`26.7.1.1315` oracle attached mixed and all-empty String writer parts,
returned exact binary/UTF-8 and key-range rows, passed `CHECK TABLE`, then
detected one-byte raw-stream and size-stream mutations respectively. The
mixed part includes an empty middle granule followed by nonempty data and
an empty final granule; the all-empty part has a zero-byte raw file. The
read-only adversarial review found no blocker within this scope. The
`Nullable(String)` zero-raw reader probe is synthetic, not an independent
producer-generated all-empty Nullable fixture. W3 proves only this normal
String Wide-part slice on Darwin and the pinned producer version, not
sparse serialization, table-level insert/merge, or performance. A
producer-version, format, platform, reader, or writer change decays the
certificate; refresh it with the focused/full suites and external oracle.

Risk tier: CAUTION, because malformed serialization can create convincing
but unusable persistent data. Rollback is the respective W1, W2, or W3 commit;
there will be no push or write into existing ClickHouse data roots. The
strongest likely failure is a subtle frame/checksum or mark/index mismatch
that our reader tolerates and ClickHouse rejects. The stock-ClickHouse attach,
read, and `CHECK TABLE` gates are mandatory for W1/W2/W3 verification.
