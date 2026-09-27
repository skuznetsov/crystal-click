# Public temporal Array fixture

`part/` is a byte-for-byte copy of a stock MergeTree part produced with the
official ClickHouse local `26.7.1.1315` build. The database/table names and UUIDs
were generated for an isolated scratch store; all payloads are synthetic.

The source DDL used a sorted `UInt64` key and the eight payload declarations
`Array(Date)`, `Array(Date32)`, `Array(DateTime)`, `Array(DateTime64(3))`, and
their `Array(Nullable(T))` forms. Its part profile was:

```sql
ENGINE = MergeTree
ORDER BY pk
SETTINGS
  index_granularity = 2,
  index_granularity_bytes = 10485760,
  enable_mixed_granularity_parts = 1,
  min_rows_for_wide_part = 0,
  min_bytes_for_wide_part = 0,
  compress_marks = 0,
  min_compress_block_size = 0,
  max_compress_block_size = 4096,
  ratio_of_defaults_for_sparse_serialization = 1.0,
  default_compression_codec = 'LZ4'
```

The rows have sorted keys `1, 2, 4, 6, 9, 11, 13`. This equivalent SQL
reproduces their semantic contents (the Date32 values are written as dates so
the SQL conversion domain is explicit):

```sql
INSERT INTO temporal_w40 VALUES
(1, CAST([], 'Array(Date)'), CAST([], 'Array(Date32)'), CAST([], 'Array(DateTime)'), CAST([], 'Array(DateTime64(3))'), CAST([], 'Array(Nullable(Date))'), CAST([], 'Array(Nullable(Date32))'), CAST([], 'Array(Nullable(DateTime))'), CAST([], 'Array(Nullable(DateTime64(3)))')),
(2, [toDate(0), toDate(1)], [toDate32('1969-12-31'), toDate32('1970-01-02')], [toDateTime(0), toDateTime(1)], [fromUnixTimestamp64Milli(-1), fromUnixTimestamp64Milli(1000)], CAST([NULL, toDate(0)], 'Array(Nullable(Date))'), CAST([NULL, toDate32('1969-12-31')], 'Array(Nullable(Date32))'), CAST([NULL, toDateTime(0)], 'Array(Nullable(DateTime))'), CAST([NULL, fromUnixTimestamp64Milli(-1)], 'Array(Nullable(DateTime64(3)))')),
(4, [toDate(65535)], [toDate32('1900-01-01')], [toDateTime(4294967295)], [fromUnixTimestamp64Milli(9223372036854775807)], [toDate(1)], [toDate32('1970-01-01')], [toDateTime(1)], [fromUnixTimestamp64Milli(0)]),
(6, CAST([], 'Array(Date)'), CAST([], 'Array(Date32)'), CAST([], 'Array(DateTime)'), CAST([], 'Array(DateTime64(3))'), CAST([], 'Array(Nullable(Date))'), CAST([], 'Array(Nullable(Date32))'), CAST([], 'Array(Nullable(DateTime))'), CAST([], 'Array(Nullable(DateTime64(3)))')),
(9, [toDate(42), toDate(0)], [toDate32('1900-01-01'), toDate32('2038-01-18')], [toDateTime(0), toDateTime(4294967295)], [fromUnixTimestamp64Milli(-9223372036854775808), fromUnixTimestamp64Milli(9223372036854775807)], CAST([NULL, toDate(0)], 'Array(Nullable(Date))'), CAST([NULL, toDate32('1970-01-01')], 'Array(Nullable(Date32))'), CAST([NULL, toDateTime(0)], 'Array(Nullable(DateTime))'), CAST([NULL, fromUnixTimestamp64Milli(-1)], 'Array(Nullable(DateTime64(3)))')),
(11, [toDate(65535)], [toDate32('1969-12-31')], [toDateTime(1)], [fromUnixTimestamp64Milli(-1)], [toDate(0)], [toDate32('1969-12-31')], [toDateTime(0)], [fromUnixTimestamp64Milli(-9223372036854775808)]),
(13, CAST([], 'Array(Date)'), CAST([], 'Array(Date32)'), CAST([], 'Array(DateTime)'), CAST([], 'Array(DateTime64(3))'), CAST([], 'Array(Nullable(Date))'), CAST([], 'Array(Nullable(Date32))'), CAST([], 'Array(Nullable(DateTime))'), CAST([], 'Array(Nullable(DateTime64(3)))'));
```

The Date32 payload uses signed 32-bit storage, but the stock SQL date conversion
domain is narrower than the full `Int32` range. In particular, the original
`toDate32(Int32::MIN/MAX)` endpoint probes normalize to 1900-01-01 and
2038-01-18; their observed raw day codes are `-25567` and `24854`, not
`Int32::MIN/MAX`. Separate W40 writer tests still exercise preservation of raw
signed `Int32` values.

The copied stock part reported seven rows and five marks (four data marks plus
the EOF sentinel); `CHECK TABLE` succeeded before and after copying. It has LZ4
data streams, plain adaptive `.mrk2` marks, and BASIC Nullable serialization.
`SHA256SUMS` pins every fixture file. This fixture is public synthetic test
data and evidence only for the pinned build and part profile; it does not
establish support for other layouts or ClickHouse versions.
