# CrystalClick Modularization Frontier

Document status: W89 implemented and verified on the combined W88+W89 source;
the larger reader/writer modularization remains future work.

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
