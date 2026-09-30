# Historical W97 pre-production discriminator: on the unchanged 3a50637
# implementation, typed-open rejected this stock-created Bool Tuple after
# stock, RowBinary, and legacy-pair controls passed. Re-running this probe on a
# later tree checks the now-admitted read; the historical RED is documented in
# docs/BOOL_TUPLE_FRONTIER.md and must not be reinterpreted as a current failure.
require "json"
require "../src/crystal_click"

W97_STOCK_VERSION = "26.7.1.1315"
W97_KEYS          = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
W97_NUMBERS       = [10_u64, 20_u64, 30_u64, 40_u64, 50_u64]
W97_PAIR_STRINGS  = ["alpha", "beta", "gamma", "delta", "epsilon"]
W97_BOOL_VALUES   = [false, true, false, true, true]
W97_BOOL_BYTES    = [0_u8, 1_u8, 0_u8, 1_u8, 1_u8]
W97_UINT8_VALUES  = [0_u8, 1_u8, 2_u8, 255_u8, 42_u8]
W97_STRINGS       = ["", "a", "bee", "tail", "z"]
W97_MARK_ROWS     = [2_u64, 2_u64, 1_u64, 0_u64]

def w97_attempt_clickhouse(binary : String, store : String, query : String, input : IO? = nil) : {Bool, String, String}
  output = IO::Memory.new
  error = IO::Memory.new
  status = if input
             Process.run(binary, ["local", "--path", store, "--query", query], input: input, output: output, error: error)
           else
             Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: error)
           end
  {status.success?, output.to_s, error.to_s}
end

def w97_run_clickhouse(binary : String, store : String, query : String) : String
  succeeded, output, error = w97_attempt_clickhouse(binary, store, query)
  raise "ClickHouse local query failed: #{error}\n#{query}" unless succeeded
  output
end

def w97_create_stock_part(binary : String, store : String, table : String, payload_type : String, values : String) : String
  settings = "index_granularity = 2, enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0, compress_marks = 0, compress_primary_key = 0, min_compress_block_size = 0, max_compress_block_size = 4096, ratio_of_defaults_for_sparse_serialization = 0.9375"
  w97_run_clickhouse(binary, store, "CREATE TABLE default.#{table} (pk UInt64, payload #{payload_type}) ENGINE = MergeTree ORDER BY pk SETTINGS #{settings}")
  w97_run_clickhouse(binary, store, "INSERT INTO default.#{table} VALUES #{values}")
  paths = w97_run_clickhouse(binary, store, "SELECT path FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TSVRaw").lines.map(&.strip).reject(&.empty?)
  raise "expected one active stock part for #{table}, got #{paths.inspect}" unless paths.size == 1
  paths.first
end

def w97_expected_substreams(payload_streams : Array(String)) : String
  lines = ["columns substreams version: 1", "2 columns:", "1 substreams for column `pk`:", "\tpk"]
  lines << "#{payload_streams.size} substreams for column `payload`:"
  payload_streams.each { |name| lines << "\t#{name}" }
  lines.join("\n") + "\n"
end

def w97_mark_rows(mark_bytes : Bytes, label : String) : Array(UInt64)
  mark_size = CrystalClick::WidePart::MARK_SIZE
  raise "#{label} mark file has a partial mark" unless mark_bytes.size % mark_size == 0
  Array.new(mark_bytes.size // mark_size) do |index|
    offset = index * mark_size + 16
    8.times.reduce(0_u64) do |value, byte|
      value | (mark_bytes[offset + byte].to_u64 << (byte * 8))
    end
  end
end

def w97_assert_stock_layout(path : String, payload_type : String, payload_streams : Array(String), label : String) : JSON::Any
  columns = File.read(File.join(path, "columns.txt")).lines.map(&.strip)
  expected_columns = ["columns format version: 1", "2 columns:", "`pk` UInt64", "`payload` #{payload_type}"]
  raise "#{label} stock columns differ: #{columns.inspect}" unless columns == expected_columns

  substreams = File.read(File.join(path, "columns_substreams.txt"))
  expected_substreams = w97_expected_substreams(payload_streams)
  raise "#{label} stock substreams differ:\n#{substreams}" unless substreams == expected_substreams

  stream_names = ["pk"] + payload_streams
  bases = stream_names.map { |name| CrystalClick::StreamName.hash(name) }
  expected_bins = bases.map { |base| "#{base}.bin" }.sort
  expected_marks = bases.map { |base| "#{base}.mrk2" }.sort
  children = Dir.children(path)
  bins = children.select(&.ends_with?(".bin")).sort
  marks = children.select(&.ends_with?(".mrk2")).sort
  raise "#{label} stock .bin inventory differs: #{bins.inspect}" unless bins == expected_bins
  raise "#{label} stock .mrk2 inventory differs: #{marks.inspect}" unless marks == expected_marks

  stream_names.each do |name|
    base = CrystalClick::StreamName.hash(name)
    rows = w97_mark_rows(File.read(File.join(path, "#{base}.mrk2")).to_slice, "#{label} #{name}")
    raise "#{label} #{name} mark rows differ: #{rows.inspect}" unless rows == W97_MARK_ROWS
  end

  info = JSON.parse(File.read(File.join(path, "serialization.json")))
  metadata = info.as_h
  raise "#{label} serialization version differs" unless metadata["version"]?.try(&.as_i) == 1
  raise "#{label} type-version propagation differs" unless metadata["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool) == true
  serializers = metadata["columns"]?.try(&.as_a) || raise "#{label} serializer metadata missing"
  names = serializers.map { |entry| entry.as_h["name"].as_s }
  raise "#{label} serializer record names differ: #{names.inspect}" unless names == ["payload", "pk"]
  serializers.each do |entry|
    row = entry.as_h
    raise "#{label} non-Default serializer: #{row.inspect}" unless row["kind"]?.try(&.as_s) == "Default"
    raise "#{label} serializer row count differs" unless row["num_rows"]?.try(&.as_i) == W97_KEYS.size
  end

  payload = serializers.find { |entry| entry.as_h["name"].as_s == "payload" }.not_nil!.as_h
  tuple_children = payload["subcolumns"]?.try(&.as_a) || raise "#{label} Tuple child serializer metadata missing"
  expected_child_count = payload_type == "Tuple(a UInt64, b String)" ? 2 : 3
  raise "#{label} Tuple child serializer count differs: #{tuple_children.size}" unless tuple_children.size == expected_child_count
  tuple_children.each do |entry|
    child = entry.as_h
    raise "#{label} Tuple child serializer is not Default" unless child["kind"]?.try(&.as_s) == "Default"
    raise "#{label} Tuple child row count differs" unless child["num_rows"]?.try(&.as_i) == W97_KEYS.size
  end
  info
end

def w97_append_unsigned_le(io : IO, value : UInt64, width : Int32) : Nil
  width.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
end

def w97_append_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

def w97_pair_rowbinary(keys : Array(UInt64), numbers : Array(UInt64), strings : Array(String)) : String
  output = IO::Memory.new
  keys.each_with_index do |key, index|
    w97_append_unsigned_le(output, key, 8)
    w97_append_unsigned_le(output, numbers[index], 8)
    value = strings[index]
    w97_append_varuint(output, value.bytesize.to_u64)
    output.write(value.to_slice)
  end
  output.to_s
end

def w97_bool_rowbinary : String
  output = IO::Memory.new
  W97_KEYS.each_with_index do |key, index|
    w97_append_unsigned_le(output, key, 8)
    output.write_byte(W97_BOOL_BYTES[index])
    output.write_byte(W97_UINT8_VALUES[index])
    value = W97_STRINGS[index]
    w97_append_varuint(output, value.bytesize.to_u64)
    output.write(value.to_slice)
  end
  output.to_s
end

def w97_check_table(binary : String, store : String, table : String, part : String) : Nil
  result = w97_run_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  expected = "#{File.basename(part.chomp("/"))}\t1"
  raise "#{table} CHECK TABLE differs: #{result.inspect}" unless result == expected
end

def w97_observe_noncanonical_bool(binary : String, store : String) : Nil
  table = "w97_noncanonical_bool_tuple"
  settings = "index_granularity = 2, enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0, compress_marks = 0, compress_primary_key = 0, min_compress_block_size = 0, max_compress_block_size = 4096, ratio_of_defaults_for_sparse_serialization = 0.9375"
  w97_run_clickhouse(binary, store, "CREATE TABLE default.#{table} (pk UInt64, payload Tuple(flag Bool, byte UInt8, text String)) ENGINE = MergeTree ORDER BY pk SETTINGS #{settings}")

  input = IO::Memory.new
  w97_append_unsigned_le(input, 1_u64, 8)
  input.write_byte(2_u8)
  input.write_byte(9_u8)
  w97_append_varuint(input, 1_u64)
  input << "x"
  succeeded, output, error = w97_attempt_clickhouse(binary, store, "INSERT INTO default.#{table} FORMAT RowBinary", IO::Memory.new(input.to_slice))
  unless succeeded
    puts "OBSERVED stock RowBinary Bool byte 0x02: rejected (#{(error + output).lines.first?.try(&.strip) || "no diagnostic"})"
    return nil
  end

  paths = w97_run_clickhouse(binary, store, "SELECT path FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TSVRaw").lines.map(&.strip).reject(&.empty?)
  unless paths.size == 1
    puts "OBSERVED stock RowBinary Bool byte 0x02: insert accepted, active part count=#{paths.size}"
    return nil
  end
  part = paths.first
  check_ok, check_output, check_error = w97_attempt_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated")
  query_ok, rowbinary, query_error = w97_attempt_clickhouse(binary, store, "SELECT payload.flag FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  logical_ok, logical, logical_error = w97_attempt_clickhouse(binary, store, "SELECT toString(payload.flag) FROM default.#{table} ORDER BY pk FORMAT TabSeparated")
  flag_path = File.join(part, "#{CrystalClick::StreamName.hash("payload%2Eflag")}.bin")
  physical = File.exists?(flag_path) ? CrystalClick::CompressedBlock.decode_all(File.read(flag_path).to_slice).to_slice : Bytes.empty
  puts "OBSERVED stock RowBinary Bool byte 0x02: insert accepted; CHECK=#{check_ok} #{check_output.strip} #{check_error.lines.first?.try(&.strip)}"
  puts "OBSERVED raw2 Bool part flag stream=#{physical.hexstring}; selected RowBinary=#{query_ok ? rowbinary.to_slice.hexstring : query_error.lines.first?.try(&.strip)}; logical=#{logical_ok ? logical.strip : logical_error.lines.first?.try(&.strip)}"
  nil
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
unless version_output.to_s.includes?(W97_STOCK_VERSION)
  raise "expected pinned ClickHouse #{W97_STOCK_VERSION}, got #{version_output.to_s.strip}"
end
puts "Stock oracle: #{version_output.to_s.strip}"

pair_values = W97_KEYS.each_with_index.map do |key, index|
  "(toUInt64('#{key}'), tuple(toUInt64('#{W97_NUMBERS[index]}'), '#{W97_PAIR_STRINGS[index]}'))"
end.join(", ")
pair_path = w97_create_stock_part(binary, store, "w97_u64_string_control", "Tuple(a UInt64, b String)", pair_values)
w97_assert_stock_layout(pair_path, "Tuple(a UInt64, b String)", ["payload%2Ea", "payload%2Eb.size", "payload%2Eb"], "UInt64/String positive control")
pair_reader = CrystalClick::WidePart.open_typed(pair_path, "payload")
pair_data = pair_reader.read_tuple_mark_range("payload", 0, pair_reader.mark_count)
raise "positive-control Tuple type differs" unless pair_data.type_name == "Tuple(a UInt64, b String)"
raise "positive-control mark rows differ: #{pair_reader.mark_row_counts.inspect}" unless pair_reader.mark_row_counts == [2_u64, 2_u64, 1_u64]
raise "positive-control UInt64 leaf differs" unless pair_data["a"].uint64_values == W97_NUMBERS
raise "positive-control String leaf differs" unless pair_data["b"].string_values == W97_PAIR_STRINGS
pair_bytes = w97_run_clickhouse(binary, store, "SELECT pk, payload.a, payload.b FROM default.w97_u64_string_control ORDER BY pk FORMAT RowBinary")
raise "positive-control stock RowBinary differs from independent expected bytes" unless pair_bytes == w97_pair_rowbinary(W97_KEYS, W97_NUMBERS, W97_PAIR_STRINGS)
w97_check_table(binary, store, "w97_u64_string_control", pair_path)
puts "PASS existing UInt64/String stock part + typed-open/read + independent RowBinary control"

bool_values = W97_KEYS.each_with_index.map do |key, index|
  bool = W97_BOOL_VALUES[index] ? "toBool(1)" : "toBool(0)"
  text = W97_STRINGS[index]
  "(toUInt64('#{key}'), tuple(#{bool}, toUInt8(#{W97_UINT8_VALUES[index]}), '#{text}'))"
end.join(", ")
bool_path = w97_create_stock_part(binary, store, "w97_bool_tuple_frontier", "Tuple(flag Bool, byte UInt8, text String)", bool_values)
w97_assert_stock_layout(bool_path, "Tuple(flag Bool, byte UInt8, text String)", ["payload%2Eflag", "payload%2Ebyte", "payload%2Etext.size", "payload%2Etext"], "Bool/UInt8/String frontier")
bool_rowbinary = w97_run_clickhouse(binary, store, "SELECT pk, payload.flag, payload.byte, payload.text FROM default.w97_bool_tuple_frontier ORDER BY pk FORMAT RowBinary")
raise "stock Bool Tuple RowBinary differs from independent explicit Bool 0/1 bytes" unless bool_rowbinary == w97_bool_rowbinary
w97_check_table(binary, store, "w97_bool_tuple_frontier", bool_path)
puts "PASS stock-persisted named Bool/UInt8/String Tuple schema, exact streams, marks, CHECK, and independently encoded RowBinary"

# This independent stock observation checks whether the pinned server accepts
# and persists a nominal Bool stream containing byte 2. Its result is printed,
# never assumed from the canonical 0/1 fixture or source-level wrappers.
w97_observe_noncanonical_bool(binary, store)

puts "HISTORICAL RED: the unchanged 3a50637 typed-open rejected this valid stock Bool Tuple; verifying post-admission read below."
bool_reader = CrystalClick::WidePart.open_typed(bool_path, "payload")
bool_data = bool_reader.read_tuple_mark_range("payload", 0, bool_reader.mark_count)
raise "Bool Tuple reader returned the wrong type identity" unless bool_data.type_name == "Tuple(flag Bool, byte UInt8, text String)"
raise "Bool Tuple reader returned the wrong row count" unless bool_data.row_count == W97_KEYS.size
W97_KEYS.each_index do |index|
  raise "Bool Tuple Bool value differs at row #{index}" unless bool_data.value_as("flag", index, Bool) == W97_BOOL_VALUES[index]
  raise "Bool Tuple UInt8 value differs at row #{index}" unless bool_data.value_as("byte", index, UInt8) == W97_UINT8_VALUES[index]
  raise "Bool Tuple String value differs at row #{index}" unless bool_data.value_as("text", index, String) == W97_STRINGS[index]
end
puts "PASS typed Bool Tuple read path is now admitted"
