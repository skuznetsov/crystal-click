# W55 stock `Array(Tuple(UInt64, UInt64))` fixture

Produced with ClickHouse local 26.7.1.1315 (official build) by
[`generate_public_wide_array_tuple_w55_fixture.sh`](../../../../scripts/generate_public_wide_array_tuple_w55_fixture.sh).
The source table uses a Wide part, LZ4 data frames, plain adaptive `.mrk2`
marks, index granularity 2, and a UInt64 primary key. The seven sorted keys
are `1, 2, 4, 6, 9, 11, 13`; data mark row counts are `[2, 2, 2, 1]` followed
by the EOF sentinel.

The payload declaration is exactly `Array(Tuple(a UInt64, b UInt64))`. It
contains empty and nonempty arrays, zero and maximum UInt64 values, and
multi-element arrays. Rows 9 and 11 form an all-empty later granule; the final
short granule has one nonempty row. The stock generator runs `CHECK TABLE`
and checks canonical columns and escaped child-stream names before copying
the part. `SHA256SUMS` covers every file in `part/`.

This fixture establishes only this exact declaration and the pinned
Wide/LZ4/plain-`.mrk2` profile; it does not imply arbitrary recursive Tuple,
Array, Nullable, Map, JSON, or other composite type support.
