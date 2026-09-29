require "./spec_helper"

describe "W84 Array(Map(K, Array(V))) physical plan" do
  it "admits only the exact paired UInt64/String key and value declarations" do
    exact = [
      "Array(Map(UInt64, Array(UInt64)))",
      "Array(Map(UInt64, Array(String)))",
      "Array(Map(String, Array(UInt64)))",
      "Array(Map(String, Array(String)))",
    ]
    exact.each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_true
      CrystalClick::WidePart.supports_array_map_type?(type).should be_true
      CrystalClick::WideTypePlan::WidePhysicalPlanShadow.for_type(type).should_not be_nil
      CrystalClick::WideTypePlan.admitted(type).should be_nil
    end

    rejected = [
      "Array(Map(UInt8, Array(UInt64)))",
      "Array(Map(UInt64, Array(UInt32)))",
      "Array(Map(UInt64, Array(Nullable(UInt64))))",
      "Array(Map(UInt64, Array(Array(UInt64))))",
      "Array(Array(Map(UInt64, Array(UInt64))))",
      "Array(Map(UInt64, Array(UInt64))) ",
      "Array(Map(UInt64, Array(UInt64), String))",
    ]
    rejected.each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
      CrystalClick::WidePart.supports_array_map_type?(type).should be_false
      CrystalClick::WideTypePlan::WidePhysicalPlanShadow.for_type(type).should be_nil
    end
  end

  it "places the four exact physical stream sets in ClickHouse serializer order" do
    expected = {
      "Array(Map(UInt64, Array(UInt64)))" => [
        "payload.size0", "payload.size1", "payload%2Ekeys",
        "payload%2Evalues.size2", "payload%2Evalues",
      ],
      "Array(Map(UInt64, Array(String)))" => [
        "payload.size0", "payload.size1", "payload%2Ekeys",
        "payload%2Evalues.size2", "payload%2Evalues.size", "payload%2Evalues",
      ],
      "Array(Map(String, Array(UInt64)))" => [
        "payload.size0", "payload.size1", "payload%2Ekeys.size",
        "payload%2Ekeys", "payload%2Evalues.size2", "payload%2Evalues",
      ],
      "Array(Map(String, Array(String)))" => [
        "payload.size0", "payload.size1", "payload%2Ekeys.size",
        "payload%2Ekeys", "payload%2Evalues.size2", "payload%2Evalues.size",
        "payload%2Evalues",
      ],
    }

    expected.each do |type, stream_names|
      plan = CrystalClick::WideTypePlan::WidePhysicalPlanShadow.for_type(type, "payload").not_nil!
      plan.streams.map(&.name).should eq(stream_names)
      plan.streams.each do |stream|
        stream.mark_row_axis.id.should eq("table_rows")
      end

      outer, maps = plan.streams[0], plan.streams[1]
      outer.role.array_size0?.should be_true
      outer.cardinality_parent_axis.not_nil!.id.should eq("table_rows")
      outer.cardinality_child_axis.not_nil!.kind.array_elements?.should be_true
      maps.role.array_size1?.should be_true
      maps.cardinality_parent_axis.not_nil!.id.should eq(outer.cardinality_child_axis.not_nil!.id)
      maps.cardinality_child_axis.not_nil!.kind.map_entries?.should be_true

      value_sizes = plan.streams.find(&.name.==("payload%2Evalues.size2")).not_nil!
      value_sizes.role.array_size2?.should be_true
      value_sizes.cardinality_parent_axis.not_nil!.id.should eq(maps.cardinality_child_axis.not_nil!.id)
      value_axis = value_sizes.cardinality_child_axis.not_nil!
      value_axis.kind.array_elements?.should be_true
      value_leaf = plan.streams.find { |stream| stream.name == "payload%2Evalues" && stream.role.value? }.not_nil!
      value_sizes.semantic_type.should eq("Array(#{type.ends_with?("Array(String)))") ? "String" : "UInt64"})")

      if key_sizes = plan.streams.find(&.name.==("payload%2Ekeys.size"))
        key_sizes.role.string_size?.should be_true
        key_sizes.cardinality_parent_axis.not_nil!.id.should eq(maps.cardinality_child_axis.not_nil!.id)
        key_sizes.cardinality_child_axis.not_nil!.kind.string_bytes?.should be_true
      end
      if value_sizes = plan.streams.find(&.name.==("payload%2Evalues.size"))
        value_sizes.role.string_size?.should be_true
        value_sizes.cardinality_parent_axis.not_nil!.id.should eq(value_axis.id)
        value_sizes.cardinality_child_axis.not_nil!.kind.string_bytes?.should be_true
        value_leaf.storage_axis.id.should eq(value_sizes.cardinality_child_axis.not_nil!.id)
      else
        value_leaf.storage_axis.id.should eq(value_axis.id)
      end
    end
  end
end
