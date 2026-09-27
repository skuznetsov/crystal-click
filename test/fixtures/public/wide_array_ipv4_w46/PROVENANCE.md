# W46 IPv4 Array stock fixture

This synthetic fixture was produced by the official ClickHouse local build
`26.7.1.1315` with `scripts/generate_public_wide_array_ipv4_w46_fixture.sh`.
It contains exactly `pk UInt64`, `plain Array(IPv4)`, and
`maybe Array(Nullable(IPv4))`, ordered by `pk`, in one Wide/LZ4 part with
plain adaptive `.mrk2` marks. The fixture verifier checks the canonical
column/substream metadata, BASIC serialization metadata, six LZ4 data streams,
and four two-row marks plus a one-row final mark and EOF sentinel.

Rows and arrays are synthetic. They deliberately include empty arrays,
asymmetric addresses (`192.0.2.1`, `1.2.0.192`, and `203.0.113.9`),
`0.0.0.0`, nullable NULLs, a nonempty all-NULL array, and values in later
marks. ClickHouse serializes the network-order IPv4 UInt32 as four
little-endian bytes. On disk, Nullable NULL elements retain a zero-filled
four-byte nested slot next to a one-byte null-map entry; RowBinary emits only
the NULL flag and omits that nested payload.

`SHA256SUMS` covers every regular file in `part/`. The fixture is a producer
observation for the pinned build and profile, not evidence by itself of
Crystal compatibility; the separate W46 spec and bidirectional oracle provide
that evidence. Refresh these checks if the producer build, codec, mark format,
reader/writer serialization boundary, or supported platform changes.
