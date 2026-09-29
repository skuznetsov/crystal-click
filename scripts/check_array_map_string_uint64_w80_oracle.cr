require "file_utils"
require "../src/crystal_click"

W80_KEYS       = [1_u64, 2_u64, 4_u64, 7_u64, 10_u64, 11_u64, 12_u64]
W80_BINARY_KEY = String.new(Bytes[0x41_u8, 0_u8, 0xff_u8])
W80_ROWS       = [
  [] of Array(Tuple(String, UInt64)),
  [
    [] of Tuple(String, UInt64),
    [{"dup", 0_u64}, {"dup", UInt64::MAX}] of Tuple(String, UInt64),
  ] of Array(Tuple(String, UInt64)),
  [] of Array(Tuple(String, UInt64)),
  [] of Array(Tuple(String, UInt64)),
  [
    [{W80_BINARY_KEY, 0_u64}, {"", 42_u64}] of Tuple(String, UInt64),
    [] of Tuple(String, UInt64),
  ] of Array(Tuple(String, UInt64)),
  [
    [] of Tuple(String, UInt64),
    [{"zero", 0_u64}, {"tail", 19_u64}] of Tuple(String, UInt64),
  ] of Array(Tuple(String, UInt64)),
  [] of Array(Tuple(String, UInt64)),
] of Array(Array(Tuple(String, UInt64)))

private def w80_clickhouse(binary : String, store : String, query : String, input : IO = IO::Memory.new) : String
  output = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], input: input, output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (#{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

private def w80_u64(io : IO, value : UInt64) : Nil
  8.times { |byte| io.write_byte(((value >> (byte * 8)) & 0xff_u64).to_u8) }
end

private def w80_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w80_string(io : IO, value : String) : Nil
  w80_varuint(io, value.bytesize.to_u64)
  io.write(value.to_slice)
end

# Independent RowBinary encoder: row -> outer Array -> Map entries.
private def w80_rowbinary(
  keys : Array(UInt64),
  rows : Array(Array(Array(Tuple(String, UInt64)))),
  indices : Array(Int32),
) : Bytes
  io = IO::Memory.new
  indices.each do |index|
    w80_u64(io, keys[index])
    maps = rows[index]
    w80_varuint(io, maps.size.to_u64)
    maps.each do |entries|
      w80_varuint(io, entries.size.to_u64)
      entries.each do |key, value|
        w80_string(io, key)
        w80_u64(io, value)
      end
    end
  end
  io.to_slice
end

private def w80_create_table(binary : String, store : String, table : String) : Nil
  w80_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.#{table} (pk UInt64, payload Array(Map(String, UInt64)))
  ENGINE = MergeTree ORDER BY pk
  SETTINGS index_granularity = 2, index_granularity_bytes = 10485760,
    enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0,
    min_bytes_for_wide_part = 0, compress_marks = 0,
    min_compress_block_size = 0, max_compress_block_size = 4096,
    ratio_of_defaults_for_sparse_serialization = 1.0,
    default_compression_codec = 'LZ4'
  SQL
end

private def w80_check_table(binary : String, store : String, table : String) : Nil
  observed = w80_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "#{table} CHECK TABLE failed: #{observed.inspect}" unless observed == "all_1_1_0\t1"
end

private def w80_query_rows(binary : String, store : String, table : String, expected : Bytes, ranged : Bytes) : Nil
  full = w80_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  raise "#{table} full RowBinary mismatch" unless full.to_slice == expected
  selected = w80_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} WHERE pk >= 2 AND pk < 10 ORDER BY pk FORMAT RowBinary")
  raise "#{table} key-range RowBinary mismatch" unless selected.to_slice == ranged
end

private def w80_u64_at(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w80_write_u64_at(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w80_mark_records(part : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64))
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  bytes = File.read(path).to_slice
  raise "#{part} #{stream} mark file has invalid size #{bytes.size}" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(Tuple(UInt64, UInt64, UInt64)).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    {w80_u64_at(bytes, offset), w80_u64_at(bytes, offset + 8), w80_u64_at(bytes, offset + 16)}
  end
end

private def w80_stock_part(binary : String, store : String, root : String, table : String) : String
  path = w80_clickhouse(binary, store, "SELECT path FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TSVRaw").strip
  raise "#{table} source part missing" unless Dir.exists?(path)
  part = File.join(root, "stock-#{table}")
  FileUtils.cp_r(path, part)
  part
end

private def w80_assert_part_topology(part : String, exact_stock_marks : Bool = true) : Nil
  expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` Array(Map(String, UInt64))\n"
  raise "#{part} columns differ" unless File.read(File.join(part, "columns.txt")) == expected_columns

  streams = [
    "payload.size0",
    "payload.size1",
    "payload%2Ekeys.size",
    "payload%2Ekeys",
    "payload%2Evalues",
  ]
  expected_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n5 substreams for column `payload`:\n" +
                        streams.map { |stream| "\t#{stream}\n" }.join
  raise "#{part} substreams differ" unless File.read(File.join(part, "columns_substreams.txt")) == expected_substreams

  serialization = File.read(File.join(part, "serialization.json")).strip
  expected_serialization = %({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
  raise "#{part} serialization differs: #{serialization}" unless serialization == expected_serialization

  expected_marks = {
    "pk"                  => [{0_u64, 0_u64, 2_u64}, {0_u64, 16_u64, 2_u64}, {0_u64, 32_u64, 2_u64}, {0_u64, 48_u64, 1_u64}, {0_u64, 56_u64, 0_u64}],
    "payload.size0"       => [{0_u64, 0_u64, 2_u64}, {0_u64, 16_u64, 2_u64}, {0_u64, 32_u64, 2_u64}, {0_u64, 48_u64, 1_u64}, {0_u64, 56_u64, 0_u64}],
    "payload.size1"       => [{0_u64, 0_u64, 2_u64}, {0_u64, 16_u64, 2_u64}, {0_u64, 16_u64, 2_u64}, {0_u64, 48_u64, 1_u64}, {0_u64, 48_u64, 0_u64}],
    "payload%2Ekeys.size" => [{0_u64, 0_u64, 2_u64}, {0_u64, 16_u64, 2_u64}, {0_u64, 16_u64, 2_u64}, {0_u64, 48_u64, 1_u64}, {0_u64, 48_u64, 0_u64}],
    "payload%2Ekeys"      => [{0_u64, 0_u64, 2_u64}, {0_u64, 6_u64, 2_u64}, {0_u64, 6_u64, 2_u64}, {0_u64, 17_u64, 1_u64}, {0_u64, 17_u64, 0_u64}],
    "payload%2Evalues"    => [{0_u64, 0_u64, 2_u64}, {0_u64, 16_u64, 2_u64}, {0_u64, 16_u64, 2_u64}, {0_u64, 48_u64, 1_u64}, {0_u64, 48_u64, 0_u64}],
  }

  (["pk"] + streams).each do |stream|
    records = w80_mark_records(part, stream)
    if exact_stock_marks
      expected = expected_marks[stream]
      raise "#{part} #{stream} exact marks differ: #{records.inspect}" unless records == expected
      puts "#{File.basename(part)} #{stream} marks=#{records.inspect}"
    else
      expected_rows = [2_u64, 2_u64, 2_u64, 1_u64, 0_u64]
      raise "#{part} #{stream} mark count differs: #{records.size}" unless records.size == expected_rows.size
      data_size = File.size(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_u64
      previous = {0_u64, 0_u64}
      records.each_with_index do |record, index|
        raise "#{part} #{stream} mark row count differs at #{index}" unless record[2] == expected_rows[index]
        raise "#{part} #{stream} compressed mark offset exceeds data extent at #{index}" if record[0] > data_size
        if index > 0 && (record[0] < previous[0] || (record[0] == previous[0] && record[1] < previous[1]))
          raise "#{part} #{stream} mark offsets are not monotonic at #{index}"
        end
        previous = {record[0], record[1]}
      end
      raise "#{part} #{stream} terminal mark does not point to data EOF" unless records.last[0] == data_size
      puts "#{File.basename(part)} #{stream} writer marks=#{records.inspect} data_bytes=#{data_size}"
    end
  end

  ["payload.size1", "payload%2Ekeys.size", "payload%2Ekeys", "payload%2Evalues"].each do |stream|
    records = w80_mark_records(part, stream)
    middle_empty = records[1]
    later_nonempty = records[2]
    unless middle_empty[0] == later_nonempty[0] && middle_empty[1] == later_nonempty[1]
      raise "#{part} #{stream} empty middle mark advanced its child stream"
    end

    final_empty = records[3]
    terminal = records[4]
    unless final_empty[0] == terminal[0] && final_empty[1] == terminal[1] && (final_empty[0] > 0_u64 || final_empty[1] > 0_u64)
      raise "#{part} #{stream} final all-empty mark did not end at nonzero child EOF"
    end
  end

  puts "#{File.basename(part)} columns=#{expected_columns.inspect}"
  puts "#{File.basename(part)} columns_substreams=#{expected_substreams.inspect}"
  puts "#{File.basename(part)} serialization.json=#{serialization}"
  nil
end

{% if flag?(:w80_reader) %}
  private def w80_assert_invalid_child_mark_rejected(part : String, root : String) : Nil
    corrupt_part = File.join(root, "corrupt-child-mark")
    FileUtils.cp_r(part, corrupt_part)
    marks_path = File.join(corrupt_part, "#{CrystalClick::StreamName.hash("payload.size1")}.mrk2")
    marks = File.read(marks_path).to_slice.dup
    mark_offset = 2 * CrystalClick::WidePart::MARK_SIZE
    w80_write_u64_at(marks, mark_offset + 8, 56_u64)
    File.write(marks_path, marks)

    rejected = false
    begin
      reader = CrystalClick::WidePart.open_typed(corrupt_part, "payload")
      reader.read_array_map_string_uint64_mark_range("payload", 2, 1)
    rescue ex : CrystalClick::CorruptPartError
      rejected = true
    end
    raise "reader accepted an out-of-extent nested Map-size mark" unless rejected
    puts "PASS W80 corruption guard: rejects same-size child mark offset beyond stream extent"
    nil
  end
{% end %}

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("CLICKHOUSE_STORE")
root = ENV.fetch("ORACLE_ROOT")
all_indices = (0...W80_KEYS.size).map(&.to_i32)
range_indices = W80_KEYS.each_with_index.compact_map { |key, index| index.to_i32 if key >= 2_u64 && key < 10_u64 }.to_a
expected = w80_rowbinary(W80_KEYS, W80_ROWS, all_indices)
ranged = w80_rowbinary(W80_KEYS, W80_ROWS, range_indices)

w80_create_table(binary, store, "w80_stock")
w80_clickhouse(binary, store, "INSERT INTO default.w80_stock FORMAT RowBinary", IO::Memory.new(expected))
w80_check_table(binary, store, "w80_stock")
w80_query_rows(binary, store, "w80_stock", expected, ranged)
stock_part = w80_stock_part(binary, store, root, "w80_stock")
w80_assert_part_topology(stock_part)

{% if flag?(:w80_reader) %}
  reader = CrystalClick::WidePart.open_typed(stock_part, "payload")
  raise "stock part Crystal read differs" unless reader.read_array_map_string_uint64_mark_range("payload", 0, reader.mark_count) == W80_ROWS
  raise "stock empty-middle mark differs" unless reader.read_array_map_string_uint64_mark_range("payload", 1, 1) == W80_ROWS[2, 2]
  raise "stock later nonempty mark differs" unless reader.read_array_map_string_uint64_mark_range("payload", 2, 1) == W80_ROWS[4, 2]
  raise "stock terminal all-empty mark differs" unless reader.read_array_map_string_uint64_mark_range("payload", 3, 1) == W80_ROWS[6, 1]
  w80_assert_invalid_child_mark_rejected(stock_part, root)
{% end %}

{% if flag?(:w80_writer) %}
  writer_part = File.join(root, "writer-w80")
  CrystalClick::WidePartWriter.write_uint64_array_map_string_uint64_pair(
    writer_part, "pk", W80_KEYS.to_unsafe.to_slice(W80_KEYS.size), "payload", W80_ROWS.to_unsafe.to_slice(W80_ROWS.size), rows_per_mark: 2
  )
  w80_assert_part_topology(writer_part, exact_stock_marks: false)
  writer_reader = CrystalClick::WidePart.open_typed(writer_part, "payload")
  raise "Crystal writer part Crystal read differs" unless writer_reader.read_array_map_string_uint64_mark_range("payload", 0, writer_reader.mark_count) == W80_ROWS
  w80_create_table(binary, store, "w80_writer")
  data_path = w80_clickhouse(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = 'w80_writer' FORMAT TSVRaw").strip
  raise "w80_writer data path missing" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(writer_part, File.join(detached, "all_1_1_0"))
  w80_clickhouse(binary, store, "ALTER TABLE default.w80_writer ATTACH PART 'all_1_1_0'")
  w80_check_table(binary, store, "w80_writer")
  w80_query_rows(binary, store, "w80_writer", expected, ranged)
{% end %}

puts "W80 stock ClickHouse oracle passed: ClickHouse 26.7.1.1315 Array(Map(String, UInt64)), CHECK TABLE, full/key-range RowBinary"
