require "file_utils"
require "./../src/crystal_click"

alias W47_IPV6_ROW_ARRAYS = Array(Array(CrystalClick::IPv6Value))
alias W47_NULLABLE_IPV6_ROW_ARRAYS = Array(Array(CrystalClick::IPv6Value?))
alias W47_RAW_IPV6_ROW_ARRAYS = Array(Array(Array(UInt8)))
alias W47_RAW_NULLABLE_IPV6_ROW_ARRAYS = Array(Array(Array(UInt8)?))

W47_ORACLE_KEYS = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]
W47_ALL_ROWS    = [0_i32, 1_i32, 2_i32, 3_i32, 4_i32, 5_i32, 6_i32]
W47_KEYED_ROWS  = [2_i32, 3_i32, 4_i32]

W47_ZERO     = CrystalClick::IPv6Value.from_hextets(0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16)
W47_LOOPBACK = CrystalClick::IPv6Value.from_hextets(0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 1_u16)
W47_A        = CrystalClick::IPv6Value.from_hextets(0x2001_u16, 0x0db8_u16, 0x0001_u16, 0x0203_u16, 0x0405_u16, 0x0607_u16, 0x0809_u16, 0x0a0b_u16)
W47_B        = CrystalClick::IPv6Value.from_hextets(0xf001_u16, 0xe203_u16, 0xd405_u16, 0xc607_u16, 0xb809_u16, 0xa00b_u16, 0x1d2e_u16, 0x3f40_u16)
W47_C        = CrystalClick::IPv6Value.from_hextets(0x2001_u16, 0x0db8_u16, 0xffff_u16, 0xeeee_u16, 0xdddd_u16, 0xcccc_u16, 0xbbbb_u16, 0xaaaa_u16)

# Explicit network-order wire bytes are independent of IPv6Value's two-word
# representation. A and B reject byte reversal and 64-bit-half swapping.
W47_ZERO_BYTES     = [0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8]
W47_LOOPBACK_BYTES = [0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x01_u8]
W47_A_BYTES        = [0x20_u8, 0x01_u8, 0x0d_u8, 0xb8_u8, 0x00_u8, 0x01_u8, 0x02_u8, 0x03_u8, 0x04_u8, 0x05_u8, 0x06_u8, 0x07_u8, 0x08_u8, 0x09_u8, 0x0a_u8, 0x0b_u8]
W47_B_BYTES        = [0xf0_u8, 0x01_u8, 0xe2_u8, 0x03_u8, 0xd4_u8, 0x05_u8, 0xc6_u8, 0x07_u8, 0xb8_u8, 0x09_u8, 0xa0_u8, 0x0b_u8, 0x1d_u8, 0x2e_u8, 0x3f_u8, 0x40_u8]
W47_C_BYTES        = [0x20_u8, 0x01_u8, 0x0d_u8, 0xb8_u8, 0xff_u8, 0xff_u8, 0xee_u8, 0xee_u8, 0xdd_u8, 0xdd_u8, 0xcc_u8, 0xcc_u8, 0xbb_u8, 0xbb_u8, 0xaa_u8, 0xaa_u8]

W47_IPV6_ROWS = [
  [] of CrystalClick::IPv6Value,
  [W47_A, W47_B, W47_LOOPBACK, W47_ZERO],
  [W47_C],
  [] of CrystalClick::IPv6Value,
  [W47_LOOPBACK, W47_B],
  [W47_ZERO],
  [] of CrystalClick::IPv6Value,
] of Array(CrystalClick::IPv6Value)

W47_NULLABLE_IPV6_ROWS = [
  [] of CrystalClick::IPv6Value?,
  [nil, W47_ZERO, W47_A, W47_LOOPBACK] of CrystalClick::IPv6Value?,
  [nil, nil] of CrystalClick::IPv6Value?,
  [] of CrystalClick::IPv6Value?,
  [W47_ZERO, nil, W47_A] of CrystalClick::IPv6Value?,
  [W47_ZERO, nil] of CrystalClick::IPv6Value?,
  [] of CrystalClick::IPv6Value?,
] of Array(CrystalClick::IPv6Value?)

W47_RAW_IPV6_ROWS = [
  [] of Array(UInt8),
  [W47_A_BYTES, W47_B_BYTES, W47_LOOPBACK_BYTES, W47_ZERO_BYTES],
  [W47_C_BYTES],
  [] of Array(UInt8),
  [W47_LOOPBACK_BYTES, W47_B_BYTES],
  [W47_ZERO_BYTES],
  [] of Array(UInt8),
] of Array(Array(UInt8))

W47_RAW_NULLABLE_IPV6_ROWS = [
  [] of Array(UInt8)?,
  [nil, W47_ZERO_BYTES, W47_A_BYTES, W47_LOOPBACK_BYTES] of Array(UInt8)?,
  [nil, nil] of Array(UInt8)?,
  [] of Array(UInt8)?,
  [W47_ZERO_BYTES, nil, W47_A_BYTES] of Array(UInt8)?,
  [W47_ZERO_BYTES, nil] of Array(UInt8)?,
  [] of Array(UInt8)?,
] of Array(Array(UInt8)?)

def w47_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  result = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (#{result.exit_code}): #{query}" unless result.success?
  output.to_s
end

def w47_append_u64_le(io : IO, value : UInt64) : Nil
  8.times { |byte| io.write_byte(((value >> (byte * 8)) & 0xff_u64).to_u8) }
end

def w47_append_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

def w47_append_array(io : IO, values : Array(Array(UInt8))) : Nil
  w47_append_varuint(io, values.size.to_u64)
  values.each { |value| io.write(value.to_unsafe.to_slice(value.size)) }
end

def w47_append_nullable_array(io : IO, values : Array(Array(UInt8)?)) : Nil
  w47_append_varuint(io, values.size.to_u64)
  values.each do |value|
    if value.nil?
      # RowBinary NULL is flag-only; its physical nested slot is not emitted.
      io.write_byte(1_u8)
    else
      io.write_byte(0_u8)
      bytes = value.not_nil!
      io.write(bytes.to_unsafe.to_slice(bytes.size))
    end
  end
end

def w47_expected_pair(plain : W47_RAW_IPV6_ROW_ARRAYS, maybe : W47_RAW_NULLABLE_IPV6_ROW_ARRAYS, selected : Array(Int32)) : Bytes
  io = IO::Memory.new
  selected.each do |row|
    w47_append_u64_le(io, W47_ORACLE_KEYS[row])
    w47_append_array(io, plain[row])
    w47_append_nullable_array(io, maybe[row])
  end
  io.to_slice
end

def w47_expected_plain(values : W47_RAW_IPV6_ROW_ARRAYS, selected : Array(Int32)) : Bytes
  io = IO::Memory.new
  selected.each do |row|
    w47_append_u64_le(io, W47_ORACLE_KEYS[row])
    w47_append_array(io, values[row])
  end
  io.to_slice
end

def w47_expected_nullable(values : W47_RAW_NULLABLE_IPV6_ROW_ARRAYS, selected : Array(Int32)) : Bytes
  io = IO::Memory.new
  selected.each do |row|
    w47_append_u64_le(io, W47_ORACLE_KEYS[row])
    w47_append_nullable_array(io, values[row])
  end
  io.to_slice
end

def w47_decoded_stream(part : String, logical_name : String) : Bytes
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.bin")
  raise "missing stream #{logical_name}" unless File.file?(path)
  encoded = File.read(path).to_slice
  encoded.empty? ? Bytes.new(0) : CrystalClick::CompressedBlock.decode_all(encoded)
end

def w47_assert_equal(actual, expected, label : String) : Nil
  raise "#{label} mismatch: expected #{expected.inspect}, got #{actual.inspect}" unless actual == expected
end

def w47_assert_rowbinary(actual : String, expected : Bytes, label : String) : Nil
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

def w47_attach_part(binary : String, store : String, table : String, schema : String, part : String) : Nil
  w47_clickhouse(binary, store, <<-SQL)
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
  data_path = w47_clickhouse(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{table}' FORMAT TSVRaw").strip
  raise "no ClickHouse data path for #{table}" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  w47_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  integrity = w47_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "CHECK TABLE failed for #{table}: #{integrity.inspect}" unless integrity == "all_1_1_0\t1"
  puts "CHECK TABLE #{table}: all_1_1_0\t1"
end

def w47_check_full_and_keyed(binary : String, store : String, table : String, columns : String, full : Bytes, keyed : Bytes) : Nil
  full_actual = w47_clickhouse(binary, store, "SELECT pk, #{columns} FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  w47_assert_rowbinary(full_actual, full, "#{table} full")
  keyed_actual = w47_clickhouse(binary, store, "SELECT pk, #{columns} FROM default.#{table} WHERE pk >= 4 AND pk < 11 ORDER BY pk FORMAT RowBinary")
  w47_assert_rowbinary(keyed_actual, keyed, "#{table} keyed")
  puts "RowBinary #{table}: full #{full.size} bytes exact; keyed #{keyed.size} bytes exact"
end

def w47_writer_plain_rows(rows : W47_IPV6_ROW_ARRAYS) : Array(Array(CrystalClick::IPv6Value))
  rows
end

def w47_writer_nullable_rows(rows : W47_NULLABLE_IPV6_ROW_ARRAYS) : Array(Array(CrystalClick::IPv6Value?))
  rows
end

def w47_writer_plain_part(root : String, name : String, rows : W47_IPV6_ROW_ARRAYS) : String
  part = File.join(root, name, "all_1_1_0")
  FileUtils.mkdir_p(File.dirname(part))
  values = w47_writer_plain_rows(rows)
  CrystalClick::WidePartWriter.write_uint64_array_ipv6_pair(
    part, "pk", W47_ORACLE_KEYS.to_unsafe.to_slice(W47_ORACLE_KEYS.size), "payload",
    values.to_unsafe.to_slice(values.size), rows_per_mark: 2
  )
  part
end

def w47_writer_nullable_part(root : String, name : String, rows : W47_NULLABLE_IPV6_ROW_ARRAYS) : String
  part = File.join(root, name, "all_1_1_0")
  FileUtils.mkdir_p(File.dirname(part))
  values = w47_writer_nullable_rows(rows)
  CrystalClick::WidePartWriter.write_uint64_array_nullable_ipv6_pair(
    part, "pk", W47_ORACLE_KEYS.to_unsafe.to_slice(W47_ORACLE_KEYS.size), "payload",
    values.to_unsafe.to_slice(values.size), rows_per_mark: 2
  )
  part
end

def w47_attach_and_check_plain(binary : String, store : String, table : String, part : String, raw : W47_RAW_IPV6_ROW_ARRAYS) : Nil
  w47_attach_part(binary, store, table, "pk UInt64, payload Array(IPv6)", part)
  w47_check_full_and_keyed(
    binary, store, table, "payload",
    w47_expected_plain(raw, W47_ALL_ROWS), w47_expected_plain(raw, W47_KEYED_ROWS)
  )
end

def w47_attach_and_check_nullable(binary : String, store : String, table : String, part : String, raw : W47_RAW_NULLABLE_IPV6_ROW_ARRAYS) : Nil
  w47_attach_part(binary, store, table, "pk UInt64, payload Array(Nullable(IPv6))", part)
  w47_check_full_and_keyed(
    binary, store, table, "payload",
    w47_expected_nullable(raw, W47_ALL_ROWS), w47_expected_nullable(raw, W47_KEYED_ROWS)
  )
end

def w47_verify_stock_fixture(binary : String, store : String, part : String) : Nil
  plain_sizes = [] of UInt8
  W47_RAW_IPV6_ROWS.each do |row|
    8.times { |byte| plain_sizes << ((row.size.to_u64 >> (byte * 8)) & 0xff_u64).to_u8 }
  end
  w47_assert_equal(w47_decoded_stream(part, "plain.size0").to_a, plain_sizes, "stock plain size0 stream")
  plain_leaves = [] of UInt8
  W47_RAW_IPV6_ROWS.each { |row| row.each { |value| plain_leaves.concat(value) } }
  w47_assert_equal(w47_decoded_stream(part, "plain").to_a, plain_leaves, "stock IPv6 network-order leaf stream")

  nullable_sizes = [] of UInt8
  W47_RAW_NULLABLE_IPV6_ROWS.each do |row|
    8.times { |byte| nullable_sizes << ((row.size.to_u64 >> (byte * 8)) & 0xff_u64).to_u8 }
  end
  w47_assert_equal(w47_decoded_stream(part, "maybe.size0").to_a, nullable_sizes, "stock nullable size0 stream")
  null_map = [] of UInt8
  nested = [] of UInt8
  W47_RAW_NULLABLE_IPV6_ROWS.each do |row|
    row.each do |value|
      null_map << (value.nil? ? 1_u8 : 0_u8)
      nested.concat(value || W47_ZERO_BYTES)
    end
  end
  w47_assert_equal(w47_decoded_stream(part, "maybe.null").to_a, null_map, "stock nullable null map")
  w47_assert_equal(w47_decoded_stream(part, "maybe").to_a, nested, "stock nullable 16-byte nested slots")
  puts "Stock disk streams: IPv6 leaves are 16 network-order octets; NULL slots still consume 16 zero bytes"

  w47_attach_part(binary, store, "w47_stock_pair", "pk UInt64, plain Array(IPv6), maybe Array(Nullable(IPv6))", part)
  w47_check_full_and_keyed(
    binary, store, "w47_stock_pair", "plain, maybe",
    w47_expected_pair(W47_RAW_IPV6_ROWS, W47_RAW_NULLABLE_IPV6_ROWS, W47_ALL_ROWS),
    w47_expected_pair(W47_RAW_IPV6_ROWS, W47_RAW_NULLABLE_IPV6_ROWS, W47_KEYED_ROWS)
  )
end

def w47_verify_writer_parts(binary : String, store : String, root : String) : Nil
  mixed_plain = w47_writer_plain_part(root, "writer-mixed-plain", W47_IPV6_ROWS)
  w47_attach_and_check_plain(binary, store, "w47_writer_mixed_plain", mixed_plain, W47_RAW_IPV6_ROWS)
  mixed_nullable = w47_writer_nullable_part(root, "writer-mixed-nullable", W47_NULLABLE_IPV6_ROWS)
  w47_attach_and_check_nullable(binary, store, "w47_writer_mixed_nullable", mixed_nullable, W47_RAW_NULLABLE_IPV6_ROWS)

  empty_plain = Array.new(W47_ORACLE_KEYS.size) { [] of CrystalClick::IPv6Value }
  empty_plain_raw = Array.new(W47_ORACLE_KEYS.size) { [] of Array(UInt8) }
  empty_plain_part = w47_writer_plain_part(root, "writer-empty-plain", empty_plain)
  w47_attach_and_check_plain(binary, store, "w47_writer_empty_plain", empty_plain_part, empty_plain_raw)
  w47_assert_equal(w47_decoded_stream(empty_plain_part, "payload").empty?, true, "empty IPv6 child stream")

  empty_nullable = Array.new(W47_ORACLE_KEYS.size) { [] of CrystalClick::IPv6Value? }
  empty_nullable_raw = Array.new(W47_ORACLE_KEYS.size) { [] of Array(UInt8)? }
  empty_nullable_part = w47_writer_nullable_part(root, "writer-empty-nullable", empty_nullable)
  w47_attach_and_check_nullable(binary, store, "w47_writer_empty_nullable", empty_nullable_part, empty_nullable_raw)
  w47_assert_equal(w47_decoded_stream(empty_nullable_part, "payload").empty?, true, "empty nullable IPv6 child stream")
  w47_assert_equal(w47_decoded_stream(empty_nullable_part, "payload.null").empty?, true, "empty nullable IPv6 null-map stream")
  puts "Crystal all-empty controls: both shapes attach; child streams remain empty"

  all_null = Array.new(W47_ORACLE_KEYS.size) { [nil, nil] of CrystalClick::IPv6Value? }
  all_null_raw = Array.new(W47_ORACLE_KEYS.size) { [nil, nil] of Array(UInt8)? }
  all_null_part = w47_writer_nullable_part(root, "writer-all-null", all_null)
  w47_attach_and_check_nullable(binary, store, "w47_writer_all_null", all_null_part, all_null_raw)
  w47_assert_equal(w47_decoded_stream(all_null_part, "payload.null").to_a, Array.new(W47_ORACLE_KEYS.size * 2, 1_u8), "all-NULL map")
  w47_assert_equal(w47_decoded_stream(all_null_part, "payload").to_a, Array.new(W47_ORACLE_KEYS.size * 2 * 16, 0_u8), "all-NULL nested default slots")
  puts "Crystal all-NULL control: disk uses 16-byte default child slots; RowBinary is flag-only"
end

binary = ENV["CLICKHOUSE_BIN"]? || raise "CLICKHOUSE_BIN is required"
store = ENV["CLICKHOUSE_STORE"]? || raise "CLICKHOUSE_STORE is required"
stock_part = ENV["STOCK_PART"]? || raise "STOCK_PART is required"
oracle_root = ENV["ORACLE_ROOT"]? || raise "ORACLE_ROOT is required"

w47_verify_stock_fixture(binary, store, stock_part)
w47_verify_writer_parts(binary, store, oracle_root)
