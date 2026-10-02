require "./spec_helper"

describe "W114 exact Geometry admission boundary" do
  it "admits only the measured declaration without opening generic Variant composition" do
    CrystalClick::WidePart.supports_typed_type?("Geometry").should be_true
    {
      "GEOMETRY",
      "Nullable(Geometry)",
      "LowCardinality(Geometry)",
      "Array(Geometry)",
      "Tuple(Geometry)",
      "Variant(Point, MultiPoint)",
      "Variant(LineString, MultiLineString, MultiPolygon, Point, Polygon, Ring, MultiPoint)",
    }.each do |type_name|
      CrystalClick::WidePart.supports_typed_type?(type_name).should be_false
      CrystalClick::WideVariantTypePlanDescriptor.for_type(type_name).should be_nil
    end

    CrystalClick::WideVariantTypePlanDescriptor.for_type("Geometry").should be_nil
    CrystalClick::WidePart.supports_typed_type?("Variant(String, UInt64)").should be_true
    CrystalClick::WidePart.supports_typed_type?("Variant(Bool, String, UInt64)").should be_true
  end

  it "rejects absolute mark origins whose selected interval cannot fit the native index" do
    expect_raises(ArgumentError) do
      CrystalClick::WideGeometryMarkSchedule.new(
        Int32::MAX, [1_u64, 1_u64], [[3_u8], [255_u8]]
      )
    end
  end
end
