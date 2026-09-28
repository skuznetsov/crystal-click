require "file_utils"
require "./../src/crystal_click"

W56_ORACLE_KEYS   = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64]
W56_ORACLE_VALUES = ["alpha", 42_u64, nil, nil, nil, nil, ""] of String | UInt64 | Nil

def run_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (status #{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

def create_table(binary : String, store : String, table : String) : Nil
  run_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.#{table}
  (
      `pk` UInt64,
      `payload` Variant(String, UInt64)
  )
  ENGINE = MergeTree
  ORDER BY pk
  SETTINGS
      index_granularity = 3,
      index_granularity_bytes = 10485760,
      enable_mixed_granularity_parts = 1,
      min_rows_for_wide_part = 0,
      min_bytes_for_wide_part = 0,
      ratio_of_defaults_for_sparse_serialization = 1.0,
      compress_marks = 0,
      min_compress_block_size = 0,
      max_compress_block_size = 4096,
      default_compression_codec = 'LZ4',
      use_compact_variant_discriminators_serialization = 1;
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

def append_variant(io : IO, value : String | UInt64 | Nil) : Nil
  case value
  when String
    io.write_byte(0_u8)
    append_varuint(io, value.bytesize.to_u64)
    io.write(value.to_slice)
  when UInt64
    io.write_byte(1_u8)
    append_u64_le(io, value)
  when Nil
    io.write_byte(255_u8)
  else
    raise "unexpected W56 Variant value"
  end
end

def rowbinary(keys : Array(UInt64), values : Array(String | UInt64 | Nil)) : String
  raise "W56 RowBinary input lengths differ" unless keys.size == values.size
  io = IO::Memory.new
  keys.each_with_index do |key, index|
    append_u64_le(io, key)
    append_variant(io, values[index])
  end
  io.to_s
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

def verify_stock_fixture(
  binary : String,
  store : String,
  part : String,
) : Nil
  table = "w56_stock_compact_control"
  create_table(binary, store, table)
  attach_part(binary, store, table, part)

  full = run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  assert_bytes(full, rowbinary(W56_ORACLE_KEYS, W56_ORACLE_VALUES), "stock COMPACT fixture full")
  ranged = run_clickhouse(binary, store,
    "SELECT pk, payload FROM default.#{table} WHERE pk >= 2 AND pk < 7 ORDER BY pk FORMAT RowBinary")
  range_keys = W56_ORACLE_KEYS[1, 5]
  range_values = W56_ORACLE_VALUES[1, 5]
  assert_bytes(ranged, rowbinary(range_keys, range_values), "stock COMPACT fixture primary-key range")
  puts "PASS stock COMPACT fixture: ATTACH/CHECK and independently proves full and primary-key-range RowBinary"
end

def verify_writer(
  binary : String,
  store : String,
  part : String,
  table : String,
  keys : Array(UInt64),
  values : Array(String | UInt64 | Nil),
  label : String,
) : Nil
  create_table(binary, store, table)
  attach_part(binary, store, table, part)
  columns = run_clickhouse(binary, store,
    "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw")
  expected_columns = "pk UInt64\npayload Variant(String, UInt64)\n"
  raise "#{table}: exact type metadata differs: #{columns.inspect}" unless columns == expected_columns

  show_create = run_clickhouse(binary, store, "SHOW CREATE TABLE default.#{table} FORMAT TSVRaw")
  normalized_create = show_create.gsub(/\s+/, "")
  raise "#{table}: SHOW CREATE lost the exact Variant type" unless normalized_create.includes?("`payload`Variant(String,UInt64)")

  full = run_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  assert_bytes(full, rowbinary(keys, values), "#{label} full")
  ranged = run_clickhouse(binary, store,
    "SELECT pk, payload FROM default.#{table} WHERE pk >= 2 AND pk < 7 ORDER BY pk FORMAT RowBinary")
  range_end = Math.min(keys.size, 6)
  range_keys = keys[1, range_end - 1]
  range_values = values[1, range_end - 1]
  assert_bytes(ranged, rowbinary(range_keys, range_values), "#{label} primary-key range")
  puts "PASS #{label}: ATTACH/CHECK, exact metadata, full and primary-key-range RowBinary"
end

binary = ENV.fetch("CLICKHOUSE_BIN")
root = ENV.fetch("TMP_ROOT")
store = File.join(root, "clickhouse-store")
stock_part = File.expand_path("../test/fixtures/public/wide_variant_w56/compact/part", __DIR__)
verify_stock_fixture(binary, store, stock_part)
keys = W56_ORACLE_KEYS.to_unsafe.to_slice(W56_ORACLE_KEYS.size)
values = W56_ORACLE_VALUES.to_unsafe.to_slice(W56_ORACLE_VALUES.size)
part = CrystalClick::WidePartWriter.write_uint64_variant_string_uint64_pair(
  File.join(root, "writer-variant-string-u64-pair"), "pk", keys, "payload", values,
  rows_per_mark: 3
)
verify_writer(binary, store, part, "w56_mixed", W56_ORACLE_KEYS, W56_ORACLE_VALUES, "mixed Variant(String, UInt64)")

all_null = Array(CrystalClick::VariantStringUInt64Value).new(W56_ORACLE_KEYS.size, nil)
all_null_part = CrystalClick::WidePartWriter.write_uint64_variant_string_uint64_pair(
  File.join(root, "writer-variant-string-u64-all-null"), "pk", keys, "payload", all_null.to_unsafe.to_slice(all_null.size),
  rows_per_mark: 3
)
verify_writer(binary, store, all_null_part, "w56_all_null", W56_ORACLE_KEYS, all_null, "all-NULL Variant")

all_strings = ["", "x", "y", "longer", "", "seven", "tail"] of String | UInt64 | Nil
all_string_part = CrystalClick::WidePartWriter.write_uint64_variant_string_uint64_pair(
  File.join(root, "writer-variant-string-u64-all-string"), "pk", keys, "payload", all_strings.to_unsafe.to_slice(all_strings.size),
  rows_per_mark: 3
)
verify_writer(binary, store, all_string_part, "w56_all_string", W56_ORACLE_KEYS, all_strings, "all-String Variant")
puts "PASS W56 Crystal-to-stock Variant(String, UInt64) oracle, including all-NULL and all-String child streams"
