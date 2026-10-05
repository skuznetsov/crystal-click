require "./spec_helper"
require "file_utils"
require "./support/simple_aggregate_w164_types"

module CrystalClick::WidePartWriter
  # Exercise the existing private typed-pair boundary with an independently
  # supplied semantic declaration so same-width payload aliases are tested
  # before any stage can be created.
  def self.w164_test_write_typed_pair_with_type(
    destination : String,
    keys : Slice(UInt64),
    values : Slice(T),
    type_name : String,
  ) : String forall T
    write_uint64_typed_pair_with_type(destination, "pk", keys, "v", values, type_name, 2)
  end
end

private def w164_assert_scalar_values(expected : Array(T), actual : Array(T)) : Nil forall T
  {% if T == CrystalClick::UInt256Value || T == CrystalClick::Int256Value %}
    actual.map { |value| {value.low, value.high} }.should eq(expected.map { |value| {value.low, value.high} })
  {% elsif T == CrystalClick::BFloat16Value %}
    actual.map(&.bits).should eq(expected.map(&.bits))
  {% else %}
    actual.should eq(expected)
  {% end %}
end

private def w164_assert_nullable_values(expected : Array(T?), actual : Array(T?)) : Nil forall T
  {% if T == CrystalClick::UInt256Value || T == CrystalClick::Int256Value %}
    actual.map { |value| value.try { |entry| {entry.low, entry.high} } }
      .should eq(expected.map { |value| value.try { |entry| {entry.low, entry.high} } })
  {% elsif T == CrystalClick::BFloat16Value %}
    actual.map { |value| value.try(&.bits) }.should eq(expected.map { |value| value.try(&.bits) })
  {% else %}
    actual.should eq(expected)
  {% end %}
end

private def w164_keys(size : Int32) : Array(UInt64)
  Array(UInt64).new(size) { |index| index.to_u64 + 1_u64 }
end

private def w164_assert_inferred_writer_refused(root : String, label : String, values : Array(T)) : Nil forall T
  parent = File.join(root, label)
  Dir.mkdir(parent)
  keys = w164_keys(values.size)
  expect_raises(CrystalClick::UnsupportedFormatError) do
    CrystalClick::WidePartWriter.write_uint64_typed_pair(
      File.join(parent, "all_1_1_0"), "pk", keys.to_unsafe.to_slice(keys.size), "v",
      values.to_unsafe.to_slice(values.size), rows_per_mark: 2
    )
  end
  Dir.children(parent).should be_empty
end

private def w164_create_catalog(root : String, part : String, value_type : String) : Nil
  database_uuid = "16400000-0000-4000-8000-000000000011"
  table_uuid = "16400000-0000-4000-8000-000000000012"
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

private def w164_assert_primitive_rejected(reader : CrystalClick::WidePart, carrier_name : String, nullable : Bool) : Nil
  case carrier_name
  when "UInt128"
    if nullable
      expect_raises(CrystalClick::UnsupportedFormatError) { reader.read_nullable_uint128_raw_mark_range("v", 0, reader.mark_count) }
    else
      expect_raises(CrystalClick::UnsupportedFormatError) { reader.read_uint128_raw_mark_range("v", 0, reader.mark_count) }
    end
  when "Int128"
    if nullable
      expect_raises(CrystalClick::UnsupportedFormatError) { reader.read_nullable_int128_raw_mark_range("v", 0, reader.mark_count) }
    else
      expect_raises(CrystalClick::UnsupportedFormatError) { reader.read_int128_raw_mark_range("v", 0, reader.mark_count) }
    end
  when "UInt256"
    if nullable
      expect_raises(CrystalClick::UnsupportedFormatError) { reader.read_nullable_uint256_raw_mark_range("v", 0, reader.mark_count) }
    else
      expect_raises(CrystalClick::UnsupportedFormatError) { reader.read_uint256_raw_mark_range("v", 0, reader.mark_count) }
    end
  when "Int256"
    if nullable
      expect_raises(CrystalClick::UnsupportedFormatError) { reader.read_nullable_int256_raw_mark_range("v", 0, reader.mark_count) }
    else
      expect_raises(CrystalClick::UnsupportedFormatError) { reader.read_int256_raw_mark_range("v", 0, reader.mark_count) }
    end
  when "BFloat16"
    if nullable
      expect_raises(CrystalClick::UnsupportedFormatError) { reader.read_nullable_bfloat16_mark_range("v", 0, reader.mark_count) }
      expect_raises(CrystalClick::UnsupportedFormatError) { reader.read_nullable_numeric_mark_range("v", 0, reader.mark_count, UInt16) }
    else
      expect_raises(CrystalClick::UnsupportedFormatError) { reader.read_bfloat16_mark_range("v", 0, reader.mark_count) }
      expect_raises(CrystalClick::UnsupportedFormatError) { reader.read_numeric_mark_range("v", 0, reader.mark_count, UInt16) }
    end
  else
    raise "unknown W164 carrier: #{carrier_name}"
  end
end

private def w164_check_scalar_carrier(
  root : String,
  carrier_name : String,
  suffix : String,
  values : Array(T),
  type : T.class,
) : Nil forall T
  keys = w164_keys(values.size)
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
  w164_assert_scalar_values(values, reader.read_simple_aggregate_numeric_mark_range("v", 0, reader.mark_count, type))
  w164_assert_scalar_values(values[2, 2], reader.read_simple_aggregate_numeric_mark_range("v", 1, 1, type))
  expect_raises(CrystalClick::UnsupportedFormatError) do
    reader.read_nullable_simple_aggregate_numeric_mark_range("v", 0, reader.mark_count, type)
  end
  w164_assert_primitive_rejected(reader, carrier_name, false)
  expect_raises(CrystalClick::UnsupportedFormatError) { reader.read_simple_aggregate_uint64_mark_range("v", 0, reader.mark_count) }

  table = CrystalClick::WidePartTable.open_selected_typed([scalar_part], ["pk", "v"])
  table.column_types.should eq([{"pk", "UInt64"}, {"v", scalar_type}])
  observed = [] of T
  table.scan_typed(batch_rows: 2) do |batch|
    size = batch.values_for("pk", UInt64).size
    w164_assert_scalar_values(values[batch.part_row_offset.to_i, size], batch.simple_aggregate_values_for("v", type).to_a)
    expect_raises(CrystalClick::UnsupportedFormatError) { batch.values_for("v", type) }
    expect_raises(CrystalClick::UnsupportedFormatError) { batch.nullable_simple_aggregate_values_for("v", type) }
    expect_raises(CrystalClick::UnsupportedFormatError) { batch.simple_aggregate_uint64s_for("v") }
    observed.concat(batch.simple_aggregate_values_for("v", type).to_a)
  end
  w164_assert_scalar_values(values, observed)

  catalog_root = File.join(root, "catalog_scalar_#{suffix}")
  w164_create_catalog(catalog_root, scalar_part, scalar_type)
  offline = CrystalClick::OfflineCatalog.open(catalog_root).table("lab", "events")
  offline.columns.find { |column| column.name == "v" }.not_nil!.type.should eq(scalar_type)
  w164_assert_scalar_values(values, offline["v"].values.map { |value| value.as(T) })
end

private def w164_check_nullable_carrier(
  root : String,
  carrier_name : String,
  suffix : String,
  values : Array(T?),
  type : T.class,
) : Nil forall T
  keys = w164_keys(values.size)
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
  w164_assert_nullable_values(values, reader.read_nullable_simple_aggregate_numeric_mark_range("v", 0, reader.mark_count, type))
  w164_assert_nullable_values(values[2, 2], reader.read_nullable_simple_aggregate_numeric_mark_range("v", 1, 1, type))
  expect_raises(CrystalClick::UnsupportedFormatError) do
    reader.read_simple_aggregate_numeric_mark_range("v", 0, reader.mark_count, type)
  end
  w164_assert_primitive_rejected(reader, carrier_name, true)
  expect_raises(CrystalClick::UnsupportedFormatError) { reader.read_nullable_simple_aggregate_uint64_mark_range("v", 0, reader.mark_count) }

  table = CrystalClick::WidePartTable.open_selected_typed([nullable_part], ["pk", "v"])
  table.column_types.should eq([{"pk", "UInt64"}, {"v", nullable_type}])
  observed = [] of T?
  table.scan_typed(batch_rows: 2) do |batch|
    size = batch.values_for("pk", UInt64).size
    expected = values[batch.part_row_offset.to_i, size]
    w164_assert_nullable_values(expected, batch.nullable_simple_aggregate_values_for("v", type).to_a)
    expect_raises(CrystalClick::UnsupportedFormatError) { batch.nullable_values_for("v", type) }
    expect_raises(CrystalClick::UnsupportedFormatError) { batch.simple_aggregate_values_for("v", type) }
    expect_raises(CrystalClick::UnsupportedFormatError) { batch.nullable_simple_aggregate_uint64s_for("v") }
    observed.concat(batch.nullable_simple_aggregate_values_for("v", type).to_a)
  end
  w164_assert_nullable_values(values, observed)

  catalog_root = File.join(root, "catalog_nullable_#{suffix}")
  w164_create_catalog(catalog_root, nullable_part, nullable_type)
  offline = CrystalClick::OfflineCatalog.open(catalog_root).table("lab", "events")
  offline.columns.find { |column| column.name == "v" }.not_nil!.type.should eq(nullable_type)
  w164_assert_nullable_values(values, offline["v"].values.map { |value| value.as(T?) })
end

private def w164_check_wrong_scalar_pair(
  root : String,
  left_name : String,
  left_values : Array(T),
  left_type : T.class,
  right_name : String,
  right_values : Array(U),
  right_type : U.class,
  label : String,
) : Nil forall T, U
  keys = W164_SIMPLE_AGGREGATE_KEYS
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
  expect_raises(CrystalClick::UnsupportedFormatError) { left.read_simple_aggregate_uint64_mark_range("v", 0, left.mark_count) }
  expect_raises(CrystalClick::UnsupportedFormatError) { right.read_simple_aggregate_uint64_mark_range("v", 0, right.mark_count) }

  left_table = CrystalClick::WidePartTable.open_selected_typed([left_part], ["pk", "v"])
  left_table.scan_typed do |batch|
    expect_raises(CrystalClick::UnsupportedFormatError) { batch.simple_aggregate_values_for("v", right_type) }
    expect_raises(CrystalClick::UnsupportedFormatError) { batch.nullable_simple_aggregate_values_for("v", left_type) }
    expect_raises(CrystalClick::UnsupportedFormatError) { batch.simple_aggregate_uint64s_for("v") }
  end
  right_table = CrystalClick::WidePartTable.open_selected_typed([right_part], ["pk", "v"])
  right_table.scan_typed do |batch|
    expect_raises(CrystalClick::UnsupportedFormatError) { batch.simple_aggregate_values_for("v", left_type) }
    expect_raises(CrystalClick::UnsupportedFormatError) { batch.nullable_simple_aggregate_values_for("v", right_type) }
    expect_raises(CrystalClick::UnsupportedFormatError) { batch.simple_aggregate_uint64s_for("v") }
  end
end

private def w164_check_wrong_nullable_pair(
  root : String,
  left_name : String,
  left_values : Array(T?),
  left_type : T.class,
  right_name : String,
  right_values : Array(U?),
  right_type : U.class,
  label : String,
) : Nil forall T, U
  keys = W164_SIMPLE_AGGREGATE_KEYS
  left_parent = File.join(root, "wrong_nullable_#{label}_left")
  right_parent = File.join(root, "wrong_nullable_#{label}_right")
  Dir.mkdir(left_parent)
  Dir.mkdir(right_parent)
  left_part = File.join(left_parent, "all_1_1_0")
  right_part = File.join(right_parent, "all_1_1_0")
  function = CrystalClick::BinarySimpleAggregateType::Function::Any
  CrystalClick::WidePartWriter.write_uint64_nullable_simple_aggregate_pair(
    left_part, "pk", keys.to_unsafe.to_slice(keys.size), "v", left_values.to_unsafe.to_slice(left_values.size), function, rows_per_mark: 2
  )
  CrystalClick::WidePartWriter.write_uint64_nullable_simple_aggregate_pair(
    right_part, "pk", keys.to_unsafe.to_slice(keys.size), "v", right_values.to_unsafe.to_slice(right_values.size), function, rows_per_mark: 2
  )

  left = CrystalClick::WidePart.open_typed(left_part, "v")
  right = CrystalClick::WidePart.open_typed(right_part, "v")
  expect_raises(CrystalClick::UnsupportedFormatError) { left.read_nullable_simple_aggregate_numeric_mark_range("v", 0, left.mark_count, right_type) }
  expect_raises(CrystalClick::UnsupportedFormatError) { right.read_nullable_simple_aggregate_numeric_mark_range("v", 0, right.mark_count, left_type) }
  expect_raises(CrystalClick::UnsupportedFormatError) { left.read_simple_aggregate_numeric_mark_range("v", 0, left.mark_count, left_type) }
  expect_raises(CrystalClick::UnsupportedFormatError) { right.read_simple_aggregate_numeric_mark_range("v", 0, right.mark_count, right_type) }
  expect_raises(CrystalClick::UnsupportedFormatError) { left.read_nullable_simple_aggregate_uint64_mark_range("v", 0, left.mark_count) }
  expect_raises(CrystalClick::UnsupportedFormatError) { right.read_nullable_simple_aggregate_uint64_mark_range("v", 0, right.mark_count) }

  left_table = CrystalClick::WidePartTable.open_selected_typed([left_part], ["pk", "v"])
  left_table.scan_typed do |batch|
    expect_raises(CrystalClick::UnsupportedFormatError) { batch.nullable_simple_aggregate_values_for("v", right_type) }
    expect_raises(CrystalClick::UnsupportedFormatError) { batch.simple_aggregate_values_for("v", left_type) }
    expect_raises(CrystalClick::UnsupportedFormatError) { batch.nullable_simple_aggregate_uint64s_for("v") }
  end
  right_table = CrystalClick::WidePartTable.open_selected_typed([right_part], ["pk", "v"])
  right_table.scan_typed do |batch|
    expect_raises(CrystalClick::UnsupportedFormatError) { batch.nullable_simple_aggregate_values_for("v", left_type) }
    expect_raises(CrystalClick::UnsupportedFormatError) { batch.simple_aggregate_values_for("v", right_type) }
    expect_raises(CrystalClick::UnsupportedFormatError) { batch.nullable_simple_aggregate_uint64s_for("v") }
  end
end

describe "W164 SimpleAggregateFunction wide runtime" do
  it "round-trips all paired carriers through scalar and outer Nullable writer, reader, table, and catalog APIs" do
    root = File.tempname("crystal-click-simple-aggregate-w164-runtime")
    Dir.mkdir(root)
    begin
      w164_check_scalar_carrier(root, "UInt128", "u128", W164_LIBRARY_UINT128_VALUES, UInt128)
      w164_check_scalar_carrier(root, "Int128", "i128", W164_LIBRARY_INT128_VALUES, Int128)
      w164_check_scalar_carrier(root, "UInt256", "u256", W164_LIBRARY_UINT256_VALUES, CrystalClick::UInt256Value)
      w164_check_scalar_carrier(root, "Int256", "i256", W164_LIBRARY_INT256_VALUES, CrystalClick::Int256Value)
      w164_check_scalar_carrier(root, "BFloat16", "bf16", W164_LIBRARY_BFLOAT16_VALUES, CrystalClick::BFloat16Value)

      w164_check_nullable_carrier(root, "UInt128", "u128", W164SimpleAggregateTestSupport.nullable_values(W164_LIBRARY_UINT128_VALUES), UInt128)
      w164_check_nullable_carrier(root, "Int128", "i128", W164SimpleAggregateTestSupport.nullable_values(W164_LIBRARY_INT128_VALUES), Int128)
      w164_check_nullable_carrier(root, "UInt256", "u256", W164SimpleAggregateTestSupport.nullable_values(W164_LIBRARY_UINT256_VALUES), CrystalClick::UInt256Value)
      w164_check_nullable_carrier(root, "Int256", "i256", W164SimpleAggregateTestSupport.nullable_values(W164_LIBRARY_INT256_VALUES), CrystalClick::Int256Value)
      w164_check_nullable_carrier(root, "BFloat16", "bf16", W164SimpleAggregateTestSupport.nullable_values(W164_LIBRARY_BFLOAT16_VALUES), CrystalClick::BFloat16Value)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects same-width signedness and BFloat16-versus-UInt16 substitutions on semantic readers and batch accessors" do
    root = File.tempname("crystal-click-simple-aggregate-w164-carrier-mismatch")
    Dir.mkdir(root)
    uint16_values = [0x0102_u16, 0x1234_u16, 0x2345_u16, 0x789a_u16, 0xabcd_u16, 0xfedc_u16]
    begin
      w164_check_wrong_scalar_pair(root, "UInt128", W164_LIBRARY_UINT128_VALUES, UInt128, "Int128", W164_LIBRARY_INT128_VALUES, Int128, "128")
      w164_check_wrong_scalar_pair(root, "UInt256", W164_LIBRARY_UINT256_VALUES, CrystalClick::UInt256Value, "Int256", W164_LIBRARY_INT256_VALUES, CrystalClick::Int256Value, "256")
      w164_check_wrong_scalar_pair(root, "BFloat16", W164_LIBRARY_BFLOAT16_VALUES, CrystalClick::BFloat16Value, "UInt16", uint16_values, UInt16, "bf16_u16")
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects same-width signedness and BFloat16-versus-UInt16 substitutions in nullable semantic readers and batch accessors" do
    root = File.tempname("crystal-click-simple-aggregate-w164-nullable-carrier-mismatch")
    Dir.mkdir(root)
    uint16_values = [0x0102_u16, 0x1234_u16, 0x2345_u16, 0x789a_u16, 0xabcd_u16, 0xfedc_u16]
    begin
      w164_check_wrong_nullable_pair(root, "UInt128", W164SimpleAggregateTestSupport.nullable_values(W164_LIBRARY_UINT128_VALUES), UInt128, "Int128", W164SimpleAggregateTestSupport.nullable_values(W164_LIBRARY_INT128_VALUES), Int128, "128")
      w164_check_wrong_nullable_pair(root, "UInt256", W164SimpleAggregateTestSupport.nullable_values(W164_LIBRARY_UINT256_VALUES), CrystalClick::UInt256Value, "Int256", W164SimpleAggregateTestSupport.nullable_values(W164_LIBRARY_INT256_VALUES), CrystalClick::Int256Value, "256")
      w164_check_wrong_nullable_pair(root, "BFloat16", W164SimpleAggregateTestSupport.nullable_values(W164_LIBRARY_BFLOAT16_VALUES), CrystalClick::BFloat16Value, "UInt16", W164SimpleAggregateTestSupport.nullable_values(uint16_values), UInt16, "bf16_u16")
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects same-width declared-carrier mismatches before creating any typed-pair stage" do
    root = File.tempname("crystal-click-simple-aggregate-w164-writer-mismatch")
    Dir.mkdir(root)
    keys = w164_keys(W164_SIMPLE_AGGREGATE_KEYS.size)
    key_slice = keys.to_unsafe.to_slice(keys.size)
    begin
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.w164_test_write_typed_pair_with_type(
          File.join(root, "u128_declared_i128"), key_slice,
          W164_LIBRARY_UINT128_VALUES.to_unsafe.to_slice(W164_LIBRARY_UINT128_VALUES.size),
          "SimpleAggregateFunction(any, Int128)"
        )
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.w164_test_write_typed_pair_with_type(
          File.join(root, "u256_declared_i256"), key_slice,
          W164_LIBRARY_UINT256_VALUES.to_unsafe.to_slice(W164_LIBRARY_UINT256_VALUES.size),
          "SimpleAggregateFunction(any, Int256)"
        )
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.w164_test_write_typed_pair_with_type(
          File.join(root, "bf16_declared_u16"), key_slice,
          W164_LIBRARY_BFLOAT16_VALUES.to_unsafe.to_slice(W164_LIBRARY_BFLOAT16_VALUES.size),
          "SimpleAggregateFunction(any, UInt16)"
        )
      end

      nullable_uint128 = W164SimpleAggregateTestSupport.nullable_values(W164_LIBRARY_UINT128_VALUES)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.w164_test_write_typed_pair_with_type(
          File.join(root, "nullable_u128_declared_i128"), key_slice,
          nullable_uint128.to_unsafe.to_slice(nullable_uint128.size),
          "Nullable(SimpleAggregateFunction(any, Int128))"
        )
      end
      nullable_bfloat16 = W164SimpleAggregateTestSupport.nullable_values(W164_LIBRARY_BFLOAT16_VALUES)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.w164_test_write_typed_pair_with_type(
          File.join(root, "nullable_bf16_declared_u16"), key_slice,
          nullable_bfloat16.to_unsafe.to_slice(nullable_bfloat16.size),
          "Nullable(SimpleAggregateFunction(any, UInt16))"
        )
      end

      Dir.children(root).should be_empty
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "keeps W164 scalar and Nullable carriers out of inferred typed-writer admission" do
    root = File.tempname("crystal-click-simple-aggregate-w164-inference-guard")
    Dir.mkdir(root)
    begin
      w164_assert_inferred_writer_refused(root, "int128", W164_LIBRARY_INT128_VALUES)
      w164_assert_inferred_writer_refused(root, "uint128", W164_LIBRARY_UINT128_VALUES)
      w164_assert_inferred_writer_refused(root, "int256", W164_LIBRARY_INT256_VALUES)
      w164_assert_inferred_writer_refused(root, "uint256", W164_LIBRARY_UINT256_VALUES)
      w164_assert_inferred_writer_refused(root, "bfloat16", W164_LIBRARY_BFLOAT16_VALUES)
      w164_assert_inferred_writer_refused(root, "nullable_int128", W164SimpleAggregateTestSupport.nullable_values(W164_LIBRARY_INT128_VALUES))
      w164_assert_inferred_writer_refused(root, "nullable_uint128", W164SimpleAggregateTestSupport.nullable_values(W164_LIBRARY_UINT128_VALUES))
      w164_assert_inferred_writer_refused(root, "nullable_int256", W164SimpleAggregateTestSupport.nullable_values(W164_LIBRARY_INT256_VALUES))
      w164_assert_inferred_writer_refused(root, "nullable_uint256", W164SimpleAggregateTestSupport.nullable_values(W164_LIBRARY_UINT256_VALUES))
      w164_assert_inferred_writer_refused(root, "nullable_bfloat16", W164SimpleAggregateTestSupport.nullable_values(W164_LIBRARY_BFLOAT16_VALUES))
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "preserves BFloat16 signed zero, subnormal, infinity, and signaling and quiet NaN bits through scalar and Nullable paths" do
    root = File.tempname("crystal-click-simple-aggregate-w164-bfloat-bits")
    Dir.mkdir(root)
    bits = [
      0x0000_u16, 0x8000_u16,
      0x0001_u16, 0x8001_u16,
      0x7f80_u16, 0xff80_u16,
      0x7f81_u16, 0xff82_u16,
      0x7fc3_u16, 0xffc5_u16,
    ]
    values = bits.map { |raw| CrystalClick::BFloat16Value.new(raw) }
    nullable_values = values.map { |value| value.as(CrystalClick::BFloat16Value?) }
    nullable_values << nil
    begin
      w164_check_scalar_carrier(root, "BFloat16", "bf16_bits", values, CrystalClick::BFloat16Value)
      w164_check_nullable_carrier(root, "BFloat16", "bf16_bits", nullable_values, CrystalClick::BFloat16Value)
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
