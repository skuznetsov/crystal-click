require "file_utils"
require "./../src/crystal_click"

W40_ORACLE_KEYS       = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]
W40_ORACLE_RANGE_ROWS = [2_i32, 3_i32, 4_i32]
W40_ORACLE_ALL_ROWS   = [0_i32, 1_i32, 2_i32, 3_i32, 4_i32, 5_i32, 6_i32]

# These raw integer codes are intentionally independent of CrystalClick's part
# reader and writer. They are the expected scalar values for the stock fixture.
W40_DATE = [
  [] of UInt16, [0_u16, 1_u16], [UInt16::MAX], [] of UInt16,
  [42_u16, 0_u16], [UInt16::MAX], [] of UInt16,
] of Array(UInt16)
W40_DATE32 = [
  [] of Int32, [-1_i32, 1_i32], [-25_567_i32], [] of Int32,
  [-25_567_i32, 24_854_i32], [-1_i32], [] of Int32,
] of Array(Int32)
W40_DATETIME = [
  [] of UInt32, [0_u32, 1_u32], [UInt32::MAX], [] of UInt32,
  [0_u32, UInt32::MAX], [1_u32], [] of UInt32,
] of Array(UInt32)
W40_DATETIME64 = [
  [] of Int64, [-1_i64, 1_000_i64], [Int64::MAX], [] of Int64,
  [Int64::MIN, Int64::MAX], [-1_i64], [] of Int64,
] of Array(Int64)
W40_DATE32_WRITER = [
  [] of Int32, [-1_i32, 1_i32], [-25_567_i32], [] of Int32,
  [Int32::MIN, Int32::MAX], [-1_i32], [] of Int32,
] of Array(Int32)

W40_NULLABLE_DATE = [
  [] of UInt16?, [nil, 0_u16] of UInt16?, [1_u16] of UInt16?, [] of UInt16?,
  [nil, 0_u16] of UInt16?, [0_u16] of UInt16?, [] of UInt16?,
] of Array(UInt16?)
W40_NULLABLE_DATE32 = [
  [] of Int32?, [nil, -1_i32] of Int32?, [0_i32] of Int32?, [] of Int32?,
  [nil, 0_i32] of Int32?, [-1_i32] of Int32?, [] of Int32?,
] of Array(Int32?)
W40_NULLABLE_DATETIME = [
  [] of UInt32?, [nil, 0_u32] of UInt32?, [1_u32] of UInt32?, [] of UInt32?,
  [nil, 0_u32] of UInt32?, [0_u32] of UInt32?, [] of UInt32?,
] of Array(UInt32?)
W40_NULLABLE_DATETIME64 = [
  [] of Int64?, [nil, -1_i64] of Int64?, [0_i64] of Int64?, [] of Int64?,
  [nil, -1_i64] of Int64?, [Int64::MIN] of Int64?, [] of Int64?,
] of Array(Int64?)

def w40_oracle_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  result = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (#{result.exit_code}): #{query}" unless result.success?
  output.to_s
end

def w40_append_u64_le(io : IO, value : UInt64) : Nil
  8.times { |byte| io.write_byte(((value >> (byte * 8)) & 0xff_u64).to_u8) }
end

def w40_append_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

def w40_append_scalar_le(io : IO, value : T) : Nil forall T
  {% if T == UInt16 || T == Int16 %}
    bits = value.unsafe_as(UInt16).to_u64
    2.times { |byte| io.write_byte(((bits >> (byte * 8)) & 0xff_u64).to_u8) }
  {% elsif T == UInt32 || T == Int32 %}
    bits = value.unsafe_as(UInt32).to_u64
    4.times { |byte| io.write_byte(((bits >> (byte * 8)) & 0xff_u64).to_u8) }
  {% elsif T == UInt64 || T == Int64 %}
    bits = value.unsafe_as(UInt64)
    8.times { |byte| io.write_byte(((bits >> (byte * 8)) & 0xff_u64).to_u8) }
  {% else %}
    {% raise "unsupported W40 temporal scalar" %}
  {% end %}
end

def w40_append_array(io : IO, values : Array(T)) : Nil forall T
  w40_append_varuint(io, values.size.to_u64)
  values.each { |value| w40_append_scalar_le(io, value) }
end

def w40_append_nullable_array(io : IO, values : Array(T?)) : Nil forall T
  w40_append_varuint(io, values.size.to_u64)
  values.each do |value|
    if value.nil?
      # Nullable RowBinary stores the null marker and no child payload.
      io.write_byte(1_u8)
    else
      io.write_byte(0_u8)
      w40_append_scalar_le(io, value.not_nil!)
    end
  end
end

def w40_expected_single_array(keys : Array(UInt64), values : Array(Array(T)), selected : Array(Int32)) : Bytes forall T
  io = IO::Memory.new
  selected.each do |row|
    w40_append_u64_le(io, keys[row])
    w40_append_array(io, values[row])
  end
  io.to_slice
end

def w40_expected_single_nullable_array(keys : Array(UInt64), values : Array(Array(T?)), selected : Array(Int32)) : Bytes forall T
  io = IO::Memory.new
  selected.each do |row|
    w40_append_u64_le(io, keys[row])
    w40_append_nullable_array(io, values[row])
  end
  io.to_slice
end

def w40_expected_stock_rowbinary(selected : Array(Int32)) : Bytes
  io = IO::Memory.new
  selected.each do |row|
    w40_append_u64_le(io, W40_ORACLE_KEYS[row])
    w40_append_array(io, W40_DATE[row])
    w40_append_array(io, W40_DATE32[row])
    w40_append_array(io, W40_DATETIME[row])
    w40_append_array(io, W40_DATETIME64[row])
    w40_append_nullable_array(io, W40_NULLABLE_DATE[row])
    w40_append_nullable_array(io, W40_NULLABLE_DATE32[row])
    w40_append_nullable_array(io, W40_NULLABLE_DATETIME[row])
    w40_append_nullable_array(io, W40_NULLABLE_DATETIME64[row])
  end
  io.to_slice
end

def w40_assert_rowbinary(actual : String, expected : Bytes, label : String) : Nil
  unless actual.to_slice == expected
    actual_bytes = actual.to_slice
    shared = Math.min(actual_bytes.size, expected.size)
    first_difference = 0
    while first_difference < shared && actual_bytes[first_difference] == expected[first_difference]
      first_difference += 1
    end
    wanted = first_difference < expected.size ? expected[first_difference].to_s(16).rjust(2, '0') : "<eof>"
    observed = first_difference < actual_bytes.size ? actual_bytes[first_difference].to_s(16).rjust(2, '0') : "<eof>"
    raise "#{label} RowBinary mismatch: expected #{expected.size} bytes, got #{actual.bytesize}; first difference at byte #{first_difference}: expected #{wanted}, got #{observed}"
  end
end

def w40_attach_part(binary : String, store : String, table : String, schema : String, part : String) : Nil
  w40_oracle_clickhouse(binary, store, <<-SQL)
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
  data_path = w40_oracle_clickhouse(
    binary,
    store,
    "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{table}' FORMAT TSVRaw"
  ).strip
  raise "no ClickHouse data path for #{table}" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  w40_oracle_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  integrity = w40_oracle_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "CHECK TABLE failed for #{table}: #{integrity.inspect}" unless integrity == "all_1_1_0\t1"
  puts "CHECK TABLE #{table}: all_1_1_0\t1"
end

def w40_check_full_and_keyed(binary : String, store : String, table : String, columns : String, full : Bytes, keyed : Bytes) : Nil
  full_actual = w40_oracle_clickhouse(binary, store, "SELECT pk, #{columns} FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  w40_assert_rowbinary(full_actual, full, "#{table} full")
  keyed_actual = w40_oracle_clickhouse(binary, store, "SELECT pk, #{columns} FROM default.#{table} WHERE pk >= 4 AND pk < 11 ORDER BY pk FORMAT RowBinary")
  w40_assert_rowbinary(keyed_actual, keyed, "#{table} keyed")
  puts "RowBinary #{table}: full #{full.size} bytes exact; keyed #{keyed.size} bytes exact"
end

def w40_write_plain(destination : String, values : Array(Array(T)), scale : Int32) : String forall T
  keys = W40_ORACLE_KEYS
  {% if T == UInt16 %}
    CrystalClick::WidePartWriter.write_uint64_array_date_pair(destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", values.to_unsafe.to_slice(values.size), rows_per_mark: 2)
  {% elsif T == Int32 %}
    CrystalClick::WidePartWriter.write_uint64_array_date32_pair(destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", values.to_unsafe.to_slice(values.size), rows_per_mark: 2)
  {% elsif T == UInt32 %}
    CrystalClick::WidePartWriter.write_uint64_array_datetime_pair(destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", values.to_unsafe.to_slice(values.size), rows_per_mark: 2)
  {% elsif T == Int64 %}
    CrystalClick::WidePartWriter.write_uint64_array_datetime64_pair(destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", values.to_unsafe.to_slice(values.size), scale, rows_per_mark: 2)
  {% else %}
    {% raise "unsupported W40 plain writer scalar" %}
  {% end %}
end

def w40_write_nullable(destination : String, values : Array(Array(T?)), scale : Int32) : String forall T
  keys = W40_ORACLE_KEYS
  w40_write_nullable_layout(destination, keys, values, scale, 2)
end

def w40_write_nullable_layout(destination : String, keys : Array(UInt64), values : Array(Array(T?)), scale : Int32, rows_per_mark : Int32) : String forall T
  key_slice = keys.to_unsafe.to_slice(keys.size)
  value_slice = values.to_unsafe.to_slice(values.size)
  {% if T == UInt16 %}
    CrystalClick::WidePartWriter.write_uint64_array_nullable_date_pair(destination, "pk", key_slice, "payload", value_slice, rows_per_mark: rows_per_mark)
  {% elsif T == Int32 %}
    CrystalClick::WidePartWriter.write_uint64_array_nullable_date32_pair(destination, "pk", key_slice, "payload", value_slice, rows_per_mark: rows_per_mark)
  {% elsif T == UInt32 %}
    CrystalClick::WidePartWriter.write_uint64_array_nullable_datetime_pair(destination, "pk", key_slice, "payload", value_slice, rows_per_mark: rows_per_mark)
  {% elsif T == Int64 %}
    CrystalClick::WidePartWriter.write_uint64_array_nullable_datetime64_pair(destination, "pk", key_slice, "payload", value_slice, scale, rows_per_mark: rows_per_mark)
  {% else %}
    {% raise "unsupported W40 nullable writer scalar" %}
  {% end %}
end

def w40_verify_plain_writer(binary : String, store : String, root : String, name : String, declaration : String, values : Array(Array(T)), scale : Int32 = 3) : Nil forall T
  part = File.join(root, "writer-#{name}-#{scale}")
  w40_write_plain(part, values, scale)
  table = "array_temporal_writer_#{name}_#{scale}"
  w40_attach_part(binary, store, table, "pk UInt64, payload Array(#{declaration})", part)
  w40_check_full_and_keyed(
    binary, store, table, "payload",
    w40_expected_single_array(W40_ORACLE_KEYS, values, W40_ORACLE_ALL_ROWS),
    w40_expected_single_array(W40_ORACLE_KEYS, values, W40_ORACLE_RANGE_ROWS),
  )
end

def w40_verify_nullable_writer(binary : String, store : String, root : String, name : String, declaration : String, values : Array(Array(T?)), scale : Int32 = 3) : Nil forall T
  part = File.join(root, "writer-nullable-#{name}-#{scale}")
  w40_write_nullable(part, values, scale)
  table = "array_nullable_temporal_writer_#{name}_#{scale}"
  w40_attach_part(binary, store, table, "pk UInt64, payload Array(Nullable(#{declaration}))", part)
  w40_check_full_and_keyed(
    binary, store, table, "payload",
    w40_expected_single_nullable_array(W40_ORACLE_KEYS, values, W40_ORACLE_ALL_ROWS),
    w40_expected_single_nullable_array(W40_ORACLE_KEYS, values, W40_ORACLE_RANGE_ROWS),
  )
end

def w40_verify_nullable_edge_writer(binary : String, store : String, root : String, name : String, declaration : String, keys : Array(UInt64), values : Array(Array(T?)), scale : Int32 = 3) : Nil forall T
  part = File.join(root, "writer-nullable-edge-#{name}-#{scale}")
  w40_write_nullable_layout(part, keys, values, scale, 1)
  table = "array_nullable_temporal_edge_#{name}_#{scale}"
  w40_attach_part(binary, store, table, "pk UInt64, payload Array(Nullable(#{declaration}))", part)
  w40_check_full_and_keyed(
    binary, store, table, "payload",
    w40_expected_single_nullable_array(keys, values, [0_i32, 1_i32, 2_i32, 3_i32]),
    w40_expected_single_nullable_array(keys, values, [2_i32, 3_i32]),
  )
end

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("CLICKHOUSE_STORE")
root = ENV.fetch("ORACLE_ROOT")
stock_part = ENV.fetch("STOCK_PART")

stock_schema = <<-SCHEMA
  pk UInt64,
  a_date Array(Date),
  a_date32 Array(Date32),
  a_datetime Array(DateTime),
  a_datetime64 Array(DateTime64(3)),
  n_date Array(Nullable(Date)),
  n_date32 Array(Nullable(Date32)),
  n_datetime Array(Nullable(DateTime)),
  n_datetime64 Array(Nullable(DateTime64(3)))
  SCHEMA
w40_attach_part(binary, store, "array_temporal_stock", stock_schema, stock_part)
stock_columns = "a_date, a_date32, a_datetime, a_datetime64, n_date, n_date32, n_datetime, n_datetime64"
w40_check_full_and_keyed(
  binary, store, "array_temporal_stock", stock_columns,
  w40_expected_stock_rowbinary(W40_ORACLE_ALL_ROWS),
  w40_expected_stock_rowbinary(W40_ORACLE_RANGE_ROWS),
)

w40_verify_plain_writer(binary, store, root, "date", "Date", W40_DATE)
w40_verify_plain_writer(binary, store, root, "date32", "Date32", W40_DATE32_WRITER)
w40_verify_plain_writer(binary, store, root, "datetime", "DateTime", W40_DATETIME)
w40_verify_plain_writer(binary, store, root, "datetime64", "DateTime64(0)", W40_DATETIME64, 0)
w40_verify_plain_writer(binary, store, root, "datetime64", "DateTime64(3)", W40_DATETIME64, 3)
w40_verify_plain_writer(binary, store, root, "datetime64", "DateTime64(9)", W40_DATETIME64, 9)

w40_verify_nullable_writer(binary, store, root, "date", "Date", W40_NULLABLE_DATE)
w40_verify_nullable_writer(binary, store, root, "date32", "Date32", W40_NULLABLE_DATE32)
w40_verify_nullable_writer(binary, store, root, "datetime", "DateTime", W40_NULLABLE_DATETIME)
w40_verify_nullable_writer(binary, store, root, "datetime64", "DateTime64(0)", W40_NULLABLE_DATETIME64, 0)
w40_verify_nullable_writer(binary, store, root, "datetime64", "DateTime64(3)", W40_NULLABLE_DATETIME64, 3)
w40_verify_nullable_writer(binary, store, root, "datetime64", "DateTime64(9)", W40_NULLABLE_DATETIME64, 9)

edge_keys = [1_u64, 2_u64, 4_u64, 6_u64]
nullable_date_edges = [
  [nil, nil] of UInt16?, [] of UInt16?, [0_u16, 1_u16] of UInt16?, [UInt16::MAX, 0_u16] of UInt16?,
] of Array(UInt16?)
nullable_datetime64_edges = [
  [nil, nil] of Int64?, [] of Int64?, [Int64::MIN, -1_i64, 0_i64, Int64::MAX] of Int64?, [-1_i64, 1_i64] of Int64?,
] of Array(Int64?)
w40_verify_nullable_edge_writer(binary, store, root, "date", "Date", edge_keys, nullable_date_edges)
w40_verify_nullable_edge_writer(binary, store, root, "datetime64", "DateTime64(3)", edge_keys, nullable_datetime64_edges, 3)

puts "Temporal Array bidirectional stock oracle passed: stock and writer parts attached, CHECK TABLE passed, exact full/keyed RowBinary for 8 semantic shapes and DateTime64 scales 0/3/9"
