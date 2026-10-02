# W124 stock oracle: independently pinned W115 Object documents transported
# through production frame/mark APIs, then admitted by an isolated stock server.
require "file_utils"
require "json"
require "../src/crystal_click"
require "./w115_json_semantic_vectors"
require "./w116_json_physical_vectors"
require "./w120_structure_vectors"
require "./w121_discriminator_vectors"
require "./w122_bulk_vectors"
require "./w123_object_vectors"

W124_VERSION           = "26.10.1.1201"
W124_BUILD_HASH        = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
W124_EXECUTABLE_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
W124_SETTINGS          = "index_granularity=2, index_granularity_bytes=10485760, enable_mixed_granularity_parts=1, min_rows_for_wide_part=0, min_bytes_for_wide_part=0, compress_marks=0, compress_primary_key=0, min_compress_block_size=0, max_compress_block_size=4096, default_compression_codec='LZ4', object_serialization_version='v3', object_shared_data_serialization_version_for_zero_level_parts='map'"
W124_OUTER_ROWS        = [2_u64, 2_u64, 2_u64, 2_u64]

alias W124PhysicalGrid = Array(Tuple(UInt64, UInt64, UInt64))
alias W124FrameSpan = Tuple(Int64, Int64, Int64, Int64)

class W124Mismatch < Exception
end

def w124_fail(message : String) : NoReturn
  raise W124Mismatch.new(message)
end

def w124_require(condition : Bool, message : String) : Nil
  w124_fail(message) unless condition
end

def w124_run(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: error)
  raise "ClickHouse local query failed: #{error}\n#{query}" unless status.success?
  output.to_s
end

def w124_run_status(binary : String, arguments : Array(String)) : String
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run(binary, arguments, output: output, error: error)
  raise "ClickHouse command failed: #{error}" unless status.success?
  output.to_s
end

def w124_verify_runtime(binary : String, store : String) : Nil
  version = w124_run_status(binary, ["local", "--version"]).strip
  expected = "ClickHouse local version #{W124_VERSION} (official build)."
  w124_require(version == expected, "unexpected ClickHouse version: #{version.inspect}")
  digest = w124_run_status("shasum", ["-a", "256", binary]).split(' ').first? || ""
  w124_require(digest == W124_EXECUTABLE_SHA256, "unexpected ClickHouse executable SHA-256")
  build = w124_run(binary, store,
    "SELECT name || '=' || value FROM system.build_options WHERE name IN ('GIT_HASH', 'VERSION_GITHASH') ORDER BY name FORMAT TSVRaw").lines.map(&.strip)
  w124_require(build == ["GIT_HASH=#{W124_BUILD_HASH}", "VERSION_GITHASH=#{W124_BUILD_HASH}"], "unexpected ClickHouse build identity")
end

def w124_store_child(path : String, store : String, label : String) : String
  real_store = File.realpath(store)
  real_path = File.realpath(path)
  unless real_path.starts_with?(real_store + "/") && !File.symlink?(path)
    w124_fail("#{label}: path escapes isolated store or is a symlink")
  end
  relative = real_path[(real_store.size + 1)..]
  cursor = real_store
  relative.split('/').each do |component|
    cursor = File.join(cursor, component)
    w124_fail("#{label}: symlink in store path") if File.symlink?(cursor)
  end
  real_path
end

def w124_assert_tree(path : String, label : String) : Nil
  w124_require(Dir.exists?(path) && !File.symlink?(path), "#{label}: unsafe/missing directory")
  Dir.children(path).each do |name|
    child = File.join(path, name)
    w124_require(!File.symlink?(child), "#{label}: symlink child #{name.inspect}")
    if Dir.exists?(child)
      w124_assert_tree(child, "#{label}/#{name}")
    else
      w124_require(File.file?(child), "#{label}: non-file child #{name.inspect}")
    end
  end
end

def w124_part(binary : String, store : String, table : String, label : String) : Tuple(String, String)
  rows = w124_run(binary, store,
    "SELECT name, path, part_type, toString(rows) FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").lines
  w124_require(rows.size == 1, "#{label}: expected one active part, got #{rows.size}")
  fields = rows.first.split('\t')
  w124_require(fields.size == 4 && fields[2] == "Wide" && fields[3] == "8", "#{label}: expected Wide eight-row part")
  {fields[0], w124_store_child(fields[1], store, "#{label} part")}
end

def w124_assert_check(actual : String, part_name : String, label : String) : Nil
  expected = "#{part_name}\t1\t\n"
  w124_fail("#{label}: CHECK output mismatch: #{actual.inspect}") unless actual == expected
end

def w124_read_u32(bytes : Bytes, offset : Int32) : UInt32
  bytes[offset].to_u32 |
    (bytes[offset + 1].to_u32 << 8) |
    (bytes[offset + 2].to_u32 << 16) |
    (bytes[offset + 3].to_u32 << 24)
end

def w124_read_u64(bytes : Bytes, offset : Int32) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

def w124_write_u32(bytes : Bytes, offset : Int32, value : UInt32) : Nil
  4.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u32).to_u8 }
end

def w124_write_u64_at(bytes : Bytes, offset : Int32, value : UInt64) : Nil
  8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

def w124_write_u64(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
end

def w124_write_hash(io : IO, hash : {UInt64, UInt64}) : Nil
  w124_write_u64(io, hash[0])
  w124_write_u64(io, hash[1])
end

def w124_write_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

# Independent literal-only LZ4 used only for the ClickHouse checksums.txt
# envelope. JSON lane framing itself always comes from CompressedMarkWriter.
def w124_literal_lz4_frame(raw : Bytes) : Bytes
  raise "cannot encode an empty W124 checksum frame" if raw.empty?
  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w124_write_u32(frame, header + 1, compressed_size.to_u32)
  w124_write_u32(frame, header + 5, raw.size.to_u32)
  cursor = CrystalClick::CompressedBlock::FRAME_HEADER_SIZE
  if raw.size < 15
    frame[cursor] = (raw.size << 4).to_u8
    cursor += 1
  else
    frame[cursor] = 0xf0_u8
    cursor += 1
    remaining = raw.size - 15
    while remaining >= 255
      frame[cursor] = 255_u8
      cursor += 1
      remaining -= 255
    end
    frame[cursor] = remaining.to_u8
    cursor += 1
  end
  raw.copy_to(frame[cursor, raw.size])
  hash = CrystalClick::CityHashV1.hash128(frame[header, compressed_size])
  w124_write_u64_at(frame, 0, hash[0])
  w124_write_u64_at(frame, 8, hash[1])
  frame
end

def w124_assert_bytes(actual : Bytes, expected : Bytes, label : String) : Nil
  w124_fail("#{label}: byte vector differs (#{actual.size} vs #{expected.size})") unless actual == expected
end

def w124_assert_grid(actual : W124PhysicalGrid, expected : W124PhysicalGrid, label : String) : Nil
  w124_fail("#{label}: semantic mark grid differs") unless actual == expected
end

def w124_read_physical_grid(path : String) : W124PhysicalGrid
  bytes = File.read(path).to_slice
  w124_require(bytes.size % 24 == 0, "mark file is not a sequence of 24-byte records")
  grid = [] of Tuple(UInt64, UInt64, UInt64)
  (bytes.size // 24).times do |index|
    offset = index * 24
    grid << {w124_read_u64(bytes, offset), w124_read_u64(bytes, offset + 8), w124_read_u64(bytes, offset + 16)}
  end
  grid
end

# This oracle computes every frame boundary itself from the on-disk headers.
# CompressedBlock.decode_frame is only the codec primitive; the W124 production
# frame index is deliberately not used to establish logical mark positions.
def w124_independent_frames(data : Bytes) : Tuple(Array(W124FrameSpan), Bytes)
  spans = [] of W124FrameSpan
  decoded = IO::Memory.new
  compressed_offset = 0_i64
  logical_offset = 0_i64
  while compressed_offset < data.size.to_i64
    unless compressed_offset <= data.size.to_i64 - CrystalClick::CompressedBlock::FRAME_HEADER_SIZE
      w124_fail("independent frame walk found a truncated header")
    end
    header = compressed_offset.to_i + CrystalClick::CompressedBlock::CHECKSUM_SIZE
    compressed_size = w124_read_u32(data, header + 1).to_i64
    decompressed_size = w124_read_u32(data, header + 5).to_i64
    frame_end = compressed_offset + CrystalClick::CompressedBlock::CHECKSUM_SIZE + compressed_size
    w124_require(frame_end <= data.size.to_i64, "independent frame walk found a truncated payload")
    frame = CrystalClick::CompressedBlock.decode_frame(data, compressed_offset)
    w124_require(frame.end_offset == frame_end, "independent frame decoder disagrees with parsed boundary")
    w124_require(frame.output.size.to_i64 == decompressed_size, "independent frame output size differs from header")
    spans << {compressed_offset, frame_end, logical_offset, logical_offset + decompressed_size}
    decoded.write(frame.output)
    compressed_offset = frame_end
    logical_offset += decompressed_size
  end
  w124_require(compressed_offset == data.size.to_i64, "independent frame walk left trailing bytes")
  {spans, decoded.to_slice}
end

def w124_map_mark_coordinate(
  compressed_offset : UInt64,
  decompressed_offset : UInt64,
  file_size : Int64,
  spans : Array(W124FrameSpan),
  logical_size : Int64,
) : UInt64
  # Real rows may point at physical EOF when their lane is empty in the
  # trailing granule; the terminal sentinel uses the same logical coordinate.
  if compressed_offset == file_size.to_u64 && decompressed_offset == 0_u64
    return logical_size.to_u64
  end

  spans.each do |(frame_start, frame_end, logical_start, logical_end)|
    frame_size = (logical_end - logical_start).to_u64
    if compressed_offset == frame_start.to_u64 && decompressed_offset <= frame_size
      return logical_start.to_u64 + decompressed_offset
    end
  end

  raise W124Mismatch.new("physical mark coordinate does not name a frame boundary")
end

def w124_assert_physical_grid(
  actual : W124PhysicalGrid,
  data_size : Int64,
  spans : Array(W124FrameSpan),
  raw_size : Int64,
  expected : W124PhysicalGrid,
  label : String,
) : Nil
  w124_require(actual.size == expected.size, "#{label}: mark record count differs")
  actual.each_with_index do |(compressed, decompressed, rows), index|
    logical = w124_map_mark_coordinate(compressed, decompressed, data_size, spans, raw_size)
    expected_logical = expected[index][1]
    expected_rows = expected[index][2]
    unless logical == expected_logical && rows == expected_rows
      w124_fail("#{label}: physical mark #{index} maps to (#{logical},#{rows}), expected (#{expected_logical},#{expected_rows})")
    end
  end
end

def w124_frame_and_grid(
  profile : String,
  part : String,
  logical : String,
  expected_raw : Bytes,
  expected_grid : W124PhysicalGrid,
  semantic_metadata : Bool = false,
) : Tuple(Bytes, W124PhysicalGrid)
  hash = CrystalClick::StreamName.hash(logical)
  bin_path = File.join(part, "#{hash}.bin")
  marks_path = File.join(part, "#{hash}.mrk2")
  w124_require(File.file?(bin_path) && !File.symlink?(bin_path), "#{logical}: unsafe/missing .bin")
  w124_require(File.file?(marks_path) && !File.symlink?(marks_path), "#{logical}: unsafe/missing .mrk2")
  physical = File.read(bin_path).to_slice
  actual_grid = w124_read_physical_grid(marks_path)
  spans, raw = w124_independent_frames(physical)
  if semantic_metadata && (logical == "payload.object_structure" || logical.ends_with?(".dynamic_structure"))
    W116JsonPhysicalVectors.assert_stream_raw(profile, logical, raw)
  else
    w124_assert_bytes(raw, expected_raw, "#{logical} independently decoded raw bytes")
  end
  w124_assert_physical_grid(actual_grid, physical.size.to_i64, spans, raw.size.to_i64, expected_grid, logical)
  {raw, actual_grid}
end

def w124_path_from_logical(profile : String, logical : String) : String?
  W120StructureVectors.dynamic_paths(profile).find do |path|
    prefix = "payload.#{W120StructureVectors.physical_path(path)}"
    logical.starts_with?(prefix + ".")
  end
end

def w124_expected_raw(profile : String, logical : String, mode : UInt64) : Bytes
  if logical == "payload.object_structure"
    W120StructureVectors.object_bytes(W120StructureVectors.expected_set(profile).object)
  elsif logical.ends_with?(".dynamic_structure")
    path = w124_path_from_logical(profile, logical) || w124_fail("#{logical}: no W124 Dynamic path")
    W120StructureVectors.dynamic_bytes(W120StructureVectors.expected_set(profile).dynamics[path])
  elsif logical.ends_with?(".variant_discr")
    path = w124_path_from_logical(profile, logical) || w124_fail("#{logical}: no W124 discriminator path")
    W121DiscriminatorVectors.stream_bytes(profile, path, mode)
  else
    W116JsonPhysicalVectors.expected_raw_stream(profile, logical)
  end
end

def w124_expected_grid(profile : String, logical : String, mode : UInt64) : W124PhysicalGrid
  if logical.ends_with?(".variant_discr")
    path = w124_path_from_logical(profile, logical) || w124_fail("#{logical}: no W124 discriminator path")
    offsets = W121DiscriminatorVectors.mark_offsets(profile, path, mode)
    Array(Tuple(UInt64, UInt64, UInt64)).new(5) do |index|
      rows = index < 4 ? W124_OUTER_ROWS[index] : 0_u64
      {0_u64, offsets[index], rows}
    end
  else
    W116JsonPhysicalVectors.expected_mark_grid(profile, logical)
  end
end

def w124_assert_expected_stream(profile : String, logical : String, actual : Bytes, mode : UInt64, label : String) : Nil
  expected = w124_expected_raw(profile, logical, mode)
  if logical == "payload.object_structure" || logical.ends_with?(".dynamic_structure")
    W116JsonPhysicalVectors.assert_stream_raw(profile, logical, actual)
  end
  w124_assert_bytes(actual, expected, label)
end

def w124_outer_grid(offsets : Array(UInt64)) : W124PhysicalGrid
  w124_require(offsets.size == 5, "W124 expected four data marks plus terminal")
  Array(Tuple(UInt64, UInt64, UInt64)).new(5) do |index|
    rows = index < 4 ? W124_OUTER_ROWS[index] : 0_u64
    {0_u64, offsets[index], rows}
  end
end

def w124_encoded_bulk_for(profile : String, logical : String, streams : CrystalClick::ObjectDocumentStreams) : CrystalClick::BinaryBulkStream
  return streams.typed_for("a").stream("root.data") if logical == "payload.a"

  shared_logicals = {
    "payload.object_shared_data.size0"    => "root.sizes",
    "payload.object_shared_data%2Epaths"  => "root.elements.field.0.data",
    "payload.object_shared_data%2Evalues" => "root.elements.field.1.data",
  }
  if role = shared_logicals[logical]?
    return streams.shared.stream(role)
  end

  path = w124_path_from_logical(profile, logical) || w124_fail("#{logical}: no encoded Dynamic path")
  structure = W122BulkVectors.structure(profile, path)
  W122BulkVectors.arm_names(structure).each do |arm_name|
    W122BulkVectors.role_streams(profile, path, arm_name).each do |role, candidate_logical|
      return streams.dynamic_for(path).arm(arm_name).stream(role) if candidate_logical == logical
    end
  end
  w124_fail("#{logical}: no encoded bulk role")
end

def w124_encoded_raw(profile : String, logical : String, streams : CrystalClick::ObjectDocumentStreams) : Bytes
  if logical == "payload.object_structure"
    streams.structures.object
  elsif logical.ends_with?(".dynamic_structure")
    path = w124_path_from_logical(profile, logical) || w124_fail("#{logical}: no metadata Dynamic path")
    streams.structures.dynamics[path]? || w124_fail("#{logical}: encoded Dynamic metadata is absent")
  elsif logical.ends_with?(".variant_discr")
    path = w124_path_from_logical(profile, logical) || w124_fail("#{logical}: no discriminator Dynamic path")
    streams.dynamic_for(path).discriminators.bytes
  else
    w124_encoded_bulk_for(profile, logical, streams).bytes
  end
end

def w124_encoded_grid(profile : String, logical : String, streams : CrystalClick::ObjectDocumentStreams) : W124PhysicalGrid
  if logical.ends_with?(".variant_discr")
    discriminator = streams.dynamic_for(w124_path_from_logical(profile, logical).not_nil!).discriminators
    Array(Tuple(UInt64, UInt64, UInt64)).new(5) do |index|
      mark = discriminator.mark_at(index)
      {0_u64, mark.offset, mark.rows}
    end
  elsif logical == "payload.object_structure" || logical.ends_with?(".dynamic_structure")
    W116JsonPhysicalVectors.expected_mark_grid(profile, logical)
  else
    w124_outer_grid(w124_encoded_bulk_for(profile, logical, streams).offsets)
  end
end

def w124_typed_schema(profile : String) : Hash(String, CrystalClick::BinaryDataType)
  if profile == "typed_mixed"
    {"a" => CrystalClick::BinaryDataType.primitive("UInt64")}
  else
    {} of String => CrystalClick::BinaryDataType
  end
end

def w124_assert_documents(expected : Array(CrystalClick::ObjectDocument), actual : Array(CrystalClick::ObjectDocument), label : String) : Nil
  w124_require(expected.size == actual.size, "#{label}: document count differs (#{actual.size} vs #{expected.size})")
  expected.each_with_index do |document, row_index|
    actual_document = actual[row_index]
    paths = document.paths
    unless paths == actual_document.paths
      w124_fail("#{label}: flattened path identities differ at row #{row_index}")
    end
    paths.each do |path|
      expected_value = document.value_for(path)
      actual_value = actual_document.value_for(path)
      unless W122BulkVectors.value_equal?(expected_value, actual_value)
        w124_fail("#{label}: nominal value differs at row #{row_index}, path #{path.inspect}")
      end
    end
  end
end

def w124_decode_assert(profile : String, streams : CrystalClick::ObjectDocumentStreams, first_mark : Int32, mark_count : Int32, label : String) : Nil
  expected_all = W123ObjectVectors.flat_documents(profile)
  expected = if mark_count == 4 && first_mark == 0
               expected_all
             else
               expected_all[first_mark * 2, mark_count * 2]
             end
  actual = CrystalClick::ObjectDocumentCodec.decode(
    w124_typed_schema(profile), streams, first_mark: 0, mark_count: mark_count,
    profile: CrystalClick::BinaryBulkProfile.with_size_stream,
    shared_profile: CrystalClick::BinaryBulkProfile.single_stream
  ).flatten
  w124_assert_documents(expected, actual, label)
end

def w124_shared_roles : Array(Tuple(String, String))
  [
    {"root.sizes", "payload.object_shared_data.size0"},
    {"root.elements.field.0.data", "payload.object_shared_data%2Epaths"},
    {"root.elements.field.1.data", "payload.object_shared_data%2Evalues"},
  ]
end

def w124_compressed_paths(part : String, logical : String) : Tuple(String, String)
  hash = CrystalClick::StreamName.hash(logical)
  {File.join(part, "#{hash}.bin"), File.join(part, "#{hash}.mrk2")}
end

def w124_assert_window(
  profile : String,
  logical : String,
  raw : Bytes,
  grid : W124PhysicalGrid,
  first_mark : Int32,
  mark_count : Int32,
  window : CrystalClick::CompressedMarkWindow,
  label : String,
) : Nil
  prefix = grid.first[1].to_i
  if logical.ends_with?(".variant_discr")
    w124_require(prefix == 8, "#{label}: Dynamic discriminator prefix must be eight bytes")
  end
  start_offset = grid[first_mark][1].to_i
  end_offset = grid[first_mark + mark_count][1].to_i
  w124_require(prefix <= start_offset && end_offset <= raw.size, "#{label}: selected logical range is outside raw lane")
  expected_bytes = Bytes.new(prefix + end_offset - start_offset, 0_u8)
  raw[0, prefix].copy_to(expected_bytes[0, prefix]) if prefix > 0
  body_size = end_offset - start_offset
  raw[start_offset, body_size].copy_to(expected_bytes[prefix, body_size]) if body_size > 0
  w124_assert_bytes(window.bytes, expected_bytes, "#{label} W124 detached local bytes")

  expected_offsets = Array(UInt64).new(mark_count + 1) do |index|
    prefix.to_u64 + (grid[first_mark + index][1] - grid[first_mark][1])
  end
  w124_require(window.offsets == expected_offsets, "#{label}: normalized local offsets differ")
  w124_require(window.first_mark == first_mark && window.prefix_size == prefix, "#{label}: window metadata differs")
  w124_require(window.rows_per_mark == grid[first_mark, mark_count].map(&.[2]), "#{label}: selected row counts differ")
end

def w124_read_window(
  part : String,
  profile : String,
  logical : String,
  first_mark : Int32,
  mark_count : Int32,
  mode : UInt64,
  budget : CrystalClick::CompressedStreamBudget,
  label : String,
) : CrystalClick::CompressedMarkWindow
  raw_expected = w124_expected_raw(profile, logical, mode)
  logical_grid = w124_expected_grid(profile, logical, mode)
  raw, _grid = w124_frame_and_grid(profile, part, logical, raw_expected, logical_grid)
  data_path, marks_path = w124_compressed_paths(part, logical)
  window = CrystalClick::CompressedMarkReader.read(
    data_path, marks_path,
    expected_data_size: File.size(data_path), expected_mark_size: File.size(marks_path),
    first_mark: first_mark, mark_count: mark_count,
    prefix_size: logical_grid.first[1].to_i, budget: budget
  )
  w124_assert_window(profile, logical, raw, logical_grid, first_mark, mark_count, window, "#{label} #{logical}")
  window
end

def w124_read_all_lane(
  part : String,
  profile : String,
  logical : String,
  mode : UInt64,
  budget : CrystalClick::CompressedStreamBudget,
  label : String,
  semantic_metadata : Bool = false,
) : Bytes
  expected = w124_expected_raw(profile, logical, mode)
  raw, _grid = w124_frame_and_grid(profile, part, logical, expected,
    w124_expected_grid(profile, logical, mode), semantic_metadata: semantic_metadata)
  data_path, _ = w124_compressed_paths(part, logical)
  physical = File.read(data_path).to_slice
  w124_require(!physical.empty?, "#{label} #{logical}: unmarked metadata lane cannot use read_all on an empty file")
  actual = CrystalClick::CompressedMarkReader.read_all(data_path, expected_size: physical.size.to_i64, budget: budget)
  w124_assert_bytes(actual, raw, "#{label} #{logical} read_all vs independent frame decode")
  actual
end

def w124_bulk_set(
  profile : String,
  roles : Array(Tuple(String, String)),
  part : String,
  first_mark : Int32,
  mark_count : Int32,
  mode : UInt64,
  budget : CrystalClick::CompressedStreamBudget,
  label : String,
) : CrystalClick::BinaryBulkStreams
  streams = {} of String => CrystalClick::BinaryBulkStream
  roles.each do |role, logical|
    window = w124_read_window(part, profile, logical, first_mark, mark_count, mode, budget, label)
    streams[role] = CrystalClick::BinaryBulkStream.new(window.bytes, window.offsets)
  end
  CrystalClick::BinaryBulkStreams.new(mark_count, streams)
end

def w124_dynamic_stream_from_part(
  profile : String,
  path : String,
  part : String,
  first_mark : Int32,
  mark_count : Int32,
  mode : UInt64,
  budget : CrystalClick::CompressedStreamBudget,
  label : String,
) : CrystalClick::DynamicValueStreams
  structure = W122BulkVectors.structure(profile, path)
  arms = {} of String => CrystalClick::BinaryBulkStreams
  W122BulkVectors.arm_names(structure).each do |arm_name|
    arms[arm_name] = w124_bulk_set(profile, W122BulkVectors.role_streams(profile, path, arm_name), part,
      first_mark, mark_count, mode, budget, "#{label} #{arm_name}")
  end

  logical = "payload.#{W120StructureVectors.physical_path(path)}.variant_discr"
  window = w124_read_window(part, profile, logical, first_mark, mark_count, mode, budget, label)
  marks = Array(CrystalClick::DynamicDiscriminatorMark).new(mark_count + 1) do |index|
    rows = index < mark_count ? window.rows_per_mark[index] : 0_u64
    CrystalClick::DynamicDiscriminatorMark.new(window.offsets[index], rows)
  end
  discriminator = CrystalClick::DynamicDiscriminatorStream.new(window.bytes, marks)
  CrystalClick::DynamicValueStreams.new(discriminator, arms)
end

def w124_streams_from_part(
  profile : String,
  part : String,
  first_mark : Int32,
  mark_count : Int32,
  mode : UInt64,
  label : String,
  semantic_metadata : Bool = false,
) : CrystalClick::ObjectDocumentStreams
  budget = CrystalClick::CompressedStreamBudget.read_default
  metadata_dynamics = {} of String => Bytes
  W120StructureVectors.dynamic_paths(profile).each do |path|
    logical = "payload.#{W120StructureVectors.physical_path(path)}.dynamic_structure"
    metadata_dynamics[path] = w124_read_all_lane(part, profile, logical, mode, budget, label,
      semantic_metadata: semantic_metadata)
  end
  object_bytes = w124_read_all_lane(part, profile, "payload.object_structure", mode, budget, label,
    semantic_metadata: semantic_metadata)
  structures = CrystalClick::ObjectDynamicStructureStreams.new(object_bytes, metadata_dynamics)

  typed = {} of String => CrystalClick::BinaryBulkStreams
  if profile == "typed_mixed"
    typed["a"] = w124_bulk_set(profile, [{"root.data", "payload.a"}], part,
      first_mark, mark_count, mode, budget, "#{label} typed a")
  end

  dynamics = {} of String => CrystalClick::DynamicValueStreams
  W120StructureVectors.dynamic_paths(profile).each do |path|
    dynamics[path] = w124_dynamic_stream_from_part(profile, path, part, first_mark, mark_count,
      mode, budget, "#{label} Dynamic #{path}")
  end
  shared = w124_bulk_set(profile, w124_shared_roles, part, first_mark, mark_count,
    mode, budget, "#{label} Object shared MAP")
  selected_rows = W124_OUTER_ROWS[first_mark, mark_count]
  CrystalClick::ObjectDocumentStreams.new(structures, selected_rows, typed, dynamics, shared)
end

def w124_rewrite_checksums(part : String, changed_bins : Array(String)) : Nil
  original = CrystalClick::PartChecksums.open(part)
  names = original.entries.keys.sort
  w124_require(!names.empty? && !names.includes?("checksums.txt"), "W124 copy has an invalid checksum inventory")
  changed_bins.each do |name|
    w124_require(names.includes?(name), "W124 changed stream is absent from checksum inventory: #{name}")
  end

  budget = CrystalClick::CompressedStreamBudget.read_default
  payload = IO::Memory.new
  w124_write_varuint(payload, names.size.to_u64)
  names.each do |name|
    w124_require(name == File.basename(name) && name != "." && name != "..", "W124 checksum path is unsafe: #{name.inspect}")
    path = File.join(part, name)
    w124_require(File.file?(path) && !File.symlink?(path), "W124 copied part has unsafe/missing file #{name}")
    physical = File.read(path).to_slice
    entry = original.entry(name) || w124_fail("W124 copied part lost checksum entry #{name}")
    changed = changed_bins.includes?(name)
    w124_require(!changed || entry.compressed, "W124 changed stream is not compressed: #{name}")
    raw = if entry.compressed
            physical.empty? ? Bytes.empty : CrystalClick::CompressedMarkReader.read_all(
              path, expected_size: physical.size.to_i64, budget: budget
            )
          else
            physical
          end
    if entry.compressed && !changed
      expected_size = entry.uncompressed_size || w124_fail("compressed checksum entry #{name} has no raw size")
      w124_require(raw.size.to_u64 == expected_size, "unchanged copied stream raw size differs for #{name}")
    end

    w124_write_varuint(payload, name.bytesize.to_u64)
    payload.write(name.to_slice)
    w124_write_varuint(payload, physical.size.to_u64)
    w124_write_hash(payload, CrystalClick::CityHashV1.file_hash(physical))
    if entry.compressed
      payload.write_byte(1_u8)
      w124_write_varuint(payload, raw.size.to_u64)
      w124_write_hash(payload, CrystalClick::CityHashV1.file_hash(raw))
    else
      payload.write_byte(0_u8)
    end
  end

  manifest = IO::Memory.new
  manifest << CrystalClick::PartChecksums::CHECKSUMS_HEADER
  manifest.write(w124_literal_lz4_frame(payload.to_slice))
  File.write(File.join(part, "checksums.txt"), manifest.to_slice)
  rewritten = CrystalClick::PartChecksums.open(part)
  w124_require(rewritten.entries.keys.sort == names, "W124 rewritten checksum inventory changed")
  names.each { |name| rewritten.validate_selected_entries(part, name) }
end

def w124_profile_table(binary : String, store : String, profile : String, mode_name : String) : String
  table = "w124_#{profile}_#{mode_name}"
  json_type = profile == "typed_mixed" ? "JSON(a UInt64, max_dynamic_paths=1, max_dynamic_types=1)" : "JSON(max_dynamic_paths=16, max_dynamic_types=8)"
  w124_run(binary, store,
    "CREATE TABLE default.#{table} (pk UInt64, payload #{json_type}) ENGINE=MergeTree ORDER BY pk SETTINGS #{W124_SETTINGS}")
  actual = w124_run(binary, store,
    "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw")
  w124_require(actual == W116JsonPhysicalVectors.expected_schema(profile), "#{profile}/#{mode_name}: isolated table schema differs from W115 literal")
  table
end

def w124_attach_path(binary : String, store : String, table : String) : String
  path = w124_run(binary, store,
    "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  w124_store_child(path, store, "W124 #{table} data path")
end

def w124_retained_part(binary : String, store : String, profile : String, attached : Bool) : Tuple(String, String)
  table = "w115_#{profile}_#{attached ? "attached" : "source"}"
  rows = w124_run(binary, store,
    "SELECT name, path, part_type, toString(rows) FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").lines
  w124_require(rows.size == 1, "W115 #{profile} #{table}: expected one active part")
  fields = rows.first.split('\t')
  w124_require(fields.size == 4 && fields[2] == "Wide" && fields[3] == "8", "W115 #{profile} #{table}: expected Wide eight-row part")
  part = w124_store_child(fields[1], store, "W115 #{profile} #{table} part")
  check = w124_run(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated")
  w124_assert_check(check, fields[0], "W115 #{profile} #{table}")
  w124_assert_tree(part, "W115 #{profile} #{table}")
  expected_files = W116JsonPhysicalVectors.expected_files(profile, attached: attached)
  w124_require(Dir.children(part).sort == expected_files, "W115 #{profile} #{table}: stream inventory differs")
  w124_assert_bytes(File.read(File.join(part, "columns.txt")).to_slice,
    W116JsonPhysicalVectors.expected_columns_text(profile).to_slice, "W115 #{profile} #{table} columns")
  {fields[0], part}
end

def w124_assert_nontransport_metadata(part : String, reference : String, profile : String, attached : Bool, label : String) : Nil
  W116JsonPhysicalVectors.expected_files(profile, attached: attached).each do |name|
    next if name == "checksums.txt" || name.ends_with?(".bin") || name.ends_with?(".mrk2")
    w124_assert_bytes(File.read(File.join(part, name)).to_slice,
      File.read(File.join(reference, name)).to_slice, "#{label} unchanged metadata #{name}")
  end
end

def w124_assert_part_transport(
  profile : String,
  part : String,
  mode : UInt64,
  label : String,
  semantic_metadata : Bool = false,
) : Nil
  W116JsonPhysicalVectors.expected_stream_names(profile).each do |logical|
    expected = w124_expected_raw(profile, logical, mode)
    grid = w124_expected_grid(profile, logical, mode)
    metadata_stream = logical == "payload.object_structure" || logical.ends_with?(".dynamic_structure")
    w124_frame_and_grid(profile, part, logical, expected, grid,
      semantic_metadata: semantic_metadata && metadata_stream)
  end
end

def w124_stock_queries(binary : String, store : String, table : String, profile : String, label : String) : Nil
  full_query = "SELECT pk, toJSONString(payload) FROM default.#{table} ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw"
  selected_query = "SELECT pk, toJSONString(payload) FROM default.#{table} WHERE pk >= 3 AND pk <= 6 ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw"
  w115_assert_semantic_documents(w124_run(binary, store, full_query), profile, false, "#{label} full")
  w115_assert_semantic_documents(w124_run(binary, store, selected_query), profile, true, "#{label} pk3..6")
end

def w124_assert_source(profile : String, binary : String, store : String, attached : Bool) : Tuple(String, String)
  name, part = w124_retained_part(binary, store, profile, attached)
  table = "w115_#{profile}_#{attached ? "attached" : "source"}"
  reference = W116JsonPhysicalVectors.fixture_path(profile, attached: attached)
  w124_assert_nontransport_metadata(part, reference, profile, attached, "W115 #{profile}")
  # The captured discriminators are COMPACT; the other W115 physical vectors
  # are mode-independent, and all coordinates are mapped from frame headers.
  w124_assert_part_transport(profile, part, W121DiscriminatorVectors::MODE_COMPACT, "W115 #{profile}",
    semantic_metadata: true)
  w124_decode_assert(profile,
    w124_streams_from_part(profile, part, 0, 4, W121DiscriminatorVectors::MODE_COMPACT, "W115 #{profile}",
      semantic_metadata: true),
    0, 4, "W124 decode retained W115 #{profile}")
  w124_decode_assert(profile,
    w124_streams_from_part(profile, part, 1, 2, W121DiscriminatorVectors::MODE_COMPACT, "W115 selected #{profile}",
      semantic_metadata: true),
    1, 2, "W124 selected retained W115 #{profile}")
  w124_stock_queries(binary, store, table, profile, "W124 retained W115 #{profile}")
  {name, part}
end

def w124_assert_encoded_documents(profile : String, encoded : CrystalClick::ObjectDocumentStreams, label : String) : Nil
  full = CrystalClick::ObjectDocumentCodec.decode(
    w124_typed_schema(profile), encoded, first_mark: 0, mark_count: 4,
    profile: CrystalClick::BinaryBulkProfile.with_size_stream,
    shared_profile: CrystalClick::BinaryBulkProfile.single_stream
  ).flatten
  w124_assert_documents(W123ObjectVectors.flat_documents(profile), full, "#{label} full encode/decode")
  selected = CrystalClick::ObjectDocumentCodec.decode(
    w124_typed_schema(profile), encoded, first_mark: 1, mark_count: 2,
    profile: CrystalClick::BinaryBulkProfile.with_size_stream,
    shared_profile: CrystalClick::BinaryBulkProfile.single_stream
  ).flatten
  w124_assert_documents(W123ObjectVectors.flat_documents(profile)[2, 4], selected, "#{label} pk3..6 encode/decode")
end

def w124_write_transport_stream(
  part : String,
  logical : String,
  raw : Bytes,
  grid : W124PhysicalGrid,
  budget : CrystalClick::CompressedStreamBudget,
  label : String,
) : Bool
  offsets = grid.map(&.[1])
  rows = grid[0, grid.size - 1].map(&.[2])
  prefix = grid.first[1].to_i
  frame_bytes = Math.max(16, prefix)
  files = CrystalClick::CompressedMarkWriter.encode(raw, offsets, rows,
    prefix_size: prefix, frame_bytes: frame_bytes, budget: budget)
  bin_path, marks_path = w124_compressed_paths(part, logical)
  File.write(bin_path, files.data)
  File.write(marks_path, files.marks)
  physical, actual_grid = w124_independent_frames(files.data), w124_read_physical_grid(marks_path)
  spans = physical[0]
  decoded = physical[1]
  w124_assert_bytes(decoded, raw, "#{label} writer frame output")
  w124_assert_physical_grid(actual_grid, files.data.size.to_i64, spans, raw.size.to_i64, grid, "#{label} writer coordinates")
  selected_start = grid[1][1].to_i64
  selected_end = grid[3][1].to_i64
  prefix_end = prefix.to_i64
  touches = spans.count do |(_, _, logical_start, logical_end)|
    prefix_touched = prefix > 0 && logical_start < prefix_end && logical_end > 0
    selected_touched = logical_start < selected_end && logical_end > selected_start
    prefix_touched || selected_touched
  end
  touches > 1
end

def w124_writer_profile(
  binary : String,
  source_store : String,
  source_part_name : String,
  source_part : String,
  temp_root : String,
  profile : String,
  mode : UInt64,
) : Nil
  mode_name = mode == W121DiscriminatorVectors::MODE_BASIC ? "basic" : "compact"
  store = File.join(temp_root, "stores", "#{profile}_#{mode_name}")
  w124_require(!File.exists?(store) && !File.symlink?(File.dirname(store)), "#{profile}/#{mode_name}: store already exists or parent is unsafe")
  FileUtils.mkdir_p(store)
  table = w124_profile_table(binary, store, profile, mode_name)
  detached = File.join(w124_attach_path(binary, store, table), "detached")
  FileUtils.mkdir_p(detached)
  w124_store_child(detached, store, "#{profile}/#{mode_name} detached directory")
  destination = File.join(detached, source_part_name)
  w124_require(!File.exists?(destination) && !File.symlink?(detached), "#{profile}/#{mode_name}: detached destination is occupied or unsafe")
  FileUtils.cp_r(source_part, destination)
  copied = w124_store_child(destination, store, "#{profile}/#{mode_name} copied part")
  w124_assert_tree(copied, "#{profile}/#{mode_name} before reframe")
  inventory_before = Dir.children(copied).sort

  encoded = CrystalClick::ObjectDocumentCodec.encode(
    W123ObjectVectors.plan(profile), W123ObjectVectors.documents(profile), mode: mode,
    profile: CrystalClick::BinaryBulkProfile.with_size_stream,
    shared_profile: CrystalClick::BinaryBulkProfile.single_stream
  )
  w124_require(encoded.rows_per_mark == W124_OUTER_ROWS, "#{profile}/#{mode_name}: production outer mark rows differ")
  w124_assert_encoded_documents(profile, encoded, "W124 production #{profile}/#{mode_name}")

  changed_bins = [] of String
  writer_budget = CrystalClick::CompressedStreamBudget.write_default
  crossing_windows = 0
  prefix8_lanes = 0
  W116JsonPhysicalVectors.expected_stream_names(profile).each do |logical|
    next if logical == "pk"
    raw = w124_encoded_raw(profile, logical, encoded)
    grid = w124_encoded_grid(profile, logical, encoded)
    w124_assert_expected_stream(profile, logical, raw, mode, "#{profile}/#{mode_name} #{logical} independent literal")
    w124_assert_grid(grid, w124_expected_grid(profile, logical, mode), "#{profile}/#{mode_name} #{logical} writer input grid")
    crosses = w124_write_transport_stream(copied, logical, raw, grid, writer_budget, "#{profile}/#{mode_name} #{logical}")
    crossing_windows += 1 if crosses
    if logical.ends_with?(".variant_discr")
      w124_require(grid.first[1] == 8_u64, "#{profile}/#{mode_name} #{logical}: literal prefix is not eight bytes")
      prefix8_lanes += 1
    end
    changed_bins << "#{CrystalClick::StreamName.hash(logical)}.bin"
  end
  w124_require(prefix8_lanes > 0, "#{profile}/#{mode_name}: no Dynamic discriminator prefix-eight lane was exercised")
  w124_require(crossing_windows > 0, "#{profile}/#{mode_name}: no selected two-mark window crossed a 16-byte frame boundary")
  w124_require(changed_bins.uniq.size == changed_bins.size, "#{profile}/#{mode_name}: duplicate transport stream rewrite")
  w124_rewrite_checksums(copied, changed_bins)
  w124_assert_tree(copied, "#{profile}/#{mode_name} after reframe")
  w124_require(Dir.children(copied).sort == inventory_before, "#{profile}/#{mode_name}: part inventory changed during transport rewrite")

  w124_run(binary, store, "ALTER TABLE default.#{table} ATTACH PART '#{source_part_name}'")
  check = w124_run(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated")
  w124_assert_check(check, source_part_name, "W124 #{profile}/#{mode_name} ATTACH")
  attached_name, attached = w124_part(binary, store, table, "W124 #{profile}/#{mode_name} attached part")
  w124_require(attached_name == source_part_name, "#{profile}/#{mode_name}: attached part name changed")
  w124_assert_tree(attached, "#{profile}/#{mode_name} attached part")

  reference_part = W116JsonPhysicalVectors.fixture_path(profile, attached: true)
  expected_files = W116JsonPhysicalVectors.expected_files(profile, attached: true)
  w124_require(Dir.children(attached).sort == expected_files, "#{profile}/#{mode_name}: attached stream inventory differs")
  w124_assert_bytes(File.read(File.join(attached, "columns.txt")).to_slice,
    W116JsonPhysicalVectors.expected_columns_text(profile).to_slice, "#{profile}/#{mode_name} attached columns")
  w124_assert_nontransport_metadata(attached, reference_part, profile, true, "W124 #{profile}/#{mode_name}")
  w124_assert_part_transport(profile, attached, mode, "W124 #{profile}/#{mode_name} attached")
  checksums = CrystalClick::PartChecksums.open(attached)
  checksums.entries.keys.each { |name| checksums.validate_selected_entries(attached, name) }

  w124_decode_assert(profile,
    w124_streams_from_part(profile, attached, 0, 4, mode, "W124 attached #{profile}/#{mode_name}"),
    0, 4, "W124 decode attached #{profile}/#{mode_name}")
  w124_decode_assert(profile,
    w124_streams_from_part(profile, attached, 1, 2, mode, "W124 selected attached #{profile}/#{mode_name}"),
    1, 2, "W124 selected attached #{profile}/#{mode_name}")
  w124_stock_queries(binary, source_store, "w115_#{profile}_source", profile, "W124 retained source #{profile}")
  w124_stock_queries(binary, store, table, profile, "W124 attached #{profile}/#{mode_name}")
  puts "PASS W124 production framed lanes + stock ATTACH/CHECK=1 + flattened full/pk3..6 documents: #{profile}/#{mode_name} part=#{attached_name}"
end

def w124_expect_comparator_controls : Nil
  begin
    w124_assert_bytes(Bytes[0x61_u8, 0x63_u8], Bytes[0x61_u8, 0x62_u8], "W124 wrong raw-byte control")
  rescue error : W124Mismatch
    w124_require(error.message.to_s.starts_with?("W124 wrong raw-byte control: byte vector differs"),
      "W124 raw-byte control failed for an unrelated reason")
  else
    w124_fail("W124 one-byte wrong-literal control was accepted")
  end

  expected_object = W116JsonPhysicalVectors.expected_raw_stream("typed_mixed", "payload.object_structure")
  wrong_object = Bytes.new(expected_object.size) { |index| expected_object[index] }
  wrong_object[wrong_object.size - 1] ^= 1_u8
  begin
    W116JsonPhysicalVectors.assert_stream_raw("typed_mixed", "payload.object_structure", wrong_object)
  rescue error : W116JsonPhysicalMismatch
    w124_require(error.message.to_s.includes?("object_structure differs"),
      "W124 Object-statistic control failed for an unrelated reason")
  else
    w124_fail("W124 wrong Object statistic literal was accepted")
  end

  begin
    w124_assert_check("w124_control_part\t0\t\n", "w124_control_part", "W124 CHECK=0 control")
  rescue error : W124Mismatch
    w124_require(error.message.to_s.starts_with?("W124 CHECK=0 control: CHECK output mismatch"),
      "W124 CHECK control failed for an unrelated reason")
  else
    w124_fail("W124 CHECK=0 control was accepted")
  end

  first = w124_literal_lz4_frame(Bytes[0x41_u8, 0x42_u8])
  second = w124_literal_lz4_frame(Bytes[0x43_u8, 0x44_u8])
  physical = Bytes.new(first.size + second.size)
  first.copy_to(physical[0, first.size])
  second.copy_to(physical[first.size, second.size])
  spans, raw = w124_independent_frames(physical)
  wrong_frame_offset = [{first.size.to_u64, 0_u64, 2_u64}]
  expected_first_frame = [{0_u64, 0_u64, 2_u64}]
  begin
    w124_assert_physical_grid(wrong_frame_offset, physical.size.to_i64, spans,
      raw.size.to_i64, expected_first_frame, "W124 wrong-frame-offset control")
  rescue error : W124Mismatch
    w124_require(error.message.to_s.includes?("physical mark 0 maps to"),
      "W124 wrong-frame-offset control failed for an unrelated reason")
  else
    w124_fail("W124 mark at the second frame boundary was accepted as logical offset zero")
  end
  puts "PASS W124 wrong-byte, altered Object statistic, wrong-frame-offset and CHECK=0 comparator controls"
end

def w124_check : Nil
  binary = ENV["CLICKHOUSE_BIN"]? || raise "CLICKHOUSE_BIN is required"
  capture_root = ENV["W115_CAPTURE_ROOT"]? || raise "W115_CAPTURE_ROOT is required"
  temp_root = ENV["W124_TMP_ROOT"]? || raise "W124_TMP_ROOT is required"
  capture_root = File.realpath(capture_root)
  temp_root = File.realpath(temp_root)
  w124_require(capture_root.starts_with?("/private/tmp/crystal-click-json-w115.") && !File.symlink?(capture_root),
    "unsafe W115 capture root")
  w124_require(temp_root.starts_with?("/private/tmp/crystal-click-json-w124.") && !File.symlink?(temp_root),
    "unsafe W124 temporary root")
  source_store = File.realpath(File.join(capture_root, "store"))
  w124_require(source_store.starts_with?(capture_root + "/") && !File.symlink?(File.join(capture_root, "store")),
    "unsafe W115 source store")
  w124_require(File.file?(File.join(capture_root, "capture.log")) && !File.symlink?(File.join(capture_root, "capture.log")),
    "W115 capture log is missing or unsafe")
  w124_require(File.file?(File.join(capture_root, "input.jsonl")) && !File.symlink?(File.join(capture_root, "input.jsonl")),
    "W115 literal input is missing or unsafe")
  w124_require(Dir.empty?(temp_root), "W124 temporary root must be fresh and empty")

  w124_verify_runtime(binary, source_store)
  w124_expect_comparator_controls
  w124_require(W123ObjectVectors::PROFILES.to_a.sort == ["dynamic_paths", "typed_mixed"].sort,
    "W124 independent literal profile inventory changed")
  w124_require(W115_SEMANTIC_PAYLOADS.size == 8, "W124 W115 semantic literal row inventory changed")

  source_parts = {} of String => Tuple(String, String)
  {"dynamic_paths", "typed_mixed"}.each do |profile|
    {false, true}.each do |attached|
      name, part = w124_assert_source(profile, binary, source_store, attached)
      if attached
        source_name = source_parts[profile]?.try(&.[0]) || w124_fail("W115 #{profile}: source part was not inspected first")
        w124_require(source_name == name, "W115 #{profile}: source and fresh-ATTACH part names differ")
      else
        source_parts[profile] = {name, part}
      end
    end
  end
  puts "PASS W124 detached-frame reader against retained W115 source and fresh ATTACH parts"

  {"dynamic_paths", "typed_mixed"}.each do |profile|
    source_part_name, source_part = source_parts[profile]
    {W121DiscriminatorVectors::MODE_BASIC, W121DiscriminatorVectors::MODE_COMPACT}.each do |mode|
      w124_writer_profile(binary, source_store, source_part_name, source_part, temp_root, profile, mode)
    end
  end
  puts "PASS W124 scope: W115 Object profiles with independent raw vectors; no all-type or whole-JSON facade claim"
end

w124_check
