# W9 typed payload writer plan

Status: implemented and verified on parent `a358b76`; final verification evidence is
recorded in `EMBEDDED_MERGETREE_FRONTIER.md`.

Risk: CAUTION (new physical serialization and public API).
Rollback: one feature commit after verification; before it, revert only the
W9-owned paths, preserving unrelated user work.

The active contract is the W9 section of `EMBEDDED_MERGETREE_FRONTIER.md`.
`rg -n 'WidePartWriter|write_uint64_.*pair' src spec examples scripts docs`
finds the existing writer, the embedded-table String caller, reader/checksum
specs, the external writer oracle, and prior plans. Existing entry points and
their on-disk output remain regression controls; the embedded table API is not
widened in W9.

1. Add red focused specs in `spec/wide_part_writer_typed_spec.cr` for exact typed scalar payloads, signed and float-bit
   boundaries, all-null/default distinction, short-final marks, invalid type
   or size refusal, and no publication on failure. Make each missing writer
   behavior fail before implementation.
2. Extend the writer using the existing stage/mark/checksum/publish path.
   Encode each admitted type without implicit conversion, preflight all
   physical streams, and self-read each completed staged part. Guard against
   width overflow, stream-name collisions, wrong Nullable stream shape, and
   float bit-pattern changes.
3. Add `scripts/check_typed_writer_oracle.sh` beside the existing pinned
   `clickhouse local` oracle with independent `ATTACH PART`,
   exact typed scans, key-range scans, `CHECK TABLE`, and a corrupt-stream
   negative control for every admitted type/substream shape. Keep fixtures
   synthetic and the store isolated. A Crystal-only round trip is not a pass.
4. Run the focused and full debug/release Crystal suites, formatting,
   `bash -n`, the pinned external oracle, and `git diff --check`; inspect the
   exact diff and update the W9 SDD boundary/evidence. Claim only the tested
   pinned version and Darwin publication frontier.

DoD commands: `crystal spec --link-flags='-fuse-ld=ld'
spec/wide_part_writer_spec.cr spec/wide_part_writer_typed_spec.cr`,
`crystal spec --link-flags='-fuse-ld=ld'`,
`crystal spec --release --link-flags='-fuse-ld=ld'`,
`bash scripts/check_wide_part_writer_oracle.sh`,
`bash scripts/check_typed_writer_oracle.sh`,
`crystal tool format --check src/crystal_click/wide_part_writer.cr
spec/wide_part_writer_typed_spec.cr`,
`bash -n scripts/check_wide_part_writer_oracle.sh scripts/check_typed_writer_oracle.sh`,
and `git diff --check`. Expected: all pass; each type is named in the oracle
output and the corrupted-stream control fails integrity checking. If the
external oracle fails or is unavailable, keep W9 in progress and do not
promote physical compatibility.
