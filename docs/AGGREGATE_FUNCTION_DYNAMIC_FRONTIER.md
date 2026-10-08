# AggregateFunction Dynamic composition frontier — W226

Status: VERIFIED within the eight measured quiescent Dynamic V3 profiles.
Baseline: `6e3d94432ddf94eaaea85f6b095f52740900d0bd` (W225).
Risk: CAUTION (runtime admission, persisted state and shared framing).
Rollback: one scoped atomic local commit; no push or changes to stock sources.

## Anchor and boundary

Count and the finite W223 Sum-family state codecs already exist. W225 admits
their static Array/Tuple/Map-value/Variant composition. Dynamic adds an actual
type descriptor and a persisted ordinary/shared placement, not another leaf
serializer for each product. At the W225 baseline, the generic value constructor
and DynamicStructure rejected aggregate-bearing actuals. The Dynamic physical
visitor also lacked the aggregate data-leaf case; the static visitors already
handle it through the compatibility alias `TAG_AGGREGATE_COUNT ==
TAG_AGGREGATE_FUNCTION`.

The first candidate reproduced a separate planner gap: the scalar codec and
physical naming visitor admitted the aggregate leaf, but all four logical
role-count/append visitors in `BinaryDynamicBulkPlan` still refused it. The
focused cohort compiled and ran 39 examples with three writer/bulk errors.
The bounded correction gives each such visitor one existing `.data` leaf;
it does not inspect AggregateFunction argument metadata as value children.

Source reference: `/Users/sergey/SrcArchives/clickhouse-2026-10-07-depth1` at
`0ca8150d9b1d0886edb2e3b4ab65eebb768d0357`. Runtime oracle: ClickHouse
26.10.1.1201, build `d9bcb5ab007f0f6299f7f973f2642245bab3d028`, SHA-256
`bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2`.
These are separate source/runtime pins, not the same-build or latest-master
claim. Dynamic delegates selected payloads to the resolved type serializer;
AggregateFunction delegates state bytes to its aggregate function. The stock
literal prerequisite confirmed the intended concrete contexts.

Admit existing static-admitted aggregate state actuals through normal generic
BinaryValue Dynamic envelopes and Dynamic V3 ordinary rosters, generic bulk
known/shared routes, existing complete-part writer/readers, callback batches
and detached values. Do not add product serializers or change fixed legacy
return unions. Qualification target is finite quiescent Wide/LZ4/Default/
plain-mrk2, Dynamic V3, BASIC discriminators, both existing String profiles.

Keep JSON typed/runtime AggregateFunction paths, Object shared MAP/Copy,
borrowed persisted envelopes and legacy DynamicValueCodec aggregate actuals
closed. Preserve ordinary Dynamic roster prohibitions (direct Dynamic,
Variant, Nullable, Nothing and LC(Nullable)), static type-law restrictions,
Count-specific nominal APIs, and all unsupported aggregate families/versions.
Compact parts, other layouts, aggregate execution, MV/projection writing,
full-type coverage, architecture-wide cleanup and performance are non-goals.

## Composition laws and failure controls

- Static aggregate admission remains static-only. Apply it to each actual
  descriptor; AggregateFunction arguments are metadata, never value lanes.
- Reuse exact Count VarUInt and opaque Sum-state dispatch. Tag 0x25 alone is
  not Count identity. Keep descriptor, selected runtime type and state bytes.
- Ordinary arms use child bulk roles; shared values use one type descriptor
  plus scalar body inside the existing String envelope. Outer String profile
  does not change scalar shared framing or aggregate state serialization.
- The shared helper allowance defaults false and is enabled only by generic
  BinaryBulk Dynamic calls. It must propagate through recursive runtime
  values: Tuple(Dynamic) can hide an aggregate actual absent from the tuple's
  nominal descriptor. Do not reset a budget or bypass JSON's semantic owner.
- Preserve cumulative depth/node/edge/wire budgets and frame reservations.
  Parent marks P, flattened Dynamic occurrences Q and selected/shared values
  R are distinct, including first-empty/ragged arrays and terminal zero marks.
- Load structures and validate complete physical grids before selected reads.
  Malformed selected state must not escape a callback. Unselected shared
  scalar bodies are not newly authenticated by a selected-window read.
- Writer validation precedes publication; refuse an existing destination and
  leave no destination/stage on invalid input. Readers require quiescent parts.

Strongest failure: library writer and reader agree on a misplaced state or
wrong Count/Sum dispatch; another is a hidden runtime AF bypass of a closed
Object helper. Independent literal stock RowBinary and known/shared placement,
P/Q/R fixtures and a coherent semantic mutation must discriminate these.

## Bounded plan and DoD

1. Add compiling behavioral RED in `spec/aggregate_dynamic_w226_core_spec.cr`
   and consumer tests before production changes. Root executes RED at baseline.
   Capture independent stock CREATE/INSERT/read/CHECK prerequisite literals.
2. Core ownership: DynamicStructure/BinaryValue/value-codec admission,
   BinaryBulk Dynamic shared call sites, the three Dynamic physical visitors,
   and explicit retained legacy DynamicValueCodec guard. New cohesive owners
   use one class/module per file. Do not duplicate static codecs or facades.
3. Consumer ownership: W226 public consumer/adversary specs and a small fixed
   Crystal helper reusing existing Dynamic/public ownership. Native runner
   reuses the bounded W224 process recorder, not a copied publication engine.
4. Execute explicit unique affected spec cohorts in DEBUG and RELEASE, build
   both helpers, qualify stock-authored reads and library ATTACH/CHECK/exact
   full/middle/empty RowBinary for known Count/shared Sum, all-shared cap zero,
   actual Array(Sum), and outer Array(Dynamic), under both String profiles.
5. Independently audit raw process statuses, literals, pins, input/helper and
   part snapshots; execute a valid wrong-value or CHECK-zero seed and restore
   exact bytes. Inspect diff/retained guards; then calibrate a scoped verdict.

Root alone runs compiler/native/Ruby/audit jobs serially through the unchanged
`cogni-ml/scripts/run_safe.sh`: minimum free memory 50 percent, compiler/native
600 seconds / 12288 MiB, one worker and isolated cache. Crystal uses
`--single-module --threads 1 --link-flags=-fuse-ld=ld --error-trace`; RELEASE
adds `--release --no-debug`. Small Ruby/audits use 120 seconds / 512 MiB.
Expected DoD: actual exit zero, no failures/errors/pending, exact literal and
native placement checks, retained negative controls, formatter/diff checks,
and scoped ROBUST review. A structural evidence packet is only an index.
The explicit adjacent regression inventory has 55 unique files in four
cohorts (7 focused, 20 Dynamic, 16 JSON/context guards, 12 static aggregate).
The DEBUG and RELEASE modes must use the same inventory, retained under
`/private/tmp/crystal-click-w226.uc2k9T/spec-inventory.json`.

## Prerequisite evidence

At the untouched W225 baseline, the three W226 spec files compiled in DEBUG
and exited 1 with 10 examples / 10 behavioral errors / no pending examples.
Each stopped at the existing aggregate-bearing Dynamic constructor or roster
guard, rather than a compiler error. Raw guarded output is
`/private/tmp/crystal-click-w226.uc2k9T/red-spec.log`.

The separate fixed-literal stock prerequisite exited 0 after 20 native
invocations. It checked ordinary Count/Sum, shared-only cap-zero Count/Sum and
first-empty/ragged Array(Dynamic), including nominal runtime types, shared
placement, exact RowBinary and CHECK=1. Raw records are below
`/private/tmp/crystal-click-w226.uc2k9T/evidence/invocations`; this prerequisite
does not qualify library part publication or the final finite physical profile.

After the planner correction, the focused DEBUG cohort exited 0 with 41
examples, no failures/errors/pending. It includes exact-fit/one-byte-short
retained-owner budgeting with atomic counter refusal, and a JSON
Array(Dynamic) runtime-actual negative. The retained-owner probe uses the
existing `ObjectValuesMaterializationBudget` API; it does not assert a new
injectable budget seam in W220 `.values`.

## Observed qualification and architecture decision

Root executed the same 55-file affected inventory in both modes. DEBUG's four
cohorts passed 41 + 119 + 105 + 62 = 327 examples; the combined RELEASE run
passed 327 examples. Each exited zero with no failures, errors or pending
examples. These are affected regression cohorts, not the whole repository.

The paired stock/library/native harness and raw audit both exited zero in
DEBUG and RELEASE: eight profiles and 171 successful raw processes per mode.
Each covers stock-authored reads, library-authored part publication, native
ATTACH/CHECK=1, exact full/middle/zero RowBinary, nominal types, known/shared
placement and the existing callback/window/owned-value consumers. The four
cases are known Count/shared Sum, all-shared cap zero, an actual Array(Sum),
and outer Array(Dynamic), each under SingleStream and WithSizeStream.
Native compatibility is limited to this finite fixture roster. Synthetic
offline owned-value witnesses do not qualify whole-catalog or projection
integration.

Raw evidence roots:

- DEBUG source: `/private/tmp/crystal-click-w226-native.debug.QIXSWy`;
  evidence: `/private/tmp/crystal-click-w226-evidence.debug.vSxCBr`.
- RELEASE source: `/private/tmp/crystal-click-w226-native.release.PaIhp4`;
  evidence: `/private/tmp/crystal-click-w226-evidence.release.vw2ERY`.
- Guarded logs and the explicit spec inventory:
  `/private/tmp/crystal-click-w226.uc2k9T`.

In both modes, a coherent CHECK-zero seed changed the raw successful-exit
CHECK stdout and its attached-case carrier, retaining exit zero and a green
summary. The raw audit exited one at the CHECK semantic comparison. Exact
SHA-256 restoration returned both audits to exit zero. This tests the audit's
failure policy, not a Count-state corruption in a live part.

All 156 generated part files matched across modes by relative path, size and
SHA-256. This is an additional deterministic-output signal; literal native
reads, not byte equality alone, establish the finite compatibility claim.
DEBUG evidence precedes whitespace-only formatter changes to the helper and
consumer spec; production bytes are unchanged, and RELEASE uses the final
formatted sources. The final formatter check and `git diff --check` exited
zero. The packet at
`.landmark/evidence/aggregate-function-dynamic-w226.json` indexes pins,
commands, raw observations and this limitation; it is not proof by itself.

Scoped adversary verdict: ROBUST for the measured eight-profile boundary.
Retained controls distinguish Count VarUInt from the UInt8 Sum accumulator,
keep hidden Tuple(Dynamic) aggregate actuals closed in the default shared
helper, reject JSON Array(Dynamic) aggregate actuals, preserve cumulative
budgets and atomic retained-owner refusal, and refuse compressed transport
corruption before a callback. The transport mutation is not a semantic
aggregate-state mutation. General recursive products remain unqualified.

Decision: reuse leaf serde and compose the wrapper's stream names, row domain,
prefix/state and marks context. Do not implement serializers per type product.
The missing W226 work was admission and Dynamic bulk role/physical binding,
not Count/Sum serialization. Next widening must first distinguish a missing
leaf codec, a missing wrapper context/layout, and a source-invalid composition;
one cannot infer JSON or LowCardinality state support from this result.

Refresh after relevant codec/guard/profile/fixture/helper/runtime/source
changes. Overall types, MV/projections and the later performance target remain
active and incomplete. No remote write is authorized by this slice.
