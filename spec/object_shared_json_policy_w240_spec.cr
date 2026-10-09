require "./spec_helper"

private def w240p_limits(
  max_depth : Int = 64,
  max_nodes : Int = 4_096,
  max_elements : Int = 1_000_000,
  max_bytes : Int = 64 * 1024 * 1024,
) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(max_depth, max_nodes, max_elements, max_bytes)
end

private def w240p_hidden_leaf(kind : Symbol) : CrystalClick::BinaryDataType
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  string = CrystalClick::BinaryDataType.primitive("String")
  case kind
  when :variant
    CrystalClick::BinaryDataType.variant([uint8, string] of CrystalClick::BinaryDataType)
  when :dynamic
    CrystalClick::BinaryDataType.dynamic(1)
  when :low_cardinality
    CrystalClick::BinaryDataType.low_cardinality(string)
  else
    raise "unrostered W240 hidden JSON leaf"
  end
end

private def w240p_hidden_typed_json_value(kind : Symbol) : CrystalClick::BinaryValue
  leaf_type = w240p_hidden_leaf(kind)
  array_type = CrystalClick::BinaryDataType.array(leaf_type)
  json_type = CrystalClick::BinaryDataType.json(
    max_dynamic_paths: 1,
    max_dynamic_types: 1,
    typed_paths: {"x" => array_type} of String => CrystalClick::BinaryDataType,
  )
  empty_array = CrystalClick::BinaryValue.array(array_type, [] of CrystalClick::BinaryValue)
  row = CrystalClick::BinaryJsonRow.new(
    json_type,
    [{"x", empty_array}] of Tuple(String, CrystalClick::BinaryValue),
  )
  CrystalClick::BinaryValue.json(json_type, row)
end

private def w240p_json_uint8_value(value : UInt8) : CrystalClick::BinaryValue
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  json_type = CrystalClick::BinaryDataType.json(
    max_dynamic_paths: 1,
    max_dynamic_types: 1,
    typed_paths: {"v" => uint8} of String => CrystalClick::BinaryDataType,
  )
  row = CrystalClick::BinaryJsonRow.new(
    json_type,
    [{"v", CrystalClick::BinaryValue.fixed(uint8, Bytes[value])}] of Tuple(String, CrystalClick::BinaryValue),
  )
  CrystalClick::BinaryValue.json(json_type, row)
end

private def w240p_raw_json_typed_tag(tag : UInt8) : Bytes
  # JSON v0, max_dynamic_paths=1024, max_dynamic_types=32, then one typed
  # path "x" with a DataType tag. The tag is intentionally the final byte:
  # policy rejection must precede parsing that type's missing payload.
  Bytes[
    CrystalClick::BinaryDataType::TAG_JSON,
    0_u8,
    0x80_u8,
    0x08_u8,
    CrystalClick::BinaryJsonType::MAX_DYNAMIC_TYPES.to_u8,
    1_u8,
    1_u8,
    0x78_u8,
    tag,
  ]
end

private def w240p_copy_structure(paths : Array(String)) : Array(CrystalClick::ObjectSharedChunkStructure)
  [
    CrystalClick::ObjectSharedChunkStructure.new(
      1_u64,
      paths,
      {0_u64, 0_u64},
      {0_u64, 0_u64},
      {0_u64, 0_u64},
    ),
  ] of CrystalClick::ObjectSharedChunkStructure
end

describe "W240 shared JSON envelope descriptor policy" do
  {:variant, :dynamic, :low_cardinality}.each do |kind|
    it "rejects #{kind} hidden below typed JSON metadata even when the array is empty" do
      value = w240p_hidden_typed_json_value(kind)
      ordinary_wire = CrystalClick::BinaryValueCodec.encode(value)
      decoded_ordinary = CrystalClick::BinaryValueCodec.decode(ordinary_wire)
      CrystalClick::BinaryValueCodec.encode(decoded_ordinary).should eq(ordinary_wire)

      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryValueCodec.encode_shared_json_envelope(
          value,
          CrystalClick::BinaryCodecBudget.new(w240p_limits, true),
        )
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryValueCodec.decode_shared_json_envelope(
          ordinary_wire,
          CrystalClick::BinaryCodecBudget.new(w240p_limits),
        )
      end
    end
  end

  it "rejects every forbidden typed DataType wire tag before parsing its payload" do
    forbidden_tags = [
      {CrystalClick::BinaryDataType::TAG_DYNAMIC, "Dynamic"},
      {CrystalClick::BinaryDataType::TAG_VARIANT, "Variant"},
      {CrystalClick::BinaryDataType::TAG_LOW_CARDINALITY, "LowCardinality"},
      {CrystalClick::BinaryDataType::TAG_AGGREGATE_FUNCTION, "AggregateFunction"},
      {CrystalClick::BinaryDataType::TAG_QBIT, "QBit"},
      {CrystalClick::BinaryDataType::TAG_QBIT_STRIDE, "QBit stride"},
    ] of Tuple(UInt8, String)

    forbidden_tags.each do |entry|
      tag = entry[0]
      expected_name = entry[1]
      error = expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryValueCodec.decode_shared_json_envelope(
          w240p_raw_json_typed_tag(tag),
          CrystalClick::BinaryCodecBudget.new(w240p_limits),
        )
      end
      expected_policy_name = expected_name == "QBit stride" ? "QBit" : expected_name
      error.message.to_s.should contain(expected_policy_name)
    end
  end

  it "keeps the default borrowed JSON fence and charges valid shared work exactly once" do
    value = w240p_json_uint8_value(37_u8)
    wire = CrystalClick::BinaryValueCodec.encode(value)

    expect_raises(CrystalClick::UnsupportedFormatError, "JSON") do
      CrystalClick::BinaryValueCodec.encode_borrowed(
        value,
        CrystalClick::BinaryCodecBudget.new(w240p_limits, true),
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError, "JSON") do
      CrystalClick::BinaryValueCodec.decode_borrowed(
        wire,
        CrystalClick::BinaryCodecBudget.new(w240p_limits),
      )
    end

    write_budget = CrystalClick::BinaryCodecBudget.new(w240p_limits, true)
    CrystalClick::BinaryValueCodec.encode_shared_json_envelope(value, write_budget).should eq(wire)
    write_budget.node_count.should eq(6_i64)
    write_budget.element_count.should eq(4_i64)
    write_budget.wire_byte_count.should eq(0_i64) # the shared Object owner charges final bytes

    read_budget = CrystalClick::BinaryCodecBudget.new(w240p_limits)
    read_budget.charge_wire_bytes(wire.size.to_u64)
    decoded = CrystalClick::BinaryValueCodec.decode_shared_json_envelope(wire, read_budget)
    CrystalClick::BinaryValueCodec.encode(decoded).should eq(wire)
    read_budget.node_count.should eq(6_i64)
    read_budget.element_count.should eq(4_i64)
    read_budget.wire_byte_count.should eq(wire.size.to_i64)
  end

  it "does not apply MAP's new exclusions to Copy's independently admitted Variant and LowCardinality actuals" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    string = CrystalClick::BinaryDataType.primitive("String")
    variant_type = CrystalClick::BinaryDataType.variant([uint8, string] of CrystalClick::BinaryDataType)
    uint8_arm = (0...variant_type.child_count).find do |index|
      variant_type.child_at(index) == uint8
    end.not_nil!
    variant = CrystalClick::BinaryValue.variant(
      variant_type,
      uint8_arm,
      CrystalClick::BinaryValue.fixed(uint8, Bytes[19_u8]),
    )
    low_cardinality_type = CrystalClick::BinaryDataType.low_cardinality(string)
    low_cardinality = CrystalClick::BinaryValue.low_cardinality(
      low_cardinality_type,
      CrystalClick::BinaryValue.string("retained"),
    )
    paths = ["a_low_cardinality", "z_variant"] of String
    values = [low_cardinality, variant] of CrystalClick::BinaryValue
    entries = Array(CrystalClick::ObjectSharedMapEntry).new(2)
    paths.each_with_index do |path, index|
      entries << CrystalClick::ObjectSharedMapEntry.new(path.to_slice, values[index])
    end
    rows = [CrystalClick::ObjectSharedMapRow.new(entries)] of CrystalClick::ObjectSharedMapRow
    structures = w240p_copy_structure(paths)

    streams = CrystalClick::ObjectSharedCopyCodec.encode(rows, structures)
    decoded = CrystalClick::ObjectSharedCopyCodec.decode(
      streams.sizes,
      streams.indexes,
      streams.values,
      structures,
    )
    2.times do |index|
      CrystalClick::BinaryValueCodec.encode(decoded[0].entry_at(index).value).should eq(
        CrystalClick::BinaryValueCodec.encode(values[index]),
      )
    end
  end
end
