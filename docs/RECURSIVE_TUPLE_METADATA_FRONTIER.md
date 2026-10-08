# Recursive Tuple serialization metadata frontier

Document status: VERIFIED within the declared finite scope (W218, 2026-10-08).
Baseline: `b2a06eec9b73745c87941f060f29d40b70cc0a28`, with the uncommitted
W217 projection-consumer candidate preserved separately.

## Problem and boundary

At the baseline, a stock-authored `Tuple(doc JSON(...), n UInt64)` supplies
Default serializer `subcolumns` in `serialization.json`, but the recursive
reader passes no validator to ObjectColumnPartMetadata. This valid physical
context is refused before values are read. Leaf codecs and stream schedules
already exist; the change must validate the metadata, not bypass it.

## Design laws

- Bind selected child serializer records to the selected StorageColumnSchema
  in schema order, with exact Tuple arity and supported field sets.
- A JSON-free BinaryBulk Tuple still owns Tuple serializer-info children.
  Traverse its named/unnamed BinaryDataType Tuple descriptor as well as
  structural StorageColumnSchema Tuple nodes. Array and other non-Tuple
  wrappers have opaque Default info; do not infer a metadata child tree from
  their value-codec recursion.
- Admit only the evidenced Default profile; validate nonnegative row/default
  counts, their bounds and the correct parent occurrence domain.
- `exact_num_defaults` is optional Boolean metadata: absent means false and
  both Boolean values are accepted; non-Boolean values and unknown fields are
  rejected. This flag does not select a different Default stream layout.
- Bound recursive metadata traversal before allocating or descending. Nested
  Tuple metadata follows the serialization-info tree, not a guessed physical
  element count; Array occurrence schedules remain the reader's responsibility.
- Keep the existing part envelope, version/profile, foreign-sibling, exact
  physical-roster, checksum, row/mark and complete-schedule checks unchanged.
- Preserve valid legacy sparse metadata produced by the current writer; do not
  require a selected record where the admitted envelope permits its absence.
- Unsupported child fields, wrong arity/kinds/counts and metadata on unrelated
  siblings remain rejected. No new JSON layout or writer wire profile is added.

## Plan and verification

Risk: CAUTION (storage admission). Rollback: revert only the exact W218-owned
diff; do not discard the pending W217 candidate or other workers' changes.

1. Add `spec/recursive_tuple_metadata_w218_spec.cr` with ordinary non-projection
   controls and stock-shaped selected metadata. Root must observe behavioral
   RED before production changes; compiler failures do not qualify.
2. Add one schema-bound validator class in its own file and minimally connect
   it to RecursiveStorageColumnReader. Enumerate call sites and preserve the
   Object metadata owner's default strict policy.
3. Root runs serial guarded DEBUG/RELEASE focused and affected recursive
   reader/writer/table regressions with `--single-module --threads 1
   --link-flags=-fuse-ld=ld`; expected zero failures, errors and pending.
4. Refresh the stock Tuple(JSON) case in the original six-family W217 native
   probe; do not rename/reduce fixtures or relax its DoD. Attack malformed
   metadata and a validator-bypass seed before a verified claim.

The declared native oracle and the existing recursive writer/reader controls
are complementary evidence, not proof of all type/layout products. Root alone
runs resource jobs under the unchanged min-free 50% guard. No push.

## Observed pre-implementation discriminator

Root executed the focused DEBUG spec under the unchanged guard. It compiled
and ran eight examples: zero assertion failures, five runtime metadata errors,
zero pending, exit 1. The five positive controls are refused by
ObjectColumnPartMetadata before decoding. This is behavioral RED, not a
compiler failure. The off-schema deep-tree negative does not certify a depth
budget; direct owner-budget checks remain required.

Pinned source anchors: SerializationInfo.cpp:357-410 models the optional flag;
SerializationInfoTuple.cpp:174-220 writes ordered, exact-arity subcolumns;
DataTypeTuple.cpp:365-404 creates recursive Tuple info. DataTypeArray inherits
IDataType's nonrecursive info even though its value serialization recurses.

Evidence expires on schema binding, serializer-info traversal, metadata
envelope, source/runtime pin or physical input changes. Refresh affected tests
and native inputs before reusing a claim. The overall goal remains active.

## Observed closure

`RecursiveTupleSerializationMetadata` validates structural Tuple and JSON-free
BinaryBulk Tuple metadata in schema order under depth/node/element limits.
Array and other non-Tuple serializer-info records stay opaque even when their
value codecs recurse. Existing sparse selected-record admission is preserved.
Primitive leaf info does not encode a type identity; validation is bounded to
the structural position, supported Default fields/counts and declared schema.

The final 11-example focused Tuple corpus and the combined 26-example new
corpus pass in DEBUG and RELEASE. The complete declared affected gate passes
252 examples per mode across 48 files. A temporary production bypass of the
new validator makes the unchanged Tuple corpus fail: one assertion failure,
five errors, zero pending, exit 1. The seed is restored before final gates.

The original six-family stock oracle passes all six families in each mode,
including `Tuple(doc JSON(...), n UInt64)` projection children. Both fresh raw
evidence trees pass the separate SQL/process/schema/grid/source and physical
file audit. This qualifies the recorded Default profile, not Sparse/Replicated
info, all wrapper products or a new writer profile. See
[W217 evidence packet](../.landmark/evidence/specialized-projection-readers-w217.json).
