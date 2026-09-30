# Historical W96 pre-production probe: at e42367a, the final Int8 read fails
# after the positive controls. After W96 it becomes a small positive path.
# Use check_numeric_tuple_oracle.sh for the final all-type regression gate.
require "json"
require "../src/crystal_click"

W96_STOCK_VERSION = "26.7.1.1315"
W96_KEYS          = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
W96_NUMBERS       = [10_u64, 20_u64, 30_u64, 40_u64, 50_u64]
W96_STRINGS       = ["alpha", "beta", "gamma", "delta", "epsilon"]
W96_FLOAT_KEYS    = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64]
W96_FLOAT32_BITS  = [0_u32, 0_u32, 0_u32, 0_u32, 0x8000_0000_u32, 0x3f80_0000_u32, 0x7f80_0000_u32, 0x7fc0_0000_u32]
W96_FLOAT64_BITS  = [0_u64, 0_u64, 0_u64, 0_u64, 0x8000_0000_0000_0000_u64, 0x3ff0_0000_0000_0000_u64, 0x7ff0_0000_0000_0000_u64, 0x7ff8_0000_0000_0000_u64]
W96_BFLOAT16_BITS = [0_u16, 0_u16, 0_u16, 0_u16, 0x8000_u16, 0x3f80_u16, 0x7f80_u16, 0x7fc0_u16]

def w96_run_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: error)
  unless status.success?
    raise "ClickHouse local query failed (#{status.exit_code}): #{error.to_s}\n#{query}"
  end
  output.to_s
end

def w96_create_stock_part(binary : String, store : String, table : String, payload_type : String, values : String) : String
  settings = "index_granularity = 2, enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0, compress_marks = 0, compress_primary_key = 0, min_compress_block_size = 0, max_compress_block_size = 4096, ratio_of_defaults_for_sparse_serialization = 0.9375"
  w96_run_clickhouse(binary, store, "CREATE TABLE default.#{table} (pk UInt64, payload #{payload_type}) ENGINE = MergeTree ORDER BY pk SETTINGS #{settings}")
  w96_run_clickhouse(binary, store, "INSERT INTO default.#{table} VALUES #{values}")
  paths = w96_run_clickhouse(binary, store, "SELECT path FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TSVRaw").lines.map(&.strip).reject(&.empty?)
  raise "expected one active part for #{table}, got #{paths.inspect}" unless paths.size == 1
  paths.first
end

def w96_expected_stream_metadata(payload_streams : Array(String)) : String
  lines = ["columns substreams version: 1", "2 columns:", "1 substreams for column `pk`:", "\tpk"]
  lines << "#{payload_streams.size} substreams for column `payload`:"
  payload_streams.each { |name| lines << "\t#{name}" }
  lines.join("\n") + "\n"
end

def w96_mark_rows(mark_bytes : Bytes, label : String) : Array(UInt64)
  mark_size = CrystalClick::WidePart::MARK_SIZE
  raise "#{label} mark file has a partial mark" unless mark_bytes.size % mark_size == 0
  Array.new(mark_bytes.size // mark_size) do |index|
    offset = index * mark_size + 16
    8.times.reduce(0_u64) do |value, byte|
      value | (mark_bytes[offset + byte].to_u64 << (byte * 8))
    end
  end
end

def w96_assert_stock_part(path : String, payload_type : String, payload_streams : Array(String), expected_rows : Array(UInt64), row_count : Int32, label : String) : JSON::Any
  column_lines = File.read(File.join(path, "columns.txt")).lines.map(&.strip)
  expected_columns = ["columns format version: 1", "2 columns:", "`pk` UInt64", "`payload` #{payload_type}"]
  raise "#{label} stock columns differ: #{column_lines.inspect}" unless column_lines == expected_columns

  actual_substreams = File.read(File.join(path, "columns_substreams.txt"))
  expected_substreams = w96_expected_stream_metadata(payload_streams)
  raise "#{label} stock substreams differ:\n#{actual_substreams}" unless actual_substreams == expected_substreams

  stream_names = ["pk"] + payload_streams
  expected_bases = stream_names.map { |name| CrystalClick::StreamName.hash(name) }
  expected_bins = expected_bases.map { |base| "#{base}.bin" }.sort
  expected_marks = expected_bases.map { |base| "#{base}.mrk2" }.sort
  children = Dir.children(path)
  actual_bins = children.select(&.ends_with?(".bin")).sort
  actual_marks = children.select(&.ends_with?(".mrk2")).sort
  raise "#{label} stock .bin inventory differs: #{actual_bins.inspect}" unless actual_bins == expected_bins
  raise "#{label} stock .mrk2 inventory differs: #{actual_marks.inspect}" unless actual_marks == expected_marks

  stream_names.each do |logical_name|
    base = CrystalClick::StreamName.hash(logical_name)
    rows = w96_mark_rows(File.read(File.join(path, "#{base}.mrk2")).to_slice, "#{label} #{logical_name}")
    raise "#{label} #{logical_name} mark rows differ: #{rows.inspect}" unless rows == expected_rows
  end

  info = JSON.parse(File.read(File.join(path, "serialization.json")))
  metadata = info.as_h
  version = metadata["version"]?.try(&.as_i) || raise "#{label} serialization.json version missing"
  raise "#{label} pinned stock serialization version differs: #{version}" unless version == 1
  propagated = metadata["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool)
  raise "#{label} nested type-version propagation differs: #{propagated.inspect}" unless propagated == true
  versions = metadata["types_serialization_versions"]?.try(&.as_h) || raise "#{label} type-version map missing"
  puts "OBSERVED #{label} type_versions=#{versions.to_json}"

  serializers = metadata["columns"]?.try(&.as_a) || raise "#{label} serializer metadata missing"
  expected_serializer_names = ["payload", "pk"]
  names = serializers.map { |entry| entry.as_h["name"].as_s }
  raise "#{label} serializer names differ: #{names.inspect}" unless names == expected_serializer_names
  serializers.each do |entry|
    row = entry.as_h
    raise "#{label} non-Default root serializer: #{row.inspect}" unless row["kind"]?.try(&.as_s) == "Default"
    observed_rows = row["num_rows"]?.try(&.as_i) || raise "#{label} root serializer row count missing"
    raise "#{label} serializer row count is #{observed_rows}, expected #{row_count}" unless observed_rows == row_count
  end
  info
end

def w96_payload_serializer(info : JSON::Any, label : String) : JSON::Any
  serializers = info.as_h["columns"].as_a
  serializers.find { |entry| entry.as_h["name"].as_s == "payload" } || raise "#{label} payload serializer missing"
end

def w96_tuple_children(info : JSON::Any, expected_count : Int32, row_count : Int32, label : String) : Array(JSON::Any)
  payload = w96_payload_serializer(info, label).as_h
  raise "#{label} payload serializer is not Default" unless payload["kind"]?.try(&.as_s) == "Default"
  children = payload["subcolumns"]?.try(&.as_a) || raise "#{label} payload child serializers missing"
  raise "#{label} Tuple child count differs: #{children.size}, expected #{expected_count}" unless children.size == expected_count
  children.each do |entry|
    row = entry.as_h
    raise "#{label} child serializer is not Default: #{row.inspect}" unless row["kind"]?.try(&.as_s) == "Default"
    observed_rows = row["num_rows"]?.try(&.as_i) || raise "#{label} Tuple child row count missing"
    raise "#{label} Tuple child row count differs: #{observed_rows}" unless observed_rows == row_count
  end
  children
end

def w96_write_unsigned_le(io : IO, value : UInt64, width : Int32) : Nil
  width.times do |index|
    io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8)
  end
end

def w96_write_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

def w96_pair_rowbinary(keys : Array(UInt64), numbers : Array(UInt64), strings : Array(String)) : String
  output = IO::Memory.new
  keys.each_with_index do |key, index|
    w96_write_unsigned_le(output, key, 8)
    w96_write_unsigned_le(output, numbers[index], 8)
    value = strings[index]
    w96_write_varuint(output, value.bytesize.to_u64)
    output.write(value.to_slice)
  end
  output.to_s
end

def w96_assert_pair_positive_control(binary : String, store : String, path : String, info : JSON::Any) : Nil
  key_reader = CrystalClick::WidePart.open_typed(path, "pk")
  tuple_reader = CrystalClick::WidePart.open_typed(path, "payload")
  raise "positive-control part type differs" unless tuple_reader.column_type == "Tuple(a UInt64, b String)"
  raise "positive-control mark schedule differs" unless key_reader.mark_row_counts == [2_u64, 2_u64, 1_u64]
  raise "positive-control Tuple mark schedule differs" unless tuple_reader.mark_row_counts == [2_u64, 2_u64, 1_u64]

  keys = key_reader.read_uint64_mark_range("pk", 0, key_reader.mark_count)
  data = tuple_reader.read_tuple_mark_range("payload", 0, tuple_reader.mark_count)
  raise "positive-control Tuple row count differs" unless data.row_count == W96_KEYS.size
  raise "positive-control UInt64 keys differ" unless keys == W96_KEYS
  raise "positive-control UInt64 values differ" unless data["a"].uint64_values == W96_NUMBERS
  raise "positive-control String values differ" unless data["b"].string_values == W96_STRINGS

  query = "SELECT pk, payload.a, payload.b FROM default.w96_u64_string_control ORDER BY pk FORMAT RowBinary"
  stock_bytes = w96_run_clickhouse(binary, store, query)
  expected = w96_pair_rowbinary(W96_KEYS, W96_NUMBERS, W96_STRINGS)
  raise "positive-control RowBinary differs from expected bytes" unless stock_bytes == expected
  crystal_bytes = w96_pair_rowbinary(keys, data["a"].uint64_values, data["b"].string_values)
  raise "positive-control RowBinary differs from Crystal values" unless crystal_bytes == expected

  integrity = w96_run_clickhouse(binary, store, "CHECK TABLE default.w96_u64_string_control FORMAT TabSeparated").strip
  part_name = File.basename(path.chomp("/"))
  raise "positive-control CHECK TABLE failed: #{integrity.inspect}" unless integrity == "#{part_name}\t1"
  puts "PASS existing UInt64/String typed-open + compositional mark-range read + RowBinary control"
end

def w96_float_values_clause : String
  rows = [] of String
  W96_FLOAT32_BITS.each_with_index do |f32, index|
    f64 = W96_FLOAT64_BITS[index]
    f32_expr = "reinterpretAsFloat32(toUInt32(#{f32}))"
    f64_expr = "reinterpretAsFloat64(toUInt64('#{f64}'))"
    bf_expr = "toBFloat16(#{f32_expr})"
    rows << "(toUInt64(#{index + 1}), tuple(#{f32_expr}, #{f64_expr}, #{bf_expr}))"
  end
  rows.join(", ")
end

def w96_expected_float_rowbinary : String
  output = IO::Memory.new
  W96_FLOAT_KEYS.each_with_index do |key, index|
    w96_write_unsigned_le(output, key, 8)
    w96_write_unsigned_le(output, W96_FLOAT32_BITS[index].to_u64, 4)
    w96_write_unsigned_le(output, W96_FLOAT64_BITS[index], 8)
    w96_write_unsigned_le(output, W96_BFLOAT16_BITS[index].to_u64, 2)
  end
  output.to_s
end

def w96_observe_float_defaults(binary : String, store : String, path : String) : Nil
  info = w96_assert_stock_part(path, "Tuple(f Float32, d Float64, bf BFloat16)", ["payload%2Ef", "payload%2Ed", "payload%2Ebf"], [2_u64, 2_u64, 2_u64, 2_u64, 0_u64], 8, "Float32/Float64/BFloat16 observation")
  children = w96_tuple_children(info, 3, W96_FLOAT_KEYS.size, "float observation")
  child_defaults = children.map do |entry|
    row = entry.as_h
    rows = row["num_rows"]?.try(&.as_i) || raise "float child row count missing"
    defaults = row["num_defaults"]?.try(&.as_i) || raise "float child default count missing"
    raise "float child row count differs: #{rows}" unless rows == W96_FLOAT_KEYS.size
    raise "float child default count outside bounds: #{defaults}" unless 0 <= defaults <= rows
    defaults
  end
  payload = w96_payload_serializer(info, "float observation").as_h
  payload_defaults = payload["num_defaults"]?.try(&.as_i) || raise "float payload default count missing"
  raise "float payload row count differs" unless payload["num_rows"]?.try(&.as_i) == W96_FLOAT_KEYS.size
  puts "OBSERVED pinned stock float Default num_defaults: payload=#{payload_defaults}, children f/d/bf=#{child_defaults.inspect} (not asserted against fresh-source policy)"

  query = "SELECT pk, payload.f, payload.d, payload.bf FROM default.w96_float_default_observation ORDER BY pk FORMAT RowBinary"
  stock_bytes = w96_run_clickhouse(binary, store, query)
  expected = w96_expected_float_rowbinary
  unless stock_bytes == expected
    raise "Float32/Float64/BFloat16 RowBinary differs from requested raw IEEE/BFloat16 patterns (got #{stock_bytes.bytesize} bytes, expected #{expected.bytesize})"
  end
  puts "PASS stock RowBinary exact Float32/Float64/BFloat16 bits (+0, -0, finite, infinity, quiet NaN)"
end

def w96_int8_values_clause : String
  ["-128", "-1", "1", "127", "42"].each_with_index.map do |value, index|
    "(toUInt64(#{index + 1}), tuple(toInt8('#{value}')))"
  end.join(", ")
end

binary = ENV["CLICKHOUSE_BIN"]? || raise "set CLICKHOUSE_BIN to the pinned ClickHouse 26.7.1.1315 executable"
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
unless version_output.to_s.includes?(W96_STOCK_VERSION)
  raise "expected pinned ClickHouse #{W96_STOCK_VERSION}, got #{version_output.to_s.strip}"
end
puts "Stock oracle: #{version_output.to_s.strip}"

pair_values = W96_KEYS.each_with_index.map do |key, index|
  "(toUInt64('#{key}'), tuple(toUInt64('#{W96_NUMBERS[index]}'), '#{W96_STRINGS[index]}'))"
end.join(", ")
pair_path = w96_create_stock_part(binary, store, "w96_u64_string_control", "Tuple(a UInt64, b String)", pair_values)
pair_info = w96_assert_stock_part(pair_path, "Tuple(a UInt64, b String)", ["payload%2Ea", "payload%2Eb.size", "payload%2Eb"], [2_u64, 2_u64, 1_u64, 0_u64], 5, "UInt64/String positive control")
w96_tuple_children(pair_info, 2, 5, "UInt64/String positive control")
w96_assert_pair_positive_control(binary, store, pair_path, pair_info)

float_path = w96_create_stock_part(binary, store, "w96_float_default_observation", "Tuple(f Float32, d Float64, bf BFloat16)", w96_float_values_clause)
w96_observe_float_defaults(binary, store, float_path)

int8_path = w96_create_stock_part(binary, store, "w96_int8_tuple_frontier", "Tuple(value Int8)", w96_int8_values_clause)
w96_int8_info = w96_assert_stock_part(int8_path, "Tuple(value Int8)", ["payload%2Evalue"], [2_u64, 2_u64, 1_u64, 0_u64], 5, "Int8 frontier")
w96_tuple_children(w96_int8_info, 1, 5, "Int8 frontier")
puts "OBSERVED stock-persisted Tuple(value Int8): columns/substreams, Default serializers, five rows and mark rows [2, 2, 1]"
puts "NEXT: current typed-open/read is expected to reject this real part; the exception is intentionally uncaught so this pre-production RED exits nonzero."

# Do not catch UnsupportedFormatError here: a current rejection is the behavioral
# RED. Once the reader admits Int8, this same call becomes the positive path.
int8_reader = CrystalClick::WidePart.open_typed(int8_path, "payload")
int8_data = int8_reader.read_tuple_mark_range("payload", 0, int8_reader.mark_count)
raise "Int8 reader returned the wrong type identity" unless int8_data.type_name == "Tuple(value Int8)"
raise "Int8 reader returned the wrong row count" unless int8_data.row_count == 5
puts "PASS typed Int8 Tuple read path is now admitted"
