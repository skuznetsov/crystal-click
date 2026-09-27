# Public Wide raw 128-bit integer fixture

This fixture is a stock ClickHouse 26.7.1.1315 part produced by
`scripts/generate_public_wide_integer_fixture.sh`. It has the exact schema
`pk UInt64, signed Int128, unsigned UInt128`, sorted by `pk`, stored as a Wide
part with LZ4 data files and uncompressed `.mrk2` marks. The fixture contains
13 rows, including negative signed values, values beyond 64 bits, both
Int128 endpoints, and UInt128 values through `UInt128::MAX`.

`SHA256SUMS` covers every file in `part/`. Recreate it with the pinned stock
ClickHouse executable and verify it with
`scripts/verify_stock_wide_integer_fixture.sh`.
