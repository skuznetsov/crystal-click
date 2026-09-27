require "file_utils"
require "./../src/crystal_click"

alias W43_Rows = Array(Array(Int64))
alias W43_NullableRows = Array(Array(Int64?))

W43_KEYS       = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]
W43_ALL_ROWS   = [0_i32, 1_i32, 2_i32, 3_i32, 4_i32, 5_i32, 6_i32]
W43_KEYED_ROWS = [2_i32, 3_i32, 4_i32]
W43_PLAIN      = [
  [] of Int64,
  [-1234_i64, 0_i64, 9999_i64],
  [-999_999_999_999_999_999_i64, 1_i64],
  [] of Int64,
  [-123_i64],
  [1234_i64, -1_i64],
  [] of Int64,
] of Array(Int64)
W43_NULLABLE = [
  [] of Int64?,
  [nil, 0_i64, -5_i64] of Int64?,
  [nil, 123_i64] of Int64?,
  [] of Int64?,
  [-100_i64, nil] of Int64?,
  [0_i64, nil] of Int64?,
  [] of Int64?,
] of Array(Int64?)
W43_EMPTY_PLAIN    = Array.new(W43_KEYS.size) { [] of Int64 }
W43_EMPTY_NULLABLE = Array.new(W43_KEYS.size) { [] of Int64? }
W43_ALL_NULL       = [
  [] of Int64?, [nil] of Int64?, [nil, nil] of Int64?, [] of Int64?,
  [nil] of Int64?, [nil, nil] of Int64?, [] of Int64?,
] of Array(Int64?)

def w43_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  result = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (#{result.exit_code}): #{query}" unless result.success?
  output.to_s
end

def w43_append_u64_le(io : IO, value : UInt64) : Nil
  8.times { |byte| io.write_byte(((value >> (byte * 8)) & 0xff_u64).to_u8) }
end

def w43_append_i64_le(io : IO, value : Int64) : Nil
  bits = value.unsafe_as(UInt64)
  8.times { |byte| io.write_byte(((bits >> (byte * 8)) & 0xff_u64).to_u8) }
end

def w43_append_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

def w43_append_array(io : IO, values : Array(Int64)) : Nil
  w43_append_varuint(io, values.size.to_u64)
  values.each { |value| w43_append_i64_le(io, value) }
end

def w43_append_nullable_array(io : IO, values : Array(Int64?)) : Nil
  w43_append_varuint(io, values.size.to_u64)
  values.each do |value|
    if value.nil?
      io.write_byte(1_u8)
    else
      io.write_byte(0_u8)
      w43_append_i64_le(io, value.not_nil!)
    end
  end
end

def w43_expected_stock(selected : Array(Int32)) : Bytes
  io = IO::Memory.new
  selected.each do |row|
    w43_append_u64_le(io, W43_KEYS[row])
    w43_append_array(io, W43_PLAIN[row])
    w43_append_nullable_array(io, W43_NULLABLE[row])
  end
  io.to_slice
end

def w43_expected_plain(keys : Array(UInt64), values : W43_Rows, selected : Array(Int32)) : Bytes
  io = IO::Memory.new
  selected.each do |row|
    w43_append_u64_le(io, keys[row])
    w43_append_array(io, values[row])
  end
  io.to_slice
end

def w43_expected_nullable(keys : Array(UInt64), values : W43_NullableRows, selected : Array(Int32)) : Bytes
  io = IO::Memory.new
  selected.each do |row|
    w43_append_u64_le(io, keys[row])
    w43_append_nullable_array(io, values[row])
  end
  io.to_slice
end

def w43_assert_rowbinary(actual : String, expected : Bytes, label : String) : Nil
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

def w43_attach_part(binary : String, store : String, table : String, schema : String, part : String) : Nil
  w43_clickhouse(binary, store, <<-SQL)
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
  data_path = w43_clickhouse(
    binary,
    store,
    "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{table}' FORMAT TSVRaw"
  ).strip
  raise "no ClickHouse data path for #{table}" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  w43_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  integrity = w43_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "CHECK TABLE failed for #{table}: #{integrity.inspect}" unless integrity == "all_1_1_0\t1"
  puts "CHECK TABLE #{table}: all_1_1_0\t1"
end

def w43_check_rows(binary : String, store : String, table : String, columns : String, full : Bytes, keyed : Bytes) : Nil
  full_actual = w43_clickhouse(binary, store, "SELECT pk, #{columns} FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  w43_assert_rowbinary(full_actual, full, "#{table} full")
  keyed_actual = w43_clickhouse(binary, store, "SELECT pk, #{columns} FROM default.#{table} WHERE pk >= 4 AND pk < 11 ORDER BY pk FORMAT RowBinary")
  w43_assert_rowbinary(keyed_actual, keyed, "#{table} keyed")
  puts "RowBinary #{table}: full #{full.size} bytes exact; keyed #{keyed.size} bytes exact"
end

def w43_decoded_stream(part : String, logical_name : String) : Bytes
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.bin")
  raise "missing writer stream #{logical_name}" unless File.file?(path)
  encoded = File.read(path).to_slice
  encoded.empty? ? Bytes.new(0) : CrystalClick::CompressedBlock.decode_all(encoded)
end

def w43_assert_writer_profile(part : String, expected_rows_per_mark : Array(UInt64)) : Nil
  raise "writer part is not Wide" unless File.file?(File.join(part, "columns.txt"))
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
      value = 0_u64
      8.times { |byte| value |= raw[offset + byte].to_u64 << (byte * 8) }
      counts << value
    end
    raise "writer rows-per-mark differs in #{File.basename(path)}" unless counts == expected_rows_per_mark + [0_u64]
  end
  Dir.glob(File.join(part, "*.bin")).each do |path|
    encoded = File.read(path).to_slice
    CrystalClick::CompressedBlock.decode_all(encoded) unless encoded.empty?
  end
end

def w43_verify_plain_writer(binary : String, store : String, root : String, suffix : String, values : W43_Rows, scale : Int32 = 2_i32) : Nil
  part = File.join(root, "writer-plain-#{suffix}")
  CrystalClick::WidePartWriter.write_uint64_array_decimal64_pair(
    part, "pk", W43_KEYS.to_unsafe.to_slice(W43_KEYS.size), "payload",
    values.to_unsafe.to_slice(values.size), scale, 2_i32
  )
  reader = CrystalClick::WidePart.open_typed(part, "payload")
  raise "writer Decimal64 scale metadata mismatch for #{suffix}" unless reader.column_type == "Array(Decimal(18, #{scale}))"
  raise "writer Decimal64 raw coefficients changed for #{suffix}" unless reader.read_array_decimal64_raw_mark_range("payload", 0, reader.mark_count) == values
  w43_assert_writer_profile(part, [2_u64, 2_u64, 2_u64, 1_u64])
  table = "array_decimal64_plain_#{suffix}"
  w43_attach_part(binary, store, table, "pk UInt64, payload Array(Decimal(18, #{scale}))", part)
  w43_check_rows(
    binary, store, table, "payload",
    w43_expected_plain(W43_KEYS, values, W43_ALL_ROWS),
    w43_expected_plain(W43_KEYS, values, W43_KEYED_ROWS),
  )
end

def w43_verify_nullable_writer(binary : String, store : String, root : String, suffix : String, values : W43_NullableRows, scale : Int32 = 2_i32) : Nil
  part = File.join(root, "writer-nullable-#{suffix}")
  CrystalClick::WidePartWriter.write_uint64_array_nullable_decimal64_pair(
    part, "pk", W43_KEYS.to_unsafe.to_slice(W43_KEYS.size), "payload",
    values.to_unsafe.to_slice(values.size), scale, 2_i32
  )
  reader = CrystalClick::WidePart.open_typed(part, "payload")
  expected_type = "Array(Nullable(Decimal(18, #{scale})))"
  raise "writer Nullable Decimal64 metadata mismatch for #{suffix}" unless reader.column_type == expected_type
  raise "writer Nullable Decimal64 raw coefficients changed for #{suffix}" unless reader.read_array_nullable_decimal64_raw_mark_range("payload", 0, reader.mark_count) == values
  w43_assert_writer_profile(part, [2_u64, 2_u64, 2_u64, 1_u64])

  if suffix == "all_empty"
    nested = w43_decoded_stream(part, "payload")
    null_map = w43_decoded_stream(part, "payload.null")
    raise "all-empty Nullable(Decimal64) child streams must be empty" unless nested.empty? && null_map.empty?
  elsif suffix == "all_null"
    leaf_count = values.sum(&.size)
    null_map = w43_decoded_stream(part, "payload.null")
    nested = w43_decoded_stream(part, "payload")
    raise "all-null control contains a non-NULL leaf" unless values.all? { |row| row.all?(&.nil?) }
    raise "all-null Nullable(Decimal64) null map differs" unless null_map == Bytes.new(leaf_count, 1_u8)
    raise "all-null Nullable(Decimal64) nested slots are not eight zero bytes each" unless nested == Bytes.new(8 * leaf_count, 0_u8)
  end

  table = "array_decimal64_nullable_#{suffix}"
  w43_attach_part(binary, store, table, "pk UInt64, payload #{expected_type}", part)
  w43_check_rows(
    binary, store, table, "payload",
    w43_expected_nullable(W43_KEYS, values, W43_ALL_ROWS),
    w43_expected_nullable(W43_KEYS, values, W43_KEYED_ROWS),
  )
end

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("CLICKHOUSE_STORE")
root = ENV.fetch("ORACLE_ROOT")
stock_part = ENV.fetch("STOCK_PART")

w43_attach_part(
  binary, store, "array_decimal64_stock",
  "pk UInt64, plain Array(Decimal64(2)), maybe Array(Nullable(Decimal64(2)))",
  stock_part
)
w43_check_rows(
  binary, store, "array_decimal64_stock", "plain, maybe",
  w43_expected_stock(W43_ALL_ROWS), w43_expected_stock(W43_KEYED_ROWS),
)

raise "non-NULL zero discriminator missing" unless W43_NULLABLE[1] == [nil, 0_i64, -5_i64]
io = IO::Memory.new
w43_append_nullable_array(io, W43_NULLABLE[1])
expected_nullable_hex = "03" + "01" + "00" + "0000000000000000" + "00" + "fbffffffffffffff"
raise "RowBinary Nullable(Decimal64) null-slot layout changed" unless io.to_slice.hexstring == expected_nullable_hex

w43_verify_plain_writer(binary, store, root, "mixed", W43_PLAIN)
w43_verify_nullable_writer(binary, store, root, "mixed", W43_NULLABLE)
w43_verify_plain_writer(binary, store, root, "all_empty", W43_EMPTY_PLAIN)
w43_verify_nullable_writer(binary, store, root, "all_empty", W43_EMPTY_NULLABLE)
w43_verify_nullable_writer(binary, store, root, "all_null", W43_ALL_NULL)

# Test decimal precision-boundary coefficients at scale boundaries using raw
# Int64 bytes; these values remain representable as Decimal(18, S) for all S.
precision_boundary = [
  [-999_999_999_999_999_999_i64], [0_i64], [999_999_999_999_999_999_i64],
  [] of Int64, [-1_i64], [1_i64], [] of Int64,
] of Array(Int64)
{0, 9, 10, 18}.each do |scale|
  w43_verify_plain_writer(binary, store, root, "precision_scale_#{scale}", precision_boundary, scale.to_i32)
end

# The backing Int64 extrema are written exactly by Crystal; stock is asked to
# attach, check, and return only binary bytes, without decimal text formatting.
backing_extremes = [
  [Int64::MIN], [0_i64], [Int64::MAX], [] of Int64,
  [-1_i64], [1_i64], [] of Int64,
] of Array(Int64)
w43_verify_plain_writer(binary, store, root, "int64_extrema_scale_18", backing_extremes, 18_i32)

puts "Decimal64 Array bidirectional stock oracle passed: pinned stock and writer ATTACH/CHECK, exact full/keyed RowBinary, all-empty/all-NULL controls, scales 0/9/10/18, and raw Int64 boundaries"
