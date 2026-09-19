# Wide Part Reader Slice Plan

Risk: CAUTION (new on-disk compatibility boundary)

Scope: a dependency-free Crystal 1.21 shard that reads only a local immutable
ClickHouse Wide part with one exact `UInt64 CODEC(LZ4)` stream and plain
adaptive `.mrk2` marks produced by ClickHouse 26.7.1.1315. No SQL is exposed
by the shard; SQL is used only by the fixture generator.

The retained final zero-row `.mrk2` sentinel may use either the final frame
offset or the data-file EOF offset; EOF is admitted only with local offset zero.

Rollback: remove the owned paths listed below. Do not touch the frontier SDD,
the private fixture, or `.git`.

Owned paths:

- `shard.yml`
- `src/crystal_click.cr`
- `src/crystal_click/errors.cr`
- `src/crystal_click/stream_name.cr`
- `src/crystal_click/metadata.cr`
- `src/crystal_click/lz4.cr`
- `src/crystal_click/wide_part.cr`
- `spec/spec_helper.cr`
- `spec/lz4_spec.cr`
- `spec/wide_part_spec.cr`
- `scripts/generate_public_fixture.sh`
- `test/fixtures/public/wide_u64_lz4/part/`

Ordered steps:

1. Generate a public one-column Wide fixture with `compress_marks=0`, fixed
   `index_granularity`, and enough rows for multiple LZ4 frames. Verify its
   shape is exactly one `.bin`, one plain `.mrk2`, `UInt64`, and `CODEC(LZ4)`.
2. Add specs for metadata, adaptive mark records, full scan, mark-range scan,
   frame parsing, and every SDD falsifier. Run them before implementation and
   retain the observed RED failure.
3. Implement strict metadata/stream discovery, bounds-checked ClickHouse
   framing, pure Crystal raw-block LZ4 decoding, and exact row-count/range
   validation. Checksum bytes are consumed but deliberately not verified.
4. Run focused specs, all specs, formatter/checks, fixture regeneration, and a
   checksum-only corruption probe. The latter must remain an explicit
   non-guarantee rather than silently becoming accepted integrity validation.

Public API:

```crystal
part = CrystalClick::WidePart.open("/path/to/part")
part.read_uint64                         # all rows
part.read_uint64_mark_range("value", 2, 2)
part.checksum_verification               # Unverified
```

The reader exposes `row_count`, `mark_count`, `data_path`, and `mark_path`; it
keeps parsed marks private, raises the typed errors in
`src/crystal_click/errors.cr`, and never returns a partial range.
`CrystalClick::StreamName.hash` is the bounded ClickHouse-compatible
original-name fallback used for the physical stream.

Definition of done:

```text
crystal spec spec/lz4_spec.cr spec/wide_part_spec.cr
crystal spec
crystal tool format --check
scripts/generate_public_fixture.sh --check
```

Expected signal: exact fixture values and selected mark-range values match the
ClickHouse input; malformed metadata, marks, frames, sizes, methods, and row
counts fail closed without returning a partial array.
