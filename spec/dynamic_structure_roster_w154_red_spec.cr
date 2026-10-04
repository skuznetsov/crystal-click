require "./spec_helper"

describe "W154 nested Dynamic V3 roster behavioral RED" do
  it "retains Array(Dynamic(max_types=0)) and String as separately named ordinary/shared alternatives" do
    dynamic_zero = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    array_dynamic = CrystalClick::BinaryDataType.array(dynamic_zero)
    string_type = CrystalClick::BinaryDataType.primitive("String")
    structure = CrystalClick::DynamicStructure.new(
      [array_dynamic, string_type] of CrystalClick::BinaryDataType,
    )

    # Literal V3 part-structure bytes: version 4, two descriptors, no stats.
    # The Array(Dynamic) descriptor and cap byte are authored independently.
    wire = Bytes[
      0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x02_u8,
      0x1e_u8, 0x2b_u8, 0x00_u8,
      0x15_u8,
      0x00_u8,
    ]

    structure.canonical_variant_names.should eq([
      "Array(Dynamic(max_types=0))",
      "SharedVariant",
      "String",
    ] of String)
    structure.shared_index.should eq(1)
    CrystalClick::DynamicStructureCodec.encode(structure).should eq(wire)

    decoded = CrystalClick::DynamicStructureCodec.decode(wire)
    decoded.types.should eq([array_dynamic, string_type] of CrystalClick::BinaryDataType)
    decoded.canonical_variant_names.should eq([
      "Array(Dynamic(max_types=0))",
      "SharedVariant",
      "String",
    ] of String)
    decoded.shared_index.should eq(1)
    CrystalClick::DynamicStructureCodec.encode(decoded).should eq(wire)
  end

  it "retains Array(Variant(UInt64, String)) using its canonical Variant descriptor" do
    variant = CrystalClick::BinaryDataType.variant([
      CrystalClick::BinaryDataType.primitive("UInt64"),
      CrystalClick::BinaryDataType.primitive("String"),
    ] of CrystalClick::BinaryDataType)
    array_variant = CrystalClick::BinaryDataType.array(variant)
    structure = CrystalClick::DynamicStructure.new([array_variant] of CrystalClick::BinaryDataType)

    # Variant's canonical arm order is String then UInt64, independent of the
    # constructor argument order above.
    wire = Bytes[
      0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x01_u8,
      0x1e_u8, 0x2a_u8, 0x02_u8, 0x15_u8, 0x04_u8,
      0x00_u8,
    ]

    variant.name.should eq("Variant(String, UInt64)")
    structure.canonical_variant_names.should eq([
      "Array(Variant(String, UInt64))",
      "SharedVariant",
    ] of String)
    CrystalClick::DynamicStructureCodec.encode(structure).should eq(wire)

    decoded = CrystalClick::DynamicStructureCodec.decode(wire)
    decoded.types.should eq([array_variant] of CrystalClick::BinaryDataType)
    decoded.canonical_variant_names.should eq([
      "Array(Variant(String, UInt64))",
      "SharedVariant",
    ] of String)
    CrystalClick::DynamicStructureCodec.encode(decoded).should eq(wire)
  end

  it "keeps immediate Dynamic alternatives and Dynamic Variant arms refused" do
    dynamic_zero = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    immediate = expect_raises(ArgumentError) do
      CrystalClick::DynamicStructure.new([dynamic_zero] of CrystalClick::BinaryDataType)
    end
    immediate.message.should eq("Dynamic alternatives are not admitted in Dynamic V3")

    dynamic_arm = expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.variant([
        dynamic_zero,
        CrystalClick::BinaryDataType.primitive("UInt64"),
      ] of CrystalClick::BinaryDataType)
    end
    dynamic_arm.message.should eq("Variant cannot directly contain Dynamic")
  end
end
