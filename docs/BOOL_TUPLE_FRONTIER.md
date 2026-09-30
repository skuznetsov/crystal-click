# Bool Tuple Leaf Frontier

Status: W97 is VERIFIED within the named Bool/numeric/String Wide Tuple
profile below. Pre-change implementation anchor: `3a50637`.
The full compatible-type/MV/projection goal remains open. Memory and performance
optimization stays deferred; no matched ClickHouse slowdown is claimed.

W98's shared-policy follow-up is tracked in `BOOL_SEMANTICS_FRONTIER.md`.
The strict root/Array policy described below is W97's historical baseline,
not the new shared policy; W98 has its own executed evidence boundary.

## Boundary and discriminator

W96 admits named, nonempty Tuples with 15 primitive numeric identities and
String, but intentionally rejects Bool. Existing root-column and Array(Bool)
readers already expose native Bool and reject bytes outside 0/1. Extend the
shared named-leaf contract, reader, writer and table/catalog consumers together.
Bool must remain nominally distinct from UInt8 even though both streams have
width one. Do not add Bool to `WideTupleNumericType` or convert a UInt8 buffer
under a Bool schema. Keep legacy numeric bits, owned buffers, String copies,
complete mark schedules, lazy payload checks and logical charge guards.

The source reference remains the separate shallow checkout
`/Users/sergey/SrcArchives/clickhouse-2026-09-29-depth1` at
`a9581941254d6113f3740a8ec125ee7519cb1bda`. Its
`DataTypeDomainBool.cpp` registers a UInt8-backed custom Bool name and
`SerializationBool` wraps its serializer. This is a source anchor, not proof
of every persisted Bool representation. Runtime evidence must use the pinned
stock executable 26.7.1.1315 and independently expected bytes.
The official [Bool documentation](https://clickhouse.com/docs/reference/data-types/boolean)
describes false/true as 0/1 with UInt8 storage; neither width nor arithmetic
equality establishes nominal schema compatibility.

First discriminator: existing-API plan tests for Bool width, declaration order
and charge, retaining UInt8/String positive controls and rejected aliases.
Before production changes, also construct a stock Wide part with UInt64 key
and `Tuple(flag Bool, byte UInt8, text String)`, verify exact schema, streams,
adaptive marks [2,2,1,0], stock CHECK and independent RowBinary, then observe
the current library's typed-open/read rejection. Probe-instrument failures
do not satisfy this gate.

Admit here: exact bare Bool named leaves with native owned Array(Bool) values,
semantic decoding (zero is false, nonzero is true), canonical writer bytes
0/1, mixed numeric/String leaves and the existing
one-UInt64-key Wide Default/accepted AlwaysDefault profile. Preserve the
single nominal `WideTupleRow` API and matching writer support.

Reject here: Bool empty-argument aliases, unnamed/empty/nested/Nullable Tuples,
other semantic leaves, Compact/Sparse and new-master metadata profiles.
Raw Bool byte identity is not represented by Crystal Bool: reading byte 2
and writing the resulting true emits byte 1. This is semantic compatibility,
not lossless physical-byte roundtrip or ClickHouse reinterpretation fidelity.
Existing strict root-column/Array/container Bool decoders are a separate
compatibility gap; their rejection policy is not widened silently in W97.
General schemas, broader MV/projections and remaining facade decomposition
are separate open obligations, not removed from the overall goal.

Risk: CAUTION (public closed unions and persisted serialization).
Rollback: one coherent local W97 commit after the gates below pass; preserve
unrelated user work, with no push or history rewrite. Caller input must remain
stable during synchronous writes. The shared 64 MiB materialization charge is
logical accounting, not a peak-RSS or simultaneous-allocation guarantee.

## Implementation seal and plan

Bounded consumer inventory: `rg` for Bool, `WideTupleLeafColumn`,
`WideTupleNumericType::Buffer`, `TupleLeafBuffers`, `value_at`,
`TupleReader.new` and `TuplePartInfrastructure.new` under source, specs,
scripts and examples. Propagate exact nominal identity through plan, owned
leaf/row access, physical decode, preflight, serializer selection, defaults
and staged readback. Replace only superseded Bool-rejection tests with still
rejected neighbors; retain numeric/String controls.

- Model/reader owner: `wide_tuple_leaf_column.cr`, `wide_tuple_column_data.cr`,
  `wide_tuple_row.cr`, `wide_tuple_type_plan.cr`, `wide_part/tuple_reader.cr`,
  narrow delegates in `wide_part.cr`, and a new focused Bool model spec.
- Writer owner: `wide_part_writer/tuple_part_write_input.cr`,
  `tuple_part_infrastructure.cr`, `tuple_part_writer.cr`, narrow delegates in
  `wide_part_writer.cr`, and a new focused Bool writer spec.
- Consumer/oracle owner: Bool plan/consumer specs and the historical RED probe
  plus final bidirectional pinned-stock oracle and shell wrapper.
- Root: pre-change measurements, import graph if needed, superseded rejection
  tests, documentation, central runs, hostile review and exact-path local Git.
  Workers do not launch compiler/spec/ClickHouse runs or Git operations.

Do not clone the numeric serializer. Use separate semantic Bool dispatch with
exact 0/1 emission and bounded, nonzero-aware decode. The strongest likely
failure is silently treating a same-width UInt8 array as Bool, claiming raw
byte preservation after native Bool normalization, or retaining a numeric-only
cast in a shared consumer. Guard these explicitly and attack
ownership and no-publication behavior for a wrong later field.

## Declared executable gates

1. Observe the plan RED and valid stock-created persisted reader RED on the
   unchanged production anchor, after positive controls.
2. Focused DEBUG and RELEASE: new Bool plan/model/writer/consumer specs plus
   existing W96, ownership, Tuple reader/writer and table/catalog regressions;
   zero failures/errors/pending. Include exact Bool-vs-UInt8 mismatch,
   returned-buffer mutation, Bool aliases, truncated payload, mark/window alignment,
   budget and zero-stage-on-invalid-input guards.
3. `bash scripts/check_bool_tuple_oracle.sh`: both directions, independent
   RowBinary bytes, seeded mismatch sensitivity, Bool-only/mixed/all-default
   shapes, multiple/short/terminal marks, low-level ranges, high-level full,
   window and catalog access, stock ATTACH and CHECK; zero failures. Also
   qualify nonzero semantics against a stock-produced Bool Tuple using raw
   bytes 0/1/2/128/255 (or all UInt8 values), retaining original stock bytes
   independently while checking the library's normalized semantic values.
4. Run numeric and both legacy Tuple oracles unchanged; zero failures.
5. Full DEBUG `crystal spec --link-flags='-fuse-ld=ld'` (the separately recorded
   compiler-layout retry may add `--single-module`), Crystal format checks,
   shell syntax and diff checks; zero failures/errors. Full RELEASE is not
   required or claimed.

Run heavy commands serially under fresh host-memory admission and the inspected
`cogni-ml/scripts/run_safe.sh` process-tree watchdog. Focused/oracle cap is
8192 MiB, full DEBUG uses the already observed 32768 MiB compiler/test envelope;
600-second timeout and 50% free-memory floor remain enabled. Those guards are
execution safety, not library memory or speed measurements.

An independent persisted-stock oracle is the fallback to library self-roundtrip.
Same-lineage static reviews are correlated, not independent replication. Before
claiming VERIFIED, root must inspect the combined diff, execute the gates and
return a bounded adversarial verdict. Evidence decays on nominal mapping,
codecs, Bool domain, union dispatch, ownership/budget/mark/metadata/import policy,
fixtures, compiler semantics or stock executable changes.

## Pre-production observations and rejected route

The canonical-only read policy is rejected as a full Bool compatibility
route. Root's isolated pinned-stock probe accepted RowBinary Bool byte 2,
persisted it in a Wide part, passed CHECK, rendered true, and returned byte 2
in RowBinary. The corrected Tuple probe independently reproduced the same
observation inside `Tuple(flag Bool, byte UInt8, text String)`.

On unchanged production at `3a50637`, root handle 46071 exited 1 at the
intended reader discriminator, not at instrumentation: the legacy
UInt64/String positive control passed typed read and independent RowBinary;
the canonical Bool/UInt8/String part passed exact schema/substreams/inventory,
adaptive mark schedule and stock CHECK/RowBinary, then typed open raised
`UnsupportedFormatError: unsupported exact typed column` in `parse_metadata`.
The probe reported stock raw2 physical flag stream `02`, selected RowBinary
`02` and logical `true`. Native Bool storage, nominal separation and canonical
writer output remain useful; only the canonical-only persisted-read claim
was refuted. The source's Bool text serializer tests the stored UInt8 as a
condition, while its bulk binary wrapper delegates to UInt8 serialization.

Root handle 94720 measured the existing-API plan RED on the same unchanged
production anchor: 2 examples, 1 unsupported-plan failure, 0 errors/pending.
The neighboring rejected-shape control passed. Production changes were
authorized only after these two discriminators and the revised semantic seal.

## Post-production observations

The first central focused build (handle 68264) failed before running examples:
the shared numeric staged comparator excluded String but not the newly added
Bool union member. The narrow fix rejects Bool before numeric raw-bit equality;
it does not admit Bool into `WideTupleNumericType`. The next run (54720)
executed 95 examples with 0 failures, 2 errors: `values_as(Bool.class)` passed
the wrong metaclass to the existing `T.class` API. Changing that call to
`values_as(Bool)` preserved exact nominal access. A correlated static review
had missed this second defect, so its source-level ROBUST verdict was withdrawn
until executable verification. Neither failing run is a passing gate.

After those fixes and adding the frozen consumer spec, root handles 62251
(DEBUG) and 59284 (RELEASE) each passed 96 examples with 0 failures, errors or
pending. The exact suite was:

```sh
crystal spec \
  spec/wide_tuple_bool_w97_spec.cr \
  spec/wide_tuple_bool_model_w97_spec.cr \
  spec/wide_part_writer_bool_tuple_w97_spec.cr \
  spec/bool_tuple_consumers_w97_spec.cr \
  spec/wide_tuple_numeric_w96_spec.cr \
  spec/wide_tuple_numeric_model_w96_spec.cr \
  spec/wide_part_writer_numeric_tuple_w96_spec.cr \
  spec/numeric_tuple_consumers_w96_spec.cr \
  spec/wide_tuple_type_plan_spec.cr \
  spec/wide_tuple_column_data_ownership_spec.cr \
  spec/wide_tuple_row_w95_spec.cr \
  spec/offline_catalog_w95_tuple_values_spec.cr \
  spec/wide_part_table_w95_tuple_spec.cr \
  spec/wide_part_writer_compositional_tuple_spec.cr \
  spec/wide_part_writer_tuple_spec.cr \
  spec/wide_part_reader_compositional_tuple_spec.cr \
  spec/wide_part_reader_tuple_metadata_spec.cr \
  spec/wide_part_reader_tuple_empty_eof_spec.cr \
  --link-flags=-fuse-ld=ld
```

The RELEASE run adds `--release`. Both used the declared 600-second/8192-MiB
watchdog and fresh 50% free-memory admission. Their guards include exact
Bool-vs-UInt8 access and zero-stage mismatch rejection, owned snapshot mutation,
logical budget rejection, full/window/sparse/catalog rows, and a checksummed
malformed final frame that fails after 128 successful lazy callbacks. These
are not allocation or performance measurements.

Root handle 68014 passed `bash scripts/check_bool_tuple_oracle.sh` against
stock 26.7.1.1315. The fresh 257-row fixture includes every UInt8 code once
plus a terminal zero row. Independent physical and RowBinary comparisons
preserved the stock bytes; stock CHECK and logical truth agreed. Actual
library-decoded stock values fed the writer, whose independently expected
canonical bytes then passed stock ATTACH/CHECK and low-level ranges, full,
window, sparse and catalog reads. Bool-only stock/read and all-default
stock/write profiles also passed. The exact-byte comparator rejected a seeded
changed byte. Initial oracle instrument builds failed on Array byte-view and
borrowed batch Slice signatures, then those helper contracts were audited and
corrected; no production admission or oracle assertion was relaxed.

The unchanged numeric oracle (77890) and compositional legacy oracle (16682)
also passed on the combined W97 source. The numeric oracle retained all 15
exact identities, bit patterns, mixed/numeric-only/all-default profiles and
both stock directions. The compositional oracle retained its 1/2/3/9-field,
String-first/all-String/UInt64-only/all-empty profiles. The unchanged exact-pair
oracle (33809) also passed Default and AlwaysDefault reads, independent marks,
stock ATTACH/CHECK, full/key-range RowBinary, empty EOF and malformed-input
no-publication checks. Declared and erased-record Sparse rejection controls
remained negative controls, not supported-profile evidence.

### Full-suite guard discriminator

Full DEBUG handle 59482 produced no suite result: the watchdog stopped the
tree at approximately 112 seconds, reporting 3421 FDs. Inspection of its
`fd_count_for_pid` shows it counts **all lsof rows**, including executable/text
and mapped files, not just numeric file descriptors; the fixed limit is 1000.
The workload emitted only the existing duplicate-`-lc` linker warning. The
cache contains 3929 object files across its builds. Those facts make a linker
mapping peak a plausible competing explanation, not a proved runtime FD leak
or a passing test. No unrelated process or shared watchdog is modified.

The discriminating retry keeps DEBUG optimization, all examples, the same
linker, 600-second timeout, 32768-MiB RSS guard, 50% free-memory kill floor and
the watchdog's unchanged lsof threshold, but adds Crystal's documented
`--single-module` compiler-layout option. Source `command.cr:584-585` sets
`single_module` without changing optimization, separately from `--release`.
Hypothesis: one LLVM/object module avoids the many-object linker mapping peak.
The alternative can use more compiler memory and remains subject to the same
guards; a killed retry is inconclusive, not evidence of test completion.

The retry (27654) exited 0 under those unchanged guards at approximately
174 seconds including compilation: 1239 examples, 0 failures, 0 errors,
0 pending; test execution took 38.52 seconds. The exact full-suite command was:

```sh
COGNI_RUN_SAFE_MIN_FREE_PCT=50 \
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
TMPDIR=/private/tmp \
CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w97-cache \
bash /Users/sergey/Projects/Crystal/cogni-ml/scripts/run_safe.sh \
  /opt/homebrew/bin/crystal 600 32768 spec \
  --single-module --link-flags=-fuse-ld=ld
```

This establishes the full DEBUG regression gate with the alternate compiler
layout. It does not establish the exact cause of the first guard event,
prove absence of library resource leaks, or provide a memory/performance
benchmark. Full RELEASE was not run or claimed. The only emitted linker
warning was the existing duplicate `-lc` warning.

## Bounded closure and continuation

Root's final adversarial verdict is ROBUST within the admitted profile:
the inspected dispatch keeps Bool separate from UInt8 and the numeric union;
executed mismatch/ownership/budget/no-stage guards and lazy-corruption tests
attack the public union extension; the pinned-stock oracle independently
qualifies every UInt8 code and the intentional semantic normalization; and
numeric plus both legacy Tuple oracles guard the shared consumers. The
correlated worker review is supporting source analysis, not independent
replication. Crystal format checks passed for all 16 touched Crystal files;
`bash -n scripts/check_bool_tuple_oracle.sh` and `git diff --check` also passed.
This certificate does not transfer to
other layouts, type compositions, compiler versions or executables.

The active goal remains complete read/write type compatibility and MV/projection
support before memory/performance work; matched ClickHouse slowdown at most
10% is still unproved. Confirmed return pointer: this W97 certificate and the
W96/W95 certificates linked by `MODULARIZATION_FRONTIER.md`. Next falsifier:
stock-produced noncanonical Bool bytes in root, Array and existing container
profiles, checked independently before reconciling their strict read policy.
Give the common Bool semantic policy one cohesive owner/file rather than
duplicating another decoder or mechanically splitting the facades.

Other open obligations include semantic and recursive Tuple leaves,
general table-writer schemas, fresh-master metadata/JSON/Geometry profiles,
general MV/projection behavior and remaining reader/writer/table/catalog
ownership extraction. The separate depth-1 source anchor remains unchanged;
runtime evidence remains pinned to 26.7.1.1315, not current master. Local
implementation, tests and coherent atomic commits remain authorized; push,
new executable installation, paid work and external data mutation need
separate authority. Refresh affected gates when the decay triggers declared
above change; a failed new-profile guard does not revoke unaffected profiles.
