# W12 raw Date/Date32 reader/writer plan

Status: verified bounded implementation on the pinned local frontier. Contract:
`EMBEDDED_MERGETREE_FRONTIER.md`, W12. Risk: CAUTION (semantic type
dispatch and persisted writer bytes). Rollback: the single W12 feature
commit after verification, or only W12-owned paths before commit. No push.

Factual anchor: pinned ClickHouse local 26.7.1.1315 emits one UInt16 day-code
stream for `Date` and one Int32 day-code stream for `Date32`, each with plain
adaptive `.mrk2`. A pinned RowBinary Date32 probe accepted the full Int32
domain through detach/attach and `CHECK TABLE`, whereas civil rendering
saturates at the extreme codes. Current Crystal unions and little-endian
decoders already represent UInt16/Int32, but the public typed grammar and
writer infer them as numeric types. The source checkout is format guidance;
the pinned executable and generated parts are the physical oracle.

1. Add RED reader and writer specs for exact Date/Date32 metadata, raw day
   codes across marks, negative/extreme Date32 values, separate semantic
   batch accessors, numeric-accessor rejection, and failure before publish.
2. Extend exact typed dispatch in `src/crystal_click/wide_part.cr` and
   `src/crystal_click/wide_part_table.cr`. Add semantic mark and batch
   accessors returning UInt16/Int32 codes, not `Time`; keep
   `supports_numeric_type?`, primitive `values_for`, and `scan_numeric`
   unchanged. Extend `src/crystal_click/offline_catalog.cr` materialization
   using those semantic accessors and preserve the column type metadata.
   Update `examples/offline_tui/page_source.cr` as a downstream typed-support
   consumer so selected Date/Date32 columns display raw codes; do not extend
   equality-filter semantics.
3. Add explicit Date and Date32 entry points in
   `src/crystal_click/wide_part_writer.cr`. Refactor only enough shared
   validation and staged reread to retain W9 checks without numeric-type
   inference. Full raw domains are valid; no calendar clamping. An invalid
   input, mismatch, or failed publication must leave the destination absent.
4. Add `scripts/check_date_oracle.sh` for pinned stock-to-Crystal generated
   parts and Crystal-to-stock attached parts. Check physical streams and
   marks, exact raw codes on full and key-filtered reads, `CHECK TABLE`, and
   a corruption negative. Run W9/W10/W11 oracles as regression guards.

DoD: focused RED-to-green specs; full Crystal debug and release suites with
`--link-flags='-fuse-ld=ld'`; `crystal tool format --check`, `bash -n`, and
`git diff --check`; pinned W12 differential oracle and W9/W10/W11 controls
all pass. Adversarially check that `Date` is not accepted as `UInt16`,
`Date32` is not accepted as `Int32`, and extreme raw codes are not silently
clamped. A self-consistent Crystal writer rejected by stock ClickHouse is
the strongest likely falsifier and blocks a compatibility claim/commit.
Compatibility evidence will be bounded to the pinned build, Wide/LZ4 shape,
Darwin filesystem/publication, and tested fixtures.

## Observed closure evidence

- RED reader/writer specs preceded the implementation. The final source tree
  passed `crystal spec --link-flags='-fuse-ld=ld'` and its `--release`
  counterpart: 376 examples, zero failures/errors/pending in each mode.
  An attempted simultaneous run collided in the shared Crystal cache and
  was excluded from evidence; both modes then passed sequentially with
  isolated `CRYSTAL_CACHE_DIR` values.
- `bash scripts/check_date_oracle.sh` passed against ClickHouse local
  26.7.1.1315. It checked one payload stream and plain adaptive marks for
  both stock-produced types, exact raw Date/Date32 codes, Crystal-written
  `ATTACH PART`, full and key-range rows, clean `CHECK TABLE`, and rejection
  of a same-size damaged payload stream for each type.
- W9, W10, and W11 differential oracles passed as regression controls.
  Focused TUI page-source specs passed 11/11; the opt-in headless TUI suite
  passed 6/6, and the linked example built. The publication-failure spec
  checks that both new writers leave no destination or staging directory.
- `crystal tool format --check` on changed Crystal files, `bash -n` on the
  new oracle, and `git diff --check` passed. The final staged diff receives
  an additional whitespace/path check before commit.

Scope: exact `Date`/`Date32` metadata, raw UInt16/Int32 day codes, the
two-column Wide/LZ4 writer, plain adaptive marks, the tested fixtures,
Darwin exclusive publication, and the pinned ClickHouse build. This does
not establish calendar/timezone semantics, nullable dates, Compact parts,
other builds or filesystems, daemon restart, or power-loss durability.
Changes to the typed dispatch, serializer, stream framing, or pinned build
invalidate the relevant compatibility evidence and require rerunning the
focused specs and differential oracle before promoting a new claim.
