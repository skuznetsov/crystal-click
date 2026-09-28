require "file_utils"
require "../src/crystal_click"

W66_KEYS       = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]
W66_ALL_ROWS   = [0_i32, 1_i32, 2_i32, 3_i32, 4_i32, 5_i32, 6_i32]
W66_RANGE_ROWS = [2_i32, 3_i32, 4_i32]
W66_MARK_ROWS  = [2_u64, 2_u64, 2_u64, 1_u64, 0_u64]

def w66o_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (#{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

def w66o_clickhouse_input(binary : String, store : String, query : String, input : IO) : String
  output = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], input: input, output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse RowBinary insert failed (#{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

def w66o_append_u64(io : IO, value : UInt64) : Nil
  8.times { |byte| io.write_byte(((value >> (byte * 8)) & 0xff_u64).to_u8) }
end

def w66o_append_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

def w66o_append_scalar(io : IO, value : T) : Nil forall T
  {% if T == Int32 %}
    bits = value.unsafe_as(UInt32).to_u64
    4.times { |byte| io.write_byte(((bits >> (byte * 8)) & 0xff_u64).to_u8) }
  {% elsif T == Int64 %}
    bits = value.unsafe_as(UInt64)
    8.times { |byte| io.write_byte(((bits >> (byte * 8)) & 0xff_u64).to_u8) }
  {% else %}
    {% raise "unsupported W66 Time carrier" %}
  {% end %}
end

def w66o_append_row(io : IO, row : Array(Array(T))) : Nil forall T
  w66o_append_varuint(io, row.size.to_u64)
  row.each do |inner|
    w66o_append_varuint(io, inner.size.to_u64)
    inner.each { |value| w66o_append_scalar(io, value) }
  end
end

def w66o_append_nullable_row(io : IO, row : Array(Array(T?))) : Nil forall T
  w66o_append_varuint(io, row.size.to_u64)
  row.each do |inner|
    w66o_append_varuint(io, inner.size.to_u64)
    inner.each do |value|
      if value.nil?
        io.write_byte(1_u8)
      else
        io.write_byte(0_u8)
        w66o_append_scalar(io, value.not_nil!)
      end
    end
  end
end

def w66o_expected(keys : Array(UInt64), values : Array(Array(Array(T))), selected : Array(Int32)) : Bytes forall T
  io = IO::Memory.new
  selected.each do |index|
    w66o_append_u64(io, keys[index])
    w66o_append_row(io, values[index])
  end
  io.to_slice
end

def w66o_expected_nullable(keys : Array(UInt64), values : Array(Array(Array(T?))), selected : Array(Int32)) : Bytes forall T
  io = IO::Memory.new
  selected.each do |index|
    w66o_append_u64(io, keys[index])
    w66o_append_nullable_row(io, values[index])
  end
  io.to_slice
end

def w66o_assert_rowbinary(actual : String, expected : Bytes, label : String) : Nil
  raise "#{label} RowBinary differs (#{actual.bytesize} bytes != #{expected.size})" unless actual.to_slice == expected
end

def w66o_values(type : T.class, scale : Int32 = 0) : Array(Array(Array(T))) forall T
  rows = [] of Array(Array(T))
  {% if T == Int32 %}
    rows << [] of Array(T)
    rows << [[] of T]
    rows << [[-3_599_999_i32, -1_i32, 0_i32, 1_i32, 3_599_999_i32] of T]
    rows << [[-3_600_000_i32] of T, [] of T]
    rows << [] of Array(T)
    rows << [[] of T]
    rows << [[999_i32] of T]
  {% elsif T == Int64 %}
    factor = 1_i64
    scale.times { factor *= 10_i64 }
    limit = 3_599_999_i64 * factor
    rows << [] of Array(T)
    rows << [[] of T]
    rows << [[-limit, -1_234_i64, 0_i64, 1_i64, limit] of T]
    rows << [[-limit + 1_i64] of T, [] of T]
    rows << [] of Array(T)
    rows << [[] of T]
    rows << [[999_i64 * factor] of T]
  {% else %}
    {% raise "unsupported W66 Time carrier" %}
  {% end %}
  rows
end

def w66o_nullable_values(type : T.class, scale : Int32 = 0) : Array(Array(Array(T?))) forall T
  rows = [] of Array(Array(T?))
  {% if T == Int32 %}
    rows << [] of Array(T?)
    rows << [[] of T?]
    rows << [[nil, nil] of T?, [] of T?]
    rows << [[nil] of T?, [nil, nil] of T?]
    rows << [] of Array(T?)
    rows << [[] of T?]
    rows << [[nil, -1_i32, 0_i32, 1_i32] of T?]
  {% elsif T == Int64 %}
    factor = 1_i64
    scale.times { factor *= 10_i64 }
    limit = 3_599_999_i64 * factor
    rows << [] of Array(T?)
    rows << [[] of T?]
    rows << [[nil, nil] of T?, [] of T?]
    rows << [[nil] of T?, [nil, nil] of T?]
    rows << [] of Array(T?)
    rows << [[] of T?]
    rows << [[nil, -1_234_i64, 0_i64, 1_i64, limit] of T?]
  {% else %}
    {% raise "unsupported W66 Time carrier" %}
  {% end %}
  rows
end

def w66o_writer_values(type : T.class, scale : Int32 = 0) : Array(Array(Array(T))) forall T
  rows = [] of Array(Array(T))
  {% if T == Int32 %}
    rows << [] of Array(T)
    rows << [[] of T]
    rows << [[0_i32, -1_i32] of T]
    rows << [[3_599_999_i32] of T, [] of T]
    rows << [[] of T]
    rows << [] of Array(T)
    rows << [[Int32::MIN, Int32::MAX] of T]
  {% elsif T == Int64 %}
    factor = 1_i64
    scale.times { factor *= 10_i64 }
    limit = 3_599_999_i64 * factor
    rows << [] of Array(T)
    rows << [[] of T]
    rows << [[0_i64, -factor] of T]
    rows << [[limit] of T, [] of T]
    rows << [[] of T]
    rows << [] of Array(T)
    rows << [[Int64::MIN, Int64::MAX] of T]
  {% else %}
    {% raise "unsupported W66 Time carrier" %}
  {% end %}
  rows
end

def w66o_writer_nullable_values(type : T.class, scale : Int32 = 0) : Array(Array(Array(T?))) forall T
  rows = [] of Array(Array(T?))
  {% if T == Int32 %}
    rows << [] of Array(T?)
    rows << [[] of T?]
    rows << [[nil, nil] of T?, [] of T?]
    rows << [[nil] of T?, [nil, nil] of T?]
    rows << [] of Array(T?)
    rows << [[] of T?]
    rows << [[nil, Int32::MIN, 0_i32, Int32::MAX] of T?]
  {% elsif T == Int64 %}
    rows << [] of Array(T?)
    rows << [[] of T?]
    rows << [[nil, nil] of T?, [] of T?]
    rows << [[nil] of T?, [nil, nil] of T?]
    rows << [] of Array(T?)
    rows << [[] of T?]
    rows << [[nil, Int64::MIN, 0_i64, Int64::MAX] of T?]
  {% else %}
    {% raise "unsupported W66 Time carrier" %}
  {% end %}
  rows
end

def w66o_reader_plain(reader : CrystalClick::WidePart, column : String, type : T.class, count : Int) : Array(Array(Array(T))) forall T
  {% if T == Int32 %}
    reader.read_array_array_time_seconds_mark_range(column, 0, count)
  {% elsif T == Int64 %}
    reader.read_array_array_time64_ticks_mark_range(column, 0, count)
  {% else %}
    {% raise "unsupported W66 reader carrier" %}
  {% end %}
end

def w66o_reader_nullable(reader : CrystalClick::WidePart, column : String, type : T.class, count : Int) : Array(Array(Array(T?))) forall T
  {% if T == Int32 %}
    reader.read_array_array_nullable_time_seconds_mark_range(column, 0, count)
  {% elsif T == Int64 %}
    reader.read_array_array_nullable_time64_ticks_mark_range(column, 0, count)
  {% else %}
    {% raise "unsupported W66 reader carrier" %}
  {% end %}
end

def w66o_assert_stock_metadata(part : String, declaration : String, nullable : Bool) : Nil
  leaf = nullable ? "Nullable(#{declaration})" : declaration
  expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` Array(Array(#{leaf}))\n"
  raise "stock columns.txt differs: #{part}" unless File.read(File.join(part, "columns.txt")) == expected_columns
  nested = nullable ? "4 substreams for column `payload`:\n\tpayload.size0\n\tpayload.size1\n\tpayload.null\n\tpayload\n" : "3 substreams for column `payload`:\n\tpayload.size0\n\tpayload.size1\n\tpayload\n"
  expected_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n#{nested}"
  raise "stock columns_substreams.txt differs: #{part}" unless File.read(File.join(part, "columns_substreams.txt")) == expected_substreams
  expected_serialization = %({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
  raise "stock serialization metadata differs: #{part}" unless File.read(File.join(part, "serialization.json")) == expected_serialization
  raise "stock codec metadata differs: #{part}" unless File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)"
  streams = ["pk", "payload.size0", "payload.size1", "payload"]
  streams.insert(3, "payload.null") if nullable
  streams.each do |stream|
    stem = CrystalClick::StreamName.hash(stream)
    mark_path = File.join(part, "#{stem}.mrk2")
    raise "stock part missing .mrk2: #{stream}" unless File.file?(mark_path)
    raise "stock part has legacy .mrk: #{stream}" if File.exists?(File.join(part, "#{stem}.mrk"))
    bytes = File.read(mark_path).to_slice
    raise "stock mark width differs for #{stream}" unless bytes.size == W66_MARK_ROWS.size * CrystalClick::WidePart::MARK_SIZE
    row_counts = Array(UInt64).new(W66_MARK_ROWS.size) do |mark|
      offset = mark * CrystalClick::WidePart::MARK_SIZE + 16
      8.times.reduce(0_u64) { |value, byte| value | (bytes[offset + byte].to_u64 << (byte * 8)) }
    end
    raise "stock mark rows differ for #{stream}: #{row_counts.inspect}" unless row_counts == W66_MARK_ROWS
  end
end

def w66o_assert_stock_plain(part : String, declaration : String, values : Array(Array(Array(T))), label : String) : Nil forall T
  reader = CrystalClick::WidePart.open_typed(part, "payload")
  expected_type = "Array(Array(#{declaration}))"
  raise "#{label} type differs: #{reader.column_type}" unless reader.column_type == expected_type
  raise "#{label} mark rows differ" unless reader.mark_row_counts == [2_u64, 2_u64, 2_u64, 1_u64]
  raise "#{label} full raw values differ" unless w66o_reader_plain(reader, "payload", T, reader.mark_count) == values
  raise "#{label} later-mark values differ" unless {% if T == Int32 %} reader.read_array_array_time_seconds_mark_range("payload", 1, 2) {% else %} reader.read_array_array_time64_ticks_mark_range("payload", 1, 2) {% end %} == values[2, 4]
end

def w66o_assert_stock_nullable(part : String, declaration : String, values : Array(Array(Array(T?))), label : String) : Nil forall T
  reader = CrystalClick::WidePart.open_typed(part, "payload")
  expected_type = "Array(Array(Nullable(#{declaration})))"
  raise "#{label} type differs: #{reader.column_type}" unless reader.column_type == expected_type
  raise "#{label} mark rows differ" unless reader.mark_row_counts == [2_u64, 2_u64, 2_u64, 1_u64]
  raise "#{label} full nullable values differ" unless w66o_reader_nullable(reader, "payload", T, reader.mark_count) == values
  later = {% if T == Int32 %} reader.read_array_array_nullable_time_seconds_mark_range("payload", 1, 2) {% else %} reader.read_array_array_nullable_time64_ticks_mark_range("payload", 1, 2) {% end %}
  raise "#{label} later-mark nullable values differ" unless later == values[2, 4]
end

def w66o_create_table(binary : String, store : String, table : String, declaration : String, nullable : Bool) : Nil
  leaf = nullable ? "Nullable(#{declaration})" : declaration
  w66o_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.#{table} (pk UInt64, payload Array(Array(#{leaf})))
  ENGINE = MergeTree ORDER BY pk
  SETTINGS index_granularity = 2, index_granularity_bytes = 10485760,
      enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0,
      min_bytes_for_wide_part = 0, compress_marks = 0,
      min_compress_block_size = 0, max_compress_block_size = 4096,
      ratio_of_defaults_for_sparse_serialization = 1.0,
      default_compression_codec = 'LZ4';
  SQL
  nil
end

def w66o_attach(binary : String, store : String, table : String, part : String) : Nil
  data_path = w66o_clickhouse(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{table}' FORMAT TSVRaw").strip
  raise "no ClickHouse data path for #{table}" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  w66o_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  check = w66o_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "ATTACH/CHECK failed for #{table}: #{check.inspect}" unless check == "all_1_1_0\t1"
end

def w66o_write_plain(part : String, type : T.class, scale : Int32, values : Array(Array(Array(T)))) : Nil forall T
  keys = W66_KEYS.to_unsafe.to_slice(W66_KEYS.size)
  data = values.to_unsafe.to_slice(values.size)
  {% if T == Int32 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_time_pair(part, "pk", keys, "payload", data, rows_per_mark: 2)
  {% elsif T == Int64 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_time64_pair(part, "pk", keys, "payload", data, scale, rows_per_mark: 2)
  {% else %}
    {% raise "unsupported W66 writer carrier" %}
  {% end %}
end

def w66o_write_nullable(part : String, type : T.class, scale : Int32, values : Array(Array(Array(T?)))) : Nil forall T
  keys = W66_KEYS.to_unsafe.to_slice(W66_KEYS.size)
  data = values.to_unsafe.to_slice(values.size)
  {% if T == Int32 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_nullable_time_pair(part, "pk", keys, "payload", data, rows_per_mark: 2)
  {% elsif T == Int64 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_nullable_time64_pair(part, "pk", keys, "payload", data, scale, rows_per_mark: 2)
  {% else %}
    {% raise "unsupported W66 nullable writer carrier" %}
  {% end %}
end

def w66o_stock_to_crystal_plain(binary : String, store : String, root : String, label : String, declaration : String, values : Array(Array(Array(T)))) : Nil forall T
  table = "w66_stock_#{label}"
  w66o_create_table(binary, store, table, declaration, false)
  input = IO::Memory.new
  W66_KEYS.each_with_index do |key, index|
    w66o_append_u64(input, key)
    w66o_append_row(input, values[index])
  end
  input.rewind
  w66o_clickhouse_input(binary, store, "INSERT INTO default.#{table} FORMAT RowBinary", input)
  row_count = w66o_clickhouse(binary, store, "SELECT count() FROM default.#{table} FORMAT TSVRaw").strip
  raise "stock source inserted #{row_count} rows instead of 7" unless row_count == "7"
  check = w66o_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "stock source CHECK TABLE failed: #{check.inspect}" unless check == "all_1_1_0\t1"
  source = w66o_clickhouse(binary, store, "SELECT path FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").strip
  part = File.join(root, "stock-#{label}")
  FileUtils.cp_r(source, part)
  w66o_assert_stock_metadata(part, declaration, false)
  w66o_assert_stock_plain(part, declaration, values, "stock #{label}")
  full = w66o_clickhouse(binary, store, "SELECT pk,payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  keyed = w66o_clickhouse(binary, store, "SELECT pk,payload FROM default.#{table} WHERE pk >= 4 AND pk < 11 ORDER BY pk FORMAT RowBinary")
  w66o_assert_rowbinary(full, w66o_expected(W66_KEYS, values, W66_ALL_ROWS), "stock #{label} full")
  w66o_assert_rowbinary(keyed, w66o_expected(W66_KEYS, values, W66_RANGE_ROWS), "stock #{label} keyed")
  puts "Stock→Crystal #{label}: exact type, full/later-mark raw reads, full/keyed RowBinary"
end

def w66o_stock_to_crystal_nullable(binary : String, store : String, root : String, label : String, declaration : String, values : Array(Array(Array(T?)))) : Nil forall T
  table = "w66_stock_#{label}"
  w66o_create_table(binary, store, table, declaration, true)
  input = IO::Memory.new
  W66_KEYS.each_with_index do |key, index|
    w66o_append_u64(input, key)
    w66o_append_nullable_row(input, values[index])
  end
  input.rewind
  w66o_clickhouse_input(binary, store, "INSERT INTO default.#{table} FORMAT RowBinary", input)
  row_count = w66o_clickhouse(binary, store, "SELECT count() FROM default.#{table} FORMAT TSVRaw").strip
  raise "stock source inserted #{row_count} rows instead of 7" unless row_count == "7"
  check = w66o_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "stock source CHECK TABLE failed: #{check.inspect}" unless check == "all_1_1_0\t1"
  source = w66o_clickhouse(binary, store, "SELECT path FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").strip
  part = File.join(root, "stock-#{label}")
  FileUtils.cp_r(source, part)
  w66o_assert_stock_metadata(part, declaration, true)
  w66o_assert_stock_nullable(part, declaration, values, "stock #{label}")
  full = w66o_clickhouse(binary, store, "SELECT pk,payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  keyed = w66o_clickhouse(binary, store, "SELECT pk,payload FROM default.#{table} WHERE pk >= 4 AND pk < 11 ORDER BY pk FORMAT RowBinary")
  w66o_assert_rowbinary(full, w66o_expected_nullable(W66_KEYS, values, W66_ALL_ROWS), "stock #{label} full")
  w66o_assert_rowbinary(keyed, w66o_expected_nullable(W66_KEYS, values, W66_RANGE_ROWS), "stock #{label} keyed")
  puts "Stock→Crystal #{label}: exact type, full/later-mark raw reads, full/keyed RowBinary"
end

def w66o_crystal_to_stock_plain(binary : String, store : String, root : String, label : String, declaration : String, scale : Int32, values : Array(Array(Array(T)))) : Nil forall T
  part = File.join(root, "writer-#{label}")
  w66o_write_plain(part, T, scale, values)
  table = "w66_writer_#{label}"
  w66o_create_table(binary, store, table, declaration, false)
  w66o_attach(binary, store, table, part)
  full = w66o_clickhouse(binary, store, "SELECT pk,payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  keyed = w66o_clickhouse(binary, store, "SELECT pk,payload FROM default.#{table} WHERE pk >= 4 AND pk < 11 ORDER BY pk FORMAT RowBinary")
  w66o_assert_rowbinary(full, w66o_expected(W66_KEYS, values, W66_ALL_ROWS), "writer #{label} full")
  w66o_assert_rowbinary(keyed, w66o_expected(W66_KEYS, values, W66_RANGE_ROWS), "writer #{label} keyed")
  puts "Crystal→stock #{label}: ATTACH PART/CHECK TABLE and exact full/keyed RowBinary"
end

def w66o_crystal_to_stock_nullable(binary : String, store : String, root : String, label : String, declaration : String, scale : Int32, values : Array(Array(Array(T?)))) : Nil forall T
  part = File.join(root, "writer-#{label}")
  w66o_write_nullable(part, T, scale, values)
  table = "w66_writer_#{label}"
  w66o_create_table(binary, store, table, declaration, true)
  w66o_attach(binary, store, table, part)
  full = w66o_clickhouse(binary, store, "SELECT pk,payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  keyed = w66o_clickhouse(binary, store, "SELECT pk,payload FROM default.#{table} WHERE pk >= 4 AND pk < 11 ORDER BY pk FORMAT RowBinary")
  w66o_assert_rowbinary(full, w66o_expected_nullable(W66_KEYS, values, W66_ALL_ROWS), "writer #{label} full")
  w66o_assert_rowbinary(keyed, w66o_expected_nullable(W66_KEYS, values, W66_RANGE_ROWS), "writer #{label} keyed")
  puts "Crystal→stock #{label}: ATTACH PART/CHECK TABLE and exact full/keyed RowBinary"
end

def w66o_run(binary : String, store : String, root : String, type : T.class, declaration : String, scale : Int32, nullable : Bool) : Nil forall T
  suffix = T == Int32 ? "time" : "time64_#{scale}"
  label = nullable ? "nullable_#{suffix}" : suffix
  if nullable
    stock = w66o_nullable_values(T, scale)
    w66o_stock_to_crystal_nullable(binary, store, root, label, declaration, stock)
    writer = w66o_writer_nullable_values(T, scale)
    w66o_crystal_to_stock_nullable(binary, store, root, label, declaration, scale, writer)
  else
    stock = w66o_values(T, scale)
    w66o_stock_to_crystal_plain(binary, store, root, label, declaration, stock)
    writer = w66o_writer_values(T, scale)
    w66o_crystal_to_stock_plain(binary, store, root, label, declaration, scale, writer)
  end
end

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("CLICKHOUSE_STORE")
root = ENV.fetch("ORACLE_ROOT")

w66o_run(binary, store, root, Int32, "Time", 0, false)
w66o_run(binary, store, root, Int32, "Time", 0, true)
{0, 3, 9}.each do |scale|
  declaration = "Time64(#{scale})"
  w66o_run(binary, store, root, Int64, declaration, scale, false)
  w66o_run(binary, store, root, Int64, declaration, scale, true)
end

puts "W66 bidirectional oracle passed: 8 stock and 8 Crystal parts at Time and Time64 scales 0/3/9"
