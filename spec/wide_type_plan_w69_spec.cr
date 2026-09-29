require "./spec_helper"

describe CrystalClick::WideTypePlan::WidePhysicalPlanShadow do
  it "describes the exact W69 UInt64-key nested nullable Array streams and axes" do
    candidate = "Map(UInt64, Array(Nullable(UInt64)))"
    maybe_plan = CrystalClick::WideTypePlan::WidePhysicalPlanShadow.for_type(candidate)
    maybe_plan.should_not be_nil

    if plan = maybe_plan
      plan.column_type.should eq(candidate)
      plan.streams.map(&.name).should eq([
        "payload.size0",
        "payload%2Ekeys",
        "payload%2Evalues.size1",
        "payload%2Evalues.null",
        "payload%2Evalues",
      ])
      plan.streams.map(&.element_width).should eq([8, 8, 8, 1, 8])
      plan.streams.map(&.storage_mode).should eq([
        CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StorageMode::Counts,
        CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StorageMode::FixedWidthValues,
        CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StorageMode::Counts,
        CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StorageMode::NullMapBytes,
        CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StorageMode::FixedWidthValues,
      ])
      plan.streams.map(&.role).should eq([
        CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StreamRole::MapSize0,
        CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StreamRole::Value,
        CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StreamRole::ArraySize1,
        CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StreamRole::NullMap,
        CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StreamRole::Value,
      ])

      map_size, keys, values_size, nulls, values = plan.streams
      entries_axis = map_size.cardinality_child_axis.not_nil!
      values_axis = values_size.cardinality_child_axis.not_nil!
      map_size.cardinality_parent_axis.not_nil!.id.should eq("table_rows")
      keys.storage_axis.id.should eq(entries_axis.id)
      keys.semantic_path.should eq(["keys"])
      values_size.storage_axis.id.should eq(entries_axis.id)
      values_size.semantic_path.should eq(["values"])
      nulls.storage_axis.id.should eq(values_axis.id)
      values.storage_axis.id.should eq(values_axis.id)
      plan.mark_row_axis.kind.should eq(CrystalClick::WideTypePlan::WidePhysicalPlanShadow::AxisKind::TableRows)
      plan.streams.each { |stream| stream.mark_row_axis.id.should eq("table_rows") }
    end
  end

  it "keeps W69 syntax parseable without admitting nearby Map spellings" do
    candidate = "Map(UInt64, Array(Nullable(UInt64)))"
    CrystalClick::WideTypePlan.parse(candidate).should_not be_nil
    CrystalClick::WideTypePlan.admitted(candidate).should be_nil

    {
      "Map(Int64, Array(Nullable(UInt64)))",
      "Map(UInt64, Array(Nullable(UInt32)))",
      "Map(UInt64, Array(Array(Nullable(UInt64))))",
      "Map(UInt64, Nullable(Array(Nullable(UInt64))))",
      "Map(UInt64, Array(Nullable(UInt64))) trailing",
    }.each do |type|
      CrystalClick::WideTypePlan::WidePhysicalPlanShadow.for_type(type).should be_nil
    end
  end
end
