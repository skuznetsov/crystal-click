# W123 stock oracle for paired flattened Object documents. Expected documents,
# metadata and child lane vectors come from independent W115/W116/W120/W121/
# W122 literals; production output is only the candidate under comparison.
require "file_utils"
require "../src/crystal_click"
require "./w115_json_semantic_vectors"
require "./w116_json_physical_vectors"
require "./w120_structure_vectors"
require "./w121_discriminator_vectors"
require "./w122_bulk_vectors"
require "./w123_object_vectors"

W123_VERSION           = "26.10.1.1201"
W123_BUILD_HASH        = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
W123_EXECUTABLE_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
W123_SETTINGS          = "index_granularity=2, index_granularity_bytes=10485760, enable_mixed_granularity_parts=1, min_rows_for_wide_part=0, min_bytes_for_wide_part=0, compress_marks=0, compress_primary_key=0, min_compress_block_size=0, max_compress_block_size=4096, default_compression_codec='LZ4', object_serialization_version='v3', object_shared_data_serialization_version_for_zero_level_parts='map'"
W123_OUTER_ROWS        = [2_u64, 2_u64, 2_u64, 2_u64]

class W123Mismatch < Exception
end

def w123_fail(message : String) : NoReturn
  raise W123Mismatch.new(message)
end

def w123_require(condition : Bool, message : String) : Nil
  w123_fail(message) unless condition
end

def w123_run(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: error)
  raise "ClickHouse local query failed: #{error}\n#{query}" unless status.success?
  output.to_s
end

def w123_run_status(binary : String, arguments : Array(String)) : String
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run(binary, arguments, output: output, error: error)
  raise "ClickHouse command failed: #{error}" unless status.success?
  output.to_s
end

def w123_verify_runtime(binary : String, store : String) : Nil
  version = w123_run_status(binary, ["local", "--version"]).strip
  expected = "ClickHouse local version #{W123_VERSION} (official build)."
  w123_require(version == expected, "unexpected ClickHouse version: #{version.inspect}")
  digest = w123_run_status("shasum", ["-a", "256", binary]).split(' ').first? || ""
  w123_require(digest == W123_EXECUTABLE_SHA256, "unexpected ClickHouse executable SHA-256")
  build = w123_run(binary, store,
    "SELECT name || '=' || value FROM system.build_options WHERE name IN ('GIT_HASH', 'VERSION_GITHASH') ORDER BY name FORMAT TSVRaw").lines.map(&.strip)
  w123_require(build == ["GIT_HASH=#{W123_BUILD_HASH}", "VERSION_GITHASH=#{W123_BUILD_HASH}"], "unexpected ClickHouse build identity")
end

def w123_store_child(path : String, store : String, label : String) : String
  real_store = File.realpath(store)
  real_path = File.realpath(path)
  unless real_path.starts_with?(real_store + "/") && !File.symlink?(path)
    w123_fail("#{label}: path escapes isolated store or is a symlink")
  end
  relative = real_path[(real_store.size + 1)..]
  cursor = real_store
  relative.split('/').each do |component|
    cursor = File.join(cursor, component)
    w123_fail("#{label}: symlink in store path") if File.symlink?(cursor)
  end
  real_path
end

def w123_assert_tree(path : String, label : String) : Nil
  w123_require(Dir.exists?(path) && !File.symlink?(path), "#{label}: unsafe/missing directory")
  Dir.children(path).each do |name|
    child = File.join(path, name)
    w123_require(!File.symlink?(child), "#{label}: symlink child #{name.inspect}")
    if Dir.exists?(child)
      w123_assert_tree(child, "#{label}/#{name}")
    else
      w123_require(File.file?(child), "#{label}: non-file child #{name.inspect}")
    end
  end
end

def w123_part(binary : String, store : String, table : String, label : String) : Tuple(String, String)
  rows = w123_run(binary, store,
    "SELECT name, path, part_type, toString(rows) FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").lines
  w123_require(rows.size == 1, "#{label}: expected exactly one active part, got #{rows.size}")
  fields = rows.first.split('\t')
  w123_require(fields.size == 4 && fields[2] == "Wide" && fields[3] == "8", "#{label}: expected one Wide eight-row part")
  {fields[0], w123_store_child(fields[1], store, "#{label} part")}
end

def w123_assert_check(actual : String, part_name : String, label : String) : Nil
  expected = "#{part_name}\t1\t\n"
  w123_fail("#{label}: CHECK output mismatch: #{actual.inspect}") unless actual == expected
end

def w123_read_compressed(part : String, logical : String) : Bytes
  name = "#{CrystalClick::StreamName.hash(logical)}.bin"
  path = File.join(part, name)
  w123_require(File.file?(path) && !File.symlink?(path), "#{logical}: unsafe/missing .bin")
  physical = File.read(path).to_slice
  physical.empty? ? Bytes.empty : CrystalClick::CompressedBlock.decode_all(physical)
end

def w123_read_u64_at(bytes : Bytes, offset : Int32) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

def w123_write_u32_le(bytes : Bytes, offset : Int32, value : UInt32) : Nil
  4.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u32).to_u8 }
end

def w123_write_u64_at(bytes : Bytes, offset : Int32, value : UInt64) : Nil
  8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

def w123_write_u64(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
end

def w123_write_hash128(bytes : Bytes, offset : Int32, hash : {UInt64, UInt64}) : Nil
  w123_write_u64_at(bytes, offset, hash[0])
  w123_write_u64_at(bytes, offset + 8, hash[1])
end

def w123_write_hash128(io : IO, hash : {UInt64, UInt64}) : Nil
  w123_write_u64(io, hash[0])
  w123_write_u64(io, hash[1])
end

def w123_write_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

def w123_read_marks(part : String, logical : String) : Array(Tuple(UInt64, UInt64, UInt64))
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical)}.mrk2")
  w123_require(File.file?(path) && !File.symlink?(path), "#{logical}: unsafe/missing .mrk2")
  bytes = File.read(path).to_slice
  w123_require(bytes.size == 120 && bytes.size % 24 == 0, "#{logical}: expected five plain Wide marks")
  Array(Tuple(UInt64, UInt64, UInt64)).new(5) do |index|
    offset = index * 24
    {w123_read_u64_at(bytes, offset), w123_read_u64_at(bytes, offset + 8), w123_read_u64_at(bytes, offset + 16)}
  end
end

def w123_assert_bytes(actual : Bytes, expected : Bytes, label : String) : Nil
  w123_fail("#{label}: raw byte vector differs (#{actual.size} vs #{expected.size})") unless actual == expected
end

def w123_assert_grid(actual : Array(Tuple(UInt64, UInt64, UInt64)), expected : Array(Tuple(UInt64, UInt64, UInt64)), label : String) : Nil
  w123_fail("#{label}: physical mark grid differs") unless actual == expected
end

def w123_outer_grid(offsets : Array(UInt64)) : Array(Tuple(UInt64, UInt64, UInt64))
  w123_require(offsets.size == 5, "W123 lane must expose four marks plus terminal offset")
  Array(Tuple(UInt64, UInt64, UInt64)).new(5) do |index|
    rows = index < 4 ? W123_OUTER_ROWS[index] : 0_u64
    {0_u64, offsets[index], rows}
  end
end

def w123_literal_lz4_frame(raw : Bytes) : Bytes
  raise "cannot encode an empty W123 LZ4 frame" if raw.empty?
  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w123_write_u32_le(frame, header + 1, compressed_size.to_u32)
  w123_write_u32_le(frame, header + 5, raw.size.to_u32)
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
  w123_write_hash128(frame, 0, CrystalClick::CityHashV1.hash128(frame[header, compressed_size]))
  frame
end

def w123_rewrite_checksums(part : String, changed_bins : Array(String)) : Nil
  original = CrystalClick::PartChecksums.open(part)
  names = original.entries.keys.sort
  w123_require(!names.empty? && !names.includes?("checksums.txt"), "W123 copy has unexpected checksum inventory")
  changed_bins.each do |name|
    w123_require(names.includes?(name), "W123 changed stream is absent from checksum inventory: #{name}")
  end

  payload = IO::Memory.new
  w123_write_varuint(payload, names.size.to_u64)
  names.each do |name|
    w123_require(name == File.basename(name) && name != "." && name != "..", "W123 checksum entry has unsafe path #{name.inspect}")
    path = File.join(part, name)
    w123_require(File.file?(path) && !File.symlink?(path), "W123 copied part has unsafe/missing file #{name}")
    physical = File.read(path).to_slice
    entry = original.entry(name) || w123_fail("W123 copied part lost checksum entry #{name}")
    changed = changed_bins.includes?(name)
    w123_require(!changed || entry.compressed, "W123 changed stream is not compressed: #{name}")
    raw = if entry.compressed
            physical.empty? ? Bytes.empty : CrystalClick::CompressedBlock.decode_all(physical)
          else
            physical
          end
    if entry.compressed && !changed
      expected_size = entry.uncompressed_size || w123_fail("compressed checksum entry #{name} has no raw size")
      w123_require(raw.size.to_u64 == expected_size, "unchanged copied stream raw size differs from checksum entry #{name}")
    end

    w123_write_varuint(payload, name.bytesize.to_u64)
    payload.write(name.to_slice)
    w123_write_varuint(payload, physical.size.to_u64)
    w123_write_hash128(payload, CrystalClick::CityHashV1.file_hash(physical))
    if entry.compressed
      payload.write_byte(1_u8)
      w123_write_varuint(payload, raw.size.to_u64)
      w123_write_hash128(payload, CrystalClick::CityHashV1.file_hash(raw))
    else
      payload.write_byte(0_u8)
    end
  end

  manifest = IO::Memory.new
  manifest << CrystalClick::PartChecksums::CHECKSUMS_HEADER
  manifest.write(w123_literal_lz4_frame(payload.to_slice))
  File.write(File.join(part, "checksums.txt"), manifest.to_slice)
  rewritten = CrystalClick::PartChecksums.open(part)
  w123_require(rewritten.entries.keys.sort == names, "W123 rewritten checksum inventory changed")
  names.each { |name| rewritten.validate_selected_entries(part, name) }
end

def w123_structure_raw(profile : String, path : String? = nil) : Bytes
  set = W120StructureVectors.expected_set(profile)
  if path
    dynamic = set.dynamics[path]? || w123_fail("#{profile}: no literal Dynamic structure for #{path.inspect}")
    W120StructureVectors.dynamic_bytes(dynamic)
  else
    W120StructureVectors.object_bytes(set.object)
  end
end

def w123_path_from_logical(profile : String, logical : String) : String?
  W120StructureVectors.dynamic_paths(profile).find do |path|
    prefix = "payload.#{W120StructureVectors.physical_path(path)}"
    logical.starts_with?(prefix + ".")
  end
end

def w123_expected_raw(profile : String, logical : String, mode : UInt64) : Bytes
  if logical == "payload.object_structure"
    w123_structure_raw(profile)
  elsif logical.ends_with?(".dynamic_structure")
    path = w123_path_from_logical(profile, logical) || w123_fail("#{logical}: no W123 Dynamic path")
    w123_structure_raw(profile, path)
  elsif logical.ends_with?(".variant_discr")
    path = w123_path_from_logical(profile, logical) || w123_fail("#{logical}: no W123 discriminator path")
    W121DiscriminatorVectors.stream_bytes(profile, path, mode)
  else
    W116JsonPhysicalVectors.expected_raw_stream(profile, logical)
  end
end

def w123_expected_grid(profile : String, logical : String, mode : UInt64) : Array(Tuple(UInt64, UInt64, UInt64))
  if logical.ends_with?(".variant_discr")
    path = w123_path_from_logical(profile, logical) || w123_fail("#{logical}: no W123 discriminator path")
    offsets = W121DiscriminatorVectors.mark_offsets(profile, path, mode)
    Array(Tuple(UInt64, UInt64, UInt64)).new(5) do |index|
      rows = index < 4 ? W123_OUTER_ROWS[index] : 0_u64
      {0_u64, offsets[index], rows}
    end
  else
    W116JsonPhysicalVectors.expected_mark_grid(profile, logical)
  end
end

def w123_assert_expected_stream(profile : String, logical : String, actual : Bytes, mode : UInt64, label : String) : Nil
  expected = w123_expected_raw(profile, logical, mode)
  if logical == "payload.object_structure" || logical.ends_with?(".dynamic_structure")
    # These W116 metadata vectors intentionally compare decoded identity and
    # statistics semantically; this separately-authored W120 literal pins the
    # exact canonical writer bytes.
    W116JsonPhysicalVectors.assert_stream_raw(profile, logical, actual)
  end
  w123_assert_bytes(actual, expected, label)
end

def w123_expected_outer_rows : Array(UInt64)
  W123_OUTER_ROWS.dup
end

def w123_bulk_from_part(profile : String, logical : String, part : String, label : String) : CrystalClick::BinaryBulkStream
  raw = w123_read_compressed(part, logical)
  expected = W116JsonPhysicalVectors.expected_raw_stream(profile, logical)
  w123_assert_bytes(raw, expected, "#{label} retained W116 raw bytes")
  grid = w123_read_marks(part, logical)
  w123_assert_grid(grid, W116JsonPhysicalVectors.expected_mark_grid(profile, logical), "#{label} retained W116 marks")
  stream = CrystalClick::BinaryBulkStream.new(raw, grid.map(&.[1]))
  w123_assert_grid(w123_outer_grid(stream.offsets), grid, "#{label} normalized grid")
  stream
end

def w123_bulk_set(profile : String, roles : Array(Tuple(String, String)), part : String, label : String) : CrystalClick::BinaryBulkStreams
  streams = {} of String => CrystalClick::BinaryBulkStream
  roles.each do |role, logical|
    streams[role] = w123_bulk_from_part(profile, logical, part, "#{label} #{role}")
  end
  CrystalClick::BinaryBulkStreams.new(4, streams)
end

def w123_shared_roles : Array(Tuple(String, String))
  [
    {"root.sizes", "payload.object_shared_data.size0"},
    {"root.elements.field.0.data", "payload.object_shared_data%2Epaths"},
    {"root.elements.field.1.data", "payload.object_shared_data%2Evalues"},
  ]
end

def w123_dynamic_stream_from_part(
  profile : String,
  path : String,
  part : String,
  label : String,
  mode : UInt64 = W121DiscriminatorVectors::MODE_COMPACT,
) : CrystalClick::DynamicValueStreams
  structure = W122BulkVectors.structure(profile, path)
  arms = {} of String => CrystalClick::BinaryBulkStreams
  W122BulkVectors.arm_names(structure).each do |arm_name|
    roles = W122BulkVectors.role_streams(profile, path, arm_name)
    arms[arm_name] = w123_bulk_set(profile, roles, part, "#{label} #{arm_name}")
  end

  logical = "payload.#{W120StructureVectors.physical_path(path)}.variant_discr"
  bytes = w123_read_compressed(part, logical)
  w123_assert_bytes(bytes, W121DiscriminatorVectors.stream_bytes(profile, path, mode), "#{label} W121 retained discriminator")
  grid = w123_read_marks(part, logical)
  w123_assert_grid(grid, W121DiscriminatorVectors.mark_offsets(profile, path, mode).each_with_index.map do |offset, index|
    rows = index < 4 ? W123_OUTER_ROWS[index] : 0_u64
    {0_u64, offset, rows}
  end.to_a, "#{label} retained discriminator grid")
  marks = grid.map { |(_compressed, offset, rows)| CrystalClick::DynamicDiscriminatorMark.new(offset, rows) }
  CrystalClick::DynamicValueStreams.new(CrystalClick::DynamicDiscriminatorStream.new(bytes, marks), arms)
end

def w123_streams_from_part(
  profile : String,
  part : String,
  label : String,
  mode : UInt64 = W121DiscriminatorVectors::MODE_COMPACT,
) : CrystalClick::ObjectDocumentStreams
  structure_set = W120StructureVectors.expected_set(profile)
  metadata_dynamics = {} of String => Bytes
  W120StructureVectors.dynamic_paths(profile).each do |path|
    logical = "payload.#{W120StructureVectors.physical_path(path)}.dynamic_structure"
    bytes = w123_read_compressed(part, logical)
    W116JsonPhysicalVectors.assert_stream_raw(profile, logical, bytes)
    metadata_dynamics[path] = bytes
  end
  object_bytes = w123_read_compressed(part, "payload.object_structure")
  W116JsonPhysicalVectors.assert_stream_raw(profile, "payload.object_structure", object_bytes)
  structures = CrystalClick::ObjectDynamicStructureStreams.new(object_bytes, metadata_dynamics)

  typed = {} of String => CrystalClick::BinaryBulkStreams
  if profile == "typed_mixed"
    typed["a"] = w123_bulk_set(profile, [{"root.data", "payload.a"}], part, "#{label} typed a")
  end

  dynamics = {} of String => CrystalClick::DynamicValueStreams
  W120StructureVectors.dynamic_paths(profile).each do |path|
    dynamics[path] = w123_dynamic_stream_from_part(profile, path, part, "#{label} Dynamic #{path}", mode)
  end

  shared = w123_bulk_set(profile, w123_shared_roles, part, "#{label} Object shared MAP")
  CrystalClick::ObjectDocumentStreams.new(structures, w123_expected_outer_rows, typed, dynamics, shared)
end

def w123_typed_schema(profile : String) : Hash(String, CrystalClick::BinaryDataType)
  if profile == "typed_mixed"
    {"a" => CrystalClick::BinaryDataType.primitive("UInt64")}
  else
    {} of String => CrystalClick::BinaryDataType
  end
end

def w123_assert_documents(expected : Array(CrystalClick::ObjectDocument), actual : Array(CrystalClick::ObjectDocument), label : String) : Nil
  unless expected.size == actual.size
    w123_fail("#{label}: document row count differs (#{actual.size} vs #{expected.size})")
  end
  expected.each_with_index do |document, row_index|
    actual_document = actual[row_index]
    paths = document.paths
    unless paths == actual_document.paths
      w123_fail("#{label}: flattened path identities differ at row #{row_index}: #{actual_document.paths.inspect} vs #{paths.inspect}")
    end
    paths.each do |path|
      expected_value = document.value_for(path)
      actual_value = actual_document.value_for(path)
      unless W122BulkVectors.value_equal?(expected_value, actual_value)
        w123_fail("#{label}: nominal value differs at row #{row_index}, path #{path.inspect}")
      end
    end
  end
end

def w123_decode_assert(profile : String, streams : CrystalClick::ObjectDocumentStreams, label : String) : Nil
  schema = w123_typed_schema(profile)
  expected = W123ObjectVectors.flat_documents(profile)
  full = CrystalClick::ObjectDocumentCodec.decode(
    schema, streams, first_mark: 0, mark_count: 4,
    profile: CrystalClick::BinaryBulkProfile.with_size_stream,
    shared_profile: CrystalClick::BinaryBulkProfile.single_stream
  ).flatten
  w123_assert_documents(expected, full, "#{label} full Object documents")

  selected = CrystalClick::ObjectDocumentCodec.decode(
    schema, streams, first_mark: 1, mark_count: 2,
    profile: CrystalClick::BinaryBulkProfile.with_size_stream,
    shared_profile: CrystalClick::BinaryBulkProfile.single_stream
  ).flatten
  w123_assert_documents(expected[2, 4], selected, "#{label} selected marks 1..2 / pk3..6")
end

def w123_encoded_bulk_for(profile : String, logical : String, streams : CrystalClick::ObjectDocumentStreams) : CrystalClick::BinaryBulkStream
  if logical == "payload.a"
    return streams.typed_for("a").stream("root.data")
  end

  shared_logicals = {
    "payload.object_shared_data.size0"    => "root.sizes",
    "payload.object_shared_data%2Epaths"  => "root.elements.field.0.data",
    "payload.object_shared_data%2Evalues" => "root.elements.field.1.data",
  }
  if role = shared_logicals[logical]?
    return streams.shared.stream(role)
  end

  path = w123_path_from_logical(profile, logical) || w123_fail("#{logical}: no encoded Dynamic path")
  structure = W122BulkVectors.structure(profile, path)
  W122BulkVectors.arm_names(structure).each do |arm_name|
    W122BulkVectors.role_streams(profile, path, arm_name).each do |role, candidate_logical|
      return streams.dynamic_for(path).arm(arm_name).stream(role) if candidate_logical == logical
    end
  end
  w123_fail("#{logical}: no encoded bulk role")
end

def w123_encoded_raw(profile : String, logical : String, streams : CrystalClick::ObjectDocumentStreams, mode : UInt64) : Bytes
  if logical == "payload.object_structure"
    streams.structures.object
  elsif logical.ends_with?(".dynamic_structure")
    path = w123_path_from_logical(profile, logical) || w123_fail("#{logical}: no metadata Dynamic path")
    streams.structures.dynamics[path]? || w123_fail("#{logical}: encoded Dynamic metadata is absent")
  elsif logical.ends_with?(".variant_discr")
    path = w123_path_from_logical(profile, logical) || w123_fail("#{logical}: no discriminator Dynamic path")
    streams.dynamic_for(path).discriminators.bytes
  else
    w123_encoded_bulk_for(profile, logical, streams).bytes
  end
end

def w123_encoded_grid(profile : String, logical : String, streams : CrystalClick::ObjectDocumentStreams, mode : UInt64) : Array(Tuple(UInt64, UInt64, UInt64))
  if logical.ends_with?(".variant_discr")
    discriminator = streams.dynamic_for(w123_path_from_logical(profile, logical).not_nil!).discriminators
    Array(Tuple(UInt64, UInt64, UInt64)).new(5) do |index|
      mark = discriminator.mark_at(index)
      {0_u64, mark.offset, mark.rows}
    end
  elsif logical == "payload.object_structure" || logical.ends_with?(".dynamic_structure")
    W116JsonPhysicalVectors.expected_mark_grid(profile, logical)
  else
    w123_outer_grid(w123_encoded_bulk_for(profile, logical, streams).offsets)
  end
end

def w123_write_stream(part : String, logical : String, raw : Bytes, grid : Array(Tuple(UInt64, UInt64, UInt64)), label : String) : Nil
  # The caller already compares the profile/mode-specific independent literal;
  # this helper only performs isolated file replacement and mark-grid surgery.
  bin_name = "#{CrystalClick::StreamName.hash(logical)}.bin"
  bin_path = File.join(part, bin_name)
  w123_require(File.file?(bin_path) && !File.symlink?(bin_path), "#{label}: unsafe/missing copied .bin")
  physical = raw.empty? ? Bytes.empty : w123_literal_lz4_frame(raw)
  unless physical.empty?
    w123_assert_bytes(CrystalClick::CompressedBlock.decode_all(physical), raw, "#{label} literal LZ4 re-encoding")
  end
  File.write(bin_path, physical)

  mark_path = File.join(part, "#{CrystalClick::StreamName.hash(logical)}.mrk2")
  w123_require(File.file?(mark_path) && !File.symlink?(mark_path), "#{label}: unsafe/missing copied .mrk2")
  original = File.read(mark_path).to_slice
  w123_require(original.size == 120 && grid.size == 5, "#{label}: expected five plain Wide marks")
  marks = Bytes.new(original.size) { |index| original[index] }
  5.times do |index|
    offset = index * 24
    w123_require(w123_read_u64_at(marks, offset) == 0_u64, "#{logical}: captured compressed mark offset is nonzero")
    w123_require(w123_read_u64_at(marks, offset + 16) == (index < 4 ? W123_OUTER_ROWS[index] : 0_u64), "#{logical}: copied outer row count differs")
    compressed, decompressed, rows = grid[index]
    w123_require(compressed == 0_u64 && rows == (index < 4 ? W123_OUTER_ROWS[index] : 0_u64), "#{logical}: output mark is outside captured W123 grid")
    w123_write_u64_at(marks, offset, compressed)
    w123_write_u64_at(marks, offset + 8, decompressed)
    w123_write_u64_at(marks, offset + 16, rows)
  end
  File.write(mark_path, marks)
end

def w123_profile_table(binary : String, store : String, profile : String) : String
  table = "w123_#{profile}"
  json_type = profile == "typed_mixed" ? "JSON(a UInt64, max_dynamic_paths=1, max_dynamic_types=1)" : "JSON(max_dynamic_paths=16, max_dynamic_types=8)"
  w123_run(binary, store,
    "CREATE TABLE default.#{table} (pk UInt64, payload #{json_type}) ENGINE=MergeTree ORDER BY pk SETTINGS #{W123_SETTINGS}")
  actual = w123_run(binary, store,
    "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw")
  w123_require(actual == W116JsonPhysicalVectors.expected_schema(profile), "#{profile}: isolated table schema differs from W115 literal")
  table
end

def w123_attach_path(binary : String, store : String, table : String) : String
  path = w123_run(binary, store,
    "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  w123_store_child(path, store, "W123 #{table} data path")
end

def w123_retained_part(binary : String, store : String, profile : String, attached : Bool) : Tuple(String, String)
  table = "w115_#{profile}_#{attached ? "attached" : "source"}"
  rows = w123_run(binary, store,
    "SELECT name, path, part_type, toString(rows) FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").lines
  w123_require(rows.size == 1, "W115 #{profile} #{table}: expected exactly one active part")
  fields = rows.first.split('\t')
  w123_require(fields.size == 4 && fields[2] == "Wide" && fields[3] == "8", "W115 #{profile} #{table}: expected Wide eight-row part")
  part = w123_store_child(fields[1], store, "W115 #{profile} #{table} part")
  check = w123_run(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated")
  w123_assert_check(check, fields[0], "W115 #{profile} #{table}")
  W116JsonPhysicalVectors.assert_part(profile, part, attached: attached)
  {fields[0], part}
end

def w123_assert_existing_source(profile : String, part : String, binary : String, store : String, table : String) : Nil
  streams = w123_streams_from_part(profile, part, "W115 #{profile} source")
  w123_decode_assert(profile, streams, "W123 decode existing W115 #{profile}")
  full_query = "SELECT pk, toJSONString(payload) FROM default.#{table} ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw"
  selected_query = "SELECT pk, toJSONString(payload) FROM default.#{table} WHERE pk >= 3 AND pk <= 6 ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw"
  w115_assert_semantic_documents(w123_run(binary, store, full_query), profile, false, "W123 retained W115 full")
  w115_assert_semantic_documents(w123_run(binary, store, selected_query), profile, true, "W123 retained W115 pk3..6")
end

def w123_writer_profile(binary : String, source_store : String, source_part_name : String, source_part : String, root : String, profile : String, mode : UInt64) : Nil
  mode_name = mode == W121DiscriminatorVectors::MODE_BASIC ? "basic" : "compact"
  store = File.join(root, "stores", "#{profile}_#{mode_name}")
  w123_require(!File.exists?(store) && !File.symlink?(File.dirname(store)), "#{profile}/#{mode_name}: store already exists or parent is unsafe")
  FileUtils.mkdir_p(store)
  table = w123_profile_table(binary, store, profile)
  detached = File.join(w123_attach_path(binary, store, table), "detached")
  FileUtils.mkdir_p(detached)
  w123_store_child(detached, store, "#{profile}/#{mode_name} detached directory")
  destination = File.join(detached, source_part_name)
  w123_require(!File.exists?(destination) && !File.symlink?(detached), "#{profile}/#{mode_name}: detached destination is occupied or unsafe")
  FileUtils.cp_r(source_part, destination)
  copied = w123_store_child(destination, store, "#{profile}/#{mode_name} copied part")
  w123_assert_tree(copied, "#{profile}/#{mode_name} copied part before surgery")
  inventory_before = Dir.children(copied).sort

  documents = W123ObjectVectors.documents(profile)
  encoded = CrystalClick::ObjectDocumentCodec.encode(
    W123ObjectVectors.plan(profile), documents, mode: mode,
    profile: CrystalClick::BinaryBulkProfile.with_size_stream,
    shared_profile: CrystalClick::BinaryBulkProfile.single_stream
  )
  w123_require(encoded.rows_per_mark == W123_OUTER_ROWS, "#{profile}/#{mode_name}: production outer row grid differs")
  w123_decode_assert(profile, encoded, "W123 production-authored #{profile}/#{mode_name}")

  changed_bins = [] of String
  W116JsonPhysicalVectors.expected_stream_names(profile).each do |logical|
    next if logical == "pk"
    raw = w123_encoded_raw(profile, logical, encoded, mode)
    grid = w123_encoded_grid(profile, logical, encoded, mode)
    w123_assert_expected_stream(profile, logical, raw, mode, "#{profile}/#{mode_name} #{logical} independent literal")
    expected_grid = w123_expected_grid(profile, logical, mode)
    w123_assert_grid(grid, expected_grid, "#{profile}/#{mode_name} #{logical} production-vs-literal marks")
    w123_write_stream(copied, logical, raw, grid, "#{profile}/#{mode_name} #{logical}")
    changed_bins << "#{CrystalClick::StreamName.hash(logical)}.bin"
  end
  w123_require(changed_bins.uniq.size == changed_bins.size, "#{profile}/#{mode_name}: production rewrote a physical stream more than once")
  w123_rewrite_checksums(copied, changed_bins)
  w123_assert_tree(copied, "#{profile}/#{mode_name} copied part after surgery")
  w123_require(Dir.children(copied).sort == inventory_before, "#{profile}/#{mode_name}: part inventory changed during stream surgery")

  w123_run(binary, store, "ALTER TABLE default.#{table} ATTACH PART '#{source_part_name}'")
  check = w123_run(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated")
  w123_assert_check(check, source_part_name, "W123 #{profile}/#{mode_name} authored ATTACH")
  attached_name, attached = w123_part(binary, store, table, "W123 #{profile}/#{mode_name} attached part")
  w123_require(attached_name == source_part_name, "#{profile}/#{mode_name}: attached part name changed")
  w123_assert_tree(attached, "#{profile}/#{mode_name} attached part")

  expected_files = W116JsonPhysicalVectors.expected_files(profile, attached: true)
  expected_part = W116JsonPhysicalVectors.fixture_path(profile, attached: true)
  w123_require(Dir.children(attached).sort == expected_files, "#{profile}/#{mode_name}: attached stream inventory differs from W116")
  w123_assert_bytes(File.read(File.join(attached, "columns.txt")).to_slice,
    W116JsonPhysicalVectors.expected_columns_text(profile).to_slice, "#{profile}/#{mode_name} attached schema")
  W116JsonPhysicalVectors.expected_stream_names(profile).each do |logical|
    raw = w123_read_compressed(attached, logical)
    w123_assert_expected_stream(profile, logical, raw, mode, "#{profile}/#{mode_name} attached #{logical}")
    grid = w123_read_marks(attached, logical)
    w123_assert_grid(grid, w123_expected_grid(profile, logical, mode), "#{profile}/#{mode_name} attached #{logical} marks")
    unless logical == "pk"
      # Existing profile helpers compare Object/Dynamic metadata semantically;
      # this additional comparison pins untouched auxiliary streams byte-for-byte.
      next if logical == "payload.object_structure" || logical.ends_with?(".dynamic_structure") || logical.ends_with?(".variant_discr")
      w123_assert_bytes(raw, w123_read_compressed(expected_part, logical), "#{profile}/#{mode_name} retained physical lane #{logical}")
    end
  end
  expected_files.each do |name|
    next if name == "checksums.txt" || name.ends_with?(".bin") || name.ends_with?(".mrk2")
    w123_assert_bytes(File.read(File.join(attached, name)).to_slice,
      File.read(File.join(expected_part, name)).to_slice, "#{profile}/#{mode_name} unchanged W116 metadata #{name}")
  end
  checksums = CrystalClick::PartChecksums.open(attached)
  checksums.entries.keys.each { |name| checksums.validate_selected_entries(attached, name) }

  attached_streams = w123_streams_from_part(profile, attached, "W123 #{profile}/#{mode_name} attached", mode)
  w123_decode_assert(profile, attached_streams, "W123 decode attached #{profile}/#{mode_name}")
  full_query = "SELECT pk, toJSONString(payload) FROM default.#{table} ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw"
  selected_query = "SELECT pk, toJSONString(payload) FROM default.#{table} WHERE pk >= 3 AND pk <= 6 ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw"
  w115_assert_semantic_documents(w123_run(binary, source_store, "SELECT pk, toJSONString(payload) FROM default.w115_#{profile}_source ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw"), profile, false, "W123 source full")
  w115_assert_semantic_documents(w123_run(binary, source_store, "SELECT pk, toJSONString(payload) FROM default.w115_#{profile}_source WHERE pk >= 3 AND pk <= 6 ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw"), profile, true, "W123 source pk3..6")
  w115_assert_semantic_documents(w123_run(binary, store, full_query), profile, false, "W123 attached full")
  w115_assert_semantic_documents(w123_run(binary, store, selected_query), profile, true, "W123 attached pk3..6")
  puts "PASS W123 isolated stock ATTACH/CHECK=1, physical lanes and flattened full/pk3..6 documents: #{profile}/#{mode_name} part=#{attached_name}"
end

def w123_expect_comparator_controls : Nil
  begin
    w123_assert_bytes(Bytes[0x61_u8, 0x63_u8], Bytes[0x61_u8, 0x62_u8], "W123 wrong raw-byte control")
  rescue error : W123Mismatch
    w123_require(error.message.to_s.starts_with?("W123 wrong raw-byte control: raw byte vector differs"), "W123 raw-byte control failed for an unrelated reason")
  else
    w123_fail("W123 one-byte wrong-literal control was accepted")
  end

  expected_object = w123_structure_raw("typed_mixed")
  wrong_object = Bytes.new(expected_object.size) { |index| expected_object[index] }
  wrong_object[wrong_object.size - 1] ^= 1_u8
  begin
    W116JsonPhysicalVectors.assert_stream_raw("typed_mixed", "payload.object_structure", wrong_object)
  rescue error : W116JsonPhysicalMismatch
    w123_require(error.message.to_s.includes?("object_structure differs"), "W123 Object-statistic control failed for an unrelated reason")
  else
    w123_fail("W123 wrong Object statistic literal was accepted")
  end

  expected_grid = [{0_u64, 0_u64, 2_u64}, {0_u64, 2_u64, 0_u64}]
  wrong_grid = [{0_u64, 0_u64, 2_u64}, {0_u64, 2_u64, 1_u64}]
  begin
    w123_assert_grid(wrong_grid, expected_grid, "W123 wrong outer-row control")
  rescue error : W123Mismatch
    w123_require(error.message.to_s.starts_with?("W123 wrong outer-row control: physical mark grid differs"), "W123 mark control failed for an unrelated reason")
  else
    w123_fail("W123 wrong outer mark count control was accepted")
  end

  begin
    w123_assert_check("w123_control_part\t0\t\n", "w123_control_part", "W123 CHECK=0 control")
  rescue error : W123Mismatch
    w123_require(error.message.to_s.starts_with?("W123 CHECK=0 control: CHECK output mismatch"), "W123 CHECK control failed for an unrelated reason")
  else
    w123_fail("W123 CHECK=0 control was accepted")
  end
  puts "PASS W123 wrong-byte, Object-statistic, outer-row and CHECK=0 comparator controls"
end

def w123_check : Nil
  binary = ENV["CLICKHOUSE_BIN"]? || raise "CLICKHOUSE_BIN is required"
  capture_root = ENV["W115_CAPTURE_ROOT"]? || raise "W115_CAPTURE_ROOT is required"
  temp_root = ENV["W123_TMP_ROOT"]? || raise "W123_TMP_ROOT is required"
  capture_root = File.realpath(capture_root)
  temp_root = File.realpath(temp_root)
  w123_require(capture_root.starts_with?("/private/tmp/crystal-click-json-w115.") && !File.symlink?(capture_root), "unsafe W115 capture root")
  w123_require(temp_root.starts_with?("/private/tmp/crystal-click-json-w123.") && !File.symlink?(temp_root), "unsafe W123 temporary root")
  source_store = File.realpath(File.join(capture_root, "store"))
  w123_require(source_store.starts_with?(capture_root + "/") && !File.symlink?(File.join(capture_root, "store")), "unsafe W115 source store")
  w123_require(File.file?(File.join(capture_root, "capture.log")) && !File.symlink?(File.join(capture_root, "capture.log")), "W115 capture log is missing or unsafe")
  w123_require(File.file?(File.join(capture_root, "input.jsonl")) && !File.symlink?(File.join(capture_root, "input.jsonl")), "W115 literal input is missing or unsafe")
  w123_require(Dir.empty?(temp_root), "W123 temporary root must be fresh and empty")

  w123_verify_runtime(binary, source_store)
  w123_expect_comparator_controls
  w123_require(W123ObjectVectors::PROFILES.to_a.sort == ["dynamic_paths", "typed_mixed"].sort, "W123 independent literal profile inventory changed")
  w123_require(W115_SEMANTIC_PAYLOADS.size == 8, "W123 W115 semantic literal row inventory changed")

  source_parts = {} of String => Tuple(String, String)
  {"dynamic_paths", "typed_mixed"}.each do |profile|
    {false, true}.each do |attached|
      name, part = w123_retained_part(binary, source_store, profile, attached)
      if attached
        source_name = source_parts[profile]?.try(&.[0]) || w123_fail("W115 #{profile}: source part was not inspected first")
        w123_require(source_name == name, "W115 #{profile}: source and fresh-ATTACH part names differ")
        w123_assert_existing_source(profile, part, binary, source_store, "w115_#{profile}_attached")
      else
        source_parts[profile] = {name, part}
        w123_assert_existing_source(profile, part, binary, source_store, "w115_#{profile}_source")
      end
    end
  end
  puts "PASS W123 independent flattened-document decoder against retained W115 source and fresh ATTACH"

  {"dynamic_paths", "typed_mixed"}.each do |profile|
    source_part_name, source_part = source_parts[profile]
    {W121DiscriminatorVectors::MODE_BASIC, W121DiscriminatorVectors::MODE_COMPACT}.each do |mode|
      w123_writer_profile(binary, source_store, source_part_name, source_part, temp_root, profile, mode)
    end
  end
  puts "PASS W123 scope: retained W115 profiles only; no all-type, whole-JSON facade or publication claim"
end

w123_check
