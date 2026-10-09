require "./spec_helper"

describe "W109 exact Point admission" do
  it "admits Point as an explicit domain rather than generic unnamed Tuple" do
    CrystalClick::WidePart.supports_typed_type?("Point").should be_true
    CrystalClick::WidePart.supports_typed_type?("Tuple(Float64, Float64)").should be_false
    CrystalClick::WidePart.supports_typed_type?("Tuple(x Float64, y Float64)").should be_true
  end

  it "does not admit malformed Point spellings or Nullable Geometry" do
    # Nullable(Point) and Array(Point) are qualified by the W238 recursive
    # Custom Geo admission spec, not this legacy Point-only guard.
    ["point", "POINT", "Point()", "Point ", "Nullable(Geometry)"].each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end
end
