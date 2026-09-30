# Historical W99 stock-first discriminator for the unchanged 85b9b28
# implementation. Run only with the pinned stock binary and a fresh temporary
# store. An exit 1 at the very end is the expected three-family reader RED;
# any earlier error is a fixture, metadata, or oracle failure instead.
require "json"
require "../src/crystal_click"

W99_STOCK_VERSION = "26.7.1.1315"
W99_KEYS          = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
W99_MARK_ROWS     = [2_u64, 2_u64, 1_u64, 0_u64]
W99_CONTROL_NUMS  = [10_u64, 20_u64, 30_u64, 40_u64, 50_u64]
W99_CONTROL_TEXT  = ["alpha", "beta", "gamma", "delta", "epsilon"]
W99_BOOL_VALUES   = [false, true, false, true, true]
W99_BOOL_BYTES    = [0_u8, 1_u8, 0_u8, 1_u8, 1_u8]

struct W99IdentifierCase
  getter label : String
  getter type_name : String
  getter stream_name : String
  getter width : Int32
  getter row_bytes : Array(Array(UInt8))

  def initialize(@label : String, @type_name : String, @stream_name : String, @width : Int32, @row_bytes : Array(Array(UInt8)))
  end

  def tuple_type : String
    "Tuple(value #{type_name})"
  end

  def mixed_table : String
    "w99_#{label}_mixed"
  end

  def all_default_table : String
    "w99_#{label}_all_default"
  end

  def zero_rows : Array(Array(UInt8))
    Array.new(W99_KEYS.size) { Array(UInt8).new(width, 0_u8) }
  end
end

# Independent fixtures: UUID halves are specified high-half LE then low-half
# LE; IPv4 is the network-order integer encoded LE; IPv6 is high then low
# network-order bytes. These intentionally distinguish both width and endian.
def w99_uint_le(value : UInt64, width : Int32) : Array(UInt8)
  Array(UInt8).new(width) do |index|
    ((value >> (index * 8)) & 0xff_u64).to_u8
  end
end

def w99_uint_be(value : UInt64, width : Int32) : Array(UInt8)
  Array(UInt8).new(width) do |index|
    shift = (width - index - 1) * 8
    ((value >> shift) & 0xff_u64).to_u8
  end
end

def w99_uuid_bytes(high : UInt64, low : UInt64) : Array(UInt8)
  w99_uint_le(high, 8) + w99_uint_le(low, 8)
end

def w99_ipv4_bytes(network_order : UInt32) : Array(UInt8)
  w99_uint_le(network_order.to_u64, 4)
end

def w99_ipv6_bytes(high : UInt64, low : UInt64) : Array(UInt8)
  w99_uint_be(high, 8) + w99_uint_be(low, 8)
end

def w99_identifier_cases : Array(W99IdentifierCase)
  [
    W99IdentifierCase.new(
      "uuid",
      "UUID",
      "payload%2Evalue",
      16,
      [
        w99_uuid_bytes(0_u64, 0_u64),
        w99_uuid_bytes(0x0011223344556677_u64, 0x8899aabbccddeeff_u64),
        w99_uuid_bytes(UInt64::MAX, UInt64::MAX),
        w99_uuid_bytes(0x8000000000000000_u64, 1_u64),
        w99_uuid_bytes(0x0123456789abcdef_u64, 0xfedcba9876543210_u64),
      ] of Array(UInt8)
    ),
    W99IdentifierCase.new(
      "ipv4",
      "IPv4",
      "payload%2Evalue",
      4,
      [
        w99_ipv4_bytes(0_u32),
        w99_ipv4_bytes(0x01020304_u32),
        w99_ipv4_bytes(UInt32::MAX),
        w99_ipv4_bytes(0x80000001_u32),
        w99_ipv4_bytes(0x7f000001_u32),
      ] of Array(UInt8)
    ),
    W99IdentifierCase.new(
      "ipv6",
      "IPv6",
      "payload%2Evalue",
      16,
      [
        w99_ipv6_bytes(0_u64, 0_u64),
        w99_ipv6_bytes(0x0123456789abcdef_u64, 0xfedcba9876543210_u64),
        w99_ipv6_bytes(UInt64::MAX, UInt64::MAX),
        w99_ipv6_bytes(0x8000000000000000_u64, 1_u64),
        w99_ipv6_bytes(0x20010db800000000_u64, 1_u64),
      ] of Array(UInt8)
    ),
  ]
end

def w99_attempt_clickhouse(binary : String, store : String, query : String, input : IO? = nil) : {Bool, String, String}
  output = IO::Memory.new
  error = IO::Memory.new
  status = if input
             Process.run(binary, ["local", "--path", store, "--query", query], input: input, output: output, error: error)
           else
             Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: error)
           end
  {status.success?, output.to_s, error.to_s}
end

def w99_run_clickhouse(binary : String, store : String, query : String) : String
  succeeded, output, error = w99_attempt_clickhouse(binary, store, query)
  raise "ClickHouse local query failed: #{error}\n#{query}" unless succeeded
  output
end

def w99_append_unsigned_le(io : IO, value : UInt64, width : Int32) : Nil
  width.times do |index|
    io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8)
  end
end

def w99_append_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

def w99_append_row_bytes(io : IO, row : Array(UInt8)) : Nil
  row.each { |byte| io.write_byte(byte) }
end

def w99_tuple_rowbinary(keys : Array(UInt64), rows : Array(Array(UInt8)), indexes : Array(Int32)) : String
  output = IO::Memory.new
  indexes.each do |index|
    w99_append_unsigned_le(output, keys[index], 8)
    w99_append_row_bytes(output, rows[index])
  end
  output.to_s
end

def w99_control_rowbinary(indexes : Array(Int32)) : String
  output = IO::Memory.new
  indexes.each do |index|
    w99_append_unsigned_le(output, W99_KEYS[index], 8)
    w99_append_unsigned_le(output, W99_CONTROL_NUMS[index], 8)
    value = W99_CONTROL_TEXT[index]
    w99_append_varuint(output, value.bytesize.to_u64)
    output.write(value.to_slice)
  end
  output.to_s
end

def w99_bool_control_rowbinary(indexes : Array(Int32)) : String
  output = IO::Memory.new
  indexes.each do |index|
    w99_append_unsigned_le(output, W99_KEYS[index], 8)
    output.write_byte(W99_BOOL_BYTES[index])
  end
  output.to_s
end

def w99_create_table(binary : String, store : String, table : String, payload_type : String, ratio : String = "0.9375") : Nil
  settings = "index_granularity = 2, enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0, compress_marks = 0, compress_primary_key = 0, min_compress_block_size = 0, max_compress_block_size = 4096, ratio_of_defaults_for_sparse_serialization = #{ratio}"
  w99_run_clickhouse(
    binary,
    store,
    "CREATE TABLE default.#{table} (pk UInt64, payload #{payload_type}) ENGINE = MergeTree ORDER BY pk SETTINGS #{settings}"
  )
end

def w99_insert_rowbinary(binary : String, store : String, table : String, bytes : String) : Nil
  input = IO::Memory.new(bytes.to_slice)
  succeeded, output, error = w99_attempt_clickhouse(binary, store, "INSERT INTO default.#{table} FORMAT RowBinary", input)
  raise "stock RowBinary insert failed for #{table}: #{error}#{output}" unless succeeded
end

def w99_part_path(binary : String, store : String, table : String, expected_type : String = "Wide") : String
  rows = w99_run_clickhouse(
    binary,
    store,
    "SELECT path, part_type, rows FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TSVRaw"
  ).lines.map(&.strip).reject(&.empty?)
  raise "expected exactly one active part for #{table}, got #{rows.inspect}" unless rows.size == 1
  columns = rows[0].split('\t')
  raise "malformed system.parts row for #{table}: #{rows[0].inspect}" unless columns.size == 3
  raise "#{table} part is not #{expected_type}: #{columns[1]}" unless columns[1] == expected_type
  raise "#{table} part row count differs: #{columns[2]}" unless columns[2].to_i == W99_KEYS.size
  columns[0]
end

def w99_check_table(binary : String, store : String, table : String, part : String) : Nil
  output = w99_run_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  expected = "#{File.basename(part.chomp("/"))}\t1"
  raise "#{table} CHECK TABLE failed: #{output.inspect}" unless output == expected
end

def w99_read_u64_le(bytes : Bytes, offset : Int32) : UInt64
  8.times.reduce(0_u64) do |value, index|
    value | (bytes[offset + index].to_u64 << (index * 8))
  end
end

def w99_mark_rows(part : String, logical_name : String) : Array(UInt64)
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.mrk2")
  bytes = File.read(path).to_slice
  mark_size = CrystalClick::WidePart::MARK_SIZE
  raise "#{logical_name} mark file has a partial record" unless bytes.size % mark_size == 0
  Array(UInt64).new(bytes.size // mark_size) do |index|
    w99_read_u64_le(bytes, index * mark_size + 16)
  end
end

def w99_expected_substreams(tuple_child : String) : String
  [
    "columns substreams version: 1",
    "2 columns:",
    "1 substreams for column `pk`:",
    "\tpk",
    "1 substreams for column `payload`:",
    "\t#{tuple_child}",
  ].join("\n") + "\n"
end

def w99_count_defaults(row : Hash(String, JSON::Any), label : String) : Nil
  rows = row["num_rows"]?.try(&.as_i) || raise "#{label} serializer row count is missing"
  defaults = row["num_defaults"]?.try(&.as_i) || raise "#{label} serializer default count is missing"
  raise "#{label} serializer counts are invalid: #{defaults}/#{rows}" unless rows == W99_KEYS.size && defaults >= 0 && defaults <= rows
end

def w99_validate_observed_default_counts(row : Hash(String, JSON::Any), label : String) : Nil
  kind = row["kind"]?.try(&.as_s) || raise "#{label} serializer kind is missing"
  unless kind == "Default" || kind == "AlwaysDefault"
    raise "#{label} unexpected serializer kind: #{kind}"
  end
  if row.has_key?("num_rows") || row.has_key?("num_defaults")
    w99_count_defaults(row, label)
  elsif kind != "AlwaysDefault"
    raise "#{label} #{kind} serializer omitted observed default counts"
  end
end

def w99_validate_observed_default_tree(row : Hash(String, JSON::Any), label : String) : Nil
  w99_validate_observed_default_counts(row, label)
  (row["subcolumns"]?.try(&.as_a) || [] of JSON::Any).each_with_index do |child, index|
    w99_validate_observed_default_tree(child.as_h, "#{label} child #{index}")
  end
end

def w99_assert_mixed_layout(part : String, payload_type : String, tuple_child : String, label : String) : JSON::Any
  columns = File.read(File.join(part, "columns.txt")).lines.map(&.strip)
  expected_columns = ["columns format version: 1", "2 columns:", "`pk` UInt64", "`payload` #{payload_type}"]
  raise "#{label} stock columns differ: #{columns.inspect}" unless columns == expected_columns

  actual_substreams = File.read(File.join(part, "columns_substreams.txt"))
  expected_substreams = w99_expected_substreams(tuple_child)
  raise "#{label} substreams differ:\n#{actual_substreams}" unless actual_substreams == expected_substreams

  streams = ["pk", tuple_child]
  expected_bins = streams.map { |name| "#{CrystalClick::StreamName.hash(name)}.bin" }.sort
  expected_marks = streams.map { |name| "#{CrystalClick::StreamName.hash(name)}.mrk2" }.sort
  entries = Dir.children(part)
  actual_bins = entries.select(&.ends_with?(".bin")).sort
  actual_marks = entries.select(&.ends_with?(".mrk2")).sort
  raise "#{label} physical stream inventory differs: #{actual_bins.inspect}" unless actual_bins == expected_bins
  raise "#{label} mark stream inventory differs: #{actual_marks.inspect}" unless actual_marks == expected_marks

  streams.each do |name|
    observed_rows = w99_mark_rows(part, name)
    raise "#{label} #{name} mark rows differ: #{observed_rows.inspect}" unless observed_rows == W99_MARK_ROWS
  end

  info = JSON.parse(File.read(File.join(part, "serialization.json")))
  metadata = info.as_h
  raise "#{label} serialization version differs" unless metadata["version"]?.try(&.as_i) == 1
  raise "#{label} nested type-version propagation differs" unless metadata["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool) == true
  versions = metadata["types_serialization_versions"]?.try(&.as_h) || raise "#{label} type-version map missing"
  unless versions.size == 1 && versions["string"]?.try(&.as_i) == 1
    raise "#{label} stock type-version map differs from the admitted Tuple profile: #{versions.to_json}"
  end

  serializers = metadata["columns"]?.try(&.as_a) || raise "#{label} serializer records missing"
  names = serializers.map { |entry| entry.as_h["name"].as_s }
  raise "#{label} serializer names differ: #{names.inspect}" unless names == ["payload", "pk"]
  serializers.each do |entry|
    row = entry.as_h
    raise "#{label} root serializer is not Default: #{row.to_json}" unless row["kind"]?.try(&.as_s) == "Default"
    w99_count_defaults(row, label)
  end
  payload = serializers.find { |entry| entry.as_h["name"].as_s == "payload" }.not_nil!.as_h
  children = payload["subcolumns"]?.try(&.as_a) || raise "#{label} Tuple child metadata missing"
  raise "#{label} Tuple child count differs: #{children.size}" unless children.size == 1
  child = children[0].as_h
  raise "#{label} Tuple child serializer is not Default: #{child.to_json}" unless child["kind"]?.try(&.as_s) == "Default"
  w99_count_defaults(child, "#{label} Tuple child")

  puts "OBSERVED #{label} serialization.json=#{info.to_json}"
  info
end

def w99_assert_control_layout(part : String, label : String) : Nil
  columns = File.read(File.join(part, "columns.txt")).lines.map(&.strip)
  expected_columns = ["columns format version: 1", "2 columns:", "`pk` UInt64", "`payload` Tuple(a UInt64, b String)"]
  raise "#{label} stock columns differ: #{columns.inspect}" unless columns == expected_columns

  expected_substreams = [
    "columns substreams version: 1",
    "2 columns:",
    "1 substreams for column `pk`:",
    "\tpk",
    "3 substreams for column `payload`:",
    "\tpayload%2Ea",
    "\tpayload%2Eb.size",
    "\tpayload%2Eb",
  ].join("\n") + "\n"
  actual_substreams = File.read(File.join(part, "columns_substreams.txt"))
  raise "#{label} substreams differ:\n#{actual_substreams}" unless actual_substreams == expected_substreams
  ["pk", "payload%2Ea", "payload%2Eb.size", "payload%2Eb"].each do |stream|
    observed = w99_mark_rows(part, stream)
    raise "#{label} #{stream} marks differ: #{observed.inspect}" unless observed == W99_MARK_ROWS
  end

  info = JSON.parse(File.read(File.join(part, "serialization.json")))
  metadata = info.as_h
  raise "#{label} serialization version differs" unless metadata["version"]?.try(&.as_i) == 1
  raise "#{label} nested type-version propagation differs" unless metadata["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool) == true
  versions = metadata["types_serialization_versions"]?.try(&.as_h) || raise "#{label} type-version map missing"
  unless versions.size == 1 && versions["string"]?.try(&.as_i) == 1
    raise "#{label} control type-version map differs: #{versions.to_json}"
  end
  serializers = metadata["columns"]?.try(&.as_a) || raise "#{label} serializer records missing"
  raise "#{label} control serializer names differ" unless serializers.map { |entry| entry.as_h["name"].as_s } == ["payload", "pk"]
  payload = serializers[0].as_h
  children = payload["subcolumns"]?.try(&.as_a) || raise "#{label} control child metadata missing"
  raise "#{label} control child count differs" unless children.size == 2
  puts "OBSERVED #{label} serialization.json=#{info.to_json}"
end

def w99_assert_key_marks(part : String, label : String) : Nil
  base = CrystalClick::StreamName.hash("pk")
  raise "#{label} key data stream missing" unless File.exists?(File.join(part, "#{base}.bin"))
  rows = w99_mark_rows(part, "pk")
  raise "#{label} key mark rows differ: #{rows.inspect}" unless rows == W99_MARK_ROWS
end

def w99_assert_mixed_physical_payload(part : String, tuple_child : String, rows : Array(Array(UInt8)), label : String) : Nil
  encoded = [] of UInt8
  rows.each { |row| row.each { |byte| encoded << byte } }
  path = File.join(part, "#{CrystalClick::StreamName.hash(tuple_child)}.bin")
  actual = CrystalClick::CompressedBlock.decode_all(File.read(path).to_slice)
  expected = encoded.to_unsafe.to_slice(encoded.size)
  raise "#{label} decompressed payload bytes differ: expected #{encoded.size}, got #{actual.size}" unless actual == expected
end

def w99_assert_default_observation(binary : String, store : String, part : String, table : String, tuple_type : String, width : Int32, label : String) : Nil
  columns = File.read(File.join(part, "columns.txt"))
  expected_columns = ["columns format version: 1", "2 columns:", "`pk` UInt64", "`payload` #{tuple_type}"]
  raise "#{label} all-default columns differ" unless columns.lines.map(&.strip) == expected_columns
  w99_assert_key_marks(part, label)
  w99_check_table(binary, store, table, part)
  zero_rows = Array.new(W99_KEYS.size) { Array(UInt8).new(width, 0_u8) }
  expected = w99_tuple_rowbinary(W99_KEYS, zero_rows, [0_i32, 1_i32, 2_i32, 3_i32, 4_i32])
  actual = w99_run_clickhouse(binary, store, "SELECT pk, payload.value FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  raise "#{label} all-default RowBinary differs from explicit zero bytes" unless actual == expected
  substreams = File.read(File.join(part, "columns_substreams.txt"))
  metadata = JSON.parse(File.read(File.join(part, "serialization.json")))
  metadata_hash = metadata.as_h
  raise "#{label} all-default serialization version differs" unless metadata_hash["version"]?.try(&.as_i) == 1
  raise "#{label} all-default propagation flag differs" unless metadata_hash["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool) == true
  serializers = metadata_hash["columns"]?.try(&.as_a) || raise "#{label} all-default serializer records missing"
  names = serializers.map { |entry| entry.as_h["name"]?.try(&.as_s) || raise "#{label} all-default serializer name missing" }
  unless names.uniq.size == names.size && names.all? { |name| name == "payload" || name == "pk" }
    raise "#{label} unexpected all-default serializer names: #{names.inspect}"
  end
  serializers.each do |entry|
    row = entry.as_h
    w99_validate_observed_default_tree(row, "#{label} all-default #{row["name"]?.try(&.as_s) || "unnamed"}")
  end
  puts "OBSERVED #{label} all-default columns_substreams.txt=#{substreams.inspect}"
  puts "OBSERVED #{label} all-default physical bin/mrk2 inventory: bins=#{Dir.children(part).select(&.ends_with?(".bin")).sort.inspect} marks=#{Dir.children(part).select(&.ends_with?(".mrk2")).sort.inspect}"
  puts "OBSERVED #{label} all-default serialization.json=#{metadata.to_json}"
end

def w99_check_mixed_stock(binary : String, store : String, case_data : W99IdentifierCase) : String
  table = case_data.mixed_table
  tuple_type = case_data.tuple_type
  w99_create_table(binary, store, table, tuple_type)
  inserted = w99_tuple_rowbinary(W99_KEYS, case_data.row_bytes, [0_i32, 1_i32, 2_i32, 3_i32, 4_i32])
  w99_insert_rowbinary(binary, store, table, inserted)

  part = w99_part_path(binary, store, table)
  w99_assert_mixed_layout(part, tuple_type, case_data.stream_name, "#{case_data.label} mixed")
  w99_assert_mixed_physical_payload(part, case_data.stream_name, case_data.row_bytes, "#{case_data.label} mixed")
  w99_check_table(binary, store, table, part)

  full_indexes = [0_i32, 1_i32, 2_i32, 3_i32, 4_i32]
  full_expected = w99_tuple_rowbinary(W99_KEYS, case_data.row_bytes, full_indexes)
  full_actual = w99_run_clickhouse(binary, store, "SELECT pk, payload.value FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  raise "#{case_data.label} full RowBinary differs from independent bytes" unless full_actual == full_expected
  range_indexes = [1_i32, 2_i32, 3_i32]
  range_expected = w99_tuple_rowbinary(W99_KEYS, case_data.row_bytes, range_indexes)
  range_actual = w99_run_clickhouse(binary, store, "SELECT pk, payload.value FROM default.#{table} WHERE pk >= 2 AND pk < 5 ORDER BY pk FORMAT RowBinary")
  raise "#{case_data.label} selected RowBinary differs from independent bytes" unless range_actual == range_expected
  puts "PASS stock #{case_data.label} mixed schema/substreams/marks, physical bytes, CHECK, full and selected RowBinary"

  part
end

def w99_expect_reader_rejection(part : String, case_data : W99IdentifierCase) : String
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

def w99_bool_control_layout(part : String) : JSON::Any
  columns = File.read(File.join(part, "columns.txt")).lines.map(&.strip)
  expected_columns = ["columns format version: 1", "2 columns:", "`pk` UInt64", "`payload` Tuple(flag Bool)"]
  raise "Bool positive control stock columns differ: #{columns.inspect}" unless columns == expected_columns

  expected_substreams = [
    "columns substreams version: 1",
    "2 columns:",
    "1 substreams for column `pk`:",
    "\tpk",
    "1 substreams for column `payload`:",
    "\tpayload%2Eflag",
  ].join("\n") + "\n"
  actual_substreams = File.read(File.join(part, "columns_substreams.txt"))
  raise "Bool positive control stock substreams differ:\n#{actual_substreams}" unless actual_substreams == expected_substreams
  ["pk", "payload%2Eflag"].each do |stream|
    rows = w99_mark_rows(part, stream)
    raise "Bool positive control #{stream} marks differ: #{rows.inspect}" unless rows == W99_MARK_ROWS
  end

  info = JSON.parse(File.read(File.join(part, "serialization.json")))
  metadata = info.as_h
  raise "Bool positive control serialization version differs" unless metadata["version"]?.try(&.as_i) == 1
  raise "Bool positive control nested propagation differs" unless metadata["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool) == true
  puts "OBSERVED Bool positive control serialization.json=#{info.to_json}"
  info
end

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
unless version_output.to_s.strip == "ClickHouse local version #{W99_STOCK_VERSION} (official build)."
  raise "expected pinned ClickHouse #{W99_STOCK_VERSION}, got #{version_output.to_s.strip}"
end
puts "Stock oracle: #{version_output.to_s.strip}"

# Existing admitted Tuple control comes first so a wrong binary/profile or a
# broken positive path cannot be mistaken for the intended missing-leaf RED.
control_table = "w99_u64_string_control"
w99_create_table(binary, store, control_table, "Tuple(a UInt64, b String)")
control_bytes = w99_control_rowbinary([0_i32, 1_i32, 2_i32, 3_i32, 4_i32])
w99_insert_rowbinary(binary, store, control_table, control_bytes)
control_part = w99_part_path(binary, store, control_table)
w99_assert_control_layout(control_part, "UInt64/String control")
w99_check_table(binary, store, control_table, control_part)
control_reader = CrystalClick::WidePart.open_typed(control_part, "payload")
control_data = control_reader.read_tuple_mark_range("payload", 0, control_reader.mark_count)
raise "positive control Tuple type differs" unless control_data.type_name == "Tuple(a UInt64, b String)"
raise "positive control UInt64 data differs" unless control_data["a"].uint64_values == W99_CONTROL_NUMS
raise "positive control String data differs" unless control_data["b"].string_values == W99_CONTROL_TEXT
raise "positive control full RowBinary differs" unless w99_run_clickhouse(binary, store, "SELECT pk, payload.a, payload.b FROM default.#{control_table} ORDER BY pk FORMAT RowBinary") == control_bytes
puts "PASS existing UInt64/String typed Tuple control + independent RowBinary + stock CHECK"

bool_table = "w99_bool_control"
w99_create_table(binary, store, bool_table, "Tuple(flag Bool)")
bool_rows = W99_BOOL_BYTES.map { |byte| [byte] }
bool_input = w99_tuple_rowbinary(W99_KEYS, bool_rows, [0_i32, 1_i32, 2_i32, 3_i32, 4_i32])
w99_insert_rowbinary(binary, store, bool_table, bool_input)
bool_part = w99_part_path(binary, store, bool_table)
w99_bool_control_layout(bool_part)
w99_assert_mixed_physical_payload(bool_part, "payload%2Eflag", bool_rows, "Bool positive control")
w99_check_table(binary, store, bool_table, bool_part)
bool_reader = CrystalClick::WidePart.open_typed(bool_part, "payload")
bool_data = bool_reader.read_tuple_mark_range("payload", 0, bool_reader.mark_count)
raise "Bool positive control type differs" unless bool_data.type_name == "Tuple(flag Bool)"
raise "Bool positive control row count differs" unless bool_data.row_count == W99_KEYS.size
W99_KEYS.each_index do |index|
  raise "Bool positive control semantic value differs at row #{index}" unless bool_data.value_as("flag", index, Bool) == W99_BOOL_VALUES[index]
end
bool_full = w99_run_clickhouse(binary, store, "SELECT pk, payload.flag FROM default.#{bool_table} ORDER BY pk FORMAT RowBinary")
raise "Bool positive control full RowBinary differs" unless bool_full == w99_bool_control_rowbinary([0_i32, 1_i32, 2_i32, 3_i32, 4_i32])
bool_selected = w99_run_clickhouse(binary, store, "SELECT pk, payload.flag FROM default.#{bool_table} WHERE pk >= 2 AND pk < 5 ORDER BY pk FORMAT RowBinary")
raise "Bool positive control selected RowBinary differs" unless bool_selected == w99_bool_control_rowbinary([1_i32, 2_i32, 3_i32])
puts "PASS existing Bool typed Tuple control with independent zero/nonzero bytes, physical stream, full/selected RowBinary, and stock CHECK"

cases = w99_identifier_cases
stock_parts = [] of {W99IdentifierCase, String}
cases.each do |case_data|
  part = w99_check_mixed_stock(binary, store, case_data)
  stock_parts << {case_data, part}

  default_table = case_data.all_default_table
  w99_create_table(binary, store, default_table, case_data.tuple_type, "1.0")
  default_rows = case_data.zero_rows
  default_input = w99_tuple_rowbinary(W99_KEYS, default_rows, [0_i32, 1_i32, 2_i32, 3_i32, 4_i32])
  w99_insert_rowbinary(binary, store, default_table, default_input)
  default_part = w99_part_path(binary, store, default_table)
  w99_assert_default_observation(binary, store, default_part, default_table, case_data.tuple_type, case_data.width, case_data.label)
end

results = [] of {String, String}
stock_parts.each do |(case_data, part)|
  results << {case_data.label, w99_expect_reader_rejection(part, case_data)}
end

rejected = results.count { |(_, result)| result == "rejected" }
puts "W99 baseline typed-reader outcomes: #{results.inspect}"
if rejected == 3
  puts "EXPECTED W99 RED: all 3 stock-valid identifier Tuple families are rejected after independent controls"
  exit 1
end
raise "W99 probe did not establish the baseline 3/3 rejection (#{rejected}/3); inspect source state and outcomes"
