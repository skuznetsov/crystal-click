require "./spec_helper"

private def w196_u64(value : UInt64) : Bytes
  Bytes.new(8) { |index| ((value >> (8 * index)) & 255_u64).to_u8 }
end

describe "W196 shared-path LowCardinality framing" do
  it "emits the independently authored Dynamic, Array and LC prefixes before the body" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    low_cardinality = CrystalClick::BinaryDataType.low_cardinality(uint8)
    array = CrystalClick::BinaryDataType.array(low_cardinality)

    lc_value = ->(value : UInt8) {
      CrystalClick::BinaryValue.low_cardinality(
        low_cardinality,
        CrystalClick::BinaryValue.fixed(uint8, Bytes[value]),
      )
    }
    rows = [
      CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.array(array, [lc_value.call(7_u8), lc_value.call(9_u8)])),
      CrystalClick::BinaryValue.dynamic(dynamic),
      CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.array(array, [] of CrystalClick::BinaryValue)),
    ]
    structures = {"root" => CrystalClick::DynamicStructure.new([array] of CrystalClick::BinaryDataType)}

    encoded = CrystalClick::ObjectSharedPathCodec.encode(dynamic, structures, rows)

    # Dynamic V3 version/type roster, Compact discriminator mode, then the
    # LC dictionary-key prefix. This literal is independent of the encoder.
    encoded.data[0, 28].should eq(Bytes[
      4, 0, 0, 0, 0, 0, 0, 0, 1, 0x1e, 0x26, 0x01,
      1, 0, 0, 0, 0, 0, 0, 0,
      1, 0, 0, 0, 0, 0, 0, 0,
    ])
    encoded.events[0, 3].map { |event| {event.name, event.relative_offset} }.should eq([
      {".dynamic_structure", 0_u64},
      {".variant_discr_prefix", 12_u64},
      {".Array(LowCardinality(UInt8)).dict_prefix", 20_u64},
    ])
  end
end
