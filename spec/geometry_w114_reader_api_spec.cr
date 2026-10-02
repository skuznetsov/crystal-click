require "./spec_helper"

describe "W114 Geometry reader facade" do
  it "exposes the exact typed Geometry entry points" do
    CrystalClick::WidePart.supports_typed_type?("Geometry").should be_true

    part = CrystalClick::WidePart.open(FIXTURE)
    part.responds_to?(:read_geometry_mark_range).should be_true
    part.responds_to?(:each_geometry_mark_range).should be_true
    part.responds_to?(:geometry_mark_range_materialization_charge).should be_true
    part.responds_to?(:validate_geometry_mark_range_structure).should be_true
  end
end
