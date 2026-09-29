require "./spec_helper"

describe "W82 Array(Map(... String)) physical plan admission" do
  it "matches the pinned stock stream order, widths, and nested child axes" do
    cases = [
      {
        "Array(Map(UInt64, String))",
        ["payload.size0", "payload.size1", "payload%2Ekeys", "payload%2Evalues.size", "payload%2Evalues"],
        [8, 8, 8, 8, 1], false, false,
      },
      {
        "Array(Map(String, String))",
        ["payload.size0", "payload.size1", "payload%2Ekeys.size", "payload%2Ekeys", "payload%2Evalues.size", "payload%2Evalues"],
        [8, 8, 8, 1, 8, 1], true, false,
      },
      {
        "Array(Map(UInt64, Nullable(String)))",
        ["payload.size0", "payload.size1", "payload%2Ekeys", "payload%2Evalues.null", "payload%2Evalues.size", "payload%2Evalues"],
        [8, 8, 8, 1, 8, 1], false, true,
      },
      {
        "Array(Map(String, Nullable(String)))",
        ["payload.size0", "payload.size1", "payload%2Ekeys.size", "payload%2Ekeys", "payload%2Evalues.null", "payload%2Evalues.size", "payload%2Evalues"],
        [8, 8, 8, 1, 1, 8, 1], true, true,
      },
    ]

    cases.each do |type, expected_names, expected_widths, string_key, nullable_value|
      maybe_plan = CrystalClick::WideTypePlan::WidePhysicalPlanShadow.for_type(type)
      maybe_plan.should_not be_nil
      next unless plan = maybe_plan

      streams = plan.streams
      streams.map(&.name).should eq(expected_names)
      streams.map(&.element_width).should eq(expected_widths)
      plan.mark_row_axis.id.should eq("table_rows")
      streams.each { |stream| stream.mark_row_axis.id.should eq("table_rows") }

      outer_sizes, map_sizes = streams[0..1]
      outer_sizes.role.should eq(CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StreamRole::ArraySize0)
      outer_sizes.storage_axis.id.should eq("table_rows")
      outer_sizes.storage_mode.should eq(CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StorageMode::Counts)
      outer_sizes.cardinality_parent_axis.not_nil!.id.should eq("table_rows")
      outer_axis = outer_sizes.cardinality_child_axis.not_nil!
      outer_axis.id.should eq("payload:root:array0_elements")
      outer_axis.kind.should eq(CrystalClick::WideTypePlan::WidePhysicalPlanShadow::AxisKind::ArrayElements)

      map_sizes.role.should eq(CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StreamRole::ArraySize1)
      map_sizes.storage_axis.id.should eq(outer_axis.id)
      map_sizes.storage_mode.should eq(CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StorageMode::Counts)
      map_sizes.cardinality_parent_axis.not_nil!.id.should eq(outer_axis.id)
      map_axis = map_sizes.cardinality_child_axis.not_nil!
      map_axis.id.should eq("payload:root:map_entries")
      map_axis.kind.should eq(CrystalClick::WideTypePlan::WidePhysicalPlanShadow::AxisKind::MapEntries)

      cursor = 2
      if string_key
        key_sizes, key_data = streams[cursor..cursor + 1]
        key_sizes.role.should eq(CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StreamRole::StringSize)
        key_sizes.storage_mode.should eq(CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StorageMode::Counts)
        key_sizes.semantic_type.should eq("String")
        key_sizes.storage_axis.id.should eq(map_axis.id)
        key_sizes.cardinality_parent_axis.not_nil!.id.should eq(map_axis.id)
        key_bytes_axis = key_sizes.cardinality_child_axis.not_nil!
        key_bytes_axis.id.should eq("payload:keys:string_bytes")
        key_bytes_axis.kind.should eq(CrystalClick::WideTypePlan::WidePhysicalPlanShadow::AxisKind::StringBytes)
        key_data.role.should eq(CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StreamRole::Value)
        key_data.storage_mode.should eq(CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StorageMode::VariableBytes)
        key_data.semantic_type.should eq("String")
        key_data.storage_axis.id.should eq(key_bytes_axis.id)
        cursor += 2
      else
        key_data = streams[cursor]
        key_data.role.should eq(CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StreamRole::Value)
        key_data.storage_mode.should eq(CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StorageMode::FixedWidthValues)
        key_data.semantic_type.should eq("UInt64")
        key_data.storage_axis.id.should eq(map_axis.id)
        cursor += 1
      end
      key_data.semantic_path.should eq(["keys"])

      if nullable_value
        nulls = streams[cursor]
        nulls.name.should eq("payload%2Evalues.null")
        nulls.role.should eq(CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StreamRole::NullMap)
        nulls.storage_mode.should eq(CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StorageMode::NullMapBytes)
        nulls.semantic_type.should eq("Nullable(String)")
        nulls.storage_axis.id.should eq(map_axis.id)
        nulls.semantic_path.should eq(["values"])
        cursor += 1
      end

      value_sizes, value_data = streams[cursor..cursor + 1]
      value_sizes.role.should eq(CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StreamRole::StringSize)
      value_sizes.storage_mode.should eq(CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StorageMode::Counts)
      value_sizes.semantic_type.should eq(nullable_value ? "Nullable(String)" : "String")
      value_sizes.storage_axis.id.should eq(map_axis.id)
      value_sizes.cardinality_parent_axis.not_nil!.id.should eq(map_axis.id)
      value_bytes_axis = value_sizes.cardinality_child_axis.not_nil!
      value_bytes_axis.id.should eq("payload:values:string_bytes")
      value_bytes_axis.kind.should eq(CrystalClick::WideTypePlan::WidePhysicalPlanShadow::AxisKind::StringBytes)
      value_data.role.should eq(CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StreamRole::Value)
      value_data.storage_mode.should eq(CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StorageMode::VariableBytes)
      value_data.semantic_type.should eq(nullable_value ? "Nullable(String)" : "String")
      value_data.storage_axis.id.should eq(value_bytes_axis.id)
      value_data.semantic_path.should eq(["values"])
    end
  end

  it "keeps extra nesting and unsupported neighboring declarations rejected" do
    {
      "Array(Map(String, Array(String)))",
      "Array(Array(Map(String, String)))",
      "Array(Map(UInt32, String))",
      "Array(Map(Int64, String))",
      "Array(Map(String, String)) trailing",
    }.each do |type|
      CrystalClick::WideTypePlan::WidePhysicalPlanShadow.for_type(type).should be_nil
    end
  end
end
