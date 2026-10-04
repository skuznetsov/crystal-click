require "./spec_helper"

private def w141_limits(
  max_depth : Int = 64,
  max_nodes : Int = 4_096,
  max_elements : Int = 1_000_000,
  max_bytes : Int = 64 * 1024 * 1024,
) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: max_depth,
    max_nodes: max_nodes,
    max_elements: max_elements,
    max_bytes: max_bytes,
  )
end

private def w141_low_cardinality_descriptor(child : Bytes) : Bytes
  bytes = [0x26_u8] of UInt8
  child.each { |byte| bytes << byte }
  Bytes.new(bytes.size) { |index| bytes[index] }
end

private def w141_expect_borrowed_low_cardinality_refusal(value : CrystalClick::BinaryValue) : Nil
  wire = CrystalClick::BinaryValueCodec.encode(value)
  limits = CrystalClick::BinaryCodecLimits.default

  expect_raises(CrystalClick::UnsupportedFormatError) do
    CrystalClick::BinaryValueCodec.encode_borrowed(
      value,
      CrystalClick::BinaryCodecBudget.new(limits, true),
    )
  end
  expect_raises(CrystalClick::UnsupportedFormatError) do
    CrystalClick::BinaryValueCodec.decode_borrowed(
      wire,
      CrystalClick::BinaryCodecBudget.new(limits, false),
    )
  end
end

describe "W141 nominal LowCardinality binary value prerequisite" do
  it "keeps LowCardinality(String) nominal while its RowBinary child is a String" do
    string_type = CrystalClick::BinaryDataType.primitive("String")
    descriptor = Bytes[0x26_u8, 0x15_u8]
    wire = Bytes[0x26_u8, 0x15_u8, 0x01_u8, 0x78_u8]

    type = CrystalClick::BinaryDataTypeCodec.decode(descriptor)
    type.name.should eq("LowCardinality(String)")
    type.tag.should eq(0x26_u8)
    type.child_at(0).should eq(string_type)
    type.should_not eq(string_type)
    CrystalClick::BinaryDataTypeCodec.encode(type).should eq(descriptor)

    value = CrystalClick::BinaryValueCodec.decode(wire)
    value.type.should eq(type)
    value.type.should_not eq(string_type)
    value.child_count.should eq(1)
    value.child_at(0).type.should eq(string_type)
    value.child_at(0).as_string.should eq("x")
    CrystalClick::BinaryValueCodec.encode(value).should eq(wire)
  end

  it "preserves the Nullable child inside LowCardinality for NULL and non-NULL RowBinary values" do
    string_type = CrystalClick::BinaryDataType.primitive("String")
    nullable_string_type = CrystalClick::BinaryDataType.nullable(string_type)
    descriptor = Bytes[0x26_u8, 0x23_u8, 0x15_u8]
    null_wire = Bytes[0x26_u8, 0x23_u8, 0x15_u8, 0x01_u8]
    value_wire = Bytes[0x26_u8, 0x23_u8, 0x15_u8, 0x00_u8, 0x01_u8, 0x78_u8]

    type = CrystalClick::BinaryDataTypeCodec.decode(descriptor)
    type.name.should eq("LowCardinality(Nullable(String))")
    type.child_at(0).should eq(nullable_string_type)
    type.should_not eq(nullable_string_type)
    CrystalClick::BinaryDataTypeCodec.encode(type).should eq(descriptor)

    null_value = CrystalClick::BinaryValueCodec.decode(null_wire)
    null_value.type.should eq(type)
    null_value.child_count.should eq(1)
    null_value.child_at(0).type.should eq(nullable_string_type)
    null_value.child_at(0).is_null?.should be_true
    CrystalClick::BinaryValueCodec.encode(null_value).should eq(null_wire)

    nonnull_value = CrystalClick::BinaryValueCodec.decode(value_wire)
    nonnull_value.type.should eq(type)
    nullable_value = nonnull_value.child_at(0)
    nullable_value.type.should eq(nullable_string_type)
    nullable_value.is_null?.should be_false
    nullable_value.child_at(0).as_string.should eq("x")
    CrystalClick::BinaryValueCodec.encode(nonnull_value).should eq(value_wire)
  end

  it "admits only source-approved scalar leaves and rejects invalid or nested wrapper shapes" do
    string_type = CrystalClick::BinaryDataType.primitive("String")
    enum_entries = [{"one", 1_i16}] of CrystalClick::BinaryEnumDefinition::Entry
    illegal_children = [
      CrystalClick::BinaryDataType.array(string_type),
      CrystalClick::BinaryDataType.tuple([string_type] of CrystalClick::BinaryDataType),
      CrystalClick::BinaryDataType.tuple([string_type] of CrystalClick::BinaryDataType, ["field"] of String),
      CrystalClick::BinaryDataType.map(string_type, string_type),
      CrystalClick::BinaryDataType.enum8(enum_entries),
      CrystalClick::BinaryDataType.enum16(enum_entries),
      CrystalClick::BinaryDataType.decimal(32, 9, 2),
      CrystalClick::BinaryDataType.datetime64(3),
      CrystalClick::BinaryDataType.datetime64(3, "UTC"),
      CrystalClick::BinaryDataType.time64(3),
      CrystalClick::BinaryDataType.primitive("Nothing"),
      CrystalClick::BinaryDataType.low_cardinality(string_type),
    ] of CrystalClick::BinaryDataType

    illegal_children.each do |child_type|
      expect_raises(ArgumentError) do
        CrystalClick::BinaryDataType.low_cardinality(child_type)
      end
      expect_raises(CrystalClick::CorruptPartError) do
        child_descriptor = CrystalClick::BinaryDataTypeCodec.encode(child_type)
        CrystalClick::BinaryDataTypeCodec.decode(w141_low_cardinality_descriptor(child_descriptor))
      end
    end

    # Nullable(LowCardinality(String)) is not interchangeable with the
    # source-admitted LowCardinality(Nullable(String)) shape above.
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.low_cardinality(string_type))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x23_u8, 0x26_u8, 0x15_u8])
    end

    low_cardinality_nullable = CrystalClick::BinaryDataType.low_cardinality(
      CrystalClick::BinaryDataType.nullable(string_type)
    )
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.map(low_cardinality_nullable, string_type)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x27_u8, 0x26_u8, 0x23_u8, 0x15_u8, 0x15_u8])
    end
  end

  it "admits exactly the represented scalar leaf families confirmed by the source constructor" do
    leaves = [
      "UInt8", "UInt16", "UInt32", "UInt64", "UInt128", "UInt256",
      "Int8", "Int16", "Int32", "Int64", "Int128", "Int256",
      "Float32", "Float64", "Bool", "BFloat16", "String", "Date",
      "Date32", "Time", "UUID", "IPv4", "IPv6",
    ].map { |name| CrystalClick::BinaryDataType.primitive(name) }
    leaves << CrystalClick::BinaryDataType.fixed_string(3)
    leaves << CrystalClick::BinaryDataType.datetime
    leaves << CrystalClick::BinaryDataType.datetime("UTC")
    leaves.each do |leaf|
      type = CrystalClick::BinaryDataType.low_cardinality(leaf)
      decoded = CrystalClick::BinaryDataTypeCodec.decode(CrystalClick::BinaryDataTypeCodec.encode(type))
      decoded.should eq(type)
      decoded.tag.should eq(0x26_u8)
      decoded.child_at(0).should eq(leaf)
    end
  end

  it "keeps one nominal LowCardinality node through Array, Tuple, named Tuple, and Map row values" do
    string_type = CrystalClick::BinaryDataType.primitive("String")
    low_cardinality_type = CrystalClick::BinaryDataType.low_cardinality(string_type)
    low_cardinality_value = CrystalClick::BinaryValue.low_cardinality(
      low_cardinality_type,
      CrystalClick::BinaryValue.string("v")
    )

    expect_raises(ArgumentError) do
      CrystalClick::BinaryValue.low_cardinality(low_cardinality_type, CrystalClick::BinaryValue.int64(1_i64))
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryValue.low_cardinality(string_type, CrystalClick::BinaryValue.string("v"))
    end
    fixed_one = CrystalClick::BinaryDataType.fixed_string(1)
    fixed_two = CrystalClick::BinaryDataType.fixed_string(2)
    fixed_two_low_cardinality = CrystalClick::BinaryDataType.low_cardinality(fixed_two)
    expect_raises(ArgumentError) do
      CrystalClick::BinaryValue.low_cardinality(
        fixed_two_low_cardinality,
        CrystalClick::BinaryValue.fixed(fixed_one, Bytes[0x61_u8])
      )
    end

    source_payload = Bytes[0x61_u8]
    owned_child = CrystalClick::BinaryValue.fixed(fixed_one, source_payload)
    source_payload[0] = 0x62_u8
    fixed_low_cardinality = CrystalClick::BinaryDataType.low_cardinality(fixed_one)
    owned_value = CrystalClick::BinaryValue.low_cardinality(fixed_low_cardinality, owned_child)
    detached_payload = owned_value.child_at(0).bytes
    detached_payload[0] = 0x63_u8
    owned_value.child_at(0).bytes.should eq(Bytes[0x61_u8])

    array_type = CrystalClick::BinaryDataType.array(low_cardinality_type)
    array_value = CrystalClick::BinaryValue.array(array_type, [low_cardinality_value] of CrystalClick::BinaryValue)
    array_wire = Bytes[0x1e_u8, 0x26_u8, 0x15_u8, 0x01_u8, 0x01_u8, 0x76_u8]
    CrystalClick::BinaryValueCodec.encode(array_value).should eq(array_wire)
    decoded_array = CrystalClick::BinaryValueCodec.decode(array_wire)
    decoded_array.type.should eq(array_type)
    decoded_array.child_at(0).type.should eq(low_cardinality_type)
    decoded_array.child_at(0).child_at(0).as_string.should eq("v")

    tuple_type = CrystalClick::BinaryDataType.tuple([low_cardinality_type] of CrystalClick::BinaryDataType)
    tuple_value = CrystalClick::BinaryValue.tuple(tuple_type, [low_cardinality_value] of CrystalClick::BinaryValue)
    tuple_wire = Bytes[0x1f_u8, 0x01_u8, 0x26_u8, 0x15_u8, 0x01_u8, 0x76_u8]
    CrystalClick::BinaryValueCodec.encode(tuple_value).should eq(tuple_wire)
    decoded_tuple = CrystalClick::BinaryValueCodec.decode(tuple_wire)
    decoded_tuple.type.should eq(tuple_type)
    decoded_tuple.child_at(0).type.should eq(low_cardinality_type)
    decoded_tuple.child_at(0).child_at(0).as_string.should eq("v")

    named_tuple_type = CrystalClick::BinaryDataType.tuple(
      [low_cardinality_type] of CrystalClick::BinaryDataType,
      ["field"] of String
    )
    named_tuple_value = CrystalClick::BinaryValue.tuple(named_tuple_type, [low_cardinality_value] of CrystalClick::BinaryValue)
    named_tuple_wire = Bytes[0x20_u8, 0x01_u8, 0x05_u8, 0x66_u8, 0x69_u8, 0x65_u8, 0x6c_u8, 0x64_u8, 0x26_u8, 0x15_u8, 0x01_u8, 0x76_u8]
    CrystalClick::BinaryValueCodec.encode(named_tuple_value).should eq(named_tuple_wire)
    decoded_named_tuple = CrystalClick::BinaryValueCodec.decode(named_tuple_wire)
    decoded_named_tuple.type.should eq(named_tuple_type)
    decoded_named_tuple.child_at(0).type.should eq(low_cardinality_type)
    decoded_named_tuple.child_at(0).child_at(0).as_string.should eq("v")

    map_value_type = CrystalClick::BinaryDataType.map(string_type, low_cardinality_type)
    map_value = CrystalClick::BinaryValue.map(map_value_type, [
      CrystalClick::BinaryValue.string("k"), low_cardinality_value,
    ] of CrystalClick::BinaryValue)
    map_value_wire = Bytes[0x27_u8, 0x15_u8, 0x26_u8, 0x15_u8, 0x01_u8, 0x01_u8, 0x6b_u8, 0x01_u8, 0x76_u8]
    CrystalClick::BinaryValueCodec.encode(map_value).should eq(map_value_wire)
    decoded_map_value = CrystalClick::BinaryValueCodec.decode(map_value_wire)
    decoded_map_value.type.should eq(map_value_type)
    decoded_map_value.child_at(0).as_string.should eq("k")
    decoded_map_value.child_at(1).type.should eq(low_cardinality_type)
    decoded_map_value.child_at(1).child_at(0).as_string.should eq("v")

    # ClickHouse permits a non-nullable LowCardinality key. Nullable(LC) and
    # LC(Nullable) key shapes are rejected separately above.
    map_key_type = CrystalClick::BinaryDataType.map(low_cardinality_type, string_type)
    map_key = CrystalClick::BinaryValue.map(map_key_type, [
      low_cardinality_value, CrystalClick::BinaryValue.string("value"),
    ] of CrystalClick::BinaryValue)
    decoded_map_key = CrystalClick::BinaryValueCodec.decode(CrystalClick::BinaryValueCodec.encode(map_key))
    decoded_map_key.type.should eq(map_key_type)
    decoded_map_key.child_at(0).type.should eq(low_cardinality_type)
    decoded_map_key.child_at(0).child_at(0).as_string.should eq("v")
    decoded_map_key.child_at(1).as_string.should eq("value")
  end

  it "preserves native Bool and BFloat16 LowCardinality row tags and payloads" do
    bool_type = CrystalClick::BinaryDataType.low_cardinality(CrystalClick::BinaryDataType.primitive("Bool"))
    bool_value = CrystalClick::BinaryValue.low_cardinality(bool_type, CrystalClick::BinaryValue.bool(true))
    bool_wire = Bytes[0x26_u8, 0x2d_u8, 0x01_u8]
    CrystalClick::BinaryValueCodec.encode(bool_value).should eq(bool_wire)
    decoded_bool = CrystalClick::BinaryValueCodec.decode(bool_wire)
    decoded_bool.type.should eq(bool_type)
    decoded_bool.child_at(0).as_bool.should be_true

    bfloat_type = CrystalClick::BinaryDataType.primitive("BFloat16")
    low_cardinality_bfloat_type = CrystalClick::BinaryDataType.low_cardinality(bfloat_type)
    bfloat_value = CrystalClick::BinaryValue.low_cardinality(
      low_cardinality_bfloat_type,
      CrystalClick::BinaryValue.fixed(bfloat_type, Bytes[0xc0_u8, 0x3f_u8])
    )
    bfloat_wire = Bytes[0x26_u8, 0x31_u8, 0xc0_u8, 0x3f_u8]
    CrystalClick::BinaryValueCodec.encode(bfloat_value).should eq(bfloat_wire)
    decoded_bfloat = CrystalClick::BinaryValueCodec.decode(bfloat_wire)
    decoded_bfloat.type.should eq(low_cardinality_bfloat_type)
    decoded_bfloat.child_at(0).bytes.should eq(Bytes[0xc0_u8, 0x3f_u8])
  end

  it "keeps borrowed persisted-envelope consumers outside LowCardinality, including nested and empty lanes" do
    string_type = CrystalClick::BinaryDataType.primitive("String")
    low_cardinality_type = CrystalClick::BinaryDataType.low_cardinality(string_type)
    low_cardinality_value = CrystalClick::BinaryValue.low_cardinality(
      low_cardinality_type,
      CrystalClick::BinaryValue.string("v")
    )
    w141_expect_borrowed_low_cardinality_refusal(low_cardinality_value)

    array_type = CrystalClick::BinaryDataType.array(low_cardinality_type)
    empty_array = CrystalClick::BinaryValue.array(array_type, [] of CrystalClick::BinaryValue)
    w141_expect_borrowed_low_cardinality_refusal(empty_array)

    tuple_type = CrystalClick::BinaryDataType.tuple([string_type, low_cardinality_type] of CrystalClick::BinaryDataType)
    tuple_value = CrystalClick::BinaryValue.tuple(tuple_type, [
      CrystalClick::BinaryValue.string("prefix"), low_cardinality_value,
    ] of CrystalClick::BinaryValue)
    w141_expect_borrowed_low_cardinality_refusal(tuple_value)

    map_type = CrystalClick::BinaryDataType.map(string_type, low_cardinality_type)
    map_value = CrystalClick::BinaryValue.map(map_type, [
      CrystalClick::BinaryValue.string("key"), low_cardinality_value,
    ] of CrystalClick::BinaryValue)
    w141_expect_borrowed_low_cardinality_refusal(map_value)
  end

  it "keeps Object shared MAP and Dynamic SharedVariant borrowed callers outside LowCardinality" do
    string_type = CrystalClick::BinaryDataType.primitive("String")
    low_cardinality_type = CrystalClick::BinaryDataType.low_cardinality(string_type)
    low_cardinality_value = CrystalClick::BinaryValue.low_cardinality(
      low_cardinality_type,
      CrystalClick::BinaryValue.string("v")
    )

    object_row = CrystalClick::ObjectSharedMapRow.new([
      CrystalClick::ObjectSharedMapEntry.new(Bytes[0x61_u8], low_cardinality_value),
    ] of CrystalClick::ObjectSharedMapEntry)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectSharedMapCodec.encode([object_row] of CrystalClick::ObjectSharedMapRow)
    end

    # One row, one path "a", and a length-delimited LC(String) envelope.
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectSharedMapCodec.decode(
        Bytes[0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8],
        Bytes[0x01_u8, 0x61_u8],
        Bytes[0x04_u8, 0x26_u8, 0x15_u8, 0x01_u8, 0x76_u8],
        1
      )
    end

    empty_structure = CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::DynamicValueCodec.encode(
        empty_structure,
        [[low_cardinality_value] of CrystalClick::BinaryValue] of Array(CrystalClick::BinaryValue)
      )
    end

    # The sole canonical Dynamic arm is SharedVariant (tag zero). Its ordinary
    # String lane carries one row containing the LC envelope above.
    discriminator = CrystalClick::DynamicDiscriminatorStream.new(
      Bytes[
        0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
        0x01_u8, 0x01_u8, 0x00_u8,
      ],
      [
        CrystalClick::DynamicDiscriminatorMark.new(8_u64, 1_u64),
        CrystalClick::DynamicDiscriminatorMark.new(11_u64, 0_u64),
      ] of CrystalClick::DynamicDiscriminatorMark
    )
    shared = CrystalClick::BinaryBulkStreams.new(
      mark_count: 1,
      streams: {
        "root.data" => CrystalClick::BinaryBulkStream.new(
          Bytes[0x04_u8, 0x26_u8, 0x15_u8, 0x01_u8, 0x76_u8],
          [0_u64, 5_u64]
        ),
      } of String => CrystalClick::BinaryBulkStream
    )
    dynamic_streams = CrystalClick::DynamicValueStreams.new(
      discriminator,
      {"SharedVariant" => shared} of String => CrystalClick::BinaryBulkStreams
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::DynamicValueCodec.decode(empty_structure, dynamic_streams)
    end
  end

  it "charges the LowCardinality descriptor node, edge, depth, and bytes at exact bounds" do
    string_type = CrystalClick::BinaryDataType.primitive("String")
    descriptor = Bytes[0x26_u8, 0x15_u8]
    type = CrystalClick::BinaryDataTypeCodec.decode(descriptor)
    exact = w141_limits(max_depth: 2, max_nodes: 2, max_elements: 1, max_bytes: 2)

    CrystalClick::BinaryDataTypeCodec.decode(descriptor, exact).should eq(type)
    CrystalClick::BinaryDataTypeCodec.encode(type, exact).should eq(descriptor)
    type.child_at(0).should eq(string_type)

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(descriptor, w141_limits(max_depth: 1, max_nodes: 2, max_elements: 1, max_bytes: 2))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(descriptor, w141_limits(max_depth: 2, max_nodes: 1, max_elements: 1, max_bytes: 2))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(descriptor, w141_limits(max_depth: 2, max_nodes: 2, max_elements: 0, max_bytes: 2))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(descriptor, w141_limits(max_depth: 2, max_nodes: 2, max_elements: 1, max_bytes: 1))
    end

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.encode(type, w141_limits(max_depth: 1, max_nodes: 2, max_elements: 1, max_bytes: 2))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.encode(type, w141_limits(max_depth: 2, max_nodes: 1, max_elements: 1, max_bytes: 2))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.encode(type, w141_limits(max_depth: 2, max_nodes: 2, max_elements: 0, max_bytes: 2))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.encode(type, w141_limits(max_depth: 2, max_nodes: 2, max_elements: 1, max_bytes: 1))
    end
  end

  it "charges both descriptor and child value visits in the combined envelope budget" do
    wire = Bytes[0x26_u8, 0x15_u8, 0x01_u8, 0x78_u8]
    exact = w141_limits(max_depth: 2, max_nodes: 4, max_elements: 2, max_bytes: 4)
    value = CrystalClick::BinaryValueCodec.decode(wire, exact)

    value.type.name.should eq("LowCardinality(String)")
    value.child_at(0).as_string.should eq("x")
    CrystalClick::BinaryValueCodec.encode(value, exact).should eq(wire)

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode(wire, w141_limits(max_depth: 1, max_nodes: 4, max_elements: 2, max_bytes: 4))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode(wire, w141_limits(max_depth: 2, max_nodes: 3, max_elements: 2, max_bytes: 4))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode(wire, w141_limits(max_depth: 2, max_nodes: 4, max_elements: 1, max_bytes: 4))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode(wire, w141_limits(max_depth: 2, max_nodes: 4, max_elements: 2, max_bytes: 3))
    end

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode(value, w141_limits(max_depth: 1, max_nodes: 4, max_elements: 2, max_bytes: 4))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode(value, w141_limits(max_depth: 2, max_nodes: 3, max_elements: 2, max_bytes: 4))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode(value, w141_limits(max_depth: 2, max_nodes: 4, max_elements: 1, max_bytes: 4))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode(value, w141_limits(max_depth: 2, max_nodes: 4, max_elements: 2, max_bytes: 3))
    end
  end

  it "charges the Nullable child path of LowCardinality at exact bounds" do
    descriptor = Bytes[0x26_u8, 0x23_u8, 0x15_u8]
    null_wire = Bytes[0x26_u8, 0x23_u8, 0x15_u8, 0x01_u8]
    value_wire = Bytes[0x26_u8, 0x23_u8, 0x15_u8, 0x00_u8, 0x01_u8, 0x78_u8]

    # Descriptor: three nodes/two edges; NULL value: two visits/one edge.
    null_exact = w141_limits(max_depth: 3, max_nodes: 5, max_elements: 3, max_bytes: 4)
    null_value = CrystalClick::BinaryValueCodec.decode(null_wire, null_exact)
    CrystalClick::BinaryValueCodec.encode(null_value, null_exact).should eq(null_wire)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode(null_wire, w141_limits(max_depth: 2, max_nodes: 5, max_elements: 3, max_bytes: 4))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode(null_value, w141_limits(max_depth: 2, max_nodes: 5, max_elements: 3, max_bytes: 4))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode(null_wire, w141_limits(max_depth: 3, max_nodes: 4, max_elements: 3, max_bytes: 4))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode(null_value, w141_limits(max_depth: 3, max_nodes: 4, max_elements: 3, max_bytes: 4))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode(null_wire, w141_limits(max_depth: 3, max_nodes: 5, max_elements: 2, max_bytes: 4))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode(null_value, w141_limits(max_depth: 3, max_nodes: 5, max_elements: 2, max_bytes: 4))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode(null_wire, w141_limits(max_depth: 3, max_nodes: 5, max_elements: 3, max_bytes: 3))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode(null_value, w141_limits(max_depth: 3, max_nodes: 5, max_elements: 3, max_bytes: 3))
    end

    # Non-NULL additionally visits the String child and consumes its payload.
    value_exact = w141_limits(max_depth: 3, max_nodes: 6, max_elements: 4, max_bytes: 6)
    value = CrystalClick::BinaryValueCodec.decode(value_wire, value_exact)
    value.child_at(0).child_at(0).as_string.should eq("x")
    CrystalClick::BinaryValueCodec.encode(value, value_exact).should eq(value_wire)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode(value_wire, w141_limits(max_depth: 3, max_nodes: 6, max_elements: 4, max_bytes: 5))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode(value, w141_limits(max_depth: 3, max_nodes: 6, max_elements: 4, max_bytes: 5))
    end

    # Keep descriptor exact consumption independently paired on both paths.
    type = CrystalClick::BinaryDataTypeCodec.decode(descriptor)
    type.name.should eq("LowCardinality(Nullable(String))")
    CrystalClick::BinaryDataTypeCodec.encode(type).should eq(descriptor)
  end

  it "preflights the recursive LowCardinality type-name bound before materializing it" do
    leaf = CrystalClick::BinaryDataType.fixed_string(CrystalClick::BinaryDataType::MAX_FIXED_STRING)
    type = CrystalClick::BinaryDataType.low_cardinality(CrystalClick::BinaryDataType.nullable(leaf))
    limits = w141_limits(max_bytes: 4_096)
    budget = CrystalClick::BinaryCodecBudget.new(limits, true)
    bounds = CrystalClick::BinaryTypeNameBudget.measure(type, budget)

    name = CrystalClick::BinaryTypeNameBudget.materialize(type, budget, bounds)
    name.should eq("LowCardinality(Nullable(FixedString(16777215)))")
    name.bytesize.to_u64.should eq(bounds[0])

    one_short = CrystalClick::BinaryCodecBudget.new(w141_limits(max_bytes: bounds[1].to_i - 1), true)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryTypeNameBudget.materialize(type, one_short, bounds)
    end
  end

  it "rejects truncated, trailing, and malformed LowCardinality descriptor or row bytes" do
    type = CrystalClick::BinaryDataType.low_cardinality(CrystalClick::BinaryDataType.primitive("String"))
    wire = Bytes[0x26_u8, 0x15_u8, 0x01_u8, 0x78_u8]

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x26_u8])
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode(wire[0, wire.size - 1])
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode(Bytes[0x26_u8, 0x15_u8, 0x01_u8, 0x78_u8, 0_u8])
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_value(type, Bytes[0x01_u8, 0x78_u8, 0_u8])
    end
  end

  it "admits declared LC leaves while ordinary bulk accepts the scalar LC kernel" do
    descriptor = Bytes[0x26_u8, 0x15_u8]
    wire = Bytes[0x26_u8, 0x15_u8, 0x01_u8, 0x78_u8]
    type = CrystalClick::BinaryDataTypeCodec.decode(descriptor)
    value = CrystalClick::BinaryValueCodec.decode(wire)

    CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(v LowCardinality(String))").declaration.should eq(
      "JSON(v LowCardinality(String))"
    )
    CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(v LowCardinality(Nullable(String)))").declaration.should eq(
      "JSON(v LowCardinality(Nullable(String)))"
    )
    # Map keys are still constrained to String by the typed Object grammar.
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(v Map(LowCardinality(Nullable(String)), String))")
    end
    encoded = CrystalClick::BinaryBulkCodec.encode(type, [[value]] of Array(CrystalClick::BinaryValue))
    encoded.roles.should eq(["root.dictionary", "root.indexes"])
    decoded = CrystalClick::BinaryBulkCodec.decode(type, encoded, [1_u64])
    decoded[0][0].child_at(0).as_string.should eq("x")
  end

  it "separates LC Nullable metadata refusal from the unchanged Dynamic physical LowCardinality fence" do
    string_type = CrystalClick::BinaryDataType.primitive("String")
    low_cardinality_string = CrystalClick::BinaryDataType.low_cardinality(string_type)
    long_zone = "America/Argentina/Buenos_Aires"
    low_cardinality_nullable_datetime = CrystalClick::BinaryDataType.low_cardinality(
      CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.datetime(long_zone))
    )
    metadata_error = expect_raises(ArgumentError) do
      CrystalClick::DynamicStructure.new([low_cardinality_nullable_datetime] of CrystalClick::BinaryDataType)
    end
    metadata_error.message.should eq("LowCardinality(Nullable) alternatives are not admitted in Dynamic V3")

    candidates = [
      low_cardinality_string,
      CrystalClick::BinaryDataType.array(low_cardinality_string),
      CrystalClick::BinaryDataType.array(low_cardinality_nullable_datetime),
    ] of CrystalClick::BinaryDataType

    candidates.each do |type|
      structures = CrystalClick::ObjectDynamicStructureSet.new(
        CrystalClick::ObjectStructure.new(["v"] of String),
        {"v" => CrystalClick::DynamicStructure.new([type] of CrystalClick::BinaryDataType)}
      )
      logical = CrystalClick::ObjectDocumentPlan.new(
        structures,
        {} of String => CrystalClick::BinaryDataType
      )
      error = expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentPhysicalPlan.new("doc", logical)
      end
      error.to_s.should contain("physical Object Dynamic LowCardinality alternatives are not admitted")
    end
  end
end
