# W116 requalifies a retained W115 ClickHouse stock capture, then records the
# precise currently unsupported whole-JSON typed-reader boundary.
require "file_utils"
require "../src/crystal_click"
require "./w115_json_semantic_vectors"
require "./w116_json_physical_vectors"

W116_VERSION           = "26.10.1.1201"
W116_BUILD_HASH        = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
W116_EXECUTABLE_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
W116_PROFILES          = {
  {"dynamic_paths", "w115_dynamic_paths_source", "w115_dynamic_paths_attached"},
  {"dynamic_shared_only", "w115_dynamic_shared_only_source", "w115_dynamic_shared_only_attached"},
  {"typed_mixed", "w115_typed_mixed_source", "w115_typed_mixed_attached"},
}

class W116Mismatch < Exception
end

def w116_fail(message : String) : NoReturn
  raise W116Mismatch.new(message)
end

def w116_require(condition : Bool, message : String) : Nil
  w116_fail(message) unless condition
end

def w116_run(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: error)
  raise "ClickHouse read-only query failed: #{error}\n#{query}" unless status.success?
  output.to_s
end

def w116_store_child(path : String, store : String, label : String) : String
  real_path = File.realpath(path)
  real_store = File.realpath(store)
  w116_require(real_path.starts_with?(real_store + "/") && !File.symlink?(path), "#{label}: part path escapes the retained store")
  real_path
end

def w116_part(binary : String, store : String, table : String, label : String) : {String, String, String}
  rows = w116_run(binary, store,
    "SELECT name, path, part_type, toString(rows) FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").lines
  w116_require(rows.size == 1, "#{label}: expected exactly one active part; got #{rows.size}")
  fields = rows.first.split('\t')
  w116_require(fields.size == 4, "#{label}: malformed system.parts row #{rows.first.inspect}")
  w116_require(fields[2] == "Wide" && fields[3] == "8", "#{label}: expected one Wide 8-row active part, got #{fields[2..].inspect}")
  {fields[0], w116_store_child(fields[1], store, label), "#{fields[0]}\t#{fields[2]}\t#{fields[3]}"}
end

def w116_schema(binary : String, store : String, table : String) : String
  w116_run(binary, store,
    "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw")
end

def w116_assert_check(actual : String, part_name : String, label : String) : Nil
  expected = "#{part_name}\t1\t\n"
  w116_fail("#{label}: CHECK record mismatch") unless actual == expected
end

def w116_check_negative_controls(part_name : String, label : String) : Nil
  ["#{part_name}\t0\t\n", "wrong_part\t1\t\n"].each_with_index do |seed, index|
    begin
      w116_assert_check(seed, part_name, "#{label} control #{index}")
    rescue error : W116Mismatch
      w116_require(error.message == "#{label} control #{index}: CHECK record mismatch", "#{label}: CHECK control caught an unrelated error")
      puts "PASS W116 CHECK comparator control: rejected #{seed.inspect}"
      next
    end
    w116_fail("#{label}: CHECK comparator accepted #{seed.inspect}")
  end
end

def w116_assert_profile_vectors(profile : String, part : String, attached : Bool, label : String) : Nil
  begin
    W116JsonPhysicalVectors.assert_part(profile, part, attached: attached)
  rescue error : W116JsonPhysicalMismatch
    raise error
  end
  puts "PASS W116 physical literal vectors: #{label} profile=#{profile}"
end

def w116_assert_live_semantics(binary : String, store : String, temp_root : String, profile : String, table : String, table_role : String, label : String) : Nil
  artifact_role = case table_role
                  when "source"   then "source"
                  when "attached" then "fresh_attach"
                  else                 w116_fail("#{label}: unknown capture role #{table_role.inspect}")
                  end
  full = w116_run(binary, store,
    "SELECT pk, toJSONString(payload) FROM default.#{table} ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw")
  selected = w116_run(binary, store,
    "SELECT pk, toJSONString(payload) FROM default.#{table} WHERE pk >= 3 AND pk < 7 ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw")
  File.write(File.join(temp_root, "#{profile}_#{artifact_role}_documents_full.tsv"), full)
  File.write(File.join(temp_root, "#{profile}_#{artifact_role}_documents_selected.tsv"), selected)
  w115_assert_semantic_documents(full, profile, false, "#{label} full")
  w115_assert_semantic_documents(selected, profile, true, "#{label} selected")
  puts "PASS W116 independent literal documents: #{label} full and selected pk 3..6"
end

def w116_write_var_uint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

def w116_write_uint32_le(bytes : Bytes, offset : Int32, value : UInt32) : Nil
  4.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u32).to_u8 }
end

def w116_write_uint64_le(bytes : Bytes, offset : Int32, value : UInt64) : Nil
  8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

def w116_write_uint64_le(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
end

def w116_write_hash128_le(bytes : Bytes, offset : Int32, hash : {UInt64, UInt64}) : Nil
  w116_write_uint64_le(bytes, offset, hash[0])
  w116_write_uint64_le(bytes, offset + 8, hash[1])
end

def w116_write_hash128(io : IO, hash : {UInt64, UInt64}) : Nil
  w116_write_uint64_le(io, hash[0])
  w116_write_uint64_le(io, hash[1])
end

def w116_read_uint64_le(bytes : Bytes, offset : Int32) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

# Test-only literal LZ4 framing for the rewritten checksums manifest and
# checksum-valid copied stream controls. Re-encoded streams preserve decoded
# length; callers assert that existing compressed mark offsets remain zero.
def w116_literal_lz4_frame(raw : Bytes) : Bytes
  raise "cannot encode an empty LZ4 frame" if raw.empty?
  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w116_write_uint32_le(frame, header + 1, compressed_size.to_u32)
  w116_write_uint32_le(frame, header + 5, raw.size.to_u32)

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
  w116_write_hash128_le(frame, 0, hash)
  frame
end

# Regenerate the ClickHouse v4 manifest in a copied part after a deliberate
# same-size logical mutation. No source/retained store file is modified.
def w116_rewrite_checksums(part : String) : Nil
  original = CrystalClick::PartChecksums.open(part)
  names = original.entries.keys.sort
  w116_require(!names.empty? && !names.includes?("checksums.txt"), "mutation copy has an unexpected checksum inventory")
  payload = IO::Memory.new
  w116_write_var_uint(payload, names.size.to_u64)
  names.each do |name|
    path = File.join(part, name)
    w116_require(File.file?(path) && !File.symlink?(path), "mutation copy has unsafe/missing file #{name}")
    physical = File.read(path).to_slice
    entry = original.entry(name) || w116_fail("mutation copy lost checksum entry #{name}")
    raw = if entry.compressed
            physical.empty? ? Bytes.empty : CrystalClick::CompressedBlock.decode_all(physical)
          else
            physical
          end
    if entry.compressed
      expected_raw_size = entry.uncompressed_size || w116_fail("compressed checksum entry #{name} has no raw size")
      w116_require(raw.size.to_u64 == expected_raw_size, "mutation copy raw size differs from checksum entry #{name}")
    end

    w116_write_var_uint(payload, name.bytesize.to_u64)
    payload.write(name.to_slice)
    w116_write_var_uint(payload, physical.size.to_u64)
    w116_write_hash128(payload, CrystalClick::CityHashV1.file_hash(physical))
    if entry.compressed
      payload.write_byte(1_u8)
      w116_write_var_uint(payload, raw.size.to_u64)
      w116_write_hash128(payload, CrystalClick::CityHashV1.file_hash(raw))
    else
      payload.write_byte(0_u8)
    end
  end

  manifest = IO::Memory.new
  manifest << CrystalClick::PartChecksums::CHECKSUMS_HEADER
  manifest.write(w116_literal_lz4_frame(payload.to_slice))
  File.write(File.join(part, "checksums.txt"), manifest.to_slice)

  rewritten = CrystalClick::PartChecksums.open(part)
  w116_require(rewritten.entries.keys.sort == names, "rewritten checksums inventory changed")
  names.each { |name| rewritten.validate_selected_entries(part, name) }
end

def w116_mutate_stream_literal(part : String, profile : String, logical_stream : String, raw_offset : Int32, replacement : UInt8) : Bytes
  bin_path = File.join(part, "#{CrystalClick::StreamName.hash(logical_stream)}.bin")
  w116_require(File.file?(bin_path) && !File.symlink?(bin_path), "#{profile} #{logical_stream}: unsafe/missing .bin")
  mark_path = File.join(part, "#{CrystalClick::StreamName.hash(logical_stream)}.mrk2")
  w116_require(File.file?(mark_path) && !File.symlink?(mark_path), "#{profile} #{logical_stream}: unsafe/missing .mrk2")
  expected = W116JsonPhysicalVectors.expected_raw_stream(profile, logical_stream)
  original_physical = File.read(bin_path).to_slice
  w116_require(!original_physical.empty?, "#{profile} #{logical_stream}: cannot mutate a zero-byte physical stream")
  original_frame = CrystalClick::CompressedBlock.decode_frame(original_physical, 0_i64)
  w116_require(original_frame.end_offset == original_physical.size, "#{profile} #{logical_stream}: mutation requires exactly one stock frame")
  actual = original_frame.output
  w116_require(actual == expected, "#{profile} #{logical_stream}: source stream differs from independent literal before mutation")
  w116_require(raw_offset >= 0 && raw_offset < expected.size, "#{profile} #{logical_stream}: raw mutation offset is out of bounds")
  w116_require(expected[raw_offset] != replacement, "#{profile} #{logical_stream}: replacement would not change the raw vector")
  marks = File.read(mark_path).to_slice
  w116_require(marks.size > 0 && marks.size % 24 == 0, "#{profile} #{logical_stream}: invalid Wide mark size")
  (marks.size // 24).times do |index|
    compressed_offset = w116_read_uint64_le(marks, index * 24)
    w116_require(compressed_offset == 0, "#{profile} #{logical_stream}: one-frame mutation would invalidate a nonzero mark frame offset")
  end

  changed = expected.dup
  changed[raw_offset] = replacement
  w116_require(changed.size == expected.size && changed[raw_offset] == replacement, "#{profile} #{logical_stream}: seeded raw byte mutation failed")
  differences = 0
  expected.each_with_index { |byte, index| differences += 1 if changed[index] != byte }
  w116_require(differences == 1, "#{profile} #{logical_stream}: mutation changed more than one logical byte")
  replacement_frame = w116_literal_lz4_frame(changed)
  redecoded = CrystalClick::CompressedBlock.decode_all(replacement_frame)
  w116_require(redecoded == changed, "#{profile} #{logical_stream}: literal re-encoding changed the intended raw mutation")
  File.write(bin_path, replacement_frame)
  w116_rewrite_checksums(part)
  changed
end

def w116_copy_part(source : String, temp_root : String, profile : String, label : String) : String
  copy = File.join(temp_root, "mutations", profile, label)
  FileUtils.mkdir_p(File.dirname(copy))
  w116_require(!File.exists?(copy) && !File.symlink?(copy), "#{profile} #{label}: mutation destination is occupied")
  FileUtils.cp_r(source, copy)
  real_copy = File.realpath(copy)
  real_root = File.realpath(temp_root)
  w116_require(real_copy.starts_with?(real_root + "/") && !File.symlink?(copy), "#{profile} #{label}: copied part escaped W116 temporary root")
  real_copy
end

def w116_expect_part_mismatch(profile : String, part : String, label : String, expected_message : String) : Nil
  begin
    W116JsonPhysicalVectors.assert_part(profile, part)
  rescue error : W116JsonPhysicalMismatch
    w116_require(error.message == expected_message, "#{label}: comparator rejected for an unexpected reason: #{error.message}")
    puts "PASS W116 copied-part comparator control: #{label}"
    return
  end
  w116_fail("#{label}: physical vector helper accepted the seeded mutation")
end

def w116_expect_raw_rejection(profile : String, logical_stream : String, changed : Bytes) : Nil
  begin
    W116JsonPhysicalVectors.assert_stream_raw(profile, logical_stream, changed)
  rescue error : W116JsonPhysicalMismatch
    expected = "W116 JSON physical mismatch: #{profile} stream #{logical_stream} raw payload differs"
    w116_require(error.message == expected, "#{profile} #{logical_stream}: raw control failed for an unexpected reason: #{error.message}")
    puts "PASS W116 decoded-payload comparator control: #{profile} #{logical_stream}"
    return
  end
  w116_fail("#{profile} #{logical_stream}: raw-vector comparator accepted a changed logical payload")
end

def w116_raw_stream_controls : Int32
  controls = {
    {"dynamic_paths", "payload.s.variant_discr"},
    {"dynamic_paths", "payload.s.String"},
    {"dynamic_shared_only", "payload.object_shared_data%2Epaths"},
    {"typed_mixed", "payload.s.variant_discr"},
    {"typed_mixed", "payload.s.String"},
  }
  controls.each do |profile, logical_stream|
    expected = W116JsonPhysicalVectors.expected_raw_stream(profile, logical_stream)
    w116_require(!expected.empty?, "#{profile} #{logical_stream}: literal raw vector must be nonempty")
    changed = expected.dup
    changed[changed.size - 1] ^= 1_u8
    w116_require(changed.size == expected.size, "#{profile} #{logical_stream}: raw mutation changed logical payload size")
    w116_expect_raw_rejection(profile, logical_stream, changed)
  end
  controls.size
end

def w116_find_ascii_offset(raw : Bytes) : Int32
  raw.each_with_index do |byte, index|
    return index if (byte >= 'a'.ord && byte <= 'z'.ord) || (byte >= 'A'.ord && byte <= 'Z'.ord)
  end
  w116_fail("literal stream has no ASCII letter to seed a same-size payload change")
end

def w116_find_pattern_offsets(raw : Bytes, pattern : Array(UInt8)) : Array(Int32)
  matches = [] of Int32
  return matches if pattern.empty? || raw.size < pattern.size
  (raw.size - pattern.size + 1).times do |start|
    matches << start if pattern.each_with_index.all? { |byte, index| raw[start + index] == byte }
  end
  matches
end

def w116_seed_payload_control(profile : String, source_part : String, temp_root : String, logical_stream : String, target_offset : Int32, replacement : UInt8, label : String) : Nil
  copy = w116_copy_part(source_part, temp_root, profile, label)
  w116_mutate_stream_literal(copy, profile, logical_stream, target_offset, replacement)
  expected = "W116 JSON physical mismatch: #{profile} stream #{logical_stream} raw payload differs"
  w116_expect_part_mismatch(profile, copy, "#{profile} #{label}", expected)
end

def w116_seed_mark_control(profile : String, source_part : String, temp_root : String) : Nil
  logical_stream = "payload.object_structure"
  copy = w116_copy_part(source_part, temp_root, profile, "mark")
  mark_path = File.join(copy, "#{CrystalClick::StreamName.hash(logical_stream)}.mrk2")
  w116_require(File.file?(mark_path) && !File.symlink?(mark_path), "#{profile}: object_structure .mrk2 is missing")
  marks = File.read(mark_path).to_slice.dup
  w116_require(marks.size >= 24 && marks.size % 24 == 0, "#{profile}: object_structure .mrk2 has invalid size")
  W116JsonPhysicalVectors.assert_mark_raw(profile, logical_stream, marks)
  original_uncompressed_offset = w116_read_uint64_le(marks, 8)
  # Structure data marks follow their serialized prefix, not byte zero.
  w116_require(original_uncompressed_offset < UInt64::MAX, "#{profile}: first object_structure decompressed mark offset cannot be mutated safely")
  w116_write_uint64_le(marks, 8, original_uncompressed_offset + 1)
  File.write(mark_path, marks)
  w116_rewrite_checksums(copy)
  expected = "W116 JSON physical mismatch: #{profile} stream #{logical_stream} mark grid differs"
  w116_expect_part_mismatch(profile, copy, "#{profile} mark grid", expected)
end

def w116_seed_schema_control(profile : String, source_part : String, temp_root : String) : Nil
  copy = w116_copy_part(source_part, temp_root, profile, "schema")
  path = File.join(copy, "columns.txt")
  schema = File.read(path)
  before, after = case profile
                  when "dynamic_paths"       then {"max_dynamic_paths=16", "max_dynamic_paths=17"}
                  when "dynamic_shared_only" then {"max_dynamic_paths=0", "max_dynamic_paths=1"}
                  when "typed_mixed"         then {"max_dynamic_types=1", "max_dynamic_types=2"}
                  else                            w116_fail("unknown profile for schema control: #{profile}")
                  end
  w116_require(schema.includes?(before), "#{profile}: schema control token #{before.inspect} is absent")
  changed = schema.sub(before, after)
  w116_require(changed.bytesize == schema.bytesize && changed != schema, "#{profile}: schema control was not a same-size edit")
  File.write(path, changed)
  w116_rewrite_checksums(copy)
  expected = "W116 JSON physical mismatch: #{profile} columns.txt schema differs"
  w116_expect_part_mismatch(profile, copy, "#{profile} schema", expected)
end

def w116_copied_part_controls(parts : Hash(String, {String, String}), temp_root : String) : {Int32, Int32, Int32, Int32}
  raw_controls = 0
  mark_controls = 0
  schema_controls = 0
  tag_controls = 0
  W116_PROFILES.each do |profile, _source_table, _attached_table|
    source_part = parts["#{profile}_source"][1]
    raw_stream = profile == "dynamic_shared_only" ? "payload.object_shared_data%2Evalues" : "payload.s.String"
    raw = W116JsonPhysicalVectors.expected_raw_stream(profile, raw_stream)
    raw_offset = w116_find_ascii_offset(raw)
    replacement = raw[raw_offset] == 'z'.ord.to_u8 ? 'y'.ord.to_u8 : (raw[raw_offset] + 1_u8)
    w116_seed_payload_control(profile, source_part, temp_root, raw_stream, raw_offset, replacement, "raw_payload")
    raw_controls += 1

    discriminator_stream = if profile == "dynamic_shared_only"
                             "payload.object_shared_data%2Evalues"
                           else
                             "payload.s.variant_discr"
                           end
    discriminator = W116JsonPhysicalVectors.expected_raw_stream(profile, discriminator_stream)
    if profile == "dynamic_shared_only"
      empty_array_string = [0x04_u8, 0x1e_u8, 0x23_u8, 0x15_u8, 0x00_u8]
      locations = w116_find_pattern_offsets(discriminator, empty_array_string)
      w116_require(locations.size == 1, "dynamic_shared_only: expected exactly one literal empty Array Nullable(String) value")
      tag_offset = locations.first + 3
      w116_seed_payload_control(profile, source_part, temp_root, discriminator_stream, tag_offset, 0x0a_u8, "empty_array_string_tag_to_int64")
    else
      # Stock W115 discriminator vectors start with a UInt64 mode prefix, then
      # a row-count byte and COMPACT-format byte. The first nominal tag follows
      # those fields; never mutate a control/header byte and call it a tag.
      w116_require(discriminator.size > 10, "#{profile}: discriminator vector is too short for its first row")
      w116_require(w116_read_uint64_le(discriminator, 0) == 1_u64, "#{profile}: unexpected discriminator mode prefix")
      w116_require(discriminator[8] == 2_u8 && discriminator[9] == 1_u8, "#{profile}: unexpected first-granule discriminator framing")
      tag_offset = 10
      expected_tag = profile == "dynamic_paths" ? 3_u8 : 1_u8
      w116_require(discriminator[tag_offset] == expected_tag, "#{profile}: first `s` tag does not match its literal profile")
      replacement_tag = expected_tag == 3_u8 ? 2_u8 : expected_tag + 1_u8
      w116_seed_payload_control(profile, source_part, temp_root, discriminator_stream, tag_offset, replacement_tag, "variant_discriminator_tag")
    end
    tag_controls += 1

    w116_seed_mark_control(profile, source_part, temp_root)
    mark_controls += 1
    w116_seed_schema_control(profile, source_part, temp_root)
    schema_controls += 1
  end
  {raw_controls, mark_controls, schema_controls, tag_controls}
end

def w116_expected_table_schema(profile : String) : String
  expected = W116JsonPhysicalVectors.expected_schema(profile)
  w116_require(expected.lines.size == 2 && expected.ends_with?("\n"), "#{profile}: physical helper returned no exact two-column SQL schema")
  expected
end

def w116_verify_runtime(binary : String, store : String) : Nil
  hash_out = IO::Memory.new
  hash_err = IO::Memory.new
  hash_status = Process.run("shasum", ["-a", "256", binary], output: hash_out, error: hash_err)
  raise "could not inspect pinned ClickHouse SHA-256: #{hash_err}" unless hash_status.success?
  sha = hash_out.to_s.split(' ').first? || raise "malformed ClickHouse SHA-256 output"
  w116_require(sha == W116_EXECUTABLE_SHA256, "wrong ClickHouse SHA-256: #{sha}")
  version_out = IO::Memory.new
  version_err = IO::Memory.new
  version_status = Process.run(binary, ["local", "--version"], output: version_out, error: version_err)
  raise "could not inspect ClickHouse version: #{version_err}" unless version_status.success?
  expected_version = "ClickHouse local version #{W116_VERSION} (official build)."
  w116_require(version_out.to_s.strip == expected_version, "wrong ClickHouse version: #{version_out.to_s.strip}")
  options = w116_run(binary, store,
    "SELECT name || '=' || value FROM system.build_options WHERE name IN ('GIT_HASH', 'VERSION_GITHASH') ORDER BY name FORMAT TSVRaw").lines.map(&.strip)
  w116_require(options == ["GIT_HASH=#{W116_BUILD_HASH}", "VERSION_GITHASH=#{W116_BUILD_HASH}"], "wrong ClickHouse build identity: #{options.inspect}")
  puts "W116 runtime pinned: #{expected_version}; build=#{W116_BUILD_HASH}; sha256=#{sha}"
end

def w116_run_check : Nil
  root = ENV["W115_CAPTURE_ROOT"]? || raise "W115_CAPTURE_ROOT is required"
  temp_root = ENV["W116_TMP_ROOT"]? || raise "W116_TMP_ROOT is required"
  binary = ENV["CLICKHOUSE_BIN"]? || raise "CLICKHOUSE_BIN is required"
  root = File.realpath(root)
  temp_root = File.realpath(temp_root)
  w116_require(root.starts_with?("/private/tmp/crystal-click-json-w115.") && !File.symlink?(root), "unsafe W115 capture root")
  w116_require(temp_root.starts_with?("/private/tmp/crystal-click-json-w116.") && !File.symlink?(temp_root), "unsafe W116 temporary root")
  store = File.realpath(File.join(root, "store"))
  w116_require(store.starts_with?(root + "/") && !File.symlink?(File.join(root, "store")), "W115 store escapes retained capture root")
  w116_verify_runtime(binary, store)

  parts = {} of String => {String, String}
  schemas = {} of String => String
  W116_PROFILES.each do |profile, source_table, attached_table|
    source_name, source_path, _source_identity = w116_part(binary, store, source_table, "#{profile} source")
    attached_name, attached_path, _attached_identity = w116_part(binary, store, attached_table, "#{profile} attached")
    w116_require(source_name == attached_name, "#{profile}: source and ATTACH part names differ")
    source_schema = w116_schema(binary, store, source_table)
    attached_schema = w116_schema(binary, store, attached_table)
    expected_schema = w116_expected_table_schema(profile)
    w116_require(source_schema == expected_schema && attached_schema == expected_schema, "#{profile}: exact source/ATTACH two-column schema differs; expected=#{expected_schema.inspect}, source=#{source_schema.inspect}, attach=#{attached_schema.inspect}")
    schemas[profile] = source_schema
    { {"source", source_path}, {"attached", attached_path} }.each do |role, path|
      actual_check = w116_run(binary, store, "CHECK TABLE default.#{role == "source" ? source_table : attached_table} FORMAT TabSeparated")
      w116_assert_check(actual_check, source_name, "#{profile} #{role}")
      w116_check_negative_controls(source_name, "#{profile} #{role}")
      w116_assert_profile_vectors(profile, path, role == "attached", "#{profile} #{role}")
      table = role == "source" ? source_table : attached_table
      w116_assert_live_semantics(binary, store, temp_root, profile, table, role, "#{profile} #{role}")
      parts["#{profile}_#{role}"] = {source_name, path}
    end
    puts "PASS W116 inventory: #{profile}, source+fresh ATTACH, schema=#{source_schema.strip.inspect}, CHECK=1"
  end

  # Same-size adversaries exercise the same literal physical comparator on
  # isolated copies, never against the retained W115 source store.
  raw_controls = w116_raw_stream_controls
  copied_raw_controls, copied_mark_controls, copied_schema_controls, copied_tag_controls = w116_copied_part_controls(parts, temp_root)

  # Only after every stock physical/document/control comparison passes do we
  # test the exact currently closed whole-JSON typed-reader boundary.
  profile = "dynamic_paths"
  source_path = parts["#{profile}_source"][1]
  type_line = schemas[profile].lines[1]
  json_type = type_line.byte_slice("payload ".bytesize, type_line.bytesize - "payload ".bytesize)
  w116_require(CrystalClick::WidePart.json_type?(json_type), "qualified source column is not exact JSON: #{json_type}")
  w116_require(!CrystalClick::WidePart.supports_typed_type?(json_type), "whole JSON unexpectedly admitted by typed type gate")
  begin
    CrystalClick::WidePart.open_typed(source_path, "payload")
  rescue error : CrystalClick::UnsupportedFormatError
    w116_require(error.message == "unsupported exact typed column", "whole JSON reader refused for an unrelated reason: #{error.message}")
    puts "QUALIFIED RED W116: profiles=#{W116_PROFILES.size}, source_parts=#{W116_PROFILES.size}, fresh_attach_parts=#{W116_PROFILES.size}, physical_parts=#{parts.size}, actual_CHECK_1=#{parts.size}, CHECK_negative_controls=#{parts.size * 2}, semantic_full_selected_checks=#{parts.size * 2}, in_memory_raw_controls=#{raw_controls}, copied_raw_controls=#{copied_raw_controls}, copied_discriminator_or_type_controls=#{copied_tag_controls}, copied_mark_controls=#{copied_mark_controls}, copied_schema_controls=#{copied_schema_controls}; exact typed whole-JSON refusal=#{error.message.inspect}"
    return
  end
  w116_fail("qualified whole-JSON reader unexpectedly opened typed JSON")
end

w116_run_check
