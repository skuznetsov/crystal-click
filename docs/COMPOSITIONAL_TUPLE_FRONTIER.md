# Compositional Tuple Frontier

Status: PROPOSED. No new Tuple shape is admitted by this document.
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

First extract path-parameterized UInt64/String leaf decoding and encoding,
shared by scalar and Tuple paths, without changing admission or bytes. Keep
root-schema validation in the caller and retain leaf stream/mark/bounds checks
inside the codec owner. Each concrete owner should have one source file;
do not add another full-type Tuple codec to the existing monoliths.

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
