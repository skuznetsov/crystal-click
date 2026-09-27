# W45 stock Decimal256 Array fixture

- Producer: ClickHouse local 26.7.1.1315 (official build).
- Producer script: `scripts/generate_public_wide_array_decimal256_w45_fixture.sh`.
- Shape: sorted `UInt64` key plus `Array(Decimal(76, 2))` and
  `Array(Nullable(Decimal(76, 2)))`.
- Part profile: Wide, LZ4, plain adaptive `.mrk2`, granularity two; seven rows
  with four data marks containing `[2, 2, 2, 1]` rows and an EOF sentinel.
- Values are synthetic. They include the valid Decimal(76,2) coefficient
  boundary, empty arrays, nullable NULLs, and non-NULL zero values. Raw signed
  Int256 extrema are tested separately by the Crystal-writer stock oracle and
  are not treated as valid SQL Decimal coefficients.
- `SHA256SUMS` covers every file under `part/`; verify with
  `scripts/verify_stock_wide_array_decimal256_w45_fixture.sh`.
