require "./spec_helper"

describe "W79 nullable numeric Map Array admission" do
  it "admits the next nullable numeric leaf under both supported Map keys" do
    [
      "Map(UInt64, Array(Nullable(Int8)))",
      "Map(String, Array(Nullable(Float64)))",
    ].each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_true
      CrystalClick::WideTypePlan::WidePhysicalPlanShadow.for_type(type).should_not be_nil
    end
  end
end
