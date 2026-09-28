require "file_utils"
require "./../src/crystal_click"

W74_KEYS    = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
W74_VALUES  = ["alpha", "", "beta", "a\0b", "tail"]
W74_TYPE    = "Dynamic"
W74_STREAMS = [
  "payload.dynamic_structure",
  "payload.variant_discr",
  "payload.SharedVariant.size",
  "payload.SharedVariant",
  "payload.String.size",
  "payload.String",
]

def w74_run_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (status #{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

def w74_create_table(binary : String, store : String, table : String) : Nil
  w74_run_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.#{table}
  (
      `pk` UInt64,
      `payload` Dynamic
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
      default_compression_codec = 'LZ4';
  SQL
  nil
end

def w74_data_path(binary : String, store : String, table : String) : String
  path = w74_run_clickhouse(binary, store,
    "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  raise "#{table}: data path missing" if path.empty? || path.includes?('\n')
  path
end

def w74_attach_part(binary : String, store : String, table : String, part : String) : Nil
  detached = File.join(w74_data_path(binary, store, table), "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  w74_run_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  result = w74_run_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "#{table}: ATTACH/CHECK TABLE failed: #{result.inspect}" unless result == "all_1_1_0\t1"

  columns = w74_run_clickhouse(binary, store,
    "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw")
  expected_columns = "pk UInt64\npayload #{W74_TYPE}\n"
  raise "#{table}: exact type metadata differs: #{columns.inspect}" unless columns == expected_columns
  nil
end

def w74_append_u64_le(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
end

def w74_append_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

def w74_rowbinary_string_cast(keys : Array(UInt64), values : Array(String)) : String
  raise "W74 RowBinary input lengths differ" unless keys.size == values.size
  io = IO::Memory.new
  keys.each_with_index do |key, index|
    w74_append_u64_le(io, key)
    value = values[index]
    w74_append_varuint(io, value.bytesize.to_u64)
    io.write(value.to_slice)
  end
  io.to_s
end

def w74_assert_bytes(actual : String, expected : String, label : String) : Nil
  return if actual.to_slice == expected.to_slice
  raise "#{label} RowBinary mismatch: got #{actual.bytesize} bytes, expected #{expected.bytesize}"
end

def w74_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

def w74_mark_records(part : String, stream : String, expected_records : Int32) : Array(Tuple(UInt64, UInt64, UInt64))
  base = CrystalClick::StreamName.hash(stream)
  bytes = File.read(File.join(part, "#{base}.mrk2")).to_slice
  unless bytes.size == CrystalClick::WidePart::MARK_SIZE * expected_records
    raise "#{part} #{stream}: expected #{expected_records - 1} plain .mrk2 data marks plus one terminal mark"
  end
  Array(Tuple(UInt64, UInt64, UInt64)).new(expected_records) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    {w74_read_u64(bytes, offset), w74_read_u64(bytes, offset + 8), w74_read_u64(bytes, offset + 16)}
  end
end

def w74_assert_part_inventory(part : String, expected_rows : Array(UInt64)) : Nil
  expected_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" +
                        "6 substreams for column `payload`:\n" + W74_STREAMS.map { |stream| "\t#{stream}\n" }.join
  actual_substreams = File.read(File.join(part, "columns_substreams.txt"))
  raise "#{part}: exact Dynamic substream inventory differs" unless actual_substreams == expected_substreams

  streams = ["pk"] + W74_STREAMS
  expected_files = streams.flat_map do |stream|
    base = CrystalClick::StreamName.hash(stream)
    ["#{base}.bin", "#{base}.mrk2"]
  end.sort
  actual_files = Dir.children(part)
    .select { |name| name.ends_with?(".bin") || name.ends_with?(".mrk2") }
    .sort
  raise "#{part}: physical stream/mark inventory differs" unless actual_files == expected_files
  unexpected_mark_formats = Dir.children(part).select do |name|
    name.ends_with?(".mrk") || name.ends_with?(".mrk3")
  end
  raise "#{part}: expected plain .mrk2 files only" unless unexpected_mark_formats.empty?

  expected_mark_rows = expected_rows + [0_u64]
  streams.each do |stream|
    base = CrystalClick::StreamName.hash(stream)
    records = w74_mark_records(part, stream, expected_mark_rows.size.to_i32)
    rows = records.map(&.[2])
    raise "#{part} #{stream}: plain mark rows differ: #{rows}" unless rows == expected_mark_rows
    encoded = File.read(File.join(part, "#{base}.bin")).to_slice
    raw = encoded.empty? ? [] of UInt8 : CrystalClick::CompressedBlock.decode_all(encoded).to_a
    (0...records.size - 1).each do |index|
      previous = records[index]
      current = records[index + 1]
      raise "#{part} #{stream}: compressed mark offsets regress" if current[0] < previous[0]
      if current[0] == previous[0]
        raise "#{part} #{stream}: uncompressed mark offsets regress" if current[1] < previous[1]
      elsif current[1] != 0_u64
        raise "#{part} #{stream}: mark does not start at a compressed frame boundary"
      end
    end
    terminal = records.last
    valid_terminal = terminal[0] == 0_u64 && terminal[1] == raw.size.to_u64 ||
                     terminal[0] == encoded.size.to_u64 && terminal[1] == 0_u64
    unless valid_terminal && terminal[2] == 0_u64
      raise "#{part} #{stream}: plain mark terminal sentinel differs"
    end
    if stream == "payload.dynamic_structure"
      expected_structure_marks = expected_rows.map { |mark_rows| {0_u64, 10_u64, mark_rows} }
      expected_structure_marks << {0_u64, raw.size.to_u64, 0_u64}
      raise "#{part}: Dynamic structure prefix/terminal mark inventory differs" unless records == expected_structure_marks
    end
  end
  puts "PASS exact six Dynamic substreams and plain .mrk2 rows #{expected_mark_rows}"
  nil
end

def w74_verify_stock_rows(binary : String, store : String, table : String, values : Array(String), label : String) : Nil
  keys = Array(UInt64).new(values.size) { |index| (index + 1).to_u64 }
  types = w74_run_clickhouse(binary, store,
    "SELECT arrayStringConcat(arrayDistinct(groupArray(dynamicType(payload))), ',') FROM default.#{table} FORMAT TSVRaw").strip
  raise "#{label}: expected a String-only Dynamic dictionary, got #{types.inspect}" unless types == "String"

  full = w74_run_clickhouse(binary, store,
    "SELECT pk, CAST(payload, 'String') FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  w74_assert_bytes(full, w74_rowbinary_string_cast(keys, values), "#{label} full")

  range_count = {3, values.size - 1}.min
  range_keys = keys[1, range_count]
  range_values = values[1, range_count]
  range_end = 2 + range_count
  ranged = w74_run_clickhouse(binary, store,
    "SELECT pk, CAST(payload, 'String') FROM default.#{table} WHERE pk >= 2 AND pk < #{range_end} ORDER BY pk FORMAT RowBinary")
  w74_assert_bytes(ranged, w74_rowbinary_string_cast(range_keys, range_values), "#{label} primary-key range")
  nil
end

def w74_verify_crystal_reader(stock_part : String, expected_values : Array(String)) : Nil
  table = CrystalClick::WidePartTable.open_selected_typed([stock_part], ["payload"])
  observed = [] of String
  table.scan_typed(batch_rows: 2) do |batch|
    observed.concat(batch.dynamic_strings_for("payload"))
  end
  raise "Crystal reader mismatch: #{observed.inspect}" unless observed == expected_values
  puts "PASS stock-to-Crystal: Dynamic(String-only) typed scan across #{expected_values.size} rows"
end

def w74_verify_crystal_writer(binary : String, store : String, root : String) : Nil
  keys = W74_KEYS.to_unsafe.to_slice(W74_KEYS.size)
  values = W74_VALUES.to_unsafe.to_slice(W74_VALUES.size)
  part = CrystalClick::WidePartWriter.write_uint64_dynamic_string_pair(
    File.join(root, "writer-dynamic-string"), "pk", keys, "payload", values,
    rows_per_mark: 2
  )
  w74_assert_part_inventory(part, [2_u64, 2_u64, 1_u64])

  table = "dynamic_writer_readback"
  w74_create_table(binary, store, table)
  w74_attach_part(binary, store, table, part)
  w74_verify_stock_rows(binary, store, table, W74_VALUES, "Crystal writer")
  puts "PASS Crystal-to-stock: Dynamic(String-only) ATTACH/CHECK and full/range RowBinary"
end

def w74_verify_empty_profile(binary : String, store : String, root : String, stock_part : String) : Nil
  values = Array(String).new(130, "")
  expected_rows = Array(UInt64).new(65, 2_u64)
  w74_assert_part_inventory(stock_part, expected_rows)

  structure_file = File.join(stock_part, "#{CrystalClick::StreamName.hash("payload.dynamic_structure")}.bin")
  structure_raw = CrystalClick::CompressedBlock.decode_all(File.read(structure_file).to_slice).to_a
  expected_structure = [0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
                        0x01_u8, 0x15_u8, 0x01_u8, 0x00_u8, 0x82_u8, 0x01_u8, 0x00_u8]
  unless structure_raw == expected_structure
    raise "130-row stock Dynamic V3 structure differs: #{structure_raw.map(&.to_s(16)).join(" ")}"
  end

  stock_reader_table = "dynamic_empty_stock_readback"
  w74_create_table(binary, store, stock_reader_table)
  w74_attach_part(binary, store, stock_reader_table, stock_part)
  w74_verify_stock_rows(binary, store, stock_reader_table, values, "all-empty stock producer")
  w74_verify_crystal_reader(stock_part, values)

  keys = Array(UInt64).new(130) { |index| (index + 1).to_u64 }
  part = CrystalClick::WidePartWriter.write_uint64_dynamic_string_pair(
    File.join(root, "writer-dynamic-string-empty"),
    "pk",
    keys.to_unsafe.to_slice(keys.size),
    "payload",
    values.to_unsafe.to_slice(values.size),
    rows_per_mark: 2
  )
  w74_assert_part_inventory(part, expected_rows)
  empty_payload = File.read(File.join(part, "#{CrystalClick::StreamName.hash("payload.String")}.bin"))
  raise "all-empty Dynamic payload stream should be zero bytes" unless empty_payload.empty?

  stock_writer_table = "dynamic_empty_writer_readback"
  w74_create_table(binary, store, stock_writer_table)
  w74_attach_part(binary, store, stock_writer_table, part)
  w74_verify_stock_rows(binary, store, stock_writer_table, values, "all-empty Crystal writer")
  puts "PASS all-empty Dynamic String child through stock ATTACH and Crystal typed scan"
end

binary = ENV.fetch("CLICKHOUSE_BIN")
root = ENV.fetch("TMP_ROOT")
store = File.join(root, "clickhouse-store")
stock_part = ENV.fetch("STOCK_PART_PATH")

stock_table = "dynamic_stock_readback"
w74_create_table(binary, store, stock_table)
w74_assert_part_inventory(stock_part, [2_u64, 2_u64, 1_u64])
w74_attach_part(binary, store, stock_table, stock_part)
w74_verify_stock_rows(binary, store, stock_table, W74_VALUES, "stock producer")
w74_verify_crystal_reader(stock_part, W74_VALUES)
w74_verify_crystal_writer(binary, store, root)
w74_verify_empty_profile(binary, store, root, ENV.fetch("EMPTY_STOCK_PART_PATH"))
puts "PASS W74 pinned Dynamic(String-only) bidirectional oracle"
