require "file_utils"
require "./../src/crystal_click"

alias W45_Rows = Array(Array(CrystalClick::Decimal256Value))
alias W45_NullableRows = Array(Array(CrystalClick::Decimal256Value?))

W45_KEYS       = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]
W45_ALL_ROWS   = [0_i32, 1_i32, 2_i32, 3_i32, 4_i32, 5_i32, 6_i32]
W45_KEYED_ROWS = [2_i32, 3_i32, 4_i32]

def w45_decimal_coefficient(text : String) : CrystalClick::Decimal256Value
  negative = text.starts_with?('-')
  digits = negative ? text[1..] : text
  words = [0_u64, 0_u64, 0_u64, 0_u64]
  digits.each_char do |character|
    raise "not a decimal coefficient: #{text}" unless character.ascii_number?
    carry = (character.ord - '0'.ord).to_u128
    4.times do |index|
      product = words[index].to_u128 * 10_u128 + carry
      words[index] = (product & UInt64::MAX.to_u128).to_u64
      carry = product >> 64
    end
    raise "Decimal256 coefficient overflow: #{text}" unless carry == 0
  end
  if negative
    carry = true
    4.times do |index|
      inverted = ~words[index]
      if carry && inverted == UInt64::MAX
        words[index] = 0_u64
      elsif carry
        words[index] = inverted + 1_u64
        carry = false
      else
        words[index] = inverted
      end
    end
  end
  CrystalClick::Decimal256Value.from_words(words[0], words[1], words[2], words[3])
end

W45_DECIMAL_MAX     = w45_decimal_coefficient("9" * 76)
W45_NEG_DECIMAL_MAX = w45_decimal_coefficient("-" + "9" * 76)
W45_NEG_123         = w45_decimal_coefficient("-123")

W45_STOCK_PLAIN = [
  [] of CrystalClick::Decimal256Value,
  [w45_decimal_coefficient("-1234"), w45_decimal_coefficient("0"), w45_decimal_coefficient("9999")],
  [W45_NEG_DECIMAL_MAX, w45_decimal_coefficient("1")],
  [] of CrystalClick::Decimal256Value,
  [w45_decimal_coefficient("-123")],
  [w45_decimal_coefficient("1234"), w45_decimal_coefficient("-1")],
  [] of CrystalClick::Decimal256Value,
] of Array(CrystalClick::Decimal256Value)

W45_STOCK_NULLABLE = [
  [] of CrystalClick::Decimal256Value?,
  [nil, w45_decimal_coefficient("0"), w45_decimal_coefficient("-5")] of CrystalClick::Decimal256Value?,
  [nil, w45_decimal_coefficient("123")] of CrystalClick::Decimal256Value?,
  [] of CrystalClick::Decimal256Value?,
  [nil, nil] of CrystalClick::Decimal256Value?,
  [w45_decimal_coefficient("0"), nil] of CrystalClick::Decimal256Value?,
  [] of CrystalClick::Decimal256Value?,
] of Array(CrystalClick::Decimal256Value?)

W45_RAW_MIN = CrystalClick::Decimal256Value.from_words(0_u64, 0_u64, 0_u64, 0x8000000000000000_u64)
W45_RAW_MAX = CrystalClick::Decimal256Value.from_words(UInt64::MAX, UInt64::MAX, UInt64::MAX, 0x7fffffffffffffff_u64)

W45_RAW_PLAIN = [
  [W45_RAW_MIN, w45_decimal_coefficient("-1"), w45_decimal_coefficient("0"), w45_decimal_coefficient("1"), W45_RAW_MAX],
  [] of CrystalClick::Decimal256Value,
  [W45_NEG_DECIMAL_MAX, W45_DECIMAL_MAX],
  [] of CrystalClick::Decimal256Value,
  [w45_decimal_coefficient("-123")],
  [w45_decimal_coefficient("0"), w45_decimal_coefficient("1")],
  [] of CrystalClick::Decimal256Value,
] of Array(CrystalClick::Decimal256Value)

W45_RAW_NULLABLE = [
  [nil, W45_RAW_MIN, w45_decimal_coefficient("0"), W45_RAW_MAX] of CrystalClick::Decimal256Value?,
  [nil, nil] of CrystalClick::Decimal256Value?,
  [nil, w45_decimal_coefficient("-1"), w45_decimal_coefficient("0")] of CrystalClick::Decimal256Value?,
  [] of CrystalClick::Decimal256Value?,
  [W45_NEG_DECIMAL_MAX, nil] of CrystalClick::Decimal256Value?,
  [w45_decimal_coefficient("0"), nil] of CrystalClick::Decimal256Value?,
  [] of CrystalClick::Decimal256Value?,
] of Array(CrystalClick::Decimal256Value?)

W45_VALID_PLAIN = [
  [W45_NEG_DECIMAL_MAX, w45_decimal_coefficient("-1"), w45_decimal_coefficient("0"), w45_decimal_coefficient("1"), W45_DECIMAL_MAX],
  [] of CrystalClick::Decimal256Value,
  [w45_decimal_coefficient("-1234567890123456789012345678901234567890123456789012345678901234567890123456"),
   w45_decimal_coefficient("1234567890123456789012345678901234567890123456789012345678901234567890123456")],
  [] of CrystalClick::Decimal256Value,
  [w45_decimal_coefficient("-123")],
  [w45_decimal_coefficient("0"), w45_decimal_coefficient("1")],
  [] of CrystalClick::Decimal256Value,
] of Array(CrystalClick::Decimal256Value)

W45_VALID_NULLABLE = [
  [nil, W45_NEG_DECIMAL_MAX, w45_decimal_coefficient("0"), W45_DECIMAL_MAX] of CrystalClick::Decimal256Value?,
  [nil, nil] of CrystalClick::Decimal256Value?,
  [nil, w45_decimal_coefficient("-1"), w45_decimal_coefficient("0")] of CrystalClick::Decimal256Value?,
  [] of CrystalClick::Decimal256Value?,
  [W45_NEG_123, nil] of CrystalClick::Decimal256Value?,
  [w45_decimal_coefficient("0"), nil] of CrystalClick::Decimal256Value?,
  [] of CrystalClick::Decimal256Value?,
] of Array(CrystalClick::Decimal256Value?)

W45_ALL_EMPTY_PLAIN    = Array.new(W45_KEYS.size) { [] of CrystalClick::Decimal256Value }
W45_ALL_EMPTY_NULLABLE = Array.new(W45_KEYS.size) { [] of CrystalClick::Decimal256Value? }
W45_ALL_NULL_NULLABLE  = Array.new(W45_KEYS.size) { [nil, nil] of CrystalClick::Decimal256Value? }

def w45_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (status #{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

def w45_append_u64_le(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
end

def w45_append_decimal256_le(io : IO, value : CrystalClick::Decimal256Value) : Nil
  16.times { |index| io.write_byte(((value.low >> (index * 8)) & 0xff_u128).to_u8) }
  16.times { |index| io.write_byte(((value.high >> (index * 8)) & 0xff_u128).to_u8) }
end

def w45_append_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

def w45_append_array(io : IO, values : Array(CrystalClick::Decimal256Value)) : Nil
  w45_append_varuint(io, values.size.to_u64)
  values.each { |value| w45_append_decimal256_le(io, value) }
end

def w45_append_nullable_array(io : IO, values : Array(CrystalClick::Decimal256Value?)) : Nil
  w45_append_varuint(io, values.size.to_u64)
  values.each do |value|
    if value.nil?
      io.write_byte(1_u8)
    else
      io.write_byte(0_u8)
      w45_append_decimal256_le(io, value.not_nil!)
    end
  end
end

def w45_expected_pair(keys : Array(UInt64), plain : W45_Rows, nullable : W45_NullableRows, selected : Array(Int32)) : Bytes
  output = IO::Memory.new
  selected.each do |row|
    w45_append_u64_le(output, keys[row])
    w45_append_array(output, plain[row])
    w45_append_nullable_array(output, nullable[row])
  end
  output.to_slice
end

def w45_expected_plain(keys : Array(UInt64), values : W45_Rows, selected : Array(Int32)) : Bytes
  output = IO::Memory.new
  selected.each do |row|
    w45_append_u64_le(output, keys[row])
    w45_append_array(output, values[row])
  end
  output.to_slice
end

def w45_expected_nullable(keys : Array(UInt64), values : W45_NullableRows, selected : Array(Int32)) : Bytes
  output = IO::Memory.new
  selected.each do |row|
    w45_append_u64_le(output, keys[row])
    w45_append_nullable_array(output, values[row])
  end
  output.to_slice
end

def w45_assert_bytes(actual : String, expected : Bytes, label : String) : Nil
  observed = actual.to_slice
  return if observed == expected
  shared = Math.min(observed.size, expected.size)
  offset = 0
  while offset < shared && observed[offset] == expected[offset]
    offset += 1
  end
  wanted = offset < expected.size ? expected[offset].to_s(16).rjust(2, '0') : "<eof>"
  got = offset < observed.size ? observed[offset].to_s(16).rjust(2, '0') : "<eof>"
  raise "#{label} RowBinary mismatch: expected #{expected.size} bytes, got #{observed.size}; first difference at byte #{offset}: expected #{wanted}, got #{got}"
end

def w45_attach_part(binary : String, store : String, table : String, schema : String, part : String) : Nil
  w45_clickhouse(binary, store, <<-SQL)
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

  data_path = w45_clickhouse(binary, store,
    "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{table}' FORMAT TSVRaw").strip
  raise "no ClickHouse data path for #{table}" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  w45_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  integrity = w45_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "CHECK TABLE failed for #{table}: #{integrity.inspect}" unless integrity == "all_1_1_0\t1"
  puts "CHECK TABLE #{table}: all_1_1_0\t1"
end

def w45_check_rows(binary : String, store : String, table : String, columns : String, full : Bytes, keyed : Bytes) : Nil
  actual_full = w45_clickhouse(binary, store, "SELECT pk, #{columns} FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  w45_assert_bytes(actual_full, full, "#{table} full")
  actual_keyed = w45_clickhouse(binary, store, "SELECT pk, #{columns} FROM default.#{table} WHERE pk >= 4 AND pk < 11 ORDER BY pk FORMAT RowBinary")
  w45_assert_bytes(actual_keyed, keyed, "#{table} keyed")
  puts "RowBinary #{table}: full #{full.size} bytes exact; keyed #{keyed.size} bytes exact"
end

def w45_attach_and_check_writer(binary : String, store : String, root : String, scale : Int32, plain : W45_Rows, nullable : W45_NullableRows, label : String) : Nil
  plain_part = File.join(root, "writer-#{label}-plain")
  CrystalClick::WidePartWriter.write_uint64_array_decimal256_pair(
    plain_part, "pk", W45_KEYS.to_unsafe.to_slice(W45_KEYS.size), "payload",
    plain.to_unsafe.to_slice(plain.size), scale, 2_i32
  )
  nullable_part = File.join(root, "writer-#{label}-nullable")
  CrystalClick::WidePartWriter.write_uint64_array_nullable_decimal256_pair(
    nullable_part, "pk", W45_KEYS.to_unsafe.to_slice(W45_KEYS.size), "payload",
    nullable.to_unsafe.to_slice(nullable.size), scale, 2_i32
  )
  raise "writer failed self-read for #{label}" unless CrystalClick::WidePart.open_typed(plain_part, "payload")
                                                        .read_array_decimal256_raw_mark_range("payload", 0, 4) == plain
  raise "nullable writer failed self-read for #{label}" unless CrystalClick::WidePart.open_typed(nullable_part, "payload")
                                                                 .read_array_nullable_decimal256_raw_mark_range("payload", 0, 4) == nullable

  canonical = "Decimal(76, #{scale})"
  nullable_type = "Nullable(#{canonical})"
  plain_table = "array_decimal256_#{label}_plain"
  w45_attach_part(binary, store, plain_table, "pk UInt64, payload Array(#{canonical})", plain_part)
  w45_check_rows(binary, store, plain_table, "payload",
    w45_expected_plain(W45_KEYS, plain, W45_ALL_ROWS),
    w45_expected_plain(W45_KEYS, plain, W45_KEYED_ROWS))
  nullable_table = "array_decimal256_#{label}_nullable"
  w45_attach_part(binary, store, nullable_table, "pk UInt64, payload Array(#{nullable_type})", nullable_part)
  w45_check_rows(binary, store, nullable_table, "payload",
    w45_expected_nullable(W45_KEYS, nullable, W45_ALL_ROWS),
    w45_expected_nullable(W45_KEYS, nullable, W45_KEYED_ROWS))
end

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("CLICKHOUSE_STORE")
root = ENV.fetch("ORACLE_ROOT")
stock_part = ENV.fetch("STOCK_PART")

stock_reader = CrystalClick::WidePart.open_typed(stock_part, "plain")
raise "stock fixture canonical Decimal256 Array type differs" unless stock_reader.column_type == "Array(Decimal(76, 2))"
raise "stock fixture rows-per-mark differ" unless stock_reader.mark_row_counts == [2_u64, 2_u64, 2_u64, 1_u64]
raise "stock fixture full plain read differs" unless stock_reader.read_array_decimal256_raw_mark_range("plain", 0, stock_reader.mark_count) == W45_STOCK_PLAIN
raise "stock fixture later plain marks differ" unless stock_reader.read_array_decimal256_raw_mark_range("plain", 1, 2) == W45_STOCK_PLAIN[2, 4]

nullable_reader = CrystalClick::WidePart.open_typed(stock_part, "maybe")
raise "stock fixture canonical nullable Decimal256 Array type differs" unless nullable_reader.column_type == "Array(Nullable(Decimal(76, 2)))"
raise "stock fixture full nullable read differs" unless nullable_reader.read_array_nullable_decimal256_raw_mark_range("maybe", 0, nullable_reader.mark_count) == W45_STOCK_NULLABLE
raise "stock fixture later nullable marks differ" unless nullable_reader.read_array_nullable_decimal256_raw_mark_range("maybe", 1, 2) == W45_STOCK_NULLABLE[2, 4]

w45_attach_part(binary, store, "array_decimal256_stock",
  "pk UInt64, plain Array(Decimal(76, 2)), maybe Array(Nullable(Decimal(76, 2)))", stock_part)
w45_check_rows(binary, store, "array_decimal256_stock", "plain, maybe",
  w45_expected_pair(W45_KEYS, W45_STOCK_PLAIN, W45_STOCK_NULLABLE, W45_ALL_ROWS),
  w45_expected_pair(W45_KEYS, W45_STOCK_PLAIN, W45_STOCK_NULLABLE, W45_KEYED_ROWS))

# ClickHouse Decimal(76, S) SQL values are limited to coefficients +/- (10^76-1).
# Int256 MIN/MAX below are intentionally separate raw backing-compatibility
# checks: attach/check/RowBinary only, never Decimal text conversion or arithmetic.
w45_attach_and_check_writer(binary, store, root, 0_i32, W45_RAW_PLAIN, W45_RAW_NULLABLE, "raw_extrema_scale_0")
w45_attach_and_check_writer(binary, store, root, 0_i32, W45_VALID_PLAIN, W45_VALID_NULLABLE, "valid_boundary_scale_0")
w45_attach_and_check_writer(binary, store, root, 76_i32, W45_VALID_PLAIN, W45_VALID_NULLABLE, "valid_boundary_scale_76")
w45_attach_and_check_writer(binary, store, root, 0_i32, W45_ALL_EMPTY_PLAIN,
  W45_ALL_EMPTY_NULLABLE, "all_empty_scale_0")
w45_attach_and_check_writer(binary, store, root, 76_i32, W45_ALL_EMPTY_PLAIN,
  W45_ALL_EMPTY_NULLABLE, "all_empty_scale_76")
w45_attach_and_check_writer(binary, store, root, 76_i32, W45_VALID_PLAIN,
  W45_ALL_NULL_NULLABLE, "all_null_scale_76")

null_zero = IO::Memory.new
w45_append_nullable_array(null_zero, [nil, w45_decimal_coefficient("0")] of CrystalClick::Decimal256Value?)
expected_null_zero_hex = "02" + "01" + "00" + ("00" * 32)
raise "Nullable Decimal256 RowBinary null-versus-zero bytes differ" unless null_zero.to_slice.hexstring == expected_null_zero_hex

puts "PASS Decimal256 Array W45 oracle on ClickHouse #{w45_clickhouse(binary, store, "SELECT version()").strip}"
puts "PASS stock-to-Crystal and Crystal-to-stock ATTACH/CHECK/full+keyed RowBinary; scales 0 and 76; valid +/- (10^76-1), raw Int256 extrema, high-word coefficients, all-NULL and all-empty arrays, NULL versus zero, later marks"
