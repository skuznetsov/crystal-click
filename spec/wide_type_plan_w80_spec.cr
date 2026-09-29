require "./spec_helper"

describe "W80 Array(Map(String, UInt64)) physical plan and admission" do
  it "tracks two distinct nested offset depths and all child axes" do
    plan = CrystalClick::WideTypePlan::WidePhysicalPlanShadow
      .for_type("Array(Map(String, UInt64))")
    plan.should_not be_nil
    streams = plan.not_nil!.streams

    streams.map(&.name).should eq([
      "payload.size0",
      "payload.size1",
      "payload%2Ekeys.size",
      "payload%2Ekeys",
      "payload%2Evalues",
    ])
    streams.map(&.element_width).should eq([8, 8, 8, 1, 8])
    streams.map(&.storage_axis.id).should eq([
      "table_rows",
      "payload:root:array0_elements",
      "payload:root:map_entries",
      "payload:keys:string_bytes",
      "payload:root:map_entries",
    ])
    streams.map(&.cardinality_parent_axis.try(&.id)).should eq([
      "table_rows",
      "payload:root:array0_elements",
      "payload:root:map_entries",
      nil,
      nil,
    ])
    streams.map(&.cardinality_child_axis.try(&.id)).should eq([
      "payload:root:array0_elements",
      "payload:root:map_entries",
      "payload:keys:string_bytes",
      nil,
      nil,
    ])
    streams.each { |stream| stream.mark_row_axis.id.should eq("table_rows") }
  end

  it "admits the exact W80 type without widening to nearby declarations" do
    CrystalClick::WidePart.supports_typed_type?("Array(Map(String, UInt64))").should be_true

    {
      "Array(Map(UInt64, UInt64))",
      "Array(Map(String, String))",
      "Array(Map(String, Nullable(UInt64)))",
      "Array(Array(Map(String, UInt64)))",
      "Array(Map(String, UInt64)) trailing",
    }.each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
      CrystalClick::WideTypePlan::WidePhysicalPlanShadow.for_type(type).should be_nil
    end
  end
end
