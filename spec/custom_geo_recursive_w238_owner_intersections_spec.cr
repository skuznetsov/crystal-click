require "./spec_helper"

private def w238oi_type(source : String) : CrystalClick::BinaryDataType
  CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(source).not_nil!
end

private def w238oi_point_value : CrystalClick::BinaryValue
  type = CrystalClick::BinaryDataType.custom("Point")
  body = CrystalClick::BinaryValue.tuple(
    type.child_at(0),
    [
      CrystalClick::BinaryValue.float64_bits(0x3ff0_0000_0000_0000_u64),
      CrystalClick::BinaryValue.float64_bits(0x4000_0000_0000_0000_u64),
    ] of CrystalClick::BinaryValue,
  )
  CrystalClick::BinaryValue.custom(type, body)
end

describe "W238 Custom Geo intersections with other persisted owners" do
  it "does not let an AggregateFunction part owner absorb a Geo-free sibling" do
    sources = [
      "Tuple(Point, AggregateFunction(sum, UInt8))",
      "Tuple(AggregateFunction(sum, UInt8), Point)",
    ]

    sources.each do |source|
      type = w238oi_type(source)
      type.name.should eq(source)
      type.contains_custom_geo?.should be_true
      type.contains_aggregate_function?.should be_true

      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryAggregateFunctionBulkColumnDeclaration.new(type)
      end
      CrystalClick::BinaryAggregateFunctionBulkColumnDeclaration.parse(source).should be_nil
    end

    ordinary = "Tuple(UInt8, AggregateFunction(sum, UInt8))"
    CrystalClick::BinaryAggregateFunctionBulkColumnDeclaration.parse(ordinary).should_not be_nil
  end

  it "keeps SimpleAggregateFunction as a root-only physical owner" do
    sources = [
      "Tuple(Point, SimpleAggregateFunction(sum, UInt64))",
      "Tuple(SimpleAggregateFunction(sum, UInt64), Point)",
    ]

    sources.each do |source|
      type = w238oi_type(source)
      type.name.should eq(source)
      type.contains_custom_geo?.should be_true
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::SimpleAggregateBulkColumnDeclaration.new(type)
      end
      CrystalClick::SimpleAggregateBulkColumnDeclaration.parse(source).should be_nil
    end

    CrystalClick::SimpleAggregateBulkColumnDeclaration.parse(
      "SimpleAggregateFunction(sum, UInt64)"
    ).should_not be_nil
  end

  it "does not let a recursive QBit physical owner absorb a Geo sibling" do
    sources = [
      "Tuple(Point, QBit(Int8, 9))",
      "Tuple(QBit(Int8, 9), Point)",
    ]

    sources.each do |source|
      type = w238oi_type(source)
      type.name.should eq(source)
      type.contains_custom_geo?.should be_true
      type.contains_qbit?.should be_true

      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryQBitBulkColumnDeclaration.new(type)
      end
      CrystalClick::BinaryQBitBulkColumnDeclaration.parse(source).should be_nil
    end

    ordinary = "Tuple(UInt8, QBit(Int8, 9))"
    CrystalClick::BinaryQBitBulkColumnDeclaration.parse(ordinary).should_not be_nil
  end

  it "keeps nominal and actual Geo out of Dynamic plans with sibling permutations" do
    [
      "Tuple(Point, Dynamic)",
      "Tuple(Dynamic, Point)",
    ].each do |source|
      type = w238oi_type(source)
      type.name.should eq(source)
      type.contains_custom_geo?.should be_true
      type.contains_dynamic?.should be_true
      dynamic_index = type.child_at(0).tag == CrystalClick::BinaryDataType::TAG_DYNAMIC ? 0 : 1
      structures = {
        "root.field.#{dynamic_index}" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType),
      } of String => CrystalClick::DynamicStructure

      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryDynamicBulkPlan.new(type, structures)
      end
    end

    dynamic = CrystalClick::BinaryDataType.dynamic
    ordinary_plan = CrystalClick::BinaryDynamicBulkPlan.new(
      dynamic,
      {"root" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)} of String => CrystalClick::DynamicStructure,
    )
    ordinary_plan.type.should eq(dynamic)
  end

  it "rejects Geo descendants in both typed JSON schemas and Object declarations" do
    sources = [
      "Tuple(Point, UInt64)",
      "Tuple(UInt64, Point)",
    ]
    point = w238oi_point_value
    json = CrystalClick::BinaryDataType.json

    sources.each do |source|
      type = w238oi_type(source)
      type.name.should eq(source)
      type.contains_custom_geo?.should be_true

      expect_raises(ArgumentError) do
        CrystalClick::BinaryDataType.json(typed_paths: {"geom" => type})
      end
      expect_raises(ArgumentError) do
        CrystalClick::ObjectDocumentSchema.new({"geom" => type})
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(geom #{type.name})")
      end

      values = [] of CrystalClick::BinaryValue
      if type.child_at(0).tag == CrystalClick::BinaryDataType::TAG_CUSTOM
        values << point
        values << CrystalClick::BinaryValue.uint64(7_u64)
      else
        values << CrystalClick::BinaryValue.uint64(7_u64)
        values << point
      end
      tuple_value = CrystalClick::BinaryValue.tuple(type, values)
      expect_raises(ArgumentError) do
        CrystalClick::BinaryJsonRow.new(json, [{"geom", tuple_value}] of Tuple(String, CrystalClick::BinaryValue))
      end
    end

    ordinary = w238oi_type("Tuple(UInt64, UInt64)")
    CrystalClick::BinaryDataType.json(typed_paths: {"geom" => ordinary}).should_not be_nil
    schema = CrystalClick::ObjectDocumentSchema.new({"geom" => ordinary})
    CrystalClick::ObjectDocumentSchema.parse_declaration(schema.declaration).typed_paths["geom"].should eq(ordinary)
  end
end
