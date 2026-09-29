require "file_utils"
require "../src/crystal_click"

W83_KEYS               = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
W83_RANGE_INDICES      = [1_i32, 2_i32, 3_i32]
W83_MARK_ROWS          = [2_u64, 2_u64, 1_u64, 0_u64]
W83_MARK_BOUNDARY_ROWS = [0, 2, 4, 5]
W83_BINARY_KEY         = String.new(Bytes[0x41_u8, 0_u8, 0xff_u8])

private def w83_rows_u64_bool : Array(Array(Array(Tuple(UInt64, Bool))))
  [
    [] of Array(Tuple(UInt64, Bool)),
    [
      [] of Tuple(UInt64, Bool),
      [{7_u64, false}, {7_u64, true}, {8_u64, false}] of Tuple(UInt64, Bool),
    ] of Array(Tuple(UInt64, Bool)),
    [[] of Tuple(UInt64, Bool)] of Array(Tuple(UInt64, Bool)),
    [] of Array(Tuple(UInt64, Bool)),
    [
      [{UInt64::MAX, true}, {0_u64, false}] of Tuple(UInt64, Bool),
      [] of Tuple(UInt64, Bool),
    ] of Array(Tuple(UInt64, Bool)),
  ] of Array(Array(Tuple(UInt64, Bool)))
end

private def w83_rows_string_bool : Array(Array(Array(Tuple(String, Bool))))
  [
    [] of Array(Tuple(String, Bool)),
    [
      [] of Tuple(String, Bool),
      [{"dup", false}, {"dup", true}, {W83_BINARY_KEY, false}] of Tuple(String, Bool),
    ] of Array(Tuple(String, Bool)),
    [[] of Tuple(String, Bool)] of Array(Tuple(String, Bool)),
    [] of Array(Tuple(String, Bool)),
    [
      [{W83_BINARY_KEY, true}, {"", false}] of Tuple(String, Bool),
      [] of Tuple(String, Bool),
    ] of Array(Tuple(String, Bool)),
  ] of Array(Array(Tuple(String, Bool)))
end

private def w83_rows_u64_nullable_bool : Array(Array(Array(Tuple(UInt64, Bool?))))
  [
    [] of Array(Tuple(UInt64, Bool?)),
    [
      [] of Tuple(UInt64, Bool?),
      [{7_u64, nil}, {7_u64, false}, {8_u64, true}] of Tuple(UInt64, Bool?),
    ] of Array(Tuple(UInt64, Bool?)),
    [[] of Tuple(UInt64, Bool?)] of Array(Tuple(UInt64, Bool?)),
    [] of Array(Tuple(UInt64, Bool?)),
    [
      [{UInt64::MAX, nil}, {0_u64, false}, {1_u64, true}] of Tuple(UInt64, Bool?),
      [] of Tuple(UInt64, Bool?),
    ] of Array(Tuple(UInt64, Bool?)),
  ] of Array(Array(Tuple(UInt64, Bool?)))
end

private def w83_rows_string_nullable_bool : Array(Array(Array(Tuple(String, Bool?))))
  [
    [] of Array(Tuple(String, Bool?)),
    [
      [] of Tuple(String, Bool?),
      [{"dup", nil}, {"dup", false}, {W83_BINARY_KEY, true}] of Tuple(String, Bool?),
    ] of Array(Tuple(String, Bool?)),
    [[] of Tuple(String, Bool?)] of Array(Tuple(String, Bool?)),
    [] of Array(Tuple(String, Bool?)),
    [
      [{W83_BINARY_KEY, nil}, {"", false}, {"true", true}] of Tuple(String, Bool?),
      [] of Tuple(String, Bool?),
    ] of Array(Tuple(String, Bool?)),
  ] of Array(Array(Tuple(String, Bool?)))
end

private def w83_rows_u64_bool_empty : Array(Array(Array(Tuple(UInt64, Bool))))
  [
    [] of Array(Tuple(UInt64, Bool)),
    [[] of Tuple(UInt64, Bool)] of Array(Tuple(UInt64, Bool)),
    [] of Array(Tuple(UInt64, Bool)),
    [[] of Tuple(UInt64, Bool)] of Array(Tuple(UInt64, Bool)),
    [] of Array(Tuple(UInt64, Bool)),
  ] of Array(Array(Tuple(UInt64, Bool)))
end

private def w83_rows_string_bool_empty : Array(Array(Array(Tuple(String, Bool))))
  [
    [] of Array(Tuple(String, Bool)),
    [[] of Tuple(String, Bool)] of Array(Tuple(String, Bool)),
    [] of Array(Tuple(String, Bool)),
    [[] of Tuple(String, Bool)] of Array(Tuple(String, Bool)),
    [] of Array(Tuple(String, Bool)),
  ] of Array(Array(Tuple(String, Bool)))
end

private def w83_rows_u64_nullable_bool_empty : Array(Array(Array(Tuple(UInt64, Bool?))))
  [
    [] of Array(Tuple(UInt64, Bool?)),
    [[] of Tuple(UInt64, Bool?)] of Array(Tuple(UInt64, Bool?)),
    [] of Array(Tuple(UInt64, Bool?)),
    [[] of Tuple(UInt64, Bool?)] of Array(Tuple(UInt64, Bool?)),
    [] of Array(Tuple(UInt64, Bool?)),
  ] of Array(Array(Tuple(UInt64, Bool?)))
end

private def w83_rows_string_nullable_bool_empty : Array(Array(Array(Tuple(String, Bool?))))
  [
    [] of Array(Tuple(String, Bool?)),
    [[] of Tuple(String, Bool?)] of Array(Tuple(String, Bool?)),
    [] of Array(Tuple(String, Bool?)),
    [[] of Tuple(String, Bool?)] of Array(Tuple(String, Bool?)),
    [] of Array(Tuple(String, Bool?)),
  ] of Array(Array(Tuple(String, Bool?)))
end

private def w83_clickhouse(binary : String, store : String, query : String, input : IO = IO::Memory.new) : String
  output = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], input: input, output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (#{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

private def w83_assert_pinned_clickhouse(binary : String) : Nil
  output = IO::Memory.new
  status = Process.run(binary, ["local", "--version"], output: output, error: Process::Redirect::Inherit)
  expected = "ClickHouse local version 26.7.1.1315 (official build)."
  raise "W83 requires #{expected}, got #{output.to_s.strip}" unless status.success? && output.to_s.strip == expected
end

private def w83_u64(io : IO, value : UInt64) : Nil
  io.write_bytes(value, IO::ByteFormat::LittleEndian)
end

private def w83_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w83_string(io : IO, value : String) : Nil
  w83_varuint(io, value.bytesize.to_u64)
  io.write(value.to_slice)
end

private def w83_key(io : IO, key : K) : Nil forall K
  {% if K == String %}
    w83_string(io, key)
  {% elsif K == UInt64 %}
    w83_u64(io, key)
  {% else %}
    {% raise "unsupported W83 Map key type" %}
  {% end %}
end

private def w83_bool_byte(io : IO, value : Bool) : Nil
  io.write_byte(value ? 1_u8 : 0_u8)
end

private def w83_rowbinary(
  keys : Array(UInt64),
  rows : Array(Array(Array(Tuple(K, V)))),
  indices : Array(Int32),
) : Bytes forall K, V
  raise "W83 primary-key and Array(Map) row counts differ" unless keys.size == rows.size
  io = IO::Memory.new
  indices.each do |index|
    w83_u64(io, keys[index])
    maps = rows[index]
    w83_varuint(io, maps.size.to_u64)
    maps.each do |entries|
      w83_varuint(io, entries.size.to_u64)
      entries.each do |key, value|
        w83_key(io, key)
        {% if V.union_types.size == 2 && V.union_types.includes?(Nil) %}
          if value.nil?
            io.write_byte(1_u8)
          else
            io.write_byte(0_u8)
            w83_bool_byte(io, value.not_nil!)
          end
        {% else %}
          w83_bool_byte(io, value)
        {% end %}
      end
    end
  end
  io.to_slice
end

private def w83_expected_streams(rows : Array(Array(Array(Tuple(K, V))))) : Hash(String, Array(UInt8)) forall K, V
  outer_sizes = IO::Memory.new
  map_sizes = IO::Memory.new
  key_sizes = IO::Memory.new
  keys = IO::Memory.new
  value_nulls = IO::Memory.new
  values = IO::Memory.new
  rows.each do |row|
    w83_u64(outer_sizes, row.size.to_u64)
    row.each do |entries|
      w83_u64(map_sizes, entries.size.to_u64)
      entries.each do |key, value|
        {% if K == String %}
          w83_u64(key_sizes, key.bytesize.to_u64)
          keys.write(key.to_slice)
        {% else %}
          w83_u64(keys, key)
        {% end %}
        {% if V.union_types.size == 2 && V.union_types.includes?(Nil) %}
          if value.nil?
            value_nulls.write_byte(1_u8)
            w83_bool_byte(values, false)
          else
            value_nulls.write_byte(0_u8)
            w83_bool_byte(values, value.not_nil!)
          end
        {% else %}
          w83_bool_byte(values, value)
        {% end %}
      end
    end
  end

  result = {
    "payload.size0"    => outer_sizes.to_slice.to_a,
    "payload.size1"    => map_sizes.to_slice.to_a,
    "payload%2Ekeys"   => keys.to_slice.to_a,
    "payload%2Evalues" => values.to_slice.to_a,
  }
  {% if K == String %}
    result["payload%2Ekeys.size"] = key_sizes.to_slice.to_a
  {% end %}
  {% if V.union_types.size == 2 && V.union_types.includes?(Nil) %}
    result["payload%2Evalues.null"] = value_nulls.to_slice.to_a
  {% end %}
  result
end

private def w83_stream_names(key_type : String, nullable : Bool) : Array(String)
  names = ["payload.size0", "payload.size1"] of String
  names << "payload%2Ekeys.size" if key_type == "String"
  names << "payload%2Ekeys"
  names << "payload%2Evalues.null" if nullable
  names << "payload%2Evalues"
  names
end

private def w83_raw_stream(part : String, stream : String) : Array(UInt8)
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
  encoded = File.read(path).to_slice
  return [] of UInt8 if encoded.empty?
  CrystalClick::CompressedBlock.decode_all(encoded).to_a
end

private def w83_u64_at(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w83_mark_records(part : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64))
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  bytes = File.read(path).to_slice
  raise "#{part} #{stream} mark file size differs: #{bytes.size}" unless bytes.size == W83_MARK_ROWS.size * CrystalClick::WidePart::MARK_SIZE
  Array(Tuple(UInt64, UInt64, UInt64)).new(W83_MARK_ROWS.size) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    {w83_u64_at(bytes, offset), w83_u64_at(bytes, offset + 8), w83_u64_at(bytes, offset + 16)}
  end
end

private def w83_expected_mark_records(
  rows : Array(Array(Array(Tuple(K, V)))),
  stream : String,
) : Array(Tuple(UInt64, UInt64, UInt64)) forall K, V
  row_bytes = rows.map do |row|
    case stream
    when "pk", "payload.size0"
      8_u64
    when "payload.size1"
      (row.size * 8).to_u64
    when "payload%2Ekeys.size"
      (row.sum(&.size) * 8).to_u64
    when "payload%2Ekeys"
      bytes = 0_u64
      row.each do |entries|
        entries.each do |key, _value|
          {% if K == String %}
            bytes += key.bytesize.to_u64
          {% else %}
            bytes += 8_u64
          {% end %}
        end
      end
      bytes
    when "payload%2Evalues.null", "payload%2Evalues"
      row.sum(&.size).to_u64
    else
      raise "unexpected W83 mark stream #{stream}"
    end
  end
  W83_MARK_BOUNDARY_ROWS.map_with_index do |boundary, index|
    raw_offset = row_bytes[0, boundary].sum
    {0_u64, raw_offset, W83_MARK_ROWS[index]}
  end
end

private def w83_expected_writer_mark_records(
  part : String,
  stream : String,
  rows : Array(Array(Array(Tuple(K, V)))),
) : Array(Tuple(UInt64, UInt64, UInt64)) forall K, V
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
  encoded = File.read(path).to_slice
  frames = [] of Tuple(UInt64, UInt64, UInt64)
  compressed_offset = 0_i64
  raw_offset = 0_u64
  while compressed_offset < encoded.size
    frame = CrystalClick::CompressedBlock.decode_frame(encoded, compressed_offset)
    frames << {compressed_offset.to_u64, raw_offset, frame.output.size.to_u64}
    raw_offset += frame.output.size.to_u64
    compressed_offset = frame.end_offset
  end

  expected_raw_marks = w83_expected_mark_records(rows, stream)
  expected_raw_marks.map do |_, mark_raw_offset, mark_rows|
    frame = frames.find do |_, frame_raw_offset, frame_raw_size|
      mark_raw_offset >= frame_raw_offset && mark_raw_offset - frame_raw_offset < frame_raw_size
    end
    if frame
      {frame[0], mark_raw_offset - frame[1], mark_rows}
    else
      raise "#{part} #{stream} mark raw offset exceeds compressed stream output" unless mark_raw_offset == raw_offset
      {compressed_offset.to_u64, 0_u64, mark_rows}
    end
  end
end

private def w83_create_table(binary : String, store : String, table : String, type_name : String) : Nil
  w83_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.#{table} (`pk` UInt64, `payload` #{type_name})
  ENGINE = MergeTree ORDER BY pk
  SETTINGS index_granularity = 2, index_granularity_bytes = 10485760,
    enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0,
    min_bytes_for_wide_part = 0, ratio_of_defaults_for_sparse_serialization = 1.0,
    compress_marks = 0, min_compress_block_size = 0, max_compress_block_size = 4096,
    write_final_mark = 1, default_compression_codec = 'LZ4'
  SQL
  nil
end

private def w83_check_table(binary : String, store : String, table : String) : Nil
  observed = w83_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "#{table} CHECK TABLE failed: #{observed.inspect}" unless observed == "all_1_1_0\t1"
end

private def w83_query_rows(binary : String, store : String, table : String, expected : Bytes, ranged : Bytes) : Nil
  full = w83_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  raise "#{table} full RowBinary differs" unless full.to_slice == expected
  selected = w83_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} WHERE pk >= 2 AND pk < 5 ORDER BY pk FORMAT RowBinary")
  raise "#{table} keyed RowBinary differs" unless selected.to_slice == ranged
  nil
end

private def w83_stock_part(binary : String, store : String, root : String, table : String) : String
  path = w83_clickhouse(binary, store, "SELECT path FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TSVRaw").strip
  raise "#{table} source part missing" unless Dir.exists?(path)
  part = File.join(root, "stock-#{table}")
  FileUtils.cp_r(path, part)
  part
end

private def w83_assert_part(
  part : String,
  key_type : String,
  nullable : Bool,
  stock : Bool,
  rows : Array(Array(Array(Tuple(K, V)))),
  expected_raw : Hash(String, Array(UInt8)),
) : Nil forall K, V
  value_type = nullable ? "Nullable(Bool)" : "Bool"
  full_type = "Array(Map(#{key_type}, #{value_type}))"
  streams = w83_stream_names(key_type, nullable)
  expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` #{full_type}\n"
  raise "#{part} columns differ" unless File.read(File.join(part, "columns.txt")) == expected_columns

  expected_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" +
                        "#{streams.size} substreams for column `payload`:\n" + streams.map { |stream| "\t#{stream}\n" }.join
  raise "#{part} substream inventory/order differs" unless File.read(File.join(part, "columns_substreams.txt")) == expected_substreams

  serialization = File.read(File.join(part, "serialization.json")).strip
  expected_serialization = %({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
  raise "#{part} serialization.json differs: #{serialization}" unless serialization == expected_serialization

  expected_files = [
    "checksums.txt", "columns.txt", "columns_substreams.txt", "count.txt",
    "default_compression_codec.txt", "metadata_version.txt", stock ? "primary.cidx" : "primary.idx",
    "serialization.json",
  ]
  (streams + ["pk"]).each do |stream|
    base = CrystalClick::StreamName.hash(stream)
    expected_files << "#{base}.bin" << "#{base}.mrk2"
  end
  actual_files = Dir.children(part).sort
  missing = expected_files - actual_files
  extra = actual_files - expected_files
  raise "#{part} file inventory differs (missing=#{missing.sort}, extra=#{extra.sort})" unless actual_files == expected_files.sort
  raise "#{part} row count differs" unless File.read(File.join(part, "count.txt")) == W83_KEYS.size.to_s
  raise "#{part} metadata version differs" unless File.read(File.join(part, "metadata_version.txt")) == "0"
  raise "#{part} codec differs" unless File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)"

  checksums = CrystalClick::PartChecksums.open(part)
  checksum_files = expected_files - [
    "checksums.txt", "columns.txt", "columns_substreams.txt", "default_compression_codec.txt", "metadata_version.txt",
  ]
  raise "#{part} checksum inventory differs" unless checksums.entries.keys.sort == checksum_files.sort
  checksums.entries.each_key { |name| checksums.validate_selected_entries(part, name) }

  expected_raw.each do |stream, bytes|
    actual = w83_raw_stream(part, stream)
    raise "#{part} #{stream} raw bytes differ (expected=#{bytes.size}, actual=#{actual.size})" unless actual == bytes
    puts "#{File.basename(part)} #{stream} raw=#{actual.map { |byte| "%02x" % byte }.join}"
  end

  (streams + ["pk"]).each do |stream|
    records = w83_mark_records(part, stream)
    expected_marks = w83_expected_mark_records(rows, stream)
    raise "#{part} #{stream} mark row counts differ: #{records.inspect}" unless records.map(&.[2]) == W83_MARK_ROWS
    raw_size = expected_raw[stream].size.to_u64
    records.each_cons(2) do |pair|
      left, right = pair[0], pair[1]
      raise "#{part} #{stream} mark offsets are not monotonic" if right[0] < left[0] || (right[0] == left[0] && right[1] < left[1])
    end
    if stock
      raise "#{part} #{stream} compressed mark coordinates differ: #{records.inspect}" unless records == expected_marks
      raise "#{part} #{stream} terminal mark raw offset differs" unless records.last[1] == raw_size
    else
      writer_marks = w83_expected_writer_mark_records(part, stream, rows)
      raise "#{part} #{stream} writer compressed/decompressed mark coordinates differ: #{records.inspect}" unless records == writer_marks
      data_size = File.size(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_u64
      raise "#{part} #{stream} writer terminal compressed offset differs" unless records.last[0] == data_size && records.last[1] == 0_u64
    end
    if streams.includes?(stream) && stream != "payload.size0" && stream != "payload.size1"
      raise "#{part} #{stream} empty child mark advanced" unless {records[1][0], records[1][1]} == {records[2][0], records[2][1]}
      if raw_size == 0_u64
        raise "#{part} #{stream} zero-byte child marks are not all at origin" unless records.all? { |record| {record[0], record[1]} == {0_u64, 0_u64} }
      end
    end
    puts "#{File.basename(part)} #{stream} marks=#{records.inspect} raw_bytes=#{raw_size}"
  end
  nil
end

private def w83_read_mark(
  reader : CrystalClick::WidePart,
  first_mark : Int32,
  mark_count : Int32,
  rows : Array(Array(Array(Tuple(K, V)))),
) : Array(Array(Array(Tuple(K, V)))) forall K, V
  {% if K == UInt64 %}
    {% if V.union_types.size == 2 && V.union_types.includes?(Nil) %}
      reader.read_array_map_uint64_nullable_bool_mark_range("payload", first_mark, mark_count)
    {% else %}
      reader.read_array_map_uint64_bool_mark_range("payload", first_mark, mark_count)
    {% end %}
  {% else %}
    {% if V.union_types.size == 2 && V.union_types.includes?(Nil) %}
      reader.read_array_map_string_nullable_bool_mark_range("payload", first_mark, mark_count)
    {% else %}
      reader.read_array_map_string_bool_mark_range("payload", first_mark, mark_count)
    {% end %}
  {% end %}
end

private def w83_table_values(
  batch : CrystalClick::WidePartTableBatch,
  rows : Array(Array(Array(Tuple(K, V)))),
) : Slice(Array(Array(Tuple(K, V)))) forall K, V
  {% if K == UInt64 %}
    {% if V.union_types.size == 2 && V.union_types.includes?(Nil) %}
      batch.array_map_uint64_nullable_bools_for("payload")
    {% else %}
      batch.array_map_uint64_bools_for("payload")
    {% end %}
  {% else %}
    {% if V.union_types.size == 2 && V.union_types.includes?(Nil) %}
      batch.array_map_string_nullable_bools_for("payload")
    {% else %}
      batch.array_map_string_bools_for("payload")
    {% end %}
  {% end %}
end

private def w83_assert_table_reads(
  part : String,
  root : String,
  rows : Array(Array(Array(Tuple(K, V)))),
  expected : Bytes,
  ranged : Bytes,
) : Nil forall K, V
  table_part = File.join(root, "typed-table-read-#{File.basename(part)}", "all_1_1_0")
  FileUtils.mkdir_p(File.dirname(table_part))
  FileUtils.cp_r(part, table_part)
  table = CrystalClick::WidePartTable.open_selected_typed([table_part], ["pk", "payload"])
  observed_keys = [] of UInt64
  observed_rows = [] of Array(Array(Tuple(K, V)))
  table.scan_typed(batch_rows: 2) do |batch|
    observed_keys.concat(batch.values_for("pk").to_a)
    observed_rows.concat(w83_table_values(batch, rows).to_a)
  end
  raise "W83 typed-table full payload differs" unless observed_rows == rows
  all_indices = (0...observed_keys.size).map(&.to_i32)
  raise "W83 typed-table full RowBinary differs" unless w83_rowbinary(observed_keys, observed_rows, all_indices) == expected

  range_keys = [] of UInt64
  range_rows = [] of Array(Array(Tuple(K, V)))
  table.scan_typed_window(1_u64, max_rows: 3) do |batch|
    range_keys.concat(batch.values_for("pk").to_a)
    range_rows.concat(w83_table_values(batch, rows).to_a)
  end
  raise "W83 typed-table keyed payload differs" unless range_rows == rows[1, 3]
  range_indices = (0...range_keys.size).map(&.to_i32)
  raise "W83 typed-table keyed RowBinary differs" unless w83_rowbinary(range_keys, range_rows, range_indices) == ranged
  puts "PASS W83 stock-to-Crystal typed table full/keyed accessors and RowBinary"
  nil
end

private def w83_write_u64_at(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w83_assert_later_mark_corruption_rejected(
  part : String,
  root : String,
  rows : Array(Array(Array(Tuple(K, V)))),
) : Nil forall K, V
  corrupt_part = File.join(root, "corrupt-w83-later-child-mark-#{File.basename(part)}")
  FileUtils.cp_r(part, corrupt_part)
  marks_path = File.join(corrupt_part, "#{CrystalClick::StreamName.hash("payload.size1")}.mrk2")
  marks = File.read(marks_path).to_slice.dup
  w83_write_u64_at(marks, 2 * CrystalClick::WidePart::MARK_SIZE + 8, UInt64::MAX)
  File.write(marks_path, marks)

  rejected = false
  begin
    corrupt_reader = CrystalClick::WidePart.open_typed(corrupt_part, "payload")
    w83_read_mark(corrupt_reader, 2, 1, rows)
  rescue ex : CrystalClick::CorruptPartError
    rejected = true
  end
  raise "reader accepted a malformed later W83 Map-size mark" unless rejected

  corrupt_table_part = File.join(root, "corrupt-w83-table-#{File.basename(part)}", "all_1_1_0")
  FileUtils.mkdir_p(File.dirname(corrupt_table_part))
  FileUtils.cp_r(corrupt_part, corrupt_table_part)
  callbacks = 0
  table_rejected = false
  begin
    corrupt_table = CrystalClick::WidePartTable.open_selected_typed([corrupt_table_part], ["pk", "payload"])
    corrupt_table.scan_typed(batch_rows: 2) do |batch|
      callbacks += batch.values_for("pk").size
    end
  rescue ex : CrystalClick::CorruptPartError
    table_rejected = true
  end
  raise "typed-table scan did not reject the malformed later W83 mark" unless table_rejected
  raise "typed-table scan yielded #{callbacks} rows before rejecting the malformed later W83 mark" unless callbacks == 0
  puts "PASS W83 corruption guard: direct reader and typed table reject later mark before callback"
  nil
end

private def w83_write_part(destination : String, rows : Array(Array(Array(Tuple(K, V))))) : String forall K, V
  {% if K == UInt64 %}
    {% if V.union_types.size == 2 && V.union_types.includes?(Nil) %}
      CrystalClick::WidePartWriter.write_uint64_array_map_uint64_nullable_bool_pair(
        destination, "pk", W83_KEYS.to_unsafe.to_slice(W83_KEYS.size), "payload", rows.to_unsafe.to_slice(rows.size), rows_per_mark: 2
      )
    {% else %}
      CrystalClick::WidePartWriter.write_uint64_array_map_uint64_bool_pair(
        destination, "pk", W83_KEYS.to_unsafe.to_slice(W83_KEYS.size), "payload", rows.to_unsafe.to_slice(rows.size), rows_per_mark: 2
      )
    {% end %}
  {% else %}
    {% if V.union_types.size == 2 && V.union_types.includes?(Nil) %}
      CrystalClick::WidePartWriter.write_uint64_array_map_string_nullable_bool_pair(
        destination, "pk", W83_KEYS.to_unsafe.to_slice(W83_KEYS.size), "payload", rows.to_unsafe.to_slice(rows.size), rows_per_mark: 2
      )
    {% else %}
      CrystalClick::WidePartWriter.write_uint64_array_map_string_bool_pair(
        destination, "pk", W83_KEYS.to_unsafe.to_slice(W83_KEYS.size), "payload", rows.to_unsafe.to_slice(rows.size), rows_per_mark: 2
      )
    {% end %}
  {% end %}
  destination
end

private def w83_attach_writer_part(
  binary : String,
  store : String,
  label : String,
  type : String,
  part : String,
  expected : Bytes,
  ranged : Bytes,
) : Nil
  table = "w83_writer_#{label}"
  w83_create_table(binary, store, table, type)
  data_path = w83_clickhouse(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{table}' FORMAT TSVRaw").strip
  raise "#{table} data path is missing" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  w83_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  w83_check_table(binary, store, table)
  w83_query_rows(binary, store, table, expected, ranged)
  puts "PASS W83 Crystal-to-stock ATTACH/CHECK/full/keyed RowBinary #{type}"
  nil
end

private def w83_run_case(
  binary : String,
  store : String,
  root : String,
  label : String,
  key_type : String,
  nullable : Bool,
  rows : Array(Array(Array(Tuple(K, V)))),
) : Nil forall K, V
  value_type = nullable ? "Nullable(Bool)" : "Bool"
  type = "Array(Map(#{key_type}, #{value_type}))"
  full_indices = (0...W83_KEYS.size).map(&.to_i32)
  expected = w83_rowbinary(W83_KEYS, rows, full_indices)
  ranged = w83_rowbinary(W83_KEYS, rows, W83_RANGE_INDICES)
  expected_raw = w83_expected_streams(rows)
  pk = IO::Memory.new
  W83_KEYS.each { |key| w83_u64(pk, key) }
  expected_raw["pk"] = pk.to_slice.to_a

  table = "w83_stock_#{label}"
  w83_create_table(binary, store, table, type)
  w83_clickhouse(binary, store, "INSERT INTO default.#{table} FORMAT RowBinary", IO::Memory.new(expected))
  w83_check_table(binary, store, table)
  w83_query_rows(binary, store, table, expected, ranged)
  part = w83_stock_part(binary, store, root, table)
  w83_assert_part(part, key_type, nullable, true, rows, expected_raw)

  {% if flag?(:w83_reader) %}
    reader = CrystalClick::WidePart.open_typed(part, "payload")
    stock_values = w83_read_mark(reader, 0, reader.mark_count, rows)
    middle_values = w83_read_mark(reader, 1, 1, rows)
    later_values = w83_read_mark(reader, 2, 1, rows)
    raise "#{table} full stock-to-Crystal read differs" unless stock_values == rows
    raise "#{table} middle mark read differs" unless middle_values == rows[2, 2]
    raise "#{table} later-mark read differs" unless later_values == rows[4, 1]
    puts "PASS W83 stock-to-Crystal full/middle/later marks #{type}"
    w83_assert_table_reads(part, root, rows, expected, ranged)
    if label == "u64_nullable_bool"
      w83_assert_later_mark_corruption_rejected(part, root, rows)
    end
  {% end %}

  {% if flag?(:w83_writer) %}
    writer_part = File.join(root, "writer-#{label}")
    w83_write_part(writer_part, rows)
    w83_assert_part(writer_part, key_type, nullable, false, rows, expected_raw)
    w83_attach_writer_part(binary, store, label, type, writer_part, expected, ranged)
  {% end %}

  puts "PASS W83 stock fixture #{type} full/keyed RowBinary and exact substreams"
  nil
end

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("CLICKHOUSE_STORE")
root = ENV.fetch("ORACLE_ROOT")
w83_assert_pinned_clickhouse(binary)

w83_run_case(binary, store, root, "u64_bool", "UInt64", false, w83_rows_u64_bool)
w83_run_case(binary, store, root, "string_bool", "String", false, w83_rows_string_bool)
w83_run_case(binary, store, root, "u64_nullable_bool", "UInt64", true, w83_rows_u64_nullable_bool)
w83_run_case(binary, store, root, "string_nullable_bool", "String", true, w83_rows_string_nullable_bool)
w83_run_case(binary, store, root, "u64_bool_empty", "UInt64", false, w83_rows_u64_bool_empty)
w83_run_case(binary, store, root, "string_bool_empty", "String", false, w83_rows_string_bool_empty)
w83_run_case(binary, store, root, "u64_nullable_bool_empty", "UInt64", true, w83_rows_u64_nullable_bool_empty)
w83_run_case(binary, store, root, "string_nullable_bool_empty", "String", true, w83_rows_string_nullable_bool_empty)

puts "W83 oracle mode=#{ENV.fetch("W83_ORACLE_MODE", "stock")}: ClickHouse 26.7.1.1315; four exact Array(Map) Bool declarations; full/keyed RowBinary; raw substreams and four-mark layout; all-empty child streams"
