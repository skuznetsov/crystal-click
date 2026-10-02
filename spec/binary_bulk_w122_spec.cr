require "./spec_helper"

private def w122_u64_le(value : UInt64) : Bytes
  Bytes[
    (value & 0xff_u64).to_u8,
    ((value >> 8) & 0xff_u64).to_u8,
    ((value >> 16) & 0xff_u64).to_u8,
    ((value >> 24) & 0xff_u64).to_u8,
    ((value >> 32) & 0xff_u64).to_u8,
    ((value >> 40) & 0xff_u64).to_u8,
    ((value >> 48) & 0xff_u64).to_u8,
    ((value >> 56) & 0xff_u64).to_u8,
  ]
end

private def w122_concat(parts : Array(Bytes)) : Bytes
  bytes = [] of UInt8
  parts.each do |part|
    part.each { |byte| bytes << byte }
  end
  Bytes.new(bytes.size) { |index| bytes[index] }
end

describe "W122 reusable binary bulk values" do
  it "matches authored Array(Nullable(String)) lanes and decodes a nonzero-origin mark window" do
    string_type = CrystalClick::BinaryDataType.primitive("String")
    nullable_string_type = CrystalClick::BinaryDataType.nullable(string_type)
    array_type = CrystalClick::BinaryDataType.array(nullable_string_type)

    skip = CrystalClick::BinaryValue.array(array_type, [
      CrystalClick::BinaryValue.nullable(nullable_string_type, CrystalClick::BinaryValue.string("skip")),
    ] of CrystalClick::BinaryValue)
    empty_array = CrystalClick::BinaryValue.array(array_type, [] of CrystalClick::BinaryValue)
    null_and_x = CrystalClick::BinaryValue.array(array_type, [
      CrystalClick::BinaryValue.nullable(nullable_string_type),
      CrystalClick::BinaryValue.nullable(nullable_string_type, CrystalClick::BinaryValue.string("x")),
    ] of CrystalClick::BinaryValue)
    one_empty_string = CrystalClick::BinaryValue.array(array_type, [
      CrystalClick::BinaryValue.nullable(nullable_string_type, CrystalClick::BinaryValue.string("")),
    ] of CrystalClick::BinaryValue)

    granules = [
      [skip] of CrystalClick::BinaryValue,
      [empty_array, null_and_x] of CrystalClick::BinaryValue,
      [one_empty_string] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)

    # Authored physical-role bytes: Array lengths [1], [0, 2], [1];
    # Nullable flags [0], [1, 0], [0]; String payloads "skip", default-empty
    # for NULL, "x", and the distinct empty string.
    expected_sizes = w122_concat([
      w122_u64_le(1_u64),
      w122_u64_le(0_u64),
      w122_u64_le(2_u64),
      w122_u64_le(1_u64),
    ] of Bytes)
    expected_nulls = Bytes[0x00_u8, 0x01_u8, 0x00_u8, 0x00_u8]
    expected_string_data = Bytes[
      0x04_u8, 0x73_u8, 0x6b_u8, 0x69_u8, 0x70_u8,
      0x00_u8,
      0x01_u8, 0x78_u8,
      0x00_u8,
    ]

    expected_streams = {
      "root.sizes"                => CrystalClick::BinaryBulkStream.new(expected_sizes, [0_u64, 8_u64, 24_u64, 32_u64]),
      "root.elements.nulls"       => CrystalClick::BinaryBulkStream.new(expected_nulls, [0_u64, 1_u64, 3_u64, 4_u64]),
      "root.elements.nested.data" => CrystalClick::BinaryBulkStream.new(expected_string_data, [0_u64, 5_u64, 8_u64, 9_u64]),
    } of String => CrystalClick::BinaryBulkStream
    expected = CrystalClick::BinaryBulkStreams.new(mark_count: 3, streams: expected_streams)

    encoded = CrystalClick::BinaryBulkCodec.encode(array_type, granules)
    encoded.mark_count.should eq(3)
    encoded.roles.sort.should eq(expected.roles.sort)
    expected.roles.each do |role|
      actual_stream = encoded.stream(role)
      expected_stream = expected.stream(role)
      actual_stream.bytes.should eq(expected_stream.bytes)
      actual_stream.offsets.should eq(expected_stream.offsets)
      actual_stream.mark_count.should eq(3)
    end

    selected = CrystalClick::BinaryBulkCodec.decode(
      array_type,
      streams: expected,
      rows_per_mark: [1_u64, 2_u64, 1_u64],
      first_mark: 1,
      mark_count: 2
    )
    selected.size.should eq(2)
    selected[0].size.should eq(2)
    selected[0][0].element_count.should eq(0)
    selected[0][1].element_count.should eq(2)
    selected[0][1].element_at(0).is_null?.should be_true
    selected[0][1].element_at(1).is_null?.should be_false
    selected[0][1].element_at(1).child_at(0).as_string.should eq("x")
    selected[1].size.should eq(1)
    selected[1][0].element_count.should eq(1)
    selected[1][0].element_at(0).is_null?.should be_false
    selected[1][0].element_at(0).child_at(0).as_string.should eq("")
  end
end
