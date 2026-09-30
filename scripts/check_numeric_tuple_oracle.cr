require "../src/crystal_click"
require "json"
require "file_utils"

struct W96OracleField
  getter name : String
  getter type_name : String
  getter column : CrystalClick::WideTupleLeafColumn
  getter rowbinary_values : Array(Bytes)

  def initialize(@name : String, @type_name : String, @column : CrystalClick::WideTupleLeafColumn, @rowbinary_values : Array(Bytes))
  end
end

struct W96OracleProfile
  getter label : String
  getter fields : Array(W96OracleField)
  getter always_default : Bool

  def initialize(@label : String, @fields : Array(W96OracleField), @always_default = false)
  end

  def type_name : String
    "Tuple(#{fields.map { |field| "#{field.name} #{field.type_name}" }.join(", ")})"
  end
end

class W96OracleMismatch < Exception
end

W96_KEYS                    = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
W96_EXPECTED_MARK_ROWS      = [2_u64, 2_u64, 1_u64]
W96_EXPECTED_MARK_FILE_ROWS = W96_EXPECTED_MARK_ROWS + [0_u64]

def w96_append_u16_le(io : IO, value : UInt16) : Nil
  2.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u16).to_u8) }
end

def w96_append_u32_le(io : IO, value : UInt32) : Nil
  4.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u32).to_u8) }
end

def w96_append_u64_le(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
end

def w96_append_u128_le(io : IO, value : UInt128) : Nil
  16.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u128).to_u8) }
end

def w96_append_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

def w96_encoded_value(value : Int8) : Bytes
  Bytes[value.unsafe_as(UInt8)]
end

def w96_encoded_value(value : UInt8) : Bytes
  Bytes[value]
end

def w96_encoded_value(value : Int16) : Bytes
  io = IO::Memory.new
  w96_append_u16_le(io, value.unsafe_as(UInt16))
  io.to_slice.dup
end

def w96_encoded_value(value : UInt16) : Bytes
  io = IO::Memory.new
  w96_append_u16_le(io, value)
  io.to_slice.dup
end

def w96_encoded_value(value : Int32) : Bytes
  io = IO::Memory.new
  w96_append_u32_le(io, value.unsafe_as(UInt32))
  io.to_slice.dup
end

def w96_encoded_value(value : UInt32) : Bytes
  io = IO::Memory.new
  w96_append_u32_le(io, value)
  io.to_slice.dup
end

def w96_encoded_value(value : Int64) : Bytes
  io = IO::Memory.new
  w96_append_u64_le(io, value.unsafe_as(UInt64))
  io.to_slice.dup
end

def w96_encoded_value(value : UInt64) : Bytes
  io = IO::Memory.new
  w96_append_u64_le(io, value)
  io.to_slice.dup
end

def w96_encoded_value(value : Int128) : Bytes
  io = IO::Memory.new
  w96_append_u128_le(io, value.unsafe_as(UInt128))
  io.to_slice.dup
end

def w96_encoded_value(value : UInt128) : Bytes
  io = IO::Memory.new
  w96_append_u128_le(io, value)
  io.to_slice.dup
end

def w96_encoded_value(value : CrystalClick::Int256Value) : Bytes
  io = IO::Memory.new
  w96_append_u128_le(io, value.low)
  w96_append_u128_le(io, value.high)
  io.to_slice.dup
end

def w96_encoded_value(value : CrystalClick::UInt256Value) : Bytes
  io = IO::Memory.new
  w96_append_u128_le(io, value.low)
  w96_append_u128_le(io, value.high)
  io.to_slice.dup
end

def w96_encoded_value(value : Float32) : Bytes
  io = IO::Memory.new
  w96_append_u32_le(io, value.unsafe_as(UInt32))
  io.to_slice.dup
end

def w96_encoded_value(value : Float64) : Bytes
  io = IO::Memory.new
  w96_append_u64_le(io, value.unsafe_as(UInt64))
  io.to_slice.dup
end

def w96_encoded_value(value : CrystalClick::BFloat16Value) : Bytes
  io = IO::Memory.new
  w96_append_u16_le(io, value.bits)
  io.to_slice.dup
end

def w96_encoded_value(value : String) : Bytes
  io = IO::Memory.new
  w96_append_varuint(io, value.bytesize.to_u64)
  io.write(value.to_slice)
  io.to_slice.dup
end

def w96_field(name : String, type_name : String, values : Array(T)) : W96OracleField forall T
  column = CrystalClick::WideTupleLeafColumn.new(name, values)
  unless column.type_name == type_name
    raise "#{name}: constructor retained #{column.type_name}, fixture expected #{type_name}"
  end
  W96OracleField.new(name, type_name, column, values.map { |value| w96_encoded_value(value) })
end

def w96_numeric_fields : Array(W96OracleField)
  [
    w96_field("i8", "Int8", [Int8::MIN, -1_i8, 0_i8, 1_i8, Int8::MAX]),
    w96_field("i16", "Int16", [Int16::MIN, -1_i16, 0_i16, 1_i16, Int16::MAX]),
    w96_field("i32", "Int32", [Int32::MIN, -1_i32, 0_i32, 1_i32, Int32::MAX]),
    w96_field("i64", "Int64", [Int64::MIN, -1_i64, 0_i64, 1_i64, Int64::MAX]),
    w96_field("i128", "Int128", [Int128::MIN, -1_i128, 0_i128, 1_i128, Int128::MAX]),
    w96_field("i256", "Int256", [
      CrystalClick::Int256Value.new(0_u128, 0x8000_0000_0000_0000_0000_0000_0000_0000_u128),
      CrystalClick::Int256Value.new(UInt128::MAX, UInt128::MAX),
      CrystalClick::Int256Value.new(0_u128, 0_u128),
      CrystalClick::Int256Value.new(1_u128, 0_u128),
      CrystalClick::Int256Value.new(UInt128::MAX, 0x7fff_ffff_ffff_ffff_ffff_ffff_ffff_ffff_u128),
    ] of CrystalClick::Int256Value),
    w96_field("u8", "UInt8", [0_u8, 1_u8, 0x80_u8, 0xfe_u8, UInt8::MAX]),
    w96_field("u16", "UInt16", [0_u16, 1_u16, 0x8000_u16, 0xfffe_u16, UInt16::MAX]),
    w96_field("u32", "UInt32", [0_u32, 1_u32, 0x8000_0000_u32, 0xffff_fffe_u32, UInt32::MAX]),
    w96_field("u64", "UInt64", [0_u64, 1_u64, 0x8000_0000_0000_0000_u64, UInt64::MAX - 1_u64, UInt64::MAX]),
    w96_field("u128", "UInt128", [0_u128, 1_u128, 0x8000_0000_0000_0000_0000_0000_0000_0000_u128, UInt128::MAX - 1_u128, UInt128::MAX]),
    w96_field("u256", "UInt256", [
      CrystalClick::UInt256Value.new(0_u128, 0_u128),
      CrystalClick::UInt256Value.new(1_u128, 0_u128),
      CrystalClick::UInt256Value.new(0_u128, 0x8000_0000_0000_0000_0000_0000_0000_0000_u128),
      CrystalClick::UInt256Value.new(UInt128::MAX, UInt128::MAX - 1_u128),
      CrystalClick::UInt256Value.new(UInt128::MAX, UInt128::MAX),
    ] of CrystalClick::UInt256Value),
    w96_field("f32", "Float32", [
      0x0000_0000_u32.unsafe_as(Float32),
      0x8000_0000_u32.unsafe_as(Float32),
      0x3fa0_0000_u32.unsafe_as(Float32),
      0x7f80_0000_u32.unsafe_as(Float32),
      0x7fc1_2345_u32.unsafe_as(Float32),
    ] of Float32),
    w96_field("f64", "Float64", [
      0x0000_0000_0000_0000_u64.unsafe_as(Float64),
      0x8000_0000_0000_0000_u64.unsafe_as(Float64),
      0x3ff4_0000_0000_0000_u64.unsafe_as(Float64),
      0x7ff0_0000_0000_0000_u64.unsafe_as(Float64),
      0x7ff8_0000_0001_2345_u64.unsafe_as(Float64),
    ] of Float64),
    w96_field("bf", "BFloat16", [
      CrystalClick::BFloat16Value.new(0x0000_u16),
      CrystalClick::BFloat16Value.new(0x8000_u16),
      CrystalClick::BFloat16Value.new(0x3fa0_u16),
      CrystalClick::BFloat16Value.new(0x7f80_u16),
      CrystalClick::BFloat16Value.new(0x7fc1_u16),
    ] of CrystalClick::BFloat16Value),
  ] of W96OracleField
end

def w96_string_field : W96OracleField
  w96_field("text", "String", [
    "",
    String.new(Bytes[0x61_u8, 0x00_u8, 0xff_u8]),
    "é",
    String.new(Bytes[0xff_u8, 0x00_u8]),
    "tail",
  ] of String)
end

def w96_zero_numeric_fields : Array(W96OracleField)
  [
    w96_field("i8", "Int8", Array.new(5, 0_i8)),
    w96_field("i16", "Int16", Array.new(5, 0_i16)),
    w96_field("i32", "Int32", Array.new(5, 0_i32)),
    w96_field("i64", "Int64", Array.new(5, 0_i64)),
    w96_field("i128", "Int128", Array.new(5, 0_i128)),
    w96_field("i256", "Int256", Array.new(5, CrystalClick::Int256Value.new(0_u128, 0_u128))),
    w96_field("u8", "UInt8", Array.new(5, 0_u8)),
    w96_field("u16", "UInt16", Array.new(5, 0_u16)),
    w96_field("u32", "UInt32", Array.new(5, 0_u32)),
    w96_field("u64", "UInt64", Array.new(5, 0_u64)),
    w96_field("u128", "UInt128", Array.new(5, 0_u128)),
    w96_field("u256", "UInt256", Array.new(5, CrystalClick::UInt256Value.new(0_u128, 0_u128))),
    w96_field("f32", "Float32", Array.new(5, 0x0000_0000_u32.unsafe_as(Float32))),
    w96_field("f64", "Float64", Array.new(5, 0x0000_0000_0000_0000_u64.unsafe_as(Float64))),
    w96_field("bf", "BFloat16", Array.new(5, CrystalClick::BFloat16Value.new(0_u16))),
  ] of W96OracleField
end

def w96_profiles : Array(W96OracleProfile)
  numeric = w96_numeric_fields
  mixed = numeric.dup
  mixed << w96_string_field
  zero = w96_zero_numeric_fields
  zero << w96_field("text", "String", Array.new(5, ""))
  [
    W96OracleProfile.new("mixed_all_15", mixed),
    W96OracleProfile.new("numeric_only_15", numeric),
    W96OracleProfile.new("always_default_all_15", zero, true),
  ] of W96OracleProfile
end

def w96_expected_rowbinary(profile : W96OracleProfile, indexes : Array(Int32), include_keys : Bool = true) : Bytes
  output = IO::Memory.new
  indexes.each do |row_index|
    w96_append_u64_le(output, W96_KEYS[row_index]) if include_keys
    profile.fields.each do |field|
      output.write(field.rowbinary_values[row_index])
    end
  end
  output.to_slice.dup
end

def w96_actual_value_bytes(type_name : String, value : CrystalClick::WideTupleLeafColumn::Value) : Bytes
  case type_name
  when "Int8"     then w96_encoded_value(value.as(Int8))
  when "UInt8"    then w96_encoded_value(value.as(UInt8))
  when "Int16"    then w96_encoded_value(value.as(Int16))
  when "UInt16"   then w96_encoded_value(value.as(UInt16))
  when "Int32"    then w96_encoded_value(value.as(Int32))
  when "UInt32"   then w96_encoded_value(value.as(UInt32))
  when "Int64"    then w96_encoded_value(value.as(Int64))
  when "UInt64"   then w96_encoded_value(value.as(UInt64))
  when "Int128"   then w96_encoded_value(value.as(Int128))
  when "UInt128"  then w96_encoded_value(value.as(UInt128))
  when "Int256"   then w96_encoded_value(value.as(CrystalClick::Int256Value))
  when "UInt256"  then w96_encoded_value(value.as(CrystalClick::UInt256Value))
  when "Float32"  then w96_encoded_value(value.as(Float32))
  when "Float64"  then w96_encoded_value(value.as(Float64))
  when "BFloat16" then w96_encoded_value(value.as(CrystalClick::BFloat16Value))
  when "String"   then w96_encoded_value(value.as(String))
  else                 raise "no independent RowBinary expectation for #{type_name}"
  end
end

def w96_actual_data_rowbinary(profile : W96OracleProfile, keys : Array(UInt64), data : CrystalClick::WideTupleColumnData, indexes : Array(Int32)) : Bytes
  output = IO::Memory.new
  indexes.each do |row_index|
    w96_append_u64_le(output, keys[row_index])
    profile.fields.each do |field|
      output.write(w96_actual_value_bytes(field.type_name, data.value_at(field.name, row_index)))
    end
  end
  output.to_slice.dup
end

def w96_actual_batch_rowbinary(profile : W96OracleProfile, batch : CrystalClick::WidePartTableBatch) : Bytes
  keys = batch.values_for("pk")
  rows = batch.tuple_rows_for("payload")
  raise "batch key/Tuple lengths differ" unless keys.size == rows.size
  output = IO::Memory.new
  keys.each_with_index do |key, index|
    w96_append_u64_le(output, key)
    row = rows[index]
    raise "batch Tuple schema changed" unless row.type_name == profile.type_name
    profile.fields.each do |field|
      output.write(w96_actual_value_bytes(field.type_name, row[field.name]))
    end
  end
  output.to_slice.dup
end

def w96_actual_catalog_payload(profile : W96OracleProfile, values : Array(CrystalClick::OfflineColumnValue)) : Bytes
  output = IO::Memory.new
  values.each do |value|
    row = value.as(CrystalClick::WideTupleRow)
    raise "catalog Tuple schema changed" unless row.type_name == profile.type_name
    profile.fields.each do |field|
      output.write(w96_actual_value_bytes(field.type_name, row[field.name]))
    end
  end
  output.to_slice.dup
end

def w96_assert_bytes(actual : Bytes, expected : Bytes, label : String) : Nil
  return if actual == expected
  first_difference = 0
  limit = {actual.size, expected.size}.min
  while first_difference < limit && actual[first_difference] == expected[first_difference]
    first_difference += 1
  end
  raise W96OracleMismatch.new("#{label}: bytes differ at #{first_difference} (actual=#{actual.size}, expected=#{expected.size})")
end

def w96_qualify_mismatch_comparator(expected : Bytes) : Nil
  raise "cannot qualify a byte comparator with empty expected data" if expected.empty?
  seeded_wrong = expected.dup
  seeded_wrong[seeded_wrong.size // 2] ^= 1_u8
  rejected = false
  begin
    w96_assert_bytes(seeded_wrong, expected, "seeded wrong-byte guard")
  rescue W96OracleMismatch
    rejected = true
  end
  raise "independent byte comparator accepted a seeded wrong byte" unless rejected
  puts "PASS seeded wrong-byte comparator rejects a deliberately changed byte"
end

def w96_run_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: error)
  unless status.success?
    raise "ClickHouse query failed (#{status.exit_code}): #{error.to_s}\n#{query}"
  end
  output.to_s
end

def w96_run_clickhouse_input(binary : String, store : String, query : String, bytes : Bytes) : String
  input = IO::Memory.new
  input.write(bytes)
  input.rewind
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], input: input, output: output, error: error)
  unless status.success?
    raise "ClickHouse RowBinary INSERT failed (#{status.exit_code}): #{error.to_s}\n#{query}"
  end
  output.to_s
end

def w96_table_sql(table : String, profile : W96OracleProfile) : String
  ratio = profile.always_default ? "1.0" : "0.9375"
  <<-SQL
  CREATE TABLE default.#{table}
  (
      pk UInt64,
      payload #{profile.type_name}
  )
  ENGINE = MergeTree
  ORDER BY pk
  SETTINGS
      index_granularity = 2,
      enable_mixed_granularity_parts = 1,
      min_rows_for_wide_part = 0,
      min_bytes_for_wide_part = 0,
      compress_marks = 0,
      compress_primary_key = 0,
      min_compress_block_size = 0,
      max_compress_block_size = 4096,
      ratio_of_defaults_for_sparse_serialization = #{ratio}
  SQL
end

def w96_active_part_path(binary : String, store : String, table : String) : String
  paths = w96_run_clickhouse(
    binary,
    store,
    "SELECT path FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TSVRaw"
  ).lines.map(&.strip).reject(&.empty?)
  raise "#{table}: expected one active part, got #{paths.inspect}" unless paths.size == 1
  paths[0]
end

def w96_insert_bytes(profile : W96OracleProfile) : Bytes
  w96_expected_rowbinary(profile, (0...W96_KEYS.size).map(&.to_i32))
end

def w96_create_stock_part(binary : String, store : String, table : String, profile : W96OracleProfile) : String
  w96_run_clickhouse(binary, store, w96_table_sql(table, profile))
  w96_run_clickhouse_input(binary, store, "INSERT INTO default.#{table} FORMAT RowBinary", w96_insert_bytes(profile))
  w96_active_part_path(binary, store, table)
end

def w96_expected_streams(profile : W96OracleProfile) : Array(String)
  streams = ["pk"] of String
  profile.fields.each do |field|
    name = "payload%2E#{field.name}"
    streams << "#{name}.size" if field.type_name == "String"
    streams << name
  end
  streams
end

def w96_mark_rows(mark_bytes : Bytes, label : String) : Array(UInt64)
  mark_size = CrystalClick::WidePart::MARK_SIZE
  raise "#{label}: partial .mrk2 record" unless mark_bytes.size % mark_size == 0
  Array.new(mark_bytes.size // mark_size) do |index|
    offset = index * mark_size + 16
    8.times.reduce(0_u64) do |value, byte|
      value | (mark_bytes[offset + byte].to_u64 << (byte * 8))
    end
  end
end

def w96_assert_stock_physical_profile(path : String, profile : W96OracleProfile, label : String) : Nil
  streams = w96_expected_streams(profile)
  lines = ["columns substreams version: 1", "2 columns:", "1 substreams for column `pk`:", "\tpk"] of String
  payload_streams = streams[1..]
  lines << "#{payload_streams.size} substreams for column `payload`:"
  payload_streams.each { |name| lines << "\t#{name}" }
  expected_metadata = lines.join("\n") + "\n"
  actual_metadata = File.read(File.join(path, "columns_substreams.txt"))
  raise "#{label}: columns_substreams.txt differs" unless actual_metadata == expected_metadata

  bases = streams.map { |name| CrystalClick::StreamName.hash(name) }
  expected_bins = bases.map { |base| "#{base}.bin" }.sort
  expected_marks = bases.map { |base| "#{base}.mrk2" }.sort
  children = Dir.children(path)
  actual_bins = children.select(&.ends_with?(".bin")).sort
  actual_marks = children.select(&.ends_with?(".mrk2")).sort
  raise "#{label}: .bin inventory differs" unless actual_bins == expected_bins
  raise "#{label}: .mrk2 inventory differs" unless actual_marks == expected_marks

  streams.each do |name|
    base = CrystalClick::StreamName.hash(name)
    rows = w96_mark_rows(File.read(File.join(path, "#{base}.mrk2")).to_slice, "#{label} #{name}")
    raise "#{label} #{name}: mark rows differ: #{rows.inspect}" unless rows == W96_EXPECTED_MARK_FILE_ROWS
  end

  columns = File.read(File.join(path, "columns.txt")).lines.map(&.strip)
  expected_columns = ["columns format version: 1", "2 columns:", "`pk` UInt64", "`payload` #{profile.type_name}"]
  raise "#{label}: columns.txt differs: #{columns.inspect}" unless columns == expected_columns
end

def w96_serialization_info(path : String, label : String) : JSON::Any
  info = JSON.parse(File.read(File.join(path, "serialization.json")))
  metadata = info.as_h
  version = metadata["version"]?.try(&.as_i) || raise "#{label}: serialization version missing"
  raise "#{label}: serialization version differs: #{version}" unless version == 1
  propagated = metadata["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool)
  raise "#{label}: nested-version propagation is not true" unless propagated == true
  versions = metadata["types_serialization_versions"]?.try(&.as_h) || raise "#{label}: type-version map missing"
  unless versions.size == 1 && versions["string"]?.try(&.as_i) == 1
    raise "#{label}: expected exact {{string: 1}} type-version map, got #{versions.inspect}"
  end
  info
end

def w96_assert_stock_serialization(path : String, profile : W96OracleProfile, label : String) : Nil
  info = w96_serialization_info(path, label)
  serializers = info.as_h["columns"]?.try(&.as_a) || raise "#{label}: serialization columns missing"
  expected_names = profile.always_default ? [] of String : ["payload", "pk"]
  names = serializers.map { |entry| entry.as_h["name"].as_s }
  raise "#{label}: serializer names differ (#{names.inspect})" unless names == expected_names
  serializers.each do |serializer|
    entry = serializer.as_h
    raise "#{label}: non-Default serializer" unless entry["kind"]?.try(&.as_s) == "Default"
    rows = entry["num_rows"]?.try(&.as_i) || raise "#{label}: serializer row count missing"
    defaults = entry["num_defaults"]?.try(&.as_i) || raise "#{label}: serializer default count missing"
    raise "#{label}: serializer rows/defaults out of bounds" unless rows == W96_KEYS.size && defaults >= 0 && defaults <= rows
    next unless entry["name"]?.try(&.as_s) == "payload"
    children = entry["subcolumns"]?.try(&.as_a) || raise "#{label}: Tuple children missing"
    raise "#{label}: Tuple child serializer count differs" unless children.size == profile.fields.size
    children.each do |child|
      child_entry = child.as_h
      raise "#{label}: Tuple child is not Default" unless child_entry["kind"]?.try(&.as_s) == "Default"
      child_rows = child_entry["num_rows"]?.try(&.as_i) || raise "#{label}: child row count missing"
      child_defaults = child_entry["num_defaults"]?.try(&.as_i) || raise "#{label}: child default count missing"
      raise "#{label}: child rows/defaults out of bounds" unless child_rows == W96_KEYS.size && child_defaults >= 0 && child_defaults <= child_rows
    end
  end
  puts "OBSERVED #{label} serialization Default records=#{names.inspect}; exact default counts intentionally not asserted"
end

def w96_assert_check(binary : String, store : String, table : String, path : String) : Nil
  output = w96_run_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  expected = "#{File.basename(path.chomp("/"))}\t1"
  raise "#{table}: CHECK TABLE differs: #{output.inspect}" unless output == expected
end

def w96_select_query(table : String, profile : W96OracleProfile, indexes : Array(Int32)) : String
  selected = ["pk"] + profile.fields.map { |field| "payload.#{field.name}" }
  keys = indexes.map { |index| W96_KEYS[index].to_s }.join(", ")
  where = indexes.size == W96_KEYS.size ? "" : " WHERE pk IN (#{keys})"
  "SELECT #{selected.join(", ")} FROM default.#{table}#{where} ORDER BY pk FORMAT RowBinary"
end

def w96_stock_read_indexes(binary : String, store : String, table : String, profile : W96OracleProfile, indexes : Array(Int32), label : String) : Nil
  actual = w96_run_clickhouse(binary, store, w96_select_query(table, profile, indexes)).to_slice
  expected = w96_expected_rowbinary(profile, indexes)
  w96_assert_bytes(actual, expected, label)
end

def w96_attach_writer_part(binary : String, store : String, table : String, part : String, profile : W96OracleProfile) : String
  w96_run_clickhouse(binary, store, w96_table_sql(table, profile))
  data_path = w96_run_clickhouse(
    binary,
    store,
    "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{table}' FORMAT TSVRaw"
  ).strip
  raise "#{table}: ClickHouse returned no data path" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  w96_run_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  File.join(data_path, "all_1_1_0")
end

def w96_check_high_level(store : String, path : String, table_name : String, profile : W96OracleProfile, label : String) : Nil
  reader = CrystalClick::WidePartTable.open_selected_typed([path], ["pk", "payload"])
  full_indexes = [0, 1, 2, 3, 4] of Int32
  full = IO::Memory.new
  reader.scan_typed { |batch| full.write(w96_actual_batch_rowbinary(profile, batch)) }
  w96_assert_bytes(full.to_slice, w96_expected_rowbinary(profile, full_indexes), "#{label} full typed scan")

  window_indexes = [1, 2, 3] of Int32
  window = IO::Memory.new
  reader.scan_typed_window(1_u64, 3) { |batch| window.write(w96_actual_batch_rowbinary(profile, batch)) }
  w96_assert_bytes(window.to_slice, w96_expected_rowbinary(profile, window_indexes), "#{label} typed window")

  sparse_indexes = [2, 3, 4] of Int32
  sparse = IO::Memory.new
  reader.scan_typed_candidate_marks([[1_i32, 2_i32]]) { |batch| sparse.write(w96_actual_batch_rowbinary(profile, batch)) }
  w96_assert_bytes(sparse.to_slice, w96_expected_rowbinary(profile, sparse_indexes), "#{label} sparse candidate scan")

  catalog_table = CrystalClick::OfflineCatalog.open(store).table("default", table_name)
  candidates = catalog_table.resolved_scan_parts
  unless candidates.size == 1 && File.realpath(candidates[0].path) == File.realpath(path)
    raise "#{label}: catalog did not resolve expected part"
  end
  values = catalog_table["payload"].values
  w96_assert_bytes(
    w96_actual_catalog_payload(profile, values),
    w96_expected_rowbinary(profile, [0, 1, 2, 3, 4] of Int32, include_keys: false),
    "#{label} catalog values"
  )
end

def w96_check_reader(path : String, profile : W96OracleProfile, label : String) : Nil
  keys = CrystalClick::WidePart.open_typed(path, "pk")
  tuple = CrystalClick::WidePart.open_typed(path, "payload")
  raise "#{label}: key mark schedule differs" unless keys.mark_row_counts == W96_EXPECTED_MARK_ROWS
  raise "#{label}: Tuple mark schedule differs" unless tuple.mark_row_counts == W96_EXPECTED_MARK_ROWS
  actual_keys = keys.read_uint64_mark_range("pk", 0, keys.mark_count)
  data = tuple.read_tuple_mark_range("payload", 0, tuple.mark_count)
  raise "#{label}: returned schema differs" unless data.type_name == profile.type_name
  raise "#{label}: returned field order differs" unless data.fields.map(&.name) == profile.fields.map(&.name)
  indexes = [0, 1, 2, 3, 4] of Int32
  w96_assert_bytes(
    w96_actual_data_rowbinary(profile, actual_keys, data, indexes),
    w96_expected_rowbinary(profile, indexes),
    "#{label} stock -> Crystal full mark range"
  )

  range_keys = keys.read_uint64_mark_range("pk", 1, tuple.mark_count - 1)
  range_data = tuple.read_tuple_mark_range("payload", 1, tuple.mark_count - 1)
  w96_assert_bytes(
    w96_actual_data_rowbinary(profile, range_keys, range_data, [0, 1, 2] of Int32),
    w96_expected_rowbinary(profile, [2, 3, 4] of Int32),
    "#{label} stock -> Crystal selected mark range"
  )
end

def w96_writer_columns(profile : W96OracleProfile) : Array(CrystalClick::WideTupleLeafColumn)
  profile.fields.map(&.column)
end

def w96_check_writer(binary : String, store : String, profile : W96OracleProfile) : Nil
  part = File.join(ENV.fetch("TUPLE_WRITER_ROOT"), profile.label)
  CrystalClick::WidePartWriter.write_uint64_tuple_pair(
    part,
    "pk",
    W96_KEYS.to_unsafe.to_slice(W96_KEYS.size),
    "payload",
    profile.type_name,
    w96_writer_columns(profile),
    rows_per_mark: 2
  )

  table = "w96_writer_#{profile.label}"
  attached = w96_attach_writer_part(binary, store, table, part, profile)
  writer_info = w96_serialization_info(attached, "writer #{profile.label}")
  writer_serializers = writer_info.as_h["columns"]?.try(&.as_a) || raise "writer #{profile.label}: serializers missing"
  writer_names = writer_serializers.map { |entry| entry.as_h["name"].as_s }
  raise "writer #{profile.label}: expected explicit Default serializers" unless writer_names == ["payload", "pk"]
  w96_assert_stock_physical_profile(attached, profile, "writer #{profile.label}")
  w96_assert_check(binary, store, table, attached)
  w96_stock_read_indexes(binary, store, table, profile, [0, 1, 2, 3, 4] of Int32, "writer #{profile.label} -> stock full RowBinary")
  w96_stock_read_indexes(binary, store, table, profile, [1, 2, 3] of Int32, "writer #{profile.label} -> stock selected RowBinary")
  w96_check_reader(attached, profile, "writer #{profile.label} attached")
  w96_check_high_level(store, attached, table, profile, "writer #{profile.label} attached")
end

def w96_check_profile(binary : String, store : String, profile : W96OracleProfile) : Nil
  plan = CrystalClick::WideTupleTypePlan.for_type(profile.type_name) || raise "#{profile.label}: Tuple plan not admitted"
  expected_fields = profile.fields.map { |field| {field.name, field.type_name} }
  observed_fields = plan.fields.map { |field| {field.name, field.type_name} }
  raise "#{profile.label}: plan declaration order/type differs" unless expected_fields == observed_fields

  stock_table = "w96_stock_#{profile.label}"
  stock_path = w96_create_stock_part(binary, store, stock_table, profile)
  w96_assert_stock_physical_profile(stock_path, profile, "stock #{profile.label}")
  w96_assert_stock_serialization(stock_path, profile, "stock #{profile.label}")
  w96_assert_check(binary, store, stock_table, stock_path)
  w96_stock_read_indexes(binary, store, stock_table, profile, [0, 1, 2, 3, 4] of Int32, "stock #{profile.label} full RowBinary")
  w96_stock_read_indexes(binary, store, stock_table, profile, [1, 2, 3] of Int32, "stock #{profile.label} selected RowBinary")
  w96_check_reader(stock_path, profile, "stock #{profile.label}")
  w96_check_high_level(store, stock_path, stock_table, profile, "stock #{profile.label}")
  w96_check_writer(binary, store, profile)
  puts "PASS #{profile.label}: all #{profile.fields.size} leaves stock->Crystal and Crystal->stock, physical Wide/marks, typed full/window/sparse, catalog, ATTACH/CHECK"
end

binary = ENV["CLICKHOUSE_BIN"]? || raise "set CLICKHOUSE_BIN to the pinned ClickHouse 26.7.1.1315 executable"
store = ENV["CLICKHOUSE_STORE"]? || raise "set CLICKHOUSE_STORE to an empty temporary ClickHouse store"
writer_root = ENV["TUPLE_WRITER_ROOT"]? || raise "set TUPLE_WRITER_ROOT to a fresh temporary directory"
unless store.starts_with?("/private/tmp/") || store.starts_with?("/tmp/")
  raise "refusing non-temporary ClickHouse store path: #{store}"
end
raise "ClickHouse store must be empty" if Dir.exists?(store) && !Dir.empty?(store)
Dir.mkdir_p(store)
Dir.mkdir_p(writer_root)

version = w96_run_clickhouse(binary, store, "SELECT version() FORMAT TSVRaw").strip
raise "oracle requires ClickHouse 26.7.1.1315, got #{version}" unless version == "26.7.1.1315"
puts "Stock oracle: ClickHouse local version #{version}"

profiles = w96_profiles
w96_qualify_mismatch_comparator(w96_expected_rowbinary(profiles[0], [0, 1, 2, 3, 4] of Int32))
profiles.each { |profile| w96_check_profile(binary, store, profile) }

puts "PASS W96 numeric Tuple oracle: fifteen nominal numeric leaves, mixed and numeric-only payloads, all-default stock profile, independent RowBinary both directions, stock ATTACH/CHECK, full/window/sparse/catalog reads"
