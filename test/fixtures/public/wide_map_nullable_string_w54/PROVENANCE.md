# W54 nullable-String-value Map fixture

This public fixture is a stock ClickHouse Wide part generated with ClickHouse
26.7.1.1315 (official build) by
`scripts/generate_public_wide_map_nullable_string_w54_fixture.sh`.

The columns are `pk UInt64`, `map_u64 Map(UInt64, Nullable(String))`, and
`map_string Map(String, Nullable(String))`. Seven ordered-key rows use index
granularity 2. They include empty maps, ordered duplicate keys, NULL next to
empty non-NULL values, a binary String key, embedded-NUL String data, UTF-8
keys and values, and a short final mark. The fixture uses LZ4 data streams and
plain `.mrk2` marks. Its exact child-stream topology and pinned serialization
metadata are recorded in the part and enforced by the verifier.

`SHA256SUMS` records the part files. Run
`scripts/verify_stock_wide_map_nullable_string_w54_fixture.sh` to check the
schema, stream inventory, compression framing, marks, and recorded digests.
