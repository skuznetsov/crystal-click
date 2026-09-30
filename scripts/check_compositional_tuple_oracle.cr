require "../src/crystal_click"
require "json"
require "file_utils"

struct W94OracleField
  getter name : String
  getter type_name : String
  getter values : Array(UInt64) | Array(String)

  def initialize(@name : String, @type_name : String, @values : Array(UInt64) | Array(String))
  end
end

struct W94OracleCase
  getter label : String
  getter fields : Array(W94OracleField)
  getter always_default : Bool

  def initialize(@label : String, @fields : Array(W94OracleField), @always_default = false)
  end

  def type_name : String
    "Tuple(#{fields.map { |field| "#{field.name} #{field.type_name}" }.join(", ")})"
  end
end

W94_KEYS                    = [0_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]
W94_EXPECTED_MARK_ROWS      = [2_u64, 2_u64, 2_u64, 1_u64]
W94_EXPECTED_MARK_FILE_ROWS = W94_EXPECTED_MARK_ROWS + [0_u64]

def w94_run_clickhouse(binary : String, store : String, query : String) : String
  output = IO::Memory.new
  result = Process.run(
    binary,
    ["local", "--path", store, "--query", query],
    output: output,
    error: Process::Redirect::Inherit
  )
  raise "ClickHouse local query failed (status #{result.exit_code}): #{query}" unless result.success?
  output.to_s
end

def w94_append_u64(io : IO::Memory, value : UInt64) : Nil
  8.times { |offset| io.write_byte(((value >> (offset * 8)) & 0xff_u64).to_u8) }
end

def w94_append_varuint(io : IO::Memory, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

def w94_assert_bytes(actual : Bytes, expected : Bytes, label : String) : Nil
  unless actual == expected
    raise "#{label} RowBinary differs: expected #{expected.size} bytes, got #{actual.size}"
  end
end

def w94_uint64_field(name : String, salt : UInt64) : W94OracleField
  values = [
    UInt64::MAX,
    101_u64 + salt,
    0_u64,
    10_000_u64 + salt,
    0x8000_0000_0000_0001_u64 + salt,
    700_u64 + salt,
    900_u64 + salt,
  ]
  W94OracleField.new(name, "UInt64", values)
end

def w94_string_field(name : String, salt : UInt8) : W94OracleField
  values = [
    "",
    String.new(Bytes[0x61_u8, 0_u8, salt]),
    String.new(Bytes[0xff_u8, salt, 0_u8]),
    "field-#{salt}-é",
    "",
    String.new(Bytes[0_u8, 0x74_u8, salt]),
    "last-#{salt}",
  ]
  W94OracleField.new(name, "String", values)
end

def w94_empty_string_field(name : String) : W94OracleField
  W94OracleField.new(name, "String", Array.new(W94_KEYS.size, ""))
end

def w94_cases : Array(W94OracleCase)
  [
    W94OracleCase.new("one_string", [w94_string_field("only", 1_u8)] of W94OracleField),
    W94OracleCase.new("pair_compatibility", [w94_uint64_field("a", 1_u64), w94_string_field("b", 2_u8)] of W94OracleField),
    W94OracleCase.new("three_string_first", [w94_string_field("c", 3_u8), w94_uint64_field("a", 4_u64), w94_string_field("b", 5_u8)] of W94OracleField),
    W94OracleCase.new("nine_alternating", [
      w94_string_field("f0", 6_u8),
      w94_uint64_field("f1", 7_u64),
      w94_string_field("f2", 8_u8),
      w94_uint64_field("f3", 9_u64),
      w94_string_field("f4", 10_u8),
      w94_uint64_field("f5", 11_u64),
      w94_string_field("f6", 12_u8),
      w94_uint64_field("f7", 13_u64),
      w94_string_field("f8", 14_u8),
    ] of W94OracleField),
    W94OracleCase.new("three_all_string", [w94_string_field("s0", 15_u8), w94_string_field("s1", 16_u8), w94_string_field("s2", 17_u8)] of W94OracleField),
    W94OracleCase.new("two_uint64_only", [w94_uint64_field("n0", 18_u64), w94_uint64_field("n1", 19_u64)] of W94OracleField),
    W94OracleCase.new("three_all_empty_strings", [w94_empty_string_field("e0"), w94_empty_string_field("e1"), w94_empty_string_field("e2")] of W94OracleField, true),
  ]
end

def w94_leaf_columns(profile : W94OracleCase) : Array(CrystalClick::WideTupleLeafColumn)
  columns = [] of CrystalClick::WideTupleLeafColumn
  profile.fields.each do |field|
    columns << CrystalClick::WideTupleLeafColumn.new(field.name, field.values)
  end
  columns
end

def w94_expected_rowbinary(keys : Array(UInt64), fields : Array(W94OracleField), row_indexes : Array(Int32)) : Bytes
  output = IO::Memory.new
  row_indexes.each do |row_index|
    w94_append_u64(output, keys[row_index])
    fields.each do |field|
      if field.type_name == "UInt64"
        w94_append_u64(output, field.values.as(Array(UInt64))[row_index])
      elsif field.type_name == "String"
        value = field.values.as(Array(String))[row_index]
        w94_append_varuint(output, value.bytesize.to_u64)
        output.write(value.to_slice)
      else
        raise "oracle has no RowBinary encoder for #{field.type_name}"
      end
    end
  end
  output.to_slice
end

def w94_expected_payload_rowbinary(fields : Array(W94OracleField), row_indexes : Array(Int32)) : Bytes
  output = IO::Memory.new
  row_indexes.each do |row_index|
    fields.each do |field|
      if field.type_name == "UInt64"
        w94_append_u64(output, field.values.as(Array(UInt64))[row_index])
      elsif field.type_name == "String"
        value = field.values.as(Array(String))[row_index]
        w94_append_varuint(output, value.bytesize.to_u64)
        output.write(value.to_slice)
      else
        raise "oracle has no Tuple payload encoder for #{field.type_name}"
      end
    end
  end
  output.to_slice
end

def w94_append_tuple_row(output : IO::Memory, profile : W94OracleCase, row : CrystalClick::WideTupleRow) : Nil
  raise "#{profile.label} row Tuple type changed: #{row.type_name}" unless row.type_name == profile.type_name
  fields = row.fields
  expected_fields = profile.fields.map { |field| {field.name, field.type_name} }
  observed_fields = fields.map { |field| {field.name, field.type_name} }
  raise "#{profile.label} row field order/type changed: #{observed_fields.inspect}" unless observed_fields == expected_fields

  fields.each do |field|
    value = row[field.name]
    if field.type_name == "UInt64"
      raise "#{profile.label} row field #{field.name} is not UInt64" unless value.is_a?(UInt64)
      w94_append_u64(output, value.as(UInt64))
    elsif field.type_name == "String"
      raise "#{profile.label} row field #{field.name} is not String" unless value.is_a?(String)
      string_value = value.as(String)
      w94_append_varuint(output, string_value.bytesize.to_u64)
      output.write(string_value.to_slice)
    else
      raise "oracle has no Tuple row encoder for #{field.type_name}"
    end
  end
end

def w94_batch_rowbinary(batch : CrystalClick::WidePartTableBatch, profile : W94OracleCase) : Bytes
  raise "#{profile.label} batch Tuple type changed" unless batch.column_type_for("payload") == profile.type_name
  keys = batch.values_for("pk")
  output = IO::Memory.new

  if profile.type_name == "Tuple(a UInt64, b String)"
    tuples = batch.tuples_for("payload")
    raise "#{profile.label} native Tuple and key rows differ" unless tuples.size == keys.size
    keys.each_with_index do |key, index|
      number, value = tuples[index]
      w94_append_u64(output, key)
      w94_append_u64(output, number)
      w94_append_varuint(output, value.bytesize.to_u64)
      output.write(value.to_slice)
    end
  else
    rows = batch.tuple_rows_for("payload")
    raise "#{profile.label} Tuple row handles and key rows differ" unless rows.size == keys.size
    keys.each_with_index do |key, index|
      w94_append_u64(output, key)
      w94_append_tuple_row(output, profile, rows[index])
    end
  end

  output.to_slice
end

def w94_values_payload_rowbinary(values : Array(CrystalClick::OfflineColumnValue), profile : W94OracleCase) : Bytes
  output = IO::Memory.new
  if profile.type_name == "Tuple(a UInt64, b String)"
    values.each do |value|
      number, string_value = value.as(Tuple(UInt64, String))
      w94_append_u64(output, number)
      w94_append_varuint(output, string_value.bytesize.to_u64)
      output.write(string_value.to_slice)
    end
  else
    values.each do |value|
      w94_append_tuple_row(output, profile, value.as(CrystalClick::WideTupleRow))
    end
  end
  output.to_slice
end

def w94_read_rowbinary(keys : Array(UInt64), profile : W94OracleCase, data : CrystalClick::WideTupleColumnData) : Bytes
  columns = data.columns
  expected_names = profile.fields.map(&.name)
  observed_names = columns.map(&.name)
  raise "#{profile.label} returned field order differs: #{observed_names.inspect}" unless observed_names == expected_names
  raise "#{profile.label} returned row count differs" unless data.row_count == keys.size

  output = IO::Memory.new
  keys.each_with_index do |key, row_index|
    w94_append_u64(output, key)
    profile.fields.each_with_index do |field, field_index|
      column = columns[field_index]
      if field.type_name == "UInt64"
        w94_append_u64(output, column.uint64_values[row_index])
      elsif field.type_name == "String"
        value = column.string_values[row_index]
        w94_append_varuint(output, value.bytesize.to_u64)
        output.write(value.to_slice)
      else
        raise "oracle has no RowBinary encoder for #{field.type_name}"
      end
    end
  end
  output.to_slice
end

def w94_expected_type_plan(profile : W94OracleCase) : CrystalClick::WideTupleTypePlan
  plan = CrystalClick::WideTupleTypePlan.for_type(profile.type_name) ||
         raise "#{profile.label} type plan is not admitted: #{profile.type_name}"
  expected = profile.fields.map { |field| {field.name, field.type_name} }
  observed = plan.fields.map { |field| {field.name, field.type_name} }
  raise "#{profile.label} plan changed declaration order/type: #{observed.inspect}" unless observed == expected
  plan
end

def w94_table_sql(table : String, profile : W94OracleCase) : String
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
      min_compress_block_size = 0,
      max_compress_block_size = 4096,
      ratio_of_defaults_for_sparse_serialization = #{ratio}
  SQL
end

def w94_sql_leaf(field : W94OracleField, row_index : Int32) : String
  if field.type_name == "UInt64"
    "toUInt64('#{field.values.as(Array(UInt64))[row_index]}')"
  elsif field.type_name == "String"
    value = field.values.as(Array(String))[row_index]
    "unhex('#{value.to_slice.hexstring}')"
  else
    raise "oracle has no SQL encoder for #{field.type_name}"
  end
end

def w94_insert_rows(binary : String, store : String, table : String, profile : W94OracleCase) : Nil
  rows = W94_KEYS.map_with_index do |key, row_index|
    values = profile.fields.map { |field| w94_sql_leaf(field, row_index) }.join(", ")
    "(toUInt64('#{key}'), tuple(#{values}))"
  end.join(", ")
  w94_run_clickhouse(binary, store, "INSERT INTO default.#{table} VALUES #{rows}")
end

def w94_create_stock_part(binary : String, store : String, table : String, profile : W94OracleCase) : String
  w94_run_clickhouse(binary, store, w94_table_sql(table, profile))
  w94_insert_rows(binary, store, table, profile)
  paths = w94_run_clickhouse(
    binary,
    store,
    "SELECT path FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TSVRaw"
  ).lines.map(&.strip).reject(&.empty?)
  raise "#{table} must have exactly one stock-created active part" unless paths.size == 1
  paths[0]
end

def w94_expected_streams(profile : W94OracleCase) : Array(String)
  streams = ["pk"]
  profile.fields.each do |field|
    prefix = "payload%2E#{field.name}"
    if field.type_name == "String"
      streams << "#{prefix}.size"
      streams << prefix
    elsif field.type_name == "UInt64"
      streams << prefix
    else
      raise "oracle has no stream profile for #{field.type_name}"
    end
  end
  streams
end

def w94_expected_substreams_metadata(profile : W94OracleCase) : String
  streams = w94_expected_streams(profile)
  key_lines = ["columns substreams version: 1", "2 columns:", "1 substreams for column `pk`:", "\tpk"]
  payload_streams = streams[1..]
  key_lines << "#{payload_streams.size} substreams for column `payload`:"
  payload_streams.each { |name| key_lines << "\t#{name}" }
  key_lines.join("\n") + "\n"
end

def w94_mark_rows(mark_bytes : Bytes, label : String) : Array(UInt64)
  mark_size = CrystalClick::WidePart::MARK_SIZE
  raise "#{label} mark file has a partial mark" unless mark_bytes.size % mark_size == 0
  Array.new(mark_bytes.size // mark_size) do |index|
    offset = index * mark_size + 16
    8.times.reduce(0_u64) do |value, byte|
      value | (mark_bytes[offset + byte].to_u64 << (byte * 8))
    end
  end
end

def w94_assert_physical_profile(path : String, profile : W94OracleCase, label : String) : Nil
  expected_streams = w94_expected_streams(profile)
  substreams_path = File.join(path, "columns_substreams.txt")
  actual_metadata = File.read(substreams_path)
  expected_metadata = w94_expected_substreams_metadata(profile)
  raise "#{label} columns_substreams.txt differs:\n#{actual_metadata}" unless actual_metadata == expected_metadata

  expected_bases = expected_streams.map { |name| CrystalClick::StreamName.hash(name) }
  expected_bin_files = expected_bases.map { |base| "#{base}.bin" }.sort
  expected_mark_files = expected_bases.map { |base| "#{base}.mrk2" }.sort
  children = Dir.children(path)
  actual_bin_files = children.select(&.ends_with?(".bin")).sort
  actual_mark_files = children.select(&.ends_with?(".mrk2")).sort
  raise "#{label} physical .bin inventory differs: #{actual_bin_files.inspect}" unless actual_bin_files == expected_bin_files
  raise "#{label} physical .mrk2 inventory differs: #{actual_mark_files.inspect}" unless actual_mark_files == expected_mark_files

  expected_streams.each do |logical_name|
    base = CrystalClick::StreamName.hash(logical_name)
    mark_path = File.join(path, "#{base}.mrk2")
    observed_rows = w94_mark_rows(File.read(mark_path).to_slice, "#{label} #{logical_name}")
    unless observed_rows == W94_EXPECTED_MARK_FILE_ROWS
      raise "#{label} #{logical_name} mark rows differ: #{observed_rows.inspect}"
    end
  end

  if profile.always_default
    profile.fields.each do |field|
      next unless field.type_name == "String"
      raw_base = CrystalClick::StreamName.hash("payload%2E#{field.name}")
      raw_path = File.join(path, "#{raw_base}.bin")
      raise "#{label} all-empty String raw stream is not zero bytes: #{field.name}" unless File.size(raw_path) == 0
    end
  end
end

def w94_stock_metadata_summary(path : String, profile : W94OracleCase, label : String) : Nil
  column_lines = File.read(File.join(path, "columns.txt")).lines.map(&.strip)
  expected_column_lines = [
    "columns format version: 1",
    "2 columns:",
    "`pk` UInt64",
    "`payload` #{profile.type_name}",
  ]
  raise "#{label} columns.txt differs: #{column_lines.inspect}" unless column_lines == expected_column_lines

  info = JSON.parse(File.read(File.join(path, "serialization.json"))).as_h
  version = info["version"]?.try(&.as_i) || raise "#{label} serialization.json version is missing"
  raise "#{label} pinned stock metadata version differs: expected 1, got #{version}" unless version == 1

  type_versions = info["types_serialization_versions"]?.try(&.as_h) ||
                  raise "#{label} typed metadata has no type-version map"
  unless type_versions.size == 1 && type_versions["string"]?.try(&.as_i) == 1
    raise "#{label} pinned stock type-version map differs: expected {string: 1}, got #{type_versions.inspect}"
  end

  propagated = info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool)
  raise "#{label} pinned stock nested-version propagation is not true" unless propagated == true

  summary = type_versions.to_json
  puts "OBSERVED #{label} serialization.json version=#{version} types_serialization_versions=#{summary}"

  serializers = info["columns"]?.try(&.as_a) || raise "#{label} serialization.json columns are missing"
  names = serializers.map { |entry| entry.as_h["name"].as_s }
  expected_names = profile.always_default ? [] of String : ["payload", "pk"]
  raise "#{label} stock serializer names differ: expected #{expected_names.inspect}, got #{names.inspect}" unless names == expected_names

  serializers.each do |serializer|
    entry = serializer.as_h
    raise "#{label} stock serializer is not Default" unless entry["kind"]?.try(&.as_s) == "Default"
    rows = entry["num_rows"]?.try(&.as_i) || raise "#{label} serializer row count is missing"
    defaults = entry["num_defaults"]?.try(&.as_i) || raise "#{label} serializer default count is missing"
    raise "#{label} serializer row count differs" unless rows == W94_KEYS.size
    raise "#{label} serializer default count is invalid" unless defaults >= 0 && defaults <= rows
    next unless entry["name"]?.try(&.as_s) == "payload"

    children = entry["subcolumns"]?.try(&.as_a) || raise "#{label} Tuple child serializers are missing"
    raise "#{label} Tuple child count differs" unless children.size == profile.fields.size
    children.each do |child|
      child_entry = child.as_h
      raise "#{label} Tuple child serializer is not Default" unless child_entry["kind"]?.try(&.as_s) == "Default"
      child_rows = child_entry["num_rows"]?.try(&.as_i) || raise "#{label} Tuple child row count is missing"
      child_defaults = child_entry["num_defaults"]?.try(&.as_i) || raise "#{label} Tuple child default count is missing"
      raise "#{label} Tuple child row count differs" unless child_rows == W94_KEYS.size
      raise "#{label} Tuple child default count is invalid" unless child_defaults >= 0 && child_defaults <= child_rows
    end
  end
  if profile.fields.all? { |field| field.type_name == "UInt64" }
    puts "OBSERVED #{label} UInt64-only metadata version=#{version} types_serialization_versions=#{summary}"
  end
end

def w94_assert_stock_table(binary : String, store : String, table : String, part_path : String, profile : W94OracleCase) : Nil
  part_name = File.basename(part_path.chomp("/"))
  integrity = w94_run_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "#{table} CHECK TABLE failed: #{integrity.inspect}" unless integrity == "#{part_name}\t1"
end

def w94_select_query(table : String, profile : W94OracleCase, ranged : Bool) : String
  selected = ["pk"] + profile.fields.map { |field| "payload.#{field.name}" }
  where = ranged ? " WHERE pk >= 2 AND pk < 11" : ""
  "SELECT #{selected.join(", ")} FROM default.#{table}#{where} ORDER BY pk FORMAT RowBinary"
end

def w94_selected_indexes(ranged : Bool) : Array(Int32)
  selected = W94_KEYS.each_with_index.compact_map do |key, index|
    index.to_i32 if !ranged || (key >= 2_u64 && key < 11_u64)
  end
  selected.to_a
end

def w94_check_high_level_consumers(store : String, part_path : String, table_name : String, profile : W94OracleCase) : Nil
  reader = CrystalClick::WidePartTable.open_selected_typed([part_path], ["pk", "payload"])
  expected_full = w94_expected_rowbinary(W94_KEYS, profile.fields, w94_selected_indexes(false))

  full = IO::Memory.new
  reader.scan_typed do |batch|
    full.write(w94_batch_rowbinary(batch, profile))
  end
  w94_assert_bytes(full.to_slice, expected_full, "#{profile.label} high-level full scan")

  window = IO::Memory.new
  reader.scan_typed_window(1_u64, 4) do |batch|
    window.write(w94_batch_rowbinary(batch, profile))
  end
  window_indexes = [1, 2, 3, 4] of Int32
  w94_assert_bytes(
    window.to_slice,
    w94_expected_rowbinary(W94_KEYS, profile.fields, window_indexes),
    "#{profile.label} high-level partial-row window"
  )

  sparse = IO::Memory.new
  reader.scan_typed_candidate_marks([[1, 3]] of Array(Int32)) do |batch|
    sparse.write(w94_batch_rowbinary(batch, profile))
  end
  sparse_indexes = [2, 3, 6] of Int32
  w94_assert_bytes(
    sparse.to_slice,
    w94_expected_rowbinary(W94_KEYS, profile.fields, sparse_indexes),
    "#{profile.label} high-level sparse key+Tuple candidate marks"
  )

  catalog_table = CrystalClick::OfflineCatalog.open(store).table("default", table_name)
  candidates = catalog_table.resolved_scan_parts
  unless candidates.size == 1 && File.realpath(candidates[0].path) == File.realpath(part_path)
    raise "#{profile.label} catalog did not resolve the expected stock part: #{candidates.map(&.path).inspect}"
  end
  values = catalog_table["payload"].values
  w94_assert_bytes(
    w94_values_payload_rowbinary(values, profile),
    w94_expected_payload_rowbinary(profile.fields, w94_selected_indexes(false)),
    "#{profile.label} catalog payload values"
  )
end

def w94_assert_table_bytes(binary : String, store : String, table : String, profile : W94OracleCase) : Nil
  full = w94_run_clickhouse(binary, store, w94_select_query(table, profile, false))
  full_indexes = w94_selected_indexes(false)
  expected_full = w94_expected_rowbinary(W94_KEYS, profile.fields, full_indexes)
  w94_assert_bytes(full.to_slice, expected_full, "#{table} full")

  ranged = w94_run_clickhouse(binary, store, w94_select_query(table, profile, true))
  range_indexes = w94_selected_indexes(true)
  range_keys = range_indexes.map { |index| W94_KEYS[index] }
  expected_range = w94_expected_rowbinary(W94_KEYS, profile.fields, range_indexes)
  w94_assert_bytes(ranged.to_slice, expected_range, "#{table} key range")
  raise "#{table} ranged key fixture changed" unless range_keys == [2_u64, 4_u64, 6_u64, 9_u64]
end

def w94_check_stock_reader(path : String, profile : W94OracleCase) : Nil
  key_reader = CrystalClick::WidePart.open_typed(path, "pk")
  tuple_reader = CrystalClick::WidePart.open_typed(path, "payload")
  raise "#{profile.label} key mark rows differ" unless key_reader.mark_row_counts == W94_EXPECTED_MARK_ROWS
  raise "#{profile.label} Tuple mark rows differ" unless tuple_reader.mark_row_counts == W94_EXPECTED_MARK_ROWS

  actual_keys = key_reader.read_uint64_mark_range("pk", 0, key_reader.mark_count)
  data = tuple_reader.read_tuple_mark_range("payload", 0, tuple_reader.mark_count)
  actual_bytes = w94_read_rowbinary(actual_keys, profile, data)
  expected_bytes = w94_expected_rowbinary(W94_KEYS, profile.fields, w94_selected_indexes(false))
  w94_assert_bytes(actual_bytes, expected_bytes, "#{profile.label} stock -> Crystal full")

  first_mark = 1
  count = tuple_reader.mark_count - first_mark
  range_keys = key_reader.read_uint64_mark_range("pk", first_mark, count)
  range_data = tuple_reader.read_tuple_mark_range("payload", first_mark, count)
  range_indexes = (2...W94_KEYS.size).map(&.to_i32)
  w94_assert_bytes(
    w94_read_rowbinary(range_keys, profile, range_data),
    w94_expected_rowbinary(W94_KEYS, profile.fields, range_indexes),
    "#{profile.label} stock -> Crystal mark range"
  )
end

def w94_attach_writer_part(binary : String, store : String, table : String, part : String, profile : W94OracleCase) : String
  w94_run_clickhouse(binary, store, w94_table_sql(table, profile))
  data_path = w94_run_clickhouse(
    binary,
    store,
    "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{table}' FORMAT TSVRaw"
  ).strip
  raise "ClickHouse returned no data path for #{table}" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  w94_run_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  File.join(data_path, "all_1_1_0")
end

def w94_check_writer(binary : String, store : String, profile : W94OracleCase) : Nil
  part = File.join(ENV.fetch("TUPLE_WRITER_ROOT"), profile.label)
  CrystalClick::WidePartWriter.write_uint64_tuple_pair(
    part,
    "pk",
    W94_KEYS.to_unsafe.to_slice(W94_KEYS.size),
    "payload",
    profile.type_name,
    w94_leaf_columns(profile),
    rows_per_mark: 2
  )

  attached_path = w94_attach_writer_part(binary, store, "tuple_writer_#{profile.label}", part, profile)
  w94_assert_physical_profile(attached_path, profile, "writer #{profile.label}")
  w94_assert_table_bytes(binary, store, "tuple_writer_#{profile.label}", profile)
  w94_assert_stock_table(binary, store, "tuple_writer_#{profile.label}", attached_path, profile)
  w94_check_high_level_consumers(store, attached_path, "tuple_writer_#{profile.label}", profile)

  reader = CrystalClick::WidePart.open_typed(attached_path, "payload")
  actual = reader.read_tuple_mark_range("payload", 0, reader.mark_count)
  expected = w94_leaf_columns(profile)
  raise "#{profile.label} writer-attached Crystal read field order differs" unless actual.columns.map(&.name) == expected.map(&.name)
  actual_bytes = w94_read_rowbinary(W94_KEYS, profile, actual)
  expected_bytes = w94_expected_rowbinary(W94_KEYS, profile.fields, w94_selected_indexes(false))
  w94_assert_bytes(actual_bytes, expected_bytes, "#{profile.label} writer -> stock -> Crystal")

  key_reader = CrystalClick::WidePart.open_typed(attached_path, "pk")
  range_keys = key_reader.read_uint64_mark_range("pk", 1, reader.mark_count - 1)
  range_data = reader.read_tuple_mark_range("payload", 1, reader.mark_count - 1)
  w94_assert_bytes(
    w94_read_rowbinary(range_keys, profile, range_data),
    w94_expected_rowbinary(W94_KEYS, profile.fields, (2...W94_KEYS.size).map(&.to_i32)),
    "#{profile.label} writer -> stock -> Crystal mark range"
  )
end

binary = ENV.fetch("CLICKHOUSE_BIN")
store = ENV.fetch("CLICKHOUSE_STORE")
cases = w94_cases

cases.each do |profile|
  w94_expected_type_plan(profile)
  table = "tuple_stock_#{profile.label}"
  path = w94_create_stock_part(binary, store, table, profile)
  w94_stock_metadata_summary(path, profile, "stock #{profile.label}")
  w94_assert_physical_profile(path, profile, "stock #{profile.label}")
  w94_assert_stock_table(binary, store, table, path, profile)
  w94_assert_table_bytes(binary, store, table, profile)
  w94_check_stock_reader(path, profile)
  w94_check_high_level_consumers(store, path, table, profile)

  w94_check_writer(binary, store, profile)
end

puts "PASS W94/W95 Tuple oracle: pinned stock -> Crystal and Crystal -> stock ATTACH/CHECK, physical and high-level full/window/candidate scans, catalog payload values, full/ranged RowBinary, exact schema/stream/mark inventories for 1/2/3/9-field, String-first, all-String, UInt64-only, mixed and all-empty profiles"
