require "./spec_helper"

private def w135_schema_type(name : String) : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.primitive(name)
end

private def w135_schema_limits(max_bytes : Int) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(max_depth: 32, max_nodes: 1024, max_elements: 1024, max_bytes: max_bytes)
end

private def w135_schema_fields : Hash(String, CrystalClick::BinaryDataType)
  {
    "ip4"  => w135_schema_type("IPv4"),
    "ip6"  => w135_schema_type("IPv6"),
    "uuid" => w135_schema_type("UUID"),
  }
end

private def w135_schema_plan(types : Hash(String, CrystalClick::BinaryDataType)) : CrystalClick::ObjectDocumentPlan
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    ),
    types,
  )
end

describe "W135 declared UUID and IP Object schema" do
  it "constructs and parses only the canonical bare UUID, IPv4, and IPv6 names" do
    fields = w135_schema_fields
    reversed = Hash(String, CrystalClick::BinaryDataType).new(initial_capacity: fields.size)
    fields.keys.sort.reverse.each { |path| reversed[path] = fields[path] }

    schema = CrystalClick::ObjectDocumentSchema.new(reversed)
    declaration = "JSON(ip4 IPv4, ip6 IPv6, uuid UUID)"
    declaration.bytesize.should eq(35)
    schema.declaration.should eq(declaration)
    schema.typed_paths.should eq(fields)

    parsed = CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(uuid UUID, ip6 IPv6, ip4 IPv4)")
    parsed.declaration.should eq(declaration)
    parsed.typed_paths.should eq(fields)
  end

  it "admits exact constructor and parser byte budgets and rejects one byte less" do
    fields = w135_schema_fields
    declaration = "JSON(ip4 IPv4, ip6 IPv6, uuid UUID)"
    path_bytes = "ip4".bytesize + "ip6".bytesize + "uuid".bytesize
    type_bytes = "IPv4".bytesize + "IPv6".bytesize + "UUID".bytesize
    fields.size.should eq(3)

    constructor_bytes = path_bytes + 2 * declaration.bytesize
    constructed = CrystalClick::ObjectDocumentSchema.new(fields, limits: w135_schema_limits(constructor_bytes))
    constructed.declaration.should eq(declaration)
    constructed.declaration_byte_size.should eq(declaration.bytesize)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentSchema.new(fields, limits: w135_schema_limits(constructor_bytes - 1))
    end

    # Parser input, path/type token copies, retained paths, and both canonical
    # declaration buffers are separately charged from these exact byte counts.
    parser_bytes = 3 * declaration.bytesize + 2 * path_bytes + type_bytes + fields.size
    parsed = CrystalClick::ObjectDocumentSchema.parse_declaration(declaration, w135_schema_limits(parser_bytes))
    parsed.declaration.should eq(declaration)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentSchema.parse_declaration(declaration, w135_schema_limits(parser_bytes - 1))
    end
  end

  it "preserves nominal plan and value identity against same-width numeric aliases" do
    ipv4 = w135_schema_type("IPv4")
    ipv6 = w135_schema_type("IPv6")
    uuid = w135_schema_type("UUID")
    uint32 = w135_schema_type("UInt32")
    uint128 = w135_schema_type("UInt128")
    schema = CrystalClick::ObjectDocumentSchema.new({"ip4" => ipv4, "ip6" => ipv6, "uuid" => uuid})

    schema.validate_plan(w135_schema_plan({"ip4" => ipv4, "ip6" => ipv6, "uuid" => uuid})).should be_nil
    expect_raises(ArgumentError) do
      schema.validate_plan(w135_schema_plan({"ip4" => uint32, "ip6" => ipv6, "uuid" => uuid}))
    end
    expect_raises(ArgumentError) do
      schema.validate_plan(w135_schema_plan({"ip4" => ipv4, "ip6" => uuid, "uuid" => uuid}))
    end
    expect_raises(ArgumentError) do
      schema.validate_plan(w135_schema_plan({"ip4" => ipv4, "ip6" => ipv6, "uuid" => uint128}))
    end

    ipv4_bits = Bytes[1_u8, 2_u8, 3_u8, 4_u8]
    uuid_bits = Bytes[0x77_u8, 0x66_u8, 0x55_u8, 0x44_u8, 0x33_u8, 0x22_u8, 0x11_u8, 0x00_u8,
      0xff_u8, 0xee_u8, 0xdd_u8, 0xcc_u8, 0xbb_u8, 0xaa_u8, 0x99_u8, 0x88_u8]

    ipv4_value = CrystalClick::BinaryValue.fixed(ipv4, ipv4_bits)
    uint32_value = CrystalClick::BinaryValue.fixed(uint32, ipv4_bits)
    ipv6_value = CrystalClick::BinaryValue.fixed(ipv6, uuid_bits)
    uuid_value = CrystalClick::BinaryValue.fixed(uuid, uuid_bits)
    uint128_value = CrystalClick::BinaryValue.fixed(uint128, uuid_bits)
    ipv4_value.bytes.should eq(uint32_value.bytes)
    ipv6_value.bytes.should eq(uuid_value.bytes)
    uuid_value.bytes.should eq(uint128_value.bytes)
    ipv4_value.type.should_not eq(uint32_value.type)
    ipv6_value.type.should_not eq(uuid_value.type)
    uuid_value.type.should_not eq(uint128_value.type)
  end

  it "keeps BFloat16 and malformed identifier tokens refused" do
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentSchema.new({"n" => w135_schema_type("BFloat16")})
    end
    [
      "JSON(n BFloat16)",
      "JSON(n uuid)",
      "JSON(n IPv4junk)",
      "JSON(n IPv6 UUID)",
      "JSON(n UUID IPv4)",
    ].each do |declaration|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentSchema.parse_declaration(declaration)
      end
    end

    ipv4 = w135_schema_type("IPv4")
    ipv6 = w135_schema_type("IPv6")
    uuid = w135_schema_type("UUID")
    string = w135_schema_type("String")
    types = {
      "array"    => CrystalClick::BinaryDataType.array(ipv4),
      "map"      => CrystalClick::BinaryDataType.map(string, ipv6),
      "nullable" => CrystalClick::BinaryDataType.nullable(uuid),
      "tuple"    => CrystalClick::BinaryDataType.tuple([uuid, ipv4]),
    } of String => CrystalClick::BinaryDataType
    schema = CrystalClick::ObjectDocumentSchema.new(types)
    schema.declaration.should eq("JSON(array Array(IPv4), map Map(String, IPv6), nullable Nullable(UUID), tuple Tuple(UUID, IPv4))")
    CrystalClick::ObjectDocumentSchema.parse_declaration(schema.declaration).typed_paths.should eq(types)
  end
end
