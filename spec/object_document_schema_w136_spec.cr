require "./spec_helper"

private def w136_fixed_type(width : Int) : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.fixed_string(width)
end

private def w136_schema_limits(max_bytes : Int = 1024) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(max_depth: 32, max_nodes: 1024, max_elements: 1024, max_bytes: max_bytes)
end

private def w136_schema_plan(types : Hash(String, CrystalClick::BinaryDataType)) : CrystalClick::ObjectDocumentPlan
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    ),
    types,
  )
end

describe "W136 declared FixedString(N) Object schema" do
  it "constructs and parses the full legal width range canonically without a payload" do
    widths = [
      1, 9, 10, 99, 100, 999, 1_000, 9_999, 10_000,
      99_999, 100_000, 999_999, 1_000_000, 9_999_999, 10_000_000,
      0x00ff_ffff,
    ]
    fields = Hash(String, CrystalClick::BinaryDataType).new(initial_capacity: widths.size)
    widths.each_with_index do |width, index|
      fields["f#{index.to_s.rjust(2, '0')}"] = w136_fixed_type(width)
    end
    declaration = "JSON(#{widths.each_with_index.map { |width, index| "f#{index.to_s.rjust(2, '0')} FixedString(#{width})" }.join(", ")})"

    reversed = Hash(String, CrystalClick::BinaryDataType).new(initial_capacity: fields.size)
    fields.keys.sort.reverse.each { |path| reversed[path] = fields[path] }
    schema = CrystalClick::ObjectDocumentSchema.new(reversed)
    schema.declaration.should eq(declaration)
    schema.typed_paths.should eq(fields)

    parsed = CrystalClick::ObjectDocumentSchema.parse_declaration(declaration)
    parsed.declaration.should eq(declaration)
    parsed.typed_paths.should eq(fields)
    parsed.typed_paths["f15"].should eq(w136_fixed_type(0x00ff_ffff))
  end

  it "splits commas only outside FixedString arguments and accepts mixed bounded declarations" do
    parsed = CrystalClick::ObjectDocumentSchema.parse_declaration(
      "JSON(max_dynamic_types=9, max_dynamic_paths=17, `root.left` FixedString(3), count UInt8)"
    )
    parsed.declaration.should eq(
      "JSON(max_dynamic_types=9, max_dynamic_paths=17, count UInt8, `root.left` FixedString(3))"
    )
    parsed.typed_paths.should eq({
      "count"     => CrystalClick::BinaryDataType.primitive("UInt8"),
      "root.left" => w136_fixed_type(3),
    })
    parsed.max_dynamic_types.should eq(9)
    parsed.max_dynamic_paths.should eq(17)
  end

  it "admits exact constructor and parser byte budgets across decimal digit boundaries" do
    [1, 9, 10, 99, 100, 999, 1_000, 9_999, 10_000, 9_999_999, 10_000_000, 0x00ff_ffff].each do |width|
      type_name = "FixedString(#{width})"
      declaration = "JSON(v #{type_name})"
      declaration.bytesize.should eq("JSON(v ".bytesize + type_name.bytesize + 1)

      constructor_bytes = 1 + declaration.bytesize * 2 # retained path and declaration builder/output
      constructed = CrystalClick::ObjectDocumentSchema.new(
        {"v" => w136_fixed_type(width)},
        limits: w136_schema_limits(constructor_bytes),
      )
      constructed.declaration.should eq(declaration)
      constructed.declaration_byte_size.should eq(declaration.bytesize)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentSchema.new(
          {"v" => w136_fixed_type(width)},
          limits: w136_schema_limits(constructor_bytes - 1),
        )
      end

      # Input declaration, copied path/type accounting, retained path, and the
      # two canonical declaration buffers are checked at the exact cutoff.
      parser_bytes = declaration.bytesize * 3 + 2 + type_name.bytesize + 1
      parsed = CrystalClick::ObjectDocumentSchema.parse_declaration(declaration, w136_schema_limits(parser_bytes))
      parsed.declaration.should eq(declaration)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentSchema.parse_declaration(declaration, w136_schema_limits(parser_bytes - 1))
      end
    end
  end

  it "preserves width as nominal plan and value identity" do
    fixed3 = w136_fixed_type(3)
    fixed4 = w136_fixed_type(4)
    string = CrystalClick::BinaryDataType.primitive("String")
    schema = CrystalClick::ObjectDocumentSchema.new({"n" => fixed3})

    schema.validate_plan(w136_schema_plan({"n" => fixed3})).should be_nil
    expect_raises(ArgumentError) do
      schema.validate_plan(w136_schema_plan({"n" => fixed4}))
    end
    expect_raises(ArgumentError) do
      schema.validate_plan(w136_schema_plan({"n" => string}))
    end

    raw = Bytes[0x00_u8, 0xc3_u8, 0xa9_u8]
    fixed_value = CrystalClick::BinaryValue.fixed(fixed3, raw)
    same_width = CrystalClick::BinaryValue.fixed(w136_fixed_type(3), raw)
    different_width = CrystalClick::BinaryValue.fixed(fixed4, Bytes[0x00_u8, 0xc3_u8, 0xa9_u8, 0x00_u8])
    string_value = CrystalClick::BinaryValue.string(String.new(raw))
    fixed_value.type.should eq(same_width.type)
    fixed_value.type.should_not eq(different_width.type)
    fixed_value.type.should_not eq(string_value.type)
    fixed_value.bytes.should eq(string_value.bytes)
    fixed_value.bytes.should eq(raw)

    expect_raises(ArgumentError) { CrystalClick::BinaryValue.fixed(fixed3, Bytes[0x00_u8, 0xc3_u8]) }
    expect_raises(ArgumentError) { CrystalClick::BinaryValue.fixed(fixed3, Bytes[0x00_u8, 0xc3_u8, 0xa9_u8, 0x00_u8]) }
  end

  it "rejects out-of-range widths, aliases, unsupported leaves, and malformed parameter grammar" do
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.fixed_string(0) }
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.fixed_string(0x0100_0000) }

    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentSchema.new({"n" => CrystalClick::BinaryDataType.primitive("BFloat16")})
    end

    [
      "JSON(n FixedString)",
      "JSON(n FixedString())",
      "JSON(n FixedString(0))",
      "JSON(n FixedString(01))",
      "JSON(n FixedString(+1))",
      "JSON(n FixedString(-1))",
      "JSON(n FixedString(16777216))",
      "JSON(n FixedString(999999999999999999999999999999999999999999))",
      "JSON(n FixedString(3, 4))",
      "JSON(n FixedString(3,) )",
      "JSON(n FixedString((3)))",
      "JSON(n FixedString(3)junk)",
      "JSON(n FixedString(3) UInt8)",
      "JSON(n FixedString(3),)",
      "JSON(n fixedstring(3))",
      "JSON(n FixedString (3))",
      "JSON(n FixedString( 3))",
      "JSON(n FixedString(3 ))",
      "JSON(n FixedString(2147483648))",
      "JSON(n FixedString(3)))",
      "JSON(n FixedString(3)",
    ].each do |declaration|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentSchema.parse_declaration(declaration)
      end
    end

    fixed3 = w136_fixed_type(3)
    string = CrystalClick::BinaryDataType.primitive("String")
    types = {
      "array"    => CrystalClick::BinaryDataType.array(fixed3),
      "map"      => CrystalClick::BinaryDataType.map(string, fixed3),
      "nullable" => CrystalClick::BinaryDataType.nullable(fixed3),
      "tuple"    => CrystalClick::BinaryDataType.tuple([fixed3]),
    } of String => CrystalClick::BinaryDataType
    schema = CrystalClick::ObjectDocumentSchema.new(types)
    schema.declaration.should eq("JSON(array Array(FixedString(3)), map Map(String, FixedString(3)), nullable Nullable(FixedString(3)), tuple Tuple(FixedString(3)))")
    CrystalClick::ObjectDocumentSchema.parse_declaration(schema.declaration).typed_paths.should eq(types)
  end
end
