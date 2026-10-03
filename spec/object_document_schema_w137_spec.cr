require "./spec_helper"

private def w137_width_bits(precision : Int) : Int32
  case precision
  when 1..9   then 32
  when 10..18 then 64
  when 19..38 then 128
  when 39..76 then 256
  else
    raise "test precision outside the SQL Decimal family"
  end
end

private def w137_decimal_type(precision : Int, scale : Int) : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.decimal(w137_width_bits(precision), precision, scale)
end

private def w137_schema_limits(max_bytes : Int) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(max_depth: 32, max_nodes: 1024, max_elements: 1024, max_bytes: max_bytes)
end

private def w137_schema_plan(types : Hash(String, CrystalClick::BinaryDataType)) : CrystalClick::ObjectDocumentPlan
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    ),
    types,
  )
end

describe "W137 canonical Decimal Object schema" do
  it "constructs and parses every legal SQL precision/scale pair with width selected independently from P" do
    pair_count = 0
    1.upto(76) do |precision|
      0.upto(precision) do |scale|
        type = w137_decimal_type(precision, scale)
        canonical_leaf = "Decimal(#{precision}, #{scale})"
        declaration = "JSON(n #{canonical_leaf})"

        schema = CrystalClick::ObjectDocumentSchema.new({"n" => type})
        schema.declaration.should eq(declaration)
        schema.typed_paths.should eq({"n" => type})

        parsed = CrystalClick::ObjectDocumentSchema.parse_declaration(declaration)
        parsed.declaration.should eq(declaration)
        parsed.typed_paths.should eq({"n" => type})
        parsed.typed_paths["n"].fixed_width.should eq(w137_width_bits(precision) // 8)
        pair_count += 1
      end
    end
    pair_count.should eq(3002)
  end

  it "admits exact constructor and parser budgets and rejects one byte less" do
    [
      {9, 0}, {10, 10}, {18, 9}, {19, 19}, {38, 0}, {39, 38}, {76, 76},
    ].each do |pair|
      precision, scale = pair
      leaf = "Decimal(#{precision}, #{scale})"
      declaration = "JSON(n #{leaf})"
      path_bytes = "n".bytesize

      constructor_bytes = path_bytes + 2 * declaration.bytesize
      constructed = CrystalClick::ObjectDocumentSchema.new(
        {"n" => w137_decimal_type(precision, scale)},
        limits: w137_schema_limits(constructor_bytes),
      )
      constructed.declaration.should eq(declaration)
      constructed.declaration_byte_size.should eq(declaration.bytesize)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentSchema.new(
          {"n" => w137_decimal_type(precision, scale)},
          limits: w137_schema_limits(constructor_bytes - 1),
        )
      end

      # Input declaration, copied path/type accounting, retained path, and
      # both canonical declaration buffers are separately charged.
      parser_bytes = declaration.bytesize * 3 + path_bytes * 2 + leaf.bytesize + 1
      parsed = CrystalClick::ObjectDocumentSchema.parse_declaration(declaration, w137_schema_limits(parser_bytes))
      parsed.declaration.should eq(declaration)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentSchema.parse_declaration(declaration, w137_schema_limits(parser_bytes - 1))
      end
    end
  end

  it "keeps width, precision, scale, and integer identity exact despite equal raw widths" do
    decimal = CrystalClick::BinaryDataType.decimal(32, 9, 2)
    same_width_other_precision = CrystalClick::BinaryDataType.decimal(32, 8, 2)
    same_width_other_scale = CrystalClick::BinaryDataType.decimal(32, 9, 3)
    integer = CrystalClick::BinaryDataType.primitive("Int32")
    schema = CrystalClick::ObjectDocumentSchema.new({"n" => decimal})

    schema.validate_plan(w137_schema_plan({"n" => decimal})).should be_nil
    [same_width_other_precision, same_width_other_scale, integer].each do |other_type|
      expect_raises(ArgumentError) do
        schema.validate_plan(w137_schema_plan({"n" => other_type}))
      end
    end

    raw = Bytes[0x01_u8, 0x02_u8, 0x03_u8, 0x04_u8]
    decimal_value = CrystalClick::BinaryValue.fixed(decimal, raw)
    integer_value = CrystalClick::BinaryValue.fixed(integer, raw)
    decimal_value.bytes.should eq(integer_value.bytes)
    decimal_value.type.should_not eq(integer_value.type)
    decimal_value.type.should_not eq(CrystalClick::BinaryValue.fixed(same_width_other_precision, raw).type)
    decimal_value.type.should_not eq(CrystalClick::BinaryValue.fixed(same_width_other_scale, raw).type)
  end

  it "rejects wire-valid descriptors that are not the canonical SQL Decimal(P, S) type locally" do
    # The binary descriptor grammar is intentionally wider than Object SQL
    # schema admission; these descriptors must remain constructible there.
    wider_storage = CrystalClick::BinaryDataType.decimal(64, 9, 2)
    wider_storage.decimal_type.not_nil!.width_bits.should eq(64)
    wider_storage.fixed_width.should eq(8)

    scale_above_precision = CrystalClick::BinaryDataType.decimal(32, 8, 9)
    scale_above_precision.decimal_type.not_nil!.scale.should eq(9)
    CrystalClick::BinaryDecimalType.new(64, 9, 2).width_bits.should eq(64)
    CrystalClick::BinaryDecimalType.new(32, 8, 9).scale.should eq(9)

    [wider_storage, scale_above_precision].each do |type|
      expect_raises(ArgumentError) do
        CrystalClick::ObjectDocumentSchema.new({"n" => type})
      end
    end
  end

  it "parses canonical Decimal beside strict FixedString and rejects aliases or malformed type tails" do
    declaration = "JSON(n Decimal(9, 2), fixed FixedString(3))"
    parsed = CrystalClick::ObjectDocumentSchema.parse_declaration(declaration)
    parsed.declaration.should eq("JSON(fixed FixedString(3), n Decimal(9, 2))")
    parsed.typed_paths.should eq({
      "n"     => w137_decimal_type(9, 2),
      "fixed" => CrystalClick::BinaryDataType.fixed_string(3),
    })

    [
      "JSON(n Decimal)",
      "JSON(n Decimal())",
      "JSON(n Decimal(9))",
      "JSON(n Decimal32(2))",
      "JSON(n Decimal64(2))",
      "JSON(n Decimal128(2))",
      "JSON(n Decimal256(2))",
      "JSON(n Decimal(01, 2))",
      "JSON(n Decimal(9, 02))",
      "JSON(n Decimal(9,2))",
      "JSON(n Decimal(9,  2))",
      "JSON(n Decimal (9, 2))",
      "JSON(n Decimal( 9, 2))",
      "JSON(n Decimal(9 , 2))",
      "JSON(n Decimal(9, 2 ))",
      "JSON(n Decimal(0, 0))",
      "JSON(n Decimal(77, 0))",
      "JSON(n Decimal(9, 10))",
      "JSON(n Decimal(999999999999999999999999999999999999999999, 0))",
      "JSON(n Decimal(9, 999999999999999999999999999999999999999999))",
      "JSON(n Decimal(9, 2) UInt8)",
      "JSON(n Decimal(9, (2)))",
      "JSON(n FixedString)",
      "JSON(n FixedString(01))",
      "JSON(n fixedstring(3))",
      "JSON(n FixedString (3))",
      "JSON(n FixedString( 3))",
      "JSON(n FixedString(3 ))",
      "JSON(n FixedString(3) UInt8)",
    ].each do |malformed|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentSchema.parse_declaration(malformed)
      end
    end
  end

  it "admits canonical recursive wrappers around Decimal and FixedString leaves" do
    decimal = w137_decimal_type(9, 2)
    fixed = CrystalClick::BinaryDataType.fixed_string(3)
    types = {
      "array"    => CrystalClick::BinaryDataType.array(decimal),
      "fixed"    => CrystalClick::BinaryDataType.nullable(fixed),
      "map"      => CrystalClick::BinaryDataType.map(CrystalClick::BinaryDataType.primitive("String"), decimal),
      "nullable" => CrystalClick::BinaryDataType.nullable(decimal),
      "tuple"    => CrystalClick::BinaryDataType.tuple([decimal]),
    } of String => CrystalClick::BinaryDataType
    declaration = "JSON(array Array(Decimal(9, 2)), fixed Nullable(FixedString(3)), map Map(String, Decimal(9, 2)), nullable Nullable(Decimal(9, 2)), tuple Tuple(Decimal(9, 2)))"

    constructed = CrystalClick::ObjectDocumentSchema.new(types)
    constructed.declaration.should eq(declaration)
    constructed.typed_paths.should eq(types)

    parsed = CrystalClick::ObjectDocumentSchema.parse_declaration(declaration)
    parsed.declaration.should eq(declaration)
    parsed.typed_paths.should eq(types)
  end
end
