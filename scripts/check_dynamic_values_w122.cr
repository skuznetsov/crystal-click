# Stock oracle for the bounded W122 recursive bulk and Dynamic logical-value
# slice. Its literal rows/lanes come from W115/W116/W120/W121, not from the
# production bulk or Dynamic codecs.
require "file_utils"
require "../src/crystal_click"
require "./w115_json_semantic_vectors"
require "./w116_json_physical_vectors"
require "./w120_structure_vectors"
require "./w121_discriminator_vectors"
require "./w122_bulk_vectors"

W122_VERSION             = "26.10.1.1201"
W122_BUILD_HASH          = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
W122_EXECUTABLE_SHA256   = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
W122_SETTINGS            = "index_granularity=2, index_granularity_bytes=10485760, enable_mixed_granularity_parts=1, min_rows_for_wide_part=0, min_bytes_for_wide_part=0, compress_marks=0, compress_primary_key=0, min_compress_block_size=0, max_compress_block_size=4096, default_compression_codec='LZ4', object_serialization_version='v3', object_shared_data_serialization_version_for_zero_level_parts='map'"
W122_SELECTED_FIRST_MARK = 1
W122_SELECTED_MARK_COUNT = 2
W122_OUTER_MARKS         = 4

class W122Mismatch < Exception
end

def w122_fail(message : String) : NoReturn
  raise W122Mismatch.new(message)
end

def w122_require(condition : Bool, message : String) : Nil
  w122_fail(message) unless condition
end

def w122_run(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: error)
  raise "ClickHouse local query failed: #{error}\n#{query}" unless status.success?
  output.to_s
end

def w122_run_status(binary : String, arguments : Array(String)) : String
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run(binary, arguments, output: output, error: error)
  raise "ClickHouse command failed: #{error}" unless status.success?
  output.to_s
end

def w122_store_child(path : String, store : String, label : String) : String
  real_store = File.realpath(store)
  real_path = File.realpath(path)
  unless real_path.starts_with?(real_store + "/") && !File.symlink?(path)
    w122_fail("#{label}: path escapes its isolated store or is a symlink")
  end
  relative = real_path[(real_store.size + 1)..]
  cursor = real_store
  relative.split('/').each do |component|
    cursor = File.join(cursor, component)
    w122_fail("#{label}: symlink in store path") if File.symlink?(cursor)
  end
  real_path
end

def w122_assert_tree(path : String, label : String) : Nil
  w122_require(Dir.exists?(path) && !File.symlink?(path), "#{label}: unsafe/missing directory")
  Dir.children(path).each do |name|
    child = File.join(path, name)
    w122_require(!File.symlink?(child), "#{label}: symlink child #{name.inspect}")
    if Dir.exists?(child)
      w122_assert_tree(child, "#{label}/#{name}")
    else
      w122_require(File.file?(child), "#{label}: non-file child #{name.inspect}")
    end
  end
end

def w122_part(binary : String, store : String, table : String, label : String) : Tuple(String, String)
  rows = w122_run(binary, store,
    "SELECT name, path, part_type, toString(rows) FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").lines
  w122_require(rows.size == 1, "#{label}: expected exactly one active part, got #{rows.size}")
  fields = rows.first.split('\t')
  w122_require(fields.size == 4 && fields[2] == "Wide" && fields[3] == "8", "#{label}: expected one Wide eight-row part")
  {fields[0], w122_store_child(fields[1], store, "#{label} part")}
end

def w122_assert_check(actual : String, part_name : String, label : String) : Nil
  expected = "#{part_name}\t1\t\n"
  w122_fail("#{label}: CHECK output mismatch: #{actual.inspect}") unless actual == expected
end

def w122_verify_runtime(binary : String, store : String) : Nil
  version = w122_run_status(binary, ["local", "--version"]).strip
  expected_version = "ClickHouse local version #{W122_VERSION} (official build)."
  w122_require(version == expected_version, "unexpected ClickHouse version: #{version.inspect}")
  digest = w122_run_status("shasum", ["-a", "256", binary]).split(' ').first? || ""
  w122_require(digest == W122_EXECUTABLE_SHA256, "unexpected ClickHouse executable SHA-256")
  build = w122_run(binary, store,
    "SELECT name || '=' || value FROM system.build_options WHERE name IN ('GIT_HASH', 'VERSION_GITHASH') ORDER BY name FORMAT TSVRaw").lines.map(&.strip)
  w122_require(build == ["GIT_HASH=#{W122_BUILD_HASH}", "VERSION_GITHASH=#{W122_BUILD_HASH}"], "unexpected ClickHouse build identity")
end

def w122_read_compressed(part : String, logical : String) : Bytes
  name = "#{CrystalClick::StreamName.hash(logical)}.bin"
  path = File.join(part, name)
  w122_require(File.file?(path) && !File.symlink?(path), "#{logical}: unsafe/missing .bin")
  physical = File.read(path).to_slice
  physical.empty? ? Bytes.empty : CrystalClick::CompressedBlock.decode_all(physical)
end

def w122_read_u64_at(bytes : Bytes, offset : Int32) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

def w122_write_u32_le(bytes : Bytes, offset : Int32, value : UInt32) : Nil
  4.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u32).to_u8 }
end

def w122_write_u64_at(bytes : Bytes, offset : Int32, value : UInt64) : Nil
  8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

def w122_write_u64(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
end

def w122_write_hash128(bytes : Bytes, offset : Int32, hash : {UInt64, UInt64}) : Nil
  w122_write_u64_at(bytes, offset, hash[0])
  w122_write_u64_at(bytes, offset + 8, hash[1])
end

def w122_write_hash128(io : IO, hash : {UInt64, UInt64}) : Nil
  w122_write_u64(io, hash[0])
  w122_write_u64(io, hash[1])
end

def w122_write_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

# This oracle only rewrites the captured one-frame, plain-Wide profile. Each
# parsed tuple is compressed offset, decompressed offset, and outer row count.
def w122_read_marks(part : String, logical : String) : Array(Tuple(UInt64, UInt64, UInt64))
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical)}.mrk2")
  w122_require(File.file?(path) && !File.symlink?(path), "#{logical}: unsafe/missing .mrk2")
  bytes = File.read(path).to_slice
  w122_require(bytes.size == 120 && bytes.size % 24 == 0, "#{logical}: expected five plain Wide marks")
  result = [] of Tuple(UInt64, UInt64, UInt64)
  5.times do |index|
    offset = index * 24
    result << {w122_read_u64_at(bytes, offset), w122_read_u64_at(bytes, offset + 8), w122_read_u64_at(bytes, offset + 16)}
  end
  result
end

def w122_assert_stock_marks(profile : String, logical : String, actual : Array(Tuple(UInt64, UInt64, UInt64)), label : String) : Nil
  expected = W116JsonPhysicalVectors.expected_mark_grid(profile, logical)
  w122_require(actual == expected, "#{label}: full stock .mrk2 grid differs from the independent W116 literal")
end

def w122_assert_bytes(actual : Bytes, expected : Bytes, label : String) : Nil
  w122_fail("#{label}: byte vector differs (#{actual.size} vs #{expected.size} bytes)") unless actual == expected
end

def w122_assert_unchanged_physical_stream(profile : String, logical : String, actual : Bytes, retained : Bytes, label : String) : Nil
  # W116 deliberately uses semantic comparison for object_structure because
  # source statistic-map order is unstable; all other stream rules remain as
  # strict as W116 defines them. This additional retained-part comparison
  # proves byte preservation even for that semantically unordered map.
  W116JsonPhysicalVectors.assert_stream_raw(profile, logical, actual)
  w122_assert_bytes(actual, retained, "#{label} retained fresh-ATTACH bytes")
end

def w122_literal_lz4_frame(raw : Bytes) : Bytes
  raise "cannot encode an empty W122 LZ4 frame" if raw.empty?
  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w122_write_u32_le(frame, header + 1, compressed_size.to_u32)
  w122_write_u32_le(frame, header + 5, raw.size.to_u32)
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
  w122_write_hash128(frame, 0, hash)
  frame
end

def w122_rewrite_checksums(part : String, changed_bins : Array(String)) : Nil
  original = CrystalClick::PartChecksums.open(part)
  names = original.entries.keys.sort
  w122_require(!names.empty? && !names.includes?("checksums.txt"), "W122 copy has unexpected checksum inventory")
  changed_bins.each do |name|
    w122_require(names.includes?(name), "W122 changed stream is absent from checksum inventory: #{name}")
  end

  payload = IO::Memory.new
  w122_write_varuint(payload, names.size.to_u64)
  names.each do |name|
    w122_require(name == File.basename(name) && name != "." && name != "..", "W122 checksum entry has unsafe path #{name.inspect}")
    path = File.join(part, name)
    w122_require(File.file?(path) && !File.symlink?(path), "W122 copied part has unsafe/missing file #{name}")
    physical = File.read(path).to_slice
    entry = original.entry(name) || w122_fail("W122 copied part lost checksum entry #{name}")
    changed = changed_bins.includes?(name)
    w122_require(!changed || entry.compressed, "W122 changed stream is not compressed: #{name}")
    raw = if entry.compressed
            physical.empty? ? Bytes.empty : CrystalClick::CompressedBlock.decode_all(physical)
          else
            physical
          end
    if entry.compressed && !changed
      expected_raw_size = entry.uncompressed_size || w122_fail("compressed checksum entry #{name} has no raw size")
      w122_require(raw.size.to_u64 == expected_raw_size, "unchanged copied stream raw size differs from checksum entry #{name}")
    end

    w122_write_varuint(payload, name.bytesize.to_u64)
    payload.write(name.to_slice)
    w122_write_varuint(payload, physical.size.to_u64)
    w122_write_hash128(payload, CrystalClick::CityHashV1.file_hash(physical))
    if entry.compressed
      payload.write_byte(1_u8)
      w122_write_varuint(payload, raw.size.to_u64)
      w122_write_hash128(payload, CrystalClick::CityHashV1.file_hash(raw))
    else
      payload.write_byte(0_u8)
    end
  end

  manifest = IO::Memory.new
  manifest << CrystalClick::PartChecksums::CHECKSUMS_HEADER
  manifest.write(w122_literal_lz4_frame(payload.to_slice))
  File.write(File.join(part, "checksums.txt"), manifest.to_slice)

  rewritten = CrystalClick::PartChecksums.open(part)
  w122_require(rewritten.entries.keys.sort == names, "W122 rewritten checksum inventory changed")
  names.each { |name| rewritten.validate_selected_entries(part, name) }
end

def w122_profile_table(binary : String, store : String, profile : String, json_type : String) : String
  table = "w122_#{profile}_values"
  w122_run(binary, store,
    "CREATE TABLE default.#{table} (pk UInt64, payload #{json_type}) ENGINE=MergeTree ORDER BY pk SETTINGS #{W122_SETTINGS}")
  schema = w122_run(binary, store,
    "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw")
  w122_require(schema == W116JsonPhysicalVectors.expected_schema(profile), "#{profile}: isolated table schema differs from retained W115 profile")
  table
end

def w122_attach_path(binary : String, store : String, table : String) : String
  path = w122_run(binary, store,
    "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  w122_store_child(path, store, "W122 #{table} table data path")
end

def w122_outer_mark_rows : Array(UInt64)
  [2_u64, 2_u64, 2_u64, 2_u64, 0_u64]
end

def w122_assert_grid(actual : Array(Tuple(UInt64, UInt64, UInt64)), expected : Array(Tuple(UInt64, UInt64, UInt64)), label : String) : Nil
  w122_fail("#{label}: physical mark grid differs") unless actual == expected
end

def w122_expected_bulk_grid(stream : CrystalClick::BinaryBulkStream, label : String) : Array(Tuple(UInt64, UInt64, UInt64))
  w122_require(stream.mark_count == 4 && stream.offset_count == 5, "#{label}: expected four marks plus terminal offset")
  rows = w122_outer_mark_rows
  result = [] of Tuple(UInt64, UInt64, UInt64)
  5.times do |index|
    result << {0_u64, stream.offset_at(index), rows[index]}
  end
  w122_require(stream.offset_at(0) == 0_u64, "#{label}: first bulk offset is not zero")
  w122_require(stream.offset_at(4) == stream.byte_size.to_u64, "#{label}: terminal bulk offset differs from lane byte size")
  result
end

def w122_bulk_stream_from_part(profile : String, logical : String, part : String, label : String) : CrystalClick::BinaryBulkStream
  raw = w122_read_compressed(part, logical)
  w122_assert_bytes(raw, W116JsonPhysicalVectors.expected_raw_stream(profile, logical), "#{label} raw bytes")
  grid = w122_read_marks(part, logical)
  w122_assert_grid(grid, W116JsonPhysicalVectors.expected_mark_grid(profile, logical), "#{label} source grid")
  offsets = grid.map(&.[1])
  stream = CrystalClick::BinaryBulkStream.new(raw, offsets)
  w122_assert_grid(w122_expected_bulk_grid(stream, label), grid, "#{label} normalized grid")
  stream
end

def w122_bulk_streams_from_part(profile : String, path : String, arm_name : String, part : String, label : String) : CrystalClick::BinaryBulkStreams
  lanes = {} of String => CrystalClick::BinaryBulkStream
  W122BulkVectors.role_streams(profile, path, arm_name).each do |role, logical|
    lanes[role] = w122_bulk_stream_from_part(profile, logical, part, "#{label} #{role}")
  end
  CrystalClick::BinaryBulkStreams.new(4, lanes)
end

def w122_discriminator_stream_from_part(profile : String, path : String, part : String, label : String, mode : UInt64 = W121DiscriminatorVectors::MODE_COMPACT) : CrystalClick::DynamicDiscriminatorStream
  logical = "payload.#{W120StructureVectors.physical_path(path)}.variant_discr"
  raw = w122_read_compressed(part, logical)
  expected_raw = W121DiscriminatorVectors.stream_bytes(profile, path, mode)
  w122_assert_bytes(raw, expected_raw, "#{label} independent W121 discriminator mode=#{mode}")
  if mode == W121DiscriminatorVectors::MODE_COMPACT
    w122_assert_bytes(raw, W116JsonPhysicalVectors.expected_raw_stream(profile, logical), "#{label} independent W116 retained discriminator")
  end
  grid = w122_read_marks(part, logical)
  expected_grid = w122_expected_discriminator_grid(profile, path, mode)
  w122_assert_grid(grid, expected_grid, "#{label} independent W121 discriminator offsets")
  if mode == W121DiscriminatorVectors::MODE_COMPACT
    w122_assert_grid(grid, W116JsonPhysicalVectors.expected_mark_grid(profile, logical), "#{label} retained W116 discriminator grid")
  end
  marks = grid.map do |(_compressed, offset, row_count)|
    CrystalClick::DynamicDiscriminatorMark.new(offset: offset, rows: row_count)
  end
  CrystalClick::DynamicDiscriminatorStream.new(raw, marks)
end

def w122_dynamic_streams_from_part(profile : String, path : String, part : String, label : String, mode : UInt64 = W121DiscriminatorVectors::MODE_COMPACT) : CrystalClick::DynamicValueStreams
  structure = W122BulkVectors.structure(profile, path)
  arms = {} of String => CrystalClick::BinaryBulkStreams
  W122BulkVectors.arm_names(structure).each do |arm_name|
    arms[arm_name] = w122_bulk_streams_from_part(profile, path, arm_name, part, "#{label} #{arm_name}")
  end
  discriminators = w122_discriminator_stream_from_part(profile, path, part, label, mode)
  CrystalClick::DynamicValueStreams.new(discriminators: discriminators, arms: arms)
end

def w122_assert_value_rows(expected : Array(Array(CrystalClick::BinaryValue)), actual : Array(Array(CrystalClick::BinaryValue)), label : String) : Nil
  unless expected.size == actual.size && expected.each_with_index.all? do |row, index|
           row.size == actual[index].size && row.each_with_index.all? do |value, value_index|
             W122BulkVectors.value_equal?(value, actual[index][value_index])
           end
         end
    w122_fail("#{label}: Dynamic BinaryValue rows differ from independent W115 literals")
  end
end

def w122_decode_and_assert(profile : String, path : String, streams : CrystalClick::DynamicValueStreams, label : String) : Nil
  structure = W122BulkVectors.structure(profile, path)
  limits = CrystalClick::BinaryCodecLimits.default
  full = CrystalClick::DynamicValueCodec.decode(
    structure, streams, first_mark: 0, mark_count: 4, limits: limits,
    profile: CrystalClick::BinaryBulkProfile.with_size_stream
  )
  w122_assert_value_rows(W122BulkVectors.expected_granules(profile, path), full, "#{label} full")
  selected = CrystalClick::DynamicValueCodec.decode(
    structure, streams, first_mark: 1, mark_count: 2, limits: limits,
    profile: CrystalClick::BinaryBulkProfile.with_size_stream
  )
  w122_assert_value_rows(W122BulkVectors.expected_granules(profile, path, 1, 2), selected, "#{label} marks 1..2 / pk3..6")
end

def w122_assert_encoded_discriminator(profile : String, path : String, stream : CrystalClick::DynamicDiscriminatorStream, mode : UInt64, label : String) : Array(Tuple(UInt64, UInt64, UInt64))
  expected_bytes = W121DiscriminatorVectors.stream_bytes(profile, path, mode)
  w122_assert_bytes(stream.bytes, expected_bytes, "#{label} literal discriminator bytes")
  offsets = W121DiscriminatorVectors.mark_offsets(profile, path, mode)
  rows = w122_outer_mark_rows
  expected_grid = [] of Tuple(UInt64, UInt64, UInt64)
  5.times { |index| expected_grid << {0_u64, offsets[index], rows[index]} }
  actual_grid = [] of Tuple(UInt64, UInt64, UInt64)
  w122_require(stream.mark_count == 5 && stream.byte_size == expected_bytes.size, "#{label}: encoded discriminator extents differ")
  5.times do |index|
    mark = stream.mark_at(index)
    actual_grid << {0_u64, mark.offset.to_u64, mark.rows.to_u64}
  end
  w122_assert_grid(actual_grid, expected_grid, "#{label} literal discriminator marks")
  actual_grid
end

def w122_encode_path(profile : String, path : String, mode : UInt64, part : String? = nil, label : String = "W122") : Array(String)
  structure = W122BulkVectors.structure(profile, path)
  encoded = CrystalClick::DynamicValueCodec.encode(
    structure, W122BulkVectors.granules(profile, path), mode: mode,
    limits: CrystalClick::BinaryCodecLimits.default,
    profile: CrystalClick::BinaryBulkProfile.with_size_stream
  )
  w122_require(encoded.arm_names == W122BulkVectors.arm_names(structure), "#{label} #{path}: encoded arm roster differs")
  w122_decode_and_assert(profile, path, encoded, "#{label} #{path} encoded")

  discriminator = encoded.discriminators
  discriminator_grid = w122_assert_encoded_discriminator(profile, path, discriminator, mode, "#{label} #{path}")
  changed_bins = [] of String
  if target = part
    logical = "payload.#{W120StructureVectors.physical_path(path)}.variant_discr"
    w122_replace_stream(target, logical, discriminator.bytes, discriminator_grid,
      W121DiscriminatorVectors.stream_bytes(profile, path, mode),
      w122_expected_discriminator_grid(profile, path, mode), "#{label} #{path} discriminator")
    changed_bins << "#{CrystalClick::StreamName.hash(logical)}.bin"
  end

  W122BulkVectors.arm_names(structure).each do |arm_name|
    bulk = encoded.arm(arm_name)
    expected_roles = W122BulkVectors.role_streams(profile, path, arm_name).map(&.[0]).sort
    w122_require(bulk.mark_count == 4 && bulk.roles == expected_roles, "#{label} #{path} #{arm_name}: encoded bulk role set differs")
    W122BulkVectors.role_streams(profile, path, arm_name).each do |role, logical|
      stream = bulk.stream(role)
      grid = w122_expected_bulk_grid(stream, "#{label} #{path} #{arm_name} #{role}")
      raw = stream.bytes
      expected_raw = W116JsonPhysicalVectors.expected_raw_stream(profile, logical)
      expected_grid = W116JsonPhysicalVectors.expected_mark_grid(profile, logical)
      w122_assert_bytes(raw, expected_raw, "#{label} #{path} #{arm_name} #{role} literal bytes")
      w122_assert_grid(grid, expected_grid, "#{label} #{path} #{arm_name} #{role} literal marks")
      if target = part
        w122_replace_stream(target, logical, raw, grid, expected_raw, expected_grid,
          "#{label} #{path} #{arm_name} #{role}")
        changed_bins << "#{CrystalClick::StreamName.hash(logical)}.bin"
      end
    end
  end
  changed_bins
end

def w122_expected_discriminator_grid(profile : String, path : String, mode : UInt64) : Array(Tuple(UInt64, UInt64, UInt64))
  offsets = W121DiscriminatorVectors.mark_offsets(profile, path, mode)
  rows = w122_outer_mark_rows
  Array(Tuple(UInt64, UInt64, UInt64)).new(5) { |index| {0_u64, offsets[index], rows[index]} }
end

def w122_replace_stream(part : String, logical : String, raw : Bytes, grid : Array(Tuple(UInt64, UInt64, UInt64)), expected_raw : Bytes, expected_grid : Array(Tuple(UInt64, UInt64, UInt64)), label : String) : Nil
  w122_assert_bytes(raw, expected_raw, "#{label} production-vs-literal bytes")
  w122_assert_grid(grid, expected_grid, "#{label} production-vs-literal grid")
  bin_name = "#{CrystalClick::StreamName.hash(logical)}.bin"
  bin_path = File.join(part, bin_name)
  w122_require(File.file?(bin_path) && !File.symlink?(bin_path), "#{label}: unsafe/missing copied .bin")
  physical = raw.empty? ? Bytes.empty : w122_literal_lz4_frame(raw)
  unless physical.empty?
    w122_assert_bytes(CrystalClick::CompressedBlock.decode_all(physical), raw, "#{label} literal LZ4 re-encoding")
  end
  File.write(bin_path, physical)
  w122_rewrite_marks(part, logical, grid)
end

def w122_rewrite_marks(part : String, logical : String, grid : Array(Tuple(UInt64, UInt64, UInt64))) : Nil
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical)}.mrk2")
  w122_require(File.file?(path) && !File.symlink?(path), "#{logical}: unsafe/missing copied .mrk2")
  original = File.read(path).to_slice
  w122_require(original.size == 120 && grid.size == 5, "#{logical}: expected five plain Wide marks")
  marks = Bytes.new(original.size) { |index| original[index] }
  expected_rows = w122_outer_mark_rows
  5.times do |index|
    mark_offset = index * 24
    w122_require(w122_read_u64_at(marks, mark_offset) == 0_u64, "#{logical}: compressed mark offset is outside this captured profile")
    w122_require(w122_read_u64_at(marks, mark_offset + 16) == expected_rows[index], "#{logical}: copied outer row count differs")
    compressed, decompressed, rows = grid[index]
    w122_require(compressed == 0_u64 && rows == expected_rows[index], "#{logical}: replacement grid is outside the captured profile")
    w122_write_u64_at(marks, mark_offset, compressed)
    w122_write_u64_at(marks, mark_offset + 8, decompressed)
    w122_write_u64_at(marks, mark_offset + 16, rows)
  end
  File.write(path, marks)
end

def w122_retained_part(binary : String, store : String, profile : String, attached : Bool) : Tuple(String, String)
  table = "w115_#{profile}_#{attached ? "attached" : "source"}"
  part_name, part_path = w122_part(binary, store, table, "W115 #{profile} #{table}")
  w122_assert_tree(part_path, "W115 #{profile} #{table} retained part")
  check = w122_run(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated")
  w122_assert_check(check, part_name, "W115 #{profile} #{table}")
  W116JsonPhysicalVectors.assert_part(profile, part_path, attached: attached)
  {part_name, part_path}
end

def w122_assert_retained_profile(profile : String, part : String, label : String, mode : UInt64 = W121DiscriminatorVectors::MODE_COMPACT) : Nil
  W122BulkVectors.dynamic_paths(profile).each do |path|
    streams = w122_dynamic_streams_from_part(profile, path, part, "#{label} #{path}", mode)
    w122_decode_and_assert(profile, path, streams, "#{label} #{path}")
  end
end

def w122_assert_attached_physical_profile(profile : String, part : String, mode : UInt64, label : String) : Nil
  expected_files = W116JsonPhysicalVectors.expected_files(profile, attached: true)
  expected_part = W116JsonPhysicalVectors.fixture_path(profile, attached: true)
  actual_files = Dir.children(part).sort
  w122_require(actual_files == expected_files, "#{label}: attached part file inventory differs from W116")
  columns = File.read(File.join(part, "columns.txt"))
  w122_require(columns == W116JsonPhysicalVectors.expected_columns_text(profile), "#{label}: attached schema differs from W116")
  W116JsonPhysicalVectors.expected_stream_names(profile).each do |logical|
    raw = w122_read_compressed(part, logical)
    grid = w122_read_marks(part, logical)
    if logical.ends_with?(".variant_discr")
      path = logical["payload.".size, logical.size - ".variant_discr".size - "payload.".size]
      path = path.gsub("%2E", ".")
      w122_assert_bytes(raw, W121DiscriminatorVectors.stream_bytes(profile, path, mode), "#{label} #{logical} mode literal")
      w122_assert_grid(grid, w122_expected_discriminator_grid(profile, path, mode), "#{label} #{logical} mode marks")
    else
      retained_raw = w122_read_compressed(expected_part, logical)
      w122_assert_unchanged_physical_stream(profile, logical, raw, retained_raw, "#{label} #{logical}")
      w122_assert_grid(grid, W116JsonPhysicalVectors.expected_mark_grid(profile, logical), "#{label} #{logical} W116 marks")
    end
  end
  expected_files.each do |name|
    next if name == "checksums.txt" || name.ends_with?(".bin") || name.ends_with?(".mrk2")
    actual = File.read(File.join(part, name)).to_slice
    expected = File.read(File.join(expected_part, name)).to_slice
    w122_assert_bytes(actual, expected, "#{label} unchanged W116 metadata #{name}")
  end
  checksums = CrystalClick::PartChecksums.open(part)
  checksums.entries.keys.each { |name| checksums.validate_selected_entries(part, name) }
end

def w122_assert_live_documents(binary : String, source_store : String, copy_store : String, source_table : String, copy_table : String, root : String, profile : String, mode_name : String) : Nil
  full_query = "SELECT pk, toJSONString(payload) FROM default.%s ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw"
  selected_query = "SELECT pk, toJSONString(payload) FROM default.%s WHERE pk >= 3 AND pk <= 6 ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw"
  source_full = w122_run(binary, source_store, full_query % source_table)
  source_selected = w122_run(binary, source_store, selected_query % source_table)
  copy_full = w122_run(binary, copy_store, full_query % copy_table)
  copy_selected = w122_run(binary, copy_store, selected_query % copy_table)
  w115_assert_semantic_documents(source_full, profile, false, "W122 #{profile} retained source full")
  w115_assert_semantic_documents(source_selected, profile, true, "W122 #{profile} retained source pk3..6")
  w115_assert_semantic_documents(copy_full, profile, false, "W122 #{profile} copied ATTACH full")
  w115_assert_semantic_documents(copy_selected, profile, true, "W122 #{profile} copied ATTACH pk3..6")
  File.write(File.join(root, "#{profile}_#{mode_name}_source_full.tsv"), source_full)
  File.write(File.join(root, "#{profile}_#{mode_name}_source_pk3_6.tsv"), source_selected)
  File.write(File.join(root, "#{profile}_#{mode_name}_copy_full.tsv"), copy_full)
  File.write(File.join(root, "#{profile}_#{mode_name}_copy_pk3_6.tsv"), copy_selected)
end

def w122_expect_comparator_controls : Nil
  correct = Bytes[0x61_u8, 0x62_u8]
  wrong = Bytes[0x61_u8, 0x63_u8]
  begin
    w122_assert_bytes(correct, wrong, "W122 wrong-byte comparator control")
  rescue error : W122Mismatch
    w122_require(error.message.to_s.starts_with?("W122 wrong-byte comparator control: byte vector differs"), "W122 wrong-byte comparator raised an unrelated failure")
  else
    w122_fail("W122 one-byte wrong-literal control was accepted")
  end

  object_raw = W116JsonPhysicalVectors.expected_raw_stream("typed_mixed", "payload.object_structure")
  wrong_object_raw = Bytes.new(object_raw.size) { |index| object_raw[index] }
  wrong_object_raw[wrong_object_raw.size - 1] ^= 1_u8
  begin
    w122_assert_unchanged_physical_stream("typed_mixed", "payload.object_structure", wrong_object_raw, object_raw,
      "W122 wrong Object shared-statistic control")
  rescue error : W116JsonPhysicalMismatch
    w122_require(error.message.to_s.includes?("object_structure differs"), "W122 Object statistics control failed for an unrelated reason")
  else
    w122_fail("W122 wrong Object shared statistic was accepted")
  end

  expected_grid = [{0_u64, 0_u64, 2_u64}, {0_u64, 2_u64, 0_u64}]
  wrong_grid = [{0_u64, 0_u64, 2_u64}, {0_u64, 2_u64, 1_u64}]
  begin
    w122_assert_grid(wrong_grid, expected_grid, "W122 wrong-mark comparator control")
  rescue error : W122Mismatch
    w122_require(error.message.to_s.starts_with?("W122 wrong-mark comparator control: physical mark grid differs"), "W122 wrong-mark comparator raised an unrelated failure")
  else
    w122_fail("W122 wrong outer mark count control was accepted")
  end

  one_mark = W122BulkVectors.expected_granules("dynamic_paths", "a", 0, 1)
  changed_first = one_mark[0].dup
  changed_first[0] = CrystalClick::BinaryValue.int64(-10_i64)
  wrong_values = [changed_first]
  begin
    w122_assert_value_rows(one_mark, wrong_values, "W122 wrong-value comparator control")
  rescue error : W122Mismatch
    w122_require(error.message.to_s.starts_with?("W122 wrong-value comparator control: Dynamic BinaryValue rows differ"), "W122 wrong-value comparator raised an unrelated failure")
  else
    w122_fail("W122 wrong logical literal control was accepted")
  end

  two_marks = W122BulkVectors.expected_granules("dynamic_paths", "a", 0, 2)
  begin
    w122_assert_value_rows(two_marks, [two_marks[0]], "W122 wrong-count comparator control")
  rescue error : W122Mismatch
    w122_require(error.message.to_s.starts_with?("W122 wrong-count comparator control: Dynamic BinaryValue rows differ"), "W122 wrong-count comparator raised an unrelated failure")
  else
    w122_fail("W122 wrong selected child count control was accepted")
  end

  begin
    w122_assert_check("w122_control_part\t0\t\n", "w122_control_part", "W122 CHECK=0 comparator control")
  rescue error : W122Mismatch
    w122_require(error.message.to_s.starts_with?("W122 CHECK=0 comparator control: CHECK output mismatch"), "W122 CHECK=0 comparator raised an unrelated failure")
  else
    w122_fail("W122 CHECK=0 control was accepted")
  end
  puts "PASS W122 wrong literal/value/count/mark and CHECK=0 comparator controls"
end

def w122_writer_profile(binary : String, source_store : String, source_table : String, source_part_name : String, source_part : String, root : String, profile : String, json_type : String, mode : UInt64) : Nil
  mode_name = mode == W121DiscriminatorVectors::MODE_BASIC ? "basic" : "compact"
  store = File.join(root, "stores", "#{profile}_#{mode_name}")
  w122_require(!File.exists?(store) && !File.symlink?(File.dirname(store)), "#{profile}/#{mode_name}: W122 store already exists or parent is unsafe")
  FileUtils.mkdir_p(store)
  w122_require(Dir.exists?(store) && !File.symlink?(store), "#{profile}/#{mode_name}: failed to create isolated store")
  table = w122_profile_table(binary, store, profile, json_type)
  data_path = w122_attach_path(binary, store, table)
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  w122_store_child(detached, store, "#{profile}/#{mode_name} detached directory")
  destination = File.join(detached, source_part_name)
  w122_require(!File.exists?(destination) && !File.symlink?(detached), "#{profile}/#{mode_name}: detached destination is occupied or unsafe")
  FileUtils.cp_r(source_part, destination)
  copied = w122_store_child(destination, store, "#{profile}/#{mode_name} isolated copied part")
  w122_assert_tree(copied, "#{profile}/#{mode_name} copied part before surgery")
  inventory_before = Dir.children(copied).sort

  changed_bins = [] of String
  W122BulkVectors.dynamic_paths(profile).each do |path|
    changed_bins.concat(w122_encode_path(profile, path, mode, copied, "W122 #{profile}/#{mode_name}"))
  end
  w122_require(changed_bins.uniq.size == changed_bins.size, "#{profile}/#{mode_name}: encoder rewrote a physical stream more than once")
  w122_rewrite_checksums(copied, changed_bins)
  w122_assert_tree(copied, "#{profile}/#{mode_name} copied part after surgery")
  w122_require(Dir.children(copied).sort == inventory_before, "#{profile}/#{mode_name}: part inventory changed during stream surgery")

  w122_run(binary, store, "ALTER TABLE default.#{table} ATTACH PART '#{source_part_name}'")
  check = w122_run(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated")
  w122_assert_check(check, source_part_name, "W122 #{profile}/#{mode_name} authored ATTACH")
  attached_name, attached_path = w122_part(binary, store, table, "W122 #{profile}/#{mode_name} attached part")
  w122_require(attached_name == source_part_name, "#{profile}/#{mode_name}: attached part name changed")
  w122_assert_tree(attached_path, "#{profile}/#{mode_name} attached part")
  w122_assert_attached_physical_profile(profile, attached_path, mode, "W122 #{profile}/#{mode_name} ATTACH")
  w122_assert_retained_profile(profile, attached_path, "W122 #{profile}/#{mode_name} ATTACH", mode)
  w122_assert_live_documents(binary, source_store, store, source_table, table, root, profile, mode_name)
  puts "PASS W122 isolated stock ATTACH/CHECK=1 and full/pk3..6 semantic values: #{profile}/#{mode_name} part=#{attached_name}"
end

def w122_check : Nil
  binary = ENV["CLICKHOUSE_BIN"]? || raise "CLICKHOUSE_BIN is required"
  capture_root = ENV["W115_CAPTURE_ROOT"]? || raise "W115_CAPTURE_ROOT is required"
  temp_root = ENV["W122_TMP_ROOT"]? || raise "W122_TMP_ROOT is required"
  capture_root = File.realpath(capture_root)
  temp_root = File.realpath(temp_root)
  w122_require(capture_root.starts_with?("/private/tmp/crystal-click-json-w115.") && !File.symlink?(capture_root), "unsafe W115 capture root")
  w122_require(temp_root.starts_with?("/private/tmp/crystal-click-json-w122.") && !File.symlink?(temp_root), "unsafe W122 temporary root")
  source_store = File.realpath(File.join(capture_root, "store"))
  w122_require(source_store.starts_with?(capture_root + "/") && !File.symlink?(File.join(capture_root, "store")), "unsafe W115 source store")
  w122_require(File.file?(File.join(capture_root, "capture.log")) && !File.symlink?(File.join(capture_root, "capture.log")), "W115 capture log is missing or unsafe")
  w122_require(File.file?(File.join(capture_root, "input.jsonl")) && !File.symlink?(File.join(capture_root, "input.jsonl")), "W115 literal input is missing or unsafe")
  w122_require(Dir.empty?(temp_root), "W122 temporary root must be fresh and empty")

  w122_verify_runtime(binary, source_store)
  w122_expect_comparator_controls
  w122_require(W122BulkVectors::PROFILES.to_a.sort == ["dynamic_paths", "typed_mixed"].sort, "W122 literal profile inventory changed")

  source_parts = {} of String => Tuple(String, String)
  {"dynamic_paths", "typed_mixed"}.each do |profile|
    {false, true}.each do |attached|
      name, part = w122_retained_part(binary, source_store, profile, attached)
      if attached
        source_name = source_parts[profile]?.try(&.[0]) || w122_fail("W115 #{profile}: source part was not inspected first")
        w122_require(source_name == name, "W115 #{profile}: source/fresh-ATTACH part names differ")
      else
        source_parts[profile] = {name, part}
      end
      w122_assert_retained_profile(profile, part, "W115 #{profile} #{attached ? "fresh ATTACH" : "source"}")
    end
  end
  puts "PASS W122 retained source and fresh-ATTACH recursive Dynamic values: both captured profiles"

  profiles = [
    {"dynamic_paths", "JSON(max_dynamic_paths=16, max_dynamic_types=8)"},
    {"typed_mixed", "JSON(a UInt64, max_dynamic_paths=1, max_dynamic_types=1)"},
  ]
  profiles.each do |profile, json_type|
    source_part_name, source_part = source_parts[profile]
    source_table = "w115_#{profile}_source"
    {W121DiscriminatorVectors::MODE_BASIC, W121DiscriminatorVectors::MODE_COMPACT}.each do |mode|
      w122_writer_profile(binary, source_store, source_table, source_part_name, source_part, temp_root, profile, json_type, mode)
    end
  end
  puts "PASS W122 scope: captured W115 profiles only; no blanket stock claim for all BinaryDataType shapes"
end

w122_check
