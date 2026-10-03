require "./spec_helper"

private def w133_schema_type(name : String) : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.primitive(name)
end

private def w133_schema_limits(max_bytes : Int) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(max_depth: 32, max_nodes: 1024, max_elements: 1024, max_bytes: max_bytes)
end

private def w133_schema_fields : Hash(String, CrystalClick::BinaryDataType)
  {
    "d"   => w133_schema_type("Date"),
    "d32" => w133_schema_type("Date32"),
  }
end

private def w133_schema_plan(types : Hash(String, CrystalClick::BinaryDataType)) : CrystalClick::ObjectDocumentPlan
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    ),
    types,
  )
end

describe "W133 declared Date and Date32 Object schema" do
  it "constructs and parses only the canonical bare Date and Date32 names" do
    fields = w133_schema_fields
    reversed = Hash(String, CrystalClick::BinaryDataType).new(initial_capacity: fields.size)
    fields.keys.sort.reverse.each { |path| reversed[path] = fields[path] }

    schema = CrystalClick::ObjectDocumentSchema.new(reversed)
    schema.declaration.should eq("JSON(d Date, d32 Date32)")
    schema.typed_paths.should eq(fields)

    parsed = CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(d32 Date32, d Date)")
    parsed.declaration.should eq(schema.declaration)
    parsed.typed_paths.should eq(fields)
  end

  it "admits the exact constructor and parser byte budgets and rejects one byte less" do
    fields = w133_schema_fields
    declaration = "JSON(d Date, d32 Date32)"
    declaration.bytesize.should eq(24)
    path_bytes = "d".bytesize + "d32".bytesize
    type_bytes = "Date".bytesize + "Date32".bytesize

    constructor_bytes = path_bytes + 2 * declaration.bytesize
    constructed = CrystalClick::ObjectDocumentSchema.new(fields, limits: w133_schema_limits(constructor_bytes))
    constructed.declaration.should eq(declaration)
    constructed.declaration_byte_size.should eq(declaration.bytesize)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentSchema.new(fields, limits: w133_schema_limits(constructor_bytes - 1))
    end

    # Parser input, path/type token copies, retained paths, and both canonical
    # declaration buffers are separately charged by the current parser.
    parser_bytes = 3 * declaration.bytesize + 2 * path_bytes + type_bytes + fields.size
    parsed = CrystalClick::ObjectDocumentSchema.parse_declaration(declaration, w133_schema_limits(parser_bytes))
    parsed.declaration.should eq(declaration)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentSchema.parse_declaration(declaration, w133_schema_limits(parser_bytes - 1))
    end
  end

  it "keeps Date distinct from UInt16 and Date32 distinct from Int32 in plans and values" do
    date = w133_schema_type("Date")
    date32 = w133_schema_type("Date32")
    uint16 = w133_schema_type("UInt16")
    int32 = w133_schema_type("Int32")
    schema = CrystalClick::ObjectDocumentSchema.new({"d" => date, "d32" => date32})

    schema.validate_plan(w133_schema_plan({"d" => date, "d32" => date32})).should be_nil
    expect_raises(ArgumentError) do
      schema.validate_plan(w133_schema_plan({"d" => uint16, "d32" => date32}))
    end
    expect_raises(ArgumentError) do
      schema.validate_plan(w133_schema_plan({"d" => date, "d32" => int32}))
    end

    same_date_bits = Bytes[0x01_u8, 0x02_u8]
    same_date32_bits = Bytes[0xff_u8, 0xfd_u8, 0xff_u8, 0xff_u8]
    date_value = CrystalClick::BinaryValue.fixed(date, same_date_bits)
    uint16_value = CrystalClick::BinaryValue.fixed(uint16, same_date_bits)
    date32_value = CrystalClick::BinaryValue.fixed(date32, same_date32_bits)
    int32_value = CrystalClick::BinaryValue.fixed(int32, same_date32_bits)
    date_value.type.should_not eq(uint16_value.type)
    date32_value.type.should_not eq(int32_value.type)
    date_value.bytes.should eq(uint16_value.bytes)
    date32_value.bytes.should eq(int32_value.bytes)
  end

  it "retains refusals for malformed Date spellings, wrappers, containers, and BFloat16" do
    unsupported_types = [
      w133_schema_type("BFloat16"),
      CrystalClick::BinaryDataType.nullable(w133_schema_type("Int64")),
      CrystalClick::BinaryDataType.array(w133_schema_type("Int64")),
      CrystalClick::BinaryDataType.map(w133_schema_type("String"), w133_schema_type("Int64")),
      CrystalClick::BinaryDataType.tuple([w133_schema_type("Int64"), w133_schema_type("String")]),
    ]
    unsupported_types.each do |type|
      expect_raises(ArgumentError) do
        CrystalClick::ObjectDocumentSchema.new({"n" => type})
      end
    end

    [
      "JSON(n Date(1))",
      "JSON(n Date32(1))",
      "JSON(n date)",
      "JSON(n Date32junk)",
      "JSON(n Date Int32)",
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
