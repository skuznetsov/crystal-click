require "./spec_helper"
require "file_utils"
require "./support/simple_aggregate_w169_types"

# A test-only reader probe mutates data only while a writer is validating its
# private staged part. The writer must reject the mismatch before publishing.
class CrystalClick::WidePart
  class_property w169_decimal_probe_enabled = false
  class_property w169_nullable_decimal_probe_enabled = false

  def read_simple_aggregate_decimal32_raw_mark_range(
    column : String, first_mark : Int, mark_count : Int,
    function : CrystalClick::BinarySimpleAggregateType::Function,
    precision : Int32, scale : Int32,
  ) : Array(Int32)
    observed = previous_def
    if CrystalClick::WidePart.w169_decimal_probe_enabled && !observed.empty?
      observed[0] &+= 1_i32
    end
    observed
  end

  def read_nullable_simple_aggregate_decimal32_raw_mark_range(
    column : String, first_mark : Int, mark_count : Int,
    function : CrystalClick::BinarySimpleAggregateType::Function,
    precision : Int32, scale : Int32,
  ) : Array(Int32?)
    observed = previous_def
    if CrystalClick::WidePart.w169_nullable_decimal_probe_enabled
      index = observed.index { |value| !value.nil? }
      if index
        observed[index] = observed[index].not_nil! &+ 1_i32
      end
    end
    observed
  end
end

private def w169_consumer_keys : Array(UInt64)
  [11_u64, 22_u64, 33_u64, 44_u64, 55_u64]
end

private def w169_consumer_type_name(
  function : CrystalClick::BinarySimpleAggregateType::Function,
  precision : Int32,
  scale : Int32,
  nullable : Bool = false,
) : String
  CrystalClick::SimpleAggregateDecimalStoragePlan.type_name(function, precision, scale, nullable)
end

private def w169_write_decimal_scalar(
  part : String,
  keys : Array(UInt64),
  values : Array(T),
  function : CrystalClick::BinarySimpleAggregateType::Function,
  precision : Int32,
  scale : Int32,
  rows_per_mark : Int32 = 2,
) : String forall T
  FileUtils.mkdir_p(File.dirname(part))
  key_slice = keys.to_unsafe.to_slice(keys.size)
  value_slice = values.to_unsafe.to_slice(values.size)
  {% if T == Int32 %}
    CrystalClick::WidePartWriter.write_uint64_simple_aggregate_decimal32_pair(
      part, "pk", key_slice, "v", value_slice, function, scale, rows_per_mark, precision: precision
    )
  {% elsif T == Int64 %}
    CrystalClick::WidePartWriter.write_uint64_simple_aggregate_decimal64_pair(
      part, "pk", key_slice, "v", value_slice, function, scale, rows_per_mark, precision: precision
    )
  {% elsif T == Int128 %}
    CrystalClick::WidePartWriter.write_uint64_simple_aggregate_decimal128_pair(
      part, "pk", key_slice, "v", value_slice, function, scale, rows_per_mark, precision: precision
    )
  {% elsif T == CrystalClick::Decimal256Value %}
    CrystalClick::WidePartWriter.write_uint64_simple_aggregate_decimal256_pair(
      part, "pk", key_slice, "v", value_slice, function, scale, rows_per_mark, precision: precision
    )
  {% else %}
    raise "unsupported W169 scalar test carrier"
  {% end %}
end

private def w169_write_decimal_nullable(
  part : String,
  keys : Array(UInt64),
  values : Array(T?),
  function : CrystalClick::BinarySimpleAggregateType::Function,
  precision : Int32,
  scale : Int32,
  rows_per_mark : Int32 = 2,
) : String forall T
  FileUtils.mkdir_p(File.dirname(part))
  key_slice = keys.to_unsafe.to_slice(keys.size)
  value_slice = values.to_unsafe.to_slice(values.size)
  {% if T == Int32 %}
    CrystalClick::WidePartWriter.write_uint64_nullable_simple_aggregate_decimal32_pair(
      part, "pk", key_slice, "v", value_slice, function, scale, rows_per_mark, precision: precision
    )
  {% elsif T == Int64 %}
    CrystalClick::WidePartWriter.write_uint64_nullable_simple_aggregate_decimal64_pair(
      part, "pk", key_slice, "v", value_slice, function, scale, rows_per_mark, precision: precision
    )
  {% elsif T == Int128 %}
    CrystalClick::WidePartWriter.write_uint64_nullable_simple_aggregate_decimal128_pair(
      part, "pk", key_slice, "v", value_slice, function, scale, rows_per_mark, precision: precision
    )
  {% elsif T == CrystalClick::Decimal256Value %}
    CrystalClick::WidePartWriter.write_uint64_nullable_simple_aggregate_decimal256_pair(
      part, "pk", key_slice, "v", value_slice, function, scale, rows_per_mark, precision: precision
    )
  {% else %}
    raise "unsupported W169 nullable test carrier"
  {% end %}
end

private def w169_read_decimal_scalar(
  part : CrystalClick::WidePart,
  values : Array(T),
  first_mark : Int,
  mark_count : Int,
  function : CrystalClick::BinarySimpleAggregateType::Function,
  precision : Int32,
  scale : Int32,
) : Array(T) forall T
  {% if T == Int32 %}
    part.read_simple_aggregate_decimal32_raw_mark_range("v", first_mark, mark_count, function, precision, scale)
  {% elsif T == Int64 %}
    part.read_simple_aggregate_decimal64_raw_mark_range("v", first_mark, mark_count, function, precision, scale)
  {% elsif T == Int128 %}
    part.read_simple_aggregate_decimal128_raw_mark_range("v", first_mark, mark_count, function, precision, scale)
  {% elsif T == CrystalClick::Decimal256Value %}
    part.read_simple_aggregate_decimal256_raw_mark_range("v", first_mark, mark_count, function, precision, scale)
  {% else %}
    raise "unsupported W169 scalar test carrier"
  {% end %}
end

private def w169_read_decimal_nullable(
  part : CrystalClick::WidePart,
  values : Array(T?),
  first_mark : Int,
  mark_count : Int,
  function : CrystalClick::BinarySimpleAggregateType::Function,
  precision : Int32,
  scale : Int32,
) : Array(T?) forall T
  {% if T == Int32 %}
    part.read_nullable_simple_aggregate_decimal32_raw_mark_range("v", first_mark, mark_count, function, precision, scale)
  {% elsif T == Int64 %}
    part.read_nullable_simple_aggregate_decimal64_raw_mark_range("v", first_mark, mark_count, function, precision, scale)
  {% elsif T == Int128 %}
    part.read_nullable_simple_aggregate_decimal128_raw_mark_range("v", first_mark, mark_count, function, precision, scale)
  {% elsif T == CrystalClick::Decimal256Value %}
    part.read_nullable_simple_aggregate_decimal256_raw_mark_range("v", first_mark, mark_count, function, precision, scale)
  {% else %}
    raise "unsupported W169 nullable test carrier"
  {% end %}
end

private def w169_batch_decimal_scalar(
  batch : CrystalClick::WidePartTableBatch,
  values : Array(T),
  function : CrystalClick::BinarySimpleAggregateType::Function,
  precision : Int32,
  scale : Int32,
) : Slice(T) forall T
  {% if T == Int32 %}
    batch.simple_aggregate_decimal32_raw_for("v", function, precision, scale)
  {% elsif T == Int64 %}
    batch.simple_aggregate_decimal64_raw_for("v", function, precision, scale)
  {% elsif T == Int128 %}
    batch.simple_aggregate_decimal128_raw_for("v", function, precision, scale)
  {% elsif T == CrystalClick::Decimal256Value %}
    batch.simple_aggregate_decimal256_raw_for("v", function, precision, scale)
  {% else %}
    raise "unsupported W169 scalar test carrier"
  {% end %}
end

private def w169_batch_decimal_nullable(
  batch : CrystalClick::WidePartTableBatch,
  values : Array(T?),
  function : CrystalClick::BinarySimpleAggregateType::Function,
  precision : Int32,
  scale : Int32,
) : Slice(T?) forall T
  {% if T == Int32 %}
    batch.nullable_simple_aggregate_decimal32_raw_for("v", function, precision, scale)
  {% elsif T == Int64 %}
    batch.nullable_simple_aggregate_decimal64_raw_for("v", function, precision, scale)
  {% elsif T == Int128 %}
    batch.nullable_simple_aggregate_decimal128_raw_for("v", function, precision, scale)
  {% elsif T == CrystalClick::Decimal256Value %}
    batch.nullable_simple_aggregate_decimal256_raw_for("v", function, precision, scale)
  {% else %}
    raise "unsupported W169 nullable test carrier"
  {% end %}
end

private def w169_assert_decimal_values(expected : Array(T), actual : Array(T)) : Nil forall T
  {% if T == CrystalClick::Decimal256Value %}
    actual.map { |value| {value.low, value.high} }.should eq(expected.map { |value| {value.low, value.high} })
  {% else %}
    actual.should eq(expected)
  {% end %}
end

private def w169_assert_decimal_nullable_values(expected : Array(T?), actual : Array(T?)) : Nil forall T
  {% if T == CrystalClick::Decimal256Value %}
    actual.map { |value| value.try { |entry| {entry.low, entry.high} } }
      .should eq(expected.map { |value| value.try { |entry| {entry.low, entry.high} } })
  {% else %}
    actual.should eq(expected)
  {% end %}
end

private def w169_exercise_scalar(
  part : String,
  function : CrystalClick::BinarySimpleAggregateType::Function,
  precision : Int32,
  scale : Int32,
  values : Array(T),
) : Nil forall T
  keys = w169_consumer_keys
  w169_write_decimal_scalar(part, keys, values, function, precision, scale)
  reader = CrystalClick::WidePart.open_typed(part, "v")
  reader.column_type.should eq(w169_consumer_type_name(function, precision, scale))
  reader.row_count.should eq(values.size.to_u64)
  reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
  w169_assert_decimal_values(values, w169_read_decimal_scalar(reader, values, 0, reader.mark_count, function, precision, scale))
  w169_assert_decimal_values(values[2, 2], w169_read_decimal_scalar(reader, values, 1, 1, function, precision, scale))

  table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "v"])
  observed = [] of T
  table.scan_typed(batch_rows: 2) do |batch|
    rows = batch.values_for("pk", UInt64).size
    expected = values[batch.part_row_offset.to_i, rows]
    actual = w169_batch_decimal_scalar(batch, values, function, precision, scale).to_a
    w169_assert_decimal_values(expected, actual)
    observed.concat(actual)
  end
  w169_assert_decimal_values(values, observed)

  window_values = [] of T
  table.scan_typed_window(1_u64, 3) do |batch|
    rows = batch.values_for("pk", UInt64).size
    expected = values[batch.part_row_offset.to_i, rows]
    actual = w169_batch_decimal_scalar(batch, values, function, precision, scale).to_a
    w169_assert_decimal_values(expected, actual)
    window_values.concat(actual)
  end
  w169_assert_decimal_values(values[1, 3], window_values)
  nil
end

private def w169_exercise_nullable(
  part : String,
  function : CrystalClick::BinarySimpleAggregateType::Function,
  precision : Int32,
  scale : Int32,
  values : Array(T?),
) : Nil forall T
  keys = w169_consumer_keys
  w169_write_decimal_nullable(part, keys, values, function, precision, scale)
  reader = CrystalClick::WidePart.open_typed(part, "v")
  reader.column_type.should eq(w169_consumer_type_name(function, precision, scale, true))
  reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
  w169_assert_decimal_nullable_values(values, w169_read_decimal_nullable(reader, values, 0, reader.mark_count, function, precision, scale))
  w169_assert_decimal_nullable_values(values[0, 4], w169_read_decimal_nullable(reader, values, 0, 2, function, precision, scale))

  table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "v"])
  observed = [] of T?
  table.scan_typed(batch_rows: 2) do |batch|
    rows = batch.values_for("pk", UInt64).size
    expected = values[batch.part_row_offset.to_i, rows]
    actual = w169_batch_decimal_nullable(batch, values, function, precision, scale).to_a
    w169_assert_decimal_nullable_values(expected, actual)
    observed.concat(actual)
  end
  w169_assert_decimal_nullable_values(values, observed)

  window_values = [] of T?
  table.scan_typed_window(1_u64, 3) do |batch|
    rows = batch.values_for("pk", UInt64).size
    expected = values[batch.part_row_offset.to_i, rows]
    actual = w169_batch_decimal_nullable(batch, values, function, precision, scale).to_a
    w169_assert_decimal_nullable_values(expected, actual)
    window_values.concat(actual)
  end
  w169_assert_decimal_nullable_values(values[1, 3], window_values)
  nil
end

private def w169_create_catalog(
  root : String,
  part : String,
  type_name : String,
  projection_part : String? = nil,
) : Nil
  database_uuid = "16900000-0000-4000-8000-000000000011"
  table_uuid = "16900000-0000-4000-8000-000000000012"
  metadata_path = File.join(root, "metadata")
  database_path = File.join(root, "store", database_uuid[0, 3], database_uuid)
  table_path = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(metadata_path)
  FileUtils.mkdir_p(database_path)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(metadata_path, "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  projection = projection_part ? ",\n    PROJECTION `by_rollup` (SELECT pk, v ORDER BY pk)" : ""
  File.write(
    File.join(database_path, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `v` #{type_name}#{projection}\n)\nENGINE = MergeTree\nORDER BY pk\n"
  )
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  parent_part = File.join(table_path, "all_1_1_0")
  FileUtils.cp_r(part, parent_part)
  if projection_part
    FileUtils.cp_r(projection_part, File.join(parent_part, "by_rollup.proj"))
  end
  nil
end

describe "W169 Decimal SimpleAggregateFunction paired runtime paths" do
  it "round-trips all eight scalar and outer-Nullable carriers with bounded marks" do
    root = File.tempname("crystal-click-simple-aggregate-decimal-w169-carriers")
    begin
      function = CrystalClick::BinarySimpleAggregateType::Function::Any
      w169_exercise_scalar(
        File.join(root, "scalar32", "all_1_1_0"), function, 8, 3,
        W169SimpleAggregateTestSupport.library_values32[0, 5]
      )
      w169_exercise_nullable(
        File.join(root, "nullable32", "all_1_1_0"), function, 8, 3,
        W169SimpleAggregateTestSupport.nullable_values(W169SimpleAggregateTestSupport.library_values32[0, 5])
      )
      w169_exercise_scalar(
        File.join(root, "scalar64", "all_1_1_0"), function, 17, 5,
        W169SimpleAggregateTestSupport.library_values64[0, 5]
      )
      w169_exercise_nullable(
        File.join(root, "nullable64", "all_1_1_0"), function, 17, 5,
        W169SimpleAggregateTestSupport.nullable_values(W169SimpleAggregateTestSupport.library_values64[0, 5])
      )
      w169_exercise_scalar(
        File.join(root, "scalar128", "all_1_1_0"), function, 37, 10,
        W169SimpleAggregateTestSupport.library_values128[0, 5]
      )
      w169_exercise_nullable(
        File.join(root, "nullable128", "all_1_1_0"), function, 37, 10,
        W169SimpleAggregateTestSupport.nullable_values(W169SimpleAggregateTestSupport.library_values128[0, 5])
      )
      w169_exercise_scalar(
        File.join(root, "scalar256", "all_1_1_0"), function, 75, 31,
        W169SimpleAggregateTestSupport.library_values256[0, 5]
      )
      w169_exercise_nullable(
        File.join(root, "nullable256", "all_1_1_0"), function, 75, 31,
        W169SimpleAggregateTestSupport.nullable_values(W169SimpleAggregateTestSupport.library_values256[0, 5])
      )

      nullable32 = W169SimpleAggregateTestSupport.nullable_values(W169SimpleAggregateTestSupport.library_values32[0, 5])
      nullable_part = File.join(root, "nullable32", "all_1_1_0")
      nullable_catalog = File.join(root, "nullable-catalog")
      w169_create_catalog(nullable_catalog, nullable_part, w169_consumer_type_name(function, 8, 3, true))
      nullable_table = CrystalClick::OfflineCatalog.open(nullable_catalog).table("lab", "events")
      nullable_materialized = nullable_table["v"].values(max_rows: 5_u64).map { |value| value.as(Int32?) }
      w169_assert_decimal_nullable_values(nullable32, nullable_materialized)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "persists every admitted Decimal SAF function and keeps SUM width-restricted" do
    root = File.tempname("crystal-click-simple-aggregate-decimal-w169-functions")
    begin
      functions = [
        {CrystalClick::BinarySimpleAggregateType::Function::Any, 8, 3, 32},
        {CrystalClick::BinarySimpleAggregateType::Function::AnyLast, 17, 5, 64},
        {CrystalClick::BinarySimpleAggregateType::Function::Min, 37, 10, 128},
        {CrystalClick::BinarySimpleAggregateType::Function::Max, 75, 31, 256},
        {CrystalClick::BinarySimpleAggregateType::Function::SumWithOverflow, 8, 3, 32},
        {CrystalClick::BinarySimpleAggregateType::Function::SumWithOverflow, 17, 5, 64},
        {CrystalClick::BinarySimpleAggregateType::Function::SumWithOverflow, 37, 10, 128},
        {CrystalClick::BinarySimpleAggregateType::Function::SumWithOverflow, 75, 31, 256},
        {CrystalClick::BinarySimpleAggregateType::Function::Sum, 37, 10, 128},
        {CrystalClick::BinarySimpleAggregateType::Function::Sum, 75, 31, 256},
      ] of Tuple(CrystalClick::BinarySimpleAggregateType::Function, Int32, Int32, Int32)
      functions.each_with_index do |profile, index|
        function = profile[0]
        precision = profile[1]
        scale = profile[2]
        width_bits = profile[3]
        part = File.join(root, "function_#{index}", "all_1_1_0")
        case width_bits
        when 32
          w169_exercise_scalar(part, function, precision, scale, W169SimpleAggregateTestSupport.library_values32[0, 5])
        when 64
          w169_exercise_scalar(part, function, precision, scale, W169SimpleAggregateTestSupport.library_values64[0, 5])
        when 128
          w169_exercise_scalar(part, function, precision, scale, W169SimpleAggregateTestSupport.library_values128[0, 5])
        when 256
          w169_exercise_scalar(part, function, precision, scale, W169SimpleAggregateTestSupport.library_values256[0, 5])
        end
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rejects wrong function, P, S, width, nullability, primitive and ordinary Decimal access" do
    root = File.tempname("crystal-click-simple-aggregate-decimal-w169-guards")
    begin
      function = CrystalClick::BinarySimpleAggregateType::Function::Any
      scalar_part = File.join(root, "scalar", "all_1_1_0")
      nullable_part = File.join(root, "nullable", "all_1_1_0")
      values = W169SimpleAggregateTestSupport.library_values32[0, 5]
      nullable_values = W169SimpleAggregateTestSupport.nullable_values(values)
      w169_write_decimal_scalar(scalar_part, w169_consumer_keys, values, function, 8, 3)
      w169_write_decimal_nullable(nullable_part, w169_consumer_keys, nullable_values, function, 8, 3)
      scalar = CrystalClick::WidePart.open_typed(scalar_part, "v")
      nullable = CrystalClick::WidePart.open_typed(nullable_part, "v")

      expect_raises(CrystalClick::UnsupportedFormatError) do
        scalar.read_simple_aggregate_decimal32_raw_mark_range("v", 0, 1, CrystalClick::BinarySimpleAggregateType::Function::Max, 8, 3)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        scalar.read_simple_aggregate_decimal32_raw_mark_range("v", 0, 1, function, 9, 3)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        scalar.read_simple_aggregate_decimal32_raw_mark_range("v", 0, 1, function, 8, 4)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        scalar.read_simple_aggregate_decimal64_raw_mark_range("v", 0, 1, function, 8, 3)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        scalar.read_nullable_simple_aggregate_decimal32_raw_mark_range("v", 0, 1, function, 8, 3)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        nullable.read_simple_aggregate_decimal32_raw_mark_range("v", 0, 1, function, 8, 3)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        nullable.read_nullable_simple_aggregate_decimal32_raw_mark_range("v", 0, 1, CrystalClick::BinarySimpleAggregateType::Function::Max, 8, 3)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        nullable.read_nullable_simple_aggregate_decimal32_raw_mark_range("v", 0, 1, function, 8, 4)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        nullable.read_nullable_simple_aggregate_decimal32_raw_mark_range("v", 0, 1, function, 9, 3)
      end
      expect_raises(CrystalClick::BoundsError) do
        scalar.read_simple_aggregate_decimal32_raw_mark_range("v", scalar.mark_count, 1, function, 8, 3)
      end

      expect_raises(CrystalClick::UnsupportedFormatError) { scalar.read_decimal32_raw_mark_range("v", 0, 1) }
      expect_raises(CrystalClick::UnsupportedFormatError) { scalar.read_numeric_mark_range("v", 0, 1, Int32) }
      expect_raises(CrystalClick::UnsupportedFormatError) { nullable.read_nullable_numeric_mark_range("v", 0, 1, Int32) }
      inferred_part = File.join(root, "inferred", "all_1_1_0")
      FileUtils.mkdir_p(File.dirname(inferred_part))
      CrystalClick::WidePartWriter.write_uint64_typed_pair(
        inferred_part, "pk", w169_consumer_keys.to_unsafe.to_slice(5),
        "v", values.to_unsafe.to_slice(5), rows_per_mark: 2
      )
      inferred_reader = CrystalClick::WidePart.open_typed(inferred_part, "v")
      inferred_reader.column_type.should eq("Int32")
      expect_raises(CrystalClick::UnsupportedFormatError) do
        inferred_reader.read_simple_aggregate_decimal32_raw_mark_range("v", 0, 1, function, 8, 3)
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "checks staged Decimal readback before publishing a corrupt part" do
    root = File.tempname("crystal-click-simple-aggregate-decimal-w169-stage-guard")
    begin
      parent = File.join(root, "part-parent")
      FileUtils.mkdir_p(parent)
      destination = File.join(parent, "all_1_1_0")
      keys = w169_consumer_keys
      values = W169SimpleAggregateTestSupport.library_values32[0, 5]
      CrystalClick::WidePart.w169_decimal_probe_enabled = true
      begin
        expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::WidePartWriter.write_uint64_simple_aggregate_decimal32_pair(
            destination, "pk", keys.to_unsafe.to_slice(keys.size), "v", values.to_unsafe.to_slice(values.size),
            CrystalClick::BinarySimpleAggregateType::Function::Any, 3, 2, precision: 8
          )
        end
      ensure
        CrystalClick::WidePart.w169_decimal_probe_enabled = false
      end
      Dir.children(parent).should be_empty

      nullable_destination = File.join(parent, "nullable_1_1_0")
      nullable_values = W169SimpleAggregateTestSupport.nullable_values(values)
      CrystalClick::WidePart.w169_nullable_decimal_probe_enabled = true
      begin
        expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::WidePartWriter.write_uint64_nullable_simple_aggregate_decimal32_pair(
            nullable_destination, "pk", keys.to_unsafe.to_slice(keys.size), "v", nullable_values.to_unsafe.to_slice(nullable_values.size),
            CrystalClick::BinarySimpleAggregateType::Function::Any, 3, 2, precision: 8
          )
        end
      ensure
        CrystalClick::WidePart.w169_nullable_decimal_probe_enabled = false
      end
      Dir.children(parent).should be_empty
    ensure
      CrystalClick::WidePart.w169_decimal_probe_enabled = false
      CrystalClick::WidePart.w169_nullable_decimal_probe_enabled = false
      FileUtils.rm_rf(root)
    end
  end

  it "materializes OfflineTable coefficients and scans independently typed projection children" do
    root = File.tempname("crystal-click-simple-aggregate-decimal-w169-offline")
    begin
      keys = w169_consumer_keys
      base_values = W169SimpleAggregateTestSupport.library_values32[0, 5]
      child_values = [1_234_567_i32, -2_345_678_i32, Int32::MAX, Int32::MIN, 7_i32]
      base_part = File.join(root, "base", "all_1_1_0")
      child_part = File.join(root, "projection", "all_1_1_0")
      any = CrystalClick::BinarySimpleAggregateType::Function::Any
      min = CrystalClick::BinarySimpleAggregateType::Function::Min
      base_type = w169_consumer_type_name(any, 8, 3)
      child_type = w169_consumer_type_name(min, 7, 2)
      w169_write_decimal_scalar(base_part, keys, base_values, any, 8, 3)
      w169_write_decimal_scalar(child_part, keys, child_values, min, 7, 2)
      catalog_root = File.join(root, "catalog")
      w169_create_catalog(catalog_root, base_part, base_type, child_part)

      table = CrystalClick::OfflineCatalog.open(catalog_root).table("lab", "events")
      offline_values = table["v"].values(max_rows: 5_u64).map { |value| value.as(Int32) }
      offline_values.should eq(base_values)

      observed = [] of Int32
      table.scan_projection_typed("by_rollup", ["v"], batch_rows: 2) do |batch|
        batch.column_type_for("v").should eq(child_type)
        actual = batch.simple_aggregate_decimal32_raw_for("v", min, 7, 2).to_a
        expected = child_values[batch.part_row_offset.to_i, actual.size]
        actual.should eq(expected)
        observed.concat(actual)
      end
      observed.should eq(child_values)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "preserves explicit mark and writer limits without widening inferred paths" do
    root = File.tempname("crystal-click-simple-aggregate-decimal-w169-budgets")
    begin
      parent = File.join(root, "oversized-mark")
      FileUtils.mkdir_p(parent)
      values = W169SimpleAggregateTestSupport.library_values32[0, 5]
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_simple_aggregate_decimal32_pair(
          File.join(parent, "all_1_1_0"), "pk", w169_consumer_keys.to_unsafe.to_slice(5),
          "v", values.to_unsafe.to_slice(5), CrystalClick::BinarySimpleAggregateType::Function::Any,
          3, CrystalClick::WidePartWriter::MAX_ROWS_PER_MARK + 1, precision: 8
        )
      end
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
