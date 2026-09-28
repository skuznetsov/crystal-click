# Public W57 stock Variant fixture

`compact/part` and `basic/part` are public-data-free MergeTree parts generated
with the pinned ClickHouse local 26.7.1.1315 official build by
`scripts/generate_public_wide_variant_w57_fixture.sh`. The table is declared
as `Variant(UInt64, Bool, String)` intentionally out of order; the stock part
metadata canonicalizes it to exactly `Variant(Bool, String, UInt64)`.

The payload substreams are exactly `.variant_discr`, `.Bool`, `.String.size`,
`.String`, and `.UInt64`. Both profiles use LZ4, plain `.mrk2` marks, 13 rows,
and index granularity 3. Their mark row counts are `[3, 3, 3, 3, 1]`. The
sample covers a mixed Bool/String/UInt64 granule, a uniform-Bool granule, an
all-NULL granule, a granule with no Bool values and an empty String, plus a
short UInt64 tail. Its keys are 1 through 13; its values are
`true, "alpha", 42, false, true, false, NULL, NULL, NULL, "", UInt64::MAX,
"omega", 99`.

The discriminator tags are Bool `0`, String `1`, UInt64 `2`, and NULL `255`.
The discriminator's first mark starts at compressed offset 0 and decompressed
offset 8 with three rows; the verifier also checks the BASIC or COMPACT mode
prefix, exact fixture inventory, child stream topology, mark records, LZ4
frames, and SHA-256 list.

Regenerate a profile only after intentionally removing its target; the
generator refuses to overwrite existing fixture paths. To check a generated
copy without touching the checked-in fixture, set `W57_FIXTURE_ROOT` to a new
empty directory. Run
`bash scripts/verify_stock_wide_variant_w57_fixture.sh compact` and the same
command with `basic` to validate the checked-in fixtures.
