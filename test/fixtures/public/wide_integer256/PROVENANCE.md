# Public Wide raw Int256/UInt256 fixture

This fixture was produced by the pinned ClickHouse local 26.7.1.1315 official
build using `scripts/generate_public_wide_integer256_fixture.sh`. The `part/`
directory is a 13-row, three-column Wide part ordered by `pk UInt64`, with
non-nullable `i Int256` and `u UInt256` values, LZ4-compressed data streams,
plain `.mrk2` marks, `index_granularity = 2`, seven data marks, and a terminal
EOF sentinel. Signed and unsigned endpoints, limb crossovers, repeated endpoint
values, negative two's-complement values, and a large decimal pair are included.

Each Int256/UInt256 value occupies exactly 32 little-endian bytes. The fixture
was generated independently by ClickHouse and is verified against pinned
physical metadata, decompressed bytes, mark records, RowBinary bytes, and SQL
edge values by `scripts/verify_stock_wide_integer256_fixture.sh`.

`SHA256SUMS` lists every regular file below `part/`. The generator refuses to
replace an existing output directory; recreate only into a new output path.
