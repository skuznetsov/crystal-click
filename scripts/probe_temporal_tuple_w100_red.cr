# W100 stock-first discriminator for the unchanged 498f5e1 predecessor.
# Run with pinned stock ClickHouse and a fresh temporary store. Exit 1 at the
# very end is the expected 24-leaf typed-reader RED; earlier errors are fixture
# or oracle failures, never evidence of a current-reader gap.
require "json"
require "../src/crystal_click"

W100_STOCK_VERSION = "26.7.1.1315"
W100_KEYS          = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
W100_MARK_ROWS     = [2_u64, 2_u64, 1_u64, 0_u64]
W100_CONTROL_NUMS  = [10_u64, 20_u64, 30_u64, 40_u64, 50_u64]
W100_CONTROL_TEXT  = ["alpha", "beta", "gamma", "delta", "epsilon"]

struct W100TemporalCase
  getter label : String
  getter type_name : String
  getter width : Int32
  getter row_bytes : Array(Array(UInt8))

  def initialize(@label : String, @type_name : String, @width : Int32, @row_bytes : Array(Array(UInt8)))
  end

  def tuple_type : String
    "Tuple(value #{type_name})"
  end

  def table_name : String
    "w100_#{label}_mixed"
  end
end

# Independent RowBinary bytes: fixed-width carriers are encoded little-endian;
# signed values contribute their two's-complement bit patterns.
def w100_uint_le(value : UInt64, width : Int32) : Array(UInt8)
  Array(UInt8).new(width) { |index| ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

def w100_i32_le(value : Int32) : Array(UInt8)
  w100_uint_le(value.unsafe_as(UInt32).to_u64, 4)
end

def w100_i64_le(value : Int64) : Array(UInt8)
  w100_uint_le(value.unsafe_as(UInt64), 8)
end

def w100_cases : Array(W100TemporalCase)
  cases = [] of W100TemporalCase
  cases << W100TemporalCase.new(
    "date", "Date", 2,
    [0_u64, 1_u64, 32_767_u64, 32_768_u64, 65_535_u64].map { |value| w100_uint_le(value, 2) }
  )
  cases << W100TemporalCase.new(
    "date32", "Date32", 4,
    [-25_567_i32, -1_i32, 0_i32, 1_i32, 24_854_i32].map { |value| w100_i32_le(value) }
  )
  cases << W100TemporalCase.new(
    "datetime", "DateTime", 4,
    [0_u64, 1_u64, 1_000_000_000_u64, 1_700_000_000_u64, 2_000_000_000_u64].map { |value| w100_uint_le(value, 4) }
  )
  cases << W100TemporalCase.new(
    "time", "Time", 4,
    [-3_723_i32, 0_i32, 1_i32, 59_i32, 52_225_i32].map { |value| w100_i32_le(value) }
  )

  (0..9).each do |precision|
    factor = 1_i64
    precision.times { factor *= 10_i64 }
    datetime_ticks = [-1_i64, 0_i64, factor, 1_700_000_000_i64 * factor, 2_000_000_000_i64 * factor]
    cases << W100TemporalCase.new(
      "datetime64_#{precision}", "DateTime64(#{precision})", 8,
      datetime_ticks.map { |value| w100_i64_le(value) }
    )

    half_tick = factor // 2_i64
    time_ticks = [
      -3_723_i64 * factor - half_tick,
      0_i64,
      factor,
      59_i64 * factor + half_tick,
      3_600_i64 * factor + factor - 1_i64,
    ]
    cases << W100TemporalCase.new(
      "time64_#{precision}", "Time64(#{precision})", 8,
      time_ticks.map { |value| w100_i64_le(value) }
    )
  end

  raise "W100 exact declaration matrix differs: #{cases.size}" unless cases.size == 24
  cases
end

def w100_attempt_clickhouse(binary : String, store : String, query : String, input : IO? = nil) : {Bool, String, String}
  output = IO::Memory.new
  error = IO::Memory.new
  status = if input
             Process.run(binary, ["local", "--path", store, "--query", query], input: input, output: output, error: error)
           else
             Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: error)
           end
  {status.success?, output.to_s, error.to_s}
end

def w100_run_clickhouse(binary : String, store : String, query : String) : String
  succeeded, output, error = w100_attempt_clickhouse(binary, store, query)
  raise "ClickHouse local query failed: #{error}\n#{query}" unless succeeded
  output
end

def w100_append_unsigned_le(io : IO, value : UInt64, width : Int32) : Nil
  width.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
end

def w100_append_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

def w100_tuple_rowbinary(keys : Array(UInt64), rows : Array(Array(UInt8)), indexes : Array(Int32)) : String
  output = IO::Memory.new
  indexes.each do |index|
    w100_append_unsigned_le(output, keys[index], 8)
    rows[index].each { |byte| output.write_byte(byte) }
  end
  output.to_s
end

def w100_control_rowbinary(indexes : Array(Int32)) : String
  output = IO::Memory.new
  indexes.each do |index|
    w100_append_unsigned_le(output, W100_KEYS[index], 8)
    w100_append_unsigned_le(output, W100_CONTROL_NUMS[index], 8)
    value = W100_CONTROL_TEXT[index]
    w100_append_varuint(output, value.bytesize.to_u64)
    output.write(value.to_slice)
  end
  output.to_s
end

def w100_control_string_bytes : Array(UInt8)
  bytes = [] of UInt8
  W100_CONTROL_TEXT.each { |value| value.to_slice.each { |byte| bytes << byte } }
  bytes
end

def w100_control_string_lengths : Array(Array(UInt8))
  # String serialization version 1 stores per-row lengths, not cumulative
  # in-memory offsets. Keep this stock-positive control independent of reader.
  W100_CONTROL_TEXT.map { |value| w100_uint_le(value.bytesize.to_u64, 8) }
end

def w100_create_table(binary : String, store : String, table : String, payload_type : String, default_ratio : String = "0.9375") : Nil
  settings = "index_granularity = 2, index_granularity_bytes = 10485760, enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0, ratio_of_defaults_for_sparse_serialization = #{default_ratio}, compress_marks = 0, compress_primary_key = 0, min_compress_block_size = 0, max_compress_block_size = 4096, default_compression_codec = 'LZ4'"
  w100_run_clickhouse(
    binary,
    store,
    "CREATE TABLE default.#{table} (pk UInt64, payload #{payload_type}) ENGINE = MergeTree ORDER BY pk SETTINGS #{settings}"
  )
end

def w100_insert_rowbinary(binary : String, store : String, table : String, bytes : String) : Nil
  input = IO::Memory.new(bytes.to_slice)
  succeeded, output, error = w100_attempt_clickhouse(binary, store, "INSERT INTO default.#{table} FORMAT RowBinary", input)
  raise "stock RowBinary insert failed for #{table}: #{error}#{output}" unless succeeded
end

def w100_part_path(binary : String, store : String, table : String) : String
  rows = w100_run_clickhouse(
    binary,
    store,
    "SELECT path, part_type, rows FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TSVRaw"
  ).lines.map(&.strip).reject(&.empty?)
  raise "expected exactly one active part for #{table}, got #{rows.inspect}" unless rows.size == 1
  columns = rows[0].split('\t')
  raise "malformed system.parts row for #{table}: #{rows[0].inspect}" unless columns.size == 3
  raise "#{table} part is not Wide: #{columns[1]}" unless columns[1] == "Wide"
  raise "#{table} part row count differs: #{columns[2]}" unless columns[2].to_i == W100_KEYS.size
  columns[0]
end

def w100_check_table(binary : String, store : String, table : String, part : String) : Nil
  output = w100_run_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  expected = "#{File.basename(part.chomp("/"))}\t1"
  raise "#{table} CHECK TABLE failed: #{output.inspect}" unless output == expected
end

def w100_read_u64_le(bytes : Bytes, offset : Int32) : UInt64
  8.times.reduce(0_u64) { |value, index| value | (bytes[offset + index].to_u64 << (index * 8)) }
end

def w100_mark_rows(part : String, logical_name : String) : Array(UInt64)
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.mrk2")
  bytes = File.read(path).to_slice
  mark_size = CrystalClick::WidePart::MARK_SIZE
  raise "#{logical_name} mark file has a partial record" unless bytes.size % mark_size == 0
  Array(UInt64).new(bytes.size // mark_size) do |index|
    w100_read_u64_le(bytes, index * mark_size + 16)
  end
end

def w100_expected_substreams(children : Array(String)) : String
  lines = ["columns substreams version: 1", "2 columns:", "1 substreams for column \x60pk\x60:", "\tpk", "#{children.size} substreams for column \x60payload\x60:"]
  children.each { |child| lines << "\t#{child}" }
  lines.join("\n") + "\n"
end

def w100_serializer_count(row : Hash(String, JSON::Any), label : String, expected : Int32) : Nil
  rows = row["num_rows"]?.try(&.as_i) || raise "#{label} serializer row count missing"
  defaults = row["num_defaults"]?.try(&.as_i) || raise "#{label} serializer default count missing"
  raise "#{label} serializer rows differ: #{rows}" unless rows == W100_KEYS.size
  raise "#{label} serializer defaults differ: expected #{expected}, got #{defaults}" unless defaults == expected
end

def w100_payload_child(info : JSON::Any, label : String) : {Hash(String, JSON::Any), Hash(String, JSON::Any)}
  serializers = info.as_h["columns"]?.try(&.as_a) || raise "#{label} serializer records missing"
  names = serializers.map { |entry| entry.as_h["name"].as_s }
  raise "#{label} serializer names differ: #{names.inspect}" unless names == ["payload", "pk"]
  payload = serializers[0].as_h
  children = payload["subcolumns"]?.try(&.as_a) || raise "#{label} Tuple child metadata missing"
  raise "#{label} Tuple child count differs: #{children.size}" unless children.size == 1
  {payload, children[0].as_h}
end

def w100_assert_schema_and_streams(part : String, type_name : String, children : Array(String), label : String) : Nil
  w100_assert_logical_schema(part, type_name, children, label)

  expected_bins = (["pk"] + children).map { |name| "#{CrystalClick::StreamName.hash(name)}.bin" }.sort
  expected_marks = (["pk"] + children).map { |name| "#{CrystalClick::StreamName.hash(name)}.mrk2" }.sort
  entries = Dir.children(part)
  actual_bins = entries.select(&.ends_with?(".bin")).sort
  actual_marks = entries.select(&.ends_with?(".mrk2")).sort
  raise "#{label} physical stream inventory differs: #{actual_bins.inspect}" unless actual_bins == expected_bins
  raise "#{label} mark stream inventory differs: #{actual_marks.inspect}" unless actual_marks == expected_marks

  (["pk"] + children).each do |name|
    rows = w100_mark_rows(part, name)
    raise "#{label} #{name} mark rows differ: #{rows.inspect}" unless rows == W100_MARK_ROWS
  end
end

def w100_assert_logical_schema(part : String, type_name : String, children : Array(String), label : String) : Nil
  w100_assert_columns_schema(part, type_name, label)

  actual_substreams = File.read(File.join(part, "columns_substreams.txt"))
  expected_substreams = w100_expected_substreams(children)
  raise "#{label} stock substreams differ:\n#{actual_substreams}" unless actual_substreams == expected_substreams
end

def w100_assert_columns_schema(part : String, type_name : String, label : String) : Nil
  columns = File.read(File.join(part, "columns.txt")).lines.map(&.strip)
  expected_columns = ["columns format version: 1", "2 columns:", "\x60pk\x60 UInt64", "\x60payload\x60 #{type_name}"]
  raise "#{label} stock schema differs: #{columns.inspect}" unless columns == expected_columns
end

def w100_observe_optional_streams(part : String, children : Array(String), label : String) : {Array(String), Array(String)}
  expected_bins = (["pk"] + children).map { |name| "#{CrystalClick::StreamName.hash(name)}.bin" }
  expected_marks = (["pk"] + children).map { |name| "#{CrystalClick::StreamName.hash(name)}.mrk2" }
  entries = Dir.children(part)
  actual_bins = entries.select(&.ends_with?(".bin")).sort
  actual_marks = entries.select(&.ends_with?(".mrk2")).sort
  raise "#{label} has undeclared physical streams: #{actual_bins.inspect}" unless actual_bins.all? { |name| expected_bins.includes?(name) }
  raise "#{label} primary-key data stream is absent" unless actual_bins.includes?(expected_bins[0])
  expected_marks_for_bins = actual_bins.map { |name| name.sub(/\.bin$/, ".mrk2") }.sort
  raise "#{label} marks do not match actual data streams: #{actual_marks.inspect}" unless actual_marks == expected_marks_for_bins
  raise "#{label} has undeclared mark streams: #{actual_marks.inspect}" unless actual_marks.all? { |name| expected_marks.includes?(name) }

  logical_names = (["pk"] + children).select { |name| actual_bins.includes?("#{CrystalClick::StreamName.hash(name)}.bin") }
  logical_names.each do |name|
    rows = w100_mark_rows(part, name)
    raise "#{label} #{name} mark rows differ: #{rows.inspect}" unless rows == W100_MARK_ROWS
  end
  {actual_bins, actual_marks}
end

def w100_assert_metadata(part : String, label : String, expected_defaults : Int32) : JSON::Any
  info = JSON.parse(File.read(File.join(part, "serialization.json")))
  metadata = info.as_h
  raise "#{label} serialization version differs" unless metadata["version"]?.try(&.as_i) == 1
  raise "#{label} nested type-version propagation differs" unless metadata["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool) == true
  payload, child = w100_payload_child(info, label)
  raise "#{label} payload serializer kind is unexpected" unless payload["kind"]?.try(&.as_s) == "Default"
  raise "#{label} child serializer kind is unexpected" unless child["kind"]?.try(&.as_s) == "Default"
  w100_serializer_count(payload, "#{label} Tuple", expected_defaults)
  w100_serializer_count(child, "#{label} Tuple child", expected_defaults)
  puts "OBSERVED #{label} serialization.json=#{info.to_json}"
  info
end

def w100_assert_physical_payload(part : String, child : String, rows : Array(Array(UInt8)), label : String) : Nil
  expected_bytes = [] of UInt8
  rows.each { |row| row.each { |byte| expected_bytes << byte } }
  path = File.join(part, "#{CrystalClick::StreamName.hash(child)}.bin")
  actual = CrystalClick::CompressedBlock.decode_all(File.read(path).to_slice)
  expected = expected_bytes.to_unsafe.to_slice(expected_bytes.size)
  raise "#{label} decompressed bytes differ: expected #{expected.size}, got #{actual.size}" unless actual == expected
end

def w100_key_rows : Array(Array(UInt8))
  W100_KEYS.map { |key| w100_uint_le(key, 8) }
end

def w100_validate_zero_metadata_row(row : Hash(String, JSON::Any), label : String, expected_defaults : Int32) : Nil
  kind = row["kind"]?.try(&.as_s) || raise "#{label} serializer kind missing"
  raise "#{label} serializer kind differs: #{kind}" unless kind == "Default" || kind == "AlwaysDefault" || kind == "Sparse"
  if row.has_key?("num_rows") || row.has_key?("num_defaults")
    w100_serializer_count(row, label, expected_defaults)
  elsif kind != "AlwaysDefault"
    raise "#{label} #{kind} serializer omitted observed defaults"
  end
  (row["subcolumns"]?.try(&.as_a) || [] of JSON::Any).each_with_index do |child, index|
    w100_validate_zero_metadata_row(child.as_h, "#{label} child #{index}", expected_defaults)
  end
end

def w100_observe_zero_composite_metadata(part : String, child_count : Int32) : JSON::Any
  info = JSON.parse(File.read(File.join(part, "serialization.json")))
  metadata = info.as_h
  raise "all-zero composite serialization version differs" unless metadata["version"]?.try(&.as_i) == 1
  raise "all-zero composite nested propagation differs" unless metadata["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool) == true
  serializers = metadata["columns"]?.try(&.as_a) || [] of JSON::Any
  if serializers.empty?
    puts "OBSERVED all-zero composite serialization.json columns=[] (legal under ratio_of_defaults_for_sparse_serialization=1.0)"
  else
    names = serializers.map { |entry| entry.as_h["name"].as_s }
    raise "all-zero composite serializer names differ: #{names.inspect}" unless names == ["payload", "pk"]
    payload = serializers[0].as_h
    w100_validate_zero_metadata_row(payload, "all-zero composite Tuple", 5)
    children = payload["subcolumns"]?.try(&.as_a) || raise "all-zero composite Tuple child metadata missing"
    raise "all-zero composite child metadata count differs: #{children.size}" unless children.size == child_count
    children.each_with_index do |child, index|
      w100_validate_zero_metadata_row(child.as_h, "all-zero composite leaf #{index}", 5)
    end
    w100_validate_zero_metadata_row(serializers[1].as_h, "all-zero composite pk", 0)
  end
  puts "OBSERVED all-zero composite serialization.json=#{info.to_json}"
  info
end

def w100_observe_default_metadata(part : String, label : String, expected_child_defaults : Int32, require_child_count : Bool) : JSON::Any
  info = JSON.parse(File.read(File.join(part, "serialization.json")))
  metadata = info.as_h
  raise "#{label} serialization version differs" unless metadata["version"]?.try(&.as_i) == 1
  raise "#{label} nested type-version propagation differs" unless metadata["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool) == true
  serializers = metadata["columns"]?.try(&.as_a) || [] of JSON::Any
  if serializers.empty?
    raise "#{label} required Date32 child default counters were not serialized" if require_child_count
    puts "OBSERVED #{label} serialization.json columns=[]; default counters are not exposed by ClickHouse"
    puts "OBSERVED #{label} serialization.json=#{info.to_json}"
    return info
  end

  names = serializers.map { |entry| entry.as_h["name"]?.try(&.as_s) || raise "#{label} serializer name missing" }
  raise "#{label} serializer names differ: #{names.inspect}" unless names == ["payload", "pk"]
  payload = serializers[0].as_h
  children = payload["subcolumns"]?.try(&.as_a) || raise "#{label} Date32 child metadata missing"
  raise "#{label} Tuple child count differs: #{children.size}" unless children.size == 1

  [{"Tuple", payload}, {"primary key", serializers[1].as_h}].each do |(suffix, row)|
    name = "#{label} #{suffix}"
    kind = row["kind"]?.try(&.as_s) || raise "#{name} serializer kind missing"
    unless kind == "Default" || kind == "AlwaysDefault" || kind == "Sparse"
      raise "#{name} serializer kind differs: #{kind}"
    end
    observed_rows = row["num_rows"]?.try(&.to_json) || "absent"
    observed_defaults = row["num_defaults"]?.try(&.to_json) || "absent"
    puts "OBSERVED #{name} kind=#{kind} num_rows=#{observed_rows} num_defaults=#{observed_defaults}"
  end

  child = children[0].as_h
  child_kind = child["kind"]?.try(&.as_s) || raise "#{label} Tuple child serializer kind missing"
  unless child_kind == "Default" || child_kind == "AlwaysDefault" || child_kind == "Sparse"
    raise "#{label} Tuple child serializer kind differs: #{child_kind}"
  end
  if child.has_key?("num_rows") || child.has_key?("num_defaults")
    w100_serializer_count(child, "#{label} Tuple child", expected_child_defaults)
  elsif require_child_count
    raise "#{label} Tuple child default counters were not serialized"
  else
    puts "OBSERVED #{label} Tuple child kind=#{child_kind} without serialized counters"
  end
  puts "OBSERVED #{label} serialization.json=#{info.to_json}"
  info
end

def w100_observed_child_default_count(info : JSON::Any) : Int32?
  serializers = info.as_h["columns"]?.try(&.as_a) || return nil
  payload = serializers.find { |entry| entry.as_h["name"]?.try(&.as_s) == "payload" } || return nil
  children = payload.as_h["subcolumns"]?.try(&.as_a) || return nil
  return nil unless children.size == 1
  children[0].as_h["num_defaults"]?.try(&.as_i)
end

def w100_check_date32_stats_profile(binary : String, store : String, label : String, raw_value : Int32, expected_defaults : Int32) : Nil
  table = "w100_date32_stats_#{label}"
  tuple_type = "Tuple(value Date32)"
  child = "payload%2Evalue"
  rows = Array.new(W100_KEYS.size) { w100_i32_le(raw_value) }
  w100_create_table(binary, store, table, tuple_type, "0.9375")
  inserted = w100_tuple_rowbinary(W100_KEYS, rows, [0_i32, 1_i32, 2_i32, 3_i32, 4_i32])
  w100_insert_rowbinary(binary, store, table, inserted)
  part = w100_part_path(binary, store, table)
  w100_assert_columns_schema(part, tuple_type, "Date32 statistics #{label}")
  entries = Dir.children(part)
  bins = entries.select(&.ends_with?(".bin")).sort
  marks = entries.select(&.ends_with?(".mrk2")).sort
  pk_bin = "#{CrystalClick::StreamName.hash("pk")}.bin"
  pk_mark = "#{CrystalClick::StreamName.hash("pk")}.mrk2"
  raise "Date32 statistics #{label} primary-key data stream is absent" unless bins.includes?(pk_bin)
  raise "Date32 statistics #{label} primary-key mark stream is absent" unless marks.includes?(pk_mark)
  pk_rows = w100_mark_rows(part, "pk")
  raise "Date32 statistics #{label} primary-key marks differ: #{pk_rows.inspect}" unless pk_rows == W100_MARK_ROWS
  w100_assert_physical_payload(part, "pk", w100_key_rows, "Date32 statistics #{label} primary key")
  leaf_bin = "#{CrystalClick::StreamName.hash(child)}.bin"
  if bins.includes?(leaf_bin)
    stored = File.read(File.join(part, leaf_bin)).to_slice
    if stored.empty?
      puts "OBSERVED Date32 statistics #{label} child stream exists with zero bytes; Sparse representation intentionally not constrained"
    else
      actual = CrystalClick::CompressedBlock.decode_all(stored)
      puts "OBSERVED Date32 statistics #{label} child physical bytes=#{actual.to_a.inspect}; representation intentionally not constrained"
    end
  end
  info = w100_observe_default_metadata(part, "Date32 statistics #{label}", expected_defaults, true)
  observed_defaults = w100_observed_child_default_count(info)
  raise "Date32 statistics #{label} expected child count #{expected_defaults}, observed #{observed_defaults}" unless observed_defaults == expected_defaults
  w100_check_table(binary, store, table, part)
  actual = w100_run_clickhouse(binary, store, "SELECT pk, payload.value FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  raise "Date32 statistics #{label} full RowBinary differs from raw #{raw_value}" unless actual == inserted
  selected = w100_tuple_rowbinary(W100_KEYS, rows, [1_i32, 2_i32, 3_i32])
  range = w100_run_clickhouse(binary, store, "SELECT pk, payload.value FROM default.#{table} WHERE pk >= 2 AND pk < 5 ORDER BY pk FORMAT RowBinary")
  raise "Date32 statistics #{label} selected RowBinary differs from raw #{raw_value}" unless range == selected
  puts "PASS stock Date32 statistics-only #{label}: ratio=0.9375, raw=#{raw_value}, expected/observed child defaults=#{expected_defaults}/#{observed_defaults}, substreams=#{File.read(File.join(part, "columns_substreams.txt")).inspect}, bins=#{bins.inspect}, marks=#{marks.inspect}, metadata=#{info.to_json}, CHECK and full/selected RowBinary; not a reader-RED/admission fixture"
end

def w100_check_all_zero_composite(binary : String, store : String, cases : Array(W100TemporalCase)) : Nil
  type_fields = cases.map { |item| "#{item.label} #{item.type_name}" }
  type_name = "Tuple(#{type_fields.join(", ")})"
  children = cases.map { |item| "payload%2E#{item.label}" }
  zero_fields = cases.map { |item| Array(UInt8).new(item.width, 0_u8) }
  rows = Array.new(W100_KEYS.size) do
    row = [] of UInt8
    zero_fields.each { |field| field.each { |byte| row << byte } }
    row
  end
  table = "w100_all_zero_temporal_composite"
  w100_create_table(binary, store, table, type_name, "1.0")
  inserted = w100_tuple_rowbinary(W100_KEYS, rows, [0_i32, 1_i32, 2_i32, 3_i32, 4_i32])
  w100_insert_rowbinary(binary, store, table, inserted)
  part = w100_part_path(binary, store, table)
  w100_assert_columns_schema(part, type_name, "all-zero temporal composite")
  puts "OBSERVED all-zero temporal composite columns_substreams.txt=#{File.read(File.join(part, "columns_substreams.txt")).inspect}"
  w100_assert_physical_payload(part, "pk", w100_key_rows, "all-zero composite primary key")

  bins, marks = w100_observe_optional_streams(part, children, "all-zero temporal composite")

  children.each_with_index do |child, index|
    bin = "#{CrystalClick::StreamName.hash(child)}.bin"
    if bins.includes?(bin)
      expected_rows = Array.new(W100_KEYS.size) { zero_fields[index] }
      w100_assert_physical_payload(part, child, expected_rows, "all-zero composite #{cases[index].label}")
    end
  end
  info = w100_observe_zero_composite_metadata(part, children.size)
  w100_check_table(binary, store, table, part)
  projection = cases.map { |item| "payload.#{item.label}" }.join(", ")
  actual = w100_run_clickhouse(binary, store, "SELECT pk, #{projection} FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  raise "all-zero composite full RowBinary differs from independently generated bytes" unless actual == inserted
  selected = w100_tuple_rowbinary(W100_KEYS, rows, [1_i32, 2_i32, 3_i32])
  range = w100_run_clickhouse(binary, store, "SELECT pk, #{projection} FROM default.#{table} WHERE pk >= 2 AND pk < 5 ORDER BY pk FORMAT RowBinary")
  raise "all-zero composite selected RowBinary differs from independently generated bytes" unless range == selected
  puts "PASS stock all-zero 24-leaf composite: CHECK, marks #{W100_MARK_ROWS.inspect} for present streams, physical bins=#{bins.inspect}, marks=#{marks.inspect}, metadata=#{info.to_json}, full and selected RowBinary"
end

def w100_assert_date32_default_profile(binary : String, store : String, label : String, raw_value : Int32, expected_defaults : Int32) : Nil
  table = "w100_date32_#{label}"
  tuple_type = "Tuple(value Date32)"
  child = "payload%2Evalue"
  rows = Array.new(W100_KEYS.size) { w100_i32_le(raw_value) }
  w100_create_table(binary, store, table, tuple_type, "1.0")
  inserted = w100_tuple_rowbinary(W100_KEYS, rows, [0_i32, 1_i32, 2_i32, 3_i32, 4_i32])
  w100_insert_rowbinary(binary, store, table, inserted)
  part = w100_part_path(binary, store, table)
  w100_assert_columns_schema(part, tuple_type, "Date32 #{label}")
  bins, marks = w100_observe_optional_streams(part, [child], "Date32 #{label}")
  w100_assert_physical_payload(part, "pk", w100_key_rows, "Date32 #{label} primary key")
  leaf_bin = "#{CrystalClick::StreamName.hash(child)}.bin"
  leaf_mark = "#{CrystalClick::StreamName.hash(child)}.mrk2"
  w100_assert_physical_payload(part, child, rows, "Date32 #{label}") if bins.includes?(leaf_bin)
  info = w100_observe_default_metadata(part, "Date32 #{label}", expected_defaults, false)
  observed_defaults = w100_observed_child_default_count(info)
  w100_check_table(binary, store, table, part)
  actual = w100_run_clickhouse(binary, store, "SELECT pk, payload.value FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  raise "Date32 #{label} full RowBinary differs from raw #{raw_value}" unless actual == inserted
  selected = w100_tuple_rowbinary(W100_KEYS, rows, [1_i32, 2_i32, 3_i32])
  range = w100_run_clickhouse(binary, store, "SELECT pk, payload.value FROM default.#{table} WHERE pk >= 2 AND pk < 5 ORDER BY pk FORMAT RowBinary")
  raise "Date32 #{label} selected RowBinary differs from raw #{raw_value}" unless range == selected

  puts "OBSERVED Date32 #{label} raw=#{raw_value} expected_child_defaults=#{expected_defaults} observed_child_defaults=#{observed_defaults.try(&.to_s) || "not exposed"} leaf_bin_present=#{bins.includes?(leaf_bin)} leaf_mrk2_present=#{marks.includes?(leaf_mark)} substreams=#{File.read(File.join(part, "columns_substreams.txt")).inspect} bins=#{bins.inspect} marks=#{marks.inspect} metadata=#{info.to_json}"
  puts "PASS Date32 default discriminator #{label}: raw=#{raw_value}, expected child defaults=#{expected_defaults}, observed child defaults=#{observed_defaults.try(&.to_s) || "not exposed"}, actual leaf stream presence independently observed"
end

def w100_check_stock_case(binary : String, store : String, case_data : W100TemporalCase) : String
  child = "payload%2Evalue"
  table = case_data.table_name
  w100_create_table(binary, store, table, case_data.tuple_type)
  inserted = w100_tuple_rowbinary(W100_KEYS, case_data.row_bytes, [0_i32, 1_i32, 2_i32, 3_i32, 4_i32])
  w100_insert_rowbinary(binary, store, table, inserted)

  part = w100_part_path(binary, store, table)
  w100_assert_schema_and_streams(part, case_data.tuple_type, [child], "#{case_data.label} mixed")
  w100_assert_physical_payload(part, "pk", w100_key_rows, "#{case_data.label} primary key")
  w100_assert_physical_payload(part, child, case_data.row_bytes, "#{case_data.label} mixed")
  expected_defaults = case_data.row_bytes.count { |row| row.all? { |byte| byte == 0_u8 } }
  w100_assert_metadata(part, "#{case_data.label} mixed", expected_defaults)
  w100_check_table(binary, store, table, part)

  actual = w100_run_clickhouse(binary, store, "SELECT pk, payload.value FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  raise "#{case_data.label} full RowBinary differs from independent bytes" unless actual == inserted
  selected = w100_tuple_rowbinary(W100_KEYS, case_data.row_bytes, [1_i32, 2_i32, 3_i32])
  range_actual = w100_run_clickhouse(binary, store, "SELECT pk, payload.value FROM default.#{table} WHERE pk >= 2 AND pk < 5 ORDER BY pk FORMAT RowBinary")
  raise "#{case_data.label} selected RowBinary differs from independent bytes" unless range_actual == selected
  puts "PASS stock #{case_data.label}: exact schema/substreams, all streams, marks #{W100_MARK_ROWS.inspect}, physical bytes, defaults=#{expected_defaults}, CHECK, full and selected RowBinary"
  part
end

def w100_assert_positive_control(binary : String, store : String) : Nil
  table = "w100_admitted_u64_string_control"
  type_name = "Tuple(a UInt64, b String)"
  w100_create_table(binary, store, table, type_name)
  expected = w100_control_rowbinary([0_i32, 1_i32, 2_i32, 3_i32, 4_i32])
  w100_insert_rowbinary(binary, store, table, expected)
  part = w100_part_path(binary, store, table)
  children = ["payload%2Ea", "payload%2Eb.size", "payload%2Eb"]
  w100_assert_schema_and_streams(part, type_name, children, "admitted Tuple control")
  w100_assert_physical_payload(part, "pk", w100_key_rows, "admitted Tuple control primary key")
  w100_assert_physical_payload(part, children[0], W100_CONTROL_NUMS.map { |value| w100_uint_le(value, 8) }, "admitted Tuple control UInt64")
  w100_assert_physical_payload(part, children[1], w100_control_string_lengths, "admitted Tuple control String lengths")
  string_bytes = w100_control_string_bytes
  w100_assert_physical_payload(part, children[2], [string_bytes], "admitted Tuple control String bytes")
  w100_check_table(binary, store, table, part)
  reader = CrystalClick::WidePart.open_typed(part, "payload")
  data = reader.read_tuple_mark_range("payload", 0, reader.mark_count)
  raise "admitted Tuple control type differs: #{data.type_name}" unless data.type_name == type_name
  raise "admitted Tuple control UInt64 values differ" unless data["a"].uint64_values == W100_CONTROL_NUMS
  raise "admitted Tuple control String values differ" unless data["b"].string_values == W100_CONTROL_TEXT
  actual = w100_run_clickhouse(binary, store, "SELECT pk, payload.a, payload.b FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  raise "admitted Tuple control RowBinary differs" unless actual == expected
  puts "PASS existing admitted UInt64/String typed Tuple + CHECK + full independent RowBinary"
end

def w100_expect_reader_rejection(part : String, case_data : W100TemporalCase) : String
  begin
    reader = CrystalClick::WidePart.open_typed(part, "payload")
    reader.read_tuple_mark_range("payload", 0, reader.mark_count)
    puts "UNEXPECTED typed reader admitted stock Tuple(value #{case_data.type_name})"
    "admitted"
  rescue ex : CrystalClick::UnsupportedFormatError
    unless ex.message == "unsupported exact typed column"
      raise "unqualified #{case_data.label} typed-open rejection: #{ex.message}"
    end
    puts "EXPECTED RED #{case_data.label}: typed reader rejects after stock controls: #{ex.message}"
    "rejected"
  end
end

W100_EXPECTED_HEAD = "498f5e141cfed4aac6d58dc2c865c24f5c06de8a"

head_output = IO::Memory.new
head_status = Process.run("git", ["rev-parse", "HEAD"], output: head_output)
raise "could not read predecessor Git HEAD" unless head_status.success?
raise "W100 RED probe must run at predecessor #{W100_EXPECTED_HEAD}, got #{head_output.to_s.strip}" unless head_output.to_s.strip == W100_EXPECTED_HEAD
source_status = Process.run("git", ["diff", "--quiet", "HEAD", "--", "src"])
raise "W100 RED probe requires unchanged tracked production source" unless source_status.success?

binary = ENV["CLICKHOUSE_BIN"]? || raise "set CLICKHOUSE_BIN to pinned ClickHouse 26.7.1.1315"
store = ENV["CLICKHOUSE_STORE"]? || raise "set CLICKHOUSE_STORE to a fresh temporary ClickHouse store directory"
unless store.starts_with?("/private/tmp/") || store.starts_with?("/tmp/")
  raise "refusing non-temporary CLICKHOUSE_STORE path: #{store}"
end
if Dir.exists?(store)
  raise "CLICKHOUSE_STORE must be empty before probe creation: #{store}" unless Dir.empty?(store)
else
  Dir.mkdir_p(store)
end

version_output = IO::Memory.new
version_status = Process.run(binary, ["local", "--version"], output: version_output)
raise "could not read ClickHouse local version" unless version_status.success?
unless version_output.to_s.strip == "ClickHouse local version #{W100_STOCK_VERSION} (official build)."
  raise "expected pinned ClickHouse #{W100_STOCK_VERSION}, got #{version_output.to_s.strip}"
end
puts "Stock oracle: #{version_output.to_s.strip}"

# Admit a known typed Tuple control before stock temporal profiles or REDs.
w100_assert_positive_control(binary, store)

cases = w100_cases
stock_parts = [] of {W100TemporalCase, String}
cases.each do |case_data|
  stock_parts << {case_data, w100_check_stock_case(binary, store, case_data)}
end

# Date32 has two distinct default domains: its SQL type default is -25567,
# while the stored Int32 column reports raw zero as the default value.
w100_assert_date32_default_profile(binary, store, "raw_zero", 0_i32, 5)
w100_assert_date32_default_profile(binary, store, "type_default", -25_567_i32, 0)
w100_check_date32_stats_profile(binary, store, "raw_zero", 0_i32, 5)
w100_check_date32_stats_profile(binary, store, "type_default", -25_567_i32, 0)
w100_check_all_zero_composite(binary, store, cases)

# No typed-reader attempt occurs until every independent stock profile passes.
results = [] of {String, String}
stock_parts.each do |(case_data, part)|
  results << {case_data.label, w100_expect_reader_rejection(part, case_data)}
end

rejected = results.count { |(_, result)| result == "rejected" }
puts "W100 predecessor typed-reader outcomes: #{results.inspect}"
if rejected == 24
  puts "EXPECTED W100 RED: all 24 stock-valid temporal Tuple declarations are rejected after independent controls"
  exit 1
end
raise "W100 probe did not establish the baseline 24/24 rejection (#{rejected}/24); inspect source state and outcomes"
