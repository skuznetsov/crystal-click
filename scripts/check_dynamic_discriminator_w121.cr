# W121 qualifies the paired Dynamic discriminator stream/mark schedule owner.
# It does not assemble or validate Dynamic child value lanes.
require "file_utils"
require "../src/crystal_click"
require "./w115_json_semantic_vectors"
require "./w116_json_physical_vectors" # Independent retained-part/schema baseline only.
require "./w120_structure_vectors"
require "./w121_discriminator_vectors"

W121_VERSION           = "26.10.1.1201"
W121_BUILD_HASH        = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
W121_EXECUTABLE_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
W121_SETTINGS          = "index_granularity=2, index_granularity_bytes=10485760, enable_mixed_granularity_parts=1, min_rows_for_wide_part=0, min_bytes_for_wide_part=0, compress_marks=0, compress_primary_key=0, min_compress_block_size=0, max_compress_block_size=4096, default_compression_codec='LZ4', object_serialization_version='v3', object_shared_data_serialization_version_for_zero_level_parts='map'"
W121_PROFILES          = [
  {"dynamic_paths", "JSON(max_dynamic_paths=16, max_dynamic_types=8)"},
  {"typed_mixed", "JSON(a UInt64, max_dynamic_paths=1, max_dynamic_types=1)"},
]

class W121Mismatch < Exception
end

def w121_fail(message : String) : NoReturn
  raise W121Mismatch.new(message)
end

def w121_require(condition : Bool, message : String) : Nil
  w121_fail(message) unless condition
end

def w121_run(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: error)
  raise "ClickHouse local query failed: #{error}\n#{query}" unless status.success?
  output.to_s
end

def w121_run_status(binary : String, arguments : Array(String)) : String
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run(binary, arguments, output: output, error: error)
  raise "ClickHouse command failed: #{error}" unless status.success?
  output.to_s
end

def w121_store_child(path : String, store : String, label : String) : String
  real_store = File.realpath(store)
  real_path = File.realpath(path)
  unless real_path.starts_with?(real_store + "/") && !File.symlink?(path)
    w121_fail("#{label}: path escapes its isolated store or is a symlink")
  end

  relative = real_path[(real_store.size + 1)..]
  cursor = real_store
  relative.split('/').each do |component|
    cursor = File.join(cursor, component)
    w121_fail("#{label}: symlink in store path") if File.symlink?(cursor)
  end
  real_path
end

def w121_assert_tree(path : String, label : String) : Nil
  w121_require(Dir.exists?(path) && !File.symlink?(path), "#{label}: unsafe/missing directory")
  Dir.children(path).each do |name|
    child = File.join(path, name)
    w121_require(!File.symlink?(child), "#{label}: symlink child #{name.inspect}")
    if Dir.exists?(child)
      w121_assert_tree(child, "#{label}/#{name}")
    else
      w121_require(File.file?(child), "#{label}: non-file child #{name.inspect}")
    end
  end
end

def w121_part(binary : String, store : String, table : String, label : String) : Tuple(String, String)
  rows = w121_run(binary, store,
    "SELECT name, path, part_type, toString(rows) FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").lines
  w121_require(rows.size == 1, "#{label}: expected exactly one active part, got #{rows.size}")
  fields = rows.first.split('\t')
  w121_require(fields.size == 4 && fields[2] == "Wide" && fields[3] == "8", "#{label}: expected one Wide eight-row part")
  {fields[0], w121_store_child(fields[1], store, "#{label} part")}
end

def w121_assert_check(actual : String, part_name : String, label : String) : Nil
  expected = "#{part_name}\t1\t\n"
  w121_fail("#{label}: CHECK output mismatch: #{actual.inspect}") unless actual == expected
end

def w121_verify_runtime(binary : String, store : String) : Nil
  version = w121_run_status(binary, ["local", "--version"]).strip
  expected_version = "ClickHouse local version #{W121_VERSION} (official build)."
  w121_require(version == expected_version, "unexpected ClickHouse version: #{version.inspect}")

  digest = w121_run_status("shasum", ["-a", "256", binary]).split(' ').first? || ""
  w121_require(digest == W121_EXECUTABLE_SHA256, "unexpected ClickHouse executable SHA-256")

  build = w121_run(binary, store,
    "SELECT name || '=' || value FROM system.build_options WHERE name IN ('GIT_HASH', 'VERSION_GITHASH') ORDER BY name FORMAT TSVRaw").lines.map(&.strip)
  w121_require(build == ["GIT_HASH=#{W121_BUILD_HASH}", "VERSION_GITHASH=#{W121_BUILD_HASH}"], "unexpected ClickHouse build identity")
end

def w121_read_compressed(part : String, logical : String) : Bytes
  name = "#{CrystalClick::StreamName.hash(logical)}.bin"
  path = File.join(part, name)
  w121_require(File.file?(path) && !File.symlink?(path), "#{logical}: unsafe/missing .bin")
  physical = File.read(path).to_slice
  w121_require(!physical.empty?, "#{logical}: empty compressed stream")
  CrystalClick::CompressedBlock.decode_all(physical)
end

def w121_read_marks(part : String, logical : String) : Array(Tuple(UInt64, UInt64, UInt64))
  name = "#{CrystalClick::StreamName.hash(logical)}.mrk2"
  path = File.join(part, name)
  w121_require(File.file?(path) && !File.symlink?(path), "#{logical}: unsafe/missing .mrk2")
  bytes = File.read(path).to_slice
  w121_require(bytes.size == 120 && bytes.size % 24 == 0, "#{logical}: expected five plain Wide marks")
  result = [] of Tuple(UInt64, UInt64, UInt64)
  5.times do |index|
    start = index * 24
    result << {
      w121_read_u64_at(bytes, start),
      w121_read_u64_at(bytes, start + 8),
      w121_read_u64_at(bytes, start + 16),
    }
  end
  result
end

def w121_read_u64_at(bytes : Bytes, offset : Int32) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

def w121_assert_mark_grid(actual : Array(Tuple(UInt64, UInt64, UInt64)), profile : String, path : String, mode : UInt64, label : String) : Nil
  offsets = W121DiscriminatorVectors.mark_offsets(profile, path, mode)
  w121_require(actual.size == 5, "#{label}: expected four real marks and one terminal")
  actual.each_with_index do |(compressed, decompressed, rows), index|
    w121_require(compressed == 0_u64, "#{label}: nonzero compressed mark offset is outside the W121 copied-profile boundary")
    w121_require(decompressed == offsets[index], "#{label}: decompressed mark #{index} offset differs")
    expected_rows = index < 4 ? 2_u64 : 0_u64
    w121_require(rows == expected_rows, "#{label}: mark #{index} row count differs")
  end
end

def w121_encoded_mark_grid(encoded : CrystalClick::DynamicDiscriminatorStream, profile : String, path : String, mode : UInt64) : Array(Tuple(UInt64, UInt64, UInt64))
  offsets = W121DiscriminatorVectors.mark_offsets(profile, path, mode)
  detached_marks = encoded.marks
  w121_require(encoded.mark_count == offsets.size && detached_marks.size == offsets.size,
    "#{profile}.#{path}: encoded mark inventory differs")

  grid = [] of Tuple(UInt64, UInt64, UInt64)
  offsets.each_with_index do |offset, index|
    indexed_mark = encoded.mark_at(index)
    detached_mark = detached_marks[index]
    expected_rows = index < 4 ? 2_u64 : 0_u64
    w121_require(indexed_mark.offset.to_u64 == offset && detached_mark.offset.to_u64 == offset,
      "#{profile}.#{path}: encoded mark #{index} offset differs")
    w121_require(indexed_mark.rows.to_u64 == expected_rows && detached_mark.rows.to_u64 == expected_rows,
      "#{profile}.#{path}: encoded mark #{index} rows differ")
    grid << {0_u64, indexed_mark.offset.to_u64, indexed_mark.rows.to_u64}
  end
  grid
end

def w121_stream_model(raw : Bytes, grid : Array(Tuple(UInt64, UInt64, UInt64))) : CrystalClick::DynamicDiscriminatorStream
  marks = grid.map do |(_compressed, offset, rows)|
    CrystalClick::DynamicDiscriminatorMark.new(offset: offset, rows: rows)
  end
  CrystalClick::DynamicDiscriminatorStream.new(raw, marks)
end

def w121_assert_bytes(actual : Bytes, expected : Bytes, label : String) : Nil
  w121_fail("#{label}: byte vector differs (#{actual.size} vs #{expected.size} bytes)") unless actual == expected
end

def w121_expect_byte_mismatch(actual : Bytes, wrong_expected : Bytes, label : String) : Nil
  begin
    w121_assert_bytes(actual, wrong_expected, label)
  rescue error : W121Mismatch
    w121_require(error.message.to_s.starts_with?("#{label}: byte vector differs"), "#{label}: byte comparator control failed for an unrelated reason")
    return
  end
  w121_fail("#{label}: one-byte expected-vector change was accepted")
end

def w121_expect_schedule_mismatch(actual : Array(CrystalClick::DynamicMarkSchedule), wrong_expected : Array(W121ExpectedSchedule), label : String) : Nil
  begin
    w121_assert_schedules(actual, wrong_expected, label)
  rescue error : W121Mismatch
    w121_require(error.message.to_s.starts_with?("#{label}: sparse schedule differs"), "#{label}: schedule comparator control failed for an unrelated reason")
    return
  end
  w121_fail("#{label}: wrong expected sparse schedule was accepted")
end

def w121_expect_check_zero_rejected(part_name : String) : Nil
  actual = "#{part_name}\t0\t\n"
  begin
    w121_assert_check(actual, part_name, "W121 CHECK=0 comparator control")
  rescue error : W121Mismatch
    w121_require(error.message.to_s.starts_with?("W121 CHECK=0 comparator control: CHECK output mismatch"),
      "W121 CHECK=0 comparator control failed for an unrelated reason")
    puts "PASS W121 CHECK comparator control: rejected CHECK=0"
    return
  end
  w121_fail("W121 CHECK comparator control accepted CHECK=0")
end

def w121_schedules_match?(actual : Array(CrystalClick::DynamicMarkSchedule), expected : Array(W121ExpectedSchedule)) : Bool
  return false unless actual.size == expected.size
  actual.each_with_index.all? do |schedule, index|
    wanted = expected[index]
    schedule.mark_index.to_u64 == wanted.mark_index &&
      schedule.first_row.to_u64 == wanted.first_row &&
      schedule.tags == wanted.tags &&
      schedule.ranks == wanted.ranks &&
      schedule.arm_counts == wanted.arm_counts &&
      schedule.arm_offsets == wanted.arm_offsets
  end
end

def w121_assert_schedules(actual : Array(CrystalClick::DynamicMarkSchedule), expected : Array(W121ExpectedSchedule), label : String) : Nil
  w121_fail("#{label}: sparse schedule differs from independent tag/rank/count/offset literal") unless w121_schedules_match?(actual, expected)
end

def w121_assert_decode_windows(profile : String, path : String, structure : CrystalClick::DynamicStructure, stream : CrystalClick::DynamicDiscriminatorStream, label : String) : Nil
  limits = CrystalClick::BinaryCodecLimits.default
  full = CrystalClick::DynamicDiscriminatorCodec.decode(structure, stream, first_mark: 0, mark_count: 4, limits: limits)
  w121_assert_schedules(full, W121DiscriminatorVectors.schedules(profile, path), "#{label} full")

  selected = CrystalClick::DynamicDiscriminatorCodec.decode(structure, stream, first_mark: 1, mark_count: 3, limits: limits)
  w121_assert_schedules(selected, W121DiscriminatorVectors.schedules(profile, path, 1, 3), "#{label} nonzero-origin pk3..8")

  terminal_empty = CrystalClick::DynamicDiscriminatorCodec.decode(structure, stream, first_mark: 4, mark_count: 0, limits: limits)
  w121_require(terminal_empty.empty?, "#{label}: zero-mark terminal selection was not empty")
end

def w121_assert_encoded(profile : String, path : String, mode : UInt64) : CrystalClick::DynamicDiscriminatorStream
  structure = W121DiscriminatorVectors.dynamic(profile, path)
  rows = W121DiscriminatorVectors.rows(profile, path)
  encoded = CrystalClick::DynamicDiscriminatorCodec.encode(
    structure, rows, mode: mode, limits: CrystalClick::BinaryCodecLimits.default
  )
  expected = W121DiscriminatorVectors.stream_bytes(profile, path, mode)
  w121_assert_bytes(encoded.bytes, expected, "#{profile}.#{path} mode=#{mode} independent full bytes")
  w121_require(encoded.byte_size.to_u64 == expected.size.to_u64, "#{profile}.#{path}: encoded byte_size differs")
  grid = w121_encoded_mark_grid(encoded, profile, path, mode)
  w121_assert_mark_grid(grid, profile, path, mode, "#{profile}.#{path} encoded")
  w121_assert_decode_windows(profile, path, structure, encoded, "#{profile}.#{path} mode=#{mode} encoded")
  encoded
end

def w121_assert_retained_stream(profile : String, path : String, part : String, role : String) : CrystalClick::DynamicDiscriminatorStream
  logical = "payload.#{W120StructureVectors.physical_path(path)}.variant_discr"
  raw = w121_read_compressed(part, logical)
  expected_raw = W121DiscriminatorVectors.stream_bytes(profile, path, W121DiscriminatorVectors::MODE_COMPACT)
  w121_assert_bytes(raw, expected_raw, "W115 #{profile} #{role} #{path} literal COMPACT stream")
  grid = w121_read_marks(part, logical)
  w121_assert_mark_grid(grid, profile, path, W121DiscriminatorVectors::MODE_COMPACT, "W115 #{profile} #{role} #{path}")
  stream = w121_stream_model(raw, grid)
  w121_assert_decode_windows(profile, path, W121DiscriminatorVectors.dynamic(profile, path), stream, "W115 #{profile} #{role} #{path}")
  stream
end

def w121_run_local_controls : Nil
  W121_PROFILES.each do |profile, _json_type|
    W121DiscriminatorVectors.dynamic(profile, "s")
  end

  # Pin one tiny byte vector directly as well as the generated seven-stream
  # vectors, so an accidental grammar edit cannot self-confirm its own helper.
  basic_a = [0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8,
             0_u8, 255_u8, 0_u8, 255_u8, 0_u8, 0_u8, 0_u8, 0_u8]
  compact_a = [1_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8,
               2_u8, 0_u8, 0_u8, 255_u8, 2_u8, 0_u8, 0_u8, 255_u8,
               2_u8, 1_u8, 0_u8, 2_u8, 1_u8, 0_u8]
  basic_a_bytes = Bytes.new(basic_a.size) { |index| basic_a[index] }
  compact_a_bytes = Bytes.new(compact_a.size) { |index| compact_a[index] }
  w121_require(W121DiscriminatorVectors.stream_bytes("dynamic_paths", "a", 0_u64) == basic_a_bytes,
    "W121 independently authored BASIC byte anchor differs")
  w121_require(W121DiscriminatorVectors.stream_bytes("dynamic_paths", "a", 1_u64) == compact_a_bytes,
    "W121 independently authored COMPACT byte anchor differs")

  streams = {} of Tuple(String, String) => CrystalClick::DynamicDiscriminatorStream
  W121_PROFILES.each do |profile, _json_type|
    entry = W121DiscriminatorVectors::PROFILES.find { |candidate, _paths| candidate == profile } ||
            w121_fail("W121 literal path inventory omits #{profile}")
    entry[1].each do |path|
      {0_u64, 1_u64}.each do |mode|
        stream = w121_assert_encoded(profile, path, mode)
        streams[{profile, path}] = stream if profile == "dynamic_paths" && path == "a" && mode == 1_u64
      end
    end
  end

  actual_a = CrystalClick::DynamicDiscriminatorCodec.decode(
    W121DiscriminatorVectors.dynamic("dynamic_paths", "a"), streams[{"dynamic_paths", "a"}],
    first_mark: 0, mark_count: 4, limits: CrystalClick::BinaryCodecLimits.default
  )
  wrong_tags = W121DiscriminatorVectors.with_wrong_first_tag(W121DiscriminatorVectors.schedules("dynamic_paths", "a"))
  w121_expect_schedule_mismatch(actual_a, wrong_tags, "W121 wrong-tag comparator control")

  actual_s = CrystalClick::DynamicDiscriminatorCodec.decode(
    W121DiscriminatorVectors.dynamic("dynamic_paths", "s"),
    CrystalClick::DynamicDiscriminatorCodec.encode(
      W121DiscriminatorVectors.dynamic("dynamic_paths", "s"),
      W121DiscriminatorVectors.rows("dynamic_paths", "s"), mode: 0_u64,
      limits: CrystalClick::BinaryCodecLimits.default
    ),
    first_mark: 0, mark_count: 4, limits: CrystalClick::BinaryCodecLimits.default
  )
  wrong_ranks = W121DiscriminatorVectors.with_wrong_first_rank(W121DiscriminatorVectors.schedules("dynamic_paths", "s"))
  w121_expect_schedule_mismatch(actual_s, wrong_ranks, "W121 wrong-rank comparator control")

  one_byte_wrong = W121DiscriminatorVectors.stream_bytes("dynamic_paths", "a", 1_u64).dup
  one_byte_wrong[0] ^= 1_u8
  w121_expect_byte_mismatch(streams[{"dynamic_paths", "a"}].bytes, one_byte_wrong, "W121 one-byte byte-vector comparator control")
  w121_expect_check_zero_rejected("w121_control_part")
  puts "PASS W121 independent byte anchor and wrong-tag/rank/one-byte comparator controls"
end

def w121_retained_part(binary : String, store : String, profile : String, attached : Bool) : Tuple(String, String)
  table = "w115_#{profile}_#{attached ? "attached" : "source"}"
  part_name, part_path = w121_part(binary, store, table, "W115 #{profile} #{table}")
  w121_assert_tree(part_path, "W115 #{profile} #{table} retained part")
  check = w121_run(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated")
  w121_assert_check(check, part_name, "W115 #{profile} #{table}")
  W116JsonPhysicalVectors.assert_part(profile, part_path, attached: attached)
  {part_name, part_path}
end

def w121_write_u32_le(bytes : Bytes, offset : Int32, value : UInt32) : Nil
  4.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u32).to_u8 }
end

def w121_write_u64_le(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
end

def w121_write_u64_at(bytes : Bytes, offset : Int32, value : UInt64) : Nil
  8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

def w121_write_hash128(bytes : Bytes, offset : Int32, hash : {UInt64, UInt64}) : Nil
  w121_write_u64_at(bytes, offset, hash[0])
  w121_write_u64_at(bytes, offset + 8, hash[1])
end

def w121_write_hash128(io : IO, hash : {UInt64, UInt64}) : Nil
  w121_write_u64_le(io, hash[0])
  w121_write_u64_le(io, hash[1])
end

def w121_write_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

# Test-only literal LZ4 frame used for changed-size discriminator streams and
# the copied part checksum manifest. No retained W115 file is modified.
def w121_literal_lz4_frame(raw : Bytes) : Bytes
  raise "cannot encode an empty W121 LZ4 frame" if raw.empty?
  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w121_write_u32_le(frame, header + 1, compressed_size.to_u32)
  w121_write_u32_le(frame, header + 5, raw.size.to_u32)

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
  w121_write_hash128(frame, 0, hash)
  frame
end

def w121_rewrite_marks(part : String, logical : String, grid : Array(Tuple(UInt64, UInt64, UInt64))) : Nil
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical)}.mrk2")
  w121_require(File.file?(path) && !File.symlink?(path), "#{logical}: unsafe/missing .mrk2")
  original = File.read(path).to_slice
  w121_require(original.size == 120 && original.size % 24 == 0 && grid.size == 5, "#{logical}: expected five plain Wide marks")
  marks = Bytes.new(original.size) { |index| original[index] }
  5.times do |index|
    mark_offset = index * 24
    w121_require(w121_read_u64_at(marks, mark_offset) == 0_u64, "#{logical}: nonzero compressed mark offset is outside W121 surgery")
    expected_rows = index < 4 ? 2_u64 : 0_u64
    w121_require(w121_read_u64_at(marks, mark_offset + 16) == expected_rows, "#{logical}: unexpected W115 mark row count")
    compressed, decompressed, rows = grid[index]
    w121_require(compressed == 0_u64 && rows == expected_rows, "#{logical}: encoded mark grid is outside W121 surgery boundary")
    w121_write_u64_at(marks, mark_offset, compressed)
    w121_write_u64_at(marks, mark_offset + 8, decompressed)
    w121_write_u64_at(marks, mark_offset + 16, rows)
  end
  File.write(path, marks)
end

def w121_replace_stream(part : String, logical : String, encoded : CrystalClick::DynamicDiscriminatorStream, profile : String, path : String, mode : UInt64) : Nil
  raw = encoded.bytes
  expected = W121DiscriminatorVectors.stream_bytes(profile, path, mode)
  w121_assert_bytes(raw, expected, "#{logical} independently authored test stream")
  grid = w121_encoded_mark_grid(encoded, profile, path, mode)
  w121_assert_mark_grid(grid, profile, path, mode, "#{logical} production-encoded mark grid")
  bin_path = File.join(part, "#{CrystalClick::StreamName.hash(logical)}.bin")
  w121_require(File.file?(bin_path) && !File.symlink?(bin_path), "#{logical}: unsafe/missing .bin")
  frame = w121_literal_lz4_frame(raw)
  w121_require(CrystalClick::CompressedBlock.decode_all(frame) == raw, "#{logical}: LZ4 re-encoding changed bytes")
  File.write(bin_path, frame)
  w121_rewrite_marks(part, logical, grid)
end

def w121_rewrite_checksums(part : String, changed_bins : Array(String)) : Nil
  original = CrystalClick::PartChecksums.open(part)
  names = original.entries.keys.sort
  w121_require(!names.empty? && !names.includes?("checksums.txt"), "W121 copy has unexpected checksum inventory")
  changed_bins.each do |name|
    w121_require(names.includes?(name), "W121 changed stream is absent from checksum inventory: #{name}")
  end

  payload = IO::Memory.new
  w121_write_varuint(payload, names.size.to_u64)
  names.each do |name|
    w121_require(name == File.basename(name) && name != "." && name != "..", "W121 checksum entry has unsafe path #{name.inspect}")
    path = File.join(part, name)
    w121_require(File.file?(path) && !File.symlink?(path), "W121 copied part has unsafe/missing file #{name}")
    physical = File.read(path).to_slice
    entry = original.entry(name) || w121_fail("W121 copied part lost checksum entry #{name}")
    changed = changed_bins.includes?(name)
    w121_require(!changed || entry.compressed, "W121 changed stream is not compressed: #{name}")
    raw = if entry.compressed
            physical.empty? ? Bytes.empty : CrystalClick::CompressedBlock.decode_all(physical)
          else
            physical
          end
    if entry.compressed && !changed
      expected_raw_size = entry.uncompressed_size || w121_fail("compressed checksum entry #{name} has no raw size")
      w121_require(raw.size.to_u64 == expected_raw_size, "unchanged copied stream raw size differs from checksum entry #{name}")
    end

    w121_write_varuint(payload, name.bytesize.to_u64)
    payload.write(name.to_slice)
    w121_write_varuint(payload, physical.size.to_u64)
    w121_write_hash128(payload, CrystalClick::CityHashV1.file_hash(physical))
    if entry.compressed
      payload.write_byte(1_u8)
      w121_write_varuint(payload, raw.size.to_u64)
      w121_write_hash128(payload, CrystalClick::CityHashV1.file_hash(raw))
    else
      payload.write_byte(0_u8)
    end
  end

  manifest = IO::Memory.new
  manifest << CrystalClick::PartChecksums::CHECKSUMS_HEADER
  manifest.write(w121_literal_lz4_frame(payload.to_slice))
  File.write(File.join(part, "checksums.txt"), manifest.to_slice)

  rewritten = CrystalClick::PartChecksums.open(part)
  w121_require(rewritten.entries.keys.sort == names, "W121 rewritten checksum inventory changed")
  names.each { |name| rewritten.validate_selected_entries(part, name) }
end

def w121_profile_table(binary : String, store : String, profile : String, json_type : String) : String
  table = "w121_#{profile}"
  w121_run(binary, store,
    "CREATE TABLE default.#{table} (pk UInt64, payload #{json_type}) ENGINE=MergeTree ORDER BY pk SETTINGS #{W121_SETTINGS}")
  schema = w121_run(binary, store,
    "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw")
  expected_schema = W116JsonPhysicalVectors.expected_schema(profile)
  w121_require(schema == expected_schema, "#{profile}: isolated table schema differs from the retained W115 profile")
  table
end

def w121_attach_path(binary : String, store : String, table : String) : String
  path = w121_run(binary, store,
    "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  w121_store_child(path, store, "W121 #{table} table data path")
end

def w121_assert_live_documents(binary : String, source_store : String, writer_store : String, source_table : String, writer_table : String, root : String, profile : String, mode_name : String) : Nil
  full_query = "SELECT pk, toJSONString(payload) FROM default.%s ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw"
  selected_query = "SELECT pk, toJSONString(payload) FROM default.%s WHERE pk >= 3 AND pk <= 8 ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw"
  source_full = w121_run(binary, source_store, full_query % source_table)
  source_selected = w121_run(binary, source_store, selected_query % source_table)
  copy_full = w121_run(binary, writer_store, full_query % writer_table)
  copy_selected = w121_run(binary, writer_store, selected_query % writer_table)

  w115_assert_semantic_documents(source_full, profile, false, "W121 #{profile} retained source full")
  w121_assert_semantic_window(source_selected, profile, "W121 #{profile} retained source selected pk3..8")
  w115_assert_semantic_documents(copy_full, profile, false, "W121 #{profile} copied ATTACH full")
  w121_assert_semantic_window(copy_selected, profile, "W121 #{profile} copied ATTACH selected pk3..8")
  File.write(File.join(root, "#{profile}_#{mode_name}_source_documents_full.tsv"), source_full)
  File.write(File.join(root, "#{profile}_#{mode_name}_source_documents_pk3_8.tsv"), source_selected)
  File.write(File.join(root, "#{profile}_#{mode_name}_copy_documents_full.tsv"), copy_full)
  File.write(File.join(root, "#{profile}_#{mode_name}_copy_documents_pk3_8.tsv"), copy_selected)
  puts "PASS W121 independent literal documents: #{profile}/#{mode_name} copied ATTACH full and selected pk3..8"

  # Supplementary differential only; the RowBinary bytes have no literal oracle.
  rowbinary_full = "SELECT pk, payload FROM default.%s ORDER BY pk FORMAT RowBinary"
  rowbinary_selected = "SELECT pk, payload FROM default.%s WHERE pk >= 3 AND pk <= 8 ORDER BY pk FORMAT RowBinary"
  source_full_binary = w121_run(binary, source_store, rowbinary_full % source_table)
  source_selected_binary = w121_run(binary, source_store, rowbinary_selected % source_table)
  copy_full_binary = w121_run(binary, writer_store, rowbinary_full % writer_table)
  copy_selected_binary = w121_run(binary, writer_store, rowbinary_selected % writer_table)
  w121_assert_bytes(copy_full_binary.to_slice, source_full_binary.to_slice, "#{profile}/#{mode_name} supplementary RowBinary full")
  w121_assert_bytes(copy_selected_binary.to_slice, source_selected_binary.to_slice, "#{profile}/#{mode_name} supplementary RowBinary selected")
  File.write(File.join(root, "#{profile}_#{mode_name}_copy_rowbinary_full.bin"), copy_full_binary)
  File.write(File.join(root, "#{profile}_#{mode_name}_copy_rowbinary_pk3_8.bin"), copy_selected_binary)
  puts "PASS W121 supplementary RowBinary source/copy differential: #{profile}/#{mode_name} full and pk3..8"
end

def w121_assert_semantic_window(actual_tsv : String, profile : String, label : String) : Nil
  expected_rows = w115_semantic_expected(profile, false).select do |row|
    key = row.as_h["pk"].as_i
    key >= 3 && key <= 8
  end
  actual_lines = actual_tsv.lines
  actual_lines.pop if actual_lines.last?.try(&.empty?)
  w121_require(actual_lines.size == expected_rows.size, "#{label}: expected six keyed JSON rows, got #{actual_lines.size}")
  actual_lines.each_with_index do |line, index|
    separator = line.index('\t') || w121_fail("#{label}: row #{index} has no TSVRaw key separator")
    actual_key = line[0, separator].to_i64?
    actual_document = JSON.parse(line[(separator + 1)..])
    expected = expected_rows[index].as_h
    expected_key = expected["pk"].as_i
    w121_require(actual_key == expected_key, "#{label}: row #{index} key differs")
    w121_require(w115_semantic_json_equal?(expected["payload"], actual_document), "#{label}: document for pk=#{expected_key} differs")
  end
end

def w121_writer_profile(binary : String, source_store : String, source_table : String, source_part_name : String, source_part : String, root : String, profile : String, json_type : String, mode : UInt64) : Nil
  mode_name = mode == 0_u64 ? "basic" : "compact"
  store = File.join(root, "stores", "#{profile}_#{mode_name}")
  w121_require(!File.exists?(store) && !File.symlink?(File.dirname(store)), "#{profile}/#{mode_name}: W121 store already exists or parent is unsafe")
  FileUtils.mkdir_p(store)
  w121_require(Dir.exists?(store) && !File.symlink?(store), "#{profile}/#{mode_name}: failed to create isolated store")

  table = w121_profile_table(binary, store, profile, json_type)
  data_path = w121_attach_path(binary, store, table)
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  w121_store_child(detached, store, "#{profile}/#{mode_name} detached directory")
  destination = File.join(detached, source_part_name)
  w121_require(!File.exists?(destination) && !File.symlink?(detached), "#{profile}/#{mode_name}: detached destination is occupied or unsafe")
  FileUtils.cp_r(source_part, destination)
  copied = w121_store_child(destination, store, "#{profile}/#{mode_name} isolated part copy")
  w121_assert_tree(copied, "#{profile}/#{mode_name} copied part before surgery")
  inventory_before = Dir.children(copied).sort

  changed_bins = [] of String
  entry = W121DiscriminatorVectors::PROFILES.find { |candidate, _paths| candidate == profile } ||
          w121_fail("W121 writer profile has no literal path inventory: #{profile}")
  entry[1].each do |path|
    logical = "payload.#{W120StructureVectors.physical_path(path)}.variant_discr"
    encoded = w121_assert_encoded(profile, path, mode)
    w121_replace_stream(copied, logical, encoded, profile, path, mode)
    changed_bins << "#{CrystalClick::StreamName.hash(logical)}.bin"
  end

  w121_rewrite_checksums(copied, changed_bins)
  w121_assert_tree(copied, "#{profile}/#{mode_name} copied part after surgery")
  w121_require(Dir.children(copied).sort == inventory_before, "#{profile}/#{mode_name}: part file inventory changed during discriminator rewrite")

  w121_run(binary, store, "ALTER TABLE default.#{table} ATTACH PART '#{source_part_name}'")
  check = w121_run(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated")
  w121_assert_check(check, source_part_name, "W121 #{profile}/#{mode_name} authored ATTACH")
  attached_name, attached_path = w121_part(binary, store, table, "W121 #{profile}/#{mode_name} attached part")
  w121_require(attached_name == source_part_name, "#{profile}/#{mode_name}: attached part name changed")
  w121_assert_tree(attached_path, "#{profile}/#{mode_name} attached part")

  entry[1].each do |path|
    logical = "payload.#{W120StructureVectors.physical_path(path)}.variant_discr"
    raw = w121_read_compressed(attached_path, logical)
    expected_raw = W121DiscriminatorVectors.stream_bytes(profile, path, mode)
    w121_assert_bytes(raw, expected_raw, "W121 #{profile}/#{mode_name} attached #{path} bytes")
    grid = w121_read_marks(attached_path, logical)
    w121_assert_mark_grid(grid, profile, path, mode, "W121 #{profile}/#{mode_name} attached #{path}")
    stream = w121_stream_model(raw, grid)
    w121_assert_decode_windows(profile, path, W121DiscriminatorVectors.dynamic(profile, path), stream, "W121 #{profile}/#{mode_name} attached #{path}")
  end
  puts "PASS W121 isolated stock ATTACH/CHECK=1: #{profile}/#{mode_name} part=#{attached_name}"
  w121_assert_live_documents(binary, source_store, store, source_table, table, root, profile, mode_name)
end

def w121_check : Nil
  binary = ENV["CLICKHOUSE_BIN"]? || raise "CLICKHOUSE_BIN is required"
  capture_root = ENV["W115_CAPTURE_ROOT"]? || raise "W115_CAPTURE_ROOT is required"
  temp_root = ENV["W121_TMP_ROOT"]? || raise "W121_TMP_ROOT is required"
  capture_root = File.realpath(capture_root)
  temp_root = File.realpath(temp_root)
  w121_require(capture_root.starts_with?("/private/tmp/crystal-click-json-w115.") && !File.symlink?(capture_root), "unsafe W115 capture root")
  w121_require(temp_root.starts_with?("/private/tmp/crystal-click-json-w121.") && !File.symlink?(temp_root), "unsafe W121 temporary root")
  source_store = File.realpath(File.join(capture_root, "store"))
  w121_require(source_store.starts_with?(capture_root + "/") && !File.symlink?(File.join(capture_root, "store")), "unsafe W115 source store")
  w121_require(File.file?(File.join(capture_root, "capture.log")) && !File.symlink?(File.join(capture_root, "capture.log")), "W115 capture log is missing or unsafe")
  w121_require(File.file?(File.join(capture_root, "input.jsonl")) && !File.symlink?(File.join(capture_root, "input.jsonl")), "W115 literal input is missing or unsafe")
  w121_require(Dir.empty?(temp_root), "W121 temporary root must be fresh and empty")

  w121_verify_runtime(binary, source_store)
  w121_run_local_controls
  w121_require(W116JsonPhysicalVectors::PROFILES.to_a.sort == ["dynamic_paths", "dynamic_shared_only", "typed_mixed"].sort,
    "W121/W116 retained profile inventories differ")

  source_parts = {} of String => Tuple(String, String)
  attached_roles = {false, true}
  decoded_streams = 0
  W121_PROFILES.each do |profile, _json_type|
    source_table = "w115_#{profile}_source"
    attached_roles.each do |attached|
      part_name, part = w121_retained_part(binary, source_store, profile, attached)
      role = attached ? "fresh ATTACH" : "source"
      if attached
        source_name = source_parts[profile]?.try(&.[0]) || w121_fail("W115 #{profile}: source part was not inspected first")
        w121_require(source_name == part_name, "W115 #{profile}: source/fresh ATTACH part names differ")
      else
        source_parts[profile] = {part_name, part}
      end

      paths = W121DiscriminatorVectors::PROFILES.find { |candidate, _paths| candidate == profile }.try(&.[1]) ||
              w121_fail("W121 retained profile has no discriminator path inventory: #{profile}")
      paths.each do |path|
        stream = w121_assert_retained_stream(profile, path, part, role)
        decoded_streams += 1
        if !attached && profile == "dynamic_paths" && path == "a"
          expected = W121DiscriminatorVectors.stream_bytes(profile, path, 1_u64)
          wrong = expected.dup
          wrong[0] ^= 1_u8
          w121_require(stream.bytes == expected && stream.bytes != wrong, "W121 retained byte comparator control was not sensitive")
        end
      end
    end
    w121_require(w121_part(binary, source_store, source_table, "W115 #{profile} source table")[0] == source_parts[profile][0],
      "W115 #{profile}: source table part identity changed")
  end
  w121_require(decoded_streams == 14, "W121 expected fourteen retained source+ATTACH discriminator streams, got #{decoded_streams}")
  puts "PASS W121 retained exact streams and schedules: #{decoded_streams} across source+ATTACH parts"

  source_parts.each do |profile, (part_name, part)|
    json_type = W121_PROFILES.find { |candidate, _type| candidate == profile }.try(&.[1]) ||
                w121_fail("W121 writer profile has no schema: #{profile}")
    source_table = "w115_#{profile}_source"
    {0_u64, 1_u64}.each do |mode|
      w121_writer_profile(binary, source_store, source_table, part_name, part, temp_root, profile, json_type, mode)
    end
  end

  puts "PASS W121: fourteen retained streams; four authored BASIC/COMPACT copied-part ATTACH/CHECK=1 profiles; no Dynamic child-value codec claimed"
end

w121_check
