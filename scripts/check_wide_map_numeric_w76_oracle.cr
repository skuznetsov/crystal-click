require "file_utils"
require "../src/crystal_click"

W76_KEYS      = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]
W76_MARK_ROWS = [2_u64, 2_u64, 2_u64, 0_u64]

private def w76_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (#{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

private def w76_create_table(binary : String, store : String, name : String, map_type : String) : Nil
  w76_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.#{name} (`pk` UInt64, `payload` #{map_type})
  ENGINE = MergeTree ORDER BY pk
  SETTINGS index_granularity = 2, index_granularity_bytes = 10485760,
    enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0,
    min_bytes_for_wide_part = 0, compress_marks = 0,
    min_compress_block_size = 0, max_compress_block_size = 4096,
    write_final_mark = 1, default_compression_codec = 'LZ4'
  SQL
  nil
end

private def w76_sql_key(key : String) : String
  "'#{key.gsub("'", "''")}'"
end

private def w76_sql_key(key : UInt64) : String
  "toUInt64(#{key})"
end

private def w76_sql_map(row : Array(Tuple(K, T)), value_type : String) : String forall K, T
  args = row.flat_map { |key, value| [w76_sql_key(key), "CAST('#{value}', '#{value_type}')"] }
  "map(#{args.join(", ")})"
end

private def w76_insert_rows(binary : String, store : String, name : String, rows : Array(Array(Tuple(K, T))), value_type : String) : Nil forall K, T
  values = rows.each_with_index.map do |row, index|
    "(#{W76_KEYS[index]}, #{w76_sql_map(row, value_type)})"
  end
  w76_clickhouse(binary, store, "INSERT INTO default.#{name} VALUES #{values.join(", ")}")
  nil
end

private def w76_u64(io : IO, value : UInt64) : Nil
  io.write_bytes(value, IO::ByteFormat::LittleEndian)
end

private def w76_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w76_key(io : IO, key : String) : Nil
  w76_varuint(io, key.bytesize.to_u64)
  io.write(key.to_slice)
end

private def w76_key(io : IO, key : UInt64) : Nil
  w76_u64(io, key)
end

private def w76_number(io : IO, value : T) : Nil forall T
  {% if T == Float32 %}
    io.write_bytes(value.unsafe_as(UInt32), IO::ByteFormat::LittleEndian)
  {% elsif T == Float64 %}
    io.write_bytes(value.unsafe_as(UInt64), IO::ByteFormat::LittleEndian)
  {% else %}
    io.write_bytes(value, IO::ByteFormat::LittleEndian)
  {% end %}
end

private def w76_rowbinary(rows : Array(Array(Tuple(K, T))), indices : Array(Int32)) : String forall K, T
  io = IO::Memory.new
  indices.each do |index|
    w76_u64(io, W76_KEYS[index])
    entries = rows[index]
    w76_varuint(io, entries.size.to_u64)
    entries.each do |key, value|
      w76_key(io, key)
      w76_number(io, value)
    end
  end
  io.to_s
end

private def w76_assert_rows(binary : String, store : String, name : String, rows : Array(Array(Tuple(K, T)))) : Nil forall K, T
  expected_full = w76_rowbinary(rows, [0, 1, 2, 3, 4, 5])
  full = w76_clickhouse(binary, store, "SELECT pk, payload FROM default.#{name} ORDER BY pk FORMAT RowBinary")
  raise "#{name}: full RowBinary differs" unless full.to_slice == expected_full.to_slice
  expected_keyed = w76_rowbinary(rows, [1, 2, 3, 4])
  keyed = w76_clickhouse(binary, store,
    "SELECT pk, payload FROM default.#{name} WHERE pk >= 2 AND pk <= 5 ORDER BY pk FORMAT RowBinary")
  raise "#{name}: keyed RowBinary differs" unless keyed.to_slice == expected_keyed.to_slice
  nil
end

private def w76_check_table(binary : String, store : String, name : String) : Nil
  result = w76_clickhouse(binary, store, "CHECK TABLE default.#{name} FORMAT TabSeparated").strip
  raise "#{name}: CHECK TABLE failed: #{result.inspect}" unless result == "all_1_1_0\t1"
  nil
end

private def w76_stock_part(binary : String, store : String, name : String) : String
  part = w76_clickhouse(binary, store,
    "SELECT path FROM system.parts WHERE database='default' AND table='#{name}' AND active FORMAT TSVRaw").strip
  raise "#{name}: stock part missing" unless Dir.exists?(part)
  part
end

private def w76_raw_stream(part : String, stream : String) : Array(UInt8)
  encoded = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
  encoded.empty? ? [] of UInt8 : CrystalClick::CompressedBlock.decode_all(encoded).to_a
end

private def w76_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w76_marks(part : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64))
  data = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
  raise "#{stream}: malformed .mrk2" unless data.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(Tuple(UInt64, UInt64, UInt64)).new(data.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    {w76_read_u64(data, offset), w76_read_u64(data, offset + 8), w76_read_u64(data, offset + 16)}
  end
end

private def w76_bytes(values : Array(T)) : Array(UInt8) forall T
  io = IO::Memory.new
  values.each { |value| w76_number(io, value) }
  io.to_slice.to_a
end

private def w76_key_streams(column : String, rows : Array(Array(Tuple(String, T)))) : Hash(String, Array(UInt8)) forall T
  keys = rows.flat_map { |row| row.map(&.[0]) }
  sizes = IO::Memory.new
  keys.each { |key| w76_u64(sizes, key.bytesize.to_u64) }
  {
    "#{column}%2Ekeys.size" => sizes.to_slice.to_a,
    "#{column}%2Ekeys"      => keys.flat_map(&.to_slice.to_a),
  }
end

private def w76_key_streams(column : String, rows : Array(Array(Tuple(UInt64, T)))) : Hash(String, Array(UInt8)) forall T
  io = IO::Memory.new
  rows.each { |row| row.each { |key, _value| w76_u64(io, key) } }
  {"#{column}%2Ekeys" => io.to_slice.to_a}
end

private def w76_expected_streams(rows : Array(Array(Tuple(K, T)))) : Hash(String, Array(UInt8)) forall K, T
  io = IO::Memory.new
  rows.each { |row| w76_u64(io, row.size.to_u64) }
  values = rows.flat_map { |row| row.map(&.[1]) }
  streams = {
    "payload.size0"    => io.to_slice.to_a,
    "payload%2Evalues" => w76_bytes(values),
  }
  w76_key_streams("payload", rows).each { |name, raw| streams[name] = raw }
  streams
end

private def w76_expected_mark_offsets(stream : String, width : Int32, string_keys : Bool) : Array(UInt64)
  case stream
  when "pk", "payload.size0"
    [0_u64, 16_u64, 32_u64, 48_u64]
  when "payload%2Ekeys.size"
    raise "unexpected String key-size stream" unless string_keys
    [0_u64, 16_u64, 16_u64, 32_u64]
  when "payload%2Ekeys"
    string_keys ? [0_u64, 6_u64, 6_u64, 11_u64] : [0_u64, 16_u64, 16_u64, 32_u64]
  when "payload%2Evalues"
    step = 2_u64 * width.to_u64
    [0_u64, step, step, 2_u64 * step]
  else
    raise "unexpected W76 stream #{stream}"
  end
end

private def w76_assert_stream(part : String, stream : String, raw : Array(UInt8), offsets : Array(UInt64), stock : Bool) : Nil
  observed_raw = w76_raw_stream(part, stream)
  raise "#{part} #{stream}: raw bytes differ" unless observed_raw == raw
  records = w76_marks(part, stream)
  raise "#{part} #{stream}: mark rows differ: #{records.map(&.[2])}" unless records.map(&.[2]) == W76_MARK_ROWS
  if stock
    expected = W76_MARK_ROWS.each_with_index.map { |rows, index| {0_u64, offsets[index], rows} }.to_a
    raise "#{part} #{stream}: stock mark bytes differ: #{records} != #{expected}" unless records == expected
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
  end
  nil
end

private def w76_assert_inventory(part : String, type_name : String, rows : Array(Array(Tuple(K, T))), stock : Bool) : Nil forall K, T
  expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` #{type_name}\n"
  raise "#{part}: columns.txt differs" unless File.read(File.join(part, "columns.txt")) == expected_columns
  columns = stock ? %([{"kind":"Default","name":"pk","num_defaults":0,"num_rows":6}]) : "[]"
  expected_serialization = %({"columns":#{columns},"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
  observed_serialization = File.read(File.join(part, "serialization.json")).strip
  raise "#{part}: serialization.json differs: #{observed_serialization.inspect} != #{expected_serialization.inspect}" unless observed_serialization == expected_serialization

  raw_streams = w76_expected_streams(rows)
  string_keys = K == String
  stream_names = string_keys ? ["payload.size0", "payload%2Ekeys.size", "payload%2Ekeys", "payload%2Evalues"] : ["payload.size0", "payload%2Ekeys", "payload%2Evalues"]
  expected_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" +
                        "#{stream_names.size} substreams for column `payload`:\n" + stream_names.map { |stream| "\t#{stream}\n" }.join
  raise "#{part}: columns_substreams.txt differs" unless File.read(File.join(part, "columns_substreams.txt")) == expected_substreams

  key_bytes = w76_bytes(W76_KEYS)
  w76_assert_stream(part, "pk", key_bytes, w76_expected_mark_offsets("pk", sizeof(T), string_keys), stock)
  stream_names.each do |stream|
    w76_assert_stream(part, stream, raw_streams[stream], w76_expected_mark_offsets(stream, sizeof(T), string_keys), stock)
  end
  checksums = CrystalClick::PartChecksums.open(part)
  checksums.entries.each_key { |name| checksums.validate_selected_entries(part, name) }
  nil
end

private def w76_assert_reader(part : String, rows : Array(Array(Tuple(K, T))), type : T.class) : Nil forall K, T
  reader = CrystalClick::WidePart.open_typed(part, "payload")
  observed = {% if K == String %}
               reader.read_map_string_numeric_mark_range("payload", 0, reader.mark_count, type)
             {% else %}
               reader.read_map_uint64_numeric_mark_range("payload", 0, reader.mark_count, type)
             {% end %}
  middle = {% if K == String %}
             reader.read_map_string_numeric_mark_range("payload", 1, 1, type)
           {% else %}
             reader.read_map_uint64_numeric_mark_range("payload", 1, 1, type)
           {% end %}
  tail = {% if K == String %}
           reader.read_map_string_numeric_mark_range("payload", 2, 1, type)
         {% else %}
           reader.read_map_uint64_numeric_mark_range("payload", 2, 1, type)
         {% end %}
  raise "#{part}: Crystal full Map read differs" unless observed == rows
  raise "#{part}: Crystal empty middle mark differs" unless middle == rows[2, 2]
  raise "#{part}: Crystal later mark differs" unless tail == rows[4, 2]
  nil
end

private def w76_attach(binary : String, store : String, table : String, part : String) : Nil
  data_path = w76_clickhouse(binary, store,
    "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  raise "#{table}: data path missing" if data_path.empty? || data_path.includes?('\n')
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  w76_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  w76_check_table(binary, store, table)
  nil
end

private def w76_case(
  binary : String,
  store : String,
  root : String,
  label : String,
  type_name : String,
  value_type : String,
  first_key : K,
  second_key : K,
  third_key : K,
  first : T,
  second : T,
  third : T,
  fourth : T,
  writer : Bool,
) : Nil forall K, T
  rows = [
    [] of Tuple(K, T),
    [{first_key, first}, {first_key, second}] of Tuple(K, T),
    [] of Tuple(K, T),
    [] of Tuple(K, T),
    [{second_key, third}] of Tuple(K, T),
    [{third_key, fourth}] of Tuple(K, T),
  ] of Array(Tuple(K, T))
  stock_table = "w76_stock_#{label}"
  w76_create_table(binary, store, stock_table, type_name)
  w76_insert_rows(binary, store, stock_table, rows, value_type)
  w76_check_table(binary, store, stock_table)
  w76_assert_rows(binary, store, stock_table, rows)
  part = w76_stock_part(binary, store, stock_table)
  w76_assert_inventory(part, type_name, rows, true)
  w76_assert_reader(part, rows, T)
  puts "PASS stock->Crystal #{type_name}: exact streams/marks, full/selected rows"

  return unless writer
  destination = File.join(root, "crystal-#{label}")
  {% if K == String %}
    CrystalClick::WidePartWriter.write_uint64_map_string_numeric_pair(
      destination, "pk", W76_KEYS.to_unsafe.to_slice(W76_KEYS.size), "payload",
      rows.to_unsafe.to_slice(rows.size), rows_per_mark: 2
    )
  {% else %}
    CrystalClick::WidePartWriter.write_uint64_map_uint64_numeric_pair(
      destination, "pk", W76_KEYS.to_unsafe.to_slice(W76_KEYS.size), "payload",
      rows.to_unsafe.to_slice(rows.size), rows_per_mark: 2
    )
  {% end %}
  w76_assert_inventory(destination, type_name, rows, false)
  w76_assert_reader(destination, rows, T)
  crystal_table = "w76_crystal_#{label}"
  w76_create_table(binary, store, crystal_table, type_name)
  w76_attach(binary, store, crystal_table, destination)
  w76_assert_rows(binary, store, crystal_table, rows)
  puts "PASS Crystal->stock #{type_name}: ATTACH/CHECK, full/keyed RowBinary"
end

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("CLICKHOUSE_STORE")
root = ENV.fetch("ORACLE_ROOT")

w76_case(binary, store, root, "s_u8", "Map(String, UInt8)", "UInt8", "dup", "x", "tail", 0_u8, UInt8::MAX, 17_u8, 44_u8, false)
w76_case(binary, store, root, "u_u8", "Map(UInt64, UInt8)", "UInt8", 0_u64, 9_u64, 42_u64, 0_u8, UInt8::MAX, 17_u8, 44_u8, true)
w76_case(binary, store, root, "s_u16", "Map(String, UInt16)", "UInt16", "dup", "x", "tail", 0_u16, UInt16::MAX, 17_u16, 44_u16, false)
w76_case(binary, store, root, "u_u16", "Map(UInt64, UInt16)", "UInt16", 0_u64, 9_u64, 42_u64, 0_u16, UInt16::MAX, 17_u16, 44_u16, false)
w76_case(binary, store, root, "s_u32", "Map(String, UInt32)", "UInt32", "dup", "x", "tail", 0_u32, UInt32::MAX, 17_u32, 44_u32, false)
w76_case(binary, store, root, "u_u32", "Map(UInt64, UInt32)", "UInt32", 0_u64, 9_u64, 42_u64, 0_u32, UInt32::MAX, 17_u32, 44_u32, false)
w76_case(binary, store, root, "s_u64", "Map(String, UInt64)", "UInt64", "dup", "x", "tail", 0_u64, UInt64::MAX, 17_u64, 44_u64, false)
w76_case(binary, store, root, "u_u64", "Map(UInt64, UInt64)", "UInt64", 0_u64, 9_u64, 42_u64, 0_u64, UInt64::MAX, 17_u64, 44_u64, false)
w76_case(binary, store, root, "s_i8", "Map(String, Int8)", "Int8", "dup", "x", "tail", Int8::MAX, Int8::MIN, -1_i8, 5_i8, true)
w76_case(binary, store, root, "u_i8", "Map(UInt64, Int8)", "Int8", 0_u64, 9_u64, 42_u64, Int8::MAX, Int8::MIN, -1_i8, 5_i8, false)
w76_case(binary, store, root, "s_i16", "Map(String, Int16)", "Int16", "dup", "x", "tail", Int16::MAX, Int16::MIN, -1_i16, 5_i16, false)
w76_case(binary, store, root, "u_i16", "Map(UInt64, Int16)", "Int16", 0_u64, 9_u64, 42_u64, Int16::MAX, Int16::MIN, -1_i16, 5_i16, false)
w76_case(binary, store, root, "s_i32", "Map(String, Int32)", "Int32", "dup", "x", "tail", Int32::MAX, Int32::MIN, -1_i32, 5_i32, false)
w76_case(binary, store, root, "u_i32", "Map(UInt64, Int32)", "Int32", 0_u64, 9_u64, 42_u64, Int32::MAX, Int32::MIN, -1_i32, 5_i32, false)
w76_case(binary, store, root, "s_i64", "Map(String, Int64)", "Int64", "dup", "x", "tail", Int64::MAX, Int64::MIN, -1_i64, 5_i64, false)
w76_case(binary, store, root, "u_i64", "Map(UInt64, Int64)", "Int64", 0_u64, 9_u64, 42_u64, Int64::MAX, Int64::MIN, -1_i64, 5_i64, true)
w76_case(binary, store, root, "s_f32", "Map(String, Float32)", "Float32", "dup", "x", "tail", 1.5_f32, -2.25_f32, 4.5_f32, 7.5_f32, true)
w76_case(binary, store, root, "u_f32", "Map(UInt64, Float32)", "Float32", 0_u64, 9_u64, 42_u64, 1.5_f32, -2.25_f32, 4.5_f32, 7.5_f32, false)
w76_case(binary, store, root, "s_f64", "Map(String, Float64)", "Float64", "dup", "x", "tail", 1.5_f64, -2.25_f64, 4.5_f64, 7.5_f64, false)
w76_case(binary, store, root, "u_f64", "Map(UInt64, Float64)", "Float64", 0_u64, 9_u64, 42_u64, 1.5_f64, -2.25_f64, 4.5_f64, 7.5_f64, true)
