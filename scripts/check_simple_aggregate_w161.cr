require "file_utils"
require "../src/crystal_click"
require "../spec/support/simple_aggregate_w161_types"

private def w161_assert(condition : Bool, message : String) : Nil
  raise message unless condition
end

private def w161_u64_bytes(values : Array(UInt64)) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |value|
    8.times { |index| bytes << ((value >> (index * 8)) & 0xff_u64).to_u8 }
  end
  bytes
end

private def w161_stream_bytes(part : String, logical_name : String) : Array(UInt8)
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.bin")
  CrystalClick::CompressedBlock.decode_all(File.read(path).to_slice).to_a
end

private def w161_mark_rows(part : String, logical_name : String) : Array(UInt64)
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.mrk2")
  bytes = File.read(path).to_slice
  w161_assert(bytes.size % CrystalClick::WidePart::MARK_SIZE == 0, "#{logical_name}: malformed mrk2 size")
  Array(UInt64).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |mark|
    offset = mark * CrystalClick::WidePart::MARK_SIZE + 16
    value = 0_u64
    8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
    value
  end
end

private def w161_check_layout(
  part : String,
  function_name : String,
  nullable : Bool,
  keys : Array(UInt64),
  values : Array(UInt64),
  nullable_values : Array(UInt64?),
) : Nil
  base_type = "SimpleAggregateFunction(#{function_name}, UInt64)"
  type = nullable ? "Nullable(#{base_type})" : base_type
  w161_assert(File.read(File.join(part, "columns.txt")) ==
              "columns format version: 1\n2 columns:\n`pk` UInt64\n`v` #{type}\n",
    "#{type}: exact columns metadata differs")

  value_streams = nullable ? ["v.null", "v"] : ["v"]
  expected_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" +
                        "#{value_streams.size} substreams for column `v`:\n" + value_streams.map { |name| "\t#{name}\n" }.join
  w161_assert(File.read(File.join(part, "columns_substreams.txt")) == expected_substreams,
    "#{type}: exact substream metadata differs")
  w161_assert(File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)", "#{type}: LZ4 metadata differs")
  w161_assert(File.read(File.join(part, "serialization.json")) ==
              "{\"columns\":[],\"propagate_types_serialization_versions_to_nested_types\":true,\"types_serialization_versions\":{\"string\":1},\"version\":1}",
    "#{type}: exact serialization metadata differs")
  w161_assert(File.read(File.join(part, "count.txt")) == "6", "#{type}: row count metadata differs")
  w161_assert(File.read(File.join(part, "metadata_version.txt")) == "0", "#{type}: metadata version differs")

  nested_values = nullable ? nullable_values.map { |value| value || 0_u64 } : values
  w161_assert(w161_stream_bytes(part, "pk") == w161_u64_bytes(keys), "#{type}: UInt64 key bytes differ")
  w161_assert(w161_stream_bytes(part, "v") == w161_u64_bytes(nested_values), "#{type}: UInt64 payload bytes differ")
  if nullable
    expected_null_map = nullable_values.map { |value| value.nil? ? 1_u8 : 0_u8 }
    w161_assert(w161_stream_bytes(part, "v.null") == expected_null_map, "#{type}: Nullable null-map bytes differ")
  end

  streams = nullable ? ["pk", "v.null", "v"] : ["pk", "v"]
  streams.each do |stream|
    w161_assert(w161_mark_rows(part, stream) == [2_u64, 2_u64, 2_u64, 0_u64], "#{type}: #{stream} mark grid differs")
  end
end

private def w161_check_table_consumers(
  part : String,
  nullable : Bool,
  values : Array(UInt64),
  nullable_values : Array(UInt64?),
  keys : Array(UInt64),
) : Nil
  table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "v"])
  observed_keys = [] of UInt64
  observed_values = [] of UInt64
  observed_nullable = [] of UInt64?
  observed_marks = [] of Int32
  table.scan_typed(batch_rows: 2) do |batch|
    batch_keys = batch.values_for("pk", UInt64)
    observed_keys.concat(batch_keys.to_a)
    observed_marks.concat(Array(Int32).new(batch_keys.size, batch.mark_index))
    if nullable
      observed_nullable.concat(batch.nullable_simple_aggregate_uint64s_for("v").to_a)
    else
      observed_values.concat(batch.simple_aggregate_uint64s_for("v").to_a)
    end
  end
  w161_assert(observed_keys == keys, "#{part}: table key batches differ")
  w161_assert(observed_marks == [0, 0, 1, 1, 2, 2], "#{part}: table mark batches differ")
  w161_assert(nullable ? observed_nullable == nullable_values : observed_values == values,
    "#{part}: table SimpleAggregateFunction batches differ")

  callbacks = 0
  table.scan_typed_window(table.total_row_count, 1) { |_batch| callbacks += 1 }
  w161_assert(callbacks == 0, "#{part}: zero-row table window yielded a batch")
end

private def w161_check_catalog_values(
  part : String,
  function_name : String,
  nullable : Bool,
  values : Array(UInt64),
  nullable_values : Array(UInt64?),
  code : UInt8,
) : Nil
  root = File.join(File.dirname(part), "catalog-#{code.to_s(16).rjust(2, '0')}-#{nullable ? "nullable" : "scalar"}")
  w161_assert(!File.exists?(root) && !File.symlink?(root), "refusing to overwrite catalog fixture #{root}")
  Dir.mkdir(root)
  token = code.to_s(16).rjust(12, '0')
  database_uuid = "00000000-0000-4000-8000-#{token}"
  table_uuid = "11111111-1111-4111-8111-#{token}"
  database_path = File.join(root, "store", database_uuid[0, 3], database_uuid)
  table_path = File.join(root, "store", table_uuid[0, 3], table_uuid)

  begin
    FileUtils.mkdir_p(File.join(root, "metadata"))
    FileUtils.mkdir_p(database_path)
    FileUtils.mkdir_p(table_path)
    File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
    type = "SimpleAggregateFunction(#{function_name}, UInt64)"
    File.write(
      File.join(database_path, "events.sql"),
      "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n" +
      "    `pk` UInt64,\n" +
      "    `v` #{nullable ? "Nullable(#{type})" : type}\n" +
      ")\nENGINE = MergeTree\nORDER BY pk\n"
    )
    File.write(File.join(table_path, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(table_path, "detached"))
    FileUtils.cp_r(part, File.join(table_path, "all_1_1_0"))

    actual = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]["v"].values
    if nullable
      w161_assert(actual.map(&.as(UInt64?)) == nullable_values, "#{type}: OfflineCatalog Nullable values differ")
    else
      w161_assert(actual.map(&.as(UInt64)) == values, "#{type}: OfflineCatalog values differ")
    end
  ensure
    FileUtils.rm_rf(root)
  end
end

private def w161_check_stock_reader(
  part : String,
  function_name : String,
  suffix : String,
  stock_values : Array(UInt64),
  stock_nullable_values : Array(UInt64?),
) : Nil
  [false, true].each do |nullable|
    column = "#{nullable ? "n" : "s"}_#{suffix}"
    reader = CrystalClick::WidePart.open_typed(part, column)
    expected_type = if nullable
                      "Nullable(SimpleAggregateFunction(#{function_name}, UInt64))"
                    else
                      "SimpleAggregateFunction(#{function_name}, UInt64)"
                    end
    w161_assert(reader.column_type == expected_type, "stock #{column}: exact nominal type differs")
    w161_assert(reader.row_count == 6_u64, "stock #{column}: row count differs")
    w161_assert(reader.mark_row_counts == [2_u64, 2_u64, 2_u64], "stock #{column}: mark rows differ")
    if nullable
      w161_assert(reader.read_nullable_simple_aggregate_uint64_mark_range(column, 0, reader.mark_count) == stock_nullable_values,
        "stock #{column}: full values differ")
      w161_assert(reader.read_nullable_simple_aggregate_uint64_mark_range(column, 1, 1) == stock_nullable_values[2, 2],
        "stock #{column}: middle mark differs")
      begin
        reader.read_nullable_simple_aggregate_uint64_mark_range(column, 0, 0)
        raise "stock #{column}: zero-mark direct range should preserve BoundsError contract"
      rescue CrystalClick::BoundsError
      end
      begin
        reader.read_nullable_numeric_mark_range(column, 0, reader.mark_count, UInt64)
        raise "stock #{column}: primitive Nullable(UInt64) reader accepted nominal SimpleAggregateFunction"
      rescue CrystalClick::UnsupportedFormatError
      end
    else
      w161_assert(reader.read_simple_aggregate_uint64_mark_range(column, 0, reader.mark_count) == stock_values,
        "stock #{column}: full values differ")
      w161_assert(reader.read_simple_aggregate_uint64_mark_range(column, 1, 1) == stock_values[2, 2],
        "stock #{column}: middle mark differs")
      begin
        reader.read_simple_aggregate_uint64_mark_range(column, 0, 0)
        raise "stock #{column}: zero-mark direct range should preserve BoundsError contract"
      rescue CrystalClick::BoundsError
      end
      begin
        reader.read_numeric_mark_range(column, 0, reader.mark_count, UInt64)
        raise "stock #{column}: primitive UInt64 reader accepted nominal SimpleAggregateFunction"
      rescue CrystalClick::UnsupportedFormatError
      end
    end
  end
end

private def w161_check_part(
  part : String,
  function_name : String,
  suffix : String,
  nullable : Bool,
  function : CrystalClick::BinarySimpleAggregateType::Function,
  keys : Array(UInt64),
  values : Array(UInt64),
  nullable_values : Array(UInt64?),
  code : UInt8,
) : Nil
  expected_parent = "#{nullable ? "nullable" : "scalar"}_#{suffix}"
  w161_assert(File.basename(File.dirname(part)) == expected_parent && File.basename(part) == "all_1_1_0",
    "#{expected_parent}: noncanonical part path")
  if nullable
    CrystalClick::WidePartWriter.write_uint64_nullable_simple_aggregate_pair(
      part, "pk", keys.to_unsafe.to_slice(keys.size), "v",
      nullable_values.to_unsafe.to_slice(nullable_values.size), function, rows_per_mark: 2
    )
  else
    CrystalClick::WidePartWriter.write_uint64_simple_aggregate_pair(
      part, "pk", keys.to_unsafe.to_slice(keys.size), "v",
      values.to_unsafe.to_slice(values.size), function, rows_per_mark: 2
    )
  end

  w161_check_layout(part, function_name, nullable, keys, values, nullable_values)
  reader = CrystalClick::WidePart.open_typed(part, "v")
  expected_type = if nullable
                    "Nullable(SimpleAggregateFunction(#{function_name}, UInt64))"
                  else
                    "SimpleAggregateFunction(#{function_name}, UInt64)"
                  end
  w161_assert(reader.column_type == expected_type, "#{expected_type}: writer type differs")
  w161_assert(reader.row_count == 6_u64, "#{expected_type}: writer row count differs")
  w161_assert(reader.mark_row_counts == [2_u64, 2_u64, 2_u64], "#{expected_type}: writer mark rows differ")
  if nullable
    w161_assert(reader.read_nullable_simple_aggregate_uint64_mark_range("v", 0, reader.mark_count) == nullable_values,
      "#{expected_type}: full writer read differs")
    w161_assert(reader.read_nullable_simple_aggregate_uint64_mark_range("v", 1, 1) == nullable_values[2, 2],
      "#{expected_type}: middle writer read differs")
    begin
      reader.read_nullable_simple_aggregate_uint64_mark_range("v", 0, 0)
      raise "#{expected_type}: zero-mark direct range should preserve BoundsError contract"
    rescue CrystalClick::BoundsError
    end
  else
    w161_assert(reader.read_simple_aggregate_uint64_mark_range("v", 0, reader.mark_count) == values,
      "#{expected_type}: full writer read differs")
    w161_assert(reader.read_simple_aggregate_uint64_mark_range("v", 1, 1) == values[2, 2],
      "#{expected_type}: middle writer read differs")
    begin
      reader.read_simple_aggregate_uint64_mark_range("v", 0, 0)
      raise "#{expected_type}: zero-mark direct range should preserve BoundsError contract"
    rescue CrystalClick::BoundsError
    end
  end
  w161_check_table_consumers(part, nullable, values, nullable_values, keys)
  w161_check_catalog_values(part, function_name, nullable, values, nullable_values, code)
  puts "PASS library #{nullable ? "Nullable" : "scalar"} #{function_name}: exact Wide bytes/marks, direct/table/catalog values"
end

part_root = ENV["W161_PART_ROOT"]? || raise "W161_PART_ROOT is required"
stock_part = ENV["W161_SIMPLE_AGGREGATE_STOCK_WIDE_PART"]? || raise "W161_SIMPLE_AGGREGATE_STOCK_WIDE_PART is required"
Dir.mkdir(part_root) unless Dir.exists?(part_root)

keys = W161_SIMPLE_AGGREGATE_KEYS
values = W161_SIMPLE_AGGREGATE_LIBRARY_VALUES
nullable_values = W161_SIMPLE_AGGREGATE_LIBRARY_NULLABLE_VALUES
stock_values = W161_SIMPLE_AGGREGATE_STOCK_VALUES
stock_nullable_values = W161_SIMPLE_AGGREGATE_STOCK_NULLABLE_VALUES

W161_SIMPLE_AGGREGATE_TYPES.each_with_index do |(function_name, suffix, function), index|
  scalar_parent = File.join(part_root, "scalar_#{suffix}")
  nullable_parent = File.join(part_root, "nullable_#{suffix}")
  Dir.mkdir(scalar_parent)
  Dir.mkdir(nullable_parent)
  w161_check_part(
    File.join(scalar_parent, "all_1_1_0"), function_name, suffix, false, function,
    keys, values, nullable_values, index.to_u8
  )
  w161_check_part(
    File.join(nullable_parent, "all_1_1_0"), function_name, suffix, true, function,
    keys, values, nullable_values, index.to_u8
  )
  w161_check_stock_reader(stock_part, function_name, suffix, stock_values, stock_nullable_values)
  puts "PASS stock #{function_name}: exact scalar/Nullable identity and full/middle direct reads"
end

# This is intentionally only a raw-value serialization mutant. It changes the
# first literal payload from 0 to 1 while preserving the exact declared type;
# it does not exercise aggregation execution or function semantics.
mutant_parent = File.join(part_root, "scalar_min_value_mutant")
Dir.mkdir(mutant_parent)
mutant_values = values.dup
mutant_values[0] = 1_u64
mutant_part = File.join(mutant_parent, "all_1_1_0")
CrystalClick::WidePartWriter.write_uint64_simple_aggregate_pair(
  mutant_part, "pk", keys.to_unsafe.to_slice(keys.size), "v",
  mutant_values.to_unsafe.to_slice(mutant_values.size),
  CrystalClick::BinarySimpleAggregateType::Function::Min, rows_per_mark: 2
)
w161_check_layout(mutant_part, "min", false, keys, mutant_values, nullable_values)
mutant_reader = CrystalClick::WidePart.open_typed(mutant_part, "v")
w161_assert(mutant_reader.column_type == "SimpleAggregateFunction(min, UInt64)", "value mutant changed exact nominal type")
w161_assert(mutant_reader.read_simple_aggregate_uint64_mark_range("v", 0, mutant_reader.mark_count) == mutant_values,
  "value mutant did not preserve its one intended UInt64 change")
puts "PASS separately labelled min value mutant: only first raw UInt64 changed 0→1; no aggregation execution claim"
