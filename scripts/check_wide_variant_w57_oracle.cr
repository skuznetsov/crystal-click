require "file_utils"
require "./../src/crystal_click"

W57_ORACLE_KEYS   = Array(UInt64).new(13) { |index| (index + 1).to_u64 }
W57_ORACLE_VALUES = [true, "alpha", 42_u64, false, true, false, nil, nil, nil, "", UInt64::MAX, "omega", 99_u64] of CrystalClick::VariantBoolStringUInt64Value

def run_w57_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (status #{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

def create_w57_table(binary : String, store : String, table : String) : Nil
  run_w57_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.#{table}
  (
      `pk` UInt64,
      `payload` Variant(Bool, String, UInt64)
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

def append_w57_u64_le(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
end

def append_w57_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

def append_w57_variant(io : IO, value : CrystalClick::VariantBoolStringUInt64Value) : Nil
  case value
  when Bool
    io.write_byte(0_u8)
    io.write_byte(value ? 1_u8 : 0_u8)
  when String
    io.write_byte(1_u8)
    append_w57_varuint(io, value.bytesize.to_u64)
    io.write(value.to_slice)
  when UInt64
    io.write_byte(2_u8)
    append_w57_u64_le(io, value)
  when Nil
    io.write_byte(255_u8)
  else
    raise "unexpected W57 Variant value"
  end
end

def w57_rowbinary(keys : Array(UInt64), values : Array(CrystalClick::VariantBoolStringUInt64Value)) : String
  raise "W57 RowBinary input lengths differ" unless keys.size == values.size
  output = IO::Memory.new
  keys.each_with_index do |key, index|
    append_w57_u64_le(output, key)
    append_w57_variant(output, values[index])
  end
  output.to_s
end

def assert_w57_bytes(actual : String, expected : String, label : String) : Nil
  return if actual.to_slice == expected.to_slice
  raise "#{label} RowBinary mismatch: got #{actual.bytesize} bytes, expected #{expected.bytesize}"
end

def w57_data_path(binary : String, store : String, table : String) : String
  path = run_w57_clickhouse(binary, store,
    "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  raise "#{table}: data path missing" if path.empty? || path.includes?('\n')
  path
end

def w57_attach_part(binary : String, store : String, table : String, part : String) : Nil
  detached = File.join(w57_data_path(binary, store, table), "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  run_w57_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  result = run_w57_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "#{table}: ATTACH/CHECK TABLE failed: #{result.inspect}" unless result == "all_1_1_0\t1"
  nil
end

def w57_verify_stock_fixture(binary : String, store : String, profile : String, part : String) : Nil
  table = "w57_stock_#{profile}"
  create_w57_table(binary, store, table)
  w57_attach_part(binary, store, table, part)
  full = run_w57_clickhouse(binary, store,
    "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  assert_w57_bytes(full, w57_rowbinary(W57_ORACLE_KEYS, W57_ORACLE_VALUES), "stock #{profile} full")
  range_keys = W57_ORACLE_KEYS[2, 9]
  range_values = W57_ORACLE_VALUES[2, 9]
  ranged = run_w57_clickhouse(binary, store,
    "SELECT pk, payload FROM default.#{table} WHERE pk >= 3 AND pk < 12 ORDER BY pk FORMAT RowBinary")
  assert_w57_bytes(ranged, w57_rowbinary(range_keys, range_values), "stock #{profile} primary-key range")
  puts "PASS stock #{profile.upcase}: ATTACH/CHECK TABLE and independent full/range RowBinary"
end

def w57_verify_writer(
  binary : String,
  store : String,
  part : String,
  table : String,
  keys : Array(UInt64),
  values : Array(CrystalClick::VariantBoolStringUInt64Value),
  label : String,
) : Nil
  create_w57_table(binary, store, table)
  w57_attach_part(binary, store, table, part)
  columns = run_w57_clickhouse(binary, store,
    "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw")
  expected_columns = "pk UInt64\npayload Variant(Bool, String, UInt64)\n"
  raise "#{table}: exact type metadata differs: #{columns.inspect}" unless columns == expected_columns

  show_create = run_w57_clickhouse(binary, store, "SHOW CREATE TABLE default.#{table} FORMAT TSVRaw")
  normalized_create = show_create.gsub(/\s+/, "")
  raise "#{table}: SHOW CREATE lost the exact Variant type" unless normalized_create.includes?("`payload`Variant(Bool,String,UInt64)")

  full = run_w57_clickhouse(binary, store,
    "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  assert_w57_bytes(full, w57_rowbinary(keys, values), "#{label} full")

  range_keys = [] of UInt64
  range_values = [] of CrystalClick::VariantBoolStringUInt64Value
  keys.each_with_index do |key, index|
    if key >= 3_u64 && key < 12_u64
      range_keys << key
      range_values << values[index]
    end
  end
  ranged = run_w57_clickhouse(binary, store,
    "SELECT pk, payload FROM default.#{table} WHERE pk >= 3 AND pk < 12 ORDER BY pk FORMAT RowBinary")
  assert_w57_bytes(ranged, w57_rowbinary(range_keys, range_values), "#{label} primary-key range")
  puts "PASS #{label}: ATTACH/CHECK, exact type, independent full/range RowBinary"
end

binary = ENV.fetch("CLICKHOUSE_BIN")
root = ENV.fetch("TMP_ROOT")
store = File.join(root, "clickhouse-store")
fixture_root = File.expand_path("../test/fixtures/public/wide_variant_w57", __DIR__)
w57_verify_stock_fixture(binary, store, "compact", File.join(fixture_root, "compact", "part"))
w57_verify_stock_fixture(binary, store, "basic", File.join(fixture_root, "basic", "part"))

keys = W57_ORACLE_KEYS.to_unsafe.to_slice(W57_ORACLE_KEYS.size)
values = W57_ORACLE_VALUES.to_unsafe.to_slice(W57_ORACLE_VALUES.size)
mixed_part = CrystalClick::WidePartWriter.write_uint64_variant_bool_string_uint64_pair(
  File.join(root, "writer-variant-bool-string-u64-mixed"), "pk", keys, "payload", values,
  rows_per_mark: 3
)
w57_verify_writer(binary, store, mixed_part, "w57_mixed", W57_ORACLE_KEYS, W57_ORACLE_VALUES, "mixed Variant")

all_null = Array(CrystalClick::VariantBoolStringUInt64Value).new(W57_ORACLE_KEYS.size, nil)
all_null_part = CrystalClick::WidePartWriter.write_uint64_variant_bool_string_uint64_pair(
  File.join(root, "writer-variant-bool-string-u64-all-null"), "pk", keys, "payload", all_null.to_unsafe.to_slice(all_null.size),
  rows_per_mark: 3
)
w57_verify_writer(binary, store, all_null_part, "w57_all_null", W57_ORACLE_KEYS, all_null, "all-NULL Variant")

all_bool = Array(CrystalClick::VariantBoolStringUInt64Value).new(W57_ORACLE_KEYS.size) { |index| index.even? }
all_bool_part = CrystalClick::WidePartWriter.write_uint64_variant_bool_string_uint64_pair(
  File.join(root, "writer-variant-bool-string-u64-all-bool"), "pk", keys, "payload", all_bool.to_unsafe.to_slice(all_bool.size),
  rows_per_mark: 3
)
w57_verify_writer(binary, store, all_bool_part, "w57_all_bool", W57_ORACLE_KEYS, all_bool, "all-Bool Variant")

no_bool = Array(CrystalClick::VariantBoolStringUInt64Value).new(W57_ORACLE_KEYS.size) do |index|
  index.even? ? "s#{index}" : (index.to_u64 + 100_u64)
end
no_bool_part = CrystalClick::WidePartWriter.write_uint64_variant_bool_string_uint64_pair(
  File.join(root, "writer-variant-bool-string-u64-no-bool"), "pk", keys, "payload", no_bool.to_unsafe.to_slice(no_bool.size),
  rows_per_mark: 3
)
w57_verify_writer(binary, store, no_bool_part, "w57_no_bool", W57_ORACLE_KEYS, no_bool, "Bool-absent Variant")

puts "PASS W57 Crystal-to-stock Variant(Bool, String, UInt64) oracle"
