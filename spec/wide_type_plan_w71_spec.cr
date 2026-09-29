require "./spec_helper"

describe CrystalClick::WideTypePlan::WidePhysicalPlanShadow do
  it "describes W71 UInt64 keys and the nested nullable String byte axis" do
    candidate = "Map(UInt64, Array(Nullable(String)))"
    maybe_plan = CrystalClick::WideTypePlan::WidePhysicalPlanShadow.for_type(candidate)
    maybe_plan.should_not be_nil

    if plan = maybe_plan
      plan.column_type.should eq(candidate)
      plan.streams.map(&.name).should eq([
        "payload.size0",
        "payload%2Ekeys",
        "payload%2Evalues.size1",
        "payload%2Evalues.null",
        "payload%2Evalues.size",
        "payload%2Evalues",
      ])
      plan.streams.map(&.element_width).should eq([8, 8, 8, 1, 8, 1])
      plan.streams.map(&.storage_mode).should eq([
        CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StorageMode::Counts,
        CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StorageMode::FixedWidthValues,
        CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StorageMode::Counts,
        CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StorageMode::NullMapBytes,
        CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StorageMode::Counts,
        CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StorageMode::VariableBytes,
      ])
      plan.streams.map(&.role).should eq([
        CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StreamRole::MapSize0,
        CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StreamRole::Value,
        CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StreamRole::ArraySize1,
        CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StreamRole::NullMap,
        CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StreamRole::StringSize,
        CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StreamRole::Value,
      ])

      map_sizes, keys, array_sizes, nulls, value_sizes, values = plan.streams
      entries_axis = map_sizes.cardinality_child_axis.not_nil!
      leaves_axis = array_sizes.cardinality_child_axis.not_nil!
      bytes_axis = value_sizes.cardinality_child_axis.not_nil!
      map_sizes.cardinality_parent_axis.not_nil!.id.should eq("table_rows")
      keys.storage_axis.id.should eq(entries_axis.id)
      keys.semantic_path.should eq(["keys"])
      array_sizes.cardinality_parent_axis.not_nil!.id.should eq(entries_axis.id)
      nulls.storage_axis.id.should eq(leaves_axis.id)
      value_sizes.cardinality_parent_axis.not_nil!.id.should eq(leaves_axis.id)
      value_sizes.semantic_path.should eq(["values"])
      values.storage_axis.id.should eq(bytes_axis.id)
      plan.streams.each { |stream| stream.mark_row_axis.id.should eq("table_rows") }
    end
  end

  it "keeps shadow-only W71 syntax outside typed admission and rejects nearby spellings" do
    candidate = "Map(UInt64, Array(Nullable(String)))"
    CrystalClick::WideTypePlan.parse(candidate).should_not be_nil
    CrystalClick::WideTypePlan.admitted(candidate).should be_nil

    {
      "Map(Int64, Array(Nullable(String)))",
      "Map(UInt64, Array(Array(Nullable(String))))",
      "Map(UInt64, Nullable(Array(Nullable(String))))",
      "Map(UInt64, Array(Nullable(String))) trailing",
    }.each do |type|
      CrystalClick::WideTypePlan::WidePhysicalPlanShadow.for_type(type).should be_nil
    end
  end
end
