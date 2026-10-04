require "./spec_helper"

private def w159_assert_dynamic_schema_round_trip(
  type : CrystalClick::BinaryDataType,
  expected : String,
) : Nil
  schema = CrystalClick::ObjectDocumentSchema.new({"value" => type})
  schema.declaration.should eq(expected)

  parsed = CrystalClick::ObjectDocumentSchema.parse_declaration(expected)
  parsed.declaration.should eq(expected)
  parsed.typed_paths.should eq({"value" => type})
end

describe "W159 recursive declared Dynamic schema RED cases" do
  it "constructs and parses Array(Dynamic) with an exact nested cap" do
    dynamic = CrystalClick::BinaryDataType.dynamic(1)
    type = CrystalClick::BinaryDataType.array(dynamic)

    w159_assert_dynamic_schema_round_trip(
      type,
      "JSON(value Array(Dynamic(max_types=1)))",
    )
  end

  it "constructs and parses two named Tuple Dynamic sites with equal caps" do
    dynamic = CrystalClick::BinaryDataType.dynamic(1)
    type = CrystalClick::BinaryDataType.tuple(
      [dynamic, dynamic] of CrystalClick::BinaryDataType,
      ["left", "right"] of String,
    )

    w159_assert_dynamic_schema_round_trip(
      type,
      "JSON(value Tuple(left Dynamic(max_types=1), right Dynamic(max_types=1)))",
    )
  end

  it "constructs and parses Map(String, Dynamic)" do
    string = CrystalClick::BinaryDataType.primitive("String")
    dynamic = CrystalClick::BinaryDataType.dynamic(1)
    type = CrystalClick::BinaryDataType.map(string, dynamic)

    w159_assert_dynamic_schema_round_trip(
      type,
      "JSON(value Map(String, Dynamic(max_types=1)))",
    )
  end

  it "constructs and parses Dynamic sites nested through Array and Tuple" do
    string = CrystalClick::BinaryDataType.primitive("String")
    dynamic = CrystalClick::BinaryDataType.dynamic(1)
    tuple = CrystalClick::BinaryDataType.tuple(
      [
        CrystalClick::BinaryDataType.array(dynamic),
        CrystalClick::BinaryDataType.map(string, dynamic),
      ] of CrystalClick::BinaryDataType,
      ["items", "lookup"] of String,
    )
    type = CrystalClick::BinaryDataType.array(tuple)

    w159_assert_dynamic_schema_round_trip(
      type,
      "JSON(value Array(Tuple(items Array(Dynamic(max_types=1)), lookup Map(String, Dynamic(max_types=1)))))",
    )
  end
end
