require "./spec_helper"

private def w147_adv_limits(
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

private def w147_adv_type : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.variant([
    CrystalClick::BinaryDataType.primitive("String"),
    CrystalClick::BinaryDataType.primitive("UInt64"),
  ] of CrystalClick::BinaryDataType)
end

private def w147_adv_dynamic_wire(type_descriptor : Bytes) : Bytes
  bytes = [
    0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    0x01_u8,
  ] of UInt8
  type_descriptor.each { |byte| bytes << byte }
  bytes << 0x00_u8
  Bytes.new(bytes.size) { |index| bytes[index] }
end

describe "W147 generic Variant adversarial boundaries" do
  it "rejects empty, oversized, duplicate, reordered, Nothing, illegal and reserved descriptor rosters" do
    malformed = [
      Bytes[0x2a_u8, 0x00_u8],                                                       # no declared arms after Nothing elision
      Bytes[0x2a_u8, 0x80_u8, 0x02_u8],                                              # 256 arms, rejected before child allocation
      Bytes[0x2a_u8, 0x82_u8, 0x00_u8, 0x15_u8, 0x04_u8],                            # nonminimal arm count
      Bytes[0x2a_u8, 0x02_u8, 0x04_u8, 0x15_u8],                                     # incoming roster is not name-canonical
      Bytes[0x2a_u8, 0x02_u8, 0x15_u8, 0x15_u8],                                     # duplicate descriptor
      Bytes[0x2a_u8, 0x02_u8, 0x00_u8, 0x15_u8],                                     # direct Nothing is not wire-canonical
      Bytes[0x2a_u8, 0x01_u8, 0x23_u8, 0x01_u8],                                     # direct Nullable
      Bytes[0x2a_u8, 0x01_u8, 0x26_u8, 0x23_u8, 0x01_u8],                            # LowCardinality(Nullable(...))
      Bytes[0x2a_u8, 0x01_u8, 0x2a_u8, 0x02_u8, 0x15_u8, 0x04_u8],                   # direct nested Variant
      Bytes[0x2a_u8, 0x01_u8, 0x33_u8],                                              # removed/reserved Time timezone tag
      Bytes[0x2a_u8, 0x01_u8, 0x35_u8],                                              # removed/reserved Time64 timezone tag
      Bytes[0x2a_u8, 0x02_u8, 0x15_u8, 0x04_u8, 0x00_u8],                            # descriptor trailer
      Bytes[0x2a_u8, 0x02_u8, 0x19_u8, 0x05_u8, 0x02_u8, 0x1a_u8, 0x05_u8, 0x02_u8], # unequal Decimal widths share one name
    ] of Bytes

    malformed.each do |descriptor|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryDataTypeCodec.decode(descriptor)
      end
    end

    [0x33_u8, 0x35_u8].each do |reserved_tag|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryDataTypeCodec.decode(Bytes[reserved_tag])
      end
    end

    # 0x37 is recognized upstream but not admitted by this kernel; it remains
    # an unsupported feature, not a malformed/reserved tag.
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x37_u8])
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x2a_u8, 0x01_u8, 0x37_u8])
    end

    descriptor = Bytes[0x2a_u8, 0x02_u8, 0x15_u8, 0x04_u8]
    (0...descriptor.size).each do |length|
      truncated = Bytes.new(length) { |index| descriptor[index] }
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryDataTypeCodec.decode(truncated)
      end
    end
  end

  it "rejects direct prohibited arms and preserves display-name collisions" do
    string = CrystalClick::BinaryDataType.primitive("String")
    nullable = CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.primitive("UInt8"))
    low_cardinality_nullable = CrystalClick::BinaryDataType.low_cardinality(
      CrystalClick::BinaryDataType.nullable(string)
    )
    nested_variant = w147_adv_type

    [nullable, low_cardinality_nullable, nested_variant].each do |arm|
      expect_raises(ArgumentError) do
        CrystalClick::BinaryDataType.variant([string, arm] of CrystalClick::BinaryDataType)
      end
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.nullable(nested_variant)
    end

    decimal32 = CrystalClick::BinaryDataType.decimal(32, 5, 2)
    decimal64 = CrystalClick::BinaryDataType.decimal(64, 5, 2)
    decimal32.name.should eq(decimal64.name)
    decimal32.should_not eq(decimal64)
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.variant([decimal32, decimal64] of CrystalClick::BinaryDataType)
    end
  end

  it "rejects bad value discriminators, malformed selected payloads and nominally wrong children" do
    type = w147_adv_type
    malformed_values = [
      Bytes.empty,                                                                   # no discriminator
      Bytes[0x02_u8],                                                                # outside two-arm roster
      Bytes[0x00_u8],                                                                # String length is truncated
      Bytes[0x00_u8, 0x81_u8, 0x00_u8],                                              # nonminimal String length
      Bytes[0x00_u8, 0x01_u8],                                                       # selected String byte is truncated
      Bytes[0x00_u8, 0x01_u8, 0x78_u8, 0x00_u8],                                     # trailing row bytes
      Bytes[0x01_u8, 0x2a_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8], # UInt64 truncated
      Bytes[0xff_u8, 0x00_u8],                                                       # NULL carries no selected payload
    ] of Bytes
    malformed_values.each do |bytes|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryValueCodec.decode_value(type, bytes)
      end
    end

    valid_values = [
      Bytes[0x00_u8, 0x01_u8, 0x78_u8],
      Bytes[0x01_u8, 0x2a_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8],
    ] of Bytes
    valid_values.each do |valid|
      (0...valid.size).each do |length|
        truncated = Bytes.new(length) { |index| valid[index] }
        expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::BinaryValueCodec.decode_value(type, truncated)
        end
      end
    end

    bool_uint8 = CrystalClick::BinaryDataType.variant([
      CrystalClick::BinaryDataType.primitive("UInt8"),
      CrystalClick::BinaryDataType.primitive("Bool"),
    ] of CrystalClick::BinaryDataType)
    decoded_bool = CrystalClick::BinaryValueCodec.decode_value(bool_uint8, Bytes[0x00_u8, 0x02_u8])
    decoded_bool.variant_child?.not_nil!.as_bool.should be_true
    CrystalClick::BinaryValueCodec.encode_value(decoded_bool).should eq(Bytes[0x00_u8, 0x01_u8])

    expect_raises(ArgumentError) do
      CrystalClick::BinaryValue.variant(type, -1, CrystalClick::BinaryValue.string("x"))
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryValue.variant(type, 2, CrystalClick::BinaryValue.string("x"))
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryValue.variant(type, 255, CrystalClick::BinaryValue.string("x"))
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryValue.variant(type, 0, CrystalClick::BinaryValue.uint64(1_u64))
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryValue.variant(type, 1, CrystalClick::BinaryValue.string("x"))
    end
  end

  it "admits 255 distinct FixedString arms but rejects arm 256" do
    arms = Array(CrystalClick::BinaryDataType).new(255) do |index|
      CrystalClick::BinaryDataType.fixed_string(index + 1)
    end
    type = CrystalClick::BinaryDataType.variant(arms)

    type.child_count.should eq(255)
    encoded = CrystalClick::BinaryDataTypeCodec.encode(type)
    CrystalClick::BinaryDataTypeCodec.decode(encoded).should eq(type)
    selected_arm = type.child_at(254)
    selected_value = CrystalClick::BinaryValue.variant(
      type,
      254,
      CrystalClick::BinaryValue.fixed(
        selected_arm,
        Bytes.new(selected_arm.fixed_width.not_nil!) { 0x2a_u8 }
      )
    )
    selected_wire = CrystalClick::BinaryValueCodec.encode_value(selected_value)
    selected_wire[0].should eq(0xfe_u8)
    decoded_selected = CrystalClick::BinaryValueCodec.decode_value(type, selected_wire)
    decoded_selected.variant_index?.should eq(254_u8)
    decoded_selected.variant_child?.not_nil!.type.should eq(selected_arm)
    decoded_selected.variant_child?.not_nil!.bytes.should eq(selected_value.variant_child?.not_nil!.bytes)

    null_wire = CrystalClick::BinaryValueCodec.encode_value(CrystalClick::BinaryValue.variant_null(type))
    null_wire.should eq(Bytes[0xff_u8])
    decoded_null = CrystalClick::BinaryValueCodec.decode_value(type, null_wire)
    decoded_null.is_null?.should be_true
    decoded_null.variant_index?.should be_nil
    decoded_null.variant_child?.should be_nil

    too_many = arms.dup
    too_many << CrystalClick::BinaryDataType.fixed_string(256)
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.variant(too_many)
    end
  end

  it "shares recursive parent and Variant work without resetting nested budgets" do
    variant = w147_adv_type
    value = CrystalClick::BinaryValue.array(
      CrystalClick::BinaryDataType.array(variant),
      [CrystalClick::BinaryValue.variant(variant, 0, CrystalClick::BinaryValue.string("x"))] of CrystalClick::BinaryValue
    )
    wire = Bytes[
      0x1e_u8, 0x2a_u8, 0x02_u8, 0x15_u8, 0x04_u8,
      0x01_u8, 0x00_u8, 0x01_u8, 0x78_u8,
    ]
    encode_exact = w147_adv_limits(max_depth: 3, max_nodes: 7, max_elements: 5, max_bytes: 9)
    decode_exact = w147_adv_limits(max_depth: 3, max_nodes: 9, max_elements: 5, max_bytes: 73)

    CrystalClick::BinaryValueCodec.encode(value, encode_exact).should eq(wire)
    CrystalClick::BinaryValueCodec.decode(wire, decode_exact).element_at(0).variant_child?.not_nil!.as_string.should eq("x")

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode(value, w147_adv_limits(max_depth: 3, max_nodes: 7, max_elements: 5, max_bytes: 8))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode(wire, w147_adv_limits(max_depth: 3, max_nodes: 9, max_elements: 5, max_bytes: 72))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode(value, w147_adv_limits(max_depth: 2, max_nodes: 7, max_elements: 5, max_bytes: 9))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode(wire, w147_adv_limits(max_depth: 3, max_nodes: 8, max_elements: 5, max_bytes: 73))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode(value, w147_adv_limits(max_depth: 3, max_nodes: 7, max_elements: 4, max_bytes: 9))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode(wire, w147_adv_limits(max_depth: 2, max_nodes: 9, max_elements: 5, max_bytes: 73))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode(wire, w147_adv_limits(max_depth: 3, max_nodes: 8, max_elements: 5, max_bytes: 73))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode(wire, w147_adv_limits(max_depth: 3, max_nodes: 9, max_elements: 4, max_bytes: 73))
    end
  end

  it "does not widen Dynamic, borrowed, bulk or Object consumers" do
    variant = w147_adv_type
    value = CrystalClick::BinaryValue.variant(variant, 0, CrystalClick::BinaryValue.string("x"))
    array_variant = CrystalClick::BinaryDataType.array(variant)
    tuple_variant = CrystalClick::BinaryDataType.tuple([variant] of CrystalClick::BinaryDataType)
    map_variant = CrystalClick::BinaryDataType.map(CrystalClick::BinaryDataType.primitive("UInt8"), variant)

    [variant, array_variant, tuple_variant, map_variant].each do |type|
      expect_raises(ArgumentError) do
        CrystalClick::DynamicStructure.new([type] of CrystalClick::BinaryDataType)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::DynamicStructureCodec.decode(w147_adv_dynamic_wire(CrystalClick::BinaryDataTypeCodec.encode(type)))
      end
    end

    array_value = CrystalClick::BinaryValue.array(
      array_variant,
      [value] of CrystalClick::BinaryValue
    )
    tuple_value = CrystalClick::BinaryValue.tuple(
      tuple_variant,
      [value] of CrystalClick::BinaryValue
    )
    map_value = CrystalClick::BinaryValue.map(map_variant, [
      CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[0x07_u8]),
      value,
    ] of CrystalClick::BinaryValue)

    borrowed_write = CrystalClick::BinaryCodecBudget.new(w147_adv_limits, true)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode_borrowed(value, borrowed_write)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode_borrowed(array_value, CrystalClick::BinaryCodecBudget.new(w147_adv_limits, true))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode_borrowed(tuple_value, CrystalClick::BinaryCodecBudget.new(w147_adv_limits, true))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode_borrowed(map_value, CrystalClick::BinaryCodecBudget.new(w147_adv_limits, true))
    end
    borrowed_wire = Bytes[0x2a_u8, 0x02_u8, 0x15_u8, 0x04_u8, 0x00_u8, 0x01_u8, 0x78_u8]
    borrowed_read = CrystalClick::BinaryCodecBudget.new(w147_adv_limits)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.decode_borrowed(borrowed_wire, borrowed_read)
    end
    nested_borrowed_wires = [
      Bytes[0x1e_u8, 0x2a_u8, 0x02_u8, 0x15_u8, 0x04_u8, 0x01_u8, 0x00_u8, 0x01_u8, 0x78_u8],
      Bytes[0x1f_u8, 0x01_u8, 0x2a_u8, 0x02_u8, 0x15_u8, 0x04_u8, 0x00_u8, 0x01_u8, 0x78_u8],
      Bytes[0x27_u8, 0x01_u8, 0x2a_u8, 0x02_u8, 0x15_u8, 0x04_u8, 0x01_u8, 0x07_u8, 0x00_u8, 0x01_u8, 0x78_u8],
    ] of Bytes
    nested_borrowed_wires.each do |wire|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryValueCodec.decode_borrowed(wire, CrystalClick::BinaryCodecBudget.new(w147_adv_limits))
      end
    end

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkPhysicalPlan.new(variant, "v")
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkPhysicalPlan.new(array_variant, "v")
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkPhysicalPlan.new(map_variant, "v")
    end

    entry = CrystalClick::ObjectSharedMapEntry.new(path: Bytes[0x70_u8], value: value)
    row = CrystalClick::ObjectSharedMapRow.new([entry] of CrystalClick::ObjectSharedMapEntry)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectSharedMapCodec.encode([row] of CrystalClick::ObjectSharedMapRow)
    end
    nested_entry = CrystalClick::ObjectSharedMapEntry.new(path: Bytes[0x61_u8], value: array_value)
    nested_row = CrystalClick::ObjectSharedMapRow.new([nested_entry] of CrystalClick::ObjectSharedMapEntry)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectSharedMapCodec.encode([nested_row] of CrystalClick::ObjectSharedMapRow)
    end
    # Full persisted shared-MAP read wrapper: one path and one typed envelope
    # carrying Array(Variant(String, UInt64)) must be rejected before rows are
    # returned, not merely by the borrowed scalar entry point in isolation.
    nested_variant_object_values = Bytes[
      0x09_u8,                                     # 9-byte typed envelope follows
      0x1e_u8, 0x2a_u8, 0x02_u8, 0x15_u8, 0x04_u8, # Array(Variant(String, UInt64)) descriptor
      0x01_u8, 0x00_u8, 0x01_u8, 0x78_u8,          # one array element: Variant(String, UInt64) = String("x")
    ]
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectSharedMapCodec.decode(
        Bytes[0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8],
        Bytes[0x01_u8, 0x70_u8],
        nested_variant_object_values,
        1
      )
    end
    map_entry = CrystalClick::ObjectSharedMapEntry.new(path: Bytes[0x6d_u8], value: map_value)
    map_row = CrystalClick::ObjectSharedMapRow.new([map_entry] of CrystalClick::ObjectSharedMapEntry)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectSharedMapCodec.encode([map_row] of CrystalClick::ObjectSharedMapRow)
    end

    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentSchema.new({"v" => variant})
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(v Variant(String, UInt64))")
    end

    # The older exact physical plans remain unchanged; nearby generic rosters
    # do not gain their stream layouts merely because the logical codec admits
    # the type tag.
    CrystalClick::WidePart.supports_variant_type?("Variant(String, UInt64)").should be_true
    CrystalClick::WidePart.supports_variant_type?("Variant(Bool, String, UInt64)").should be_true
    CrystalClick::WidePart.supports_variant_type?("Variant(Bool, String, UInt16)").should be_false
  end
end
