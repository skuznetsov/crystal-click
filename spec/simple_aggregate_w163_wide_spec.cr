require "./spec_helper"
require "file_utils"
require "./support/simple_aggregate_w163_types"

module CrystalClick::WidePartWriter
  # Exercise the existing typed-pair bridge with a declaration intentionally
  # different from the payload's nominal carrier.
  def self.w163_test_write_declared_typed_pair(
    destination : String,
    keys : Slice(UInt64),
    values : Slice(T),
    type_name : String,
  ) : String forall T
    write_uint64_typed_pair_with_type(destination, "pk", keys, "v", values, type_name, 2)
  end
end

private def w163_assert_scalar_values(expected : Array(T), actual : Array(T)) : Nil forall T
  {% if T == Float32 %}
    actual.map(&.unsafe_as(UInt32)).should eq(expected.map(&.unsafe_as(UInt32)))
  {% elsif T == Float64 %}
    actual.map(&.unsafe_as(UInt64)).should eq(expected.map(&.unsafe_as(UInt64)))
  {% else %}
    actual.should eq(expected)
  {% end %}
end

private def w163_assert_nullable_values(expected : Array(T?), actual : Array(T?)) : Nil forall T
  {% if T == Float32 %}
    actual.map { |value| value.nil? ? nil : value.not_nil!.unsafe_as(UInt32) }
      .should eq(expected.map { |value| value.nil? ? nil : value.not_nil!.unsafe_as(UInt32) })
  {% elsif T == Float64 %}
    actual.map { |value| value.nil? ? nil : value.not_nil!.unsafe_as(UInt64) }
      .should eq(expected.map { |value| value.nil? ? nil : value.not_nil!.unsafe_as(UInt64) })
  {% else %}
    actual.should eq(expected)
  {% end %}
end

private def w163_create_catalog(root : String, part : String, value_type : String) : Nil
  database_uuid = "16300000-0000-4000-8000-000000000011"
  table_uuid = "16300000-0000-4000-8000-000000000012"
  metadata_path = File.join(root, "metadata")
  database_path = File.join(root, "store", database_uuid[0, 3], database_uuid)
  table_path = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(metadata_path)
  FileUtils.mkdir_p(database_path)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(metadata_path, "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  File.write(
    File.join(database_path, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `v` #{value_type}\n)\nENGINE = MergeTree\nORDER BY pk\n"
  )
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  FileUtils.cp_r(part, File.join(table_path, "all_1_1_0"))
  nil
end

private def w163_check_scalar_carrier(
  root : String,
  carrier_name : String,
  suffix : String,
  values : Array(T),
  type : T.class,
) : Nil forall T
  keys = W163_SIMPLE_AGGREGATE_KEYS
  scalar_parent = File.join(root, "scalar_#{suffix}")
  Dir.mkdir(scalar_parent)
  scalar_part = File.join(scalar_parent, "all_1_1_0")
  scalar_type = "SimpleAggregateFunction(any, #{carrier_name})"
  CrystalClick::WidePartWriter.write_uint64_simple_aggregate_pair(
    scalar_part, "pk", keys.to_unsafe.to_slice(keys.size), "v",
    values.to_unsafe.to_slice(values.size), CrystalClick::BinarySimpleAggregateType::Function::Any,
    rows_per_mark: 2
  ).should eq(scalar_part)

  reader = CrystalClick::WidePart.open_typed(scalar_part, "v")
  reader.column_type.should eq(scalar_type)
  w163_assert_scalar_values(values, reader.read_simple_aggregate_numeric_mark_range("v", 0, reader.mark_count, type))
  w163_assert_scalar_values(values[2, 2], reader.read_simple_aggregate_numeric_mark_range("v", 1, 1, type))
  expect_raises(CrystalClick::UnsupportedFormatError) do
    reader.read_numeric_mark_range("v", 0, reader.mark_count, type)
  end

  table = CrystalClick::WidePartTable.open_selected_typed([scalar_part], ["pk", "v"])
  table.column_types.should eq([{"pk", "UInt64"}, {"v", scalar_type}])
  observed = [] of T
  table.scan_typed(batch_rows: 2) do |batch|
    size = batch.values_for("pk", UInt64).size
    w163_assert_scalar_values(values[batch.part_row_offset.to_i, size], batch.simple_aggregate_values_for("v", type).to_a)
    expect_raises(CrystalClick::UnsupportedFormatError) { batch.values_for("v", type) }
    expect_raises(CrystalClick::UnsupportedFormatError) { batch.nullable_simple_aggregate_values_for("v", type) }
    observed.concat(batch.simple_aggregate_values_for("v", type).to_a)
  end
  w163_assert_scalar_values(values, observed)

  catalog_root = File.join(root, "catalog_scalar_#{suffix}")
  w163_create_catalog(catalog_root, scalar_part, scalar_type)
  offline = CrystalClick::OfflineCatalog.open(catalog_root).table("lab", "events")
  offline.columns.find { |column| column.name == "v" }.not_nil!.type.should eq(scalar_type)
  w163_assert_scalar_values(values, offline["v"].values.map { |value| value.as(T) })
end

private def w163_check_nullable_carrier(
  root : String,
  carrier_name : String,
  suffix : String,
  values : Array(T?),
  type : T.class,
) : Nil forall T
  keys = W163_SIMPLE_AGGREGATE_KEYS
  nullable_parent = File.join(root, "nullable_#{suffix}")
  Dir.mkdir(nullable_parent)
  nullable_part = File.join(nullable_parent, "all_1_1_0")
  scalar_type = "SimpleAggregateFunction(any, #{carrier_name})"
  nullable_type = "Nullable(#{scalar_type})"
  CrystalClick::WidePartWriter.write_uint64_nullable_simple_aggregate_pair(
    nullable_part, "pk", keys.to_unsafe.to_slice(keys.size), "v",
    values.to_unsafe.to_slice(values.size), CrystalClick::BinarySimpleAggregateType::Function::Any,
    rows_per_mark: 2
  ).should eq(nullable_part)

  reader = CrystalClick::WidePart.open_typed(nullable_part, "v")
  reader.column_type.should eq(nullable_type)
  w163_assert_nullable_values(values, reader.read_nullable_simple_aggregate_numeric_mark_range("v", 0, reader.mark_count, type))
  w163_assert_nullable_values(values[2, 2], reader.read_nullable_simple_aggregate_numeric_mark_range("v", 1, 1, type))
  expect_raises(CrystalClick::UnsupportedFormatError) do
    reader.read_nullable_numeric_mark_range("v", 0, reader.mark_count, type)
  end

  table = CrystalClick::WidePartTable.open_selected_typed([nullable_part], ["pk", "v"])
  table.column_types.should eq([{"pk", "UInt64"}, {"v", nullable_type}])
  observed = [] of T?
  table.scan_typed(batch_rows: 2) do |batch|
    size = batch.values_for("pk", UInt64).size
    expected = values[batch.part_row_offset.to_i, size]
    w163_assert_nullable_values(expected, batch.nullable_simple_aggregate_values_for("v", type).to_a)
    expect_raises(CrystalClick::UnsupportedFormatError) { batch.nullable_values_for("v", type) }
    expect_raises(CrystalClick::UnsupportedFormatError) { batch.simple_aggregate_values_for("v", type) }
    observed.concat(batch.nullable_simple_aggregate_values_for("v", type).to_a)
  end
  w163_assert_nullable_values(values, observed)

  catalog_root = File.join(root, "catalog_nullable_#{suffix}")
  w163_create_catalog(catalog_root, nullable_part, nullable_type)
  offline = CrystalClick::OfflineCatalog.open(catalog_root).table("lab", "events")
  offline.columns.find { |column| column.name == "v" }.not_nil!.type.should eq(nullable_type)
  w163_assert_nullable_values(values, offline["v"].values.map { |value| value.as(T?) })
end

private def w163_check_wrong_scalar_pair(
  left_name : String,
  left_type : T.class,
  left_values : Array(T),
  right_name : String,
  right_type : U.class,
  right_values : Array(U),
  root : String,
  label : String,
) : Nil forall T, U
  keys = W163_SIMPLE_AGGREGATE_KEYS
  left_parent = File.join(root, "wrong_#{label}_left")
  right_parent = File.join(root, "wrong_#{label}_right")
  Dir.mkdir(left_parent)
  Dir.mkdir(right_parent)
  left_part = File.join(left_parent, "all_1_1_0")
  right_part = File.join(right_parent, "all_1_1_0")
  function = CrystalClick::BinarySimpleAggregateType::Function::Any
  CrystalClick::WidePartWriter.write_uint64_simple_aggregate_pair(
    left_part, "pk", keys.to_unsafe.to_slice(keys.size), "v", left_values.to_unsafe.to_slice(left_values.size), function, rows_per_mark: 2
  )
  CrystalClick::WidePartWriter.write_uint64_simple_aggregate_pair(
    right_part, "pk", keys.to_unsafe.to_slice(keys.size), "v", right_values.to_unsafe.to_slice(right_values.size), function, rows_per_mark: 2
  )

  left = CrystalClick::WidePart.open_typed(left_part, "v")
  right = CrystalClick::WidePart.open_typed(right_part, "v")
  expect_raises(CrystalClick::UnsupportedFormatError) { left.read_simple_aggregate_numeric_mark_range("v", 0, left.mark_count, right_type) }
  expect_raises(CrystalClick::UnsupportedFormatError) { right.read_simple_aggregate_numeric_mark_range("v", 0, right.mark_count, left_type) }
  expect_raises(CrystalClick::UnsupportedFormatError) { left.read_nullable_simple_aggregate_numeric_mark_range("v", 0, left.mark_count, left_type) }
  expect_raises(CrystalClick::UnsupportedFormatError) { right.read_nullable_simple_aggregate_numeric_mark_range("v", 0, right.mark_count, right_type) }
  expect_raises(CrystalClick::UnsupportedFormatError) { left.read_simple_aggregate_uint64_mark_range("v", 0, left.mark_count) } unless left_name == "UInt64"
  expect_raises(CrystalClick::UnsupportedFormatError) { right.read_simple_aggregate_uint64_mark_range("v", 0, right.mark_count) } unless right_name == "UInt64"

  left_table = CrystalClick::WidePartTable.open_selected_typed([left_part], ["pk", "v"])
  left_table.scan_typed do |batch|
    expect_raises(CrystalClick::UnsupportedFormatError) { batch.simple_aggregate_values_for("v", right_type) }
    expect_raises(CrystalClick::UnsupportedFormatError) { batch.nullable_simple_aggregate_values_for("v", left_type) }
    expect_raises(CrystalClick::UnsupportedFormatError) { batch.simple_aggregate_uint64s_for("v") } unless left_name == "UInt64"
  end
  right_table = CrystalClick::WidePartTable.open_selected_typed([right_part], ["pk", "v"])
  right_table.scan_typed do |batch|
    expect_raises(CrystalClick::UnsupportedFormatError) { batch.simple_aggregate_values_for("v", left_type) }
    expect_raises(CrystalClick::UnsupportedFormatError) { batch.nullable_simple_aggregate_values_for("v", right_type) }
    expect_raises(CrystalClick::UnsupportedFormatError) { batch.simple_aggregate_uint64s_for("v") } unless right_name == "UInt64"
  end
end

private def w163_check_wrong_nullable_pair(
  left_name : String,
  left_type : T.class,
  left_values : Array(T?),
  right_name : String,
  right_type : U.class,
  right_values : Array(U?),
  root : String,
  label : String,
) : Nil forall T, U
  keys = W163_SIMPLE_AGGREGATE_KEYS
  left_parent = File.join(root, "wrong_nullable_#{label}_left")
  right_parent = File.join(root, "wrong_nullable_#{label}_right")
  Dir.mkdir(left_parent)
  Dir.mkdir(right_parent)
  left_part = File.join(left_parent, "all_1_1_0")
  right_part = File.join(right_parent, "all_1_1_0")
  CrystalClick::WidePartWriter.write_uint64_nullable_simple_aggregate_pair(
    left_part, "pk", keys.to_unsafe.to_slice(keys.size), "v", left_values.to_unsafe.to_slice(left_values.size),
    CrystalClick::BinarySimpleAggregateType::Function::Any, rows_per_mark: 2
  )
  CrystalClick::WidePartWriter.write_uint64_nullable_simple_aggregate_pair(
    right_part, "pk", keys.to_unsafe.to_slice(keys.size), "v", right_values.to_unsafe.to_slice(right_values.size),
    CrystalClick::BinarySimpleAggregateType::Function::Any, rows_per_mark: 2
  )

  left = CrystalClick::WidePart.open_typed(left_part, "v")
  right = CrystalClick::WidePart.open_typed(right_part, "v")
  expect_raises(CrystalClick::UnsupportedFormatError) { left.read_nullable_simple_aggregate_numeric_mark_range("v", 0, left.mark_count, right_type) }
  expect_raises(CrystalClick::UnsupportedFormatError) { right.read_nullable_simple_aggregate_numeric_mark_range("v", 0, right.mark_count, left_type) }
  expect_raises(CrystalClick::UnsupportedFormatError) { left.read_simple_aggregate_numeric_mark_range("v", 0, left.mark_count, left_type) }
  expect_raises(CrystalClick::UnsupportedFormatError) { right.read_simple_aggregate_numeric_mark_range("v", 0, right.mark_count, right_type) }
  expect_raises(CrystalClick::UnsupportedFormatError) { left.read_nullable_simple_aggregate_uint64_mark_range("v", 0, left.mark_count) } unless left_name == "UInt64"
  expect_raises(CrystalClick::UnsupportedFormatError) { right.read_nullable_simple_aggregate_uint64_mark_range("v", 0, right.mark_count) } unless right_name == "UInt64"

  left_table = CrystalClick::WidePartTable.open_selected_typed([left_part], ["pk", "v"])
  left_table.scan_typed do |batch|
    expect_raises(CrystalClick::UnsupportedFormatError) { batch.nullable_simple_aggregate_values_for("v", right_type) }
    expect_raises(CrystalClick::UnsupportedFormatError) { batch.simple_aggregate_values_for("v", left_type) }
    expect_raises(CrystalClick::UnsupportedFormatError) { batch.nullable_simple_aggregate_uint64s_for("v") } unless left_name == "UInt64"
  end
  right_table = CrystalClick::WidePartTable.open_selected_typed([right_part], ["pk", "v"])
  right_table.scan_typed do |batch|
    expect_raises(CrystalClick::UnsupportedFormatError) { batch.nullable_simple_aggregate_values_for("v", left_type) }
    expect_raises(CrystalClick::UnsupportedFormatError) { batch.simple_aggregate_values_for("v", right_type) }
    expect_raises(CrystalClick::UnsupportedFormatError) { batch.nullable_simple_aggregate_uint64s_for("v") } unless right_name == "UInt64"
  end
end

describe "W163 SimpleAggregateFunction numeric runtime" do
  it "round-trips every standard any carrier through scalar and outer Nullable runtime consumers" do
    root = File.tempname("crystal-click-simple-aggregate-w163-runtime")
    Dir.mkdir(root)
    begin
      w163_check_scalar_carrier(root, "UInt8", "u8", W163_LIBRARY_UINT8_VALUES, UInt8)
      w163_check_scalar_carrier(root, "UInt16", "u16", W163_LIBRARY_UINT16_VALUES, UInt16)
      w163_check_scalar_carrier(root, "UInt32", "u32", W163_LIBRARY_UINT32_VALUES, UInt32)
      w163_check_scalar_carrier(root, "UInt64", "u64", W163_LIBRARY_UINT64_VALUES, UInt64)
      w163_check_scalar_carrier(root, "Int8", "i8", W163_LIBRARY_INT8_VALUES, Int8)
      w163_check_scalar_carrier(root, "Int16", "i16", W163_LIBRARY_INT16_VALUES, Int16)
      w163_check_scalar_carrier(root, "Int32", "i32", W163_LIBRARY_INT32_VALUES, Int32)
      w163_check_scalar_carrier(root, "Int64", "i64", W163_LIBRARY_INT64_VALUES, Int64)
      w163_check_scalar_carrier(root, "Float32", "f32", W163_LIBRARY_FLOAT32_VALUES, Float32)
      w163_check_scalar_carrier(root, "Float64", "f64", W163_LIBRARY_FLOAT64_VALUES, Float64)

      w163_check_nullable_carrier(root, "UInt8", "u8", W163SimpleAggregateTestSupport.nullable_values(W163_LIBRARY_UINT8_VALUES), UInt8)
      w163_check_nullable_carrier(root, "UInt16", "u16", W163SimpleAggregateTestSupport.nullable_values(W163_LIBRARY_UINT16_VALUES), UInt16)
      w163_check_nullable_carrier(root, "UInt32", "u32", W163SimpleAggregateTestSupport.nullable_values(W163_LIBRARY_UINT32_VALUES), UInt32)
      w163_check_nullable_carrier(root, "UInt64", "u64", W163SimpleAggregateTestSupport.nullable_values(W163_LIBRARY_UINT64_VALUES), UInt64)
      w163_check_nullable_carrier(root, "Int8", "i8", W163SimpleAggregateTestSupport.nullable_values(W163_LIBRARY_INT8_VALUES), Int8)
      w163_check_nullable_carrier(root, "Int16", "i16", W163SimpleAggregateTestSupport.nullable_values(W163_LIBRARY_INT16_VALUES), Int16)
      w163_check_nullable_carrier(root, "Int32", "i32", W163SimpleAggregateTestSupport.nullable_values(W163_LIBRARY_INT32_VALUES), Int32)
      w163_check_nullable_carrier(root, "Int64", "i64", W163SimpleAggregateTestSupport.nullable_values(W163_LIBRARY_INT64_VALUES), Int64)
      w163_check_nullable_carrier(root, "Float32", "f32", W163SimpleAggregateTestSupport.nullable_values(W163_LIBRARY_FLOAT32_VALUES), Float32)
      w163_check_nullable_carrier(root, "Float64", "f64", W163SimpleAggregateTestSupport.nullable_values(W163_LIBRARY_FLOAT64_VALUES), Float64)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "keeps equal-width semantic carriers nominal in direct readers, batches, and legacy UInt64 accessors" do
    root = File.tempname("crystal-click-simple-aggregate-w163-carrier-mismatch")
    Dir.mkdir(root)
    begin
      w163_check_wrong_scalar_pair("UInt64", UInt64, W163_LIBRARY_UINT64_VALUES, "Float64", Float64, W163_LIBRARY_FLOAT64_VALUES, root, "u64_f64")
      w163_check_wrong_scalar_pair("Int32", Int32, W163_LIBRARY_INT32_VALUES, "Float32", Float32, W163_LIBRARY_FLOAT32_VALUES, root, "i32_f32")
      w163_check_wrong_nullable_pair(
        "UInt64", UInt64, W163SimpleAggregateTestSupport.nullable_values(W163_LIBRARY_UINT64_VALUES),
        "Float64", Float64, W163SimpleAggregateTestSupport.nullable_values(W163_LIBRARY_FLOAT64_VALUES), root, "u64_f64"
      )
      w163_check_wrong_nullable_pair(
        "Int32", Int32, W163SimpleAggregateTestSupport.nullable_values(W163_LIBRARY_INT32_VALUES),
        "Float32", Float32, W163SimpleAggregateTestSupport.nullable_values(W163_LIBRARY_FLOAT32_VALUES), root, "i32_f32"
      )
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects same-width payload and declaration mismatches before staging or publication" do
    root = File.tempname("crystal-click-simple-aggregate-w163-typed-mismatch")
    Dir.mkdir(root)
    keys = W163_SIMPLE_AGGREGATE_KEYS
    scalar_values = W163_LIBRARY_FLOAT64_VALUES
    nullable_values = W163SimpleAggregateTestSupport.nullable_values(scalar_values)
    begin
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.w163_test_write_declared_typed_pair(
          File.join(root, "scalar"), keys.to_unsafe.to_slice(keys.size),
          scalar_values.to_unsafe.to_slice(scalar_values.size), "SimpleAggregateFunction(any, UInt64)"
        )
      end
      Dir.children(root).should be_empty

      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.w163_test_write_declared_typed_pair(
          File.join(root, "nullable"), keys.to_unsafe.to_slice(keys.size),
          nullable_values.to_unsafe.to_slice(nullable_values.size), "Nullable(SimpleAggregateFunction(any, UInt64))"
        )
      end
      Dir.children(root).should be_empty
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects invalid pairs and unsupported public writer carriers before creating a part or stage" do
    root = File.tempname("crystal-click-simple-aggregate-w163-preflight")
    Dir.mkdir(root)
    keys = W163_SIMPLE_AGGREGATE_KEYS
    begin
      invalid = [
        {"sum_u32", CrystalClick::BinarySimpleAggregateType::Function::Sum},
      ]
      invalid.each do |label, function|
        destination = File.join(root, label)
        expect_raises(ArgumentError) do
          CrystalClick::WidePartWriter.write_uint64_simple_aggregate_pair(
            destination, "pk", keys.to_unsafe.to_slice(keys.size), "v",
            W163_LIBRARY_UINT32_VALUES.to_unsafe.to_slice(W163_LIBRARY_UINT32_VALUES.size), function
          )
        end
        File.exists?(destination).should be_false
        Dir.children(root).should be_empty
      end

      destination = File.join(root, "group_bit_float32")
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_simple_aggregate_pair(
          destination, "pk", keys.to_unsafe.to_slice(keys.size), "v",
          W163_LIBRARY_FLOAT32_VALUES.to_unsafe.to_slice(W163_LIBRARY_FLOAT32_VALUES.size),
          CrystalClick::BinarySimpleAggregateType::Function::GroupBitAnd
        )
      end
      File.exists?(destination).should be_false
      Dir.children(root).should be_empty

      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_simple_aggregate_pair(
          File.join(root, "bool"), "pk", keys.to_unsafe.to_slice(keys.size), "v",
          [true, false, true, false, true, false].to_unsafe.to_slice(6), CrystalClick::BinarySimpleAggregateType::Function::Any
        )
      end
      bfloat_values = [0_u16, 0x8000_u16, 0x3f80_u16, 0x7fc1_u16, 0xffa2_u16, 1_u16].map { |bits| CrystalClick::BFloat16Value.new(bits) }
      [
        CrystalClick::BinarySimpleAggregateType::Function::Sum,
        CrystalClick::BinarySimpleAggregateType::Function::GroupBitAnd,
      ].each_with_index do |function, index|
        expect_raises(ArgumentError) do
          CrystalClick::WidePartWriter.write_uint64_simple_aggregate_pair(
            File.join(root, "invalid_bfloat_#{index}"), "pk", keys.to_unsafe.to_slice(keys.size), "v",
            bfloat_values.to_unsafe.to_slice(bfloat_values.size), function
          )
        end
      end
      Dir.children(root).should be_empty
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "preserves Float32 and Float64 negative-zero and NaN payload bits across scalar and Nullable access" do
    root = File.tempname("crystal-click-simple-aggregate-w163-float-bits")
    Dir.mkdir(root)
    keys = W163_SIMPLE_AGGREGATE_KEYS
    begin
      f32_bits = [0x8000_0000_u32, 0x7fc1_2345_u32, 0xffc5_4321_u32, 0x3fc0_0000_u32, 0x0000_0001_u32, 0x7f80_0000_u32]
      f32_values = f32_bits.map(&.unsafe_as(Float32))
      f32_nullable = W163SimpleAggregateTestSupport.nullable_values(f32_values)
      scalar32 = File.join(root, "float32")
      nullable32 = File.join(root, "nullable_float32")
      CrystalClick::WidePartWriter.write_uint64_simple_aggregate_pair(
        scalar32, "pk", keys.to_unsafe.to_slice(keys.size), "v", f32_values.to_unsafe.to_slice(f32_values.size),
        CrystalClick::BinarySimpleAggregateType::Function::Any, rows_per_mark: 2
      )
      CrystalClick::WidePartWriter.write_uint64_nullable_simple_aggregate_pair(
        nullable32, "pk", keys.to_unsafe.to_slice(keys.size), "v", f32_nullable.to_unsafe.to_slice(f32_nullable.size),
        CrystalClick::BinarySimpleAggregateType::Function::Any, rows_per_mark: 2
      )
      f32_scalar_reader = CrystalClick::WidePart.open_typed(scalar32, "v")
      f32_nullable_reader = CrystalClick::WidePart.open_typed(nullable32, "v")
      f32_scalar_reader.read_simple_aggregate_numeric_mark_range("v", 0, f32_scalar_reader.mark_count, Float32).map(&.unsafe_as(UInt32)).should eq(f32_bits)
      f32_nullable_reader.read_nullable_simple_aggregate_numeric_mark_range("v", 0, f32_nullable_reader.mark_count, Float32).map { |value| value.try(&.unsafe_as(UInt32)) }
        .should eq(f32_nullable.map { |value| value.try(&.unsafe_as(UInt32)) })

      f64_bits = [0x8000_0000_0000_0000_u64, 0x7ff8_1234_5678_9abc_u64, 0xfff8_abcd_0123_4567_u64, 0x3ff8_0000_0000_0000_u64, 0x0000_0000_0000_0001_u64, 0x7ff0_0000_0000_0000_u64]
      f64_values = f64_bits.map(&.unsafe_as(Float64))
      f64_nullable = W163SimpleAggregateTestSupport.nullable_values(f64_values)
      scalar64 = File.join(root, "float64")
      nullable64 = File.join(root, "nullable_float64")
      CrystalClick::WidePartWriter.write_uint64_simple_aggregate_pair(
        scalar64, "pk", keys.to_unsafe.to_slice(keys.size), "v", f64_values.to_unsafe.to_slice(f64_values.size),
        CrystalClick::BinarySimpleAggregateType::Function::Any, rows_per_mark: 2
      )
      CrystalClick::WidePartWriter.write_uint64_nullable_simple_aggregate_pair(
        nullable64, "pk", keys.to_unsafe.to_slice(keys.size), "v", f64_nullable.to_unsafe.to_slice(f64_nullable.size),
        CrystalClick::BinarySimpleAggregateType::Function::Any, rows_per_mark: 2
      )
      f64_scalar_reader = CrystalClick::WidePart.open_typed(scalar64, "v")
      f64_nullable_reader = CrystalClick::WidePart.open_typed(nullable64, "v")
      f64_scalar_reader.read_simple_aggregate_numeric_mark_range("v", 0, f64_scalar_reader.mark_count, Float64).map(&.unsafe_as(UInt64)).should eq(f64_bits)
      f64_nullable_reader.read_nullable_simple_aggregate_numeric_mark_range("v", 0, f64_nullable_reader.mark_count, Float64).map { |value| value.try(&.unsafe_as(UInt64)) }
        .should eq(f64_nullable.map { |value| value.try(&.unsafe_as(UInt64)) })
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
