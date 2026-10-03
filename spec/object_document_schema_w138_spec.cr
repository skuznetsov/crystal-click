require "./spec_helper"

private def w138_schema_limits(
  max_bytes : Int,
  max_nodes : Int = 128,
  max_elements : Int = 128,
) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: 32,
    max_nodes: max_nodes,
    max_elements: max_elements,
    max_bytes: max_bytes,
  )
end

private def w138_enum8_type : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.enum8([
    {"opaque, equals= parens() backtick` apostrophe' slash\\ tab\t line\n", 127_i16},
    {"zero", 0_i16},
    {"negative", -1_i16},
    {"lowest", -128_i16},
  ] of CrystalClick::BinaryEnumDefinition::Entry)
end

private def w138_enum16_type : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.enum16([
    {"maximum", 32_767_i16},
    {"zero", 0_i16},
    {"minimum", -32_768_i16},
    {"negative", -1_i16},
  ] of CrystalClick::BinaryEnumDefinition::Entry)
end

private def w138_full_enum_type(width_bits : Int32) : CrystalClick::BinaryDataType
  first_code = width_bits == 8 ? -128 : -32_768
  last_code = width_bits == 8 ? 127 : 32_767
  entries = Array(CrystalClick::BinaryEnumDefinition::Entry).new(last_code - first_code + 1)
  (first_code..last_code).each do |code|
    entries << {"v#{code}", code.to_i16}
  end
  width_bits == 8 ? CrystalClick::BinaryDataType.enum8(entries) : CrystalClick::BinaryDataType.enum16(entries)
end

private def w138_schema_plan(types : Hash(String, CrystalClick::BinaryDataType)) : CrystalClick::ObjectDocumentPlan
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    ),
    types,
  )
end

describe "W138 canonical Enum Object schema" do
  it "constructs canonical signed-code ordered names and preserves full map identity" do
    enum8 = w138_enum8_type
    enum16 = w138_enum16_type
    enum8.name.should eq(
      "Enum8('lowest' = -128, 'negative' = -1, 'zero' = 0, 'opaque, equals= parens() backtick` apostrophe\\' slash\\\\ tab\\t line\\n' = 127)"
    )
    enum16.name.should eq("Enum16('minimum' = -32768, 'negative' = -1, 'zero' = 0, 'maximum' = 32767)")

    schema = CrystalClick::ObjectDocumentSchema.new({"e8" => enum8, "e16" => enum16})
    schema.declaration.should eq("JSON(e16 #{enum16.name}, e8 #{enum8.name})")
    parsed = CrystalClick::ObjectDocumentSchema.parse_declaration(schema.declaration)
    parsed.declaration.should eq(schema.declaration)
    parsed.typed_paths.should eq({"e8" => enum8, "e16" => enum16})
    parsed.validate_plan(w138_schema_plan({"e8" => enum8, "e16" => enum16})).should be_nil

    changed_label = CrystalClick::BinaryDataType.enum8([
      {"lowest", -128_i16},
      {"negative", -1_i16},
      {"zero", 0_i16},
      {"renamed", 127_i16},
    ] of CrystalClick::BinaryEnumDefinition::Entry)
    changed_code = CrystalClick::BinaryDataType.enum8([
      {"lowest", -128_i16},
      {"negative", -1_i16},
      {"zero", 0_i16},
      {"opaque, equals= parens() backtick` apostrophe' slash\\ tab\t line\n", 126_i16},
    ] of CrystalClick::BinaryEnumDefinition::Entry)
    same_width_integer = CrystalClick::BinaryDataType.primitive("Int8")
    [changed_label, changed_code, same_width_integer].each do |other_type|
      expect_raises(ArgumentError) do
        schema.validate_plan(w138_schema_plan({"e8" => other_type, "e16" => enum16}))
      end
    end

    raw = Bytes[0xff_u8]
    original_value = CrystalClick::BinaryValue.fixed(enum8, raw)
    same_map_value = CrystalClick::BinaryValue.fixed(w138_enum8_type, raw)
    different_map_value = CrystalClick::BinaryValue.fixed(changed_label, raw)
    integer_value = CrystalClick::BinaryValue.fixed(same_width_integer, raw)
    original_value.bytes.should eq(raw)
    original_value.type.should eq(same_map_value.type)
    original_value.type.should_not eq(different_map_value.type)
    original_value.bytes.should eq(integer_value.bytes)
    original_value.type.should_not eq(integer_value.type)
  end

  it "parses opaque quoted labels without confusing map punctuation or top-level options" do
    declaration =
      "JSON(max_dynamic_types=7, `root.state` Enum8('lowest' = -128, 'comma, equals= parens() backtick` apostrophe\\' slash\\\\ tab\\t line\\n' = -1, 'zero' = 0, 'maximum' = 127))"
    parsed = CrystalClick::ObjectDocumentSchema.parse_declaration(declaration)
    expected_type = CrystalClick::BinaryDataType.enum8([
      {"maximum", 127_i16},
      {"zero", 0_i16},
      {"comma, equals= parens() backtick` apostrophe' slash\\ tab\t line\n", -1_i16},
      {"lowest", -128_i16},
    ] of CrystalClick::BinaryEnumDefinition::Entry)
    expected = CrystalClick::ObjectDocumentSchema.new(
      {"root.state" => expected_type},
      max_dynamic_types: 7,
    )
    parsed.declaration.should eq(expected.declaration)
    parsed.typed_paths.should eq({"root.state" => expected_type})
    parsed.max_dynamic_types.should eq(7)
  end

  it "round-trips every canonical byte escape plus UTF-8 and opaque invalid UTF-8 labels" do
    utf8 = "caf\u00e9"
    opaque = String.new(Bytes[0xff_u8, 0x00_u8, 0x27_u8, 0x5c_u8, 0x01_u8])
    type = CrystalClick::BinaryDataType.enum8([
      {"empty", -128_i16},
      {utf8, -2_i16},
      {opaque, -1_i16},
      {String.new(Bytes[0x00_u8, 0x08_u8, 0x09_u8, 0x0a_u8, 0x0c_u8, 0x0d_u8]), 0_i16},
      {"quote' slash\\", 1_i16},
      {"", 127_i16},
    ] of CrystalClick::BinaryEnumDefinition::Entry)
    schema = CrystalClick::ObjectDocumentSchema.new({"state" => type})
    parsed = CrystalClick::ObjectDocumentSchema.parse_declaration(schema.declaration)
    parsed.declaration.should eq(schema.declaration)
    parsed.typed_paths.should eq({"state" => type})
  end

  it "admits the full Enum8 and Enum16 code domains with explicit matching limits" do
    enum8 = w138_full_enum_type(8)
    enum16 = w138_full_enum_type(16)
    enum8.enum_definition.not_nil!.size.should eq(256)
    enum16.enum_definition.not_nil!.size.should eq(65_536)
    enum8.enum_definition.not_nil!.code_at(0).should eq(-128_i16)
    enum8.enum_definition.not_nil!.code_at(255).should eq(127_i16)
    enum16.enum_definition.not_nil!.code_at(0).should eq(-32_768_i16)
    enum16.enum_definition.not_nil!.code_at(65_535).should eq(32_767_i16)

    limits = w138_schema_limits(16 * 1024 * 1024, max_nodes: 70_000, max_elements: 70_000)
    schema = CrystalClick::ObjectDocumentSchema.new(
      {"small" => enum8, "wide" => enum16},
      limits: limits,
    )
    parsed = CrystalClick::ObjectDocumentSchema.parse_declaration(schema.declaration, limits)
    parsed.typed_paths.should eq({"small" => enum8, "wide" => enum16})
    parsed.typed_paths["wide"].enum_definition.not_nil!.size.should eq(65_536)
  end

  it "preflights enum map budgets and charges exact constructor and parser byte cutoffs" do
    enum8 = CrystalClick::BinaryDataType.enum8([
      {"positive", 1_i16},
      {"negative", -1_i16},
    ] of CrystalClick::BinaryEnumDefinition::Entry)
    type_name = enum8.name
    declaration = "JSON(v #{type_name})"
    constructor_bytes = "v".bytesize + 2 * declaration.bytesize
    constructed = CrystalClick::ObjectDocumentSchema.new(
      {"v" => enum8},
      limits: w138_schema_limits(constructor_bytes, max_nodes: 8, max_elements: 8),
    )
    constructed.declaration.should eq(declaration)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentSchema.new(
        {"v" => enum8},
        limits: w138_schema_limits(constructor_bytes - 1, max_nodes: 8, max_elements: 8),
      )
    end

    decoded_label_bytes = "positive".bytesize + "negative".bytesize
    parser_bytes = declaration.bytesize * 3 + 2 + type_name.bytesize + 2 * decoded_label_bytes + 1
    parsed = CrystalClick::ObjectDocumentSchema.parse_declaration(
      declaration,
      w138_schema_limits(parser_bytes, max_nodes: 8, max_elements: 8),
    )
    parsed.declaration.should eq(declaration)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentSchema.parse_declaration(
        declaration,
        w138_schema_limits(parser_bytes - 1, max_nodes: 8, max_elements: 8),
      )
    end

    constructor_map_limits = w138_schema_limits(64 * 1024, max_nodes: 4, max_elements: 3)
    CrystalClick::ObjectDocumentSchema.new({"v" => enum8}, limits: constructor_map_limits).declaration.should eq(declaration)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentSchema.new(
        {"v" => enum8},
        limits: w138_schema_limits(64 * 1024, max_nodes: 3, max_elements: 3),
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentSchema.new(
        {"v" => enum8},
        limits: w138_schema_limits(64 * 1024, max_nodes: 4, max_elements: 2),
      )
    end
    parser_map_limits = w138_schema_limits(64 * 1024, max_nodes: 4, max_elements: 3)
    CrystalClick::ObjectDocumentSchema.parse_declaration(declaration, parser_map_limits).declaration.should eq(declaration)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentSchema.parse_declaration(
        declaration,
        w138_schema_limits(64 * 1024, max_nodes: 3, max_elements: 3),
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentSchema.parse_declaration(
        declaration,
        w138_schema_limits(64 * 1024, max_nodes: 4, max_elements: 2),
      )
    end
  end

  it "revalidates borrowed enum preflight metadata before materializing entries" do
    bytes = "Enum8('line\\n' = 1)".to_slice.dup
    preflight = CrystalClick::ObjectEnumDeclaration.preflight_slice(bytes, 0, bytes.size).not_nil!
    escape_first = "Enum8('line".bytesize
    bytes[escape_first] = 'a'.ord.to_u8
    bytes[escape_first + 1] = 'b'.ord.to_u8

    # The replacement is still a valid canonical declaration with the same
    # tag, code count, and byte span, but it decodes to one additional byte.
    expect_raises(ArgumentError) do
      preflight.materialize_entries
    end

    stable_bytes = "Enum8('x' = 1)".to_slice
    stable = CrystalClick::ObjectEnumDeclaration.preflight_slice(stable_bytes, 0, stable_bytes.size).not_nil!
    forged = CrystalClick::ObjectEnumDeclaration::Preflight.new(
      stable.tag,
      stable.byte_size + 1,
      stable.entry_count,
      stable.decoded_label_bytes,
      stable_bytes,
      0,
      stable_bytes.size,
    )
    expect_raises(ArgumentError) do
      forged.materialize_entries
    end
  end

  it "aggregates budgets across two small Enum maps in constructors and parsers" do
    enum_a = CrystalClick::BinaryDataType.enum8([
      {"a-low", -1_i16},
      {"a-high", 1_i16},
    ] of CrystalClick::BinaryEnumDefinition::Entry)
    enum_b = CrystalClick::BinaryDataType.enum8([
      {"b-low", -1_i16},
      {"b-high", 1_i16},
    ] of CrystalClick::BinaryEnumDefinition::Entry)
    types = {"a" => enum_a, "b" => enum_b}
    declaration = "JSON(a #{enum_a.name}, b #{enum_b.name})"
    paths_bytes = "a".bytesize + "b".bytesize
    type_bytes = enum_a.name.bytesize + enum_b.name.bytesize
    decoded_label_bytes = "a-low".bytesize + "a-high".bytesize + "b-low".bytesize + "b-high".bytesize
    constructor_bytes = paths_bytes + 2 * declaration.bytesize
    parser_bytes = 3 * declaration.bytesize + 2 * paths_bytes + type_bytes + 2 * decoded_label_bytes + 2

    constructor_exact = w138_schema_limits(constructor_bytes, max_nodes: 7, max_elements: 6)
    CrystalClick::ObjectDocumentSchema.new(types, limits: constructor_exact).declaration.should eq(declaration)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentSchema.new(
        types,
        limits: w138_schema_limits(constructor_bytes - 1, max_nodes: 7, max_elements: 6),
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentSchema.new(
        types,
        limits: w138_schema_limits(constructor_bytes, max_nodes: 6, max_elements: 6),
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentSchema.new(
        types,
        limits: w138_schema_limits(constructor_bytes, max_nodes: 7, max_elements: 5),
      )
    end

    parser_exact = w138_schema_limits(parser_bytes, max_nodes: 7, max_elements: 6)
    CrystalClick::ObjectDocumentSchema.parse_declaration(declaration, parser_exact).declaration.should eq(declaration)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentSchema.parse_declaration(
        declaration,
        w138_schema_limits(parser_bytes - 1, max_nodes: 7, max_elements: 6),
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentSchema.parse_declaration(
        declaration,
        w138_schema_limits(parser_bytes, max_nodes: 6, max_elements: 6),
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentSchema.parse_declaration(
        declaration,
        w138_schema_limits(parser_bytes, max_nodes: 7, max_elements: 5),
      )
    end
  end

  it "rejects noncanonical, out-of-range, duplicate, and aliased enum declarations" do
    [
      "JSON(v Enum8)",
      "JSON(v Enum8())",
      "JSON(v Enum8('a'=1))",
      "JSON(v Enum8('a' = 01))",
      "JSON(v Enum8('a' = +1))",
      "JSON(v Enum8('a' = -0))",
      "JSON(v Enum8('a' = 128))",
      "JSON(v Enum8('a' = -129))",
      "JSON(v Enum8('a' = 1, 'b' = 1))",
      "JSON(v Enum8('a' = 1, 'a' = 2))",
      "JSON(v Enum8('b' = 2, 'a' = 1))",
      "JSON(v Enum8('a' = 1,'b' = 2))",
      "JSON(v Enum8('a' = 1,  'b' = 2))",
      "JSON(v Enum8('a' = 1,))",
      "JSON(v Enum8('bad\\q' = 1))",
      "JSON(v Enum8('unterminated = 1))",
      "JSON(v Enum8('a' = 1) UInt8)",
      "JSON(v Enum('a' = 1))",
      "JSON(v Enum16('a' = 32768))",
      "JSON(v Enum16('a' = -32769))",
    ].each do |malformed|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentSchema.parse_declaration(malformed)
      end
    end
  end

  it "admits canonical recursive wrappers around Enum leaves" do
    enum_type = w138_enum8_type
    string_type = CrystalClick::BinaryDataType.primitive("String")
    types = {
      "array"    => CrystalClick::BinaryDataType.array(enum_type),
      "map"      => CrystalClick::BinaryDataType.map(string_type, enum_type),
      "nullable" => CrystalClick::BinaryDataType.nullable(enum_type),
      "tuple"    => CrystalClick::BinaryDataType.tuple([enum_type]),
    } of String => CrystalClick::BinaryDataType
    declaration = "JSON(array Array(#{enum_type.name}), map Map(String, #{enum_type.name}), nullable Nullable(#{enum_type.name}), tuple Tuple(#{enum_type.name}))"

    constructed = CrystalClick::ObjectDocumentSchema.new(types)
    constructed.declaration.should eq(declaration)
    constructed.typed_paths.should eq(types)

    parsed = CrystalClick::ObjectDocumentSchema.parse_declaration(declaration)
    parsed.declaration.should eq(declaration)
    parsed.typed_paths.should eq(types)
  end
end
