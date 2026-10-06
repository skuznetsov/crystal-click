require "./spec_helper"

private def w182_shared_dynamic_limits(
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

describe "W182 shared Dynamic selected JSON recursion" do
  it "charges one shared JSON/Dynamic owner at each typed sibling occurrence" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    inner_type = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
      typed_paths: {"n" => uint8} of String => CrystalClick::BinaryDataType,
    )
    inner_row = CrystalClick::BinaryJsonRow.new(
      inner_type,
      [{"n", CrystalClick::BinaryValue.fixed(uint8, Bytes[0x2a_u8])}] of Tuple(String, CrystalClick::BinaryValue),
    )
    selected_json = CrystalClick::BinaryValue.json(inner_type, inner_row)
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    shared_dynamic = CrystalClick::BinaryValue.dynamic(dynamic_type, selected_json)
    outer_type = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
      typed_paths: {
        "a" => dynamic_type,
        "b" => dynamic_type,
      } of String => CrystalClick::BinaryDataType,
    )
    entries = [
      {"a", shared_dynamic},
      {"b", shared_dynamic},
    ] of Tuple(String, CrystalClick::BinaryValue)

    # Construction visits the outer JSON root, both Dynamic typed paths, both
    # selected JSON values, and both inner UInt8 values: depth 4, 22 nodes,
    # and 20 edges/metadata records. Each of a, b, and the repeated inner n
    # path costs two metadata bytes, for eight bytes total. The scalar row wire
    # below is 33 bytes: outer count + two (path + Dynamic selected JSON) pairs.
    exact_constructor_limits = w182_shared_dynamic_limits(
      max_depth: 4,
      max_nodes: 22,
      max_elements: 20,
      max_bytes: 8,
    )
    row = CrystalClick::BinaryJsonRow.new(outer_type, entries, exact_constructor_limits)
    row.path_count.should eq(2)
    row.path_at(0).should eq("a")
    row.path_at(1).should eq("b")
    row.value_at(0).should eq(shared_dynamic)
    row.value_at(1).should eq(shared_dynamic)

    constructor_one_short = [
      w182_shared_dynamic_limits(max_depth: 3, max_nodes: 22, max_elements: 20, max_bytes: 8),
      w182_shared_dynamic_limits(max_depth: 4, max_nodes: 21, max_elements: 20, max_bytes: 8),
      w182_shared_dynamic_limits(max_depth: 4, max_nodes: 22, max_elements: 19, max_bytes: 8),
      w182_shared_dynamic_limits(max_depth: 4, max_nodes: 22, max_elements: 20, max_bytes: 7),
    ] of CrystalClick::BinaryCodecLimits
    constructor_one_short.each do |limits|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryJsonRow.new(outer_type, entries, limits)
      end
    end

    value = CrystalClick::BinaryValue.json(outer_type, row)
    row_wire = Bytes[
      0x02_u8,
      0x01, 0x61,
      0x30, 0x00, 0x00, 0x00, 0x01, 0x01, 0x6e, 0x01, 0x00, 0x00,
      0x01, 0x01, 0x6e, 0x2a,
      0x01, 0x62,
      0x30, 0x00, 0x00, 0x00, 0x01, 0x01, 0x6e, 0x01, 0x00, 0x00,
      0x01, 0x01, 0x6e, 0x2a,
    ]
    row_wire.size.should eq(33)
    exact_codec_limits = w182_shared_dynamic_limits(
      max_depth: 4,
      max_nodes: 22,
      max_elements: 20,
      max_bytes: row_wire.size,
    )
    CrystalClick::BinaryValueCodec.encode_value(value, exact_codec_limits).should eq(row_wire)
    decoded = CrystalClick::BinaryValueCodec.decode_value(outer_type, row_wire, exact_codec_limits)
    decoded.json_row.path_count.should eq(2)
    decoded.json_row.value_at(0).child_at(0).type.should eq(inner_type)
    decoded.json_row.value_at(0).child_at(0).json_row.value_at(0).bytes.should eq(Bytes[0x2a_u8])
    decoded.json_row.value_at(1).child_at(0).type.should eq(inner_type)
    decoded.json_row.value_at(1).child_at(0).json_row.value_at(0).bytes.should eq(Bytes[0x2a_u8])

    codec_one_short = [
      w182_shared_dynamic_limits(max_depth: 3, max_nodes: 22, max_elements: 20, max_bytes: row_wire.size),
      w182_shared_dynamic_limits(max_depth: 4, max_nodes: 21, max_elements: 20, max_bytes: row_wire.size),
      w182_shared_dynamic_limits(max_depth: 4, max_nodes: 22, max_elements: 19, max_bytes: row_wire.size),
      w182_shared_dynamic_limits(max_depth: 4, max_nodes: 22, max_elements: 20, max_bytes: row_wire.size - 1),
    ] of CrystalClick::BinaryCodecLimits
    codec_one_short.each do |limits|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryValueCodec.encode_value(value, limits)
      end
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryValueCodec.decode_value(outer_type, row_wire, limits)
      end
    end
  end
end
