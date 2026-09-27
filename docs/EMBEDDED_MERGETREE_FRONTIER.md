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
parity: at W15, JSON typed-path reading remained an unmatched surface; W24
later pairs one exact declaration with a writer.
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
W19 admits paired `IPv6` and BASIC `Nullable(IPv6)` payloads on the same
pinned Wide/LZ4 frontier after a bidirectional stock/Crystal oracle and full
regression gate. The value is distinct from UUID and UInt128; IPv6 keys,
general IP operations, and untested ClickHouse versions remain outside scope.
W20 admits paired raw `Decimal256` and BASIC `Nullable(Decimal256)` payloads
on the same pinned frontier. A bidirectional stock/Crystal oracle exercises
scales 0, 38, and 76 in both shapes, including the signed 256-bit backing
extrema at scale 0. This is raw coefficient compatibility, not Decimal SQL
arithmetic, conversion, or support for arbitrary part layouts.
W21 admits paired `Array(UInt64)` and `Array(String)` payloads in the existing
two-column Wide/LZ4 part. A pinned bidirectional stock/Crystal oracle,
debug/release suites, and prior-type oracles passed on this host. This is a
bounded physical and API compatibility claim, not generic Array support or a
performance claim. W22 addresses `LowCardinality(String)` as a separate
boundary, not an implied Array variant.
W22 implements bounded, paired `LowCardinality(String)` payloads, including
the two observed UInt8 dictionary shapes for reading and one shared-dictionary
writer shape. Its verification record and exclusions are below.
W23 admits one exact named `Tuple(a UInt64, b String)` payload beside a
`UInt64` key. Its stock-to-Crystal reader and Crystal-to-stock writer gates
passed on the pinned build; this is not general Tuple or recursive type support.
W24 pairs the existing scalar typed-path reader with a writer for exactly
`JSON(a UInt64, b String)` beside a `UInt64` key. The pinned stock oracle
passes `ATTACH PART`, exact typed and normalized whole-object reads, and
`CHECK TABLE`; this is not general JSON support.
W25 admits one exact top-level `Map(UInt64, String)` payload beside a
`UInt64` key. Its reader and writer use ordered entry arrays, not a hash,
to preserve duplicate keys and entry order. See
`MAP_UINT64_STRING_FRONTIER.md` for the physical probe, evidence, and limits.
W26 admits one more exact top-level payload, `Map(UInt64, UInt64)`, with a
paired reader and writer on the same pinned frontier. Its three-stream
physical probe, stock fixture, and bounded evidence are in
`MAP_UINT64_UINT64_FRONTIER.md`; this is not general Map support.
W27 admits paired `Array(Nullable(UInt64))` reading and writing while reusing
the existing bounded Array stream topology. Its bidirectional stock oracle and
full regression gate passed on the pinned build; it does not admit arbitrary
recursive types or change the optimization priority below.
W28 admits one exact recursive composition, `Array(Array(UInt64))`, with
paired reading and writing. Its stock-part, writer, and regression gates passed;
this does not admit arbitrary nested types.
W29 admits exactly `Array(Array(Nullable(UInt64)))` with paired reading and
writing, typed batches, and offline catalog values. Its four-stream stock
oracle and regression gates passed; this is not general recursive type support.
W30 admits a bounded single-level numeric Array family, replacing
one-spelling-at-a-time widening with a sealed leaf plan. It does not admit
nullable numeric leaves or arbitrary recursive Arrays.
W31 admits paired `Array(Nullable(T))` payloads for those ten primitive
numeric leaves, retaining W27's exact `UInt64` entry points. Its multi-column
empty-serializer admission is limited to the pinned 11-column stock shape;
this does not imply arbitrary table-schema composition.
W32 admits paired `Array(Nullable(String))` payloads beside a sorted `UInt64`
key, with typed batches and caller-owned offline catalog values. Its stock
oracle covers four physical streams and both directions; it does not admit
other nullable String wrappers or arbitrary recursive types.
W33 admits paired `Array(FixedString(N))` and
`Array(Nullable(FixedString(N)))` for canonical widths on the pinned
Wide/LZ4/plain-mark frontier. Its exact evidence and limits are below.
W34 admits paired `Array(Bool)` and `Array(Nullable(Bool))` on that pinned
frontier. Its stock physical probe, exact-domain checks, and bidirectional
oracle are recorded below; this is not generic semantic Array support.
W35 admits bare raw `Int128` and `UInt128` scalar payloads through exact
reader, batch, catalog, and writer APIs. Its compatibility evidence and
remaining exclusions are recorded below.
W36 separately admits BASIC `Nullable(Int128)` and `Nullable(UInt128)`
scalar payloads through exact paired APIs; Sparse remains rejected.
W37 admits bare raw `Int256` and `UInt256` scalar payloads through the
same exact reader, batch, catalog, and writer boundary; its pinned stock
compatibility evidence and remaining exclusions are recorded below.
W38 separately admits BASIC `Nullable(Int256)` and `Nullable(UInt256)`
scalar payloads through exact paired APIs; Sparse remains rejected.
W39 admits single-level Arrays of the already admitted raw 128- and 256-bit
integer values, with BASIC Nullable leaves on the pinned Wide/LZ4/plain-mark
frontier. It does not admit generic recursive Arrays or semantic aliases.
W40 admits paired single-level temporal Arrays: bare `Date`, `Date32`,
`DateTime`, and canonical `DateTime64(p)` leaves, plus their BASIC Nullable
forms. Raw code and tick APIs must retain the exact semantic declaration;
this does not admit timezone-qualified declarations or calendar conversion.

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

Implementation order: pursue reader/writer parity across ClickHouse type
families first, including recursive and JSON shapes; then implement
materialized-view and projection compatibility; only then optimize memory and
throughput. Interim bounds and regression checks protect correctness, but are
not a speed-tuning phase. A future like-for-like comparison no more than 10%
slower than stock ClickHouse may end the optimization phase; its workload,
output equivalence, and measurement conditions must be pinned before using
that number as evidence. Passing a speed target cannot replace type, MV, or
projection compatibility.

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

## Completed slice W19: paired IPv6 payloads

Admit exactly `IPv6` and BASIC `Nullable(IPv6)` as payload declarations on
the existing sorted `UInt64`-key, two-column Wide/LZ4, plain adaptive-mark
part shape. Keep an IPv6 value distinct from `UUID`, `UInt128`, and
`FixedString(16)` even if the payload width is 16 bytes. The reader, batch,
offline catalog, and optional TUI must expose one consistent value or reject
selection before page loading. Named bare/nullable writer APIs must preserve
type identity, and NULL must remain distinct from the all-zero address with
a deterministic zero-filled nested slot. No IPv6 key ordering, subnet
operation, IP function, or general parser contract is admitted.

Before implementation, probe pinned ClickHouse 26.7.1.1315 with asymmetric
addresses, `::`, `::1`, `2001:db8::1`, a non-compressible address, and a
NULL slot. Establish canonical type spelling, physical 16-byte order,
text rendering relevant to the exposed API, substream order, serialization
metadata, marks, RowBinary, and stock `CHECK TABLE`. The gate is a
bidirectional stock/Crystal oracle: exact bytes and marks, full and key-range
RowBinary, stock attachment of Crystal parts, clean `CHECK TABLE`, and stock
rejection of representative same-size corruption in an isolated copy.
Focused negative specs must reject UUID/numeric aliases, malformed metadata,
truncated streams, and bad inputs before publication. Full debug/release
suites and W9-W18 pinned type oracles guard regression. Any later probe
conflict reopens W19 and requires this design boundary to be revised first.

The preimplementation pinned stock probe recorded `IPv6` and
`Nullable(IPv6)` in `columns.txt`, the bare `payload` stream or BASIC
`payload.null` then `payload`, version-1 serialization metadata with only
global `string:1`, and 16 network-order address octets per physical row.
The pinned text probe renders both IPv4-compatible `::192.0.2.1` and
IPv4-mapped `::ffff:192.0.2.1` with a dotted-decimal tail, but renders
`::ffff:0:192.0.2.1` as `::ffff:0:c000:201`. The value renderer must
preserve these distinct observed cases rather than convert every low
32-bit tail to dotted decimal. A boundary probe rendered compatible
`::0.0.0.2` as `::2` and `::0.0.1.0` as `::100`, but retained dotted
tails for `::0.1.0.0` and `::1.0.0.0`; the low-order 32-bit value's upper
16 bits therefore determine the tested compatible-text branch.
For five rows at granularity two, payload marks were `(0,0,2)`, `(0,32,2)`,
`(0,64,1)`, `(0,80,0)`; the nullable map marks were `(0,0,2)`,
`(0,2,2)`, `(0,4,1)`, `(0,5,0)`. A NULL row had a one-byte null flag in
RowBinary without nested bytes, but a 16-zero-byte physical nested slot;
non-NULL `::` had the same nested zeros and a zero null flag. The
bidirectional oracle must independently replay these expectations before
any compatibility claim.

Observed W19 gate: `scripts/check_ipv6_oracle.sh` passed on pinned ClickHouse
26.7.1.1315 for both bare and BASIC Nullable shapes. It checked hardcoded
16-byte network-order payloads and high/low halves independent of the writer,
exact streams/marks/metadata, stock-to-Crystal reads, Crystal-to-stock
`ATTACH PART`, full and key-range RowBinary, clean `CHECK TABLE`, and
same-size corruption rejection in isolated copies. Focused specs cover
declaration and alias isolation, cross-mark/batch/catalog access, NULL versus
`::`, malformed metadata, truncated streams, prepublication rejection, and
TUI display. The full debug and release Crystal suites each passed 467
examples; W9-W18 pinned type oracles and the optional headless TUI harness
passed. These checks establish paired compatibility only on the tested
two-column `UInt64`-key Wide/LZ4/plain-adaptive-mark shape. A future reader,
writer, serialization, ClickHouse build, or platform change decays this
evidence and requires rerunning the oracle and relevant suites.

Residual W19 guard-only surfaces: unobserved IPv4-compatible presentation,
non-BASIC Nullable serializers, IPv6 primary keys, IP functions, arbitrary
schemas, Compact parts, and claims beyond the pinned build and Darwin
publication boundary. A structurally valid 16-byte value can silently render
as another address if halves or octets are reversed; the hardcoded byte and
text controls guard this tested risk. Rollback is one W19-only local feature
commit; no push or mutation of an existing ClickHouse data root is authorized.

## Completed slice W20: paired raw Decimal256 payloads

W20 admits only `Decimal256(S)` and BASIC `Nullable(Decimal256(S))` payloads on
the existing sorted `UInt64`-key, two-column Wide/LZ4, plain adaptive-mark
part shape. The public value must be a distinct 32-byte signed two's-complement
coefficient, not `Int128`, `UUID`, `IPv6`, or a scaled floating-point number.
The scale is explicit and never changes stored raw bits. The pinned producer
persists `Decimal256(S)` as `Decimal(76, S)` and its BASIC Nullable form as
`Nullable(Decimal(76, S))`; scales 0 and 76 are accepted while -1 and 77 are
rejected. The exact admitted range is 0 through 76.
Named bare/nullable writer APIs must preserve type identity, and NULL must
remain distinct from zero with a deterministic zero-filled nested slot. No
SQL decimal conversion, arithmetic, rounding, or general `Decimal(P,S)`
contract is admitted.

The isolated pinned ClickHouse 26.7.1.1315 probe observes 32-byte signed
little-endian coefficients, including an asymmetric high-word positive value,
its two's-complement negative, zero, +1, and -1. A five-row Wide part at
granularity two has four marks (including the final zero-row mark): Decimal256
decompressed offsets 0, 64, 128, 160; Nullable null-map offsets 0, 2, 4, 5.
The Nullable physical stream order is `payload.null`, then `payload`, with
zero-filled nested slots for NULL. `CHECK TABLE` succeeds. RowBinary accepts
raw coefficient one at scale 76, stores the same 32 bytes, and renders 76
fractional places. At scale zero, RowBinary accepts both signed 256-bit backing
extrema and SQL renders their full signed integers. SQL
`toDecimal256('1', 76)` is not a valid substitute for a raw coefficient of one
because that decimal input needs 77 unscaled digits.

The bidirectional pinned stock/Crystal oracle passes at scales 0, 38, and 76
for both bare and BASIC Nullable: hardcoded raw bytes and marks independent
of the writer, stock-to-Crystal reads, Crystal-to-stock `ATTACH PART`, exact
full/key-range RowBinary, clean `CHECK TABLE`, and isolated same-size
corruption rejection for bare payload and nullable map/payload. Focused
negative specs reject noncanonical scales/declarations, primitive or UUID/IP
aliases, malformed metadata, truncated streams, and bad inputs before
publication. Reader, batch, catalog, and TUI expose one consistent raw value;
the TUI displays the coefficient with an explicit scale label, not a SQL
formatted decimal. Full debug/release suites (478 examples each), headless
TUI (6 examples), and all W9-W19 pinned type oracles passed. The adversarial
review found no concrete defect within this bounded path (ROBUST); it does
not widen the pinned-version or layout claim. Evidence decays if ClickHouse
version, part format, writer serialization, reader dispatch, or TUI formatting
changes; refresh the pinned oracle and relevant suites.

Rejected in W20: generic `Decimal(P,S)` widths, numeric conversion/arithmetic/rounding,
non-BASIC Nullable serializers, arbitrary schemas, Compact parts, and claims
beyond the pinned build and Darwin publication boundary. CAUTION: a 32-byte
stream can remain structurally valid after high-word sign extension or word
order is wrong. Rollback is one W20-only local feature commit; no push or
mutation of an existing ClickHouse data root is authorized.

## Verified bounded slice W21: paired Array(UInt64) and Array(String)

Admit exactly one payload column of `Array(UInt64)` or `Array(String)` beside
the sorted `UInt64` key in the existing Wide/LZ4, plain adaptive-mark part.
Expose one owned array of element values per row without SQL array functions
or implicit casts. Empty arrays, empty strings, embedded zero bytes, multiple
marks, and a short final granule must retain their distinct values. Bound
each selected mark range to 65,536 outer rows, 65,536 flattened elements,
and 64 MiB of raw nested bytes; a stock part beyond those limits must fail
closed before a large allocation. The writer must preflight the same limits
per mark.
Catalog `.values` materialization has a separate whole-call ceiling of
1,000,000 flattened elements, in addition to its existing row and String
byte ceilings; lazy scans remain available for larger columns.
Publication remains staged, self-read, and exclusive.

The pinned ClickHouse 26.7.1.1315 physical probe established plain adaptive
`.mrk2` Wide parts with exactly `payload.size0` then `payload` for
`Array(UInt64)`, and `payload.size0`, `payload.size`, `payload` for
`Array(String)`. `size0` stores one little-endian UInt64 length per outer
row; nested `.size` stores one little-endian UInt64 length per flattened
String; payload elements are flattened. A seven-row part at granularity two
has data mark rows `[2, 2, 2, 1]` and a zero-row sentinel. The UInt64
array's decompressed mark offsets are `size0: [0, 16, 32, 48, 56]` and
`payload: [0, 8, 32, 40, 56]`. The String array has `size0` offsets as
above, nested `.size: [0, 8, 24, 48, 56]`, and raw payload offsets
`[0, 0, 1, 7, 11]`. Stock `serialization.json` declares `string: 1` with
propagation enabled. Both seven-row stock parts attached to matching clean
tables, passed `CHECK TABLE`, and returned exact full and key-range RowBinary,
including empty arrays and embedded-zero String bytes. The Crystal reader
accepts this stock metadata shape and the writer's bounded metadata shape.
An independent all-empty probe found a present zero-byte `payload.bin` and
ordinary `.mrk2` for `Array(UInt64)` rows containing only `[]`. The same
present zero-byte raw stream occurs for `Array(String)` containing empty
arrays and only empty strings; its nested `.size` stream remains nonempty.
Zero-byte stream presence is therefore distinct from a missing stream.

The bidirectional oracle passed stock-to-Crystal positional and key-range
reading plus Crystal-to-stock `ATTACH PART`, positional and key-range
RowBinary, and `CHECK TABLE` for both types, including the zero-byte stream
cases. It also passed isolated same-size offset and nested-data corruption
controls on each array stream. Full debug and release Crystal suites each
passed 495 examples with zero failures/errors, and the earlier pinned type
oracles passed. The independent W21 implementation review found no material
physical-format defect within this pinned scope. Reader checksum/hash
verification is still not a general guarantee against arbitrary same-size
corruption; the oracle's negative controls are narrower than that claim.

Rejected for W21: generic or nested `Array(T)`, Nullable arrays or elements,
Map/Tuple/Nested, `LowCardinality`, arbitrary key and table schemas, Compact
parts, other codecs/mark layouts, and a performance claim. The TUI renders
only bounded, escaped previews and rejects array equality filters. Catalog
`.values` owns its array/String copies and enforces its whole-call element
ceiling; direct lazy scans remain available. A selected table batch can still
materialize up to 16 individually bounded array columns, so worst-case GC
cost remains a performance risk. Risk: CAUTION because plausible offset/mark
bytes can produce silently shifted rows. Rollback is one W21-only local
feature commit; no existing ClickHouse data root is in scope. Evidence decays
with producer version, serializer/substream shape, or shared reader/writer
changes.

## Verified bounded slice W22: paired LowCardinality(String)

Admit exactly one non-null `LowCardinality(String)` payload beside the sorted
`UInt64` key in a Wide/LZ4 part. Return owned binary-safe `String` values to
Crystal callers, while retaining the exact declared type in metadata and
typed batch accessors. The writer may emit only a single shared dictionary
with the default empty key at ID 0 and other keys in first-seen order; the
reader must also recognize the observed stock
per-granule additional-keys shape. Neither is a generic LowCardinality
implementation. Catalog `.values` reuses its String-byte and row ceilings;
the TUI may show bounded escaped previews but must keep equality filtering
restricted to its existing exact scalar types.

The pinned ClickHouse 26.7.1.1315 producer uses two physical substreams,
`payload.dict` then `payload`, with `.bin` files and adaptive `.cmrk2` marks.
`serialization.json` has version 1, nested-version propagation, and
`types_serialization_versions: {"string": 1}`. Its UInt64 key serializer's
`num_defaults` is a data statistic, not a fixed format value: pinned stock
parts with and without a zero key produced 1 and 0 respectively. The
dictionary stream starts
with a little-endian UInt64 key-format version `1`; String keys are encoded
with VarUInt byte lengths followed by raw bytes. In the default shared form,
the dictionary stream then contains one count and the final keys. Its marks
start at decompressed offset 8, can repeat the same physical position for
multiple granules, and end at EOF. In the pinned small part, the zero-row
sentinel for all three streams addresses raw EOF within the final compressed
frame rather than the byte after that frame; the dictionary sentinel is
`(0, 36, 0)`. The index stream's first granule starts
with a little-endian UInt64 header `0x500` (UInt8 IDs, global dictionary,
update), subsequent granules with `0x100` (UInt8 IDs, same global dictionary),
then each has a UInt64 row count and one UInt8 ID per row. A nine-row stock
part at granularity three had index IDs `[0,0,1]`, `[2,3,2]`, `[4,5,0]` over
six binary-safe keys; all-empty and single-value parts kept the same form.

With `low_cardinality_max_dictionary_size=0` at process start, stock instead
writes per-granule `0x600` headers (UInt8 IDs, additional keys and update,
without global dictionary). Each granule embeds its local count/keys before
the row count and IDs, with the empty default key at local ID 0 even when
that granule has no empty rows. Its `.dict` stream still contains version 1 followed
by one empty/default dictionary record per mark, so a missing `.dict` stream
is not a valid shortcut. The observed stock part passed `CHECK TABLE`, sparse
range selection, and a binary String round-trip. These producer observations
alone do not certify a Crystal reader or handcrafted writer; the independent
bidirectional oracle is required.

Limit this slice to at most 256 dictionary keys per shared dictionary or
granule, at most 65,536 selected rows and 64 MiB of materialized String bytes
per mark, at most 65,536 marks per part, at most 64 MiB of decoded dictionary
bytes, and at most 64 MiB of aggregate decoded index bytes. Each compressed
substream is further bounded to 262,208 frames to prevent tiny-frame metadata
amplification. The writer must
preflight matching per-mark output, dictionary, and index limits before
publication.
The 256-key limit includes the reserved empty key even when input rows never
contain it (`ColumnUnique` reserves one non-nullable special value).
The reader must validate exact serializer metadata, stream presence, flag
sequence, dictionary/version framing, mark boundaries, row counts, ID ranges,
and trailing bytes. It must load the single shared dictionary before decoding
any selected range, rather than assuming a range starts with initialized
state. A LowCardinality-specific dictionary-mark parser may admit the observed
8-byte prefix offset; the generic stream-mark parser must not silently weaken
its first-mark invariant. Existing generic `.cmrk2` decompression can be
reused. The reader validates both entire bounded streams on first selected
read and caches that state for the immutable-part lifetime; later reads
reparse only selected marks. In-place mutation after that first read is not
detected by this cache. A typed table scan releases each part's cache after
that part is processed, including exceptional callback exits, so one table
scan does not retain all parts' decoded indices. Direct `WidePart` instances
retain their own caches until released or collected; this is a reachable-state
bound, not a guarantee that the GC immediately returns RSS to the OS.
Reader and writer changes remain separate from the transactional
`EmbeddedMergeTreeTable` validator.

The bidirectional falsifier is stock-to-Crystal full/key-range reads for both
observed UInt8 shapes and Crystal-to-stock `ATTACH PART`, full/key-range
RowBinary, and `CHECK TABLE` for the writer's shared form. Include empty and
repeated strings across marks, embedded zero/invalid UTF-8 bytes, a short
last granule, and same-size mutations of dictionary or ID streams. A
self-readback alone cannot certify stock compatibility.

Rejected for W22: UInt16/32/64 ID widths, more than 256 keys, mid-part global
dictionary updates/resets, mixed global/additional-key flags, Nullable or
nested LowCardinality, generic Array/Map/Tuple, Compact parts, non-LZ4 codecs,
other serializer versions, arbitrary key/table schemas, and a performance
claim. Risk: CAUTION because plausible but incorrect dictionary state can
silently relabel rows. Rollback is one W22-only local feature commit, with no
push or mutation of an existing ClickHouse data root. Evidence decays with
producer version, serializer flags, dictionary/mark shape, or shared stream
reader/writer changes.

W22 evidence at the implementation diff atop W21 commit `62e501b`: the full
debug and release Crystal suites each passed 513 examples. All 16 pinned
stock/Crystal oracle scripts passed. The W22 oracle compared exact stock
shared and per-granule dictionary bytes and marks, Crystal full and keyed
reads, and RowBinary results; a Crystal-written shared-dictionary part
attached to ClickHouse 26.7.1.1315, returned exact full/key-range rows, and
passed `CHECK TABLE`. Oracle mutations without checksum repair demonstrate
ClickHouse checksum detection; Crystal specs with recomputed checksums
separately reject malformed dictionary versions, flags, IDs, marks, and
trailing bytes. Focused specs also reject over-limit dictionary/index mark
files before mark-array allocation and prove table-cache release after both
successful and exceptional scans. Formatting, shell syntax, and diff checks
passed. The adversarial memory finding was resolved by per-part scan-cache
release and the existing exactly-two-column schema gate: each admitted part
has only one LC payload. This does not certify general LC shapes, a daemon
restart path, a performance gain, or immediate GC/RSS reclamation.

## Verified bounded slice W23: paired Tuple(a UInt64, b String)

Admit exactly one non-null `Tuple(a UInt64, b String)` payload beside a sorted
`UInt64` key in Wide/LZ4 parts. A Crystal row is a typed two-element tuple;
the reader and writer must preserve the UInt64 value and binary String bytes
without flattening the payload into two public table columns. The offline
catalog exposes the tuple through `.values`; TUI Tuple display and filtering
remain guard-only. This slice does not widen the embedded transactional table
schema.

Pinned ClickHouse 26.7.1.1315 produced a Wide part with substreams `id`,
`payload%2Ea`, `payload%2Eb.size`, and `payload%2Eb` for named elements
`a UInt64` and `b String`. The initial probe used unsupported legacy `.mrk`
marks. The retained public fixture uses four independent `.mrk2` streams,
LZ4, exact stock `columns.txt`, `columns_substreams.txt`, and version-1
`serialization.json` with per-child default statistics. Its generator pins
the producer version, refuses fixture replacement, and checks an exact
stream-data digest; a fresh isolated generation reproduced that digest.
Unfamiliar Tuple grammars and metadata fail closed.

The first focused reader and writer tests were RED before production changes.
The reader, batch/catalog propagation, and named paired writer API compose
the existing UInt64 and String leaf codecs with independent marks. The
bidirectional falsifier passed: exact positional and sparse stock-to-Crystal
reads, then Crystal-to-stock `ATTACH PART`, full and keyed RowBinary bytes,
and `CHECK TABLE`, including embedded NUL/invalid UTF-8, all-empty String
values, multiple marks, and a short final granule. Negative tests reject
alternate type spelling, unexpected serializer fields, mis-escaped
substreams, same-size child mark row-count mutation, invalid writer names,
and unsorted keys before value exposure or publication. A self-readback alone
was not used to certify stock compatibility. Risk remains CAUTION because a
new serialization shape could produce plausible but incorrect rows. Rollback
is one W23-only local feature commit; no push or writes into an existing
server data root. Evidence decays on producer version, format, codec,
platform, or reader/writer changes.

W23 evidence at the implementation diff atop `02df34e`: the full debug and
release Crystal suites each passed 521 examples; all 17 pinned stock/Crystal
oracle scripts passed, including the dedicated Tuple writer oracle with a
zero-byte all-empty String stream. The fixture generator reproduced its
saved stream digest in a fresh temporary directory. Crystal format, shell
syntax, and diff checks passed. The adversarial same-size mark mutation is
detected before selected values are returned. Within the exact named
Tuple/UInt64-key/Wide-LZ4/Darwin/pinned-build scope, the adversary verdict
is ROBUST; it is not a claim of general Tuple support or a speed gain.

Guard-only after W23: unnamed or differently typed Tuple elements, nested
Tuple/Array/Map combinations, Nullable(Tuple), Map and Nested layouts,
general JSON writer parity, TUI Tuple display/filtering, Compact parts, and
performance claims. At W23, the JSON scalar-path reader did not yet imply a
compatible Object V3 writer; W24 adds one exact writer shape.

## Verified bounded slice W24: one JSON typed-path writer

Admit `WidePartWriter.write_uint64_json_typed_a_uint64_b_string_pair` for the
exact `JSON(a UInt64, b String)` payload beside a sorted `UInt64` key. The
input is an array of positional `{UInt64, String}` path values, including
ClickHouse's defaults for absent declared paths. It does not accept arbitrary
JSON documents, dynamic keys, or nonempty shared data. The existing reader
still exposes only declared scalar virtual paths,
not a whole-document API. W24's writer emits the Object V3 structure, the
two typed paths, and all three required empty shared-data streams, each with
its own plain adaptive marks. See `JSON_TYPED_PATH_FRONTIER.md` for the exact
physical target and evidence.

The focused spec was RED before the API existed. Its staged checks cover
exact file and checksum inventory, all stream bytes and marks, primary index,
metadata, all-empty String, short final granule, and invalid-input refusal
before publication. The first stock `CHECK TABLE` caught a missing
`object_structure.mrk2` checksum record that self-readback and `ATTACH PART`
had not exposed. After adding the record and exact manifest validation, the
pinned ClickHouse 26.7.1.1315 oracle passed `ATTACH PART`, full/key-range
typed-path RowBinary, normalized whole-object JSONEachRow, and `CHECK TABLE`
for mixed and all-empty String parts. Full debug/release suites each passed
524 examples; all 18 pinned oracle scripts, fixture shape, formatter, shell
syntax, and diff checks passed at the implementation diff atop `6be7716`.

Risk remains CAUTION; rollback is one W24-only local feature commit. The
hostile verdict is **ROBUST** only for this exact schema, pinned build,
Wide/LZ4/plain-adaptive-mark settings, and tested inputs. No byte-for-byte
canonical stock-part identity is claimed. Evidence decays when the producer
version, Object serialization, codec/mark settings, or writer/reader changes.
General JSON, dynamic/shared values, other typed-path schemas, recursive
types, MV/projections, Compact parts, and performance remain guard-only.

## Verified bounded slice W25: paired Map(UInt64, String)

Admit one exact top-level `Map(UInt64, String)` payload beside a sorted
`UInt64` key in the existing Wide/LZ4/plain-adaptive-mark part layout. The
public Crystal value is an ordered `Array(Tuple(UInt64, String))`; a `Hash`
would lose duplicate keys and entry order. The stock part establishes four
independent Map substreams: per-row `size0` entry counts, flattened UInt64
keys, flattened String byte lengths, and concatenated String bytes. The
reader exposes a bounded mark-range API, typed batches, and catalog-owned
`.values`; the writer publishes an immutable part after staged checks.

The retained stock fixture tests empty maps, duplicate keys, NUL and UTF-8
bytes, a short final granule, and nonzero later-mark reads. Focused negative
tests reject other Map spellings, unsupported nested serializer versions,
malformed marks, conflicting child counts, and over-limit entries or bytes.
The pinned ClickHouse writer oracle attaches Crystal parts, compares exact
full and key-range direct Map RowBinary, checks `mapKeys`/`mapValues`, and
runs `CHECK TABLE`. Separate all-empty Map and all-empty String-value parts
guard zero-byte nested streams. Self-readback is an additional integration
check, not the stock compatibility certificate. The original fixture SQL
was not retained; its snapshot has a SHA-256 manifest and byte-for-byte
stock-part comparison, not a from-scratch regeneration claim.

The hostile reader pass found that common metadata loading accepted symlinks
to files outside the part. A RED regression test reproduced acceptance;
explicit symlink guards now cover `columns.txt`, `columns_substreams.txt`,
`default_compression_codec.txt`, and `count.txt`, consistently with the
existing stream/checksum/serialization guards. This is a static path check,
not a claim of safety against concurrent directory mutation.

At the W25 implementation diff atop `dbf306d`, full debug and release suites
each pass 533 examples; all 19 pinned stock-oracle scripts pass. The Map
fixture matches the captured stock part file set and bytes, and formatting,
shell syntax, and diff checks pass. The hostile verdict is **ROBUST** only
within the exact type, pinned ClickHouse 26.7.1.1315, Wide/LZ4/mark settings,
and tested inputs. Risk is CAUTION; rollback is one W25-only local feature
commit, with no push or mutation of a live ClickHouse root. Evidence decays
with producer version, serializer or mark layout, codec, platform, or shared
reader/writer changes. General Map/Nested compositions, MV, projections,
Compact parts, and performance remain guard-only.

## Verified bounded slice W26: paired Map(UInt64, UInt64)

Admit exactly `Map(UInt64, UInt64)` beside one sorted `UInt64` key in the
pinned Wide/LZ4/plain-adaptive-mark format. The stock-produced part has three
Map streams: per-row `size0` counts and flattened UInt64 keys and values.
The public ordered `Array(Tuple(UInt64, UInt64))` preserves duplicate keys,
zero and maximum values, and entry order. The reader exposes full and bounded
mark ranges, typed batches, and caller-owned offline catalog `.values`; the
writer validates a staged part before exclusive publication.

The retained seven-row stock fixture pins physical streams, marks, checksum
inventory, and bytes against its original stock part. Crystal-produced mixed,
all-empty, and empty-middle-granule parts pass stock `ATTACH PART`, exact
RowBinary reads, and `CHECK TABLE`; full and key-range mixed reads also match
`mapKeys` and `mapValues`. A RED test caught an aggregate materialization
preflight that counted only one 8-byte child; the corrected bound counts both
flattened children, 16 bytes per entry. A malformed child-mark control and
the stock oracle challenge silent key/value misalignment.

At the W26 implementation diff atop `e92c4d0`, full debug and release suites
each pass 542 examples; all 20 pinned stock-oracle scripts pass. Fixture
identity, format, shell syntax, and diff checks pass. The hostile verdict is
**ROBUST** only within this exact type, ClickHouse 26.7.1.1315, pinned
Wide/LZ4/mark settings, and tested inputs. Risk is CAUTION; rollback is one
W26-only local feature commit, with no live ClickHouse-root mutation or push.
Evidence decays with a different stock build, serialization/mark layout,
codec, platform, or shared reader/writer changes. General recursive Map or
Nested compositions, MV, projections, Compact parts, and performance remain
guard-only. The implementation order above keeps type parity and MV/projection
work ahead of performance tuning.

## Verified W27 slice: Array of nullable UInt64

W27 admits exactly `Array(Nullable(UInt64))` beside a sorted `UInt64` key, with
paired bounded-mark reading, typed batch and offline-catalog values, and
immutable part writing. Keep `Array(UInt64)` and `Array(String)` behavior
unchanged. A bounded Array child-stream plan may share their physical stream
inventory, but must not make arbitrary `Array(T)`, `Nullable(Array(T))`,
recursive Map/Tuple/Nested, or alternate type spellings publicly admissible.

The pinned ClickHouse 26.7.1.1315 Wide/LZ4 physical probe produced three
payload streams: outer `payload.size0`, flattened `payload.null`, and
flattened `payload`. This matches the local ClickHouse source's composition
of Array and Nullable serializers. In particular, a zero-length outer
array contributes no nullable child elements, and child stream marks must
stay aligned to the flattened count across empty and nonempty outer marks.

The discriminating RED case has an empty-array mark followed by nonempty
arrays containing both `NULL` and `0`, plus a maximum `UInt64` value. It
distinguishes a null bit from the nested zero slot and rejects a shifted
null/value child mark even if total byte counts still match. Admission required
stock-produced full and later-mark reads; Crystal-produced stock `ATTACH
PART`, exact full and key-range values, and `CHECK TABLE`; debug and release
specs; and all prior stock oracles. The stock input is pinned by
`test/fixtures/public/wide_array_nullable_uint64/SHA256SUMS` and the
bidirectional producer gate is `scripts/check_array_nullable_uint64_oracle.sh`.
A self-readback alone is insufficient.
The probe's `serialization.json` records `kind=Default` and one default
`pk` row because `pk=0`: ClickHouse's `SerializationInfo::Data::add` in
`src/DataTypes/Serializations/SerializationInfo.cpp` counts default-valued
rows for choosing a serializer, rather than omitting physical bytes. W27
accepts a bounded Default count in `[0, num_rows]` with the unchanged physical
key stream and rejects Sparse/unknown kinds; tests cover both the valid
nonzero count and out-of-range or wrong-kind counterexamples.

Risk is CAUTION: wrong flattened-child alignment can silently pair the wrong
null flag with a value. Rollback is a W27-only local feature commit; the
stock probe uses a disposable directory and no live ClickHouse root. Claims
decay with producer build, serializer or mark layout, codec, filesystem, or
shared reader/writer changes. MV/projections and performance stay guard-only.

At the W27 implementation diff atop `2f277b5`, the stock fixture's 16 part
files match the original stock-produced part byte-for-byte. The reader tests
cover exact child streams and marks, a later-mark range, typed batches, and
offline-catalog caller-owned values. Same-size shifted child marks, invalid
null bytes, oversized outer sizes, out-of-range Default statistics, and Sparse
serializer metadata are rejected. Selected-entry checksum validation is
size-only, so the shifted-mark control also exercises structural validation;
only the stock `CHECK TABLE` gate checks the complete part checksums.

The bidirectional oracle passes stock-produced reads and Crystal-produced
mixed, all-empty, and empty-middle-granule parts through ClickHouse `ATTACH
PART`, exact full/key-range RowBinary results, and `CHECK TABLE`. Full debug
and release suites each pass 548 examples; all 21 pinned stock-oracle scripts
pass. The adversarial verdict is **ROBUST** only for the exact type, pinned
ClickHouse 26.7.1.1315 build, Wide/LZ4/plain-mark settings, and exercised
inputs. This does not establish byte-identical serializer statistics, generic
recursive types, Compact parts, MV, projections, or performance parity.

## Admitted W28 slice: two-level UInt64 arrays

Admit only `Array(Array(UInt64))` beside a sorted `UInt64` key in the pinned
Wide/LZ4/plain-adaptive-mark layout. The public value is an ordered array of
ordered UInt64 arrays per row. Do not infer general recursive Array support,
`Nullable` at either level, other leaf types, or a writable catalog from this
one spelling. Reading, typed batch materialization, offline catalog `.values`,
and immutable part writing must agree on that exact shape.

The local ClickHouse `SerializationArray::enumerateStreams` contributes a
named `sizeN` stream at each nesting level, then descends to its child. A
stock-produced probe must confirm the physical stream names, that `size0`
counts inner arrays per outer row, that `size1` counts UInt64 leaves per inner
array, and that all three streams' marks advance in outer-row granules.
The discriminating stock fixture has empty outer arrays, empty inner arrays,
`0`, `UInt64::MAX`, multiple marks, and a zero-leaf final mark. A separate
Crystal-writer case must place a zero-leaf mark between nonempty leaf marks.
An incorrect `size1` boundary can produce plausible total counts but attach
the wrong inner array to a row; a same-size shifted mark is the primary
negative control. A zero-leaf middle mark checks the writer's compressed-frame
offset handling without conflating empty outer and empty inner arrays.

The DoD is: a pinned ClickHouse-produced fixture read exactly at full and
later-mark ranges; a Crystal-written mixed, all-empty, and empty-middle-mark
part accepted by stock `ATTACH PART`, exact full and key-range RowBinary, and
`CHECK TABLE`; debug and release specs; all earlier stock oracles; and a
focused adversarial check of counts, mark alignment, and unsupported type
admission. Crystal self-readback alone does not prove wire compatibility.
The observed gate on ClickHouse 26.7.1.1315 passed: the 16-file synthetic
stock fixture was regenerated byte-for-byte, the bidirectional W28 oracle
passed all listed part shapes and checks, all 22 oracle scripts passed,
and both debug and release suites passed 554 examples each. The shifted
`size1` mark was rejected before any batch callback; an oversized leaf count
was rejected before leaf allocation; over-limit writer input published no
part. The decoded three-stream byte count is recomputed and compared with
the preflight count before a batch is exposed. This makes the exact W28 scope
robust against the tested mark/count failure modes, not against untested
serializer variants.
Risk is **CAUTION** because a second offsets level can silently change nested
row grouping. Rollback is one W28-only local feature commit. The stock probe
uses a disposable store, not a live ClickHouse root. Evidence will decay when
the producer build, serializer/mark layout, codec, filesystem, or shared
reader/writer changes. MV, projections, Compact parts, and performance remain
guard-only, in that order after type completion.

## Admitted W29 slice: nested nullable UInt64 arrays

Admit exactly `Array(Array(Nullable(UInt64)))` beside a sorted `UInt64` key
in the pinned Wide/LZ4/plain-adaptive-mark layout, and keep every other new
composition rejected. Reading, typed batch materialization, offline catalog
`.values`, and immutable part writing must agree on ordered outer arrays,
ordered inner arrays, and nullable UInt64 leaves. No generic recursive-type
support is claimed by admitting this one spelling.

The pinned ClickHouse 26.7.1.1315 stock probe produced four payload streams,
`payload.size0`, `payload.size1`, `payload.null`, and `payload`; `CHECK TABLE`
passed. `size0` counts inner arrays per row, `size1` counts leaf slots per
inner array, and the null map has one byte per leaf slot, including nulls.
Each stream must advance by the same outer-row mark boundaries, including
zero-leaf marks. A malformed same-size shifted `size1` or null-map mark must
fail before a typed batch is exposed; equal total counts do not establish
correct row grouping. A null leaf must not be decoded as the UInt64 zero
stored in the non-null value stream.

The RED fixture and tests must distinguish empty outer arrays, empty inner
arrays, null leaves, zero, `UInt64::MAX`, multiple marks, and a short final
mark. The writer must additionally produce all-empty and empty-middle-mark
parts. The DoD is a stock-produced fixture read at full and later-mark
ranges; Crystal-produced parts accepted by stock `ATTACH PART`, exact full
and key-range RowBinary, and `CHECK TABLE`; debug and release specs; all
earlier stock-oracle scripts; and a hostile count/mark/unsupported-admission
review. A passing self-readback alone is not wire compatibility.

Risk is **CAUTION**: a shifted null map can silently attach nulls to the
wrong leaves or rows. The guard is preflight count/mark alignment before any
batch callback, plus the shifted-mark negative controls. Rollback is the
single W29 feature commit, with no change to existing part files. A small
recursive physical-stream descriptor may replace duplicated name lists if
the current admitted array forms retain identical stream inventories and
strict admission remains unchanged. A general recursive value codec or
unbounded parser is guard-only until independently tested. The stock probe
uses a disposable store. Evidence decays when the ClickHouse producer build,
serializer/mark layout, codec, filesystem, or shared reader/writer changes.
The observed gate on ClickHouse 26.7.1.1315 passed: the 18-file synthetic
stock fixture regenerated byte-for-byte; the bidirectional W29 oracle passed
stock reads plus Crystal-written mixed, all-empty, and empty-middle parts
through `ATTACH PART`, exact RowBinary, and `CHECK TABLE`; all 23 stock-oracle
scripts passed; debug and release suites each passed 561 examples. Same-total
shifted `size1` and `.null` mark boundaries were rejected before any table
callback, oversized leaf counts were rejected before materialization or
publication, and a malformed null-map byte was rejected. The hostile verdict
is **ROBUST** only for this exact shape and the pinned Wide/LZ4/plain-mark
profile. General recursive codecs, MV, projections, Compact parts, and
performance remain outside this slice.

## Completed slice W30: single-level numeric Array family

W30 admits paired `Array(T)` only for the existing fixed-width primitive numeric
leaves `T`: `UInt8/16/32/64`, `Int8/16/32/64`, and `Float32/64`. A sealed
leaf dispatch selects the canonical type, width, and exact substreams. It
does not parse or admit arbitrary recursive types. Existing `Array(UInt64)`
behavior remains unchanged while moving onto the common path; existing
`Array(Nullable(UInt64))` and nested Array support did not regress. Other
nullable Array leaves are a separate W31 candidate. String/semantic leaves,
new nested Arrays, JSON, Map, Tuple, Variant, and MV/projections remain
outside W30.

The physical streams are `payload.size0` plus `payload`, confirmed by the
stock-produced fixture. It verifies stream inventory, mark alignment, and
values for every admitted spelling, including empty arrays, an empty middle
row, an all-empty final mark, integer extrema, finite float boundaries, and
NaN payload handling. A shifted value mark and a declared leaf-width mismatch
are rejected before a typed batch is published. The writer rejects oversized
arrays before publishing a part.

Risk is **CAUTION** because a shared dispatch can silently decode the wrong
width or associate elements with the wrong row. Rollback is the W30-only
feature commit; neither existing part bytes nor live ClickHouse directories
were mutated. The DoD passed: the pinned stock 26.7.1.1315 fixture reads at
full and later-mark ranges, all ten Crystal-written shapes pass stock
`ATTACH PART`, exact full/key-range RowBinary, and `CHECK TABLE`; mark-offset
and width mismatch controls fail closed before a typed batch is published;
debug and release suites each pass 568 examples; and all 24 stock-oracle
scripts pass. The adversary verdict is **ROBUST within the admitted profile**:
exact one-level numeric leaves in Wide/LZ4/plain-mark parts. This does not
establish compatibility for other serializer layouts, nullable leaves,
arbitrary recursive Arrays, MV, projections, or Compact parts. Evidence
decays when the producer build, serializer/mark layout, codec, filesystem,
or shared reader/writer changes. No memory or throughput optimization was
admitted in this slice.

## Admitted W31 slice: nullable numeric Array leaves

W31 extends the paired one-level Array contract to `Array(Nullable(T))` for
the ten primitive numeric leaves already admitted by W30: `UInt8/16/32/64`,
`Int8/16/32/64`, and `Float32/64`. The existing exact
`Array(Nullable(UInt64))` contract remains valid. This is a closed leaf family,
not a recursive grammar: `Nullable(Array(T))`, other nested nullable Arrays,
semantic/Decimal/String leaves, and alternate type spellings remain outside
this slice. Public reader, typed-batch, offline-catalog, and immutable-writer
values must agree; nulls must not be conflated with numeric zero or floating
point payload bits.

The pinned ClickHouse 26.7.1.1315 Wide/LZ4/plain-marks disposable producer
confirmed the same three streams for all ten leaves: `<name>.size0`,
`<name>.null`, and `<name>`. Its 11-row probe had six granules and a sentinel
mark in every stream. Two all-empty granules left child offsets unchanged;
an all-null granule advanced both child streams by three flattened slots,
with zero-valued nested placeholders. Float32/64 `-0`, `+0`, NaN payloads,
infinities, and subnormals retained their raw bits. The producer's
`serialization.json` used `columns:[]`; `CHECK TABLE` passed. This probe
establishes the physical hypothesis only; durable fixture identity and the
bidirectional reader/writer oracle remain W31 acceptance gates. The
falsifier fixture must mix empty arrays, `NULL`,
zero, integer extrema, and floating-point signed zero, infinities, and a NaN
payload. It must include an empty middle mark and a later selected mark. A
same-total shifted child mark, malformed null-map byte, declared width
mismatch, and oversized element count must fail before any typed batch or
part publication. Floating-point comparisons use raw bits for non-null
values. An all-null row does not waive the child's physical-slot or mark
requirements.

Admission requires both directions of the stock oracle: read stock-produced
parts through full and later-mark ranges; then attach Crystal-produced parts
to stock ClickHouse and compare exact full/key-range RowBinary plus `CHECK
TABLE`. Confirm selected typed batches and caller-owned catalog values, run
debug and release specs, and retain all prior pinned stock-oracle passes.
Reader self-readback alone cannot establish compatibility. The strongest
failure mode is shifted flattened null/value alignment that still has the
correct total byte count; the controls above target that case. Risk is
**CAUTION** because this widens common Array dispatch and serialization.
Rollback is one W31-only local feature commit; no live ClickHouse root or
existing part is mutated. Evidence will decay with a changed stock build,
serializer/mark layout, codec, filesystem, or shared reader/writer logic.
MV/projections and performance work remain deferred until type parity.

Observed W31 gate on this host: the fixture verifier checked its SHA-256
manifest, exact 11-column schema, 31 physical streams, six data marks, and
sentinels; the W31 focused spec passed 6/6, including byte-level stream
checks, later-mark reads, typed batches, catalog ownership, a mixed-schema
rejection, and corrupt null/mark/width/count negatives before callbacks. The
pinned stock oracle passed attachment and `CHECK TABLE` for the stock part and
all ten Crystal-written two-column parts, with exact full/key-range RowBinary
including floating-point payload bits. Debug and release suites each passed
574 examples, and all 25 stock-oracle scripts passed. Adversary verdict:
**ROBUST within this pinned profile**. This is not arbitrary table-schema or
serializer compatibility; populated TUI display of W31 arrays, further type
compositions, MV/projections, Compact parts, other codecs/platforms, and
performance remain unverified or guard-only.

## Design-sealed W32 slice: nullable String Array leaves

W32 targets exactly one `Array(Nullable(String))` payload beside a sorted
`UInt64` key. It composes the existing Array outer-row and String child-size
contracts with a flattened null map, but must not infer compatibility from
those components alone. A disposable stock ClickHouse 26.7.1.1315 Wide/LZ4/
plain-marks probe observed four physical streams: `<name>.size0`,
`<name>.null`, `<name>.size`, and `<name>`. Its `serialization.json` has the
`string` version and no separate `nullable` version. In the probe, each NULL
element consumed a zero-valued nested String-size slot but no raw String bytes;
all-NULL and all-present-empty marks had identical size/raw offsets and differed
only in the null map. This is a stock-writer observation, not a decoder
restriction: ClickHouse `SerializationNullable` serializes and deserializes
the nested column independently of the null map, so a nonzero physical String
slot beneath NULL must still be consumed while the visible value remains NULL.
The probe alone did not admit a reader or writer; the gate below does.

Admission requires a pinned stock part containing empty arrays, all-NULL and
all-empty-string marks, mixed NULL/empty/nonempty values, embedded NUL and
non-ASCII bytes, an empty middle mark, and a short final mark. Each child
stream must agree with the outer row marks and flattened element counts;
`NULL` must consume its physical String-size and raw-byte slots without being
confused with `""`. The reader, typed batch, caller-owned offline catalog
values, and immutable writer must agree on full and later-mark ranges. The
writer must publish no part until staged readback, selected checksums, and
mark/size bounds pass. A bidirectional oracle must read the stock part and
attach Crystal-written parts to the pinned stock build, comparing exact full
and key-range RowBinary plus `CHECK TABLE`.

Falsifiers include an invalid null flag, same-total shifted child marks,
string-size/raw-byte disagreement, malformed physical slots under NULL, and
oversized element or byte counts. Direct reader assertions must distinguish
structural rejection from table-level `checksums.txt` rejection; selected
table scans must reject before callbacks. Risk is **CAUTION** because this
widens common Array dispatch and four-stream serialization. Rollback is one
W32-only local feature commit. Arbitrary recursive types, schema composition,
other codecs/marks/platforms, populated TUI display, MV/projections, and
performance remain guard-only. The gate requires focused, debug, release,
and pinned stock-oracle passes. Evidence decays with a changed stock build,
serialization, codec/mark layout, filesystem, or shared reader/writer
implementation.

The table batch preflight charges physical nested String bytes plus fixed
allowances per flattened nullable slot and outer row. This is an estimated
retained-output budget, not a strict peak-RSS bound: decoding can temporarily
hold both the raw stream buffer and copied visible Strings. Tight peak-memory
accounting belongs to the later optimization phase and must not silently
reject otherwise compatible large String payloads here.

Observed W32 gate on this host: the pinned fixture verifier checked the exact
two-column schema, five physical streams including the key, six data marks
and sentinel, raw null/size/value bytes, and its SHA-256 manifest. The
focused W32 spec passed 7/7: exact type admission; stock full/later-mark
reads; typed batch and catalog ownership; writer stream/readback equivalence;
a checksum-updated positive with a nonzero nested String byte beneath NULL;
and checksum-updated invalid-null and shifted-mark rejections before table
callbacks. The pinned ClickHouse 26.7.1.1315 oracle attached both the stock
and Crystal-written parts, passed `CHECK TABLE`, and matched independently
encoded full/key-range RowBinary. Debug and release regression suites passed
581 examples each, and all 26 stock-oracle scripts passed. Adversary verdict:
**ROBUST within this pinned physical/API profile**, with the estimated
retained-output versus peak-memory caveat above. This is not a general
recursive Array, schema-composition, TUI, MV/projection, codec, platform, or
performance claim.

## Verified W33 slice: FixedString Array leaf family

W33 targets both `Array(FixedString(N))` and
`Array(Nullable(FixedString(N)))` for canonical widths accepted by the
existing scalar `FixedString(N)` contract. A sorted `UInt64` key remains the
only writer key. Public values are arrays of byte-preserving `String` or
`String?` elements; non-null values are padded to exactly N bytes as in the
scalar contract. Nullness must not be inferred from zero-filled bytes.

A disposable pinned ClickHouse 26.7.1.1315 Wide/LZ4/plain-mark probe of both
shapes confirmed `payload.size0` and `payload` for the non-null form; the
nullable form adds `payload.null`. With N=3 and 11 rows at granularity 2,
each stream had six data marks and a sentinel. Child byte offsets were
`[0, 3, 12, 12, 18, 21, 24]` in both forms; nullable null-map offsets were
`[0, 1, 4, 4, 6, 8, 9]`. Thus NULL still occupies an N-byte child slot and
an empty middle granule repeats child offsets. The stock fixtures retain both
observed serialization variants: an empty serializer list and a `Default`
serializer for the `UInt64` key. A nonzero hidden slot under NULL is tested
as a reader-only positive control; stock acceptance of that mutated part is
not claimed.

Admission requires exact type parsing and stream inventory for canonical N,
bounded full and later-mark reads, typed batches, owned offline catalog
values, immutable writing, and stock `ATTACH PART`, full/key-range RowBinary,
and `CHECK TABLE` in both directions. Falsifiers: N of zero or noncanonical
spelling, wrong child width, missing/shifted marks with unchanged totals,
invalid null flags, NULL versus zero-padded non-NULL confusion, oversized
flattened count or byte size, and a writer failure that publishes a part.
The strongest risk is a wrong flattened-element alignment that yields
plausible row values while crossing a mark boundary; the selected-scan guard
must reject such corruption before callbacks.

Risk is **CAUTION** because a parameterized nested serializer widens the
reader, table, catalog, and writer contract. Rollback is one W33-only local
feature commit; no live ClickHouse data directory or existing part is
modified. A red 4097-row all-empty `FixedString(16384)` case exposed an
incorrect child-stream row cap: marks count outer rows, not flattened child
elements. W33 child marks now use the eight-byte `size0` row width for this
cap while retaining their physical-width alignment, frame, exact-byte, and
sentinel guards; scalar FixedString and all other types keep their prior cap.

The pinned stock fixture verifier checks both serializer variants, exact
stream inventories, marks, binary values, NULL slots, and SHA256 manifests.
The W33 oracle attaches both stock parts and both Crystal writer forms,
including all-empty plain and nullable arrays at N=4; stock `CHECK TABLE`
and exact full/key-range RowBinary comparisons pass for each. The 4097-row
all-empty N=16384 case passes writer/self-reader validation but has no
separate stock attach check. Over-width input is rejected without publishing
a destination or leaving staging files; injected staged-failure cleanup is
not separately tested. Focused W33 is 12/12; full debug and release suites
are 593/593 each. Five adjacent stock oracles
(scalar FixedString, nullable scalar FixedString, nullable String arrays,
numeric arrays, and nullable numeric arrays) also pass. These observations
support **ROBUST within the pinned Wide/LZ4/plain-mark and exact-schema
profile**; they do not establish arbitrary recursive types, schemas, MV or
projections, other codecs/marks/platforms, or performance parity. Evidence
decays with a changed stock build, serialization or mark layout, filesystem,
or shared reader/writer implementation.

## Verified W34 slice: Bool Array leaf family

W34 targets exactly `Array(Bool)` and `Array(Nullable(Bool))` beside the
existing sorted `UInt64` writer key. Public elements are `Bool` or `Bool?`,
not numeric `UInt8` aliases. The physical child value stream uses one byte
per flattened element; the nullable form also has a one-byte null-map
stream. Each row's `size0` offset and every child mark must remain aligned
across empty and nonempty granules. A visible value byte must be 0 or 1;
nullness comes only from the null map. A hidden value byte beneath NULL is
consumed but is not interpreted as a `Bool`, matching the scalar Nullable
contract. Writer output uses canonical 0 for NULL placeholders.

Admission requires exact type and stream validation, bounded full and
later-mark reads, typed table batches, owned offline-catalog values,
immutable writing, and a pinned stock ClickHouse oracle in both directions:
`ATTACH PART`, `CHECK TABLE`, and independently encoded full and key-range
RowBinary. A falsifier must reject a checksum-updated visible child byte of
2 or 255, an invalid null flag, a shifted child mark, and any writer failure
that publishes a destination. The strongest risk is conflating semantic
`Bool` with numeric `UInt8`, silently widening generic numeric or JSON
paths or accepting out-of-domain bytes. W34 must use exact Bool-array
admission and preserve all existing scalar and numeric-array gates.

Risk is **CAUTION** because this changes nested type admission and the
reader/table/catalog/writer contract. Rollback is one W34-only local
feature commit. No existing part or live ClickHouse data directory was
modified.

The pinned ClickHouse 26.7.1.1315 probe produced both exact array types in
one 13-row, three-column Wide part with seven data marks plus an EOF
sentinel. Both observed serializer forms (empty list and `Default` key)
have verified manifests, checksums, logical streams, one-byte Bool/null
values, and mark offsets. The focused W34 spec passed 12/12, including
checksum-updated visible bytes 2/255, invalid null flags, shifted marks,
hidden invalid bytes beneath NULL, owned catalog values, no-publication on
writer input rejection, and 4,097 all-empty rows at one row per mark for
both shapes. Full debug and release suites passed 605/605 each.

The bidirectional stock oracle attached both stock fixtures and both
Crystal writer parts; all four passed `CHECK TABLE` and exact full/key-range
RowBinary comparisons with independent expected-byte encoding. Four
adjacent stock oracles (scalar Bool/Enum/Decimal, numeric Array, nullable
numeric Array, and FixedString Array) also passed. An additional direct
ClickHouse check attached both 4,097-row all-empty Crystal parts, passed
`CHECK TABLE`, and returned 4,097 rows with no nonempty arrays. Hostile
review found no P0/P1/P2 issue after the catalog row-value union and oracle
encoder corrections: **ROBUST within the exact pinned Wide/LZ4/plain-mark
and schema profile**. Earlier valid-mark callbacks can precede a later
corrupt mark; scans are not transactional across marks. This evidence does
not establish arbitrary nested semantic types, other schemas/codecs/marks,
MV/projections, other ClickHouse builds, or performance parity. It decays
if the stock build, serialization/mark layout, platform, or shared
reader/writer implementation changes.

## Verified W35 slice: raw 128-bit integer scalar payloads

Admit exactly bare `Int128` and `UInt128` scalar payload columns beside the
existing sorted `UInt64` key, in the pinned Wide/LZ4/plain-mark profile.
Their physical values are fixed 16-byte little-endian integers; `Int128`
uses two's-complement bits. The public reader, table-batch, catalog-row,
and writer contracts must retain the signed/unsigned distinction and the
exact `columns.txt` type. A stock part containing both payloads and separate
Crystal-written key/payload pairs provide the two compatibility directions.

W35 alone did not admit `Nullable(Int128)` or `Nullable(UInt128)`; W36 admits
them separately below. Neither slice admits their Array forms, 256-bit
integers, an Int128 primary key, or generic writer inference of `Int128`.
The last restriction preserves the earlier requirement that an
unscaled `Int128` slice must not silently become `Decimal(38, S)`. Exact
raw-type entry points are required; neither `Decimal128` nor another 16-byte
semantic type may be accepted through them. In particular, the shared
numeric Array predicate and generic `open_numeric`/numeric accessor routes
must not be widened as a side effect of scalar admission. The stock
`serialization.json` may carry `Default` column entries with default-row
statistics; a `Sparse` serializer must be rejected rather than decoded as a
plain 16-byte stream. Those entries are matched by unique column name,
not by JSON order: ClickHouse can emit them lexicographically while
`columns.txt` retains schema order.

Risk is **CAUTION**: conflating raw `Int128` with Decimal128 or silently
opening nested/nullable dispatch could yield a part that self-reads but has
the wrong ClickHouse declaration. Rollback is one W35-only local feature
commit. The first falsifier is a focused RED spec for exact bare-scalar
admission while the Array/Nullable/Decimal aliases remain rejected. The
DoD is the focused spec, full debug and release suites, formatting and diff
checks, and pinned ClickHouse `ATTACH PART`, `CHECK TABLE`, and independently
encoded full/key-range RowBinary for both stock and Crystal-written parts.
The strongest counterexample is a boundary value above 64 bits or negative
`Int128` that round-trips in Crystal but fails the stock reader or has the
wrong signed interpretation, or a sparse-serializer metadata mutation that
reaches the plain decoder. No existing ClickHouse data root is a test
destination. Memory and throughput optimization stay deferred until types,
MV, and projections have their own admitted coverage.

The pinned ClickHouse 26.7.1.1315 fixture has 13 rows, seven data marks
plus the EOF sentinel, and exact `Int128` and `UInt128` columns in one Wide
part. Focused tests passed 10/10; the full debug and release suites each
passed 615/615 on the formatted final tree. The tests exercise signed and
unsigned endpoints, values above 64 bits, later-mark and row-window reads,
caller-owned catalog values, writer bytes and marks, Decimal128 alias
rejection, no-publication on invalid input, malformed-stream rejection before
the first callback, and strict serializer-name and `Sparse` guards. The
bidirectional stock oracle passed `ATTACH PART`, `CHECK TABLE`, and
independently encoded full/key-range RowBinary for the stock fixture and
both Crystal-written pair parts; it also detected same-size stream damage.
Adjacent Decimal128 and Decimal256 stock oracles passed after the shared
writer-path change. An adversarial stock part with `columns.txt` order
`zeta, unsigned, alpha` but lexical serializer order `alpha, unsigned,
zeta` read correctly, directly checking the name-matching fix. Hostile
review found no blocker: **ROBUST within the exact scalar-only pinned
profile**. The ClickHouse source checkout used for layout review
is at `4576ba3bfac` (26.6 development line), so the pinned 26.7.1.1315
binary and its actual parts, not that source revision, are the compatibility
authority. This is not evidence for arbitrary serializers, Nullable/Array
128-bit forms, Int256/UInt256, other schemas or part profiles, MV,
projections, or performance parity. The evidence decays if the stock build,
serialization/mark layout, platform, or shared reader/writer implementation
changes.

## Verified W36 slice: BASIC Nullable raw 128-bit integer payloads

Admit exactly `Nullable(Int128)` and `Nullable(UInt128)` payload columns
beside a sorted `UInt64` key in the pinned Wide/LZ4/plain-mark profile.
Expose separate exact raw reader, typed-batch, offline-catalog, and explicit
writer APIs. Do not infer either declaration from a nullable Crystal slice:
`Int128?` is also the Decimal128 backing representation. Generic numeric,
nullable-numeric, Array, and recursive admission remain unchanged; 256-bit
integers, primary keys of these types, and arbitrary serializer layouts are
still outside this slice.

A temporary stock ClickHouse 26.7.1.1315 probe produced a 32-row Wide part
with eight four-row data marks and one EOF sentinel. With BASIC nullable
serialization, each selected column has a `.null` byte stream (0=present,
1=NULL) and a fixed-width 16-byte-per-row payload stream; NULL payload slots
were zero-filled. `columns_substreams.txt` named exactly those two streams,
and `serialization.json` contained version 1, propagated nested versions,
`string:1`, and an empty `columns` list. A second stock probe with nullable
ALLOW_SPARSE selected Sparse column records, `nullable:1`, `.sparse.idx`
streams, and only non-null payload values. That layout must fail closed:
neither its index nor its shortened payload may be treated as BASIC nulls.
Serializer records, if present in an admitted BASIC part, must cover unique
exact column names with Default records; their JSON order is not schema
order. The 26.6 development source checkout is explanatory only; the pinned
26.7 binary and observed parts are the compatibility authority.

Risk is **CAUTION**: equal-width Decimal128 bytes can silently produce the
wrong declared type, and a Sparse nullable part can look plausible until a
later mark. Rollback is one W36-only local feature commit. The first
falsifier is a focused RED spec that rejects both nullable raw types before
implementation and keeps generic/Decimal/Array gates closed. DoD: exact
metadata and stream assertions, full and later-mark reads, bounded table and
catalog windows with owned values, invalid null-byte and Sparse rejection,
no destination publication on writer input failure, full debug and release
suites, formatting/diff checks, and a pinned stock oracle in both directions
using `ATTACH PART`, `CHECK TABLE`, and independently encoded full/key-range
RowBinary. The strongest counterexample is NULL followed by a >64-bit or
negative non-null value across a granule boundary that self-reads but stock
ClickHouse interprets differently. No existing ClickHouse data root is a
test destination; memory and speed tuning remain deferred.

Evidence at parent `05310ad` plus the W36 implementation diff on Crystal
1.21.0 and Darwin: the exact Nullable type gate first failed the focused
RED spec. The final W16/W35/W36 focused suite passed 26/26; full debug and
release suites each passed 626/626. Formatting, shell syntax, and diff
whitespace checks passed. The pinned ClickHouse local 26.7.1.1315 fixture
verifier checked the exact BASIC and Sparse layouts, mark rows, null maps,
payload bytes, and separate SHA256 provenance. The bidirectional oracle
attached and checked the stock BASIC part and both Crystal-written Nullable
parts, compared independently encoded full and key-range RowBinary, and
confirmed Crystal rejected the valid stock Sparse control. The raw integer
accessors rejected Decimal128 aliases; malformed explicit Nullable-version
metadata, invalid null-map bytes, duplicate/missing serializer names, and
generic writer inference were negative controls. Complete `Default`
serializer records in non-schema order were accepted by name, including an
explicit BASIC Nullable version 0. Independent hostile review returned
ROBUST within this bounded scope. This does not establish compatibility for
Sparse, Compact parts, compressed marks, arbitrary schemas, daemon restart
behavior, or other ClickHouse versions. A reader/writer, format, ClickHouse
build, platform, or fixture change decays the certificate; refresh the
focused/full suites and pinned external oracle before reasserting
compatibility.

## Verified W37 slice: raw 256-bit integer scalar payloads

Admit exactly bare `Int256` and `UInt256` payload columns beside a sorted
`UInt64` key in the pinned Wide/LZ4/plain-mark profile. Expose distinct
`Int256Value` and `UInt256Value` structs, each storing the low and high
`UInt128` halves of the 32-byte little-endian value. Signed values preserve
two's-complement bits; they are not Decimal256 coefficients. Add exact raw
reader, typed-batch, offline-catalog, and explicit writer APIs. Keep generic
numeric access and writer inference closed, even though the physical width
matches Decimal256. Do not admit Nullable 256-bit integers, Array forms,
256-bit primary keys, arithmetic/comparison, SQL decimal rendering, or TUI
formatting in this slice.

A read-only stock ClickHouse local 26.7.1.1315 probe produced one 13-row
Wide part containing both payloads, each with 416 uncompressed value bytes
(13 times 32). Seven data marks with row counts 2, 2, 2, 2, 2, 2, and 1
plus one zero-row EOF mark had 24-byte plain records. Each complete column
stream occupied one LZ4 frame, so compressed-file offsets remained zero;
payload decompressed mark offsets advanced 64 bytes for full granules,
ending at byte 416. `CHECK TABLE` passed. RowBinary stores each
signed/unsigned value as 32 raw little-endian bytes following the key;
the signed minimum and unsigned high-bit value share a byte pattern but
must retain different declared types. `columns_substreams.txt` names
exactly one stream per column. The
stock `serialization.json` has version 1, propagated nested versions,
`string:1`, and complete `Default` records ordered `i`, `pk`, `u` rather
than schema order; validation must match unique names, not JSON positions.
The local 26.6 development source is explanatory only; the pinned 26.7
binary and observed part are the compatibility authority.

Risk is **CAUTION**: shared 32-byte wire layout can make an Int256 part look
correct in Crystal while ClickHouse sees Decimal256 or the wrong signedness.
Rollback is one W37-only local feature commit; no push or existing
ClickHouse data-root mutation. The first falsifier is a focused RED spec for
exact `Int256`/`UInt256` admission while Decimal256, Nullable, Array, generic
numeric, and generic writer routes stay distinct. DoD: exact metadata and
stream checks; hardcoded limb-crossover, signed MIN/MAX, -1, unsigned
high-bit/MAX and zero bytes; full/later-mark reads and bounded table/catalog
windows; writer no-publication on invalid input; full debug and release
suites; formatting/diff checks; and a pinned stock oracle in both directions
with `ATTACH PART`, `CHECK TABLE`, independently encoded full/key-range
RowBinary, and same-size corruption detection. The strongest counterexample
is a shared 32-byte pattern read through the wrong signed, unsigned, or
Decimal256 API. No memory or speed tuning is admitted before remaining types,
MV, and projections are implemented.

Observed W37 evidence on this checkout: the focused W37 spec passed 7/7;
the full debug and release suites each passed 633/633. The public stock
fixture verifier checked exact named Default records, stream inventory,
32-byte little-endian payloads, all eight marks including the sentinel,
SHA256, SQL edge values, and independent RowBinary. The pinned ClickHouse
local 26.7.1.1315 bidirectional oracle passed stock `ATTACH PART` and
`CHECK TABLE`, Crystal full and keyed raw reads, and full/keyed RowBinary; both
Crystal writer parts attached, checked, and returned the independently
encoded full/keyed RowBinary. Mutating one byte in an attached stock stream
without changing its size produced `CHECKSUM_DOESNT_MATCH`; restoring it
restored `CHECK TABLE` and RowBinary. Adjacent W35/W36 raw-integer and
Decimal256 oracles also passed. Hostile review verdict: **ROBUST within this
bare-scalar Wide/LZ4/plain-mark profile**; no claim is made for Nullable,
Array, other part profiles, other ClickHouse versions, MV/projections, or
performance parity. A source, fixture, pinned binary, or compiler change
decays this certificate; refresh the focused/full suites and bidirectional
stock oracle before reasserting compatibility.

## Verified W38 slice: BASIC Nullable raw 256-bit integer payloads

Admit exactly `Nullable(Int256)` and `Nullable(UInt256)` scalar payload
columns beside a sorted `UInt64` key in the pinned Wide/LZ4/plain-mark
profile. Expose distinct optional raw `Int256Value?` and `UInt256Value?`
reader, typed-batch, offline-catalog, and explicit writer APIs. Keep the
32-byte nested values separate from `Nullable(Decimal(76, S))` and from
generic numeric/inferred writer paths. `Array(Nullable(Int256))`,
`Array(Nullable(UInt256))`, other array forms, Sparse serialization, Compact
parts, arbitrary schemas, 256-bit keys, arithmetic, and performance tuning
remain closed.

A read-only isolated stock ClickHouse local 26.7.1.1315 probe accepted both
types in a 13-row Wide part and passed `CHECK TABLE`. The BASIC part has
`i.null`, `i`, `u.null`, and `u` substreams; each `.mrk2` has seven data
marks plus one zero-row EOF mark with 24-byte plain records. Null-map
decompressed offsets are 0, 2, 4, 6, 8, 10, 12, 13; nested-value offsets
are 0, 64, 128, 192, 256, 320, 384, 416. Its `serialization.json`
is version 1 with propagated nested versions, `string:1`, an empty column
serializer list, and no explicit `nullable` version entry (BASIC version 0).
Stock RowBinary uses a nullable flag and emits the 32-byte child only for
non-NULL values, whereas the physical part reserves one child slot per row,
including NULL. A separate stock Sparse control uses `nullable:1`, sparse
index streams, and Sparse serializer records rather than BASIC null maps;
it is a negative admission test, not another accepted representation.
The pinned executable/part is the authority; local development source is
explanatory only.

Risk is **CAUTION**: the same 32-byte layout can conceal signed/unsigned/
Decimal256 aliasing, and RowBinary NULL omission can be mistaken for the
on-disk nested stream. Rollback is one W38-only local feature commit; do
not mutate the user's ClickHouse data root or push. The first falsifier is
a focused RED spec for exact metadata, optional raw values, paired marks,
and explicit writer admission while cross-type, generic, and Sparse paths
still reject. DoD: hardcoded NULL/non-NULL edge bit patterns, full/later-
mark reads and bounded table/catalog windows; bool-only null maps, equal
substream row counts and exact nested byte consumption; fail-closed
serialization records and no-publication invalid writes; full debug and
release suites; format/diff checks; and a pinned bidirectional stock oracle
with `ATTACH PART`, `CHECK TABLE`, independent full/key-range RowBinary,
and same-size corruption detection. The strongest adversarial case is an
identical high-bit bit pattern under the wrong signed, unsigned, or decimal
type that is incorrectly accepted by a typed API. No compatibility or
performance claim follows from the physical layout alone.

Observed W38 evidence on this checkout: the focused W38 spec passed 13/13;
the full debug and release suites each passed 646/646. The public stock
fixture verifier checked SHA256 coverage, exact metadata/substreams,
null-map and 32-byte nested bytes including NULL slots, all marks and the
sentinel, SQL values, independent Python-integer RowBinary, and stock
`ATTACH PART`/`CHECK TABLE` for both the 13-row BASIC part and the 32-row
Sparse negative control. The pinned ClickHouse local 26.7.1.1315
bidirectional oracle passed stock-to-Crystal full/later-mark reads and
full/keyed RowBinary; both Crystal nullable writers attached and checked
in ClickHouse and returned independent full/keyed RowBinary. A same-size
mutation of the attached BASIC null-map stream produced
`CHECKSUM_DOESNT_MATCH`; restoration recovered `CHECK TABLE` and RowBinary.
Adjacent W35/W36/W37 raw-integer and Decimal256 oracles passed. Format,
shell syntax, and diff checks passed. Hostile review verdict: **ROBUST
within this pinned BASIC Wide/LZ4/plain-mark profile**; no claim is made
for Sparse writing, arrays, other part layouts or ClickHouse versions,
TUI formatting, MV/projections, or performance parity. The writer oracle's
RowBinary expectation is separately encoded but uses the same Crystal raw
value structs passed to the writer; the Python-integer stock fixture and
raw-stream tests provide the independent byte anchor. A reader/writer,
fixture, pinned binary, compiler, or filesystem-case change decays this
certificate; refresh the focused/full suites and pinned bidirectional
oracle before reasserting compatibility.

## W39 slice: paired wide-integer Array leaves

Admit only one-level `Array(Int128)`, `Array(UInt128)`, `Array(Int256)`,
`Array(UInt256)`, and their `Array(Nullable(T))` BASIC counterparts beside a
sorted `UInt64` key, provided the pinned stock physical probe confirms the
expected `size0`, optional nested null-map, and fixed-width value streams.
The public Array accessors, typed batches, offline catalog, and explicit
writer must preserve signed/unsigned type identity, flattened element count,
and mark boundaries. Decimal128/256 aliases, arbitrary nesting, Sparse
serialization, Compact parts, other table schemas, and inferred generic
writer routes remain closed. The offline TUI page source does not render the
new arrays and must reject their selection even for an empty table.

A pinned stock ClickHouse local 26.7.1.1315 scratch probe accepted all eight
types in a seven-row Wide part and passed `CHECK TABLE`. All eight report
`Default` serialization with no column overrides in `serialization.json`.
Plain `.mrk2` marks and LZ4 data use `size0` plus the nested payload for
non-null leaves, and `size0`, a `null` map, and the nested payload for BASIC
Nullable leaves. Nullable physical payloads retain zero-filled slots under
NULL, whereas RowBinary omits the child value. This establishes the stream
topology independently of the Crystal codecs.

Risk is **CAUTION**: a correct-looking 16- or 32-byte stream can conceal a
wrong signedness or Decimal interpretation, and nullable child marks may be
misread as outer-row counts rather than flattened element counts. Rollback is
one W39-only local commit; do not mutate an existing ClickHouse data root or
push. First falsifier: a focused RED spec rejecting all eight currently
unsupported forms, then requiring exact typed admission and independent
edge-value bytes while cross-type and Decimal aliases still fail closed.
DoD: stock physical stream/metadata/mark probe, later-mark and empty-row
reads, corruption negatives, no-publication invalid writer inputs, focused
and full debug/release suites, and a pinned bidirectional stock oracle with
`ATTACH PART`, `CHECK TABLE`, and independently encoded full/keyed RowBinary.
The strongest counterexample is a same-width Decimal or signed/unsigned
array accepted by the wrong accessor. The fixture, pinned executable,
source, compiler, or filesystem-case change decays any W39 certificate.
Observed W39 checks on the pinned build and fixture: the checked-in fixture
verifier confirms all eight types, 21 physical streams, the exact nine-column
schema and `Default` serialization, four data marks with row counts
`[2, 2, 2, 1]`, and SHA-256 for all 50 part files. The focused spec reads
all eight stock columns and writer outputs across the full part and later
marks, checks byte-exact stream payloads and typed batch/catalog values,
rejects cross-type and Decimal aliases, rejects malformed plain reads and
nullable streams before typed-batch publication, and checks writer preflight does not
publish a destination on invalid row counts. The pinned oracle attaches the
stock part and all eight Crystal-written shapes to isolated ClickHouse tables,
passes `CHECK TABLE`, and compares independently encoded full and keyed
RowBinary byte-for-byte. This evidence does not establish compatibility with
other part profiles, recursive Arrays, or newer ClickHouse versions.
At this source state, `spec/wide_part_reader_w39_spec.cr` passed 9/0, the
complete debug and release `crystal spec` runs each passed 655/0, and
`scripts/check_array_integer128_256_oracle.sh` passed on ClickHouse local
26.7.1.1315. The neighboring W31 nullable-numeric Array and W38 nullable
256-bit scalar bidirectional oracles also passed. A proportionate adversarial
review found no remaining W39 correctness or scope counterexample (`ROBUST`
within this pinned profile). Any codec, fixture, compiler, pinned ClickHouse
binary, or reader/writer source change requires those checks to be rerun.

## W40 bounded implementation: paired temporal Array leaves

Admit only one-level `Array(Date)`, `Array(Date32)`, `Array(DateTime)`,
`Array(DateTime64(p))`, and their `Array(Nullable(T))` BASIC counterparts,
beside a sorted `UInt64` key on the pinned Wide/LZ4/plain-mark frontier.
`p` is a canonical single digit from 0 through 9 and remains part of the
column type; values are raw day codes, epoch seconds, or signed ticks, with
no calendar or timezone conversion. Public readers, typed batches, offline
catalog values, and explicit writers must preserve this semantic identity
even where the physical widths equal ordinary integers. A physical stock
probe must establish `size0`, optional child null-map, child payload, marks,
and serializer metadata before the implementation is promoted.

Reject same-width integer aliases in temporal accessors, alternate
`DateTime64` spellings, timezone-qualified `DateTime`, nested or Sparse
arrays, Compact parts, and any inferred generic writer route. The offline
TUI remains guard-only for these values; no renderer is implied by catalog
materialization. MV and projection semantics remain separate follow-ons.

Risk is **CAUTION**: equal-width payloads can silently exchange Date with
UInt16, Date32 with Int32, DateTime with UInt32, or DateTime64 with Int64;
precision may be lost even when tick bytes round-trip. Rollback is one
W40-only local commit; no existing ClickHouse data root or remote is changed.
The first falsifier is a RED exact-type spec, followed by a stock physical
probe spanning empty rows, NULL versus zero, and later marks at scale 3.
Writer readback and the independent ClickHouse oracle then cover scales 0,
3, and 9. DoD is paired reader/writer coverage for all eight declaration
families, exact type and precision rejection, malformed child-stream
fail-closed behavior, no-publication invalid writer inputs, typed batch and
catalog ownership checks, focused and full debug/release suites, and a
pinned bidirectional ClickHouse `ATTACH PART`/`CHECK TABLE`/independently
encoded full and keyed RowBinary oracle. The strongest adversarial case is a
same-width numeric column accepted as temporal, or a `DateTime64(9)` part
read/written as precision 3. Any change to the fixture, pinned binary,
compiler, serialization code, or filesystem-case assumption decays the
resulting certificate.
The initial pinned ClickHouse local 26.7.1.1315 stock probe produced one
seven-row, five-mark Wide part with nine exact columns (one `UInt64` key and
the eight W40 Array declarations). `CHECK TABLE` passed. Its 21 LZ4 data
streams and 21 plain mark streams follow `size0` plus child payload for
non-null leaves, and `size0`, child null-map, and payload for BASIC Nullable
leaves. `serialization.json` has no per-column serializer overrides and the
expected nested String serialization version 1. This was the physical-layout
anchor before reader/writer verification.

The W40 admission test was RED before production: `Array(Date)` was rejected.
At the final W40 source state, the focused spec passed 10/10; full debug and
release suites each passed 665/665 with the host's `-fuse-ld=ld` link flag.
The fixture verifier checked all 50 stock-part files, SHA-256 pins, eight
declarations, 21 data and 21 mark streams, and four data marks plus EOF.
Pinned ClickHouse local 26.7.1.1315 accepted the stock fixture and each
paired writer part through `ATTACH PART` and `CHECK TABLE`; independently
encoded full and key-filtered RowBinary matched byte-for-byte for all eight
families, representative DateTime64 precisions 0, 3, and 9, and nullable
all-NULL, empty-only, and adjacent non-NULL marks. Local writer readback
covered every DateTime64 precision 0 through 9. The stock Date32 SQL
conversion saturated the requested Int32 endpoints to raw codes `-25567`
and `24854`; separate paired-writer checks preserved raw Int32 extrema.
The neighboring W39 wide-integer Array and nullable temporal scalar
ClickHouse oracles also passed after W40. Final hostile review found no
W40-specific alias, precision, mark/null, or publication counterexample:
`ROBUST` within this pinned profile.

This is a bounded compatibility result, not general Array or DateTime64
coverage. The external ClickHouse oracle samples precision 0/3/9, while
precisions 1/2/4-8 have local readback only. The W40 corruption falsifier
truncates a nullable child frame; checksum-consistent malformed child/null
topology remains a cross-family adversarial test gap, although the shared
fixed-leaf decoder validates child marks, byte spans, 0/1 null flags, and
flattened consumption. Compact, Sparse, timezone-qualified, nested, and
non-paired writer shapes remain rejected. Re-run the gate after any decay
trigger above.

## W41 frontier: paired UUID Array leaves

Admit exactly one-level `Array(UUID)` and BASIC
`Array(Nullable(UUID))` payloads beside a sorted `UInt64` key in the pinned
Wide/LZ4/plain-`.mrk2` profile. Preserve `UUIDValue` as two ClickHouse-order
little-endian `UInt64` halves, not a `UInt128`, `IPv6`, or string alias. The
public typed reader, batch, catalog `.values`, and staged writer must retain
the exact declared type and NULL/empty distinctions. The paired writer must
publish only after self-readback and expose no generic inferred UUID path.

The pinned ClickHouse 26.7.1.1315 preimplementation probe accepted both
declarations and `CHECK TABLE`: `Array(UUID)` has `size0` plus the 16-byte
child stream; `Array(Nullable(UUID))` adds a child `.null` stream. This is
physical-layout evidence, not yet a compatibility result. Reject nested or
outer-Nullable variants, other UUID spellings, Compact/Sparse parts, and
cross-type numeric/IP aliases. Keep key ordering and partition semantics
within existing bounds; do not add UUID-key filtering or SQL functions.

Risk is **CAUTION**: byte-width compatibility can hide swapped UUID halves,
or malformed child/null marks can silently misalign values. Rollback is one
W41-only local commit, without touching existing ClickHouse data or pushing.
The discriminating preimplementation test was required to be RED because
exact UUID Arrays were rejected at the preimplementation source state. DoD
was focused debug and full debug/release specs, formatting, exact stock
reader fixture checks, and stock `ATTACH PART`/`CHECK TABLE` plus full and
keyed RowBinary comparison for both writer variants. Adversarial checks
targeted same-width aliases and malformed NULL/mark topology and used
non-symmetric UUID halves to expose byte-order errors.

The preimplementation admission spec was RED: `Array(UUID)` returned false.
At the final W41 source state, its focused spec passed 9/9; the full debug
and release suites each passed 674 examples with no failures or errors.
Formatting and `git diff --check` passed. The stock fixture verifier pinned
the exact three-column schema, six LZ4 data streams, six plain `.mrk2`
streams, mark rows `[2, 2, 2, 1]`, and all copied-file hashes. Reader tests
covered later marks, typed windows, catalog-owned values, same-width alias
rejection, malformed child marks, and a frame-checksum-consistent non-boolean
NULL map. The independent pinned ClickHouse oracle attached and checked the
stock part and both normal writer variants, then compared full and keyed
RowBinary byte-for-byte. It also attached and checked writer parts with all
outer rows empty and with six nonempty all-NULL leaves; the latter retained
six set null bytes and 96 zero-filled nested UUID bytes on disk while
RowBinary omitted NULL child payloads. Final hostile review found no W41
half-order, alias, null-topology, or publication defect: **ROBUST within this
exact profile**.

This does not admit arbitrary multi-column UUID Array schemas: the stock
serializer exception recognizes only the observed `pk`/`plain`/`maybe`
three-column fixture, while paired writer output retains its exact
two-column gate. The corruption tests do not rewrite the part-level checksum
inventory, so checksum-consistent malformed part metadata remains a
cross-family adversarial gap. ClickHouse version/profile changes, Array or
UUID codec changes, and mark/checksum validation changes decay this evidence;
rerun the focused suite and stock oracle before widening compatibility.

## W42 frontier: paired Decimal32 Array leaves

Admit only one-level `Array(Decimal(9, S))` and BASIC
`Array(Nullable(Decimal(9, S)))` payloads, with `S` from 0 through 9,
beside a sorted `UInt64` key in the pinned Wide/LZ4/plain-`.mrk2` profile.
The leaf representation is a signed little-endian `Int32` raw coefficient;
the scale remains part of the exact column type, not a floating-point
conversion or inferred property of the values. Reader, batch, catalog
`.values`, and paired writer must agree on the declared scale, preserve
negative/zero/NULL/empty distinctions, and consume one child slot per NULL.
The writer must preflight cardinality and mark bounds and publish only after
staged self-readback and exclusive destination creation.

The stock ClickHouse 26.7.1.1315 probe found `size0` and value streams for
the plain Array, plus a child `.null` stream for the Nullable Array. Treat
that as physical-layout evidence only until a copied, hashed fixture and
bidirectional oracle pass. The compatibility DoD is a behavioral RED test
before production changes, focused and full debug/release Crystal suites,
format/whitespace checks, stock fixture verification, and stock `ATTACH
PART`/`CHECK TABLE` with exact full and keyed RowBinary comparison of
writer output. Use string decimal literals in the oracle: ClickHouse
`toDecimal32` from a floating-point literal can truncate unexpectedly and
would make an invalid expected coefficient. Include negative coefficients,
empty Arrays, NULL vs zero, later marks, scale boundaries, and wrong-type
rejection.

Risk is **CAUTION**: a shared 4-byte codec could silently accept an `Int32`
alias, lose the scale, or mishandle NULL child slots. The strongest falsifier
is a stock-accepted part whose exact raw coefficients or keyed rows disagree
with our reader/writer. Reject Decimal64/128/256 Arrays, nested and
outer-Nullable Arrays, malformed scales, inferred numeric APIs, Compact/
Sparse serialization, arbitrary multi-column schemas, and any performance
claim. Rollback is a single W42-only local commit; no writes to existing
ClickHouse data roots and no push. Evidence decays with a producer-version,
codec, mark/checksum, or platform change and must be refreshed before
widening this boundary.

The preimplementation behavioral gate was RED: the canonical
`Array(Decimal(9, 2))` declaration returned false. The pinned stock fixture
uses alias DDL but canonical three-column part metadata, six LZ4 data streams
and plain `.mrk2` streams, with mark rows `[2, 2, 2, 1]`; its copied-file
hashes and source `CHECK TABLE` pass. At final W42 source state, the focused
W31/W42 specs passed 12/12 and the full debug/release suites each passed
680 examples without failures or errors. The reader preserves signed raw
coefficients, later marks, NULL versus non-NULL zero, and catalog DDL alias
normalization; the writer keeps the signed `Int32` backing range at scales
0 and 9. Reverse negative tests reject Decimal accessors on both plain and
nullable `Int32` Arrays. Formatting, shell syntax, and whitespace checks
passed.

The independent pinned ClickHouse oracle attached and checked the stock
part and our mixed, all-empty, and all-NULL writer parts, then compared full
and key-filtered RowBinary byte-for-byte. The all-NULL writer part contains
one set null flag and a zero-filled four-byte nested slot per NULL on disk;
RowBinary emits only the null flag. A scale-9 writer part containing
`Int32::MIN` and `Int32::MAX` also passed ClickHouse `ATTACH PART` and
`CHECK TABLE`, with exact full/keyed RowBinary. Hostile review returned
**ROBUST within this exact W42 profile**. The stock three-column serializer
exception remains bound to `pk`/`plain`/`maybe` at scale 2; arbitrary
multi-column schemas and Decimal64/128/256 Arrays remain unadmitted.
Checksum-consistent malformed child/null/mark topology remains a shared
Array-decoder adversarial gap rather than a W42-specific failure observed
here. Refresh the focused/full suites and oracle after the decay triggers
above.

## Rejected and guard-only surfaces

Rejected for W1: mutation of existing parts, table-level `INSERT`, merges,
replication, transactions across tables, SQL, Compact parts, compressed
marks, composite codecs, `Nullable`, `String`, JSON, projections, deletes,
TTL, and arbitrary partition expressions. No performance claim is admitted.

Residual guard-only surfaces:

1. Extend reader and writer together beyond W42's paired Decimal32 Arrays,
   W41's paired UUID Arrays,
   W40's paired temporal Arrays,
   W39's paired raw 128/256-bit
   Array leaves, W38's paired BASIC Nullable raw 256-bit scalars,
   W37's paired raw 256-bit scalars, W36's paired BASIC
   Nullable raw 128-bit scalars, W35's paired raw 128-bit scalars,
   W34's paired Bool Array family,
   W33's paired FixedString Array family, W32's nullable String Array,
   W31's nullable numeric Array family, and W30's non-null numeric Array family,
   W29's nested nullable Array, W28's nested Array, W27's exact nullable array,
   W25/W26's exact Maps,
   W24's exact JSON typed paths, W23's exact named Tuple,
   W22's bounded `LowCardinality(String)`, W21's paired arrays, W20's paired Decimal256,
   W19's paired IPv6, W18's paired IPv4, W17's paired UUID, W16's bounded
   semantic scalars, W14's BASIC nullable temporal codes, W13's raw time
   codes, W12's raw dates, W11's BASIC `Nullable(FixedString(N))`, W10's plain
   `FixedString(N)`, and W9's exact 22 payload shapes, one stock-ClickHouse
   differential fixture per type and substream shape.
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
