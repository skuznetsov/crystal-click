# W53 Nullable-value Map fixture

This public fixture is a stock ClickHouse Wide part generated with ClickHouse
26.7.1.1315 (official build) by
`scripts/generate_public_wide_map_nullable_w53_fixture.sh`.

The three columns are `pk UInt64`, `map_u64 Map(UInt64, Nullable(UInt64))`,
and `map_string Map(String, Nullable(UInt64))`. The seven rows use index
granularity 2 and contain empty maps, ordered duplicate keys, NULL values next
to non-NULL zero values, UInt64 boundary values, and a binary String key.
The fixture uses LZ4 data streams, plain `.mrk2` marks, and a short final mark.

`SHA256SUMS` records the committed part files. Run
`scripts/verify_stock_wide_map_nullable_w53_fixture.sh` to check the exact
schema, stream inventory, compression framing, marks, and recorded digests.
