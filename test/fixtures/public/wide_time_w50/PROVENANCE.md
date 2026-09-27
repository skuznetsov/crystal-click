# W50 Time and Time64 stock fixture

This fixture is a synthetic public MergeTree part produced by the pinned
ClickHouse local binary `26.7.1.1315 (official build)` using
`scripts/generate_public_wide_time_w50_fixture.sh`. It contains seven rows,
an unsigned key, and the eight admitted Time/Time64 composition shapes, with
Time64 precision controls at 0, 3, and 9. Values are deliberately in ClickHouse
Time's supported range and include negative values, negative fractions, NULLs,
empty arrays, arrays containing only NULLs, and multiple marks.

The fixture is checked by the pinned ClickHouse local engine before capture
and by `scripts/verify_stock_wide_time_w50_fixture.sh` after capture. Its exact
schema, substream topology, serializer metadata, mark layout, compression
profile, and part-file digests are pinned alongside the part.
