require "./spec_helper"

describe CrystalClick::WideTypePlan::WidePhysicalPlanShadow do
  it "describes the exact W70 String-key nested nullable String streams and axes" do
    candidate = "Map(String, Array(Nullable(String)))"
    maybe_plan = CrystalClick::WideTypePlan::WidePhysicalPlanShadow.for_type(candidate)
    maybe_plan.should_not be_nil

    if plan = maybe_plan
      plan.column_type.should eq(candidate)
      plan.streams.map(&.name).should eq([
        "payload.size0",
        "payload%2Ekeys.size",
        "payload%2Ekeys",
        "payload%2Evalues.size1",
        "payload%2Evalues.null",
        "payload%2Evalues.size",
        "payload%2Evalues",
      ])
      plan.streams.map(&.element_width).should eq([8, 8, 1, 8, 1, 8, 1])
      plan.streams.map(&.storage_mode).should eq([
        CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StorageMode::Counts,
        CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StorageMode::Counts,
        CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StorageMode::VariableBytes,
        CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StorageMode::Counts,
        CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StorageMode::NullMapBytes,
        CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StorageMode::Counts,
        CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StorageMode::VariableBytes,
      ])
      plan.streams.map(&.role).should eq([
        CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StreamRole::MapSize0,
        CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StreamRole::StringSize,
        CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StreamRole::Value,
        CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StreamRole::ArraySize1,
        CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StreamRole::NullMap,
        CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StreamRole::StringSize,
        CrystalClick::WideTypePlan::WidePhysicalPlanShadow::StreamRole::Value,
      ])

      map_size, key_sizes, keys, array_sizes, nulls, value_sizes, values = plan.streams
      entries_axis = map_size.cardinality_child_axis.not_nil!
      leaf_axis = array_sizes.cardinality_child_axis.not_nil!
      key_bytes_axis = key_sizes.cardinality_child_axis.not_nil!
      value_bytes_axis = value_sizes.cardinality_child_axis.not_nil!
      map_size.cardinality_parent_axis.not_nil!.id.should eq("table_rows")
      key_sizes.cardinality_parent_axis.not_nil!.id.should eq(entries_axis.id)
      keys.storage_axis.id.should eq(key_bytes_axis.id)
      key_sizes.semantic_path.should eq(["keys"])
      array_sizes.cardinality_parent_axis.not_nil!.id.should eq(entries_axis.id)
      nulls.storage_axis.id.should eq(leaf_axis.id)
      value_sizes.cardinality_parent_axis.not_nil!.id.should eq(leaf_axis.id)
      values.storage_axis.id.should eq(value_bytes_axis.id)
      value_sizes.semantic_path.should eq(["values"])
      plan.mark_row_axis.kind.should eq(CrystalClick::WideTypePlan::WidePhysicalPlanShadow::AxisKind::TableRows)
      plan.streams.each { |stream| stream.mark_row_axis.id.should eq("table_rows") }
    end
  end

  it "keeps W70 syntax parseable without admitting nearby Map spellings" do
    candidate = "Map(String, Array(Nullable(String)))"
    CrystalClick::WideTypePlan.parse(candidate).should_not be_nil
    CrystalClick::WideTypePlan.admitted(candidate).should be_nil
    CrystalClick::WideTypePlan::WidePhysicalPlanShadow
      .for_type("Map(String, Array(Nullable(UInt64)))").should_not be_nil

    {
      "Map(String, Array(Nullable(Int64)))",
      "Map(String, Array(Array(Nullable(String))))",
      "Map(String, Nullable(Array(Nullable(String))))",
      "Map(String, Array(Nullable(String))) trailing",
    }.each do |type|
      CrystalClick::WideTypePlan::WidePhysicalPlanShadow.for_type(type).should be_nil
    end
  end
end
