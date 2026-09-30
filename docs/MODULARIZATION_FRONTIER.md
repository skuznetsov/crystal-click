# CrystalClick Modularization Frontier

Document status: W89 implemented and verified on the combined W88+W89 source;
W90 Array(Map) plan owners and W91 payload owners are verified below. The larger
reader/writer modularization remains future work.

## Problem and boundary

At `26ab2a2`, `wide_part_writer.cr` has 25,905 lines, `wide_part.cr` 14,989,
`wide_part_table.cr` 6,583, and `offline_catalog.cr` 5,283. File count alone
does not establish modularity: extraction must give each class one source file
and separate a responsibility with an independently checkable contract.
The committed W88 MV materializer owns `offline_catalog.cr` and its tests;
W89 must not mix with that storage behavior change.

## W89 admitted design

Move the bounded ClickHouse type-expression grammar out of the body of
`wide_type_plan.cr`. Create one source file each for `WideTypePlan::Node`,
`WideTypePlan::Parser`, and the new `WideTypeExpression` facade. Retain the
original nominal Node/Parser identities, not just aliases: public reflection
and diagnostics can observe their canonical names. The parser handles syntax,
parse limits, and AST construction only. `WideTypePlan` continues to own
physical substreams and exact admission policy, and keeps its existing
`.parse` method as a delegate to `WideTypeExpression`. The facade may expose
aliases back to the original Node/Parser types. Require node, parser, facade,
then `wide_type_plan.cr` in `src/crystal_click.cr`. Each concrete type owns its
methods in one file; the `WideTypePlan` namespace is reopened only to declare
its nested types.

Reject for W89: newly admitted ClickHouse types, changed parse trees or
limits, generic codec dispatch, changed on-disk bytes, changed public typed
table accessors, performance claims, and a mechanical redistribution of the
large reader/writer modules into multi-class files. These need separate
behavioral and compatibility slices.

Guard-only next boundary: the W80-W85 `Array(Map)` physical-plan builders in
`wide_part_writer.cr`: `array_map_string_uint64_physical_plan`,
`array_map_string_physical_plan`, `array_map_numeric_physical_plan`,
`array_map_array_physical_plan`, and
`array_map_array_numeric_physical_plan`. They form a roughly 661-line cluster
of private plan descriptors, builders, and axis comparison, separate from the
public writer facade and byte serializers. Extracting cohesive builders into
one class per file could remove plan ownership from the 25,905-line writer
without changing on-disk bytes. This needs its own exact stream/role/axis
falsifiers, W80-W85 writer/type-plan specs, available stock ClickHouse oracles,
and a separate commit; it is not admitted by W89's green parser tests. Moving
the already-small map-row adapters out of `wide_part_table.cr` is lower risk but
mostly improves navigation, not class responsibility. The borrowed batch
view, reader leaf codecs, and writer serializers need later owner-by-contract
slices. Do not treat lower lines-per-file as proof of lower coupling.

## Falsifiers and execution plan

Risk: CAUTION. The strongest failure is a changed AST nominal identity or
require order that silently changes exact admission. A first implementation
that moved the definitions under `WideTypeExpression` passed 35 focused and
1,115 debug examples, but hostile review found its aliases changed canonical
type names. That route is rejected despite green tests; preserve the original
`WideTypePlan::Node` and `::Parser` definitions in separate files. Rollback is
the isolated W89 commit; do not bundle W88 behavior with W89 refactoring.

Before editing, compare the W67/W69-W71 parse and admission specs on the
same source state. The bounded consumer search found no external use of
`WideTypePlan::Node` or `::Parser` in `src/`, `spec/`, or `scripts/`;
`WideTypePlan.parse` has one production call in its shadow plan and five
spec callers. Retain nominal names because absence of in-repo callers does
not prove public API freedom. After extraction, run the same focused specs,
the relevant reader spec, full debug and release suites, Crystal format,
and `git diff --check`. A no-codegen compile and direct AST type-identity plus
canonical-name checks are additional guards; neither replaces runtime specs.
The expected signal is identical parser output and admission, no new supported types,
and zero regression failures. Review the final diff specifically for
accidental semantics edits or circular requires before an atomic commit.

This evidence decays if Crystal's parser/reflection semantics, the type plan,
its callers, or the root require graph changes.

## W89 observed result

The syntax tree and parser now each have their own file; the new
`WideTypeExpression` facade has a third file. `WideTypePlan.parse` delegates
without changing the parser's 4,096-byte, 64-depth, or 512-node limits. A
hostile review found and rejected an initial implementation that changed the
canonical `WideTypePlan::Node` and `::Parser` names despite green tests. The
corrected implementation retains those nominal identities, guarded by the
new spec. The final adversarial verdict was ROBUST within the aggregate
`require "./crystal_click"` API. Direct internal-file imports were not found
in this repository and are outside that verdict.

The isolated worktree passed 35 focused examples and 1,115 full debug and
release examples, all with zero failures. After integrating over W88, full
debug and release each passed 1,125 examples with zero failures or errors;
the pinned ClickHouse MV part oracle also passed. Crystal format and staged
diff checks passed. These are regression and compatibility signals, not a
performance result, generic type-admission proof, or evidence that the larger
reader/writer classes have been modularized.

## W90 design and execution boundary

Move the five existing private `WidePartWriter::ArrayMap*PhysicalPlan` structs
into one file per struct under `src/crystal_click/wide_part_writer/`. Each
struct owns a `.build` factory and the exact stream, role, semantic path,
width, storage mode, cardinality, and mark-axis checks previously performed
by its writer helper. Retain the structs' nominal identities and value
semantics. The public writer facades call these factories, and the existing
serializers continue consuming the same descriptors. Numeric factories take
the expected leaf width computed by the existing writer width policy; they
must compare it with the planned stream width. A two-line axis comparator
may remain private in each owner rather than adding a shared base class.

Admitted change: responsibility and source-file ownership only. Rejected:
new types, relaxed admission, changed serializer bytes, new public accessors,
codec dispatch, performance claims, or replacing the structs with heap objects.
Risk is CAUTION; rollback is the atomic W90 commit. The strongest failure is
a check disappearing during extraction while ordinary round-trip tests stay
green. Guard it with role/order/width/axis negative cases at the owner boundary,
in addition to the existing W80-W85 exact-byte and admission tests. All five
builder helpers and descriptors have only writer-local consumers at `bff96b5`;
`numeric_width` is shared with other writer families and remains in place.

Execution order:

1. Record the W80-W85 writer/type-plan baseline and identify negative cases
   for altered stream order, role, leaf width, and count/mark axes.
2. Extract the five descriptor/factory files, update the aggregate require
   graph and writer-local calls, and remove the old helpers from the writer.
3. Run the focused specs, pinned stock ClickHouse oracles for the affected
   families, full debug and release suites, Crystal format, and diff checks.
   Expected signal: unchanged exact bytes and admission, rejection of malformed
   plans, and zero regressions. Review every moved predicate before committing.

The source inventory and certificates decay when physical-plan construction,
writer admission, serializer consumers, Crystal type semantics, or the pinned
ClickHouse profile changes. Reader codecs, serializers, and table adapters
remain separate future responsibility slices.

## W90 observed result

The five private plan structs now own their factories and validation in five
separate files. Their canonical names and struct value semantics are retained.
The public writer delegates to those factories; the byte serializers are
unchanged. Numeric leaf-width policy remains in the writer and is passed to
the relevant factory rather than duplicated. The writer decreased from
25,905 to 25,241 lines; this is an ownership/navigation result, not a measure
of performance or proof that the entire writer is modular.

The frozen implementation passed 37 focused W80-W85 writer/type-plan/owner
examples and full debug and release suites of 1,132 examples each, with zero
failures or errors. The release suite completed on 2026-09-30 UTC; its test
execution took 20.35 seconds, excluding compilation, and is not a reader
benchmark. New negative tests reject changed stream count/order, role, storage
mode/axis, leaf width, mark-row axis, and nested cardinality axes. A compiler
reflection check guards the nominal names and struct semantics without
exposing a production test hook.

All six pinned `26.7.1.1315` W80-W85 oracles passed in full reader+writer mode,
including stock-produced reads, exact selected streams/marks, full/key-range
RowBinary, and Crystal-produced parts checked/attached by ClickHouse. The
new W83 shell wrapper defaults to full mode and rejects an invalid mode or
an unpinned executable. W80 and W82 default to stock-only mode, so their full
checks require explicit mode flags; W85 is invoked through Bash because its
tracked wrapper is not executable.

Scoped hostile review found no removed validation predicate or changed
serializer and returned ROBUST for the aggregate import boundary. Direct
imports of internal files and future factories supplied with an incorrect
numeric width are outside that verdict. Root independently reviewed the
source diff and ran full debug, release, and stock-oracle checks. Same-lineage
review is correlated evidence, not an independent compatibility proof.

Observed checks use the following environment on this host:

```sh
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
export CRYSTAL_CACHE_DIR=/private/tmp/crystal-click-w88-cache
export CLICKHOUSE_BIN=/Users/sergey/.local/bin/clickhouse
export TMPDIR=/private/tmp
crystal spec --link-flags='-fuse-ld=ld'
crystal spec --release --link-flags='-fuse-ld=ld'
W80_ORACLE_MODE=full bash scripts/check_array_map_string_uint64_w80_oracle.sh
W81_ORACLE_MODE=full bash scripts/check_array_map_numeric_w81_oracle.sh
W82_ORACLE_MODE=full bash scripts/check_array_map_string_values_w82_oracle.sh
W83_ORACLE_MODE=full bash scripts/check_array_map_bool_values_w83_oracle.sh
W84_ORACLE_MODE=full bash scripts/check_array_map_array_w84_oracle.sh
W85_ORACLE_MODE=full bash scripts/check_array_map_array_w85_oracle.sh
```

Crystal format, shell syntax, and `git diff --check` passed. These checks do
not admit new types, prove compatibility with September master, establish
matched ClickHouse performance, or close the larger class-architecture task.
Evidence decays under the W90 source/profile changes listed above.

## W91 payload-owner result

The next neutral slice extracted four private concrete owners, one file each:
reader `WidePart::StringPayloadDecoder`, writer `WidePartWriter::LeafStreamWriter`
and `::StreamEncoding`, and the existing `::ChecksumRecord` struct. String
assembly is shared by the exact Tuple and scalar reader; actual UInt64/String
payload method bodies moved out of the writer, whose old entrypoints delegate.
Schema/physical admission, range policy, budgets and stage lifecycle remain
in place. The writer is still 25,045 lines and reader 14,982; this is a small
ownership improvement, not closure of the larger architecture task.

The frozen source passed 72 focused and 1,145 full debug/release examples, with
zero failures/errors, plus the pinned Tuple, typed and basic writer oracles.
Scoped hostile review returned ROBUST at the aggregate import boundary; root
also checked mechanical body parity and executed the runtime checks. Exact
commands, source/profile lineage, residual Tuple metadata/EOF gaps and evidence
decay are recorded in [the W91 seal and result](COMPOSITIONAL_TUPLE_FRONTIER.md).
No new type, metadata profile, public generic Tuple API, arbitrary-table writer
or performance claim is admitted by this extraction.
