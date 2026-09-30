require "./spec_helper"

private def w96_mutate_first_byte(value : String) : Nil
  raise "W96 mutation fixture must be non-empty" if value.empty?
  value.to_unsafe[0] = 0x58_u8
end

private def w96_legacy_leaf(name : String, values : Array(UInt64) | Array(String)) : CrystalClick::WideTupleLeafColumn
  CrystalClick::WideTupleLeafColumn.new(name, values)
end

describe "W96 numeric Tuple model" do
  it "maps the closed numeric leaf identities to exact names and widths" do
    profiles = {
      {"Int8", 1}, {"UInt8", 1},
      {"Int16", 2}, {"UInt16", 2},
      {"Int32", 4}, {"UInt32", 4},
      {"Int64", 8}, {"UInt64", 8},
      {"Int128", 16}, {"UInt128", 16},
      {"Int256", 32}, {"UInt256", 32},
      {"Float32", 4}, {"Float64", 8}, {"BFloat16", 2},
    }

    profiles.each do |type_name, width|
      CrystalClick::WideTupleNumericType.width(type_name).should eq(width)

      plan = CrystalClick::WideTupleTypePlan.for_type("Tuple(value #{type_name})").not_nil!
      plan.fields.map(&.type_name).should eq([type_name])
      plan.stream_width("payload", "payload%2Evalue").should eq(width)
    end

    CrystalClick::WideTupleNumericType.type_name(Int8).should eq("Int8")
    CrystalClick::WideTupleNumericType.type_name(UInt8).should eq("UInt8")
    CrystalClick::WideTupleNumericType.type_name(Int16).should eq("Int16")
    CrystalClick::WideTupleNumericType.type_name(UInt16).should eq("UInt16")
    CrystalClick::WideTupleNumericType.type_name(Int32).should eq("Int32")
    CrystalClick::WideTupleNumericType.type_name(UInt32).should eq("UInt32")
    CrystalClick::WideTupleNumericType.type_name(Int64).should eq("Int64")
    CrystalClick::WideTupleNumericType.type_name(UInt64).should eq("UInt64")
    CrystalClick::WideTupleNumericType.type_name(Int128).should eq("Int128")
    CrystalClick::WideTupleNumericType.type_name(UInt128).should eq("UInt128")
    CrystalClick::WideTupleNumericType.type_name(CrystalClick::Int256Value).should eq("Int256")
    CrystalClick::WideTupleNumericType.type_name(CrystalClick::UInt256Value).should eq("UInt256")
    CrystalClick::WideTupleNumericType.type_name(Float32).should eq("Float32")
    CrystalClick::WideTupleNumericType.type_name(Float64).should eq("Float64")
    CrystalClick::WideTupleNumericType.type_name(CrystalClick::BFloat16Value).should eq("BFloat16")

    CrystalClick::WideTupleNumericType.width(Int8).should eq(1)
    CrystalClick::WideTupleNumericType.width(UInt8).should eq(1)
    CrystalClick::WideTupleNumericType.width(Int16).should eq(2)
    CrystalClick::WideTupleNumericType.width(UInt16).should eq(2)
    CrystalClick::WideTupleNumericType.width(Int32).should eq(4)
    CrystalClick::WideTupleNumericType.width(UInt32).should eq(4)
    CrystalClick::WideTupleNumericType.width(Int64).should eq(8)
    CrystalClick::WideTupleNumericType.width(UInt64).should eq(8)
    CrystalClick::WideTupleNumericType.width(Int128).should eq(16)
    CrystalClick::WideTupleNumericType.width(UInt128).should eq(16)
    CrystalClick::WideTupleNumericType.width(CrystalClick::Int256Value).should eq(32)
    CrystalClick::WideTupleNumericType.width(CrystalClick::UInt256Value).should eq(32)
    CrystalClick::WideTupleNumericType.width(Float32).should eq(4)
    CrystalClick::WideTupleNumericType.width(Float64).should eq(8)
    CrystalClick::WideTupleNumericType.width(CrystalClick::BFloat16Value).should eq(2)
  end

  it "rejects parameterized and empty aliases instead of treating them as bare leaves" do
    parameterized = [
      "Tuple(value UInt8(1))",
      "Tuple(value Float32(3))",
      "Tuple(value UInt256(foo))",
    ]
    parameterized.each do |type_name|
      CrystalClick::WideTypeExpression.parse(type_name).should_not be_nil
      CrystalClick::WideTupleTypePlan.for_type(type_name).should be_nil
    end

    empty_arguments = [
      "Int8", "UInt8", "Int16", "UInt16", "Int32", "UInt32", "Int64", "UInt64",
      "Int128", "UInt128", "Int256", "UInt256", "Float32", "Float64", "BFloat16",
    ]
    empty_arguments.each do |type_name|
      CrystalClick::WideTupleTypePlan.for_type("Tuple(value #{type_name}())").should be_nil
    end
  end

  it "preserves legacy UInt64/String union construction and deep ownership" do
    uint64_source = [1_u64, UInt64::MAX]
    uint64_leaf = w96_legacy_leaf("count", uint64_source)
    uint64_source[0] = 9_u64
    uint64_snapshot = uint64_leaf.uint64_values
    uint64_snapshot[1] = 0_u64
    uint64_leaf.uint64_values.should eq([1_u64, UInt64::MAX])
    uint64_leaf.type_name.should eq("UInt64")

    string_source = [String.new(Bytes[0x61_u8, 0_u8, 0xff_u8]), "tail"] of String
    string_leaf = w96_legacy_leaf("text", string_source)
    string_source[0].to_unsafe[0] = 0x58_u8
    string_source[1] = "replaced"
    string_snapshot = string_leaf.string_values
    w96_mutate_first_byte(string_snapshot[0])
    string_leaf.string_values.should eq([String.new(Bytes[0x61_u8, 0_u8, 0xff_u8]), "tail"])
    string_leaf.type_name.should eq("String")
  end

  it "rejects Bool buffers through the generic constructor without widening Buffer" do
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::WideTupleLeafColumn.new("flag", [true, false])
    end

    numeric_leaf = CrystalClick::WideTupleLeafColumn.new("count", [1_i8])
    numeric_leaf.values.as(Array(Int8)).should eq([1_i8])
  end

  it "copies numeric buffers and enforces exact nominal typed access" do
    source = [-1_i8, 0_i8, Int8::MAX]
    leaf = CrystalClick::WideTupleLeafColumn.new("signed", source)
    source[0] = 1_i8

    all_values = leaf.values.as(Array(Int8))
    all_values[2] = 0_i8
    exposed = leaf.values_as(Int8)
    exposed[1] = 7_i8
    leaf.values_as(Int8).should eq([-1_i8, 0_i8, Int8::MAX])
    leaf.value_at(0, Int8).should eq(-1_i8)
    leaf.type_name.should eq("Int8")
    expect_raises(CrystalClick::UnsupportedFormatError) { leaf.values_as(UInt8) }
    expect_raises(CrystalClick::UnsupportedFormatError) { leaf.value_at(0, UInt8) }
  end

  it "constructs and exact-copies each admitted numeric Array identity" do
    leaves = [
      CrystalClick::WideTupleLeafColumn.new("i8", [] of Int8),
      CrystalClick::WideTupleLeafColumn.new("u8", [] of UInt8),
      CrystalClick::WideTupleLeafColumn.new("i16", [] of Int16),
      CrystalClick::WideTupleLeafColumn.new("u16", [] of UInt16),
      CrystalClick::WideTupleLeafColumn.new("i32", [] of Int32),
      CrystalClick::WideTupleLeafColumn.new("u32", [] of UInt32),
      CrystalClick::WideTupleLeafColumn.new("i64", [] of Int64),
      CrystalClick::WideTupleLeafColumn.new("u64", [] of UInt64),
      CrystalClick::WideTupleLeafColumn.new("i128", [] of Int128),
      CrystalClick::WideTupleLeafColumn.new("u128", [] of UInt128),
      CrystalClick::WideTupleLeafColumn.new("i256", [] of CrystalClick::Int256Value),
      CrystalClick::WideTupleLeafColumn.new("u256", [] of CrystalClick::UInt256Value),
      CrystalClick::WideTupleLeafColumn.new("f32", [] of Float32),
      CrystalClick::WideTupleLeafColumn.new("f64", [] of Float64),
      CrystalClick::WideTupleLeafColumn.new("bf16", [] of CrystalClick::BFloat16Value),
    ] of CrystalClick::WideTupleLeafColumn

    leaves.map(&.type_name).should eq([
      "Int8", "UInt8", "Int16", "UInt16", "Int32", "UInt32", "Int64", "UInt64",
      "Int128", "UInt128", "Int256", "UInt256", "Float32", "Float64", "BFloat16",
    ])
    leaves[0].values_as(Int8).should eq([] of Int8)
    leaves[1].values_as(UInt8).should eq([] of UInt8)
    leaves[2].values_as(Int16).should eq([] of Int16)
    leaves[3].values_as(UInt16).should eq([] of UInt16)
    leaves[4].values_as(Int32).should eq([] of Int32)
    leaves[5].values_as(UInt32).should eq([] of UInt32)
    leaves[6].values_as(Int64).should eq([] of Int64)
    leaves[7].values_as(UInt64).should eq([] of UInt64)
    leaves[8].values_as(Int128).should eq([] of Int128)
    leaves[9].values_as(UInt128).should eq([] of UInt128)
    leaves[10].values_as(CrystalClick::Int256Value).size.should eq(0)
    leaves[11].values_as(CrystalClick::UInt256Value).size.should eq(0)
    leaves[12].values_as(Float32).should eq([] of Float32)
    leaves[13].values_as(Float64).should eq([] of Float64)
    leaves[14].values_as(CrystalClick::BFloat16Value).should eq([] of CrystalClick::BFloat16Value)
  end

  it "compares floating and wrapper-backed values by their exact stored bits" do
    plus_zero_f32 = 0_u32.unsafe_as(Float32)
    minus_zero_f32 = 0x8000_0000_u32.unsafe_as(Float32)
    nan_f64 = 0x7ff8_0000_0001_2345_u64.unsafe_as(Float64)
    same_nan_f64 = 0x7ff8_0000_0001_2345_u64.unsafe_as(Float64)

    CrystalClick::WideTupleNumericType.same_bits?(plus_zero_f32, plus_zero_f32).should be_true
    CrystalClick::WideTupleNumericType.same_bits?(plus_zero_f32, minus_zero_f32).should be_false
    CrystalClick::WideTupleNumericType.same_bits?(nan_f64, same_nan_f64).should be_true
    CrystalClick::WideTupleNumericType.is_default?(plus_zero_f32).should be_true
    CrystalClick::WideTupleNumericType.is_default?(minus_zero_f32).should be_false

    bfloat_zero = CrystalClick::BFloat16Value.new(0_u16)
    bfloat_negative_zero = CrystalClick::BFloat16Value.new(0x8000_u16)
    CrystalClick::WideTupleNumericType.same_bits?(bfloat_zero, bfloat_zero).should be_true
    CrystalClick::WideTupleNumericType.same_bits?(bfloat_zero, bfloat_negative_zero).should be_false
    CrystalClick::WideTupleNumericType.is_default?(bfloat_zero).should be_true
    CrystalClick::WideTupleNumericType.is_default?(bfloat_negative_zero).should be_false

    int256 = CrystalClick::Int256Value.new(1_u128, 2_u128)
    same_int256 = CrystalClick::Int256Value.new(1_u128, 2_u128)
    other_int256 = CrystalClick::Int256Value.new(1_u128, 3_u128)
    CrystalClick::WideTupleNumericType.same_bits?(int256, same_int256).should be_true
    CrystalClick::WideTupleNumericType.same_bits?(int256, other_int256).should be_false
    CrystalClick::WideTupleNumericType.same_bits?(1_u8, 1_u16).should be_false
  end

  it "returns owned type-name strings for String and numeric leaves" do
    string_leaf = CrystalClick::WideTupleLeafColumn.new("text", ["value"] of String)
    string_name = string_leaf.type_name
    w96_mutate_first_byte(string_name)
    string_leaf.type_name.should eq("String")

    numeric_leaf = CrystalClick::WideTupleLeafColumn.new("count", [1_u64])
    numeric_name = numeric_leaf.type_name
    w96_mutate_first_byte(numeric_name)
    numeric_leaf.type_name.should eq("UInt64")

    helper_name = CrystalClick::WideTupleNumericType.type_name(Int8)
    w96_mutate_first_byte(helper_name)
    CrystalClick::WideTupleNumericType.type_name(Int8).should eq("Int8")
  end
end
