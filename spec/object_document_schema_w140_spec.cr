require "./spec_helper"

private def w140_limits(
  max_depth : Int = 32,
  max_nodes : Int = 128,
  max_elements : Int = 128,
  max_bytes : Int = 16 * 1024,
) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: max_depth,
    max_nodes: max_nodes,
    max_elements: max_elements,
    max_bytes: max_bytes,
  )
end

describe "W140 recursive Object JSON declared fields" do
  it "parses and directly constructs recursive Array, Map, Tuple, and Nullable declarations" do
    string = CrystalClick::BinaryDataType.primitive("String")
    uint16 = CrystalClick::BinaryDataType.primitive("UInt16")
    nullable_string = CrystalClick::BinaryDataType.nullable(string)
    tuple = CrystalClick::BinaryDataType.tuple([uint16, nullable_string], ["n", "s"] of String)
    array_map_tuple = CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.map(string, tuple))
    expected = "JSON(v Array(Map(String, Tuple(n UInt16, s Nullable(String)))))"

    schema = CrystalClick::ObjectDocumentSchema.new({"v" => array_map_tuple})
    schema.declaration.should eq(expected)
    parsed = CrystalClick::ObjectDocumentSchema.parse_declaration(expected)
    parsed.declaration.should eq(expected)
    parsed.typed_paths.should eq({"v" => array_map_tuple})

    nullable_tuple = CrystalClick::BinaryDataType.nullable(tuple)
    nullable_tuple_schema = CrystalClick::ObjectDocumentSchema.new({"v" => nullable_tuple})
    nullable_tuple_schema.declaration.should eq("JSON(v Nullable(Tuple(n UInt16, s Nullable(String))))")
    CrystalClick::ObjectDocumentSchema.parse_declaration(nullable_tuple_schema.declaration).typed_paths.should eq(
      {"v" => nullable_tuple}
    )
  end

  it "preserves named versus unnamed Tuple identity and admits the empty Tuple" do
    uint16 = CrystalClick::BinaryDataType.primitive("UInt16")
    string = CrystalClick::BinaryDataType.primitive("String")
    named = CrystalClick::BinaryDataType.tuple([uint16, string], ["n", "s"] of String)
    unnamed = CrystalClick::BinaryDataType.tuple([uint16, string])
    empty = CrystalClick::BinaryDataType.tuple([] of CrystalClick::BinaryDataType)

    named.should_not eq(unnamed)
    schema = CrystalClick::ObjectDocumentSchema.new({"named" => named, "unnamed" => unnamed, "empty" => empty})
    schema.declaration.should eq("JSON(empty Tuple(), named Tuple(n UInt16, s String), unnamed Tuple(UInt16, String))")
    parsed = CrystalClick::ObjectDocumentSchema.parse_declaration(schema.declaration)
    parsed.typed_paths.should eq({"named" => named, "unnamed" => unnamed, "empty" => empty})
  end

  it "parses nested Enum and explicit timezone leaf parameters without losing identity" do
    enum_type = CrystalClick::BinaryDataType.enum8([
      {"off", 0_i16},
      {"on", 1_i16},
    ] of CrystalClick::BinaryEnumDefinition::Entry)
    datetime = CrystalClick::BinaryDataType.datetime64(3, "UTC")
    tuple = CrystalClick::BinaryDataType.tuple([enum_type, datetime], ["state", "at"] of String)
    nested = CrystalClick::BinaryDataType.array(tuple)
    expected = "JSON(event Array(Tuple(state Enum8('off' = 0, 'on' = 1), at DateTime64(3, 'UTC'))))"

    schema = CrystalClick::ObjectDocumentSchema.new({"event" => nested})
    schema.declaration.should eq(expected)
    parsed = CrystalClick::ObjectDocumentSchema.parse_declaration(expected)
    parsed.typed_paths.should eq({"event" => nested})
  end

  it "preserves canonical quoted, escaped, and reserved Tuple field names" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    names = ["a b", "back`tick", "back\\slash", "line\nbreak", "select"] of String
    tuple = CrystalClick::BinaryDataType.tuple(Array.new(names.size, uint8), names)
    expected = "JSON(v Tuple(`a b` UInt8, `back\\`tick` UInt8, `back\\\\slash` UInt8, `line\\nbreak` UInt8, `select` UInt8))"

    schema = CrystalClick::ObjectDocumentSchema.new({"v" => tuple})
    schema.declaration.should eq(expected)
    parsed = CrystalClick::ObjectDocumentSchema.parse_declaration(expected)
    parsed.typed_paths.should eq({"v" => tuple})

    # Raw controls and unnecessary quoting are noncanonical, even though the
    # tuple-name decoder could otherwise produce an equivalent String.
    raw_newline = "JSON(v Tuple(`line\nbreak` UInt8))"
    [
      raw_newline,
      "JSON(v Tuple(`field` UInt8))",
    ].each do |declaration|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentSchema.parse_declaration(declaration)
      end
    end
  end

  it "keeps general Map descriptors legal but rejects non-String Object Map keys recursively" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    uint16 = CrystalClick::BinaryDataType.primitive("UInt16")
    string = CrystalClick::BinaryDataType.primitive("String")
    array_key_map = CrystalClick::BinaryDataType.map(CrystalClick::BinaryDataType.array(uint8), string)
    uint16_key_map = CrystalClick::BinaryDataType.map(uint16, string)
    nested_array_map = CrystalClick::BinaryDataType.array(uint16_key_map)
    nested_tuple_map = CrystalClick::BinaryDataType.tuple([array_key_map], ["items"] of String)

    # These descriptors remain legal in the general binary type grammar; the
    # narrower restriction belongs only to Object JSON typed-field policy.
    array_key_map.tag.should eq(CrystalClick::BinaryDataType::TAG_MAP)
    uint16_key_map.tag.should eq(CrystalClick::BinaryDataType::TAG_MAP)

    [array_key_map, uint16_key_map, nested_array_map, nested_tuple_map].each do |type|
      expect_raises(ArgumentError) do
        CrystalClick::ObjectDocumentSchema.new({"v" => type})
      end
    end

    [
      "JSON(v Map(Array(UInt8), String))",
      "JSON(v Map(UInt16, String))",
      "JSON(v Array(Map(UInt16, String)))",
      "JSON(v Tuple(items Map(Array(UInt8), String)))",
    ].each do |declaration|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentSchema.parse_declaration(declaration)
      end
    end
  end

  it "reports the depth-budget failure for parsed and directly constructed recursive schemas" do
    limits = w140_limits(max_depth: 2)

    parsed_error = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(v Array(UInt8))", limits)
    end
    parsed_error.message.should eq("binary codec depth limit exceeded")

    array = CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.primitive("UInt8"))
    constructed_error = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentSchema.new({"v" => array}, limits: limits)
    end
    constructed_error.message.should eq("binary codec depth limit exceeded")
  end

  it "refuses oversized borrowed slices before scanning malformed declarations" do
    malformed = "Array(DefinitelyNotAType)".to_slice
    byte_limited = w140_limits(max_bytes: 4)

    direct_error = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectRecursiveDeclarationText.preflight_slice(malformed, 0, malformed.size, byte_limited)
    end
    direct_error.message.should eq("binary codec byte limit exceeded")
    parent_error = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectRecursiveDeclaration.preflight_slice(malformed, 0, malformed.size, byte_limited)
    end
    parent_error.message.should eq("binary codec byte limit exceeded")

    exact_token = "UInt8".to_slice
    exact_limits = w140_limits(max_bytes: exact_token.size)
    CrystalClick::ObjectRecursiveDeclarationText.preflight_slice(exact_token, 0, exact_token.size, exact_limits).should_not be_nil
    CrystalClick::ObjectRecursiveDeclaration.preflight_slice(exact_token, 0, exact_token.size, exact_limits).should_not be_nil

    CrystalClick::ObjectRecursiveDeclarationText.preflight_slice(exact_token, 1, 0, exact_limits).should be_nil
    CrystalClick::ObjectRecursiveDeclaration.preflight_slice(exact_token, 0, exact_token.size + 1, exact_limits).should be_nil
  end

  it "rejects duplicate Tuple names and noncanonical recursive spelling" do
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(v Tuple(n UInt16, n String))")
    end

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(v Tuple(n UInt16,s String))")
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.tuple(
        [CrystalClick::BinaryDataType.primitive("UInt16"), CrystalClick::BinaryDataType.primitive("String")],
        ["n", "n"] of String,
      )
    end
  end

  it "admits the bounded LowCardinality subset and declared recursive Dynamic" do
    low = CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(v LowCardinality(String))")
    low.declaration.should eq("JSON(v LowCardinality(String))")

    recursive = CrystalClick::ObjectDocumentSchema.parse_declaration(
      "JSON(v Array(Dynamic(max_types=1)))"
    )
    recursive.declaration.should eq("JSON(v Array(Dynamic(max_types=1)))")
    recursive.typed_paths["v"].should eq(
      CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.dynamic(1))
    )
  end
end
