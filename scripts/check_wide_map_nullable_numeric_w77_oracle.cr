require "file_utils"
require "set"
require "../src/crystal_click"

W77_KEYS         = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64]
W77_MARK_ROWS    = [2_u64, 2_u64, 2_u64, 2_u64, 0_u64]
W77_MARK_STARTS  = [0, 2, 4, 6, 8]
W77_ALL_ROWS     = [0_i32, 1_i32, 2_i32, 3_i32, 4_i32, 5_i32, 6_i32, 7_i32]
W77_RANGE_ROWS   = [1_i32, 2_i32, 3_i32, 4_i32]
W77_NULL_STREAM  = "payload%2Evalues.null"
W77_VALUE_STREAM = "payload%2Evalues"

private def w77_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (#{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

private def w77_clickhouse_input(binary : String, store : String, query : String, input : IO) : String
  output = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], input: input, output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse RowBinary insert failed (#{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

private def w77_create_table(binary : String, store : String, name : String, type_name : String) : Nil
  w77_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.#{name} (`pk` UInt64, `payload` #{type_name})
  ENGINE = MergeTree ORDER BY pk
  SETTINGS index_granularity = 2, index_granularity_bytes = 10485760,
    enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0,
    min_bytes_for_wide_part = 0, ratio_of_defaults_for_sparse_serialization = 1.0,
    compress_marks = 0, min_compress_block_size = 0, max_compress_block_size = 4096,
    write_final_mark = 1, default_compression_codec = 'LZ4'
  SQL
  nil
end

private def w77_check_table(binary : String, store : String, table : String) : Nil
  result = w77_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "#{table}: CHECK TABLE failed: #{result.inspect}" unless result == "all_1_1_0\t1"
  nil
end

private def w77_u64(io : IO, value : UInt64) : Nil
  io.write_bytes(value, IO::ByteFormat::LittleEndian)
end

private def w77_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w77_key(io : IO, key : K) : Nil forall K
  {% if K == String %}
    w77_varuint(io, key.bytesize.to_u64)
    io.write(key.to_slice)
  {% elsif K == UInt64 %}
    w77_u64(io, key)
  {% else %}
    {% raise "unsupported W77 Map key type" %}
  {% end %}
end

private def w77_number(io : IO, value : T) : Nil forall T
  {% if T == Float32 %}
    io.write_bytes(value.unsafe_as(UInt32), IO::ByteFormat::LittleEndian)
  {% elsif T == Float64 %}
    io.write_bytes(value.unsafe_as(UInt64), IO::ByteFormat::LittleEndian)
  {% elsif T == UInt8 || T == UInt16 || T == UInt32 || T == UInt64 || T == Int8 || T == Int16 || T == Int32 || T == Int64 %}
    io.write_bytes(value, IO::ByteFormat::LittleEndian)
  {% else %}
    {% raise "unsupported W77 primitive numeric type" %}
  {% end %}
end

private def w77_nullable_number(io : IO, value : T?) : Nil forall T
  if value.nil?
    io.write_byte(1_u8)
  else
    io.write_byte(0_u8)
    w77_number(io, value.not_nil!)
  end
end

private def w77_rowbinary_map(io : IO, entries : Array(Tuple(K, T?))) : Nil forall K, T
  w77_varuint(io, entries.size.to_u64)
  entries.each do |key, value|
    w77_key(io, key)
    w77_nullable_number(io, value)
  end
end

private def w77_rowbinary(keys : Array(UInt64), rows : Array(Array(Tuple(K, T?))), indexes : Array(Int32)) : String forall K, T
  raise "W77 primary key and Map row counts differ" unless keys.size == rows.size
  io = IO::Memory.new
  indexes.each do |index|
    w77_u64(io, keys[index])
    w77_rowbinary_map(io, rows[index])
  end
  io.to_s
end

private def w77_assert_bytes(actual : String, expected : String, label : String) : Nil
  return if actual.to_slice == expected.to_slice
  common = Math.min(actual.bytesize, expected.bytesize)
  offset = 0
  while offset < common && actual.to_slice[offset] == expected.to_slice[offset]
    offset += 1
  end
  first = Math.max(0, offset - 8)
  last = Math.min(common, offset + 16)
  got = actual.to_slice[first, last - first].hexstring
  wanted = expected.to_slice[first, last - first].hexstring
  raise "#{label}: RowBinary differs at byte #{offset} (got #{actual.bytesize} bytes / #{got}; expected #{expected.bytesize} bytes / #{wanted})"
end

private def w77_raw_number_bytes(values : Array(T)) : Array(UInt8) forall T
  io = IO::Memory.new
  values.each { |value| w77_number(io, value) }
  io.to_slice.to_a
end

private def w77_expected_streams(rows : Array(Array(Tuple(K, T?)))) : Hash(String, Array(UInt8)) forall K, T
  sizes = IO::Memory.new
  keys = IO::Memory.new
  key_sizes = IO::Memory.new
  nulls = IO::Memory.new
  values = IO::Memory.new
  rows.each { |row| w77_u64(sizes, row.size.to_u64) }
  rows.each do |row|
    row.each do |key, value|
      {% if K == String %}
        keys.write(key.to_slice)
        w77_u64(key_sizes, key.bytesize.to_u64)
      {% else %}
        w77_u64(keys, key)
      {% end %}
      if value.nil?
        nulls.write_byte(1_u8)
        sizeof(T).times { values.write_byte(0_u8) }
      else
        nulls.write_byte(0_u8)
        w77_number(values, value.not_nil!)
      end
    end
  end
  streams = {
    "payload.size0"  => sizes.to_slice.to_a,
    W77_NULL_STREAM  => nulls.to_slice.to_a,
    W77_VALUE_STREAM => values.to_slice.to_a,
  }
  {% if K == String %}
    streams["payload%2Ekeys.size"] = key_sizes.to_slice.to_a
  {% end %}
  streams["payload%2Ekeys"] = keys.to_slice.to_a
  streams
end

private def w77_raw_stream(part : String, stream : String) : Array(UInt8)
  encoded_path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
  encoded = File.read(encoded_path).to_slice
  encoded.empty? ? [] of UInt8 : CrystalClick::CompressedBlock.decode_all(encoded).to_a
end

private def w77_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w77_marks(part : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64))
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  data = File.read(path).to_slice
  raise "#{part} #{stream}: malformed .mrk2" unless data.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(Tuple(UInt64, UInt64, UInt64)).new(data.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    {w77_read_u64(data, offset), w77_read_u64(data, offset + 8), w77_read_u64(data, offset + 16)}
  end
end

private def w77_expected_raw_offset(
  stream : String,
  rows : Array(Array(Tuple(K, T?))),
  start_row : Int32,
) : UInt64 forall K, T
  return start_row.to_u64 * 8_u64 if stream == "pk" || stream == "payload.size0"
  entries_before = 0_u64
  key_bytes_before = 0_u64
  start_row.times do |row_index|
    rows[row_index].each do |key, _value|
      entries_before += 1_u64
      {% if K == String %}
        key_bytes_before += key.bytesize.to_u64
      {% end %}
    end
  end
  case stream
  when "payload%2Ekeys.size"
    entries_before * 8_u64
  when "payload%2Ekeys"
    {% if K == String %}
      key_bytes_before
    {% else %}
      entries_before * 8_u64
    {% end %}
  when W77_NULL_STREAM
    entries_before
  when W77_VALUE_STREAM
    entries_before * sizeof(T).to_u64
  else
    raise "unexpected W77 stream #{stream}"
  end
end

private def w77_assert_stream(
  part : String,
  stream : String,
  raw : Array(UInt8),
  rows : Array(Array(Tuple(K, T?))),
  stock : Bool,
) : Nil forall K, T
  observed_raw = w77_raw_stream(part, stream)
  raise "#{part} #{stream}: raw bytes differ (#{observed_raw.size} != #{raw.size})" unless observed_raw == raw
  records = w77_marks(part, stream)
  raise "#{part} #{stream}: mark rows differ: #{records.map(&.[2])}" unless records.map(&.[2]) == W77_MARK_ROWS
  if stock
    expected = W77_MARK_STARTS.each_with_index.map do |start_row, index|
      {0_u64, w77_expected_raw_offset(stream, rows, start_row), W77_MARK_ROWS[index]}
    end.to_a
    raise "#{part} #{stream}: stock marks differ: #{records} != #{expected}" unless records == expected
  else
    records.each_cons(2) do |pair|
      left = pair[0]
      right = pair[1]
      raise "#{part} #{stream}: mark offset regresses" if right[0] < left[0] || (right[0] == left[0] && right[1] < left[1])
    end
    terminal = records.last
    encoded_size = File.size(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_u64
    valid_terminal = terminal[0] == 0_u64 && terminal[1] == raw.size.to_u64 ||
                     terminal[0] == encoded_size && terminal[1] == 0_u64
    raise "#{part} #{stream}: invalid terminal mark" unless valid_terminal
    if stream == "payload%2Ekeys.size" || stream == "payload%2Ekeys" || stream == W77_NULL_STREAM || stream == W77_VALUE_STREAM
      final_empty_mark = records[3]
      raise "#{part} #{stream}: final all-empty Map mark is not at nonzero EOF" unless encoded_size > 0_u64 && final_empty_mark[0] == encoded_size && final_empty_mark[1] == 0_u64
    end
  end
  nil
end

private def w77_assert_inventory(
  part : String,
  type_name : String,
  rows : Array(Array(Tuple(K, T?))),
  stock : Bool,
) : Nil forall K, T
  expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` #{type_name}\n"
  raise "#{part}: columns.txt differs" unless File.read(File.join(part, "columns.txt")) == expected_columns
  columns = "[]"
  expected_serialization = %({"columns":#{columns},"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
  observed_serialization = File.read(File.join(part, "serialization.json")).strip
  raise "#{part}: serialization.json differs: #{observed_serialization.inspect} != #{expected_serialization.inspect}" unless observed_serialization == expected_serialization

  stream_names = {% if K == String %}
                   ["payload.size0", "payload%2Ekeys.size", "payload%2Ekeys", W77_NULL_STREAM, W77_VALUE_STREAM]
                 {% else %}
                   ["payload.size0", "payload%2Ekeys", W77_NULL_STREAM, W77_VALUE_STREAM]
                 {% end %}
  expected_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" +
                        "#{stream_names.size} substreams for column `payload`:\n" + stream_names.map { |stream| "\t#{stream}\n" }.join
  raise "#{part}: columns_substreams.txt differs" unless File.read(File.join(part, "columns_substreams.txt")) == expected_substreams

  expected_streams = w77_expected_streams(rows)
  w77_assert_stream(part, "pk", w77_raw_number_bytes(W77_KEYS), rows, stock)
  stream_names.each do |stream|
    w77_assert_stream(part, stream, expected_streams[stream], rows, stock)
  end

  metadata_files = ["checksums.txt", "columns.txt", "columns_substreams.txt", "count.txt",
                    "default_compression_codec.txt", "metadata_version.txt", stock ? "primary.cidx" : "primary.idx",
                    "serialization.json"]
  stream_files = stream_names + ["pk"]
  expected_files = metadata_files + stream_files.flat_map do |stream|
    base = CrystalClick::StreamName.hash(stream)
    ["#{base}.bin", "#{base}.mrk2"]
  end
  actual_files = Dir.children(part).sort
  raise "#{part}: file inventory differs: #{actual_files.inspect} != #{expected_files.sort.inspect}" unless actual_files == expected_files.sort
  raise "#{part}: count.txt differs" unless File.read(File.join(part, "count.txt")) == W77_KEYS.size.to_s
  raise "#{part}: metadata_version.txt differs" unless File.read(File.join(part, "metadata_version.txt")) == "0"
  raise "#{part}: codec metadata differs" unless File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)"
  checksums = CrystalClick::PartChecksums.open(part)
  checksums.entries.each_key { |name| checksums.validate_selected_entries(part, name) }
  nil
end

private def w77_numeric_equal?(expected : T, actual : T) : Bool forall T
  {% if T == Float32 %}
    expected.unsafe_as(UInt32) == actual.unsafe_as(UInt32)
  {% elsif T == Float64 %}
    expected.unsafe_as(UInt64) == actual.unsafe_as(UInt64)
  {% else %}
    expected == actual
  {% end %}
end

private def w77_nullable_equal?(expected : T?, actual : T?) : Bool forall T
  return expected.nil? && actual.nil? if expected.nil? || actual.nil?
  w77_numeric_equal?(expected.not_nil!, actual.not_nil!)
end

private def w77_assert_rows_equal?(expected : Array(Array(Tuple(K, T?))), actual : Array(Array(Tuple(K, T?)))) : Bool forall K, T
  return false unless expected.size == actual.size
  expected.each_with_index do |row, row_index|
    return false unless row.size == actual[row_index].size
    row.each_with_index do |entry, entry_index|
      observed = actual[row_index][entry_index]
      return false unless entry[0] == observed[0] && w77_nullable_equal?(entry[1], observed[1])
    end
  end
  true
end

private def w77_assert_reader(part : String, rows : Array(Array(Tuple(K, T?))), type : T.class) : Nil forall K, T
  reader = CrystalClick::WidePart.open_typed(part, "payload")
  observed = {% if K == String %}
               reader.read_map_string_nullable_numeric_mark_range("payload", 0, reader.mark_count, type)
             {% else %}
               reader.read_map_uint64_nullable_numeric_mark_range("payload", 0, reader.mark_count, type)
             {% end %}
  middle = {% if K == String %}
             reader.read_map_string_nullable_numeric_mark_range("payload", 1, 1, type)
           {% else %}
             reader.read_map_uint64_nullable_numeric_mark_range("payload", 1, 1, type)
           {% end %}
  tail = {% if K == String %}
           reader.read_map_string_nullable_numeric_mark_range("payload", 2, 1, type)
         {% else %}
           reader.read_map_uint64_nullable_numeric_mark_range("payload", 2, 1, type)
         {% end %}
  final_empty = {% if K == String %}
                  reader.read_map_string_nullable_numeric_mark_range("payload", 3, 1, type)
                {% else %}
                  reader.read_map_uint64_nullable_numeric_mark_range("payload", 3, 1, type)
                {% end %}
  raise "#{part}: full Crystal Map read differs" unless w77_assert_rows_equal?(rows, observed)
  raise "#{part}: empty middle granule differs" unless w77_assert_rows_equal?(rows[2, 2], middle)
  raise "#{part}: later mark differs" unless w77_assert_rows_equal?(rows[4, 2], tail)
  raise "#{part}: final all-empty granule at nonzero EOF differs" unless w77_assert_rows_equal?(rows[6, 2], final_empty)
  nil
end

private def w77_stock_part(binary : String, store : String, root : String, table : String) : String
  source = w77_clickhouse(binary, store,
    "SELECT path FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").strip
  raise "#{table}: stock part missing" unless Dir.exists?(source)
  destination = File.join(root, "stock-#{table}")
  FileUtils.cp_r(source, destination)
  destination
end

private def w77_assert_columns(binary : String, store : String, table : String, type_name : String) : Nil
  actual = w77_clickhouse(binary, store,
    "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw")
  expected = "pk UInt64\npayload #{type_name}\n"
  raise "#{table}: exact system.columns mismatch: #{actual.inspect}" unless actual == expected
  create = w77_clickhouse(binary, store, "SHOW CREATE TABLE default.#{table} FORMAT TSVRaw").gsub(/\s+/, "")
  raise "#{table}: SHOW CREATE type mismatch" unless create.includes?(type_name.gsub(/\s+/, ""))
  nil
end

private def w77_assert_clickhouse_rows(
  binary : String,
  store : String,
  table : String,
  rows : Array(Array(Tuple(K, T?))),
) : Nil forall K, T
  full = w77_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  w77_assert_bytes(full, w77_rowbinary(W77_KEYS, rows, W77_ALL_ROWS), "#{table} full")
  selected = w77_clickhouse(binary, store,
    "SELECT pk, payload FROM default.#{table} WHERE pk >= 2 AND pk <= 5 ORDER BY pk FORMAT RowBinary")
  w77_assert_bytes(selected, w77_rowbinary(W77_KEYS, rows, W77_RANGE_ROWS), "#{table} selected rows")
  nil
end

private def w77_attach(binary : String, store : String, table : String, part : String) : Nil
  data_path = w77_clickhouse(binary, store,
    "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  raise "#{table}: ClickHouse data path missing" if data_path.empty? || data_path.includes?('\n')
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  w77_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  w77_check_table(binary, store, table)
  nil
end

private def w77_values(
  first_key : K,
  second_key : K,
  third_key : K,
  later_key : K,
  maximum : T,
  minimum : T,
  later : T,
) : Array(Array(Tuple(K, T?))) forall K, T
  {% if T == Float32 %}
    negative_zero = 0x80000000_u32.unsafe_as(Float32)
    positive_zero = 0_u32.unsafe_as(Float32)
    [
      [] of Tuple(K, T?),
      [{first_key, nil}, {first_key, negative_zero}, {first_key, positive_zero}, {first_key, maximum}] of Tuple(K, T?),
      [] of Tuple(K, T?),
      [] of Tuple(K, T?),
      [{second_key, minimum}, {third_key, nil}] of Tuple(K, T?),
      [{later_key, later}] of Tuple(K, T?),
      [] of Tuple(K, T?),
      [] of Tuple(K, T?),
    ] of Array(Tuple(K, T?))
  {% elsif T == Float64 %}
    negative_zero = 0x8000000000000000_u64.unsafe_as(Float64)
    positive_zero = 0_u64.unsafe_as(Float64)
    [
      [] of Tuple(K, T?),
      [{first_key, nil}, {first_key, negative_zero}, {first_key, positive_zero}, {first_key, maximum}] of Tuple(K, T?),
      [] of Tuple(K, T?),
      [] of Tuple(K, T?),
      [{second_key, minimum}, {third_key, nil}] of Tuple(K, T?),
      [{later_key, later}] of Tuple(K, T?),
      [] of Tuple(K, T?),
      [] of Tuple(K, T?),
    ] of Array(Tuple(K, T?))
  {% else %}
    [
      [] of Tuple(K, T?),
      [{first_key, nil}, {first_key, maximum}] of Tuple(K, T?),
      [] of Tuple(K, T?),
      [] of Tuple(K, T?),
      [{second_key, minimum}, {third_key, nil}] of Tuple(K, T?),
      [{later_key, later}] of Tuple(K, T?),
      [] of Tuple(K, T?),
      [] of Tuple(K, T?),
    ] of Array(Tuple(K, T?))
  {% end %}
end

private def w77_case(
  binary : String,
  store : String,
  root : String,
  label : String,
  value_type : String,
  first_key : K,
  second_key : K,
  third_key : K,
  later_key : K,
  maximum : T,
  minimum : T,
  later : T,
  type : T.class,
) : Nil forall K, T
  key_type = {% if K == String %}"String"{% else %}"UInt64"{% end %}
  type_name = "Map(#{key_type}, Nullable(#{value_type}))"
  rows = w77_values(first_key, second_key, third_key, later_key, maximum, minimum, later)
  indexes = (0...W77_KEYS.size).map(&.to_i32)

  stock_table = "w77_stock_#{label}"
  w77_create_table(binary, store, stock_table, type_name)
  input = IO::Memory.new
  input.write(w77_rowbinary(W77_KEYS, rows, indexes).to_slice)
  input.rewind
  w77_clickhouse_input(binary, store, "INSERT INTO default.#{stock_table} FORMAT RowBinary", input)
  count = w77_clickhouse(binary, store, "SELECT count() FROM default.#{stock_table} FORMAT TSVRaw").strip
  raise "#{stock_table}: inserted #{count} rows instead of #{W77_KEYS.size}" unless count == W77_KEYS.size.to_s
  w77_check_table(binary, store, stock_table)
  w77_assert_columns(binary, store, stock_table, type_name)
  w77_assert_clickhouse_rows(binary, store, stock_table, rows)
  stock_part = w77_stock_part(binary, store, root, stock_table)
  w77_assert_inventory(stock_part, type_name, rows, true)
  w77_assert_reader(stock_part, rows, T)
  puts "PASS stock→Crystal #{type_name}: exact null/value/key streams and marks; full, empty-middle, later-mark, empty-EOF reads"

  crystal_part = File.join(root, "crystal-#{label}")
  {% if K == String %}
    CrystalClick::WidePartWriter.write_uint64_map_string_nullable_numeric_pair(
      crystal_part, "pk", W77_KEYS.to_unsafe.to_slice(W77_KEYS.size), "payload",
      rows.to_unsafe.to_slice(rows.size), rows_per_mark: 2
    )
  {% else %}
    CrystalClick::WidePartWriter.write_uint64_map_uint64_nullable_numeric_pair(
      crystal_part, "pk", W77_KEYS.to_unsafe.to_slice(W77_KEYS.size), "payload",
      rows.to_unsafe.to_slice(rows.size), rows_per_mark: 2
    )
  {% end %}
  w77_assert_inventory(crystal_part, type_name, rows, false)
  w77_assert_reader(crystal_part, rows, T)
  crystal_table = "w77_crystal_#{label}"
  w77_create_table(binary, store, crystal_table, type_name)
  w77_attach(binary, store, crystal_table, crystal_part)
  w77_assert_columns(binary, store, crystal_table, type_name)
  w77_assert_clickhouse_rows(binary, store, crystal_table, rows)
  puts "PASS Crystal→stock #{type_name}: ATTACH/CHECK, exact schema, full and selected-row RowBinary with empty final mark"
end

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("CLICKHOUSE_STORE")
root = ENV.fetch("ORACLE_ROOT")

# The UInt64 nullable Map controls are exercised by W53; W77 adds the other 18
# combinations (nine primitive leaves times two key types).
w77_case(binary, store, root, "string_u8", "UInt8", "dup", "", "binary\u0000key", "tail", UInt8::MAX, UInt8::MIN, 17_u8, UInt8)
w77_case(binary, store, root, "uint64_u8", "UInt8", 0_u64, UInt64::MAX, 42_u64, 7_u64, UInt8::MAX, UInt8::MIN, 17_u8, UInt8)
w77_case(binary, store, root, "string_u16", "UInt16", "dup", "", "binary\u0000key", "tail", UInt16::MAX, UInt16::MIN, 17_u16, UInt16)
w77_case(binary, store, root, "uint64_u16", "UInt16", 0_u64, UInt64::MAX, 42_u64, 7_u64, UInt16::MAX, UInt16::MIN, 17_u16, UInt16)
w77_case(binary, store, root, "string_u32", "UInt32", "dup", "", "binary\u0000key", "tail", UInt32::MAX, UInt32::MIN, 17_u32, UInt32)
w77_case(binary, store, root, "uint64_u32", "UInt32", 0_u64, UInt64::MAX, 42_u64, 7_u64, UInt32::MAX, UInt32::MIN, 17_u32, UInt32)
w77_case(binary, store, root, "string_i8", "Int8", "dup", "", "binary\u0000key", "tail", Int8::MAX, Int8::MIN, -1_i8, Int8)
w77_case(binary, store, root, "uint64_i8", "Int8", 0_u64, UInt64::MAX, 42_u64, 7_u64, Int8::MAX, Int8::MIN, -1_i8, Int8)
w77_case(binary, store, root, "string_i16", "Int16", "dup", "", "binary\u0000key", "tail", Int16::MAX, Int16::MIN, -1_i16, Int16)
w77_case(binary, store, root, "uint64_i16", "Int16", 0_u64, UInt64::MAX, 42_u64, 7_u64, Int16::MAX, Int16::MIN, -1_i16, Int16)
w77_case(binary, store, root, "string_i32", "Int32", "dup", "", "binary\u0000key", "tail", Int32::MAX, Int32::MIN, -1_i32, Int32)
w77_case(binary, store, root, "uint64_i32", "Int32", 0_u64, UInt64::MAX, 42_u64, 7_u64, Int32::MAX, Int32::MIN, -1_i32, Int32)
w77_case(binary, store, root, "string_i64", "Int64", "dup", "", "binary\u0000key", "tail", Int64::MAX, Int64::MIN, -1_i64, Int64)
w77_case(binary, store, root, "uint64_i64", "Int64", 0_u64, UInt64::MAX, 42_u64, 7_u64, Int64::MAX, Int64::MIN, -1_i64, Int64)
w77_case(binary, store, root, "string_f32", "Float32", "dup", "", "binary\u0000key", "tail", 0x7f7fffff_u32.unsafe_as(Float32), 0xff7fffff_u32.unsafe_as(Float32), 0x7fc01234_u32.unsafe_as(Float32), Float32)
w77_case(binary, store, root, "uint64_f32", "Float32", 0_u64, UInt64::MAX, 42_u64, 7_u64, 0x7f7fffff_u32.unsafe_as(Float32), 0xff7fffff_u32.unsafe_as(Float32), 0x7fc01234_u32.unsafe_as(Float32), Float32)
w77_case(binary, store, root, "string_f64", "Float64", "dup", "", "binary\u0000key", "tail", 0x7fefffffffffffff_u64.unsafe_as(Float64), 0xffefffffffffffff_u64.unsafe_as(Float64), 0x7ff8000000001234_u64.unsafe_as(Float64), Float64)
w77_case(binary, store, root, "uint64_f64", "Float64", 0_u64, UInt64::MAX, 42_u64, 7_u64, 0x7fefffffffffffff_u64.unsafe_as(Float64), 0xffefffffffffffff_u64.unsafe_as(Float64), 0x7ff8000000001234_u64.unsafe_as(Float64), Float64)
