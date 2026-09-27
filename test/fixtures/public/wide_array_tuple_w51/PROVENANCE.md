# W51 stock `Array(Tuple)` fixture

Produced with ClickHouse local 26.7.1.1315 (official build) by
[`generate_public_wide_array_tuple_w51_fixture.sh`](../../../../scripts/generate_public_wide_array_tuple_w51_fixture.sh).
The source table uses Wide parts, LZ4 data frames, plain adaptive `.mrk2`
marks, index granularity 2, and a UInt64 primary key. The seven sorted keys
are `1, 2, 4, 6, 9, 11, 13`; data mark row counts are `[2, 2, 2, 1]` followed
by the EOF sentinel.

The two payload declarations are exactly:

- `Array(Tuple(a UInt64, b String))`
- `Array(Tuple(a Nullable(UInt64), b String))`

The fixture includes empty arrays, empty and binary Strings, multi-element
arrays, `UInt64::MAX`, nullable values including all-NULL tuple fields, and
long String values. The stock generator runs `CHECK TABLE` and checks the
canonical columns and escaped child-stream names before copying the part.
`SHA256SUMS` covers every file in `part/`.

This fixture establishes only these exact declarations and the pinned
Wide/LZ4/plain-`.mrk2` profile; it does not imply arbitrary recursive Tuple,
Array, Nullable, Map, JSON, or other composite type support.
