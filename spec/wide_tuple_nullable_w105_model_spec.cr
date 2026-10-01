require "./spec_helper"

describe "W105 nullable Tuple leaf model" do
  it "owns a strict, detached, row-aligned null map" do
    source = Bytes[1_u8, 0_u8, 1_u8]
    null_map = CrystalClick::ScalarNullMap.new(source, 3_u64)

    source[0] = 0_u8
    null_map.null_at?(0).should be_true
    null_map.null_at?(1).should be_false
    null_map.null_at?(2).should be_true
    null_map.size.should eq(3)

    exposed = null_map.bytes
    exposed[0] = 0_u8
    null_map.null_at?(0).should be_true
    null_map.logical_charge.should be > 0_u64

    empty = CrystalClick::ScalarNullMap.new(Bytes.empty, 0_u64)
    empty.size.should eq(0)
    empty.bytes.should eq([] of UInt8)
    empty.logical_charge.should be > 0_u64

    expect_raises(ArgumentError) do
      CrystalClick::ScalarNullMap.new(Bytes[0_u8], 2_u64)
    end
    expect_raises(ArgumentError) do
      CrystalClick::ScalarNullMap.new(Bytes[0_u8, 2_u8], 2_u64)
    end
  end

  it "retains nullable declaration identity while rejecting nested and container wrappers" do
    declarations = [
      {"Nullable(UInt64)", "UInt64"},
      {"Nullable(String)", "String"},
      {"Nullable(DateTime('US/Eastern'))", "DateTime('US/Eastern')"},
      {"Nullable(DateTime64(3, 'US/Eastern'))", "DateTime64(3, 'US/Eastern')"},
      {"Nullable(Enum8('negative' = -7, 'positive' = 4))", "Enum8('negative' = -7, 'positive' = 4)"},
      {"Nullable(Decimal(9, 2))", "Decimal(9, 2)"},
    ]

    declarations.each do |nullable_name, base_name|
      leaf_type = CrystalClick::WideTupleLeafType.parse(nullable_name).not_nil!
      leaf_type.nullable?.should be_true
      leaf_type.type_name.should eq(nullable_name)
      leaf_type.base_type_name.should eq(base_name)
      CrystalClick::WideTupleLeafType.parse(base_name).not_nil!.nullable?.should be_false
    end

    datetime = CrystalClick::WideTupleLeafType.parse(
      "Nullable(DateTime64(3, 'US/Eastern'))"
    ).not_nil!.datetime_type.not_nil!
    datetime.family.should eq(CrystalClick::DateTimeColumnType::Family::DateTime64)
    datetime.precision?.should eq(3_u8)
    datetime.time_zone?.not_nil!.name.should eq("US/Eastern")

    [
      "Nullable(Nullable(UInt8))",
      "Nullable(Array(UInt8))",
      "Nullable(Tuple(inner UInt8))",
      "Nullable(LowCardinality(String))",
      "Nullable(DefinitelyNotAType)",
      "Nullable(DateTime64(10))",
      "Nullable (UInt8)",
    ].each do |source|
      CrystalClick::WideTupleLeafType.parse(source).should be_nil
      CrystalClick::WideTupleTypePlan.for_type("Tuple(value #{source})").should be_nil
    end

    bare = CrystalClick::WideTupleLeafType.parse("UInt8").not_nil!
    zoned = CrystalClick::WideTupleLeafType.parse("Nullable(DateTime('US/Eastern'))").not_nil!
    bare.should_not eq(CrystalClick::WideTupleLeafType.parse("Nullable(UInt8)").not_nil!)
    zoned.type_name.should eq("Nullable(DateTime('US/Eastern'))")
  end

  it "returns logical Nil without losing numeric, String, or empty-value payloads" do
    number_plan = CrystalClick::WideTupleTypePlan.for_type(
      "Tuple(value Nullable(UInt8))"
    ).not_nil!
    number_type = number_plan.fields.first.leaf_type
    number_mask = CrystalClick::ScalarNullMap.new(Bytes[1_u8, 0_u8], 2_u64)
    number_leaf = CrystalClick::WideTupleLeafColumn.new(
      "value", number_type, [0_u8, 7_u8] of UInt8, number_mask
    )
    number_data = CrystalClick::WideTupleColumnData.new(number_plan, [number_leaf])

    number_data.row(0)["value"].should be_nil
    number_data.row(1)["value"].should eq(7_u8)
    number_data.value_at("value", 0).should be_nil
    number_data.value_as("value", 1, UInt8).should eq(7_u8)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      number_data.value_as("value", 0, UInt8)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      number_data["value"].values_as(UInt8)
    end

    number_copy = number_data["value"]
    number_copy.leaf_type.should eq(number_type)
    number_copy.null_map.not_nil!.bytes.should eq([1_u8, 0_u8])
    number_raw = number_copy.physical_values.as(Array(UInt8))
    number_raw.should eq([0_u8, 7_u8])
    number_raw[0] = 99_u8
    number_copy.physical_values.as(Array(UInt8)).should eq([0_u8, 7_u8])

    string_plan = CrystalClick::WideTupleTypePlan.for_type(
      "Tuple(text Nullable(String))"
    ).not_nil!
    string_leaf = CrystalClick::WideTupleLeafColumn.new(
      "text",
      string_plan.fields.first.leaf_type,
      ["hidden", "visible"] of String,
      CrystalClick::ScalarNullMap.new(Bytes[1_u8, 0_u8], 2_u64)
    )
    string_data = CrystalClick::WideTupleColumnData.new(string_plan, [string_leaf])
    string_data.row(0)["text"].should be_nil
    string_data.row(1)["text"].should eq("visible")
    string_data["text"].physical_values.as(Array(String)).should eq(["hidden", "visible"])
    string_data["text"].values.as(Array(CrystalClick::WideTupleLeafColumn::Value))[0].should be_nil
    string_data["text"].values.as(Array(CrystalClick::WideTupleLeafColumn::Value))[1].should eq("visible")
    string_data.row(0).string_bytesize.should eq(6_u64)
    string_data["text"].string_bytesize_at(0).should eq(6_u64)
    string_sizes = [] of Int32
    string_data["text"].each_string_bytesize { |size| string_sizes << size }
    string_sizes.should eq([6, 7])
  end

  it "preserves masked Enum and Bool storage while validating visible Enum codes" do
    enum_plan = CrystalClick::WideTupleTypePlan.for_type(
      "Tuple(state Nullable(Enum8('negative' = -7, 'positive' = 4)))"
    ).not_nil!
    enum_type = enum_plan.fields.first.leaf_type
    enum_leaf = CrystalClick::WideTupleLeafColumn.new(
      "state",
      enum_type,
      [0_i8, -7_i8, -7_i8, 4_i8] of Int8,
      CrystalClick::ScalarNullMap.new(Bytes[1_u8, 1_u8, 0_u8, 0_u8], 4_u64)
    )
    enum_data = CrystalClick::WideTupleColumnData.new(enum_plan, [enum_leaf])
    enum_data.row(0)["state"].should be_nil
    enum_data.row(1)["state"].should be_nil
    enum_data.row(2)["state"].as(CrystalClick::Enum8Value).code.should eq(-7_i8)
    enum_data.row(3)["state"].as(CrystalClick::Enum8Value).label.should eq("positive")
    enum_data["state"].physical_values.as(Array(Int8)).should eq([0_i8, -7_i8, -7_i8, 4_i8])
    expect_raises(CrystalClick::UnsupportedFormatError) do
      enum_data.value_as("state", 2, Int8)
    end

    expect_raises(ArgumentError) do
      CrystalClick::WideTupleLeafColumn.new(
        "state",
        enum_type,
        [0_i8] of Int8,
        CrystalClick::ScalarNullMap.new(Bytes[0_u8], 1_u64)
      )
    end

    bool_plan = CrystalClick::WideTupleTypePlan.for_type(
      "Tuple(flag Nullable(Bool))"
    ).not_nil!
    bool_leaf = CrystalClick::WideTupleLeafColumn.new(
      "flag",
      bool_plan.fields.first.leaf_type,
      [0xfe_u8, 0_u8, 2_u8] of UInt8,
      CrystalClick::ScalarNullMap.new(Bytes[1_u8, 0_u8, 0_u8], 3_u64)
    )
    bool_data = CrystalClick::WideTupleColumnData.new(bool_plan, [bool_leaf])
    bool_data.row(0)["flag"].should be_nil
    bool_data.row(1)["flag"].should eq(false)
    bool_data.row(2)["flag"].should eq(true)
    bool_data["flag"].physical_values.as(Array(UInt8)).should eq([0xfe_u8, 0_u8, 2_u8])
    expect_raises(CrystalClick::UnsupportedFormatError) do
      bool_data.value_as("flag", 1, UInt8)
    end
  end

  it "retains nullable Decimal and timezone metadata through empty and copied plans" do
    decimal_plan = CrystalClick::WideTupleTypePlan.for_type(
      "Tuple(amount Nullable(Decimal(9, 2)))"
    ).not_nil!
    decimal_type = decimal_plan.fields.first.leaf_type
    decimal_leaf = CrystalClick::WideTupleLeafColumn.new(
      "amount",
      decimal_type,
      [Int32::MIN] of Int32,
      CrystalClick::ScalarNullMap.new(Bytes[1_u8], 1_u64)
    )
    decimal_data = CrystalClick::WideTupleColumnData.new(decimal_plan, [decimal_leaf])
    decimal_data.row(0)["amount"].should be_nil
    decimal_data["amount"].physical_values.as(Array(Int32)).should eq([Int32::MIN])

    visible_decimal = CrystalClick::WideTupleLeafColumn.new(
      "amount",
      decimal_type,
      [17_i32] of Int32,
      CrystalClick::ScalarNullMap.new(Bytes[0_u8], 1_u64)
    )
    visible_decimal_data = CrystalClick::WideTupleColumnData.new(decimal_plan, [visible_decimal])
    expect_raises(CrystalClick::UnsupportedFormatError) do
      visible_decimal_data.value_as("amount", 0, CrystalClick::Decimal64Value)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      visible_decimal_data.value_as("amount", 0, Int32)
    end

    empty_plan = CrystalClick::WideTupleTypePlan.for_type(
      "Tuple(tick Nullable(DateTime64(3, 'US/Eastern')))"
    ).not_nil!
    exact_type = empty_plan.fields.first.leaf_type
    empty_leaf = CrystalClick::WideTupleLeafColumn.new(
      "tick",
      exact_type,
      [] of CrystalClick::DateTime64Value,
      CrystalClick::ScalarNullMap.new(Bytes.empty, 0_u64)
    )
    empty_data = CrystalClick::WideTupleColumnData.new(empty_plan, [empty_leaf])
    empty_data.row_count.should eq(0)
    copied_field = empty_data.fields.first
    copied_field.leaf_type.should eq(exact_type)
    copied_field.type_name.should eq("Nullable(DateTime64(3, 'US/Eastern'))")
    empty_copy = empty_data.columns.first
    empty_copy.size.should eq(0)
    empty_copy.type_name.should eq(copied_field.type_name)
    empty_copy.null_map.not_nil!.bytes.should eq([] of UInt8)
    empty_copy.datetime_type.not_nil!.time_zone?.not_nil!.name.should eq("US/Eastern")
  end

  it "charges Nullable wrappers as parser nodes without weakening byte bounds" do
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_".chars.map(&.to_s)
    names = alphabet.dup
    459.times do |index|
      names << "#{alphabet[index // alphabet.size]}#{alphabet[index % alphabet.size]}"
    end
    source_for = ->(field_count : Int32) {
      fields = names[0, field_count - 1].map { |name| "#{name} Bool" }
      fields << "#{names[field_count - 1]} Nullable(Bool)"
      "Tuple(" + fields.join(",") + ")"
    }

    exactly_at_limit = source_for.call(510)
    over_limit = source_for.call(511)
    exactly_at_limit.bytesize.should be <= CrystalClick::WideTupleSchemaParser::MAX_SOURCE_BYTES
    over_limit.bytesize.should be <= CrystalClick::WideTupleSchemaParser::MAX_SOURCE_BYTES
    CrystalClick::WideTupleSchemaParser.parse(exactly_at_limit).not_nil!.size.should eq(510)
    CrystalClick::WideTupleSchemaParser.parse(over_limit).should be_nil
  end
end
