require "./spec_helper"
require "file_utils"

private def w204_json_schema : CrystalClick::ObjectDocumentSchema
  CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(t UInt8)")
end

private def w204_object_plan(schema : CrystalClick::ObjectDocumentSchema) : CrystalClick::ObjectDocumentPlan
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    ),
    schema.typed_paths,
  )
end

private def w204_mixed_schema : CrystalClick::StorageColumnSchema
  CrystalClick::StorageColumnSchema.parse(
    "Tuple(root JSON(t UInt8), rows Array(Tuple(doc JSON(t UInt8), " +
    "state Tuple(tag LowCardinality(String), samples Array(Dynamic(max_types=1))), seq UInt64)), tail UInt64)"
  )
end

private def w204_state_type : CrystalClick::BinaryDataType
  low_cardinality_string = CrystalClick::BinaryDataType.low_cardinality(
    CrystalClick::BinaryDataType.primitive("String")
  )
  values = CrystalClick::BinaryDataType.array(
    CrystalClick::BinaryDataType.dynamic(max_types: 1)
  )
  CrystalClick::BinaryDataType.tuple(
    [low_cardinality_string, values] of CrystalClick::BinaryDataType,
    ["tag", "samples"] of String,
  )
end

private def w204_dynamic_plans : Hash(String, CrystalClick::BinaryDynamicBulkPlan)
  state_type = w204_state_type
  actual_uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
  {
    "root/tuple[1]/array[0]/tuple[1]" => CrystalClick::BinaryDynamicBulkPlan.new(
      state_type,
      {"root.field.1.elements" => CrystalClick::DynamicStructure.new(
        [actual_uint64] of CrystalClick::BinaryDataType
      )},
    ),
  }
end

private def w204_document(value : UInt8) : CrystalClick::ObjectDocument
  CrystalClick::ObjectDocument.new({
    "t" => CrystalClick::BinaryValue.fixed(
      CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[value]
    ),
  } of String => CrystalClick::BinaryValue)
end

private def w204_dynamic_value(
  type : CrystalClick::BinaryDataType,
  child : CrystalClick::BinaryValue?,
) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.dynamic(type, child)
end

private def w204_item(
  document : UInt8,
  tag : String,
  values : Array(CrystalClick::BinaryValue),
  sequence : UInt64,
) : CrystalClick::StorageColumnValue
  state_type = w204_state_type
  tag_type = state_type.child_at(0)
  values_type = state_type.child_at(1)
  state = CrystalClick::BinaryValue.tuple(
    state_type,
    [
      CrystalClick::BinaryValue.low_cardinality(tag_type, CrystalClick::BinaryValue.string(tag)),
      CrystalClick::BinaryValue.array(values_type, values),
    ] of CrystalClick::BinaryValue,
  )
  CrystalClick::StorageColumnValue.tuple([
    CrystalClick::StorageColumnValue.object_document(w204_document(document)),
    CrystalClick::StorageColumnValue.bulk(state),
    CrystalClick::StorageColumnValue.bulk(CrystalClick::BinaryValue.uint64(sequence)),
  ] of CrystalClick::StorageColumnValue)
end

private def w204_root(
  document : UInt8,
  rows : Array(CrystalClick::StorageColumnValue),
  tail : UInt64,
) : CrystalClick::StorageColumnValue
  CrystalClick::StorageColumnValue.tuple([
    CrystalClick::StorageColumnValue.object_document(w204_document(document)),
    CrystalClick::StorageColumnValue.array(rows),
    CrystalClick::StorageColumnValue.bulk(CrystalClick::BinaryValue.uint64(tail)),
  ] of CrystalClick::StorageColumnValue)
end

private def w204_mixed_granules : Array(Array(CrystalClick::StorageColumnValue))
  empty = [] of CrystalClick::StorageColumnValue
  seven = w204_dynamic_value(
    CrystalClick::BinaryDataType.dynamic(max_types: 1), CrystalClick::BinaryValue.uint64(7_u64)
  )
  shared = w204_dynamic_value(
    CrystalClick::BinaryDataType.dynamic(max_types: 1), CrystalClick::BinaryValue.string("overflow")
  )
  null = w204_dynamic_value(CrystalClick::BinaryDataType.dynamic(max_types: 1), nil)
  forty_two = w204_dynamic_value(
    CrystalClick::BinaryDataType.dynamic(max_types: 1), CrystalClick::BinaryValue.uint64(42_u64)
  )
  [
    [
      w204_root(1_u8, empty, 100_u64),
      w204_root(2_u8, empty, 200_u64),
    ] of CrystalClick::StorageColumnValue,
    [
      w204_root(3_u8, [w204_item(31_u8, "red", [seven] of CrystalClick::BinaryValue, 310_u64)] of CrystalClick::StorageColumnValue, 300_u64),
      w204_root(4_u8, empty, 400_u64),
    ] of CrystalClick::StorageColumnValue,
    [
      w204_root(5_u8, [
        w204_item(51_u8, "blue", [shared, null] of CrystalClick::BinaryValue, 510_u64),
        w204_item(52_u8, "red", [] of CrystalClick::BinaryValue, 520_u64),
      ] of CrystalClick::StorageColumnValue, 500_u64),
      w204_root(6_u8, [w204_item(61_u8, "blue", [forty_two] of CrystalClick::BinaryValue, 610_u64)] of CrystalClick::StorageColumnValue, 600_u64),
    ] of CrystalClick::StorageColumnValue,
    [
      w204_root(7_u8, empty, 700_u64),
      w204_root(8_u8, empty, 800_u64),
    ] of CrystalClick::StorageColumnValue,
  ] of Array(CrystalClick::StorageColumnValue)
end

private def w204_binary_values(value : CrystalClick::BinaryValue) : String
  parts = [] of String
  value.element_count.times do |index|
    dynamic = value.element_at(index)
    if dynamic.is_null?
      parts << "null"
    else
      actual = dynamic.child_at(0)
      parts << case actual.type.name
               when "UInt64"
                 "u#{actual.as_uint64}"
               when "String"
                 "s:#{actual.as_string}"
               else
                 "unexpected:#{actual.type.name}"
               end
    end
  end
  parts.join("+")
end

private def w204_row_signature(value : CrystalClick::StorageColumnValue) : String
  document = value.child_at(0).object_document.value_for("t").bytes[0]
  state = value.child_at(1).bulk_value
  tag = state.child_at(0).child_at(0).as_string
  dynamic_values = w204_binary_values(state.child_at(1))
  sequence = value.child_at(2).bulk_value.as_uint64
  "#{document}:#{tag}:#{dynamic_values}:#{sequence}"
end

private def w204_signature(value : CrystalClick::StorageColumnValue) : String
  root_document = value.child_at(0).object_document.value_for("t").bytes[0]
  rows = value.child_at(1).array_values.map { |row| w204_row_signature(row) }.join(";")
  tail = value.child_at(2).bulk_value.as_uint64
  "#{root_document}|#{rows}|#{tail}"
end

private def w204_with_parent(label : String, & : String ->)
  parent = File.tempname("crystal-click-w204-#{label}-")
  Dir.mkdir(parent)
  yield parent
ensure
  FileUtils.rm_rf(parent) if parent && Dir.exists?(parent)
end

private def w204_zero_schema : CrystalClick::StorageColumnSchema
  CrystalClick::StorageColumnSchema.parse(
    "Array(Tuple(doc JSON(t UInt8), d Dynamic(max_types=1)))"
  )
end

private def w204_zero_object_plans(
  schema : CrystalClick::ObjectDocumentSchema,
) : Hash(String, CrystalClick::ObjectDocumentPlan)
  {"root/array[0]/tuple[0]" => w204_object_plan(schema)}
end

private def w204_zero_dynamic_plans : Hash(String, CrystalClick::BinaryDynamicBulkPlan)
  dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
  uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
  {
    "root/array[0]/tuple[1]" => CrystalClick::BinaryDynamicBulkPlan.new(
      dynamic,
      {"root" => CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType)},
    ),
  }
end

describe "W204 recursive JSON and Dynamic physical-site composition" do
  it "round-trips mixed JSON and JSON-free Dynamic bulk through P/Q marks, selected windows, and table callbacks" do
    json_schema = w204_json_schema
    schema = w204_mixed_schema
    object_plan = w204_object_plan(json_schema)
    object_plans = {
      "root/tuple[0]" => object_plan,
      "root/tuple[1]/array[0]/tuple[0]" => object_plan,
    }
    dynamic_plans = w204_dynamic_plans
    plan = CrystalClick::RecursiveStorageColumnPlan.for_column(
      "payload", schema, object_plans, dynamic_plans: dynamic_plans
    )
    plan.object_site_count.should eq(2)
    plan.dynamic_site_count.should eq(1)
    plan.array_site_count.should eq(1)
    site = plan.dynamic_site_at(0)
    {site.key, site.prefix, site.array_level}.should eq({
      "root/tuple[1]/array[0]/tuple[1]", "payload%2Erows%2Estate", 1_u64,
    })
    site.plan.site_paths.should eq(["root.field.1.elements"])

    expected = [
      ["1||100", "2||200"] of String,
      ["3|31:red:u7:310|300", "4||400"] of String,
      ["5|51:blue:s:overflow+null:510;52:red::520|500", "6|61:blue:u42:610|600"] of String,
      ["7||700", "8||800"] of String,
    ] of Array(String)

    w204_with_parent("mixed") do |parent|
      part = File.join(parent, "all_1_1_0")
      keys = Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64]
      CrystalClick::WidePartWriter.write_uint64_recursive_pair(
        part, "pk", keys, "payload", schema, object_plans, w204_mixed_granules,
        rows_per_mark: 2,
        dynamic_plans: dynamic_plans,
      ).should eq(part)

      reader = CrystalClick::RecursiveStorageColumnReader.open(part, "payload", schema)
      reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
      names = reader.physical_stream_names
      names.should eq(plan.physical_stream_names)
      names.should contain("payload%2Eroot.t")
      names.should contain("payload%2Erows.size0")
      names.should contain("payload%2Erows%2Edoc.t")
      names.should contain("payload%2Erows%2Estate%2Etag.dict")
      names.should contain("payload%2Erows%2Estate%2Etag")
      names.should contain("payload%2Erows%2Estate%2Esamples.size1")
      names.should contain(site.physical.structure_name_for("root.field.1.elements"))

      full = reader.read_marks(0, 4)
      full.map(&.size).should eq([2, 2, 2, 2])
      full.map { |mark| mark.map { |row| w204_signature(row) } }.should eq(expected)
      reader.read_marks(2, 1).map { |mark| mark.map { |row| w204_signature(row) } }.should eq([expected[2]])
      reader.read_marks(3, 1).map { |mark| mark.map { |row| w204_signature(row) } }.should eq([expected[3]])
      reader.read_marks(reader.mark_count, 0).should be_empty

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      table_full = [] of Array(String)
      table.scan_typed_candidate_marks([[0, 1, 2, 3]]) do |batch|
        table_full << batch.recursive_values_for("payload").map { |row| w204_signature(row) }.to_a
      end
      table_full.should eq(expected)

      table_middle = [] of Array(String)
      table.scan_typed_candidate_marks([[2]]) do |batch|
        table_middle << batch.recursive_values_for("payload").map { |row| w204_signature(row) }.to_a
      end
      table_middle.should eq([expected[2]])

      table_end_zero = [] of Array(String)
      table.scan_typed_window(6_u64, 2) do |batch|
        table_end_zero << batch.recursive_values_for("payload").map { |row| w204_signature(row) }.to_a
      end
      table_end_zero.should eq([expected[3]])
    end
  end

  it "keeps the P structure grid and parent rows when every Dynamic occurrence Q is zero" do
    json_schema = w204_json_schema
    schema = w204_zero_schema
    object_plans = w204_zero_object_plans(json_schema)
    dynamic_plans = w204_zero_dynamic_plans
    plan = CrystalClick::RecursiveStorageColumnPlan.for_column(
      "payload", schema, object_plans, dynamic_plans: dynamic_plans
    )
    site = plan.dynamic_site_at(0)
    site.key.should eq("root/array[0]/tuple[1]")
    site.plan.statistics_offset_for("root").should be > 0

    w204_with_parent("all-zero-site") do |parent|
      part = File.join(parent, "all_1_1_0")
      keys = Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64]
      empty = CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue)
      granules = Array(Array(CrystalClick::StorageColumnValue)).new(4) do
        [empty, empty] of CrystalClick::StorageColumnValue
      end
      CrystalClick::WidePartWriter.write_uint64_recursive_pair(
        part, "pk", keys, "payload", schema, object_plans, granules,
        rows_per_mark: 2,
        dynamic_plans: dynamic_plans,
      )

      structure_name = site.physical.structure_name_for("root")
      hash = CrystalClick::StreamName.hash(structure_name)
      grid = CrystalClick::PartStreamSource.new(part).inspect_grid(
        "#{hash}.bin", "#{hash}.mrk2", site.plan.statistics_offset_for("root"),
        CrystalClick::CompressedStreamBudget.new,
      )
      grid.prefix_size.should eq(site.plan.statistics_offset_for("root"))
      grid.rows_per_mark.should eq([2_u64, 2_u64, 2_u64, 2_u64])
      grid.positions[0...4].should eq(Array(Int64).new(4, site.plan.statistics_offset_for("root").to_i64))
      grid.position_at(grid.mark_count).should eq(grid.logical_size)

      reader = CrystalClick::RecursiveStorageColumnReader.open(part, "payload", schema)
      reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
      values = reader.read_marks(0, reader.mark_count).flatten
      values.size.should eq(8)
      values.each do |value|
        value.array?.should be_true
        value.child_count.should eq(0)
      end

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      callback_count = 0
      table_rows = 0
      table.scan_typed_candidate_marks([[0, 1, 2, 3]]) do |batch|
        callback_count += 1
        rows = batch.recursive_values_for("payload")
        table_rows += rows.size
        rows.each do |row|
          row.array?.should be_true
          row.child_count.should eq(0)
        end
      end
      callback_count.should eq(4)
      table_rows.should eq(8)

      end_window = [] of Int32
      table.scan_typed_window(6_u64, 2) do |batch|
        end_window << batch.recursive_values_for("payload").size
      end
      end_window.should eq([2])
    end
  end
end
