require "./spec_helper"

private def w235_guard_qbit_type(element_type : String, dimension : UInt64) : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.qbit(CrystalClick::QBitType.new(element_type, dimension))
end

private def w235_guard_empty_structures : CrystalClick::ObjectDynamicStructureSet
  CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([] of String),
    {} of String => CrystalClick::DynamicStructure,
  )
end

describe "W235 static declared Object QBit refusal guards" do
  it "keeps source-valid QBit leaf and recursive candidates outside Object declaration admission" do
    qbits = [
      w235_guard_qbit_type("Int8", 9_u64),
      w235_guard_qbit_type("BFloat16", 9_u64),
      w235_guard_qbit_type("Float32", 9_u64),
      w235_guard_qbit_type("Float64", 9_u64),
    ] of CrystalClick::BinaryDataType
    qbits.map(&.name).should eq([
      "QBit(Int8, 9)",
      "QBit(BFloat16, 9)",
      "QBit(Float32, 9)",
      "QBit(Float64, 9)",
    ])

    qbit = qbits[0]
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    string = CrystalClick::BinaryDataType.primitive("String")
    tuple = CrystalClick::BinaryDataType.tuple(
      [qbit, uint8] of CrystalClick::BinaryDataType,
      ["q", "tag"] of String,
    )
    variant = CrystalClick::BinaryDataType.variant([qbit, string] of CrystalClick::BinaryDataType)
    candidates = qbits + [
      CrystalClick::BinaryDataType.qbit(CrystalClick::QBitType.new("Int8", 16_u64, 8_u64)),
      CrystalClick::BinaryDataType.array(qbit),
      tuple,
      CrystalClick::BinaryDataType.map(string, qbit),
      CrystalClick::BinaryDataType.nested(
        [qbit, uint8] of CrystalClick::BinaryDataType,
        ["q", "tag"] of String,
      ),
      CrystalClick::BinaryDataType.nullable(qbit),
      CrystalClick::BinaryDataType.nullable(tuple),
      CrystalClick::BinaryDataType.variant([qbit] of CrystalClick::BinaryDataType),
      variant,
      CrystalClick::BinaryDataType.array(variant),
    ] of CrystalClick::BinaryDataType
    candidates.map(&.name).should eq([
      "QBit(Int8, 9)",
      "QBit(BFloat16, 9)",
      "QBit(Float32, 9)",
      "QBit(Float64, 9)",
      "QBit(Int8, 16, 8)",
      "Array(QBit(Int8, 9))",
      "Tuple(q QBit(Int8, 9), tag UInt8)",
      "Map(String, QBit(Int8, 9))",
      "Nested(q QBit(Int8, 9), tag UInt8)",
      "Nullable(QBit(Int8, 9))",
      "Nullable(Tuple(q QBit(Int8, 9), tag UInt8))",
      "Variant(QBit(Int8, 9))",
      "Variant(QBit(Int8, 9), String)",
      "Array(Variant(QBit(Int8, 9), String))",
    ])

    candidates.each do |type|
      expect_raises(ArgumentError, "typed JSON schema admits only supported Object recursive types") do
        CrystalClick::ObjectDocumentSchema.new({"payload" => type})
      end
      expect_raises(ArgumentError, "typed Object QBit descriptor is outside the persisted Object declaration grammar") do
        CrystalClick::ObjectDocumentPlan.new(w235_guard_empty_structures, {"payload" => type})
      end
      expect_raises(CrystalClick::UnsupportedFormatError, "typed Object JSON fields admit only supported Object recursive types") do
        CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(payload #{type.name})")
      end
    end
  end

  it "retains an admitted ordinary recursive Object type as a positive control" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    ordinary = CrystalClick::BinaryDataType.array(uint8)
    schema = CrystalClick::ObjectDocumentSchema.new({"items" => ordinary})
    schema.declaration.should eq("JSON(items Array(UInt8))")
    schema.typed_paths.should eq({"items" => ordinary})

    parsed = CrystalClick::ObjectDocumentSchema.parse_declaration(schema.declaration)
    parsed.declaration.should eq(schema.declaration)
    plan = CrystalClick::ObjectDocumentPlan.new(w235_guard_empty_structures, parsed.typed_paths)
    plan.typed_path_count.should eq(1)
  end
end
