require "./spec_helper"

describe "W114 exact Geometry admission boundary" do
  it "keeps the bare legacy owner separate from shared recursive static routes" do
    CrystalClick::WidePart.supports_typed_type?("Geometry").should be_true
    {
      "GEOMETRY",
      "Nullable(Geometry)",
      "LowCardinality(Geometry)",
    }.each do |type_name|
      CrystalClick::WidePart.supports_typed_type?(type_name).should be_false
      CrystalClick::WideVariantTypePlanDescriptor.for_type(type_name).should be_nil
    end

    # W239 admits recursive wrappers while preserving the nominal Geometry
    # wrapper as the visitor's one transparent child.
    {"Array(Geometry)", "Tuple(Geometry)"}.each do |type_name|
      CrystalClick::WidePart.supports_typed_type?(type_name).should be_true
      CrystalClick::WideVariantTypePlanDescriptor.for_type(type_name).should be_nil
    end

    # W238 already admitted these ordinary static Variant products through the
    # shared Custom Geo recursion route. The specialized Geometry Variant
    # descriptor remains unavailable; W239 does not widen that legacy owner.
    {
      "Variant(MultiPoint, Point)",
      "Variant(LineString, MultiLineString, MultiPoint, MultiPolygon, Point, Polygon, Ring)",
    }.each do |type_name|
      CrystalClick::WidePart.supports_typed_type?(type_name).should be_true
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
