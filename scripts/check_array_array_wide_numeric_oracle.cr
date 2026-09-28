require "file_utils"
require "../src/crystal_click"

private def w62_clickhouse(binary : String, store : String, query : String, input : IO = IO::Memory.new) : String
  output = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], input: input, output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (#{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

private def w62_u64(io : IO, value : UInt64) : Nil
  8.times { |byte| io.write_byte(((value >> (byte * 8)) & 0xff_u64).to_u8) }
end

private def w62_u128(io : IO, value : UInt128) : Nil
  16.times { |byte| io.write_byte(((value >> (byte * 8)) & 0xff_u128).to_u8) }
end

private def w62_varuint(io : IO, value : UInt64) : Nil
  while value >= 0x80_u64
    io.write_byte(((value & 0x7f_u64) | 0x80_u64).to_u8)
    value >>= 7
  end
  io.write_byte(value.to_u8)
end

# Independent RowBinary leaf encoder: deliberately does not call the writer.
private def w62_leaf(io : IO, value : T) : Nil forall T
  {% if T == Int128 %}
    w62_u128(io, value.unsafe_as(UInt128))
  {% elsif T == UInt128 %}
    w62_u128(io, value)
  {% elsif T == CrystalClick::Int256Value || T == CrystalClick::UInt256Value %}
    w62_u128(io, value.low)
    w62_u128(io, value.high)
  {% elsif T == CrystalClick::BFloat16Value %}
    io.write_byte((value.bits & 0xff_u16).to_u8)
    io.write_byte((value.bits >> 8).to_u8)
  {% else %}
    raise "unsupported W62 oracle leaf"
  {% end %}
end

private def w62_row(io : IO, row : Array(Array(T))) : Nil forall T
  w62_varuint(io, row.size.to_u64)
  row.each do |inner|
    w62_varuint(io, inner.size.to_u64)
    inner.each { |value| w62_leaf(io, value) }
  end
end

private def w62_nullable_row(io : IO, row : Array(Array(T?))) : Nil forall T
  w62_varuint(io, row.size.to_u64)
  row.each do |inner|
    w62_varuint(io, inner.size.to_u64)
    inner.each do |value|
      if value.nil?
        io.write_byte(1_u8)
      else
        io.write_byte(0_u8)
        w62_leaf(io, value.not_nil!)
      end
    end
  end
end

private def w62_rowbinary(keys : Array(UInt64), rows : Array(Array(Array(T))), indices : Array(Int32)) : Bytes forall T
  io = IO::Memory.new
  indices.each do |index|
    w62_u64(io, keys[index])
    w62_row(io, rows[index])
  end
  io.to_slice
end

private def w62_nullable_rowbinary(keys : Array(UInt64), rows : Array(Array(Array(T?))), indices : Array(Int32)) : Bytes forall T
  io = IO::Memory.new
  indices.each do |index|
    w62_u64(io, keys[index])
    w62_nullable_row(io, rows[index])
  end
  io.to_slice
end

private def w62_query_rows(binary : String, store : String, table : String, keys : Array(UInt64), expected : Bytes, ranged : Bytes) : Nil
  full_query = "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary"
  full = w62_clickhouse(binary, store, full_query)
  raise "#{table} full RowBinary mismatch" unless full.to_slice == expected
  range_query = "SELECT pk, payload FROM default.#{table} WHERE pk >= 2 AND pk < 10 ORDER BY pk FORMAT RowBinary"
  selected = w62_clickhouse(binary, store, range_query)
  raise "#{table} key-range RowBinary mismatch" unless selected.to_slice == ranged
end

private def w62_create_table(binary : String, store : String, table : String, declaration : String) : Nil
  w62_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.#{table} (pk UInt64, payload #{declaration})
  ENGINE = MergeTree ORDER BY pk
  SETTINGS index_granularity = 2, index_granularity_bytes = 10485760,
    enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0,
    min_bytes_for_wide_part = 0, compress_marks = 0,
    min_compress_block_size = 0, max_compress_block_size = 4096,
    ratio_of_defaults_for_sparse_serialization = 1.0,
    default_compression_codec = 'LZ4'
  SQL
end

private def w62_check_table(binary : String, store : String, table : String) : Nil
  result = w62_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "#{table} CHECK TABLE failed: #{result.inspect}" unless result == "all_1_1_0\t1"
end

private def w62_stock_part(binary : String, store : String, root : String, table : String) : String
  path = w62_clickhouse(binary, store, "SELECT path FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TSVRaw").strip
  raise "#{table} source part missing" unless Dir.exists?(path)
  part = File.join(root, "stock-#{table}")
  FileUtils.cp_r(path, part)
  part
end

private def w62_assert_topology(part : String, declaration : String, nullable : Bool) : Nil
  expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` #{declaration}\n"
  raise "#{part} columns differ" unless File.read(File.join(part, "columns.txt")) == expected_columns
  stream_names = nullable ? ["payload.size0", "payload.size1", "payload.null", "payload"] : ["payload.size0", "payload.size1", "payload"]
  expected_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n#{stream_names.size} substreams for column `payload`:\n" + stream_names.map { |name| "\t#{name}\n" }.join
  raise "#{part} substreams differ" unless File.read(File.join(part, "columns_substreams.txt")) == expected_substreams
  serialization = File.read(File.join(part, "serialization.json")).strip
  expected_serialization = %({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
  raise "#{part} serialization differs" unless serialization == expected_serialization
  stream_names.each do |stream|
    marks = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
    raise "#{part} #{stream} mark size differs" unless marks.size == 5 * CrystalClick::WidePart::MARK_SIZE
    [2_u64, 2_u64, 2_u64, 1_u64, 0_u64].each_with_index do |expected_rows, index|
      offset = index * CrystalClick::WidePart::MARK_SIZE + 16
      observed_rows = 0_u64
      8.times { |byte| observed_rows |= marks[offset + byte].to_u64 << (byte * 8) }
      raise "#{part} #{stream} mark #{index} rows differ" unless observed_rows == expected_rows
    end
  end
end

private def w62_attach(binary : String, store : String, table : String, part : String) : Nil
  data_path = w62_clickhouse(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{table}' FORMAT TSVRaw").strip
  raise "#{table} data path missing" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  w62_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  w62_check_table(binary, store, table)
end

private def w62_rows(zero : T, positive : T, extreme : T) : Array(Array(Array(T))) forall T
  [
    [[positive, zero] of T, [] of T],
    [[extreme] of T],
    [] of Array(T),
    [[] of T],
    [[zero] of T],
    [] of Array(T),
    [[extreme, positive] of T],
  ] of Array(Array(T))
end

private def w62_nullable_rows(zero : T, positive : T, extreme : T) : Array(Array(Array(T?))) forall T
  [
    [[positive, nil, zero] of T?, [] of T?],
    [[extreme] of T?],
    [] of Array(T?),
    [[] of T?],
    [[nil, nil] of T?],
    [[nil] of T?],
    [[extreme, positive] of T?],
  ] of Array(Array(T?))
end

private def w62_verify_plain(binary : String, store : String, root : String, label : String, type : T.class, zero : T, positive : T, extreme : T) : Nil forall T
  declaration = "Array(Array(#{CrystalClick::WidePart.array_numeric_type_name(type)}))"
  keys = [1_u64, 2_u64, 4_u64, 7_u64, 10_u64, 11_u64, 12_u64]
  rows = w62_rows(zero, positive, extreme)
  all = (0...keys.size).map(&.to_i32)
  selected = keys.each_with_index.compact_map { |key, index| index.to_i32 if key >= 2_u64 && key < 10_u64 }.to_a
  expected = w62_rowbinary(keys, rows, all)
  ranged = w62_rowbinary(keys, rows, selected)

  source = "w62_source_plain_#{label}"
  w62_create_table(binary, store, source, declaration)
  w62_clickhouse(binary, store, "INSERT INTO default.#{source} FORMAT RowBinary", IO::Memory.new(expected))
  w62_check_table(binary, store, source)
  w62_query_rows(binary, store, source, keys, expected, ranged)
  stock_part = w62_stock_part(binary, store, root, source)
  w62_assert_topology(stock_part, declaration, false)
  reader = CrystalClick::WidePart.open_typed(stock_part, "payload")
  raise "#{source} Crystal read differs" unless reader.read_array_array_numeric_mark_range("payload", 0, reader.mark_count, type) == rows
  raise "#{source} Crystal selected mark differs" unless reader.read_array_array_numeric_mark_range("payload", 3, 1, type) == rows[6, 1]

  writer_part = File.join(root, "writer-plain-#{label}")
  CrystalClick::WidePartWriter.write_uint64_array_array_numeric_pair(writer_part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size), rows_per_mark: 2)
  w62_assert_topology(writer_part, declaration, false)
  target = "w62_writer_plain_#{label}"
  w62_create_table(binary, store, target, declaration)
  w62_attach(binary, store, target, writer_part)
  w62_query_rows(binary, store, target, keys, expected, ranged)
end

private def w62_verify_nullable(binary : String, store : String, root : String, label : String, type : T.class, zero : T, positive : T, extreme : T) : Nil forall T
  declaration = "Array(Array(Nullable(#{CrystalClick::WidePart.array_numeric_type_name(type)})))"
  keys = [1_u64, 2_u64, 4_u64, 7_u64, 10_u64, 11_u64, 12_u64]
  rows = w62_nullable_rows(zero, positive, extreme)
  all = (0...keys.size).map(&.to_i32)
  selected = keys.each_with_index.compact_map { |key, index| index.to_i32 if key >= 2_u64 && key < 10_u64 }.to_a
  expected = w62_nullable_rowbinary(keys, rows, all)
  ranged = w62_nullable_rowbinary(keys, rows, selected)

  source = "w62_source_nullable_#{label}"
  w62_create_table(binary, store, source, declaration)
  w62_clickhouse(binary, store, "INSERT INTO default.#{source} FORMAT RowBinary", IO::Memory.new(expected))
  w62_check_table(binary, store, source)
  w62_query_rows(binary, store, source, keys, expected, ranged)
  stock_part = w62_stock_part(binary, store, root, source)
  w62_assert_topology(stock_part, declaration, true)
  reader = CrystalClick::WidePart.open_typed(stock_part, "payload")
  raise "#{source} Crystal read differs" unless reader.read_array_array_nullable_numeric_mark_range("payload", 0, reader.mark_count, type) == rows
  raise "#{source} Crystal selected mark differs" unless reader.read_array_array_nullable_numeric_mark_range("payload", 3, 1, type) == rows[6, 1]

  writer_part = File.join(root, "writer-nullable-#{label}")
  CrystalClick::WidePartWriter.write_uint64_array_array_nullable_numeric_pair(writer_part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size), rows_per_mark: 2)
  w62_assert_topology(writer_part, declaration, true)
  target = "w62_writer_nullable_#{label}"
  w62_create_table(binary, store, target, declaration)
  w62_attach(binary, store, target, writer_part)
  w62_query_rows(binary, store, target, keys, expected, ranged)
end

private def w62_verify_both(binary : String, store : String, root : String, label : String, type : T.class, zero : T, positive : T, extreme : T) : Nil forall T
  w62_verify_plain(binary, store, root, label, type, zero, positive, extreme)
  w62_verify_nullable(binary, store, root, label, type, zero, positive, extreme)
end

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("CLICKHOUSE_STORE")
root = ENV.fetch("ORACLE_ROOT")
w62_verify_both(binary, store, root, "i128", Int128, 0_i128, 1_i128, Int128::MIN)
w62_verify_both(binary, store, root, "u128", UInt128, 0_u128, 1_u128, UInt128::MAX)
w62_verify_both(
  binary, store, root, "i256", CrystalClick::Int256Value,
  CrystalClick::Int256Value.from_words(0_u64, 0_u64, 0_u64, 0_u64),
  CrystalClick::Int256Value.from_words(1_u64, 0_u64, 0_u64, 0_u64),
  CrystalClick::Int256Value.from_words(0_u64, 0_u64, 0_u64, 0x8000000000000000_u64)
)
w62_verify_both(
  binary, store, root, "u256", CrystalClick::UInt256Value,
  CrystalClick::UInt256Value.from_words(0_u64, 0_u64, 0_u64, 0_u64),
  CrystalClick::UInt256Value.from_words(1_u64, 0_u64, 0_u64, 0_u64),
  CrystalClick::UInt256Value.from_words(UInt64::MAX, UInt64::MAX, UInt64::MAX, UInt64::MAX)
)
w62_verify_both(
  binary, store, root, "bf16", CrystalClick::BFloat16Value,
  CrystalClick::BFloat16Value.new(0_u16),
  CrystalClick::BFloat16Value.new(0x3f80_u16),
  CrystalClick::BFloat16Value.new(0xbf80_u16)
)

puts "W62 stock oracle passed: five wide numeric leaves, plain and BASIC nullable, both read/write directions, CHECK TABLE, exact metadata, full/key-range RowBinary"
