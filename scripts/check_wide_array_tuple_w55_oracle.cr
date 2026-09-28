require "file_utils"
require "./../src/crystal_click"

W55_ORACLE_KEYS   = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]
W55_ORACLE_VALUES = [
  [] of Tuple(UInt64, UInt64),
  [{0_u64, 0_u64}, {UInt64::MAX, UInt64::MAX}] of Tuple(UInt64, UInt64),
  [{42_u64, UInt64::MAX}] of Tuple(UInt64, UInt64),
  [{UInt64::MAX, 0_u64}, {0_u64, UInt64::MAX}] of Tuple(UInt64, UInt64),
  [] of Tuple(UInt64, UInt64),
  [] of Tuple(UInt64, UInt64),
  [{123_u64, 456_u64}] of Tuple(UInt64, UInt64),
] of Array(Tuple(UInt64, UInt64))

def run_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (status #{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

def create_table(binary : String, store : String) : Nil
  run_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.w55_writer_array_tuple_u64_pair
  (
      `pk` UInt64,
      `payload` Array(Tuple(a UInt64, b UInt64))
  )
  ENGINE = MergeTree
  ORDER BY pk
  SETTINGS
      index_granularity = 2,
      index_granularity_bytes = 10485760,
      enable_mixed_granularity_parts = 1,
      min_rows_for_wide_part = 0,
      min_bytes_for_wide_part = 0,
      ratio_of_defaults_for_sparse_serialization = 1.0,
      compress_marks = 0,
      min_compress_block_size = 0,
      max_compress_block_size = 4096,
      default_compression_codec = 'LZ4';
  SQL
  nil
end

def append_u64_le(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
end

def append_varuint(io : IO, value : UInt64) : Nil
  rest = value
  while rest >= 0x80_u64
    io.write_byte(((rest & 0x7f_u64) | 0x80_u64).to_u8)
    rest >>= 7
  end
  io.write_byte(rest.to_u8)
end

def append_array_tuple_uint64_uint64(io : IO, values : Array(Tuple(UInt64, UInt64))) : Nil
  append_varuint(io, values.size.to_u64)
  values.each do |first, second|
    append_u64_le(io, first)
    append_u64_le(io, second)
  end
end

def rowbinary(keys : Array(UInt64), values : Array(Array(Tuple(UInt64, UInt64)))) : String
  raise "Array(Tuple(UInt64, UInt64)) RowBinary lengths differ" unless keys.size == values.size
  io = IO::Memory.new
  keys.each_with_index do |key, index|
    append_u64_le(io, key)
    append_array_tuple_uint64_uint64(io, values[index])
  end
  io.to_s
end

def range_values(values : Array(T)) : Array(T) forall T
  [values[1], values[2], values[3], values[4], values[5]]
end

def range_keys : Array(UInt64)
  [W55_ORACLE_KEYS[1], W55_ORACLE_KEYS[2], W55_ORACLE_KEYS[3], W55_ORACLE_KEYS[4], W55_ORACLE_KEYS[5]]
end

def assert_bytes(actual : String, expected : String, label : String) : Nil
  return if actual.to_slice == expected.to_slice
  raise "#{label} RowBinary mismatch: got #{actual.bytesize} bytes, expected #{expected.bytesize}"
end

def data_path(binary : String, store : String, table : String) : String
  path = run_clickhouse(binary, store,
    "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  raise "#{table}: data path missing" if path.empty? || path.includes?('\n')
  path
end

def attach_part(binary : String, store : String, table : String, part : String) : Nil
  detached = File.join(data_path(binary, store, table), "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  run_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  result = run_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "#{table}: reverse ATTACH/CHECK TABLE failed: #{result.inspect}" unless result == "all_1_1_0\t1"
  nil
end

def verify_writer(binary : String, store : String, part : String) : Nil
  table = "w55_writer_array_tuple_u64_pair"
  create_table(binary, store)
  attach_part(binary, store, table, part)
  columns = run_clickhouse(binary, store,
    "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw")
  expected_columns = "pk UInt64\npayload Array(Tuple(a UInt64, b UInt64))\n"
  raise "#{table}: exact type metadata differs: #{columns.inspect}" unless columns == expected_columns

  show_create = run_clickhouse(binary, store, "SHOW CREATE TABLE default.#{table} FORMAT TSVRaw")
  normalized_create = show_create.gsub(/\s+/, "")
  normalized_declaration = "`payload`Array(Tuple(aUInt64,bUInt64))"
  raise "#{table}: SHOW CREATE lost the named Tuple type" unless normalized_create.includes?(normalized_declaration)
  full = run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  assert_bytes(full, rowbinary(W55_ORACLE_KEYS, W55_ORACLE_VALUES), "Crystal writer full")
  ranged = run_clickhouse(binary, store,
    "SELECT pk, payload FROM default.#{table} WHERE pk >= 2 AND pk < 12 ORDER BY pk FORMAT RowBinary")
  assert_bytes(ranged, rowbinary(range_keys, range_values(W55_ORACLE_VALUES)), "Crystal writer key-range")
  puts "PASS Crystal writer Array(Tuple(a UInt64, b UInt64)): ATTACH/CHECK, exact metadata, full and key-range RowBinary"
end

binary = ENV.fetch("CLICKHOUSE_BIN")
root = ENV.fetch("TMP_ROOT")
store = File.join(root, "clickhouse-store")
keys = W55_ORACLE_KEYS.to_unsafe.to_slice(W55_ORACLE_KEYS.size)
values = W55_ORACLE_VALUES.to_unsafe.to_slice(W55_ORACLE_VALUES.size)
part = CrystalClick::WidePartWriter.write_uint64_array_tuple_uint64_uint64_pair(
  File.join(root, "writer-array-tuple-u64-pair"), "pk", keys, "payload", values,
  rows_per_mark: 2
)
verify_writer(binary, store, part)
puts "PASS W55 Crystal-to-stock Array(Tuple(UInt64, UInt64)) oracle"
