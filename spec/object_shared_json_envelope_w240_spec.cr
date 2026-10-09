require "./spec_helper"

private def w240e_limits(
  max_depth : Int = 64,
  max_nodes : Int = 4_096,
  max_elements : Int = 1_000_000,
  max_bytes : Int = 64 * 1024 * 1024,
) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(max_depth, max_nodes, max_elements, max_bytes)
end

private def w240e_json_type : CrystalClick::BinaryDataType
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  CrystalClick::BinaryDataType.json(
    max_dynamic_paths: 1,
    max_dynamic_types: 1,
    typed_paths: {"v" => uint8} of String => CrystalClick::BinaryDataType,
  )
end

private def w240e_json_value(value : UInt8) : CrystalClick::BinaryValue
  type = w240e_json_type
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  row = CrystalClick::BinaryJsonRow.new(
    type,
    [{"v", CrystalClick::BinaryValue.fixed(uint8, Bytes[value])}] of Tuple(String, CrystalClick::BinaryValue),
  )
  CrystalClick::BinaryValue.json(type, row)
end

private def w240e_empty_json_value : CrystalClick::BinaryValue
  type = CrystalClick::BinaryDataType.json
  row = CrystalClick::BinaryJsonRow.new(type, [] of Tuple(String, CrystalClick::BinaryValue))
  CrystalClick::BinaryValue.json(type, row)
end

private def w240e_assert_value_equal!(actual : CrystalClick::BinaryValue, expected : CrystalClick::BinaryValue) : Nil
  CrystalClick::BinaryValueCodec.encode(actual).should eq(CrystalClick::BinaryValueCodec.encode(expected))
end

private def w240e_concat(parts : Array(Bytes)) : Bytes
  size = 0
  parts.each { |part| size += part.size }
  output = Bytes.new(size)
  offset = 0
  parts.each do |part|
    part.each do |byte|
      output[offset] = byte
      offset += 1
    end
  end
  output
end

private def w240e_var_uint(value : UInt64) : Bytes
  output = [] of UInt8
  remaining = value
  loop do
    payload = (remaining & 0x7f_u64).to_u8
    remaining >>= 7
    output << (remaining == 0_u64 ? payload : payload | 0x80_u8)
    break if remaining == 0_u64
  end
  Bytes.new(output.size) { |index| output[index] }
end

private def w240e_frame(bytes : Bytes) : Bytes
  w240e_concat([w240e_var_uint(bytes.size.to_u64), bytes] of Bytes)
end

private def w240e_sizes(count : UInt64) : Bytes
  output = Bytes.new(8)
  8.times do |byte|
    output[byte] = ((count >> (byte * 8)) & 0xff_u64).to_u8
  end
  output
end

private def w240e_row(paths : Array(String), values : Array(CrystalClick::BinaryValue)) : CrystalClick::ObjectSharedMapRow
  raise "W240 shared row path/value mismatch" unless paths.size == values.size
  entries = Array(CrystalClick::ObjectSharedMapEntry).new(paths.size)
  paths.each_with_index do |path, index|
    entries << CrystalClick::ObjectSharedMapEntry.new(path.to_slice, values[index])
  end
  CrystalClick::ObjectSharedMapRow.new(entries)
end

private def w240e_copy_structure(paths : Array(String)) : Array(CrystalClick::ObjectSharedChunkStructure)
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

private def w240e_document_plan : CrystalClick::ObjectDocumentPlan
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([] of String),
    {} of String => CrystalClick::DynamicStructure,
  )
  CrystalClick::ObjectDocumentPlan.new(
    structures,
    {} of String => CrystalClick::BinaryDataType,
  )
end

describe "W240 shared JSON scalar envelopes" do
  it "composes JSON, Array(JSON), empty arrays, and deeper static wrappers" do
    json = w240e_json_value(41_u8)
    json_type = json.type
    array_type = CrystalClick::BinaryDataType.array(json_type)
    array = CrystalClick::BinaryValue.array(array_type, [json] of CrystalClick::BinaryValue)
    empty_array = CrystalClick::BinaryValue.array(array_type, [] of CrystalClick::BinaryValue)
    tuple_type = CrystalClick::BinaryDataType.tuple(
      [CrystalClick::BinaryDataType.primitive("UInt8"), array_type] of CrystalClick::BinaryDataType,
    )
    wrapped = CrystalClick::BinaryValue.tuple(
      tuple_type,
      [CrystalClick::BinaryValue.fixed(tuple_type.child_at(0), Bytes[9_u8]), array] of CrystalClick::BinaryValue,
    )

    [json, array, empty_array, wrapped].each do |expected|
      budget = CrystalClick::BinaryCodecBudget.new(w240e_limits, true)
      encoded = CrystalClick::BinaryValueCodec.encode_shared_json_envelope(expected, budget)
      encoded.should eq(CrystalClick::BinaryValueCodec.encode(expected))

      read_budget = CrystalClick::BinaryCodecBudget.new(w240e_limits)
      decoded = CrystalClick::BinaryValueCodec.decode_shared_json_envelope(encoded, read_budget)
      w240e_assert_value_equal!(decoded, expected)
    end
  end

  it "keeps default borrowed envelope JSON rejection and the borrowed Custom behavior" do
    json = w240e_json_value(42_u8)
    array_type = CrystalClick::BinaryDataType.array(json.type)
    array_json = CrystalClick::BinaryValue.array(array_type, [json] of CrystalClick::BinaryValue)

    [json, array_json].each do |value|
      expect_raises(CrystalClick::UnsupportedFormatError, "JSON") do
        CrystalClick::BinaryValueCodec.encode_borrowed(
          value,
          CrystalClick::BinaryCodecBudget.new(w240e_limits, true),
        )
      end
      expect_raises(CrystalClick::UnsupportedFormatError, "JSON") do
        CrystalClick::BinaryValueCodec.decode_borrowed(
          CrystalClick::BinaryValueCodec.encode(value),
          CrystalClick::BinaryCodecBudget.new(w240e_limits),
        )
      end
    end

    point_type = CrystalClick::BinaryDataType.custom("Point")
    point_body_type = point_type.child_at(0)
    point_body = CrystalClick::BinaryValue.tuple(
      point_body_type,
      [
        CrystalClick::BinaryValue.float64_bits(0x3ff0_0000_0000_0000_u64),
        CrystalClick::BinaryValue.float64_bits(0x4000_0000_0000_0000_u64),
      ] of CrystalClick::BinaryValue,
    )
    point = CrystalClick::BinaryValue.custom(point_type, point_body)
    point_wire = CrystalClick::BinaryValueCodec.encode_borrowed(
      point,
      CrystalClick::BinaryCodecBudget.new(w240e_limits, true),
    )
    shared_point_wire = CrystalClick::BinaryValueCodec.encode_shared_json_envelope(
      point,
      CrystalClick::BinaryCodecBudget.new(w240e_limits, true),
    )
    shared_point_wire.should eq(point_wire)
    decoded_point = CrystalClick::BinaryValueCodec.decode_shared_json_envelope(
      point_wire,
      CrystalClick::BinaryCodecBudget.new(w240e_limits),
    )
    w240e_assert_value_equal!(decoded_point, point)
  end

  it "retains the non-JSON borrowed admission fences in the shared MAP envelope" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    string = CrystalClick::BinaryDataType.primitive("String")

    dynamic_type = CrystalClick::BinaryDataType.dynamic
    dynamic = CrystalClick::BinaryValue.dynamic(dynamic_type, CrystalClick::BinaryValue.fixed(uint8, Bytes[1_u8]))

    variant_type = CrystalClick::BinaryDataType.variant([uint8, string] of CrystalClick::BinaryDataType)
    uint8_arm = (0...variant_type.child_count).find { |index| variant_type.child_at(index) == uint8 }.not_nil!
    variant = CrystalClick::BinaryValue.variant(
      variant_type,
      uint8_arm,
      CrystalClick::BinaryValue.fixed(uint8, Bytes[2_u8]),
    )

    low_cardinality_type = CrystalClick::BinaryDataType.low_cardinality(string)
    low_cardinality = CrystalClick::BinaryValue.low_cardinality(
      low_cardinality_type,
      CrystalClick::BinaryValue.string("value"),
    )

    aggregate_type = CrystalClick::BinaryDataType.aggregate_count
    aggregate = CrystalClick::BinaryValue.aggregate_count_state(aggregate_type, 0_u64)

    qbit_type = CrystalClick::QBitType.new("Int8", 1_u64)
    qbit_descriptor = CrystalClick::BinaryDataType.qbit(qbit_type)
    qbit = CrystalClick::BinaryValue.qbit(qbit_descriptor, CrystalClick::QBitValue.new(qbit_type, Bytes[0_u8]))

    [
      {dynamic, "Dynamic"},
      {variant, "Variant"},
      {low_cardinality, "LowCardinality"},
      {aggregate, "AggregateFunction"},
      {qbit, "QBit"},
    ].each do |entry|
      value = entry[0]
      expected_message = entry[1]
      error = expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryValueCodec.encode_shared_json_envelope(
          value,
          CrystalClick::BinaryCodecBudget.new(w240e_limits, true),
        )
      end
      error.message.to_s.should contain(expected_message)
    end

    # Copy uses its stricter specialized Dynamic-child owner, so JSON opt-in
    # must not admit Custom Geo there.
    point_type = CrystalClick::BinaryDataType.custom("Point")
    point_body = CrystalClick::BinaryValue.tuple(
      point_type.child_at(0),
      [
        CrystalClick::BinaryValue.float64_bits(0x3ff0_0000_0000_0000_u64),
        CrystalClick::BinaryValue.float64_bits(0x4000_0000_0000_0000_u64),
      ] of CrystalClick::BinaryValue,
    )
    custom_row = w240e_row(
      ["x"] of String,
      [CrystalClick::BinaryValue.custom(point_type, point_body)] of CrystalClick::BinaryValue,
    )
    expect_raises(CrystalClick::UnsupportedFormatError, "Custom Geo") do
      CrystalClick::ObjectSharedCopyCodec.encode(
        [custom_row] of CrystalClick::ObjectSharedMapRow,
        w240e_copy_structure(["x"] of String),
      )
    end
  end

  it "round-trips late JSON entries through MAP, Object MAP, and Copy" do
    json_type = w240e_json_type
    json = w240e_json_value(43_u8)
    array_json = CrystalClick::BinaryValue.array(
      CrystalClick::BinaryDataType.array(json_type),
      [json] of CrystalClick::BinaryValue,
    )
    values = [CrystalClick::BinaryValue.bool(true), array_json] of CrystalClick::BinaryValue
    paths = ["a", "z"] of String

    map_rows = [w240e_row(paths, values)] of CrystalClick::ObjectSharedMapRow
    map = CrystalClick::ObjectSharedMapCodec.encode(map_rows)
    map_decoded = CrystalClick::ObjectSharedMapCodec.decode(map.sizes, map.paths, map.values, map_rows.size)
    map_decoded[0].entry_at(1).path.should eq(Bytes[0x7a_u8])
    w240e_assert_value_equal!(map_decoded[0].entry_at(1).value, array_json)

    document = CrystalClick::ObjectDocument.new(
      {"a" => values[0], "z" => values[1]} of String => CrystalClick::BinaryValue,
    )
    document_streams = CrystalClick::ObjectDocumentCodec.encode(
      w240e_document_plan,
      [[document] of CrystalClick::ObjectDocument] of Array(CrystalClick::ObjectDocument),
    )
    decoded_documents = CrystalClick::ObjectDocumentCodec.decode(
      {} of String => CrystalClick::BinaryDataType,
      document_streams,
    )
    w240e_assert_value_equal!(decoded_documents[0][0].value_for("z"), array_json)

    copy_rows = [w240e_row(paths, values)] of CrystalClick::ObjectSharedMapRow
    structures = w240e_copy_structure(paths)
    copy = CrystalClick::ObjectSharedCopyCodec.encode(copy_rows, structures)
    copy_decoded = CrystalClick::ObjectSharedCopyCodec.decode(
      copy.sizes,
      copy.indexes,
      copy.values,
      structures,
    )
    w240e_assert_value_equal!(copy_decoded[0].entry_at(1).value, array_json)
  end

  it "decodes an independently framed shared MAP envelope" do
    expected = w240e_json_value(44_u8)
    envelope = CrystalClick::BinaryValueCodec.encode(expected)
    decoded = CrystalClick::ObjectSharedMapCodec.decode(
      w240e_sizes(1_u64),
      Bytes[0x01_u8, 0x78_u8],
      w240e_frame(envelope),
      1,
    )
    w240e_assert_value_equal!(decoded[0].entry_at(0).value, expected)
  end

  it "rejects truncated and trailing shared envelope bytes" do
    wire = CrystalClick::BinaryValueCodec.encode(w240e_empty_json_value)
    (0...wire.size).each do |length|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryValueCodec.decode_shared_json_envelope(
          wire[0, length],
          CrystalClick::BinaryCodecBudget.new(w240e_limits),
        )
      end
    end

    trailing = w240e_concat([wire, Bytes[0_u8]] of Bytes)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_shared_json_envelope(
        trailing,
        CrystalClick::BinaryCodecBudget.new(w240e_limits),
      )
    end
  end

  it "honors envelope depth, node, element, reserved-wire, and cumulative budgets" do
    empty_json = w240e_empty_json_value
    direct_wire = CrystalClick::BinaryValueCodec.encode(empty_json)

    write_depth_limited = CrystalClick::BinaryCodecBudget.new(w240e_limits(max_depth: 0), true)
    expect_raises(CrystalClick::UnsupportedFormatError, "depth") do
      CrystalClick::BinaryValueCodec.encode_shared_json_envelope(empty_json, write_depth_limited)
    end
    expect_raises(CrystalClick::CorruptPartError, "depth") do
      CrystalClick::BinaryValueCodec.decode_shared_json_envelope(
        direct_wire,
        CrystalClick::BinaryCodecBudget.new(w240e_limits(max_depth: 0)),
      )
    end

    exact = w240e_limits(max_depth: 1, max_nodes: 2, max_elements: 0, max_bytes: direct_wire.size)
    exact_write_budget = CrystalClick::BinaryCodecBudget.new(exact, true)
    CrystalClick::BinaryValueCodec.encode_shared_json_envelope(empty_json, exact_write_budget).should eq(direct_wire)
    exact_write_budget.node_count.should eq(2_i64)
    exact_write_budget.element_count.should eq(0_i64)
    exact_write_budget.wire_byte_count.should eq(0_i64) # owner charges the final framed bytes

    expect_raises(CrystalClick::UnsupportedFormatError, "node") do
      CrystalClick::BinaryValueCodec.encode_shared_json_envelope(
        empty_json,
        CrystalClick::BinaryCodecBudget.new(w240e_limits(max_depth: 1, max_nodes: 1, max_bytes: direct_wire.size), true),
      )
    end

    reserve_budget = CrystalClick::BinaryCodecBudget.new(
      w240e_limits(max_depth: 1, max_nodes: 2, max_elements: 0, max_bytes: direct_wire.size + 1),
      true,
    )
    CrystalClick::BinaryValueCodec.encode_shared_json_envelope(empty_json, reserve_budget, 1_u64).should eq(direct_wire)
    expect_raises(CrystalClick::UnsupportedFormatError, "byte") do
      CrystalClick::BinaryValueCodec.encode_shared_json_envelope(
        empty_json,
        CrystalClick::BinaryCodecBudget.new(
          w240e_limits(max_depth: 1, max_nodes: 2, max_elements: 0, max_bytes: direct_wire.size),
          true,
        ),
        1_u64,
      )
    end

    # A read owner charges the complete physical lane once before decoding
    # multiple borrowed envelopes; child reads consume work, never wire again.
    repeated_wire = w240e_concat([direct_wire, direct_wire] of Bytes)
    cumulative_read = CrystalClick::BinaryCodecBudget.new(
      w240e_limits(max_depth: 1, max_nodes: 3, max_elements: 0, max_bytes: repeated_wire.size),
    )
    cumulative_read.charge_wire_bytes(repeated_wire.size.to_u64)
    CrystalClick::BinaryValueCodec.decode_shared_json_envelope(direct_wire, cumulative_read)
    expect_raises(CrystalClick::CorruptPartError, "node") do
      CrystalClick::BinaryValueCodec.decode_shared_json_envelope(direct_wire, cumulative_read)
    end
    cumulative_read.wire_byte_count.should eq(repeated_wire.size.to_i64)

    cumulative_write = CrystalClick::BinaryCodecBudget.new(
      w240e_limits(max_depth: 1, max_nodes: 3, max_elements: 0, max_bytes: direct_wire.size * 2),
      true,
    )
    CrystalClick::BinaryValueCodec.encode_shared_json_envelope(empty_json, cumulative_write)
    expect_raises(CrystalClick::UnsupportedFormatError, "node") do
      CrystalClick::BinaryValueCodec.encode_shared_json_envelope(empty_json, cumulative_write)
    end

    array_type = CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.json)
    array_value = CrystalClick::BinaryValue.array(
      array_type,
      [w240e_empty_json_value] of CrystalClick::BinaryValue,
    )
    expect_raises(CrystalClick::UnsupportedFormatError, "depth") do
      CrystalClick::BinaryValueCodec.encode_shared_json_envelope(
        array_value,
        CrystalClick::BinaryCodecBudget.new(w240e_limits(max_depth: 1), true),
      )
    end
    array_wire = CrystalClick::BinaryValueCodec.encode(array_value)
    expect_raises(CrystalClick::CorruptPartError, "depth") do
      CrystalClick::BinaryValueCodec.decode_shared_json_envelope(
        array_wire,
        CrystalClick::BinaryCodecBudget.new(w240e_limits(max_depth: 1)),
      )
    end

    measured = CrystalClick::BinaryCodecBudget.new(w240e_limits, true)
    CrystalClick::BinaryValueCodec.encode_shared_json_envelope(array_value, measured)
    measured.element_count.should be > 0_i64
    expect_raises(CrystalClick::UnsupportedFormatError, "element") do
      CrystalClick::BinaryValueCodec.encode_shared_json_envelope(
        array_value,
        CrystalClick::BinaryCodecBudget.new(
          w240e_limits(max_elements: measured.element_count.to_i - 1),
          true,
        ),
      )
    end

    expect_raises(CrystalClick::CorruptPartError, "element") do
      CrystalClick::BinaryValueCodec.decode_shared_json_envelope(
        array_wire,
        CrystalClick::BinaryCodecBudget.new(
          w240e_limits(max_elements: measured.element_count.to_i - 1),
        ),
      )
    end

    expect_raises(CrystalClick::CorruptPartError, "byte") do
      CrystalClick::BinaryValueCodec.decode_shared_json_envelope(
        direct_wire,
        CrystalClick::BinaryCodecBudget.new(w240e_limits(max_bytes: direct_wire.size - 1)),
      )
    end
  end
end
