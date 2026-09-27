require "file_utils"
require "./../src/crystal_click"

alias W42_Rows = Array(Array(Int32))
alias W42_NullableRows = Array(Array(Int32?))

W42_KEYS       = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]
W42_ALL_ROWS   = [0_i32, 1_i32, 2_i32, 3_i32, 4_i32, 5_i32, 6_i32]
W42_KEYED_ROWS = [2_i32, 3_i32, 4_i32]
W42_PLAIN      = [
  [] of Int32,
  [-1234_i32, 0_i32, 9999_i32],
  [-999_999_999_i32, 1_i32],
  [] of Int32,
  [-123_i32],
  [1234_i32, -1_i32],
  [] of Int32,
] of Array(Int32)
W42_NULLABLE = [
  [] of Int32?,
  [nil, 0_i32, -5_i32] of Int32?,
  [nil, 123_i32] of Int32?,
  [] of Int32?,
  [-100_i32, nil] of Int32?,
  [0_i32, nil] of Int32?,
  [] of Int32?,
] of Array(Int32?)
W42_EMPTY_PLAIN    = Array.new(W42_KEYS.size) { [] of Int32 }
W42_EMPTY_NULLABLE = Array.new(W42_KEYS.size) { [] of Int32? }
W42_ALL_NULL       = [
  [] of Int32?, [nil] of Int32?, [nil, nil] of Int32?, [] of Int32?,
  [nil] of Int32?, [nil, nil] of Int32?, [] of Int32?,
] of Array(Int32?)

def w42_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  result = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (#{result.exit_code}): #{query}" unless result.success?
  output.to_s
end

def w42_append_u64_le(io : IO, value : UInt64) : Nil
  8.times { |byte| io.write_byte(((value >> (byte * 8)) & 0xff_u64).to_u8) }
end

def w42_append_i32_le(io : IO, value : Int32) : Nil
  bits = value.unsafe_as(UInt32)
  4.times { |byte| io.write_byte(((bits >> (byte * 8)) & 0xff_u32).to_u8) }
end

def w42_append_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

def w42_append_array(io : IO, values : Array(Int32)) : Nil
  w42_append_varuint(io, values.size.to_u64)
  values.each { |value| w42_append_i32_le(io, value) }
end

def w42_append_nullable_array(io : IO, values : Array(Int32?)) : Nil
  w42_append_varuint(io, values.size.to_u64)
  values.each do |value|
    if value.nil?
      io.write_byte(1_u8)
    else
      io.write_byte(0_u8)
      w42_append_i32_le(io, value.not_nil!)
    end
  end
end

def w42_expected_stock(selected : Array(Int32)) : Bytes
  io = IO::Memory.new
  selected.each do |row|
    w42_append_u64_le(io, W42_KEYS[row])
    w42_append_array(io, W42_PLAIN[row])
    w42_append_nullable_array(io, W42_NULLABLE[row])
  end
  io.to_slice
end

def w42_expected_plain(keys : Array(UInt64), values : W42_Rows, selected : Array(Int32)) : Bytes
  io = IO::Memory.new
  selected.each do |row|
    w42_append_u64_le(io, keys[row])
    w42_append_array(io, values[row])
  end
  io.to_slice
end

def w42_expected_nullable(keys : Array(UInt64), values : W42_NullableRows, selected : Array(Int32)) : Bytes
  io = IO::Memory.new
  selected.each do |row|
    w42_append_u64_le(io, keys[row])
    w42_append_nullable_array(io, values[row])
  end
  io.to_slice
end

def w42_assert_rowbinary(actual : String, expected : Bytes, label : String) : Nil
  actual_bytes = actual.to_slice
  return if actual_bytes == expected

  shared = Math.min(actual_bytes.size, expected.size)
  first_difference = 0
  while first_difference < shared && actual_bytes[first_difference] == expected[first_difference]
    first_difference += 1
  end
  wanted = first_difference < expected.size ? expected[first_difference].to_s(16).rjust(2, '0') : "<eof>"
  observed = first_difference < actual_bytes.size ? actual_bytes[first_difference].to_s(16).rjust(2, '0') : "<eof>"
  raise "#{label} RowBinary mismatch: expected #{expected.size} bytes, got #{actual.bytesize}; first difference at byte #{first_difference}: expected #{wanted}, got #{observed}"
end

def w42_attach_part(binary : String, store : String, table : String, schema : String, part : String) : Nil
  w42_clickhouse(binary, store, <<-SQL)
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
  data_path = w42_clickhouse(
    binary,
    store,
    "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{table}' FORMAT TSVRaw"
  ).strip
  raise "no ClickHouse data path for #{table}" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  w42_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  integrity = w42_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "CHECK TABLE failed for #{table}: #{integrity.inspect}" unless integrity == "all_1_1_0\t1"
  puts "CHECK TABLE #{table}: all_1_1_0\t1"
end

def w42_check_rows(binary : String, store : String, table : String, columns : String, full : Bytes, keyed : Bytes) : Nil
  full_actual = w42_clickhouse(binary, store, "SELECT pk, #{columns} FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  w42_assert_rowbinary(full_actual, full, "#{table} full")
  keyed_actual = w42_clickhouse(binary, store, "SELECT pk, #{columns} FROM default.#{table} WHERE pk >= 4 AND pk < 11 ORDER BY pk FORMAT RowBinary")
  w42_assert_rowbinary(keyed_actual, keyed, "#{table} keyed")
  puts "RowBinary #{table}: full #{full.size} bytes exact; keyed #{keyed.size} bytes exact"
end

def w42_decoded_stream(part : String, logical_name : String) : Bytes
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.bin")
  raise "missing writer stream #{logical_name}" unless File.file?(path)
  encoded = File.read(path).to_slice
  encoded.empty? ? Bytes.new(0) : CrystalClick::CompressedBlock.decode_all(encoded)
end

def w42_verify_plain_writer(binary : String, store : String, root : String, suffix : String, values : W42_Rows, scale : Int32 = 2_i32) : Nil
  part = File.join(root, "writer-plain-#{suffix}")
  CrystalClick::WidePartWriter.write_uint64_array_decimal32_pair(
    part, "pk", W42_KEYS.to_unsafe.to_slice(W42_KEYS.size), "payload",
    values.to_unsafe.to_slice(values.size), scale, 2_i32
  )
  reader = CrystalClick::WidePart.open_typed(part, "payload")
  raise "writer Decimal32 scale metadata mismatch for #{suffix}" unless reader.column_type == "Array(Decimal(9, #{scale}))"
  raise "writer Decimal32 raw coefficients changed for #{suffix}" unless reader.read_array_decimal32_raw_mark_range("payload", 0, reader.mark_count) == values
  table = "array_decimal32_plain_#{suffix}"
  w42_attach_part(binary, store, table, "pk UInt64, payload Array(Decimal(9, #{scale}))", part)
  w42_check_rows(
    binary, store, table, "payload",
    w42_expected_plain(W42_KEYS, values, W42_ALL_ROWS),
    w42_expected_plain(W42_KEYS, values, W42_KEYED_ROWS),
  )
end

def w42_verify_nullable_writer(binary : String, store : String, root : String, suffix : String, values : W42_NullableRows) : Nil
  part = File.join(root, "writer-nullable-#{suffix}")
  CrystalClick::WidePartWriter.write_uint64_array_nullable_decimal32_pair(
    part, "pk", W42_KEYS.to_unsafe.to_slice(W42_KEYS.size), "payload",
    values.to_unsafe.to_slice(values.size), 2_i32, 2_i32
  )

  if suffix == "all_empty"
    nested = w42_decoded_stream(part, "payload")
    null_map = w42_decoded_stream(part, "payload.null")
    raise "all-empty Nullable(Decimal32) child stream must be empty" unless nested.empty? && null_map.empty?
  elsif suffix == "all_null"
    leaf_count = values.sum(&.size)
    null_map = w42_decoded_stream(part, "payload.null")
    nested = w42_decoded_stream(part, "payload")
    raise "all-null control contains a non-NULL leaf" unless values.all? { |row| row.all?(&.nil?) }
    raise "all-null Nullable(Decimal32) null map differs" unless null_map == Bytes.new(leaf_count, 1_u8)
    raise "all-null Nullable(Decimal32) nested slots are not four zero bytes each" unless nested == Bytes.new(4 * leaf_count, 0_u8)
  end

  table = "array_decimal32_nullable_#{suffix}"
  w42_attach_part(binary, store, table, "pk UInt64, payload Array(Nullable(Decimal(9, 2)))", part)
  w42_check_rows(
    binary, store, table, "payload",
    w42_expected_nullable(W42_KEYS, values, W42_ALL_ROWS),
    w42_expected_nullable(W42_KEYS, values, W42_KEYED_ROWS),
  )
end

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("CLICKHOUSE_STORE")
root = ENV.fetch("ORACLE_ROOT")
stock_part = ENV.fetch("STOCK_PART")

w42_attach_part(
  binary, store, "array_decimal32_stock",
  "pk UInt64, plain Array(Decimal(9, 2)), maybe Array(Nullable(Decimal(9, 2)))",
  stock_part
)
w42_check_rows(
  binary, store, "array_decimal32_stock", "plain, maybe",
  w42_expected_stock(W42_ALL_ROWS), w42_expected_stock(W42_KEYED_ROWS),
)

# Ensure the test payload really distinguishes a null element from its nested
# zero-width value and from a non-NULL zero Decimal coefficient.
raise "non-NULL zero discriminator missing" unless W42_NULLABLE[1] == [nil, 0_i32, -5_i32]
io = IO::Memory.new
w42_append_nullable_array(io, W42_NULLABLE[1])
raise "RowBinary Nullable(Decimal32) null-slot layout changed" unless io.to_slice.hexstring == "0301000000000000fbffffff"

w42_verify_plain_writer(binary, store, root, "mixed", W42_PLAIN)
w42_verify_nullable_writer(binary, store, root, "mixed", W42_NULLABLE)
w42_verify_plain_writer(binary, store, root, "all_empty", W42_EMPTY_PLAIN)
w42_verify_nullable_writer(binary, store, root, "all_empty", W42_EMPTY_NULLABLE)
w42_verify_nullable_writer(binary, store, root, "all_null", W42_ALL_NULL)

# Decimal(9, 9) SQL literals cannot represent these out-of-precision raw
# coefficients. Exercise the Crystal-generated part at stock attach/check/query
# boundaries and compare RowBinary against the signed Int32 raw-byte oracle.
extreme_rows = [
  [0_i32], [-1_i32], [Int32::MIN, 0_i32], [] of Int32,
  [Int32::MAX], [-100_i32, 1_i32], [] of Int32,
] of Array(Int32)
w42_verify_plain_writer(binary, store, root, "extreme_scale_9", extreme_rows, 9_i32)

puts "Decimal32 Array bidirectional stock oracle passed: pinned stock and writer ATTACH, CHECK TABLE, full/keyed RowBinary; empty/null controls; raw Int32 boundaries"
