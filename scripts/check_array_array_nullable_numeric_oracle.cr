require "file_utils"
require "../src/crystal_click"

def w60_oracle_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  result = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (#{result.exit_code}): #{query}" unless result.success?
  output.to_s
end

def w60_append_u64(io : IO, value : UInt64) : Nil
  8.times { |byte| io.write_byte(((value >> (byte * 8)) & 0xff_u64).to_u8) }
end

def w60_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

def w60_append_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

def w60_numeric_bits(value : T) : UInt64 forall T
  {% if T == UInt8 || T == Int8 %}
    value.unsafe_as(UInt8).to_u64
  {% elsif T == UInt16 || T == Int16 %}
    value.unsafe_as(UInt16).to_u64
  {% elsif T == UInt32 || T == Int32 || T == Float32 %}
    value.unsafe_as(UInt32).to_u64
  {% else %}
    value.unsafe_as(UInt64)
  {% end %}
end

def w60_numeric_width(type : T.class) : Int32 forall T
  {% if T == UInt8 || T == Int8 %}
    1
  {% elsif T == UInt16 || T == Int16 %}
    2
  {% elsif T == UInt32 || T == Int32 || T == Float32 %}
    4
  {% else %}
    8
  {% end %}
end

def w60_append_numeric(io : IO, value : T) : Nil forall T
  bits = w60_numeric_bits(value)
  w60_numeric_width(T).times do |byte|
    io.write_byte(((bits >> (byte * 8)) & 0xff_u64).to_u8)
  end
end

def w60_append_array_array(io : IO, row : Array(Array(T?))) : Nil forall T
  w60_append_varuint(io, row.size.to_u64)
  row.each do |inner|
    w60_append_varuint(io, inner.size.to_u64)
    inner.each do |value|
      if value.nil?
        io.write_byte(1_u8)
      else
        io.write_byte(0_u8)
        w60_append_numeric(io, value.not_nil!)
      end
    end
  end
end

def w60_expected_rowbinary(
  keys : Array(UInt64),
  rows : Array(Array(Array(T?))),
  selected : Array(Int32),
) : Bytes forall T
  io = IO::Memory.new
  selected.each do |index|
    w60_append_u64(io, keys[index])
    w60_append_array_array(io, rows[index])
  end
  io.to_slice
end

def w60_assert_rowbinary(actual : String, expected : Bytes, label : String) : Nil
  raise "#{label} RowBinary mismatch: expected #{expected.size} bytes, got #{actual.bytesize}" unless actual.to_slice == expected
end

def w60_mark_position(part : String, stream : String, mark_index : Int) : {UInt64, UInt64}
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(path).to_slice
  offset = mark_index * CrystalClick::WidePart::MARK_SIZE
  {w60_read_u64(marks, offset), w60_read_u64(marks, offset + 8)}
end

def w60_assert_stream_topology(part : String, type_name : String, mark_rows : Array(UInt64)) : Nil
  expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` Array(Array(Nullable(#{type_name})))\n"
  raise "nested nullable numeric column types differ" unless File.read(File.join(part, "columns.txt")) == expected_columns
  expected = "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n4 substreams for column `payload`:\n\tpayload.size0\n\tpayload.size1\n\tpayload.null\n\tpayload\n"
  actual = File.read(File.join(part, "columns_substreams.txt"))
  raise "nested nullable numeric stream topology differs" unless actual == expected
  serialization = File.read(File.join(part, "serialization.json")).strip
  expected_serialization = %({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
  raise "nested nullable numeric serialization metadata differs" unless serialization == expected_serialization
  ["payload.size0", "payload.size1", "payload.null", "payload"].each do |stream|
    ["bin", "mrk2"].each do |extension|
      path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.#{extension}")
      raise "missing #{stream}.#{extension}" unless File.file?(path)
    end
    marks = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
    expected_size = (mark_rows.size + 1) * CrystalClick::WidePart::MARK_SIZE
    raise "#{stream} mark count differs" unless marks.size == expected_size
    (mark_rows + [0_u64]).each_with_index do |rows, index|
      actual_rows = w60_read_u64(marks, index * CrystalClick::WidePart::MARK_SIZE + 16)
      raise "#{stream} mark #{index} rows differ: #{actual_rows} != #{rows}" unless actual_rows == rows
    end
  end
  nil
end

def w60_assert_zero_middle_child_mark(part : String) : Nil
  size0_middle = w60_mark_position(part, "payload.size0", 1)
  size0_later = w60_mark_position(part, "payload.size0", 2)
  raise "payload.size0 did not advance across the middle mark" if size0_middle == size0_later
  ["payload.size1", "payload.null", "payload"].each do |stream|
    middle = w60_mark_position(part, stream, 1)
    later = w60_mark_position(part, stream, 2)
    raise "#{stream} middle mark is not zero-byte: #{middle.inspect} != #{later.inspect}" unless middle == later
  end
  nil
end

def w60_assert_empty_leaf_streams(part : String) : Nil
  ["payload.null", "payload"].each do |stream|
    path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
    size = File.size(path)
    raise "#{stream} should have a zero-byte data file, got #{size} bytes" unless size == 0
  end
  size0_path = File.join(part, "#{CrystalClick::StreamName.hash("payload.size0")}.bin")
  raise "payload.size0 should still contain row offsets" unless File.size(size0_path) > 0
  size1_path = File.join(part, "#{CrystalClick::StreamName.hash("payload.size1")}.bin")
  raise "payload.size1 should contain offsets for empty inner Arrays" unless File.size(size1_path) > 0
  nil
end

def w60_assert_rows_equal(actual : Array(Array(Array(T?))), expected : Array(Array(Array(T?))), label : String) : Nil forall T
  actual_bits = actual.map { |row| row.map { |inner| inner.map { |value| value.nil? ? nil : w60_numeric_bits(value.not_nil!) } } }
  expected_bits = expected.map { |row| row.map { |inner| inner.map { |value| value.nil? ? nil : w60_numeric_bits(value.not_nil!) } } }
  raise "#{label} values differ by row or raw numeric bits" unless actual_bits == expected_bits
end

def w60_sql_scalar(value : T) : String forall T
  {% if T == Float32 %}
    "reinterpretAsFloat32(toUInt32(#{value.unsafe_as(UInt32)}))"
  {% elsif T == Float64 %}
    "reinterpretAsFloat64(toUInt64(#{value.unsafe_as(UInt64)}))"
  {% else %}
    value.to_s
  {% end %}
end

def w60_array_array_sql(row : Array(Array(T?)), type : T.class) : String forall T
  inner = row.map { |values| "[#{values.map { |value| value.nil? ? "NULL" : w60_sql_scalar(value.not_nil!) }.join(", ")}]" }.join(", ")
  "CAST([#{inner}], 'Array(Array(Nullable(#{CrystalClick::WidePart.numeric_type_name(type)})))')"
end

private def w60_oracle_rows(type : T.class) : Array(Array(Array(T))) forall T
  {% if T == UInt8 %}
    [
      [] of Array(UInt8),
      [[] of UInt8, [0_u8, UInt8::MAX], [] of UInt8],
      [[] of UInt8],
      [[1_u8, 128_u8], [] of UInt8],
      [[UInt8::MAX]],
    ] of Array(Array(UInt8))
  {% elsif T == UInt16 %}
    [
      [] of Array(UInt16),
      [[] of UInt16, [0_u16, UInt16::MAX], [] of UInt16],
      [[] of UInt16],
      [[1_u16, 32_768_u16], [] of UInt16],
      [[UInt16::MAX]],
    ] of Array(Array(UInt16))
  {% elsif T == UInt32 %}
    [
      [] of Array(UInt32),
      [[] of UInt32, [0_u32, UInt32::MAX], [] of UInt32],
      [[] of UInt32],
      [[1_u32, 0x8000_0000_u32], [] of UInt32],
      [[UInt32::MAX]],
    ] of Array(Array(UInt32))
  {% elsif T == UInt64 %}
    [
      [] of Array(UInt64),
      [[] of UInt64, [0_u64, UInt64::MAX], [] of UInt64],
      [[] of UInt64],
      [[1_u64, 0x8000_0000_0000_0000_u64], [] of UInt64],
      [[UInt64::MAX]],
    ] of Array(Array(UInt64))
  {% elsif T == Int8 %}
    [
      [] of Array(Int8),
      [[] of Int8, [Int8::MIN, -1_i8], [] of Int8],
      [[] of Int8],
      [[0_i8, Int8::MAX], [] of Int8],
      [[-42_i8]],
    ] of Array(Array(Int8))
  {% elsif T == Int16 %}
    [
      [] of Array(Int16),
      [[] of Int16, [Int16::MIN, -1_i16], [] of Int16],
      [[] of Int16],
      [[0_i16, Int16::MAX], [] of Int16],
      [[-42_i16]],
    ] of Array(Array(Int16))
  {% elsif T == Int32 %}
    [
      [] of Array(Int32),
      [[] of Int32, [Int32::MIN, -1_i32], [] of Int32],
      [[] of Int32],
      [[0_i32, Int32::MAX], [] of Int32],
      [[-42_i32]],
    ] of Array(Array(Int32))
  {% elsif T == Int64 %}
    [
      [] of Array(Int64),
      [[] of Int64, [Int64::MIN, -1_i64], [] of Int64],
      [[] of Int64],
      [[0_i64, Int64::MAX], [] of Int64],
      [[-42_i64]],
    ] of Array(Array(Int64))
  {% elsif T == Float32 %}
    [
      [] of Array(Float32),
      [[] of Float32, [0x8000_0000_u32.unsafe_as(Float32), 0_u32.unsafe_as(Float32), 0x7fc1_2345_u32.unsafe_as(Float32)], [] of Float32],
      [[] of Float32],
      [[0x0000_0001_u32.unsafe_as(Float32), 0x8000_0001_u32.unsafe_as(Float32)], [] of Float32],
      [[0x7f80_0000_u32.unsafe_as(Float32)]],
    ] of Array(Array(Float32))
  {% elsif T == Float64 %}
    [
      [] of Array(Float64),
      [[] of Float64, [0x8000_0000_0000_0000_u64.unsafe_as(Float64), 0_u64.unsafe_as(Float64), 0x7ff8_0000_0000_1234_u64.unsafe_as(Float64)], [] of Float64],
      [[] of Float64],
      [[0x0000_0000_0000_0001_u64.unsafe_as(Float64), 0x8000_0000_0000_0001_u64.unsafe_as(Float64)], [] of Float64],
      [[0x7ff0_0000_0000_0000_u64.unsafe_as(Float64)]],
    ] of Array(Array(Float64))
  {% end %}
end

private def w60_nullable_rows(type : T.class) : Array(Array(Array(T?))) forall T
  rows = w60_oracle_rows(type).map do |row|
    row.map do |inner|
      inner.map { |value| value.as(T?) }
    end
  end
  # Retain the original extrema and raw Float patterns while adding distinct
  # NULL slots inside nonempty inner Arrays and at the tail.
  rows[1][1].insert(1, nil)
  rows[3] << [nil, nil] of T?
  rows[4][0] << nil
  rows
end

def w60_attach_part(binary : String, store : String, table : String, type_name : String, part : String) : Nil
  w60_oracle_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.#{table}
  (
      pk UInt64,
      payload Array(Array(Nullable(#{type_name})))
  )
  ENGINE = MergeTree
  ORDER BY pk
  SETTINGS
      index_granularity = 2,
      index_granularity_bytes = 10485760,
      enable_mixed_granularity_parts = 1,
      min_rows_for_wide_part = 0,
      min_bytes_for_wide_part = 0,
      compress_marks = 0,
      min_compress_block_size = 0,
      max_compress_block_size = 4096,
      ratio_of_defaults_for_sparse_serialization = 1.0,
      default_compression_codec = 'LZ4';
  SQL
  data_path = w60_oracle_clickhouse(
    binary,
    store,
    "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{table}' FORMAT TSVRaw"
  ).strip
  raise "no ClickHouse data path for #{table}" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  w60_oracle_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  integrity = w60_oracle_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "CHECK TABLE failed for #{table}: #{integrity.inspect}" unless integrity == "all_1_1_0\t1"
  nil
end

def w60_verify_stock_read(
  binary : String,
  store : String,
  part : String,
  table : String,
  column : String,
  type : T.class,
  rows : Array(Array(Array(T?))),
  keys : Array(UInt64),
  mark_rows : Array(UInt64) = [2_u64, 2_u64, 1_u64],
) : Nil forall T
  type_name = CrystalClick::WidePart.numeric_type_name(type)
  selected = (0...keys.size).map(&.to_i32)
  actual = w60_oracle_clickhouse(binary, store, "SELECT pk, #{column} FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  w60_assert_rowbinary(actual, w60_expected_rowbinary(keys, rows, selected), "stock #{table} full")

  reader = CrystalClick::WidePart.open_typed(part, column)
  expected_type = "Array(Array(Nullable(#{type_name})))"
  raise "stock #{table} declared #{reader.column_type}, expected #{expected_type}" unless reader.column_type == expected_type
  raise "stock #{table} mark rows mismatch: #{reader.mark_row_counts.inspect}" unless reader.mark_row_counts == mark_rows
  observed = reader.read_array_array_nullable_numeric_mark_range(column, 0, reader.mark_count, type)
  w60_assert_rows_equal(observed, rows, "stock #{table} Crystal reader")
  if reader.mark_count > 2
    later_start = mark_rows[0] + mark_rows[1]
    later = reader.read_array_array_nullable_numeric_mark_range(column, 2, reader.mark_count - 2, type)
    w60_assert_rows_equal(later, rows[later_start.to_i..], "stock #{table} later marks")
  end
  nil
end

def w60_create_stock_source(
  binary : String,
  store : String,
  root : String,
  table : String,
  type : T.class,
  rows : Array(Array(Array(T?))),
  keys : Array(UInt64),
  mark_rows : Array(UInt64) = [2_u64, 2_u64, 1_u64],
  assert_zero_middle_child_mark : Bool = false,
  check_empty_leaf_streams : Bool = false,
) : Nil forall T
  type_name = CrystalClick::WidePart.numeric_type_name(type)
  table_name = "source_#{table}"
  insert_rows = keys.each_index.map do |index|
    "(#{keys[index]}, #{w60_array_array_sql(rows[index], type)})"
  end

  w60_oracle_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.#{table_name}
  (
      pk UInt64,
      payload Array(Array(Nullable(#{type_name})))
  )
  ENGINE = MergeTree
  ORDER BY pk
  SETTINGS
      index_granularity = 2,
      index_granularity_bytes = 10485760,
      enable_mixed_granularity_parts = 1,
      min_rows_for_wide_part = 0,
      min_bytes_for_wide_part = 0,
      compress_marks = 0,
      min_compress_block_size = 0,
      max_compress_block_size = 4096,
      ratio_of_defaults_for_sparse_serialization = 1.0,
      default_compression_codec = 'LZ4'
  SQL
  w60_oracle_clickhouse(binary, store, "INSERT INTO default.#{table_name} VALUES #{insert_rows.join(", ")}")
  source_check = w60_oracle_clickhouse(binary, store, "CHECK TABLE default.#{table_name} FORMAT TabSeparated").strip
  raise "stock producer CHECK TABLE failed for #{table}: #{source_check.inspect}" unless source_check == "all_1_1_0\t1"
  stock_path = w60_oracle_clickhouse(binary, store, "SELECT path FROM system.parts WHERE database = 'default' AND table = '#{table_name}' AND active FORMAT TSVRaw").strip
  raise "stock producer part missing for #{table}: #{stock_path.inspect}" unless Dir.exists?(stock_path)
  stock_part = File.join(root, "stock-part-#{table}")
  FileUtils.cp_r(stock_path, stock_part)
  w60_assert_stream_topology(stock_part, type_name, mark_rows)
  w60_assert_zero_middle_child_mark(stock_part) if assert_zero_middle_child_mark
  w60_assert_empty_leaf_streams(stock_part) if check_empty_leaf_streams
  w60_verify_stock_read(binary, store, stock_part, table_name, "payload", type, rows, keys, mark_rows)
  nil
end

def w60_verify_writer(
  binary : String,
  store : String,
  root : String,
  table : String,
  type : T.class,
  rows : Array(Array(Array(T?))),
  keys : Array(UInt64),
  mark_rows : Array(UInt64) = [2_u64, 2_u64, 1_u64],
  assert_zero_middle_child_mark : Bool = false,
  check_empty_leaf_streams : Bool = false,
) : Nil forall T
  type_name = CrystalClick::WidePart.numeric_type_name(type)
  part = File.join(root, "writer-#{table}")
  CrystalClick::WidePartWriter.write_uint64_array_array_nullable_numeric_pair(
    part,
    "pk",
    keys.to_unsafe.to_slice(keys.size),
    "payload",
    rows.to_unsafe.to_slice(rows.size),
    rows_per_mark: 2
  )
  w60_assert_stream_topology(part, type_name, mark_rows)
  w60_assert_zero_middle_child_mark(part) if assert_zero_middle_child_mark
  w60_assert_empty_leaf_streams(part) if check_empty_leaf_streams

  table_name = "array_array_writer_#{table}"
  w60_attach_part(binary, store, table_name, type_name, part)
  selected = keys.each_with_index.compact_map { |key, index| index.to_i32 if key >= 2_u64 && key < 10_u64 }.to_a
  full = w60_oracle_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table_name} ORDER BY pk FORMAT RowBinary")
  w60_assert_rowbinary(full, w60_expected_rowbinary(keys, rows, (0...keys.size).map(&.to_i32)), "writer #{table} full")
  ranged = w60_oracle_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table_name} WHERE pk >= 2 AND pk < 10 ORDER BY pk FORMAT RowBinary")
  w60_assert_rowbinary(ranged, w60_expected_rowbinary(keys, rows, selected), "writer #{table} key range")
  nil
end

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("CLICKHOUSE_STORE")
root = ENV.fetch("ORACLE_ROOT")
keys = [1_u64, 2_u64, 4_u64, 7_u64, 10_u64]
u8 = w60_nullable_rows(UInt8)
u16 = w60_nullable_rows(UInt16)
u32 = w60_nullable_rows(UInt32)
u64 = w60_nullable_rows(UInt64)
i8 = w60_nullable_rows(Int8)
i16 = w60_nullable_rows(Int16)
i32 = w60_nullable_rows(Int32)
i64 = w60_nullable_rows(Int64)
f32 = w60_nullable_rows(Float32)
f64 = w60_nullable_rows(Float64)

w60_create_stock_source(binary, store, root, "u8", UInt8, u8, keys)
w60_create_stock_source(binary, store, root, "u16", UInt16, u16, keys)
w60_create_stock_source(binary, store, root, "u32", UInt32, u32, keys)
w60_create_stock_source(binary, store, root, "u64", UInt64, u64, keys)
w60_create_stock_source(binary, store, root, "i8", Int8, i8, keys)
w60_create_stock_source(binary, store, root, "i16", Int16, i16, keys)
w60_create_stock_source(binary, store, root, "i32", Int32, i32, keys)
w60_create_stock_source(binary, store, root, "i64", Int64, i64, keys)
w60_create_stock_source(binary, store, root, "f32", Float32, f32, keys)
w60_create_stock_source(binary, store, root, "f64", Float64, f64, keys)

w60_verify_writer(binary, store, root, "u8", UInt8, u8, keys)
w60_verify_writer(binary, store, root, "u16", UInt16, u16, keys)
w60_verify_writer(binary, store, root, "u32", UInt32, u32, keys)
w60_verify_writer(binary, store, root, "u64", UInt64, u64, keys)
w60_verify_writer(binary, store, root, "i8", Int8, i8, keys)
w60_verify_writer(binary, store, root, "i16", Int16, i16, keys)
w60_verify_writer(binary, store, root, "i32", Int32, i32, keys)
w60_verify_writer(binary, store, root, "i64", Int64, i64, keys)
w60_verify_writer(binary, store, root, "f32", Float32, f32, keys)
w60_verify_writer(binary, store, root, "f64", Float64, f64, keys)

empty_middle_keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]
empty_middle_rows = [
  [[11_i32, nil, 12_i32] of Int32?],
  [] of Array(Int32?),
  [] of Array(Int32?),
  [] of Array(Int32?),
  [[nil, 33_i32] of Int32?, [] of Int32?],
  [[] of Int32?],
] of Array(Array(Int32?))
empty_middle_marks = [2_u64, 2_u64, 2_u64]
w60_create_stock_source(
  binary,
  store,
  root,
  "empty_middle",
  Int32,
  empty_middle_rows,
  empty_middle_keys,
  empty_middle_marks,
  assert_zero_middle_child_mark: true
)
w60_verify_writer(
  binary,
  store,
  root,
  "empty_middle",
  Int32,
  empty_middle_rows,
  empty_middle_keys,
  empty_middle_marks,
  assert_zero_middle_child_mark: true
)

all_null_middle_rows = [
  [[11_i32, 12_i32] of Int32?],
  [[] of Int32?],
  [[nil, nil] of Int32?],
  [[nil] of Int32?, [nil] of Int32?],
  [[33_i32] of Int32?],
  [[nil, 44_i32] of Int32?],
] of Array(Array(Int32?))
w60_create_stock_source(binary, store, root, "all_null_middle", Int32, all_null_middle_rows, empty_middle_keys, empty_middle_marks)
w60_verify_writer(binary, store, root, "all_null_middle", Int32, all_null_middle_rows, empty_middle_keys, empty_middle_marks)

empty_child_keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
empty_child_rows = Array(Array(Array(Int32?))).new(5) { [[] of Int32?] }
w60_create_stock_source(
  binary,
  store,
  root,
  "empty_child",
  Int32,
  empty_child_rows,
  empty_child_keys,
  check_empty_leaf_streams: true
)
w60_verify_writer(
  binary,
  store,
  root,
  "empty_child",
  Int32,
  empty_child_rows,
  empty_child_keys,
  check_empty_leaf_streams: true
)

puts "Array(Array(Nullable(T))) stock oracle passed: ClickHouse 26.7.1.1315 all-ten producer/consumer plus empty and all-NULL middle marks, empty leaf streams, and ATTACH PART/CHECK/full/range RowBinary"
