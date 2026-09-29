require "./spec_helper"

describe "W83 Array(Map) Bool-leaf physical plan" do
  it "admits only the four exact UInt64/String key and Bool/Nullable(Bool) declarations" do
    exact = [
      "Array(Map(UInt64, Bool))",
      "Array(Map(String, Bool))",
      "Array(Map(UInt64, Nullable(Bool)))",
      "Array(Map(String, Nullable(Bool)))",
    ]
    exact.each do |type|
      CrystalClick::WideTypePlan::WidePhysicalPlanShadow.for_type(type).should_not be_nil
      CrystalClick::WidePart.supports_typed_type?(type).should be_true
      CrystalClick::WidePart.supports_array_map_type?(type).should be_true
      CrystalClick::WideTypePlan.admitted(type).should be_nil
    end

    [
      "Array(Map(Int64, Bool))",
      "Array(Map(UInt32, Bool))",
      "Array(Map(UInt64, Nullable(Nullable(Bool))))",
      "Array(Map(UInt64, Bool)) ",
      "Array(Map(UInt64,Nullable(Bool)))",
      "Array(Map(UInt64, Bool, String))",
      "Array(Map(UInt64, Array(Bool)))",
    ].each do |type|
      CrystalClick::WideTypePlan::WidePhysicalPlanShadow.for_type(type).should be_nil
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
      CrystalClick::WidePart.supports_array_map_type?(type).should be_false
    end

    # UInt8 is a neighboring W81 numeric shape, not a Bool alias. Preserve
    # that older admission while keeping it out of W83's exact Bool API.
    ["Array(Map(UInt64, UInt8))", "Array(Map(UInt64, Nullable(UInt8)))"].each do |type|
      CrystalClick::WideTypePlan::WidePhysicalPlanShadow.for_type(type).should_not be_nil
      CrystalClick::WidePart.supports_array_map_bool_leaf_type?(type).should be_false
    end
  end

  it "binds all stock streams to table rows and the exact nested cardinality axes" do
    type = "Array(Map(String, Nullable(Bool)))"
    plan = CrystalClick::WideTypePlan::WidePhysicalPlanShadow.for_type(type, "payload").not_nil!
    plan.streams.map(&.name).should eq([
      "payload.size0",
      "payload.size1",
      "payload%2Ekeys.size",
      "payload%2Ekeys",
      "payload%2Evalues.null",
      "payload%2Evalues",
    ])
    plan.streams.each do |stream|
      stream.mark_row_axis.id.should eq("table_rows")
    end

    outer, maps, key_sizes, keys, null_map, values = plan.streams
    outer.role.array_size0?.should be_true
    outer.storage_mode.counts?.should be_true
    outer.cardinality_parent_axis.not_nil!.id.should eq("table_rows")
    outer.cardinality_child_axis.not_nil!.kind.array_elements?.should be_true

    maps.role.array_size1?.should be_true
    maps.storage_mode.counts?.should be_true
    maps.cardinality_parent_axis.not_nil!.id.should eq(outer.cardinality_child_axis.not_nil!.id)
    maps.cardinality_child_axis.not_nil!.kind.map_entries?.should be_true

    key_sizes.role.string_size?.should be_true
    key_sizes.cardinality_parent_axis.not_nil!.id.should eq(maps.cardinality_child_axis.not_nil!.id)
    key_sizes.cardinality_child_axis.not_nil!.kind.string_bytes?.should be_true
    keys.storage_mode.variable_bytes?.should be_true
    keys.storage_axis.id.should eq(key_sizes.cardinality_child_axis.not_nil!.id)

    null_map.role.null_map?.should be_true
    null_map.storage_mode.null_map_bytes?.should be_true
    null_map.storage_axis.id.should eq(maps.cardinality_child_axis.not_nil!.id)
    values.role.value?.should be_true
    values.element_width.should eq(1)
    values.storage_mode.fixed_width_values?.should be_true
    values.storage_axis.id.should eq(maps.cardinality_child_axis.not_nil!.id)
    values.semantic_type.should eq("Nullable(Bool)")
  end
end
