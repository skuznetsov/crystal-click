require "file_utils"
require "../src/crystal_click"

W65_KEYS             = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]
W65_ALL_ROWS         = [0_i32, 1_i32, 2_i32, 3_i32, 4_i32, 5_i32, 6_i32]
W65_RANGE_ROWS       = [2_i32, 3_i32, 4_i32]
W65_MARK_ROWS        = [2_u64, 2_u64, 2_u64, 1_u64, 0_u64]
W65_READER_MARK_ROWS = [2_u64, 2_u64, 2_u64, 1_u64]

# Values for the independent stock producer use valid temporal ranges. The
# writer-consumer vectors below additionally carry signed physical extrema.
W65_STOCK_DATE = [
  [] of Array(UInt16), [[] of UInt16], [[] of UInt16], [[] of UInt16],
  [] of Array(UInt16), [[0_u16, 1_u16]], [[UInt16::MAX, 0_u16]],
] of Array(Array(UInt16))
W65_STOCK_DATE32 = [
  [] of Array(Int32), [[] of Int32], [[] of Int32], [[] of Int32],
  [] of Array(Int32), [[-25_567_i32, 0_i32]], [[24_854_i32, -1_i32]],
] of Array(Array(Int32))
W65_STOCK_DATETIME = [
  [] of Array(UInt32), [[] of UInt32], [[] of UInt32], [[] of UInt32],
  [] of Array(UInt32), [[0_u32, 1_u32]], [[UInt32::MAX, 0_u32]],
] of Array(Array(UInt32))
W65_STOCK_DATETIME64 = [
  [] of Array(Int64), [[] of Int64], [[] of Int64], [[] of Int64],
  [] of Array(Int64), [[0_i64, 1_i64]], [[1_000_000_000_i64, 0_i64]],
] of Array(Array(Int64))

W65_STOCK_NULLABLE_DATE = [
  [] of Array(UInt16?), [[] of UInt16?], [[nil, nil] of UInt16?, [] of UInt16?],
  [[nil] of UInt16?, [] of UInt16?], [] of Array(UInt16?), [[] of UInt16?],
  [[UInt16::MAX, 0_u16, nil] of UInt16?],
] of Array(Array(UInt16?))
W65_STOCK_NULLABLE_DATE32 = [
  [] of Array(Int32?), [[] of Int32?], [[nil, nil] of Int32?, [] of Int32?],
  [[nil] of Int32?, [] of Int32?], [] of Array(Int32?), [[] of Int32?],
  [[24_854_i32, 0_i32, nil] of Int32?],
] of Array(Array(Int32?))
W65_STOCK_NULLABLE_DATETIME = [
  [] of Array(UInt32?), [[] of UInt32?], [[nil, nil] of UInt32?, [] of UInt32?],
  [[nil] of UInt32?, [] of UInt32?], [] of Array(UInt32?), [[] of UInt32?],
  [[UInt32::MAX, 0_u32, nil] of UInt32?],
] of Array(Array(UInt32?))
W65_STOCK_NULLABLE_DATETIME64 = [
  [] of Array(Int64?), [[] of Int64?], [[nil, nil] of Int64?, [] of Int64?],
  [[nil] of Int64?, [] of Int64?], [] of Array(Int64?), [[] of Int64?],
  [[1_000_000_000_i64, 0_i64, nil] of Int64?],
] of Array(Array(Int64?))

def w65_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (#{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

def w65_clickhouse_input(binary : String, store : String, query : String, input : IO) : String
  output = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], input: input, output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse RowBinary insert failed (#{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

def w65_append_u64(io : IO, value : UInt64) : Nil
  8.times { |byte| io.write_byte(((value >> (byte * 8)) & 0xff_u64).to_u8) }
end

def w65_append_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

def w65_append_scalar(io : IO, value : T) : Nil forall T
  {% if T == UInt16 %}
    bits = value.to_u64
    2.times { |byte| io.write_byte(((bits >> (byte * 8)) & 0xff_u64).to_u8) }
  {% elsif T == Int32 %}
    bits = value.unsafe_as(UInt32).to_u64
    4.times { |byte| io.write_byte(((bits >> (byte * 8)) & 0xff_u64).to_u8) }
  {% elsif T == UInt32 %}
    bits = value.to_u64
    4.times { |byte| io.write_byte(((bits >> (byte * 8)) & 0xff_u64).to_u8) }
  {% elsif T == Int64 %}
    bits = value.unsafe_as(UInt64)
    8.times { |byte| io.write_byte(((bits >> (byte * 8)) & 0xff_u64).to_u8) }
  {% else %}
    {% raise "unsupported W65 temporal scalar" %}
  {% end %}
end

def w65_append_array_array(io : IO, row : Array(Array(T))) : Nil forall T
  w65_append_varuint(io, row.size.to_u64)
  row.each do |inner|
    w65_append_varuint(io, inner.size.to_u64)
    inner.each { |value| w65_append_scalar(io, value) }
  end
end

def w65_append_nullable_array_array(io : IO, row : Array(Array(T?))) : Nil forall T
  w65_append_varuint(io, row.size.to_u64)
  row.each do |inner|
    w65_append_varuint(io, inner.size.to_u64)
    inner.each do |value|
      if value.nil?
        # RowBinary Nullable markers encode NULL without a nested scalar.
        io.write_byte(1_u8)
      else
        io.write_byte(0_u8)
        w65_append_scalar(io, value.not_nil!)
      end
    end
  end
end

def w65_expected_plain(keys : Array(UInt64), values : Array(Array(Array(T))), selected : Array(Int32)) : Bytes forall T
  output = IO::Memory.new
  selected.each do |index|
    w65_append_u64(output, keys[index])
    w65_append_array_array(output, values[index])
  end
  output.to_slice
end

def w65_expected_nullable(keys : Array(UInt64), values : Array(Array(Array(T?))), selected : Array(Int32)) : Bytes forall T
  output = IO::Memory.new
  selected.each do |index|
    w65_append_u64(output, keys[index])
    w65_append_nullable_array_array(output, values[index])
  end
  output.to_slice
end

def w65_assert_rowbinary(actual : String, expected : Bytes, label : String) : Nil
  unless actual.to_slice == expected
    observed = actual.to_slice
    shared = Math.min(observed.size, expected.size)
    mismatch = 0
    while mismatch < shared && observed[mismatch] == expected[mismatch]
      mismatch += 1
    end
    wanted = mismatch < expected.size ? expected[mismatch].to_s(16).rjust(2, '0') : "<eof>"
    got = mismatch < observed.size ? observed[mismatch].to_s(16).rjust(2, '0') : "<eof>"
    raise "#{label} RowBinary mismatch: expected #{expected.size} bytes, got #{observed.size}; first difference at byte #{mismatch}: expected #{wanted}, got #{got}"
  end
end

def w65_assert_rows_equal(actual : Array(Array(Array(T))), expected : Array(Array(Array(T))), label : String) : Nil forall T
  raise "#{label} raw temporal codes differ" unless actual == expected
end

def w65_assert_nullable_rows_equal(actual : Array(Array(Array(T?))), expected : Array(Array(Array(T?))), label : String) : Nil forall T
  raise "#{label} nullable temporal codes differ" unless actual == expected
end

def w65_assert_stream_marks(part : String, stream : String, expect_empty_middle : Bool = false) : Nil
  mark_path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  raise "missing real .mrk2 for #{stream}" unless File.file?(mark_path)
  raise "unexpected legacy .mrk for #{stream}" if File.exists?(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk"))
  bytes = File.read(mark_path).to_slice
  raise "#{stream} .mrk2 size differs: #{bytes.size}" unless bytes.size == W65_MARK_ROWS.size * CrystalClick::WidePart::MARK_SIZE
  rows = Array(UInt64).new(W65_MARK_ROWS.size) do |mark|
    offset = mark * CrystalClick::WidePart::MARK_SIZE + 16
    8.times.reduce(0_u64) { |value, byte| value | (bytes[offset + byte].to_u64 << (byte * 8)) }
  end
  raise "#{stream} per-mark row counts differ: #{rows.inspect}" unless rows == W65_MARK_ROWS
  if expect_empty_middle
    marks = [1, 2].map do |mark|
      offset = mark * CrystalClick::WidePart::MARK_SIZE
      [0, 8].map do |field|
        8.times.reduce(0_u64) { |value, byte| value | (bytes[offset + field + byte].to_u64 << (byte * 8)) }
      end
    end
    raise "#{stream} middle mark is not empty: #{marks.inspect}" unless marks[0] == marks[1]
  end
end

def w65_assert_pair_metadata(part : String, value_name : String, declaration : String, nullable : Bool) : Nil
  leaf = nullable ? "Nullable(#{declaration})" : declaration
  expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`#{value_name}` Array(Array(#{leaf}))\n"
  actual_columns = File.read(File.join(part, "columns.txt"))
  raise "#{value_name} columns metadata mismatch:\n#{actual_columns}" unless actual_columns == expected_columns
  nested = nullable ? "4 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n\t#{value_name}.size1\n\t#{value_name}.null\n\t#{value_name}\n" : "3 substreams for column `#{value_name}`:\n\t#{value_name}.size0\n\t#{value_name}.size1\n\t#{value_name}\n"
  expected_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n#{nested}"
  actual_substreams = File.read(File.join(part, "columns_substreams.txt"))
  raise "#{value_name} substream metadata mismatch:\n#{actual_substreams}" unless actual_substreams == expected_substreams
  expected_serialization = %({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
  actual_serialization = File.read(File.join(part, "serialization.json"))
  raise "#{value_name} serialization metadata mismatch: #{actual_serialization.inspect}" unless actual_serialization == expected_serialization
  raise "#{value_name} codec metadata mismatch" unless File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)"
  raise "#{value_name} metadata version mismatch" unless File.read(File.join(part, "metadata_version.txt")) == "0"
  ["pk", "#{value_name}.size0", "#{value_name}.size1"].each { |stream| w65_assert_stream_marks(part, stream) }
  w65_assert_stream_marks(part, "#{value_name}.null") if nullable
  w65_assert_stream_marks(part, value_name, !nullable)
end

def w65_assert_stock_plain(part : String, column : String, declaration : String, values : Array(Array(Array(T))), label : String) : Nil forall T
  reader = CrystalClick::WidePart.open_typed(part, column)
  expected_type = "Array(Array(#{declaration}))"
  raise "#{label} type mismatch: #{reader.column_type}, expected #{expected_type}" unless reader.column_type == expected_type
  observed = {% if T == UInt16 %}
               reader.read_array_array_date_codes_mark_range(column, 0, reader.mark_count)
             {% elsif T == Int32 %}
               reader.read_array_array_date32_codes_mark_range(column, 0, reader.mark_count)
             {% elsif T == UInt32 %}
               reader.read_array_array_datetime_seconds_mark_range(column, 0, reader.mark_count)
             {% elsif T == Int64 %}
               reader.read_array_array_datetime64_ticks_mark_range(column, 0, reader.mark_count)
             {% else %}
               {% raise "unsupported W65 reader scalar" %}
             {% end %}
  raise "#{label} mark rows differ: #{reader.mark_row_counts.inspect}" unless reader.mark_row_counts == W65_READER_MARK_ROWS
  w65_assert_rows_equal(observed, values, label)
end

def w65_assert_stock_nullable(part : String, column : String, declaration : String, values : Array(Array(Array(T?))), label : String) : Nil forall T
  reader = CrystalClick::WidePart.open_typed(part, column)
  expected_type = "Array(Array(Nullable(#{declaration})))"
  raise "#{label} type mismatch: #{reader.column_type}, expected #{expected_type}" unless reader.column_type == expected_type
  observed = {% if T == UInt16 %}
               reader.read_array_array_nullable_date_codes_mark_range(column, 0, reader.mark_count)
             {% elsif T == Int32 %}
               reader.read_array_array_nullable_date32_codes_mark_range(column, 0, reader.mark_count)
             {% elsif T == UInt32 %}
               reader.read_array_array_nullable_datetime_seconds_mark_range(column, 0, reader.mark_count)
             {% elsif T == Int64 %}
               reader.read_array_array_nullable_datetime64_ticks_mark_range(column, 0, reader.mark_count)
             {% else %}
               {% raise "unsupported W65 nullable reader scalar" %}
             {% end %}
  raise "#{label} mark rows differ: #{reader.mark_row_counts.inspect}" unless reader.mark_row_counts == W65_READER_MARK_ROWS
  w65_assert_nullable_rows_equal(observed, values, label)
end

def w65_stock_plain_input(keys : Array(UInt64), values : Array(Array(Array(T)))) : Bytes forall T
  io = IO::Memory.new
  keys.each_with_index do |key, index|
    w65_append_u64(io, key)
    w65_append_array_array(io, values[index])
  end
  io.to_slice
end

def w65_stock_nullable_input(keys : Array(UInt64), values : Array(Array(Array(T?)))) : Bytes forall T
  io = IO::Memory.new
  keys.each_with_index do |key, index|
    w65_append_u64(io, key)
    w65_append_nullable_array_array(io, values[index])
  end
  io.to_slice
end

def w65_create_stock_source(binary : String, store : String, root : String, name : String, declaration : String, nullable : Bool, input : Bytes) : {String, String}
  table = "w65_stock_#{name}"
  type_name = nullable ? "Nullable(#{declaration})" : declaration
  w65_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.#{table}
  (
      pk UInt64,
      payload Array(Array(#{type_name}))
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
  w65_clickhouse_input(binary, store, "INSERT INTO default.#{table} FORMAT RowBinary", IO::Memory.new(input))
  check = w65_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "stock producer CHECK TABLE failed for #{table}: #{check.inspect}" unless check == "all_1_1_0\t1"
  source_path = w65_clickhouse(binary, store, "SELECT path FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TSVRaw").strip
  raise "stock producer part is missing: #{source_path}" unless Dir.exists?(source_path)
  part = File.join(root, "stock-source-#{name}")
  FileUtils.cp_r(source_path, part)
  w65_assert_pair_metadata(part, "payload", declaration, nullable)
  {part, table}
end

def w65_verify_stock_plain(binary : String, store : String, root : String, name : String, declaration : String, values : Array(Array(Array(T)))) : Nil forall T
  part, table = w65_create_stock_source(binary, store, root, name, declaration, false, w65_stock_plain_input(W65_KEYS, values))
  w65_assert_stock_plain(part, "payload", declaration, values, "stock #{name}")
  full = w65_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  keyed = w65_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} WHERE pk >= 4 AND pk < 11 ORDER BY pk FORMAT RowBinary")
  w65_assert_rowbinary(full, w65_expected_plain(W65_KEYS, values, W65_ALL_ROWS), "stock #{name} full")
  w65_assert_rowbinary(keyed, w65_expected_plain(W65_KEYS, values, W65_RANGE_ROWS), "stock #{name} keyed")
  puts "Stock→Crystal #{table}: exact type/raw read and full/keyed RowBinary"
end

def w65_verify_stock_nullable(binary : String, store : String, root : String, name : String, declaration : String, values : Array(Array(Array(T?)))) : Nil forall T
  part, table = w65_create_stock_source(binary, store, root, name, declaration, true, w65_stock_nullable_input(W65_KEYS, values))
  w65_assert_stock_nullable(part, "payload", declaration, values, "stock nullable #{name}")
  full = w65_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  keyed = w65_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} WHERE pk >= 4 AND pk < 11 ORDER BY pk FORMAT RowBinary")
  w65_assert_rowbinary(full, w65_expected_nullable(W65_KEYS, values, W65_ALL_ROWS), "stock nullable #{name} full")
  w65_assert_rowbinary(keyed, w65_expected_nullable(W65_KEYS, values, W65_RANGE_ROWS), "stock nullable #{name} keyed")
  puts "Stock→Crystal #{table}: exact type/raw read and full/keyed RowBinary"
end

def w65_create_table(binary : String, store : String, table : String, declaration : String, nullable : Bool) : Nil
  leaf = nullable ? "Nullable(#{declaration})" : declaration
  w65_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.#{table}
  (
      pk UInt64,
      payload Array(Array(#{leaf}))
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
  nil
end

def w65_attach_part(binary : String, store : String, table : String, part : String) : Nil
  data_path = w65_clickhouse(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{table}' FORMAT TSVRaw").strip
  raise "no data path for #{table}" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  w65_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  check = w65_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "CHECK TABLE failed for #{table}: #{check.inspect}" unless check == "all_1_1_0\t1"
  puts "ATTACH PART/CHECK TABLE #{table}: all_1_1_0\\t1"
end

def w65_verify_writer(binary : String, store : String, root : String, name : String, declaration : String, values : Array(Array(Array(T))), scale : Int32 = 3) : Nil forall T
  part = File.join(root, "writer-#{name}-#{scale}")
  key_slice = W65_KEYS.to_unsafe.to_slice(W65_KEYS.size)
  value_slice = values.to_unsafe.to_slice(values.size)
  {% if T == UInt16 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_date_pair(part, "pk", key_slice, "payload", value_slice, rows_per_mark: 2)
  {% elsif T == Int32 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_date32_pair(part, "pk", key_slice, "payload", value_slice, rows_per_mark: 2)
  {% elsif T == UInt32 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_datetime_pair(part, "pk", key_slice, "payload", value_slice, rows_per_mark: 2)
  {% elsif T == Int64 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_datetime64_pair(part, "pk", key_slice, "payload", value_slice, scale, rows_per_mark: 2)
  {% else %}
    {% raise "unsupported W65 writer scalar" %}
  {% end %}
  w65_assert_pair_metadata(part, "payload", declaration, false)
  table = "w65_writer_#{name}_#{scale}"
  w65_create_table(binary, store, table, declaration, false)
  w65_attach_part(binary, store, table, part)
  full = w65_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  keyed = w65_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} WHERE pk >= 4 AND pk < 11 ORDER BY pk FORMAT RowBinary")
  w65_assert_rowbinary(full, w65_expected_plain(W65_KEYS, values, W65_ALL_ROWS), "writer #{name} full")
  w65_assert_rowbinary(keyed, w65_expected_plain(W65_KEYS, values, W65_RANGE_ROWS), "writer #{name} keyed")
  puts "Crystal→stock #{table}: full/keyed RowBinary exact"
end

def w65_verify_nullable_writer(binary : String, store : String, root : String, name : String, declaration : String, values : Array(Array(Array(T?))), scale : Int32 = 3) : Nil forall T
  part = File.join(root, "writer-nullable-#{name}-#{scale}")
  key_slice = W65_KEYS.to_unsafe.to_slice(W65_KEYS.size)
  value_slice = values.to_unsafe.to_slice(values.size)
  {% if T == UInt16 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_nullable_date_pair(part, "pk", key_slice, "payload", value_slice, rows_per_mark: 2)
  {% elsif T == Int32 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_nullable_date32_pair(part, "pk", key_slice, "payload", value_slice, rows_per_mark: 2)
  {% elsif T == UInt32 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_nullable_datetime_pair(part, "pk", key_slice, "payload", value_slice, rows_per_mark: 2)
  {% elsif T == Int64 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_nullable_datetime64_pair(part, "pk", key_slice, "payload", value_slice, scale, rows_per_mark: 2)
  {% else %}
    {% raise "unsupported W65 nullable writer scalar" %}
  {% end %}
  w65_assert_pair_metadata(part, "payload", declaration, true)
  table = "w65_nullable_writer_#{name}_#{scale}"
  w65_create_table(binary, store, table, declaration, true)
  w65_attach_part(binary, store, table, part)
  full = w65_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  keyed = w65_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} WHERE pk >= 4 AND pk < 11 ORDER BY pk FORMAT RowBinary")
  w65_assert_rowbinary(full, w65_expected_nullable(W65_KEYS, values, W65_ALL_ROWS), "writer nullable #{name} full")
  w65_assert_rowbinary(keyed, w65_expected_nullable(W65_KEYS, values, W65_RANGE_ROWS), "writer nullable #{name} keyed")
  puts "Crystal→stock #{table}: full/keyed RowBinary exact"
end

def w65_writer_plain_values(type : T.class) : Array(Array(Array(T))) forall T
  {% if T == UInt16 %}
    [[] of Array(UInt16), [[] of UInt16], [[] of UInt16], [[] of UInt16], [[0_u16, UInt16::MAX]], [[42_u16]], [[UInt16::MAX, 0_u16]]] of Array(Array(UInt16))
  {% elsif T == Int32 %}
    [[] of Array(Int32), [[] of Int32], [[] of Int32], [[] of Int32], [[-1_i32, 0_i32]], [[Int32::MIN, Int32::MAX]], [[Int32::MAX, 0_i32]]] of Array(Array(Int32))
  {% elsif T == UInt32 %}
    [[] of Array(UInt32), [[] of UInt32], [[] of UInt32], [[] of UInt32], [[0_u32, UInt32::MAX]], [[1_u32]], [[UInt32::MAX, 0_u32]]] of Array(Array(UInt32))
  {% elsif T == Int64 %}
    [[] of Array(Int64), [[] of Int64], [[] of Int64], [[] of Int64], [[-1_i64, 0_i64]], [[Int64::MIN, Int64::MAX]], [[Int64::MAX, 0_i64]]] of Array(Array(Int64))
  {% else %}
    {% raise "unsupported W65 writer values scalar" %}
  {% end %}
end

def w65_writer_nullable_values(type : T.class) : Array(Array(Array(T?))) forall T
  {% if T == UInt16 %}
    [[] of Array(UInt16?), [[] of UInt16?], [[nil, nil] of UInt16?, [] of UInt16?], [[nil] of UInt16?, [] of UInt16?], [] of Array(UInt16?), [[] of UInt16?], [[UInt16::MAX, 0_u16, nil] of UInt16?]] of Array(Array(UInt16?))
  {% elsif T == Int32 %}
    [[] of Array(Int32?), [[] of Int32?], [[nil, nil] of Int32?, [] of Int32?], [[nil] of Int32?, [] of Int32?], [] of Array(Int32?), [[] of Int32?], [[Int32::MAX, 0_i32, nil] of Int32?]] of Array(Array(Int32?))
  {% elsif T == UInt32 %}
    [[] of Array(UInt32?), [[] of UInt32?], [[nil, nil] of UInt32?, [] of UInt32?], [[nil] of UInt32?, [] of UInt32?], [] of Array(UInt32?), [[] of UInt32?], [[UInt32::MAX, 0_u32, nil] of UInt32?]] of Array(Array(UInt32?))
  {% elsif T == Int64 %}
    [[] of Array(Int64?), [[] of Int64?], [[nil, nil] of Int64?, [] of Int64?], [[nil] of Int64?, [] of Int64?], [] of Array(Int64?), [[] of Int64?], [[Int64::MAX, 0_i64, nil] of Int64?]] of Array(Array(Int64?))
  {% else %}
    {% raise "unsupported W65 nullable writer values scalar" %}
  {% end %}
end

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("CLICKHOUSE_STORE")
root = ENV.fetch("ORACLE_ROOT")

w65_verify_stock_plain(binary, store, root, "date", "Date", W65_STOCK_DATE)
w65_verify_stock_plain(binary, store, root, "date32", "Date32", W65_STOCK_DATE32)
w65_verify_stock_plain(binary, store, root, "datetime", "DateTime", W65_STOCK_DATETIME)
{0, 3, 9}.each do |scale|
  w65_verify_stock_plain(binary, store, root, "datetime64_#{scale}", "DateTime64(#{scale})", W65_STOCK_DATETIME64)
end
w65_verify_stock_nullable(binary, store, root, "nullable_date", "Date", W65_STOCK_NULLABLE_DATE)
w65_verify_stock_nullable(binary, store, root, "nullable_date32", "Date32", W65_STOCK_NULLABLE_DATE32)
w65_verify_stock_nullable(binary, store, root, "nullable_datetime", "DateTime", W65_STOCK_NULLABLE_DATETIME)
{0, 3, 9}.each do |scale|
  w65_verify_stock_nullable(binary, store, root, "nullable_datetime64_#{scale}", "DateTime64(#{scale})", W65_STOCK_NULLABLE_DATETIME64)
end

w65_verify_writer(binary, store, root, "date", "Date", w65_writer_plain_values(UInt16))
w65_verify_writer(binary, store, root, "date32", "Date32", w65_writer_plain_values(Int32))
w65_verify_writer(binary, store, root, "datetime", "DateTime", w65_writer_plain_values(UInt32))
{0, 3, 9}.each { |scale| w65_verify_writer(binary, store, root, "datetime64", "DateTime64(#{scale})", w65_writer_plain_values(Int64), scale) }

w65_verify_nullable_writer(binary, store, root, "date", "Date", w65_writer_nullable_values(UInt16))
w65_verify_nullable_writer(binary, store, root, "date32", "Date32", w65_writer_nullable_values(Int32))
w65_verify_nullable_writer(binary, store, root, "datetime", "DateTime", w65_writer_nullable_values(UInt32))
{0, 3, 9}.each { |scale| w65_verify_nullable_writer(binary, store, root, "datetime64", "DateTime64(#{scale})", w65_writer_nullable_values(Int64), scale) }

puts "W65 bidirectional oracle passed: 12 stock and 12 Crystal parts, DateTime64 scales 0/3/9, .mrk2 metadata, ATTACH/CHECK and independent full/keyed RowBinary"
