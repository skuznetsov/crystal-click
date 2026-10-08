# AggregateFunction(count) physical-name frontier

Document status: VERIFIED within the declared finite scope (W219, 2026-10-08).
Baseline: `b2a06eec9b73745c87941f060f29d40b70cc0a28`, with the uncommitted
W217 projection-consumer candidate preserved separately.

## Problem and boundary

A stock grouped projection declares `intDiv(pk, 2)` and `count()`. Its physical
streams are `intDiv%28pk%2C%202%29` and `count%28%29`; Wide files hash those
escaped identities. At the baseline, the Count plan and ordinary UInt64 sibling
path expect raw names. Both owners must agree on exact physical identity without
accepting arbitrary aliases or changing Count's nominal state codec.

## Design laws

- Preserve raw column identity in columns.txt, selection and public APIs;
  derive physical identities with ClickHouse's bytewise filename escaping.
- Escape raw percent characters rather than interpreting them as existing
  escapes. Exact roster equality, uniqueness and safe file binding remain
  mandatory; raw, noncanonical and double-escaped alternatives are rejected.
- Propagate the same identity through primary-stream selection, state/sibling
  reads, stream widths, hash/file/checksum lookups and admitted writer output.
- Preserve the exact Count descriptor/profile and required UInt64 sibling,
  matching row/mark axes, bounded canonical VarUInt and full-schedule guards.
- Inventory existing writer name restrictions before changing output. Existing
  admitted writer inputs must remain byte-compatible; this is not blanket
  authorization to widen unrelated name grammars or serialization profiles.

## Plan and verification

Risk: CAUTION (shared stream identity). Rollback: exact W219-owned diff only;
preserve pending W217 and W218 changes. Most likely failure: the Count state
opens but its hidden sibling or mark-range reader still uses raw names.

1. Add `spec/aggregate_count_physical_names_w219_spec.cr`: expression names,
   ordinary direct controls, literal percent/dot distinction and wrong-roster
   negatives. Root must observe behavioral RED before production changes.
2. Enumerate all Count plan consumers and raw-key/state uses. Add the smallest
   exact binding change in those owners; do not generalize unrelated layouts
   or weaken physical-shape checks. Root reviews the consumer inventory first.
3. Root runs serial guarded DEBUG/RELEASE focused and affected Count
   reader/writer/table/offline regressions with `--single-module --threads 1
   --link-flags=-fuse-ld=ld`; expected zero failures, errors and pending.
4. Refresh the original grouped Count native case without renaming its columns
   or reducing the six-family W217 DoD. Require child three-row/[2,1] axes
   versus parent six-row/[2,2,2], exact literal stock/library equality, CHECKs
   and independent raw-artifact audit. Attack wrong aliases/axes/checksum files.

Root alone runs resource jobs under the unchanged min-free 50% guard. No push,
new aggregate implementation, expression execution or performance claim.

## Observed pre-implementation discriminator

Root executed the focused DEBUG spec under the unchanged guard. It compiled
and ran seven examples: five assertion failures, one runtime metadata error,
zero pending, exit 1. The plan returns raw Count names; the grouped positive
fails exact-roster admission. Raw malformed roster names currently advance to
file lookup, while the hidden-sibling axis test is stopped by the earlier
unsupported-name guard. This is behavioral RED, not a compiler failure.

The writer admits bounded ASCII identifiers only, so escaping its admitted
names is identity and no name-grammar widening is needed. The narrow ordinary
UInt64 binding change must not escape an existing JSON typed-path separator
as if it were a character of the raw top-level column name.

Pinned source anchors: ISerialization.cpp:441-457 starts regular physical
names with escapeForFileName; escapeForFileName.cpp:8-30 uses uppercase
bytewise escapes. Hashed filenames hash this physical identity, not the raw
logical expression name.

Evidence expires on name escaping/binding, Count profile, sibling admission,
source/runtime pin or physical input changes. Refresh those gates before reuse.
The overall types/MV/projections goal remains active.

## Observed closure

The plan, Count accessor, primary selection and shared UInt64 mark-range path
now agree on exact escaped physical identity. Ordinary UInt64 names are escaped
only outside JSON typed-path and flattened-Nested contexts; typed-path separators
retain their existing physical meaning. The writer's bounded ASCII grammar and
wire profiles remain unchanged.

The final nine-example name corpus and combined 26-example new corpus pass in
DEBUG and RELEASE; the full affected gate passes 252 examples per mode across
48 files. ROOT's first integrated run exposed a remaining raw-key lookup in
`each_mark_range_bytes`: one runtime KeyError, exit 1. The narrow binding fix
is exercised by direct mark-range and grouped table reads. The historical
unsafe-filename test then exposed changed error precedence; selected roster
components now validate before exact-shape comparison, without changing the
old assertion or validating foreign sibling names as selected names.

Fresh DEBUG and RELEASE native oracles retain all six original families and
their original SQL. Count has child three-row/[2,1] schedules versus parent
six-row/[2,2,2] schedules, escaped expression names, exact literal low-level
and catalog values, and successful stock CHECKs. Both raw evidence trees pass
the separate immutable-input audit. Wrong aliases, decoy files, lowercase
escapes and mismatched sibling grids reject in the executed corpus. This is
not a claim about arbitrary aggregate states, names or wrapper layouts. See
[W217 evidence packet](../.landmark/evidence/specialized-projection-readers-w217.json).
