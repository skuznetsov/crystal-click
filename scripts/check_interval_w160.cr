require "file_utils"
require "../src/crystal_click"
require "../spec/support/interval_w160_types"

def w160_interval_assert(condition : Bool, message : String) : Nil
  raise message unless condition
end

def w160_interval_stream_bytes(part : String, logical_name : String) : Array(UInt8)
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.bin")
  CrystalClick::CompressedBlock.decode_all(File.read(path).to_slice).to_a
end

def w160_interval_mark_rows(part : String, logical_name : String) : Array(UInt64)
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.mrk2")
  bytes = File.read(path).to_slice
  w160_interval_assert(bytes.size % CrystalClick::WidePart::MARK_SIZE == 0, "#{logical_name}: malformed mrk2 size")
  Array(UInt64).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |mark|
    offset = mark * CrystalClick::WidePart::MARK_SIZE + 16
    value = 0_u64
    8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
    value
  end
end

def w160_interval_check_layout(
  part : String,
  type_name : String,
  nullable : Bool,
  keys : Array(UInt64),
  counts : Array(Int64),
  nullable_counts : Array(Int64?),
) : Nil
  declared_type = nullable ? "Nullable(#{type_name})" : type_name
  expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`v` #{declared_type}\n"
  w160_interval_assert(File.read(File.join(part, "columns.txt")) == expected_columns, "#{type_name}: exact columns metadata differs")

  streams = nullable ? ["v.null", "v"] : ["v"]
  expected_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" +
                        "#{streams.size} substreams for column `v`:\n" + streams.map { |name| "\t#{name}\n" }.join
  w160_interval_assert(File.read(File.join(part, "columns_substreams.txt")) == expected_substreams, "#{type_name}: exact substream metadata differs")
  w160_interval_assert(File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)", "#{type_name}: LZ4 metadata differs")
  expected_serialization = "{\"columns\":[],\"propagate_types_serialization_versions_to_nested_types\":true," +
                           "\"types_serialization_versions\":{\"string\":1},\"version\":1}"
  w160_interval_assert(File.read(File.join(part, "serialization.json")) == expected_serialization, "#{type_name}: exact serialization metadata differs")

  expected_keys = keys.flat_map { |value| W160IntervalTestSupport.u64_le(value) }
  expected_value_bytes = (nullable ? nullable_counts.map { |value| value || 0_i64 } : counts).flat_map do |value|
    W160IntervalTestSupport.i64_le(value)
  end
  w160_interval_assert(w160_interval_stream_bytes(part, "pk") == expected_keys, "#{type_name}: UInt64 key stream bytes differ")
  w160_interval_assert(w160_interval_stream_bytes(part, "v") == expected_value_bytes, "#{type_name}: raw Int64 count bytes differ")
  if nullable
    expected_null_map = nullable_counts.map { |value| value.nil? ? 1_u8 : 0_u8 }
    w160_interval_assert(w160_interval_stream_bytes(part, "v.null") == expected_null_map, "#{type_name}: Nullable null-map bytes differ")
  end

  mark_streams = nullable ? ["pk", "v.null", "v"] : ["pk", "v"]
  mark_streams.each do |stream|
    w160_interval_assert(w160_interval_mark_rows(part, stream) == [2_u64, 2_u64, 2_u64, 0_u64], "#{type_name}: #{stream} mark grid differs")
  end
end

def w160_interval_check_stock_reader(
  part : String,
  type_name : String,
  suffix : String,
  expected_counts : Array(Int64),
  expected_nullable_counts : Array(Int64?),
) : Nil
  [false, true].each do |nullable|
    column = "#{nullable ? "n" : "s"}_#{suffix}"
    reader = CrystalClick::WidePart.open_typed(part, column)
    expected_type = nullable ? "Nullable(#{type_name})" : type_name
    w160_interval_assert(reader.column_type == expected_type, "stock #{column}: exact type differs")
    w160_interval_assert(reader.row_count == 6_u64, "stock #{column}: row count differs")
    w160_interval_assert(reader.mark_row_counts == [2_u64, 2_u64, 2_u64], "stock #{column}: mark rows differ")
    if nullable
      w160_interval_assert(reader.read_nullable_interval_counts_mark_range(column, 0, reader.mark_count) == expected_nullable_counts, "stock #{column}: full raw counts differ")
      w160_interval_assert(reader.read_nullable_interval_counts_mark_range(column, 1, 1) == [0_i64, nil] of Int64?, "stock #{column}: middle mark differs")
      begin
        reader.read_nullable_interval_counts_mark_range(column, 0, 0)
        raise "stock #{column}: zero-mark direct range should preserve BoundsError contract"
      rescue CrystalClick::BoundsError
      end
    else
      w160_interval_assert(reader.read_interval_counts_mark_range(column, 0, reader.mark_count) == expected_counts, "stock #{column}: full raw counts differ")
      w160_interval_assert(reader.read_interval_counts_mark_range(column, 1, 1) == [0_i64, 42_i64], "stock #{column}: middle mark differs")
      begin
        reader.read_interval_counts_mark_range(column, 0, 0)
        raise "stock #{column}: zero-mark direct range should preserve BoundsError contract"
      rescue CrystalClick::BoundsError
      end
    end
  end
end

def w160_interval_check_public_table_consumers(
  part : String,
  nullable : Bool,
  counts : Array(Int64),
  nullable_counts : Array(Int64?),
  keys : Array(UInt64),
) : Nil
  table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "v"])
  observed_keys = [] of UInt64
  observed_counts = [] of Int64
  observed_nullable_counts = [] of Int64?
  observed_marks = [] of Int32
  table.scan_typed(batch_rows: 2) do |batch|
    batch_keys = batch.values_for("pk", UInt64)
    observed_keys.concat(batch_keys.to_a)
    observed_marks.concat(Array(Int32).new(batch_keys.size, batch.mark_index))
    if nullable
      observed_nullable_counts.concat(batch.nullable_interval_counts_for("v").to_a)
    else
      observed_counts.concat(batch.interval_counts_for("v").to_a)
    end
  end
  w160_interval_assert(observed_keys == keys, "#{part}: WidePartTable key batches differ")
  w160_interval_assert(observed_marks == [0, 0, 1, 1, 2, 2], "#{part}: WidePartTable mark batches differ")
  w160_interval_assert(nullable ? observed_nullable_counts == nullable_counts : observed_counts == counts,
    "#{part}: WidePartTable Interval value batches differ")

  callbacks = 0
  table.scan_typed_window(table.total_row_count, 1) { |_batch| callbacks += 1 }
  w160_interval_assert(callbacks == 0, "#{part}: zero-row table window yielded a batch")
end

def w160_interval_check_catalog_values(
  part : String,
  type_name : String,
  nullable : Bool,
  counts : Array(Int64),
  nullable_counts : Array(Int64?),
  code : UInt8,
) : Nil
  root = File.join(File.dirname(part), "catalog-#{code.to_s(16).rjust(2, '0')}-#{nullable ? "nullable" : "scalar"}")
  w160_interval_assert(!File.exists?(root) && !File.symlink?(root), "refusing to overwrite catalog fixture #{root}")
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
    File.write(
      File.join(database_path, "events.sql"),
      "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n" +
      "    `pk` UInt64,\n" +
      "    `v` #{nullable ? "Nullable(#{type_name})" : type_name}\n" +
      ")\nENGINE = MergeTree\nORDER BY pk\n"
    )
    File.write(File.join(table_path, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(table_path, "detached"))
    FileUtils.cp_r(part, File.join(table_path, "all_1_1_0"))

    actual = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]["v"].values
    matches = if nullable
                actual.map(&.as(Int64?)) == nullable_counts
              else
                actual.map(&.as(Int64)) == counts
              end
    w160_interval_assert(matches, "#{type_name}: OfflineCatalog column.values differs")
  ensure
    FileUtils.rm_rf(root)
  end
end

part_root = ENV["W160_PART_ROOT"]? || raise "W160_PART_ROOT is required"
stock_part = ENV["W160_INTERVAL_STOCK_WIDE_PART"]? || raise "W160_INTERVAL_STOCK_WIDE_PART is required"
Dir.mkdir(part_root) unless Dir.exists?(part_root)

keys = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64]
counts = [Int64::MIN, -3_i64, 0_i64, 42_i64, -1_i64, Int64::MAX]
nullable_counts = [Int64::MIN, -3_i64, 0_i64, nil, -1_i64, Int64::MAX] of Int64?
stock_counts = [7_i64, -3_i64, 0_i64, 42_i64, -1_i64, 11_i64]
stock_nullable_counts = [7_i64, -3_i64, 0_i64, nil, -1_i64, 11_i64] of Int64?
key_slice = keys.to_unsafe.to_slice(keys.size)
count_slice = counts.to_unsafe.to_slice(counts.size)
nullable_slice = nullable_counts.to_unsafe.to_slice(nullable_counts.size)

W160_INTERVAL_TYPES.each do |type_name, kind, _code|
  suffix = type_name.byte_slice("Interval".bytesize, type_name.bytesize - "Interval".bytesize).not_nil!.downcase
  scalar_parent = File.join(part_root, "scalar_#{suffix}")
  nullable_parent = File.join(part_root, "nullable_#{suffix}")
  Dir.mkdir(scalar_parent)
  Dir.mkdir(nullable_parent)
  scalar_part = File.join(scalar_parent, "all_1_1_0")
  nullable_part = File.join(nullable_parent, "all_1_1_0")
  CrystalClick::WidePartWriter.write_uint64_interval_pair(
    scalar_part, "pk", key_slice, "v", count_slice, kind, rows_per_mark: 2
  )
  CrystalClick::WidePartWriter.write_uint64_nullable_interval_pair(
    nullable_part, "pk", key_slice, "v", nullable_slice, kind, rows_per_mark: 2
  )

  w160_interval_check_layout(scalar_part, type_name, false, keys, counts, nullable_counts)
  w160_interval_check_layout(nullable_part, type_name, true, keys, counts, nullable_counts)

  scalar = CrystalClick::WidePart.open_typed(scalar_part, "v")
  w160_interval_assert(scalar.column_type == type_name, "#{type_name}: writer scalar type differs")
  w160_interval_assert(scalar.read_interval_counts_mark_range("v", 0, scalar.mark_count) == counts, "#{type_name}: scalar full library read differs")
  w160_interval_assert(scalar.read_interval_counts_mark_range("v", 1, 1) == [0_i64, 42_i64], "#{type_name}: scalar middle library read differs")
  begin
    scalar.read_interval_counts_mark_range("v", 0, 0)
    raise "#{type_name}: scalar zero-mark direct range should preserve BoundsError contract"
  rescue CrystalClick::BoundsError
  end
  w160_interval_check_public_table_consumers(scalar_part, false, counts, nullable_counts, keys)
  w160_interval_check_catalog_values(scalar_part, type_name, false, counts, nullable_counts, _code)

  nullable = CrystalClick::WidePart.open_typed(nullable_part, "v")
  w160_interval_assert(nullable.column_type == "Nullable(#{type_name})", "#{type_name}: writer Nullable type differs")
  w160_interval_assert(nullable.read_nullable_interval_counts_mark_range("v", 0, nullable.mark_count) == nullable_counts, "#{type_name}: Nullable full library read differs")
  w160_interval_assert(nullable.read_nullable_interval_counts_mark_range("v", 1, 1) == [0_i64, nil] of Int64?, "#{type_name}: Nullable middle library read differs")
  begin
    nullable.read_nullable_interval_counts_mark_range("v", 0, 0)
    raise "#{type_name}: Nullable zero-mark direct range should preserve BoundsError contract"
  rescue CrystalClick::BoundsError
  end
  w160_interval_check_public_table_consumers(nullable_part, true, counts, nullable_counts, keys)
  w160_interval_check_catalog_values(nullable_part, type_name, true, counts, nullable_counts, _code)

  w160_interval_check_stock_reader(stock_part, type_name, suffix, stock_counts, stock_nullable_counts)
  puts "PASS #{type_name}: scalar+Nullable writer bytes/marks and native stock full/middle/zero reads"
end

value_mutant_parent = File.join(part_root, "scalar-second-value-mutant")
Dir.mkdir(value_mutant_parent)
value_mutant_part = File.join(value_mutant_parent, "all_1_1_0")
mutant_counts = counts.dup
mutant_counts[0] = Int64::MIN + 1_i64
CrystalClick::WidePartWriter.write_uint64_interval_pair(
  value_mutant_part,
  "pk",
  key_slice,
  "v",
  mutant_counts.to_unsafe.to_slice(mutant_counts.size),
  CrystalClick::BinaryIntervalType::Kind::Second,
  rows_per_mark: 2
)
w160_interval_check_layout(value_mutant_part, "IntervalSecond", false, keys, mutant_counts, nullable_counts)
mutant_reader = CrystalClick::WidePart.open_typed(value_mutant_part, "v")
w160_interval_assert(
  mutant_reader.read_interval_counts_mark_range("v", 0, mutant_reader.mark_count) == mutant_counts,
  "IntervalSecond value mutant did not change exactly the intended first raw count"
)
puts "PASS library-authored IntervalSecond one-count mutant is a complete, readable Wide part"
