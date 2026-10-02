# W118 qualifies only the reusable, decompressed three-lane Object MAP codec.
# Expected bytes come from the source-derived W116 literal model; retained stock
# parts and the pinned runtime are separate evidence inputs.
require "../src/crystal_click"
require "./w116_json_physical_vectors"

W118_VERSION           = "26.10.1.1201"
W118_BUILD_HASH        = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
W118_EXECUTABLE_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
W118_PROFILES          = {"dynamic_paths", "dynamic_shared_only", "typed_mixed"}
W118_ROW_COUNT         = 8
W118_WINDOW_FIRST      = 2 # pk=3, from zero-based local row origin.
W118_WINDOW_COUNT      = 4 # pk 3..6.
W118_SIZE_STREAM       = "payload.object_shared_data.size0"
W118_PATH_STREAM       = "payload.object_shared_data%2Epaths"
W118_VALUE_STREAM      = "payload.object_shared_data%2Evalues"

class W118Mismatch < Exception
end

def w118_fail(message : String) : NoReturn
  raise W118Mismatch.new(message)
end

def w118_require(condition : Bool, message : String) : Nil
  w118_fail(message) unless condition
end

def w118_assert_bytes(label : String, actual : Bytes, expected : Bytes) : Nil
  w118_fail("W118 byte mismatch: #{label}") unless actual == expected
end

# This check precedes the metadata helper as well as raw-stream reads. The
# retained capture is quiescent; this is not a concurrent-filesystem guarantee.
def w118_guard_part_children(part : String) : Nil
  w118_require(File.directory?(part) && !File.symlink?(part), "unsafe W118 part directory")
  resolved_part = File.realpath(part)
  Dir.each_child(part) do |name|
    child = File.join(part, name)
    w118_require(File.file?(child) && !File.symlink?(child), "unsafe W118 part child #{name.inspect}")
    w118_require(File.realpath(child).starts_with?(resolved_part + "/"), "W118 child escapes its part directory")
  end
end

def w118_check_child_symlink_control(test_root : String) : Nil
  probe = File.join(test_root, "child-symlink-control")
  Dir.mkdir(probe)
  target = File.join(test_root, "child-symlink-target")
  File.write(target, "test-only target outside the probe part")
  File.symlink(target, File.join(probe, "columns.txt"))
  begin
    w118_guard_part_children(probe)
  rescue ex : W118Mismatch
    w118_require(ex.message == "unsafe W118 part child \"columns.txt\"", "unexpected symlink-control failure")
    puts "PASS W118 child-symlink control before metadata or stream reads"
    return
  end
  w118_fail("W118 child-symlink control was accepted")
end

def w118_run(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: error)
  raise "ClickHouse read-only identity query failed: #{error}\n#{query}" unless status.success?
  output.to_s
end

def w118_verify_runtime(binary : String, store : String) : Nil
  hash_out = IO::Memory.new
  hash_err = IO::Memory.new
  hash_status = Process.run("shasum", ["-a", "256", binary], output: hash_out, error: hash_err)
  raise "could not inspect pinned ClickHouse SHA-256: #{hash_err}" unless hash_status.success?
  sha = hash_out.to_s.split(' ').first? || raise "malformed ClickHouse SHA-256 output"
  w118_require(sha == W118_EXECUTABLE_SHA256, "wrong ClickHouse SHA-256: #{sha}")

  version_out = IO::Memory.new
  version_err = IO::Memory.new
  version_status = Process.run(binary, ["local", "--version"], output: version_out, error: version_err)
  raise "could not inspect ClickHouse version: #{version_err}" unless version_status.success?
  expected_version = "ClickHouse local version #{W118_VERSION} (official build)."
  w118_require(version_out.to_s.strip == expected_version, "wrong ClickHouse version: #{version_out.to_s.strip}")

  options = w118_run(binary, store,
    "SELECT name || '=' || value FROM system.build_options WHERE name IN ('GIT_HASH', 'VERSION_GITHASH') ORDER BY name FORMAT TSVRaw").lines.map(&.strip)
  w118_require(options == ["GIT_HASH=#{W118_BUILD_HASH}", "VERSION_GITHASH=#{W118_BUILD_HASH}"], "wrong ClickHouse build identity: #{options.inspect}")
  puts "W118 stock runtime pinned: #{expected_version}; build=#{W118_BUILD_HASH}; sha256=#{sha}"
  puts "W118 provenance: current upstream source comparison=0c68f01a; W116 literal/source baseline=935de744; retained W115 parts and this stock runtime are separately identified"
end

def w118_empty_row : CrystalClick::ObjectSharedMapRow
  CrystalClick::ObjectSharedMapRow.new([] of CrystalClick::ObjectSharedMapEntry)
end

def w118_row(*entries : Tuple(String, CrystalClick::BinaryValue)) : CrystalClick::ObjectSharedMapRow
  owned = Array(CrystalClick::ObjectSharedMapEntry).new(entries.size) do |index|
    path, value = entries[index]
    CrystalClick::ObjectSharedMapEntry.new(path.to_slice, value)
  end
  CrystalClick::ObjectSharedMapRow.new(owned)
end

def w118_i64(value : Int64) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.int64(value)
end

def w118_string(value : String) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.string(value)
end

def w118_bool(value : Bool) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.bool(value)
end

def w118_array_nullable_i64(values : Array(Int64)) : CrystalClick::BinaryValue
  nullable = CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.primitive("Int64"))
  type = CrystalClick::BinaryDataType.array(nullable)
  children = values.map do |value|
    CrystalClick::BinaryValue.nullable(nullable, w118_i64(value))
  end
  CrystalClick::BinaryValue.array(type, children)
end

def w118_array_nullable_string(values : Array(String)) : CrystalClick::BinaryValue
  nullable = CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.primitive("String"))
  type = CrystalClick::BinaryDataType.array(nullable)
  children = values.map do |value|
    CrystalClick::BinaryValue.nullable(nullable, w118_string(value))
  end
  CrystalClick::BinaryValue.array(type, children)
end

# These nominal rows are authored from the W115 input literals, not recovered
# from the stock part or from a codec decode. Entry order is raw-byte sorted.
def w118_expected_rows(profile : String) : Array(CrystalClick::ObjectSharedMapRow)
  case profile
  when "dynamic_paths"
    Array(CrystalClick::ObjectSharedMapRow).new(W118_ROW_COUNT) { w118_empty_row }
  when "dynamic_shared_only"
    [
      w118_row({"a", w118_i64(10_i64)}, {"arr", w118_array_nullable_i64([1_i64, 2_i64])}, {"dot.key", w118_i64(101_i64)}, {"flag", w118_bool(true)}, {"nest.leaf", w118_string("one")}, {"s", w118_string("alpha")}),
      w118_row({"arr", w118_array_nullable_string([] of String)}, {"dot.key", w118_i64(102_i64)}, {"flag", w118_bool(false)}, {"nest.leaf", w118_string("two")}, {"s", w118_string("")}),
      w118_row({"a", w118_i64(3_i64)}, {"arr", w118_array_nullable_i64([3_i64])}, {"dot.key", w118_i64(103_i64)}, {"s", w118_string("a\0b")}),
      w118_empty_row,
      w118_row({"a", w118_i64(5_i64)}, {"arr", w118_array_nullable_i64([4_i64, 5_i64])}, {"dot.key", w118_i64(105_i64)}, {"flag", w118_bool(true)}, {"nest.leaf", w118_string("five")}, {"s", w118_i64(42_i64)}),
      w118_row({"a", w118_i64(6_i64)}, {"dot.key", w118_i64(106_i64)}, {"flag", w118_bool(false)}),
      w118_row({"a", w118_i64(7_i64)}, {"arr", w118_array_nullable_i64([6_i64])}, {"dot.key", w118_i64(107_i64)}, {"nest.leaf", w118_string("end")}, {"s", w118_string("last")}),
      w118_row({"a", w118_i64(8_i64)}, {"arr", w118_array_nullable_i64([7_i64])}, {"dot.key", w118_i64(108_i64)}, {"flag", w118_bool(true)}, {"nest.leaf", w118_string("")}, {"s", w118_bool(true)}),
    ]
  when "typed_mixed"
    [
      w118_row({"arr", w118_array_nullable_i64([1_i64, 2_i64])}, {"dot.key", w118_i64(101_i64)}, {"flag", w118_bool(true)}, {"nest.leaf", w118_string("one")}),
      w118_row({"arr", w118_array_nullable_string([] of String)}, {"dot.key", w118_i64(102_i64)}, {"flag", w118_bool(false)}, {"nest.leaf", w118_string("two")}),
      w118_row({"arr", w118_array_nullable_i64([3_i64])}, {"dot.key", w118_i64(103_i64)}),
      w118_empty_row,
      w118_row({"arr", w118_array_nullable_i64([4_i64, 5_i64])}, {"dot.key", w118_i64(105_i64)}, {"flag", w118_bool(true)}, {"nest.leaf", w118_string("five")}),
      w118_row({"dot.key", w118_i64(106_i64)}, {"flag", w118_bool(false)}),
      w118_row({"arr", w118_array_nullable_i64([6_i64])}, {"dot.key", w118_i64(107_i64)}, {"nest.leaf", w118_string("end")}),
      w118_row({"arr", w118_array_nullable_i64([7_i64])}, {"dot.key", w118_i64(108_i64)}, {"flag", w118_bool(true)}, {"nest.leaf", w118_string("")}),
    ]
  else
    w118_fail("unknown W118 profile #{profile.inspect}")
  end
end

def w118_assert_value(actual : CrystalClick::BinaryValue, expected : CrystalClick::BinaryValue, label : String) : Nil
  unless actual.type == expected.type
    w118_fail("#{label}: nominal type differs: #{actual.type.name.inspect} != #{expected.type.name.inspect}")
  end
  w118_require(actual.is_null? == expected.is_null?, "#{label}: NULL state differs")
  return if expected.is_null?

  tag = actual.type.tag
  recursive = tag == CrystalClick::BinaryDataType::TAG_ARRAY ||
              tag == CrystalClick::BinaryDataType::TAG_NULLABLE ||
              tag == CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE ||
              tag == CrystalClick::BinaryDataType::TAG_NAMED_TUPLE ||
              tag == CrystalClick::BinaryDataType::TAG_MAP
  if recursive
    w118_require(actual.child_count == expected.child_count, "#{label}: child count differs")
    expected.child_count.times do |index|
      w118_assert_value(actual.child_at(index), expected.child_at(index), "#{label} child #{index}")
    end
  else
    w118_assert_bytes("#{label} scalar payload", actual.bytes, expected.bytes)
  end
end

def w118_assert_rows(actual : Array(CrystalClick::ObjectSharedMapRow), expected : Array(CrystalClick::ObjectSharedMapRow), label : String) : Nil
  w118_require(actual.size == expected.size, "#{label}: row count differs")
  expected.each_with_index do |expected_row, row_index|
    actual_row = actual[row_index]
    w118_require(actual_row.entry_count == expected_row.entry_count, "#{label}: row #{row_index} entry count differs")
    expected_row.entry_count.times do |entry_index|
      actual_entry = actual_row.entry_at(entry_index)
      expected_entry = expected_row.entry_at(entry_index)
      w118_assert_bytes("#{label}: row #{row_index} path #{entry_index}", actual_entry.path, expected_entry.path)
      w118_assert_value(actual_entry.value, expected_entry.value, "#{label}: row #{row_index} entry #{entry_index}")
    end
  end
end

def w118_read_u64_le(bytes : Bytes, offset : Int32) : UInt64
  w118_require(offset >= 0 && offset <= bytes.size - 8, "W118 size lane is truncated")
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

def w118_read_varuint(bytes : Bytes, start : Int32) : Tuple(UInt64, Int32)
  cursor = start
  value = 0_u64
  10.times do |group|
    w118_require(cursor < bytes.size, "W118 path/value lane has a truncated length")
    byte = bytes[cursor]
    cursor += 1
    w118_require(group != 9 || byte <= 1_u8, "W118 path/value lane length overflows UInt64")
    payload = (byte & 0x7f_u8).to_u64
    w118_require(!(group > 0 && byte < 0x80_u8 && payload == 0_u64), "W118 path/value lane has noncanonical length")
    value |= payload << (group * 7)
    return {value, cursor} if byte < 0x80_u8
  end
  w118_fail("W118 path/value lane length does not terminate")
end

def w118_lane_offset(bytes : Bytes, entries : Int32) : Int32
  cursor = 0_i32
  entries.times do
    length, payload_start = w118_read_varuint(bytes, cursor)
    w118_require(length <= (bytes.size - payload_start).to_u64, "W118 path/value lane item exceeds its slice")
    cursor = payload_start + length.to_i32
  end
  cursor
end

def w118_counts_before(sizes : Bytes, row_count : Int32) : Int32
  total = 0_i64
  row_count.times do |row|
    count = w118_read_u64_le(sizes, row * 8)
    w118_require(count <= Int32::MAX.to_u64 && total <= Int32::MAX.to_i64 - count.to_i64, "W118 selected entry count exceeds in-memory domain")
    total += count.to_i64
  end
  total.to_i32
end

def w118_slice(bytes : Bytes, start : Int32, length : Int32) : Bytes
  w118_require(start >= 0 && length >= 0 && start <= bytes.size - length, "W118 selected lane slice is out of bounds")
  Bytes.new(length) { |index| bytes[start + index] }
end

def w118_selected_lanes(lanes : Tuple(Bytes, Bytes, Bytes)) : Tuple(Bytes, Bytes, Bytes)
  sizes, paths, values = lanes
  w118_require(sizes.size == W118_ROW_COUNT * 8, "W118 size lane is not exactly one UInt64 per source row")
  first_entry = w118_counts_before(sizes, W118_WINDOW_FIRST)
  after_window = w118_counts_before(sizes, W118_WINDOW_FIRST + W118_WINDOW_COUNT)
  total_entries = w118_counts_before(sizes, W118_ROW_COUNT)
  paths_start = w118_lane_offset(paths, first_entry)
  paths_end = w118_lane_offset(paths, after_window)
  values_start = w118_lane_offset(values, first_entry)
  values_end = w118_lane_offset(values, after_window)
  w118_require(w118_lane_offset(paths, total_entries) == paths.size, "W118 paths lane has trailing or missing entries")
  w118_require(w118_lane_offset(values, total_entries) == values.size, "W118 values lane has trailing or missing entries")
  {
    w118_slice(sizes, W118_WINDOW_FIRST * 8, W118_WINDOW_COUNT * 8),
    w118_slice(paths, paths_start, paths_end - paths_start),
    w118_slice(values, values_start, values_end - values_start),
  }
end

def w118_stream_raw(part : String, logical_stream : String, profile : String, role : String) : Bytes
  hash = CrystalClick::StreamName.hash(logical_stream)
  bin_path = File.join(part, "#{hash}.bin")
  w118_require(File.file?(bin_path) && !File.symlink?(bin_path), "#{profile} #{role}: unsafe/missing #{logical_stream} .bin")
  compressed = File.read(bin_path).to_slice
  compressed.empty? ? Bytes.empty : CrystalClick::CompressedBlock.decode_all(compressed)
end

def w118_load_lanes(part : String, profile : String, role : String, temp_root : String) : Tuple(Bytes, Bytes, Bytes)
  streams = {W118_SIZE_STREAM, W118_PATH_STREAM, W118_VALUE_STREAM}
  raws = streams.map do |logical_stream|
    raw = w118_stream_raw(part, logical_stream, profile, role)
    expected = W116JsonPhysicalVectors.expected_raw_stream(profile, logical_stream)
    w118_assert_bytes("#{profile} #{role} independent literal #{logical_stream}", raw, expected)
    lane = logical_stream == W118_SIZE_STREAM ? "sizes" : logical_stream == W118_PATH_STREAM ? "paths" : "values"
    File.write(File.join(temp_root, "#{profile}_#{role}_#{lane}_raw.bin"), raw)
    raw
  end
  {raws[0], raws[1], raws[2]}
end

def w118_encoded_lanes(rows : Array(CrystalClick::ObjectSharedMapRow)) : Tuple(Bytes, Bytes, Bytes)
  streams = CrystalClick::ObjectSharedMapCodec.encode(rows, CrystalClick::BinaryCodecLimits.default)
  {streams.sizes, streams.paths, streams.values}
end

def w118_store_lanes(temp_root : String, profile : String, role : String, kind : String, lanes : Tuple(Bytes, Bytes, Bytes)) : Nil
  File.write(File.join(temp_root, "#{profile}_#{role}_#{kind}_sizes.bin"), lanes[0])
  File.write(File.join(temp_root, "#{profile}_#{role}_#{kind}_paths.bin"), lanes[1])
  File.write(File.join(temp_root, "#{profile}_#{role}_#{kind}_values.bin"), lanes[2])
end

def w118_compare_lanes(label : String, actual : Tuple(Bytes, Bytes, Bytes), expected : Tuple(Bytes, Bytes, Bytes)) : Nil
  w118_assert_bytes("#{label} sizes", actual[0], expected[0])
  w118_assert_bytes("#{label} paths", actual[1], expected[1])
  w118_assert_bytes("#{label} values", actual[2], expected[2])
end

def w118_expect_writer_mismatch_control(rows : Array(CrystalClick::ObjectSharedMapRow), expected : Tuple(Bytes, Bytes, Bytes)) : Nil
  candidate = w118_encoded_lanes(rows)
  values = candidate[2].dup
  w118_require(!values.empty?, "W118 writer mismatch control needs a nonempty values lane")
  values[values.size - 1] ^= 1_u8
  begin
    w118_compare_lanes("seeded writer byte control", {candidate[0], candidate[1], values}, expected)
  rescue error : W118Mismatch
    w118_require(error.message == "W118 byte mismatch: seeded writer byte control values", "W118 seeded byte control failed for an unrelated reason")
    puts "PASS W118 writer comparator control: rejected one seeded values-lane byte"
    return
  end
  w118_fail("W118 writer comparator accepted a seeded byte mismatch")
end

def w118_check_nothing_null_envelope : Nil
  # Root Nothing is a W117 envelope sentinel for NULL, not an ordinary scalar.
  # Physical MAP stores can preserve an explicitly serialized dynamic value;
  # canonical insertion omission is a higher-level Object policy.
  row = w118_row({"x", CrystalClick::BinaryValue.null})
  rows = [row]
  authored = w118_encoded_lanes(rows)
  expected = {
    Bytes[1_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8], # one UInt64 count
    Bytes[1_u8, 'x'.ord.to_u8],                            # path "x"
    Bytes[1_u8, 0_u8],                                     # one-byte NULL envelope
  }
  w118_compare_lanes("Nothing NULL envelope hand literal", authored, expected)
  decoded = CrystalClick::ObjectSharedMapCodec.decode(
    expected[0], expected[1], expected[2], 1, CrystalClick::BinaryCodecLimits.default
  )
  w118_assert_rows(decoded, rows, "Nothing NULL envelope decoded")
  puts "PASS W118 paired MAP NULL envelope: hand-authored Nothing NULL bytes"
end

def w118_check_pair(profile : String, role : String, part : String, temp_root : String) : Nil
  w118_guard_part_children(part)
  W116JsonPhysicalVectors.assert_part(profile, part, attached: role == "attached")
  lanes = w118_load_lanes(part, profile, role, temp_root)
  expected_rows = w118_expected_rows(profile)
  w118_require(expected_rows.size == W118_ROW_COUNT, "#{profile}: authored row count differs")

  decoded = CrystalClick::ObjectSharedMapCodec.decode(
    lanes[0], lanes[1], lanes[2], W118_ROW_COUNT, CrystalClick::BinaryCodecLimits.default
  )
  w118_assert_rows(decoded, expected_rows, "#{profile} #{role} decoded full block")

  authored_lanes = w118_encoded_lanes(expected_rows)
  w118_store_lanes(temp_root, profile, role, "authored_full", authored_lanes)
  w118_compare_lanes("#{profile} #{role} authored full block", authored_lanes, lanes)
  w118_compare_lanes("#{profile} #{role} decoded re-encode", w118_encoded_lanes(decoded), lanes)

  selected = w118_selected_lanes(lanes)
  expected_selected = expected_rows[W118_WINDOW_FIRST, W118_WINDOW_COUNT]
  w118_require(expected_selected.size == W118_WINDOW_COUNT, "#{profile}: authored selected row window is incomplete")
  selected_decoded = CrystalClick::ObjectSharedMapCodec.decode(
    selected[0], selected[1], selected[2], W118_WINDOW_COUNT, CrystalClick::BinaryCodecLimits.default
  )
  w118_assert_rows(selected_decoded, expected_selected, "#{profile} #{role} selected pk 3..6")
  selected_authored = w118_encoded_lanes(expected_selected)
  w118_store_lanes(temp_root, profile, role, "authored_selected", selected_authored)
  w118_compare_lanes("#{profile} #{role} authored selected pk 3..6", selected_authored, selected)

  if profile == "typed_mixed" && role == "source"
    w118_expect_writer_mismatch_control(expected_rows, lanes)
  end

  puts "PASS W118 MAP lanes: profile=#{profile} role=#{role} rows=#{decoded.size} selected=pk3..6 counts=#{expected_rows.map(&.entry_count).inspect} sizes=#{lanes[0].size} paths=#{lanes[1].size} values=#{lanes[2].size}"
end

def w118_run_check : Nil
  capture_root = ENV["W115_CAPTURE_ROOT"]? || raise "W115_CAPTURE_ROOT is required"
  test_root = ENV["W118_TEST_ROOT"]? || raise "W118_TEST_ROOT is required"
  store_arg = ENV["W118_STORE"]? || raise "W118_STORE is required"
  binary = ENV["CLICKHOUSE_BIN"]? || raise "CLICKHOUSE_BIN is required"
  capture_root = File.realpath(capture_root)
  test_root = File.realpath(test_root)
  store = File.realpath(store_arg)
  w118_require(capture_root.starts_with?("/private/tmp/crystal-click-json-w115.") && !File.symlink?(capture_root), "unsafe W115 capture root")
  w118_require(test_root.starts_with?("/private/tmp/") && !File.symlink?(test_root), "unsafe W118 test root")
  w118_require(store.starts_with?(test_root + "/") && !File.symlink?(store_arg), "W118 ClickHouse store escapes its fresh test root")
  w118_verify_runtime(binary, store)
  w118_check_child_symlink_control(test_root)

  pairs = 0
  W118_PROFILES.each do |profile|
    source = W116JsonPhysicalVectors.fixture_path(profile, false)
    attached = W116JsonPhysicalVectors.fixture_path(profile, true)
    { {"source", source}, {"attached", attached} }.each do |role, part|
      w118_check_pair(profile, role, part, test_root)
      pairs += 1
    end
  end

  w118_check_nothing_null_envelope
  puts "QUALIFIED W118 tri-lane stock oracle: profiles=#{W118_PROFILES.size}, retained_source_and_attached_pairs=#{pairs}, full_and_selected_windows=#{pairs * 2}, independent_literal_lanes=#{pairs * 3}, seeded_writer_byte_control=1, child_symlink_control=1; no new ATTACH/CHECK was executed by W118; no part writer or whole-JSON admission"
end

w118_run_check
