require "file_utils"
require "./../src/crystal_click"

def oracle_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  result = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (#{result.exit_code}): #{query}" unless result.success?
  output.to_s
end

def append_u64(io : IO, value : UInt64) : Nil
  8.times { |byte| io.write_byte(((value >> (byte * 8)) & 0xff_u64).to_u8) }
end

def append_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

def numeric_bits(value : T) : UInt64 forall T
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

def numeric_width(type : T.class) : Int32 forall T
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

def append_numeric(io : IO, value : T) : Nil forall T
  bits = numeric_bits(value)
  width = numeric_width(T)
  width.times { |byte| io.write_byte(((bits >> (byte * 8)) & 0xff_u64).to_u8) }
end

def append_array(io : IO, values : Array(T)) : Nil forall T
  append_varuint(io, values.size.to_u64)
  values.each { |value| append_numeric(io, value) }
end

def expected_single_array_rowbinary(keys : Array(UInt64), values : Array(Array(T)), selected : Array(Int32)) : Bytes forall T
  io = IO::Memory.new
  selected.each do |row|
    append_u64(io, keys[row])
    append_array(io, values[row])
  end
  io.to_slice
end

def expected_stock_rowbinary(
  keys : Array(UInt64),
  u8 : Array(Array(UInt8)), u16 : Array(Array(UInt16)), u32 : Array(Array(UInt32)), u64 : Array(Array(UInt64)),
  i8 : Array(Array(Int8)), i16 : Array(Array(Int16)), i32 : Array(Array(Int32)), i64 : Array(Array(Int64)),
  f32 : Array(Array(Float32)), f64 : Array(Array(Float64)),
  selected : Array(Int32),
) : Bytes
  io = IO::Memory.new
  selected.each do |row|
    append_u64(io, keys[row])
    append_array(io, u8[row])
    append_array(io, u16[row])
    append_array(io, u32[row])
    append_array(io, u64[row])
    append_array(io, i8[row])
    append_array(io, i16[row])
    append_array(io, i32[row])
    append_array(io, i64[row])
    append_array(io, f32[row])
    append_array(io, f64[row])
  end
  io.to_slice
end

def assert_rowbinary(actual : String, expected : Bytes, label : String) : Nil
  raise "#{label} RowBinary mismatch: expected #{expected.size} bytes, got #{actual.bytesize}" unless actual.to_slice == expected
end

def attach_part(binary : String, store : String, table : String, schema : String, part : String) : Nil
  oracle_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.#{table}
  (
      #{schema}
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
  data_path = oracle_clickhouse(
    binary,
    store,
    "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{table}' FORMAT TSVRaw"
  ).strip
  raise "no ClickHouse data path for #{table}" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  oracle_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  integrity = oracle_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "CHECK TABLE failed for #{table}: #{integrity.inspect}" unless integrity == "all_1_1_0\t1"
end

def verify_writer(binary : String, store : String, root : String, name : String, type : T.class, values : Array(Array(T)), keys : Array(UInt64), selected : Array(Int32)) : Nil forall T
  part = File.join(root, "writer-#{name}")
  CrystalClick::WidePartWriter.write_uint64_array_numeric_pair(
    part,
    "pk",
    keys.to_unsafe.to_slice(keys.size),
    "payload",
    values.to_unsafe.to_slice(values.size),
    rows_per_mark: 2
  )
  type_name = CrystalClick::WidePart.numeric_type_name(type)
  table = "array_numeric_writer_#{name}"
  attach_part(binary, store, table, "pk UInt64, payload Array(#{type_name})", part)
  full = oracle_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  assert_rowbinary(full, expected_single_array_rowbinary(keys, values, (0...keys.size).map(&.to_i32)), "writer #{name} full")
  ranged = oracle_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} WHERE pk >= 2 AND pk < 11 ORDER BY pk FORMAT RowBinary")
  assert_rowbinary(ranged, expected_single_array_rowbinary(keys, values, selected), "writer #{name} range")
end

private def expected_values(type : T.class) : Array(Array(T)) forall T
  {% if T == UInt8 %}
    [[] of UInt8, [0_u8, UInt8::MAX], [] of UInt8, [1_u8, 128_u8], [0_u8, 1_u8], [UInt8::MAX], [] of UInt8] of Array(UInt8)
  {% elsif T == UInt16 %}
    [[] of UInt16, [0_u16, UInt16::MAX], [] of UInt16, [1_u16, 32_768_u16], [0_u16, 1_u16], [UInt16::MAX], [] of UInt16] of Array(UInt16)
  {% elsif T == UInt32 %}
    [[] of UInt32, [0_u32, UInt32::MAX], [] of UInt32, [1_u32, 0x8000_0000_u32], [0_u32, 1_u32], [UInt32::MAX], [] of UInt32] of Array(UInt32)
  {% elsif T == UInt64 %}
    [[] of UInt64, [0_u64, UInt64::MAX], [] of UInt64, [1_u64, 0x8000_0000_0000_0000_u64], [0_u64, 1_u64], [UInt64::MAX], [] of UInt64] of Array(UInt64)
  {% elsif T == Int8 %}
    [[] of Int8, [0_i8, Int8::MAX], [] of Int8, [Int8::MIN, -1_i8], [0_i8, 1_i8], [Int8::MAX], [] of Int8] of Array(Int8)
  {% elsif T == Int16 %}
    [[] of Int16, [0_i16, Int16::MAX], [] of Int16, [Int16::MIN, -1_i16], [0_i16, 1_i16], [Int16::MAX], [] of Int16] of Array(Int16)
  {% elsif T == Int32 %}
    [[] of Int32, [0_i32, Int32::MAX], [] of Int32, [Int32::MIN, -1_i32], [0_i32, 1_i32], [Int32::MAX], [] of Int32] of Array(Int32)
  {% elsif T == Int64 %}
    [[] of Int64, [0_i64, Int64::MAX], [] of Int64, [Int64::MIN, -1_i64], [0_i64, 1_i64], [Int64::MAX], [] of Int64] of Array(Int64)
  {% elsif T == Float32 %}
    [[] of Float32, [0x8000_0000_u32.unsafe_as(Float32), 0x0000_0000_u32.unsafe_as(Float32), 0x7fc1_2345_u32.unsafe_as(Float32), 0x7f7f_ffff_u32.unsafe_as(Float32), 0x7f80_0000_u32.unsafe_as(Float32)], [] of Float32, [0xff7f_ffff_u32.unsafe_as(Float32), 0xff80_0000_u32.unsafe_as(Float32)], [0x3fc0_0000_u32.unsafe_as(Float32), 0xc010_0000_u32.unsafe_as(Float32)], [0x0000_0001_u32.unsafe_as(Float32), 0x8000_0001_u32.unsafe_as(Float32)], [] of Float32] of Array(Float32)
  {% else %}
    [[] of Float64, [0x8000_0000_0000_0000_u64.unsafe_as(Float64), 0x0000_0000_0000_0000_u64.unsafe_as(Float64), 0x7ff8_0000_0000_1234_u64.unsafe_as(Float64), 0x7fef_ffff_ffff_ffff_u64.unsafe_as(Float64), 0x7ff0_0000_0000_0000_u64.unsafe_as(Float64)], [] of Float64, [0xffef_ffff_ffff_ffff_u64.unsafe_as(Float64), 0xfff0_0000_0000_0000_u64.unsafe_as(Float64)], [0x3ff8_0000_0000_0000_u64.unsafe_as(Float64), 0xc002_0000_0000_0000_u64.unsafe_as(Float64)], [0x0000_0000_0000_0001_u64.unsafe_as(Float64), 0x8000_0000_0000_0001_u64.unsafe_as(Float64)], [] of Float64] of Array(Float64)
  {% end %}
end

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("CLICKHOUSE_STORE")
root = ENV.fetch("ORACLE_ROOT")
keys = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]
selected = keys.each_with_index.compact_map { |key, index| index.to_i32 if key >= 2_u64 && key < 11_u64 }.to_a
u8 = expected_values(UInt8)
u16 = expected_values(UInt16)
u32 = expected_values(UInt32)
u64 = expected_values(UInt64)
i8 = expected_values(Int8)
i16 = expected_values(Int16)
i32 = expected_values(Int32)
i64 = expected_values(Int64)
f32 = expected_values(Float32)
f64 = expected_values(Float64)

stock_schema = <<-SQL
pk UInt64,
arr_u8 Array(UInt8), arr_u16 Array(UInt16), arr_u32 Array(UInt32), arr_u64 Array(UInt64),
arr_i8 Array(Int8), arr_i16 Array(Int16), arr_i32 Array(Int32), arr_i64 Array(Int64),
arr_f32 Array(Float32), arr_f64 Array(Float64)
SQL
attach_part(binary, store, "array_numeric_stock", stock_schema, ENV.fetch("STOCK_PART"))
stock_select = "pk, arr_u8, arr_u16, arr_u32, arr_u64, arr_i8, arr_i16, arr_i32, arr_i64, arr_f32, arr_f64"
stock_full = oracle_clickhouse(binary, store, "SELECT #{stock_select} FROM default.array_numeric_stock ORDER BY pk FORMAT RowBinary")
assert_rowbinary(stock_full, expected_stock_rowbinary(keys, u8, u16, u32, u64, i8, i16, i32, i64, f32, f64, (0...keys.size).map(&.to_i32)), "stock full")
stock_range = oracle_clickhouse(binary, store, "SELECT #{stock_select} FROM default.array_numeric_stock WHERE pk >= 2 AND pk < 11 ORDER BY pk FORMAT RowBinary")
assert_rowbinary(stock_range, expected_stock_rowbinary(keys, u8, u16, u32, u64, i8, i16, i32, i64, f32, f64, selected), "stock range")

verify_writer(binary, store, root, "u8", UInt8, u8, keys, selected)
verify_writer(binary, store, root, "u16", UInt16, u16, keys, selected)
verify_writer(binary, store, root, "u32", UInt32, u32, keys, selected)
verify_writer(binary, store, root, "u64", UInt64, u64, keys, selected)
verify_writer(binary, store, root, "i8", Int8, i8, keys, selected)
verify_writer(binary, store, root, "i16", Int16, i16, keys, selected)
verify_writer(binary, store, root, "i32", Int32, i32, keys, selected)
verify_writer(binary, store, root, "i64", Int64, i64, keys, selected)
verify_writer(binary, store, root, "f32", Float32, f32, keys, selected)
verify_writer(binary, store, root, "f64", Float64, f64, keys, selected)

puts "Array(T) numeric bidirectional stock oracle passed: stock/writer attach, CHECK TABLE, exact full/range RowBinary for 10 leaves"
