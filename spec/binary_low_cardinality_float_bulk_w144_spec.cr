require "./spec_helper"

private def w144_float_u64(value : UInt64) : Bytes
  Bytes.new(8) { |index| ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w144_float_concat(parts : Array(Bytes)) : Bytes
  bytes = [] of UInt8
  parts.each { |part| part.each { |byte| bytes << byte } }
  Bytes.new(bytes.size) { |index| bytes[index] }
end

private def w144_float_scalar_bytes(name : String, bits : UInt64) : Bytes
  width = case name
          when "Float32"  then 4
          when "Float64"  then 8
          when "BFloat16" then 2
          else
            raise ArgumentError.new("unknown W144 float type")
          end
  Bytes.new(width) { |index| ((bits >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w144_float_leaf(name : String, bits : UInt64) : CrystalClick::BinaryValue
  case name
  when "Float32"
    CrystalClick::BinaryValue.float32_bits(bits.to_u32)
  when "Float64"
    CrystalClick::BinaryValue.float64_bits(bits)
  when "BFloat16"
    type = CrystalClick::BinaryDataType.primitive("BFloat16")
    CrystalClick::BinaryValue.fixed(type, w144_float_scalar_bytes(name, bits))
  else
    raise ArgumentError.new("unknown W144 float type")
  end
end

private def w144_float_lc(type : CrystalClick::BinaryDataType, name : String, bits : UInt64) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.low_cardinality(type, w144_float_leaf(name, bits))
end

private def w144_nullable_float_lc(
  type : CrystalClick::BinaryDataType,
  name : String,
  bits : UInt64?,
) : CrystalClick::BinaryValue
  nullable = type.child_at(0)
  value = if raw = bits
            CrystalClick::BinaryValue.nullable(nullable, w144_float_leaf(name, raw))
          else
            CrystalClick::BinaryValue.nullable(nullable)
          end
  CrystalClick::BinaryValue.low_cardinality(type, value)
end

private def w144_float_dictionary(name : String, entries : Array(UInt64)) : Bytes
  parts = [w144_float_u64(1_u64), w144_float_u64(entries.size.to_u64)] of Bytes
  entries.each { |bits| parts << w144_float_scalar_bytes(name, bits) }
  w144_float_concat(parts)
end

private def w144_float_index_mark(ids : Array(UInt64), flags : UInt64, width : Int32 = 1) : Bytes
  parts = [w144_float_u64(flags), w144_float_u64(ids.size.to_u64)] of Bytes
  ids.each do |id|
    parts << Bytes.new(width) { |index| ((id >> (index * 8)) & 0xff_u64).to_u8 }
  end
  w144_float_concat(parts)
end

private def w144_float_streams(
  mark_count : Int,
  dictionary : Bytes,
  dictionary_offsets : Array(UInt64),
  indexes : Bytes,
  index_offsets : Array(UInt64),
) : CrystalClick::BinaryBulkStreams
  CrystalClick::BinaryBulkStreams.new(mark_count, {
    "root.dictionary" => CrystalClick::BinaryBulkStream.new(dictionary, dictionary_offsets),
    "root.indexes"    => CrystalClick::BinaryBulkStream.new(indexes, index_offsets),
  } of String => CrystalClick::BinaryBulkStream)
end

private def w144_assert_exact_encode_limits(
  type : CrystalClick::BinaryDataType,
  rows : Array(Array(CrystalClick::BinaryValue)),
) : CrystalClick::BinaryBulkStreams
  measured = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true)
  streams = CrystalClick::BinaryBulkCodec.encode_with_budget(type, rows, measured)
  measured.wire_byte_count.should eq(streams.total_input_byte_size.to_i64)

  exact_limits = CrystalClick::BinaryCodecLimits.new(
    max_depth: 64,
    max_nodes: measured.node_count,
    max_elements: measured.element_count,
    max_bytes: measured.wire_byte_count
  )
  exact_budget = CrystalClick::BinaryCodecBudget.new(exact_limits, true)
  exact = CrystalClick::BinaryBulkCodec.encode_with_budget(type, rows, exact_budget)
  {exact_budget.node_count, exact_budget.element_count, exact_budget.wire_byte_count}.should eq(
    {measured.node_count, measured.element_count, measured.wire_byte_count}
  )
  exact.roles.should eq(streams.roles)
  exact.roles.each do |role|
    exact.stream(role).bytes.should eq(streams.stream(role).bytes)
    exact.stream(role).offsets.should eq(streams.stream(role).offsets)
  end

  short_limits = [
    CrystalClick::BinaryCodecLimits.new(64, measured.node_count - 1, measured.element_count, measured.wire_byte_count),
    CrystalClick::BinaryCodecLimits.new(64, measured.node_count, measured.element_count - 1, measured.wire_byte_count),
    CrystalClick::BinaryCodecLimits.new(64, measured.node_count, measured.element_count, measured.wire_byte_count - 1),
  ]
  short_limits.each do |limits|
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkCodec.encode_with_budget(type, rows, CrystalClick::BinaryCodecBudget.new(limits, true))
    end
  end
  streams
end

private def w144_assert_exact_decode_limits(
  type : CrystalClick::BinaryDataType,
  streams : CrystalClick::BinaryBulkStreams,
  rows_per_mark : Array(UInt64),
  first_mark : Int = 0,
  mark_count : Int? = nil,
) : Nil
  measured = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS)
  decoded = CrystalClick::BinaryBulkCodec.decode_with_budget(
    type,
    streams,
    rows_per_mark,
    measured,
    first_mark: first_mark,
    mark_count: mark_count
  )
  measured.wire_byte_count.should eq(streams.total_input_byte_size.to_i64)

  exact_limits = CrystalClick::BinaryCodecLimits.new(
    max_depth: 64,
    max_nodes: measured.node_count,
    max_elements: measured.element_count,
    max_bytes: measured.wire_byte_count
  )
  exact_budget = CrystalClick::BinaryCodecBudget.new(exact_limits)
  exact = CrystalClick::BinaryBulkCodec.decode_with_budget(
    type,
    streams,
    rows_per_mark,
    exact_budget,
    first_mark: first_mark,
    mark_count: mark_count
  )
  {exact_budget.node_count, exact_budget.element_count, exact_budget.wire_byte_count}.should eq(
    {measured.node_count, measured.element_count, measured.wire_byte_count}
  )
  exact.size.should eq(decoded.size)

  short_limits = [
    CrystalClick::BinaryCodecLimits.new(64, measured.node_count - 1, measured.element_count, measured.wire_byte_count),
    CrystalClick::BinaryCodecLimits.new(64, measured.node_count, measured.element_count - 1, measured.wire_byte_count),
    CrystalClick::BinaryCodecLimits.new(64, measured.node_count, measured.element_count, measured.wire_byte_count - 1),
  ]
  short_limits.each do |limits|
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(
        type,
        streams,
        rows_per_mark,
        first_mark: first_mark,
        mark_count: mark_count,
        limits: limits
      )
    end
  end
end

describe "W144 recursive LowCardinality Float transport" do
  it "preserves Float32 raw key bytes and IDs through root bulk and matches standalone W142 accounting" do
    name = "Float32"
    float = CrystalClick::BinaryDataType.primitive(name)
    low = CrystalClick::BinaryDataType.low_cardinality(float)
    rows = [
      [
        w144_float_lc(low, name, 0x0000_0000_u64), # +0 reserved default
        w144_float_lc(low, name, 0x8000_0000_u64), # -0 is a distinct raw key
        w144_float_lc(low, name, 0x7fc0_1234_u64), # NaN payload A
        w144_float_lc(low, name, 0x7f80_0000_u64), # +infinity
      ] of CrystalClick::BinaryValue,
      [] of CrystalClick::BinaryValue,
      [
        w144_float_lc(low, name, 0xffc0_5678_u64), # signed NaN payload B
        w144_float_lc(low, name, 0xff80_0000_u64), # -infinity
        w144_float_lc(low, name, 0x0000_0001_u64), # smallest subnormal
        w144_float_lc(low, name, 0x3f80_0000_u64), # 1.0
      ] of CrystalClick::BinaryValue,
      [] of CrystalClick::BinaryValue,
      [] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)

    encoded = w144_assert_exact_encode_limits(low, rows)
    expected_dictionary = w144_float_dictionary(name, [
      0x0000_0000_u64, 0x8000_0000_u64, 0x7fc0_1234_u64, 0x7f80_0000_u64,
      0xffc0_5678_u64, 0xff80_0000_u64, 0x0000_0001_u64, 0x3f80_0000_u64,
    ] of UInt64)
    expected_indexes = w144_float_concat([
      w144_float_index_mark([0_u64, 1_u64, 2_u64, 3_u64], 0x500_u64),
      w144_float_index_mark([4_u64, 5_u64, 6_u64, 7_u64], 0x100_u64),
    ] of Bytes)
    encoded.roles.should eq(["root.dictionary", "root.indexes"])
    encoded.stream("root.dictionary").bytes.should eq(expected_dictionary)
    encoded.stream("root.dictionary").offsets.should eq([8_u64, 8_u64, 8_u64, 8_u64, 8_u64, 48_u64])
    encoded.stream("root.indexes").bytes.should eq(expected_indexes)
    encoded.stream("root.indexes").offsets.should eq([0_u64, 20_u64, 20_u64, 40_u64, 40_u64, 40_u64])
    encoded.total_input_byte_size.should eq(88_u64)

    standalone_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true)
    standalone = CrystalClick::BinaryLowCardinalityStorageCodec.encode_with_budget(low, rows, standalone_budget)
    bulk_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true)
    bulk = CrystalClick::BinaryBulkCodec.encode_with_budget(low, rows, bulk_budget)
    {bulk_budget.node_count, bulk_budget.element_count, bulk_budget.wire_byte_count}.should eq(
      {standalone_budget.node_count, standalone_budget.element_count, standalone_budget.wire_byte_count}
    )
    # Independent accounting: descriptor 2/1; K=5 metadata 17/17;
    # eight LC wrappers+scalars 16/8 plus eight IDs; default reserve 1/1;
    # seven distinct non-default keys 7/7. The physical lanes are 48+40 bytes.
    {bulk_budget.node_count, bulk_budget.element_count, bulk_budget.wire_byte_count}.should eq(
      {43_u64, 42_u64, 88_u64}
    )
    bulk.stream("root.dictionary").bytes.should eq(standalone.stream("root.dictionary").bytes)
    bulk.stream("root.indexes").bytes.should eq(standalone.stream("root.indexes").bytes)

    selected = CrystalClick::BinaryBulkCodec.decode(low, encoded, [4_u64, 0_u64, 4_u64, 0_u64, 0_u64], first_mark: 2, mark_count: 1)
    selected.size.should eq(1)
    selected[0].map { |value| value.child_at(0).bytes }.should eq([
      Bytes[0x78_u8, 0x56_u8, 0xc0_u8, 0xff_u8],
      Bytes[0x00_u8, 0x00_u8, 0x80_u8, 0xff_u8],
      Bytes[0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8],
      Bytes[0x00_u8, 0x00_u8, 0x80_u8, 0x3f_u8],
    ])
    w144_assert_exact_decode_limits(low, encoded, [4_u64, 0_u64, 4_u64, 0_u64, 0_u64], 2, 1)
  end

  it "preserves Float64 and BFloat16 NaN, zero, infinity, and subnormal payloads" do
    {
      {"Float64", [
        0x0000_0000_0000_0000_u64, 0x8000_0000_0000_0000_u64,
        0x7ff8_0000_0000_1234_u64, 0x7ff0_0000_0000_0000_u64,
        0xfff8_0000_0000_5678_u64, 0xfff0_0000_0000_0000_u64,
        0x0000_0000_0000_0001_u64, 0x3ff0_0000_0000_0000_u64,
      ] of UInt64},
      {"BFloat16", [
        0x0000_u64, 0x8000_u64, 0x7fc1_u64, 0x7f80_u64,
        0xffc2_u64, 0xff80_u64, 0x0001_u64, 0x3f80_u64,
      ] of UInt64},
    }.each do |scenario|
      name = scenario[0]
      entries = scenario[1]
      low = CrystalClick::BinaryDataType.low_cardinality(CrystalClick::BinaryDataType.primitive(name))
      rows = [
        entries[0..3].map { |bits| w144_float_lc(low, name, bits) },
        [] of CrystalClick::BinaryValue,
        entries[4..7].map { |bits| w144_float_lc(low, name, bits) },
      ] of Array(CrystalClick::BinaryValue)
      encoded = w144_assert_exact_encode_limits(low, rows)
      encoded.stream("root.dictionary").bytes.should eq(w144_float_dictionary(name, entries))
      encoded.stream("root.indexes").bytes.should eq(w144_float_concat([
        w144_float_index_mark([0_u64, 1_u64, 2_u64, 3_u64], 0x500_u64),
        w144_float_index_mark([4_u64, 5_u64, 6_u64, 7_u64], 0x100_u64),
      ] of Bytes))
      decoded = CrystalClick::BinaryBulkCodec.decode(low, encoded, [4_u64, 0_u64, 4_u64])
      decoded[0].map { |value| value.child_at(0).bytes }.should eq(entries[0..3].map { |bits| w144_float_scalar_bytes(name, bits) })
      decoded[2].map { |value| value.child_at(0).bytes }.should eq(entries[4..7].map { |bits| w144_float_scalar_bytes(name, bits) })
    end
  end

  it "reuses identical raw negative-zero and NaN IDs while keeping distinct NaN payloads separate" do
    [
      {"Float32", 0x8000_0000_u64, 0x7fc0_1234_u64, 0xffc0_5678_u64},
      {"Float64", 0x8000_0000_0000_0000_u64, 0x7ff8_0000_0000_1234_u64, 0xfff8_0000_0000_5678_u64},
      {"BFloat16", 0x8000_u64, 0x7fc1_u64, 0xffc2_u64},
    ].each do |scenario|
      name = scenario[0]
      minus_zero = scenario[1]
      nan_a = scenario[2]
      nan_b = scenario[3]
      low = CrystalClick::BinaryDataType.low_cardinality(CrystalClick::BinaryDataType.primitive(name))
      rows = [
        [
          w144_float_lc(low, name, 0_u64),
          w144_float_lc(low, name, minus_zero),
          w144_float_lc(low, name, nan_a),
        ] of CrystalClick::BinaryValue,
        [
          w144_float_lc(low, name, nan_a),
          w144_float_lc(low, name, minus_zero),
          w144_float_lc(low, name, nan_b),
        ] of CrystalClick::BinaryValue,
      ] of Array(CrystalClick::BinaryValue)

      encoded = CrystalClick::BinaryBulkCodec.encode(low, rows)
      encoded.stream("root.dictionary").bytes.should eq(w144_float_dictionary(name, [0_u64, minus_zero, nan_a, nan_b] of UInt64))
      encoded.stream("root.indexes").bytes.should eq(w144_float_concat([
        w144_float_index_mark([0_u64, 1_u64, 2_u64], 0x500_u64),
        w144_float_index_mark([2_u64, 1_u64, 3_u64], 0x100_u64),
      ] of Bytes))
    end
  end

  it "keeps Nullable(Float) NULL separate from the raw +0 default for each float width" do
    ["Float32", "Float64", "BFloat16"].each do |name|
      float = CrystalClick::BinaryDataType.primitive(name)
      nullable = CrystalClick::BinaryDataType.nullable(float)
      low = CrystalClick::BinaryDataType.low_cardinality(nullable)
      minus_zero = case name
                   when "Float32" then 0x8000_0000_u64
                   when "Float64" then 0x8000_0000_0000_0000_u64
                   else                0x8000_u64
                   end
      nan = case name
            when "Float32" then 0x7fc0_4321_u64
            when "Float64" then 0x7ff8_0000_0000_4321_u64
            else                0x7fc3_u64
            end
      rows = [
        [
          w144_nullable_float_lc(low, name, nil),
          w144_nullable_float_lc(low, name, 0_u64),
          w144_nullable_float_lc(low, name, minus_zero),
          w144_nullable_float_lc(low, name, nan),
        ] of CrystalClick::BinaryValue,
        [w144_nullable_float_lc(low, name, nil)] of CrystalClick::BinaryValue,
      ] of Array(CrystalClick::BinaryValue)

      encoded = w144_assert_exact_encode_limits(low, rows)
      encoded.stream("root.dictionary").bytes.should eq(w144_float_dictionary(name, [0_u64, 0_u64, minus_zero, nan] of UInt64))
      encoded.stream("root.indexes").bytes.should eq(w144_float_concat([
        w144_float_index_mark([0_u64, 1_u64, 2_u64, 3_u64], 0x500_u64),
        w144_float_index_mark([0_u64], 0x100_u64),
      ] of Bytes))

      decoded = CrystalClick::BinaryBulkCodec.decode(low, encoded, [4_u64, 1_u64])
      decoded[0][0].child_at(0).is_null?.should be_true
      decoded[0][1].child_at(0).child_at(0).bytes.should eq(w144_float_scalar_bytes(name, 0_u64))
      decoded[0][2].child_at(0).child_at(0).bytes.should eq(w144_float_scalar_bytes(name, minus_zero))
      decoded[0][3].child_at(0).child_at(0).bytes.should eq(w144_float_scalar_bytes(name, nan))
      decoded[1][0].child_at(0).is_null?.should be_true
      w144_assert_exact_decode_limits(low, encoded, [4_u64, 1_u64])
    end
  end

  it "rejects duplicate identical non-reserved NaN keys for every raw float width" do
    [
      {"Float32", 0x7fc0_1234_u64},
      {"Float64", 0x7ff8_0000_0000_1234_u64},
      {"BFloat16", 0x7fc1_u64},
    ].each do |scenario|
      name = scenario[0]
      nan = scenario[1]
      low = CrystalClick::BinaryDataType.low_cardinality(CrystalClick::BinaryDataType.primitive(name))
      dictionary = w144_float_dictionary(name, [0_u64, nan, nan] of UInt64)
      indexes = w144_float_index_mark([1_u64], 0x500_u64)
      malformed = w144_float_streams(
        1,
        dictionary,
        [8_u64, dictionary.size.to_u64],
        indexes,
        [0_u64, indexes.size.to_u64]
      )

      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryBulkCodec.decode(low, malformed, [1_u64])
      end
    end
  end

  it "uses flattened Array occurrence counts and retains dictionary history for a selected later mark" do
    name = "Float64"
    float = CrystalClick::BinaryDataType.primitive(name)
    low = CrystalClick::BinaryDataType.low_cardinality(float)
    array = CrystalClick::BinaryDataType.array(low)
    array_value = ->(bits : Array(UInt64)) do
      elements = bits.map { |raw| w144_float_lc(low, name, raw) }
      CrystalClick::BinaryValue.array(array, elements)
    end
    rows = [
      [array_value.call([0x8000_0000_0000_0000_u64, 0x7ff8_0000_0000_1234_u64]), array_value.call([] of UInt64)],
      [array_value.call([] of UInt64)],
      [array_value.call([0xfff8_0000_0000_5678_u64, 0x0000_0000_0000_0001_u64])],
    ] of Array(CrystalClick::BinaryValue)
    encoded = CrystalClick::BinaryBulkCodec.encode(array, rows)
    encoded.stream("root.sizes").bytes.should eq(w144_float_concat([
      w144_float_u64(2_u64), w144_float_u64(0_u64), w144_float_u64(0_u64), w144_float_u64(2_u64),
    ] of Bytes))
    encoded.stream("root.elements.dictionary").bytes.should eq(w144_float_dictionary(name, [
      0x0000_0000_0000_0000_u64, 0x8000_0000_0000_0000_u64,
      0x7ff8_0000_0000_1234_u64, 0xfff8_0000_0000_5678_u64,
      0x0000_0000_0000_0001_u64,
    ] of UInt64))
    encoded.stream("root.elements.indexes").bytes.should eq(w144_float_concat([
      w144_float_index_mark([1_u64, 2_u64], 0x500_u64),
      w144_float_index_mark([3_u64, 4_u64], 0x100_u64),
    ] of Bytes))
    selected = CrystalClick::BinaryBulkCodec.decode(array, encoded, [2_u64, 1_u64, 1_u64], first_mark: 2, mark_count: 1)
    selected.size.should eq(1)
    selected[0][0].elements.map { |value| value.child_at(0).bytes }.should eq([
      w144_float_scalar_bytes(name, 0xfff8_0000_0000_5678_u64),
      w144_float_scalar_bytes(name, 0x0000_0000_0000_0001_u64),
    ])
    w144_assert_exact_decode_limits(array, encoded, [2_u64, 1_u64, 1_u64], 2, 1)
  end

  it "keeps a Float LC Tuple site independent from an ordinary sibling lane" do
    name = "Float32"
    float = CrystalClick::BinaryDataType.primitive(name)
    low = CrystalClick::BinaryDataType.low_cardinality(float)
    string = CrystalClick::BinaryDataType.primitive("String")
    tuple = CrystalClick::BinaryDataType.tuple([low, string] of CrystalClick::BinaryDataType, ["reading", "label"] of String)
    row = ->(bits : UInt64, label : String) do
      CrystalClick::BinaryValue.tuple(tuple, [w144_float_lc(low, name, bits), CrystalClick::BinaryValue.string(label)] of CrystalClick::BinaryValue)
    end
    rows = [
      [row.call(0x8000_0000_u64, "minus"), row.call(0x7fc0_1234_u64, "nan")],
      [row.call(0x0000_0000_u64, "zero")],
    ] of Array(CrystalClick::BinaryValue)
    encoded = CrystalClick::BinaryBulkCodec.encode(tuple, rows, profile: CrystalClick::BinaryBulkProfile.with_size_stream)
    encoded.roles.should contain("root.field.0.dictionary")
    encoded.roles.should contain("root.field.0.indexes")
    encoded.stream("root.field.0.dictionary").bytes.should eq(w144_float_dictionary(name, [
      0x0000_0000_u64, 0x8000_0000_u64, 0x7fc0_1234_u64,
    ] of UInt64))
    encoded.stream("root.field.0.indexes").bytes.should eq(w144_float_concat([
      w144_float_index_mark([1_u64, 2_u64], 0x500_u64),
      w144_float_index_mark([0_u64], 0x100_u64),
    ] of Bytes))
    encoded.stream("root.field.1.data").bytes.should eq(Bytes[0x6d_u8, 0x69_u8, 0x6e_u8, 0x75_u8, 0x73_u8, 0x6e_u8, 0x61_u8, 0x6e_u8, 0x7a_u8, 0x65_u8, 0x72_u8, 0x6f_u8])
    encoded.stream("root.field.1.string_sizes").bytes.should eq(w144_float_concat([
      w144_float_u64(5_u64), w144_float_u64(3_u64), w144_float_u64(4_u64),
    ] of Bytes))
    decoded = CrystalClick::BinaryBulkCodec.decode(tuple, encoded, [2_u64, 1_u64], profile: CrystalClick::BinaryBulkProfile.with_size_stream)
    decoded[0][0].child_at(0).child_at(0).bytes.should eq(w144_float_scalar_bytes(name, 0x8000_0000_u64))
    decoded[0][1].child_at(0).child_at(0).bytes.should eq(w144_float_scalar_bytes(name, 0x7fc0_1234_u64))
    decoded[1][0].child_at(1).as_string.should eq("zero")
  end

  it "keeps two Map Float LC dictionaries independent across empty and populated maps" do
    key_name = "BFloat16"
    value_name = "Float64"
    key_type = CrystalClick::BinaryDataType.low_cardinality(CrystalClick::BinaryDataType.primitive(key_name))
    value_type = CrystalClick::BinaryDataType.low_cardinality(CrystalClick::BinaryDataType.primitive(value_name))
    map = CrystalClick::BinaryDataType.map(key_type, value_type)
    key = ->(bits : UInt64) { w144_float_lc(key_type, key_name, bits) }
    value = ->(bits : UInt64) { w144_float_lc(value_type, value_name, bits) }
    rows = [
      [CrystalClick::BinaryValue.map(map, [key.call(0x3f80_u64), value.call(0x0000_0000_0000_0000_u64), key.call(0x4000_u64), value.call(0x7ff8_0000_0000_1234_u64)] of CrystalClick::BinaryValue)],
      [CrystalClick::BinaryValue.map(map, [] of CrystalClick::BinaryValue), CrystalClick::BinaryValue.map(map, [key.call(0x8000_u64), value.call(0x8000_0000_0000_0000_u64)] of CrystalClick::BinaryValue)],
    ] of Array(CrystalClick::BinaryValue)

    encoded = CrystalClick::BinaryBulkCodec.encode(map, rows)
    encoded.stream("root.sizes").bytes.should eq(w144_float_concat([
      w144_float_u64(2_u64), w144_float_u64(0_u64), w144_float_u64(1_u64),
    ] of Bytes))
    encoded.stream("root.elements.field.0.dictionary").bytes.should eq(w144_float_dictionary(key_name, [
      0x0000_u64, 0x3f80_u64, 0x4000_u64, 0x8000_u64,
    ] of UInt64))
    encoded.stream("root.elements.field.1.dictionary").bytes.should eq(w144_float_dictionary(value_name, [
      0x0000_0000_0000_0000_u64, 0x7ff8_0000_0000_1234_u64, 0x8000_0000_0000_0000_u64,
    ] of UInt64))
    encoded.stream("root.elements.field.0.indexes").bytes.should eq(w144_float_concat([
      w144_float_index_mark([1_u64, 2_u64], 0x500_u64),
      w144_float_index_mark([3_u64], 0x100_u64),
    ] of Bytes))
    encoded.stream("root.elements.field.1.indexes").bytes.should eq(w144_float_concat([
      w144_float_index_mark([0_u64, 1_u64], 0x500_u64),
      w144_float_index_mark([2_u64], 0x100_u64),
    ] of Bytes))
    selected = CrystalClick::BinaryBulkCodec.decode(map, encoded, [1_u64, 2_u64], first_mark: 1, mark_count: 1)
    selected[0][0].element_count.should eq(0)
    pair = selected[0][1].elements
    pair[0].child_at(0).bytes.should eq(w144_float_scalar_bytes(key_name, 0x8000_u64))
    pair[1].child_at(0).bytes.should eq(w144_float_scalar_bytes(value_name, 0x8000_0000_0000_0000_u64))
  end

  it "emits version-only dictionaries for all-empty nested Float LC occurrences" do
    ["Float32", "Float64", "BFloat16"].each do |name|
      low = CrystalClick::BinaryDataType.low_cardinality(CrystalClick::BinaryDataType.primitive(name))
      array = CrystalClick::BinaryDataType.array(low)
      empty = CrystalClick::BinaryValue.array(array, [] of CrystalClick::BinaryValue)
      rows = [[empty, empty], [empty]] of Array(CrystalClick::BinaryValue)
      encoded = CrystalClick::BinaryBulkCodec.encode(array, rows)
      encoded.stream("root.elements.dictionary").bytes.should eq(w144_float_u64(1_u64))
      encoded.stream("root.elements.dictionary").offsets.should eq([8_u64, 8_u64, 8_u64])
      encoded.stream("root.elements.indexes").bytes.should be_empty
      encoded.stream("root.elements.indexes").offsets.should eq([0_u64, 0_u64, 0_u64])
      decoded = CrystalClick::BinaryBulkCodec.decode(array, encoded, [2_u64, 1_u64])
      decoded.each { |mark| mark.each { |value| value.element_count.should eq(0) } }
    end
  end

  it "validates corrupt unselected Float index marks before returning a selected window" do
    name = "Float32"
    low = CrystalClick::BinaryDataType.low_cardinality(CrystalClick::BinaryDataType.primitive(name))
    dictionary = w144_float_dictionary(name, [0x0000_0000_u64, 0x8000_0000_u64])
    indexes = w144_float_concat([
      w144_float_index_mark([1_u64], 0x500_u64),
      w144_float_index_mark([2_u64], 0x100_u64), # invalid id exists outside requested mark 2
      w144_float_index_mark([1_u64], 0x100_u64),
    ] of Bytes)
    malformed = w144_float_streams(3, dictionary, [8_u64, 8_u64, 8_u64, 24_u64], indexes, [0_u64, 17_u64, 34_u64, 51_u64])
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(low, malformed, [1_u64, 1_u64, 1_u64], first_mark: 2, mark_count: 1)
    end
  end

  it "keeps Dynamic closed while composing raw Float LC through paired typed Object lanes" do
    name = "Float32"
    low = CrystalClick::BinaryDataType.low_cardinality(CrystalClick::BinaryDataType.primitive(name))
    value = w144_float_lc(low, name, 0x7fc0_1234_u64)

    [CrystalClick::BinaryBulkProfile.single_stream, CrystalClick::BinaryBulkProfile.with_size_stream].each do |profile|
      physical = CrystalClick::BinaryBulkPhysicalPlan.new(low, "column", profile: profile)
      physical.stream_names.should eq({
        "root.dictionary" => "column.dict",
        "root.indexes"    => "column",
      })
    end

    dynamic = CrystalClick::DynamicStructure.new([low] of CrystalClick::BinaryDataType)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::DynamicValueCodec.encode(dynamic, [[value]] of Array(CrystalClick::BinaryValue))
    end
    empty_discriminator = CrystalClick::DynamicDiscriminatorCodec.encode(dynamic, [] of Array(UInt8))
    empty_lc = w144_float_streams(0, w144_float_u64(1_u64), [8_u64], Bytes.empty, [0_u64])
    empty_string = CrystalClick::BinaryBulkStreams.new(0, {
      "root.data" => CrystalClick::BinaryBulkStream.new(Bytes.empty, [0_u64]),
    } of String => CrystalClick::BinaryBulkStream)
    dynamic_streams = CrystalClick::DynamicValueStreams.new(
      empty_discriminator,
      {"SharedVariant" => empty_string, low.name => empty_lc} of String => CrystalClick::BinaryBulkStreams
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::DynamicValueCodec.decode(dynamic, dynamic_streams, first_mark: 0, mark_count: 0)
    end

    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure
    )
    plan = CrystalClick::ObjectDocumentPlan.new(structures, {"typed" => low})
    document = CrystalClick::ObjectDocument.new({"typed" => value} of String => CrystalClick::BinaryValue)
    paired = CrystalClick::ObjectDocumentCodec.encode(plan, [[document]] of Array(CrystalClick::ObjectDocument))
    paired_value = CrystalClick::ObjectDocumentCodec.decode({"typed" => low} of String => CrystalClick::BinaryDataType, paired)[0][0].value_for("typed")
    paired_value.child_at(0).bytes.should eq(value.child_at(0).bytes)

    typed_dictionary = w144_float_dictionary(name, [0_u64, 0x3f80_0000_u64])
    typed_streams = w144_float_streams(1, typed_dictionary, [8_u64, 24_u64], w144_float_index_mark([1_u64], 0x500_u64), [0_u64, 17_u64])
    metadata = CrystalClick::ObjectDynamicStructureCodec.encode(structures)
    object_streams = CrystalClick::ObjectDocumentStreams.new(
      metadata,
      [1_u64],
      {"typed" => typed_streams} of String => CrystalClick::BinaryBulkStreams,
      {} of String => CrystalClick::DynamicValueStreams,
      paired.shared
    )
    decoded_typed = CrystalClick::ObjectDocumentCodec.decode(
      {"typed" => low} of String => CrystalClick::BinaryDataType,
      object_streams,
    )
    decoded_typed[0][0].value_for("typed").child_at(0).bytes.should eq(
      w144_float_scalar_bytes(name, 0x3f80_0000_u64)
    )
  end
end
