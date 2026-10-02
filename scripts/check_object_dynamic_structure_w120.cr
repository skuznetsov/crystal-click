# W120 qualifies bounded complete Object/Dynamic structure metadata against
# retained W115 stock parts and three isolated stock ATTACH copies. It does not
# admit or write any value lanes.
require "file_utils"
require "../src/crystal_click"
require "./w115_json_semantic_vectors"
require "./w116_json_physical_vectors" # W116 literal baseline/schema qualification only.
require "./w120_structure_vectors"

W120_VERSION           = "26.10.1.1201"
W120_BUILD_HASH        = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
W120_EXECUTABLE_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
W120_SETTINGS          = "index_granularity=2, index_granularity_bytes=10485760, enable_mixed_granularity_parts=1, min_rows_for_wide_part=0, min_bytes_for_wide_part=0, compress_marks=0, compress_primary_key=0, min_compress_block_size=0, max_compress_block_size=4096, default_compression_codec='LZ4', object_serialization_version='v3', object_shared_data_serialization_version_for_zero_level_parts='map'"
W120_PROFILES          = {
  {"dynamic_paths", "JSON(max_dynamic_paths=16, max_dynamic_types=8)"},
  {"dynamic_shared_only", "JSON(max_dynamic_paths=0, max_dynamic_types=8)"},
  {"typed_mixed", "JSON(a UInt64, max_dynamic_paths=1, max_dynamic_types=1)"},
}

class W120Mismatch < Exception
end

def w120_fail(message : String) : NoReturn
  raise W120Mismatch.new(message)
end

def w120_require(condition : Bool, message : String) : Nil
  w120_fail(message) unless condition
end

def w120_run(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: error)
  raise "ClickHouse local query failed: #{error}\n#{query}" unless status.success?
  output.to_s
end

def w120_run_status(binary : String, arguments : Array(String)) : String
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run(binary, arguments, output: output, error: error)
  raise "ClickHouse command failed: #{error}" unless status.success?
  output.to_s
end

def w120_store_child(path : String, store : String, label : String) : String
  real_store = File.realpath(store)
  real_path = File.realpath(path)
  unless real_path.starts_with?(real_store + "/") && !File.symlink?(path)
    w120_fail("#{label}: path escapes its isolated store or is a symlink")
  end

  relative = real_path[(real_store.size + 1)..]
  cursor = real_store
  relative.split('/').each do |component|
    cursor = File.join(cursor, component)
    w120_fail("#{label}: symlink in store path") if File.symlink?(cursor)
  end
  real_path
end

def w120_assert_tree(path : String, label : String) : Nil
  w120_require(Dir.exists?(path) && !File.symlink?(path), "#{label}: unsafe/missing directory")
  Dir.children(path).each do |name|
    child = File.join(path, name)
    w120_require(!File.symlink?(child), "#{label}: symlink child #{name.inspect}")
    if Dir.exists?(child)
      w120_assert_tree(child, "#{label}/#{name}")
    else
      w120_require(File.file?(child), "#{label}: non-file child #{name.inspect}")
    end
  end
end

def w120_part(binary : String, store : String, table : String, label : String) : Tuple(String, String)
  rows = w120_run(binary, store,
    "SELECT name, path, part_type, toString(rows) FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").lines
  w120_require(rows.size == 1, "#{label}: expected exactly one active part, got #{rows.size}")
  fields = rows.first.split('\t')
  w120_require(fields.size == 4 && fields[2] == "Wide" && fields[3] == "8", "#{label}: expected one Wide eight-row part")
  {fields[0], w120_store_child(fields[1], store, "#{label} part")}
end

def w120_assert_check(actual : String, part_name : String, label : String) : Nil
  expected = "#{part_name}\t1\t\n"
  w120_fail("#{label}: CHECK output mismatch: #{actual.inspect}") unless actual == expected
end

def w120_verify_runtime(binary : String, store : String) : Nil
  version = w120_run_status(binary, ["local", "--version"]).strip
  expected_version = "ClickHouse local version #{W120_VERSION} (official build)."
  w120_require(version == expected_version, "unexpected ClickHouse version: #{version.inspect}")

  digest = w120_run_status("shasum", ["-a", "256", binary]).split(' ').first? || ""
  w120_require(digest == W120_EXECUTABLE_SHA256, "unexpected ClickHouse executable SHA-256")

  build = w120_run(binary, store,
    "SELECT name || '=' || value FROM system.build_options WHERE name IN ('GIT_HASH', 'VERSION_GITHASH') ORDER BY name FORMAT TSVRaw").lines.map(&.strip)
  w120_require(build == ["GIT_HASH=#{W120_BUILD_HASH}", "VERSION_GITHASH=#{W120_BUILD_HASH}"], "unexpected ClickHouse build identity")
end

def w120_retained_part(binary : String, store : String, profile : String, attached : Bool) : Tuple(String, String)
  table = "w115_#{profile}_#{attached ? "attached" : "source"}"
  part_name, part_path = w120_part(binary, store, table, "W115 #{profile} #{table}")
  w120_assert_tree(part_path, "W115 #{profile} #{table} retained part")
  check = w120_run(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated")
  w120_assert_check(check, part_name, "W115 #{profile} #{table}")
  {part_name, part_path}
end

def w120_read_structure(part : String, logical : String) : Bytes
  hash = CrystalClick::StreamName.hash(logical)
  path = File.join(part, "#{hash}.bin")
  w120_require(File.file?(path) && !File.symlink?(path), "#{logical}: unsafe/missing .bin")
  physical = File.read(path).to_slice
  w120_require(!physical.empty?, "#{logical}: empty compressed structure stream")
  CrystalClick::CompressedBlock.decode_all(physical)
end

def w120_read_metadata(part : String, profile : String, label : String) : CrystalClick::ObjectDynamicStructureSet
  object = w120_read_structure(part, "payload.object_structure")
  dynamics = {} of String => Bytes
  W120StructureVectors.dynamic_paths(profile).each do |path|
    physical_path = W120StructureVectors.physical_path(path)
    logical = "payload.#{physical_path}.dynamic_structure"
    dynamics[path] = w120_read_structure(part, logical)
  end
  streams = CrystalClick::ObjectDynamicStructureStreams.new(object, dynamics)
  CrystalClick::ObjectDynamicStructureCodec.decode(streams, CrystalClick::BinaryCodecLimits.default)
rescue error : Exception
  raise error if error.is_a?(W120Mismatch) || error.is_a?(CrystalClick::CorruptPartError) || error.is_a?(CrystalClick::UnsupportedFormatError)
  w120_fail("#{label}: could not decode complete structure metadata: #{error.message}")
end

def w120_assert_bytes(actual : Bytes, expected : Bytes, label : String) : Nil
  w120_fail("#{label}: byte vector differs (#{actual.size} vs #{expected.size} bytes)") unless actual == expected
end

def w120_write_var_uint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

def w120_write_uint32_le(bytes : Bytes, offset : Int32, value : UInt32) : Nil
  4.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u32).to_u8 }
end

def w120_write_uint64_le(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
end

def w120_write_hash128(bytes : Bytes, offset : Int32, hash : {UInt64, UInt64}) : Nil
  w120_write_uint64_at(bytes, offset, hash[0])
  w120_write_uint64_at(bytes, offset + 8, hash[1])
end

def w120_write_hash128(io : IO, hash : {UInt64, UInt64}) : Nil
  w120_write_uint64_le(io, hash[0])
  w120_write_uint64_le(io, hash[1])
end

# Test-only literal LZ4 framing for W120's changed-size copied structure streams
# and regenerated checksums manifest. Retained source streams are never edited.
def w120_literal_lz4_frame(raw : Bytes) : Bytes
  raise "cannot encode an empty LZ4 frame" if raw.empty?
  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w120_write_uint32_le(frame, header + 1, compressed_size.to_u32)
  w120_write_uint32_le(frame, header + 5, raw.size.to_u32)

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
  w120_write_hash128(frame, 0, hash)
  frame
end

# Rebuild the copied part's v4 manifest from its current files. Structure
# streams may now have different raw lengths; all other compressed entries must
# still match their original declared lengths. The resulting manifest is then
# reopened and every named entry is validated from disk.
def w120_rewrite_checksums(part : String, changed_bins : Array(String)) : Nil
  original = CrystalClick::PartChecksums.open(part)
  names = original.entries.keys.sort
  w120_require(!names.empty? && !names.includes?("checksums.txt"), "W120 copy has an unexpected checksum inventory")
  changed_bins.each do |name|
    w120_require(names.includes?(name), "W120 changed stream is absent from checksum inventory: #{name}")
  end

  payload = IO::Memory.new
  w120_write_var_uint(payload, names.size.to_u64)
  names.each do |name|
    w120_require(name == File.basename(name) && name != "." && name != "..", "W120 checksum entry has unsafe path #{name.inspect}")
    path = File.join(part, name)
    w120_require(File.file?(path) && !File.symlink?(path), "W120 copied part has unsafe/missing file #{name}")
    physical = File.read(path).to_slice
    entry = original.entry(name) || w120_fail("W120 copied part lost checksum entry #{name}")
    changed = changed_bins.includes?(name)
    w120_require(!changed || entry.compressed, "W120 changed stream is not compressed: #{name}")
    raw = if entry.compressed
            physical.empty? ? Bytes.empty : CrystalClick::CompressedBlock.decode_all(physical)
          else
            physical
          end
    if entry.compressed
      expected_raw_size = entry.uncompressed_size || w120_fail("compressed checksum entry #{name} has no raw size")
      unless changed
        w120_require(raw.size.to_u64 == expected_raw_size, "unchanged copied stream raw size differs from checksum entry #{name}")
      end
    end

    w120_write_var_uint(payload, name.bytesize.to_u64)
    payload.write(name.to_slice)
    w120_write_var_uint(payload, physical.size.to_u64)
    w120_write_hash128(payload, CrystalClick::CityHashV1.file_hash(physical))
    if entry.compressed
      payload.write_byte(1_u8)
      w120_write_var_uint(payload, raw.size.to_u64)
      w120_write_hash128(payload, CrystalClick::CityHashV1.file_hash(raw))
    else
      payload.write_byte(0_u8)
    end
  end

  manifest = IO::Memory.new
  manifest << CrystalClick::PartChecksums::CHECKSUMS_HEADER
  manifest.write(w120_literal_lz4_frame(payload.to_slice))
  File.write(File.join(part, "checksums.txt"), manifest.to_slice)

  rewritten = CrystalClick::PartChecksums.open(part)
  w120_require(rewritten.entries.keys.sort == names, "W120 rewritten checksum inventory changed")
  names.each { |name| rewritten.validate_selected_entries(part, name) }
end

def w120_expect_byte_mismatch(actual : Bytes, wrong_expected : Bytes, label : String) : Nil
  begin
    w120_assert_bytes(actual, wrong_expected, label)
  rescue error : W120Mismatch
    w120_require(error.message.to_s.starts_with?("#{label}: byte vector differs"), "#{label}: comparator control failed for unrelated reason")
    puts "PASS W120 one-byte comparator control: rejected changed expected vector"
    return
  end
  w120_fail("#{label}: one-byte expected-vector change was accepted")
end

def w120_assert_retained_model(profile : String, role : String, expected : CrystalClick::ObjectDynamicStructureSet, actual : CrystalClick::ObjectDynamicStructureSet) : Nil
  W120StructureVectors.assert_equal(expected, actual, "W115 #{profile} #{role}")
  puts "PASS W120 authored metadata: W115 #{profile} #{role} Object plus #{actual.dynamics.size} Dynamic stream(s)"
end

def w120_write_uint64_at(bytes : Bytes, offset : Int32, value : UInt64) : Nil
  8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

def w120_read_uint64_at(bytes : Bytes, offset : Int32) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

def w120_rewrite_marks(part : String, logical : String, prefix_size : Int32, raw_size : Int32) : Nil
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical)}.mrk2")
  w120_require(File.file?(path) && !File.symlink?(path), "#{logical}: unsafe/missing .mrk2")
  original = File.read(path).to_slice
  w120_require(original.size == 120 && original.size % 24 == 0, "#{logical}: expected five plain Wide marks")
  marks = Bytes.new(original.size) { |index| original[index] }
  5.times do |index|
    offset = index * 24
    w120_require(w120_read_uint64_at(marks, offset) == 0_u64, "#{logical}: nonzero compressed mark offset is outside W120 surgery")
    expected_rows = index < 4 ? 2_u64 : 0_u64
    w120_require(w120_read_uint64_at(marks, offset + 16) == expected_rows, "#{logical}: unexpected W115 mark row count")
    raw_offset = index < 4 ? prefix_size.to_u64 : raw_size.to_u64
    w120_write_uint64_at(marks, offset + 8, raw_offset)
  end
  File.write(path, marks)
end

def w120_replace_stream(part : String, logical : String, raw : Bytes, prefix : Bytes) : Nil
  w120_require(raw.size >= prefix.size && raw[0, prefix.size] == prefix, "#{logical}: independently authored prefix differs from encoded stream")
  bin_path = File.join(part, "#{CrystalClick::StreamName.hash(logical)}.bin")
  w120_require(File.file?(bin_path) && !File.symlink?(bin_path), "#{logical}: unsafe/missing .bin")
  frame = w120_literal_lz4_frame(raw)
  w120_require(CrystalClick::CompressedBlock.decode_all(frame) == raw, "#{logical}: LZ4 re-encoding changed bytes")
  File.write(bin_path, frame)
  w120_rewrite_marks(part, logical, prefix.size, raw.size)
end

def w120_mutate_copied_part(part : String, encoded : CrystalClick::ObjectDynamicStructureStreams, expected : CrystalClick::ObjectDynamicStructureSet, label : String) : Nil
  w120_assert_tree(part, "#{label} copied part before surgery")
  inventory_before = Dir.children(part).sort
  authored = W120StructureVectors.streams(expected)
  changed_bins = [] of String

  w120_assert_bytes(encoded.object, authored.object, "#{label} Object full vector")
  object_prefix = W120StructureVectors.object_header(expected.object)
  object_logical = "payload.object_structure"
  w120_replace_stream(part, object_logical, encoded.object, object_prefix)
  changed_bins << "#{CrystalClick::StreamName.hash(object_logical)}.bin"
  encoded.dynamics.each do |path, raw|
    model = expected.dynamics[path]? || w120_fail("#{label}: encoded unknown Dynamic path #{path.inspect}")
    expected_raw = authored.dynamics[path]? || w120_fail("#{label}: missing authored Dynamic vector #{path.inspect}")
    w120_assert_bytes(raw, expected_raw, "#{label} Dynamic #{path} full vector")
    prefix = W120StructureVectors.dynamic_header(model)
    logical = "payload.#{W120StructureVectors.physical_path(path)}.dynamic_structure"
    w120_replace_stream(part, logical, raw, prefix)
    changed_bins << "#{CrystalClick::StreamName.hash(logical)}.bin"
  end
  w120_require(encoded.dynamics.keys.sort == expected.dynamics.keys.sort, "#{label}: encoded Dynamic stream roster differs")

  w120_rewrite_checksums(part, changed_bins)
  w120_assert_tree(part, "#{label} copied part after surgery")
  w120_require(Dir.children(part).sort == inventory_before, "#{label}: part file inventory changed during structure rewrite")
end

def w120_profile_table(binary : String, store : String, profile : String, json_type : String) : String
  table = "w120_#{profile}"
  w120_run(binary, store,
    "CREATE TABLE default.#{table} (pk UInt64, payload #{json_type}) ENGINE=MergeTree ORDER BY pk SETTINGS #{W120_SETTINGS}")
  schema = w120_run(binary, store,
    "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw")
  expected_schema = W116JsonPhysicalVectors.expected_schema(profile)
  w120_require(schema == expected_schema, "#{profile}: isolated table schema differs from the retained W115 profile")
  table
end

def w120_attach_path(binary : String, store : String, table : String) : String
  path = w120_run(binary, store,
    "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  w120_store_child(path, store, "W120 #{table} table data path")
end

def w120_assert_live_documents(binary : String, source_store : String, writer_store : String, source_table : String, writer_table : String, temp_root : String, profile : String) : Nil
  full_query = "SELECT pk, toJSONString(payload) FROM default.%s ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw"
  selected_query = "SELECT pk, toJSONString(payload) FROM default.%s WHERE pk >= 3 AND pk < 7 ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw"
  source_full = w120_run(binary, source_store, full_query % source_table)
  source_selected = w120_run(binary, source_store, selected_query % source_table)
  copy_full = w120_run(binary, writer_store, full_query % writer_table)
  copy_selected = w120_run(binary, writer_store, selected_query % writer_table)

  w115_assert_semantic_documents(source_full, profile, false, "W120 #{profile} retained source full")
  w115_assert_semantic_documents(source_selected, profile, true, "W120 #{profile} retained source selected")
  w115_assert_semantic_documents(copy_full, profile, false, "W120 #{profile} copied ATTACH full")
  w115_assert_semantic_documents(copy_selected, profile, true, "W120 #{profile} copied ATTACH selected")
  File.write(File.join(temp_root, "#{profile}_source_documents_full.tsv"), source_full)
  File.write(File.join(temp_root, "#{profile}_source_documents_selected.tsv"), source_selected)
  File.write(File.join(temp_root, "#{profile}_copy_documents_full.tsv"), copy_full)
  File.write(File.join(temp_root, "#{profile}_copy_documents_selected.tsv"), copy_selected)
  puts "PASS W120 independent literal documents: #{profile} copied ATTACH full and selected pk 3..6"

  # Differential only: RowBinary has no independent W120 literal oracle.
  rowbinary_full = "SELECT pk, payload FROM default.%s ORDER BY pk FORMAT RowBinary"
  rowbinary_selected = "SELECT pk, payload FROM default.%s WHERE pk >= 3 AND pk < 7 ORDER BY pk FORMAT RowBinary"
  source_full_binary = w120_run(binary, source_store, rowbinary_full % source_table)
  source_selected_binary = w120_run(binary, source_store, rowbinary_selected % source_table)
  copy_full_binary = w120_run(binary, writer_store, rowbinary_full % writer_table)
  copy_selected_binary = w120_run(binary, writer_store, rowbinary_selected % writer_table)
  w120_assert_bytes(copy_full_binary.to_slice, source_full_binary.to_slice, "#{profile} supplementary RowBinary full differential")
  w120_assert_bytes(copy_selected_binary.to_slice, source_selected_binary.to_slice, "#{profile} supplementary RowBinary selected differential")
  File.write(File.join(temp_root, "#{profile}_copy_rowbinary_full.bin"), copy_full_binary)
  File.write(File.join(temp_root, "#{profile}_copy_rowbinary_selected.bin"), copy_selected_binary)
  puts "PASS W120 supplementary RowBinary source/copy differential: #{profile} full and selected"
end

def w120_run_local_controls : Nil
  no_stats = CrystalClick::ObjectStructure.new(
    [] of String,
    version: 4_u64,
    shared_data_version: 0_u64,
    bucket_count: 1_u64,
    legacy_max_dynamic_paths: nil,
    statistics: nil,
  )
  zero_stats = CrystalClick::ObjectStructure.new(
    [] of String,
    version: 4_u64,
    shared_data_version: 0_u64,
    bucket_count: 1_u64,
    legacy_max_dynamic_paths: nil,
    statistics: CrystalClick::StructureStatistics.new([] of UInt64, [] of CrystalClick::StructureStatistic),
  )
  limits = CrystalClick::BinaryCodecLimits.default
  no_stats_manual = W120StructureVectors.object_bytes(no_stats)
  zero_stats_manual = W120StructureVectors.object_bytes(zero_stats)
  no_stats_bytes = CrystalClick::ObjectStructureCodec.encode(no_stats, limits)
  zero_stats_bytes = CrystalClick::ObjectStructureCodec.encode(zero_stats, limits)
  w120_assert_bytes(no_stats_bytes, no_stats_manual, "W120 absent Object statistics vector")
  w120_assert_bytes(zero_stats_bytes, zero_stats_manual, "W120 present-zero Object statistics vector")
  w120_require(no_stats_bytes != zero_stats_bytes, "V3 absent and present-zero statistics collapsed")
  w120_require(CrystalClick::ObjectStructureCodec.decode(no_stats_bytes, limits).statistics.nil?, "V3 no-stat decode lost absent state")
  zero_decoded = CrystalClick::ObjectStructureCodec.decode(zero_stats_bytes, limits).statistics || w120_fail("V3 zero-stat decode lost present state")
  w120_require(zero_decoded.counts.empty? && zero_decoded.shared.empty?, "V3 present-zero statistics did not remain empty")
  puts "PASS W120 local absent-vs-present-zero V3 statistics vectors"

  shared_set = W120StructureVectors.expected_set("dynamic_shared_only")
  canonical_object = W120StructureVectors.object_bytes(shared_set.object)
  permuted_object = W120StructureVectors.object_bytes(shared_set.object, reverse_shared: true)
  w120_require(canonical_object != permuted_object, "shared-map permutation did not change the authored wire order")
  permuted_model = CrystalClick::ObjectStructureCodec.decode(permuted_object, limits)
  empty_dynamics = {} of String => CrystalClick::DynamicStructure
  decoded_set = CrystalClick::ObjectDynamicStructureSet.new(permuted_model, empty_dynamics)
  W120StructureVectors.assert_equal(shared_set, decoded_set, "W120 valid permuted Object shared-map control")
  canonical_reencoded = CrystalClick::ObjectStructureCodec.encode(permuted_model, limits)
  w120_assert_bytes(canonical_reencoded, canonical_object, "W120 canonical shared-map re-emission")
  puts "PASS W120 valid permuted shared-statistics map: accepted and canonically re-emitted"

  typed_set = W120StructureVectors.expected_set("typed_mixed")
  typed_canonical = W120StructureVectors.streams(typed_set)
  typed_permuted = W120StructureVectors.streams(typed_set, reverse_dynamic_shared_path: "s")
  w120_require(typed_canonical.dynamics["s"] != typed_permuted.dynamics["s"], "Dynamic shared-map permutation did not change authored wire order")
  typed_permuted_model = CrystalClick::ObjectDynamicStructureCodec.decode(typed_permuted, limits)
  W120StructureVectors.assert_equal(typed_set, typed_permuted_model, "W120 valid permuted Dynamic shared-map control")
  typed_reencoded = CrystalClick::ObjectDynamicStructureCodec.encode(typed_permuted_model, limits)
  w120_assert_bytes(typed_reencoded.object, typed_canonical.object, "W120 canonical paired Object re-emission")
  w120_assert_bytes(typed_reencoded.dynamics["s"], typed_canonical.dynamics["s"], "W120 canonical Dynamic shared-map re-emission")
  puts "PASS W120 valid permuted Dynamic shared-statistics map: accepted and canonically re-emitted"

  one_byte_wrong = canonical_object.dup
  one_byte_wrong[0] ^= 1_u8
  w120_expect_byte_mismatch(canonical_object, one_byte_wrong, "W120 one-byte expected-vector control")

  null_vs_shared = W120StructureVectors.expected_set("dynamic_paths")
  actual_a = null_vs_shared.dynamics["a"]
  wrong_a = CrystalClick::DynamicStructure.new(
    actual_a.types,
    statistics: CrystalClick::StructureStatistics.new([6_u64, 2_u64], [] of CrystalClick::StructureStatistic),
  )
  wrong_dynamics = null_vs_shared.dynamics.dup
  wrong_dynamics["a"] = wrong_a
  wrong_shared_count = CrystalClick::ObjectDynamicStructureSet.new(null_vs_shared.object, wrong_dynamics)
  w120_require(!W120StructureVectors.same?(null_vs_shared, wrong_shared_count), "metadata comparator counted NULL discriminator 255 as SharedVariant")
  w120_require(actual_a.statistics.not_nil!.counts == [6_u64, 0_u64], "authored vector confused NULL with SharedVariant")
  puts "PASS W120 NULL-vs-SharedVariant control: NULL discriminator 255 contributes no variant count"

  typed_expected = W120StructureVectors.expected_set("typed_mixed")
  typed_actual = typed_expected.dynamics["s"].statistics.not_nil!.shared
  wrong_shared = typed_actual.map do |entry|
    entry.name == "Bool" ? CrystalClick::StructureStatistic.new(entry.name, entry.count + 1_u64) : entry
  end
  typed_dynamic = typed_expected.dynamics["s"]
  wrong_dynamic = CrystalClick::DynamicStructure.new(
    typed_dynamic.types,
    statistics: CrystalClick::StructureStatistics.new(typed_dynamic.statistics.not_nil!.counts, wrong_shared),
  )
  wrong_stats_dynamics = typed_expected.dynamics.dup
  wrong_stats_dynamics["s"] = wrong_dynamic
  wrong_stats_set = CrystalClick::ObjectDynamicStructureSet.new(typed_expected.object, wrong_stats_dynamics)
  w120_require(!W120StructureVectors.same?(typed_expected, wrong_stats_set), "metadata comparator accepted a wrong Dynamic spilled-type estimate")
  puts "PASS W120 wrong-statistics metadata comparator control (stock CHECK is not an estimate oracle)"
end

def w120_writer_profile(binary : String, source_store : String, source_table : String, source_part_name : String, source_part : String, root : String, profile : String, json_type : String) : Nil
  store = File.join(root, "stores", profile)
  w120_require(!File.exists?(store) && !File.symlink?(File.dirname(store)), "#{profile}: W120 store already exists or parent is unsafe")
  FileUtils.mkdir_p(store)
  w120_require(Dir.exists?(store) && !File.symlink?(store), "#{profile}: failed to create isolated store")

  table = w120_profile_table(binary, store, profile, json_type)
  data_path = w120_attach_path(binary, store, table)
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  w120_store_child(detached, store, "#{profile} detached directory")
  destination = File.join(detached, source_part_name)
  w120_require(!File.exists?(destination) && !File.symlink?(detached), "#{profile}: detached destination is occupied or unsafe")
  FileUtils.cp_r(source_part, destination)
  copied = w120_store_child(destination, store, "#{profile} isolated part copy")
  w120_assert_tree(copied, "#{profile} copied part")

  expected = W120StructureVectors.expected_set(profile)
  encoded = CrystalClick::ObjectDynamicStructureCodec.encode(expected, CrystalClick::BinaryCodecLimits.default)
  W120StructureVectors.assert_equal(expected,
    CrystalClick::ObjectDynamicStructureCodec.decode(encoded, CrystalClick::BinaryCodecLimits.default),
    "W120 #{profile} local authored encode/decode")
  w120_mutate_copied_part(copied, encoded, expected, "W120 #{profile}")

  w120_run(binary, store, "ALTER TABLE default.#{table} ATTACH PART '#{source_part_name}'")
  check = w120_run(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated")
  w120_assert_check(check, source_part_name, "W120 #{profile} authored ATTACH")
  attached_name, attached_path = w120_part(binary, store, table, "W120 #{profile} attached part")
  w120_require(attached_name == source_part_name, "#{profile}: attached part name changed")
  w120_assert_tree(attached_path, "#{profile} attached part")

  attached_model = w120_read_metadata(attached_path, profile, "W120 #{profile} attached part")
  W120StructureVectors.assert_equal(expected, attached_model, "W120 #{profile} authored copied-part metadata")
  puts "PASS W120 isolated stock ATTACH/CHECK=1: #{profile} part=#{attached_name}"
  w120_assert_live_documents(binary, source_store, store, source_table, table, root, profile)
end

def w120_check : Nil
  binary = ENV["CLICKHOUSE_BIN"]? || raise "CLICKHOUSE_BIN is required"
  capture_root = ENV["W115_CAPTURE_ROOT"]? || raise "W115_CAPTURE_ROOT is required"
  temp_root = ENV["W120_TMP_ROOT"]? || raise "W120_TMP_ROOT is required"
  capture_root = File.realpath(capture_root)
  temp_root = File.realpath(temp_root)
  w120_require(capture_root.starts_with?("/private/tmp/crystal-click-json-w115.") && !File.symlink?(capture_root), "unsafe W115 capture root")
  w120_require(temp_root.starts_with?("/private/tmp/crystal-click-json-w120.") && !File.symlink?(temp_root), "unsafe W120 temporary root")
  source_store = File.realpath(File.join(capture_root, "store"))
  w120_require(source_store.starts_with?(capture_root + "/") && !File.symlink?(File.join(capture_root, "store")), "unsafe W115 source store")
  w120_require(File.file?(File.join(capture_root, "capture.log")) && !File.symlink?(File.join(capture_root, "capture.log")), "W115 capture log is missing or unsafe")
  w120_require(File.file?(File.join(capture_root, "input.jsonl")) && !File.symlink?(File.join(capture_root, "input.jsonl")), "W115 literal input is missing or unsafe")
  w120_require(Dir.empty?(temp_root), "W120 temporary root must be fresh and empty")

  w120_verify_runtime(binary, source_store)
  w120_run_local_controls
  w120_require(W116JsonPhysicalVectors::PROFILES.to_a.sort == W120_PROFILES.map(&.[0]).to_a.sort, "W120/W116 profile sets differ")
  W116JsonPhysicalVectors::PROFILES.each do |profile|
    W120StructureVectors.check_profile(profile)
  end

  source_table_by_profile = {} of String => String
  source_path_by_profile = {} of String => String
  source_name_by_profile = {} of String => String
  attached_roles = {false, true}
  decoded_count = 0

  W120_PROFILES.each do |profile, _json_type|
    expected = W120StructureVectors.expected_set(profile)
    source_table = "w115_#{profile}_source"
    source_table_by_profile[profile] = source_table

    attached_roles.each do |attached|
      part_name, part_path = w120_retained_part(binary, source_store, profile, attached)
      role = attached ? "fresh ATTACH" : "source"
      W116JsonPhysicalVectors.assert_part(profile, part_path, attached: attached)
      model = w120_read_metadata(part_path, profile, "W115 #{profile} #{role}")
      w120_assert_retained_model(profile, role, expected, model)
      decoded_count += 1 + model.dynamics.size
      if !attached
        source_name_by_profile[profile] = part_name
        source_path_by_profile[profile] = part_path
      else
        w120_require(source_name_by_profile[profile] == part_name, "W115 #{profile}: source/fresh ATTACH part names differ")
      end
    end
  end
  w120_require(decoded_count == 20, "W120 expected exactly 20 retained Object/Dynamic structure instances; got #{decoded_count}")
  puts "PASS W120 retained structure reads: #{decoded_count} source+ATTACH Object/Dynamic streams across six parts"

  # These live source CHECK positives cannot validate statistical estimates;
  # the intentionally wrong model above is rejected by the independent model
  # comparator even though the corresponding stock table checks successfully.
  W120_PROFILES.each do |profile, json_type|
    source_table = source_table_by_profile[profile]
    source_part_name = source_name_by_profile[profile]
    source_part = source_path_by_profile[profile]
    w120_writer_profile(binary, source_store, source_table, source_part_name, source_part, temp_root, profile, json_type)
  end

  puts "PASS W120: three authored Object+Dynamic part copies; no value-lane or production part-writer admission claimed"
end

w120_check
