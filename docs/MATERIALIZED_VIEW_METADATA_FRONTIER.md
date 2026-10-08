# Materialized-view metadata frontier (W228)

Status: VERIFIED within the bounded offline declaration and current-local
physical-target identity scope (scoped adversary verdict: ROBUST).
Baseline: `6a8a31ee125188363361d50408159341dbb1318a`.
Context: bounded offline Atomic catalog declarations and explicit local identity
resolution, not SQL execution, live activation or refresh state.

## Implemented declaration model

The catalog retains raw bounded DDL, logical kind, columns and projection
declarations, and now exposes structured persisted MATERIALIZED VIEW target
and SELECT information. A view's UUID is not its physical target UUID; existing
view data-access guards remain intact.

`OfflineTable#materialized_view : OfflineMaterializedView?` returns nil for
ordinary and synthetic tables. The detached descriptor exposes
declaring_database, the exact trimmed SELECT query slice including its initial
SELECT or WITH keyword, optional inner_engine, and a tagged target: named
reference, explicit inner UUID or implicit inner engine. Named references
preserve explicit database qualification separately from the normalized
declaring-database context, and optional target UUID. Qualification describes
the parsed persisted ATTACH spelling; stock may have qualified an originally
unqualified CREATE reference before persisting it. All strings,
target/reference values and collections are copied at boundaries.

Explicit catalog `resolve_materialized_view_target` overloads accept a database
name or catalog-owned OfflineDatabase and a view name. Named targets resolve
against current metadata with optional UUID equality. Explicit inner UUIDs must
match exactly one physical table in the declaring database. Implicit targets
use the source-defined `.inner_id.<view UUID>` metadata name, not a view-UUID
store path. Missing, ambiguous, wrong-kind and changed identities fail closed.
Resolution proves only current local metadata identity, not target contents.

## Query-reference boundary

`source_references` and `source_references_complete?` describe direct syntactic
FROM table references in a bounded SELECT grammar. Completeness is not source
existence, a ClickHouse INSERT-trigger dependency graph, dictionary/function
dependencies, or refresh `DEPENDS ON`. The server triggers classic MVs only
from the first selected table; refresh dependencies are a different mechanism.

Source-free SELECT or one direct table relation may be complete only when the
whole supported relation shape is recognized, with captured database context.
Projection/filter/group/order expressions do not require execution. Unsupported
CTEs, multiple relations/JOIN, subqueries, table functions, set operations,
IN-table ambiguities return status unknown, an explanatory reason and no
partial references. The inherited DDL lexical guard still rejects statement
and comment controls before exposing a descriptor. Quoted words and String literals
must never create phantom table edges. Unknown is not an empty complete graph.

## Source laws and preserved guards

Comparison source: `/Users/sergey/SrcArchives/clickhouse-2026-10-07-depth1`,
`0ca8150d9b1d0886edb2e3b4ab65eebb768d0357`. Runtime 26.10.1.1201,
build `d9bcb5ab007f0f6299f7f973f2642245bab3d028`; these are separate pins.
Source anchors: ParserCreateQuery.cpp:1413-1637 and 1728-1750,
ASTViewTargets.h:16-73, ExpressionElementParsers.cpp:344-378 and 429-459,
ParserTablesInSelectQuery.cpp:28-36 and 95-125,
StorageMaterializedView.cpp:98-103,
SelectQueryDescription.cpp:75-120 and InterpreterCreateQuery.cpp:2038-2075.

Preserve existing accepted classic Atomic MV forms, projection declarations,
W87 complete-child/preflight behavior and W88's exact detached-only identity
materializer. Do not infer query execution, target freshness, server Active or
general MV/projection writing. Unsupported refresh/security/parameterized target
forms remain explicit guards unless source and stock-authored evidence justify
a later parser slice. Source-invalid external TO plus ENGINE is rejected.

## Architecture and public use

The catalog orchestrates bounded file/identity access. Separate single-file
owners represent `OfflineMaterializedView`, `OfflineMaterializedViewTarget`
and `OfflineTableReference`; `OfflineMaterializedViewTargetParser` handles the
TO prefix and `OfflineMaterializedViewQueryAnalyzer` handles the conservative
syntactic inventory. W88 retains its historical SELECT-body-only materializer
gate; the new descriptor preserves the complete SELECT/WITH query slice.

```crystal
view = catalog["analytics"]["events_mv"]
if declaration = view.materialized_view
  declaration.query
  declaration.target
  declaration.source_references_status
  declaration.source_references # Empty if status is :unknown.
  target = catalog.resolve_materialized_view_target("analytics", "events_mv")
end
```

The explicit resolution call does not execute the query or claim that the
target is current. Reading the MV object itself remains guarded; callers may
inspect or read the independently resolved physical table within its existing
reader capability.

## Risk, falsifiers and executed sequence

CAUTION: public catalog API and metadata identity boundary. Rollback is one
atomic local commit from the clean baseline; no push or history rewriting.
Use one file per new descriptor/reference/analysis owner. Existing consumers
were enumerated with bounded searches for parse_table_ddl, table(location),
DatabaseLocation and OfflineTable construction before changing their context.

1. Behavioral RED preceded production changes; W86/W87/W88 controls remained
   green.
2. Independent current-runtime probes established persisted MV prerequisites,
   including default security, target quoting and canonical ATTACH behavior.
3. Immutable descriptor/reference/target owners and contextual catalog
   integration landed; query analysis remains separate from DDL validation and
   target resolution.
4. Root executed the affected DEBUG/RELEASE roster, stock metadata and explicit
   target-resolution fixtures, separate raw audits and seeded semantic-forgery
   refusals. This records only the frozen evidence below, not a full repository
   or general SQL/MV qualification.

Strongest failure: a partial SQL scanner labels omitted relations complete.
Falsifiers include CTE aliases, repeated nested SELECT, JOIN/table functions,
IN table, fake FROM/TO in quotes, qualified/unqualified names in two databases,
optional target UUID mismatch, duplicate inner UUIDs, absent inner metadata,
mutable constructor/getter aliases, unsafe controls, a view with no UUID store,
projection separation and unchanged W88 detached-only fences.

Executed pre-implementation RED: the new W228 specs plus W86/W87/W88 catalog
and materializer controls compiled successfully at the baseline and produced
36 examples, 6 failures, 2 errors and 0 pending. All 28 existing controls passed.
The eight new examples exposed the missing descriptor/resolver APIs and parser
gaps for AS WITH ... SELECT and a named target's optional UUID. The raw log is
`/private/tmp/crystal-click-w228.t5rWWK/red.log`; temporary logs are not durable
certificates and must be refreshed if missing.

Stock prerequisite probes also established that source-free SELECT and explicit
TO INNER UUID are accepted. CREATE with an implicit inner ENGINE is persisted
as explicit TO INNER UUID. A named target's optional UUID is accepted in CREATE
but omitted from canonical persisted ATTACH. Native fixture expectations must
describe the actual persisted bytes, not the original CREATE spelling.

An executed isolated adversary probe exposed false completeness for
`SELECT s.k FROM lab.source AS s SAMPLE 1/2, other.source AS o`: the initial
analyzer returned only `lab.source` with status complete. The source grammar
consumes SAMPLE before a following comma relation. The final bounded analyzer
returns unknown for unsupported SAMPLE and unrecognized source suffixes;
commas inside projection/filter/group/order expressions remain valid. Both
regressions are covered by the focused suite. The probe log is
`/private/tmp/crystal-click-w228.t5rWWK/analyzer-sample-red.log`.

A second source-backed executed probe exposed false completeness for
`SELECT k FROM 'source' AS s`: discarding literals caused the initial analyzer
to report `lab.AS`. ClickHouse's TableAsStringLiteralIdentifier parser accepts
that relation spelling. The corrected lexer preserves an opaque literal token
and returns unknown for that unsupported source form, without lexing FROM/TO
words inside expressions. Positive literal-projection controls guard the
opposite failure. The RED log is
`/private/tmp/crystal-click-w228.t5rWWK/analyzer-string-red.log`.

The pre-literal-fix source state passed 42 focused examples and 186 examples in
the 35-file affected catalog/offline/projection roster in DEBUG and RELEASE.
Final frozen-source reruns pass 187 examples in that same 35-file roster in
each mode, with zero failures, errors or pending. The full repository suite is
not claimed. Final `format --check` passed for 10 Crystal files, and root's
final 12-file source-hash check matched the frozen inputs. The only hash changes
since earlier harness runs were two Ruby harness fixes; production, helper and
spec inputs did not drift.

Fresh paired native DEBUG and RELEASE qualification and independent raw audits
pass 11 stock-authored views, 26 actual metadata files, and 20 raw processes
per mode (19 exit-zero processes plus one expected stock table-function
refusal). The qualification includes two refresh/security parser guards, two
resolver negative controls and an ordinary projection metadata control. Both
auditors reject a coherent equal-width cross-database target-reference forgery
in both `helper.json` and `0020-crystal-helper.stdout`, while preserving the
original successful process statuses and green summary; exact-byte restoration
was checked separately and both restored audits pass. This adversary check
supports the scoped claim; it does not certify arbitrary evidence mutations,
all metadata inventory shapes or all SQL.

Frozen helper SHA-256: DEBUG
`c6962ed70ac99ecdd0b91ef2ebd8cf391aab1807f1113d8ddbf1f0d2421588c5`;
RELEASE `105f1d7fe16b50dcbe6328130ae56817816f4580d0b643fdc4ce26a8da2948a2`.
Fresh native catalog roots are
`/private/tmp/crystal-click-w228-native.debug-retry.IDUWCz` and
`/private/tmp/crystal-click-w228-native.release.HXprUA`; paired evidence roots
are `/private/tmp/crystal-click-w228-evidence.debug-retry.H8o6Jb` and
`/private/tmp/crystal-click-w228-evidence.release.Oi7pHN`. Final run and audit
logs are under `/private/tmp/crystal-click-w228.t5rWWK`: the two
`catalog-*-final.log` files, `native-debug-final.log`, `native-release.log`,
`audit-debug-final.log`, `audit-release.log`, the two
`audit-*-semantic-seed.log` files and the two `audit-*-restored.log` files.
The durable evidence index is
[`materialized-view-metadata-w228.json`](../.landmark/evidence/materialized-view-metadata-w228.json);
temporary raw roots are evidence caches, not durable certificates.

## DoD and continuity

Root serialized compiler/native/audit jobs through run_safe, min free memory
50%, one Crystal worker and isolated cache. The affected DEBUG/RELEASE roster
and fresh stock-authored Atomic catalogs passed against independent
literal/reference expectations and actual metadata bytes. The separate raw
auditors rejected successful-exit semantic forgery and passed after exact
restoration. Counts above are observed results, not inferred.

This is VERIFIED only for the bounded offline declaration and current-local
physical-target identity resolution described above. It does not establish
server Active state, freshness, query execution, insert-trigger completeness,
general MV/projection support or native full-repository coverage. Refresh
evidence after parser, context, descriptor, resolver, fixture/helper, source or
runtime changes. The full types/MV/projection objective remains active.
Memory/performance remains deferred; no stock-reader parity claim.
