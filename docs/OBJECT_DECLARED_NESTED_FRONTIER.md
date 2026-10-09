# Declared Object Nested composition (W236)

Status: VERIFIED, root hostile verdict ROBUST within the finite W236 scope.
Baseline `cda3ae3c72e61011293f9c272acc806de880f818` was clean. Three existing
declaration-policy owners changed; no leaf/value/bulk codec changed.
The full goal remains CH-compatible read/write types and MV/projections before
memory/performance work and the original <=10% slowdown target.

## Current boundary and candidate

The previous Object declaration grammar omitted the nominal Nested descriptor
and borrowed `Nested(...)` spelling although generic descriptor/value/bulk
Nested serde already existed. W236 closes that declaration seam. W235's stock-refused
static JSON/QBit combinations remain refused; they do not justify rejecting
ordinary Nested with supported children or inventing another leaf codec.

Source candidate pin: `/Users/sergey/SrcArchives/clickhouse-2026-10-07-depth1`,
revision `0ca8150d9b1d0886edb2e3b4ab65eebb768d0357`.
`DataTypeNested.cpp:35-75` preserves a nominal custom name over Array(Tuple).
`JSONExtractTree.cpp:2767-2779` recurses through the underlying Array/Tuple.
Source observations alone do not prove persisted compatibility. The separately
pinned native `26.10.1.1201`, build
`d9bcb5ab007f0f6299f7f973f2642245bab3d028`, accepted all five tested nominal
schemas, persisted the fixtures and consumed the library parts in both modes.
This is not a claim that the source revision built that runtime.

Admission: ordinary Nested with supported static descendants inside
declared JSON paths, composed through existing lawful Array/Tuple/Map/Variant
wrappers. Native probes must preserve the exact observed name and substreams.
Nullable(Nested), LowCardinality(Nested), static QBit descendants, unsupported
aggregate/Object descendants and unqualified runtime-owner intersections stay
rejected. No automatic runtime Dynamic/JSON/shared-data widening is allowed
merely because a static declaration becomes parseable. Ordinary typed-Object
Dynamic actuals containing Nested remain rejected. The earlier qualified
QBit/shared-JSON owner branches retain their separate admission rules.

## Composition, not product codecs

The same leaf serde composes recursively. Array/Nested add child cardinality
axes, Tuple adds named field axes, and the existing bulk/physical plan maps
those axes to streams and mark coordinates. The declaration seam must also
preserve nominal identity and the owner's legal grammar. Stateful prefixes,
dictionary/type rosters and physical version selection do not disappear just
because a child value codec exists. This matches upstream's distinct
`ISerialization` value and stateful multi-stream bulk interfaces.

W236 adds no `ArrayNestedCodec`, `MapNestedCodec` or other product-specific
serializer. See [modularization direction](MODULARIZATION_FRONTIER.md) for the
existing one-owner-per-responsibility architecture; broad facade decomposition
is not part of this serialization change.

## Design laws and risk

- Reuse the current child codecs, value model and bulk stream plan. Preserve
  nominal Nested identity and the implicit named Tuple; do not erase it to an
  ordinary Array(Tuple) without an evidenced metadata rule.
- Descriptor/text preflight, materialization, rendering and budget accounting
  must agree on the implicit Tuple depth, child edges and name metadata. Validate
  complete borrowed source and forged preflight before proportional allocation.
- Logical Nested child counts are not enclosing Object rows or physical mark
  rows. Empty/default typed paths must use native defaults. No fresh caller
  budget per path, wrapper or mark may bypass existing aggregate limits.
- Complete shape admission must precede observable descriptors/callbacks where
  the current owner promises that guarantee; do not claim authentication of
  unselected payloads, RSS bounds or performance from these checks.
- New responsibilities have separate files. No broad facade refactor, new
  dependency or optimization is part of this type-format change.

Risk: CAUTION (persistent serialization). Highest-risk assumption: generic
Nested bulk support alone makes Object declared storage compatible. Native
persistence and both-direction checks are the guard against that inference.
Rollback: exact owned diff from the clean baseline, then one atomic local commit
after the DoD. Preserve other edits. No push or remote/history mutation.

## Execution and Definition of Done

1. `scripts/recheck_object_declared_nested_stock_w236.rb`: isolated stock CREATE,
   INSERT, CHECK, exact schema/part inventory and literal full/middle/empty
   RowBinary for direct, Array, named Tuple, Map and Variant Nested candidates
   plus an ordinary JSON control. Bounded raw captures, fixed native pin, fresh
   canonical `/private/tmp` root; timeout/signal/plumbing is not a type refusal.
2. `spec/object_declared_nested_w236_spec.cr`: run a compile-valid RED
   against unchanged production before widening declaration policy. Cover
   nominal and borrowed forms, wrapper composition, exact defaults, implicit
   Tuple/name budgets, invalid owner intersections and preflight mutation.
3. Extend only the inventoried declaration/plan seams after both previous gates
   justify admission. Root assigns exact non-overlapping production ownership;
   reused generic serde, not per-combination codecs, is the intended change.
4. `spec/object_declared_nested_physical_w236_spec.cr` and
   `scripts/check_object_declared_nested_parts_w236.cr`: exercise asymmetric
   cardinalities/strings across multiple marks, missing/empty typed paths and
   full/middle/zero/EOF selections; stock-to-Crystal and Crystal-to-stock
   ATTACH/CHECK/independent literals for the admitted roster.
5. Root executes focused tests plus historical recursive/Object/QBit owner guards
   in DEBUG and RELEASE, formatting, syntax and exact diff checks. Require
   nonzero examples and zero failures/errors/pending. Native/probe and compiler
   jobs are serial under `run_safe.sh`, minimum-free50%, `CRYSTAL_WORKERS=1`,
   at most 600s/12288MiB per guarded major job. Record actually executed commands,
   pins and raw evidence, then hostile-review before a capability claim.

## Observed qualification

- The compile-valid RED on unchanged production ran five examples: three
  admission errors and two passing controls. Compiler/fixture/helper failures
  are retained separately and are not that falsifier or a native type refusal.
- The same 21 spec files pass 114 examples per mode (11 focused, 59 recursive
  schema/Nested, 44 shared-Nested/QBit/runtime-owner regressions), with zero
  failures/errors/pending. Exact recursion/name/byte budgets and forged borrowed
  preflight are covered. The all-empty local direct-Nested fixture retains six
  parent rows across three marks with zero-byte child payload lanes.
- Stock produced six profiles (five candidates plus ordinary JSON control):
  50 actual successful processes. The checker reads the five actual stock parts
  through both Crystal readers, including middle/zero/EOF mark selections.
- Each mode generates the five library parts and the native consumer executes
  42 successful processes: exact nominal schema, ATTACH, CHECK=1 and independent
  full/middle/empty RowBinary. Root audits raw statuses, argv, SQL, schemas,
  attached file bytes and independently packed RowBinary, not witness labels.
  Each consumer audit rejects eight forged process outcomes and six missing
  process fields. The stock audit also rejects those mutations.
- All 146 generated part files match across modes by actual names and bytes:
  18,859 bytes per mode. Native ATTACH preserves those original files and may
  add only the exact two-name invalidated-system-column set; upstream writes
  that set in unspecified order. Stock uses single-stream String serialization;
  library parts retain their declared with-size-stream String profile.
- Six parent rows and three data groups `[2,2,2]` are not the native
  `system.parts.marks=4`, which includes the terminal mark. A missing source
  typed path becomes the native typed default; source absence is not recoverable
  and is not claimed to round-trip.

Scope is quiescent Wide/LZ4/plain `.mrk2`, the fixed five Nested declarations
with UInt8/String children and the pinned native/runtime settings. Local grammar
reuses already admitted static descendants, but this finite native matrix is
not a proof for every parameter/depth/product/version. A late checksum-valid
size mutation fails when its payload is selected; an early selection does not
authenticate unselected payloads. No whole-suite, allocator/RSS/throughput,
MV/projection or broad modularization closure is claimed. The inherited native
recorder has execution/time bounds, not a hard stdout/stderr allocation cap.

Exact commands, log hashes, pins, retained failed attempts and continuation:
[W236 evidence index](../.landmark/evidence/object-declared-nested-w236.json).
Raw roots are temporary; replay the bounded probes when absent.

## Stop, continuity and decay

If stock rejects a candidate or metadata/stream/value equality fails, keep its
guard and pivot to the failing owner boundary; do not manufacture a compatible
part by assertion. A scoped successful test is not the whole type/layout matrix.
Refresh evidence after relevant source/native/compiler/profile/codec/policy or
oracle changes, or loss of captures. Root scratch:
`/private/tmp/crystal-click-w236.P4YPUa`. The overall goal remains ACTIVE.
