require "./spec_helper"

private def w252_embedded_control_path : String
  String.new(Bytes[0x61_u8, 0x08, 0x0c, 0x0a, 0x0d, 0x09, 0x00, 0x62])
end

private def w252_embedded_path_cases : Array(Tuple(String, String))
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
  cases << {w252_embedded_control_path, "`a\\b\\f\\n\\r\\t\\0b`"}
  cases
end

private def w252_name_limits(
  max_nodes : Int = 4_096,
  max_elements : Int = 1_000_000,
  max_bytes : Int = 64 * 1024 * 1024,
) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: 64,
    max_nodes: max_nodes,
    max_elements: max_elements,
    max_bytes: max_bytes,
  )
end

describe "W252 embedded JSON raw path identity" do
  it "keeps canonical SQL quoting separate from raw descriptor and typed-row bytes" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")

    w252_embedded_path_cases.each do |path, token|
      type = CrystalClick::BinaryDataType.json(
        max_dynamic_paths: 1,
        max_dynamic_types: 1,
        typed_paths: {path => uint8},
      )
      expected_name = "JSON(max_dynamic_types=1, max_dynamic_paths=1, #{token} UInt8)"

      type.name.should eq(expected_name)
      CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(expected_name)
        .should eq(type)
      decoded = CrystalClick::BinaryDataTypeCodec.decode(CrystalClick::BinaryDataTypeCodec.encode(type))
      decoded.json_type.not_nil!.typed_path_at(0).should eq(path)
    end

    dotted = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 1,
      max_dynamic_types: 1,
      typed_paths: {"a.b" => uint8},
    )
    dotted_wire = Bytes[
      0x30_u8, 0x00, 0x01, 0x01, 0x01, 0x03,
      0x61, 0x2e, 0x62, 0x01, 0x00, 0x00,
    ]
    CrystalClick::BinaryDataTypeCodec.encode(dotted).should eq(dotted_wire)
    CrystalClick::BinaryDataTypeCodec.decode(dotted_wire).json_type.not_nil!.typed_path_at(0)
      .should eq("a.b")

    percent = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 1,
      max_dynamic_types: 1,
      typed_paths: {"a%2Eb" => uint8},
    )
    percent_wire = Bytes[
      0x30_u8, 0x00, 0x01, 0x01, 0x01, 0x05,
      0x61, 0x25, 0x32, 0x45, 0x62, 0x01, 0x00, 0x00,
    ]
    CrystalClick::BinaryDataTypeCodec.encode(percent).should eq(percent_wire)
    CrystalClick::BinaryDataTypeCodec.decode(percent_wire).json_type.not_nil!.typed_path_at(0)
      .should eq("a%2Eb")

    json = CrystalClick::BinaryDataType.json(max_dynamic_paths: 2, max_dynamic_types: 2)
    values = [
      {"a.b", CrystalClick::BinaryValue.fixed(uint8, Bytes[0x11_u8])},
      {"a%2Eb", CrystalClick::BinaryValue.fixed(uint8, Bytes[0x17_u8])},
    ] of Tuple(String, CrystalClick::BinaryValue)
    row = CrystalClick::BinaryJsonRow.new(json, values)
    value = CrystalClick::BinaryValue.json(json, row)
    row_wire = Bytes[
      0x02_u8,
      0x05, 0x61, 0x25, 0x32, 0x45, 0x62, 0x01, 0x17,
      0x03, 0x61, 0x2e, 0x62, 0x01, 0x11,
    ]
    CrystalClick::BinaryValueCodec.encode_value(value).should eq(row_wire)

    decoded_row = CrystalClick::BinaryValueCodec.decode_value(json, row_wire).json_row
    decoded_row.path_count.should eq(2)
    decoded_row.path_at(0).should eq("a%2Eb")
    decoded_row.path_at(1).should eq("a.b")
    decoded_row.value_for("a%2Eb").not_nil!.byte_at(0).should eq(0x17_u8)
    decoded_row.value_for("a.b").not_nil!.byte_at(0).should eq(0x11_u8)
    CrystalClick::BinaryValueCodec.encode_value(CrystalClick::BinaryValue.json(json, decoded_row))
      .should eq(row_wire)

    control_path = w252_embedded_control_path
    control_json = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 1,
      max_dynamic_types: 1,
      typed_paths: {control_path => uint8},
    )
    control_values = [
      {control_path, CrystalClick::BinaryValue.fixed(uint8, Bytes[0x42_u8])},
    ] of Tuple(String, CrystalClick::BinaryValue)
    control_value = CrystalClick::BinaryValue.json(
      control_json,
      CrystalClick::BinaryJsonRow.new(control_json, control_values),
    )
    control_row_wire = Bytes[
      0x01_u8, 0x08, 0x61, 0x08, 0x0c, 0x0a, 0x0d, 0x09, 0x00, 0x62, 0x42,
    ]
    CrystalClick::BinaryValueCodec.encode_value(control_value).should eq(control_row_wire)
    decoded_control = CrystalClick::BinaryValueCodec.decode_value(control_json, control_row_wire)
    decoded_control.json_row.path_at(0).should eq(control_path)
    decoded_control.json_row.value_at(0).byte_at(0).should eq(0x42_u8)
    CrystalClick::BinaryValueCodec.encode_value(decoded_control).should eq(control_row_wire)
  end

  it "keeps JSON descriptor bytes opaque without weakening Dynamic SQL-name UTF-8" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    invalid_utf8_path = String.new(Bytes[0xff_u8])
    json_type = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 1,
      max_dynamic_types: 1,
      typed_paths: {invalid_utf8_path => uint8},
    )

    descriptor = CrystalClick::BinaryDataTypeCodec.encode(json_type)
    descriptor.should eq(Bytes[
      0x30_u8, 0x00, 0x01, 0x01, 0x01, 0x01, 0xff, 0x01, 0x00, 0x00,
    ])
    decoded_json = CrystalClick::BinaryDataTypeCodec.decode(descriptor).json_type.not_nil!
    decoded_json.typed_path_at(0).to_slice.should eq(Bytes[0xff_u8])
    CrystalClick::BinaryDataTypeCodec.encode(CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 1,
      max_dynamic_types: 1,
      typed_paths: {decoded_json.typed_path_at(0) => uint8},
    )).should eq(descriptor)

    {1_u64, 2_u64}.each do |version|
      structure = CrystalClick::DynamicStructure.new(
        [json_type] of CrystalClick::BinaryDataType,
        version: version,
      )
      error = expect_raises(CrystalClick::UnsupportedFormatError, /not valid UTF-8/) do
        CrystalClick::DynamicStructureCodec.encode_prefix_without_statistics(structure)
      end
      error.message.not_nil!.should contain("not valid UTF-8")
    end
  end

  it "charges escaped canonical-name output and keeps raw length and malformed-name fences" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    plain = "JSON(max_dynamic_types=1, max_dynamic_paths=1, abc UInt8)"
    escaped = "JSON(max_dynamic_types=1, max_dynamic_paths=1, `a.b` UInt8)"

    plain_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
    plain_type = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical_with_budget(plain, plain_budget)
    plain_type.should eq(CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 1,
      max_dynamic_types: 1,
      typed_paths: {"abc" => uint8},
    ))

    escaped_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
    escaped_type = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical_with_budget(escaped, escaped_budget)
    escaped_type.should eq(CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 1,
      max_dynamic_types: 1,
      typed_paths: {"a.b" => uint8},
    ))
    escaped_budget.wire_byte_count.should be > plain_budget.wire_byte_count

    exact_budget = CrystalClick::BinaryCodecBudget.new(w252_name_limits(max_bytes: escaped_budget.wire_byte_count.to_i))
    CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical_with_budget(escaped, exact_budget)
      .should eq(escaped_type)
    short_budget = CrystalClick::BinaryCodecBudget.new(w252_name_limits(max_bytes: escaped_budget.wire_byte_count.to_i - 1))
    CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical_with_budget(escaped, short_budget)
      .should be_nil

    [
      "JSON(max_dynamic_types=1, max_dynamic_paths=1, a.b UInt8)",
      "JSON(max_dynamic_types=1, max_dynamic_paths=1, `abc` UInt8)",
      "JSON(max_dynamic_types=1, max_dynamic_paths=1, `` UInt8)",
      "JSON(max_dynamic_types=1, max_dynamic_paths=1, `a\\q` UInt8)",
      "JSON(max_dynamic_types=1, max_dynamic_paths=1, `a.b` UInt8, `a.b` UInt8)",
    ].each do |name|
      CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(name).should be_nil
    end

    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.json(typed_paths: {"" => uint8})
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.json(typed_paths: {"x" * 257 => uint8})
    end
    CrystalClick::BinaryDataType.json(typed_paths: {"x" * 256 => uint8})
      .json_type.not_nil!.typed_path_count.should eq(1)
  end

  it "bounds decoded token bytes independently of escaped SQL and rejects forged measures before copying" do
    path = "`" * CrystalClick::BinaryJsonType::MAX_PATH_BYTES
    token = "`#{"\\`" * CrystalClick::BinaryJsonType::MAX_PATH_BYTES}`"
    token.bytesize.should eq(514)
    CrystalClick::JsonPathSqlName.canonical_size(path.to_slice).should eq(514_u64)
    measure = CrystalClick::JsonPathSqlName.scan_token(token.to_slice, 0, 256).not_nil!
    measure.decoded_bytes.should eq(256_u64)
    exact = CrystalClick::BinaryCodecBudget.new(w252_name_limits(max_bytes: 256))
    CrystalClick::JsonPathSqlName.decode_token(token.to_slice, measure, exact).should eq(path)
    exact.wire_byte_count.should eq(256)

    short = CrystalClick::BinaryCodecBudget.new(w252_name_limits(max_bytes: 255))
    expect_raises(CrystalClick::CorruptPartError, /byte limit/) do
      CrystalClick::JsonPathSqlName.decode_token(token.to_slice, measure, short)
    end
    short.wire_byte_count.should eq(0)
    CrystalClick::JsonPathSqlName.scan_token(token.to_slice, 0, 255).should be_nil
    long_token = "`#{"\\`" * 257}`"
    CrystalClick::JsonPathSqlName.scan_token(long_token.to_slice, 0, 256).should be_nil

    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    json_type = CrystalClick::BinaryDataType.json(typed_paths: {path => uint8})
    CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(json_type.name)
      .should eq(json_type)

    ["", "``", "`a\\`", "`a`b", "a.b", "`a\\q`", "a`b", "`a`=1"].each do |bad|
      CrystalClick::JsonPathSqlName.scan_token(bad.to_slice, 0).should be_nil
    end
    CrystalClick::JsonPathSqlName.scan_token("a".to_slice, -1).should be_nil
    CrystalClick::JsonPathSqlName.scan_token("a".to_slice, 1).should be_nil

    forged = CrystalClick::JsonPathSqlName::TokenMeasure.new(
      measure.token_start, measure.token_after, measure.content_start,
      measure.content_after, 255_u64, measure.quoted,
    )
    untouched = CrystalClick::BinaryCodecBudget.new(w252_name_limits)
    expect_raises(ArgumentError, /token measure/) do
      CrystalClick::JsonPathSqlName.decode_token(token.to_slice, forged, untouched)
    end
    untouched.wire_byte_count.should eq(0)
  end
end
