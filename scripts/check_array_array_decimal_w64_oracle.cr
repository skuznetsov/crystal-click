require "file_utils"
require "../src/crystal_click"

private def w64_ch(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  result = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (#{result.exit_code}): #{query}" unless result.success?
  output.to_s
end

private def w64_append_u64(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
end

private def w64_append_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w64_append_coefficient(io : IO, value : T) : Nil forall T
  {% if T == Int32 %}
    bits = value.unsafe_as(UInt32)
    4.times { |index| io.write_byte(((bits >> (index * 8)) & 0xff_u32).to_u8) }
  {% elsif T == Int64 %}
    bits = value.unsafe_as(UInt64)
    8.times { |index| io.write_byte(((bits >> (index * 8)) & 0xff_u64).to_u8) }
  {% elsif T == Int128 %}
    bits = value.unsafe_as(UInt128)
    16.times { |index| io.write_byte(((bits >> (index * 8)) & 0xff_u128).to_u8) }
  {% elsif T == CrystalClick::Decimal256Value %}
    16.times { |index| io.write_byte(((value.low >> (index * 8)) & 0xff_u128).to_u8) }
    16.times { |index| io.write_byte(((value.high >> (index * 8)) & 0xff_u128).to_u8) }
  {% else %}
    {% raise "unsupported W64 coefficient type" %}
  {% end %}
end

private def w64_expected_plain(keys : Array(UInt64), rows : Array(Array(Array(T))), selected : Array(Int32)) : Bytes forall T
  io = IO::Memory.new
  selected.each do |index|
    w64_append_u64(io, keys[index])
    w64_append_varuint(io, rows[index].size.to_u64)
    rows[index].each do |inner|
      w64_append_varuint(io, inner.size.to_u64)
      inner.each { |value| w64_append_coefficient(io, value) }
    end
  end
  io.to_slice
end

private def w64_expected_nullable(keys : Array(UInt64), rows : Array(Array(Array(T?))), selected : Array(Int32)) : Bytes forall T
  io = IO::Memory.new
  selected.each do |index|
    w64_append_u64(io, keys[index])
    w64_append_varuint(io, rows[index].size.to_u64)
    rows[index].each do |inner|
      w64_append_varuint(io, inner.size.to_u64)
      inner.each do |value|
        if value.nil?
          io.write_byte(1_u8)
        else
          io.write_byte(0_u8)
          w64_append_coefficient(io, value.not_nil!)
        end
      end
    end
  end
  io.to_slice
end

private def w64_decimal_text(value : T, scale : Int32) : String forall T
  raw = value.to_s
  negative = raw.starts_with?('-')
  digits = negative ? raw[1..] : raw
  return "#{negative ? "-" : ""}#{digits}" if scale == 0
  padded = digits.rjust(scale + 1, '0')
  "#{negative ? "-" : ""}#{padded[0, padded.size - scale]}.#{padded[-scale, scale]}"
end

private def w64_sql_plain(row : Array(Array(T)), width : Int32, scale : Int32) : String forall T
  inners = row.map do |inner|
    "[#{inner.map { |value| "toDecimal#{width}('#{w64_decimal_text(value, scale)}', #{scale})" }.join(", ")}]"
  end
  "CAST([#{inners.join(", ")}], 'Array(Array(Decimal#{width}(#{scale})))')"
end

private def w64_sql_nullable(row : Array(Array(T?)), width : Int32, scale : Int32) : String forall T
  inners = row.map do |inner|
    elements = inner.map do |value|
      value.nil? ? "NULL" : "toDecimal#{width}('#{w64_decimal_text(value.not_nil!, scale)}', #{scale})"
    end
    "[#{elements.join(", ")}]"
  end
  "CAST([#{inners.join(", ")}], 'Array(Array(Nullable(Decimal#{width}(#{scale}))))')"
end

private def w64_create_table(binary : String, store : String, table : String, width : Int32, scale : Int32, nullable : Bool) : Nil
  leaf = "Decimal#{width}(#{scale})"
  leaf = "Nullable(#{leaf})" if nullable
  w64_ch(binary, store, <<-SQL)
  CREATE TABLE default.#{table}
  (pk UInt64, payload Array(Array(#{leaf})))
  ENGINE = MergeTree ORDER BY pk
  SETTINGS index_granularity = 2, index_granularity_bytes = 10485760,
    enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0,
    min_bytes_for_wide_part = 0, compress_marks = 0,
    min_compress_block_size = 0, max_compress_block_size = 4096,
    ratio_of_defaults_for_sparse_serialization = 1.0,
    default_compression_codec = 'LZ4'
  SQL
  nil
end

private def w64_stock_part(binary : String, store : String, table : String) : String
  check = w64_ch(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "stock CHECK TABLE failed for #{table}: #{check.inspect}" unless check == "all_1_1_0\t1"
  path = w64_ch(binary, store, "SELECT path FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TSVRaw").strip
  raise "stock part missing: #{table}" unless Dir.exists?(path)
  path
end

private def w64_assert_metadata(stock_part : String, writer_part : String, precision : Int32, scale : Int32, nullable : Bool) : Nil
  leaf = "Decimal(#{precision}, #{scale})"
  leaf = "Nullable(#{leaf})" if nullable
  expected = "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` Array(Array(#{leaf}))\n"
  raise "stock columns declaration differs" unless File.read(File.join(stock_part, "columns.txt")) == expected
  {"columns.txt", "columns_substreams.txt", "serialization.json"}.each do |file|
    stock = File.read(File.join(stock_part, file))
    writer = File.read(File.join(writer_part, file))
    raise "writer #{file} differs from stock" unless stock == writer
  end
  streams = nullable ? ["payload.size0", "payload.size1", "payload.null", "payload"] : ["payload.size0", "payload.size1", "payload"]
  streams.each do |stream|
    {stock_part, writer_part}.each do |part|
      marks = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
      reader = CrystalClick::WidePart.open_typed(part, "payload")
      raise "#{part} has incorrect logical mark rows" unless reader.mark_row_counts == [2_u64, 2_u64, 2_u64, 1_u64]
      observed_size = File.size(marks)
      expected_size = (reader.mark_count + 1) * CrystalClick::WidePart::MARK_SIZE
      raise "#{stream} has incorrect physical marks in #{part}: #{observed_size} bytes, expected #{expected_size}" unless observed_size == expected_size
    end
  end
  nil
end

private def w64_attach(binary : String, store : String, table : String, writer_part : String) : Nil
  data_path = w64_ch(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{table}' FORMAT TSVRaw").strip
  raise "no ClickHouse data path for #{table}" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(writer_part, File.join(detached, "all_1_1_0"))
  w64_ch(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  check = w64_ch(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "writer CHECK TABLE failed for #{table}: #{check.inspect}" unless check == "all_1_1_0\t1"
  nil
end

private def w64_write_plain(part : String, keys : Array(UInt64), rows : Array(Array(Array(T))), scale : Int32) : Nil forall T
  {% if T == Int32 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_decimal32_pair(part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size), scale, rows_per_mark: 2)
  {% elsif T == Int64 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_decimal64_pair(part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size), scale, rows_per_mark: 2)
  {% elsif T == Int128 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_decimal128_pair(part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size), scale, rows_per_mark: 2)
  {% elsif T == CrystalClick::Decimal256Value %}
    CrystalClick::WidePartWriter.write_uint64_array_array_decimal256_pair(part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size), scale, rows_per_mark: 2)
  {% else %}
    {% raise "unsupported W64 writer type" %}
  {% end %}
  nil
end

private def w64_write_nullable(part : String, keys : Array(UInt64), rows : Array(Array(Array(T?))), scale : Int32) : Nil forall T
  {% if T == Int32 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_nullable_decimal32_pair(part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size), scale, rows_per_mark: 2)
  {% elsif T == Int64 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_nullable_decimal64_pair(part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size), scale, rows_per_mark: 2)
  {% elsif T == Int128 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_nullable_decimal128_pair(part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size), scale, rows_per_mark: 2)
  {% elsif T == CrystalClick::Decimal256Value %}
    CrystalClick::WidePartWriter.write_uint64_array_array_nullable_decimal256_pair(part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size), scale, rows_per_mark: 2)
  {% else %}
    {% raise "unsupported W64 writer type" %}
  {% end %}
  nil
end

private def w64_read_plain(part : String, type : T.class) : Array(Array(Array(T))) forall T
  reader = CrystalClick::WidePart.open_typed(part, "payload")
  {% if T == Int32 %}
    reader.read_array_array_decimal32_mark_range("payload", 0, reader.mark_count)
  {% elsif T == Int64 %}
    reader.read_array_array_decimal64_mark_range("payload", 0, reader.mark_count)
  {% elsif T == Int128 %}
    reader.read_array_array_decimal128_mark_range("payload", 0, reader.mark_count)
  {% elsif T == CrystalClick::Decimal256Value %}
    reader.read_array_array_decimal256_mark_range("payload", 0, reader.mark_count)
  {% else %}
    {% raise "unsupported W64 reader type" %}
  {% end %}
end

private def w64_read_nullable(part : String, type : T.class) : Array(Array(Array(T?))) forall T
  reader = CrystalClick::WidePart.open_typed(part, "payload")
  {% if T == Int32 %}
    reader.read_array_array_nullable_decimal32_mark_range("payload", 0, reader.mark_count)
  {% elsif T == Int64 %}
    reader.read_array_array_nullable_decimal64_mark_range("payload", 0, reader.mark_count)
  {% elsif T == Int128 %}
    reader.read_array_array_nullable_decimal128_mark_range("payload", 0, reader.mark_count)
  {% elsif T == CrystalClick::Decimal256Value %}
    reader.read_array_array_nullable_decimal256_mark_range("payload", 0, reader.mark_count)
  {% else %}
    {% raise "unsupported W64 reader type" %}
  {% end %}
end

private def w64_assert_rowbinary(binary : String, store : String, table : String, keys : Array(UInt64), rows : Array(Array(Array(T)))) : Nil forall T
  all = w64_ch(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  expected = w64_expected_plain(keys, rows, (0...keys.size).map(&.to_i32))
  raise "#{table} full RowBinary mismatch" unless all.to_slice == expected
  selected = keys.each_with_index.compact_map { |key, index| index.to_i32 if key >= 2_u64 && key < 10_u64 }.to_a
  ranged = w64_ch(binary, store, "SELECT pk, payload FROM default.#{table} WHERE pk >= 2 AND pk < 10 ORDER BY pk FORMAT RowBinary")
  raise "#{table} key-range RowBinary mismatch" unless ranged.to_slice == w64_expected_plain(keys, rows, selected)
  nil
end

private def w64_assert_nullable_rowbinary(binary : String, store : String, table : String, keys : Array(UInt64), rows : Array(Array(Array(T?)))) : Nil forall T
  all = w64_ch(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  expected = w64_expected_nullable(keys, rows, (0...keys.size).map(&.to_i32))
  raise "#{table} full RowBinary mismatch" unless all.to_slice == expected
  selected = keys.each_with_index.compact_map { |key, index| index.to_i32 if key >= 2_u64 && key < 10_u64 }.to_a
  ranged = w64_ch(binary, store, "SELECT pk, payload FROM default.#{table} WHERE pk >= 2 AND pk < 10 ORDER BY pk FORMAT RowBinary")
  raise "#{table} key-range RowBinary mismatch" unless ranged.to_slice == w64_expected_nullable(keys, rows, selected)
  nil
end

private def w64_small(type : T.class, value : Int32) : T forall T
  {% if T == Int32 %}
    value
  {% elsif T == Int64 %}
    value.to_i64
  {% elsif T == Int128 %}
    value.to_i128
  {% elsif T == CrystalClick::Decimal256Value %}
    CrystalClick::Decimal256Value.from_int128(value.to_i128)
  {% else %}
    {% raise "unsupported W64 coefficient type" %}
  {% end %}
end

private def w64_run_width(binary : String, store : String, root : String, label : String, type : T.class, precision : Int32, width : Int32, maximum : T, minimum : T) : Nil forall T
  scale = 2
  keys = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]
  zero = w64_small(type, 0)
  positive = w64_small(type, 123)
  negative = w64_small(type, -123)
  plain_rows = [
    [] of Array(T),
    [[maximum, minimum] of T, [] of T],
    [[] of T],
    [] of Array(T),
    [[zero], [] of T],
    [] of Array(T),
    [[positive, negative] of T],
  ] of Array(Array(T))
  nullable_rows = [
    [] of Array(T?),
    [[maximum, nil, minimum] of T?, [] of T?],
    [[] of T?],
    [] of Array(T?),
    [[nil, nil] of T?, [] of T?],
    [] of Array(T?),
    [[zero, nil, positive] of T?],
  ] of Array(Array(T?))

  {false, true}.each do |nullable|
    tag = "#{label}_#{nullable ? "nullable" : "plain"}"
    source_table = "source_w64_#{tag}"
    writer_table = "writer_w64_#{tag}"
    w64_create_table(binary, store, source_table, width, scale, nullable)
    insert = keys.each_index.map do |index|
      sql_value = nullable ? w64_sql_nullable(nullable_rows[index], width, scale) : w64_sql_plain(plain_rows[index], width, scale)
      "(#{keys[index]}, #{sql_value})"
    end
    w64_ch(binary, store, "INSERT INTO default.#{source_table} VALUES #{insert.join(", ")}")
    stock_part = w64_stock_part(binary, store, source_table)
    if nullable
      raise "stock Crystal nullable decode differs for #{tag}" unless w64_read_nullable(stock_part, type) == nullable_rows
      w64_assert_nullable_rowbinary(binary, store, source_table, keys, nullable_rows)
    else
      raise "stock Crystal plain decode differs for #{tag}" unless w64_read_plain(stock_part, type) == plain_rows
      w64_assert_rowbinary(binary, store, source_table, keys, plain_rows)
    end

    writer_part = File.join(root, "writer-part-#{tag}")
    if nullable
      w64_write_nullable(writer_part, keys, nullable_rows, scale)
    else
      w64_write_plain(writer_part, keys, plain_rows, scale)
    end
    w64_assert_metadata(stock_part, writer_part, precision, scale, nullable)
    w64_create_table(binary, store, writer_table, width, scale, nullable)
    w64_attach(binary, store, writer_table, writer_part)
    if nullable
      w64_assert_nullable_rowbinary(binary, store, writer_table, keys, nullable_rows)
    else
      w64_assert_rowbinary(binary, store, writer_table, keys, plain_rows)
    end
  end
  nil
end

private def w64_decimal256_from_coefficient(text : String) : CrystalClick::Decimal256Value
  negative = text.starts_with?('-')
  digits = negative ? text[1..] : text
  words = [0_u64, 0_u64, 0_u64, 0_u64]
  digits.each_char do |character|
    raise "invalid coefficient" unless character.ascii_number?
    carry = (character.ord - '0'.ord).to_u128
    4.times do |index|
      product = words[index].to_u128 * 10_u128 + carry
      words[index] = (product & UInt64::MAX.to_u128).to_u64
      carry = product >> 64
    end
    raise "Decimal256 coefficient overflows" unless carry == 0
  end
  if negative
    carry = true
    4.times do |index|
      inverted = ~words[index]
      if carry && inverted == UInt64::MAX
        words[index] = 0_u64
      elsif carry
        words[index] = inverted + 1_u64
        carry = false
      else
        words[index] = inverted
      end
    end
  end
  CrystalClick::Decimal256Value.from_words(words[0], words[1], words[2], words[3])
end

private def w64_check_raw_decimal32_extreme(binary : String, store : String, root : String) : Nil
  keys = [1_u64, 2_u64, 3_u64]
  rows = [
    [[Int32::MIN, Int32::MAX]],
    [] of Array(Int32),
    [[-1_i32, 0_i32, 1_i32]],
  ] of Array(Array(Int32))
  part = File.join(root, "writer-part-d32-raw-extreme")
  w64_write_plain(part, keys, rows, 2)
  table = "writer_w64_d32_raw_extreme"
  w64_create_table(binary, store, table, 32, 2, false)
  w64_attach(binary, store, table, part)
  w64_assert_rowbinary(binary, store, table, keys, rows)
  nil
end

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("CLICKHOUSE_STORE")
root = ENV.fetch("ORACLE_ROOT")
w64_run_width(binary, store, root, "d32", Int32, 9, 32, 999_999_999_i32, -999_999_999_i32)
w64_run_width(binary, store, root, "d64", Int64, 18, 64, 999_999_999_999_999_999_i64, -999_999_999_999_999_999_i64)
w64_run_width(binary, store, root, "d128", Int128, 38, 128, 10_i128**38 - 1_i128, -(10_i128**38 - 1_i128))
w64_run_width(binary, store, root, "d256", CrystalClick::Decimal256Value, 76, 256, w64_decimal256_from_coefficient("9" * 76), w64_decimal256_from_coefficient("-" + "9" * 76))
w64_check_raw_decimal32_extreme(binary, store, root)
puts "W64 two-level Decimal oracle passed: eight stock producer and Crystal writer/stock reader cases plus raw Decimal32 backing extrema, CHECK TABLE, exact metadata, full/key-range RowBinary"
