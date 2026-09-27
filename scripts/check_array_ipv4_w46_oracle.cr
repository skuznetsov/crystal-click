require "file_utils"
require "./../src/crystal_click"

alias W46_IPV4_ROWS = Array(Array(UInt32))
alias W46_NULLABLE_IPV4_ROWS = Array(Array(UInt32?))

W46_ORACLE_KEYS = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]
W46_ALL_ROWS    = [0_i32, 1_i32, 2_i32, 3_i32, 4_i32, 5_i32, 6_i32]
W46_KEYED_ROWS  = [2_i32, 3_i32, 4_i32]

# These expected producer values are raw IPv4 network-order UInt32 numbers,
# declared independently from CrystalClick's reader and writer.
W46_RAW_IPV4_ROWS = [
  [] of UInt32,
  [0xc0000201_u32, 0x010200c0_u32, 0xcb007109_u32],
  [0_u32],
  [] of UInt32,
  [0xc6336407_u32],
  [0xc0000201_u32],
  [] of UInt32,
] of Array(UInt32)

W46_RAW_NULLABLE_IPV4_ROWS = [
  [] of UInt32?,
  [nil, 0_u32, 0xc0000201_u32] of UInt32?,
  [nil, nil] of UInt32?,
  [] of UInt32?,
  [0xcb007109_u32, nil] of UInt32?,
  [0xc0000201_u32] of UInt32?,
  [] of UInt32?,
] of Array(UInt32?)

W46_EMPTY_IPV4_ROWS          = Array.new(W46_ORACLE_KEYS.size) { [] of UInt32 }
W46_EMPTY_NULLABLE_IPV4_ROWS = Array.new(W46_ORACLE_KEYS.size) { [] of UInt32? }
W46_NULL_ONLY_ROWS           = Array.new(W46_ORACLE_KEYS.size) { [nil, nil] of UInt32? }

def w46_oracle_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  result = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (#{result.exit_code}): #{query}" unless result.success?
  output.to_s
end

def w46_append_u32_le(io : IO, value : UInt32) : Nil
  4.times { |byte| io.write_byte(((value >> (byte * 8)) & 0xff_u32).to_u8) }
end

def w46_append_u64_le(io : IO, value : UInt64) : Nil
  8.times { |byte| io.write_byte(((value >> (byte * 8)) & 0xff_u64).to_u8) }
end

def w46_append_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

def w46_append_array(io : IO, values : Array(UInt32)) : Nil
  w46_append_varuint(io, values.size.to_u64)
  values.each { |value| w46_append_u32_le(io, value) }
end

def w46_append_nullable_array(io : IO, values : Array(UInt32?)) : Nil
  w46_append_varuint(io, values.size.to_u64)
  values.each do |value|
    if value.nil?
      # RowBinary Nullable is flag-only for NULL; disk child slots are separate.
      io.write_byte(1_u8)
    else
      io.write_byte(0_u8)
      w46_append_u32_le(io, value.not_nil!)
    end
  end
end

def w46_decoded_stream(part : String, logical_name : String) : Bytes
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.bin")
  raise "missing stream #{logical_name}" unless File.file?(path)
  encoded = File.read(path).to_slice
  encoded.empty? ? Bytes.new(0) : CrystalClick::CompressedBlock.decode_all(encoded)
end

def w46_append_row(io : IO, key : UInt64, plain : Array(UInt32), maybe : Array(UInt32?)) : Nil
  w46_append_u64_le(io, key)
  w46_append_array(io, plain)
  w46_append_nullable_array(io, maybe)
end

def w46_expected_pair(plain : W46_IPV4_ROWS, maybe : W46_NULLABLE_IPV4_ROWS, selected : Array(Int32)) : Bytes
  io = IO::Memory.new
  selected.each do |row|
    w46_append_row(io, W46_ORACLE_KEYS[row], plain[row], maybe[row])
  end
  io.to_slice
end

def w46_expected_plain(plain : W46_IPV4_ROWS, selected : Array(Int32)) : Bytes
  io = IO::Memory.new
  selected.each do |row|
    w46_append_u64_le(io, W46_ORACLE_KEYS[row])
    w46_append_array(io, plain[row])
  end
  io.to_slice
end

def w46_expected_nullable_only(maybe : W46_NULLABLE_IPV4_ROWS, selected : Array(Int32)) : Bytes
  io = IO::Memory.new
  selected.each do |row|
    w46_append_u64_le(io, W46_ORACLE_KEYS[row])
    w46_append_nullable_array(io, maybe[row])
  end
  io.to_slice
end

def w46_expected_nullable(maybe : W46_NULLABLE_IPV4_ROWS, selected : Array(Int32)) : Bytes
  w46_expected_nullable_only(maybe, selected)
end

def w46_assert_rowbinary(actual : String, expected : Bytes, label : String) : Nil
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

def w46_assert_equal(actual, expected, label : String) : Nil
  raise "#{label} mismatch: expected #{expected.inspect}, got #{actual.inspect}" unless actual == expected
end

def w46_attach_part(binary : String, store : String, table : String, schema : String, part : String) : Nil
  w46_oracle_clickhouse(binary, store, <<-SQL)
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
  data_path = w46_oracle_clickhouse(
    binary,
    store,
    "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{table}' FORMAT TSVRaw"
  ).strip
  raise "no ClickHouse data path for #{table}" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  w46_oracle_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  integrity = w46_oracle_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "CHECK TABLE failed for #{table}: #{integrity.inspect}" unless integrity == "all_1_1_0\t1"
  puts "CHECK TABLE #{table}: all_1_1_0\t1"
end

def w46_check_full_and_keyed(
  binary : String,
  store : String,
  table : String,
  columns : String,
  full : Bytes,
  keyed : Bytes,
) : Nil
  full_actual = w46_oracle_clickhouse(binary, store, "SELECT pk, #{columns} FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  w46_assert_rowbinary(full_actual, full, "#{table} full")
  keyed_actual = w46_oracle_clickhouse(binary, store, "SELECT pk, #{columns} FROM default.#{table} WHERE pk >= 4 AND pk < 11 ORDER BY pk FORMAT RowBinary")
  w46_assert_rowbinary(keyed_actual, keyed, "#{table} keyed")
  puts "RowBinary #{table}: full #{full.size} bytes exact; keyed #{keyed.size} bytes exact"
end

def w46_ipv4_value(network_order : UInt32) : CrystalClick::IPv4Value
  CrystalClick::IPv4Value.new(network_order)
end

def w46_writer_plain_rows(rows : W46_IPV4_ROWS) : Array(Array(CrystalClick::IPv4Value))
  rows.map { |row| row.map { |value| w46_ipv4_value(value) } }
end

def w46_writer_nullable_rows(rows : W46_NULLABLE_IPV4_ROWS) : Array(Array(CrystalClick::IPv4Value?))
  rows.map do |row|
    row.map { |value| value.try { |network_order| w46_ipv4_value(network_order) } }
  end
end

def w46_writer_plain_part(root : String, name : String, plain : W46_IPV4_ROWS) : String
  part = File.join(root, name)
  plain_values = w46_writer_plain_rows(plain)
  CrystalClick::WidePartWriter.write_uint64_array_ipv4_pair(
    part, "pk", W46_ORACLE_KEYS.to_unsafe.to_slice(W46_ORACLE_KEYS.size), "plain",
    plain_values.to_unsafe.to_slice(plain_values.size), rows_per_mark: 2
  )
  part
end

def w46_writer_nullable_part(root : String, name : String, maybe : W46_NULLABLE_IPV4_ROWS) : String
  part = File.join(root, name)
  nullable_values = w46_writer_nullable_rows(maybe)
  CrystalClick::WidePartWriter.write_uint64_array_nullable_ipv4_pair(
    part, "pk", W46_ORACLE_KEYS.to_unsafe.to_slice(W46_ORACLE_KEYS.size), "maybe",
    nullable_values.to_unsafe.to_slice(nullable_values.size), rows_per_mark: 2
  )
  part
end

def w46_attach_and_check_plain(
  binary : String,
  store : String,
  table : String,
  part : String,
  plain : W46_IPV4_ROWS,
) : Nil
  w46_attach_part(binary, store, table, "pk UInt64, plain Array(IPv4)", part)
  w46_check_full_and_keyed(
    binary, store, table, "plain",
    w46_expected_plain(plain, W46_ALL_ROWS),
    w46_expected_plain(plain, W46_KEYED_ROWS),
  )
end

def w46_attach_and_check_nullable(
  binary : String,
  store : String,
  table : String,
  part : String,
  maybe : W46_NULLABLE_IPV4_ROWS,
) : Nil
  w46_attach_part(binary, store, table, "pk UInt64, maybe Array(Nullable(IPv4))", part)
  w46_check_full_and_keyed(
    binary, store, table, "maybe",
    w46_expected_nullable(maybe, W46_ALL_ROWS),
    w46_expected_nullable(maybe, W46_KEYED_ROWS),
  )
end

def w46_verify_stock_fixture(binary : String, store : String, part : String) : Nil
  expected_sizes = [] of UInt8
  W46_RAW_IPV4_ROWS.each do |row|
    value = row.size.to_u64
    8.times { |byte| expected_sizes << ((value >> (byte * 8)) & 0xff_u64).to_u8 }
  end
  w46_assert_equal(w46_decoded_stream(part, "plain.size0").to_a, expected_sizes, "stock plain size0 stream")
  expected_plain = W46_RAW_IPV4_ROWS.flat_map do |row|
    row.flat_map do |value|
      bytes = IO::Memory.new
      w46_append_u32_le(bytes, value)
      bytes.to_slice.to_a
    end
  end
  w46_assert_equal(w46_decoded_stream(part, "plain").to_a, expected_plain, "stock IPv4 nested stream")

  expected_nullable_sizes = [] of UInt8
  W46_RAW_NULLABLE_IPV4_ROWS.each do |row|
    value = row.size.to_u64
    8.times { |byte| expected_nullable_sizes << ((value >> (byte * 8)) & 0xff_u64).to_u8 }
  end
  w46_assert_equal(w46_decoded_stream(part, "maybe.size0").to_a, expected_nullable_sizes, "stock nullable size0 stream")

  expected_null_map = W46_RAW_NULLABLE_IPV4_ROWS.flat_map { |row| row.map { |value| value.nil? ? 1_u8 : 0_u8 } }
  w46_assert_equal(w46_decoded_stream(part, "maybe.null").to_a, expected_null_map, "stock nullable map")
  expected_nested = W46_RAW_NULLABLE_IPV4_ROWS.flat_map do |row|
    row.flat_map do |value|
      bytes = IO::Memory.new
      w46_append_u32_le(bytes, value || 0_u32)
      bytes.to_slice.to_a
    end
  end
  w46_assert_equal(w46_decoded_stream(part, "maybe").to_a, expected_nested, "stock nullable nested stream")
  puts "Stock disk streams: IPv4 leaves are LE network-order UInt32; NULL child slots consume four bytes"

  w46_attach_part(binary, store, "w46_stock_pair", "pk UInt64, plain Array(IPv4), maybe Array(Nullable(IPv4))", part)
  w46_check_full_and_keyed(
    binary, store, "w46_stock_pair", "plain, maybe",
    w46_expected_pair(W46_RAW_IPV4_ROWS, W46_RAW_NULLABLE_IPV4_ROWS, W46_ALL_ROWS),
    w46_expected_pair(W46_RAW_IPV4_ROWS, W46_RAW_NULLABLE_IPV4_ROWS, W46_KEYED_ROWS),
  )
end

def w46_verify_writer_parts(binary : String, store : String, root : String) : Nil
  mixed_plain = w46_writer_plain_part(root, "writer-mixed-plain", W46_RAW_IPV4_ROWS)
  w46_attach_and_check_plain(
    binary, store, "w46_writer_mixed_plain", mixed_plain, W46_RAW_IPV4_ROWS
  )
  mixed_nullable = w46_writer_nullable_part(root, "writer-mixed-nullable", W46_RAW_NULLABLE_IPV4_ROWS)
  w46_attach_and_check_nullable(
    binary, store, "w46_writer_mixed_nullable", mixed_nullable, W46_RAW_NULLABLE_IPV4_ROWS
  )

  empty_plain = w46_writer_plain_part(root, "writer-empty-plain", W46_EMPTY_IPV4_ROWS)
  w46_attach_and_check_plain(
    binary, store, "w46_writer_empty_plain", empty_plain, W46_EMPTY_IPV4_ROWS
  )
  empty_nullable = w46_writer_nullable_part(root, "writer-empty-nullable", W46_EMPTY_NULLABLE_IPV4_ROWS)
  w46_attach_and_check_nullable(
    binary, store, "w46_writer_empty_nullable", empty_nullable, W46_EMPTY_NULLABLE_IPV4_ROWS
  )
  w46_assert_equal(w46_decoded_stream(empty_plain, "plain").empty?, true, "empty IPv4 child stream")
  w46_assert_equal(w46_decoded_stream(empty_nullable, "maybe").empty?, true, "empty nullable IPv4 child stream")
  w46_assert_equal(w46_decoded_stream(empty_nullable, "maybe.null").empty?, true, "empty nullable null-map stream")
  puts "Crystal all-empty writer controls: both array shapes attach; every child stream is empty"

  null_only_part = w46_writer_nullable_part(root, "writer-all-null", W46_NULL_ONLY_ROWS)
  w46_attach_and_check_nullable(
    binary, store, "w46_writer_all_null", null_only_part, W46_NULL_ONLY_ROWS
  )
  w46_assert_equal(w46_decoded_stream(null_only_part, "maybe.null").to_a, Array.new(W46_ORACLE_KEYS.size * 2, 1_u8), "all-NULL map")
  w46_assert_equal(w46_decoded_stream(null_only_part, "maybe").to_a, Array.new(W46_ORACLE_KEYS.size * 2 * 4, 0_u8), "all-NULL nested default slots")
  puts "Crystal all-NULL writer control: on-disk 4-byte defaults; RowBinary NULL flag only"
end

binary = ENV["CLICKHOUSE_BIN"]? || raise "CLICKHOUSE_BIN is required"
store = ENV["CLICKHOUSE_STORE"]? || raise "CLICKHOUSE_STORE is required"
stock_part = ENV["STOCK_PART"]? || raise "STOCK_PART is required"
oracle_root = ENV["ORACLE_ROOT"]? || raise "ORACLE_ROOT is required"

w46_verify_stock_fixture(binary, store, stock_part)
w46_verify_writer_parts(binary, store, oracle_root)
