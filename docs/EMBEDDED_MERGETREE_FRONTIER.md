# Embedded MergeTree Storage Frontier SDD

Document status: active design. W1, W2, and bounded W3 are verified on this
macOS host against the pinned ClickHouse build. Bounded W4, W5, and W6 are
verified on the local Darwin process-atomicity frontier. Bounded W7 is
verified on the same Crystal-owned table frontier; power-loss recovery
remains future work. Bounded W8 recorded primary-index hash validation is
verified for embedded candidate scans only. W9 covers the exact scalar and
Nullable payload types supported by the typed reader, on the pinned local
ClickHouse/Darwin writer frontier. W10 verifies plain `FixedString(N)` as a
separately tested reader/writer payload. W11 verifies BASIC
`Nullable(FixedString(N))` within its bounded reader/writer scope. W12 verifies
raw non-null `Date` and `Date32` day-code reading and writing on the pinned
Wide/LZ4 ClickHouse/Darwin frontier; other type families remain guard-only.
W13 admits raw non-null `DateTime` seconds and `DateTime64(p)` ticks for
canonical precisions 0 through 9 on the same pinned Wide/LZ4 frontier;
the differential oracle directly exercises precisions 0, 3, and 9.
W14 admits BASIC Nullable wrappers for these four raw date/time families on
the pinned Wide/LZ4/plain-adaptive-mark frontier. The differential oracle
directly tests DateTime64 precisions 0, 3, and 9; the exact parser and writer
accept canonical precisions 0 through 9. W15 admits paired reader/writer
support for bounded Bool, Enum8/16, and Decimal32/64 payloads and their BASIC
Nullable forms on the same pinned frontier. This is not full ClickHouse type
parity: JSON typed-path reading remains an intentionally unmatched surface.
W16 admits paired raw Decimal128 and BASIC Nullable(Decimal128) reading and
writing at canonical scales 0 through 38 on the same pinned Wide/LZ4 frontier.
The differential oracle directly exercises scales 0, 2, and 38, plus the
full signed Int128 backing extrema at scale 0.
W17 admits paired `UUID` and BASIC `Nullable(UUID)` payloads on this pinned
Wide/LZ4 frontier after a bidirectional stock/Crystal oracle and full
regression gate. It does not imply support for other 128-bit or IP types.
W18 admits paired `IPv4` and BASIC `Nullable(IPv4)` payloads on the same
pinned Wide/LZ4 frontier after a bidirectional stock/Crystal oracle and full
regression gate. It does not imply `IPv6`, IP functions, or IPv4 key support.

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

Boundary 2 now has bounded table ownership, a two-part logical merge, and
explicit historical-part reclamation, but power-loss recovery remains open. Existing readers
and the offline catalog provide useful inputs; the latter remains read-only
and cannot infer a server's Active state from a physical directory inventory.

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

## Verified slice W5: two-part logical merge without reclamation

Admit `merge_adjacent(left_name, right_name, rows_per_mark)` only for two
distinct, neighboring currently visible parts of the same W4 table. The
caller names both active parts in increasing block order. Under the table's
exclusive advisory lock, resolve and validate the active set, read both
parts, and perform a stable key-ordered two-way merge. Preserve every row,
including duplicate keys and binary/empty String values; equal keys from the
left part precede equal keys from the right part. Do not concatenate parts or
deduplicate rows. Bound one merge to 100,000 output rows and 64 MiB of total
String payload; reject an over-limit request before publishing anything.
Reuse the W3 writer and its existing physical validation for the result.

Only the new part is key-sorted. A table scan with multiple remaining active
parts still visits parts in block order and does not promise global key order;
the preservation claim is an exact row multiset plus the specified stable
order within the merged output.

Name the output `all_<left.min>_<right.max>_<level>`, where `level` exceeds
both input levels and every physical orphan level already occupying that
exact block range; reject level exhaustion. The new part is staged and
exclusively published under `parts/`. Only a subsequent exclusive empty
`committed/<output-name>/` mkdir makes it visible. The old marker directories
and immutable source parts remain untouched. A failure before that mkdir
leaves an orphan and the old active set; a failure after it leaves the new
active set. No cleanup, adoption, or deletion of old parts is attempted.

W5 widens W4 inventory rules only inside `EmbeddedMergeTreeTable`: canonical
single-block level-zero and multi-block positive-level part names are
accepted. Orphans are named and bounded but excluded from overlap resolution,
so a published unmarked merge result cannot poison reopen. Marked intervals
must be laminar: a pair may be disjoint or one must strictly contain the
other; partial overlaps and equal-range distinct parts fail closed. Visible
parts are the maximal marked intervals, pairwise disjoint and sorted by block
range. Generic `WidePartTable` still receives only this nonoverlapping set;
its overlap policy does not change. A reader acquires the shared lock through
inventory resolution and may observe the before- or after-merge set, never
both. Sources remain readable for scans that already captured them.

The selected reader remains capped at 1,024 visible parts. Historical marker
directories and physical entries (including orphans and staging entries)
each have an explicit 2,048-entry cap. Insert and merge preflight both caps
before creating a new part so a successful publication cannot make the root
unopenable. This is logical compaction of the scan set, not disk-space
reclamation or unbounded insert capacity; once history fills, operations
fail closed until a separately designed GC/recovery frontier exists.

W5 falsifiers: interleaved keys must emerge globally sorted with stable
duplicates and exact row multiset; a post-publication/pre-marker orphan must
leave the old active rows visible on reopen and force a distinct retry name;
post-marker reopen must select the merged part once, not double-count source
rows; a partial or equal-range marked overlap must fail closed; merge of
non-neighboring or stale inputs and row/history-cap overflow must publish
nothing. A pinned ClickHouse attach/read/`CHECK TABLE` of the synthetic
positive-level merged output is required for a physical compatibility claim.
W5 still claims only local Darwin process atomicity, size-based reader checks,
and cooperating-process locks—not fsync durability, hash authentication,
mutation, partition-general merging, or server Active-state equivalence.

Local W5 verification: the focused embedded-table suite passed 20 examples;
the full debug and release suites each passed 293 examples. A synthetic
positive-level merged part attached to pinned ClickHouse 26.7.1.1315, returned
the exact rows and key-range result, and passed `CHECK TABLE`; ClickHouse
renamed the attached part to its own block identity. The pre-marker recovery
test constructs the complete orphan state and checks reopen/retry, but does
not inject a process death at the exact instruction boundary. Changes to
publication, inventory selection, reader retention, or the pinned ClickHouse
version reopen the relevant claim.

## Verified slice W6: explicit reclamation and process-death recovery

Admit an explicit `reclaim_obsolete!` operation on the Crystal-owned table
root only; never run it automatically or on a ClickHouse server data root.
It holds the exclusive table lock through selection and deletion. The operation
may remove covered historical marked parts, unmarked physical parts whose
block interval is contained in a valid active interval, and recognizable
writer staging directories. It must retain every active part and uncovered
unmarked physical part. The latter still reserves its block number and, for
merge outputs, its exact-range level. No general orphan adoption, blanket
orphan deletion, or allocator-watermark format change is admitted.

Resolve canonical marked interval names and reject ambiguous overlaps before
checking part content. Require structural validation of every maximal active
part. A missing or structurally invalid *covered* historical part may be
reclaimed without blocking reads; a missing or invalid active part still fails
closed. Delete a covered part's empty commit marker before its physical
directory. A process death between those actions leaves an unmarked part that
the next explicit reclamation can finish. A process death during recursive
removal likewise leaves only an unmarked, retryable directory. Reclamation
must work at the 2,048-entry capacity boundary without creating an extra
physical entry. It does not claim power-loss durability: no file or directory
`fsync` protocol is admitted.

The table's `scan_typed` must hold its shared lock through reader opening,
mark consumption, and every user callback before any physical deletion is
allowed. A scoped path-borrowing callback may provide the same pin for callers
who use `WidePartTable` directly. A raw path returned by `part_paths` is only
an instantaneous inventory result; it is not a lifetime lease once explicit
reclamation is enabled. A callback must not attempt a reentrant table write
while holding the shared lock. Full-scan locking can delay inserts and merges;
an epoch/lease mechanism is future work, not assumed here.

W6 falsifiers: a covered missing or damaged source does not poison an intact
covering part, while a damaged active part still fails; reclamation leaves the
row multiset and active path set unchanged; a concurrent scan keeps its source
readable until callback completion; a process death after marker removal or
during physical removal is recoverable; a killed writer stage can be reclaimed
at the capacity boundary; uncovered orphans retain their identity reservations.
Test-only compile-time fault barriers may exercise writer-stage creation,
part-before-marker publication, marker-before-return, and GC deletion windows.
Those tests establish process-death behavior only, not power-loss durability
or exactly-once insert retries. Filtering and typed PK-granule pruning remain
guard-only until a separate execution slice.

W6 evidence at the implementation diff on parent `a1e515c`: 26 focused
embedded-table examples and 30 combined fault-flag examples passed; the full
Crystal suite passed 299/299 in both debug and release. The four SIGKILL
barriers exercised stage creation, part publication before its marker, marker
creation before return, and marker-first GC. Focused tests additionally
covered a failing deletion, explicit retry, a paused scan versus concurrent
GC, exactly 2,048 physical entries, retained uncovered block/level
reservations, and partially removed, symlink, and regular-file historical
remnants after marker-first interruption. The pinned ClickHouse `26.7.1.1315`
W3 and W5 physical oracles passed, including exact merged rows and
`CHECK TABLE`. Formatting, shell
syntax, and diff-whitespace checks passed. This certificate covers only the
Crystal-owned bounded UInt64/String table, cooperating processes on Darwin,
and the tested process-death windows. It decays on lock, inventory, deletion,
writer publication, platform, or part-format changes; refresh it with the
focused/fault/full suites and both external oracles. It does not authenticate
all stored bytes, prove power-loss durability, protect unscoped raw paths, or
guarantee exactly-once caller retries.

## Verified slice W7: typed UInt64 primary-key candidate granules

Add `EmbeddedMergeTreeTable#scan_uint64_pk_candidates` for a caller-selected
column list containing the table's sorted `UInt64` key and optionally its
regular `String` payload. Require at least one inclusive `UInt64` bound and
reject an inverted pair, duplicates, or unknown columns before any callback,
including on an empty table. The method exposes complete physical candidate
granules in active-part order, with the original part, mark, and row offsets.
It is not an exact row filter: callers must apply the bounds to each returned
key before using its row. Multiple active parts do not imply global key order.
Do not add SQL parsing, arbitrary key expressions, or background scheduling.

Resolve the maximal committed part set under the shared table lock, open a
typed selected-column reader, validate every active raw `primary.idx`, and
compute every part's conservative mark schedule before exposing the first
callback. Reuse `PrimaryKeyIndex#candidate_marks`, which retains the predecessor
granule for lower bounds and handles duplicates across mark boundaries. The
typed candidate path must skip unselected marks without materializing their
column values, preserve physical offsets across skips and parts, and expose
one full selected granule per callback even when it exceeds the ordinary
4,096-row batch size. Existing per-mark and String-byte limits remain in
force. Keep the shared lock through the callbacks so explicit GC cannot
remove scanned parts. Callbacks must not reenter a table write.

Context bridge: the offline `OfflineTable#scan_uint64_pk_candidates` and this
embedded method overlap in the index-to-mark algorithm and residual-filter
obligation, but not in table authority. The offline catalog sees physical
candidates without server Active-state knowledge; the embedded table owns its
commit markers and chooses a maximal active set. Neither method authenticates
the full primary-index content. This bridge is valid for the current bounded
UInt64 index format and decays if its format, table ownership, or index
validation changes. In particular, a same-size monotone but semantically
wrong index could omit matching marks; a residual predicate cannot recover
rows that were never read. Exact parity therefore assumes immutable,
untampered writer-produced parts, not arbitrary filesystem corruption.

W7 falsifiers: exact caller-filtered rows must match a full typed scan for
one-sided and two-sided ranges, duplicates spanning marks, String payloads,
multiple active parts, and a post-merge active set; skipped marks must retain
their original offsets; a damaged index in any active part must fail before
the first callback; malformed requests must expose no callback. The method
must not read selected String payload bytes from pruned marks. W7 changes no
part bytes, so the pinned W3/W5 physical oracles are regression controls,
not proof of candidate-pruning correctness. No speedup is claimed without a
separate measurement.

W7 evidence at the implementation diff on parent `a50e640`: 10 focused
candidate tests passed, including a same-size corrupted String frame in a
pruned mark (full scan fails, candidate scan succeeds), a 4,097-row whole-mark
callback, an entirely pruned leading part, a damaged later index with no
candidate marks, and inclusive `0`/`UInt64::MAX` edges. The full suite passed
309/309 in both debug and release, and the W6 fault-flag regression passed
30/30. Both pinned ClickHouse physical oracles remained green; the new example
typechecked; formatting and diff checks passed. An adversarial source review
found no in-scope omission, offset, pruning, or index-order bug. The existing
W6 GC-versus-scan test covers the shared lock path, but no new W7-specific
callback-versus-GC process test was added. This certificate assumes immutable,
untampered writer-produced indexes and decays on changes to index selection,
typed mark materialization, active-part inventory, lock scope, writer format,
or the pinned ClickHouse version. Refresh focused/full/fault and physical
oracle checks accordingly; no performance or hash-integrity claim follows.

## Verified slice W8: recorded primary-index hash validation

For `EmbeddedMergeTreeTable#scan_uint64_pk_candidates` only, verify each
active raw `primary.idx` against its recorded 128-bit physical-file hash in
`checksums.txt` before computing mark schedules or exposing any callback.
The checksum parser retains the recorded hash, but its existing size-only
APIs and other readers keep their current contracts. Hash the same bounded
index bytes used for key decoding; do not reopen the file to hash a different
snapshot. A mismatch fails closed, including when a same-size, monotone but
wrong index would otherwise make a matching range appear empty. Preflight
every active part before the first callback as in W7.

W8 changes no part bytes. It does not verify data or mark files, the
`checksums.txt` envelope itself, offline-catalog indexes, or a coordinated
rewrite of both index and recorded hash. The ClickHouse file hash is an
accidental-corruption consistency check, not a cryptographic authenticity
claim. Power-loss durability, external filesystem mutation during a scan,
and a general content-integrity mode remain rejected. The strongest W8
falsifier is a same-size monotone replacement index that omits a real key:
the candidate scan must reject it before any callback, while an unchanged
writer-produced index must still select the same exact residual rows.

W8 evidence at the implementation diff on parent `df4a547`: the first- and
later-active-part same-size monotone wrong-index tests reject before callbacks;
an independent public ClickHouse fixture and a Crystal-written part agree
with the parsed recorded hash. Focused checksum/candidate specs passed 20/20,
and the full debug and release suites each passed 314/314. The W6 fault-flag
regression and both pinned physical oracles remained green; formatter and
diff checks passed. A size-only `PrimaryKeyIndex.open` control accepts the
altered index, confirming the opt-in boundary. This certificate covers only
the recorded physical hash of active embedded candidate indexes on the
tested Darwin/pinned-producer frontier. It decays on checksum parsing, hash
algorithm, index bytes/selection, active-part preflight, or producer-version
changes. Refresh the focused/full/fault suites and the physical oracles.

## Completed slice W9: typed payload parity with the exact typed reader

Admit a bounded writer for a sorted `UInt64` key and one payload whose type is
one of the exact physical scalar types accepted by `WidePart.open_typed`:
`UInt8/16/32/64`, `Int8/16/32/64`, `Float32/64`, `String`, or `Nullable` of
any of those. Existing writer entry points remain supported. The new entry
point must derive the declared ClickHouse type from the exact Crystal payload
type, encode integers and float bit patterns little-endian, and use BASIC
Nullable streams with deterministic zero/empty nested values under nulls.
It retains W1's two-column Wide part, `UInt64` key, LZ4 frames, plain adaptive
marks, one partition, staged checksums, and exclusive Darwin publication.
Every stream must be bounded against the current reader's frame/file/mark
limits before publication. No implicit conversion or lossy narrowing is
admitted.

W9 does not claim arbitrary table schemas, non-`UInt64` sorting keys, Compact
parts, sparse String variants, or complete JSON object support. The reader's
`JSON(path Type, ...)` virtual typed-path access is a separate structural
format: its object-structure stream and serialization metadata are not covered
by ordinary scalar parity. It remains guard-only until a distinct stock
ClickHouse differential writer slice is designed and tested. Likewise this
slice does not widen embedded table insertion beyond its current schema.

For each admitted payload type and substream shape, the falsifier is a
synthetic multi-mark part with boundary values, null-vs-default distinctions,
and a short final granule that Crystal reads exactly but pinned stock
ClickHouse cannot `ATTACH PART`, return the same typed values and key-range
selection, or pass `CHECK TABLE`. A corrupt stream must make the external
integrity check fail. The oracle must report the specific type/shape tested;
a scalar pass cannot certify a Nullable or String shape. The old three writer
forms are regression controls. A separate disposable `clickhouse-server`
smoke test remains needed before claiming daemon lifecycle compatibility.

## Verified slice W10: plain FixedString(N) payload

Admit an exact `FixedString(N)` selected column in a Wide part, where
`1 <= N <= 65,536` bytes. The reader must recognize only canonical
`FixedString(N)` spelling, require one ordinary physical stream (no String
`.size` stream), check every selected mark's `rows * N` byte count, and return
all `N` bytes for each value, including trailing and embedded zero bytes.
Direct materialization is capped at 64 MiB of raw bytes and 65,536 returned
values per call, preventing small-width values from multiplying into an
unbounded number of Crystal objects. Validate the global `string`
serialization version as one of the pinned ClickHouse enum values, even
though FixedString itself uses one stream.
Table and offline-catalog typed selection must expose that exact byte value;
the existing variable `String` behavior must remain unchanged. Reject a
malformed declaration or a stream shape that does not match this contract.

Admit a writer entry point with explicit `N`, sorted `UInt64` key, and one
`Slice(String)` payload. Each input is a byte string, not a character count:
reject values longer than `N`, zero-pad shorter values to exactly `N`, and
write one bounded fixed-width stream. Reuse W9's staged checksums, marks,
checksummed `serialization.json`, Crystal self-read, and exclusive publication.
Reject a per-mark row count above the reader's 65,536-value materialization
limit before staging. Do not infer
`FixedString(N)` from the Crystal `String` type or silently truncate a value.
The writer and reader must preflight `rows * N`, frame, file, and mark limits
before allocating or publishing. Existing W9 entry points remain unchanged.

W10's falsifier is a stock ClickHouse-generated reader fixture and a
Crystal-generated writer part with multiple marks, short and exact-width
values, embedded and trailing zeros, multibyte UTF-8 bytes, and a short final
granule. Both readers must return identical hex bytes per key. Pinned stock
ClickHouse must `ATTACH PART`, return identical full and key-range results,
and pass `CHECK TABLE`; a corrupt-stream negative control must fail integrity.
If any of these fail, keep W10 experimental and do not claim server-readable
format compatibility. The verified scope will be the tested pinned producer,
Darwin filesystem and two-column Wide/LZ4 layout, not generic ClickHouse
parts or daemon restart behavior.

`Nullable(FixedString(N))`, date/time, UUID/IP, Decimal, Enum,
LowCardinality, arrays, maps, tuples, Variant/Dynamic, full JSON objects,
arbitrary schemas, and Compact parts remain guard-only for this slice.
Rollback is the single W10 feature commit. The DoD signal is focused and full
Crystal specs plus the pinned differential oracle all passing, with each
physical byte shape named in its output.

## Verified slice W11: BASIC Nullable(FixedString(N)) payload

Admit only the canonical exact `Nullable(FixedString(N))` spelling with
`1 <= N <= 65,536`, in the existing two-column Wide/LZ4 part with sorted
`UInt64` key. The BASIC reader must require exactly two physical substreams:
`<column>.null` (one boolean byte per row) and `<column>` (exactly `N` bytes
per row), with equal adaptive mark rows and no String `.size` stream. It must
consume the nested `N` bytes even when the null flag is set, while exposing
`nil` to the caller. Preserve the exact byte representation of non-null
values, including zeros and invalid UTF-8. The global String serialization
version must be a pinned valid enum value and Nullable serialization must be
BASIC; sparse or unknown versions fail closed. A direct call must preflight
both the 64-MiB raw-byte limit and the 65,536-value materialization limit.
The `types_serialization_versions` object is mandatory; omitted per-type
entries mean ClickHouse's version-0 defaults (String SINGLE_STREAM and
Nullable BASIC), not an unknown version.

Admit a separate writer entry point with explicit `N` and `Slice(String?)`;
Crystal's `String?` alone must continue to mean `Nullable(String)` in the
existing inferred writer. For `nil`, write flag 1 and a deterministic `N`
zero-byte nested slot. For non-null input, write flag 0 and zero-pad to `N`
bytes; reject overwidth inputs. Preflight frame/file/mark limits and
`rows_per_mark <= 65,536` before staging. Reuse checksummed metadata,
Crystal self-read, and exclusive publication. Table batches and offline
catalog values must expose the nullable byte string without conflating its
type or accessor with `Nullable(String)`.

The independent falsifier is a pinned stock ClickHouse-generated
`Nullable(FixedString(3))` part with NULL, empty, short, exact-width, and
embedded-zero values across multiple marks and a short final granule. Assert
two streams and exact physical mark rows; Crystal must read the same null flags
and non-null hex bytes. Conversely, pinned ClickHouse local must `ATTACH PART`
for Crystal output, return exact full and key-range rows, pass `CHECK TABLE`,
and detect a damaged payload or null-map stream. Include an all-NULL control
and an invalid-null-byte negative. The oracle must pin its producer version;
the available newer source tree is format guidance, not version authority.

W11 rejects sparse Nullable, Nullable(String) remapping, nested generic
Nullable expressions, non-UInt64 keys, Compact parts, mutable table inserts,
and daemon restart claims. Date/time, UUID/IP, Decimal, Enum,
LowCardinality, arrays, maps, tuples, Variant/Dynamic, and full JSON objects
remain guard-only. Risk tier is CAUTION: a wrong nested slot, stream shape,
or version check could create a convincing but unusable part. Rollback is one
W11 feature commit; before commit, revert only W11-owned paths.
DoD: focused RED-to-green specs, full debug/release suites, format and shell
checks, the pinned W11 differential oracle, and the W9/W10
oracles as regression guards. A failed external oracle prevents a verified
compatibility claim or commit.

W11 closure on the pinned local ClickHouse 26.7.1.1315/Darwin frontier:
366 Crystal examples passed in both debug and release. The independent
`N=3` oracle read a stock-generated two-stream part, attached the
Crystal-generated part, checked full and key-range rows, passed
`CHECK TABLE`, detected corruption in both streams, and exercised an invalid null
flag plus an all-NULL part. W9/W10 oracles also passed. This does not certify
every width against stock ClickHouse, other builds/filesystems, Compact
parts, power-loss durability, or daemon restart behavior.

## Completed slice W12: raw Date and Date32 day codes

Admit exactly the non-null `Date` and `Date32` column types as separate
semantic types in the existing Wide/LZ4, plain adaptive `.mrk2` reader and
two-column writer. A `Date` row is one little-endian `UInt16` day code since
1970-01-01; a `Date32` row is one little-endian signed `Int32` day code since
that epoch. Each has one data substream and the same mark/index boundaries as
the already-supported fixed-width numbers. The physical `Date` range is the
whole `UInt16` domain. The physical `Date32` range is the whole `Int32`
domain: the pinned ClickHouse build accepted both signed extrema in a part,
detached and reattached it, and passed `CHECK TABLE`. Its civil-date display
and SQL text conversions saturate outside their calendar range, so they must
not be used as a lossless representation of those raw codes.

Reader APIs return raw codes with distinct `Date`/`Date32` names and require
exact column metadata. They must not make a `Date` readable through the
ordinary `UInt16` accessor, a `Date32` through the ordinary `Int32` accessor,
or vice versa. Table batches and offline catalog column values preserve that
distinction at the schema/accessor boundary while yielding `UInt16` or
`Int32` codes to Crystal callers. Existing numeric-only scans remain limited
to exact numeric metadata. The offline TUI is a downstream consumer of the
typed-support predicate; if it selects these columns, it must display their
raw codes under the declared type rather than fail after selection. Its
existing equality filters remain UInt64/String-only. No Crystal `Time`
conversion, timezone, date arithmetic, or calendar validation is admitted.

Writer entry points name `Date` or `Date32` explicitly; the existing
type-inferred writer must continue mapping `UInt16` and `Int32` to their
numeric ClickHouse types. Reuse the W9 frame/mark/checksum/primary-index
preflights, staged self-read, and exclusive Darwin publication. Reject wrong
shapes or metadata and leave no published part on failure. Do not clamp or
reinterpret an input code during writing or reading.

The differential falsifier uses pinned ClickHouse 26.7.1.1315 stock-generated
parts with multiple marks and a short final granule, including `Date` 0 and
65,535 and `Date32` negative, ordinary, and signed-extreme codes. Crystal
must return the exact codes and mark ranges. Conversely, the pinned build
must `ATTACH PART` for separate Crystal-generated Date and Date32 parts,
return identical full/key-range raw codes, pass `CHECK TABLE`, and detect a
same-size damaged payload stream. Focused RED-to-green specs, full debug and
release suites, formatting/shell checks, and the W9/W10/W11 typed oracles are
the completion gate. Self-read alone cannot establish stock compatibility.

`DateTime`, `DateTime64`, Nullable dates, LowCardinality, timezone semantics,
calendar objects, non-UInt64 keys, mutable table inserts, Compact parts,
other ClickHouse builds, and daemon restart remain guard-only. Risk is
CAUTION: an accidental numeric alias or date conversion could silently
mislabel persisted values. Rollback is a single W12 feature commit; no push
or write into an existing ClickHouse data root is authorized.

W12 closure on the pinned local ClickHouse 26.7.1.1315/Darwin frontier:
376 Crystal examples passed in both debug and release. The differential
oracle checked stock-produced `Date` and `Date32` payload bytes, exact raw
codes (including both `Int32` extrema), adaptive marks `[2, 2, 1]`, and
Crystal-generated parts through `ATTACH PART`, full/key-range queries,
`CHECK TABLE`, and same-size payload corruption detection. W9/W10/W11
oracles passed as regression controls. The headless TUI specs and linked
example build passed; date cells show raw codes and equality filtering was
not widened. This evidence is fixture- and build-scoped, not proof of other
ClickHouse builds, calendar conversions, Compact parts, power-loss recovery,
or daemon restart behavior. Refresh it after changing the date serializer,
reader dispatch, part framing, or pinned ClickHouse build.

## Completed slice W13: raw DateTime seconds and DateTime64 ticks

Admit only non-null, timezone-unqualified `DateTime` and the canonical
`DateTime64(p)` spelling with one decimal precision digit `p` from 0 through
9, as separate semantic payload types in the existing two-column Wide/LZ4
reader and writer. The intended physical values are little-endian `UInt32`
epoch seconds and little-endian signed `Int64` ticks at scale `p`. The
precision is part of the exact column type and must survive catalog and
batch selection; raw ticks are meaningless without it. The pinned build has
already round-tripped `DateTime` including `UInt32::MAX` and `DateTime64(3)`
including both `Int64` extrema through RowBinary and detach/attach. Endpoint
scales 0 and 9 also preserve both extrema in pinned RowBinary probes;
stock parts use one stream and plain adaptive marks and pass `CHECK TABLE`.
The completed differential oracle also confirms Crystal-generated attachment
and reverse-direction raw-code reads.

Reader entry points and batch accessors must name seconds/ticks explicitly
and require exact metadata. `DateTime` must not pass the primitive `UInt32`
reader; `DateTime64(p)` must not pass the primitive `Int64` reader. Numeric
scans remain primitive-only. Catalog materialization yields raw UInt32/Int64
values while retaining the full DDL type string. The offline TUI may display
raw decimal seconds and ticks, but must label each DateTime64 cell with its
precision because its column header currently contains only a name. It must
not invent calendar text or widen its UInt64/String equality filter.

Writer entry points must name `DateTime` or an explicit precision `p`; the
inferred `UInt32` and `Int64` writer stays numeric. Retain W12's staged
self-read, exact metadata, width/frame/mark/checksum preflights, and
exclusive publication. Invalid precision, mismatched lengths, unsorted keys,
or failed publication must leave no part at the destination. No rounding,
clamping, timezone conversion, or `Time`/`Time::Span` conversion is admitted.

The falsifier uses pinned stock ClickHouse 26.7.1.1315 parts for bare
`DateTime` and `DateTime64(0)`, `(3)`, `(9)` across multiple marks and a
short last granule. It compares exact RowBinary codes, physical payload
bytes, marks and type metadata, including negative ticks and supported
extrema. In the reverse direction the pinned build must attach distinct
Crystal-generated parts, return exact full/key-range raw codes, pass
`CHECK TABLE`, and reject same-size payload corruption. Negative tests must
reject timezone-qualified or noncanonical type strings, primitive aliases,
and malformed precision before any callback or publication. Full debug and
release suites, TUI checks, format/shell checks, and W9-W12 differential
oracles are regression guards; self-read alone is insufficient.

`DateTime('zone')`, `DateTime64(p, 'zone')`, implicit precision spellings,
Nullable time types, timezone semantics, civil formatting, DST, arbitrary
keys, Compact parts, other ClickHouse builds, daemon restart, and power-loss
durability remain guard-only. The risk is CAUTION: an accidental scale or
timezone alias can silently change the meaning of persisted ticks. Rollback
is one local W13 feature commit after verification; no push or mutation of
an existing ClickHouse data root is authorized.

W13 closure on the pinned local ClickHouse 26.7.1.1315/Darwin frontier:
388 Crystal examples passed in both debug and release. The differential
oracle checked stock-produced `DateTime` and `DateTime64(0)`, `(3)`, `(9)`
metadata, physical payload bytes, exact marks, raw values including
`UInt32::MAX` and both `Int64` extrema, and full/key-range RowBinary.
Crystal-generated parts attached for all four types, returned byte-exact
full/key-range RowBinary, passed clean `CHECK TABLE`, and rejected a seeded
same-size payload corruption. W9-W12 oracles passed as regression controls;
the headless TUI suite and linked example build passed. The TUI exposes raw
codes and explicit DateTime64 precision without widening equality filters.
This evidence is fixture- and build-scoped, not proof of timezone-bearing
metadata, civil conversion, Compact parts, other ClickHouse builds, daemon
restart, or power-loss recovery. Refresh after changes to the time serializer,
type dispatch, part framing, or pinned ClickHouse build.

## Slice W14: nullable raw date/time codes

The admitted scope is exact `Nullable(Date)`, `Nullable(Date32)`,
`Nullable(DateTime)`, and `Nullable(DateTime64(p))`, where the inner precision
has W13's canonical one-digit 0..9 grammar. Non-NULL values remain raw
UInt16 day codes, Int32 day codes, UInt32 epoch seconds, or Int64 ticks;
NULL remains distinct from a zero code. The DDL and part type must retain
the complete wrapper and precision. No civil-time, timezone, or calendar
conversion is proposed.

The pinned ClickHouse 26.7.1.1315 probe generated a Wide/LZ4 part with exact
type spellings, `name.null` then `name` substreams, one fixed-width nested
value per row, zero placeholders under NULL, and plain adaptive `.mrk2`
records for `4,4,1` rows plus sentinel. `serialization.json` carries version
1, `types_serialization_versions:{"string":1}` and
`propagate_types_serialization_versions_to_nested_types:true`, with no
temporal column records. Raw RowBinary insertion and selection were
byte-identical for NULL, zero, and signed/unsigned extrema; the NULL wire
form omits nested bytes. `CHECK TABLE` passed. This admits reuse of the
existing BASIC Nullable byte codec, not the primitive numeric API. Reader entry points
and batch accessors must require the exact semantic Nullable type, and
primitive `Nullable(UInt16/Int32/UInt32/Int64)` accessors must refuse the
corresponding date/time metadata. Writer entry points must name the
semantic type and DateTime64 precision explicitly; inferred nullable
numeric slices must remain numeric. Invalid precision, mismatched rows,
unsupported metadata (including missing or non-1 `string` serialization
version), malformed null flags, or publication failure must fail closed
without exposing a partial part.

The falsifier reads stock-generated multi-mark parts through Crystal,
including NULL, zero, extreme non-NULL codes, and a short tail mark. In the
reverse direction stock ClickHouse must attach Crystal-generated parts,
return byte-exact full/key-range RowBinary, pass `CHECK TABLE`, and detect
same-size corruption in both the null-map and nested value streams. Local
negative tests must reject timezone-qualified or noncanonical metadata and
numeric accessor aliases before callbacks. W9-W13 differential oracles and
full Crystal debug/release suites are regression controls. The offline TUI
may display `NULL` and raw codes with an explicit DateTime64 precision label;
its equality filters remain unchanged. No compatibility claim is allowed
from Crystal self-read alone.

Nullable timezone-bearing types, implicit precision spellings, non-BASIC
serializations, civil conversion, other ClickHouse builds, Compact parts,
power-loss durability, and daemon restart remain guard-only. Risk is
CAUTION: a wrong null-map or semantic alias can silently alter persisted
data. Rollback is one W14-only local feature commit after the gate passes;
no push or mutation of an existing ClickHouse data root is authorized.

Observed W14 gate: the full debug and release Crystal suites each passed 405
examples. The pinned differential oracle passed stock-to-Crystal and
Crystal-to-stock for `Nullable(Date)`, `Nullable(Date32)`,
`Nullable(DateTime)`, and `Nullable(DateTime64(0/3/9))`: exact metadata,
substreams, marks and raw codes, full/key-range RowBinary, `ATTACH PART`,
`CHECK TABLE`, and independent same-size corruption of the null-map and
nested value streams. W9-W13 differential controls, the headless TUI suite,
and the linked TUI build passed. This does not admit timezone semantics,
SQL calendar conversion, Compact parts, compressed marks, other ClickHouse
builds, daemon restart, or power-loss durability. Refresh after changes to
Nullable/date-time dispatch, part framing, or the pinned ClickHouse build.

## Completed slice W15: paired fixed-width semantic payloads

W15 targets a UInt64 primary key and one payload in the existing Wide/LZ4,
plain adaptive-mark part format. The paired reader/writer surface is exact
`Bool`, bounded canonical `Enum8/16` declarations, and stock-normalized
`Decimal(9, S)` / `Decimal(18, S)` (the metadata emitted for `Decimal32(S)` /
`Decimal64(S)`), plus one BASIC `Nullable(...)` wrapper for
each. No type becomes reader-admitted until its writer can produce a part
accepted by pinned ClickHouse 26.7.1.1315, and vice versa. `Bool` is exposed
as Crystal Bool, enums as signed raw codes with the exact label/code mapping
retained in metadata, and decimals as signed raw scaled integers with the
explicit scale retained in metadata. Inferred signed-integer slices remain
signed-integer columns; semantic types require named entry points. No text
conversion, arithmetic, enum-label lookup, or decimal rounding is admitted.

The strongest likely failure is an apparently valid primitive-width stream
whose semantic metadata, enum code, Bool byte, or Nullable placeholder is
wrong. Require exact type grammars and reject malformed, duplicate, or
unsupported enum definitions; reject Bool bytes outside 0/1 and undeclared
enum codes in non-NULL rows. A Nullable NULL slot is represented by a null
flag and fixed-width zero placeholder, not by conflating NULL with a valid
zero value. No existing directory may be replaced on failed validation or
publication. Reader and writer accessors must not alias the corresponding
primitive numeric metadata. The pinned stock probe must establish exact
`columns.txt`, substream ordering, `serialization.json`, marks, and raw bytes
before implementation of each shape. The pinned 26.7.1.1315 probe observed
the normalized decimal spellings above, exact Bool and Enum8/16 spellings,
one fixed-width raw stream per bare column, `<name>.null` then `<name>` for
Nullable, and `serialization.json` version 1 with only global `string:1`.
RowBinary uses the corresponding little-endian fixed width and omits the
nested value on NULL. Stock RowBinary ingestion and `CHECK TABLE` accept
non-0/1 Bool bytes and undeclared Enum codes; W15 deliberately rejects those
on its bounded semantic reader/writer surface. Therefore stock `CHECK TABLE`
alone is not a semantic-value oracle. The pinned stock probe also accepted
the full signed Int32/Int64 backing ranges for Decimal32/64, despite their
nominal decimal precisions; W15 preserves those raw widths without rounding.
Stock Enum metadata escaped embedded quote and backslash labels; those two
escape forms are admitted, with the pinned canonical comma/equality spacing.
Raw control characters and alternate spacing in a declaration remain outside
the admitted grammar. W15 also requires the observed empty per-column
serialization list and no `missing_columns` override.

W15 falsifier: stock-generated multi-mark parts with a short tail, Boolean
false/true, signed enum codes, decimal negative/zero/positive raw values,
and NULL distinct from zero must read exactly through Crystal. In reverse,
stock ClickHouse must attach Crystal-generated parts, return the expected
RowBinary for full and key-range scans, and pass `CHECK TABLE`. Negative
tests must reject unsupported semantic metadata and invalid values before
publication; same-size stream corruption must fail the applicable checksum
or stock `CHECK TABLE` guard. Full debug/release Crystal suites and W9-W14
oracles are regression controls. The TUI may display raw semantic values but
does not gain new equality predicates in W15.

Rejected for W15: inferred enum or decimal metadata, SQL-level conversion,
noncanonical enum label grammars beyond the pinned quote/backslash escapes, sparse or
alternative serialization, arbitrary table schemas, Compact parts, and full
JSON values. `Decimal128/256`, UUID/IP, timezone-qualified date/time,
LowCardinality, Array/Map/Tuple, Variant/Dynamic, and nested composites stay
guard-only. Risk is CAUTION: a metadata/value mismatch can silently corrupt
persistent data. Rollback is the W15-only local feature commit; no push or
existing ClickHouse data-root mutation is authorized.

Observed W15 gate: the full debug and release Crystal suites each passed 426
examples. The pinned ClickHouse 26.7.1.1315 differential oracle passed 23
stock-to-Crystal and Crystal-to-stock fixtures: bare and BASIC Nullable Bool,
Enum8/16, Decimal32 at scales 0/2/9, Decimal64 at scales 0/4/18, plus a bare
Enum8 declaration with escaped quote and backslash labels. Bare and Nullable
Enum8/16 fixtures also cover the signed backing-width minimum and maximum
codes. Every fixture checked physical streams/marks, metadata, full and
key-range RowBinary,
`ATTACH PART`, and `CHECK TABLE`; representative bare and nullable payloads
also rejected same-size stream corruption. Reader negatives cover invalid
Bool bytes, undeclared Enum codes, malformed/noncanonical declarations,
per-column serialization overrides, and NULL placeholders. W9-W14 pinned
oracles, the headless TUI harness, and the linked TUI build passed. This
evidence decays after a reader/writer/serialization change, a pinned
ClickHouse build change, or a format/platform change; refresh the paired
oracles and full suites before widening the claim.

## Completed slice W16: paired raw Decimal128

The W16 payload is ClickHouse `Decimal128(S)` at scales 0 through 38,
including one BASIC `Nullable(Decimal128(S))` wrapper, in the same sorted
`UInt64`-key, two-column Wide/LZ4, plain adaptive-mark part shape. Expose raw
signed 128-bit scaled integers in Crystal with an explicit scale; generic
`Int128` slices must not silently become Decimal128 columns. The pinned
producer normalizes these aliases to `Decimal(38, S)` and
`Nullable(Decimal(38, S))`; accept only these exact canonical part declarations.
The pinned physical probe confirmed scales 0 and 38, signed 16-byte
little-endian words, one bare payload stream, Nullable `.null` then payload
with zero-filled NULL slots, plain 24-byte adaptive mark records, and the
global `string:1` serialization-version metadata already used by W15.
RowBinary omits the nested word under NULL.

The compatibility falsifier has two directions: stock-generated multi-mark
parts with negative, zero, positive, and NULL values must read exactly in
Crystal; Crystal-generated parts must attach to pinned ClickHouse, return
byte-exact full and key-range RowBinary, and pass `CHECK TABLE`. Scale endpoints
and invalid scales, malformed declarations, truncated streams, and NULL versus
zero must be tested. A failed writer validation must leave no published part.
Generic primitive numeric accessors, including attempted `Int128` dispatch,
must not alias Decimal128 metadata. The W15-named public semantic predicates
remain W15-only; the neutral fixed-width predicates include W16. Full debug
and release suites and the prior pinned oracles are regression guards, not
substitutes for the W16 differential oracle.

Observed W16 gate: the pinned ClickHouse 26.7.1.1315 differential oracle
passed seven stock-to-Crystal and Crystal-to-stock fixtures: bare and BASIC
Nullable Decimal128 at scales 0, 2, and 38, plus bare scale-0 raw
`Int128::MIN/MAX`. Each fixture checked canonical metadata, physical streams
and marks, exact full and key-range RowBinary, `ATTACH PART`, and stock
`CHECK TABLE`; representative bare payload and Nullable payload/null-map
streams rejected same-size corruption. SQL `toDecimal128` conversion rejects a
39-digit input, but stock RowBinary ingestion and attached parts preserved the
full signed Int128 backing extrema; W16 is a raw-code API, not a SQL decimal
conversion API. Both full debug and release suites passed 436 examples each.
The selected-column TUI spec passed 21 examples, the optional headless TUI
harness passed six, and the W9-W15 pinned type oracles passed. These signals
apply to the tested Wide/LZ4/plain-mark/Darwin and pinned-build boundary, not
to arbitrary ClickHouse releases or part layouts.

Rejected in W16: Decimal256, arbitrary `Decimal(P,S)` widths or conversions,
rounding, SQL arithmetic, alternative serializers, nested composites, Compact
parts, and any claim beyond the pinned build and Darwin publication boundary.
Risk is CAUTION because valid-looking 16-byte streams can encode incorrect
signed values or scales. Rollback is a W16-only local feature commit; no push
or mutation of an existing ClickHouse data root is authorized.

## Completed slice W17: paired UUID payloads

Admit exactly `UUID` and BASIC `Nullable(UUID)` as payload declarations on the
existing sorted `UInt64`-key, two-column Wide/LZ4, plain adaptive-mark part
shape. The Crystal value is a 16-byte structure with separate high and low
`UInt64` halves, preserving the canonical UUID value without per-row strings;
generic `UInt128` and `FixedString(16)` accessors must not alias this type.
The reader, table batch, offline catalog, and optional TUI must either expose
and render this value consistently or refuse selection before page loading.
The writer must require a named UUID entry point and zero-fill the nested slot
for NULL. It may not infer UUID metadata from a generic numeric or string
slice. No variant/version validation is implied by the UUID type.

Before implementation, probe pinned ClickHouse 26.7.1.1315 to establish the
canonical type spelling, exact high/low byte order, data and null-map stream
names/order, serialization metadata, marks, and RowBinary NULL encoding. A
falsifier uses non-symmetric high/low halves and a short final mark: stock
parts must decode to the exact canonical identifiers in Crystal, and Crystal
parts must attach to stock ClickHouse, return byte-exact full and key-range
RowBinary, pass `CHECK TABLE`, and fail the appropriate integrity check after
representative same-size corruption. Missing/truncated streams and malformed
type metadata must fail closed. Full debug/release suites and W9-W16 pinned
oracles are regression controls, not substitutes for this W17 oracle.
The pinned preimplementation probe observed `UUID` and `Nullable(UUID)` in
`columns.txt`, a bare payload stream or BASIC `payload.null` then `payload`,
and version-1 serialization metadata with only the global `string:1` entry.
Canonical `00112233-4455-6677-8899-aabbccddeeff` physically encodes as
`77 66 55 44 33 22 11 00 ff ee dd cc bb aa 99 88`: high `UInt64` little
endian, then low `UInt64` little endian. For a NULL row, the nested payload
is 16 zero bytes while RowBinary emits only the null flag. The five-row
stock parts had four plain adaptive marks with a short final granule.

Observed W17 gate: the pinned ClickHouse 26.7.1.1315 differential oracle
passed both bare and BASIC Nullable shapes in both directions. Stock parts
read exactly in Crystal; Crystal parts attached to stock ClickHouse with
matching metadata, streams, payload bytes, marks, full and key-range
RowBinary, and clean `CHECK TABLE`. Isolated same-size payload and nullable
null-map corruption were detected. Focused specs reject absent/malformed
serialization metadata, truncated streams, primitive aliases, and invalid
prepublication inputs. The full debug and release suites each passed 448
examples, the selected-column TUI spec passed 22, the optional headless TUI
harness passed six, and the W9-W16 pinned type oracles passed. This evidence
decays after a reader/writer/serialization change, a pinned ClickHouse build
change, or a format/platform change; refresh the paired oracle and suites
before widening the claim.

Rejected in W17: `IPv4`, `IPv6`, `Decimal256`, timezone-qualified temporal
declarations, UUID ordering as a generic `UInt128`, non-BASIC Nullable
serializers, composite types, Compact parts, arbitrary table schemas, and
claims beyond the pinned build and Darwin publication boundary. Risk is
CAUTION: an apparently valid 16-byte stream can silently swap UUID halves.
Rollback is the W17-only local feature commit; no push or existing ClickHouse
data-root mutation is authorized.

## Completed slice W18: paired IPv4 payloads

Admit exactly `IPv4` and BASIC `Nullable(IPv4)` as payload declarations on the
existing sorted `UInt64`-key, two-column Wide/LZ4, plain adaptive-mark part
shape. An `IPv4Value` is a four-byte value type with canonical dotted-decimal
rendering and no per-row string object. Its public representation and accessor
must be distinct from a plain `UInt32`, even if the on-disk scalar occupies
four bytes. The reader, table batch, offline catalog, and optional TUI must
either expose the same semantic value or reject the selection before page
loading. Named bare/nullable writer APIs must preserve that type identity;
generic `UInt32` inputs must never silently produce `IPv4` metadata. NULL and
`0.0.0.0` are distinct values, with a deterministic zero-filled nested slot
for NULL. No IPv4-specific key ordering, filtering, or SQL function is added.

Before production edits, probe pinned ClickHouse 26.7.1.1315 for canonical
type spelling, byte order with asymmetric addresses, stream and mark names,
serialization metadata, null-map behavior, and RowBinary encoding. A
falsifier includes `1.2.3.4`, `4.3.2.1`, `0.0.0.0`, NULL, multiple marks, and a
short final granule. The exact byte order is established by the probe, not by
assuming that IPv4 aliases a native-endian `UInt32`. Stock parts must decode
to the expected addresses in Crystal; Crystal parts must attach to stock
ClickHouse, return byte-exact full and key-range RowBinary, pass `CHECK TABLE`,
and have ClickHouse `CHECK TABLE` reject representative same-size stream
corruption in a disposable attached copy. Missing/truncated
streams, malformed type/serialization metadata, and primitive accessor
aliasing must fail closed. Full debug/release suites and W9-W17 pinned oracles
are regression controls, not substitutes for the W18 oracle.
The pinned preimplementation RowBinary probe observes `1.2.3.4` as
`04 03 02 01` and `4.3.2.1` as `01 02 03 04`: a little-endian encoding of
the network-order 32-bit address, not dotted-octet byte order. Stock
`columns.txt` spells the types `IPv4` and `Nullable(IPv4)`; the BASIC nullable
stream order is `payload.null` then `payload`. Both shapes use version-1
serialization metadata with the global `string:1` entry and empty per-column
list. RowBinary NULL carries only the one-byte flag; the physical nested
NULL slot is four zero bytes. The stock nullable null map was
`01 00 00 00 00`; a non-NULL `0.0.0.0` has the same four nested zero bytes
but map byte `00`. These are preimplementation format observations, not a
paired-compatibility claim.

Observed W18 gate: the pinned ClickHouse 26.7.1.1315 differential oracle
passed bare and BASIC Nullable IPv4 in both directions. Stock parts decoded
exactly in Crystal; Crystal parts attached to stock ClickHouse with matching
metadata, stream bytes, marks, full and key-range RowBinary, and clean
`CHECK TABLE`. Isolated same-size payload and nullable null-map corruption
was rejected by stock `CHECK TABLE`; this does not claim Crystal independently
detects arbitrary same-size semantic changes. Focused specs cover malformed
serialization/type metadata, truncated streams, NULL versus `0.0.0.0`,
primitive `UInt32` accessor isolation, and named-only writer admission. The
full debug and release suites each passed 458 examples, the selected-column
TUI spec passed 23, the optional headless TUI harness passed six, and W9-W17
pinned type oracles passed. This evidence decays after a reader/writer or
serialization change, a pinned ClickHouse build change, or a format/platform
change; refresh the paired oracle and suites before widening the claim.

Rejected in W18: `IPv6`, IP subnet and other address operations, IPv4 primary
keys, non-BASIC Nullable serializers, composite types, Compact parts,
arbitrary table schemas, and claims beyond the pinned build and Darwin
publication boundary. CAUTION: a four-byte stream can remain structurally
valid after octet reversal while every address becomes wrong. Rollback is one
W18-only local feature commit; no push or existing ClickHouse data-root
mutation is authorized.

## Rejected and guard-only surfaces

Rejected for W1: mutation of existing parts, table-level `INSERT`, merges,
replication, transactions across tables, SQL, Compact parts, compressed
marks, composite codecs, `Nullable`, `String`, JSON, projections, deletes,
TTL, and arbitrary partition expressions. No performance claim is admitted.

Residual guard-only surfaces:

1. Extend reader and writer together beyond W16's bounded semantic scalars,
   W14's BASIC nullable temporal codes, W13's raw time codes, W12's raw dates,
   W11's BASIC
   `Nullable(FixedString(N))`, W10's plain `FixedString(N)`, W9's exact 22
   payload shapes, one stock-ClickHouse differential fixture per type and
   substream shape.
   Reader support never implies writer support. Recheck physical stream naming
   on case-sensitive filesystems before claiming cross-filesystem
   compatibility. Sparse and other String variants remain guard-only.
2. The bounded Crystal-owned table does not widen `OfflineCatalog` to a
   mutable API, and W9 does not widen table insertion to new schemas.
3. General filtering, power-loss durability, and idempotent caller retries
   remain separate frontiers. W8's recorded-index-hash validation applies
   only to embedded candidate scans.

Generic selected-entry validation remains size-only. W8 checks only the
embedded candidate path's active primary indexes; it is not full part
content-integrity verification.
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

W9 evidence at parent `a358b76` plus the W9 implementation diff on Crystal
1.21.0 and Darwin: the missing typed entry point was first exercised as a
RED spec. The legacy and typed writer specs passed 24/24 together; the full
debug and release suites each passed 340/340. Formatting, shell syntax, and
diff whitespace checks passed. The independent official ClickHouse local
`26.7.1.1315` oracle attached all 22 exact scalar/Nullable payload shapes,
returned exact typed rows and `UInt64` key-range rows, and passed clean
`CHECK TABLE`. It then detected an independent one-byte mutation in each
nonempty payload substream, restored the byte, and required a clean check
before testing the next stream. Additional controls covered all-NULL
`Nullable(UInt64)`, all-NULL `Nullable(String)` with a zero-byte raw stream,
and all-empty `String`; the older four-shape writer oracle stayed green.
Local failure probes reject invalid input and oversized regular or Nullable
String payloads without publishing a part. The adversarial review's two
negative-test gaps were closed before the final runs. This certificate is
limited to one sorted `UInt64` key plus one typed payload in a Wide/LZ4 part,
exclusive Darwin publication, and the pinned `clickhouse local` consumer;
it does not prove a daemon's attach/restart lifecycle, arbitrary schemas,
JSON object serialization, or other ClickHouse types. A writer/reader or
format change, ClickHouse build change, or platform/filesystem change decays
it; refresh the focused/full suites and both external writer oracles.

W10 evidence at parent `d3ac49c` plus the W10 implementation diff on Crystal
1.21.0 and Darwin: the exact typed reader and explicit writer APIs were first
exercised by RED specs. A second RED spec showed that `FixedString` wrongly
accepted `serialization.json` with global `string: 999`; a read-only adversary
also found that a 64-MiB `FixedString(1)` range could create tens of millions
of String objects. Both gaps were closed before final checks. The focused
reader/writer specs passed 12/12; the full debug and release suites each
passed 352/352. Formatting, shell syntax, and diff whitespace checks passed.
The pinned ClickHouse local `26.7.1.1315` oracle generated a stock
`FixedString(3)` part whose exact bytes and `[2, 2, 1]` mark rows Crystal
read correctly. It then attached a Crystal-generated part, compared full and
key-range hex rows, passed `CHECK TABLE`, and detected a damaged payload
frame. The W9 22-shape oracle and all-null/all-empty controls stayed green.
Adversarial review returned ROBUST within the bounded scope. This certificate
covers one sorted `UInt64` key and one plain `FixedString(N)` payload in a
Wide/LZ4 part with exclusive Darwin publication; stock interoperability was
exercised at `N=3`, not every width. It does not prove daemon restart behavior,
Nullable(FixedString), other formats, or all ClickHouse versions. A
reader/writer, format, ClickHouse build, platform, or filesystem change decays
it; refresh the focused/full suites and the W10 external oracle.

Risk tier: CAUTION, because malformed serialization can create convincing
but unusable persistent data. Rollback is the respective feature commit;
there will be no push or write into existing ClickHouse data roots. The
strongest likely failure is a subtle frame/checksum or mark/index mismatch
that our reader tolerates and ClickHouse rejects. The stock-ClickHouse attach,
read, and `CHECK TABLE` gates are mandatory for W1/W2/W3/W9/W10 verification.
