require "./spec_helper"

private def w119_limits(
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

private def w119_var_uint(value : UInt64) : Bytes
  bytes = [] of UInt8
  remaining = value
  loop do
    payload = (remaining & 0x7f_u64).to_u8
    remaining >>= 7
    bytes << (remaining == 0_u64 ? payload : payload | 0x80_u8)
    break if remaining == 0_u64
  end
  Bytes.new(bytes.size) { |index| bytes[index] }
end

private def w119_concat(left : Bytes, right : Bytes) : Bytes
  Bytes.new(left.size + right.size) do |index|
    index < left.size ? left[index] : right[index - left.size]
  end
end

private def w119_corrupt_descriptor_prefixes(descriptor : Bytes) : Nil
  (0...descriptor.size).each do |length|
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(descriptor[0, length])
    end
  end
end

private def w119_corrupt_value_prefixes(type : CrystalClick::BinaryDataType, value_bytes : Bytes) : Nil
  (0...value_bytes.size).each do |length|
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_value(type, value_bytes[0, length])
    end
  end
end

private def w119_corrupt_envelope_prefixes(envelope : Bytes) : Nil
  (0...envelope.size).each do |length|
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode(envelope[0, length])
    end
  end
end

describe "W119 fixed-width binary scalar repertoire" do
  it "adds the remaining primitive leaves with exact tags and opaque raw payload bytes" do
    cases = [
      {"Date", Bytes[0x0f_u8], Bytes[0x34_u8, 0x12_u8], 2},
      {"Date32", Bytes[0x10_u8], Bytes[0x00_u8, 0x00_u8, 0x00_u8, 0x80_u8], 4},
      {"Time", Bytes[0x32_u8], Bytes[0xef_u8, 0xcd_u8, 0xab_u8, 0x89_u8], 4},
      {"UUID", Bytes[0x1d_u8], Bytes[
        0x00_u8, 0x01_u8, 0x02_u8, 0x03_u8, 0x04_u8, 0x05_u8, 0x06_u8, 0x07_u8,
        0x08_u8, 0x09_u8, 0x0a_u8, 0x0b_u8, 0x0c_u8, 0x0d_u8, 0x0e_u8, 0x0f_u8,
      ], 16},
      {"IPv4", Bytes[0x28_u8], Bytes[0x01_u8, 0x02_u8, 0x03_u8, 0x04_u8], 4},
      {"IPv6", Bytes[0x29_u8], Bytes[
        0x00_u8, 0x11_u8, 0x22_u8, 0x33_u8, 0x44_u8, 0x55_u8, 0x66_u8, 0x77_u8,
        0x88_u8, 0x99_u8, 0xaa_u8, 0xbb_u8, 0xcc_u8, 0xdd_u8, 0xee_u8, 0xff_u8,
      ], 16},
    ] of Tuple(String, Bytes, Bytes, Int32)

    cases.each do |name, descriptor, payload, width|
      type = CrystalClick::BinaryDataType.primitive(name)
      type.fixed_width.should eq(width)
      CrystalClick::BinaryDataTypeCodec.encode(type).should eq(descriptor)
      CrystalClick::BinaryDataTypeCodec.decode(descriptor).should eq(type)

      value = CrystalClick::BinaryValue.fixed(type, payload)
      CrystalClick::BinaryValueCodec.encode_value(value).should eq(payload)
      decoded = CrystalClick::BinaryValueCodec.decode_value(type, payload)
      decoded.bytes.should eq(payload)
      decoded.type.should eq(type)

      envelope = w119_concat(descriptor, payload)
      CrystalClick::BinaryValueCodec.encode(value).should eq(envelope)
      decoded_envelope = CrystalClick::BinaryValueCodec.decode(envelope)
      decoded_envelope.type.should eq(type)
      decoded_envelope.bytes.should eq(payload)
    end
  end

  it "preserves temporal tag, scale, timezone, and source-normalized empty-zone identity" do
    cases = [] of Tuple(CrystalClick::BinaryDataType, Bytes, Bytes)
    cases << {
      CrystalClick::BinaryDataType.datetime,
      Bytes[0x11_u8],
      Bytes[0x78_u8, 0x56_u8, 0x34_u8, 0x12_u8],
    }
    cases << {
      CrystalClick::BinaryDataType.datetime("UTC"),
      Bytes[0x12_u8, 0x03_u8, 0x55_u8, 0x54_u8, 0x43_u8],
      Bytes[0x78_u8, 0x56_u8, 0x34_u8, 0x12_u8],
    }
    cases << {
      CrystalClick::BinaryDataType.datetime64(0),
      Bytes[0x13_u8, 0x00_u8],
      Bytes[0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x80_u8],
    }
    cases << {
      CrystalClick::BinaryDataType.datetime64(9, "UTC"),
      Bytes[0x14_u8, 0x09_u8, 0x03_u8, 0x55_u8, 0x54_u8, 0x43_u8],
      Bytes[0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0x7f_u8],
    }
    cases << {
      CrystalClick::BinaryDataType.time64(0),
      Bytes[0x34_u8, 0x00_u8],
      Bytes[0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x80_u8],
    }
    cases << {
      CrystalClick::BinaryDataType.time64(9),
      Bytes[0x34_u8, 0x09_u8],
      Bytes[0x01_u8, 0x23_u8, 0x45_u8, 0x67_u8, 0x89_u8, 0xab_u8, 0xcd_u8, 0xef_u8],
    }

    cases.each do |type, descriptor, payload|
      CrystalClick::BinaryDataTypeCodec.encode(type).should eq(descriptor)
      CrystalClick::BinaryDataTypeCodec.decode(descriptor).should eq(type)
      type.fixed_width.should eq(payload.size)
      value = CrystalClick::BinaryValue.fixed(type, payload)
      CrystalClick::BinaryValueCodec.encode_value(value).should eq(payload)
      CrystalClick::BinaryValueCodec.decode_value(type, payload).bytes.should eq(payload)
    end

    bare_datetime = CrystalClick::BinaryDataType.datetime
    explicit_utc = CrystalClick::BinaryDataType.datetime("UTC")
    bare_datetime.should_not eq(explicit_utc)
    CrystalClick::BinaryDataTypeCodec.encode(explicit_utc).should eq(
      Bytes[0x12_u8, 0x03_u8, 0x55_u8, 0x54_u8, 0x43_u8]
    )

    empty_datetime_zone = Bytes[0x12_u8, 0x00_u8]
    decoded_empty_datetime = CrystalClick::BinaryDataTypeCodec.decode(empty_datetime_zone)
    decoded_empty_datetime.should eq(bare_datetime)
    CrystalClick::BinaryDataTypeCodec.encode(decoded_empty_datetime).should eq(Bytes[0x11_u8])

    empty_datetime64_zone = Bytes[0x14_u8, 0x03_u8, 0x00_u8]
    decoded_empty_datetime64 = CrystalClick::BinaryDataTypeCodec.decode(empty_datetime64_zone)
    decoded_empty_datetime64.should eq(CrystalClick::BinaryDataType.datetime64(3))
    CrystalClick::BinaryDataTypeCodec.encode(decoded_empty_datetime64).should eq(
      Bytes[0x13_u8, 0x03_u8]
    )

    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.datetime64(-1) }
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.datetime64(10) }
    CrystalClick::BinaryDataType.datetime64(3_i64).should eq(CrystalClick::BinaryDataType.datetime64(3))
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.time64(-1) }
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.time64(10) }
    CrystalClick::BinaryDataType.time64(3_i64).should eq(CrystalClick::BinaryDataType.time64(3))

    [
      Bytes[0x13_u8, 0x0a_u8],
      Bytes[0x14_u8, 0x0a_u8, 0x03_u8, 0x55_u8, 0x54_u8, 0x43_u8],
      Bytes[0x34_u8, 0x0a_u8],
      Bytes[0x33_u8],
      Bytes[0x35_u8],
      Bytes[0x12_u8, 0x03_u8, 0x55_u8, 0x54_u8],
    ].each do |malformed|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryDataTypeCodec.decode(malformed)
      end
    end

    unknown_zone = Bytes[0x12_u8, 0x0a_u8, 0x4e_u8, 0x6f_u8, 0x53_u8, 0x75_u8, 0x63_u8, 0x68_u8, 0x5a_u8, 0x6f_u8, 0x6e_u8, 0x65_u8]
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.decode(unknown_zone)
    end
  end

  it "keeps Decimal wire width distinct from P/S validity and fixed payload width" do
    cases = [
      {32, 9, 9, Bytes[0x19_u8, 0x09_u8, 0x09_u8], Bytes[0x01_u8, 0x23_u8, 0x45_u8, 0x67_u8]},
      {64, 18, 18, Bytes[0x1a_u8, 0x12_u8, 0x12_u8], Bytes[0x00_u8, 0x01_u8, 0x02_u8, 0x03_u8, 0x04_u8, 0x05_u8, 0x06_u8, 0x07_u8]},
      {128, 38, 38, Bytes[0x1b_u8, 0x26_u8, 0x26_u8], Bytes[
        0x00_u8, 0x01_u8, 0x02_u8, 0x03_u8, 0x04_u8, 0x05_u8, 0x06_u8, 0x07_u8,
        0x08_u8, 0x09_u8, 0x0a_u8, 0x0b_u8, 0x0c_u8, 0x0d_u8, 0x0e_u8, 0x0f_u8,
      ]},
      {256, 76, 76, Bytes[0x1c_u8, 0x4c_u8, 0x4c_u8], Bytes[
        0x00_u8, 0x01_u8, 0x02_u8, 0x03_u8, 0x04_u8, 0x05_u8, 0x06_u8, 0x07_u8,
        0x08_u8, 0x09_u8, 0x0a_u8, 0x0b_u8, 0x0c_u8, 0x0d_u8, 0x0e_u8, 0x0f_u8,
        0x10_u8, 0x11_u8, 0x12_u8, 0x13_u8, 0x14_u8, 0x15_u8, 0x16_u8, 0x17_u8,
        0x18_u8, 0x19_u8, 0x1a_u8, 0x1b_u8, 0x1c_u8, 0x1d_u8, 0x1e_u8, 0x1f_u8,
      ]},
    ] of Tuple(Int32, Int32, Int32, Bytes, Bytes)

    cases.each do |width_bits, precision, scale, descriptor, payload|
      type = CrystalClick::BinaryDataType.decimal(width_bits, precision, scale)
      type.fixed_width.should eq(width_bits // 8)
      CrystalClick::BinaryDataTypeCodec.encode(type).should eq(descriptor)
      CrystalClick::BinaryDataTypeCodec.decode(descriptor).should eq(type)

      value = CrystalClick::BinaryValue.fixed(type, payload)
      CrystalClick::BinaryValueCodec.encode_value(value).should eq(payload)
      CrystalClick::BinaryValueCodec.decode_value(type, payload).bytes.should eq(payload)
      CrystalClick::BinaryValueCodec.decode(w119_concat(descriptor, payload)).bytes.should eq(payload)
    end

    # Binary construction is width-specific, not SQL DecimalType width
    # inference: scale may exceed precision, and a wider wire tag may carry a
    # smaller precision.
    CrystalClick::BinaryDataType.decimal(32, 1, 9).should_not be_nil
    CrystalClick::BinaryDataType.decimal(256, 3, 2).should_not be_nil

    decimal32 = CrystalClick::BinaryDataType.decimal(32, 5, 2)
    decimal64 = CrystalClick::BinaryDataType.decimal(64, 5, 2)
    decimal32.name.should eq(decimal64.name)
    decimal32.should_not eq(decimal64)
    identity_set = Set(CrystalClick::BinaryDataType).new
    identity_set.add(decimal32)
    identity_set.add(decimal64)
    identity_set.size.should eq(2)

    [
      {32, 0, 0},
      {32, 10, 0},
      {32, 1, 10},
      {64, 19, 0},
      {128, 38, 39},
      {256, 77, 0},
      {16, 1, 0},
    ].each do |width, precision, scale|
      expect_raises(ArgumentError) do
        CrystalClick::BinaryDataType.decimal(width, precision, scale)
      end
    end

    [
      Bytes[0x19_u8, 0x00_u8, 0x00_u8],
      Bytes[0x19_u8, 0x0a_u8, 0x00_u8],
      Bytes[0x1a_u8, 0x12_u8, 0x13_u8],
      Bytes[0x1c_u8, 0x4c_u8, 0xff_u8],
    ].each do |malformed|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryDataTypeCodec.decode(malformed)
      end
    end
  end

  it "owns sorted Enum8/Enum16 metadata while preserving labels as opaque bytes" do
    enum8_entries = [
      {"z", 2_i16},
      {"a", -1_i16},
    ] of CrystalClick::BinaryEnumDefinition::Entry
    enum8 = CrystalClick::BinaryDataType.enum8(enum8_entries)
    enum8_wire = Bytes[
      0x17_u8, 0x02_u8,
      0x01_u8, 0x61_u8, 0xff_u8,
      0x01_u8, 0x7a_u8, 0x02_u8,
    ]
    CrystalClick::BinaryDataTypeCodec.encode(enum8).should eq(enum8_wire)
    enum8.name.should eq("Enum8('a' = -1, 'z' = 2)")
    enum8_entries.clear
    CrystalClick::BinaryDataTypeCodec.encode(enum8).should eq(enum8_wire)

    # The decoder accepts a valid unsorted table, then emits the source's
    # canonical signed-code order.
    unsorted_enum8 = Bytes[
      0x17_u8, 0x02_u8,
      0x01_u8, 0x7a_u8, 0x02_u8,
      0x01_u8, 0x61_u8, 0xff_u8,
    ]
    decoded_enum8 = CrystalClick::BinaryDataTypeCodec.decode(unsorted_enum8)
    CrystalClick::BinaryDataTypeCodec.encode(decoded_enum8).should eq(enum8_wire)

    # A decoded Enum owns label bytes rather than retaining a view into the
    # caller's mutable descriptor buffer.
    mutable_enum_wire = Bytes.new(enum8_wire.size) { |index| enum8_wire[index] }
    detached_enum = CrystalClick::BinaryDataTypeCodec.decode(mutable_enum_wire)
    mutable_enum_wire[3] = 0x78_u8
    CrystalClick::BinaryDataTypeCodec.encode(detached_enum).should eq(enum8_wire)

    enum16_entries = [
      {"high", Int16::MAX},
      {"low", Int16::MIN},
    ] of CrystalClick::BinaryEnumDefinition::Entry
    enum16 = CrystalClick::BinaryDataType.enum16(enum16_entries)
    enum16_wire = Bytes[
      0x18_u8, 0x02_u8,
      0x03_u8, 0x6c_u8, 0x6f_u8, 0x77_u8, 0x00_u8, 0x80_u8,
      0x04_u8, 0x68_u8, 0x69_u8, 0x67_u8, 0x68_u8, 0xff_u8, 0x7f_u8,
    ]
    CrystalClick::BinaryDataTypeCodec.encode(enum16).should eq(enum16_wire)
    enum16.name.should eq("Enum16('low' = -32768, 'high' = 32767)")
    CrystalClick::BinaryDataTypeCodec.decode(enum16_wire).should eq(enum16)

    empty_label = CrystalClick::BinaryDataType.enum8([
      {"", 0_i16},
    ] of CrystalClick::BinaryEnumDefinition::Entry)
    CrystalClick::BinaryDataTypeCodec.encode(empty_label).should eq(
      Bytes[0x17_u8, 0x01_u8, 0x00_u8, 0x00_u8]
    )

    opaque_label = String.new(Bytes[0xff_u8, 0x00_u8, 0x61_u8])
    opaque_type = CrystalClick::BinaryDataType.enum8([
      {opaque_label, -1_i16},
    ] of CrystalClick::BinaryEnumDefinition::Entry)
    opaque_wire = Bytes[0x17_u8, 0x01_u8, 0x03_u8, 0xff_u8, 0x00_u8, 0x61_u8, 0xff_u8]
    CrystalClick::BinaryDataTypeCodec.encode(opaque_type).should eq(opaque_wire)
    CrystalClick::BinaryDataTypeCodec.encode(CrystalClick::BinaryDataTypeCodec.decode(opaque_wire)).should eq(opaque_wire)

    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.enum8([] of CrystalClick::BinaryEnumDefinition::Entry)
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.enum8([
        {"same", 1_i16},
        {"same", 2_i16},
      ] of CrystalClick::BinaryEnumDefinition::Entry)
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.enum8([
        {"first", 1_i16},
        {"second", 1_i16},
      ] of CrystalClick::BinaryEnumDefinition::Entry)
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.enum8([
        {"too-low", -129_i16},
      ] of CrystalClick::BinaryEnumDefinition::Entry)
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.enum8([
        {"too-high", 128_i16},
      ] of CrystalClick::BinaryEnumDefinition::Entry)
    end

    [
      Bytes[0x17_u8, 0x00_u8],
      Bytes[0x17_u8, 0x02_u8, 0x01_u8, 0x61_u8, 0x01_u8, 0x01_u8, 0x61_u8, 0x02_u8],
      Bytes[0x17_u8, 0x02_u8, 0x01_u8, 0x61_u8, 0x01_u8, 0x01_u8, 0x62_u8, 0x01_u8],
    ].each do |malformed|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryDataTypeCodec.decode(malformed)
      end
    end
  end

  it "counts Enum metadata against exact and minus-one descriptor/value budgets" do
    type = CrystalClick::BinaryDataType.enum8([
      {"a", -1_i16},
      {"z", 2_i16},
    ] of CrystalClick::BinaryEnumDefinition::Entry)
    descriptor = Bytes[
      0x17_u8, 0x02_u8,
      0x01_u8, 0x61_u8, 0xff_u8,
      0x01_u8, 0x7a_u8, 0x02_u8,
    ]
    payload = Bytes[0x7f_u8] # raw Enum codes need not be declared labels

    descriptor_exact = w119_limits(max_depth: 1, max_nodes: 3, max_elements: 2, max_bytes: 8)
    CrystalClick::BinaryDataTypeCodec.encode(type, descriptor_exact).should eq(descriptor)
    CrystalClick::BinaryDataTypeCodec.decode(descriptor, descriptor_exact).should eq(type)

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(descriptor, w119_limits(max_depth: 1, max_nodes: 2, max_elements: 2, max_bytes: 8))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(descriptor, w119_limits(max_depth: 1, max_nodes: 3, max_elements: 1, max_bytes: 8))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(descriptor, w119_limits(max_depth: 1, max_nodes: 3, max_elements: 2, max_bytes: 7))
    end

    value_exact = w119_limits(max_depth: 1, max_nodes: 4, max_elements: 2, max_bytes: 1)
    value = CrystalClick::BinaryValue.fixed(type, payload)
    CrystalClick::BinaryValueCodec.encode_value(value, value_exact).should eq(payload)
    CrystalClick::BinaryValueCodec.decode_value(type, payload, value_exact).bytes.should eq(payload)

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode_value(value, w119_limits(max_depth: 1, max_nodes: 3, max_elements: 2, max_bytes: 1))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_value(type, payload, w119_limits(max_depth: 1, max_nodes: 3, max_elements: 2, max_bytes: 1))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode_value(value, w119_limits(max_depth: 1, max_nodes: 4, max_elements: 1, max_bytes: 1))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_value(type, payload, w119_limits(max_depth: 1, max_nodes: 4, max_elements: 1, max_bytes: 1))
    end
  end

  it "keeps Enum metadata at the scalar depth while sharing borrowed MAP budgets" do
    type = CrystalClick::BinaryDataType.enum8([
      {"a", -1_i16},
      {"z", 2_i16},
    ] of CrystalClick::BinaryEnumDefinition::Entry)
    value = CrystalClick::BinaryValue.fixed(type, Bytes[0x7f_u8])
    row = CrystalClick::ObjectSharedMapRow.new([
      CrystalClick::ObjectSharedMapEntry.new(Bytes[0x78_u8], value),
    ] of CrystalClick::ObjectSharedMapEntry)
    rows = [row] of CrystalClick::ObjectSharedMapRow

    sizes = Bytes[0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8]
    paths = Bytes[0x01_u8, 0x78_u8]
    values = Bytes[
      0x09_u8,
      0x17_u8, 0x02_u8,
      0x01_u8, 0x61_u8, 0xff_u8,
      0x01_u8, 0x7a_u8, 0x02_u8,
      0x7f_u8,
    ]
    exact = w119_limits(max_depth: 1, max_nodes: 6, max_elements: 4, max_bytes: 20)

    streams = CrystalClick::ObjectSharedMapCodec.encode(rows, exact)
    streams.sizes.should eq(sizes)
    streams.paths.should eq(paths)
    streams.values.should eq(values)
    decoded = CrystalClick::ObjectSharedMapCodec.decode(sizes, paths, values, 1, exact)
    decoded[0].entry_at(0).value.type.should eq(type)
    decoded[0].entry_at(0).value.bytes.should eq(Bytes[0x7f_u8])

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectSharedMapCodec.encode(rows, w119_limits(max_depth: 1, max_nodes: 5, max_elements: 4, max_bytes: 20))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedMapCodec.decode(sizes, paths, values, 1, w119_limits(max_depth: 1, max_nodes: 5, max_elements: 4, max_bytes: 20))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectSharedMapCodec.encode(rows, w119_limits(max_depth: 1, max_nodes: 6, max_elements: 3, max_bytes: 20))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedMapCodec.decode(sizes, paths, values, 1, w119_limits(max_depth: 1, max_nodes: 6, max_elements: 3, max_bytes: 20))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectSharedMapCodec.encode(rows, w119_limits(max_depth: 1, max_nodes: 6, max_elements: 4, max_bytes: 19))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedMapCodec.decode(sizes, paths, values, 1, w119_limits(max_depth: 1, max_nodes: 6, max_elements: 4, max_bytes: 19))
    end
  end

  it "preflights Enum code-domain, aggregate, and minimum-wire counts before allocation" do
    # Enum16 cannot have more entries than its signed Int16 code space. Build
    # the complete minimum body before measuring so neither input truncation
    # nor aggregate budgets can mask the domain preflight.
    domain_count = 1_000_000
    domain_count_wire = w119_var_uint(domain_count.to_u64)
    domain_minimum_body = Bytes.new(domain_count * 3, 0_u8)
    domain_descriptor = Bytes.new(1 + domain_count_wire.size) do |index|
      index == 0 ? 0x18_u8 : domain_count_wire[index - 1]
    end
    too_many = w119_concat(domain_descriptor, domain_minimum_body)
    high_limits = w119_limits(
      max_depth: 1,
      max_nodes: 2_000_000,
      max_elements: 2_000_000,
      max_bytes: too_many.size
    )
    GC.stats
    before_domain = GC.stats.total_bytes
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(too_many, high_limits)
    end
    (GC.stats.total_bytes - before_domain).should be < 128_u64 * 1024_u64

    # A count in the Enum16 signed domain still needs at least one name-length
    # byte and two code bytes per entry, even when empty labels are allowed.
    no_minimum_body = Bytes[0x18_u8, 0x80_u8, 0x80_u8, 0x04_u8] # 65,536
    raised_for_domain = w119_limits(max_depth: 1, max_nodes: 70_000, max_elements: 70_000, max_bytes: 4)
    GC.stats
    before_wire = GC.stats.total_bytes
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(no_minimum_body, raised_for_domain)
    end
    (GC.stats.total_bytes - before_wire).should be < 128_u64 * 1024_u64

    # Enough input exists for the minimum shape, so this failure isolates the
    # aggregate node/edge preflight before the count-sized entry collection.
    count = 50_000
    count_wire = w119_var_uint(count.to_u64)
    minimum_body = Bytes.new(count * 3, 0_u8)
    bounded = w119_concat(
      Bytes.new(1 + count_wire.size) do |index|
        index == 0 ? 0x18_u8 : count_wire[index - 1]
      end,
      minimum_body
    )
    low_aggregate_limits = w119_limits(
      max_depth: 1,
      max_nodes: 100,
      max_elements: 100,
      max_bytes: bounded.size
    )
    GC.stats
    before_budget = GC.stats.total_bytes
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(bounded, low_aggregate_limits)
    end
    (GC.stats.total_bytes - before_budget).should be < 128_u64 * 1024_u64
  end

  it "composes the new leaves through existing recursive Array and Nullable models" do
    enum_type = CrystalClick::BinaryDataType.enum8([
      {"ok", 1_i16},
    ] of CrystalClick::BinaryEnumDefinition::Entry)
    nullable_enum = CrystalClick::BinaryDataType.nullable(enum_type)
    array_type = CrystalClick::BinaryDataType.array(nullable_enum)
    non_null = CrystalClick::BinaryValue.nullable(
      nullable_enum,
      CrystalClick::BinaryValue.fixed(enum_type, Bytes[0x7f_u8])
    )
    value = CrystalClick::BinaryValue.array(array_type, [
      non_null,
      CrystalClick::BinaryValue.null(nullable_enum),
    ] of CrystalClick::BinaryValue)

    descriptor = Bytes[
      0x1e_u8, 0x23_u8, 0x17_u8, 0x01_u8,
      0x02_u8, 0x6f_u8, 0x6b_u8, 0x01_u8,
    ]
    payload = Bytes[0x02_u8, 0x00_u8, 0x7f_u8, 0x01_u8]
    envelope = w119_concat(descriptor, payload)
    CrystalClick::BinaryDataTypeCodec.encode(array_type).should eq(descriptor)
    CrystalClick::BinaryValueCodec.encode(value).should eq(envelope)
    decoded = CrystalClick::BinaryValueCodec.decode(envelope)
    decoded.type.should eq(array_type)
    decoded.elements[0].child_at(0).bytes.should eq(Bytes[0x7f_u8])
    decoded.elements[1].is_null?.should be_true
  end

  it "rejects every truncated prefix, trailing byte, and wrong fixed-width scalar size" do
    descriptor_value_cases = [
      {CrystalClick::BinaryDataType.primitive("Date"), Bytes[0x0f_u8], Bytes[0x34_u8, 0x12_u8]},
      {CrystalClick::BinaryDataType.datetime("UTC"), Bytes[0x12_u8, 0x03_u8, 0x55_u8, 0x54_u8, 0x43_u8], Bytes[0x01_u8, 0x02_u8, 0x03_u8, 0x04_u8]},
      {CrystalClick::BinaryDataType.datetime64(3), Bytes[0x13_u8, 0x03_u8], Bytes[0x01_u8, 0x02_u8, 0x03_u8, 0x04_u8, 0x05_u8, 0x06_u8, 0x07_u8, 0x08_u8]},
      {CrystalClick::BinaryDataType.time64(9), Bytes[0x34_u8, 0x09_u8], Bytes[0x01_u8, 0x02_u8, 0x03_u8, 0x04_u8, 0x05_u8, 0x06_u8, 0x07_u8, 0x08_u8]},
      {CrystalClick::BinaryDataType.decimal(32, 9, 2), Bytes[0x19_u8, 0x09_u8, 0x02_u8], Bytes[0x01_u8, 0x02_u8, 0x03_u8, 0x04_u8]},
      {CrystalClick::BinaryDataType.enum8([
        {"a", -1_i16},
      ] of CrystalClick::BinaryEnumDefinition::Entry), Bytes[0x17_u8, 0x01_u8, 0x01_u8, 0x61_u8, 0xff_u8], Bytes[0x7f_u8]},
      {CrystalClick::BinaryDataType.enum16([
        {"a", -1_i16},
      ] of CrystalClick::BinaryEnumDefinition::Entry), Bytes[0x18_u8, 0x01_u8, 0x01_u8, 0x61_u8, 0xff_u8, 0xff_u8], Bytes[0x34_u8, 0x12_u8]},
    ] of Tuple(CrystalClick::BinaryDataType, Bytes, Bytes)

    descriptor_value_cases.each do |type, descriptor, payload|
      w119_corrupt_descriptor_prefixes(descriptor)
      w119_corrupt_value_prefixes(type, payload)

      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryDataTypeCodec.decode(w119_concat(descriptor, Bytes[0x00_u8]))
      end
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryValueCodec.decode_value(type, w119_concat(payload, Bytes[0x00_u8]))
      end
      envelope = w119_concat(descriptor, payload)
      w119_corrupt_envelope_prefixes(envelope)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryValueCodec.decode(w119_concat(envelope, Bytes[0x00_u8]))
      end
    end

    date = CrystalClick::BinaryDataType.primitive("Date")
    expect_raises(ArgumentError) do
      CrystalClick::BinaryValue.fixed(date, Bytes[0x00_u8])
    end
  end
end
