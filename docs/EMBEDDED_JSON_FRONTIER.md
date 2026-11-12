# Embedded MergeTree JSON Typed-Path Frontier

Status: bounded table support for an explicitly declared, flat set of scalar
typed paths in one top-level `JSON` column. The table writes native JSON
typed-path parts; it does not serialize the payload as a `String`.

The v2 manifest records the key and payload names, the canonical `JSON(...)`
type, and each `(path, scalar type)` declaration. Existing v1 String manifests
and the `create` / `insert` API remain supported. JSON schemas admit at most
15 simple top-level paths so the key and full JSON projection fit the reader's
16-column selection limit. Complete part metadata must also fit the table's
4 KiB metadata bound.

`insert_json` requires every declared path exactly once, with its declared
homogeneous scalar type and the same row count as the sorted UInt64 key. Values
for absent paths are caller-supplied normalized defaults. `scan_typed` selects
the key and declared projections such as `record.kind`; it does not return a
whole JSON document. Adjacent-part merge preserves every typed path and stable
left-before-right ordering for equal keys.

The merge row cap remains 100,000 rows. The 64 MiB merge payload cap counts
String typed-path bytes; numeric path arrays are separately bounded by the row
cap and 15-path schema limit. This is a bounded in-memory implementation, not
an exact heap-accounting guarantee.

Guard-only: nested or dotted paths, dynamic paths, arbitrary JSON documents,
Nullable paths, path-presence inference, non-default serializers, power-loss
durability, and schemas exceeding the declaration or metadata bounds.

Verification (2026-10-27): `crystal spec spec/embedded_merge_tree_json_spec.cr
spec/embedded_merge_tree_table_spec.cr` passed 31 examples with no failures or
errors. The same run passed on clean base
`6e893890713d09ecdb7d7909ee9a2addf80eff75` with only this feature's table,
spec, and document overlaid. It covers native physical declarations, mixed
scalar merge stability, reopen/reclaim, wrong-schema rejection before
publication, the complete metadata size boundary, and the existing String
table behavior. Repeat after changing the table, writer, reader, or runtime.
