# Reusable Decode Workspace Frontier SDD

Document status: **completed + VERIFIED** within the declared synchronous
decode-workspace scope. Final adversary verdict: **ROBUST**.

Current frontier: remove the fresh decompressed `Bytes` allocation from every
physical frame on the existing synchronous Wide-part scan path. One decode
workspace belongs to one scan operation and retains one GC-managed high-water
buffer. The admitted `Multiple(Delta, ZSTD)` chain reconstructs Delta forward
in place after nested ZSTD decode.

Bounded context: the existing LZ4, ZSTD, and exact
`Multiple(Delta, ZSTD)` codecs in `src/crystal_click`, with the current mmap,
frame, mark, size-limit, checksum-status, and typed-error semantics. This is a
buffer-ownership change, not a new codec, unmanaged allocator, or end-to-end
performance claim.

## Admitted API and lifetime

The admitted destination-oriented API is:

```crystal
workspace = CrystalClick::CompressedBlock::DecodeWorkspace.new
frame = CrystalClick::CompressedBlock.decode_frame_into(data, offset, workspace)
```

`frame.output` aliases workspace-owned storage. Its contents are stable only
until the next call that uses the same workspace. A consumer must finish
reading the slice synchronously or copy it. A workspace is neither reentrant
nor thread-safe and must not be shared by concurrent scans.

`LZ4.decode_into` and `ZSTD.decode_into` decode into an exact-size writable
destination. The existing `decode`, `decode_frame`, and `decode_all` APIs keep
their signatures and owning-result behavior. `WidePart` creates one local
workspace per scan operation and reuses it across physical frames; it never
stores the workspace on a reader instance.

The workspace grows only when a validated stage requires more bytes than its
current capacity and never shrinks during the operation. Returned slices are
exact logical lengths, not full capacities. For `Multiple`, the nested Delta
block is longer than the final output by its nine-byte header plus two-byte
payload prefix. Forward reconstruction writes each output word eleven bytes
behind the next unread difference, so it cannot overwrite unread input.

## Admitted surface

- Direct LZ4 and ZSTD frames decode into the workspace buffer.
- The exact admitted `Multiple(Delta, ZSTD)` chain decodes nested ZSTD into the
  workspace and reconstructs Delta forward in the same buffer only after the
  complete nested header, payload size, width, skip, alignment, and outer
  output size have been validated.
- Existing compressed/decompressed/aggregate limits are checked before buffer
  growth.
- `decode_all` may reuse a local workspace while retaining its one final owning
  aggregate result.
- The mmap-backed Wide-part scan reuses one workspace across all selected
  frames and consumes every borrowed output before the next decode.
- Existing direct codec APIs return owning storage that is not overwritten by
  a later independent decode call.
- Existing corruption, truncation, method allowlist, output-size, mark-boundary,
  callback-error, and mmap-cleanup behavior remains unchanged.

## Rejected surface

- Returning workspace-backed output as an owning or stable result.
- Storing one workspace on `WidePart`, global pooling, cross-thread sharing, or
  same-workspace reentrancy.
- Caller-provided raw pointers, unmanaged allocation, manual free, arena
  allocation, or escaped unsafe slices.
- In-place transforms for any codec chain other than the exact admitted
  `Multiple(Delta, ZSTD)` layout.
- ClickHouse's padded wild-copy LZ4 decoder or its 64-byte source/destination
  tail contract; Crystal's checked scalar decoder remains authoritative.
- New codecs, a wider `Multiple` chain, checksum verification, persistent mmap,
  changed seek behavior, or mark-format changes.
- A claim of zero allocations, zero GC, lower RSS, or higher throughput. The
  structural claim is limited to reuse of codec output storage after its
  high-water capacity has been reached.

## Design laws

1. Every requested buffer size comes from an already validated frame or nested
   stage and remains within the existing decompressed-size limit.
2. An in-place stage must prove its write cursor cannot reach unread input. For
   admitted Delta, the output write cursor remains eleven bytes behind the
   next unread difference.
3. The logical output slice has exactly the declared decoded length even when
   retained capacity is larger.
4. No borrowed workspace slice crosses the synchronous frame-consumer
   boundary in `WidePart`.
5. Independent calls to the existing owning APIs do not alias one reusable
   workspace.
6. Buffer reuse must not weaken exact-input, exact-output, trailing-byte,
   alignment, or codec-allowlist checks.
7. Capacity/pointer reuse is structural evidence only. Performance claims need
   a separate benchmark frontier with workload, warmup, and variance controls.

## Falsifier roster

| Falsifier | Required signal | Boundary |
| --- | --- | --- |
| RED API | Focused spec initially fails because `DecodeWorkspace` or `decode_frame_into` is absent | Historical TDD evidence |
| Same-size reuse | Consecutive same-size LZ4, ZSTD, and Multiple outputs use the same primary address | High-water reuse |
| Growth then reuse | A larger validated frame changes/grows capacity once; a later smaller frame reuses the grown primary allocation and returns only its logical prefix | Capacity law |
| In-place safety | Multiple exact values, wraparound cases, and a larger nested-than-final layout decode in place without corrupting unread differences | Transform overlap |
| Borrowed lifetime | A retained workspace output observes overwrite on the next same-size decode; a copied output remains stable | Explicit borrowed contract |
| Owning compatibility | Outputs from independent `decode_frame` calls remain stable and non-aliased | Existing API |
| Codec parity | Public LZ4, ZSTD, Delta/ZSTD, range, and multi-part fixtures retain exact values | Supported formats |
| Corruption parity | Existing malformed/truncated/limit vectors retain their typed failures | Fail-closed behavior |
| Scan route | Source inspection and fixture scan show one local workspace is reused across a scan, with no instance/global workspace | Concurrency boundary |
| Repository regression | Focused, full debug, and full release suites pass | Current checkout |

## Stop rules and rollback

- Stop if an in-place stage can overwrite unread input, if an output escapes
  past the documented lifetime, or if a size limit is checked after allocation.
- Stop if the existing owning API begins returning mutable aliases or if any
  malformed vector changes from rejection to acceptance.
- Stop if reuse requires shared mutable reader/global state.
- Rollback is one atomic commit containing codec/workspace implementation,
  Wide-part integration, focused specs, and these docs.

## Observed verification

- Historical RED: the focused spec failed to compile because
  `CompressedBlock::DecodeWorkspace` was absent.
- Focused workspace suite: **4 examples, 0 failures, 0 errors, 0 pending**.
- Relevant codec/streaming/multipart suite: **41 examples, 0 failures, 0
  errors, 0 pending**.
- Full debug suite: **129 examples, 0 failures, 0 errors, 0 pending**.
- Full release suite: **129 examples, 0 failures, 0 errors, 0 pending**.
- `crystal tool format --check` and `git diff --check`: pass.
- The focused destination tests reject undersized and read-only LZ4 output and
  reject read-only ZSTD output before native decompression.

These signals establish exact supported-codec behavior, operation-local
high-water reuse, explicit borrowed overwrite, owning compatibility, and
repository regression coverage. They do not establish lower query latency,
lower RSS, fewer total GC cycles, or allocation-free execution.

The final adversary review found no blocker in allocation order, in-place
overlap, destination mutability, borrowed lifetime, owning compatibility, or
workspace locality. Caller-forged native pointers and overlapping external
input/output remain outside the admitted API contract. Verdict: **ROBUST**.

## Ledger and seal

- Implementation owners: `src/crystal_click/lz4.cr`,
  `src/crystal_click/zstd.cr`, `src/crystal_click/compressed_block.cr`, and the
  narrow decode call in `src/crystal_click/wide_part.cr`.
- Focused spec owner: `spec/decode_workspace_spec.cr`, with existing codec and
  reader suites as compatibility consumers.
- Source authority: ClickHouse revision
  `066ea77cf4221959f9f8dc615f6ce776521b52ff` demonstrates reusable output and
  staged Multiple decoding. The one-buffer in-place Delta specialization is a
  narrower Crystal design and therefore carries its own overlap falsifier;
  ClickHouse's checksum and padded LZ4 contracts remain outside this frontier.
- Design status: **sealed**.
- Implementation status: **completed + VERIFIED** within the declared scope;
  final adversary verdict **ROBUST**.
