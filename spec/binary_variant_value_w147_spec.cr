require "./spec_helper"

private def w147_limits(
  max_depth : Int = 64,
  max_nodes : Int = 4_096,
  max_elements : Int = 1_000_000,
  max_bytes : Int = 64 * 1024 * 1024,
) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: max_depth,
    max_nodes: max_nodes,
    max_elements: max_elements,
    max_bytes: max_bytes
  )
end

private def w147_string_uint64_type : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.variant([
    CrystalClick::BinaryDataType.primitive("String"),
    CrystalClick::BinaryDataType.primitive("UInt64"),
  ] of CrystalClick::BinaryDataType)
end

describe "W147 generic Variant logical kernel" do
  it "decodes a canonical Variant descriptor and its selected String value" do
    # This RED uses only baseline APIs. Its first failure is the behavioral
    # refusal of a valid 0x2A descriptor, not a missing method or type.
    type = CrystalClick::BinaryDataTypeCodec.decode(
      Bytes[0x2a_u8, 0x02_u8, 0x15_u8, 0x04_u8]
    )

    type.name.should eq("Variant(String, UInt64)")

    value_bytes = Bytes[0x00_u8, 0x01_u8, 0x78_u8]
    value = CrystalClick::BinaryValueCodec.decode_value(type, value_bytes)
    value.type.name.should eq(type.name)
    CrystalClick::BinaryValueCodec.encode_value(value).should eq(value_bytes)
  end

  it "canonicalizes type arms by complete name, removes duplicates, and elides direct Nothing" do
    nothing = CrystalClick::BinaryDataType.primitive("Nothing")
    string = CrystalClick::BinaryDataType.primitive("String")
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    supplied = [uint64, string, uint64, nothing, string] of CrystalClick::BinaryDataType

    type = CrystalClick::BinaryDataType.variant(supplied)
    supplied.clear

    type.children.map(&.name).should eq(["String", "UInt64"] of String)
    type.name.should eq("Variant(String, UInt64)")
    type.tag.should eq(0x2a_u8)
    descriptor = Bytes[0x2a_u8, 0x02_u8, 0x15_u8, 0x04_u8]
    CrystalClick::BinaryDataTypeCodec.encode(type).should eq(descriptor)
    CrystalClick::BinaryDataTypeCodec.decode(descriptor).should eq(type)

    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.variant([nothing] of CrystalClick::BinaryDataType)
    end
  end

  it "represents NULL separately from each non-NULL arm and exposes no phantom child" do
    type = w147_string_uint64_type
    string_value = CrystalClick::BinaryValue.variant(
      type,
      0,
      CrystalClick::BinaryValue.string("x")
    )
    uint64_value = CrystalClick::BinaryValue.variant(
      type,
      1,
      CrystalClick::BinaryValue.uint64(42_u64)
    )
    null_value = CrystalClick::BinaryValue.variant_null(type)

    string_value.is_null?.should be_false
    string_value.variant_index?.should eq(0_u8)
    string_value.variant_child?.not_nil!.as_string.should eq("x")
    CrystalClick::BinaryValueCodec.encode_value(string_value).should eq(Bytes[0x00_u8, 0x01_u8, 0x78_u8])

    uint64_value.variant_index?.should eq(1_u8)
    uint64_value.variant_child?.not_nil!.as_uint64.should eq(42_u64)
    CrystalClick::BinaryValueCodec.encode_value(uint64_value).should eq(
      Bytes[0x01_u8, 0x2a_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8]
    )

    null_value.is_null?.should be_true
    null_value.variant_index?.should be_nil
    null_value.variant_child?.should be_nil
    CrystalClick::BinaryValueCodec.encode_value(null_value).should eq(Bytes[0xff_u8])
    CrystalClick::BinaryValueCodec.decode_value(type, Bytes[0xff_u8]).variant_index?.should be_nil
  end

  it "keeps Bool nominally distinct from the same-width UInt8 arm" do
    bool = CrystalClick::BinaryDataType.primitive("Bool")
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    type = CrystalClick::BinaryDataType.variant([uint8, bool] of CrystalClick::BinaryDataType)

    type.children.map(&.name).should eq(["Bool", "UInt8"] of String)
    type.child_at(0).should_not eq(type.child_at(1))
    CrystalClick::BinaryDataTypeCodec.encode(type).should eq(
      Bytes[0x2a_u8, 0x02_u8, 0x2d_u8, 0x01_u8]
    )

    bool_value = CrystalClick::BinaryValue.variant(type, 0, CrystalClick::BinaryValue.bool(true))
    uint8_value = CrystalClick::BinaryValue.variant(
      type,
      1,
      CrystalClick::BinaryValue.fixed(uint8, Bytes[0x01_u8])
    )
    CrystalClick::BinaryValueCodec.encode_value(bool_value).should eq(Bytes[0x00_u8, 0x01_u8])
    CrystalClick::BinaryValueCodec.encode_value(uint8_value).should eq(Bytes[0x01_u8, 0x01_u8])
    CrystalClick::BinaryValueCodec.decode_value(type, Bytes[0x01_u8, 0x02_u8]).type.should eq(type)
  end

  it "composes legal LowCardinality, Array, Tuple, and Map arms through the logical value codec" do
    string = CrystalClick::BinaryDataType.primitive("String")
    low_cardinality_string = CrystalClick::BinaryDataType.low_cardinality(string)
    low_cardinality_variant = CrystalClick::BinaryDataType.variant([
      string,
      low_cardinality_string,
    ] of CrystalClick::BinaryDataType)
    low_cardinality_variant.children.map(&.name).should eq([
      "LowCardinality(String)",
      "String",
    ] of String)
    low_cardinality_value = CrystalClick::BinaryValue.variant(
      low_cardinality_variant,
      0,
      CrystalClick::BinaryValue.low_cardinality(
        low_cardinality_string,
        CrystalClick::BinaryValue.string("x")
      )
    )
    CrystalClick::BinaryValueCodec.encode_value(low_cardinality_value).should eq(
      Bytes[0x00_u8, 0x01_u8, 0x78_u8]
    )

    array_string = CrystalClick::BinaryDataType.array(string)
    tuple = CrystalClick::BinaryDataType.tuple([
      CrystalClick::BinaryDataType.primitive("UInt8"),
      string,
    ] of CrystalClick::BinaryDataType)
    map = CrystalClick::BinaryDataType.map(CrystalClick::BinaryDataType.primitive("UInt8"), string)
    composite_variant = CrystalClick::BinaryDataType.variant([
      tuple,
      array_string,
      map,
    ] of CrystalClick::BinaryDataType)
    composite_variant.children.map(&.name).should eq([
      "Array(String)",
      "Map(UInt8, String)",
      "Tuple(UInt8, String)",
    ] of String)
    CrystalClick::BinaryDataTypeCodec.encode(composite_variant).should eq(
      Bytes[0x2a_u8, 0x03_u8, 0x1e_u8, 0x15_u8, 0x27_u8, 0x01_u8, 0x15_u8, 0x1f_u8, 0x02_u8, 0x01_u8, 0x15_u8]
    )

    array_value = CrystalClick::BinaryValue.variant(
      composite_variant,
      0,
      CrystalClick::BinaryValue.array(array_string, [CrystalClick::BinaryValue.string("x")] of CrystalClick::BinaryValue)
    )
    tuple_value = CrystalClick::BinaryValue.variant(
      composite_variant,
      2,
      CrystalClick::BinaryValue.tuple(tuple, [
        CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[0x07_u8]),
        CrystalClick::BinaryValue.string("y"),
      ] of CrystalClick::BinaryValue)
    )
    map_value = CrystalClick::BinaryValue.variant(
      composite_variant,
      1,
      CrystalClick::BinaryValue.map(map, [
        CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[0x07_u8]),
        CrystalClick::BinaryValue.string("m"),
      ] of CrystalClick::BinaryValue)
    )
    array_wire = Bytes[0x00_u8, 0x01_u8, 0x01_u8, 0x78_u8]
    map_wire = Bytes[0x01_u8, 0x01_u8, 0x07_u8, 0x01_u8, 0x6d_u8]
    tuple_wire = Bytes[0x02_u8, 0x07_u8, 0x01_u8, 0x79_u8]
    CrystalClick::BinaryValueCodec.encode_value(array_value).should eq(array_wire)
    CrystalClick::BinaryValueCodec.encode_value(map_value).should eq(map_wire)
    CrystalClick::BinaryValueCodec.encode_value(tuple_value).should eq(tuple_wire)
    CrystalClick::BinaryValueCodec.decode_value(composite_variant, array_wire).variant_child?.not_nil!.element_at(0).as_string.should eq("x")
    decoded_map = CrystalClick::BinaryValueCodec.decode_value(composite_variant, map_wire).variant_child?.not_nil!
    decoded_map.element_at(0).bytes.should eq(Bytes[0x07_u8])
    decoded_map.element_at(1).as_string.should eq("m")
    decoded_tuple = CrystalClick::BinaryValueCodec.decode_value(composite_variant, tuple_wire).variant_child?.not_nil!
    decoded_tuple.element_at(0).bytes.should eq(Bytes[0x07_u8])
    decoded_tuple.element_at(1).as_string.should eq("y")

    variant = w147_string_uint64_type
    map_parent_type = CrystalClick::BinaryDataType.map(
      CrystalClick::BinaryDataType.primitive("UInt8"),
      variant
    )
    map_parent_value = CrystalClick::BinaryValue.map(map_parent_type, [
      CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[0x07_u8]),
      CrystalClick::BinaryValue.variant(variant, 0, CrystalClick::BinaryValue.string("x")),
    ] of CrystalClick::BinaryValue)
    map_parent_wire = Bytes[0x01_u8, 0x07_u8, 0x00_u8, 0x01_u8, 0x78_u8]
    CrystalClick::BinaryValueCodec.encode_value(map_parent_value).should eq(map_parent_wire)
    decoded_parent = CrystalClick::BinaryValueCodec.decode_value(map_parent_type, map_parent_wire)
    decoded_parent.element_at(1).variant_child?.not_nil!.as_string.should eq("x")
  end

  it "composes Variant through the existing Array and Tuple logical codecs" do
    variant = w147_string_uint64_type
    string_value = CrystalClick::BinaryValue.variant(variant, 0, CrystalClick::BinaryValue.string("x"))
    null_value = CrystalClick::BinaryValue.variant_null(variant)

    array_type = CrystalClick::BinaryDataType.array(variant)
    array_value = CrystalClick::BinaryValue.array(array_type, [string_value, null_value])
    array_wire = Bytes[0x02_u8, 0x00_u8, 0x01_u8, 0x78_u8, 0xff_u8]
    CrystalClick::BinaryDataTypeCodec.encode(array_type).should eq(
      Bytes[0x1e_u8, 0x2a_u8, 0x02_u8, 0x15_u8, 0x04_u8]
    )
    CrystalClick::BinaryValueCodec.encode_value(array_value).should eq(array_wire)
    decoded_array = CrystalClick::BinaryValueCodec.decode_value(array_type, array_wire)
    decoded_array.element_count.should eq(2)
    decoded_array.element_at(0).variant_child?.not_nil!.as_string.should eq("x")
    decoded_array.element_at(1).is_null?.should be_true

    tuple_type = CrystalClick::BinaryDataType.tuple([
      variant,
      CrystalClick::BinaryDataType.primitive("UInt8"),
    ] of CrystalClick::BinaryDataType)
    tuple_value = CrystalClick::BinaryValue.tuple(tuple_type, [
      string_value,
      CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[0x07_u8]),
    ] of CrystalClick::BinaryValue)
    tuple_wire = Bytes[0x00_u8, 0x01_u8, 0x78_u8, 0x07_u8]
    CrystalClick::BinaryDataTypeCodec.encode(tuple_type).should eq(
      Bytes[0x1f_u8, 0x02_u8, 0x2a_u8, 0x02_u8, 0x15_u8, 0x04_u8, 0x01_u8]
    )
    CrystalClick::BinaryValueCodec.encode_value(tuple_value).should eq(tuple_wire)
    CrystalClick::BinaryValueCodec.decode_value(tuple_type, tuple_wire).element_at(0).type.should eq(variant)
  end

  it "keeps empty Array(Nothing) logical while rejecting a nonempty Nothing scalar" do
    nothing = CrystalClick::BinaryDataType.primitive("Nothing")
    array_type = CrystalClick::BinaryDataType.array(nothing)
    empty = CrystalClick::BinaryValue.array(array_type, [] of CrystalClick::BinaryValue)

    CrystalClick::BinaryValueCodec.encode_value(empty).should eq(Bytes[0x00_u8])
    CrystalClick::BinaryValueCodec.decode_value(array_type, Bytes[0x00_u8]).element_count.should eq(0)

    nonempty = CrystalClick::BinaryValue.array(array_type, [CrystalClick::BinaryValue.null(nothing)])
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode_value(nonempty)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.decode_value(array_type, Bytes[0x01_u8])
    end
  end

  it "shares the exact aggregate depth, node, edge, and byte budget across descriptor and value" do
    type = w147_string_uint64_type
    value = CrystalClick::BinaryValue.variant(type, 0, CrystalClick::BinaryValue.string("x"))
    wire = Bytes[0x2a_u8, 0x02_u8, 0x15_u8, 0x04_u8, 0x00_u8, 0x01_u8, 0x78_u8]
    encode_exact = w147_limits(max_depth: 2, max_nodes: 5, max_elements: 3, max_bytes: 7)
    decode_exact = w147_limits(max_depth: 2, max_nodes: 7, max_elements: 3, max_bytes: 71)

    CrystalClick::BinaryValueCodec.encode(value, encode_exact).should eq(wire)
    decoded = CrystalClick::BinaryValueCodec.decode(wire, decode_exact)
    decoded.type.should eq(type)
    decoded.variant_child?.not_nil!.as_string.should eq("x")

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode(value, w147_limits(max_depth: 1, max_nodes: 5, max_elements: 3, max_bytes: 7))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode(wire, w147_limits(max_depth: 1, max_nodes: 7, max_elements: 3, max_bytes: 71))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode(value, w147_limits(max_depth: 2, max_nodes: 4, max_elements: 3, max_bytes: 7))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode(wire, w147_limits(max_depth: 2, max_nodes: 6, max_elements: 3, max_bytes: 71))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode(value, w147_limits(max_depth: 2, max_nodes: 5, max_elements: 2, max_bytes: 7))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode(wire, w147_limits(max_depth: 2, max_nodes: 7, max_elements: 2, max_bytes: 71))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode(value, w147_limits(max_depth: 2, max_nodes: 5, max_elements: 3, max_bytes: 6))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode(wire, w147_limits(max_depth: 2, max_nodes: 7, max_elements: 3, max_bytes: 70))
    end
  end

  it "applies recursive type-name bounds to the complete Variant name" do
    type = w147_string_uint64_type
    exact_budget = CrystalClick::BinaryCodecBudget.new(w147_limits(max_bytes: 4_096), true)
    bounds = CrystalClick::BinaryTypeNameBudget.measure(type, exact_budget)
    name = CrystalClick::BinaryTypeNameBudget.materialize(type, exact_budget, bounds)

    name.should eq("Variant(String, UInt64)")
    name.bytesize.to_u64.should be <= bounds[0]

    one_short = CrystalClick::BinaryCodecBudget.new(w147_limits(max_bytes: bounds[1].to_i - 1), true)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryTypeNameBudget.materialize(type, one_short, bounds)
    end

    arms = [
      CrystalClick::BinaryDataType.primitive("String"),
      CrystalClick::BinaryDataType.primitive("UInt64"),
    ] of CrystalClick::BinaryDataType
    constructor_exact = w147_limits(max_depth: 2, max_nodes: 3, max_elements: 2, max_bytes: 64)
    CrystalClick::BinaryDataType.variant(arms, limits: constructor_exact).name.should eq(type.name)

    [
      w147_limits(max_depth: 1, max_nodes: 3, max_elements: 2, max_bytes: 64),
      w147_limits(max_depth: 2, max_nodes: 2, max_elements: 2, max_bytes: 64),
      w147_limits(max_depth: 2, max_nodes: 3, max_elements: 1, max_bytes: 64),
      w147_limits(max_depth: 2, max_nodes: 3, max_elements: 2, max_bytes: 63),
    ].each do |one_short_limits|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryDataType.variant(arms, limits: one_short_limits)
      end
    end
  end
end
