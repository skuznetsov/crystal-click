require "file_utils"
require "../src/crystal_click"

W81_KEYS          = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64]
W81_RANGE_INDICES = [2_i32, 3_i32, 4_i32, 5_i32]
W81_MARK_ROWS     = [2_u64, 2_u64, 2_u64, 1_u64, 0_u64]

private def w81_rows_uint64_key_nonnullable : Array(Array(Array(Tuple(UInt64, UInt64))))
  [
    [] of Array(Tuple(UInt64, UInt64)),
    [
      [] of Tuple(UInt64, UInt64),
      [{7_u64, 0_u64}, {7_u64, UInt64::MAX}] of Tuple(UInt64, UInt64),
    ] of Array(Tuple(UInt64, UInt64)),
    [] of Array(Tuple(UInt64, UInt64)),
    [] of Array(Tuple(UInt64, UInt64)),
    [
      [{UInt64::MAX, 42_u64}, {0_u64, 0_u64}] of Tuple(UInt64, UInt64),
      [] of Tuple(UInt64, UInt64),
    ] of Array(Tuple(UInt64, UInt64)),
    [] of Array(Tuple(UInt64, UInt64)),
    [] of Array(Tuple(UInt64, UInt64)),
  ] of Array(Array(Tuple(UInt64, UInt64)))
end

private def w81_rows_string_key_nonnullable : Array(Array(Array(Tuple(String, UInt64))))
  binary_key = String.new(Bytes[0x41_u8, 0_u8, 0xff_u8])
  [
    [] of Array(Tuple(String, UInt64)),
    [
      [] of Tuple(String, UInt64),
      [{"dup", 0_u64}, {"dup", UInt64::MAX}, {binary_key, 17_u64}] of Tuple(String, UInt64),
    ] of Array(Tuple(String, UInt64)),
    [] of Array(Tuple(String, UInt64)),
    [] of Array(Tuple(String, UInt64)),
    [
      [{binary_key, 0_u64}, {"", 42_u64}] of Tuple(String, UInt64),
      [] of Tuple(String, UInt64),
    ] of Array(Tuple(String, UInt64)),
    [] of Array(Tuple(String, UInt64)),
    [] of Array(Tuple(String, UInt64)),
  ] of Array(Array(Tuple(String, UInt64)))
end

private def w81_rows_uint64_key_nullable : Array(Array(Array(Tuple(UInt64, Float32?))))
  nan = 0x7fc0_0042_u32.unsafe_as(Float32)
  [
    [] of Array(Tuple(UInt64, Float32?)),
    [
      [] of Tuple(UInt64, Float32?),
      [{7_u64, nil}, {7_u64, 0.0_f32}] of Tuple(UInt64, Float32?),
    ] of Array(Tuple(UInt64, Float32?)),
    [] of Array(Tuple(UInt64, Float32?)),
    [] of Array(Tuple(UInt64, Float32?)),
    [
      [{UInt64::MAX, nan}, {0_u64, nil}] of Tuple(UInt64, Float32?),
      [{1_u64, -0.0_f32}] of Tuple(UInt64, Float32?),
    ] of Array(Tuple(UInt64, Float32?)),
    [] of Array(Tuple(UInt64, Float32?)),
    [] of Array(Tuple(UInt64, Float32?)),
  ] of Array(Array(Tuple(UInt64, Float32?)))
end

private def w81_rows_string_key_nullable : Array(Array(Array(Tuple(String, Float32?))))
  binary_key = String.new(Bytes[0_u8, 0xff_u8, 0x80_u8])
  nan = 0x7fc0_0042_u32.unsafe_as(Float32)
  [
    [] of Array(Tuple(String, Float32?)),
    [
      [] of Tuple(String, Float32?),
      [{"dup", nil}, {"dup", 0.0_f32}] of Tuple(String, Float32?),
    ] of Array(Tuple(String, Float32?)),
    [] of Array(Tuple(String, Float32?)),
    [] of Array(Tuple(String, Float32?)),
    [
      [{binary_key, nan}, {"", nil}] of Tuple(String, Float32?),
      [{"negative-zero", -0.0_f32}] of Tuple(String, Float32?),
    ] of Array(Tuple(String, Float32?)),
    [] of Array(Tuple(String, Float32?)),
    [] of Array(Tuple(String, Float32?)),
  ] of Array(Array(Tuple(String, Float32?)))
end

private def w81_rows_string_key_all_empty_nullable : Array(Array(Array(Tuple(String, Float32?))))
  [
    [] of Array(Tuple(String, Float32?)),
    [
      [] of Tuple(String, Float32?),
      [] of Tuple(String, Float32?),
    ] of Array(Tuple(String, Float32?)),
    [
      [] of Tuple(String, Float32?),
    ] of Array(Tuple(String, Float32?)),
    [] of Array(Tuple(String, Float32?)),
    [
      [] of Tuple(String, Float32?),
      [] of Tuple(String, Float32?),
      [] of Tuple(String, Float32?),
    ] of Array(Tuple(String, Float32?)),
    [] of Array(Tuple(String, Float32?)),
    [
      [] of Tuple(String, Float32?),
    ] of Array(Tuple(String, Float32?)),
  ] of Array(Array(Tuple(String, Float32?)))
end

private def w81_clickhouse(binary : String, store : String, query : String, input : IO = IO::Memory.new) : String
  output = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], input: input, output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (#{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

private def w81_u64(io : IO, value : UInt64) : Nil
  io.write_bytes(value, IO::ByteFormat::LittleEndian)
end

private def w81_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w81_key(io : IO, key : K) : Nil forall K
  {% if K == String %}
    w81_varuint(io, key.bytesize.to_u64)
    io.write(key.to_slice)
  {% elsif K == UInt64 %}
    w81_u64(io, key)
  {% else %}
    {% raise "unsupported W81 Map key type" %}
  {% end %}
end

private def w81_number(io : IO, value : T) : Nil forall T
  {% if T == Float32 %}
    io.write_bytes(value.unsafe_as(UInt32), IO::ByteFormat::LittleEndian)
  {% elsif T == Float64 %}
    io.write_bytes(value.unsafe_as(UInt64), IO::ByteFormat::LittleEndian)
  {% elsif T == UInt8 || T == UInt16 || T == UInt32 || T == UInt64 || T == Int8 || T == Int16 || T == Int32 || T == Int64 %}
    io.write_bytes(value, IO::ByteFormat::LittleEndian)
  {% else %}
    {% raise "unsupported W81 primitive numeric type" %}
  {% end %}
end

private def w81_rowbinary(
  keys : Array(UInt64),
  rows : Array(Array(Array(Tuple(K, V)))),
  indices : Array(Int32),
) : Bytes forall K, V
  raise "W81 primary-key and Array(Map) row counts differ" unless keys.size == rows.size
  io = IO::Memory.new
  indices.each do |index|
    w81_u64(io, keys[index])
    maps = rows[index]
    w81_varuint(io, maps.size.to_u64)
    maps.each do |entries|
      w81_varuint(io, entries.size.to_u64)
      entries.each do |key, value|
        w81_key(io, key)
        {% if V.union_types.size == 2 && V.union_types.includes?(Nil) %}
          if value.nil?
            io.write_byte(1_u8)
          else
            io.write_byte(0_u8)
            w81_number(io, value.not_nil!)
          end
        {% else %}
          w81_number(io, value)
        {% end %}
      end
    end
  end
  io.to_slice
end

private def w81_value_equal(expected : T, actual : T) : Bool forall T
  {% if T == Float32 %}
    expected.unsafe_as(UInt32) == actual.unsafe_as(UInt32)
  {% elsif T == Float64 %}
    expected.unsafe_as(UInt64) == actual.unsafe_as(UInt64)
  {% else %}
    expected == actual
  {% end %}
end

private def w81_rows_equal?(expected : Array(Array(Array(Tuple(K, T)))), actual : Array(Array(Array(Tuple(K, T))))) : Bool forall K, T
  return false unless expected.size == actual.size
  expected.each_with_index do |expected_row, row_index|
    actual_row = actual[row_index]?
    return false unless actual_row && expected_row.size == actual_row.size
    expected_row.each_with_index do |expected_map, map_index|
      actual_map = actual_row[map_index]?
      return false unless actual_map && expected_map.size == actual_map.size
      expected_map.each_with_index do |expected_entry, entry_index|
        actual_entry = actual_map[entry_index]?
        return false unless actual_entry && expected_entry[0] == actual_entry[0]
        expected_value = expected_entry[1]
        actual_value = actual_entry[1]
        {% if T.union_types.size == 2 && T.union_types.includes?(Nil) %}
          if expected_value.nil?
            return false unless actual_value.nil?
          else
            return false if actual_value.nil?
            return false unless w81_value_equal(expected_value.not_nil!, actual_value.not_nil!)
          end
        {% else %}
          return false unless w81_value_equal(expected_value, actual_value)
        {% end %}
      end
    end
  end
  true
end

private def w81_numeric_width(type_name : String) : Int32
  case type_name
  when "UInt8", "Int8"              then 1
  when "UInt16", "Int16"            then 2
  when "UInt32", "Int32", "Float32" then 4
  when "UInt64", "Int64", "Float64" then 8
  else
    raise "unsupported W81 numeric type #{type_name}"
  end
end

private def w81_expected_streams(rows : Array(Array(Array(Tuple(K, V)))), type_name : String) : Hash(String, Array(UInt8)) forall K, V
  outer_sizes = IO::Memory.new
  map_sizes = IO::Memory.new
  key_sizes = IO::Memory.new
  keys = IO::Memory.new
  null_map = IO::Memory.new
  values = IO::Memory.new
  value_width = w81_numeric_width(type_name)
  rows.each do |row|
    w81_u64(outer_sizes, row.size.to_u64)
    row.each do |entries|
      w81_u64(map_sizes, entries.size.to_u64)
      entries.each do |key, value|
        {% if K == String %}
          w81_u64(key_sizes, key.bytesize.to_u64)
          keys.write(key.to_slice)
        {% else %}
          w81_u64(keys, key)
        {% end %}
        {% if V.union_types.size == 2 && V.union_types.includes?(Nil) %}
          if value.nil?
            null_map.write_byte(1_u8)
            values.write(Bytes.new(value_width, 0_u8))
          else
            null_map.write_byte(0_u8)
            w81_number(values, value.not_nil!)
          end
        {% else %}
          w81_number(values, value)
        {% end %}
      end
    end
  end

  result = {
    "payload.size0"    => outer_sizes.to_slice.to_a,
    "payload.size1"    => map_sizes.to_slice.to_a,
    "payload%2Ekeys"   => keys.to_slice.to_a,
    "payload%2Evalues" => values.to_slice.to_a,
  }
  {% if K == String %}
    result["payload%2Ekeys.size"] = key_sizes.to_slice.to_a
  {% end %}
  {% if V.union_types.size == 2 && V.union_types.includes?(Nil) %}
    result["payload%2Evalues.null"] = null_map.to_slice.to_a
  {% end %}
  result
end

private def w81_stream_names(key_type : String, nullable : Bool) : Array(String)
  names = ["payload.size0", "payload.size1"] of String
  names << "payload%2Ekeys.size" if key_type == "String"
  names << "payload%2Ekeys"
  names << "payload%2Evalues.null" if nullable
  names << "payload%2Evalues"
  names
end

private def w81_raw_stream(part : String, stream : String) : Array(UInt8)
  encoded = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
  return [] of UInt8 if encoded.empty?
  CrystalClick::CompressedBlock.decode_all(encoded).to_a
end

private def w81_mark_records(part : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64))
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  bytes = File.read(path).to_slice
  raise "#{part} #{stream} mark file has invalid size #{bytes.size}" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(Tuple(UInt64, UInt64, UInt64)).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    word = ->(base : Int32) do
      value = 0_u64
      8.times { |byte| value |= bytes[offset + base + byte].to_u64 << (byte * 8) }
      value
    end
    {word.call(0), word.call(8), word.call(16)}
  end
end

private def w81_assert_inventory_and_streams(
  part : String,
  type_name : String,
  key_type : String,
  nullable : Bool,
  expected_raw : Hash(String, Array(UInt8)),
  stock : Bool,
) : Nil
  full_value_type = nullable ? "Nullable(#{type_name})" : type_name
  full_type = "Array(Map(#{key_type}, #{full_value_type}))"
  streams = w81_stream_names(key_type, nullable)
  expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` #{full_type}\n"
  raise "#{part} columns differ" unless File.read(File.join(part, "columns.txt")) == expected_columns

  expected_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" +
                        "#{streams.size} substreams for column `payload`:\n" + streams.map { |stream| "\t#{stream}\n" }.join
  raise "#{part} substreams differ" unless File.read(File.join(part, "columns_substreams.txt")) == expected_substreams

  serialization = File.read(File.join(part, "serialization.json")).strip
  expected_serialization = %({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
  raise "#{part} serialization differs: #{serialization}" unless serialization == expected_serialization

  expected_files = [
    "checksums.txt", "columns.txt", "columns_substreams.txt", "count.txt",
    "default_compression_codec.txt", "metadata_version.txt", stock ? "primary.cidx" : "primary.idx",
    "serialization.json",
  ]
  (streams + ["pk"]).each do |stream|
    base = CrystalClick::StreamName.hash(stream)
    expected_files << "#{base}.bin" << "#{base}.mrk2"
  end
  actual_files = Dir.children(part).sort
  raise "#{part} file inventory differs (missing=#{(expected_files - actual_files).sort}, extra=#{(actual_files - expected_files).sort})" unless actual_files == expected_files.sort
  raise "#{part} count differs" unless File.read(File.join(part, "count.txt")) == W81_KEYS.size.to_s
  raise "#{part} metadata version differs" unless File.read(File.join(part, "metadata_version.txt")) == "0"
  raise "#{part} codec differs" unless File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)"

  checksums = CrystalClick::PartChecksums.open(part)
  checksum_files = expected_files - [
    "checksums.txt", "columns.txt", "columns_substreams.txt", "default_compression_codec.txt", "metadata_version.txt",
  ]
  raise "#{part} checksum inventory differs" unless checksums.entries.keys.sort == checksum_files.sort
  checksums.entries.each_key { |name| checksums.validate_selected_entries(part, name) }

  expected_raw.each do |stream, bytes|
    actual = w81_raw_stream(part, stream)
    raise "#{part} #{stream} raw stream differs" unless actual == bytes
  end

  (streams + ["pk"]).each do |stream|
    records = w81_mark_records(part, stream)
    raise "#{part} #{stream} marks differ in count/row counts: #{records.inspect}" unless records.map(&.[2]) == W81_MARK_ROWS
    data_size = File.size(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_u64
    raw_size = if stream == "pk"
                 W81_KEYS.size.to_u64 * 8_u64
               else
                 expected_raw[stream].size.to_u64
               end
    if stock
      raise "#{part} #{stream} terminal mark does not point to raw EOF" unless records.last[1] == raw_size
    else
      raise "#{part} #{stream} terminal mark does not point to compressed EOF" unless records.last[0] == data_size && records.last[1] == 0_u64
    end
    if stream != "pk" && stream != "payload.size0" && stream != "payload.size1"
      raise "#{part} #{stream} empty middle mark advanced child data" unless {records[1][0], records[1][1]} == {records[2][0], records[2][1]}
      terminal_at_child_eof = if expected_raw[stream].empty?
                                {records[3][0], records[3][1]} == {0_u64, 0_u64}
                              else
                                records[3][0] > 0_u64 || records[3][1] > 0_u64
                              end
      unless {records[3][0], records[3][1]} == {records[4][0], records[4][1]} && terminal_at_child_eof
        raise "#{part} #{stream} terminal empty mark is not at child EOF"
      end
    end
    puts "#{File.basename(part)} #{stream} marks=#{records.inspect} data_bytes=#{data_size} raw_bytes=#{raw_size}"
  end
  nil
end

private def w81_key_bytes(keys : Array(UInt64)) : Array(UInt8)
  io = IO::Memory.new
  keys.each { |key| w81_u64(io, key) }
  io.to_slice.to_a
end

private def w81_create_table(binary : String, store : String, table : String, type_name : String) : Nil
  w81_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.#{table} (`pk` UInt64, `payload` #{type_name})
  ENGINE = MergeTree ORDER BY pk
  SETTINGS index_granularity = 2, index_granularity_bytes = 10485760,
    enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0,
    min_bytes_for_wide_part = 0, ratio_of_defaults_for_sparse_serialization = 1.0,
    compress_marks = 0, min_compress_block_size = 0, max_compress_block_size = 4096,
    write_final_mark = 1, default_compression_codec = 'LZ4'
  SQL
  nil
end

private def w81_check_table(binary : String, store : String, table : String) : Nil
  observed = w81_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "#{table} CHECK TABLE failed: #{observed.inspect}" unless observed == "all_1_1_0\t1"
  nil
end

private def w81_query_rows(binary : String, store : String, table : String, expected : Bytes, ranged : Bytes) : Nil
  full = w81_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  raise "#{table} full RowBinary differs" unless full.to_slice == expected
  selected = w81_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} WHERE pk >= 3 AND pk < 7 ORDER BY pk FORMAT RowBinary")
  raise "#{table} key-range RowBinary differs" unless selected.to_slice == ranged
  nil
end

private def w81_stock_part(binary : String, store : String, root : String, table : String) : String
  path = w81_clickhouse(binary, store, "SELECT path FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TSVRaw").strip
  raise "#{table} source part missing" unless Dir.exists?(path)
  part = File.join(root, "stock-#{table}")
  FileUtils.cp_r(path, part)
  part
end

private def w81_write_u64_at(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

{% if flag?(:w81_reader) %}
  private def w81_assert_later_mark_corruption_rejected(part : String, root : String) : Nil
    corrupt_part = File.join(root, "corrupt-w81-child-mark")
    FileUtils.cp_r(part, corrupt_part)
    marks_path = File.join(corrupt_part, "#{CrystalClick::StreamName.hash("payload.size1")}.mrk2")
    marks = File.read(marks_path).to_slice.dup
    w81_write_u64_at(marks, 2 * CrystalClick::WidePart::MARK_SIZE + 8, UInt64::MAX)
    File.write(marks_path, marks)

    rejected = false
    begin
      reader = CrystalClick::WidePart.open_typed(corrupt_part, "payload")
      reader.read_array_map_uint64_numeric_mark_range("payload", 2, 1, UInt64)
    rescue ex : CrystalClick::CorruptPartError
      rejected = true
    end
    raise "reader accepted a later W81 child mark beyond its stream extent" unless rejected
    puts "PASS W81 corruption guard: rejects a malformed later Map-size mark"
    nil
  end
{% end %}

private def w81_run_case(
  binary : String,
  store : String,
  root : String,
  label : String,
  type_name : String,
  key_type : String,
  leaf_type : U.class,
  nullable : Bool,
  keys : Array(UInt64),
  rows : Array(Array(Array(Tuple(K, V)))),
) : Nil forall K, V, U
  table_stock = "w81_stock_#{label}"
  table_writer = "w81_writer_#{label}"
  full_type = "Array(Map(#{key_type}, #{nullable ? "Nullable(#{type_name})" : type_name}))"
  all_indices = (0...keys.size).map(&.to_i32)
  expected = w81_rowbinary(keys, rows, all_indices)
  ranged = w81_rowbinary(keys, rows, W81_RANGE_INDICES)
  expected_raw = w81_expected_streams(rows, type_name)
  expected_raw["pk"] = w81_key_bytes(keys)

  w81_create_table(binary, store, table_stock, full_type)
  w81_clickhouse(binary, store, "INSERT INTO default.#{table_stock} FORMAT RowBinary", IO::Memory.new(expected))
  w81_check_table(binary, store, table_stock)
  w81_query_rows(binary, store, table_stock, expected, ranged)
  stock_part = w81_stock_part(binary, store, root, table_stock)
  w81_assert_inventory_and_streams(stock_part, type_name, key_type, nullable, expected_raw, true)

  {% if flag?(:w81_reader) %}
    stock_reader = CrystalClick::WidePart.open_typed(stock_part, "payload")
    {% if K == String %}
      {% if V.union_types.size == 2 && V.union_types.includes?(Nil) %}
        stock_values = stock_reader.read_array_map_string_nullable_numeric_mark_range("payload", 0, stock_reader.mark_count, leaf_type)
        middle_values = stock_reader.read_array_map_string_nullable_numeric_mark_range("payload", 1, 1, leaf_type)
        later_values = stock_reader.read_array_map_string_nullable_numeric_mark_range("payload", 2, 1, leaf_type)
        terminal_values = stock_reader.read_array_map_string_nullable_numeric_mark_range("payload", 3, 1, leaf_type)
      {% else %}
        stock_values = stock_reader.read_array_map_string_numeric_mark_range("payload", 0, stock_reader.mark_count, leaf_type)
        middle_values = stock_reader.read_array_map_string_numeric_mark_range("payload", 1, 1, leaf_type)
        later_values = stock_reader.read_array_map_string_numeric_mark_range("payload", 2, 1, leaf_type)
        terminal_values = stock_reader.read_array_map_string_numeric_mark_range("payload", 3, 1, leaf_type)
      {% end %}
    {% else %}
      {% if V.union_types.size == 2 && V.union_types.includes?(Nil) %}
        stock_values = stock_reader.read_array_map_uint64_nullable_numeric_mark_range("payload", 0, stock_reader.mark_count, leaf_type)
        middle_values = stock_reader.read_array_map_uint64_nullable_numeric_mark_range("payload", 1, 1, leaf_type)
        later_values = stock_reader.read_array_map_uint64_nullable_numeric_mark_range("payload", 2, 1, leaf_type)
        terminal_values = stock_reader.read_array_map_uint64_nullable_numeric_mark_range("payload", 3, 1, leaf_type)
      {% else %}
        stock_values = stock_reader.read_array_map_uint64_numeric_mark_range("payload", 0, stock_reader.mark_count, leaf_type)
        middle_values = stock_reader.read_array_map_uint64_numeric_mark_range("payload", 1, 1, leaf_type)
        later_values = stock_reader.read_array_map_uint64_numeric_mark_range("payload", 2, 1, leaf_type)
        terminal_values = stock_reader.read_array_map_uint64_numeric_mark_range("payload", 3, 1, leaf_type)
      {% end %}
    {% end %}
    raise "#{table_stock} full stock-to-Crystal read differs" unless w81_rows_equal?(rows, stock_values)
    raise "#{table_stock} middle empty mark read differs" unless w81_rows_equal?(rows[2, 2], middle_values)
    raise "#{table_stock} later mark read differs" unless w81_rows_equal?(rows[4, 2], later_values)
    raise "#{table_stock} terminal empty mark read differs" unless w81_rows_equal?(rows[6, 1], terminal_values)
    if key_type == "UInt64" && type_name == "UInt64" && !nullable
      wrong_leaf_rejected = false
      begin
        stock_reader.read_array_map_uint64_numeric_mark_range("payload", 0, 1, Float32)
      rescue ex : CrystalClick::UnsupportedFormatError
        wrong_leaf_rejected = true
      end
      raise "reader admitted a W81 declaration with a mismatched numeric leaf" unless wrong_leaf_rejected
      puts "PASS W81 negative admission: rejects a mismatched numeric leaf class"
      w81_assert_later_mark_corruption_rejected(stock_part, root)
    end
    puts "PASS W81 stock-to-Crystal #{full_type}"
  {% end %}

  {% if flag?(:w81_writer) %}
    writer_part = File.join(root, "writer-#{label}")
    {% if K == String %}
      {% if V.union_types.size == 2 && V.union_types.includes?(Nil) %}
        CrystalClick::WidePartWriter.write_uint64_array_map_string_nullable_numeric_pair(
          writer_part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size), rows_per_mark: 2
        )
      {% else %}
        CrystalClick::WidePartWriter.write_uint64_array_map_string_numeric_pair(
          writer_part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size), rows_per_mark: 2
        )
      {% end %}
    {% else %}
      {% if V.union_types.size == 2 && V.union_types.includes?(Nil) %}
        CrystalClick::WidePartWriter.write_uint64_array_map_uint64_nullable_numeric_pair(
          writer_part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size), rows_per_mark: 2
        )
      {% else %}
        CrystalClick::WidePartWriter.write_uint64_array_map_uint64_numeric_pair(
          writer_part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size), rows_per_mark: 2
        )
      {% end %}
    {% end %}
    w81_assert_inventory_and_streams(writer_part, type_name, key_type, nullable, expected_raw, false)
    writer_reader = CrystalClick::WidePart.open_typed(writer_part, "payload")
    {% if K == String %}
      {% if V.union_types.size == 2 && V.union_types.includes?(Nil) %}
        writer_values = writer_reader.read_array_map_string_nullable_numeric_mark_range("payload", 0, writer_reader.mark_count, leaf_type)
      {% else %}
        writer_values = writer_reader.read_array_map_string_numeric_mark_range("payload", 0, writer_reader.mark_count, leaf_type)
      {% end %}
    {% else %}
      {% if V.union_types.size == 2 && V.union_types.includes?(Nil) %}
        writer_values = writer_reader.read_array_map_uint64_nullable_numeric_mark_range("payload", 0, writer_reader.mark_count, leaf_type)
      {% else %}
        writer_values = writer_reader.read_array_map_uint64_numeric_mark_range("payload", 0, writer_reader.mark_count, leaf_type)
      {% end %}
    {% end %}
    raise "#{table_writer} writer-local full roundtrip differs" unless w81_rows_equal?(rows, writer_values)

    w81_create_table(binary, store, table_writer, full_type)
    data_path = w81_clickhouse(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{table_writer}' FORMAT TSVRaw").strip
    raise "#{table_writer} data path is missing" if data_path.empty?
    detached = File.join(data_path, "detached")
    FileUtils.mkdir_p(detached)
    FileUtils.cp_r(writer_part, File.join(detached, "all_1_1_0"))
    w81_clickhouse(binary, store, "ALTER TABLE default.#{table_writer} ATTACH PART 'all_1_1_0'")
    w81_check_table(binary, store, table_writer)
    w81_query_rows(binary, store, table_writer, expected, ranged)
    puts "PASS W81 Crystal-to-stock ATTACH/CHECK #{full_type}"
  {% end %}
  nil
end

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("CLICKHOUSE_STORE")
root = ENV.fetch("ORACLE_ROOT")
keys = W81_KEYS

w81_run_case(binary, store, root, "u64_u64", "UInt64", "UInt64", UInt64, false, keys, w81_rows_uint64_key_nonnullable)
w81_run_case(binary, store, root, "string_u64", "UInt64", "String", UInt64, false, keys, w81_rows_string_key_nonnullable)
w81_run_case(binary, store, root, "u64_null_f32", "Float32", "UInt64", Float32, true, keys, w81_rows_uint64_key_nullable)
w81_run_case(binary, store, root, "string_null_f32", "Float32", "String", Float32, true, keys, w81_rows_string_key_nullable)
w81_run_case(binary, store, root, "string_null_f32_empty", "Float32", "String", Float32, true, keys, w81_rows_string_key_all_empty_nullable)

puts "W81 pinned ClickHouse oracle mode=#{ENV.fetch("W81_ORACLE_MODE")}: ClickHouse 26.7.1.1315; four representative key/nullability combinations plus all-empty child streams; exact streams, marks, metadata, full/keyed RowBinary, ATTACH/CHECK where enabled"
