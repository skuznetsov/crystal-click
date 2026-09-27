require "file_utils"
require "./../src/crystal_click"

alias W41_UUID_HALVES = Tuple(UInt64, UInt64)

W41_ORACLE_KEYS   = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]
W41_SELECTED_ROWS = [2_i32, 3_i32, 4_i32]
W41_ALL_ROWS      = [0_i32, 1_i32, 2_i32, 3_i32, 4_i32, 5_i32, 6_i32]

# Expected stock values are raw UUID halves, not values read through CrystalClick.
W41_RAW_UUID_ROWS = [
  [] of W41_UUID_HALVES,
  [{0x0011223344556677_u64, 0x8899aabbccddeeff_u64}, {0_u64, 0_u64}] of W41_UUID_HALVES,
  [{UInt64::MAX, UInt64::MAX}] of W41_UUID_HALVES,
  [] of W41_UUID_HALVES,
  [{0x61f0c4045cb311e7_u64, 0x907ba6006ad3dba0_u64}] of W41_UUID_HALVES,
  [{0x0123456789abcdef_u64, 0xfedcba9876543210_u64}, {0x1020304050607080_u64, 0x90a0b0c0d0e0f001_u64}] of W41_UUID_HALVES,
  [] of W41_UUID_HALVES,
] of Array(W41_UUID_HALVES)

W41_RAW_NULLABLE_UUID_ROWS = [
  [] of W41_UUID_HALVES?,
  [nil, {0_u64, 0_u64}] of W41_UUID_HALVES?,
  [nil, nil] of W41_UUID_HALVES?,
  [] of W41_UUID_HALVES?,
  [{0x0123456789abcdef_u64, 0xfedcba9876543210_u64}] of W41_UUID_HALVES?,
  [nil, {0x61f0c4045cb311e7_u64, 0x907ba6006ad3dba0_u64}] of W41_UUID_HALVES?,
  [] of W41_UUID_HALVES?,
] of Array(W41_UUID_HALVES?)

W41_RAW_EMPTY_UUID_ROWS          = Array.new(W41_ORACLE_KEYS.size) { [] of W41_UUID_HALVES }
W41_RAW_EMPTY_NULLABLE_UUID_ROWS = Array.new(W41_ORACLE_KEYS.size) { [] of W41_UUID_HALVES? }
W41_RAW_NULL_ONLY_UUID_ROWS      = [
  [] of W41_UUID_HALVES?,
  [nil, nil] of W41_UUID_HALVES?,
  [] of W41_UUID_HALVES?,
  [nil] of W41_UUID_HALVES?,
  [nil, nil] of W41_UUID_HALVES?,
  [nil] of W41_UUID_HALVES?,
  [] of W41_UUID_HALVES?,
] of Array(W41_UUID_HALVES?)

def w41_oracle_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  result = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (#{result.exit_code}): #{query}" unless result.success?
  output.to_s
end

def w41_append_u64_le(io : IO, value : UInt64) : Nil
  8.times { |byte| io.write_byte(((value >> (byte * 8)) & 0xff_u64).to_u8) }
end

def w41_read_u64_le(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

def w41_append_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

def w41_append_uuid(io : IO, halves : W41_UUID_HALVES) : Nil
  # ClickHouse RowBinary UUID is the little-endian first UInt64 half followed by
  # the little-endian second UInt64 half; asymmetric constants catch reversal.
  w41_append_u64_le(io, halves[0])
  w41_append_u64_le(io, halves[1])
end

def w41_append_array(io : IO, values : Array(W41_UUID_HALVES)) : Nil
  w41_append_varuint(io, values.size.to_u64)
  values.each { |uuid| w41_append_uuid(io, uuid) }
end

def w41_append_nullable_array(io : IO, values : Array(W41_UUID_HALVES?)) : Nil
  w41_append_varuint(io, values.size.to_u64)
  values.each do |uuid|
    if uuid.nil?
      io.write_byte(1_u8)
    else
      io.write_byte(0_u8)
      w41_append_uuid(io, uuid.not_nil!)
    end
  end
end

def w41_decoded_stream(part : String, logical_name : String) : Bytes
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.bin")
  raise "missing stream #{logical_name}" unless File.file?(path)
  encoded = File.read(path).to_slice
  encoded.empty? ? Bytes.new(0) : CrystalClick::CompressedBlock.decode_all(encoded)
end

def w41_expected_stock(selected : Array(Int32)) : Bytes
  io = IO::Memory.new
  selected.each do |row|
    w41_append_u64_le(io, W41_ORACLE_KEYS[row])
    w41_append_array(io, W41_RAW_UUID_ROWS[row])
    w41_append_nullable_array(io, W41_RAW_NULLABLE_UUID_ROWS[row])
  end
  io.to_slice
end

def w41_expected_single(keys : Array(UInt64), values : Array(Array(W41_UUID_HALVES)), selected : Array(Int32)) : Bytes
  io = IO::Memory.new
  selected.each do |row|
    w41_append_u64_le(io, keys[row])
    w41_append_array(io, values[row])
  end
  io.to_slice
end

def w41_expected_single_nullable(keys : Array(UInt64), values : Array(Array(W41_UUID_HALVES?)), selected : Array(Int32)) : Bytes
  io = IO::Memory.new
  selected.each do |row|
    w41_append_u64_le(io, keys[row])
    w41_append_nullable_array(io, values[row])
  end
  io.to_slice
end

def w41_assert_rowbinary(actual : String, expected : Bytes, label : String) : Nil
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

def w41_attach_part(binary : String, store : String, table : String, schema : String, part : String) : Nil
  w41_oracle_clickhouse(binary, store, <<-SQL)
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
  data_path = w41_oracle_clickhouse(
    binary,
    store,
    "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{table}' FORMAT TSVRaw"
  ).strip
  raise "no ClickHouse data path for #{table}" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  w41_oracle_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  integrity = w41_oracle_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "CHECK TABLE failed for #{table}: #{integrity.inspect}" unless integrity == "all_1_1_0\t1"
  puts "CHECK TABLE #{table}: all_1_1_0\t1"
end

def w41_check_full_and_keyed(binary : String, store : String, table : String, columns : String, full : Bytes, keyed : Bytes) : Nil
  full_actual = w41_oracle_clickhouse(binary, store, "SELECT pk, #{columns} FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  w41_assert_rowbinary(full_actual, full, "#{table} full")
  keyed_actual = w41_oracle_clickhouse(binary, store, "SELECT pk, #{columns} FROM default.#{table} WHERE pk >= 4 AND pk < 11 ORDER BY pk FORMAT RowBinary")
  w41_assert_rowbinary(keyed_actual, keyed, "#{table} keyed")
  puts "RowBinary #{table}: full #{full.size} bytes exact; keyed #{keyed.size} bytes exact"
end

def w41_report_stock_streams(part : String) : Nil
  puts "Stock stream files and first .mrk2 samples:"
  ["pk", "plain.size0", "plain", "maybe.size0", "maybe.null", "maybe"].each do |name|
    hash = CrystalClick::StreamName.hash(name)
    mark = File.read(File.join(part, "#{hash}.mrk2")).to_slice
    sample = 3.times.map { |field| w41_read_u64_le(mark, field * 8).to_s }.join(",")
    puts "  #{name}: #{hash}.bin / #{hash}.mrk2; first mark (compressed,decompressed,rows)=#{sample}"
  end
end

def w41_values(rows : Array(Array(W41_UUID_HALVES))) : Array(Array(CrystalClick::UUIDValue))
  rows.map do |row|
    row.map { |uuid| CrystalClick::UUIDValue.new(uuid[0], uuid[1]) }
  end
end

def w41_nullable_values(rows : Array(Array(W41_UUID_HALVES?))) : Array(Array(CrystalClick::UUIDValue?))
  rows.map do |row|
    row.map do |uuid|
      uuid.nil? ? nil : CrystalClick::UUIDValue.new(uuid.not_nil![0], uuid.not_nil![1])
    end
  end
end

def w41_verify_writer(binary : String, store : String, root : String, nullable : Bool) : Nil
  keys = W41_ORACLE_KEYS
  if nullable
    part = File.join(root, "writer-nullable-uuid")
    values = w41_nullable_values(W41_RAW_NULLABLE_UUID_ROWS)
    CrystalClick::WidePartWriter.write_uint64_array_nullable_uuid_pair(
      part, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
      values.to_unsafe.to_slice(values.size), rows_per_mark: 2
    )
    table = "array_uuid_nullable_writer"
    w41_attach_part(binary, store, table, "pk UInt64, payload Array(Nullable(UUID))", part)
    w41_check_full_and_keyed(
      binary, store, table, "payload",
      w41_expected_single_nullable(keys, W41_RAW_NULLABLE_UUID_ROWS, W41_ALL_ROWS),
      w41_expected_single_nullable(keys, W41_RAW_NULLABLE_UUID_ROWS, W41_SELECTED_ROWS),
    )
  else
    part = File.join(root, "writer-uuid")
    values = w41_values(W41_RAW_UUID_ROWS)
    CrystalClick::WidePartWriter.write_uint64_array_uuid_pair(
      part, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
      values.to_unsafe.to_slice(values.size), rows_per_mark: 2
    )
    table = "array_uuid_writer"
    w41_attach_part(binary, store, table, "pk UInt64, payload Array(UUID)", part)
    w41_check_full_and_keyed(
      binary, store, table, "payload",
      w41_expected_single(keys, W41_RAW_UUID_ROWS, W41_ALL_ROWS),
      w41_expected_single(keys, W41_RAW_UUID_ROWS, W41_SELECTED_ROWS),
    )
  end
end

def w41_verify_empty_plain_writer(binary : String, store : String, root : String) : Nil
  keys = W41_ORACLE_KEYS
  part = File.join(root, "writer-uuid-all-empty")
  values = w41_values(W41_RAW_EMPTY_UUID_ROWS)
  CrystalClick::WidePartWriter.write_uint64_array_uuid_pair(
    part, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
    values.to_unsafe.to_slice(values.size), rows_per_mark: 2
  )
  payload_path = File.join(part, "#{CrystalClick::StreamName.hash("payload")}.bin")
  raise "all-empty Array(UUID) must keep a zero-byte UUID child stream" unless File.file?(payload_path) && File.size(payload_path) == 0
  table = "array_uuid_writer_all_empty"
  w41_attach_part(binary, store, table, "pk UInt64, payload Array(UUID)", part)
  w41_check_full_and_keyed(
    binary, store, table, "payload",
    w41_expected_single(keys, W41_RAW_EMPTY_UUID_ROWS, W41_ALL_ROWS),
    w41_expected_single(keys, W41_RAW_EMPTY_UUID_ROWS, W41_SELECTED_ROWS),
  )
end

def w41_verify_nullable_edge_writer(binary : String, store : String, root : String, name : String, raw_values : Array(Array(W41_UUID_HALVES?))) : Nil
  keys = W41_ORACLE_KEYS
  part = File.join(root, "writer-nullable-uuid-#{name}")
  values = w41_nullable_values(raw_values)
  CrystalClick::WidePartWriter.write_uint64_array_nullable_uuid_pair(
    part, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
    values.to_unsafe.to_slice(values.size), rows_per_mark: 2
  )

  null_map = w41_decoded_stream(part, "payload.null")
  nested = w41_decoded_stream(part, "payload")
  leaf_count = raw_values.sum(&.size)
  nonnull_count = raw_values.sum { |row| row.count { |uuid| !uuid.nil? } }
  raise "#{name} Nullable(UUID) input unexpectedly contains a non-NULL leaf" unless nonnull_count == 0
  expected_null_map = Bytes.new(leaf_count, 1_u8)
  raise "#{name} Nullable(UUID) null-map bytes differ" unless null_map == expected_null_map
  expected_nested = Bytes.new(16 * leaf_count, 0_u8)
  raise "#{name} Nullable(UUID) nested slots differ" unless nested == expected_nested

  table = "array_uuid_nullable_writer_#{name}"
  w41_attach_part(binary, store, table, "pk UInt64, payload Array(Nullable(UUID))", part)
  w41_check_full_and_keyed(
    binary, store, table, "payload",
    w41_expected_single_nullable(keys, raw_values, W41_ALL_ROWS),
    w41_expected_single_nullable(keys, raw_values, W41_SELECTED_ROWS),
  )
end

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("CLICKHOUSE_STORE")
root = ENV.fetch("ORACLE_ROOT")
stock_part = ENV.fetch("STOCK_PART")
w41_report_stock_streams(stock_part)

stock_schema = <<-SCHEMA
  pk UInt64,
  plain Array(UUID),
  maybe Array(Nullable(UUID))
  SCHEMA
w41_attach_part(binary, store, "array_uuid_stock", stock_schema, stock_part)
w41_check_full_and_keyed(
  binary, store, "array_uuid_stock", "plain, maybe",
  w41_expected_stock(W41_ALL_ROWS),
  w41_expected_stock(W41_SELECTED_ROWS),
)

# This asymmetric value catches a UUID half-endianness swap in either direction.
io = IO::Memory.new
w41_append_uuid(io, W41_RAW_UUID_ROWS[1][0])
raise "UUID half-order discriminator changed" unless io.to_slice.hexstring == "7766554433221100ffeeddccbbaa9988"

w41_verify_writer(binary, store, root, false)
w41_verify_writer(binary, store, root, true)
w41_verify_empty_plain_writer(binary, store, root)
w41_verify_nullable_edge_writer(binary, store, root, "all_empty", W41_RAW_EMPTY_NULLABLE_UUID_ROWS)
w41_verify_nullable_edge_writer(binary, store, root, "all_null", W41_RAW_NULL_ONLY_UUID_ROWS)
puts "UUID Array bidirectional stock oracle passed: exact stock/writer ATTACH, CHECK TABLE, and full/keyed RowBinary"
