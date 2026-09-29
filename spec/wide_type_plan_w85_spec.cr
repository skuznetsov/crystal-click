require "./spec_helper"

describe "W85 Array(Map(K, Array(N))) physical plan" do
  it "plans the exact UInt64 and String key matrix with all primitive numeric leaves" do
    numeric = {
      {"UInt8", 1}, {"UInt16", 2}, {"UInt32", 4}, {"UInt64", 8},
      {"Int8", 1}, {"Int16", 2}, {"Int32", 4}, {"Int64", 8},
      {"Float32", 4}, {"Float64", 8},
    }

    {"UInt64", "String"}.each do |key_type|
      numeric.each do |value_type, value_width|
        type = "Array(Map(#{key_type}, Array(#{value_type})))"
        CrystalClick::WidePart.supports_typed_type?(type).should be_true
        CrystalClick::WidePart.supports_array_map_type?(type).should be_true

        plan = CrystalClick::WideTypePlan::WidePhysicalPlanShadow.for_type(type, "payload").not_nil!
        expected_names = ["payload.size0", "payload.size1"] of String
        expected_widths = [8, 8] of Int32
        if key_type == "String"
          expected_names << "payload%2Ekeys.size"
          expected_widths << 8
        end
        expected_names << "payload%2Ekeys" << "payload%2Evalues.size2" << "payload%2Evalues"
        expected_widths << (key_type == "String" ? 1 : 8) << 8 << value_width
        plan.streams.map(&.name).should eq(expected_names)
        plan.streams.map(&.element_width).should eq(expected_widths)
        plan.streams.each { |stream| stream.mark_row_axis.id.should eq("table_rows") }

        outer, maps = plan.streams[0..1]
        outer.role.array_size0?.should be_true
        outer.cardinality_parent_axis.not_nil!.id.should eq("table_rows")
        outer_axis = outer.cardinality_child_axis.not_nil!
        outer_axis.kind.array_elements?.should be_true
        maps.role.array_size1?.should be_true
        maps.cardinality_parent_axis.not_nil!.id.should eq(outer_axis.id)
        map_axis = maps.cardinality_child_axis.not_nil!
        map_axis.kind.map_entries?.should be_true

        size2 = plan.streams.find(&.name.==("payload%2Evalues.size2")).not_nil!
        size2.role.array_size2?.should be_true
        size2.cardinality_parent_axis.not_nil!.id.should eq(map_axis.id)
        size2.cardinality_child_axis.not_nil!.kind.array_elements?.should be_true
        leaf = plan.streams.last
        leaf.role.value?.should be_true
        leaf.semantic_type.should eq(value_type)
        leaf.storage_mode.fixed_width_values?.should be_true
        leaf.storage_axis.id.should eq(size2.cardinality_child_axis.not_nil!.id)
      end
    end
  end

  it "retains the W84 UInt64 and String leaf declarations" do
    {"UInt64", "String"}.each do |key_type|
      {"UInt64", "String"}.each do |value_type|
        type = "Array(Map(#{key_type}, Array(#{value_type})))"
        CrystalClick::WidePart.supports_typed_type?(type).should be_true
        CrystalClick::WideTypePlan::WidePhysicalPlanShadow.for_type(type).should_not be_nil
      end
    end
  end

  it "rejects neighboring key, nullable, Boolean, and deeper nested declarations" do
    rejected = [
      "Array(Map(UInt8, Array(UInt16)))",
      "Array(Map(Int64, Array(Float32)))",
      "Array(Map(UInt64, Array(Bool)))",
      "Array(Map(String, Array(Nullable(UInt8))))",
      "Array(Map(UInt64, Array(Array(UInt8))))",
      "Array(Array(Map(String, Array(Float64))))",
      "Array(Map(String, Array(Float64))) ",
      "Array(Map(String, Array(Float64), UInt64))",
    ]
    rejected.each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
      CrystalClick::WidePart.supports_array_map_type?(type).should be_false
      CrystalClick::WideTypePlan::WidePhysicalPlanShadow.for_type(type).should be_nil
    end
  end
end
