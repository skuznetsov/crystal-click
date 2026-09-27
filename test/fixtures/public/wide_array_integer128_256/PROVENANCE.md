# Public Wide raw 128/256-bit integer Array fixture

The `part/` tree was produced in an isolated scratch ClickHouse local store by
the official ClickHouse 26.7.1.1315 build. Its source table was a nine-column
MergeTree ordered by `pk UInt64`: four `Array(Int128/UInt128/Int256/UInt256)`
columns and four corresponding `Array(Nullable(T))` columns. The seven rows
have keys `1, 2, 4, 6, 9, 11, 13` and include empty arrays, signed minima and
maxima, unsigned maxima, values crossing 64/128-bit limbs, and NULL elements.

The part is Wide with LZ4 data streams, plain `.mrk2` marks,
`index_granularity = 2`, four data marks, and an EOF sentinel. Each non-null
Array has `size0` plus payload streams; each BASIC Nullable leaf adds a `null`
stream. The nested fixed-width payload contains zero-filled slots beneath
NULL, while RowBinary omits those child bytes.

The fixture was copied byte-for-byte from the stock part after `CHECK TABLE`
returned success. It is compatibility evidence only for this pinned build and
part profile, not for arbitrary ClickHouse versions or Array compositions.
