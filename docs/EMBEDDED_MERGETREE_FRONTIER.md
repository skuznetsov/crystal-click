# Embedded MergeTree Storage Frontier SDD

Document status: active design. W82 is admitted only for four exact
`Array(Map(UInt64|String, String|Nullable(String)))` declarations on the
pinned Wide/LZ4/plain-mark profile below. W81 is admitted only for the closed
`Array(Map(UInt64|String, T|Nullable(T)))` primitive-numeric family on the
pinned Wide/LZ4/plain-mark profile below. W80 is admitted only for the exact
`Array(Map(String, UInt64))` Wide/LZ4/plain-mark profile below. W79 is
admitted only for the bounded
`Map(UInt64|String, Array(Nullable(T)))` primitive-numeric profile below on
the pinned Wide/LZ4/plain-mark frontier. W77 is admitted only for the bounded
primitive-numeric `Map(UInt64, Nullable(T))` and
`Map(String, Nullable(T))` profile below. W76 is admitted only for the bounded
scalar-numeric `Map(UInt64, T)` and `Map(String, T)` profile below. W75 is
admitted only for mixed standalone
`Dynamic(String, UInt64, NULL)` on the pinned Wide/LZ4/plain-mark profile;
W74 remains admitted only for its String-only profile. W1, W2, and bounded
W3 are verified on this macOS host against the pinned ClickHouse build.
Bounded W4, W5, and W6 are verified on the local Darwin process-atomicity
frontier. Bounded W7 is
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
W72 extends that writer to arbitrary nonempty lists of the reader's simple
top-level `String` and ten primitive numeric JSON typed paths. Both metadata
declarations and physical streams are canonicalized by path name. The pinned
reverse oracle accepts a mixed-width three-path Crystal part; dynamic paths,
arbitrary documents, and general JSON remain outside scope. See
`JSON_TYPED_PATH_FRONTIER.md` for the evidence and limits.
W73 admits the three previously missing non-null cells of the core
`Map(K, Array(V))` matrix where `K` and `V` are each `UInt64` or `String`,
within the bidirectionally checked Wide/LZ4/plain-mark scope below.
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
W41 admits paired single-level UUID Arrays and BASIC Nullable UUID leaves.
W42 and W43 separately admit paired Decimal32 and Decimal64 Array leaves,
respectively, with signed raw coefficients and exact precision/scale metadata.
W44 admits the corresponding paired Decimal128 Array leaves on the pinned
Wide/LZ4/plain-mark profile; its detailed evidence and limits are below.
W45 admits paired Decimal256 Array leaves with distinct signed raw
`Decimal256Value` coefficients; its scoped stock compatibility evidence is
recorded below. Neither Decimal Array slice admits general decimal arithmetic.
W46 admits paired single-level IPv4 Arrays with BASIC Nullable leaves on the
pinned Wide/LZ4/plain-mark profile; its scoped evidence is recorded below.
W47 admits paired single-level IPv6 Arrays with BASIC Nullable leaves on the
pinned Wide/LZ4/plain-mark profile. Its network-octet codec is distinct from
IPv4, UUID, UInt128, and FixedString(16); scoped evidence is recorded below.
W48 admits paired Enum8 and Enum16 Array leaves, including BASIC Nullable
forms, with exact code membership and stock-canonical metadata in the bounded
Wide/LZ4/plain-mark profile. Its scoped evidence and limits are below.
W49 admits paired BFloat16 scalars and single-level Arrays, including BASIC
Nullable forms, with distinct raw-bit identity on the same pinned profile.
Its scoped evidence and limits are below. W50 admits paired raw Time and
Time64 values in the exact scalar, BASIC Nullable, and one-level Array shapes
recorded below. W51 admits the two exact named-Tuple Array declarations below
for paired reading, table/catalog access, and immutable writing. Its recursive
syntax parser does not admit other physical type compositions.
W52 admits the two remaining String-key Map combinations over the existing
`{UInt64, String}` leaf matrix for a pinned physical probe and paired
reader/writer implementation; verification status is recorded in its section.
W53 admits two exact nullable-UInt64-value Map declarations over the same
key families within the paired oracle below. W54 admits the corresponding
nullable-String-value Map pair within its pinned physical and paired oracle
below; it is not generic recursive Map support. W55 admits the exact
`Array(Tuple(a UInt64, b UInt64))` declaration alongside W51's two named-Tuple
Arrays, sharing their parsed physical stream plan and bounded reader/writer
path; it does not admit arbitrary recursive types. W56 targets an exact
`Variant(String, UInt64)` paired codec with stock BASIC/COMPACT discriminator
reads and a COMPACT writer; its verification status is recorded below. This
does not admit arbitrary Variant alternatives, Dynamic, or general JSON.
W57 targets one three-alternative `Variant(Bool, String, UInt64)` paired
profile, preserving W56; its admitted boundary and verification status are
recorded below.
W58 admits paired two-level `Array(Array(T))` support for the ten existing
fixed-width primitive numeric leaves, reusing W28's nested offset topology
without widening nullable, string, or arbitrary recursive shapes. Its
admitted boundary and verification status are recorded below.
W59 admits paired `Array(Array(String))` only, with the exact four-stream
reader/writer, typed table, and offline catalog boundary recorded below.
W60 admits paired `Array(Array(Nullable(T)))` for the ten primitive numeric
leaves already admitted by W31 and W58. Its evidence and limits are recorded
below; this does not admit arbitrary recursive types.
W61 admits paired `Array(Array(Nullable(String)))` within the exact five-stream
Wide/LZ4/plain-mark BASIC profile below. Its stock oracle and verification
status do not generalize to arbitrary nested types or serializers.
W62 admits paired two-level Arrays over the five already supported
fixed-width numeric Array leaves beyond the primitive family: `Int128`,
`UInt128`, `Int256`, `UInt256`, and `BFloat16`, both plain and BASIC nullable.
Its physical and verification boundary is specified below.
W63 admits one exact `Map(String, Array(UInt64))` paired part profile. Its
observed stock topology, verification, and guard-only boundary are recorded
below. This does not advance MV/projections or memory/performance optimization.
W64 admits paired two-level Decimal Arrays with BASIC nullable leaves at the
four canonical backing widths. W65 admits paired two-level temporal Arrays
with BASIC nullable leaves; its verification and limits are below. W66
admits paired two-level Time and Time64 Arrays with BASIC nullable leaves;
its bounded bidirectional oracle evidence and limits are below.

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

## W43 frontier: paired Decimal64 Array leaves

Admit only one-level `Array(Decimal(18, S))` and BASIC
`Array(Nullable(Decimal(18, S)))`, with `S` from 0 through 18, beside a
sorted `UInt64` key in the pinned Wide/LZ4/plain-`.mrk2` profile. Preserve
signed little-endian `Int64` raw coefficients and the exact scale in column
metadata; do not convert through floating-point numbers or infer a decimal
scale from values. Reader, batch, offline catalog `.values`, and paired
writer must agree on the exact declared type. NULL consumes a child slot,
and the writer must preflight sizes and marks, self-read the staged part,
and publish exclusively only after validation.

Risk is **CAUTION**: reusing the eight-byte integer stream without semantic
gates could accept an `Int64` alias or lose the scale; null flags and later
marks could also disagree while simple rows still pass. The first gate is a
behavioral RED test on the current reader. Then generate a synthetic part
with the pinned official ClickHouse local build, retain hashed physical
files, and test stock-to-Crystal reading plus Crystal-to-stock `ATTACH PART`,
`CHECK TABLE`, and exact full/keyed RowBinary comparison. Include empty
Arrays, NULL versus zero, negative coefficients, later marks, boundary
scales, wrong-type rejection, and a string-literal oracle for decimal values.
DoD also requires focused and full debug/release Crystal suites, formatting,
shell syntax, diff checks, and proportionate hostile review. A stock-accepted
part whose raw coefficients or keyed rows differ is the strongest falsifier.

Reject Decimal128/256 Arrays, nested and outer-Nullable Arrays, inferred
numeric APIs, Compact/Sparse serialization, arbitrary multi-column schemas,
MV/projection semantics, and any performance claim in this slice. Rollback
is a W43-only local commit; no existing ClickHouse data root is modified and
there is no push. Evidence is scoped to the pinned producer/consumer build,
the exact part profile, and this platform. A producer version, codec,
mark/checksum implementation, or platform change decays the certificate and
requires rerunning the focused/full suites and external oracle.

The preimplementation W43 assertion was RED: the current reader returned
false for `Array(Decimal(18, 0))` (one example, one failure). The pinned
stock fixture has canonical `Decimal(18, 2)` declarations, six LZ4 data
streams, plain `.mrk2` rows `[2, 2, 2, 1]`, and SHA256-verified files. The
W31/W43 focused suite passed 12 examples; the full debug and release suites
each passed 686 examples without failures or errors. Format, shell syntax,
and diff-whitespace checks passed. Type admission and writer readback cover
all scales 0..18. The stock reader and scale-2 catalog probes cover later
marks, exact raw signed coefficients, NULL versus non-NULL zero, and owned
`.values`; separate negative probes reject malformed grammar, including a
tampered `columns.txt` declaration, and `Int64` Array aliases.

The independent pinned ClickHouse oracle attached and checked the stock
fixture, mixed writer parts, all-empty and all-NULL controls, precision
boundary parts at scales 0, 9, 10, and 18, and a scale-18 writer part with
`Int64::MIN`/`Int64::MAX` backing coefficients. Full and PK-filtered
RowBinary matched exact expected bytes in every case. The all-NULL nested
stream contains eight zero bytes per NULL slot, while RowBinary emits only
the null flag. The observed stock three-column part has an empty serializer
list, and W43 admits only that exact `pk`/`plain`/`maybe` scale-2 exception
plus the paired two-column writer profile. A serializer-bearing three-column
part, arbitrary schemas, and Decimal128/256 Arrays remain unadmitted.
Checksum-consistent malformed child/null/mark topology remains a shared
Array-decoder adversarial gap. Hostile review returned **ROBUST within this
exact W43 profile**; it treats the absent serializer-bearing three-column
branch as a conservative rejection, not an observed compatibility failure.
Refresh the scoped evidence after the decay triggers above.

## W44 frontier: paired Decimal128 Array leaves

Admit only one-level `Array(Decimal(38, S))` and BASIC
`Array(Nullable(Decimal(38, S)))`, with `S` from 0 through 38, beside a
sorted `UInt64` key in the pinned Wide/LZ4/plain-`.mrk2` profile. The public
typed value is the signed little-endian `Int128` raw coefficient; the exact
scale stays in column metadata. Do not infer decimals from `Int128` Arrays,
convert coefficients through floating point, or accept an arbitrary
`Decimal(P, S)` precision. Reader, batch, offline catalog `.values`, and
paired writer must preserve the same declaration and row order. NULL child
slots contain the stock default payload and are distinct from non-NULL zero.
Only the canonical `Decimal(38, S)` spelling is accepted in physical part
metadata; the exact `Decimal128(S)` alias may normalize at the catalog DDL
boundary, as it does for existing scalar Decimal128.
The writer preflights dimensions and mark boundaries, self-reads its staged
part, and publishes exclusively only after validation.

Risk is **CAUTION**: a 16-byte raw integer stream could accidentally alias
`Array(Int128)` or `Array(Decimal(38,S))` with the wrong scale, while simple
single-mark rows may conceal null-map or later-mark corruption. The initial
gate is a behavioral RED assertion against the current typed-support
predicate. The independent producer/consumer check uses a synthetic part
made by the pinned local ClickHouse build, SHA256-pinned physical streams,
stock-to-Crystal reader tests, and Crystal-to-stock `ATTACH PART`,
`CHECK TABLE`, and byte-exact full/keyed RowBinary. Include empty Arrays, NULL
versus zero, negative values, later marks, scale boundaries,
noncanonical/wrong-type rejection, and catalog/batch access. DoD also
requires focused and full debug/release Crystal suites, format and shell
syntax checks, whitespace check, and hostile review. A stock-accepted part
whose signed coefficients, null positions, or keyed rows differ is the
strongest falsifier; a failing guard or oracle blocks the feature commit.
Test the valid SQL Decimal(38,S) coefficient boundary separately from full
`Int128::MIN/MAX` raw backing compatibility; the latter does not claim those
coefficients are valid Decimal SQL values.

Reject Decimal256 Arrays, nested and outer-Nullable Arrays, generic inferred
numeric APIs, Compact/Sparse serialization, arbitrary multi-column schemas,
MV/projection semantics, and memory/performance changes in this slice.
Rollback is one W44-only local commit; no existing ClickHouse data root or
remote is changed. Evidence is scoped to the pinned ClickHouse build, part
profile, and platform. Changing producer version, codec, mark/checksum
implementation, or platform decays it and calls for rerunning the focused,
full, and stock-oracle gates.

The preimplementation W44 typed-admission assertion was RED: the current
reader returned false for `Array(Decimal(38, 0))` (one example, one failure,
not a compile error). The pinned official ClickHouse 26.7.1.1315 fixture has
canonical scale-2 three-column declarations, six LZ4 streams, and mark rows
`[2, 2, 2, 1]`; SHA256 and physical-topology checks pass. The focused W44
spec passes six examples, and the full debug suite passes 692 examples with
no failures or errors. The full release suite also passes 692 examples with
no failures or errors. Crystal formatting, shell syntax, and diff-whitespace
checks pass.

The independent stock oracle attaches and checks seven parts: the stock
fixture, Crystal plain/nullable scale-0 raw-extrema parts, plain/nullable
scale-38 valid-precision-boundary parts, and plain/nullable all-empty parts.
For each it confirms exact full and PK-filtered RowBinary bytes. Mixed and
all-NULL rows distinguish null flags from non-NULL zero; all-NULL leaves
retain 16 zero nested bytes per leaf on disk. Physical Decimal128 aliases,
wrong precision/scale grammar, and raw `Array(Int128)` semantic aliasing are
rejected. The stock three-column empty-serializer exception is pinned only
to the observed `pk`/`plain`/`maybe` scale-2 schema; arbitrary schemas and
serializer-bearing three-column parts remain outside this claim.
Hostile review returned **ROBUST within the exact W44 profile** after the
all-NULL and all-empty controls were added. The remaining shared Array
adversarial gap is checksum-consistent malformed child/null/mark topology;
the W44 evidence does not promote arbitrary multi-column layouts, other
storage formats, Decimal SQL arithmetic, MV/projections, or performance
parity. Refresh the scoped checks after the decay triggers above.

## W45 frontier: paired Decimal256 Array leaves

Admit only one-level `Array(Decimal(76, S))` and BASIC
`Array(Nullable(Decimal(76, S)))`, with `S` from 0 through 76, beside a
sorted `UInt64` key in the pinned Wide/LZ4/plain-`.mrk2` profile. The public
typed value is `Decimal256Value`, preserving the signed little-endian 32-byte
raw coefficient and the exact scale in column metadata; neither `Int256Value`
nor `UInt256Value` is a Decimal alias. Reader, batch, offline catalog
`.values`, and explicit paired writer APIs must agree on type identity, row
order, empty Arrays, and NULL versus non-NULL zero. A NULL child slot has
the stock zero-filled nested payload. Only canonical `Decimal(76, S)` is
admitted in physical part metadata; `Decimal256(S)` may normalize only at
the catalog DDL boundary. No SQL arithmetic, rounding, or generic numeric
inference is admitted. Distinguish raw backing compatibility from the valid
SQL Decimal(76, S) coefficient range in tests and claims.

Risk is **CAUTION**: a 32-byte child stream could alias raw `Int256` or
`UInt256`, and an all-NULL or all-empty row can conceal a missing nested
stream or wrong serializer metadata. Start with a typed-admission RED test,
then use a pinned stock ClickHouse fixture and independently verify its
physical topology and SHA256. The bidirectional oracle must cover
stock-to-Crystal reads and Crystal-to-stock `ATTACH PART`, `CHECK TABLE`, and
byte-exact full/keyed RowBinary. Include scale 0 and 76, sign/high-word
patterns, NULL versus zero, nonempty all-NULL and all-empty controls, later
marks, noncanonical declarations, wrong scale, batch/catalog access, and
writer rejection before publication. A stock-accepted part whose coefficient
bytes, null positions, or keyed rows differ is the strongest falsifier.
DoD also requires focused and full debug/release Crystal suites, format and
shell syntax checks, whitespace check, and hostile self-review. A failed
guard or oracle blocks the feature commit.

Reject nested or outer-Nullable Arrays, generic `Array(T)` dispatch,
Compact/Sparse serialization, arbitrary schemas, MV/projection semantics,
and memory/performance work in W45. The writer must preflight dimensions
and mark boundaries, self-read the staged part, and publish exclusively
only after validation. Rollback is one W45-only local commit, without
changing existing ClickHouse data roots or any remote. Evidence is scoped
to the pinned ClickHouse build, part profile, and platform; producer version,
codec, mark/checksum implementation, or platform changes require refreshing
the focused, full, and stock-oracle gates.

The preimplementation typed-admission assertion was behaviorally RED:
`Array(Decimal(76, 0))` returned false (one example, one failure, no compile
error). The pinned official ClickHouse 26.7.1.1315 fixture has canonical
scale-2 three-column declarations, BASIC `serialization.json`, six LZ4
streams, and mark rows `[2, 2, 2, 1]` plus EOF. Its 20 SHA256 entries and
physical topology pass the fixture verifier. The focused W45 spec passes
seven examples; the final full debug and release suites each pass 699
examples with no failures or errors. Format, shell syntax, and diff-whitespace
checks pass.

The bidirectional stock oracle checks 13 parts: the stock fixture plus
Crystal-written bare/nullable scale-0 raw signed backing extrema, valid
`+(10^76-1)` and `-(10^76-1)` boundaries at scales 0 and 76, all-empty
controls at both scales, and scale-76 nonempty all-NULL controls. Every part
passes `ATTACH PART` and `CHECK TABLE`, and its full and PK-filtered
RowBinary bytes match the independent expected encoding exactly. The oracle
also checks later marks, high-word coefficients, zero-filled 32-byte NULL
slots on disk versus omitted NULL payload in RowBinary, and NULL versus
non-NULL zero. Raw signed Int256 backing extrema are storage-compatibility
cases, not claims of valid SQL Decimal(76) values. Physical Decimal256 aliases,
noncanonical precision/scale, and semantic aliasing through generic Int256
Array access remain rejected; the DDL alias is accepted only at the catalog
boundary.

Hostile self-review returned **ROBUST within the exact W45 profile** after
independent focused and stock-oracle reruns. The strongest attempted attacks
were identical-width Int256/Decimal256 type leakage and nonempty all-NULL
nullable arrays. The remaining shared Array gap is checksum-consistent
malformed child/null/mark topology; this evidence does not establish arbitrary
multi-column schemas, other formats or ClickHouse versions, Decimal SQL
arithmetic, MV/projections, or performance parity. Refresh these scoped
checks when the producer or reader/writer format boundary changes.

## W46 frontier: paired IPv4 Array leaves

Admit only one-level `Array(IPv4)` and BASIC
`Array(Nullable(IPv4))` beside a sorted `UInt64` key in the pinned
Wide/LZ4/plain-`.mrk2` profile. The public leaf is `IPv4Value`, representing
the network-order UInt32 address, and the physical child stream writes that
integer little-endian. This type must not alias `UInt32`, `Date32`, or raw
four-byte Array values. Reader, batch, offline catalog `.values`, and paired
writer APIs must agree on exact type identity, key order, empty Arrays,
non-NULL zero address, and NULL placement. The pinned stock NULL-insertion
fixture has a four-byte zero child slot for each NULL, whereas RowBinary emits
only the NULL flag. A reader must consume and ignore that child slot even if
its bytes are nonzero, because ClickHouse can copy a nested value under a
set NULL bit. Only canonical IPv4 declarations are admitted in physical part
metadata.

Risk is **CAUTION**: a byte-compatible numeric Array may pass superficial
round-trip tests while losing IPv4 semantics, and a NULL flag can conceal an
incorrect nested slot. The preimplementation falsifier is exact typed
admission returning false. A pinned stock fixture must fix the substream
topology (`size0`, optional `null`, and IPv4 leaf), serializer metadata,
plain mark row boundaries, and physical IPv4 byte order. The bidirectional
oracle must cover stock-to-Crystal reads and Crystal-to-stock `ATTACH PART`,
`CHECK TABLE`, and byte-exact full/keyed RowBinary. It must distinguish
192.0.2.1 from its byte-swapped form, NULL from 0.0.0.0, nonempty all-NULL
from all-empty, and first from later marks. Also test semantic alias rejection,
batch/catalog access, incorrect dimensions, and writer rejection before
publication. A stock-accepted part whose address bytes or keyed rows differ
is the strongest falsifier.

DoD requires the focused W46 spec, full debug and release Crystal suites,
fixture verifier and bidirectional stock oracle on the pinned build, Crystal
format/shell syntax/diff-whitespace checks, and hostile self-review. The
writer must preflight dimensions and mark boundaries, self-read its staged
part, and publish exclusively only after validation. Reject IPv6 Arrays,
nested or outer-Nullable Arrays, generic `Array(T)` dispatch,
Compact/Sparse serialization, arbitrary schemas, IP functions, MV/projection
semantics, and memory/performance work in W46. Rollback is one W46-only local
commit; do not mutate existing ClickHouse data roots or any remote. Evidence
is scoped to the pinned ClickHouse build, codec, mark/checksum implementation,
and platform; a change to those boundaries requires refreshing the gates.

The preimplementation admission test was behaviorally RED: `Array(IPv4)`
returned false (one example, one failure, no compile error). The pinned
official ClickHouse 26.7.1.1315 fixture has three canonical columns, six
LZ4 streams, BASIC serializer metadata, and mark rows `[2, 2, 2, 1]` plus
the EOF mark. Its full inventory, physical topology, and SHA256 manifest
pass the fixture verifier. The focused W46 spec passes 10 examples; the
final full debug and release suites each pass 709 examples with no failures
or errors. Crystal format, shell syntax, and diff-whitespace checks pass.

The bidirectional stock oracle checks six parts: the stock paired fixture
plus Crystal-written mixed plain/nullable, all-empty plain/nullable, and
nonempty all-NULL nullable controls. Each passes `ATTACH PART` and
`CHECK TABLE`; its full and PK-filtered RowBinary matches an independent
raw-address byte encoder exactly. Physical leaf checks distinguish IPv4's
little-endian encoding of a network-order UInt32 from a byte-swapped address.
The stock NULL-insertion fixture and Crystal writer retain a zero-filled
four-byte nested slot, while RowBinary omits the NULL payload. A separate
reader test reseals a nonzero nested slot under a NULL bit and still decodes
`nil`, consistent with ClickHouse's nullable bulk/copy semantics.

Hostile self-review returned **ROBUST within this pinned profile** after an
independent focused-spec and stock-oracle rerun. The strongest attempted
attacks were IPv4/UInt32 semantic aliasing and a nonzero hidden payload
under NULL. The poisoned hidden-slot reader case was not itself attached to
ClickHouse. The stock oracle does not establish arbitrary schemas,
checksum-consistent malformed child/null/mark topology, other part formats
or ClickHouse versions, IP functions, MV/projections, or performance parity.
Refresh this scoped evidence after the producer, codec, or reader/writer
format boundary changes.

## W47 frontier: paired IPv6 Array leaves

Admit only one-level `Array(IPv6)` and BASIC
`Array(Nullable(IPv6))` beside a sorted `UInt64` key in the pinned
Wide/LZ4/plain-`.mrk2` profile. The public leaf is `IPv6Value` with exact
16 network-order address octets; it must not alias UUID, UInt128, or a
FixedString(16) leaf. Reader, batch, offline catalog `.values`, and paired
writer APIs must preserve exact type identity, address-octet order, key order,
empty Arrays, non-NULL `::`, and NULL placement. A stock NULL-insertion part
has a 16-byte zero child slot for each NULL while RowBinary emits only the
NULL flag. The reader must consume and ignore even a nonzero child slot under
a set NULL bit. Only canonical IPv6 declarations are admitted in physical
part metadata; the `INET6` DDL alias is a separate catalog-boundary concern.

Risk is **CAUTION**: a same-width UInt128/UUID codec can produce valid-looking
but byte-swapped addresses, and a hidden NULL slot can shift later leaves.
The preimplementation falsifier is exact typed admission returning false.
Use a pinned stock fixture to establish `size0`, optional `null`, child
stream ordering, BASIC serializer metadata, and adaptive marks including the
zero-row terminal mark. The bidirectional oracle must cover stock-to-Crystal
reads and Crystal-to-stock `ATTACH PART`, `CHECK TABLE`, and byte-exact full
and PK-filtered RowBinary. Include asymmetric IPv6 addresses to distinguish
octet reversal and swapped 64-bit halves, `::1`, non-NULL zero, NULL versus
zero, later marks, all-empty and nonempty all-NULL controls. Challenge typed
alias leakage, a nonzero hidden child under NULL, malformed declarations,
incorrect dimensions, and rejection before publication. A stock-accepted
part with a mismatched asymmetric address or keyed row is the strongest
falsifier.

DoD requires focused W47 spec, full debug and release Crystal suites,
fixture verifier and bidirectional stock oracle on the pinned build, format
and shell-syntax checks, diff-whitespace check, and hostile self-review.
The writer must preflight dimensions and marks, self-read its staged part,
and publish exclusively only after validation. Reject nested or
outer-Nullable Arrays, generic `Array(T)` dispatch, Compact/Sparse
serialization, arbitrary schemas, IP functions, MV/projection semantics,
and memory/performance work in W47. Rollback is one W47-only local commit,
without touching existing ClickHouse data roots or remote state. The evidence
decays when the producer version, codec, mark/checksum implementation, or
platform changes; refresh focused, full-suite, and stock-oracle gates then.

W47 result on pinned ClickHouse 26.7.1.1315 (Darwin): the stock three-column
fixture has six LZ4 data streams, matching plain `.mrk2` streams, four data
marks with row counts `[2, 2, 2, 1]`, and a zero-row terminal mark. Focused
W47 spec passed 8/0, including explicit asymmetric network octets, typed
batch/catalog access, UUID/UInt128/FixedString(16) rejection, writer
preflight, all-empty and all-NULL cases, and a resealed first NULL child
whose nonzero byte does not shift the following `::` sentinel. Full debug
and release suites passed 717/0 each. The pinned fixture verifier passed;
the bidirectional stock oracle passed `ATTACH PART` and `CHECK TABLE` on
the stock pair plus five Crystal-written controls, with byte-exact full and
PK-filtered RowBinary in all six cases. Formatting, shell syntax, and diff
whitespace checks passed. Independent hostile review returned **ROBUST**
within this profile. The poisoned NULL child was tested by the Crystal
reader after resealing its frame and marks, but was not independently
accepted by stock ClickHouse. This result does not admit other schemas,
aliases in physical metadata, Compact/Sparse parts, MV/projection semantics,
or any memory/performance conclusion.

## W48 frontier: paired Enum8 and Enum16 Array leaves

Admit one-level `Array(Enum8(...))`, `Array(Enum16(...))`, and their BASIC
`Array(Nullable(Enum8(...)))` / `Array(Nullable(Enum16(...)))` forms beside
a sorted `UInt64` key in the pinned Wide/LZ4/plain-`.mrk2` profile. Expose
signed `Int8` / `Int16` backing codes through exact typed APIs, retaining the
canonical Enum declaration and checking every non-NULL code against its
declared set. The writer must sort valid declaration entries by numeric code
in `columns.txt`, as stock ClickHouse does even when the input spelling is
unsorted. A matching-width `Array(Int8)` or `Array(Int16)` is a different
type; generic numeric Array APIs must not reinterpret it as Enum. Only the
existing bounded canonical Enum8/16 physical grammar is admitted. The API
does not separately parse generic `Enum(...)` or MySQL `ENUM` spellings, but
stock ClickHouse can normalize those inputs to identical canonical Enum8/16
metadata; their original spelling cannot be distinguished from a part.
Label conversion and arbitrary recursive Arrays remain rejected.

This is **CAUTION** because width-correct raw decoding can silently admit an
undeclared code or alias an ordinary numeric Array. The initial falsifier is
exact typed admission returning false before production edits. Use one stock
fixture with all four shapes, signed endpoints, negative/zero/positive codes,
empty and nonempty all-NULL rows, NULL beside valid zero, multiple marks and
a short tail. The reader must consume each fixed-width nested slot under a
NULL bit without assigning its hidden code or shifting a later sentinel;
the writer uses the `DataTypeEnum` default (the smallest numeric declared
code) in hidden slots, matching the pinned explicit-`CAST` stock path. Stock
insertion paths can put other ignored bytes under `NULL`, so that physical
slot is not a unique representation of nullness. A resealed visible undeclared
code must fail closed, while a resealed nonzero hidden NULL code must not.

DoD: focused W48 spec, full debug/release suites, pinned fixture verifier,
and bidirectional stock `ATTACH PART` / `CHECK TABLE` / byte-exact full and
PK-filtered RowBinary for stock and Crystal-written cases, plus canonical
metadata and hidden-leaf byte comparison for unsorted Enum declarations;
format, shell syntax, diff-whitespace checks, and hostile self-review. The pair
writers preflight dimensions and code membership, self-read staged files, and publish
exclusively only after validation. This slice does not admit other schemas,
Compact/Sparse serialization, enum keys, MV/projection semantics, or
memory/performance work. Rollback is one W48-only local commit. Its evidence
decays when the producer version, canonical Enum grammar, codec, mark or
checksum implementation, or platform changes; refresh all gates then.

W48 result on pinned ClickHouse 26.7.1.1315 (Darwin): focused W48 spec passed
9/0; full debug and release suites passed 726/0 each. The stock fixture
verifier confirmed five canonical columns, 11 LZ4 streams, and mark rows
`[2, 2, 2, 1]`. The bidirectional oracle passed on that stock fixture, a
second stock part with unsorted no-zero Enum8/16 declarations, and 12
Crystal-written parts. Every attached part passed `CHECK TABLE`; full and
PK-filtered RowBinary were byte-exact. The second stock part established
numeric-sorted `columns.txt` and explicit-`CAST` hidden NULL child bytes
`f9` (Enum8) and `d4 fe` (Enum16); the Crystal writer matched both widths
byte-for-byte and canonicalized their metadata. Formatting, shell syntax,
and diff-whitespace checks passed. A separate source-and-oracle hostile review
returned **ROBUST** within this bounded profile. The Enum grammar still
rejects some valid ClickHouse escaped control labels, so this is not full
Enum-label compatibility. Hidden NULL child bytes may also differ across
stock insertion paths; only the explicit-`CAST`/`DataTypeEnum` default path
was matched. Other schemas, Compact/Sparse parts, MV/projections, and any
memory/performance conclusion remain outside this result.

## W49 frontier: paired BFloat16 scalar and Array values

Admit exact `BFloat16`, `Nullable(BFloat16)`, `Array(BFloat16)`, and
`Array(Nullable(BFloat16))` payloads beside a sorted `UInt64` key in the
pinned Wide/LZ4/plain-`.mrk2` profile. Expose a distinct raw-bits value whose
`UInt16` payload is preserved exactly; neither `Float32` conversion nor the
existing `UInt16` type may silently stand in for BFloat16. This includes
signed zero and NaN payload bits. BASIC nullable slots carry a null map and a
16-bit nested value; an ignored nested value under a NULL bit must not become
visible or misalign following values. Array adds its size0 stream. Public
reader and writer support must be paired for all four admitted forms.

This is **CAUTION**: the physical width matches `UInt16` while the logical
type and bit semantics differ. The initial falsifier is rejection of all four
types by the current exact reader admission gate. Before widening it, add a
focused failing spec that distinguishes BFloat16 from UInt16 and checks
byte-exact raw-bit preservation across multiple marks. The strongest guard is
a stock-produced fixture and the reverse stock oracle: `ATTACH PART`, `CHECK
TABLE`, and byte-exact full and key-filtered RowBinary for stock and
Crystal-written parts, including signed zero, distinct NaN payloads, empty
Arrays, all-NULL rows, and a short final mark. Reader preflight and staged
writer validation must bound rows, elements, frame bytes, and substream marks.

DoD: focused W49 spec, full debug and release suites, pinned fixture verifier,
bidirectional stock oracle, format and diff checks, and a hostile review of
logical type identity and NULL child handling. Other BFloat16 compositions,
Compact/Sparse parts, MV/projections, and memory/performance work remain
guard-only. Rollback is one W49-only local commit. The evidence decays with
the stock producer version, codec/mark format, platform, or BFloat16
serialization semantics; refresh the fixture and oracle gates then.

W49 result: the focused spec passed 7/0; the full debug and isolated release
suites passed 733/0 each. The public synthetic fixture verifier confirmed the
five-column stock part, nine LZ4 streams, and mark rows `[2, 2, 2, 1]`.
ClickHouse local 26.7.1.1315 accepted and checked the stock part and all four
Crystal-written two-column parts, with byte-exact full and key-range RowBinary
against independently assembled expected bytes. The hostile check found no
counterexample to exact logical identity, raw-bit preservation, or NULL child
masking within these shapes. A first full release run failed in an unrelated
process-lock spec while other Crystal spec processes were active; the isolated
single-spec and complete release reruns passed. Interference is plausible but
not proven as the cause. The NULL-child poison spec reseals the compressed
frame, not `checksums.txt`, so it establishes reader masking rather than stock
acceptance of a poisoned part. A wholly empty nested stream, an all-NULL-only
part, other ClickHouse versions, and other schemas/codecs/mark formats remain
untested. No memory or performance conclusion follows from W49.

## W50 frontier: paired Time and Time64 raw temporal values

Admission: exact `Time` and canonical `Time64(p)` for `p = 0..9`,
their BASIC Nullable forms, and one-level `Array(T)` and
`Array(Nullable(T))` leaves beside a sorted `UInt64` key. Expose signed raw
`Int32` seconds for Time and signed raw `Int64` ticks for Time64 while retaining
the logical type and precision; these accessors must reject generic Int32,
Int64, DateTime, and DateTime64 declarations. The writer must emit the same
eight shapes the reader accepts, not claim support from physical width alone.

This is **CAUTION**: the scalar payloads reuse existing integer widths, but
ClickHouse gives them distinct type metadata and text semantics. The pre-W50
reader's exact admission gate rejected them at the initial RED test.
The pinned stock-part probe established binary
representation, substream names, serializers, mark topology, NULL child
slots, and Array size0 streams. Keep semantic parsing and text formatting
outside this raw storage API. Do not generalize the empty-serializer
multi-column exception beyond the observed stock schema; malformed or
recursive declarations must still fail closed.

DoD: a synthetic stock Wide/LZ4/plain-`.mrk2` part containing all eight
shapes, including Time64 precisions 0, 3, and 9, nontrivial mark boundaries,
zero/nonzero values, NULL slots, and empty/all-NULL Array rows; a focused
RED-to-green reader/writer spec; full debug and release suites; fixture
integrity and format checks; reverse `ATTACH PART`/`CHECK TABLE` and
independently expected full and key-filtered RowBinary for the stock part and
each Crystal-written shape; and a hostile review of semantic identity,
precision, offsets, and NULL handling. Rollback is one W50-only local commit.
Other temporal wrappers, other physical formats, MV/physical projection
subparts, and memory/performance work remain guard-only. This evidence
decays when the pinned ClickHouse producer, platform, codec, marks, or Time
serialization semantics change.

W50 result: the focused spec passed 8/0, and the full debug and release
suites passed 741/0 each. The public synthetic fixture verifier confirmed
11 canonical columns, 19 LZ4 streams, and mark rows `[2, 2, 2, 1]`.
ClickHouse local 26.7.1.1315 accepted and checked the stock part and all ten
Crystal-written two-column parts; independently assembled full and
key-filtered RowBinary matched byte-for-byte. The exact type-gate tests
reject same-width numeric and DateTime declarations, malformed precision,
and unadmitted recursive wrappers. The scoped adversary check found no
counterexample to logical identity, precision preservation, offset/mark
handling, or NULL separation in these shapes (`ROBUST` within this profile).
Other ClickHouse versions, text/timezone semantics, other physical formats,
and arbitrary nested Time compositions remain untested. No memory or
performance conclusion follows from W50.

## W51 admitted frontier: recursive physical plan for Array of named Tuple

Admit `Array(Tuple(a UInt64, b String))` and
`Array(Tuple(a Nullable(UInt64), b String))` beside a sorted `UInt64` key,
with paired mark-range reader, typed-table/catalog values, and immutable
writer. A recursive type-plan parser may describe Array, named Tuple,
Nullable, and leaf nodes, but parsing alone must not admit other
compositions. The public admission seal remains exactly these two new
declarations plus previously admitted types. Derive the escaped Tuple child
stream inventory and widths from the sealed plan, rather than accepting a
matching physical width under the wrong logical type.

Risk is **CAUTION**: outer sizes, two flattened Tuple children, String byte
sizes, and the optional child null map must share exact mark boundaries.
A wrong boundary can silently pair a valid `a` value with the next row's
`b` value. Preflight all child mark/count/byte relationships and aggregate
materialization bounds before a batch callback; staged writer readback must
recheck the same invariant before exclusive publication. Rollback is one
W51-only local commit. This plan must not alter generic admission of
`Tuple`, `Map`, `Array`, `Nullable(Array)`, or JSON, and must not begin
memory/performance tuning.

First falsifier: a focused RED test opens a pinned stock Wide/LZ4/plain-mark
part containing both exact declarations and fails at current type admission.
The stock probe must establish escaped stream names, serializer metadata,
mark topology, NULL placeholders, empty arrays, and String framing before
the reader/writer changes. DoD: mixed and empty/all-NULL arrays over multiple
marks including a short final mark; exact full and later-mark reads; typed
batch and offline catalog values; malformed logical type and shifted child
mark rejection before callback/publication; a stock-to-Crystal fixture and
Crystal-to-stock `ATTACH PART`, `CHECK TABLE`, full/key-range RowBinary oracle;
full debug/release suites, fixture integrity, format/diff checks, and hostile
review of row/element alignment. Evidence decays with a change in the pinned
ClickHouse producer, codec, mark or Tuple escaping format, platform, or
shared recursive plan.

W51 result: the focused spec passed 7/0, and the full debug and release
suites each passed 748/0 at the formatted source state. The public synthetic
stock fixture verifier confirmed the exact two declarations, ten escaped
LZ4 streams, and mark rows `[2, 2, 2, 1]`. ClickHouse local 26.7.1.1315
accepted and checked five Crystal-written parts: mixed plain and nullable
arrays, all-empty arrays, an all-NULL nullable field, and a nonempty middle
mark whose String raw stream has repeated boundaries. Independently assembled
full and key-filtered RowBinary matched byte-for-byte for all five parts.
Reader opening rejects a shifted child row-count mark, and reader preflight
rejects a String raw-stream decompressed-offset mutation that preserves every
child mark's row vector and the `.bin` bytes. The table exposes zero
callbacks in both cases. The mutated mark files retain their lengths, so
they pass the table's documented size-only selected-checksum gate; the
tests also pin the distinct mark-row and byte-boundary error messages.
Admission tests reject unadmitted recursive wrappers and mismatched Tuple
leaves. The adversarial verdict is **ROBUST within this exact W51 profile**;
the review found no concrete counterexample after the checksum premise was
checked against the size-only implementation. This evidence does not
establish content-hash validation for mutated marks, other ClickHouse
versions, arbitrary recursive types, MV/projection subparts, total heap use,
or performance.

## W52 admitted frontier: ordered String-key Maps over the existing leaf codecs

Admit exactly `Map(String, UInt64)` and `Map(String, String)` alongside the
previous `Map(UInt64, UInt64)` and `Map(UInt64, String)` declarations, with
paired mark-range reader, typed-table/catalog values, and immutable writer
beside a sorted `UInt64` primary key. Together these form the Cartesian
`{UInt64, String}` key/value matrix, but do not imply general Map admission.
Represent entries as ordered tuples, preserving duplicate keys and arbitrary
String bytes. Reject Nullable keys, unadmitted children, nested Maps, and
other Map serialization variants at this boundary.

This is **CAUTION**: String keys require both a `.size` and raw child stream,
whose flattened element counts and per-mark byte boundaries must align with
the Map `size0` stream and the independent value child. A valid-looking part
can otherwise pair a key with the next value or row. Preflight each selected
mark's child streams, sizes, and materialization budget before that mark's
table callback; scans are streaming, not whole-scan transactions, so a later
corrupt mark can fail after earlier batches were delivered. The writer must
read back the staged part before exclusive publication. Use
the pinned ClickHouse 26.7.1.1315 producer to establish the actual physical
substreams; the logical `Array(Tuple)` equivalence is not format evidence.
Rollback is one W52-only local commit, with no existing ClickHouse data root
modified and no memory/performance work.

First falsifier: open a stock Wide/LZ4/plain-`.mrk2` part with both new
declarations; the pre-W52 type gate must reject them. DoD: pinned stock
fixture with duplicate and binary String keys, empty Maps, empty/nonempty
values, multiple marks and a short final mark; exact full and later-mark
reads, typed batch/catalog values, malformed type and shifted child-boundary
rejection before the affected mark's callback or staged publication; reverse
stock `ATTACH PART`, `CHECK TABLE`, and independently expected full/key-range
RowBinary for both new
writer shapes; full debug/release suites, fixture integrity, format/diff
checks, and hostile review of key/value pairing and bounds. Evidence decays
on a change in the pinned ClickHouse producer, Map serialization, codec,
marks, platform, or shared reader/writer helpers. MV/projection subparts,
other physical formats, remaining types, and performance remain guard-only.

W52 result: the pinned fixture verifier confirmed ten physical streams and
mark rows `[2, 2, 2, 1]`. Reader specs exercised exact ordered entries,
duplicate and binary keys, later marks, typed-table/catalog access, charge
accounting, and shifted key-stream boundaries. A later corrupt mark was
observed to fail after one earlier callback; this is the declared streaming
boundary, not whole-scan atomicity. The independent ClickHouse oracle
accepted both Crystal-written Map shapes and two empty-stream variants with
`ATTACH PART`/`CHECK TABLE`; exact type metadata and full/key-range RowBinary
matched separately encoded expectations. At this source state, full debug
and release suites each passed 756 examples with no failures or errors;
format, fixture, shell syntax, and diff checks passed. A read-only hostile
review returned **ROBUST** for the per-mark contract. Budget overflow and
exact-limit edges were source-audited, not separately stress-tested; no total
heap, other ClickHouse version, MV/projection, or performance claim follows.

## W53 admitted frontier: nullable UInt64 values in ordered Maps

Admit exactly `Map(UInt64, Nullable(UInt64))` and
`Map(String, Nullable(UInt64))` on the existing Wide/LZ4/plain-`.mrk2`
profile, beside a sorted `UInt64` primary key. Reader, typed table/catalog,
and immutable writer must preserve ordered duplicate entries and distinguish
`NULL` from non-null zero. No Nullable keys, other Nullable value leaves,
generic Map composition, mutation, MV/projection ownership, or performance
claim is admitted. The API may use `Array(Tuple(K, UInt64?))` for each row;
it must not collapse duplicate keys into a Hash.

The pinned ClickHouse 26.7.1.1315 stock probe observed `size0`, flattened
keys, `values.null`, and fixed-width `values` for the UInt64-key case; the
String-key case adds `keys.size` before raw `keys`. Every child has per-mark
row counts `[2, 2, 1, 0]` in the five-row probe. Its flattened null bytes
were `01 00 00 01 00`, while flattened UInt64 bytes represented
`[0, 0, 42, 0, 1]`: zero storage for a null slot does not make it non-null.
This scratch probe is physical evidence, not a committed fixture or writer
compatibility result.

This is **CAUTION**: misaligned null bits can silently turn a null into zero
or shift one Map entry into the next row. Preflight each selected mark's
outer counts, key child, null child, value child, raw byte limits, and
materialization charge before that mark's callback. The writer must validate
the staged inventory and readback before exclusive publication. Rollback is
one W53-only local commit; no existing ClickHouse data root is modified.

First falsifier: the pre-W53 type gate rejects both stock declarations.
DoD: preserve a pinned stock fixture with duplicate ordered keys, null and
non-null zero values, empty rows, multiple marks, and a short final mark;
verify full/later-mark reader and table/catalog access, corrupt or shifted
null/value child rejection at the per-mark boundary, invalid-input and
publish-safety checks; independently attach Crystal-written parts in stock
ClickHouse, run `CHECK TABLE`, and compare full/key-range output against
independently encoded expectations. Run focused and full debug/release specs,
fixture integrity, format/diff/shell checks, then a hostile self-review of
null semantics, child alignment, bounds, and rollback. Evidence decays when
the pinned producer, serialization, mark codec, or shared helpers change.

## W53 result: exact nullable-value Map pairs

The pinned ClickHouse 26.7.1.1315 seven-row fixture verifies both declared
types, escaped child-stream inventory, LZ4 framing, and plain `.mrk2` marks.
The reader, typed-table batches, and offline catalog preserve ordered duplicate
keys and distinguish `NULL` from non-null zero. Checksum-refreshed tests reject
both a shifted null-child mark boundary and a non-boolean null byte. The writer
also preserves fully empty Maps and nonempty `Map(String, Nullable(UInt64))`
rows whose keys are all empty Strings, leaving the raw key stream zero bytes.

At this source state, the full debug and release spec suites each passed 766
examples with zero failures/errors. The independent stock oracle attached and
checked the pinned fixture and both Crystal writer forms, including all-empty
variants and the all-blank String-key variant; exact full and primary-key-range
`RowBinary` bytes matched independently encoded expectations. The scoped
adversary review found no must-fix defect in the admitted reader/table/catalog
or writer paths. It did not establish generic Map composition, MV/projection
semantics, other physical part profiles, or any memory/performance result.
All-empty parts were checked through the direct reader and stock ClickHouse,
but not separately through table/catalog materialization. Refresh this evidence
after a producer, serializer, mark codec, or shared reader/writer helper change.

## W54 admitted frontier: nullable String values in ordered Maps

Admit exactly `Map(UInt64, Nullable(String))` and
`Map(String, Nullable(String))` beside a sorted `UInt64` primary key on the
pinned ClickHouse 26.7.1.1315 Wide/LZ4/plain-`.mrk2` profile. Reader,
typed-table/catalog, and immutable writer must preserve ordered duplicate
entries and distinguish a null value from an empty non-null String. Do not
admit nullable keys, arbitrary Map or Array(Map) composition, other physical
layouts, MV/projection ownership, or performance claims. A wider recursive
codec remains guard-only until these child-stream contracts are established.

This is **CAUTION**: an off-by-one in the flattened String sizes, null map,
key bytes, or per-mark child cursor can silently pair a key with the wrong
value. The first falsifier is the pre-W54 exact type gate rejecting both
declarations in a stock-generated part. The pre-code RED assertion observed
this rejection. A pinned stock plain-mark probe then produced seven rows
with populated mark row counts `[2, 2, 2, 1]` plus a zero-row terminal mark.
Its exact UInt64-key child inventory is `size0`, `keys`, `values.null`,
`values.size`, and `values`; the String-key variant adds `keys.size` before
raw `keys`. All three columns together have twelve `.bin` and twelve plain
`.mrk2` streams, and stock `ATTACH PART`/`CHECK TABLE` accepts the scratch
part. This initial probe established topology only; the committed fixture,
negative tests, and reverse writer compatibility are recorded below.

DoD: pinned stock fixture with ordered duplicate keys, null versus empty
values, empty Maps, multiple marks and a short tail; exact full and later-mark
reads, typed-table/catalog values, shifted child-boundary and malformed null
rejection before the affected mark callback, budget and invalid-input guards;
reverse stock `ATTACH PART`/`CHECK TABLE` and independently encoded full and
key-range `RowBinary` for both Crystal writer shapes, including zero-byte
String child cases; focused and full debug/release suites, fixture integrity,
format/diff checks, and hostile review. The writer must validate staged
inventory/readback before exclusive publication. Rollback is one W54-only
local commit; no existing ClickHouse data root is modified. Evidence decays
on a change in the pinned producer, Map/String serialization, codec, marks,
platform, or shared reader/writer helpers.

## W54 result: exact nullable String-value Map pairs

The pinned seven-row stock fixture verifies both exact declarations, twelve
data/mark stream pairs, LZ4 framing, plain `.mrk2` marks, and populated mark
rows `[2, 2, 2, 1]`. Reader, typed-table batches, and offline catalog retain
duplicate ordered entries, binary String keys, embedded-NUL/UTF-8 data, and
the difference between `NULL` and empty non-null String values. A
checksum-refreshed non-boolean null flag is rejected before any table
callback. Shifted value-size and raw-value child boundaries are rejected
before the affected mark callback; an earlier valid mark may already have
been yielded, consistent with streaming scan semantics.

The writer's staged inventory/readback checks and exclusive publication
boundary remain intact. Stock ClickHouse 26.7.1.1315 accepted and checked
both Crystal-written shapes, plus all-empty Map variants and a String-key
variant whose raw key and value streams are zero bytes. Exact type metadata,
full `RowBinary`, and primary-key-range `RowBinary` matched separately
encoded expectations. At this source state, full debug and release suites
each passed 776 examples with zero failures/errors; the focused
reader/table/catalog run passed 13 examples. Fixture integrity, shell
syntax, formatting, and diff checks passed. A read-only hostile review
returned **ROBUST** for this exact scope.

This does not establish all ClickHouse types, other part profiles or server
versions, MV/projection behavior, or a memory/performance improvement. The
shifted-child adversary tests cover the UInt64-key value children, not every
String-key child independently; large budget edges were source-audited but
not stress-tested. Complete paired type coverage and MV/projection support
before returning to memory or performance optimization. Refresh W54 evidence
when the pinned producer, serialization, codec, marks, platform, or shared
reader/writer helpers change.

## W55 admitted frontier: paired recursive Array of named Tuple codec

This type-coverage slice admits exactly `Array(Tuple(a UInt64, b UInt64))`
alongside W51's two existing named-Tuple Array declarations. Use the parsed
type tree to select and traverse the physical child streams for all three
admitted declarations; do not infer physical support merely from successful
syntax parsing. The new declaration has `column.size0`, `column%2Ea`, and
`column%2Eb` in serializer order. Keep its public read/write values concrete
and row-aligned, while sharing the physical plan and fixed-width leaf handling
with the existing W51 paths. This is a type-compatibility change, not a
memory or performance optimization.

The first falsifier was W51's rejection of the exact new declaration: the
test was flipped to require admission and the three-stream plan, followed by a
stock-produced Wide/LZ4 fixture with empty/nonempty rows, zero and maximum
UInt64 values, multiple marks, and a short tail. Compare full and later-mark
reads, selected-table and offline-catalog scans. Independently verify a
Crystal-written part through ClickHouse 26.7.1.1315 `ATTACH PART`,
`CHECK TABLE`, full `RowBinary`, and primary-key-range `RowBinary` against
separately encoded expectations. Re-run W51's existing cases to detect a
regression in String framing and Nullable child cardinality. Negative cases
must reject malformed/unnamed/unsupported recursive types and inconsistent
child marks or stream inventory before yielding values.

Admission remains exact: positional Tuple members, changed field names or
arity, other leaves, nested or nullable outer Arrays, arbitrary recursion,
`Variant`, `Dynamic`, general JSON, MV, and projections stay guard-only. The
strongest likely failure is a plausible three-stream schema whose children
have mismatched per-mark row counts or offsets; retain the existing mark and
staged-writer inventory/readback guards rather than trusting the syntax tree.
Rollback is a single local feature commit (or removal of the uncommitted W55
diff). DoD is a failing pre-change test followed by the focused W55/W51 tests,
full debug and release suites, fixture integrity, and the independent stock
round trip above. Refresh evidence when the pinned ClickHouse producer,
serializer, codec, marks, platform, or shared reader/writer helpers change.

## W55 result: exact two-UInt64 named-Tuple Array

The pinned seven-row stock fixture verifies the exact declaration, three
payload streams plus the UInt64 key stream, LZ4 frames, plain `.mrk2`
marks, and mark rows `[2, 2, 2, 1]`. Its later all-empty granule and short
nonempty tail are read correctly. The reader, typed-table batches (including
one-row batches and a later-row window), and offline catalog preserve both
UInt64 tuple fields and row alignment. Independent mutations of each child
stream's mark row counts and offsets are rejected before any table callback;
the mutations retain the same mark-file length, so size-only checksum checks
are not the reason for rejection.

The immutable writer uses the admitted physical plan for stream order,
mark/frame emission, and staged readback. Stock ClickHouse 26.7.1.1315
accepted the Crystal-written part with `ATTACH PART` and `CHECK TABLE`; its
exact type metadata, full `RowBinary`, and primary-key-range `RowBinary`
matched separately encoded expectations. Repeating W51's stock reverse
oracle after the shared writer change preserved both String-child forms,
including their empty and nullable cases. At this source state, full debug
and release suites each passed 781 examples with zero failures/errors;
fixture integrity, shell syntax, Crystal formatting, and diff checks passed.
A read-only hostile review returned **ROBUST** for this exact scope.

This result establishes only the exact named declaration on the pinned
Wide/LZ4/plain-mark profile. It does not establish all ClickHouse types,
other part profiles or server versions, MV/projection behavior, or a memory
or performance improvement. Table checksum admission is size-only, not
content-hash verification; the tested mark guards are a separate property.
Complete paired type coverage and MV/projection support before returning to
optimization. Refresh W55 evidence if the pinned
producer, serializer, codec, marks, platform, or shared reader/writer helpers
change.

## W56 admitted frontier: paired `Variant(String, UInt64)`

Admit exactly `Variant(String, UInt64)` as a Wide/LZ4/plain-mark payload beside
the existing sorted `UInt64` key. Its typed value domain is `String | UInt64 |
Nil`; `Nil` is the implicit Variant NULL, not a declared `Nothing` arm. The
physical streams are `column.variant_discr`, `column.String.size`,
`column.String`, and `column.UInt64`, in that order. The pinned ClickHouse
26.7.1.1315 producer uses global tags `0` for String, `1` for UInt64, and
`255` for NULL. The discriminator stream starts with an eight-byte
little-endian mode before the first granule: its first plain mark is at
compressed offset `0`, decompressed offset `8`, while the other streams start
at `0, 0`. Mode `1` (COMPACT) carries a VarUInt granule row count,
then format `0` with one tag per row or format `1` with one shared tag; the
format may change between granules. Reader admission must validate the mode,
tag domain, exact granule row counts, child-stream cardinality and marks, and
short-tail/empty-child behavior before returning typed rows. A second stock
probe with `use_compact_variant_discriminators_serialization=0` establishes
mode `0` (BASIC): after the same eight-byte prefix it stores one tag byte per
row, with no granule header. The reader must cover both modes; the first
paired writer may emit COMPACT only.

The first falsifier is a RED spec that requires this exact type to be admitted
and reads a stock-produced fixture with mixed String/UInt64/NULL, an all-NULL
granule, a uniform granule, empty String, and a short final granule. Compare
full and later-mark reads, typed-table and offline-catalog scans. A Crystal
writer must produce an immutable part that the pinned ClickHouse consumer
accepts with `ATTACH PART`, `CHECK TABLE`, exact full `RowBinary`, and
primary-key-range `RowBinary` against separately encoded expectations.
Negative probes must reject illegal tags or formats, wrong count, truncated
discriminators, mismatched child cardinality/marks, and unsupported Variant
declarations before yielding table callbacks. Repeat adjacent scalar String
and UInt64 tests and the full debug/release suites.

This adds a bounded Variant foundation, not arbitrary alternative sets,
`Dynamic`, general JSON, other part formats, MV, projections, or an
optimization. `Dynamic` has structure and SharedVariant streams; general
JSON additionally has Object V3 and shared-data buckets, so neither is
inferred from this admission. Risk tier is CAUTION: a wrong tag-to-child
mapping can return plausible but incorrect rows or publish a part that
ClickHouse rejects. The guard is independent producer/consumer oracles plus
explicit child counts at every mark. Rollback is the one local W56 feature
commit (or removal of its uncommitted diff); do not push or mutate existing
ClickHouse data. Refresh this evidence if the pinned producer, serializer,
codec, mark format, platform, or shared reader/writer helpers change.

Observed W56 result: both pinned stock COMPACT and BASIC fixtures passed the
exact typed reader, later-mark, table-batch, and offline-catalog checks. A
negative first-mark probe established that accepting discriminator offset
`(0, 0)` masked a real compatibility failure: `ATTACH` and `CHECK TABLE`
accepted the Crystal part, but ClickHouse rejected its full `RowBinary` read.
The writer now emits the stock `(0, 8)` first discriminator mark, and the
reader rejects `(0, 0)`. The reverse oracle first checks independently
encoded full and key-range `RowBinary` against a stock COMPACT part, then
checks mixed, all-NULL, and all-String Crystal-written parts through
`ATTACH PART`, `CHECK TABLE`, exact type metadata, and full/key-range
`RowBinary` in ClickHouse 26.7.1.1315. Focused W56 specs passed 8/0;
complete debug and release `crystal spec` suites each passed 789/0 on
Crystal 1.21.0 with the local linker flag. These results cover only the
bounded Wide/LZ4/plain-mark profile and declared schema above; they do not
establish general Variant, arbitrary schema composition, MV/projections,
other ClickHouse versions, or memory/performance gains. Open-time checksum
admission is size-only, so same-size content or mark mutations are not
promised to be detected unless a selected decode or other explicit guard
rejects them.

## W57 admitted frontier: paired three-arm Variant

Admit exactly `Variant(Bool, String, UInt64)` as another Wide/LZ4/plain-mark
payload beside one sorted `UInt64` key; preserve W56's exact two-arm contract.
The public value domain is `Bool | String | UInt64 | Nil`. A physical probe
with pinned ClickHouse 26.7.1.1315, checked by `CHECK TABLE` and stock
`RowBinary`, established canonical order Bool, String, UInt64, with tags
0, 1, 2 and NULL tag 255. The five payload substreams are discriminator,
Bool, String size, String data, and UInt64. Bool contributes one byte per
non-NULL Bool value; empty String remains a distinct String-tagged value.
The producer's nested serialization metadata is the W56 shape with only
`string: 1`, and its COMPACT discriminator first mark has decompressed
offset 8 after the mode prefix. BASIC and COMPACT retain the same stream
topology. These are observations from the pinned binary, not a claim that
the separate local ClickHouse source checkout matches that binary exactly.
The first falsifier is a stock-produced part whose SQL declares alternatives
out of order and whose granules include mixed values, all NULL, one uniform
arm, no Bool values, and a short tail. Compare exact typed values on full and
later-mark reads, table batches, and offline-catalog scans; reject illegal
tags, malformed mode/format/count, mismatched child marks or cardinality,
noncanonical/unsupported Variant declarations, and wrong Bool codes before
yielding callbacks for the affected mark. Earlier valid marks may already
have been yielded by the streaming table scan. A Crystal writer must pass
the pinned consumer's `ATTACH PART`, `CHECK TABLE`, exact type metadata,
full and primary-key-range `RowBinary` against separately encoded
expectations. The stock fixture first calibrates those RowBinary expectations.

Risk tier is CAUTION: reusing W56's tag constants for a new canonical arm
order could silently swap values, while omitting a sparse child mark could
publish an unreadable part. The guard is a descriptor-driven tag/stream plan,
stock BASIC and COMPACT controls, exact child-count checks, and the reverse
oracle. Implementation inventory: `variant_type_plan.cr`, `wide_part.cr`,
`wide_part_writer.cr`, `wide_part_table.cr`, and `offline_catalog.cr` all
contain exact W56 admission or dispatch and must be covered together. Rollback
is one local W57 feature commit or removal of the uncommitted W57 diff; no
existing ClickHouse data root is changed and no remote push is authorized.
DoD is a RED pre-change spec, focused W57/W56 specs, pinned stock fixture and
reverse writer oracles, full debug/release `crystal spec`, and a hostile
counterexample review. This does not admit generic Variant, `Dynamic`, full
JSON, arbitrary schema composition, MV/projection semantics, or any memory or
throughput optimization. Evidence decays if the pinned producer, serializer,
codec, mark format, platform, or shared type dispatch changes.

Observed W57 result: the pinned stock BASIC and COMPACT fixtures passed
full and later-mark typed reads, table batches, and offline-catalog values.
The focused W56/W57 specs passed 14/0; W57's invalid Bool code and unknown
discriminator tag probes failed before callbacks for their affected mark.
A two-mark corruption probe confirms an earlier valid mark can be yielded
while the later malformed mark is rejected before its own callback.
The Crystal COMPACT writer passed the pinned ClickHouse 26.7.1.1315
`ATTACH PART`, `CHECK TABLE`, exact schema, and independently encoded full
and key-range `RowBinary` checks for mixed, all-NULL, all-Bool, and
Bool-absent parts. The prior W56 reverse oracle also passed. Complete debug
and release `crystal spec` suites each passed 795/0 on Crystal 1.21.0 with
the local linker flag. This evidence is restricted to the declared
Wide/LZ4/plain-mark profile and does not establish arbitrary Variant, other
ClickHouse versions, MV/projections, or performance gains. Open-time
checksum admission remains size-only; content integrity is established by
selected decodes and the explicit stock consumer checks above, not by
the open-time checksum size guard alone.

## Observed slice W58: two-level primitive numeric Arrays

W58 admits paired read and immutable write for `Array(Array(T))` where `T` is one
of `UInt8`, `UInt16`, `UInt32`, `UInt64`, `Int8`, `Int16`, `Int32`, `Int64`,
`Float32`, or `Float64`. The physical plan is the existing Wide/LZ4/plain-mark
three-stream topology: per-row outer `.size0` counts, per-inner `.size1`
counts, and one fixed-width leaf stream. The writer retains one sorted
`UInt64` key and one payload column; the reader, typed table batch, and
offline catalog agree on the same admitted set and value type. W28's
`Array(Array(UInt64))` API and W29's `Array(Array(Nullable(UInt64)))` remain
unchanged. The shape is not an admission of generic recursive `Array`,
`Nullable` leaves, semantic numeric types, or other codecs/mark formats.

The pre-implementation gate required a failing test for at least `Int32` and
`Float64` across empty outer/inner arrays, multiple marks, and a short tail.
Reader checks compare both count-stream cardinalities, the selected leaf
byte count and width, and mark rows before exposing an affected mark. Float
values are compared by raw bits where NaNs or signed zero make ordinary
equality insufficient. The independent producer/consumer gate used pinned
ClickHouse 26.7.1.1315: stock-created parts read by Crystal, and
Crystal-created parts accepted by `ATTACH PART`, `CHECK TABLE`, and exact
full/key-range `RowBinary` checks. W28/W29 controls, complete debug and
release specs, and hostile review are required for the W58 claim below.

Risk is CAUTION: a width-dependent leaf stream may self-read while remaining
incompatible with ClickHouse or misalign later marks. Rollback is the W58
feature commit (or the uncommitted diff before it); no existing part is
modified. Failure policy is to reject unsupported shapes and malformed
stream cardinality without yielding rows for the affected mark. The
certificate decays when the producer version, serializer,
codec, mark layout, typed dispatch, or leaf-width handling changes.

Observed W58 evidence: a direct multi-mark `.size0` boundary mutation was
rejected only after the new mark-local guard; the pre-fix test failed and its
post-fix regression passed. The focused W58/W28/W29/W30 specs passed 24/0.
The pinned stock ClickHouse 26.7.1.1315 oracle passed both producer/consumer
directions for all ten leaves, including raw Float bit identity, an empty
middle child mark followed by nonempty data, and fully empty `.size1`/leaf
files. Stock `ATTACH PART`, `CHECK TABLE`, and independently encoded full and
key-range `RowBinary` checks passed for the Crystal writer. Complete debug
and release `crystal spec` suites each passed 801/0 on Crystal 1.21.0 with
the local linker flag. This is evidence for the declared Wide/LZ4/plain-mark
profile only, not arbitrary nested shapes, other ClickHouse versions, or
MV/projection support. Complete type compatibility and then MV/projections
remain ahead of memory/performance work.

## Completed slice W59: two-level String Arrays

Target paired read and immutable write for exactly `Array(Array(String))`
beside a sorted `UInt64` key. The reader, typed table batch, and offline
catalog must preserve each outer/inner boundary and every String's bytes,
including empty, embedded-NUL, and non-ASCII values. The expected Wide/LZ4/
plain-mark streams are outer `.size0`, inner `.size1`, String `.size`, and
String data. A pinned ClickHouse 26.7.1.1315 producer probe confirmed this
logical order in a Wide part with plain marks and `string: 1` serialization
metadata. The W21
String codec and W58 two-level count validation may be reused, but their
separate successes do not prove the composition.

The first physical falsifier is a stock-produced part with empty outer rows,
empty inner Arrays, zero-length Strings, a later nonempty mark after an
all-empty middle mark, a short tail, binary/multibyte Strings, and a String
crossing a compressed frame boundary. Inspect the exact stream inventory,
marks, child cardinalities, and full/key-range `RowBinary`. The first code
falsifier requires this exact type to be admitted and read from that stock
part; it must fail on the pre-W59 reader. After implementation, mutate each
child mark's offset or row count independently and require rejection before
the affected table callback. A Crystal-written part must pass stock
`ATTACH PART`, `CHECK TABLE`, exact schema, and independently encoded full
and key-range `RowBinary`; self-readback alone is insufficient.

The pre-implementation admission test in `wide_part_reader_w59_spec.cr`
failed as predicted on the W58 source (`Expected: true / got: false`, one
example, one failure). This RED result established the missing type gate,
not physical compatibility. The pinned stock producer/consumer oracle now
passes on the exact Wide/LZ4/plain-mark profile: Crystal reads stock parts
with empty middle marks, zero-length and binary/multibyte Strings, a
short tail, and a 5000-byte String spanning two LZ4 frames. The oracle
asserts that the stock 4096-byte frame boundary falls inside that String.
Stock ClickHouse accepts Crystal parts via `ATTACH PART`, passes
`CHECK TABLE`, and returns independently encoded full and key-range
`RowBinary` values. Corruption tests shift each of the four stream marks
independently, reject the selected corrupt mark before callback exposure,
and still read a later valid mark.

Execution order: establish the pinned physical oracle and RED spec in
`scripts/check_array_array_string_oracle.*` and
`spec/wide_part_reader_w59_spec.cr`; then admit and decode the exact shape in
`src/crystal_click/wide_part.cr` with a bounded depth-two plan; then implement
staged writing in `src/crystal_click/wide_part_writer.cr`; finally connect
`src/crystal_click/wide_part_table.cr` and
`src/crystal_click/offline_catalog.cr`. Each step must retain W21/W58
controls and the unsupported-shape guards. Do not treat plan syntax or a
Crystal self-read as physical compatibility evidence.

Risk is CAUTION: a String length stream can appear locally consistent while
later marks or stock ClickHouse consume different byte boundaries. The guard
is mark-local count/byte validation plus the pinned bidirectional oracle.
Full debug and release `crystal spec` suites each passed 808/0 on Crystal
1.21.0 with the local linker flag; formatting and diff whitespace checks
passed. The hostile review found no concrete W59 blocker within this profile.
Local checksum preflight only validates selected file sizes; stock
`CHECK TABLE` supplies the separate content-integrity check for the writer
oracle. Rollback is the W59-only local feature commit; no existing part was
modified. Keep `Array(Array(Nullable(String)))`, deeper recursion,
other leaves, Compact/compressed marks, general JSON, MV/projections, and
performance guard-only. Evidence decays if the pinned producer, serializer,
codec, marks, platform, or shared reader/writer helpers change.

## W60: two-level nullable primitive numeric Arrays

Admit paired immutable writing and typed reading for exactly
`Array(Array(Nullable(T)))`, where `T` is `UInt8`, `UInt16`, `UInt32`,
`UInt64`, `Int8`, `Int16`, `Int32`, `Int64`, `Float32`, or `Float64`.
Preserve W29's existing `UInt64` entry points. The target is one sorted
`UInt64` key and one payload in a Wide/LZ4/plain-mark part. It must expose
the same values through direct mark reads, typed table batches, and offline
catalog columns, without treating parser acceptance as physical admission.
Other nullable leaves, deeper nesting, Sparse serialization, Compact parts,
compressed marks, and arbitrary schemas remain guard-only.

The expected physical plan is four independently checked streams: outer
`.size0`, inner `.size1`, BASIC null map, and fixed-width leaf data. First
confirm their exact names, serialization metadata, mark rows, empty-stream
behavior, and mark-local cardinalities with a pinned ClickHouse 26.7.1.1315
producer. A pre-change RED spec must fail on at least `Int32` and `Float64`
type admission. Stock-produced test rows must distinguish NULL from numeric
zero (and signed zero/NaN by raw bits), cover empty outer and inner Arrays,
all-NULL and all-empty middle marks followed by nonempty leaves, and a short
tail. Mutate the selected mark of each physical stream independently and
require rejection before the affected table callback; earlier valid marks
may already have been yielded. Reverse evidence requires stock `ATTACH PART`,
`CHECK TABLE`, exact type metadata, and independently encoded full and
key-range `RowBinary` for Crystal-written parts. Self-readback is insufficient.

Risk is CAUTION: nullable leaf slots have physical bytes even for NULL, and
incorrect count or mark alignment could silently shift later values. Guard
each selected mark's rows and flattened child cardinality before exposing
it. Implement only after the physical probe and RED spec; connect reader,
writer, table, catalog, specs, and oracle as one feature. The DoD is focused
W60/W29/W31/W58 controls, the bidirectional pinned oracle, full debug and
release `crystal spec`, and a hostile counterexample review. Rollback is
removal of the isolated uncommitted diff or one local W60 feature commit;
existing parts and remote history are untouched. Evidence decays when the
pinned ClickHouse serializer, codec/mark format, platform, or shared nested
array dispatch changes. Type compatibility, then MV/projections, remain
ahead of memory/performance tuning.

The pre-change admission spec failed as predicted (`Expected: true`, got
`false`) for a formerly unsupported leaf. An isolated stock-producer probe
for `Int32` and `Float64` confirmed `.size0`, `.size1`, `.null`, and the root
value stream, in that order, with one null byte and one fixed-width physical
slot per flattened leaf. NULL slots contained zero data bytes of the leaf
width; an all-empty middle mark advanced only `.size0`, while the other
stream offsets repeated. Each stream carried base-row MRK2 counts
`[2, 2, 2, 1, 0]` including the short tail and sentinel. The probe alone
did not establish paired implementation or all-ten stock compatibility.

The paired reader and staged writer now admit all ten leaves on this exact
profile. Direct reads, typed table batches, and catalog-owned materialization
were checked, including W29 `UInt64` API preservation and four-stream
corruption rejection before the selected table callback. The pinned
ClickHouse 26.7.1.1315 bidirectional oracle passed for all ten leaves:
stock-produced parts decoded in Crystal, and Crystal-written parts passed
stock `ATTACH PART` and `CHECK TABLE` plus independently encoded full and
key-range `RowBinary`. It also checked exact column and substream metadata,
per-stream mark rows, empty and all-NULL middle marks, nonempty outer Arrays
with empty inner Arrays, and raw Float bit patterns. W29 and W58 stock oracles
passed as regression controls. Full debug and release `crystal spec` each
passed 815/0 on Crystal 1.21.0 with the local linker flag; formatting and
diff whitespace checks passed. A read-only hostile review of the oracle first
found missing edge cases; after adding them and rerunning the oracle, repeat
oracle and implementation reviews found no concrete blocker in the pinned
scope. This evidence does not generalize to other serializers, marks, codecs,
or arbitrary nested types. MV/projection coverage and type compatibility
remain ahead of memory or performance tuning.

## W61: two-level nullable String Arrays

Admit paired immutable writing and typed reading for exactly
`Array(Array(Nullable(String)))` beside a sorted `UInt64` key in one
Wide/LZ4/plain-mark part. Preserve NULL versus empty String, arbitrary String
bytes (including embedded NUL and multibyte text), every outer and inner
Array boundary, and W59/W32 entry points. Expose the values through direct
mark reads, typed table batches, and offline catalog columns. Parser
acceptance or Crystal self-readback alone is not physical compatibility.

The refreshed pinned ClickHouse 26.7.1.1315 BASIC/Wide probe confirms five
streams in order: outer `.size0`, inner `.size1`, BASIC `.null`, String `.size`,
and root String data, with String serialization version 1. Every leaf,
including NULL, contributes one byte to `.null` and one UInt64 to `.size`;
stock NULL writes length zero and no raw payload. The direct reader must still
consume valid noncanonical hidden String bytes for a NULL leaf, as in the
W32 reader contract. The oracle must independently recheck exact
`columns.txt`, `columns_substreams.txt`, `serialization.json`, mark rows and
offsets, zero-byte child-stream behavior, and per-mark cardinality.
The probe must distinguish NULL from an empty non-NULL String and include
empty outer and inner Arrays, an all-NULL middle mark, an all-empty middle
mark followed by nonempty leaves, a short tail, binary/multibyte bytes, and
a String crossing a compressed frame boundary.

A pre-change admission spec must fail for the exact W61 type. Reader and
table tests must mutate each of the five selected stream marks independently
and reject the affected mark before its callback; earlier valid callbacks
may already have occurred. The writer must stage and validate before atomic
publication, then pass stock `ATTACH PART`, `CHECK TABLE`, exact type and
substream metadata, and independently encoded full and key-range
`RowBinary`. Retain W59/W32/W60 controls, including rejection of deeper
nesting and unsupported wrappers. The DoD is the focused falsifiers, pinned
bidirectional oracle, complete debug and release `crystal spec`, formatting
and diff checks, and hostile counterexample review.

Risk is CAUTION: nullable String lengths and raw bytes can be internally
consistent while shifting a later mark or confusing NULL with empty String.
Guard every selected mark's five row counts, nested cardinalities, null-map
domain, length count, and raw-byte consumption before exposing rows. The
existing nested-nullable numeric prefix dispatch in table and catalog code
must not claim the exact String shape; test W61 dispatch ahead of that branch.
Rollback is removal of the isolated W61 diff or its single local feature
commit; no existing part is mutated. Other recursive types, Sparse
serialization, Compact parts, compressed marks, arbitrary schemas,
MV/projections, and performance remain guard-only. Evidence decays when the
pinned producer, serializer, codec/mark format, platform, or shared
nested-array dispatch changes. The full type frontier, then MV/projections,
precedes memory and performance optimization.

The RED admission spec failed before implementation. W61 now has the exact
five-stream reader, staged writer, typed table batches, and deep-owned offline
catalog materialization. Reader specs exercise NULL versus empty String,
hidden noncanonical bytes under NULL, per-mark raw-byte preflight, invalid
null-map bytes, and shifted boundaries in each selected stream; table specs
reject a corrupt selected mark before callback. The pinned ClickHouse
26.7.1.1315 oracle passed in both directions: stock-produced bytes and MRK2
offsets were independently checked and decoded by Crystal; a Crystal-written
part passed stock `ATTACH PART` and `CHECK TABLE`, exact metadata, and full
and key-range `RowBinary`. The stock fixture also crossed a 4096-byte LZ4
frame boundary and exercised all-NULL and empty-child middle marks. Full
debug and release `crystal spec` each passed 825/0 with the host linker
override; formatting and diff whitespace checks passed. Hostile review found
no concrete blocker within this scope, but compressed-offset and sentinel
mutation coverage can still be strengthened. This is not evidence for other
serializations, mark formats, codecs, or MV/projections.

## W62: two-level wide numeric Arrays

Admit paired reading and immutable writing for exactly `Array(Array(T))` and
`Array(Array(Nullable(T)))`, where `T` is `Int128`, `UInt128`, `Int256`,
`UInt256`, or `BFloat16`. These five leaves already have paired one-level
Array codecs. Reuse the existing three- and four-stream nested-array path;
do not infer arbitrary recursive composition from type-parser acceptance.
The public scope is one sorted `UInt64` key and one payload in a
Wide/LZ4/plain-MRK2 part, with direct mark reads, typed table batches, and
offline catalog access. Existing W58/W60 primitive leaves and W59/W61 String
leaves remain unchanged. `Bool`, temporal, UUID/IP, Decimal, Enum,
FixedString, Map-of-Array, deeper Arrays, JSON, arbitrary table schemas,
MV/projections, and performance tuning remain guard-only.

The falsifier is a pre-change admission spec for a wide leaf and a nullable
wide leaf. Before implementation, the pinned ClickHouse 26.7.1.1315 producer
must confirm the selected physical stream names, mark-local cardinalities,
nullable placeholder bytes, and metadata for representative 2-, 16-, and
32-byte leaves. The paired oracle must then check every one of the five
leaves in both nullability modes: stock-produced parts decoded by Crystal,
and Crystal-written parts passing stock `ATTACH PART`, `CHECK TABLE`, exact
type/substream metadata, and independently encoded full and key-range
`RowBinary`. Fixtures must cover empty outer and inner Arrays, NULL versus
zero or signed values, an all-empty or all-NULL middle mark followed by data,
and a short tail. A selected-mark corruption in each physical stream must be
rejected before that mark's table callback; earlier valid callbacks may have
been yielded.

Risk is CAUTION: 16/32-byte widths and BASIC NULL placeholders can silently
shift later marks or deserialize as plausible but wrong values. Guard all
selected stream row counts, flattened cardinalities, widths, null-map domain,
and byte consumption. The DoD is focused W62 and W58/W60 controls, the pinned
bidirectional oracle, complete debug and release `crystal spec`, formatting
and diff checks, then hostile counterexample review. Rollback is the isolated
uncommitted diff or one local W62 feature commit; existing parts and remote
history are untouched. Evidence decays when the pinned producer, serializer,
codec/mark format, platform, or shared numeric/nested-array codec changes.
This type-parity slice does not advance the later MV/projection or optimization
phases.

The pre-change admission spec failed as predicted. W62 now reuses the
one-level numeric leaf whitelist for exact two-level plain and nullable
admission, with paired writer, typed table batch, and offline catalog paths.
The pinned ClickHouse 26.7.1.1315 oracle passed for all five leaves in both
directions: Crystal read stock parts; stock `ATTACH PART` and `CHECK TABLE`
accepted Crystal parts; exact metadata and full/key-range `RowBinary`
matched. The W58/W60 primitive nested-numeric oracles also passed. Complete
debug and release `crystal spec` each passed 834/0 with the host linker
override; formatting and diff whitespace checks passed. Reader and writer
specs cover exact leaf bytes, NULL placeholders, empty/all-NULL middle marks,
selected marks, and shifted mark boundaries. Hostile review found no concrete
blocker within this pinned scope. Direct table/catalog materialization is
tested for nullable `BFloat16`; the other four wide leaves have explicit
dispatch and stock/read/write tests, not separate table/catalog integration
fixtures. This evidence does not establish arbitrary recursive types, other
part profiles, MV/projections, or any performance result.

## W63: bounded Map of UInt64 Arrays

Admit paired reading and immutable writing for exactly
`Map(String, Array(UInt64))` in the existing one-sorted-`UInt64`-key,
one-payload Wide/LZ4/plain-MRK2 part profile. Preserve the Map as an ordered
array of key/value tuples: duplicate String keys and their insertion order
are observable and must not be collapsed into a Hash. Expose direct selected
mark reading, typed table batches, and offline catalog values. This slice
does not admit other Map key or value types, arbitrary composition, Compact
parts, MV/projections, or a performance claim.

The pinned ClickHouse 26.7.1.1315 producer accepted this exact type and
`CHECK TABLE` passed. `columns_substreams.txt` listed the payload streams in
serializer order as `payload.size0`, `payload%2Ekeys.size`,
`payload%2Ekeys`, `payload%2Evalues.size1`, and `payload%2Evalues`.
`size0` counts Map entries per row; `values.size1` counts UInt64 elements
per Map entry. The two offset levels must not be interchanged or inferred
from existing root-Array readers. A pre-change admission spec is the first
falsifier; then test stock-produced parts decoded by Crystal and
Crystal-written parts accepted by stock `ATTACH PART` and `CHECK TABLE`.
Compare exact type/substream metadata plus independently encoded full and
key-range RowBinary. Fixtures include empty maps, empty value Arrays,
duplicate keys, repeated equal values, a short tail, and an empty middle
mark followed by data. Shifted selected-stream mark boundaries or invalid
cardinalities must fail before the affected table callback.

Risk is CAUTION: wrongly nested offsets can silently shift later marks while
plausibly decoding early values. Guard exact per-mark row, Map-entry,
String-key, and UInt64-element counts; stream byte consumption; overflow;
and selected mark boundaries. DoD is focused W63 tests, existing Map and
nested-Array controls, the pinned bidirectional oracle, complete debug and
release specs, formatting/diff checks, and a hostile counterexample review.
Rollback is the isolated uncommitted diff or one local W63 feature commit;
existing parts and remote history are untouched. Evidence decays if the
pinned producer, serializer/version, codec/mark format, platform, or shared
Map/Array codec changes.

The pre-change admission spec failed as predicted. The pinned ClickHouse
26.7.1.1315 bidirectional oracle passed: Crystal decoded a stock-produced
part; stock `ATTACH PART` and `CHECK TABLE` accepted a Crystal-written part;
exact metadata and independent full/key-range RowBinary matched. Focused
reader tests rejected shifted selected boundaries in each of the five
physical streams and a mismatched `values.size1` count. Typed table tests
rejected selected key and nested-value corruption before callbacks; catalog
tests checked ordered duplicate keys, owned values, and the string budget.
Existing String-key Map and nested UInt64 Array stock oracles passed. Complete
debug and release `crystal spec` each passed 845/0 with the host linker
override; Crystal formatting, shell syntax, and diff whitespace checks
passed. A bounded hostile review found no concrete W63 blocker. This evidence
does not establish arbitrary recursive Maps, other part profiles, MV or
projection support, detection of arbitrary same-size payload bit flips beyond
existing checksum semantics, or a performance result.

## W64: two-level Decimal Arrays

Admit paired reading and immutable writing for exactly
`Array(Array(Decimal(P, S)))` and
`Array(Array(Nullable(Decimal(P, S))))`, where `P` is one of 9, 18, 38, or
76 and `0 <= S <= P`, in the existing sorted-`UInt64`-key, one-payload
Wide/LZ4/plain-MRK2 part profile. Crystal values are raw signed coefficients
(`Int32`, `Int64`, `Int128`, or `Decimal256Value`); the declared scale and
precision are retained in metadata, not inferred from coefficient values.
Expose selected-mark reading, typed table batches, and offline catalog values.
Do not admit arbitrary `Decimal(P, S)` precision, deeper Array nesting,
Compact parts, or other codecs. Complete paired type coverage first, then
MV/projection support, before memory or performance optimization.

The first falsifier observed pre-change rejection of a representative nested
Decimal declaration; the remaining widths had no admitted branch. The pinned
ClickHouse 26.7.1.1315 producer must then
establish exact canonical declarations and serializer-order streams, including
two independent offset levels and nullable leaf null-map. Reader and writer
must agree on per-mark row, inner-array, and flattened-leaf cardinality; raw
width, NULL placeholder, stream-byte, and selected-mark boundaries; and reject
corruption before the affected table callback. Exercise zero and maximum
scales, positive/negative coefficient extremes, empty outer and inner arrays,
all-NULL middle marks, and short tails. The bidirectional stock oracle must
compare metadata and independent full/key-range RowBinary and pass stock
`ATTACH PART` plus `CHECK TABLE` on Crystal-written parts.

Risk is CAUTION: a wrong nested offset, signed-width, or scale identity can
silently produce plausible but shifted data. Rollback is the isolated W64 diff
or one local feature commit; no existing parts or remote history are changed.
DoD is focused W64 specs, existing nested numeric and single-level Decimal
controls, the pinned bidirectional oracle, complete debug and release specs,
format/diff checks, and hostile counterexample review. Evidence decays when
the pinned producer, serializer/version, codec/mark format, platform, or
shared nested/Decimal codec changes.

The pre-change admission falsifier failed as predicted. The pinned ClickHouse
26.7.1.1315 bidirectional oracle passed for all eight width/nullability
profiles: Crystal decoded stock parts; stock `ATTACH PART` and `CHECK TABLE`
accepted Crystal parts; exact column/substream/serialization metadata and
independent full/key-range `RowBinary` matched. A separate writer-only
Decimal32 probe passed stock attach, check, and RowBinary for the full raw
`Int32::MIN`/`Int32::MAX` backing range, which intentionally exceeds SQL
`Decimal(9, S)` precision while retaining the existing raw-coefficient API
contract. Focused specs covered zero/maximum legal scales, empty and all-NULL
middle marks, short tails, catalog-owned values, and rejection of shifted
selected-stream boundaries before callbacks. Complete debug and release
`crystal spec` each passed 853/0 with the host linker override; the W58/W60
nested numeric and W42-W45 one-level Decimal stock controls passed. Crystal
formatting, shell syntax, and diff whitespace checks passed. This evidence
does not establish arbitrary Decimal precision/composition, MV or projection
semantics, other part formats or ClickHouse versions, or a memory/performance
gain. A bounded hostile review returned ROBUST within the W64 scope and found
no concrete blocker; its out-of-precision raw-coefficient candidate was
falsified by the pinned Decimal32 backing-extrema probe.

## W65 admitted frontier: two-level temporal Arrays

Admit paired reading and immutable writing for `Array(Array(T))` and
`Array(Array(Nullable(T)))` where `T` is exactly `Date`, `Date32`,
`DateTime`, or canonical `DateTime64(p)` with one digit `0 <= p <= 9`.
The part profile remains one sorted `UInt64` key plus one payload in
Wide/LZ4/plain-`.mrk2` format. Public values are raw `UInt16` day codes,
`Int32` day codes, `UInt32` epoch seconds, or `Int64` ticks. The exact
temporal declaration, including `p`, is mandatory even where the physical
width matches an integer leaf. Selected-mark readers, typed batches,
offline catalog values, and explicit writers must agree. This does not
admit timezone-qualified declarations, calendar conversion, deeper Arrays,
other codecs/part formats, or generic recursive type composition.

The first falsifier is pre-change rejection of a representative nested
`DateTime64(3)` declaration. The pinned ClickHouse 26.7.1.1315 producer
must establish serializer-order `size0`, `size1`, optional leaf null-map,
and temporal data streams, their exact marks, canonical metadata, and
RowBinary semantics before admission. Exercise empty outer and inner
Arrays, zero versus NULL, signed date/tick boundaries, scales 0/3/9,
an all-NULL middle granule, and a short final granule. Reject selected
offset/null/data cardinality or mark-boundary corruption before the affected
table callback, and reject wrong declarations or invalid writer input
before publication. A bidirectional stock oracle must compare independent
full and key-range RowBinary and require `ATTACH PART` plus `CHECK TABLE`
for Crystal-written parts.

Risk is CAUTION: same-width numeric substitution or wrong nested offsets
can silently return plausible rows or publish an unreadable part. Guard
exact type identity, all three cardinality levels, selected stream bytes,
and the stock producer/consumer oracle. Rollback is the isolated W65 diff
or one local W65 feature commit; existing parts and remote history are
untouched. DoD is the RED admission spec, focused W65 tests, W40 temporal
and W58/W60 nested controls, the bidirectional stock oracle, complete
debug and release suites, format/diff checks, and hostile self-review.
Evidence decays on producer/serializer version, codec/marks, platform,
or shared nested/temporal codec changes. General `JSON`, `Dynamic`, arbitrary
`Variant`, MV/projections, and memory/performance optimization remain
guard-only.

The RED admission spec failed before implementation. The pinned ClickHouse
26.7.1.1315 bidirectional oracle passed for 12 stock-produced and 12
Crystal-produced paired profiles: plain and BASIC nullable `Date`, `Date32`,
`DateTime`, and `DateTime64` at scales 0, 3, and 9. It checked exact
declarations, `serialization.json`/codec/substream metadata, stream topology,
plain `.mrk2` rows, raw readback, independent
full/key-range `RowBinary`, and stock `ATTACH PART`/`CHECK TABLE` for each
Crystal part. The stock producer pins
`ratio_of_defaults_for_sparse_serialization = 1.0`; without that setting,
stock adds an adaptive default-serialization entry for the key, so exact
metadata equality is not claimed for that alternate profile. Focused W65
specs cover empty outer/inner Arrays, raw carrier
extrema, zero versus NULL, an all-NULL middle mark, a short tail, typed
batch/catalog values, same-width numeric accessor rejection, invalid scale
and pre-stage input rejection, nonzero child bytes hidden under NULL, and
selected later-mark size0/size1/null/data corruption before any callback.
The W40 one-level temporal, W58 nested numeric, and pinned W40 stock controls
passed. Complete debug and release `crystal spec` each passed 859/0 with the
host linker override; formatting, shell syntax, and diff checks passed. A
bounded hostile review found no concrete blocker and returned ROBUST within
this exact W65 scope. These signals do not establish arbitrary temporal
composition, timezone variants, other part formats or ClickHouse versions,
or a memory/performance gain.

## Verified W66 slice: paired two-level Time and Time64 Arrays

Target admission is exactly `Array(Array(Time))`,
`Array(Array(Nullable(Time)))`, `Array(Array(Time64(p)))`, and
`Array(Array(Nullable(Time64(p))))` for canonical one-digit `p = 0..9`.
The part profile remains one sorted `UInt64` key plus one payload in
Wide/LZ4/plain-`.mrk2` format. Public values are raw signed `Int32` Time
seconds or raw signed `Int64` Time64 ticks; preserve the exact logical type and
precision without text, clock, or timezone conversion. Reader, typed batch,
offline catalog, and immutable writer APIs must agree. No other wrapper or
composition is admitted.

The first admission falsifier was a RED spec for these exact declarations:
on the pre-W66 source `Array(Array(Time))` was not admitted, while malformed
precision, timezone, double-nullable, and nullable-outer controls rejected.
W66 now admits only the listed forms; Time64 scales 0 through 9 are parsed
canonically and the same-width numeric and other temporal accessors reject the
W66 metadata. Raw accessors are
`read_array_array_time_seconds_mark_range`,
`read_array_array_time64_ticks_mark_range`, and their nullable counterparts;
the paired writers are `write_uint64_array_array_time_pair`,
`write_uint64_array_array_time64_pair`,
`write_uint64_array_array_nullable_time_pair`, and
`write_uint64_array_array_nullable_time64_pair`. Table batches and offline
catalog projections are covered by the focused reader spec.

The pinned ClickHouse local 26.7.1.1315 probe created a five-row Wide part
with nested `Time`, nullable nested `Time`, `Time64(3)`, and nullable nested
`Time64(3)` payloads. `columns_substreams.txt` ordered plain streams as
`size0`, `size1`, data, and nullable streams as `size0`, `size1`, `null`,
data. Its `.mrk2` rows were `[2, 2, 1, 0]`; sample decompressed data offsets
were `[0, 0, 16, 20]` for Time and `[0, 0, 32, 40]` for Time64(3), while
nullable null-stream offsets were `[0, 0, 5, 6]`. The nested decimal-seconds
SQL probe needed explicit `CAST(... AS Time64(3))`; without it, the expression
inferred Float64 and failed before part creation (an input typing issue, not a
storage divergence).

The completed bidirectional oracle on that pinned binary covers all eight
plain/nullable variants: Time and Time64 scales 0, 3, and 9. Stock-produced
parts are checked for exact metadata, substream order, Wide/LZ4/plain-`.mrk2`
shape, and mark rows `[2, 2, 2, 1, 0]`; Crystal reads exact types and raw
values over full and later-mark ranges. Crystal-produced parts are attached to
stock tables and pass `CHECK TABLE`; independently encoded full and keyed
RowBinary match exactly. Crystal-written Time vectors include `Int32::MIN` and
`Int32::MAX`; Time64(0/3/9) vectors include `Int64::MIN` and `Int64::MAX`,
including nullable variants, and stock preserves those raw codes through
attachment and RowBinary. Vectors also cover empty outer/inner arrays, zero
versus NULL, an all-NULL middle mark, and a one-row short tail.

Focused W66 reader/writer specs pass (6 examples); combined W50/W65/W66 reader
and W66 writer controls pass (18 examples). The full debug and release suites
each pass (865 examples, 0 failures/errors/pending). The reader corruption
spec shifts selected later-mark `.size0`, `.size1`, `.null`, and data offsets;
each fails with `CorruptPartError` before a callback. A resealed nullable
frame with nonzero hidden child bytes under NULL is consumed and those bytes
are ignored. Invalid Time64 scale and unsorted keys fail before a writer
publishes output. W50's stock oracle also passes its temporal writer controls;
the W65 bidirectional oracle passes 12 stock and 12 Crystal parts.

Risk remains CAUTION: Time shares an `Int32` carrier with other semantic types
and Time64 shares `Int64` with other semantic types, while wrong nested
offsets can shift otherwise plausible values. The verified compatibility
claim is scoped to one sorted `UInt64` key plus one payload, Wide/LZ4/plain
`.mrk2`, and the pinned ClickHouse 26.7.1.1315 producer/consumer. It does not
establish timezone-qualified forms, other codecs/part formats or ClickHouse
versions, arbitrary Array depth, generic recursive types, MV/projections, or
memory/performance behavior. Evidence decays on ClickHouse
producer/serializer, codec/mark, platform, or shared nested/temporal codec
changes. Rollback is the isolated W66 diff or one local W66 feature commit;
do not push.

## W67 verified: compositional physical plan in shadow mode

The type-compatibility goal needs a reusable physical plan before more
Array/Map/Tuple/Nullable combinations are admitted. `WideTypePlan.parse`
currently accepts more syntax than `WideTypePlan.admitted`, while the latter
describes physical streams for only five exact declarations. W63's
`Map(String, Array(UInt64))` has a separate physical path. W67 adds a
bounded shadow descriptor for stream order, semantic leaf identity, width,
and cardinality axes; it must not make a parseable type readable or writable.
Existing exact admission and public reader/writer behavior stay unchanged.

The first candidate falsifier is `Map(String, Array(Nullable(UInt64)))`.
A pinned ClickHouse local 26.7.1.1315 Wide/LZ4/plain-`.mrk2` producer probe
observed six payload streams in serializer order: `payload.size0`,
`payload%2Ekeys.size`, `payload%2Ekeys`, `payload%2Evalues.size1`,
`payload%2Evalues.null`, and `payload%2Evalues`. The stock table preserved
duplicate String keys, empty maps and value Arrays, and NULL distinct from
zero. This is topology evidence, not reader/writer admission. Exact mark and
stream cardinalities were probed separately. Each of the seven streams,
including `pk`, has four 24-byte `.mrk2` records with row counts
`[2, 2, 1, 0]` (the final record is a zero-row sentinel). Raw decompressed
offsets by stream are `pk` and `payload.size0` `[0, 16, 32, 40]`,
`keys.size` and `values.size1` `[0, 16, 40, 48]`, key bytes
`[0, 6, 19, 23]`, `values.null` `[0, 2, 4, 5]`, and value bytes
`[0, 16, 32, 40]`. The three data granules have respectively
`(Map entries, key bytes, value elements)` counts `(2, 6, 2)`,
`(3, 13, 2)`, and `(1, 4, 1)`. The vector includes duplicate `dup` keys,
empty Maps/Arrays, `[NULL, 0]`, `[NULL]`, `[0]`, and `UInt64::MAX`;
the null and UInt64 streams retain a slot for each value element, even
when NULL. The part reports Wide and `CODEC(LZ4)` with uncompressed marks;
this producer evidence is pinned to binary 26.7.1.1315, not the older
local source checkout. The probe's temporary stock part remains under
`/private/tmp/w67-map-nullable.GUqdjX/`, but the temporary path is not a
durable oracle; repeat the pinned producer probe if the serializer changes.

The shadow plan must model independent axes: table rows, Map entries,
per-entry Array elements, and variable String bytes. The `.mrk2` rows field
remains table rows on every stream; it does not replace the payload's axis.
Map keys and values share the entry axis; `values.size1` maps entries to
elements; `values.null` and the UInt64 child data share the element axis.
An Array count stream maps its parent slots to child slots, Tuple fields
share parent slots, and Nullable's null map and child share slots. The plan
must preserve semantic leaf identity when multiple types have equal width.

The RED test failed to compile on the absent `WidePhysicalPlanShadow`.
The green descriptor tests use literal expected fingerprints for the stock
candidate and W51/W55/W59/W61/W63 controls: ordered stream names, semantic
types and paths, widths, one-byte-per-slot null maps, storage/cardinality
axes, and the table-row mark axis. Map keys and values share the same entry
axis, and nullable flags and value bytes share the element axis. The existing
`admitted` set and `WidePart.supports_typed_type?` still reject the candidate.
The type-only plan cannot validate the stock vector's numeric mark offsets;
the next reader/writer slice must make them executable oracle evidence before
admission. No generic recursive codec, new readable/writable column type,
MV/projection, or performance claim is admitted by W67. A future consumer
must pass the canonical physical column name to `for_type`.

Risk remains CAUTION: an apparently equivalent stream list can conceal wrong
per-mark cardinalities or accidentally broaden type admission. The focused
descriptor spec passes 2 examples; focused W51/W55/W59/W61/W63 controls pass
32 examples. Full debug and release specs each pass 867 examples with 0
failures/errors/pending. The pinned W63 bidirectional stock oracle passes;
formatting and diff-whitespace checks pass. A hostile static review returned
ROBUST within this type-only scope, while marking numeric producer-backed
assertions as mandatory for the next codec slice. Rollback is the isolated
W67 diff or one local feature commit; no part or remote history was mutated.
Evidence decays on a ClickHouse serializer, mark-layout, parser, or shared
type-dispatch change.

## W68 design-sealed: nullable UInt64 Arrays inside String-key Maps

The next exact type is `Map(String, Array(Nullable(UInt64)))` for a sorted
`UInt64` key and one payload column in Wide/LZ4/plain-`.mrk2` parts. W63
already reads and writes the non-nullable sibling, and W67 has a shadow
physical plan for both. The pinned 26.7.1.1315 stock producer probe above
is the format anchor; it does not itself prove Crystal can consume or produce
this candidate. A second pinned stock probe extended the vector to seven rows:
rows 5 and 6 carry only NULL nested values and row 7 has a non-NULL tail.
All seven streams have `.mrk2` row counts `[2, 2, 2, 1, 0]`. Decompressed
offsets are `pk` and `payload.size0` `[0, 16, 32, 48, 56]`,
`keys.size` and `values.size1` `[0, 16, 40, 56, 64]`, key bytes
`[0, 6, 19, 36, 40]`, `values.null` `[0, 2, 4, 7, 8]`, and values data
`[0, 16, 32, 56, 64]`. This gives `(entries, key bytes, value elements)`
per data mark `(2, 6, 2)`, `(3, 13, 2)`, `(2, 17, 3)`, `(1, 4, 1)`; the
third mark proves that NULL elements still occupy 8-byte value slots.
No performance or allocation change is intended.

Admit one typed reader accessor, the matching table/batch/catalog value
surface, and one immutable-part writer only after their own RED tests and
the bidirectional stock oracle pass. Preserve ordered Map entries and
duplicate keys; never collapse them into a dictionary. `size0` counts entries
per table row, `keys.size` counts bytes per entry, `values.size1` counts
nullable UInt64 elements per entry, and `.values.null` plus `.values` each
contains one slot per flattened element, including NULL. Every `.mrk2` row
coordinate remains the table-row coordinate. NULL payload bytes are consumed
but ignored by the reader; the writer emits a deterministic hidden value.

Reject generic Map admission, non-String keys, a different value leaf or
Array depth, Compact parts, unrelated codecs, and server MV/projection or
merge behavior. Parsing a broader type remains guard-only. Malformed stream
sets, shifted marks, per-mark count/byte mismatches, inconsistent null/data
cardinality, unsorted primary keys, and writer overflow must fail closed.
Construction-time metadata corruption is rejected before any callback;
data corruption discovered during a mark-lazy scan is rejected before a
callback for that affected mark, while earlier valid marks may already have
been delivered. Writer validation must fail before output publication. The
current stock vector's empty Map,
empty Array, repeated key, NULL versus zero, and short terminal granule are
mandatory tests; an all-NULL granule and selected later-mark read are the
adversarial additions.

Risk is CAUTION because the writer could produce an attachable but shifted
part, or the reader could return plausible wrong values after an empty mark.
Rollback is the isolated W68 diff or one local feature commit; do not mutate
existing parts or remote history. DoD is RED-to-green reader/writer and
catalog/table specs, selected-mark corruption guards, exact metadata/stream
order/marks, pinned stock-to-Crystal and Crystal-to-stock `ATTACH PART` plus
`CHECK TABLE` and exact full/keyed RowBinary, existing W63 controls, full
debug and release suites, and a hostile counterexample review. Evidence
decays on a ClickHouse serializer/mark change, a shared nested codec or
catalog dispatch change, or a different ClickHouse version.

## W68 verified: exact nested nullable Map reader and writer

The missing writer API, table batch accessor, and catalog value-union member
were first observed as RED checks. W68 reader, writer, table, and catalog
focused specs then passed; the combined W63/W68 reader/writer/table control
passed 23 examples before the later-mark falsifier was added. The stale W63
and W67 negative-admission expectations
were updated only for this exact type; the generic physical-plan admission
remains closed. A later-mark null-frame mutation with a valid compressed
checksum was rejected before that mark's callback after four valid earlier
rows had been delivered. This falsified the stronger whole-scan zero-callback
wording and established the mark-local guarantee above.

At the final W68 source state on Crystal 1.21.0 and Darwin, the full debug
and release suites each passed 882 examples with zero failures/errors. The
debug/release commands used an isolated `CRYSTAL_CACHE_DIR` because a prior
concurrent run lost its temporary spec executable while a process-reexec
test was active; that prior run is not counted as product evidence. The
pinned official ClickHouse local 26.7.1.1315 bidirectional oracle passed:
stock-produced seven-row Wide/LZ4 part metadata and every `.mrk2` vector,
full/all-NULL/later/cross-mark Crystal reads, then Crystal writer output
accepted via `ATTACH PART`, clean `CHECK TABLE`, and exact full/keyed
RowBinary. Formatting, shell syntax, and diff-whitespace checks passed.
Hostile review returned ROBUST within this exact type and part scope after
the callback claim was narrowed and the late-corruption falsifier added.

This certificate does not cover generic Maps, Compact parts, alternative
codecs, a running server's restart lifecycle, MV/projection semantics, or
speed/allocation parity. Its evidence decays on a ClickHouse serializer,
mark-layout or version change, a shared reader/writer/table/catalog dispatch
change, or a platform change; refresh the focused/full tests and pinned
bidirectional oracle before reusing the interoperability claim.

## W69 design-sealed: numeric keys with nullable UInt64 Array values

The next exact payload is `Map(UInt64, Array(Nullable(UInt64)))` beside one
sorted `UInt64` primary key in a Wide/LZ4/plain-`.mrk2` part. This composes
the existing numeric-key Map and W68 nullable Array value paths without
admitting generic recursive Maps. The local ClickHouse source models Map as
an Array of a named key/value Tuple. The pinned ClickHouse 26.7.1.1315
producer generated exactly five payload streams in this order:
`payload.size0`, `payload%2Ekeys`, `payload%2Evalues.size1`,
`payload%2Evalues.null`, and `payload%2Evalues`. The seven-row Wide/LZ4
part has five marks with row counts `[2, 2, 2, 1, 0]` on every stream.
Decompressed mark offsets are `[0, 16, 32, 48, 56]` for `pk` and
`payload.size0`, `[0, 16, 40, 64, 72]` for `keys` and `values.size1`,
`[0, 16, 32, 64, 72]` for `values`, and `[0, 2, 4, 8, 9]` for
`values.null`. All compressed offsets
in this one-block vector are zero. This producer evidence is a format
anchor, not yet proof that Crystal consumes or emits the type. Stock
`serialization.json` has no column entries but does carry global `string: 1`
and nested-version propagation even without a String column; admission must
follow the existing metadata policy rather than infer a String payload.

Admit only an exact typed reader, table/batch/catalog surface, and immutable
writer for this declaration. Preserve entry order and duplicate numeric keys;
do not coerce a Map to a hash. `size0` counts entries per row; the key stream
has one UInt64 per entry; `values.size1` counts Array elements per entry;
the null map and child data each have one slot per Array element, including
NULL. Every `.mrk2` row count remains in table-row coordinates. The reader
must reject inconsistent counts, byte extents, null codes, or shifted marks
before yielding the affected mark; earlier valid marks may have yielded.
The writer must validate before exclusive publication and emit deterministic
hidden bytes for NULL values.

Risk is CAUTION: a plausible, shifted nested stream can self-read but fail
stock `ATTACH PART` or return a value under the wrong key. Rollback is the
isolated W69 diff or its one local commit; existing parts and remote history
remain untouched. DoD is RED-to-green exact reader/writer/table/catalog
tests; stock producer evidence for names, serialization, all mark row counts
and offsets; selected later-mark and checksum-valid corruption guards; a
bidirectional pinned stock/Crystal oracle with `ATTACH PART`, `CHECK TABLE`,
and exact full/keyed RowBinary; focused prior-type controls; full debug and
release suites; and hostile review. The oracle vector must distinguish
duplicate keys, empty Map and Arrays, NULL versus zero, an all-NULL mark
followed by a non-NULL tail, key/value extrema, and a short terminal mark.
The claim excludes other Map declarations, Compact parts, other codecs,
running-server lifecycle, MV/projections, and performance. Evidence decays
on a serializer, mark layout, ClickHouse version, or shared type-dispatch
change; then refresh the producer probe and both oracle directions.

W69 implementation evidence: the exact reader, writer, table/batch accessor,
catalog materializer, and physical-plan shadow now admit this declaration
only. The focused tests establish ordered duplicate-key and NULL-slot
roundtrips, selected later/all-NULL/tail marks, nested byte/cardinality
guards, deep-owned catalog values, and no callback for a corrupt selected
mark. The pinned ClickHouse 26.7.1.1315 bidirectional oracle passed: stock
part metadata and all stream marks matched the producer probe; Crystal read
the stock part; a checksum-valid mutation of a hidden UInt64 slot under a
NULL at a later mark preserved NULL and the tail in both readers; and the
Crystal-written part passed stock `ATTACH PART`, `CHECK TABLE`, and exact
full/keyed RowBinary comparisons. The complete debug and release suites each
passed with 897 examples, 0 failures, 0 errors, and 0 pending. The stock
oracle command was
`bash scripts/check_map_uint64_array_nullable_uint64_oracle.sh`; the suite
commands were `crystal spec --link-flags='-fuse-ld=ld'` and
`crystal spec --release --link-flags='-fuse-ld=ld'` with isolated Crystal
caches. These observations do not widen the stated exclusions or establish
speed/allocation parity. Hostile review returned ROBUST within this exact
pinned type/part scope after checking the corrected stock value offsets,
NULL-hidden-slot mutation, per-mark preflight, and writer publication path.

## W70 design-sealed: String keys with nullable String Array values

The next exact payload is `Map(String, Array(Nullable(String)))` beside one
sorted `UInt64` primary key in a Wide/LZ4/plain-`.mrk2` part. It composes
the existing String-key Map and nullable String Array paths without admitting
a general recursive Map. A pinned ClickHouse 26.7.1.1315 producer emitted
seven payload streams, in order: `m.size0`, `m%2Ekeys.size`, `m%2Ekeys`,
`m%2Evalues.size1`, `m%2Evalues.null`, `m%2Evalues.size`, and
`m%2Evalues`. The final seven-row stock vector has Map entry counts
`[3, 0, 1, 2, 2, 1, 2]`: its four data marks contain `[3, 3, 3, 2]`
entries but `[2, 2, 2, 1]` table rows. This distinction is essential: an
earlier probe happened to have equal entry and row counts and could not
falsify a wrong coordinate system. Every stream's fifth, terminal mark has
zero rows.

All compressed mark offsets in this small one-block stock vector are zero.
Decompressed offsets including the terminal mark are `[0, 16, 32, 48, 56]`
for the primary key and `m.size0`, `[0, 24, 48, 72, 88]` for
`m%2Ekeys.size` and `m%2Evalues.size1`, `[0, 9, 23, 39, 48]` for
`m%2Ekeys`, `[0, 6, 9, 13, 16]` for `m%2Evalues.null`,
`[0, 48, 72, 104, 128]` for `m%2Evalues.size`, and
`[0, 21, 28, 28, 43]` for `m%2Evalues`. The stock part passed
`CHECK TABLE`; full and keyed RowBinary stock readback preserved same-Map
duplicate keys, an empty Map, empty nested Arrays, NULL versus empty String,
embedded NUL/UTF-8, an all-NULL data mark followed by a non-NULL tail, and
the short final mark. With the stock sparse-serialization threshold, its
`serialization.json` records an `id` entry with `kind=Default`,
`num_defaults=1`, and `num_rows=7`, plus global `string: 1` with
nested-version propagation. A separate stock DDL setting
`ratio_of_defaults_for_sparse_serialization=1.0` suppresses per-column
entries, yielding `columns: []` for the same physical Default serializer.
The `id` statistic is therefore setting-dependent, not a universal schema
requirement; neither form licenses a different physical serializer.

Admit an exact typed reader, table/batch/catalog accessor, physical-plan
shadow, and immutable pair writer only. `size0` counts Map entries per table
row; key sizes and `values.size1` count one slot per entry; the null and
String-size streams count one slot per flattened Array leaf. The raw key and
value streams count bytes, which may be zero across a positive-row mark.
Each child `.mrk2` row count still refers to table rows. Preserve entry
order, duplicate keys, String bytes, NULL versus empty String, and all
independent axes. A checksum-valid mutation of a stock part reassigned one
existing raw byte from a later visible String to a preceding NULL leaf by
changing their size slots, without changing the raw bytes or mark offsets.
ClickHouse accepted the part via `ATTACH PART`/`CHECK TABLE` and returned
the expected shifted visible tail;
the Crystal reader matched it. Thus nonzero hidden String sizes must consume
their raw spans while still returning `nil`. This probe is specific to the
pinned serializer profile, not a general authorization for malformed parts.
The reader must reject changed cardinalities, invalid null codes, raw-byte
extents, and shifted mark boundaries before yielding the affected mark.
Earlier valid marks may have yielded. The writer emits canonical zero-size,
zero-byte NULL leaves and validates bounds and staged readback before
exclusive publication.

Risk is CAUTION: variable-length children can self-read while shifting a
later Map entry or causing stock `ATTACH PART`/`CHECK TABLE` failure.
Rollback is the isolated W70 diff or its one local commit; existing parts
and remote history remain untouched. DoD is RED-to-green exact
reader/writer/table/catalog/type-plan tests; a checksum-valid shifted-mark
or malformed-child falsifier with no callback for the affected mark; focused
prior-type controls; the pinned stock producer vector above; a bidirectional
stock/Crystal oracle with `ATTACH PART`, `CHECK TABLE`, and exact full/keyed
RowBinary; full debug and release suites; and hostile review. The oracle
must keep Map-entry count distinct from table-row count at each mark. Other
Map declarations, Compact parts, other codecs or marks, server lifecycle,
MV/projections, and speed/allocation parity remain outside this claim.
Evidence decays on a ClickHouse serializer/mark-layout/version change or
shared reader/writer/table/catalog dispatch change; refresh the producer
probe and both oracle directions before reuse.

W70 implementation evidence: the exact reader, immutable pair writer,
typed table/batch accessor, offline-catalog materializer, and physical-plan
shadow admit only this declaration. Focused W68/W69/W70 controls passed with
41 examples; the complete debug and release suites each passed with 914
examples, 0 failures, 0 errors, and 0 pending. The pinned ClickHouse
26.7.1.1315 oracle command was
`bash scripts/check_map_string_array_nullable_string_oracle.sh`; both stock
producer to Crystal reader and Crystal writer to stock `ATTACH PART`,
`CHECK TABLE`, and exact full/keyed RowBinary passed. A checksum-valid stock
mutation proved that a nonzero hidden String span under NULL is consumed
without shifting the following leaf. A second Crystal-written part with a
positive-row all-empty Map mark followed by empty String key/value slots
also passed stock attach/check and full/keyed readback; its repeated child
stream compressed offsets and mark rows were checked independently. The
full-suite commands were `crystal spec --link-flags='-fuse-ld=ld'` and
`crystal spec --release --link-flags='-fuse-ld=ld'` with isolated Crystal
caches. These observations do not widen the exclusions above or establish
speed/allocation parity. Hostile review returned ROBUST within this exact
pinned scope after checking row/entry/leaf accounting, hidden-NULL spans,
mark boundaries, the setting-dependent serializer metadata, and staged
publication. The second writer part's later entry mark still has zero raw
String bytes; the main oracle independently covers a zero-byte value mark
followed by a nonzero raw-value tail.

## W71 admitted frontier: numeric Map keys with nullable String Array values

The next exact payload is `Map(UInt64, Array(Nullable(String)))` beside one
sorted `UInt64` primary key in a Wide/LZ4/plain-`.mrk2` part. This combines
W69's fixed-width numeric Map keys with W70's variable-width nullable String
Array values; neither neighboring certificate admits their cross-product.
The pinned stock producer confirmed six payload streams: `m.size0`, `m%2Ekeys`,
`m%2Evalues.size1`, `m%2Evalues.null`, `m%2Evalues.size`, and
`m%2Evalues`, in that order. The fresh 26.7.1.1315 part passed stock
`CHECK TABLE`. Its seven rows have Map entry counts `[3, 0, 1, 2, 2, 1, 2]`
and flattened nullable String leaf counts `[6, 0, 0, 3, 3, 1, 3]`.
Every stream has five marks with table-row counts `[2, 2, 2, 1, 0]` and
compressed offsets all zero. Decompressed offsets including the terminal
mark are `[0, 16, 32, 48, 56]` for `id` and `m.size0`,
`[0, 24, 48, 72, 88]` for numeric keys and `values.size1`,
`[0, 6, 9, 13, 16]` for the null map,
`[0, 48, 72, 104, 128]` for String sizes, and
`[0, 21, 28, 28, 43]` for raw String bytes. The stock vector preserves
duplicate numeric keys, empty Maps and Arrays, NULL versus empty String,
embedded NUL/UTF-8, maximum UInt64, and an all-NULL mark followed by a
non-NULL tail. The baseline NULL leaves have size zero and no raw bytes;
the value stream has 43 raw bytes overall. Its `serialization.json` has
global `string: 1` and nested-version propagation plus a setting-dependent
Default statistic for `id`;
that statistic is not a universal serializer requirement. This is producer
evidence, not yet proof that Crystal consumes or emits the type.

Admit only the exact typed reader, table/batch/catalog materialization,
physical-plan shadow, and immutable ordered-pair writer. `size0` maps table
rows to Map entries; the numeric key and `values.size1` streams have one slot
per entry; the nullable and String-size streams have one slot per flattened
Array leaf; the raw String stream counts bytes, including nonzero hidden
spans under NULL. Every `.mrk2` row field remains in table-row coordinates.
The stock vector must make entries differ from rows at each relevant mark,
preserve duplicate keys and empty Map/Array values, distinguish NULL from
empty String, and include an all-NULL or zero-byte mark followed by a
nonempty tail. A checksum-valid hidden-NULL size mutation must not shift the
later visible String. Invalid null codes, child cardinalities, extents, or
shifted marks must reject before yielding the affected mark; earlier valid
marks may already have yielded. The writer emits canonical zero-size NULL
children and publishes only after staged readback and validation.

Risk is CAUTION: independent entry, leaf, and byte axes can self-read while
shifting a value under the wrong key or yielding a stock-invalid part.
Rollback is the isolated W71 diff or its one local commit, with existing
parts and remote history untouched. DoD is RED-to-green focused exact
reader/writer/table/catalog/type-plan tests, producer-confirmed stream and
mark topology, checksum-valid corruption guards, focused adjacent-type
controls, a bidirectional pinned stock oracle with `ATTACH PART`,
`CHECK TABLE`, and exact full/keyed RowBinary, full debug and release suites,
and hostile review. Other Map declarations, Compact parts, other codecs or
marks, server lifecycle, MV/projections, and speed/allocation parity stay
outside this claim. Evidence decays on a serializer/mark-layout/version or
shared reader/writer/table/catalog dispatch change; refresh the producer
probe and both oracle directions before reuse.

The continuation order is paired reader/writer type compatibility first,
then MV and projection support, and only then memory and performance work.
No W71 optimization result is claimed.

The first W71 RED test executed with the project's system-linker override:
`WidePhysicalPlanShadow.for_type` returned nil for the exact candidate.
This is an admission falsifier only; it does not yet verify any reader or
writer behavior.

W71 implementation evidence: the exact reader, immutable pair writer,
typed table/batch accessor, offline-catalog materializer, and physical-plan
shadow admit only this declaration. Focused W71 reader/writer tests passed
with 7 examples, and adjacent W69/W70 controls passed with 12 examples.
The complete debug and release suites each passed with 926 examples, 0
failures, 0 errors, and 0 pending after the distinct entry- and leaf-overflow
guards were tested. The suite commands were
`crystal spec --link-flags='-fuse-ld=ld'` and
`crystal spec --release --link-flags='-fuse-ld=ld'` with isolated caches.
The pinned ClickHouse 26.7.1.1315 oracle command was
`bash scripts/check_map_uint64_array_nullable_string_oracle.sh`; stock
producer to Crystal reader and Crystal writer to stock `ATTACH PART`,
`CHECK TABLE`, and exact full/keyed RowBinary passed. Its checksum-valid
hidden-NULL size mutation did not shift the next visible String. A
positive-row zero-byte child mark retained its table-row count and equal
child offsets before a nonempty tail. The oracle also exposed a real
setting-dependent `Default` key-serializer count, now also accepted for this
exact W71 declaration; the writer's zero-primary-key case covers it. Hostile
review returned ROBUST for this pinned exact surface after checking the
separate row, entry, leaf, and byte axes, materialization bounds, type gate,
and staged publication. These observations do not widen the exclusions
above or establish any memory or performance result.

## W72 admitted frontier: scalar JSON typed-path writer parity

W72 closes the reader/writer mismatch for the existing simple top-level
declared JSON typed-path grammar: `String` and the ten primitive numeric
types. `JSONTypedPathColumn` binds a path name, exact scalar type name, and
row-aligned values; `write_uint64_json_typed_paths` accepts a nonempty set of
such columns next to a sorted `UInt64` key. It preserves each name/type/value
association while sorting `columns.txt`, `columns_substreams.txt`, and typed
physical streams by path name, matching the pinned ClickHouse producer.
Missing declared-path values must be supplied as normalized scalar defaults;
the API neither models path presence nor accepts dynamic/shared values.

Risk is CAUTION: a self-readable part can still mis-map typed paths or have
invalid Object V3 auxiliary streams. Rollback is the isolated W72 commit;
existing parts and remote history are untouched. The focused API test was RED
before implementation. It then passed 5 examples, including mixed widths,
multiple marks, input order differing from physical order, String empty/NUL
bytes, and pre-publication rejection of invalid inputs and an oversized
String granule. The full debug and release suites each passed 931 examples,
0 failures/errors/pending. The pinned 26.7.1.1315 reverse oracle attached a
Crystal-generated `JSON(z String, a Int16, m Float32)` Wide part and passed
exact full/keyed RowBinary, normalized whole-object JSONEachRow, canonical
metadata, Object V3 byte/mark checks, checksum/file inventory, and `CHECK
TABLE`. The old exact-shape JSON oracle and 63 other pinned oracles passed.
Format, shell syntax, and diff checks passed. The stock producer probe
independently established sorted metadata and stream order and the zero-
dynamic-path structure. The focused test confirms raw Float32 `-0`/NaN/Inf
bit preservation; the durable reverse oracle covers finite Float32 values.
This evidence does not establish all JSON shapes or physical MV/projections,
and decays on a producer version, Object serialization setting, codec/mark
layout, or relevant code change. Memory/performance work remains deferred
until type parity and MV/projection support.
The hostile pass found an off-by-one estimate for the reader's metadata-line
limit; an over-limit case was RED before the exact LF-inclusive guard and
green afterward, while an exact-limit line still opens in Crystal. All
gates above were rerun on the corrected source. The adversary verdict is
ROBUST within the pinned mixed-path/reader-limit scope, not arbitrary JSON
or acceptance of 64 KiB path names by stock ClickHouse.

## W73 design seal: complete the non-null core Map/Array matrix

The current paired surface includes `Map(String, Array(UInt64))` and several
nullable-leaf relatives, but not `Map(UInt64, Array(UInt64))`,
`Map(String, Array(String))`, or `Map(UInt64, Array(String))`. W73 targets all
three missing non-null cells as one coherent matrix over the existing key and
leaf codecs. A shared internal physical-plan/axis path may replace duplicated
exact-shape machinery, but public type admission stays limited to the four
matrix declarations. Merely accepting their type strings without reader,
table/catalog, writer, and stock compatibility is not admission.

Risk is CAUTION: Map entries, nested Array elements, and String bytes have
independent cardinalities while every stream mark reports table rows. An
apparently plausible part can silently associate values with the wrong key.
Rollback is one isolated W73 feature commit; existing data roots and remote
history remain untouched. Before implementation, the falsifier is a focused
RED test proving each absent declaration is refused by the current reader or
writer. A pinned ClickHouse 26.7.1.1315 producer must then establish the
ordered stream inventory, mark rows and offsets, and serializer metadata for
all three cells, using vectors with row, entry, element, and byte counts that
differ. Include duplicate keys, empty Maps and Arrays, a short final mark,
numeric extrema, and empty/binary String values followed by nonempty tails.

The DoD is exact typed reader, table/batch/catalog, and immutable writer
coverage for all three cells; selected later-mark offset corruption and
compressed-frame-checksum-valid cardinality corruption rejection before
yielding the affected mark;
Crystal reads of stock parts; stock `ATTACH PART`, full/keyed RowBinary, and
`CHECK TABLE` for Crystal parts; focused specs, full debug/release suites,
all pinned regression oracles, format/diff checks, and a hostile review.
Stock disagreement narrows or rejects the proposed matrix instead of
assuming that adjacent nullable codecs prove it. Other Map key/value types,
arbitrary recursive nesting and table schemas, Compact parts, other codecs,
MV/projections, and memory/performance claims remain guard-only. Evidence
expires on a ClickHouse serializer, mark-layout/version, or shared
reader/writer/table/catalog dispatch change. Dynamic/shared JSON remains the
next separately probed type frontier after this matrix.

Pre-implementation producer evidence on pinned ClickHouse 26.7.1.1315:
`bash scripts/check_map_array_core_w73_oracle.sh` passed its stock-only phase
for all three declarations before the writer was added. The probe inserts
five rows through RowBinary with duplicate keys, empty Maps/Arrays, numeric
extrema, and empty/binary Strings; it checks full/keyed RowBinary, `CHECK
TABLE`, exact substream inventory, raw bytes, checksums, and three plain
`.mrk2` data marks with row counts `[2, 2, 1]` plus a terminal mark. It
sets `compress_marks=0`, LZ4, and bounded compression blocks explicitly;
this is not evidence for compressed marks or other codec settings. Observed
substreams are `size0, keys, values.size1, values` for UInt64/UInt64,
`size0, keys.size, keys, values.size1, values.size, values` for
String/String, and `size0, keys, values.size1, values.size, values` for
UInt64/String. Each uses a distinct row, entry, element, and (where present)
String-byte axis. All three stock parts have the same Default `pk`
serialization entry with `num_defaults: 1` and `num_rows: 5`. This
producer-only phase did not itself certify a Crystal reader or writer.

The completed bidirectional W73 oracle now does: Crystal reads the stock
parts across full and final-mark ranges, and pinned ClickHouse accepts the
Crystal-written parts via `ATTACH PART`, full/keyed RowBinary readback, and
`CHECK TABLE`. The oracle also checks stock parts where every Map is empty or
every nested Array is empty. In those cases child `.bin` streams have zero
length, child mark offsets remain zero through the terminal mark, and stock
`serialization.json` reports `num_defaults: 0` for the tested primary keys
`[1, 2, 3]`; the main fixture above reports one default with a primary key
zero. W73 admits the bounded `Default` count for only its three exact shapes,
not an arbitrary Map serializer. Reader specs reject shifted later marks on
each child stream and changed per-mark row counts even when their aggregate is
unchanged. The latter is caught by the existing open-time full mark-row-vector
comparison, not by a new W73 guard. Batch/catalog specs check typed accessors,
ownership, materialization limits, and withholding a corrupted later mark
before yield.
Both full `crystal spec` and `crystal spec --release` passed with 948 examples,
zero failures, errors, or pending tests. All 66 pinned `check_*_oracle.sh`
scripts passed with no exclusions or source drift during that batch. This is
compatibility evidence only for pinned Wide/LZ4/plain `.mrk2` parts with the
declared two-column schema;
it is not a performance claim and does not extend to MV or projections.

## W74 design seal: standalone Dynamic with one String alternative

The next type-parity step admits a top-level `Dynamic` column only when its
physical type dictionary contains the single `String` alternative, every row
selects that alternative, and the SharedVariant streams are empty. The public
Crystal view is a String-valued column; it does not erase or reinterpret
non-String, NULL, or shared values. Reader, batch/table/catalog dispatch, and
an immutable `UInt64`-keyed writer must agree on this exact shape. This is a
reusable physical codec for a later JSON dynamic-path feature, not admission
of JSON dynamic-path discovery or whole-document access.

The pinned ClickHouse 26.7.1.1315 producer established six ordered streams:
`dynamic_structure`, `variant_discr`, `SharedVariant.size`, `SharedVariant`,
`String.size`, and `String`. In a two-row String-only probe, the decompressed
structure is `0400000000000000011501000200`, the discriminator stream is
`0100000000000000020101`, shared streams are empty, String sizes are 5 and 4,
and String bytes concatenate `alpha` and `beta`. A one-off probe with that
pinned build also observed byte-identical streams when the column was embedded
as one dynamic path inside `JSON(max_dynamic_paths=1)`. The tracked W74 oracle
does not reproduce the JSON comparison, so this observation cannot admit JSON
dynamic-path reading or writing; that boundary needs its own fixture.

Risk is CAUTION because a plausible-looking discriminator or type dictionary
can silently reinterpret values. Rollback is one W74 feature commit without
touching existing server data roots or remote history. The first falsifier is
a RED focused spec for a missing String-only `Dynamic` reader/writer API and
an independently produced Wide/LZ4/plain-mark stock part. The guard check is
rejection before yielding the affected mark or publishing when the dictionary,
discriminators, shared streams, mark row counts, or String cardinalities violate
the admitted shape. Include multiple marks, empty and binary Strings, short
final marks, and malformed later marks. The DoD is focused specs;
stock-to-Crystal read;
Crystal-to-stock `ATTACH PART`, full and keyed RowBinary, and `CHECK TABLE`;
all pinned regression oracles; full debug and release specs; formatter and
diff checks; and hostile review of both directions and publication safety.
An observed mismatch narrows the admitted shape rather than weakening the
guard. Evidence expires on a ClickHouse Dynamic serializer/version, mark or
codec change, or shared dispatch change.

Guard-only: additional Dynamic alternatives, NULL and SharedVariant values,
heterogeneous rows, nested Dynamic, JSON dynamic/shared paths, Compact parts,
other codecs/mark settings, MV/projections, and memory/performance claims.
The broader type-parity and MV/projection frontier remains active before any
optimization phase.

W74 implementation evidence: the focused spec passed 11 examples, including
empty and binary Strings, a zero-byte String child with 130 rows and a
multi-byte row statistic, catalog materialization, later-mark tag and offset
corruption, dictionary/statistic corruption, child row disagreement, a
nonempty SharedVariant, and pre-publication writer rejection. The pinned
ClickHouse 26.7.1.1315 oracle passed both directions for mixed and 130-row
all-empty parts: six-stream inventory, plain mark rows, exact stock V3
structure bytes `04 00 00 00 00 00 00 00 01 15 01 00 82 01 00`,
stock-to-Crystal typed scans, and Crystal-to-stock `ATTACH PART`,
`CHECK TABLE`, full and primary-key-range RowBinary. The full debug and release
suites each passed 959 examples with no failures, errors, or pending tests;
release used the host-compatible `-fuse-ld=ld` linker override. All 67 pinned
oracle scripts passed before the oracle-only 130-row extension, and the
extended W74 oracle passed separately afterward; the other 66 scripts and
production source were unchanged. Formatting, shell syntax, and diff checks
passed. This evidence covers the admitted profile, not arbitrary `Dynamic`,
JSON dynamic paths, MV/projections, or performance parity.

## W75 admitted: mixed standalone Dynamic values

W75 targets a top-level `Dynamic` payload containing `String`, `UInt64`, and
optional `NULL` rows beside a sorted `UInt64` key. Both concrete arms must
occur at least once in a part; the writer rejects all-NULL, UInt64-only, and
String-only input before staging. The W74 String-only writer remains the
supported path for its one-arm profile. The public value type must preserve
the row's concrete arm or absence, not coerce it to String. Reader, typed
table/batch, offline catalog, and immutable writer must agree on exact values
and row order. Preserve W74's existing String-only API. This step does not
admit general `Dynamic`, even if the physical dictionary is extensible.

Risk is CAUTION: a syntactically valid dictionary, statistic, or COMPACT tag
could silently reinterpret a row or shift sparse child values across marks.
Rollback is one isolated local feature commit; existing parts and remote
history are untouched. The first falsifier is a focused RED test for the
missing mixed-value reader/writer API. Before encoding any new structure,
the pinned ClickHouse 26.7.1.1315 producer must establish exact type codes,
dictionary order, statistics, discriminator modes/tags, substream order,
mark offsets, and sparse child cardinalities for multiple marks. Include
empty/binary Strings, UInt64 extrema, `NULL`, an arm absent from one granule,
and a short final granule. Preserve the stock bytes as executable oracle
assertions rather than inferring them from the W56 Variant codec. Exact stock
mark offsets are an oracle for the stock-produced part, not a demand that the
Crystal writer choose identical LZ4 frame boundaries. Writer marks instead
must be internally sound and pass ClickHouse `ATTACH PART`/`CHECK TABLE` and
exact row comparisons.

The pinned producer probe uses explicit `CAST(..., 'Dynamic')` per arm before
`UNION ALL`; a mixed `VALUES` expression was rejected as evidence because its
common-type inference silently turned `NULL` into `UInt64(0)`. The first
seven-row, three-rows-per-mark producer case reports concrete types
`String, UInt64, None, String, String, None, UInt64`. Its structure is
`04000000000000000215040100030200`: V4, two dictionary arms (`String=0x15`,
`UInt64=0x04`), required statistics, zero shared rows, three String rows, and
two UInt64 rows. Its discriminator is
`010000000000000003000102ff03000101ff010102`: compact mode, mixed-mark
format 0 and uniform-mark format 1, with tags 1/String, 2/UInt64, and
255/NULL for this dictionary. Child streams are sparse; empty SharedVariant
streams remain present. These tag values are fixture observations, not an
assumption about dictionaries emitted in another arm order. A second pinned
producer probe begins with `UInt64(42)` before any String and still emits
the same canonical dictionary and tags; its discriminator is
`010000000000000003000201ff03000201ff010101`. W75 nevertheless validates
the actual dictionary rather than assuming encounter order is the format rule.

Admitted after the pinned bidirectional oracle: exact mixed rows in the
two-column Wide/LZ4/plain-`.mrk2` profile, with no SharedVariant payload.
Guard-only:
zero-arm and one-arm non-W74 Dynamic subsets, additional concrete Dynamic
types, nonempty SharedVariant, nested Dynamic,
JSON dynamic/shared paths, Compact or other codecs/marks, MV/projections,
and memory/performance results. Malformed dictionaries, statistics, tags,
child extents, and later-mark offsets must reject before exposing the
affected mark; earlier valid marks may already have yielded. A nonempty
SharedVariant or unsupported arm must fail closed.

The physical substream inventory must match the dictionary arms at part-open
time; a missing child is an unsupported shape, not a late hash lookup error.

DoD: RED-to-green focused reader/writer/table/catalog specs; stock-to-Crystal
typed reads; Crystal-to-stock `ATTACH PART`, `CHECK TABLE`, and exact full and
key-range RowBinary with concrete-type identity; all pinned regression
oracles; full debug and release suites; format/diff checks; and hostile
review of both directions and publication safety. A stock disagreement
narrows or rejects W75, not the oracle. Evidence decays on a ClickHouse
Dynamic serializer/version, codec/mark layout, or shared dispatch change.
Continue remaining type parity, then MV/projections, before memory or speed
optimization.

W75 evidence on 2026-09-28: the pinned ClickHouse 26.7.1.1315 oracle passed
stock-to-Crystal and Crystal-to-stock for both String-first and UInt64-first
parts, including exact stock structure/discriminator bytes, seven-stream
inventory, stock marks, sparse children, checksums, stock ATTACH/CHECK, and
full/key-range RowBinary with concrete `dynamicType` identity.
Ten W75 reader and three W75 writer focused examples passed. The final full
debug and release suites each passed 972 examples with zero failures, errors,
or pending tests, using the host-compatible `-fuse-ld=ld` override. All 68
pinned oracle scripts passed in one sweep; after the final malformed-inventory
guard, the affected W74 and W75 oracles passed again. Crystal formatting,
shell syntax, and diff checks passed. A hostile read-only review found and
closed the missing-child-at-open defect and returned `ROBUST` for the admitted
profile. The offline catalog's existing PK-candidate API remains
UInt64-projection-only; typed full scans and low-level selected-mark scans
cover W75, but a catalog-level keyed Dynamic query is not claimed. General
`Dynamic`, MV/projections, and memory or speed parity remain unverified.

## W76 admitted: scalar-numeric Map values

W76 admits only `Map(UInt64, T)` and `Map(String, T)` for exact primitive
`T` in `UInt8`, `UInt16`, `UInt32`, `UInt64`, `Int8`, `Int16`, `Int32`,
`Int64`, `Float32`, and `Float64`, in the existing sorted-`UInt64`-key,
two-column Wide/LZ4/plain-`.mrk2` profile. The two `UInt64` value
declarations already work and are regression controls; the other 18 are
new reader/writer parity targets. Rows preserve ordered Map entries,
including duplicate keys, rather than collapsing them into a dictionary.
No recursive Map grammar or nullable numeric values are admitted by this
step. `Float32` and `Float64` retain their exact bit patterns, including
signed zero and NaN payloads, where stock ClickHouse preserves them.

Risk is CAUTION: a wrong nested value width can appear correct in a full
scan while shifting later-mark boundaries or mischarging materialization.
Rollback is the isolated local W76 feature commit; existing parts and remote
history are untouched. The first falsifier is a RED typed reader/writer test
for one missing narrow numeric value on each key shape. Before a physical
codec change, the pinned ClickHouse 26.7.1.1315 producer must confirm the
exact stream inventory, nested width, metadata, marks, empty Maps, duplicate
keys, and multi-mark tails for representative widths and key shapes.
If the producer shows a distinct physical profile, narrow this admission
before implementing it. The consumer must validate each selected child's
mark rows, flattened cardinality, byte extent, and aggregate materialization
charge before exposing affected rows. Earlier valid marks may already have
yielded. Reader, typed table/batch, offline catalog, and immutable writer
must agree on type identity and ordered values.

DoD: RED-to-green focused reader/writer/table/catalog specs; pinned
stock-to-Crystal selected and full reads across all ten numeric leaves and
both key shapes; Crystal-to-stock `ATTACH PART`, `CHECK TABLE`, exact full
and primary-key-range RowBinary for representative width/float/key cases;
adjacent Map regression controls; all pinned oracles; full debug and
release suites; format/diff checks; and hostile review of both directions,
later-mark integrity, and publication safety. A stock disagreement rejects
or narrows W76, not the oracle. Evidence decays on a ClickHouse nested-Map
serializer, codec/mark layout, or shared dispatch change. Additional
`Dynamic`, general JSON, MV/projections, and memory/performance parity
remain guard-only.

W76 evidence on 2026-09-28: the pinned ClickHouse 26.7.1.1315 oracle passed
stock-to-Crystal for all 20 declarations, checking exact physical stream
inventory, marks, metadata, checksums, full rows, and selected later marks.
Five representative Crystal-to-stock cases passed `ATTACH PART`,
`CHECK TABLE`, and exact full/key-range RowBinary. The Crystal writer's
`serialization.json` uses an accepted metadata variant rather than the
stock producer's byte-identical record; interoperability, not metadata
identity, is the reverse-direction claim. Physical writer-backed typed-table
and offline-catalog specs cover all 20 declarations, ordered duplicates,
empty rows, and floating-point bit retention. A RED-to-green empty-row
regression raised W76's logical charge to 64 bytes per retained Map row,
including both pre-existing `UInt64` value controls, without changing older
Array(Tuple)/Map charge contracts. This is not an exact heap/RSS bound.
The final debug and release suites each passed 988 examples with zero
failures, errors, or pending tests using the host-compatible
`-fuse-ld=ld` override. All 69 pinned oracle scripts passed in one sweep;
Crystal formatting, shell syntax, and diff checks passed. A read-only
hostile review found the empty-row undercharge and later the String/UInt64
dispatch mismatch; both were corrected, and it found no remaining concrete
W76 blocker in the final source. Stock interoperability for arbitrary NaN
payloads, multi-column stock parts, other layouts/builds, remaining type
families, MV/projections, and memory/performance parity is not established.

## W77 admitted: nullable primitive-numeric Map values

W77 admits paired reader/writer support for
`Map(UInt64, Nullable(T))` and `Map(String, Nullable(T))`, where `T` is one
of W76's ten primitive numeric leaves. W53's `Nullable(UInt64)` declarations
are existing controls; the other 18 declarations are newly checked. This is
still the sorted-`UInt64`-key, two-column
Wide/LZ4/plain-`.mrk2` profile, not a recursive Map grammar. Ordered entries,
duplicate keys, NULL versus non-NULL zero, empty Maps, and exact non-NULL
floating-point bits are observable parts of the admitted contract.

Risk is CAUTION: an independently plausible null bitmap or numeric width can
misalign later marks, and an incorrect charge can admit oversized row
materialization. Rollback is one isolated W77 feature commit, without
modifying existing stock parts or remote history. The first RED falsifier was
the previous exact type gate rejecting `Map(UInt64, Nullable(UInt8))` and
`Map(String, Nullable(Float64))`. Before admission, the pinned stock producer
established `size0`, key, null, and numeric-value stream inventory; each
child's row count, flattened cardinality, byte extent, empty-mark behavior,
terminal mark, and accepted metadata. The reader
must validate these before returning selected rows, and the immutable writer
must validate its staged part before publication. Reader, typed table/batch,
offline catalog, and writer must agree on exact type identity and ordered
values. A stock discrepancy narrows the design rather than the oracle.

DoD: RED-to-green focused reader/writer/table/catalog specs including null,
empty, duplicate, later-mark, malformed child-mark, and logical-charge cases;
pinned stock-to-Crystal exact stream and RowBinary checks for all 20 profiles;
Crystal-to-stock `ATTACH PART`, `CHECK TABLE`, and keyed/full
RowBinary checks; all pinned oracles; debug and release suites; format/diff
checks; and hostile review of both interoperability directions and publication
safety. Evidence will decay if the pinned ClickHouse nested-Nullable serializer, codec/mark layout,
or shared dispatch changes. General JSON/Dynamic, further recursive types,
MV/projections, and memory/performance tuning remain outside this slice.

W77 evidence on 2026-09-28: the pinned ClickHouse 26.7.1.1315 oracle passed
stock-to-Crystal and Crystal-to-stock for all 18 new declarations, checking
exact null/value/key stream inventory, checksums, metadata, marks, full and
selected RowBinary, `ATTACH PART`, and `CHECK TABLE`. The existing W53 oracle
passed for both `Nullable(UInt64)` controls. Each W77 stock case includes
duplicate keys, NULL versus non-NULL zero, an empty middle mark, a later
nonempty mark, and a final all-empty mark at nonzero child-stream EOF; direct
reader and typed-table specs also check that final mark for both key shapes.
Writer-backed table and catalog specs cover all 20 declarations and bitwise
floating-point values. A read-only hostile review identified the previously
untested nonzero-EOF empty suffix; adding that falsifier exposed no production
defect, and the updated oracle passed in both directions. The final debug and
release suites each passed 1002 examples with zero failures, errors, or pending
tests using the host-compatible `-fuse-ld=ld` override. All 69 prior pinned
oracle scripts passed; Crystal format, shell syntax, and diff checks passed.
This does not establish arbitrary Map recursion, all ClickHouse physical
layouts/builds, MV/projection semantics, or memory/performance parity. Memory
and performance work remains deferred until the remaining type coverage and
MV/projection support are implemented.

## W78 design seal: numeric leaves in Map values that are Arrays

W78 targets paired reading and writing of `Map(UInt64, Array(T))` and
`Map(String, Array(T))` for the ten primitive numeric leaves in W76. The two
`Array(UInt64)` declarations are existing W73 controls; the other 18 are new
targets. Admission is conditional on a pinned ClickHouse producer probe of
the exact physical streams and marks, not on similarity to scalar Map or
top-level Array codecs. This remains the sorted-`UInt64`-key, two-column
Wide/LZ4/plain-`.mrk2` profile. Entries remain ordered and may have duplicate
keys. Empty Maps, empty inner Arrays, signed extrema, and preserved floating
bits are part of the proposed observable contract. Nullable leaves, other
Map keys, additional nesting, and general recursive type parsing are not.

Risk is CAUTION: table rows, Map entries, and Array elements have independent
cardinalities; a numeric leaf-width error can leave a full scan looking
plausible while shifting a later mark or undercharging materialization.
Rollback is one isolated W78 feature commit, without changing existing parts
or remote history. The first falsifier is a RED exact-type reader/writer test
for a narrow signed leaf and a floating leaf on opposite key shapes. Before
production changes, the pinned ClickHouse 26.7.1.1315 producer must establish
the stream inventory, width, mark coordinates, terminal empty marks, metadata,
and RowBinary behavior for representative leaves. The final stock oracle must
cover every admitted spelling and both interoperability directions. A stock
disagreement narrows or rejects the candidate instead of changing the oracle.

The reader must validate each selected child's mark rows, flattened
cardinality, byte extent, and aggregate logical charge before yielding the
affected mark. Earlier valid marks may already have yielded. The writer must
validate the staged part before publication. The physical shadow, direct
reader, typed table/batch, offline catalog, and writer must agree on exact
type identity and ordered values. A malformed later child mark, empty middle
mark, and final all-empty mark at nonzero child-stream EOF are guard cases.

DoD: RED-to-green focused reader/writer/table/catalog and physical-shadow
specs; exact pinned stock-to-Crystal streams, marks, and full/selected
RowBinary for all 20 declarations; Crystal-to-stock `ATTACH PART`, `CHECK
TABLE`, and full/keyed RowBinary; adjacent Map/Array regression controls;
all pinned oracles; full debug and release suites; format/diff checks; and a
hostile review of both directions, later-mark integrity, charge, and
publication safety. The evidence decays on a ClickHouse nested-Map/Array
serializer, codec/mark layout, or shared dispatch change. Remaining type
families and MV/projections precede memory/performance work.

Pre-implementation stock evidence on pinned ClickHouse 26.7.1.1315: one
five-column producer part carried `Map(UInt64, Array(Int8))`,
`Map(UInt64, Array(Float64))`, `Map(String, Array(Int8))`, and
`Map(String, Array(Float64))` beside a sorted UInt64 key. Each UInt64-key
payload had `size0`, `keys`, `values.size1`, and `values` streams; String
keys added `keys.size`. Every stream's five plain marks reported table-row
counts `[2, 2, 2, 2, 0]`. The Int8 value-stream decompressed offsets were
`[0, 0, 4, 6, 6]`, and the Float64 offsets were `[0, 0, 24, 40, 40]`;
the final data mark was all-empty at nonzero child EOF. All child terminal
marks used the exact raw-stream byte length and zero rows. Stock `CHECK
TABLE` and same-schema stock-to-stock `ATTACH PART` succeeded, and stock
RowBinary showed entry counts, key encodings, nested-array counts, and
width-correct numeric leaf bytes. This is producer and stock consumer
evidence for four representative shapes, not yet Crystal reader/writer
evidence or all-20-declaration coverage. A two-column stock oracle remains
required by W78's DoD.

W78 implementation evidence on 2026-09-28: the pinned ClickHouse 26.7.1.1315
two-column oracle passed 20/20 stock-to-Crystal reader cases and 20/20
Crystal-to-stock writer cases. For each exact declaration it checked physical
stream inventory, metadata, checksums, marks, full and later-selected values;
the reverse direction also passed stock `ATTACH PART`, `CHECK TABLE`, and
full/keyed RowBinary. Stock-produced wide children supplied two selected
greater-than-4096-byte compressed-frame-crossing witnesses. Crystal's writer
intentionally emits one frame per mark, so its reverse cases assert equivalent
payload and mark semantics, not identical frame splitting. The full debug
and release suites each passed 1017 examples with no failures, errors, or
pending tests using the host-compatible `-fuse-ld=ld` override. All 70
prior pinned oracle scripts passed on unchanged source and oracle hashes.
The W78-specific exclusive-publication failure test confirmed that a failed
publish removes the private stage and leaves no destination. A read-only
adversary review found no confirmed product defect and judged the bounded
surface ROBUST; an injected mid-stage I/O failure remains untested, although
the new direct writer helper has an `ensure` cleanup. This evidence does not
admit arbitrary recursive Map types, other ClickHouse layouts or builds,
MV/projection semantics, or a memory/performance claim. Finish type coverage
and MV/projections before performance work.

## W79 admitted frontier: nullable primitive-numeric leaves in Map Arrays

W79 targets paired reading and writing of `Map(UInt64, Array(Nullable(T)))`
and `Map(String, Array(Nullable(T)))` for the ten primitive numeric leaves
already covered by W76-W78. The two `Nullable(UInt64)` declarations are
existing W68/W69 controls; the other 18 are new. Admission is exact, on the
pinned ClickHouse 26.7.1.1315 Wide/LZ4/plain-`.mrk2` profile beside a sorted
`UInt64` key. A parsed type expression alone must not admit other Map keys,
leaf types, nullable containers, or additional Array depth. Preserve ordered
Map entries, duplicate keys, empty Maps and inner Arrays, NULL versus zero,
signed extrema, and floating-point payload bits.

Before implementation, stock ClickHouse produced and checked representative
`Map(UInt64, Array(Nullable(Int8)))` and
`Map(String, Array(Nullable(Float64)))` parts. The former has five payload
streams: `payload.size0`, `payload%2Ekeys`,
`payload%2Evalues.size1`, `payload%2Evalues.null`, and
`payload%2Evalues`. String keys add `payload%2Ekeys.size` before the raw
key stream. `serialization.json` reported the pinned Default serializer and
the nested String version. These initial probes established stream inventory
and stock `CHECK TABLE` only, not the final per-mark, Crystal-reader, or
Crystal-writer contract. The broader fixture reported below supplied the
required mark-coordinate, terminal-sentinel, physical-extent, and full/keyed
RowBinary checks.

Risk is CAUTION: rows, Map entries, Array leaves, nullable flags, and
fixed-width value bytes have different cardinalities. A shifted null stream
could return plausible rows while assigning a later value to the wrong key;
a self-reading writer could still fail stock attach. The reader must validate
every selected child's mark rows, per-mark cardinality, physical extent,
null bytes, and aggregate materialization charge before yielding the affected
mark. Earlier valid marks may have yielded. The writer must emit deterministic
hidden bytes for NULLs, validate its private stage, and publish exclusively.
Rollback is one isolated W79 commit; existing data roots and remote history
stay unchanged.

The first falsifier was exact W79 reader/writer admission for `Int8` under
`UInt64` keys and `Float64` under String keys: the W78 source failed new
admission while existing `Nullable(UInt64)` controls remained green. DoD was
RED-to-green focused type-plan/reader/writer/table/catalog and corruption
tests; a pinned stock producer probe for all exact declarations with streams,
marks, metadata, and selected later marks; a bidirectional stock oracle for
all 20 declarations including stock `ATTACH PART`, `CHECK TABLE`, and
full/keyed RowBinary; adjacent W68-W71/W77/W78 controls; full debug and
release suites; format/diff checks; and hostile review. The oracle included a
positive-row empty middle mark, a later nonempty mark, a terminal
all-empty mark at nonzero child-stream EOF, and NULL versus visible zero.
Evidence decays on a ClickHouse nested Map/Array/Nullable serializer, codec
or mark layout, pinned version, or shared dispatch change. Other type
families and MV/projections remain ahead of memory/performance work.

W79 implementation evidence on 2026-09-28: the pinned ClickHouse 26.7.1.1315
oracle passed 20/20 stock-to-Crystal reader cases and 20/20 Crystal-to-stock
writer cases, including the two existing UInt64-leaf controls. For every
exact declaration it checked physical stream inventory, metadata, checksums,
all mark coordinates and the terminal sentinel, full and later-selected
reads, plus stock `ATTACH PART`, `CHECK TABLE`, and full/keyed RowBinary for
Crystal-written parts. Fixtures included an empty middle mark, a later
nonempty mark, an all-empty terminal mark at nonzero child-stream EOF, NULL
versus visible zero, duplicate keys, and floating-point payload-bit probes.
Focused corruption tests rejected checksum-valid invalid null bytes and a
shifted later null mark before the affected mark yielded rows. The six
adjacent pinned oracles passed. The full debug and release suites each passed
1026 examples with zero failures, errors, or pending tests using
`-fuse-ld=ld`; Crystal formatting, shell syntax, and `git diff --check` also
passed. A bounded read-only adversary review found no actionable falsifier
and judged this exact surface ROBUST. These checks do not admit arbitrary
recursive Maps, other ClickHouse versions or layouts, MV/projection
semantics, or any memory/performance claim.

## W80 design frontier: Array of String-to-UInt64 Maps

W80 tests the first `Array(Map(...))` composition, initially the exact
`Array(Map(String, UInt64))` declaration beside a sorted `UInt64` key. This
is a type-compatibility step, not a memory or performance optimization. A
successful syntax parse or physical shadow plan does not admit a reader or
writer. Other key/value types, nullable containers, further nesting, and
alternate ClickHouse physical layouts remain rejected until separately
verified. Existing exact Map/Array admissions must remain unchanged.

The factual anchor is a stock ClickHouse 26.7.1.1315 Wide/LZ4/plain-`.mrk2`
part that passed `CHECK TABLE`. Its payload stream order is
`payload.size0`, `payload.size1`, `payload%2Ekeys.size`,
`payload%2Ekeys`, `payload%2Evalues`. The current shadow builder hardcodes
Map's `.size0`, so nesting it below Array would collide with the outer
Array `.size0`; the nested offset depth must be carried through Map lowering.
The reader and writer currently dispatch by exact shapes, so the plan alone
cannot establish operational support.

Risk is CAUTION: a plausible but wrong inner offset or key-size mark can
shift later rows while leaving stream checksums valid, and a Crystal
self-read does not establish stock-server compatibility. The first falsifier
is a RED plan test for distinct `.size0` and `.size1` streams with their
table-row, outer-element, map-entry, and key-byte axes. Then a stock-written
part must fail typed admission before implementation. The bounded build will
use the depth-aware physical plan for stream naming/cardinality while keeping
codec admission explicit; reader and writer must agree on exact rows and
ordered Map entries, including empty Arrays, empty Maps, duplicate keys,
empty and binary String keys, zero UInt64 values, selected later marks, and
terminal marks. Fail before yielding an affected mark on malformed nested
offset, key-size, or physical extent.

DoD: the RED probes turn green; a pinned bidirectional oracle checks stock
stream inventory, all `.mrk2` coordinates and terminal sentinel, metadata,
stock-to-Crystal full/keyed RowBinary, and Crystal-to-stock `ATTACH PART`,
`CHECK TABLE`, and full/keyed RowBinary; focused corruption tests exercise
later-mark cardinality failure; adjacent exact type oracles and full debug
and release suites pass; a hostile review finds no unresolved in-scope
falsifier. Rollback is the isolated W80 commit. Evidence decays if pinned
ClickHouse nested serialization, codec/mark layout, or shared type dispatch
changes. This slice does not prove arbitrary recursive types, MV/projection
semantics, or a speed target. Complete type coverage and MV/projections
before beginning optimization.

W80 observed evidence: the pinned ClickHouse 26.7.1.1315 bidirectional oracle
passed exact stream/mark/metadata checks, stock-to-Crystal full and keyed
RowBinary, and Crystal-to-stock `ATTACH PART`, `CHECK TABLE`, and full and
keyed RowBinary. It covered duplicate and binary String keys, empty inner
Maps and outer Arrays, a middle empty mark, and a terminal empty mark at
nonzero child-stream EOF. Focused tests rejected a shifted later inner-offset
mark before any row callback and preserved `UnsupportedFormatError` for a
checksum-valid non-LZ4 frame header. Adjacent W73, W78, and W79 pinned
oracles passed. The full debug and release suites each passed 1041 examples
with zero failures, errors, or pending tests using `-fuse-ld=ld`; Crystal
formatting, shell syntax, and `git diff --check` also passed.

The bounded hostile review found no overflow or out-of-bounds path in the
new frame-checksum discriminator but identified a P2 error-classification
limit: an adversarial frame-like byte sequence inside an existing frame could
make a corrupt interior mark appear to have an unsupported codec. The reader
still rejects it before returning rows. W80 therefore establishes exact
read/write compatibility and fail-closed behavior for the tested physical
layout, not perfect classification of arbitrary corrupt offsets, other
ClickHouse versions, or general recursive Array/Map support.

## W81 admitted frontier: bounded Array of primitive-numeric Maps

W81 extends W80's one-spelling special case with paired reading and
writing for the closed family `Array(Map(K, V))`: `K` is `UInt64` or `String`,
and `V` is one of `UInt8`, `UInt16`, `UInt32`, `UInt64`, `Int8`, `Int16`,
`Int32`, `Int64`, `Float32`, `Float64`, or `Nullable` of one of those ten
leaves. Admission must be exact after parsing; `Array(Map(...))` with other
keys, values, or another container layer remains rejected. This is a type
compatibility change, not a memory/performance change. Existing exact W80
behavior and all standalone Map/Array behavior must remain stable.

The factual anchor is W80's stock-verified outer Array/inner Map offset
topology and the existing paired numeric/nullable Map leaf codecs. The
bridge tested here was whether those codecs compose under a second offset
depth for both key shapes. The likeliest failure was a later-mark offset or
null-map shift that self-round-trips but changes ClickHouse's interpretation.
Before admission, a RED test exercised the new key/value stream names and
axes, and stock-written parts were rejected by the old typed dispatcher.
The bounded build generalizes plan, reader, writer, table batch, and
catalog dispatch together, retaining pre-materialization validation and
explicit per-mark accounting. It must preserve duplicate Map keys, String
key bytes, float bits, and NULL versus zero, and fail before yielding any row
of a malformed selected mark.

Risk is CAUTION because physical serialization, checksum inventories, and
table-visible data change. Rollback is one isolated W81 commit. DoD is a
pinned ClickHouse 26.7.1.1315 bidirectional oracle for both key shapes and
nullable/non-nullable numeric representatives, including full/keyed RowBinary,
mark topology/sentinel checks, Crystal-to-stock `ATTACH PART` and `CHECK
TABLE`, plus later-mark corruption and negative-admission tests; debug and
release suites, adjacent W78-W80 oracles, formatting, and a hostile review
must pass. Passing representatives does not alone prove every admitted leaf:
the complete closed declaration matrix needs a programmatic codec-width and
round-trip check before claiming family parity. Evidence decays when pinned
ClickHouse serialization, mark/codec layout, or shared type dispatch changes.
MV and projection support, other type families, and performance remain outside
this slice; optimization starts only after type and MV/projection completion.

W81 observed evidence (2026-09-29): the pinned ClickHouse 26.7.1.1315
bidirectional oracle passed for both key shapes and nullable/non-nullable
numeric representatives. It compares physical streams, marks, and sentinels,
then checks stock-to-Crystal reads and Crystal-to-stock `ATTACH PART`, `CHECK
TABLE`, and full/keyed RowBinary. The all-empty String-key nullable case
also passed with zero-byte child streams and zero child mark offsets while
the structural map-size stream advanced. Local writer/reader tests cover all
40 admitted declarations, including physical widths, signed leaves, float
bits, and NULL versus zero. Selected later-mark corruption of `size1` and
the nullable value stream rejects before callbacks; negative admission and
catalog-owned String-key values are covered. The complete debug and release
suites each passed 1050 examples with no failures or errors; adjacent W78,
W79, and W80 full oracles, format, shell syntax, and diff checks passed. A
scoped hostile review found no concrete blocker. The external stock oracle
is representative, not a proof of stock compatibility for every one of the
40 declarations or other ClickHouse versions. No MV/projection or
performance claim follows from this evidence.

## W82 admitted frontier: String leaves inside bounded Array(Map)

Paired reading and writing are admitted for exactly
`Array(Map(UInt64, String))`, `Array(Map(String, String))`,
`Array(Map(UInt64, Nullable(String)))`, and
`Array(Map(String, Nullable(String)))`. The reader, writer, table batch, and
catalog agree on these four declarations. Other keys, value types, aliases,
whitespace variants, and
additional container layers remain rejected. No memory or performance work is
in scope; complete type compatibility, then MV/projections, before tuning.

The factual anchor is W81's stock-verified outer Array/inner Map offsets and
the existing String/Nullable leaf codecs. The highest-risk bridge is nested
axis and byte-length accounting: a self-round-trip could pass while ClickHouse
reads later marks, empty strings, or null values differently. First, capture
the exact physical streams/marks with the pinned ClickHouse 26.7.1.1315
binary. Then add a RED exact-admission/stream-axis test, including rejection
of `Array(Map(String, Array(String)))` and
`Array(Array(Map(String, String)))`. The implementation may share recursive
physical-plan and leaf-codec logic, but must preserve every W80/W81 descriptor
and reject all unadmitted neighboring shapes. If a shared compiler needs
shape-specific axis surgery, changes an existing descriptor, or cannot model
Map-entry versus String-byte axes unambiguously, do not promote that route.

Risk is CAUTION: the change affects serialized data, checksums, and public
table visibility. Rollback is one isolated W82 commit. DoD requires a pinned
bidirectional stock oracle (physical streams, marks, sentinels, stock-to-Crystal
full/keyed RowBinary, and Crystal-to-stock ATTACH/CHECK), targeted empty/null
and later-mark corruption-before-callback checks, exact negative admission,
unchanged W80/W81 descriptors, debug/release suites, and hostile review.
Representative oracle cases cannot prove other layouts or all ClickHouse
versions. Evidence decays if the pinned stock serialization or shared stream
dispatch changes. MV/projections and the eventual at-most-10%-slower performance
gate remain outside W82.

W82 stock-only observation (2026-09-29): the pinned ClickHouse 26.7.1.1315
binary produced all four exact Wide-part stream inventories and four 24-byte
mark records per stream for the five-row fixture, with row counts `[2,2,1,0]`
including the terminal mark. Exact raw streams and full/keyed RowBinary
matched the fixture, including invalid-byte Strings and all-empty child
streams. In `Nullable(String)`, NULL contributes null-map `1`, an eight-byte
zero String length, and no value bytes; a non-null empty String has null-map
`0` with the same zero-length child. This is stock-layout evidence only, not
reader or writer admission.

W82 observed implementation evidence (2026-09-29): the pinned bidirectional
oracle passed for all four declarations with populated/binary values and
all-empty child streams (eight cases). It compares raw streams, marks, and
sentinels, stock-to-Crystal full/keyed RowBinary, and Crystal-to-stock
`ATTACH PART`, `CHECK TABLE`, and full/keyed RowBinary. Focused tests passed
15 examples and the full debug and release suites each passed 1060 examples
with no failures or errors. The adjacent W80 and W81 full bidirectional
oracles passed on the same tree. Selected later-mark corruption rejects before
callbacks. An aggregate
preflight also rejects over-limit materialization across multiple selected W82
columns before callbacks. A scoped hostile review found no concrete W82
blocker. This preflight does not establish whole-scan callback atomicity for
mixed W82 and legacy columns; representative oracle cases do not prove every
layout or other ClickHouse versions. Evidence decays when pinned stock
serialization, mark/codec layout, or shared dispatch changes. MV, projections,
remaining types, and performance remain open.

## Rejected and guard-only surfaces

Rejected for W1: mutation of existing parts, table-level `INSERT`, merges,
replication, transactions across tables, SQL, Compact parts, compressed
marks, composite codecs, `Nullable`, `String`, JSON, projections, deletes,
TTL, and arbitrary partition expressions. No performance claim is admitted.

Residual guard-only surfaces:

1. Extend reader and writer together beyond W68-W71's exact nested nullable
   Map combinations and W66's exact nested Time/Time64
   Arrays and W65's exact nested Date/Date32/DateTime/DateTime64 temporal,
   W64's exact nested Decimal, W63's exact `Map(String, Array(UInt64))`,
   W62's exact nested extended numeric, and W61's exact nested nullable
   String Arrays, W60's exact nested nullable primitive numerics,
   W59's nested String Arrays, W58's nested primitive
   numerics, W57's three-alternative Variant, W56's paired Variant,
   W55's exact two-UInt64 named-Tuple Array, W54's exact nullable-String Maps,
   and W53's
   nullable-UInt64-value Maps,
   W52's paired String-key Maps,
   W51's paired named-Tuple Arrays,
   W50's paired Time family,
   W49's paired BFloat16 family,
   W48's paired Enum Arrays, W47's paired IPv6 Arrays,
   W46's paired IPv4 Arrays,
   W45's paired Decimal256 Arrays,
   W44's paired Decimal128 Arrays,
   W43's paired Decimal64 Arrays,
   W42's paired Decimal32 Arrays,
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
   W72's bounded scalar JSON typed paths, W23's exact named Tuple,
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
