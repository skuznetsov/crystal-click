require "./spec_helper"

describe "W151 independent Object Variant schema probes" do
  it "retains canonical arm identity in descriptor and borrowed declaration paths" do
    string = CrystalClick::BinaryDataType.primitive("String")
    number = CrystalClick::BinaryDataType.primitive("UInt64")
    variant = CrystalClick::BinaryDataType.variant([number, string])
    declaration = "JSON(v Variant(String, UInt64))"
    CrystalClick::ObjectDocumentSchema.new({"v" => variant}).declaration.should eq(declaration)
    CrystalClick::ObjectDocumentSchema.parse_declaration(declaration).typed_paths.should eq({"v" => variant})
  end

  it "admits a nested Variant only through a legal Array arm" do
    declaration = "JSON(v Variant(Array(Variant(String, UInt64)), UInt64))"
    CrystalClick::ObjectDocumentSchema.parse_declaration(declaration).declaration.should eq(declaration)
  end

  it "shares one node and edge budget across sibling Variant subtrees" do
    string = CrystalClick::BinaryDataType.primitive("String")
    number = CrystalClick::BinaryDataType.primitive("UInt64")
    variant = CrystalClick::BinaryDataType.variant([number, string])
    fields = {"a" => variant, "b" => CrystalClick::BinaryDataType.array(variant)}
    declaration = "JSON(a Variant(String, UInt64), b Array(Variant(String, UInt64)))"
    # JSON root + three-node Variant + four-node Array(Variant), with
    # two path edges and five recursive child edges. No per-roster reset.
    exact = CrystalClick::BinaryCodecLimits.new(max_depth: 4, max_nodes: 8, max_elements: 7, max_bytes: 4096)
    CrystalClick::ObjectDocumentSchema.new(fields, limits: exact).declaration.should eq(declaration)
    CrystalClick::ObjectDocumentSchema.parse_declaration(declaration, exact).typed_paths.should eq(fields)
    [
      CrystalClick::BinaryCodecLimits.new(max_depth: 3, max_nodes: 8, max_elements: 7, max_bytes: 4096),
      CrystalClick::BinaryCodecLimits.new(max_depth: 4, max_nodes: 7, max_elements: 7, max_bytes: 4096),
      CrystalClick::BinaryCodecLimits.new(max_depth: 4, max_nodes: 8, max_elements: 6, max_bytes: 4096),
    ].each do |one_short|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentSchema.new(fields, limits: one_short)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentSchema.parse_declaration(declaration, one_short)
      end
    end
  end

  it "rejects noncanonical borrowed rosters instead of normalizing discriminator identity" do
    [
      "JSON(v Variant(UInt64, String))",
      "JSON(v Variant(String, String))",
      "JSON(v Variant(Nothing, String))",
      "JSON(v Variant(Nullable(String), UInt64))",
      "JSON(v Variant(Variant(String, UInt64), UInt64))",
    ].each do |declaration|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentSchema.parse_declaration(declaration)
      end
    end
  end
end
