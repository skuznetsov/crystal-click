require "file_utils"
require "../src/crystal_click"

W85_KEYS             = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
W85_SELECTED_INDICES = [1_i32, 2_i32, 3_i32]

private def w85_clickhouse(binary : String, store : String, query : String, input : IO = IO::Memory.new) : String
  output = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], input: input, output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (#{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

private def w85_scalar(io : IO, value : T) : Nil forall T
  io.write_bytes(value, IO::ByteFormat::LittleEndian)
end

private def w85_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w85_string(io : IO, value : String) : Nil
  w85_varuint(io, value.bytesize.to_u64)
  io.write(value.to_slice)
end

private def w85_rows(key_a : K, key_b : K, low : T, high : T) : Array(Array(Array(Tuple(K, Array(T))))) forall K, T
  first_map = [{key_a, [low, high]}, {key_b, [] of T}] of Tuple(K, Array(T))
  empty_map = [] of Tuple(K, Array(T))
  one_entry_map = [{key_a, [high]}] of Tuple(K, Array(T))
  duplicate_map = [{key_a, [] of T}, {key_a, [low, high]}] of Tuple(K, Array(T))
  [
    [first_map] of Array(Tuple(K, Array(T))),
    [] of Array(Tuple(K, Array(T))),
    [empty_map, one_entry_map] of Array(Tuple(K, Array(T))),
    [duplicate_map] of Array(Tuple(K, Array(T))),
    [] of Array(Tuple(K, Array(T))),
  ] of Array(Array(Tuple(K, Array(T))))
end

private def w85_write_key(io : IO, key : K) : Nil forall K
  {% if K == UInt64 %}
    w85_scalar(io, key)
  {% elsif K == String %}
    w85_string(io, key)
  {% else %}
    {% raise "W85 oracle only supports UInt64 and String keys" %}
  {% end %}
end

private def w85_rowbinary(
  rows : Array(Array(Array(Tuple(K, Array(T))))),
  indices : Array(Int32),
) : Bytes forall K, T
  raise "W85 row count differs from the pinned primary-key rows" unless rows.size == W85_KEYS.size
  io = IO::Memory.new
  indices.each do |index|
    w85_scalar(io, W85_KEYS[index])
    row_maps = rows[index]
    w85_varuint(io, row_maps.size.to_u64)
    row_maps.each do |entries|
      w85_varuint(io, entries.size.to_u64)
      entries.each do |key, values|
        w85_write_key(io, key)
        w85_varuint(io, values.size.to_u64)
        values.each { |value| w85_scalar(io, value) }
      end
    end
  end
  io.to_slice
end

private def w85_append_u64(io : IO, value : UInt64) : Nil
  io.write_bytes(value, IO::ByteFormat::LittleEndian)
end

private def w85_expected_streams(
  column : String,
  rows : Array(Array(Array(Tuple(K, Array(T))))),
) : Hash(String, Array(UInt8)) forall K, T
  size0 = IO::Memory.new
  size1 = IO::Memory.new
  key_sizes = IO::Memory.new
  key_data = IO::Memory.new
  size2 = IO::Memory.new
  leaf_data = IO::Memory.new
  rows.each do |row_maps|
    w85_append_u64(size0, row_maps.size.to_u64)
    row_maps.each do |entries|
      w85_append_u64(size1, entries.size.to_u64)
      entries.each do |key, values|
        {% if K == String %}
          w85_append_u64(key_sizes, key.bytesize.to_u64)
          key_data.write(key.to_slice)
        {% else %}
          w85_append_u64(key_data, key)
        {% end %}
        w85_append_u64(size2, values.size.to_u64)
        values.each { |value| w85_scalar(leaf_data, value) }
      end
    end
  end

  streams = {
    "#{column}.size0"          => size0.to_slice.to_a,
    "#{column}.size1"          => size1.to_slice.to_a,
    "#{column}%2Ekeys"         => key_data.to_slice.to_a,
    "#{column}%2Evalues.size2" => size2.to_slice.to_a,
    "#{column}%2Evalues"       => leaf_data.to_slice.to_a,
  }
  {% if K == String %}
    streams["#{column}%2Ekeys.size"] = key_sizes.to_slice.to_a
  {% end %}
  streams
end

private def w85_stream_names(column : String, key_type : String) : Array(String)
  streams = ["#{column}.size0", "#{column}.size1"] of String
  streams << "#{column}%2Ekeys.size" if key_type == "String"
  streams << "#{column}%2Ekeys" << "#{column}%2Evalues.size2" << "#{column}%2Evalues"
  streams
end

private def w85_u64_at(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w85_mark_records(part : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64))
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  bytes = File.read(path).to_slice
  raise "#{part} #{stream} mark file size differs: #{bytes.size}" unless bytes.size == 4 * CrystalClick::WidePart::MARK_SIZE
  Array(Tuple(UInt64, UInt64, UInt64)).new(4) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    {w85_u64_at(bytes, offset), w85_u64_at(bytes, offset + 8), w85_u64_at(bytes, offset + 16)}
  end
end

private def w85_raw_stream(part : String, stream : String) : Array(UInt8)
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
  encoded = File.read(path).to_slice
  return [] of UInt8 if encoded.empty?
  CrystalClick::CompressedBlock.decode_all(encoded).to_a
end

private def w85_literal_frame_size(raw_size : Int) : UInt64
  return 0_u64 if raw_size == 0
  extension_size = raw_size < 15 ? 0 : ((raw_size - 15) // 255) + 1
  (CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + 1 + extension_size + raw_size).to_u64
end

private def w85_expected_stock_mark_records(
  stream : String,
  rows : Array(Array(Array(Tuple(K, Array(T))))),
) : Array(Tuple(UInt64, UInt64, UInt64)) forall K, T
  # This five-row pinned ClickHouse fixture fits one compressed frame per
  # stream, so marks stay in compressed frame 0 and point at raw byte offsets.
  offsets = [0_u64]
  start_row = 0
  while start_row < rows.size
    mark_rows = {2, rows.size - start_row}.min
    raw_size = if stream == "pk"
                 mark_rows * 8
               else
                 w85_expected_streams("payload", rows[start_row, mark_rows])[stream].size
               end
    offsets << offsets.last + raw_size.to_u64
    start_row += mark_rows
  end
  offsets.map_with_index do |offset, index|
    row_count = index == offsets.size - 1 ? 0_u64 : ({2, rows.size - (index * 2)}.min).to_u64
    {0_u64, offset, row_count}
  end
end

private def w85_expected_writer_mark_records(
  stream : String,
  rows : Array(Array(Array(Tuple(K, Array(T))))),
) : Array(Tuple(UInt64, UInt64, UInt64)) forall K, T
  # The Crystal writer deliberately emits one literal-only frame per mark;
  # mark starts therefore advance compressed offsets and reset raw offsets.
  records = [] of Tuple(UInt64, UInt64, UInt64)
  compressed_offset = 0_u64
  start_row = 0
  while start_row < rows.size
    mark_rows = {2, rows.size - start_row}.min
    raw_size = if stream == "pk"
                 mark_rows * 8
               else
                 w85_expected_streams("payload", rows[start_row, mark_rows])[stream].size
               end
    records << {compressed_offset, 0_u64, mark_rows.to_u64}
    unless stream != "pk" && raw_size == 0
      compressed_offset += w85_literal_frame_size(raw_size)
    end
    start_row += mark_rows
  end
  records << {compressed_offset, 0_u64, 0_u64}
  records
end

private def w85_assert_part(
  part : String,
  type : String,
  key_type : String,
  expected_raw : Hash(String, Array(UInt8)),
  rows : Array(Array(Array(Tuple(K, Array(T))))),
  origin : String,
) : Nil forall K, T
  streams = w85_stream_names("payload", key_type)
  expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` #{type}\n"
  raise "#{part} columns differ" unless File.read(File.join(part, "columns.txt")) == expected_columns
  expected_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" +
                        "#{streams.size} substreams for column `payload`:\n" + streams.map { |stream| "\t#{stream}\n" }.join
  raise "#{part} substream order differs" unless File.read(File.join(part, "columns_substreams.txt")) == expected_substreams

  streams.each do |stream|
    actual = w85_raw_stream(part, stream)
    expected = expected_raw[stream]
    raise "#{part} #{stream} raw bytes differ (origin=#{origin}, expected=#{expected.size}, actual=#{actual.size})" unless actual == expected
  end
  raise "#{part} primary-key raw bytes differ" unless w85_raw_stream(part, "pk") == expected_raw["pk"]

  (streams + ["pk"]).each do |stream|
    records = w85_mark_records(part, stream)
    expected_records = origin == "stock ClickHouse" ? w85_expected_stock_mark_records(stream, rows) : w85_expected_writer_mark_records(stream, rows)
    raise "#{part} #{stream} exact mark coordinates differ for #{origin}: expected=#{expected_records}, actual=#{records}" unless records == expected_records
    puts "PASS W85 #{origin} exact mark coordinates #{stream}: #{records}"
  end

  puts "PASS W85 #{origin} exact raw streams/marks #{type}"
  nil
end

private def w85_read_range(
  reader : CrystalClick::WidePart,
  column : String,
  first_mark : Int32,
  mark_count : Int32,
  type : T.class,
  rows : Array(Array(Array(Tuple(K, Array(T))))),
) : Array(Array(Array(Tuple(K, Array(T))))) forall K, T
  {% if K == UInt64 %}
    reader.read_array_map_uint64_array_numeric_mark_range(column, first_mark, mark_count, type)
  {% elsif K == String %}
    reader.read_array_map_string_array_numeric_mark_range(column, first_mark, mark_count, type)
  {% else %}
    {% raise "W85 reader only supports UInt64 and String keys" %}
  {% end %}
end

private def w85_write_part(
  destination : String,
  rows : Array(Array(Array(Tuple(K, Array(T))))),
) : String forall K, T
  {% if K == UInt64 %}
    CrystalClick::WidePartWriter.write_uint64_array_map_uint64_array_numeric_pair(
      destination, "pk", W85_KEYS.to_unsafe.to_slice(W85_KEYS.size), "payload", rows.to_unsafe.to_slice(rows.size), rows_per_mark: 2
    )
  {% elsif K == String %}
    CrystalClick::WidePartWriter.write_uint64_array_map_string_array_numeric_pair(
      destination, "pk", W85_KEYS.to_unsafe.to_slice(W85_KEYS.size), "payload", rows.to_unsafe.to_slice(rows.size), rows_per_mark: 2
    )
  {% else %}
    {% raise "W85 writer only supports UInt64 and String keys" %}
  {% end %}
end

private def w85_assert_selected_mark_corruption(
  part : String,
  rows : Array(Array(Array(Tuple(K, Array(T))))),
  label : String,
  stream : String,
  shift_bytes : UInt64,
  corruption_name : String,
) : Nil forall K, T
  corrupt_part = File.join(ENV.fetch("ORACLE_ROOT"), corruption_name, "all_2_2_0")
  FileUtils.mkdir_p(File.dirname(corrupt_part))
  FileUtils.cp_r(part, corrupt_part)
  mark_path = File.join(corrupt_part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(mark_path).to_slice.dup
  mark_size = CrystalClick::WidePart::MARK_SIZE
  previous_uncompressed_offset = w85_u64_at(marks, 8)
  old_uncompressed_offset = w85_u64_at(marks, mark_size + 8)
  next_mark_uncompressed_offset = w85_u64_at(marks, 2 * mark_size + 8)
  shifted_uncompressed_offset = old_uncompressed_offset + shift_bytes
  raw_size = w85_raw_stream(corrupt_part, stream).size.to_u64
  raise "W85 #{label} #{stream} middle mark is not leaf-width aligned" unless old_uncompressed_offset % shift_bytes == 0
  unless previous_uncompressed_offset < shifted_uncompressed_offset && shifted_uncompressed_offset < next_mark_uncompressed_offset && shifted_uncompressed_offset < raw_size
    raise "W85 #{label} #{stream} corruption cannot make an in-range monotonic shift of #{shift_bytes} bytes"
  end
  8.times { |byte| marks[mark_size + 8 + byte] = ((shifted_uncompressed_offset >> (byte * 8)) & 0xff_u64).to_u8 }
  File.write(mark_path, marks)

  opened_corrupt = CrystalClick::WidePart.open_typed(corrupt_part, "payload")
  original_reader = CrystalClick::WidePart.open_typed(part, "payload")
  raise "W85 #{label} #{stream} shift changed mark count before table preflight" unless opened_corrupt.mark_count == original_reader.mark_count
  corrupt_table = CrystalClick::WidePartTable.open_selected_typed([corrupt_part], ["pk", "payload"])

  callbacks = 0
  rejection_message = nil.as(String?)
  begin
    corrupt_table.scan_typed_candidate_marks([[1]]) do |batch|
      callbacks += 1
      batch.array_map_array_leaf_values_for("payload", K, T)
    end
  rescue ex : CrystalClick::CorruptPartError
    rejection_message = ex.message
  end
  unless rejection_message.try(&.includes?("mark range byte count mismatch"))
    raise "W85 #{label} #{stream} corruption did not fail on exact range byte count: #{rejection_message || "no error"}"
  end
  raise "W85 #{label} #{stream} corruption reached #{callbacks} callbacks" unless callbacks == 0
  puts "PASS W85 #{label} #{stream} #{shift_bytes}-byte in-range selected-middle-mark shift rejected during scan preflight before callbacks"
  nil
end

private def w85_assert_table_reader(
  part : String,
  label : String,
  rows : Array(Array(Array(Tuple(K, Array(T))))),
  check_corruption : Bool = false,
) : Nil forall K, T
  reader = CrystalClick::WidePart.open_typed(part, "payload")
  raise "W85 full stock-to-Crystal read differs" unless w85_read_range(reader, "payload", 0, reader.mark_count, T, rows) == rows
  raise "W85 selected middle stock-to-Crystal read differs" unless w85_read_range(reader, "payload", 1, 1, T, rows) == rows[2, 2]

  actual_keys = [] of UInt64
  actual_rows = [] of Array(Array(Tuple(K, Array(T))))
  CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"]).scan_typed do |batch|
    actual_keys.concat(batch.values_for("pk", UInt64).to_a)
    actual_rows.concat(batch.array_map_array_leaf_values_for("payload", K, T).to_a)
  end
  raise "W85 typed-table full scan differs" unless actual_keys == W85_KEYS && actual_rows == rows

  selected_keys = [] of UInt64
  selected_rows = [] of Array(Array(Tuple(K, Array(T))))
  CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"]).scan_typed_candidate_marks([[1]]) do |batch|
    selected_keys.concat(batch.values_for("pk", UInt64).to_a)
    selected_rows.concat(batch.array_map_array_leaf_values_for("payload", K, T).to_a)
  end
  raise "W85 typed-table selected mark differs" unless selected_keys == W85_KEYS[2, 2] && selected_rows == rows[2, 2]

  if check_corruption
    w85_assert_selected_mark_corruption(
      part, rows, label, "payload%2Evalues.size2", 8_u64, "corrupt-middle-mark"
    )
  end
  w85_assert_selected_mark_corruption(
    part, rows, label, "payload%2Evalues", sizeof(T).to_u64, "corrupt-leaf-middle-mark-#{label}"
  )
  nil
end

private def w85_create_table(binary : String, store : String, table : String, type : String) : Nil
  w85_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.#{table} (`pk` UInt64, `payload` #{type})
  ENGINE = MergeTree ORDER BY pk
  SETTINGS index_granularity = 2, index_granularity_bytes = 10485760,
    enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0,
    min_bytes_for_wide_part = 0, ratio_of_defaults_for_sparse_serialization = 1.0,
    compress_marks = 0, min_compress_block_size = 0, max_compress_block_size = 4096,
    write_final_mark = 1, default_compression_codec = 'LZ4'
  SQL
  nil
end

private def w85_check_table(binary : String, store : String, table : String) : Nil
  observed = w85_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "#{table} CHECK TABLE failed: #{observed.inspect}" unless observed == "all_1_1_0\t1"
end

private def w85_query_rows(binary : String, store : String, table : String, expected : Bytes, ranged : Bytes) : Nil
  full = w85_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  raise "#{table} full RowBinary differs" unless full.to_slice == expected
  selected = w85_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} WHERE pk >= 2 AND pk < 5 ORDER BY pk FORMAT RowBinary")
  raise "#{table} keyed RowBinary differs" unless selected.to_slice == ranged
  nil
end

private def w85_stock_part(binary : String, store : String, root : String, table : String) : String
  path = w85_clickhouse(binary, store, "SELECT path FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TSVRaw").strip
  raise "#{table} stock part is missing" unless Dir.exists?(path)
  parent = File.join(root, "stock-#{table}")
  FileUtils.mkdir_p(parent)
  part = File.join(parent, "all_1_1_0")
  FileUtils.cp_r(path, part)
  part
end

private def w85_attach_writer_part(
  binary : String,
  store : String,
  label : String,
  type : String,
  part : String,
  expected : Bytes,
  ranged : Bytes,
) : Nil
  table = "w85_writer_#{label.gsub('-', '_')}"
  w85_create_table(binary, store, table, type)
  data_path = w85_clickhouse(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{table}' FORMAT TSVRaw").strip
  raise "#{table} data path is missing" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  w85_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  w85_check_table(binary, store, table)
  w85_query_rows(binary, store, table, expected, ranged)
  nil
end

private def w85_run_case(
  binary : String,
  store : String,
  root : String,
  label : String,
  key_type : String,
  value_type : String,
  key_a : K,
  key_b : K,
  low : T,
  high : T,
) : Nil forall K, T
  type = "Array(Map(#{key_type}, Array(#{value_type})))"
  rows = w85_rows(key_a, key_b, low, high)
  full_indices = (0...W85_KEYS.size).map(&.to_i32)
  expected = w85_rowbinary(rows, full_indices)
  ranged = w85_rowbinary(rows, W85_SELECTED_INDICES)
  expected_raw = w85_expected_streams("payload", rows)
  primary = IO::Memory.new
  W85_KEYS.each { |key| w85_scalar(primary, key) }
  expected_raw["pk"] = primary.to_slice.to_a

  stock_table = "w85_stock_#{label.gsub('-', '_')}"
  w85_create_table(binary, store, stock_table, type)
  w85_clickhouse(binary, store, "INSERT INTO default.#{stock_table} FORMAT RowBinary", IO::Memory.new(expected))
  w85_check_table(binary, store, stock_table)
  w85_query_rows(binary, store, stock_table, expected, ranged)
  stock = w85_stock_part(binary, store, root, stock_table)
  w85_assert_part(stock, type, key_type, expected_raw, rows, "stock ClickHouse")

  {% if flag?(:w85_reader) %}
    w85_assert_table_reader(stock, label, rows, label == "u64-f32")
  {% end %}

  {% if flag?(:w85_writer) %}
    writer_part = File.join(root, "writer-#{label}")
    w85_write_part(writer_part, rows)
    w85_assert_part(writer_part, type, key_type, expected_raw, rows, "Crystal writer")
    w85_attach_writer_part(binary, store, label, type, writer_part, expected, ranged)
  {% end %}

  if label == "u64-f32"
    zero_bytes = expected_raw["payload%2Evalues"][0, 4]
    raise "Float32 negative-zero bits differ: #{zero_bytes}" unless zero_bytes == [0_u8, 0_u8, 0_u8, 0x80_u8]
  elsif label == "string-f64"
    zero_bytes = expected_raw["payload%2Evalues"][0, 8]
    raise "Float64 negative-zero bits differ: #{zero_bytes}" unless zero_bytes == [0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0x80_u8]
  end
  puts "PASS W85 ClickHouse RowBinary/ATTACH/CHECK #{type}"
  nil
end

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("CLICKHOUSE_STORE")
root = ENV.fetch("ORACLE_ROOT")
mode = ENV.fetch("W85_ORACLE_MODE", "full")
version = w85_clickhouse(binary, store, "SELECT version() FORMAT TSVRaw").strip
raise "W85 oracle requires ClickHouse 26.7.1.1315, got #{version}" unless version == "26.7.1.1315"

binary_key = String.new(Bytes[0x41_u8, 0x00_u8, 0xff_u8])

w85_run_case(binary, store, root, "u64-u8", "UInt64", "UInt8", 1_u64, 2_u64, 0_u8, UInt8::MAX)
w85_run_case(binary, store, root, "u64-u16", "UInt64", "UInt16", 1_u64, 2_u64, 0_u16, UInt16::MAX)
w85_run_case(binary, store, root, "u64-u32", "UInt64", "UInt32", 1_u64, 2_u64, 0_u32, UInt32::MAX)
w85_run_case(binary, store, root, "u64-u64", "UInt64", "UInt64", 1_u64, 2_u64, 0_u64, UInt64::MAX)
w85_run_case(binary, store, root, "u64-i8", "UInt64", "Int8", 1_u64, 2_u64, Int8::MIN, Int8::MAX)
w85_run_case(binary, store, root, "u64-i16", "UInt64", "Int16", 1_u64, 2_u64, Int16::MIN, Int16::MAX)
w85_run_case(binary, store, root, "u64-i32", "UInt64", "Int32", 1_u64, 2_u64, Int32::MIN, Int32::MAX)
w85_run_case(binary, store, root, "u64-i64", "UInt64", "Int64", 1_u64, 2_u64, Int64::MIN, Int64::MAX)
w85_run_case(binary, store, root, "u64-f32", "UInt64", "Float32", 1_u64, 2_u64, -0.0_f32, 3.5_f32)
w85_run_case(binary, store, root, "u64-f64", "UInt64", "Float64", 1_u64, 2_u64, -1.25_f64, 3.5_f64)

w85_run_case(binary, store, root, "string-u8", "String", "UInt8", "dup", binary_key, 0_u8, UInt8::MAX)
w85_run_case(binary, store, root, "string-u16", "String", "UInt16", "dup", binary_key, 0_u16, UInt16::MAX)
w85_run_case(binary, store, root, "string-u32", "String", "UInt32", "dup", binary_key, 0_u32, UInt32::MAX)
w85_run_case(binary, store, root, "string-u64", "String", "UInt64", "dup", binary_key, 0_u64, UInt64::MAX)
w85_run_case(binary, store, root, "string-i8", "String", "Int8", "dup", binary_key, Int8::MIN, Int8::MAX)
w85_run_case(binary, store, root, "string-i16", "String", "Int16", "dup", binary_key, Int16::MIN, Int16::MAX)
w85_run_case(binary, store, root, "string-i32", "String", "Int32", "dup", binary_key, Int32::MIN, Int32::MAX)
w85_run_case(binary, store, root, "string-i64", "String", "Int64", "dup", binary_key, Int64::MIN, Int64::MAX)
w85_run_case(binary, store, root, "string-f32", "String", "Float32", "dup", binary_key, -1.25_f32, 3.5_f32)
w85_run_case(binary, store, root, "string-f64", "String", "Float64", "x", "y", -0.0_f64, 3.5_f64)

reader_result = mode == "reader" || mode == "full" ? "stock-to-Crystal full/selected reader and table scans" : "reader not requested"
writer_result = mode == "writer" || mode == "full" ? "Crystal-to-stock ATTACH/CHECK/full/keyed RowBinary" : "writer not requested"
puts "W85 oracle mode=#{mode}: ClickHouse #{version}; 20 exact Array(Map(K, Array(N))) types; widths 1/2/4/8, signed and float values, negative-zero bits, duplicate/empty levels, binary String keys, exact raw streams and per-origin mark coordinates (stock one-frame/raw offsets vs Crystal per-mark frame offsets); #{reader_result}; #{writer_result}"
