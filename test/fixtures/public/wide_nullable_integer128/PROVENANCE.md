# Public Wide BASIC Nullable raw 128-bit integer fixture

This fixture was produced by the pinned ClickHouse local 26.7.1.1315 official
build using `scripts/generate_public_wide_nullable_integer_fixture.sh`. The
`part/` directory is a 32-row, three-column Wide part ordered by `pk UInt64`,
with `signed Nullable(Int128)` and `unsigned Nullable(UInt128)` payloads,
LZ4-compressed data streams, plain `.mrk2` marks, BASIC nullable serialization,
eight four-row marks, and a zero-row EOF sentinel. It includes NULLs, signed
negative values, Int128 endpoints, and values beyond 64 bits through
`UInt128::MAX`.

The separate `sparse/part/` is a stock negative control generated with
`nullable_serialization_version='allow_sparse'`. Its exact serializer records
are Sparse, its nested serialization version is `nullable:1`, and each
nullable column uses a `.sparse.idx` substream. It is expected to be rejected
by the bounded BASIC reader.

`SHA256SUMS` lists every regular file below `part/` and `sparse/part/`.
Recreate only into a new output directory (the generator refuses to overwrite)
and verify with `scripts/verify_stock_wide_nullable_integer_fixture.sh`.
