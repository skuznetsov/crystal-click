require "./spec_helper"

describe "W81 bounded Array(Map) numeric family" do
  it "plans UInt64-key and nullable String-key stream axes without offset collisions" do
    uint_plan = CrystalClick::WideTypePlan::WidePhysicalPlanShadow
      .for_type("Array(Map(UInt64, Int8))")
    uint_plan.should_not be_nil
    uint_streams = uint_plan.not_nil!.streams
    uint_streams.map(&.name).should eq([
      "payload.size0", "payload.size1", "payload%2Ekeys", "payload%2Evalues",
    ])
    uint_streams.map(&.element_width).should eq([8, 8, 8, 1])
    uint_streams.map(&.storage_axis.id).should eq([
      "table_rows", "payload:root:array0_elements",
      "payload:root:map_entries", "payload:root:map_entries",
    ])

    nullable_plan = CrystalClick::WideTypePlan::WidePhysicalPlanShadow
      .for_type("Array(Map(String, Nullable(Float32)))")
    nullable_plan.should_not be_nil
    nullable_streams = nullable_plan.not_nil!.streams
    nullable_streams.map(&.name).should eq([
      "payload.size0", "payload.size1", "payload%2Ekeys.size",
      "payload%2Ekeys", "payload%2Evalues.null", "payload%2Evalues",
    ])
    nullable_streams.map(&.element_width).should eq([8, 8, 8, 1, 1, 4])
    nullable_streams.each { |stream| stream.mark_row_axis.id.should eq("table_rows") }
  end

  it "admits the closed numeric matrix but no neighboring container or leaf" do
    {"UInt64", "String"}.each do |key|
      {"UInt8", "UInt16", "UInt32", "UInt64", "Int8", "Int16", "Int32", "Int64", "Float32", "Float64"}.each do |leaf|
        {leaf, "Nullable(#{leaf})"}.each do |value|
          type = "Array(Map(#{key}, #{value}))"
          CrystalClick::WideTypePlan::WidePhysicalPlanShadow.for_type(type).should_not be_nil
          CrystalClick::WidePart.supports_typed_type?(type).should be_true
        end
      end
    end

    {
      "Array(Map(String, String))",
      "Array(Map(UInt64, String))",
      "Array(Map(UInt32, UInt64))",
      "Array(Map(String, Array(UInt64)))",
      "Array(Array(Map(String, UInt64)))",
      "Array(Map(String, UInt64)) trailing",
    }.each do |type|
      CrystalClick::WideTypePlan::WidePhysicalPlanShadow.for_type(type).should be_nil
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end
end
