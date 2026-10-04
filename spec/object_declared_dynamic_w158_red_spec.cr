require "./spec_helper"

describe "W158 direct declared Dynamic schema RED cases" do
  it "renders an explicitly declared Dynamic typed path canonically" do
    type = CrystalClick::BinaryDataType.dynamic
    schema = CrystalClick::ObjectDocumentSchema.new({"a" => type})

    schema.declaration.should eq("JSON(a Dynamic)")
    schema.typed_paths.should eq({"a" => type})
  end

  it "parses a directly declared Dynamic typed path canonically" do
    parsed = CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(a Dynamic)")

    parsed.declaration.should eq("JSON(a Dynamic)")
    parsed.typed_paths.should eq({"a" => CrystalClick::BinaryDataType.dynamic})
  end

  it "preserves exact Dynamic max_types boundary declarations through construction and parsing" do
    {0, 254}.each do |max_types|
      type = CrystalClick::BinaryDataType.dynamic(max_types)
      declaration = "JSON(a Dynamic(max_types=#{max_types}))"
      expected = {"a" => type}

      constructed = CrystalClick::ObjectDocumentSchema.new(expected)
      constructed.declaration.should eq(declaration)
      constructed.typed_paths.should eq(expected)

      parsed = CrystalClick::ObjectDocumentSchema.parse_declaration(declaration)
      parsed.declaration.should eq(declaration)
      parsed.typed_paths.should eq(expected)
    end
  end
end
