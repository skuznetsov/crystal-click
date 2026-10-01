require "spec"

# Exercise the historical entry point without the aggregate library require.
require "../src/crystal_click/errors"
require "../src/crystal_click/wide_type_plan_node"
require "../src/crystal_click/wide_type_plan_parser"
require "../src/crystal_click/wide_type_expression"
require "../src/crystal_click/wide_type_plan"

describe "WideTypePlan compatibility entry point" do
  it "loads the nested physical owners under their original constant paths" do
    admitted = CrystalClick::WideTypePlan.admitted("Array(Tuple(a UInt64, b String))").not_nil!
    streams = admitted.physical_streams("payload")
    streams.map(&.name).should eq(["payload.size0", "payload%2Ea", "payload%2Eb.size", "payload%2Eb"])
    streams.map(&.element_width).should eq([8, 8, 8, 1])
    streams[1].kind.should eq(CrystalClick::WideTypePlan::PhysicalSubstreamKind::UInt64)
    field_path = streams[1].field_path
    field_path << "changed"
    streams[1].field_path.should eq(["a"])

    shadow = CrystalClick::WideTypePlan::WidePhysicalPlanShadow.for_type(admitted.column_type).not_nil!
    shadow.streams.map(&.name).should eq(streams.map(&.name))
    shadow.mark_row_axis.kind.should eq(CrystalClick::WideTypePlan::WidePhysicalPlanShadow::AxisKind::TableRows)
    shadow.streams[1].storage_axis.kind.should eq(CrystalClick::WideTypePlan::WidePhysicalPlanShadow::AxisKind::ArrayElements)
    shadow.streams[1].mark_row_axis.id.should eq("table_rows")
    shadow.streams.clear
    shadow.streams.size.should eq(4)
    shadow.axes.clear
    shadow.axes.should_not be_empty
  end

  it "does not turn parsed or shadow-only types into legacy physical admission" do
    shadow_only = "Map(String, Array(Nullable(UInt64)))"
    CrystalClick::WideTypePlan.parse(shadow_only).should_not be_nil
    CrystalClick::WideTypePlan::WidePhysicalPlanShadow.for_type(shadow_only).should_not be_nil
    CrystalClick::WideTypePlan.admitted(shadow_only).should be_nil

    neighbor = "Array(Tuple(a UInt8))"
    CrystalClick::WideTypePlan.parse(neighbor).should_not be_nil
    CrystalClick::WideTypePlan::WidePhysicalPlanShadow.for_type(neighbor).should be_nil
    CrystalClick::WideTypePlan.admitted(neighbor).should be_nil
  end
end
