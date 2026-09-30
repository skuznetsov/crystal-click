require "json"
require "file_utils"
require "../src/crystal_click"

struct W97BoolField
  getter name : String
  getter type_name : String

  def initialize(@name : String, @type_name : String)
  end
end

class W97BoolOracleMismatch < Exception
end

W97_STOCK_VERSION = "26.7.1.1315"
W97_ROW_COUNT     = 257
W97_KEYS          = Array(UInt64).new(W97_ROW_COUNT) { |index| index.to_u64 + 1_u64 }
W97_CODES         = Array(UInt8).new(W97_ROW_COUNT) { |index| (index % 256).to_u8 }
W97_BYTES         = W97_CODES.map { |code| code ^ 0xa5_u8 }
W97_STRINGS       = Array(String).new(W97_ROW_COUNT) do |index|
  code = W97_CODES[index]
  if index % 5 == 0
    ""
  else
    String.new(Bytes[0x77_u8, code, 0x00_u8, 0xff_u8])
  end
end
W97_MARK_ROWS      = Array.new(128, 2_u64) + [1_u64]
W97_MARK_FILE_ROWS = W97_MARK_ROWS + [0_u64]
W97_MIXED_FIELDS   = [W97BoolField.new("flag", "Bool"), W97BoolField.new("byte", "UInt8"), W97BoolField.new("text", "String")]
W97_MIXED_TYPE     = "Tuple(flag Bool, byte UInt8, text String)"
W97_BOOL_ONLY_TYPE = "Tuple(flag Bool)"

def w97_append_u64_le(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
end

def w97_append_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

def w97_append_string(io : IO, value : String) : Nil
  w97_append_varuint(io, value.bytesize.to_u64)
  io.write(value.to_slice)
end

# Independent RowBinary encoder: a UInt64 key, one Bool storage byte, one
# UInt8, and one RowBinary String. Stock expectations pass original Bool bytes;
# writer expectations pass canonical 0/1 bytes explicitly.
def w97_expected_rowbinary(
  keys : Array(UInt64),
  bool_bytes : Array(UInt8),
  byte_values : Array(UInt8),
  strings : Array(String),
  include_keys : Bool = true,
) : Bytes
  raise "W97 expected RowBinary fixture lengths differ" unless keys.size == bool_bytes.size && keys.size == byte_values.size && keys.size == strings.size
  output = IO::Memory.new
  keys.each_index do |index|
    w97_append_u64_le(output, keys[index]) if include_keys
    output.write_byte(bool_bytes[index])
    output.write_byte(byte_values[index])
    w97_append_string(output, strings[index])
  end
  output.to_slice.dup
end

def w97_expected_bool_only(keys : Array(UInt64), bool_bytes : Array(UInt8)) : Bytes
  raise "W97 Bool-only fixture lengths differ" unless keys.size == bool_bytes.size
  output = IO::Memory.new
  keys.each_index do |index|
    w97_append_u64_le(output, keys[index])
    output.write_byte(bool_bytes[index])
  end
  output.to_slice.dup
end

def w97_flags(codes : Array(UInt8)) : Array(Bool)
  codes.map { |code| code != 0_u8 }
end

def w97_canonical_bool_bytes(flags : Array(Bool)) : Array(UInt8)
  flags.map { |value| value ? 1_u8 : 0_u8 }
end

def w97_columns(flags : Array(Bool), bytes : Array(UInt8), strings : Array(String)) : Array(CrystalClick::WideTupleLeafColumn)
  [
    CrystalClick::WideTupleLeafColumn.new("flag", flags),
    CrystalClick::WideTupleLeafColumn.new("byte", bytes),
    CrystalClick::WideTupleLeafColumn.new("text", strings),
  ] of CrystalClick::WideTupleLeafColumn
end

def w97_type_name(fields : Array(W97BoolField)) : String
  "Tuple(#{fields.map { |field| "#{field.name} #{field.type_name}" }.join(", ")})"
end

def w97_attempt_clickhouse(binary : String, store : String, query : String, input : Bytes? = nil) : {Bool, String, String}
  output = IO::Memory.new
  error = IO::Memory.new
  status = if bytes = input
             source = IO::Memory.new
             source.write(bytes)
             source.rewind
             Process.run(binary, ["local", "--path", store, "--query", query], input: source, output: output, error: error)
           else
             Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: error)
           end
  {status.success?, output.to_s, error.to_s}
end

def w97_run_clickhouse(binary : String, store : String, query : String) : String
  succeeded, output, error = w97_attempt_clickhouse(binary, store, query)
  raise "ClickHouse query failed: #{error}\n#{query}" unless succeeded
  output
end

def w97_run_clickhouse_input(binary : String, store : String, query : String, bytes : Bytes) : Nil
  succeeded, _output, error = w97_attempt_clickhouse(binary, store, query, bytes)
  raise "ClickHouse RowBinary INSERT failed: #{error}\n#{query}" unless succeeded
  nil
end

def w97_table_sql(table : String, type_name : String, ratio_of_defaults : String = "0.9375") : String
  <<-SQL
  CREATE TABLE default.#{table}
  (
      pk UInt64,
      payload #{type_name}
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
      ratio_of_defaults_for_sparse_serialization = #{ratio_of_defaults}
  SQL
end

def w97_create_table(binary : String, store : String, table : String, type_name : String, ratio_of_defaults : String = "0.9375") : Nil
  w97_run_clickhouse(binary, store, w97_table_sql(table, type_name, ratio_of_defaults))
end

def w97_active_part_path(binary : String, store : String, table : String) : String
  paths = w97_run_clickhouse(binary, store, "SELECT path FROM system.parts WHERE database = 'default' AND table = '#{table}' AND active FORMAT TSVRaw").lines.map(&.strip).reject(&.empty?)
  raise "#{table}: expected one active part, got #{paths.inspect}" unless paths.size == 1
  paths.first
end

def w97_insert_mixed(binary : String, store : String, table : String, codes : Array(UInt8), byte_values : Array(UInt8), strings : Array(String), keys : Array(UInt64) = W97_KEYS) : Nil
  w97_run_clickhouse_input(binary, store, "INSERT INTO default.#{table} FORMAT RowBinary", w97_expected_rowbinary(keys, codes, byte_values, strings))
end

def w97_insert_bool_only(binary : String, store : String, table : String, keys : Array(UInt64), codes : Array(UInt8)) : Nil
  w97_run_clickhouse_input(binary, store, "INSERT INTO default.#{table} FORMAT RowBinary", w97_expected_bool_only(keys, codes))
end

def w97_run_query_rowbinary(binary : String, store : String, table : String, columns : Array(String), keys : Array(UInt64) = W97_KEYS) : Bytes
  where_clause = keys.size == W97_KEYS.size && keys == W97_KEYS ? "" : " WHERE pk IN (#{keys.join(", ")})"
  selected = (["pk"] + columns.map { |column| "payload.#{column}" }).join(", ")
  w97_run_clickhouse(binary, store, "SELECT #{selected} FROM default.#{table}#{where_clause} ORDER BY pk FORMAT RowBinary").to_slice.dup
end

def w97_write_hash(io : IO, hash : {UInt64, UInt64}) : Nil
  w97_append_u64_le(io, hash[0])
  w97_append_u64_le(io, hash[1])
end

def w97_read_u64(bytes : Bytes, offset : Int) : UInt64
  8.times.reduce(0_u64) { |value, index| value | (bytes[offset + index].to_u64 << (index * 8)) }
end

def w97_mark_rows(bytes : Bytes, label : String) : Array(UInt64)
  mark_size = CrystalClick::WidePart::MARK_SIZE
  raise "#{label}: partial mark record" unless bytes.size % mark_size == 0
  Array.new(bytes.size // mark_size) do |index|
    w97_read_u64(bytes, index * mark_size + 16)
  end
end

def w97_expected_streams(fields : Array(W97BoolField)) : Array(String)
  streams = ["pk"] of String
  fields.each do |field|
    name = "payload%2E#{field.name}"
    streams << "#{name}.size" if field.type_name == "String"
    streams << name
  end
  streams
end

def w97_expected_substreams(fields : Array(W97BoolField)) : String
  streams = w97_expected_streams(fields)
  payload_streams = streams[1..]
  [
    "columns substreams version: 1",
    "2 columns:",
    "1 substreams for column `pk`:",
    "\tpk",
    "#{payload_streams.size} substreams for column `payload`:",
    *payload_streams.map { |name| "\t#{name}" },
  ].join("\n") + "\n"
end

def w97_assert_serialization(path : String, fields : Array(W97BoolField), rows : Int32, label : String, always_default : Bool = false) : Nil
  info = JSON.parse(File.read(File.join(path, "serialization.json"))).as_h
  raise "#{label}: serialization version differs" unless info["version"]?.try(&.as_i) == 1
  raise "#{label}: nested type-version propagation differs" unless info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool) == true
  versions = info["types_serialization_versions"]?.try(&.as_h) || raise "#{label}: type serialization version map missing"
  if fields.any? { |field| field.type_name == "String" }
    raise "#{label}: expected exact String serialization version" unless versions.size == 1 && versions["string"]?.try(&.as_i) == 1
  end

  records = info["columns"]?.try(&.as_a) || raise "#{label}: Default serializer records missing"
  if always_default
    raise "#{label}: AlwaysDefault profile unexpectedly has serialization records" unless records.empty?
  else
    names = records.map { |record| record.as_h["name"].as_s }
    raise "#{label}: Default serializer record names differ: #{names.inspect}" unless names == ["payload", "pk"]
  end

  records.each do |record|
    entry = record.as_h
    raise "#{label}: unexpected serializer kind" unless entry["kind"]?.try(&.as_s) == "Default"
    raise "#{label}: serializer row count differs" unless entry["num_rows"]?.try(&.as_i) == rows
    defaults = entry["num_defaults"]?.try(&.as_i) || raise "#{label}: default count missing"
    raise "#{label}: default count outside row count" unless defaults >= 0 && defaults <= rows
    next unless entry["name"]?.try(&.as_s) == "payload"
    children = entry["subcolumns"]?.try(&.as_a) || raise "#{label}: Tuple child serializer metadata missing"
    raise "#{label}: Tuple serializer child count differs" unless children.size == fields.size
    children.each do |child|
      child_entry = child.as_h
      raise "#{label}: child serializer kind differs" unless child_entry["kind"]?.try(&.as_s) == "Default"
      raise "#{label}: child serializer row count differs" unless child_entry["num_rows"]?.try(&.as_i) == rows
      child_defaults = child_entry["num_defaults"]?.try(&.as_i) || raise "#{label}: child default count missing"
      raise "#{label}: child default count outside row count" unless child_defaults >= 0 && child_defaults <= rows
    end
  end
  nil
end

def w97_assert_physical(path : String, type_name : String, fields : Array(W97BoolField), rows : Int32, mark_rows : Array(UInt64), label : String, always_default : Bool = false) : Nil
  columns = File.read(File.join(path, "columns.txt")).lines.map(&.strip)
  expected_columns = ["columns format version: 1", "2 columns:", "`pk` UInt64", "`payload` #{type_name}"]
  raise "#{label}: columns.txt differs: #{columns.inspect}" unless columns == expected_columns
  substreams = File.read(File.join(path, "columns_substreams.txt"))
  raise "#{label}: columns_substreams.txt differs:\n#{substreams}" unless substreams == w97_expected_substreams(fields)

  streams = w97_expected_streams(fields)
  bases = streams.map { |name| CrystalClick::StreamName.hash(name) }
  expected_bins = bases.map { |base| "#{base}.bin" }.sort
  expected_marks = bases.map { |base| "#{base}.mrk2" }.sort
  children = Dir.children(path)
  actual_bins = children.select(&.ends_with?(".bin")).sort
  actual_marks = children.select(&.ends_with?(".mrk2")).sort
  raise "#{label}: .bin inventory differs: #{actual_bins.inspect}" unless actual_bins == expected_bins
  raise "#{label}: .mrk2 inventory differs: #{actual_marks.inspect}" unless actual_marks == expected_marks
  streams.each do |stream|
    base = CrystalClick::StreamName.hash(stream)
    observed = w97_mark_rows(File.read(File.join(path, "#{base}.mrk2")).to_slice, "#{label} #{stream}")
    raise "#{label}: #{stream} mark rows differ: #{observed.inspect}" unless observed == mark_rows
  end
  w97_assert_serialization(path, fields, rows, label, always_default)
  nil
end

def w97_decompressed_stream(path : String, stream : String) : Bytes
  file = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
  file.empty? ? Bytes.empty : CrystalClick::CompressedBlock.decode_all(file).to_slice.dup
end

def w97_assert_bytes(actual : Bytes, expected : Bytes, label : String) : Nil
  return nil if actual == expected
  offset = 0
  limit = {actual.size, expected.size}.min
  while offset < limit && actual[offset] == expected[offset]
    offset += 1
  end
  raise W97BoolOracleMismatch.new("#{label}: byte mismatch at #{offset} (actual=#{actual.size}, expected=#{expected.size})")
end

def w97_qualify_byte_comparator(expected : Bytes) : Nil
  raise "W97 seeded-byte sensitivity fixture is empty" if expected.empty?
  seeded_wrong = expected.dup
  seeded_wrong[seeded_wrong.size // 2] ^= 1_u8
  rejected = false
  begin
    w97_assert_bytes(seeded_wrong, expected, "seeded wrong-byte comparator")
  rescue W97BoolOracleMismatch
    rejected = true
  end
  raise "W97 exact-byte oracle accepted a deliberately changed byte" unless rejected
  puts "PASS seeded wrong-byte sensitivity: exact comparison rejects a modified expected byte"
  nil
end

def w97_check_table(binary : String, store : String, table : String, part : String) : Nil
  actual = w97_run_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  expected = "#{File.basename(part.chomp("/"))}\t1"
  raise "#{table}: CHECK TABLE differs: #{actual.inspect}" unless actual == expected
  nil
end

def w97_assert_stock_truth(binary : String, store : String, table : String, codes : Array(UInt8), label : String) : Nil
  output = w97_run_clickhouse(binary, store, "SELECT if(payload.flag, 1, 0) FROM default.#{table} ORDER BY pk FORMAT TabSeparatedRaw")
  expected = codes.map { |code| code == 0_u8 ? "0\n" : "1\n" }.join
  raise "#{label}: stock Bool logical truth differs" unless output == expected
  nil
end

def w97_leaf_columns_for_rows(flags : Array(Bool), bytes : Array(UInt8), strings : Array(String)) : Array(CrystalClick::WideTupleLeafColumn)
  w97_columns(flags, bytes, strings)
end

def w97_actual_tuple_rowbinary(keys : Slice(UInt64), rows : Slice(CrystalClick::WideTupleRow)) : Bytes
  output = IO::Memory.new
  raise "W97 table batch key/row count differs" unless keys.size == rows.size
  keys.each_with_index do |key, index|
    row = rows[index]
    w97_append_u64_le(output, key)
    output.write_byte(row.value_as("flag", Bool) ? 1_u8 : 0_u8)
    output.write_byte(row.value_as("byte", UInt8))
    w97_append_string(output, row.value_as("text", String))
  end
  output.to_slice.dup
end

def w97_check_table_consumers(store : String, part : String, table_name : String, expected_raw_codes : Array(UInt8), byte_values : Array(UInt8), strings : Array(String), label : String) : Nil
  canonical = w97_canonical_bool_bytes(w97_flags(expected_raw_codes))
  expected = w97_expected_rowbinary(W97_KEYS, canonical, byte_values, strings)
  table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])

  full = IO::Memory.new
  table.scan_typed do |batch|
    full.write(w97_actual_tuple_rowbinary(batch.values_for("pk"), batch.tuple_rows_for("payload")))
    nil
  end
  w97_assert_bytes(full.to_slice, expected, "#{label}: normalized full typed scan")

  window = IO::Memory.new
  table.scan_typed_window(100_u64, 5) do |batch|
    window.write(w97_actual_tuple_rowbinary(batch.values_for("pk"), batch.tuple_rows_for("payload")))
    nil
  end
  w97_assert_bytes(window.to_slice, w97_expected_rowbinary(W97_KEYS[100, 5], canonical[100, 5], byte_values[100, 5], strings[100, 5]), "#{label}: typed row window")

  sparse_indexes = [0, 1, 256] of Int32
  sparse = IO::Memory.new
  table.scan_typed_candidate_marks([[0_i32, 128_i32]]) do |batch|
    sparse.write(w97_actual_tuple_rowbinary(batch.values_for("pk"), batch.tuple_rows_for("payload")))
    nil
  end
  w97_assert_bytes(
    sparse.to_slice,
    w97_expected_rowbinary(
      sparse_indexes.map { |index| W97_KEYS[index] },
      sparse_indexes.map { |index| canonical[index] },
      sparse_indexes.map { |index| byte_values[index] },
      sparse_indexes.map { |index| strings[index] }
    ),
    "#{label}: sparse candidate scan"
  )

  catalog_table = CrystalClick::OfflineCatalog.open(store).table("default", table_name)
  candidates = catalog_table.resolved_scan_parts
  raise "#{label}: catalog did not resolve the intended part" unless candidates.size == 1 && File.realpath(candidates[0].path) == File.realpath(part)
  values = catalog_table["payload"].values
  catalog_bytes = IO::Memory.new
  values.each do |value|
    row = value.as(CrystalClick::WideTupleRow)
    # Catalog values contain payload only, unlike the table's RowBinary query.
    catalog_bytes.write_byte(row.value_as("flag", Bool) ? 1_u8 : 0_u8)
    catalog_bytes.write_byte(row.value_as("byte", UInt8))
    w97_append_string(catalog_bytes, row.value_as("text", String))
  end
  expected_payload = IO::Memory.new
  W97_ROW_COUNT.times do |index|
    expected_payload.write_byte(canonical[index])
    expected_payload.write_byte(byte_values[index])
    w97_append_string(expected_payload, strings[index])
  end
  w97_assert_bytes(catalog_bytes.to_slice, expected_payload.to_slice, "#{label}: catalog payload values")
  nil
end

def w97_check_low_level(part : String, codes : Array(UInt8), byte_values : Array(UInt8), strings : Array(String), label : String) : Nil
  reader = CrystalClick::WidePart.open_typed(part, "payload")
  raise "#{label}: mark row schedule differs: #{reader.mark_row_counts.inspect}" unless reader.mark_row_counts == W97_MARK_ROWS
  all = reader.read_tuple_mark_range("payload", 0, reader.mark_count)
  raise "#{label}: schema identity differs" unless all.type_name == W97_MIXED_TYPE
  raise "#{label}: row count differs" unless all.row_count == W97_ROW_COUNT
  W97_ROW_COUNT.times do |index|
    expected_code = codes[index]
    raise "#{label}: Bool semantic mismatch at row #{index}" unless all.value_as("flag", index, Bool) == (expected_code != 0_u8)
    raise "#{label}: UInt8 mismatch at row #{index}" unless all.value_as("byte", index, UInt8) == byte_values[index]
    raise "#{label}: String mismatch at row #{index}" unless all.value_as("text", index, String) == strings[index]
  end

  tail = reader.read_tuple_mark_range("payload", 127, 2)
  raise "#{label}: final two-mark range row count differs" unless tail.row_count == 3
  [254, 255, 256].each_with_index do |global_index, local_index|
    raise "#{label}: selected Bool range mismatch" unless tail.value_as("flag", local_index, Bool) == (codes[global_index] != 0_u8)
  end
  nil
end

def w97_attach_writer_part(binary : String, store : String, table : String, part : String, type_name : String) : String
  w97_create_table(binary, store, table, type_name)
  data_path = w97_run_clickhouse(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database = 'default' AND name = '#{table}' FORMAT TSVRaw").strip
  raise "#{table}: ClickHouse returned no data path" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  w97_run_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  w97_active_part_path(binary, store, table)
end

def w97_check_mixed_stock(binary : String, store : String) : String
  table = "w97_stock_all_bool_codes"
  w97_create_table(binary, store, table, W97_MIXED_TYPE)
  w97_insert_mixed(binary, store, table, W97_CODES, W97_BYTES, W97_STRINGS)
  part = w97_active_part_path(binary, store, table)
  w97_assert_physical(part, W97_MIXED_TYPE, W97_MIXED_FIELDS, W97_ROW_COUNT, W97_MARK_FILE_ROWS, "stock mixed all-byte-domain")
  w97_check_table(binary, store, table, part)

  flag_stream = w97_decompressed_stream(part, "payload%2Eflag")
  w97_assert_bytes(flag_stream, W97_CODES.to_unsafe.to_slice(W97_CODES.size), "stock Bool physical stream must preserve every inserted byte")
  stock = w97_run_clickhouse(binary, store, "SELECT pk, payload.flag, payload.byte, payload.text FROM default.#{table} ORDER BY pk FORMAT RowBinary").to_slice
  w97_assert_bytes(stock, w97_expected_rowbinary(W97_KEYS, W97_CODES, W97_BYTES, W97_STRINGS), "stock raw RowBinary roundtrip 0x00..0xff and terminal short row")
  selected_keys = [W97_KEYS[254], W97_KEYS[255], W97_KEYS[256]]
  selected = w97_run_clickhouse(binary, store, "SELECT pk, payload.flag, payload.byte, payload.text FROM default.#{table} WHERE pk IN (#{selected_keys.join(", ")}) ORDER BY pk FORMAT RowBinary").to_slice
  w97_assert_bytes(selected, w97_expected_rowbinary(selected_keys, W97_CODES[254, 3], W97_BYTES[254, 3], W97_STRINGS[254, 3]), "stock selected raw RowBinary tail")
  w97_assert_stock_truth(binary, store, table, W97_CODES, "stock all-byte Bool")
  w97_check_low_level(part, W97_CODES, W97_BYTES, W97_STRINGS, "stock mixed all-byte-domain")
  w97_check_table_consumers(store, part, table, W97_CODES, W97_BYTES, W97_STRINGS, "stock mixed all-byte-domain")
  puts "PASS stock mixed Bool Tuple: physical and RowBinary preserve all 256 byte values; typed consumers normalize zero/nonzero semantics"
  part
end

def w97_check_writer_mixed(binary : String, store : String, stock_part : String) : String
  stock_keys_reader = CrystalClick::WidePart.open_typed(stock_part, "pk")
  stock_reader = CrystalClick::WidePart.open_typed(stock_part, "payload")
  keys = stock_keys_reader.read_uint64_mark_range("pk", 0, stock_keys_reader.mark_count)
  stock_data = stock_reader.read_tuple_mark_range("payload", 0, stock_reader.mark_count)
  raise "writer source Stock keys differ from independent fixture" unless keys == W97_KEYS
  flags = Array(Bool).new(stock_data.row_count) { |index| stock_data.value_as("flag", index, Bool) }
  bytes = Array(UInt8).new(stock_data.row_count) { |index| stock_data.value_as("byte", index, UInt8) }
  strings = Array(String).new(stock_data.row_count) { |index| stock_data.value_as("text", index, String) }
  flags.each_with_index do |flag, index|
    raise "writer source Stock Bool normalization differs at row #{index}" unless flag == (W97_CODES[index] != 0_u8)
  end
  columns = w97_leaf_columns_for_rows(flags, bytes, strings)
  writer_root = ENV.fetch("TUPLE_WRITER_ROOT")
  part = File.join(writer_root, "mixed_bool_all_byte_domain")
  CrystalClick::WidePartWriter.write_uint64_tuple_pair(
    part,
    "pk",
    keys.to_unsafe.to_slice(keys.size),
    "payload",
    W97_MIXED_TYPE,
    columns,
    rows_per_mark: 2
  )
  table = "w97_writer_mixed_bool_all_byte_codes"
  attached = w97_attach_writer_part(binary, store, table, part, W97_MIXED_TYPE)
  w97_assert_physical(attached, W97_MIXED_TYPE, W97_MIXED_FIELDS, W97_ROW_COUNT, W97_MARK_FILE_ROWS, "writer mixed all-byte-domain")
  w97_check_table(binary, store, table, attached)

  canonical = w97_canonical_bool_bytes(w97_flags(W97_CODES))
  physical_flags = w97_decompressed_stream(attached, "payload%2Eflag")
  w97_assert_bytes(physical_flags, canonical.to_unsafe.to_slice(canonical.size), "writer Bool physical stream must be canonical 0/1")
  stock = w97_run_clickhouse(binary, store, "SELECT pk, payload.flag, payload.byte, payload.text FROM default.#{table} ORDER BY pk FORMAT RowBinary").to_slice
  w97_assert_bytes(stock, w97_expected_rowbinary(W97_KEYS, canonical, W97_BYTES, W97_STRINGS), "writer -> stock canonical RowBinary after stock raw-byte normalization")
  w97_assert_stock_truth(binary, store, table, W97_CODES, "writer normalized Bool")
  w97_check_low_level(attached, canonical, W97_BYTES, W97_STRINGS, "writer attached mixed")
  w97_check_table_consumers(store, attached, table, canonical, W97_BYTES, W97_STRINGS, "writer attached mixed")
  puts "PASS writer mixed Bool Tuple: owned Bool inputs serialize canonically, then stock ATTACH/CHECK and all typed consumer paths pass"
  attached
end

def w97_check_bool_only(binary : String, store : String) : Nil
  keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
  codes = [0_u8, 1_u8, 0_u8, 1_u8, 1_u8]
  fields = [W97BoolField.new("flag", "Bool")]
  table = "w97_stock_bool_only"
  w97_create_table(binary, store, table, W97_BOOL_ONLY_TYPE)
  w97_insert_bool_only(binary, store, table, keys, codes)
  part = w97_active_part_path(binary, store, table)
  w97_assert_physical(part, W97_BOOL_ONLY_TYPE, fields, keys.size.to_i32, [2_u64, 2_u64, 1_u64, 0_u64], "stock Bool-only")
  w97_check_table(binary, store, table, part)
  w97_assert_bytes(w97_decompressed_stream(part, "payload%2Eflag"), codes.to_unsafe.to_slice(codes.size), "Bool-only stock physical bytes")
  rowbinary = w97_run_clickhouse(binary, store, "SELECT pk, payload.flag FROM default.#{table} ORDER BY pk FORMAT RowBinary").to_slice
  w97_assert_bytes(rowbinary, w97_expected_bool_only(keys, codes), "Bool-only stock RowBinary")
  reader = CrystalClick::WidePart.open_typed(part, "payload")
  data = reader.read_tuple_mark_range("payload", 0, reader.mark_count)
  raise "Bool-only reader schema differs" unless data.type_name == W97_BOOL_ONLY_TYPE
  keys.size.times do |index|
    raise "Bool-only typed value differs" unless data.value_as("flag", index, Bool) == (codes[index] != 0_u8)
  end
  puts "PASS Bool-only named Tuple stock/read profile"
  nil
end

def w97_check_all_default(binary : String, store : String) : Nil
  fields = W97_MIXED_FIELDS
  zeros = Array.new(5, 0_u8)
  empty_strings = Array.new(5, "")
  keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
  table = "w97_stock_bool_tuple_always_default"
  w97_create_table(binary, store, table, W97_MIXED_TYPE, "1.0")
  w97_insert_mixed(binary, store, table, zeros, zeros, empty_strings, keys)
  part = w97_active_part_path(binary, store, table)
  w97_assert_physical(part, W97_MIXED_TYPE, fields, keys.size.to_i32, [2_u64, 2_u64, 1_u64, 0_u64], "stock AlwaysDefault Bool Tuple", always_default: true)
  w97_check_table(binary, store, table, part)
  expected = w97_expected_rowbinary(keys, zeros, zeros, empty_strings)
  w97_assert_bytes(w97_run_clickhouse(binary, store, "SELECT pk, payload.flag, payload.byte, payload.text FROM default.#{table} ORDER BY pk FORMAT RowBinary").to_slice, expected, "AlwaysDefault stock RowBinary")
  reader = CrystalClick::WidePart.open_typed(part, "payload")
  data = reader.read_tuple_mark_range("payload", 0, reader.mark_count)
  keys.size.times do |index|
    raise "AlwaysDefault Bool value differs" unless data.value_as("flag", index, Bool) == false
    raise "AlwaysDefault UInt8 value differs" unless data.value_as("byte", index, UInt8) == 0_u8
    raise "AlwaysDefault String value differs" unless data.value_as("text", index, String).empty?
  end

  columns = w97_leaf_columns_for_rows(Array.new(5, false), zeros, empty_strings)
  writer_part = File.join(ENV.fetch("TUPLE_WRITER_ROOT"), "bool_tuple_always_default")
  CrystalClick::WidePartWriter.write_uint64_tuple_pair(
    writer_part,
    "pk",
    keys.to_unsafe.to_slice(keys.size),
    "payload",
    W97_MIXED_TYPE,
    columns,
    rows_per_mark: 2
  )
  writer_table = "w97_writer_bool_tuple_always_default"
  attached = w97_attach_writer_part(binary, store, writer_table, writer_part, W97_MIXED_TYPE)
  w97_assert_physical(attached, W97_MIXED_TYPE, fields, keys.size.to_i32, [2_u64, 2_u64, 1_u64, 0_u64], "writer AlwaysDefault Bool Tuple")
  w97_check_table(binary, store, writer_table, attached)
  w97_assert_bytes(w97_decompressed_stream(attached, "payload%2Eflag"), Bytes.new(5, 0_u8), "writer AlwaysDefault Bool bytes")
  writer_output = w97_run_clickhouse(binary, store, "SELECT pk, payload.flag, payload.byte, payload.text FROM default.#{writer_table} ORDER BY pk FORMAT RowBinary").to_slice
  w97_assert_bytes(writer_output, expected, "writer AlwaysDefault -> stock RowBinary")
  puts "PASS all-default Bool Tuple stock and writer/ATTACH profiles"
  nil
end

binary = ENV["CLICKHOUSE_BIN"]? || raise "set CLICKHOUSE_BIN to pinned ClickHouse 26.7.1.1315"
store = ENV["CLICKHOUSE_STORE"]? || raise "set CLICKHOUSE_STORE to a fresh temporary ClickHouse store directory"
writer_root = ENV["TUPLE_WRITER_ROOT"]? || raise "set TUPLE_WRITER_ROOT to a fresh temporary writer directory"
unless store.starts_with?("/private/tmp/") || store.starts_with?("/tmp/")
  raise "refusing non-temporary CLICKHOUSE_STORE path: #{store}"
end
raise "CLICKHOUSE_STORE must be empty" if Dir.exists?(store) && !Dir.empty?(store)
Dir.mkdir_p(store)
Dir.mkdir_p(writer_root)

version_output = IO::Memory.new
version_status = Process.run(binary, ["local", "--version"], output: version_output)
raise "could not read ClickHouse local version" unless version_status.success?
unless version_output.to_s.strip == "ClickHouse local version #{W97_STOCK_VERSION} (official build)."
  raise "Bool Tuple oracle requires pinned ClickHouse #{W97_STOCK_VERSION}, got #{version_output.to_s.strip}"
end
puts "Stock oracle: #{version_output.to_s.strip}"

w97_qualify_byte_comparator(W97_CODES.to_unsafe.to_slice(W97_CODES.size))
stock_part = w97_check_mixed_stock(binary, store)
w97_check_writer_mixed(binary, store, stock_part)
w97_check_bool_only(binary, store)
w97_check_all_default(binary, store)
puts "PASS W97 Bool Tuple oracle: stock raw codes 0x00..0xff preserved physically, native reads normalize nonzero to true, writers emit canonical 0/1; mixed, Bool-only, AlwaysDefault, stock ATTACH/CHECK and typed consumers exercised"
