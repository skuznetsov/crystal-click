require "file_utils"
require "./../src/crystal_click"

alias W44_Rows = Array(Array(Int128))
alias W44_NullableRows = Array(Array(Int128?))

W44_KEYS        = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]
W44_ALL_ROWS    = [0_i32, 1_i32, 2_i32, 3_i32, 4_i32, 5_i32, 6_i32]
W44_KEYED_ROWS  = [2_i32, 3_i32, 4_i32]
W44_DECIMAL_MAX = ("9" * 38).to_i128

W44_STOCK_PLAIN = [
  [] of Int128,
  [-1234_i128, 0_i128, 9999_i128],
  [-W44_DECIMAL_MAX, 1_i128],
  [] of Int128,
  [-123_i128],
  [1234_i128, -1_i128],
  [] of Int128,
] of Array(Int128)

W44_STOCK_NULLABLE = [
  [] of Int128?,
  [nil, 0_i128, -5_i128] of Int128?,
  [nil, 123_i128] of Int128?,
  [] of Int128?,
  [-100_i128, nil] of Int128?,
  [0_i128, nil] of Int128?,
  [] of Int128?,
] of Array(Int128?)

W44_RAW_EXTREMA_PLAIN = [
  [Int128::MIN, -1_i128, 0_i128, 1_i128, Int128::MAX],
  [] of Int128,
  [-W44_DECIMAL_MAX, W44_DECIMAL_MAX],
  [] of Int128,
  [-123_i128],
  [0_i128, 1_i128],
  [] of Int128,
] of Array(Int128)

W44_RAW_EXTREMA_NULLABLE = [
  [nil, Int128::MIN, 0_i128, Int128::MAX] of Int128?,
  [nil, nil] of Int128?,
  [nil, -1_i128, 0_i128] of Int128?,
  [] of Int128?,
  [-W44_DECIMAL_MAX, nil] of Int128?,
  [0_i128, nil] of Int128?,
  [] of Int128?,
] of Array(Int128?)

W44_SCALE38_PLAIN = [
  [-W44_DECIMAL_MAX, -1_i128, 0_i128, 1_i128, W44_DECIMAL_MAX],
  [] of Int128,
  [-123_i128, 123_i128],
  [] of Int128,
  [-1_i128],
  [0_i128, 1_i128],
  [] of Int128,
] of Array(Int128)

W44_SCALE38_NULLABLE = [
  [nil, -W44_DECIMAL_MAX, 0_i128, W44_DECIMAL_MAX] of Int128?,
  [nil, nil] of Int128?,
  [nil, -1_i128, 0_i128] of Int128?,
  [] of Int128?,
  [-123_i128, nil] of Int128?,
  [0_i128, nil],
  [] of Int128?,
] of Array(Int128?)

W44_ALL_EMPTY_PLAIN    = Array.new(W44_KEYS.size) { [] of Int128 }
W44_ALL_EMPTY_NULLABLE = Array.new(W44_KEYS.size) { [] of Int128? }

def w44_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (status #{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

def w44_append_u64_le(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
end

def w44_append_i128_le(io : IO, value : Int128) : Nil
  bits = value.unsafe_as(UInt128)
  16.times { |index| io.write_byte(((bits >> (index * 8)) & 0xff_u128).to_u8) }
end

def w44_append_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

def w44_append_array(io : IO, values : Array(Int128)) : Nil
  w44_append_varuint(io, values.size.to_u64)
  values.each { |value| w44_append_i128_le(io, value) }
end

def w44_append_nullable_array(io : IO, values : Array(Int128?)) : Nil
  w44_append_varuint(io, values.size.to_u64)
  values.each do |value|
    if value.nil?
      io.write_byte(1_u8)
    else
      io.write_byte(0_u8)
      w44_append_i128_le(io, value.not_nil!)
    end
  end
end

def w44_expected_pair(keys : Array(UInt64), plain : W44_Rows, nullable : W44_NullableRows, selected : Array(Int32)) : Bytes
  output = IO::Memory.new
  selected.each do |row|
    w44_append_u64_le(output, keys[row])
    w44_append_array(output, plain[row])
    w44_append_nullable_array(output, nullable[row])
  end
  output.to_slice
end

def w44_expected_plain(keys : Array(UInt64), values : W44_Rows, selected : Array(Int32)) : Bytes
  output = IO::Memory.new
  selected.each do |row|
    w44_append_u64_le(output, keys[row])
    w44_append_array(output, values[row])
  end
  output.to_slice
end

def w44_expected_nullable(keys : Array(UInt64), values : W44_NullableRows, selected : Array(Int32)) : Bytes
  output = IO::Memory.new
  selected.each do |row|
    w44_append_u64_le(output, keys[row])
    w44_append_nullable_array(output, values[row])
  end
  output.to_slice
end

def w44_assert_bytes(actual : String, expected : Bytes, label : String) : Nil
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

def w44_attach_part(binary : String, store : String, table : String, schema : String, part : String) : Nil
  w44_clickhouse(binary, store, <<-SQL)
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

  data_path = w44_clickhouse(
    binary,
    store,
    "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{table}' FORMAT TSVRaw"
  ).strip
  raise "no ClickHouse data path for #{table}" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  w44_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  integrity = w44_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "CHECK TABLE failed for #{table}: #{integrity.inspect}" unless integrity == "all_1_1_0\t1"
  puts "CHECK TABLE #{table}: all_1_1_0\t1"
end

def w44_check_rows(binary : String, store : String, table : String, columns : String, full : Bytes, keyed : Bytes) : Nil
  actual_full = w44_clickhouse(binary, store, "SELECT pk, #{columns} FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  w44_assert_bytes(actual_full, full, "#{table} full")
  actual_keyed = w44_clickhouse(binary, store, "SELECT pk, #{columns} FROM default.#{table} WHERE pk >= 4 AND pk < 11 ORDER BY pk FORMAT RowBinary")
  w44_assert_bytes(actual_keyed, keyed, "#{table} keyed")
  puts "RowBinary #{table}: full #{full.size} bytes exact; keyed #{keyed.size} bytes exact"
end

def w44_decoded_stream(part : String, logical_name : String) : Bytes
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.bin")
  raise "missing writer stream #{logical_name}" unless File.file?(path)
  encoded = File.read(path).to_slice
  encoded.empty? ? Bytes.new(0) : CrystalClick::CompressedBlock.decode_all(encoded)
end

def w44_int128_payload(values : W44_Rows) : Bytes
  output = IO::Memory.new
  values.each { |row| row.each { |value| w44_append_i128_le(output, value) } }
  output.to_slice
end

def w44_nullable_payload(values : W44_NullableRows) : Bytes
  output = IO::Memory.new
  values.each do |row|
    row.each { |value| w44_append_i128_le(output, value || 0_i128) }
  end
  output.to_slice
end

def w44_null_map(values : W44_NullableRows) : Bytes
  output = IO::Memory.new
  values.each do |row|
    row.each { |value| output.write_byte(value.nil? ? 1_u8 : 0_u8) }
  end
  output.to_slice
end

def w44_assert_writer_profile(part : String, canonical_type : String, nullable : Bool) : Nil
  columns = File.read(File.join(part, "columns.txt"))
  raise "writer columns metadata differs for #{canonical_type}" unless columns.includes?("`payload` #{canonical_type}")
  raise "writer part does not declare LZ4" unless File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)"
  mark_paths = Dir.glob(File.join(part, "*.mrk2"))
  raise "writer part has no plain .mrk2 files" if mark_paths.empty?
  raise "writer part contains unsupported mark files" unless Dir.glob(File.join(part, "*.cmrk*")).empty? && Dir.glob(File.join(part, "*.mrk")).empty? && Dir.glob(File.join(part, "*.mrk3")).empty?
  mark_paths.each do |path|
    raw = File.read(path).to_slice
    raise "writer mark size is not a sequence of 24-byte records" unless raw.size % CrystalClick::WidePart::MARK_SIZE == 0
    counts = [] of UInt64
    (raw.size // CrystalClick::WidePart::MARK_SIZE).times do |mark_index|
      offset = mark_index * CrystalClick::WidePart::MARK_SIZE + 16
      count = 0_u64
      8.times { |byte| count |= raw[offset + byte].to_u64 << (byte * 8) }
      counts << count
    end
    raise "writer rows-per-mark differs in #{File.basename(path)}" unless counts == [2_u64, 2_u64, 2_u64, 1_u64, 0_u64]
  end
  Dir.glob(File.join(part, "*.bin")).each do |path|
    encoded = File.read(path).to_slice
    CrystalClick::CompressedBlock.decode_all(encoded) unless encoded.empty?
  end
  expected_streams = nullable ? 4 : 3
  raise "writer child-stream count differs for #{canonical_type}" unless mark_paths.size == expected_streams && Dir.glob(File.join(part, "*.bin")).size == expected_streams
end

def w44_verify_plain_writer(binary : String, store : String, root : String, scale : Int32, values : W44_Rows, label : String) : Nil
  part = File.join(root, "writer-plain-#{label}")
  CrystalClick::WidePartWriter.write_uint64_array_decimal128_pair(
    part, "pk", W44_KEYS.to_unsafe.to_slice(W44_KEYS.size), "payload",
    values.to_unsafe.to_slice(values.size), scale, 2_i32
  )
  canonical_type = "Array(Decimal(38, #{scale}))"
  reader = CrystalClick::WidePart.open_typed(part, "payload")
  raise "writer canonical type differs for #{label}" unless reader.column_type == canonical_type
  raise "writer raw coefficients changed for #{label}" unless reader.read_array_decimal128_raw_mark_range("payload", 0, reader.mark_count) == values
  w44_assert_writer_profile(part, canonical_type, false)

  table = "array_decimal128_plain_#{label}"
  w44_attach_part(binary, store, table, "pk UInt64, payload #{canonical_type}", part)
  w44_check_rows(
    binary, store, table, "payload",
    w44_expected_plain(W44_KEYS, values, W44_ALL_ROWS),
    w44_expected_plain(W44_KEYS, values, W44_KEYED_ROWS),
  )
end

def w44_verify_nullable_writer(binary : String, store : String, root : String, scale : Int32, values : W44_NullableRows, label : String) : Nil
  part = File.join(root, "writer-nullable-#{label}")
  CrystalClick::WidePartWriter.write_uint64_array_nullable_decimal128_pair(
    part, "pk", W44_KEYS.to_unsafe.to_slice(W44_KEYS.size), "payload",
    values.to_unsafe.to_slice(values.size), scale, 2_i32
  )
  canonical_type = "Array(Nullable(Decimal(38, #{scale})))"
  reader = CrystalClick::WidePart.open_typed(part, "payload")
  raise "writer canonical type differs for #{label}" unless reader.column_type == canonical_type
  raise "writer raw coefficients or NULL slots changed for #{label}" unless reader.read_array_nullable_decimal128_raw_mark_range("payload", 0, reader.mark_count) == values
  w44_assert_writer_profile(part, canonical_type, true)

  nested = w44_decoded_stream(part, "payload")
  nulls = w44_decoded_stream(part, "payload.null")
  raise "writer Nullable nested slots differ, including NULL defaults, for #{label}" unless nested == w44_nullable_payload(values)
  raise "writer Nullable null map differs for #{label}" unless nulls == w44_null_map(values)

  table = "array_decimal128_nullable_#{label}"
  w44_attach_part(binary, store, table, "pk UInt64, payload #{canonical_type}", part)
  w44_check_rows(
    binary, store, table, "payload",
    w44_expected_nullable(W44_KEYS, values, W44_ALL_ROWS),
    w44_expected_nullable(W44_KEYS, values, W44_KEYED_ROWS),
  )
end

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("CLICKHOUSE_STORE")
root = ENV.fetch("ORACLE_ROOT")
stock_part = ENV.fetch("STOCK_PART")

stock_reader = CrystalClick::WidePart.open_typed(stock_part, "plain")
raise "stock fixture canonical Decimal128 type differs" unless stock_reader.column_type == "Array(Decimal(38, 2))"
raise "stock fixture full plain read differs" unless stock_reader.read_array_decimal128_raw_mark_range("plain", 0, stock_reader.mark_count) == W44_STOCK_PLAIN
nullable_reader = CrystalClick::WidePart.open_typed(stock_part, "maybe")
raise "stock fixture canonical nullable type differs" unless nullable_reader.column_type == "Array(Nullable(Decimal(38, 2)))"
raise "stock fixture full nullable read differs" unless nullable_reader.read_array_nullable_decimal128_raw_mark_range("maybe", 0, nullable_reader.mark_count) == W44_STOCK_NULLABLE
w44_attach_part(
  binary, store, "array_decimal128_stock",
  "pk UInt64, plain Array(Decimal(38, 2)), maybe Array(Nullable(Decimal(38, 2)))",
  stock_part
)
w44_check_rows(
  binary, store, "array_decimal128_stock", "plain, maybe",
  w44_expected_pair(W44_KEYS, W44_STOCK_PLAIN, W44_STOCK_NULLABLE, W44_ALL_ROWS),
  w44_expected_pair(W44_KEYS, W44_STOCK_PLAIN, W44_STOCK_NULLABLE, W44_KEYED_ROWS),
)

# These are raw backing compatibility checks. Int128 MIN/MAX exceed Decimal(38)
# semantic range; the oracle asks ClickHouse only to attach, check, and return
# the unformatted RowBinary coefficient bytes. Scale 38 uses valid coefficients.
w44_verify_plain_writer(binary, store, root, 0_i32, W44_RAW_EXTREMA_PLAIN, "raw_extrema_scale_0")
w44_verify_nullable_writer(binary, store, root, 0_i32, W44_RAW_EXTREMA_NULLABLE, "raw_extrema_scale_0")
w44_verify_plain_writer(binary, store, root, 38_i32, W44_SCALE38_PLAIN, "precision_boundary_scale_38")
w44_verify_nullable_writer(binary, store, root, 38_i32, W44_SCALE38_NULLABLE, "precision_boundary_scale_38")
w44_verify_plain_writer(binary, store, root, 0_i32, W44_ALL_EMPTY_PLAIN, "all_empty_scale_0")
w44_verify_nullable_writer(binary, store, root, 38_i32, W44_ALL_EMPTY_NULLABLE, "all_empty_scale_38")

io = IO::Memory.new
w44_append_nullable_array(io, W44_STOCK_NULLABLE[1])
expected_nullable_hex = "03" + "01" + "00" + ("00" * 16) + "00" + "fb" + ("ff" * 15)
raise "Nullable Decimal128 RowBinary null-versus-zero bytes differ" unless io.to_slice.hexstring == expected_nullable_hex

puts "PASS Decimal128 Array W44 oracle on ClickHouse #{w44_clickhouse(binary, store, "SELECT version()").strip}"
puts "PASS stock-to-Crystal and Crystal-to-stock ATTACH/CHECK/full+keyed RowBinary; scales 0 and 38; raw Int128 extrema, all-NULL rows, all-empty arrays, NULL versus zero, later marks"
