require "./spec_helper"

private def w155_literal_dynamic_bulk_streams : CrystalClick::BinaryDynamicBulkStreams
  structures = CrystalClick::BinaryDynamicStructureStreams.new({
    "root.field.0.elements" => Bytes[
      0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x01_u8, 0x04_u8, 0x00_u8,
    ],
    "root.field.1" => Bytes[
      0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x01_u8, 0x15_u8, 0x00_u8,
    ],
  })

  lanes = Hash(String, CrystalClick::BinaryBulkStream).new
  lanes["root.field.0.elements.arm.0.data"] = CrystalClick::BinaryBulkStream.new(
    Bytes.empty,
    [0_u64, 0_u64, 0_u64],
  )
  lanes["root.field.0.elements.arm.1.data"] = CrystalClick::BinaryBulkStream.new(
    Bytes[0x2a_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8],
    [0_u64, 8_u64, 8_u64],
  )
  lanes["root.field.0.elements.discriminators"] = CrystalClick::BinaryBulkStream.new(
    Bytes[0x01_u8],
    [0_u64, 1_u64, 1_u64],
  )
  lanes["root.field.0.sizes"] = CrystalClick::BinaryBulkStream.new(
    Bytes[
      0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    ],
    [0_u64, 8_u64, 16_u64],
  )
  lanes["root.field.1.arm.0.data"] = CrystalClick::BinaryBulkStream.new(
    Bytes.empty,
    [0_u64, 0_u64, 0_u64],
  )
  lanes["root.field.1.arm.1.data"] = CrystalClick::BinaryBulkStream.new(
    Bytes[0x01_u8, 0x78_u8],
    [0_u64, 0_u64, 2_u64],
  )
  lanes["root.field.1.discriminators"] = CrystalClick::BinaryBulkStream.new(
    Bytes[0xff_u8, 0x01_u8],
    [0_u64, 1_u64, 2_u64],
  )

  data = CrystalClick::BinaryBulkStreams.new(2, lanes)
  CrystalClick::BinaryDynamicBulkStreams.new(structures, data)
end

describe "W155 paired normalized Dynamic bulk values" do
  it "pairs independent Dynamic sites and complete literal role grids across sparse marks" do
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    array_type = CrystalClick::BinaryDataType.array(dynamic_type)
    tuple_type = CrystalClick::BinaryDataType.tuple([
      array_type,
      dynamic_type,
    ] of CrystalClick::BinaryDataType)
    uint64_type = CrystalClick::BinaryDataType.primitive("UInt64")
    string_type = CrystalClick::BinaryDataType.primitive("String")

    structures = {
      "root.field.0.elements" => CrystalClick::DynamicStructure.new([uint64_type] of CrystalClick::BinaryDataType),
      "root.field.1"          => CrystalClick::DynamicStructure.new([string_type] of CrystalClick::BinaryDataType),
    }

    mark_zero = CrystalClick::BinaryValue.tuple(tuple_type, [
      CrystalClick::BinaryValue.array(array_type, [
        CrystalClick::BinaryValue.dynamic(dynamic_type, CrystalClick::BinaryValue.uint64(42_u64)),
      ] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.dynamic(dynamic_type),
    ] of CrystalClick::BinaryValue)
    mark_one = CrystalClick::BinaryValue.tuple(tuple_type, [
      CrystalClick::BinaryValue.array(array_type, [] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.dynamic(dynamic_type, CrystalClick::BinaryValue.string("x")),
    ] of CrystalClick::BinaryValue)
    granules = [
      [mark_zero] of CrystalClick::BinaryValue,
      [mark_one] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)

    encoded = CrystalClick::BinaryDynamicBulkCodec.encode(tuple_type, structures, granules)
    encoded.structures.site_paths.should eq([
      "root.field.0.elements",
      "root.field.1",
    ] of String)
    encoded.structures.structure_bytes_for("root.field.0.elements").should eq(Bytes[
      0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x01_u8, 0x04_u8, 0x00_u8,
    ])
    encoded.structures.structure_bytes_for("root.field.1").should eq(Bytes[
      0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x01_u8, 0x15_u8, 0x00_u8,
    ])

    expected_roles = [
      "root.field.0.elements.arm.0.data",
      "root.field.0.elements.arm.1.data",
      "root.field.0.elements.discriminators",
      "root.field.0.sizes",
      "root.field.1.arm.0.data",
      "root.field.1.arm.1.data",
      "root.field.1.discriminators",
    ] of String
    encoded.data.roles.should eq(expected_roles)
    encoded.data.mark_count.should eq(2)

    encoded.data.stream("root.field.0.elements.arm.0.data").bytes.should eq(Bytes.empty)
    encoded.data.stream("root.field.0.elements.arm.0.data").offsets.should eq([0_u64, 0_u64, 0_u64])
    encoded.data.stream("root.field.0.elements.arm.1.data").bytes.should eq(Bytes[
      0x2a_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    ])
    encoded.data.stream("root.field.0.elements.arm.1.data").offsets.should eq([0_u64, 8_u64, 8_u64])
    encoded.data.stream("root.field.0.elements.discriminators").bytes.should eq(Bytes[0x01_u8])
    encoded.data.stream("root.field.0.elements.discriminators").offsets.should eq([0_u64, 1_u64, 1_u64])
    encoded.data.stream("root.field.0.sizes").bytes.should eq(Bytes[
      0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    ])
    encoded.data.stream("root.field.0.sizes").offsets.should eq([0_u64, 8_u64, 16_u64])
    encoded.data.stream("root.field.1.arm.0.data").bytes.should eq(Bytes.empty)
    encoded.data.stream("root.field.1.arm.0.data").offsets.should eq([0_u64, 0_u64, 0_u64])
    encoded.data.stream("root.field.1.arm.1.data").bytes.should eq(Bytes[0x01_u8, 0x78_u8])
    encoded.data.stream("root.field.1.arm.1.data").offsets.should eq([0_u64, 0_u64, 2_u64])
    encoded.data.stream("root.field.1.discriminators").bytes.should eq(Bytes[0xff_u8, 0x01_u8])
    encoded.data.stream("root.field.1.discriminators").offsets.should eq([0_u64, 1_u64, 2_u64])

    # Decode independently authored literal lanes, not the encoder result.
    decoded = CrystalClick::BinaryDynamicBulkCodec.decode(
      tuple_type,
      w155_literal_dynamic_bulk_streams,
      [1_u64, 1_u64],
    )
    decoded.size.should eq(2)
    decoded[0].size.should eq(1)
    decoded[0][0].type.should eq(tuple_type)
    first_array = decoded[0][0].child_at(0)
    first_array.element_count.should eq(1)
    selected_uint64 = first_array.element_at(0)
    selected_uint64.type.should eq(dynamic_type)
    selected_uint64.is_null?.should be_false
    selected_uint64.child_at(0).type.should eq(uint64_type)
    selected_uint64.child_at(0).as_uint64.should eq(42_u64)
    decoded[0][0].child_at(1).type.should eq(dynamic_type)
    decoded[0][0].child_at(1).is_null?.should be_true
    decoded[0][0].child_at(1).child_count.should eq(0)

    decoded[1][0].child_at(0).element_count.should eq(0)
    selected_string = decoded[1][0].child_at(1)
    selected_string.type.should eq(dynamic_type)
    selected_string.is_null?.should be_false
    selected_string.child_at(0).type.should eq(string_type)
    selected_string.child_at(0).bytes.should eq(Bytes[0x78_u8])
  end

  it "keeps the no-structure Dynamic bulk API fenced" do
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    value = CrystalClick::BinaryValue.dynamic(dynamic_type)

    expect_raises(CrystalClick::UnsupportedFormatError, /Dynamic/) do
      CrystalClick::BinaryBulkCodec.encode(
        dynamic_type,
        [[value]] of Array(CrystalClick::BinaryValue),
      )
    end
  end
end
