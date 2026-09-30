# Compositional Tuple Frontier

Status: W91 neutral payload ownership is VERIFIED below; compositional Tuple
admission remains PROPOSED. No new Tuple shape is admitted by this document.
Continuation anchor: `3f09429`, with W90 debug/release and W80-W85 oracle
verification recorded in `MODULARIZATION_FRONTIER.md`.

## Confirmed problem

The current reader, table accessor, and writer support the exact
`Tuple(a UInt64, b String)` profile. `WidePart.supports_tuple_uint64_string_type?`
and `WidePartTable#tuples_for` are exact-shape APIs; retain their behavior.
`OfflineColumnValue` also has only the exact `Tuple(UInt64, String)` variant.

The reader's scalar numeric/String methods validate the root column type,
so they cannot directly decode a child of a Tuple. The existing exact Tuple
reader decodes its two physical fields itself. The writer already invokes
private UInt64/String stream writers at `%2Ea` and `%2Eb`. Adding more complete
type-string branches would duplicate codec responsibilities rather than make
Tuple compositional.

Source reference: ClickHouse `a9581941254d6113f3740a8ec125ee7519cb1bda`,
`src/DataTypes/DataTypeTuple.cpp`. Each field delegates to its own serialization
under `SerializationNamed(..., TupleElement)`. Explicit names must be nonempty,
unique, and not `null`; unnamed fields use positional names `1`, `2`, and so on.
The factory accepts an empty Tuple. The pinned 26.7.1.1315 binary also accepted
zero- and one-field type-expression probes; persisted empty-Tuple behavior
has not been tested.

## Proposed boundary and architecture

First extract shared UInt64/String payload responsibilities without changing
admission or bytes. Writer leaf owners accept a logical physical prefix. The
reader's numeric bit decoder is already shared; root String and Tuple String
will share a context-free String materialization iterator. Keep root-schema
validation and context-sensitive stream/mark/frame checks in `WidePart` until
an explicit physical-stream context has its own separately verified boundary.
Each concrete owner should have one source file; do not add another full-type
Tuple codec to the existing monoliths.

Only after that seam passes parity checks, propose a named, nonempty Tuple
profile with UInt64/String leaves for both reader and writer. Use the existing
type-expression, stream-count, row, and byte budgets instead of an arbitrary
2-8 field limit. Restrict initial names to the supported simple identifier
grammar and distinguish that library guard from ClickHouse's wider grammar.
Empty, unnamed, recursive, nullable, and other scalar leaf profiles need
separate probes; their rejection does not mean ClickHouse rejects them.

Represent a Tuple as ordered field descriptors and columnar leaf buffers,
not a Cartesian union of `Tuple(T1, ..., Tn)` instantiations. Immutable metadata
records field name, leaf type, and physical prefix. An initially owned buffer
union grows linearly with admitted leaf types. Existing borrowed batches must
not be confused with a retained owned Tuple result; document copies and
lifetimes explicitly. Generic `OfflineColumnValue` row mapping is a separate
expansion, not part of this first profile.

Preflight selected schema/profile and stream/mark metadata before callbacks;
validate alignment and charge all fields of each materialized mark before
that mark's callback. Do not decode future payloads eagerly or promise that
corruption in a later mark prevents earlier callbacks. Validate all writer
fields and row counts before stage creation and retain failure cleanup.

## Next falsifier and verification

The first architecture falsifier is whether the same leaf implementations can
serve scalar and arbitrary Tuple prefixes without relaxing root admission or
copying payload codecs. Preserve the existing pair API's exact results and
bytes after the behavior-neutral extraction, including callback exceptions.

For the later admission slice, use a reordered
`Tuple(c String, a UInt64, b String)` across several marks and a short final
mark, with distinct empty/NUL/binary String values. Test 1, 2, 3, and 9 fields;
nine is a counterexample to an arbitrary cap, not a maximum. Reject unsupported
later fields, duplicate/reserved names, and mismatched vector lengths. An
injected stage-factory call counter must remain zero on invalid writer input;
an empty destination alone is insufficient evidence.

DoD: focused leaf/pair/composition specs, full debug and release suites,
`git diff --check`, format checks, and a pinned binary oracle exercising
stock-created -> Crystal-read and Crystal-written -> stock `ATTACH`/`CHECK`,
with full and ranged RowBinary equality. Passing type-expression probes does
not replace persisted-part evidence. Keep old pair tests and unadmitted-neighbor
guards, and obtain scoped hostile review before a compatibility claim.

Risk: CAUTION. Use separate atomic commits for behavior-neutral leaf ownership
and new type admission; each commit is its rollback boundary. Performance work
remains deferred until type and MV/projection frontiers close. The active goal
also retains the matched ClickHouse slowdown <=10% condition, not yet proven.
In-scope local implementation and tests remain authorized; push, a new binary
installation, and external data mutation are not authorized by this capsule.
Refresh this proposal if leaf consumers, admission, lifetime contracts, the
source reference, or the pinned executable/profile changes.

## W91 behavior-neutral execution seal

The inventory falsified the assumption that physical stream decoding can move
to a context-free leaf owner: `WidePart#each_mark_range_bytes` derives empty-EOF
and frame/profile admission from the selected root type and physical stream
names. Do not copy or relax that logic. This slice owns payload assembly and
encoding only; generic Tuple admission and physical-stream-context extraction
remain PROPOSED.

Ownership and paths:

- Reader: `wide_part/string_payload_decoder.cr`, private
  `WidePart::StringPayloadDecoder.each`, and its callers in `wide_part.cr`.
  Yield Strings and indices directly into existing scalar/Tuple result arrays;
  do not add intermediate String/UInt64 arrays. Tuple uses the existing
  `decode_numeric_value(..., UInt64)` bit decoder. Preserve root admission,
  row alignment, budgets, selected-range validation and error ordering.
- Writer: `wide_part_writer/leaf_stream_writer.cr`, private
  `WidePartWriter::LeafStreamWriter`; move the actual UInt64/String payload
  method bodies, not just a wrapper. Extract private `ChecksumRecord` and shared
  `StreamEncoding` into their own files if required, preserving nominal record
  identity. Existing private writer entrypoints remain delegates. Schema
  preflight, stage lifecycle, checksum aggregation and staged validation stay
  in the writer.
- Root integration: aggregate requires, this frontier, and
  `scripts/check_tuple_oracle.sh`. Worker-specific specs are
  `wide_part_reader_payload_seam_spec.cr` and
  `wide_part_writer_leaf_seam_spec.cr`.

Pre-change discriminator: establish the missing-owner architecture red before
production changes. Reader seam compile-red exited 1 on the undefined private
owner; writer owner-file existence probe exited 1 while Crystal builds were
held for the user-requested Qwen memory slot. No pre-change writer seam compile
was executed; the later green gate must not be presented as that red. These
are architecture-existence probes, not evidence of a pre-existing behavioral
defect. Negative controls cover exact Tuple/scalar-root admission and wrong
escaped physical prefixes. Existing
scalar/String/Tuple specs establish decoded bytes, independent marks, empty
streams, short final granules and failure cleanup.

DoD commands: the two seam specs plus existing fixed numeric, String/nullable,
W23 reader and writer scalar/typed/Tuple specs (including
`wide_part_writer_typed_spec.cr` for mixed/all-null `Nullable(String)`); full
`crystal spec` and `crystal spec --release`, each with
`--link-flags='-fuse-ld=ld'`; format checks
for touched Crystal files and `git diff --check`; pinned
`bash scripts/check_tuple_oracle.sh`, `bash scripts/check_typed_writer_oracle.sh`
and `bash scripts/check_wide_part_writer_oracle.sh`. Expected signal is zero
failures and byte-exact pinned oracle checks, not improved performance.

Strongest failure modes: root admission accidentally becomes child admission;
escaped String `.size` prefixes, terminal marks or all-empty frames change;
writer cleanup/checksums change through helper extraction. Guard with negative
root/prefix tests, exact raw-byte and mark assertions, binary/all-empty String
oracles, and full-suite coverage of the shared UInt64 writer's consumers.
Rollback is one atomic neutral-seam commit. The declared neutral-seam DoD
passed below; it does not certify new type or metadata admission.

### Stock-created metadata counterexamples (pre-extraction)

The new pinned 26.7.1.1315 stock-created Tuple probe read the admitted mixed
`id UInt64, payload Tuple(a UInt64, b String)` profile at sparse ratio 0.9375,
including full and mark-range binary equality. It then falsified broader
reader compatibility on three independently stock-created profiles:

- Ratio 1.0 omits per-column serializer records; the reader demands two.
- `pk` before `payload` in `columns.txt` differs from stock serializer-record
  ordering; the reader incorrectly treats record order as a format boundary.
- All-empty child String values at ratio 0.9375 select Sparse child metadata;
  the reader admits only Default child serialization and physical streams.

Keep those explicit rejection controls in W91. Reordered/omitted Default
metadata needs a separate admission fix before generic Tuple expansion;
Sparse child serialization needs its own physical-stream plan. A negative
control certifies safe rejection, not closure of the requested compatibility.
The final edited oracle and full release suite passed after extraction, with
these rejection controls retained. Do not infer newer-master binary support
from these pinned 26.7 runtime observations.

### Separate next boundaries (source inventory only)

The smallest metadata admission proposal is to validate the exact top-level
serializer-name set rather than record order. Preserve uniqueness, completeness,
per-role field/count/kind checks, and positional Tuple child order. An exact
empty `columns` list is a distinct stock AlwaysDefault metadata profile; do
not infer it from an arbitrary missing or partial list. At the reference
commit, `SerializationInfoByName` is a `std::map` in
`SerializationInfo.h`, its `writeJSON` iterates by name, and its constructor
omits entries when `settings.isAlwaysDefault()` in `SerializationInfo.cpp`.
Both proposals retain the current outer metadata/version and exact physical
stream checks. Duplicate, partial, unexpected, and Sparse records are the
negative controls. This is not yet an admission design seal or implementation.

Source inventory also found two different existing EOF policies:
`parse_marks` allows the exact Tuple `%2Eb` raw stream's positive-row marks at
EOF, but `each_mark_range_bytes` has no corresponding Tuple empty-payload
case. Both the exact Tuple read and raw-byte preflight call that range reader,
even for zero expected bytes. The writer omits empty String frames, and its
staged validator deliberately skips empty raw-frame readback. The cheapest
next runtime falsifier is therefore a library-written one-row
`Tuple(a UInt64, b String)` with `{7_u64, ""}`, followed by full/ranged reads
and raw-byte preflight. The source predicts the current EOF error; this probe
has not been executed and is not a verified bug report.

A future neutral physical-stream owner must derive and retain separate
mark-EOF and range-EOF rules at admission, rather than silently unify them.
It also needs the existing frame-profile/error-order policy: unrestricted,
Variant LZ4, Dynamic LZ4, or Array(Map) LZ4 with its checksum-first corruption
guard. Re-stat the file per operation, retain callback-scoped mmap/chunks and
an operation-local decode workspace, and reuse checksum/bit helpers. Fixing
the Tuple EOF mismatch is a separate compatibility action before or after
that extraction, not an unannounced part of W91. Both routes remain PROPOSED.

A separate writer inventory found 170 public `write_*` entrypoints, all
constrained to a UInt64 key and one top-level payload column, including the
generic typed-pair and multi-path JSON facades. More Tuple fields do not make
this an arbitrary-table writer. The smallest future lifecycle boundary is a
private schema-driven staged-part owner: ordered column/stream descriptors,
common row/mark layout, an explicit index profile, per-column validation,
metadata/checksum/index production, exclusive publication and cleanup. An
initial UInt64 index profile would still be constrained N-column writing;
other primary keys need separate admission. Existing validators do not
uniformly assert complete file inventories or every recorded hash, so the
new contract must not silently upgrade those guarantees. This inventory
does not authorize that refactor inside W91 or admit a new writer API.

## W91 observed result (2026-09-30 UTC)

State: VERIFIED within the aggregate `require "./crystal_click"` boundary.
The frozen source is `015fa2f` plus this neutral extraction. Four concrete
owners each have one file: private reader `StringPayloadDecoder`, writer
`LeafStreamWriter` and `StreamEncoding`, and the original private
`ChecksumRecord` struct. The reader yields owned Strings directly into the
existing result arrays, without intermediate leaf arrays. Root admission,
physical stream/range rules, budgets, stage preflight, validation, publication
and cleanup remain with their previous owners. No new Tuple shape is admitted.

Root mechanically compared ten moved declarations/bodies, including the
checksum record, with `015fa2f`: they were identical after indentation,
private-method visibility and helper qualifier normalization. The 13 new
examples cover owned binary/empty/multibyte Strings, UInt64 bounds, callback
exceptions, exact root rejection, arbitrary escaped physical prefixes,
independent marks, terminal offsets, checksums and zero-byte String streams.

Observed DoD: 72 focused examples, 1,145 full debug examples and 1,145 full
release examples, each with zero failures/errors/pending. Debug test execution
took 37.94 seconds and release 18.65 seconds; compilation is excluded, and
neither timing is a matched reader benchmark. All three pinned
`26.7.1.1315` oracles passed:

- Tuple: stock-created mixed Default profile -> Crystal full/mark-range
  RowBinary equality and strict scalar-root rejection; reordered, omitted and
  Sparse metadata remain explicit negative controls. Crystal-written parts
  -> stock ATTACH/CHECK and full/key-range RowBinary equality, including
  binary/empty Strings, independent marks and a zero-byte all-empty raw stream.
- Typed writer: 22 scalar/Nullable shapes plus all-null/all-empty controls,
  exact stock rows/key ranges, ATTACH/CHECK and independent corruption checks
  for nonempty selected streams.
- Basic writer: UInt64, Nullable and mixed/all-empty String parts, exact stock
  full/key-range results, ATTACH/CHECK, and index/null-map/raw/size-stream
  corruption detection.

Execution environment and commands:

```sh
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
export CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w88-cache
export CLICKHOUSE_BIN=/Users/sergey/.local/bin/clickhouse
export TMPDIR=/private/tmp
crystal spec spec/wide_part_reader_payload_seam_spec.cr \
  spec/wide_part_writer_leaf_seam_spec.cr \
  spec/wide_part_reader_w23_spec.cr spec/wide_part_writer_tuple_spec.cr \
  spec/wide_part_writer_spec.cr spec/wide_part_writer_typed_spec.cr \
  spec/string_nullable_scan_spec.cr spec/fixed_numeric_scan_spec.cr \
  --link-flags='-fuse-ld=ld'
crystal spec --link-flags='-fuse-ld=ld'
crystal spec --release --link-flags='-fuse-ld=ld'
bash scripts/check_tuple_oracle.sh
bash scripts/check_typed_writer_oracle.sh
bash scripts/check_wide_part_writer_oracle.sh
```

The focused gate used a separate `crystal-click-w91-focus-cache`; each oracle
creates its own temporary cache. Crystal is 1.21.0, LLVM 22.1.8, on aarch64
Darwin. Touched-file Crystal format, Tuple shell syntax and diff whitespace
checks passed. The evidence-packet skill's referenced template and validator
are absent from its installed directory and this repository; this frontier
is the curated fallback, not a validator-backed JSON packet.

Scoped hostile source review returned ROBUST for neutral ownership at the
aggregate import boundary. Same-lineage reviews are correlated; root's
mechanical comparison and executed suites/oracles are the additional evidence.
Direct internal-file imports, mutable caller inputs during synchronous writes,
generic Tuple admission, Sparse/omitted/reordered metadata compatibility and
current-master runtime compatibility are outside that verdict. The predicted
all-empty Tuple reader EOF mismatch above remains an unexecuted next falsifier;
the empty-payload seam tests and stock writer acceptance do not close it.

Evidence decays if owner bodies, root admission/range policy, require order,
Crystal semantics, fixtures or the pinned executable/profile change. Re-run
the affected focused/full/oracle checks rather than transferring this result
to new types. The full type/MV/projection goal and matched slowdown <=10%
condition remain open. Next: prove or refute the exact Tuple empty-EOF
counterexample, then separately admit stock Default metadata profiles before
generic Tuple expansion. Push still requires new authority.
