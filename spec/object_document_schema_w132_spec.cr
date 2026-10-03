require "./spec_helper"

private def w132_schema_type(name : String) : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.primitive(name)
end

private def w132_schema_limits(max_bytes : Int = 1024) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(max_depth: 32, max_nodes: 1024, max_elements: 1024, max_bytes: max_bytes)
end

private def w132_schema_fields : Hash(String, CrystalClick::BinaryDataType)
  {
    "b"    => w132_schema_type("Bool"),
    "f32"  => w132_schema_type("Float32"),
    "f64"  => w132_schema_type("Float64"),
    "i128" => w132_schema_type("Int128"),
    "i16"  => w132_schema_type("Int16"),
    "i256" => w132_schema_type("Int256"),
    "i32"  => w132_schema_type("Int32"),
    "i64"  => w132_schema_type("Int64"),
    "i8"   => w132_schema_type("Int8"),
    "s"    => w132_schema_type("String"),
    "u128" => w132_schema_type("UInt128"),
    "u16"  => w132_schema_type("UInt16"),
    "u256" => w132_schema_type("UInt256"),
    "u32"  => w132_schema_type("UInt32"),
    "u64"  => w132_schema_type("UInt64"),
    "u8"   => w132_schema_type("UInt8"),
  }
end

private def w132_schema_plan(type : CrystalClick::BinaryDataType, path : String = "n") : CrystalClick::ObjectDocumentPlan
  fields = {path => type}
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    ),
    fields,
  )
end

describe "W132 declared numeric Object schema" do
  it "constructs and parses the admitted nominal numeric roster with canonical sorting" do
    fields = w132_schema_fields
    reversed_fields = Hash(String, CrystalClick::BinaryDataType).new(initial_capacity: fields.size)
    fields.keys.sort.reverse.each { |path| reversed_fields[path] = fields[path] }
    schema = CrystalClick::ObjectDocumentSchema.new(reversed_fields)
    schema.declaration.should eq(
      "JSON(b Bool, f32 Float32, f64 Float64, i128 Int128, i16 Int16, i256 Int256, i32 Int32, i64 Int64, i8 Int8, s String, u128 UInt128, u16 UInt16, u256 UInt256, u32 UInt32, u64 UInt64, u8 UInt8)"
    )
    schema.typed_paths.should eq(fields)

    arguments = fields.to_a.reverse.map { |entry| "#{entry[0]} #{entry[1].name}" }.join(", ")
    parsed = CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(#{arguments})")
    parsed.declaration.should eq(schema.declaration)
    parsed.typed_paths.should eq(fields)
  end

  it "admits exact constructor and parser byte budgets for each nominal name" do
    [
      "UInt8", "UInt16", "UInt32", "UInt64", "UInt128", "UInt256",
      "Int8", "Int16", "Int32", "Int64", "Int128", "Int256",
      "Float32", "Float64", "Bool", "String",
    ].each do |name|
      declaration = "JSON(v #{name})"
      declaration.bytesize.should eq(8 + name.bytesize)

      constructor_bytes = 1 + declaration.bytesize * 2 # retained path and builder/output declaration
      constructor = CrystalClick::ObjectDocumentSchema.new(
        {"v" => w132_schema_type(name)},
        limits: w132_schema_limits(constructor_bytes),
      )
      constructor.declaration.should eq(declaration)
      constructor.declaration_byte_size.should eq(declaration.bytesize)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentSchema.new(
          {"v" => w132_schema_type(name)},
          limits: w132_schema_limits(constructor_bytes - 1),
        )
      end

      # Parser input, path/type token copies, retained path, and two canonical
      # declaration buffers are independently accounted from this literal.
      parser_bytes = declaration.bytesize * 3 + 2 + name.bytesize + 1
      parsed = CrystalClick::ObjectDocumentSchema.parse_declaration(declaration, w132_schema_limits(parser_bytes))
      parsed.declaration.should eq(declaration)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentSchema.parse_declaration(declaration, w132_schema_limits(parser_bytes - 1))
      end
    end
  end

  it "keeps UInt8 and Bool as distinct exact schema-plan identities" do
    uint8_schema = CrystalClick::ObjectDocumentSchema.new({"n" => w132_schema_type("UInt8")})
    uint8_schema.validate_plan(w132_schema_plan(w132_schema_type("UInt8"))).should be_nil
    expect_raises(ArgumentError) do
      uint8_schema.validate_plan(w132_schema_plan(w132_schema_type("Bool")))
    end

    bool_schema = CrystalClick::ObjectDocumentSchema.new({"n" => w132_schema_type("Bool")})
    expect_raises(ArgumentError) do
      bool_schema.validate_plan(w132_schema_plan(w132_schema_type("UInt8")))
    end
  end

  it "rejects Nothing, DateTime, UUID, BFloat16, Nullable, and container declarations" do
    unsupported_types = [
      w132_schema_type("Nothing"),
      CrystalClick::BinaryDataType.datetime,
      w132_schema_type("UUID"),
      w132_schema_type("BFloat16"),
      CrystalClick::BinaryDataType.nullable(w132_schema_type("Int64")),
      CrystalClick::BinaryDataType.array(w132_schema_type("Int64")),
      CrystalClick::BinaryDataType.map(w132_schema_type("String"), w132_schema_type("Int64")),
      CrystalClick::BinaryDataType.tuple([w132_schema_type("Int64"), w132_schema_type("String")]),
    ]
    unsupported_types.each do |type|
      expect_raises(ArgumentError) do
        CrystalClick::ObjectDocumentSchema.new({"n" => type})
      end
    end

    [
      "JSON(n Nothing)",
      "JSON(n DateTime)",
      "JSON(n UUID)",
      "JSON(n BFloat16)",
      "JSON(n Nullable(Int64))",
      "JSON(n Array(Int64))",
      "JSON(n Map(String, Int64))",
      "JSON(n Tuple(Int64, String))",
    ].each do |declaration|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentSchema.parse_declaration(declaration)
      end
    end
  end
end
