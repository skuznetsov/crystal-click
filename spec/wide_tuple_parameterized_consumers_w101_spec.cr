require "./spec_helper"
require "file_utils"

private class W101ParameterizedConsumerField
  getter name : String
  getter type_name : String
  getter column : CrystalClick::WideTupleLeafColumn

  def initialize(@name : String, @type_name : String, @column : CrystalClick::WideTupleLeafColumn)
    raise "consumer field type differs from its exact owner" unless @column.type_name == @type_name
    raise "consumer field has no parameterized owner" unless @column.parameterized_type
  end
end

private def w101c_fields : Array(W101ParameterizedConsumerField)
  fixed_type = CrystalClick::WideTupleFixedStringType.new(4)
  fixed_values = ["x", "a\0b", "é", "\xffZ", "wxyz"].map { |value| CrystalClick::FixedStringValue.new(4, value) }

  enum8_definition = CrystalClick::WideTupleEnumDefinition.new(:enum8, [
    {"minimum", -128_i16}, {"negative", -1_i16}, {"zero", 0_i16}, {"positive", 1_i16}, {"maximum", 127_i16},
  ] of CrystalClick::WideTupleEnumDefinition::Entry)
  enum8_type = CrystalClick::WideTupleEnumType.new(enum8_definition)
  enum8_values = [-128_i8, -1_i8, 0_i8, 127_i8, 1_i8].map { |code| CrystalClick::Enum8Value.new(enum8_definition, code) }

  enum16_definition = CrystalClick::WideTupleEnumDefinition.new(:enum16, [
    {"minimum", -32_768_i16}, {"negative", -42_i16}, {"zero", 0_i16}, {"positive", 42_i16}, {"maximum", 32_767_i16},
  ] of CrystalClick::WideTupleEnumDefinition::Entry)
  enum16_type = CrystalClick::WideTupleEnumType.new(enum16_definition)
  enum16_values = [-32_768_i16, -42_i16, 0_i16, 32_767_i16, 42_i16].map { |code| CrystalClick::Enum16Value.new(enum16_definition, code) }

  decimal32_type = CrystalClick::WideTupleDecimalType.new(9, 2)
  decimal32_values = [-999_999_999_i32, -1_i32, 0_i32, 1_i32, 999_999_999_i32].map do |raw|
    CrystalClick::Decimal32Value.new(raw, 9, 2)
  end
  decimal64_type = CrystalClick::WideTupleDecimalType.new(18, 4)
  decimal64_values = [-999_999_999_999_999_999_i64, -1_i64, 0_i64, 1_i64, 999_999_999_999_999_999_i64].map do |raw|
    CrystalClick::Decimal64Value.new(raw, 18, 4)
  end
  decimal128_type = CrystalClick::WideTupleDecimalType.new(38, 19)
  decimal128_limit = 10_i128 ** 38 - 1_i128
  decimal128_values = [-decimal128_limit, -1_i128, 0_i128, 1_i128, decimal128_limit].map do |raw|
    CrystalClick::Decimal128Value.new(raw, 38, 19)
  end
  decimal256_type = CrystalClick::WideTupleDecimalType.new(76, 38)
  decimal256_values = [-99_i128, -1_i128, 0_i128, 1_i128, 99_i128].map do |raw|
    CrystalClick::Decimal256TupleValue.new(CrystalClick::Decimal256Value.from_int128(raw), 76, 38)
  end

  [
    W101ParameterizedConsumerField.new("fixed", fixed_type.type_name, CrystalClick::WideTupleLeafColumn.new("fixed", fixed_type, fixed_values)),
    W101ParameterizedConsumerField.new("enum8", enum8_type.type_name, CrystalClick::WideTupleLeafColumn.new("enum8", enum8_type, enum8_values)),
    W101ParameterizedConsumerField.new("enum16", enum16_type.type_name, CrystalClick::WideTupleLeafColumn.new("enum16", enum16_type, enum16_values)),
    W101ParameterizedConsumerField.new("d32", decimal32_type.type_name, CrystalClick::WideTupleLeafColumn.new("d32", decimal32_type, decimal32_values)),
    W101ParameterizedConsumerField.new("d64", decimal64_type.type_name, CrystalClick::WideTupleLeafColumn.new("d64", decimal64_type, decimal64_values)),
    W101ParameterizedConsumerField.new("d128", decimal128_type.type_name, CrystalClick::WideTupleLeafColumn.new("d128", decimal128_type, decimal128_values)),
    W101ParameterizedConsumerField.new("d256", decimal256_type.type_name, CrystalClick::WideTupleLeafColumn.new("d256", decimal256_type, decimal256_values)),
  ] of W101ParameterizedConsumerField
end

private def w101c_tuple_type(fields : Array(W101ParameterizedConsumerField)) : String
  "Tuple(#{fields.map { |field| "#{field.name} #{field.type_name}" }.join(", ")})"
end

private def w101c_assert_row(
  row : CrystalClick::WideTupleRow,
  fields : Array(W101ParameterizedConsumerField),
  source_index : Int32,
  label : String,
) : Nil
  row.type_name.should eq(w101c_tuple_type(fields))
  row.field_count.should eq(fields.size)
  fields.each do |field|
    exact_type = field.column.parameterized_type || raise "#{label}: missing exact type for #{field.name}"
    case exact_type
    when CrystalClick::WideTupleFixedStringType
      row.value_as(field.name, CrystalClick::FixedStringValue).should eq(field.column.value_at(source_index, CrystalClick::FixedStringValue))
    when CrystalClick::WideTupleEnumType
      if exact_type.width == 1
        row.value_as(field.name, CrystalClick::Enum8Value).should eq(field.column.value_at(source_index, CrystalClick::Enum8Value))
      else
        row.value_as(field.name, CrystalClick::Enum16Value).should eq(field.column.value_at(source_index, CrystalClick::Enum16Value))
      end
    when CrystalClick::WideTupleDecimalType
      case exact_type.storage_width
      when 4
        row.value_as(field.name, CrystalClick::Decimal32Value).should eq(field.column.value_at(source_index, CrystalClick::Decimal32Value))
      when 8
        row.value_as(field.name, CrystalClick::Decimal64Value).should eq(field.column.value_at(source_index, CrystalClick::Decimal64Value))
      when 16
        row.value_as(field.name, CrystalClick::Decimal128Value).should eq(field.column.value_at(source_index, CrystalClick::Decimal128Value))
      when 32
        row.value_as(field.name, CrystalClick::Decimal256TupleValue).should eq(field.column.value_at(source_index, CrystalClick::Decimal256TupleValue))
      else
        raise "#{label}: unsupported Decimal storage width"
      end
    end
  end
  nil
end

private def w101c_catalog_root(root : String, part : String, type_name : String) : String
  database_uuid = "10110000-0000-4000-8000-000000000001"
  table_uuid = "10110000-0000-4000-8000-000000000002"
  metadata = File.join(root, "metadata")
  database = File.join(root, "store", database_uuid[0, 3], database_uuid)
  table = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(metadata)
  FileUtils.mkdir_p(database)
  FileUtils.mkdir_p(table)
  File.write(File.join(metadata, "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  File.write(File.join(database, "events.sql"), "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `payload` #{type_name}\n)\nENGINE = MergeTree\nORDER BY pk\n")
  File.write(File.join(table, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table, "detached"))
  copied = File.join(table, "all_1_1_0")
  FileUtils.cp_r(part, copied)
  copied
end

describe "parameterized named-flat Tuple consumers" do
  it "preserves FixedString, Enum, and all Decimal widths through reader, table, and catalog paths" do
    fields = w101c_fields
    type_name = w101c_tuple_type(fields)
    keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
    parent = File.tempname("crystal-click-w101-parameterized-consumers")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_tuple_pair(
        part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name, fields.map(&.column), 2
      ).should eq(part)

      reader = CrystalClick::WidePart.open_typed(part, "payload")
      reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      data = reader.read_tuple_mark_range("payload", 0, reader.mark_count)
      data.type_name.should eq(type_name)
      data.fields.map { |field| {field.name, field.type_name} }.should eq(fields.map { |field| {field.name, field.type_name} })
      5.times { |index| w101c_assert_row(data.row(index), fields, index.to_i32, "reader row #{index}") }

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      table_seen = [] of Int32
      table.scan_typed do |batch|
        batch.values_for("pk").each_with_index do |key, offset|
          index = (key - 1_u64).to_i32
          w101c_assert_row(batch.tuple_rows_for("payload")[offset], fields, index, "table full scan")
          table_seen << index
        end
        nil
      end
      table_seen.should eq([0_i32, 1_i32, 2_i32, 3_i32, 4_i32])

      window_seen = [] of Int32
      table.scan_typed_window(1_u64, 3) do |batch|
        batch.values_for("pk").each_with_index do |key, offset|
          index = (key - 1_u64).to_i32
          w101c_assert_row(batch.tuple_rows_for("payload")[offset], fields, index, "table window")
          window_seen << index
        end
        nil
      end
      window_seen.should eq([1_i32, 2_i32, 3_i32])

      candidate_seen = [] of Int32
      table.scan_typed_candidate_marks([[1_i32, 2_i32]]) do |batch|
        batch.values_for("pk").each_with_index do |key, offset|
          index = (key - 1_u64).to_i32
          w101c_assert_row(batch.tuple_rows_for("payload")[offset], fields, index, "table candidate marks")
          candidate_seen << index
        end
        nil
      end
      candidate_seen.should eq([2_i32, 3_i32, 4_i32])

      catalog_root = File.join(parent, "catalog")
      copied = w101c_catalog_root(catalog_root, part, type_name)
      offline_table = CrystalClick::OfflineCatalog.open(catalog_root).table("lab", "events")
      resolved = offline_table.resolved_scan_parts
      resolved.size.should eq(1)
      File.realpath(resolved[0].path).should eq(File.realpath(copied))

      values = offline_table["payload"].values(max_tuple_cells: 100_u64)
      values.size.should eq(5)
      values.each_with_index do |value, index|
        w101c_assert_row(value.as(CrystalClick::WideTupleRow), fields, index.to_i32, "catalog materialized value")
      end

      catalog_seen = [] of Int32
      offline_table.scan_typed(["pk", "payload"]) do |batch|
        batch.values_for("pk").each_with_index do |key, offset|
          index = (key - 1_u64).to_i32
          w101c_assert_row(batch.tuple_rows_for("payload")[offset], fields, index, "catalog full scan")
          catalog_seen << index
        end
        nil
      end
      catalog_seen.should eq([0_i32, 1_i32, 2_i32, 3_i32, 4_i32])

      catalog_window_seen = [] of Int32
      offline_table.scan_typed_window(["pk", "payload"], 1_u64, 3) do |batch|
        batch.values_for("pk").each_with_index do |key, offset|
          index = (key - 1_u64).to_i32
          w101c_assert_row(batch.tuple_rows_for("payload")[offset], fields, index, "catalog window")
          catalog_window_seen << index
        end
        nil
      end
      catalog_window_seen.should eq([1_i32, 2_i32, 3_i32])

      candidate_keys = [] of UInt64
      offline_table.scan_uint64_pk_candidates(["pk"], 3_u64, 5_u64) do |batch|
        candidate_keys.concat(batch.values_for("pk"))
        nil
      end
      # Candidate scans return whole conservative granules; callers apply the
      # exact inclusive primary-key predicate to each returned batch.
      candidate_keys.should eq([1_u64, 2_u64, 3_u64, 4_u64, 5_u64])
      candidate_keys.select { |key| key >= 3_u64 && key <= 5_u64 }.should eq([3_u64, 4_u64, 5_u64])
    ensure
      FileUtils.rm_rf(parent) if Dir.exists?(parent)
    end
  end
end
