require "json"
require "file_utils"
require "../src/crystal_click"

W99O_VERSION        = "26.7.1.1315"
W99O_KEYS           = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
W99O_MARK_ROWS      = [2_u64, 2_u64, 1_u64, 0_u64]
W99O_FULL_INDEXES   = [0_i32, 1_i32, 2_i32, 3_i32, 4_i32]
W99O_KEY_RANGE      = [1_i32, 2_i32, 3_i32]
W99O_MARK_RANGE     = [2_i32, 3_i32, 4_i32]
W99O_WINDOW_INDEXES = [1_i32, 2_i32, 3_i32]
W99O_CANDIDATE      = [0_i32, 1_i32, 4_i32]

struct W99OracleCase
  getter label : String
  getter columns : Array(CrystalClick::WideTupleLeafColumn)
  getter ratio : String

  def initialize(@label : String, columns : Array(CrystalClick::WideTupleLeafColumn), @ratio : String = "0.9375")
    @columns = columns.map(&.owned_copy)
  end

  def type_name : String
    "Tuple(#{@columns.map { |column| "#{column.name} #{column.type_name}" }.join(", ")})"
  end

  def source_table : String
    "w99_source_#{@label}"
  end

  def writer_table : String
    "w99_writer_#{@label}"
  end
end

def w99o_u64_le(value : UInt64, width : Int32 = 8) : String
  output = IO::Memory.new
  width.times { |index| output.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
  output.to_s
end

def w99o_u64_be(value : UInt64, width : Int32 = 8) : String
  output = IO::Memory.new
  width.times do |index|
    shift = (width - index - 1) * 8
    output.write_byte(((value >> shift) & 0xff_u64).to_u8)
  end
  output.to_s
end

def w99o_ipv6_bytes(value : CrystalClick::IPv6Value) : String
  w99o_u64_be(value.high) + w99o_u64_be(value.low)
end

def w99o_leaf_disk_bytes(column : CrystalClick::WideTupleLeafColumn, row : Int32) : String
  case column.type_name
  when "UUID"
    value = column.value_at(row, CrystalClick::UUIDValue)
    w99o_u64_le(value.high) + w99o_u64_le(value.low)
  when "IPv4"
    value = column.value_at(row, CrystalClick::IPv4Value)
    w99o_u64_le(value.network_order.to_u64, 4)
  when "IPv6"
    w99o_ipv6_bytes(column.value_at(row, CrystalClick::IPv6Value))
  when "UInt64"
    w99o_u64_le(column.value_at(row, UInt64))
  when "Bool"
    column.value_at(row, Bool) ? "\x01" : "\x00"
  when "String"
    column.value_at(row, String)
  else
    raise "W99 oracle has no identifier Tuple encoder for #{column.type_name}"
  end
end

def w99o_leaf_default?(column : CrystalClick::WideTupleLeafColumn, row : Int32) : Bool
  case column.type_name
  when "UUID"
    value = column.value_at(row, CrystalClick::UUIDValue)
    value.high == 0_u64 && value.low == 0_u64
  when "IPv4"
    column.value_at(row, CrystalClick::IPv4Value).network_order == 0_u32
  when "IPv6"
    value = column.value_at(row, CrystalClick::IPv6Value)
    value.high == 0_u64 && value.low == 0_u64
  when "UInt64"
    column.value_at(row, UInt64) == 0_u64
  when "Bool"
    !column.value_at(row, Bool)
  when "String"
    column.value_at(row, String).empty?
  else
    raise "W99 oracle has no default predicate for #{column.type_name}"
  end
end

def w99o_row_default?(columns : Array(CrystalClick::WideTupleLeafColumn), row : Int32) : Bool
  columns.all? { |column| w99o_leaf_default?(column, row) }
end

def w99o_varuint(value : UInt64) : String
  output = IO::Memory.new
  remaining = value
  while remaining >= 0x80_u64
    output.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  output.write_byte(remaining.to_u8)
  output.to_s
end

def w99o_rowbinary_payload(columns : Array(CrystalClick::WideTupleLeafColumn), row : Int32) : String
  output = IO::Memory.new
  columns.each do |column|
    case column.type_name
    when "String"
      value = column.value_at(row, String)
      output << w99o_varuint(value.bytesize.to_u64) << value
    else
      output << w99o_leaf_disk_bytes(column, row)
    end
  end
  output.to_s
end

def w99o_expected_rowbinary(keys : Array(UInt64), columns : Array(CrystalClick::WideTupleLeafColumn), indexes : Array(Int32)) : String
  output = IO::Memory.new
  indexes.each do |index|
    output << w99o_u64_le(keys[index]) << w99o_rowbinary_payload(columns, index)
  end
  output.to_s
end

def w99o_expected_payload_rowbinary(columns : Array(CrystalClick::WideTupleLeafColumn), indexes : Array(Int32)) : String
  output = IO::Memory.new
  indexes.each { |index| output << w99o_rowbinary_payload(columns, index) }
  output.to_s
end

class W99OracleByteMismatchError < Exception
end

def w99o_assert_bytes(actual : String, expected : String, label : String) : Nil
  return if actual == expected
  limit = Math.min(actual.bytesize, expected.bytesize)
  difference = 0
  while difference < limit && actual.to_slice[difference] == expected.to_slice[difference]
    difference += 1
  end
  got = difference < actual.bytesize ? actual.to_slice[difference].to_s(16).rjust(2, '0') : "<eof>"
  wanted = difference < expected.bytesize ? expected.to_slice[difference].to_s(16).rjust(2, '0') : "<eof>"
  raise W99OracleByteMismatchError.new("#{label} differs: expected #{expected.bytesize} bytes, got #{actual.bytesize}; first difference #{difference}: expected #{wanted}, got #{got}")
end

def w99o_seeded_wrong_byte_rejected(actual : String, expected : String, label : String) : Nil
  raise "#{label} baseline oracle comparison did not match" unless actual == expected
  damaged = String.new(expected.to_slice)
  damaged.to_unsafe[0] = damaged.to_slice[0] ^ 0x01_u8
  begin
    w99o_assert_bytes(actual, damaged, "#{label} seeded wrong-byte expectation")
    raise "#{label} seeded wrong-byte expectation was not rejected"
  rescue ex : W99OracleByteMismatchError
  end
  puts "PASS #{label}: one-byte seeded wrong expectation is rejected"
end

def w99o_clickhouse(binary : String, store : String, query : String, input : IO? = nil) : String
  output = IO::Memory.new
  error = IO::Memory.new
  status = if input
             Process.run(binary, ["local", "--path", store, "--query", query], input: input, output: output, error: error)
           else
             Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: error)
           end
  raise "ClickHouse query failed: #{error}\n#{query}" unless status.success?
  output.to_s
end

def w99o_insert_rowbinary(binary : String, store : String, table : String, bytes : String) : Nil
  input = IO::Memory.new(bytes.to_slice)
  w99o_clickhouse(binary, store, "INSERT INTO default.#{table} FORMAT RowBinary", input)
  nil
end

def w99o_create_table(binary : String, store : String, table : String, type_name : String, ratio : String) : Nil
  settings = "index_granularity = 2, enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0, compress_marks = 0, compress_primary_key = 0, min_compress_block_size = 0, max_compress_block_size = 4096, ratio_of_defaults_for_sparse_serialization = #{ratio}"
  w99o_clickhouse(binary, store, "CREATE TABLE default.#{table} (pk UInt64, payload #{type_name}) ENGINE = MergeTree ORDER BY pk SETTINGS #{settings}")
  nil
end

def w99o_part_path(binary : String, store : String, table : String) : String
  rows = w99o_clickhouse(binary, store, "SELECT path, part_type, rows FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").lines.map(&.strip).reject(&.empty?)
  raise "#{table}: expected one active part, got #{rows.inspect}" unless rows.size == 1
  parts = rows[0].split('\t')
  raise "#{table}: malformed part metadata #{rows[0].inspect}" unless parts.size == 3
  raise "#{table}: expected Wide part, got #{parts[1]}" unless parts[1] == "Wide"
  raise "#{table}: expected five rows, got #{parts[2]}" unless parts[2] == "5"
  parts[0]
end

def w99o_check_table(binary : String, store : String, table : String, part : String) : Nil
  actual = w99o_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  expected = "#{File.basename(part.chomp("/"))}\t1"
  raise "#{table} CHECK TABLE failed: #{actual.inspect}" unless actual == expected
  nil
end

def w99o_columns_schema(binary : String, store : String, table : String, type_name : String) : Nil
  actual = w99o_clickhouse(binary, store, "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw").lines.map(&.strip)
  expected = ["pk UInt64", "payload #{type_name}"]
  raise "#{table} system.columns mismatch: #{actual.inspect}" unless actual == expected
  nil
end

def w99o_plan(case_data : W99OracleCase) : CrystalClick::WideTupleTypePlan
  plan = CrystalClick::WideTupleTypePlan.for_type(case_data.type_name) || raise "#{case_data.label}: plan rejects #{case_data.type_name}"
  expected_fields = case_data.columns.map { |column| {column.name, column.type_name} }
  actual_fields = plan.fields.map { |field| {field.name, field.type_name} }
  raise "#{case_data.label}: plan field order differs" unless actual_fields == expected_fields
  plan
end

def w99o_stream_expected(case_data : W99OracleCase, stream : String) : String
  if stream == "pk"
    return W99O_KEYS.map { |key| w99o_u64_le(key) }.join
  end
  plan = w99o_plan(case_data)
  case_data.columns.each do |column|
    leaf_name = "payload%2E#{column.name}"
    if column.type_name == "String"
      if stream == "#{leaf_name}.size"
        return String.build do |output|
          W99O_KEYS.each do |key|
            index = (key - 1_u64).to_i32
            output << w99o_u64_le(column.value_at(index, String).bytesize.to_u64)
          end
        end
      elsif stream == leaf_name
        return String.build do |output|
          W99O_KEYS.each { |key| output << column.value_at((key - 1_u64).to_i32, String) }
        end
      end
    elsif stream == leaf_name
      return String.build do |output|
        W99O_KEYS.each { |key| output << w99o_leaf_disk_bytes(column, (key - 1_u64).to_i32) }
      end
    end
  end
  raise "#{case_data.label}: no independently expected bytes for physical stream #{stream.inspect} in #{plan.type_name}"
end

def w99o_mark_rows(part : String, stream : String) : Array(UInt64)
  mark_path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  bytes = File.read(mark_path).to_slice
  mark_size = CrystalClick::WidePart::MARK_SIZE
  raise "#{stream}: partial mark record" unless bytes.size % mark_size == 0
  Array(UInt64).new(bytes.size // mark_size) do |index|
    offset = index * mark_size + 16
    8.times.reduce(0_u64) { |value, byte| value | (bytes[offset + byte].to_u64 << (byte * 8)) }
  end
end

def w99o_substreams(case_data : W99OracleCase) : String
  payload_streams = w99o_plan(case_data).physical_streams("payload")
  lines = ["columns substreams version: 1", "2 columns:", "1 substreams for column `pk`:", "\tpk", "#{payload_streams.size} substreams for column `payload`:"]
  payload_streams.each { |stream| lines << "\t#{stream}" }
  lines.join("\n") + "\n"
end

def w99o_serializer_count(row : Hash(String, JSON::Any), expected_rows : Int32, expected_defaults : Int32?, label : String) : Nil
  raise "#{label}: serializer is not Default" unless row["kind"]?.try(&.as_s) == "Default"
  rows = row["num_rows"]?.try(&.as_i) || raise "#{label}: num_rows missing"
  defaults = row["num_defaults"]?.try(&.as_i) || raise "#{label}: num_defaults missing"
  raise "#{label}: row count #{rows}, expected #{expected_rows}" unless rows == expected_rows.to_i64
  raise "#{label}: invalid default count #{defaults}" unless defaults >= 0 && defaults <= rows
  if expected_defaults
    raise "#{label}: default count #{defaults}, expected #{expected_defaults}" unless defaults == expected_defaults.to_i64
  end
  nil
end

def w99o_validate_serialization(case_data : W99OracleCase, part : String, source_allzero : Bool, label : String) : JSON::Any
  info = JSON.parse(File.read(File.join(part, "serialization.json")))
  metadata = info.as_h
  raise "#{label}: serialization version differs" unless metadata["version"]?.try(&.as_i) == 1
  raise "#{label}: nested type-version propagation differs" unless metadata["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool) == true
  versions = metadata["types_serialization_versions"]?.try(&.as_h) || raise "#{label}: type version map missing"
  raise "#{label}: expected exact string serialization version 1, got #{versions.to_json}" unless versions.size == 1 && versions["string"]?.try(&.as_i) == 1
  records = metadata["columns"]?.try(&.as_a) || raise "#{label}: columns serializer list missing"

  if source_allzero
    raise "#{label}: pinned stock allzero profile must have columns: []" unless records.empty?
  else
    names = records.map { |entry| entry.as_h["name"]?.try(&.as_s) || raise "#{label}: serializer record name missing" }
    raise "#{label}: serializer roots/order differ: #{names.inspect}" unless names == ["payload", "pk"]
    root_default_rows = W99O_KEYS.count { |key| w99o_row_default?(case_data.columns, (key - 1_u64).to_i32) }
    w99o_serializer_count(records[0].as_h, 5, root_default_rows, "#{label} Tuple root")
    w99o_serializer_count(records[1].as_h, 5, 0, "#{label} key root")
    child_records = records[0].as_h["subcolumns"]?.try(&.as_a) || raise "#{label}: Tuple leaf records missing"
    raise "#{label}: Tuple leaf record count differs: #{child_records.size}" unless child_records.size == case_data.columns.size
    case_data.columns.each_with_index do |column, index|
      expected_defaults = W99O_KEYS.count { |key| w99o_leaf_default?(column, (key - 1_u64).to_i32) }
      w99o_serializer_count(child_records[index].as_h, 5, expected_defaults, "#{label} child #{column.name}")
    end
  end
  puts "OBSERVED #{label} serialization.json=#{info.to_json}"
  info
end

def w99o_assert_layout(case_data : W99OracleCase, part : String, source_allzero : Bool, label : String) : Nil
  expected_columns = ["columns format version: 1", "2 columns:", "`pk` UInt64", "`payload` #{case_data.type_name}"]
  actual_columns = File.read(File.join(part, "columns.txt")).lines.map(&.strip)
  raise "#{label}: columns.txt differs: #{actual_columns.inspect}" unless actual_columns == expected_columns
  actual_substreams = File.read(File.join(part, "columns_substreams.txt"))
  expected_substreams = w99o_substreams(case_data)
  raise "#{label}: columns_substreams.txt differs:\n#{actual_substreams}" unless actual_substreams == expected_substreams

  plan = w99o_plan(case_data)
  streams = ["pk"] + plan.physical_streams("payload")
  expected_bins = streams.map { |stream| "#{CrystalClick::StreamName.hash(stream)}.bin" }.sort
  expected_marks = streams.map { |stream| "#{CrystalClick::StreamName.hash(stream)}.mrk2" }.sort
  entries = Dir.children(part)
  actual_bins = entries.select(&.ends_with?(".bin")).sort
  actual_marks = entries.select(&.ends_with?(".mrk2")).sort
  raise "#{label}: physical bin inventory differs" unless actual_bins == expected_bins
  raise "#{label}: physical mark inventory differs" unless actual_marks == expected_marks
  streams.each do |stream|
    rows = w99o_mark_rows(part, stream)
    raise "#{label}: #{stream} mark rows differ: #{rows.inspect}" unless rows == W99O_MARK_ROWS
    path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
    actual = CrystalClick::CompressedBlock.decode_all(File.read(path).to_slice)
    expected = w99o_stream_expected(case_data, stream).to_slice
    raise "#{label}: #{stream} full physical bytes differ (#{actual.size} vs #{expected.size})" unless actual == expected
  end
  w99o_validate_serialization(case_data, part, source_allzero, label)
  puts "PASS #{label}: exact schema/substreams, full physical bytes and [2,2,1,0] marks"
  nil
end

def w99o_insert_input(case_data : W99OracleCase) : String
  w99o_expected_rowbinary(W99O_KEYS, case_data.columns, W99O_FULL_INDEXES)
end

def w99o_query_fields(case_data : W99OracleCase) : String
  (["pk"] + case_data.columns.map { |column| "payload.#{column.name}" }).join(", ")
end

def w99o_check_stock_sql(binary : String, store : String, table : String, case_data : W99OracleCase) : Nil
  full = w99o_clickhouse(binary, store, "SELECT #{w99o_query_fields(case_data)} FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  w99o_assert_bytes(full, w99o_expected_rowbinary(W99O_KEYS, case_data.columns, W99O_FULL_INDEXES), "#{table} complete stock RowBinary")
  selected = w99o_clickhouse(binary, store, "SELECT #{w99o_query_fields(case_data)} FROM default.#{table} WHERE pk >= 2 AND pk < 5 ORDER BY pk FORMAT RowBinary")
  w99o_assert_bytes(selected, w99o_expected_rowbinary(W99O_KEYS, case_data.columns, W99O_KEY_RANGE), "#{table} selected key-range RowBinary")
  puts "PASS #{table}: full and key-range RowBinary bytes"
  nil
end

def w99o_assert_data(data : CrystalClick::WideTupleColumnData, case_data : W99OracleCase, indexes : Array(Int32), label : String) : Nil
  raise "#{label}: Tuple type differs" unless data.type_name == case_data.type_name
  raise "#{label}: row count differs" unless data.row_count == indexes.size
  raise "#{label}: field order differs" unless data.fields.map { |field| {field.name, field.type_name} } == case_data.columns.map { |column| {column.name, column.type_name} }
  case_data.columns.each_with_index do |expected_column, field_index|
    actual_column = data.columns[field_index]
    indexes.each_with_index do |source_index, local_index|
      expected = w99o_leaf_disk_bytes(expected_column, source_index)
      actual = w99o_leaf_disk_bytes(actual_column, local_index)
      raise "#{label}: #{expected_column.name} raw identity/value differs at row #{source_index}" unless actual == expected
    end
  end
  nil
end

def w99o_append_batch(output : IO, batch : CrystalClick::WidePartTableBatch, case_data : W99OracleCase, expected_indexes : Array(Int32), label : String) : Nil
  keys = batch.values_for("pk")
  rows = batch.tuple_rows_for("payload")
  raise "#{label}: batch keys/rows differ in length" unless keys.size == rows.size
  keys.each_with_index do |key, index|
    source_index = (key - 1_u64).to_i32
    raise "#{label}: unexpected key #{key}" unless expected_indexes.includes?(source_index)
    row = rows[index]
    raise "#{label}: row schema differs" unless row.type_name == case_data.type_name
    case_data.columns.each do |column|
      expected_bytes = w99o_leaf_disk_bytes(column, source_index)
      actual_bytes = case column.type_name
                     when "String"
                       row.value_as(column.name, String)
                     when "Bool"
                       row.value_as(column.name, Bool) ? "\x01" : "\x00"
                     when "UInt64"
                       w99o_u64_le(row.value_as(column.name, UInt64))
                     when "UUID"
                       value = row.value_as(column.name, CrystalClick::UUIDValue)
                       w99o_u64_le(value.high) + w99o_u64_le(value.low)
                     when "IPv4"
                       w99o_u64_le(row.value_as(column.name, CrystalClick::IPv4Value).network_order.to_u64, 4)
                     when "IPv6"
                       w99o_ipv6_bytes(row.value_as(column.name, CrystalClick::IPv6Value))
                     else
                       raise "#{label}: no row encoder for #{column.type_name}"
                     end
      raise "#{label}: #{column.name} differs at key #{key}" unless actual_bytes == expected_bytes
    end
    output << w99o_u64_le(key) << w99o_rowbinary_payload(case_data.columns, source_index)
  end
  nil
end

def w99o_check_table_scans(part : String, case_data : W99OracleCase, label : String) : Nil
  table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])

  full = IO::Memory.new
  seen = [] of Int32
  table.scan_typed do |batch|
    w99o_append_batch(full, batch, case_data, W99O_FULL_INDEXES, "#{label} full scan")
    batch.values_for("pk").each { |key| seen << (key - 1_u64).to_i32 }
    nil
  end
  raise "#{label}: full scan indexes differ: #{seen.inspect}" unless seen == W99O_FULL_INDEXES
  w99o_assert_bytes(full.to_s, w99o_expected_rowbinary(W99O_KEYS, case_data.columns, W99O_FULL_INDEXES), "#{label} table full scan")

  window = IO::Memory.new
  window_seen = [] of Int32
  table.scan_typed_window(1_u64, 3) do |batch|
    w99o_append_batch(window, batch, case_data, W99O_WINDOW_INDEXES, "#{label} window")
    batch.values_for("pk").each { |key| window_seen << (key - 1_u64).to_i32 }
    nil
  end
  raise "#{label}: window indexes differ: #{window_seen.inspect}" unless window_seen == W99O_WINDOW_INDEXES
  w99o_assert_bytes(window.to_s, w99o_expected_rowbinary(W99O_KEYS, case_data.columns, W99O_WINDOW_INDEXES), "#{label} positional window")

  candidate = IO::Memory.new
  candidate_seen = [] of Int32
  table.scan_typed_candidate_marks([[0_i32, 2_i32]]) do |batch|
    w99o_append_batch(candidate, batch, case_data, W99O_CANDIDATE, "#{label} candidate marks")
    batch.values_for("pk").each { |key| candidate_seen << (key - 1_u64).to_i32 }
    nil
  end
  raise "#{label}: candidate mark indexes differ: #{candidate_seen.inspect}" unless candidate_seen == W99O_CANDIDATE
  w99o_assert_bytes(candidate.to_s, w99o_expected_rowbinary(W99O_KEYS, case_data.columns, W99O_CANDIDATE), "#{label} candidate marks")
  puts "PASS #{label}: complete table, positional-window and sparse-candidate semantic scans"
  nil
end

def w99o_prepare_catalog_root(root : String, part : String, type_name : String) : String
  database_uuid = "99000000-0000-4000-8000-000000000001"
  table_uuid = "99000000-0000-4000-8000-000000000002"
  metadata_path = File.join(root, "metadata")
  database_path = File.join(root, "store", database_uuid[0, 3], database_uuid)
  table_path = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(metadata_path)
  FileUtils.mkdir_p(database_path)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(metadata_path, "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  File.write(
    File.join(database_path, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `payload` #{type_name}\n)\nENGINE = MergeTree\nORDER BY pk\n"
  )
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  copied_part = File.join(table_path, "all_1_1_0")
  FileUtils.cp_r(part, copied_part)
  copied_part
end

def w99o_catalog_values(root : String, part : String, case_data : W99OracleCase, label : String) : Nil
  copied_part = w99o_prepare_catalog_root(root, part, case_data.type_name)
  catalog = CrystalClick::OfflineCatalog.open(root)
  table = catalog.table("lab", "events")
  parts = table.resolved_scan_parts
  raise "#{label}: catalog did not resolve exactly the copied part" unless parts.size == 1 && File.realpath(parts[0].path) == File.realpath(copied_part)
  values = table["payload"].values(max_tuple_cells: 1_000_u64)
  raise "#{label}: catalog value count differs" unless values.size == W99O_KEYS.size
  payload = IO::Memory.new
  values.each_with_index do |value, index|
    row = value.as(CrystalClick::WideTupleRow)
    raise "#{label}: catalog row type differs" unless row.type_name == case_data.type_name
    case_data.columns.each do |column|
      expected = w99o_leaf_disk_bytes(column, index.to_i32)
      actual = case column.type_name
               when "String"
                 row.value_as(column.name, String)
               when "Bool"
                 row.value_as(column.name, Bool) ? "\x01" : "\x00"
               when "UInt64"
                 w99o_u64_le(row.value_as(column.name, UInt64))
               when "UUID"
                 id = row.value_as(column.name, CrystalClick::UUIDValue)
                 w99o_u64_le(id.high) + w99o_u64_le(id.low)
               when "IPv4"
                 w99o_u64_le(row.value_as(column.name, CrystalClick::IPv4Value).network_order.to_u64, 4)
               when "IPv6"
                 w99o_ipv6_bytes(row.value_as(column.name, CrystalClick::IPv6Value))
               else
                 raise "#{label}: no catalog encoder for #{column.type_name}"
               end
      raise "#{label}: catalog #{column.name} differs at row #{index}" unless actual == expected
    end
    payload << w99o_rowbinary_payload(case_data.columns, index.to_i32)
  end
  w99o_assert_bytes(payload.to_s, w99o_expected_payload_rowbinary(case_data.columns, W99O_FULL_INDEXES), "#{label} catalog full values")

  scanned = IO::Memory.new
  table.scan_typed(["pk", "payload"]) do |batch|
    w99o_append_batch(scanned, batch, case_data, W99O_FULL_INDEXES, "#{label} catalog scan")
    nil
  end
  w99o_assert_bytes(scanned.to_s, w99o_expected_rowbinary(W99O_KEYS, case_data.columns, W99O_FULL_INDEXES), "#{label} catalog scan")

  window = IO::Memory.new
  table.scan_typed_window(["pk", "payload"], 1_u64, 3) do |batch|
    w99o_append_batch(window, batch, case_data, W99O_WINDOW_INDEXES, "#{label} catalog window")
    nil
  end
  w99o_assert_bytes(window.to_s, w99o_expected_rowbinary(W99O_KEYS, case_data.columns, W99O_WINDOW_INDEXES), "#{label} catalog positional window")
  puts "PASS #{label}: catalog materialization, scan and positional window"
  nil
end

def w99o_check_source_reader(part : String, case_data : W99OracleCase, label : String) : CrystalClick::WideTupleColumnData
  key_reader = CrystalClick::WidePart.open_typed(part, "pk")
  tuple_reader = CrystalClick::WidePart.open_typed(part, "payload")
  expected_mark_counts = [2_u64, 2_u64, 1_u64]
  raise "#{label}: key marks differ" unless key_reader.mark_row_counts == expected_mark_counts
  raise "#{label}: Tuple marks differ" unless tuple_reader.mark_row_counts == expected_mark_counts
  keys = key_reader.read_uint64_mark_range("pk", 0, key_reader.mark_count)
  data = tuple_reader.read_tuple_mark_range("payload", 0, tuple_reader.mark_count)
  w99o_assert_data(data, case_data, W99O_FULL_INDEXES, "#{label} full read")
  actual_full = String.build do |output|
    columns = data.columns
    keys.each_with_index do |key, index|
      output << w99o_u64_le(key)
      output << w99o_rowbinary_payload(columns, index.to_i32)
    end
  end
  w99o_assert_bytes(actual_full, w99o_expected_rowbinary(W99O_KEYS, case_data.columns, W99O_FULL_INDEXES), "#{label} stock-to-Crystal full read")

  # Physical mark range [1,3) selects source rows [2,3,4]; this intentionally
  # differs from the SQL key range [1,2,3] checked above.
  range_keys = key_reader.read_uint64_mark_range("pk", 1, 2)
  range_data = tuple_reader.read_tuple_mark_range("payload", 1, 2)
  w99o_assert_data(range_data, case_data, W99O_MARK_RANGE, "#{label} physical mark range")
  range = String.build do |output|
    columns = range_data.columns
    range_keys.each_with_index do |key, index|
      output << w99o_u64_le(key)
      output << w99o_rowbinary_payload(columns, index.to_i32)
    end
  end
  w99o_assert_bytes(range, w99o_expected_rowbinary(W99O_KEYS, case_data.columns, W99O_MARK_RANGE), "#{label} selected physical mark range")
  puts "PASS #{label}: stock -> Crystal full and independent selected physical mark range"
  data
end

def w99o_attach_writer(binary : String, store : String, case_data : W99OracleCase, part : String) : String
  table = case_data.writer_table
  w99o_create_table(binary, store, table, case_data.type_name, case_data.ratio)
  data_path = w99o_clickhouse(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  raise "#{table}: stock did not return data path" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  w99o_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  attached = File.join(data_path, "all_1_1_0")
  w99o_check_table(binary, store, table, attached)
  w99o_columns_schema(binary, store, table, case_data.type_name)
  attached
end

def w99o_check_writer_reader(part : String, case_data : W99OracleCase, label : String) : Nil
  data = CrystalClick::WidePart.open_typed(part, "payload").read_tuple_mark_range("payload", 0, CrystalClick::WidePart.open_typed(part, "payload").mark_count)
  w99o_assert_data(data, case_data, W99O_FULL_INDEXES, "#{label} writer read")
  keys = CrystalClick::WidePart.open_typed(part, "pk").read_uint64_mark_range("pk", 0, 3)
  rowbinary = String.build do |output|
    columns = data.columns
    keys.each_with_index do |key, index|
      output << w99o_u64_le(key)
      output << w99o_rowbinary_payload(columns, index.to_i32)
    end
  end
  w99o_assert_bytes(rowbinary, w99o_expected_rowbinary(W99O_KEYS, case_data.columns, W99O_FULL_INDEXES), "#{label} writer -> Crystal")
  key_reader = CrystalClick::WidePart.open_typed(part, "pk")
  tuple_reader = CrystalClick::WidePart.open_typed(part, "payload")
  keys_range = key_reader.read_uint64_mark_range("pk", 1, 2)
  data_range = tuple_reader.read_tuple_mark_range("payload", 1, 2)
  w99o_assert_data(data_range, case_data, W99O_MARK_RANGE, "#{label} writer mark range")
  actual_range = String.build do |output|
    columns = data_range.columns
    keys_range.each_with_index do |key, index|
      output << w99o_u64_le(key)
      output << w99o_rowbinary_payload(columns, index.to_i32)
    end
  end
  w99o_assert_bytes(actual_range, w99o_expected_rowbinary(W99O_KEYS, case_data.columns, W99O_MARK_RANGE), "#{label} writer selected physical range")
  puts "PASS #{label}: writer -> Crystal full and mark-range reads"
  nil
end

def w99o_catalog_root(base : String, label : String) : String
  root = File.join(base, label)
  FileUtils.mkdir_p(root)
  root
end

def w99o_cases : Array(W99OracleCase)
  ipv6 = [
    CrystalClick::IPv6Value.new(0x20010db885a30000_u64, 0x00008a2e03707334_u64),
    CrystalClick::IPv6Value.new(0xfedcba9876543210_u64, 0x0123456789abcdef_u64),
    CrystalClick::IPv6Value.new(0_u64, 0_u64),
    CrystalClick::IPv6Value.new(UInt64::MAX, 0x0102030405060708_u64),
    CrystalClick::IPv6Value.new(0x8000000000000000_u64, 0xffff000000000001_u64),
  ]
  ipv4 = [
    CrystalClick::IPv4Value.from_octets(1_u8, 2_u8, 3_u8, 4_u8),
    CrystalClick::IPv4Value.from_octets(4_u8, 3_u8, 2_u8, 1_u8),
    CrystalClick::IPv4Value.from_octets(0_u8, 0_u8, 0_u8, 0_u8),
    CrystalClick::IPv4Value.from_octets(255_u8, 255_u8, 255_u8, 255_u8),
    CrystalClick::IPv4Value.from_octets(192_u8, 168_u8, 1_u8, 7_u8),
  ]
  uuid = [
    CrystalClick::UUIDValue.new(0x0011223344556677_u64, 0x8899aabbccddeeff_u64),
    CrystalClick::UUIDValue.new(UInt64::MAX, 0_u64),
    CrystalClick::UUIDValue.new(0_u64, 0_u64),
    CrystalClick::UUIDValue.new(0x0123456789abcdef_u64, 0xfedcba9876543210_u64),
    CrystalClick::UUIDValue.new(0x7f00ff01fe02fd03_u64, 0x04fc05fb06fa07f9_u64),
  ]
  mixed = [
    CrystalClick::WideTupleLeafColumn.new("v6", ipv6),
    CrystalClick::WideTupleLeafColumn.new("count", [10_u64, 20_u64, 30_u64, 40_u64, 50_u64]),
    CrystalClick::WideTupleLeafColumn.new("v4", ipv4),
    CrystalClick::WideTupleLeafColumn.new("id", uuid),
    CrystalClick::WideTupleLeafColumn.new("flag", [false, true, false, true, true]),
    CrystalClick::WideTupleLeafColumn.new("text", ["alpha", String.new(Bytes[0x62_u8, 0x00_u8, 0xff_u8]), "", "delta", "epsilon"]),
    CrystalClick::WideTupleLeafColumn.new("id_again", uuid),
    CrystalClick::WideTupleLeafColumn.new("v6_again", ipv6),
    CrystalClick::WideTupleLeafColumn.new("v4_again", ipv4),
  ] of CrystalClick::WideTupleLeafColumn
  identifier_only = [mixed[3].owned_copy, mixed[2].owned_copy, mixed[0].owned_copy] of CrystalClick::WideTupleLeafColumn
  all_default = [
    CrystalClick::WideTupleLeafColumn.new("id", Array.new(5) { CrystalClick::UUIDValue.new(0_u64, 0_u64) }),
    CrystalClick::WideTupleLeafColumn.new("v4", Array.new(5) { CrystalClick::IPv4Value.new(0_u32) }),
    CrystalClick::WideTupleLeafColumn.new("v6", Array.new(5) { CrystalClick::IPv6Value.new(0_u64, 0_u64) }),
  ] of CrystalClick::WideTupleLeafColumn
  [
    W99OracleCase.new("mixed", mixed),
    W99OracleCase.new("identifier_only", identifier_only),
    W99OracleCase.new("all_default", all_default, "1.0"),
  ] of W99OracleCase
end

binary = ENV["CLICKHOUSE_BIN"]? || raise "set CLICKHOUSE_BIN to pinned ClickHouse 26.7.1.1315"
store = ENV["IDENTIFIER_TUPLE_STORE"]? || raise "set IDENTIFIER_TUPLE_STORE to a fresh temporary ClickHouse store"
writer_root = ENV["IDENTIFIER_TUPLE_WRITER_ROOT"]? || raise "set IDENTIFIER_TUPLE_WRITER_ROOT to an empty temporary directory"
catalog_root = ENV["IDENTIFIER_TUPLE_CATALOG_ROOT"]? || raise "set IDENTIFIER_TUPLE_CATALOG_ROOT to an empty temporary directory"
unless store.starts_with?("/private/tmp/") || store.starts_with?("/tmp/")
  raise "refusing non-temporary ClickHouse store path: #{store}"
end
raise "ClickHouse store must be empty" unless Dir.exists?(store) && Dir.empty?(store)
FileUtils.mkdir_p(writer_root)
FileUtils.mkdir_p(catalog_root)

version = IO::Memory.new
version_status = Process.run(binary, ["local", "--version"], output: version)
raise "cannot inspect pinned ClickHouse version" unless version_status.success?
expected_version = "ClickHouse local version #{W99O_VERSION} (official build)."
raise "expected #{expected_version}, got #{version.to_s.strip}" unless version.to_s.strip == expected_version
puts "Stock oracle: #{version.to_s.strip}"

cases = w99o_cases
expected_names = ["mixed", "identifier_only", "all_default"]
raise "W99 fixture matrix changed" unless cases.map(&.label) == expected_names
source_parts = {} of String => String

cases.each do |case_data|
  w99o_create_table(binary, store, case_data.source_table, case_data.type_name, case_data.ratio)
  w99o_insert_rowbinary(binary, store, case_data.source_table, w99o_insert_input(case_data))
  source_part = w99o_part_path(binary, store, case_data.source_table)
  source_parts[case_data.label] = source_part
  w99o_columns_schema(binary, store, case_data.source_table, case_data.type_name)
  w99o_assert_layout(case_data, source_part, case_data.label == "all_default", "stock source #{case_data.label}")
  w99o_check_table(binary, store, case_data.source_table, source_part)
  w99o_check_stock_sql(binary, store, case_data.source_table, case_data)
  w99o_seeded_wrong_byte_rejected(
    w99o_clickhouse(binary, store, "SELECT #{w99o_query_fields(case_data)} FROM default.#{case_data.source_table} ORDER BY pk FORMAT RowBinary"),
    w99o_expected_rowbinary(W99O_KEYS, case_data.columns, W99O_FULL_INDEXES),
    "stock #{case_data.label} RowBinary comparator"
  ) if case_data.label == "mixed"

  source_data = w99o_check_source_reader(source_part, case_data, "stock source #{case_data.label}")
  w99o_check_table_scans(source_part, case_data, "stock source #{case_data.label}")
  source_catalog_root = w99o_catalog_root(catalog_root, "source_#{case_data.label}")
  w99o_catalog_values(source_catalog_root, source_part, case_data, "stock source #{case_data.label}")

  writer_part = File.join(writer_root, case_data.label, "all_1_1_0")
  FileUtils.mkdir_p(File.dirname(writer_part))
  key_reader = CrystalClick::WidePart.open_typed(source_part, "pk")
  actual_stock_keys = key_reader.read_uint64_mark_range("pk", 0, key_reader.mark_count)
  actual_stock_columns = source_data.columns
  CrystalClick::WidePartWriter.write_uint64_tuple_pair(
    writer_part,
    "pk",
    actual_stock_keys.to_unsafe.to_slice(actual_stock_keys.size),
    "payload",
    case_data.type_name,
    actual_stock_columns,
    rows_per_mark: 2
  )
  w99o_assert_layout(case_data, writer_part, false, "Crystal writer #{case_data.label}")
  w99o_check_writer_reader(writer_part, case_data, "Crystal writer #{case_data.label}")

  attached = w99o_attach_writer(binary, store, case_data, writer_part)
  w99o_assert_layout(case_data, attached, false, "attached Crystal writer #{case_data.label}")
  w99o_check_stock_sql(binary, store, case_data.writer_table, case_data)
  w99o_check_table_scans(attached, case_data, "attached Crystal writer #{case_data.label}")
  writer_catalog_root = w99o_catalog_root(catalog_root, "writer_#{case_data.label}")
  w99o_catalog_values(writer_catalog_root, attached, case_data, "attached Crystal writer #{case_data.label}")
  puts "PASS W99 bidirectional profile #{case_data.label}: source stock -> Crystal reader/writer -> stock ATTACH/CHECK -> both high-level consumers"
end

puts "PASS identifier Tuple bidirectional stock oracle: UUID/IPv4/IPv6 mixed/reordered/repeated, identifier-only, allzero, exact physical streams, full and selected RowBinary, marks, table scans, catalogs and ATTACH/CHECK"
