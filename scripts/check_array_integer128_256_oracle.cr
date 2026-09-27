require "file_utils"
require "../src/crystal_click"

W39_KEYS    = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]
W39_COLUMNS = {
  {"a_i128", "Int128", false},
  {"a_u128", "UInt128", false},
  {"a_i256", "Int256", false},
  {"a_u256", "UInt256", false},
  {"n_i128", "Int128", true},
  {"n_u128", "UInt128", true},
  {"n_i256", "Int256", true},
  {"n_u256", "UInt256", true},
}

W39_INT256_MIN            = CrystalClick::Int256Value.from_words(0_u64, 0_u64, 0_u64, 0x8000000000000000_u64)
W39_INT256_MAX            = CrystalClick::Int256Value.from_words(UInt64::MAX, UInt64::MAX, UInt64::MAX, 0x7fffffffffffffff_u64)
W39_INT256_MIN_PLUS_ONE   = CrystalClick::Int256Value.from_words(1_u64, 0_u64, 0_u64, 0x8000000000000000_u64)
W39_INT256_NEGATIVE_ONE   = CrystalClick::Int256Value.from_words(UInt64::MAX, UInt64::MAX, UInt64::MAX, UInt64::MAX)
W39_UINT256_MAX_MINUS_ONE = CrystalClick::UInt256Value.from_words(UInt64::MAX - 1_u64, UInt64::MAX, UInt64::MAX, UInt64::MAX)
W39_UINT256_2_128         = CrystalClick::UInt256Value.from_words(0_u64, 0_u64, 1_u64, 0_u64)
W39_UINT256_FORTY_TWO     = CrystalClick::UInt256Value.from_words(42_u64, 0_u64, 0_u64, 0_u64)

W39_INT128_ROWS = [
  [] of Int128,
  [Int128::MIN, -1_i128],
  [0_i128],
  [] of Int128,
  [1_i128, Int128::MAX],
  [Int128::MIN + 1_i128],
  [] of Int128,
] of Array(Int128)
W39_UINT128_ROWS = [
  [] of UInt128,
  [0_u128, UInt128::MAX],
  [1_u128],
  [] of UInt128,
  [UInt128::MAX - 1_u128, 18_446_744_073_709_551_616_u128],
  [42_u128],
  [] of UInt128,
] of Array(UInt128)
W39_INT256_ROWS = [
  [] of CrystalClick::Int256Value,
  [W39_INT256_MIN, W39_INT256_NEGATIVE_ONE],
  [CrystalClick::Int256Value.new(0_u128, 0_u128)],
  [] of CrystalClick::Int256Value,
  [CrystalClick::Int256Value.new(1_u128, 0_u128), W39_INT256_MAX],
  [W39_INT256_MIN_PLUS_ONE],
  [] of CrystalClick::Int256Value,
] of Array(CrystalClick::Int256Value)
W39_UINT256_ROWS = [
  [] of CrystalClick::UInt256Value,
  [CrystalClick::UInt256Value.new(0_u128, 0_u128), CrystalClick::UInt256Value.new(UInt128::MAX, UInt128::MAX)],
  [CrystalClick::UInt256Value.new(1_u128, 0_u128)],
  [] of CrystalClick::UInt256Value,
  [W39_UINT256_MAX_MINUS_ONE, W39_UINT256_2_128],
  [W39_UINT256_FORTY_TWO],
  [] of CrystalClick::UInt256Value,
] of Array(CrystalClick::UInt256Value)

W39_NULLABLE_INT128_ROWS = [
  [] of Int128?, [nil, Int128::MIN, -1_i128] of Int128?, [] of Int128?,
  [0_i128, nil] of Int128?, [Int128::MAX] of Int128?, [nil] of Int128?, [] of Int128?,
] of Array(Int128?)
W39_NULLABLE_UINT128_ROWS = [
  [] of UInt128?, [nil, 0_u128, UInt128::MAX] of UInt128?, [] of UInt128?,
  [1_u128, nil] of UInt128?, [UInt128::MAX - 1_u128] of UInt128?, [nil] of UInt128?, [] of UInt128?,
] of Array(UInt128?)
W39_NULLABLE_INT256_ROWS = [
  [] of CrystalClick::Int256Value?, [nil, W39_INT256_MIN, W39_INT256_NEGATIVE_ONE] of CrystalClick::Int256Value?,
  [] of CrystalClick::Int256Value?,
  [CrystalClick::Int256Value.new(0_u128, 0_u128), nil] of CrystalClick::Int256Value?,
  [W39_INT256_MAX] of CrystalClick::Int256Value?, [nil] of CrystalClick::Int256Value?,
  [] of CrystalClick::Int256Value?,
] of Array(CrystalClick::Int256Value?)
W39_NULLABLE_UINT256_ROWS = [
  [] of CrystalClick::UInt256Value?,
  [nil, CrystalClick::UInt256Value.new(0_u128, 0_u128), CrystalClick::UInt256Value.new(UInt128::MAX, UInt128::MAX)] of CrystalClick::UInt256Value?,
  [] of CrystalClick::UInt256Value?,
  [CrystalClick::UInt256Value.new(1_u128, 0_u128), nil] of CrystalClick::UInt256Value?,
  [W39_UINT256_MAX_MINUS_ONE] of CrystalClick::UInt256Value?, [nil] of CrystalClick::UInt256Value?,
  [] of CrystalClick::UInt256Value?,
] of Array(CrystalClick::UInt256Value?)

def w39_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (#{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

def w39_append_u64(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
end

def w39_append_u128(io : IO, value : UInt128) : Nil
  16.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u128).to_u8) }
end

def w39_append_value(io : IO, value : T) : Nil forall T
  {% if T == Int128 %}
    w39_append_u128(io, value.unsafe_as(UInt128))
  {% elsif T == UInt128 %}
    w39_append_u128(io, value)
  {% elsif T == CrystalClick::Int256Value || T == CrystalClick::UInt256Value %}
    w39_append_u128(io, value.low)
    w39_append_u128(io, value.high)
  {% else %}
    raise "unsupported W39 RowBinary leaf type"
  {% end %}
end

def w39_append_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

def w39_append_array(io : IO, values : Array(T)) : Nil forall T
  w39_append_varuint(io, values.size.to_u64)
  values.each { |value| w39_append_value(io, value) }
end

def w39_append_nullable_array(io : IO, values : Array(T?)) : Nil forall T
  w39_append_varuint(io, values.size.to_u64)
  values.each do |value|
    if value.nil?
      io.write_byte(1_u8)
    else
      io.write_byte(0_u8)
      w39_append_value(io, value.not_nil!)
    end
  end
end

def w39_expected_plain_rowbinary(keys : Array(UInt64), values : Array(Array(T)), selected : Array(Int32)) : Bytes forall T
  output = IO::Memory.new
  selected.each do |index|
    w39_append_u64(output, keys[index])
    w39_append_array(output, values[index])
  end
  output.to_slice
end

def w39_expected_nullable_rowbinary(keys : Array(UInt64), values : Array(Array(T?)), selected : Array(Int32)) : Bytes forall T
  output = IO::Memory.new
  selected.each do |index|
    w39_append_u64(output, keys[index])
    w39_append_nullable_array(output, values[index])
  end
  output.to_slice
end

def w39_assert_rowbinary(actual : String, expected : Bytes, label : String) : Nil
  unless actual.to_slice == expected
    raise "#{label} RowBinary mismatch: expected #{expected.size} bytes, got #{actual.bytesize}"
  end
end

def w39_table_schema(type_name : String, nullable : Bool) : String
  leaf = nullable ? "Nullable(#{type_name})" : type_name
  "pk UInt64, payload Array(#{leaf})"
end

def w39_create_table(binary : String, store : String, table : String, schema : String) : Nil
  w39_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.#{table} (#{schema})
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
  nil
end

def w39_attach_and_check(binary : String, store : String, table : String, schema : String, part : String) : Nil
  w39_create_table(binary, store, table, schema)
  data_path = w39_clickhouse(
    binary,
    store,
    "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{table}' FORMAT TSVRaw"
  ).strip
  raise "#{table}: ClickHouse data path is missing" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  w39_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")

  columns = w39_clickhouse(
    binary,
    store,
    "SELECT name, type FROM system.columns WHERE database = 'default' AND table = '#{table}' ORDER BY position FORMAT TabSeparated"
  ).strip
  expected_columns = schema.split(", ").map_with_index do |column, index|
    name, type = column.split(' ', 2)
    "#{name}\t#{type}"
  end.join('\n')
  raise "#{table}: attached schema differs: #{columns.inspect}" unless columns == expected_columns

  shape = w39_clickhouse(
    binary,
    store,
    "SELECT rows, marks, part_type FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TabSeparated"
  ).strip
  # system.parts.marks counts the .mrk2 EOF sentinel, so four row marks
  # ([2, 2, 2, 1]) are reported as five marks here.
  raise "#{table}: expected 7 rows, 5 marks, Wide; got #{shape.inspect}" unless shape == "7\t5\tWide"
  part_name = w39_clickhouse(
    binary,
    store,
    "SELECT name FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TSVRaw"
  ).strip
  raise "#{table}: active part is missing or ambiguous" if part_name.empty? || part_name.includes?('\n')
  check = w39_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "#{table}: CHECK TABLE failed: #{check.inspect}" unless check == "#{part_name}\t1"
  nil
end

def w39_verify_plain_writer(
  binary : String,
  store : String,
  root : String,
  name : String,
  type_name : String,
  values : Array(Array(T)),
  keys : Array(UInt64),
  selected : Array(Int32),
) : Nil forall T
  part = File.join(root, "writer-#{name}")
  CrystalClick::WidePartWriter.write_uint64_array_numeric_pair(
    part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", values.to_unsafe.to_slice(values.size), rows_per_mark: 2
  )
  table = "w39_array_writer_#{name}"
  w39_attach_and_check(binary, store, table, w39_table_schema(type_name, false), part)
  full = w39_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  w39_assert_rowbinary(full, w39_expected_plain_rowbinary(keys, values, (0...keys.size).map(&.to_i32)), "writer #{name} full")
  ranged = w39_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} WHERE pk >= 2 AND pk < 11 ORDER BY pk FORMAT RowBinary")
  w39_assert_rowbinary(ranged, w39_expected_plain_rowbinary(keys, values, selected), "writer #{name} keyed")
  puts "PASS writer Array(#{type_name}): ATTACH/CHECK, full and keyed RowBinary"
  nil
end

def w39_verify_nullable_writer(
  binary : String,
  store : String,
  root : String,
  name : String,
  type_name : String,
  values : Array(Array(T?)),
  keys : Array(UInt64),
  selected : Array(Int32),
) : Nil forall T
  part = File.join(root, "writer-#{name}")
  CrystalClick::WidePartWriter.write_uint64_array_nullable_numeric_pair(
    part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", values.to_unsafe.to_slice(values.size), rows_per_mark: 2
  )
  table = "w39_array_writer_#{name}"
  w39_attach_and_check(binary, store, table, w39_table_schema(type_name, true), part)
  full = w39_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  w39_assert_rowbinary(full, w39_expected_nullable_rowbinary(keys, values, (0...keys.size).map(&.to_i32)), "writer #{name} full")
  ranged = w39_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} WHERE pk >= 2 AND pk < 11 ORDER BY pk FORMAT RowBinary")
  w39_assert_rowbinary(ranged, w39_expected_nullable_rowbinary(keys, values, selected), "writer #{name} keyed")
  puts "PASS writer Array(Nullable(#{type_name})): ATTACH/CHECK, full and keyed RowBinary"
  nil
end

def w39_expected_stock_rowbinary(selected : Array(Int32)) : Bytes
  output = IO::Memory.new
  selected.each do |index|
    w39_append_u64(output, W39_KEYS[index])
    w39_append_array(output, W39_INT128_ROWS[index])
    w39_append_array(output, W39_UINT128_ROWS[index])
    w39_append_array(output, W39_INT256_ROWS[index])
    w39_append_array(output, W39_UINT256_ROWS[index])
    w39_append_nullable_array(output, W39_NULLABLE_INT128_ROWS[index])
    w39_append_nullable_array(output, W39_NULLABLE_UINT128_ROWS[index])
    w39_append_nullable_array(output, W39_NULLABLE_INT256_ROWS[index])
    w39_append_nullable_array(output, W39_NULLABLE_UINT256_ROWS[index])
  end
  output.to_slice
end

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("CLICKHOUSE_STORE")
root = ENV.fetch("ORACLE_ROOT")
stock_part = ENV.fetch("STOCK_PART")
selected = W39_KEYS.each_with_index.compact_map do |key, index|
  index.to_i32 if key >= 2_u64 && key < 11_u64
end.to_a

stock_schema = String.build do |io|
  io << "pk UInt64"
  W39_COLUMNS.each do |(column, type_name, nullable)|
    leaf = nullable ? "Nullable(#{type_name})" : type_name
    io << ", " << column << " Array(" << leaf << ')'
  end
end
w39_attach_and_check(binary, store, "w39_array_stock", stock_schema, stock_part)
stock_select = "pk, " + W39_COLUMNS.map(&.[0]).join(", ")
stock_full = w39_clickhouse(binary, store, "SELECT #{stock_select} FROM default.w39_array_stock ORDER BY pk FORMAT RowBinary")
w39_assert_rowbinary(stock_full, w39_expected_stock_rowbinary((0...W39_KEYS.size).map(&.to_i32)), "stock eight-column full")
stock_range = w39_clickhouse(binary, store, "SELECT #{stock_select} FROM default.w39_array_stock WHERE pk >= 2 AND pk < 11 ORDER BY pk FORMAT RowBinary")
w39_assert_rowbinary(stock_range, w39_expected_stock_rowbinary(selected), "stock eight-column keyed")
puts "PASS stock W39 part: ATTACH/CHECK, exact eight-column full and keyed RowBinary"

w39_verify_plain_writer(binary, store, root, "i128", "Int128", W39_INT128_ROWS, W39_KEYS, selected)
w39_verify_plain_writer(binary, store, root, "u128", "UInt128", W39_UINT128_ROWS, W39_KEYS, selected)
w39_verify_plain_writer(binary, store, root, "i256", "Int256", W39_INT256_ROWS, W39_KEYS, selected)
w39_verify_plain_writer(binary, store, root, "u256", "UInt256", W39_UINT256_ROWS, W39_KEYS, selected)
w39_verify_nullable_writer(binary, store, root, "n_i128", "Int128", W39_NULLABLE_INT128_ROWS, W39_KEYS, selected)
w39_verify_nullable_writer(binary, store, root, "n_u128", "UInt128", W39_NULLABLE_UINT128_ROWS, W39_KEYS, selected)
w39_verify_nullable_writer(binary, store, root, "n_i256", "Int256", W39_NULLABLE_INT256_ROWS, W39_KEYS, selected)
w39_verify_nullable_writer(binary, store, root, "n_u256", "UInt256", W39_NULLABLE_UINT256_ROWS, W39_KEYS, selected)

puts "PASS W39 bidirectional ClickHouse oracle: stock plus writer, eight Array integer shapes, full/keyed RowBinary and CHECK TABLE"
