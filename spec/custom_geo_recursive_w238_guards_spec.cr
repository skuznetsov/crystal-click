require "./spec_helper"

private def w238g_point : CrystalClick::BinaryValue
  type = CrystalClick::BinaryDataType.custom("Point")
  body = CrystalClick::BinaryValue.tuple(type.child_at(0), [
    CrystalClick::BinaryValue.float64_bits(0x3ff0_0000_0000_0000_u64),
    CrystalClick::BinaryValue.float64_bits(0x4000_0000_0000_0000_u64),
  ] of CrystalClick::BinaryValue)
  CrystalClick::BinaryValue.custom(type, body)
end

describe "W238 Custom Geo owner boundaries" do
  it "does not silently widen Count's separate nominal argument profile" do
    point = CrystalClick::BinaryDataType.custom("Point")
    [point, CrystalClick::BinaryDataType.array(point)].each do |type|
      CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(type.name).should eq(type)
      CrystalClick::BinaryAggregateCountArgumentNameParser.parse_canonical(type.name).should be_nil
      CrystalClick::BinaryAggregateCountArgumentPolicy.admitted?(type).should be_false
      expect_raises(ArgumentError, "outside the bounded canonical profile") do
        CrystalClick::BinaryDataType.aggregate_count(type)
      end
    end
    CrystalClick::BinaryAggregateCountArgumentPolicy.admitted?(
      CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.primitive("UInt64"))
    ).should be_true
  end

  it "rejects unqualified Custom Geo ordinary and shared actuals in legacy Dynamic V3" do
    point = w238g_point
    ordinary = CrystalClick::DynamicStructure.new([point.type] of CrystalClick::BinaryDataType)
    shared = CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)
    [ordinary, shared].each do |structure|
      expect_raises(CrystalClick::UnsupportedFormatError, "Custom Geo") do
        CrystalClick::DynamicValueCodec.encode(
          structure, [[point] of CrystalClick::BinaryValue] of Array(CrystalClick::BinaryValue)
        )
      end
    end
  end

  it "rejects a Custom Geo Dynamic roster even for a zero-row child-site operation" do
    point = CrystalClick::BinaryDataType.custom("Point")
    expect_raises(CrystalClick::UnsupportedFormatError, "Custom Geo") do
      CrystalClick::BinaryDynamicBulkPlan.new(
        CrystalClick::BinaryDataType.dynamic,
        {"root" => CrystalClick::DynamicStructure.new([point] of CrystalClick::BinaryDataType)}
      )
    end
  end
end
