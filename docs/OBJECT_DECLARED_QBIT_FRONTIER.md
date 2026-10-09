# Declared Object QBit composition (W235)

Status: VERIFIED refusal/guard boundary for the stated native pin; not a new
admitted type. Baseline:
clean `00cb48cfca26484913a63eb0b5f6e210ea37c8e2` (W234).
The full objective remains CH-compatible read/write types and MV/projections,
then memory/performance work and the original <=10% slowdown target. A bounded
feature certificate does not satisfy or replace that overall objective.

## Anchor and next discriminator

W234 qualifies QBit actuals at Object runtime sites, not statically declared
Object paths. The live declaration policy has no QBit leaf; the reader's
complete QBit census captures `:typed_dynamic` and inferred `:dynamic`, but
not ordinary declared `:typed` bulk lanes. Existing leaf and static-product
serde must be reused, not duplicated for each wrapper combination.

Source pin: `/Users/sergey/SrcArchives/clickhouse-2026-10-07-depth1`, revision
`0ca8150d9b1d0886edb2e3b4ab65eebb768d0357`.
`DataTypeObject.cpp:861-869` constructs typed paths through DataTypeFactory;
`SerializationObject.cpp:196-233` delegates stream enumeration to the child;
`SerializationQBit.cpp:421-465` delegates bulk serde to its nested tuple.
These are source facts, not native persistence evidence. They are insufficient
for admission: `DataTypeObject.cpp:180-227` also unconditionally builds a
JSONExtractTree while constructing JSON serialization. That tree has no QBit
case (`src/Formats/JSONExtractTree.cpp:2655-2833`). Array, Nullable, Tuple, Map
and every Variant arm recurse into it; the default throws Code 43.

Native candidate: `/private/tmp/crystal-click-w216-runtime-recovery.DmL9Kw/clickhouse-stripped`,
version `26.10.1.1201`, SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
Source and runtime are distinct pins. Do not claim latest-master equivalence.

The stock CREATE at
`/private/tmp/crystal-click-w235-stock.y5i8zm/invocations/0003-static_products-create`
returned `ILLEGAL_TYPE_OF_ARGUMENT` / Code 43:
`JSON serialization doesn't support the return type schema: QBit(Int8, 9)`.
This happens before RowBinary ingestion; binary-format settings cannot avoid
the eager serialization constructor. An earlier wrapper-module API error,
before any native child ran, is harness plumbing, not a native refusal.

Decision: preserve the existing guards. The fresh isolated matrix independently
probed each wrapper and all four element tags, with an ordinary JSON
persistence positive control.
No hypothetical static-QBit part may be advertised as CH-compatible merely
because its leaf and physical bulk codec exist.

## Rejected candidate and surviving design laws

- Direct QBit and legal static Array/Tuple/Map/Nested/Nullable descendants at
  declared Object paths; source-valid declared Variant combinations are an
  explicit discriminator rather than silently omitted from the candidate.
- Preserve exact element tag, dimension, stride, nominal metadata and physical
  substream names. Missing typed paths use their actual CH defaults; do not
  normalize them into Dynamic NULL or invent retained path-presence semantics.
- Reuse the existing static occurrence visitor with separate logical Object
  occurrence counts and physical enclosing mark rows. Complete all-mark shape
  checks must precede descriptor publication, callbacks and selected decoding,
  including early, zero and EOF selections.
- Shared per-mark shape totals and caller codec/transport allowances compose
  across static, typed-Dynamic and inferred siblings. Do not allocate a fresh
  allowance per path or forget prefix reads preceding the census.
- New responsibility owners get separate files. No memory/performance rewrite.

Currently admitted: W234 and earlier evidenced surfaces only. W235 does not
widen production admission. Existing invalid
Nullable/Variant grammar, runtime-owner intersections, LowCardinality and
aggregate-owner constraints, sparse/custom/Compact or unqualified versions
remain rejected unless explicitly qualified in this slice. Complete shape
checks are not unselected-payload authentication or an allocator/RSS guarantee.

## Risk, rollback, plan and Definition of Done

The proposed admission was CAUTION. Its highest-risk assumption failed:
DataTypeFactory construction does not imply stock serialization or persistence.
The remaining change is local tests/documentation and a bounded isolated native
probe; production serialization remains unchanged. Rollback is the exact owned
diff from the clean baseline. No push or remote/history mutation is authorized.

1. Luna authors a stock-only rejection discriminator under `scripts/*w235*`:
   separate CREATE attempts, fixed runtime, exact Code 43 and leaf-name checks,
   plus one ordinary JSON control with actual CHECK and literal row windows.
   Root runs it in a fresh canonical `/private/tmp` capture. A timeout, crash,
   missing capture, other exception or label-only refusal must fail the gate.
2. Luna replaces unqualified positive candidate specs with guard regressions;
   root runs declaration/parser/plan refusals and ordinary recursive controls.
   Candidate RED ran against unchanged production (kernel 7 examples, 6
   admission/metric errors and 1 passing guard; physical 7 admission errors).
   These results establish the local gap, not an obligation to admit a
   stock-rejected type. Removed candidate specs are not green capabilities.
3. Root independently reviews the raw native output and source gate. No
   production or historical guard edits are authorized by this refused route.
4. Root runs focused guard regressions and the declared affected roster in
   DEBUG and RELEASE,
   serially under `run_safe.sh`, minimum-free50%, `CRYSTAL_WORKERS=1`,
   600s/12288MiB. Crystal arguments:
   `--single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace`;
   RELEASE adds `--release --no-debug`. Require nonzero examples and zero
   failures/errors/pending. Isolate the known grouped JSON Proc-alias symptom
   rather than claim a compiler fix.
5. Inspect the exact final diff, formatting and Ruby syntax, record the scoped
   hostile verdict and residual boundaries, then commit only owned paths.

Expected gate commands include `crystal spec
spec/object_declared_qbit_guards_w235_spec.cr` with the guarded flags above,
plus `ruby scripts/recheck_object_declared_qbit_stock_w235.rb --capture-root
FRESH_ROOT` with the resource guard. Record exact commands when executed.
No unexecuted command, stale W234 pass or model agreement is a W235 certificate.

## Observed verification and hostile verdict

- Stock command: `ruby scripts/recheck_object_declared_qbit_stock_w235.rb
  --capture-root /private/tmp/crystal-click-w235-stock.ApllVz` under the recorded
  resource guard. All 23 children completed: runtime version/build, 13 separate
  exact Code 43 CREATE refusals, and 8 positive-control operations.
- Native refused matrix: Int8/BFloat16/Float32/Float64 at dimension 9;
  Int8 dimension 16/stride 8; Array, named Tuple, String-key Map, Nested,
  Nullable(QBit), one-arm Variant, Variant(QBit,String), and Array(Variant).
  The ordinary `JSON(q UInt8, xs Array(UInt8))` control persisted 6 rows in
  3 data marks plus terminal mark, CHECK=1, exact schema and independent
  full/middle/empty RowBinary windows.
- Root independently read actual SQL/status/stderr/stdout for all 23 records;
  witness classification labels are not the basis of the verdict.
- Same 5-file roster passed 25 examples/mode, 0 failures/errors/pending in
  DEBUG and RELEASE: W235 guards, W179 Object boundary, W230 recursive owner
  guards, W234 Object runtime kernel and static Variant/QBit composition.
  These are guard/control regressions, not a whole-repository suite.
- Exact refusal classifier pressure passed 2 genuine forms, rejected 14
  mutated records plus a wrong expected leaf, and failed closed for 4 missing
  fields. Timeout/signal/spawn errors or plausible Code 43 substrings do not
  establish the tested native refusal. Ruby syntax and Crystal format passed.
- Root hostile verdict: ROBUST within this finite refusal/guard scope. The
  generic leaf-recursion hypothesis survives; the stronger inference that
  DataTypeFactory acceptance makes every JSON composition stock-compatible
  is refuted. Luna source reviews are correlated, not independent evidence.

See [.landmark/evidence/object-declared-qbit-refusal-w235.json](../.landmark/evidence/object-declared-qbit-refusal-w235.json)
for exact commands, pins, retained capture references and refreshed hashes.

## Continuity and decay

Root scratch: `/private/tmp/crystal-click-w235.lBAMp1`.
Confirmed frontier: native static Object QBit declaration refusal; preserve
the guard, keep the overall goal active. Next discriminating candidate:
ordinary Nested declared paths with already supported scalar children, first
stock persistence, then the existing declaration/parser seam. This is a
candidate, not a promise of new coverage.
Return to positive static Object composition only after an upstream JSON tree
change or a separately evidenced supported serialization route. Ordinary
Nested declarations are a distinct potential gap; do not conflate that with
admission of a QBit leaf that the stock JSON owner rejects.
Refresh after relevant declaration/reader/schedule/consumer changes, fixture or
oracle changes, source/runtime/compiler changes, or loss of retained captures.
General MV/projection writing/execution, other unqualified type/layout products,
broad facade decomposition and the final performance target remain open.
