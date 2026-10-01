require "./spec_helper"

W108_ADMISSION_TUPLE_WITNESS = "Tuple(left Tuple(code UInt64, note Nullable(String)), right Tuple(code DateTime64(9, 'America/New_York'), state Nullable(Enum8('negative' = -7, 'positive' = 4))))"

describe "W108 compositional Map(Tuple) admission" do
  ["String", "UInt64"].each do |key_type|
    it "admits #{key_type} keys with recursively named scalar/Nullable Tuple values" do
      declaration = "Map(#{key_type}, #{W108_ADMISSION_TUPLE_WITNESS})"
      CrystalClick::WidePart.supports_typed_type?(declaration).should be_true
    end
  end

  it "counts the Map wrapper in the complete-source recursion budget" do
    value = "Tuple(value UInt8)"
    (CrystalClick::WideTupleSchemaParser::MAX_DEPTH - 2).times do
      value = "Tuple(child #{value})"
    end
    CrystalClick::WideMapTupleTypePlan.for_type("Map(UInt64, #{value})").should_not be_nil

    too_deep = "Tuple(child #{value})"
    CrystalClick::WideTupleTypePlan.for_type(too_deep).should_not be_nil
    CrystalClick::WideMapTupleTypePlan.for_type("Map(UInt64, #{too_deep})").should be_nil
  end

  it "preserves existing controls and rejects unsupported key/container edges" do
    CrystalClick::WidePart.supports_typed_type?("Map(String, UInt64)").should be_true
    CrystalClick::WidePart.supports_typed_type?("Map(UInt64, String)").should be_true
    CrystalClick::WidePart.supports_typed_type?("Array(#{W108_ADMISSION_TUPLE_WITNESS})").should be_true

    [
      "Map(Nullable(String), #{W108_ADMISSION_TUPLE_WITNESS})",
      "Map(String, Nullable(#{W108_ADMISSION_TUPLE_WITNESS}))",
      "Map(String, Tuple(value Array(UInt64)))",
      "Map(String, Tuple(value Map(String, UInt64)))",
      "Map(String, Tuple(value Nullable(Tuple(inner UInt64))))",
      "Map(String, Tuple())",
      "Map(String, Tuple(UInt64, String))",
      "Map(String, Tuple(value UInt64, value String))",
    ].each do |declaration|
      CrystalClick::WidePart.supports_typed_type?(declaration).should be_false
    end
  end
end
