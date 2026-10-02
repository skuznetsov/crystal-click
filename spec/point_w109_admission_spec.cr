require "./spec_helper"

describe "W109 exact Point admission" do
  it "admits Point as an explicit domain rather than generic unnamed Tuple" do
    CrystalClick::WidePart.supports_typed_type?("Point").should be_true
    CrystalClick::WidePart.supports_typed_type?("Tuple(Float64, Float64)").should be_false
    CrystalClick::WidePart.supports_typed_type?("Tuple(x Float64, y Float64)").should be_true
  end

  it "does not silently admit unqualified Geo or Point container shapes" do
    ["point", "POINT", "Point()", "Point ", "Nullable(Point)", "Array(Point)",
     "Nullable(Geometry)"].each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end
end
