require "./spec_helper"
require "file_utils"
require "./support/simple_aggregate_w161_types"

private def w161_wide_u64_bytes(values : Array(UInt64)) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |value|
    8.times { |index| bytes << ((value >> (index * 8)) & 0xff_u64).to_u8 }
  end
  bytes
end

private def w161_wide_stream_bytes(part : String, logical_name : String) : Array(UInt8)
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.bin")
  CrystalClick::CompressedBlock.decode_all(File.read(path).to_slice).to_a
end

private def w161_wide_mark_rows(part : String, logical_name : String) : Array(UInt64)
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.mrk2")
  bytes = File.read(path).to_slice
  raise "W161 malformed mrk2 size for #{logical_name}" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(UInt64).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |mark|
    offset = mark * CrystalClick::WidePart::MARK_SIZE + 16
    value = 0_u64
    8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
    value
  end
end

private def w161_wide_assert_layout(
  part : String,
  function_name : String,
  nullable : Bool,
  keys : Array(UInt64),
  values : Array(UInt64),
  nullable_values : Array(UInt64?),
) : Nil
  declaration = "SimpleAggregateFunction(#{function_name}, UInt64)"
  declared_type = nullable ? "Nullable(#{declaration})" : declaration
  File.read(File.join(part, "columns.txt")).should eq(
    "columns format version: 1\n2 columns:\n`pk` UInt64\n`v` #{declared_type}\n"
  )
  value_streams = nullable ? ["v.null", "v"] : ["v"]
  expected_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n" +
                        "#{value_streams.size} substreams for column `v`:\n" + value_streams.map { |name| "\t#{name}\n" }.join
  File.read(File.join(part, "columns_substreams.txt")).should eq(expected_substreams)
  File.read(File.join(part, "default_compression_codec.txt")).should eq("CODEC(LZ4)")
  File.read(File.join(part, "serialization.json")).should eq(
    "{\"columns\":[],\"propagate_types_serialization_versions_to_nested_types\":true," +
    "\"types_serialization_versions\":{\"string\":1},\"version\":1}"
  )

  expected_values = nullable ? nullable_values.map { |value| value || 0_u64 } : values
  w161_wide_stream_bytes(part, "pk").should eq(w161_wide_u64_bytes(keys))
  w161_wide_stream_bytes(part, "v").should eq(w161_wide_u64_bytes(expected_values))
  if nullable
    w161_wide_stream_bytes(part, "v.null").should eq(W161SimpleAggregateTestSupport.null_map(nullable_values))
  end

  (nullable ? ["pk", "v.null", "v"] : ["pk", "v"]).each do |stream|
    w161_wide_mark_rows(part, stream).should eq([2_u64, 2_u64, 2_u64, 0_u64])
  end
end

private def w161_wide_assert_table_batches(
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
  observed_keys.should eq(keys)
  observed_marks.should eq([0, 0, 1, 1, 2, 2])
  if nullable
    observed_nullable.should eq(nullable_values)
  else
    observed_values.should eq(values)
  end
  empty_callbacks = 0
  table.scan_typed_window(table.total_row_count, 1) { |_batch| empty_callbacks += 1 }
  empty_callbacks.should eq(0)
end

private def w161_wide_assert_catalog_values(
  part : String,
  function_name : String,
  nullable : Bool,
  values : Array(UInt64),
  nullable_values : Array(UInt64?),
  code : UInt8,
) : Nil
  root = File.join(File.dirname(part), "catalog-#{code.to_s(16).rjust(2, '0')}-#{nullable ? "nullable" : "scalar"}")
  raise "refusing to overwrite W161 catalog fixture #{root}" if File.exists?(root) || File.symlink?(root)
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
      actual.map(&.as(UInt64?)).should eq(nullable_values)
    else
      actual.map(&.as(UInt64)).should eq(values)
    end
  ensure
    FileUtils.rm_rf(root)
  end
end

describe "W161 SimpleAggregateFunction scalar and Nullable Wide pair" do
  it "preserves all nine exact function identities across physical parts, readers, batches and offline values" do
    parent = File.tempname("crystal-click-simple-aggregate-w161-wide")
    Dir.mkdir(parent)
    keys = W161_SIMPLE_AGGREGATE_KEYS
    values = W161_SIMPLE_AGGREGATE_LIBRARY_VALUES
    nullable_values = W161_SIMPLE_AGGREGATE_LIBRARY_NULLABLE_VALUES
    key_slice = keys.to_unsafe.to_slice(keys.size)
    value_slice = values.to_unsafe.to_slice(values.size)
    nullable_slice = nullable_values.to_unsafe.to_slice(nullable_values.size)

    begin
      W161_SIMPLE_AGGREGATE_TYPES.each_with_index do |(function_name, suffix, function), index|
        scalar_parent = File.join(parent, "scalar-#{suffix}")
        nullable_parent = File.join(parent, "nullable-#{suffix}")
        Dir.mkdir(scalar_parent)
        Dir.mkdir(nullable_parent)
        scalar_part = File.join(scalar_parent, "all_1_1_0")
        nullable_part = File.join(nullable_parent, "all_1_1_0")

        CrystalClick::WidePartWriter.write_uint64_simple_aggregate_pair(
          scalar_part, "pk", key_slice, "v", value_slice, function, rows_per_mark: 2
        ).should eq(scalar_part)
        CrystalClick::WidePartWriter.write_uint64_nullable_simple_aggregate_pair(
          nullable_part, "pk", key_slice, "v", nullable_slice, function, rows_per_mark: 2
        ).should eq(nullable_part)
        w161_wide_assert_layout(scalar_part, function_name, false, keys, values, nullable_values)
        w161_wide_assert_layout(nullable_part, function_name, true, keys, values, nullable_values)

        scalar = CrystalClick::WidePart.open_typed(scalar_part, "v")
        scalar.column_type.should eq("SimpleAggregateFunction(#{function_name}, UInt64)")
        scalar.row_count.should eq(6_u64)
        scalar.mark_row_counts.should eq([2_u64, 2_u64, 2_u64])
        scalar.read_simple_aggregate_uint64_mark_range("v", 0, scalar.mark_count).should eq(values)
        scalar.read_simple_aggregate_uint64_mark_range("v", 1, 1).should eq(values[2, 2])
        expect_raises(CrystalClick::BoundsError) { scalar.read_simple_aggregate_uint64_mark_range("v", 0, 0) }
        expect_raises(CrystalClick::UnsupportedFormatError) { scalar.read_numeric_mark_range("v", 0, scalar.mark_count, UInt64) }
        w161_wide_assert_table_batches(scalar_part, false, values, nullable_values, keys)
        w161_wide_assert_catalog_values(scalar_part, function_name, false, values, nullable_values, index.to_u8)

        nullable = CrystalClick::WidePart.open_typed(nullable_part, "v")
        nullable.column_type.should eq("Nullable(SimpleAggregateFunction(#{function_name}, UInt64))")
        nullable.row_count.should eq(6_u64)
        nullable.mark_row_counts.should eq([2_u64, 2_u64, 2_u64])
        nullable.read_nullable_simple_aggregate_uint64_mark_range("v", 0, nullable.mark_count).should eq(nullable_values)
        nullable.read_nullable_simple_aggregate_uint64_mark_range("v", 1, 1).should eq(nullable_values[2, 2])
        expect_raises(CrystalClick::BoundsError) { nullable.read_nullable_simple_aggregate_uint64_mark_range("v", 0, 0) }
        expect_raises(CrystalClick::UnsupportedFormatError) { nullable.read_nullable_numeric_mark_range("v", 0, nullable.mark_count, UInt64) }
        w161_wide_assert_table_batches(nullable_part, true, values, nullable_values, keys)
        w161_wide_assert_catalog_values(nullable_part, function_name, true, values, nullable_values, index.to_u8)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "leaves primitive UInt64 and different SimpleAggregateFunction identities closed to each other" do
    parent = File.tempname("crystal-click-simple-aggregate-w161-identity")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64]
    values = [0x8000_0000_0000_0000_u64, UInt64::MAX]
    key_slice = keys.to_unsafe.to_slice(keys.size)
    value_slice = values.to_unsafe.to_slice(values.size)
    begin
      minimum_parent = File.join(parent, "min")
      maximum_parent = File.join(parent, "max")
      Dir.mkdir(minimum_parent)
      Dir.mkdir(maximum_parent)
      minimum = File.join(minimum_parent, "all_1_1_0")
      maximum = File.join(maximum_parent, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_simple_aggregate_pair(
        minimum, "pk", key_slice, "v", value_slice,
        CrystalClick::BinarySimpleAggregateType::Function::Min, rows_per_mark: 1
      )
      CrystalClick::WidePartWriter.write_uint64_simple_aggregate_pair(
        maximum, "pk", key_slice, "v", value_slice,
        CrystalClick::BinarySimpleAggregateType::Function::Max, rows_per_mark: 1
      )
      min_reader = CrystalClick::WidePart.open_typed(minimum, "v")
      max_reader = CrystalClick::WidePart.open_typed(maximum, "v")
      min_reader.column_type.should eq("SimpleAggregateFunction(min, UInt64)")
      max_reader.column_type.should eq("SimpleAggregateFunction(max, UInt64)")
      w161_wide_stream_bytes(minimum, "v").should eq(w161_wide_stream_bytes(maximum, "v"))
      expect_raises(CrystalClick::UnsupportedFormatError) { min_reader.read_numeric_mark_range("v", 0, 2, UInt64) }
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "does not leave a destination when the public Nullable writer rejects mismatched inputs" do
    parent = File.tempname("crystal-click-simple-aggregate-w161-writer-cleanup")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64]
    values = [1_u64] of UInt64?
    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_nullable_simple_aggregate_pair(
          destination,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "v",
          values.to_unsafe.to_slice(values.size),
          CrystalClick::BinarySimpleAggregateType::Function::Min,
          rows_per_mark: 1
        )
      end
      File.exists?(destination).should be_false
      Dir.children(parent).should eq([] of String)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
