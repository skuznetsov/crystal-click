# Stock Map(UInt64, String) Wide-part fixture

This is a byte-for-byte copy of the `all_1_1_0` part emitted by ClickHouse
26.7.1.1315 in the pinned stock probe. The captured source directory was:

`/private/tmp/clickhouse-w25-mrk2.SvPa2I/store/store/98b/98bca696-b46b-4b22-9c53-b66285d979d9/all_1_1_0`

It is a Wide part using the default LZ4 codec and MRK2 marks. The part contains
`id UInt64`, `m Map(UInt64, String)`, and an unrelated
`a Array(Tuple(k UInt64, v String))` column. The unrelated Array column also
guards that Map stream validation does not mistake other nested streams for
the Map's unique UInt64 key column.

To verify the committed snapshot's SHA-256 digests:

```sh
scripts/verify_stock_map_uint64_string_fixture.sh
```

When the pinned ClickHouse probe directory is available, verify byte-for-byte
identity and file-set equality against the stock part:

```sh
scripts/verify_stock_map_uint64_string_fixture.sh \
  /private/tmp/clickhouse-w25-mrk2.SvPa2I/store/store/98b/98bca696-b46b-4b22-9c53-b66285d979d9/all_1_1_0
```

To reproduce the checked-in snapshot from the captured stock directory:

```sh
STOCK_PART=/private/tmp/clickhouse-w25-mrk2.SvPa2I/store/store/98b/98bca696-b46b-4b22-9c53-b66285d979d9/all_1_1_0
cp -R "$STOCK_PART"/. test/fixtures/stock_map_uint64_string_lz4/part/
(cd test/fixtures/stock_map_uint64_string_lz4 && \
  shasum -a 256 part/* > SHA256SUMS)
scripts/verify_stock_map_uint64_string_fixture.sh "$STOCK_PART"
```

For a newly generated pinned stock part, substitute its part directory for
`STOCK_PART`. Review any changed digests as an intentional fixture update. The
reader spec independently asserts decompressed logical stream bytes and MRK2
values, so changing the manifest alone cannot make a changed fixture satisfy
the format assertions.

The original SQL statements used to create this captured part were not retained.
The path above and the SHA-256 manifest prove the identity of the captured
snapshot, not that this document can reproduce the same bytes from scratch.
The writer oracle independently creates fresh tables and tests Crystal output
against the pinned ClickHouse binary.
