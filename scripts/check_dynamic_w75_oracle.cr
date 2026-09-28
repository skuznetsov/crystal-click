require "file_utils"
require "./../src/crystal_click"

W75_KEYS                 = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64]
W75_STRING_FIRST_VALUES  = ["alpha", 0_u64, nil, "", "a\0b", nil, UInt64::MAX] of CrystalClick::VariantStringUInt64Value
W75_U64_FIRST_VALUES     = [42_u64, "s", nil, UInt64::MAX, "", nil, "tail"] of CrystalClick::VariantStringUInt64Value
W75_STRING_FIRST_TYPES   = ["String", "UInt64", "None", "String", "String", "None", "UInt64"]
W75_STRING_FIRST_DISPLAY = ["alpha", "0", "", "", "a\0b", "", "18446744073709551615"]
W75_U64_FIRST_TYPES      = ["UInt64", "String", "None", "UInt64", "String", "None", "String"]
W75_U64_FIRST_DISPLAY    = ["42", "s", "", "18446744073709551615", "", "", "tail"]
W75_STREAMS              = [
  "payload.dynamic_structure",
  "payload.variant_discr",
  "payload.SharedVariant.size",
  "payload.SharedVariant",
  "payload.String.size",
  "payload.String",
  "payload.UInt64",
]
W75_MODELS = ["string-first", "u64-first"]

def w75_run_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: Process::Redirect::Inherit)
  raise "ClickHouse query failed (#{status.exit_code}): #{query}" unless status.success?
  output.to_s
end

def w75_data_path(binary : String, store : String, table : String) : String
  path = w75_run_clickhouse(binary, store,
    "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  raise "#{table}: data path missing" if path.empty? || path.includes?('\n')
  path
end

def w75_create_table(binary : String, store : String, table : String) : Nil
  w75_run_clickhouse(binary, store, <<-SQL)
  CREATE TABLE default.#{table}
  (
      `pk` UInt64,
      `payload` Dynamic
  )
  ENGINE = MergeTree
  ORDER BY pk
  SETTINGS
      index_granularity = 3,
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

def w75_attach_check(binary : String, store : String, table : String, part : String) : Nil
  detached = File.join(w75_data_path(binary, store, table), "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  w75_run_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  result = w75_run_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "#{table}: ATTACH/CHECK failed: #{result.inspect}" unless result == "all_1_1_0\t1"

  columns = w75_run_clickhouse(binary, store,
    "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw")
  expected = "pk UInt64\npayload Dynamic\n"
  raise "#{table}: exact type metadata differs: #{columns.inspect}" unless columns == expected
  nil
end

def w75_append_u64_le(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
end

def w75_append_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

def w75_append_string(io : IO, value : String) : Nil
  w75_append_varuint(io, value.bytesize.to_u64)
  io.write(value.to_slice)
end

def w75_rowbinary(keys : Array(UInt64), types : Array(String), values : Array(String)) : String
  raise "W75 RowBinary input lengths differ" unless keys.size == types.size && keys.size == values.size
  io = IO::Memory.new
  keys.each_with_index do |key, index|
    w75_append_u64_le(io, key)
    w75_append_string(io, types[index])
    w75_append_string(io, values[index])
  end
  io.to_s
end

def w75_assert_rowbinary(actual : String, expected : String, label : String) : Nil
  return if actual.to_slice == expected.to_slice
  raise "#{label}: RowBinary mismatch (got #{actual.bytesize}, expected #{expected.bytesize} bytes)"
end

def w75_verify_stock_rows(binary : String, store : String, table : String, types : Array(String), values : Array(String), label : String) : Nil
  null_rendering = w75_run_clickhouse(binary, store,
    "SELECT toTypeName(toString(payload)), hex(toString(payload)) FROM default.#{table} WHERE pk IN (3, 6) ORDER BY pk FORMAT TSVRaw")
  raise "#{label}: Dynamic NULL must render as an empty non-nullable String: #{null_rendering.inspect}" unless null_rendering == "String\t\nString\t\n"

  full = w75_run_clickhouse(binary, store,
    "SELECT pk, dynamicType(payload), toString(payload) FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  w75_assert_rowbinary(full, w75_rowbinary(W75_KEYS, types, values), "#{label} full typed rows")

  selected_indexes = [0, 1, 2, 4, 6]
  keys = selected_indexes.map { |index| W75_KEYS[index] }
  selected_types = selected_indexes.map { |index| types[index] }
  selected_values = selected_indexes.map { |index| values[index] }
  keyed = w75_run_clickhouse(binary, store,
    "SELECT pk, dynamicType(payload), toString(payload) FROM default.#{table} WHERE pk IN (1, 2, 3, 5, 7) ORDER BY pk FORMAT RowBinary")
  w75_assert_rowbinary(keyed, w75_rowbinary(keys, selected_types, selected_values), "#{label} keyed typed rows")
end

def w75_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

def w75_mark_records(part : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64))
  base = CrystalClick::StreamName.hash(stream)
  bytes = File.read(File.join(part, "#{base}.mrk2")).to_slice
  raise "#{stream}: malformed .mrk2 size #{bytes.size}" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  count = (bytes.size / CrystalClick::WidePart::MARK_SIZE).to_i
  Array(Tuple(UInt64, UInt64, UInt64)).new(count) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    {w75_u64(bytes, offset), w75_u64(bytes, offset + 8), w75_u64(bytes, offset + 16)}
  end
end

def w75_expected_hex(model : String, stream : String) : String
  case stream
  when "payload.dynamic_structure"
    "04000000000000000215040100030200"
  when "payload.variant_discr"
    model == "string-first" ? "010000000000000003000102ff03000101ff010102" : "010000000000000003000201ff03000201ff010101"
  when "payload.SharedVariant.size", "payload.SharedVariant"
    ""
  when "payload.String.size"
    model == "string-first" ? "050000000000000000000000000000000300000000000000" : "010000000000000000000000000000000400000000000000"
  when "payload.String"
    model == "string-first" ? "616c706861610062" : "737461696c"
  when "payload.UInt64"
    model == "string-first" ? "0000000000000000ffffffffffffffff" : "2a00000000000000ffffffffffffffff"
  else
    raise "unexpected W75 stream #{stream}"
  end
end

def w75_expected_marks(model : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64))
  offsets = case stream
            when "pk"
              [0_u64, 24_u64, 48_u64, 56_u64]
            when "payload.dynamic_structure"
              [11_u64, 11_u64, 11_u64, 16_u64]
            when "payload.variant_discr"
              [8_u64, 13_u64, 18_u64, 21_u64]
            when "payload.SharedVariant.size", "payload.SharedVariant"
              [0_u64, 0_u64, 0_u64, 0_u64]
            when "payload.String.size"
              model == "string-first" ? [0_u64, 8_u64, 24_u64, 24_u64] : [0_u64, 8_u64, 16_u64, 24_u64]
            when "payload.String"
              model == "string-first" ? [0_u64, 5_u64, 8_u64, 8_u64] : [0_u64, 1_u64, 1_u64, 5_u64]
            when "payload.UInt64"
              model == "string-first" ? [0_u64, 8_u64, 8_u64, 16_u64] : [0_u64, 8_u64, 16_u64, 16_u64]
            else
              raise "unexpected W75 mark stream #{stream}"
            end
  [3_u64, 3_u64, 1_u64, 0_u64].each_with_index.map do |rows, index|
    {0_u64, offsets[index], rows}
  end.to_a
end

def w75_assert_inventory(part : String, model : String, exact_marks : Bool) : Nil
  raise "unknown W75 fixture #{model}" unless W75_MODELS.includes?(model)
  expected_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" +
                        "7 substreams for column `payload`:\n" + W75_STREAMS.map { |stream| "\t#{stream}\n" }.join
  raise "#{model}: exact substream list differs" unless File.read(File.join(part, "columns_substreams.txt")) == expected_substreams
  expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` Dynamic\n"
  raise "#{model}: exact column metadata differs" unless File.read(File.join(part, "columns.txt")) == expected_columns
  expected_serialization = "{\"columns\":[{\"kind\":\"Default\",\"name\":\"pk\",\"num_defaults\":0,\"num_rows\":7}],\"propagate_types_serialization_versions_to_nested_types\":true,\"types_serialization_versions\":{\"string\":1},\"version\":1}"
  raise "#{model}: exact serialization.json differs" unless File.read(File.join(part, "serialization.json")) == expected_serialization

  streams = ["pk"] + W75_STREAMS
  expected_files = streams.flat_map do |stream|
    base = CrystalClick::StreamName.hash(stream)
    ["#{base}.bin", "#{base}.mrk2"]
  end.sort
  actual_files = Dir.children(part).select { |name| name.ends_with?(".bin") || name.ends_with?(".mrk2") }.sort
  raise "#{model}: exact physical stream inventory differs" unless actual_files == expected_files

  checksums = CrystalClick::PartChecksums.open(part)
  expected_files.each do |name|
    verification = checksums.validate_selected_entries(part, name)
    raise "#{model}: checksum entry size validation failed for #{name}" unless verification == CrystalClick::ChecksumVerification::SizeChecked
  end

  streams.each do |stream|
    base = CrystalClick::StreamName.hash(stream)
    encoded = File.read(File.join(part, "#{base}.bin")).to_slice
    raw = encoded.empty? ? [] of UInt8 : CrystalClick::CompressedBlock.decode_all(encoded).to_a
    actual_hex = raw.map { |byte| byte.to_s(16).rjust(2, '0') }.join
    expected_hex = stream == "pk" ? "0100000000000000020000000000000003000000000000000400000000000000050000000000000006000000000000000700000000000000" : w75_expected_hex(model, stream)
    raise "#{model} #{stream}: raw bytes differ (#{actual_hex})" unless actual_hex == expected_hex

    actual_marks = w75_mark_records(part, stream)
    expected_marks = w75_expected_marks(model, stream)
    if exact_marks
      raise "#{model} #{stream}: exact .mrk2 records differ: #{actual_marks}" unless actual_marks == expected_marks
    else
      rows = actual_marks.map(&.[2])
      raise "#{model} #{stream}: per-mark row counts differ: #{rows}" unless rows == [3_u64, 3_u64, 1_u64, 0_u64]
      actual_marks.each_with_index do |current, index|
        next if index == 0
        previous = actual_marks[index - 1]
        raise "#{model} #{stream}: compressed mark offsets regress" if current[0] < previous[0]
        if current[0] == previous[0]
          raise "#{model} #{stream}: uncompressed mark offsets regress" if current[1] < previous[1]
        elsif current[1] != 0_u64
          raise "#{model} #{stream}: new compressed frame has nonzero uncompressed offset"
        end
      end
      terminal = actual_marks.last
      encoded_size = File.size(File.join(part, "#{base}.bin")).to_u64
      terminal_valid = terminal[0] == 0_u64 && terminal[1] == raw.size.to_u64 ||
                       terminal[0] == encoded_size && terminal[1] == 0_u64
      raise "#{model} #{stream}: invalid terminal mark sentinel" unless terminal_valid && terminal[2] == 0_u64
    end
  end
  mode = exact_marks ? "pinned plain .mrk2 records" : "valid row counts/offsets and terminal marks"
  puts "PASS #{model}: exact seven Dynamic substreams and raw bytes, #{mode}, checksum entry sizes"
end

def w75_verify_crystal_reader(part : String, model : String) : Nil
  expected = model == "string-first" ? W75_STRING_FIRST_VALUES : W75_U64_FIRST_VALUES
  reader = CrystalClick::WidePart.open_typed(part, "payload")
  observed = reader.read_dynamic_string_uint64_mark_range("payload", 0, reader.mark_count)
  raise "#{model}: Crystal mark-range read differs: #{observed.inspect}" unless observed == expected

  table = CrystalClick::WidePartTable.open_selected_typed([part], ["payload"])
  scanned = [] of CrystalClick::VariantStringUInt64Value
  table.scan_typed(batch_rows: 2) do |batch|
    scanned.concat(batch.dynamic_string_uint64_for("payload"))
  end
  raise "#{model}: Crystal typed table scan differs: #{scanned.inspect}" unless scanned == expected
  puts "PASS stock-to-Crystal #{model}: mark-range and typed table scan"
end

def w75_verify_stock_part(binary : String, store : String, part : String, table : String, model : String) : Nil
  w75_assert_inventory(part, model, true)
  w75_create_table(binary, store, table)
  w75_attach_check(binary, store, table, part)
  types = model == "string-first" ? W75_STRING_FIRST_TYPES : W75_U64_FIRST_TYPES
  values = model == "string-first" ? W75_STRING_FIRST_DISPLAY : W75_U64_FIRST_DISPLAY
  w75_verify_stock_rows(binary, store, table, types, values, "stock #{model}")
  w75_verify_crystal_reader(part, model)
end

def w75_verify_crystal_writer(binary : String, store : String, root : String, model : String) : Nil
  values = model == "string-first" ? W75_STRING_FIRST_VALUES : W75_U64_FIRST_VALUES
  types = model == "string-first" ? W75_STRING_FIRST_TYPES : W75_U64_FIRST_TYPES
  display = model == "string-first" ? W75_STRING_FIRST_DISPLAY : W75_U64_FIRST_DISPLAY
  keys = W75_KEYS.to_unsafe.to_slice(W75_KEYS.size)
  part = CrystalClick::WidePartWriter.write_uint64_dynamic_string_uint64_pair(
    File.join(root, "writer-dynamic-#{model}"), "pk", keys, "payload",
    values.to_unsafe.to_slice(values.size), rows_per_mark: 3
  )
  w75_assert_inventory(part, model, false)
  table = "dynamic_writer_#{model.gsub('-', '_')}"
  w75_create_table(binary, store, table)
  w75_attach_check(binary, store, table, part)
  w75_verify_stock_rows(binary, store, table, types, display, "Crystal writer #{model}")
  reader_part = File.join(root, "reader-#{model}", "all_1_1_0")
  FileUtils.mkdir_p(File.dirname(reader_part))
  FileUtils.cp_r(part, reader_part)
  w75_verify_crystal_reader(reader_part, model)
  puts "PASS Crystal-to-stock #{model}: ATTACH/CHECK plus full/keyed dynamicType RowBinary"
end

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("CLICKHOUSE_STORE")
root = ENV.fetch("TMP_ROOT")
w75_verify_stock_part(binary, store, ENV.fetch("STOCK_STRING_FIRST_PART"), "dynamic_attached_string_first", "string-first")
w75_verify_stock_part(binary, store, ENV.fetch("STOCK_U64_FIRST_PART"), "dynamic_attached_u64_first", "u64-first")
w75_verify_crystal_writer(binary, store, root, "string-first")
w75_verify_crystal_writer(binary, store, root, "u64-first")
puts "PASS W75 pinned Dynamic(String, UInt64, NULL) bidirectional oracle"
