require "./spec_helper"

private def w252_object_control_path : String
  String.new(Bytes[0x61_u8, 0x08, 0x0c, 0x0a, 0x0d, 0x09, 0x00, 0x62])
end

private def w252_object_path_cases : Array(Tuple(String, String))
  cases = [
    {"id", "id"},
    {"a.b", "`a.b`"},
    {".a", "`.a`"},
    {"a.", "`a.`"},
    {"a..b", "`a..b`"},
    {"a%2Eb", "`a%2Eb`"},
    {"a b", "`a b`"},
    {"x=y", "`x=y`"},
    {"a,b(c)", "`a,b(c)`"},
    {"SKIP", "`SKIP`"},
    {"a`b", "`a\\`b`"},
    {"a\\b", "`a\\\\b`"},
    {"ключ", "`ключ`"},
    {"select", "`select`"},
    {"inf", "`inf`"},
  ] of Tuple(String, String)
  cases << {w252_object_control_path, "`a\\b\\f\\n\\r\\t\\0b`"}
  cases
end

private def w252_object_limits(max_bytes : Int = 64 * 1024 * 1024) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: 64,
    max_nodes: 4_096,
    max_elements: 1_000_000,
    max_bytes: max_bytes,
  )
end

describe "W252 root Object path identity and physical names" do
  it "roundtrips canonical declarations without changing raw typed-path bytes" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")

    w252_object_path_cases.each do |path, token|
      declaration = "JSON(#{token} UInt8)"
      schema = CrystalClick::ObjectDocumentSchema.new({path => uint8})
      schema.declaration.should eq(declaration)
      schema.typed_paths.should eq({path => uint8})

      parsed = CrystalClick::ObjectDocumentSchema.parse_declaration(declaration)
      parsed.declaration.should eq(declaration)
      parsed.typed_paths.should eq({path => uint8})
    end

    dotted_and_percent = CrystalClick::ObjectDocumentSchema.new({
      "a.b"   => uint8,
      "a%2Eb" => uint8,
    })
    dotted_and_percent.declaration.should eq("JSON(`a%2Eb` UInt8, `a.b` UInt8)")
    parsed_pair = CrystalClick::ObjectDocumentSchema.parse_declaration(dotted_and_percent.declaration)
    parsed_pair.typed_paths.should eq({"a.b" => uint8, "a%2Eb" => uint8})

    # The embedded descriptor path cap is not a root Object schema limit.
    long_path = "x" * 300
    long_schema = CrystalClick::ObjectDocumentSchema.new({long_path => uint8})
    long_schema.declaration.should eq("JSON(#{long_path} UInt8)")
    CrystalClick::ObjectDocumentSchema.parse_declaration(long_schema.declaration)
      .typed_paths.should eq({long_path => uint8})
  end

  it "keeps path spelling and escaped physical components in separate domains" do
    CrystalClick::PhysicalStreamName.append_escaped_component("json", "a.b").should eq("json.a%2Eb")
    CrystalClick::PhysicalStreamName.append_escaped_component("json", "a%2Eb").should eq("json.a%252Eb")
    CrystalClick::PhysicalStreamName.append_escaped_component("json", "a b").should eq("json.a%20b")
    CrystalClick::PhysicalStreamName.append_escaped_component("json", "SKIP").should eq("json.SKIP")
    CrystalClick::PhysicalStreamName.append_escaped_component("json", "a`b").should eq("json.a%60b")
    CrystalClick::PhysicalStreamName.append_escaped_component("json", "a\\b").should eq("json.a%5Cb")
    CrystalClick::PhysicalStreamName.append_escaped_component("json", "ключ")
      .should eq("json.%D0%BA%D0%BB%D1%8E%D1%87")
    CrystalClick::PhysicalStreamName.append_escaped_component("json", w252_object_control_path)
      .should eq("json.a%08%0C%0A%0D%09%00b")
  end

  it "retains empty, malformed, duplicate, and operation-budget rejection" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentSchema.new({"" => uint8})
    end

    [
      "JSON()",
      "JSON(a.b UInt8)",
      "JSON(`` UInt8)",
      "JSON(`a\\q` UInt8)",
      "JSON(`a.b` UInt8, `a.b` String)",
    ].each do |declaration|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentSchema.parse_declaration(declaration)
      end
    end

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentSchema.new(
        {"a.b" => uint8},
        limits: w252_object_limits(max_bytes: 1),
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentSchema.parse_declaration(
        "JSON(`a.b` UInt8)",
        w252_object_limits(max_bytes: 1),
      )
    end
  end
end
