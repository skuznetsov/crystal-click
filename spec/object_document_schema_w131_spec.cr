require "./spec_helper"

private def w131_schema_type(name : String) : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.primitive(name)
end

private def w131_schema_limits(max_bytes : Int = 1024) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(max_depth: 32, max_nodes: 1024, max_elements: 1024, max_bytes: max_bytes)
end

private def w131_schema_plan(type : CrystalClick::BinaryDataType) : CrystalClick::ObjectDocumentPlan
  dynamic = CrystalClick::DynamicStructure.new([w131_schema_type("String")])
  object = CrystalClick::ObjectStructure.new(["d"], 4_u64, 0_u64, 1_u64)
  structures = CrystalClick::ObjectDynamicStructureSet.new(object, {"d" => dynamic})
  CrystalClick::ObjectDocumentPlan.new(structures, {"n" => type})
end

describe "W131 declared Int64 Object schema" do
  it "constructs and parses Int64 with canonical sorted rendering" do
    schema = CrystalClick::ObjectDocumentSchema.new({
      "z" => w131_schema_type("String"),
      "n" => w131_schema_type("Int64"),
    })
    schema.declaration.should eq("JSON(n Int64, z String)")
    schema.typed_paths.should eq({
      "n" => w131_schema_type("Int64"),
      "z" => w131_schema_type("String"),
    })

    parsed = CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(z String, n Int64)")
    parsed.declaration.should eq("JSON(n Int64, z String)")
    parsed.declaration_byte_size.should eq(23)
  end

  it "accounts for exact constructor declaration byte sizes and limits" do
    {"Int64" => 5, "UInt64" => 6, "String" => 6}.each do |name, type_bytes|
      declaration = "JSON(v #{name})"
      declaration.bytesize.should eq(8 + type_bytes)
      required_bytes = 1 + declaration.bytesize * 2 # retained path plus builder/output declaration

      schema = CrystalClick::ObjectDocumentSchema.new(
        {"v" => w131_schema_type(name)},
        limits: w131_schema_limits(required_bytes)
      )
      schema.declaration.should eq(declaration)
      schema.declaration_byte_size.should eq(declaration.bytesize)

      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentSchema.new(
          {"v" => w131_schema_type(name)},
          limits: w131_schema_limits(required_bytes - 1)
        )
      end
    end
  end

  it "accounts for exact parser declaration and retained-copy byte limits" do
    {"Int64" => 47, "UInt64" => 51, "String" => 51}.each do |name, required_bytes|
      declaration = "JSON(v #{name})"
      parsed = CrystalClick::ObjectDocumentSchema.parse_declaration(declaration, w131_schema_limits(required_bytes))
      parsed.declaration.should eq(declaration)

      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentSchema.parse_declaration(declaration, w131_schema_limits(required_bytes - 1))
      end
    end
  end

  it "preserves exact nominal Int64 schema-plan identity" do
    schema = CrystalClick::ObjectDocumentSchema.new({"n" => w131_schema_type("Int64")})
    schema.validate_plan(w131_schema_plan(w131_schema_type("Int64"))).should be_nil

    expect_raises(ArgumentError) do
      schema.validate_plan(w131_schema_plan(w131_schema_type("UInt64")))
    end
  end

  it "rejects BFloat16 while admitting legal Nullable and Array Int64 declarations" do
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentSchema.new({"n" => w131_schema_type("BFloat16")})
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(n BFloat16)")
    end

    types = {
      "array"    => CrystalClick::BinaryDataType.array(w131_schema_type("Int64")),
      "nullable" => CrystalClick::BinaryDataType.nullable(w131_schema_type("Int64")),
    } of String => CrystalClick::BinaryDataType
    schema = CrystalClick::ObjectDocumentSchema.new(types)
    schema.declaration.should eq("JSON(array Array(Int64), nullable Nullable(Int64))")
    parsed = CrystalClick::ObjectDocumentSchema.parse_declaration(schema.declaration)
    parsed.typed_paths.should eq(types)
  end
end
