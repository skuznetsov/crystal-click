require "./spec_helper"

private def w148_u64(value : UInt64) : Bytes
  Bytes.new(8) { |index| ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w148_concat(parts : Array(Bytes)) : Bytes
  bytes = [] of UInt8
  parts.each { |part| part.each { |byte| bytes << byte } }
  Bytes.new(bytes.size) { |index| bytes[index] }
end

private def w148_variant_string_uint64 : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.variant([
    CrystalClick::BinaryDataType.primitive("UInt64"),
    CrystalClick::BinaryDataType.primitive("String"),
  ] of CrystalClick::BinaryDataType)
end

private def w148_assert_value_budget(
  type : CrystalClick::BinaryDataType,
  rows : Array(Array(CrystalClick::BinaryValue)),
  profile : CrystalClick::BinaryBulkProfile,
) : Nil
  measured = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true)
  streams = CrystalClick::BinaryBulkCodec.encode_with_budget(type, rows, measured, profile: profile)
  measured.wire_byte_count.should eq(streams.total_input_byte_size.to_i64)

  exact_limits = CrystalClick::BinaryCodecLimits.new(
    64,
    measured.node_count,
    measured.element_count,
    measured.wire_byte_count
  )
  exact = CrystalClick::BinaryCodecBudget.new(exact_limits, true)
  replay = CrystalClick::BinaryBulkCodec.encode_with_budget(type, rows, exact, profile: profile)
  {exact.node_count, exact.element_count, exact.wire_byte_count}.should eq(
    {measured.node_count, measured.element_count, measured.wire_byte_count}
  )
  replay.roles.should eq(streams.roles)
  replay.roles.each do |role|
    replay.stream(role).bytes.should eq(streams.stream(role).bytes)
    replay.stream(role).offsets.should eq(streams.stream(role).offsets)
  end

  [
    CrystalClick::BinaryCodecLimits.new(64, measured.node_count - 1, measured.element_count, measured.wire_byte_count),
    CrystalClick::BinaryCodecLimits.new(64, measured.node_count, measured.element_count - 1, measured.wire_byte_count),
    CrystalClick::BinaryCodecLimits.new(64, measured.node_count, measured.element_count, measured.wire_byte_count - 1),
  ].each do |limits|
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkCodec.encode(type, rows, limits: limits, profile: profile)
    end
  end

  measured_read = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS)
  CrystalClick::BinaryBulkCodec.decode_with_budget(
    type,
    streams,
    rows.map(&.size.to_u64),
    measured_read,
    profile: profile
  )
  measured_read.wire_byte_count.should eq(streams.total_input_byte_size.to_i64)
  exact_read_limits = CrystalClick::BinaryCodecLimits.new(
    64,
    measured_read.node_count,
    measured_read.element_count,
    measured_read.wire_byte_count
  )
  exact_read = CrystalClick::BinaryCodecBudget.new(exact_read_limits)
  CrystalClick::BinaryBulkCodec.decode_with_budget(
    type,
    streams,
    rows.map(&.size.to_u64),
    exact_read,
    profile: profile
  )
  {exact_read.node_count, exact_read.element_count, exact_read.wire_byte_count}.should eq(
    {measured_read.node_count, measured_read.element_count, measured_read.wire_byte_count}
  )
  [
    CrystalClick::BinaryCodecLimits.new(64, measured_read.node_count - 1, measured_read.element_count, measured_read.wire_byte_count),
    CrystalClick::BinaryCodecLimits.new(64, measured_read.node_count, measured_read.element_count - 1, measured_read.wire_byte_count),
    CrystalClick::BinaryCodecLimits.new(64, measured_read.node_count, measured_read.element_count, measured_read.wire_byte_count - 1),
  ].each do |limits|
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(
        type,
        streams,
        rows.map(&.size.to_u64),
        limits: limits,
        profile: profile
      )
    end
  end
  nil
end

describe "W148 sparse Variant BinaryBulk lanes" do
  it "writes a discriminator lane and keeps inactive and NULL arm lanes in the role grid" do
    string = CrystalClick::BinaryDataType.primitive("String")
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    type = CrystalClick::BinaryDataType.variant([uint64, string] of CrystalClick::BinaryDataType)
    rows = [[
      CrystalClick::BinaryValue.variant(type, 0, CrystalClick::BinaryValue.string("x")),
      CrystalClick::BinaryValue.variant_null(type),
    ]] of Array(CrystalClick::BinaryValue)

    streams = CrystalClick::BinaryBulkCodec.encode(type, rows)

    streams.roles.should eq([
      "root.arm.0.data",
      "root.arm.1.data",
      "root.discriminators",
    ] of String)
    streams.stream("root.discriminators").bytes.should eq(Bytes[0x00_u8, 0xff_u8])
    streams.stream("root.discriminators").offsets.should eq([0_u64, 2_u64])
    streams.stream("root.arm.0.data").bytes.should eq(Bytes[0x01_u8, 0x78_u8])
    streams.stream("root.arm.0.data").offsets.should eq([0_u64, 2_u64])
    streams.stream("root.arm.1.data").bytes.should eq(Bytes.empty)
    streams.stream("root.arm.1.data").offsets.should eq([0_u64, 0_u64])
  end

  it "keeps UInt8 BASIC discriminators separate from arm bytes in both String profiles" do
    type = w148_variant_string_uint64
    string = CrystalClick::BinaryValue.string("a")
    uint64 = CrystalClick::BinaryValue.uint64(42_u64)
    rows = [
      [CrystalClick::BinaryValue.variant(type, 0, string), CrystalClick::BinaryValue.variant_null(type)],
      [CrystalClick::BinaryValue.variant(type, 1, uint64)],
      [CrystalClick::BinaryValue.variant_null(type), CrystalClick::BinaryValue.variant(type, 0, CrystalClick::BinaryValue.string("bc"))],
    ] of Array(CrystalClick::BinaryValue)

    [CrystalClick::BinaryBulkProfile.single_stream, CrystalClick::BinaryBulkProfile.with_size_stream].each do |profile|
      streams = CrystalClick::BinaryBulkCodec.encode(type, rows, profile: profile)
      streams.stream("root.discriminators").bytes.should eq(Bytes[0x00_u8, 0xff_u8, 0x01_u8, 0xff_u8, 0x00_u8])
      streams.stream("root.discriminators").offsets.should eq([0_u64, 2_u64, 3_u64, 5_u64])
      streams.stream("root.arm.1.data").bytes.should eq(Bytes[0x2a_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8])
      streams.stream("root.arm.1.data").offsets.should eq([0_u64, 0_u64, 8_u64, 8_u64])

      if profile.with_size_stream?
        streams.roles.should eq([
          "root.arm.0.data",
          "root.arm.0.string_sizes",
          "root.arm.1.data",
          "root.discriminators",
        ] of String)
        streams.stream("root.arm.0.data").bytes.should eq(Bytes[0x61_u8, 0x62_u8, 0x63_u8])
        streams.stream("root.arm.0.data").offsets.should eq([0_u64, 1_u64, 1_u64, 3_u64])
        streams.stream("root.arm.0.string_sizes").bytes.should eq(w148_concat([w148_u64(1_u64), w148_u64(2_u64)] of Bytes))
        streams.stream("root.arm.0.string_sizes").offsets.should eq([0_u64, 8_u64, 8_u64, 16_u64])
      else
        streams.roles.should eq([
          "root.arm.0.data",
          "root.arm.1.data",
          "root.discriminators",
        ] of String)
        streams.stream("root.arm.0.data").bytes.should eq(Bytes[0x01_u8, 0x61_u8, 0x02_u8, 0x62_u8, 0x63_u8])
        streams.stream("root.arm.0.data").offsets.should eq([0_u64, 2_u64, 2_u64, 5_u64])
      end

      decoded = CrystalClick::BinaryBulkCodec.decode(type, streams, [2_u64, 1_u64, 2_u64], profile: profile)
      decoded[0][0].variant_child?.not_nil!.as_string.should eq("a")
      decoded[0][1].is_null?.should be_true
      decoded[1][0].variant_child?.not_nil!.as_uint64.should eq(42_u64)
      decoded[2][0].is_null?.should be_true
      decoded[2][1].variant_child?.not_nil!.as_string.should eq("bc")
      selected = CrystalClick::BinaryBulkCodec.decode(
        type,
        streams,
        [2_u64, 1_u64, 2_u64],
        first_mark: 1,
        mark_count: 1,
        profile: profile
      )
      selected.size.should eq(1)
      selected[0][0].variant_child?.not_nil!.as_uint64.should eq(42_u64)
    end

    w148_assert_value_budget(type, rows, CrystalClick::BinaryBulkProfile.single_stream)
    w148_assert_value_budget(type, rows, CrystalClick::BinaryBulkProfile.with_size_stream)
  end

  it "distinguishes NULL from a selected empty Array and composes Variant as an Array child" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    string = CrystalClick::BinaryDataType.primitive("String")
    array_type = CrystalClick::BinaryDataType.array(uint8)
    type = CrystalClick::BinaryDataType.variant([string, array_type] of CrystalClick::BinaryDataType)
    type.children.map(&.name).should eq(["Array(UInt8)", "String"] of String)
    empty_array = CrystalClick::BinaryValue.array(array_type, [] of CrystalClick::BinaryValue)
    one_array = CrystalClick::BinaryValue.array(array_type, [CrystalClick::BinaryValue.fixed(uint8, Bytes[0x07_u8])] of CrystalClick::BinaryValue)
    rows = [[
      CrystalClick::BinaryValue.variant_null(type),
      CrystalClick::BinaryValue.variant(type, 0, empty_array),
      CrystalClick::BinaryValue.variant(type, 0, one_array),
    ]] of Array(CrystalClick::BinaryValue)

    encoded = CrystalClick::BinaryBulkCodec.encode(type, rows)
    encoded.roles.should eq([
      "root.arm.0.elements.data",
      "root.arm.0.sizes",
      "root.arm.1.data",
      "root.discriminators",
    ] of String)
    encoded.stream("root.discriminators").bytes.should eq(Bytes[0xff_u8, 0x00_u8, 0x00_u8])
    encoded.stream("root.arm.0.sizes").bytes.should eq(w148_concat([w148_u64(0_u64), w148_u64(1_u64)] of Bytes))
    encoded.stream("root.arm.0.sizes").offsets.should eq([0_u64, 16_u64])
    encoded.stream("root.arm.0.elements.data").bytes.should eq(Bytes[0x07_u8])
    encoded.stream("root.arm.1.data").bytes.should be_empty
    decoded = CrystalClick::BinaryBulkCodec.decode(type, encoded, [3_u64])
    decoded[0][0].is_null?.should be_true
    decoded[0][1].variant_child?.not_nil!.element_count.should eq(0)
    decoded[0][2].variant_child?.not_nil!.element_at(0).bytes.should eq(Bytes[0x07_u8])

    tuple_type = CrystalClick::BinaryDataType.tuple([
      type,
      uint8,
    ] of CrystalClick::BinaryDataType)
    tuple_value = CrystalClick::BinaryValue.tuple(tuple_type, [
      CrystalClick::BinaryValue.variant_null(type),
      CrystalClick::BinaryValue.fixed(uint8, Bytes[0x09_u8]),
    ] of CrystalClick::BinaryValue)
    tuple_streams = CrystalClick::BinaryBulkCodec.encode(tuple_type, [[tuple_value]] of Array(CrystalClick::BinaryValue))
    tuple_streams.stream("root.field.0.discriminators").bytes.should eq(Bytes[0xff_u8])
    tuple_streams.stream("root.field.0.arm.0.sizes").bytes.should be_empty
    tuple_streams.stream("root.field.1.data").bytes.should eq(Bytes[0x09_u8])
    tuple_decoded = CrystalClick::BinaryBulkCodec.decode(tuple_type, tuple_streams, [1_u64])
    tuple_decoded[0][0].element_at(0).is_null?.should be_true
    tuple_decoded[0][0].element_at(1).bytes.should eq(Bytes[0x09_u8])
  end

  it "composes eligible Array, LowCardinality Float, Map, and Tuple arms under both profiles" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    uint16 = CrystalClick::BinaryDataType.primitive("UInt16")
    string = CrystalClick::BinaryDataType.primitive("String")
    nullable_uint8 = CrystalClick::BinaryDataType.nullable(uint8)
    array_type = CrystalClick::BinaryDataType.array(nullable_uint8)
    low_float_type = CrystalClick::BinaryDataType.low_cardinality(CrystalClick::BinaryDataType.primitive("Float32"))
    map_type = CrystalClick::BinaryDataType.map(string, uint16)
    tuple_type = CrystalClick::BinaryDataType.tuple([string, string] of CrystalClick::BinaryDataType)
    type = CrystalClick::BinaryDataType.variant([tuple_type, map_type, low_float_type, array_type] of CrystalClick::BinaryDataType)
    type.children.map(&.name).should eq([
      "Array(Nullable(UInt8))",
      "LowCardinality(Float32)",
      "Map(String, UInt16)",
      "Tuple(String, String)",
    ] of String)

    array_value = CrystalClick::BinaryValue.array(array_type, [
      CrystalClick::BinaryValue.nullable(nullable_uint8, CrystalClick::BinaryValue.fixed(uint8, Bytes[0x07_u8])),
      CrystalClick::BinaryValue.nullable(nullable_uint8),
    ] of CrystalClick::BinaryValue)
    low_float_value = CrystalClick::BinaryValue.low_cardinality(
      low_float_type,
      CrystalClick::BinaryValue.float32_bits(0x8000_0000_u32)
    )
    map_value = CrystalClick::BinaryValue.map(map_type, [
      CrystalClick::BinaryValue.string("k"),
      CrystalClick::BinaryValue.fixed(uint16, Bytes[0x34_u8, 0x12_u8]),
    ] of CrystalClick::BinaryValue)
    tuple_value = CrystalClick::BinaryValue.tuple(tuple_type, [
      CrystalClick::BinaryValue.string("a"),
      CrystalClick::BinaryValue.string("b"),
    ] of CrystalClick::BinaryValue)
    rows = [
      [CrystalClick::BinaryValue.variant(type, 0, array_value)],
      [CrystalClick::BinaryValue.variant(type, 1, low_float_value)],
      [CrystalClick::BinaryValue.variant(type, 2, map_value)],
      [CrystalClick::BinaryValue.variant(type, 3, tuple_value)],
    ] of Array(CrystalClick::BinaryValue)

    [CrystalClick::BinaryBulkProfile.single_stream, CrystalClick::BinaryBulkProfile.with_size_stream].each do |profile|
      encoded = CrystalClick::BinaryBulkCodec.encode(type, rows, profile: profile)
      encoded.stream("root.discriminators").bytes.should eq(Bytes[0x00_u8, 0x01_u8, 0x02_u8, 0x03_u8])
      encoded.roles.should contain("root.arm.0.elements.nulls")
      encoded.roles.should contain("root.arm.0.elements.nested.data")
      encoded.roles.should contain("root.arm.1.dictionary")
      encoded.roles.should contain("root.arm.1.indexes")
      encoded.roles.should contain("root.arm.2.sizes")
      encoded.roles.should contain("root.arm.3.field.0.data")
      encoded.roles.should contain("root.arm.3.field.1.data")
      decoded = CrystalClick::BinaryBulkCodec.decode(type, encoded, [1_u64, 1_u64, 1_u64, 1_u64], profile: profile)
      decoded_array = decoded[0][0].variant_child?.not_nil!
      decoded_array.element_count.should eq(2)
      decoded_array.element_at(0).is_null?.should be_false
      decoded_array.element_at(0).child_at(0).bytes.should eq(Bytes[0x07_u8])
      decoded[0][0].variant_child?.not_nil!.element_at(1).is_null?.should be_true
      decoded[1][0].variant_child?.not_nil!.child_at(0).as_float32_bits.should eq(0x8000_0000_u32)
      decoded[2][0].variant_child?.not_nil!.element_at(0).as_string.should eq("k")
      decoded[2][0].variant_child?.not_nil!.element_at(1).bytes.should eq(Bytes[0x34_u8, 0x12_u8])
      decoded[3][0].variant_child?.not_nil!.element_at(0).as_string.should eq("a")
      decoded[3][0].variant_child?.not_nil!.element_at(1).as_string.should eq("b")
    end
  end

  it "censuses LC arm occurrences through Array sizes and Variant discriminators across all marks" do
    string = CrystalClick::BinaryDataType.primitive("String")
    low = CrystalClick::BinaryDataType.low_cardinality(string)
    type = CrystalClick::BinaryDataType.variant([string, low] of CrystalClick::BinaryDataType)
    array_type = CrystalClick::BinaryDataType.array(type)
    type.children.map(&.name).should eq(["LowCardinality(String)", "String"] of String)
    low_value = ->(value : String) { CrystalClick::BinaryValue.variant(type, 0, CrystalClick::BinaryValue.low_cardinality(low, CrystalClick::BinaryValue.string(value))) }
    rows = [
      [CrystalClick::BinaryValue.array(array_type, [] of CrystalClick::BinaryValue)],
      [CrystalClick::BinaryValue.array(array_type, [
        CrystalClick::BinaryValue.variant_null(type),
        CrystalClick::BinaryValue.variant(type, 1, CrystalClick::BinaryValue.string("skip")),
      ] of CrystalClick::BinaryValue)],
      [CrystalClick::BinaryValue.array(array_type, [low_value.call("red"), low_value.call("blue")] of CrystalClick::BinaryValue)],
      [CrystalClick::BinaryValue.array(array_type, [CrystalClick::BinaryValue.variant_null(type)] of CrystalClick::BinaryValue)],
    ] of Array(CrystalClick::BinaryValue)

    encoded = CrystalClick::BinaryBulkCodec.encode(array_type, rows)
    encoded.roles.should eq([
      "root.elements.arm.0.dictionary",
      "root.elements.arm.0.indexes",
      "root.elements.arm.1.data",
      "root.elements.discriminators",
      "root.sizes",
    ] of String)
    encoded.stream("root.sizes").bytes.should eq(w148_concat([
      w148_u64(0_u64), w148_u64(2_u64), w148_u64(2_u64), w148_u64(1_u64),
    ] of Bytes))
    encoded.stream("root.elements.discriminators").bytes.should eq(Bytes[0xff_u8, 0x01_u8, 0x00_u8, 0x00_u8, 0xff_u8])
    encoded.stream("root.elements.discriminators").offsets.should eq([0_u64, 0_u64, 2_u64, 4_u64, 5_u64])
    encoded.stream("root.elements.arm.0.dictionary").bytes.should eq(w148_concat([
      w148_u64(1_u64), w148_u64(3_u64), Bytes[0x00_u8], Bytes[0x03_u8, 0x72_u8, 0x65_u8, 0x64_u8],
      Bytes[0x04_u8, 0x62_u8, 0x6c_u8, 0x75_u8, 0x65_u8],
    ] of Bytes))
    # Each mark refers to the same global dictionary record at offset 8;
    # only the terminal grid entry points to the dictionary lane's EOF.
    encoded.stream("root.elements.arm.0.dictionary").offsets.should eq([8_u64, 8_u64, 8_u64, 8_u64, 26_u64])
    encoded.stream("root.elements.arm.0.indexes").bytes.should eq(w148_concat([
      w148_u64(0x500_u64), w148_u64(2_u64), Bytes[0x01_u8, 0x02_u8],
    ] of Bytes))
    encoded.stream("root.elements.arm.0.indexes").offsets.should eq([0_u64, 0_u64, 0_u64, 18_u64, 18_u64])
    selected = CrystalClick::BinaryBulkCodec.decode(
      array_type,
      encoded,
      [1_u64, 1_u64, 1_u64, 1_u64],
      first_mark: 2,
      mark_count: 1
    )
    selected[0][0].element_at(0).variant_child?.not_nil!.child_at(0).as_string.should eq("red")
    selected[0][0].element_at(1).variant_child?.not_nil!.child_at(0).as_string.should eq("blue")
    w148_assert_value_budget(array_type, rows, CrystalClick::BinaryBulkProfile.single_stream)
  end

  it "censuses LC arm occurrences through Map pair sizes and nested discriminators" do
    string = CrystalClick::BinaryDataType.primitive("String")
    low = CrystalClick::BinaryDataType.low_cardinality(string)
    variant = CrystalClick::BinaryDataType.variant([string, low] of CrystalClick::BinaryDataType)
    map_type = CrystalClick::BinaryDataType.map(string, variant)
    low_value = ->(value : String) { CrystalClick::BinaryValue.variant(variant, 0, CrystalClick::BinaryValue.low_cardinality(low, CrystalClick::BinaryValue.string(value))) }
    map_value = ->(flat : Array(CrystalClick::BinaryValue)) { CrystalClick::BinaryValue.map(map_type, flat) }
    rows = [
      [map_value.call([] of CrystalClick::BinaryValue)],
      [map_value.call([CrystalClick::BinaryValue.string("skip"), CrystalClick::BinaryValue.variant(variant, 1, CrystalClick::BinaryValue.string("else"))] of CrystalClick::BinaryValue)],
      [map_value.call([
        CrystalClick::BinaryValue.string("a"), low_value.call("red"),
        CrystalClick::BinaryValue.string("b"), low_value.call("blue"),
      ] of CrystalClick::BinaryValue)],
      [map_value.call([CrystalClick::BinaryValue.string("c"), CrystalClick::BinaryValue.variant_null(variant)] of CrystalClick::BinaryValue)],
    ] of Array(CrystalClick::BinaryValue)

    encoded = CrystalClick::BinaryBulkCodec.encode(map_type, rows)
    encoded.roles.should contain("root.sizes")
    encoded.roles.should contain("root.elements.field.1.discriminators")
    encoded.roles.should contain("root.elements.field.1.arm.0.dictionary")
    encoded.stream("root.sizes").bytes.should eq(w148_concat([
      w148_u64(0_u64), w148_u64(1_u64), w148_u64(2_u64), w148_u64(1_u64),
    ] of Bytes))
    encoded.stream("root.elements.field.1.discriminators").bytes.should eq(Bytes[0x01_u8, 0x00_u8, 0x00_u8, 0xff_u8])
    encoded.stream("root.elements.field.1.discriminators").offsets.should eq([0_u64, 0_u64, 1_u64, 3_u64, 4_u64])
    encoded.stream("root.elements.field.1.arm.0.indexes").bytes.should eq(w148_concat([
      w148_u64(0x500_u64), w148_u64(2_u64), Bytes[0x01_u8, 0x02_u8],
    ] of Bytes))
    selected = CrystalClick::BinaryBulkCodec.decode(
      map_type,
      encoded,
      [1_u64, 1_u64, 1_u64, 1_u64],
      first_mark: 2,
      mark_count: 1
    )
    selected[0][0].element_at(1).variant_child?.not_nil!.child_at(0).as_string.should eq("red")
    selected[0][0].element_at(3).variant_child?.not_nil!.child_at(0).as_string.should eq("blue")
    w148_assert_value_budget(map_type, rows, CrystalClick::BinaryBulkProfile.single_stream)
  end

  it "uses Variant NULL as the hidden default beneath Nullable Tuple while retaining sibling LC defaults" do
    string = CrystalClick::BinaryDataType.primitive("String")
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    variant = CrystalClick::BinaryDataType.variant([string, uint64] of CrystalClick::BinaryDataType)
    low = CrystalClick::BinaryDataType.low_cardinality(string)
    tuple = CrystalClick::BinaryDataType.tuple([variant, low] of CrystalClick::BinaryDataType)
    type = CrystalClick::BinaryDataType.nullable(tuple)
    null = CrystalClick::BinaryValue.nullable(type)

    encoded = CrystalClick::BinaryBulkCodec.encode(type, [[null]] of Array(CrystalClick::BinaryValue))
    encoded.stream("root.nulls").bytes.should eq(Bytes[0x01_u8])
    encoded.stream("root.nested.field.0.discriminators").bytes.should eq(Bytes[0xff_u8])
    encoded.stream("root.nested.field.0.arm.0.data").bytes.should be_empty
    encoded.stream("root.nested.field.0.arm.1.data").bytes.should be_empty
    encoded.stream("root.nested.field.1.indexes").bytes.should eq(w148_concat([
      w148_u64(0x500_u64), w148_u64(1_u64), Bytes[0x00_u8],
    ] of Bytes))
    decoded = CrystalClick::BinaryBulkCodec.decode(type, encoded, [1_u64])
    decoded[0][0].is_null?.should be_true
  end

  it "routes LC through Variant Array children and replays full state for a selected last mark" do
    string = CrystalClick::BinaryDataType.primitive("String")
    low_string = CrystalClick::BinaryDataType.low_cardinality(string)
    array_type = CrystalClick::BinaryDataType.array(low_string)
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    type = CrystalClick::BinaryDataType.variant([uint8, array_type] of CrystalClick::BinaryDataType)
    type.children.map(&.name).should eq(["Array(LowCardinality(String))", "UInt8"] of String)

    array_variant = ->(values : Array(String)) do
      children = values.map do |value|
        CrystalClick::BinaryValue.low_cardinality(low_string, CrystalClick::BinaryValue.string(value))
      end
      CrystalClick::BinaryValue.variant(type, 0, CrystalClick::BinaryValue.array(array_type, children))
    end
    uint8_variant = ->(value : UInt8) do
      CrystalClick::BinaryValue.variant(type, 1, CrystalClick::BinaryValue.fixed(uint8, Bytes[value]))
    end

    rows = [
      [array_variant.call(["red"] of String)],
      [array_variant.call([] of String)],
      [uint8_variant.call(0x11_u8)],
      [CrystalClick::BinaryValue.variant_null(type)],
      [array_variant.call(["blue", "red"] of String)],
      [array_variant.call(["tail"] of String), uint8_variant.call(0x2a_u8)],
    ] of Array(CrystalClick::BinaryValue)
    rows_per_mark = [1_u64, 1_u64, 1_u64, 1_u64, 1_u64, 2_u64]

    plan = CrystalClick::BinaryBulkTypePlan.new(type, CrystalClick::BinaryBulkProfile.single_stream)
    plan.low_cardinality_shape_roles.should eq([
      "root.arm.0.sizes",
      "root.discriminators",
    ] of String)
    plan.low_cardinality_schedule_grid_count.should eq(2_u64)

    encoded = CrystalClick::BinaryBulkCodec.encode(type, rows)
    encoded.roles.should eq([
      "root.arm.0.elements.dictionary",
      "root.arm.0.elements.indexes",
      "root.arm.0.sizes",
      "root.arm.1.data",
      "root.discriminators",
    ] of String)
    encoded.stream("root.discriminators").bytes.should eq(Bytes[0x00_u8, 0x00_u8, 0x01_u8, 0xff_u8, 0x00_u8, 0x00_u8, 0x01_u8])
    encoded.stream("root.discriminators").offsets.should eq([0_u64, 1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 7_u64])
    encoded.stream("root.arm.0.sizes").bytes.should eq(w148_concat([
      w148_u64(1_u64), w148_u64(0_u64), w148_u64(2_u64), w148_u64(1_u64),
    ] of Bytes))
    encoded.stream("root.arm.0.sizes").offsets.should eq([0_u64, 8_u64, 16_u64, 16_u64, 16_u64, 24_u64, 32_u64])
    encoded.stream("root.arm.1.data").bytes.should eq(Bytes[0x11_u8, 0x2a_u8])
    encoded.stream("root.arm.1.data").offsets.should eq([0_u64, 0_u64, 0_u64, 1_u64, 1_u64, 1_u64, 2_u64])
    encoded.stream("root.arm.0.elements.dictionary").byte_size.should eq(31)
    encoded.stream("root.arm.0.elements.indexes").byte_size.should eq(52)
    encoded.stream("root.arm.0.elements.indexes").offsets.should eq([0_u64, 17_u64, 17_u64, 17_u64, 17_u64, 35_u64, 52_u64])

    # The schedule counts the Array's flattened children, not root Variant
    # rows: empty arrays, the other arm, and NULL all contribute zero.
    schedule_budget = CrystalClick::BinaryCodecBudget.new(
      CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: 12, max_elements: 12, max_bytes: 39)
    )
    occurrences = CrystalClick::BinaryBulkLowCardinalityOccurrenceSchedule.build(
      type,
      plan.low_cardinality_shape_roles,
      plan.low_cardinality_schedule_grid_count,
      encoded,
      rows_per_mark,
      schedule_budget
    )
    occurrences["root.arm.0.elements"].should eq([1_u64, 0_u64, 0_u64, 0_u64, 2_u64, 1_u64])
    {schedule_budget.node_count, schedule_budget.element_count, schedule_budget.wire_byte_count}.should eq(
      {12_i64, 12_i64, 39_i64}
    )

    decoded = CrystalClick::BinaryBulkCodec.decode(type, encoded, rows_per_mark)
    decoded[1][0].variant_index?.should eq(0_u8)
    decoded[1][0].variant_child?.not_nil!.element_count.should eq(0)
    decoded[2][0].variant_index?.should eq(1_u8)
    decoded[2][0].variant_child?.not_nil!.bytes.should eq(Bytes[0x11_u8])
    decoded[3][0].is_null?.should be_true
    decoded[4][0].variant_child?.not_nil!.element_at(0).child_at(0).as_string.should eq("blue")
    decoded[4][0].variant_child?.not_nil!.element_at(1).child_at(0).as_string.should eq("red")

    measured_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS)
    selected = CrystalClick::BinaryBulkCodec.decode_with_budget(
      type,
      encoded,
      rows_per_mark,
      measured_budget,
      first_mark: 5,
      mark_count: 1
    )
    selected.size.should eq(1)
    selected[0].size.should eq(2)
    selected[0][0].variant_child?.not_nil!.element_at(0).child_at(0).as_string.should eq("tail")
    selected[0][1].variant_child?.not_nil!.bytes.should eq(Bytes[0x2a_u8])

    # Compute the selected decode's expected bytes from physical lane ranges:
    # both shape lanes are paid once in full by the LC census, both LC lanes
    # are fully replayed, and only the selected mark's ordinary UInt8 byte is
    # otherwise consumed. The other UInt8 occurrence is outside the window.
    full_shape_bytes = encoded.stream("root.discriminators").byte_size.to_u64 +
                       encoded.stream("root.arm.0.sizes").byte_size.to_u64
    lc_replay_bytes = encoded.stream("root.arm.0.elements.dictionary").byte_size.to_u64 +
                      encoded.stream("root.arm.0.elements.indexes").byte_size.to_u64
    selected_uint8_stream = encoded.stream("root.arm.1.data")
    selected_ordinary_bytes = selected_uint8_stream.offset_at(6) - selected_uint8_stream.offset_at(5)
    full_shape_bytes.should eq(39_u64)
    lc_replay_bytes.should eq(83_u64)
    selected_ordinary_bytes.should eq(1_u64)
    expected_read_bytes = full_shape_bytes + lc_replay_bytes + selected_ordinary_bytes
    expected_read_bytes.should eq(123_u64)
    measured_budget.wire_byte_count.should eq(expected_read_bytes.to_i64)

    exact_budget = CrystalClick::BinaryCodecBudget.new(
      CrystalClick::BinaryCodecLimits.new(
        64,
        measured_budget.node_count,
        measured_budget.element_count,
        expected_read_bytes.to_i64
      )
    )
    CrystalClick::BinaryBulkCodec.decode_with_budget(
      type,
      encoded,
      rows_per_mark,
      exact_budget,
      first_mark: 5,
      mark_count: 1
    )
    {exact_budget.node_count, exact_budget.element_count, exact_budget.wire_byte_count}.should eq(
      {measured_budget.node_count, measured_budget.element_count, expected_read_bytes.to_i64}
    )

    short_budgets = [
      CrystalClick::BinaryCodecLimits.new(64, measured_budget.node_count, measured_budget.element_count, expected_read_bytes.to_i64 - 1_i64),
      CrystalClick::BinaryCodecLimits.new(64, measured_budget.node_count - 1, measured_budget.element_count, expected_read_bytes.to_i64),
      CrystalClick::BinaryCodecLimits.new(64, measured_budget.node_count, measured_budget.element_count - 1, expected_read_bytes.to_i64),
    ]
    short_budgets.each do |limits|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryBulkCodec.decode(
          type,
          encoded,
          rows_per_mark,
          first_mark: 5,
          mark_count: 1,
          limits: limits
        )
      end
    end
  end
end
