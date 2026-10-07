require "./spec_helper"

private def w199_path_qbit_type : CrystalClick::QBitType
  CrystalClick::QBitType.new("Int8", 16_u64, 8_u64)
end

private def w199_path_qbit_raw : Bytes
  Bytes[
    0x80_u8, 0x40_u8, 0x20_u8, 0x10_u8, 0x08_u8, 0x04_u8, 0x02_u8, 0x01_u8,
    0x01_u8, 0x02_u8, 0x04_u8, 0x08_u8, 0x10_u8, 0x20_u8, 0x40_u8, 0x80_u8,
  ]
end

private def w199_path_qbit_data : Bytes
  Bytes[
    0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    0x01_u8, 0x37_u8, 0x07_u8, 0x10_u8, 0x08_u8,
    0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    0x01_u8, 0x01_u8, 0x00_u8,
    0x01_u8, 0x02_u8, 0x04_u8, 0x08_u8, 0x10_u8, 0x20_u8, 0x40_u8, 0x80_u8,
    0x80_u8, 0x40_u8, 0x20_u8, 0x10_u8, 0x08_u8, 0x04_u8, 0x02_u8, 0x01_u8,
  ]
end

private def w199_path_qbit_events : Array(CrystalClick::ObjectSharedPathSubstreamEvent)
  events = [
    CrystalClick::ObjectSharedPathSubstreamEvent.new(".dynamic_structure", 0_u64),
    CrystalClick::ObjectSharedPathSubstreamEvent.new(".variant_discr_prefix", 13_u64),
    CrystalClick::ObjectSharedPathSubstreamEvent.new(".variant_discr", 21_u64),
  ] of CrystalClick::ObjectSharedPathSubstreamEvent
  16.times do |plane|
    events << CrystalClick::ObjectSharedPathSubstreamEvent.new(
      ".QBit(Int8, 16, 8)%2E#{plane + 1}",
      24_u64 + plane.to_u64,
    )
  end
  events << CrystalClick::ObjectSharedPathSubstreamEvent.new(".SharedVariant.size", 40_u64)
  events << CrystalClick::ObjectSharedPathSubstreamEvent.new(".SharedVariant", 40_u64)
  events
end

describe "W199 QBit in Object shared-path Data" do
  it "decodes an independently authored QBit Dynamic tape with group-major numeric plane callbacks" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    candidate = begin
      CrystalClick::ObjectSharedPathCodec.decode(
        w199_path_qbit_data,
        w199_path_qbit_events,
        1,
        dynamic,
      )
    rescue ex : CrystalClick::CorruptPartError | CrystalClick::UnsupportedFormatError
      nil
    end

    candidate.should_not be_nil
    decoded = candidate.not_nil!
    decoded.size.should eq(1)
    decoded[0].type.should eq(dynamic)
    decoded[0].is_null?.should be_false
    decoded[0].child_at(0).type.should eq(CrystalClick::BinaryDataType.qbit(w199_path_qbit_type))
    decoded[0].child_at(0).qbit_value.should eq(CrystalClick::QBitValue.new(w199_path_qbit_type, w199_path_qbit_raw))
  end

  it "rejects truncated, trailing, misnamed, and misaligned QBit callback tapes" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    data = w199_path_qbit_data
    events = w199_path_qbit_events

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedPathCodec.decode(data[0, data.size - 1], events, 1, dynamic)
    end

    missing_event = events[0, events.size - 1]
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedPathCodec.decode(data, missing_event, 1, dynamic)
    end

    trailing = Bytes.new(data.size + 1) do |index|
      index < data.size ? data[index] : 0_u8
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedPathCodec.decode(trailing, events, 1, dynamic)
    end

    misnamed_events = [] of CrystalClick::ObjectSharedPathSubstreamEvent
    events.each_with_index do |event, index|
      name = index == 3 ? ".QBit(Int8, 16, 8)%2E2" : event.name
      misnamed_events << CrystalClick::ObjectSharedPathSubstreamEvent.new(name, event.relative_offset)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedPathCodec.decode(data, misnamed_events, 1, dynamic)
    end

    # A 9-bit row has two bytes per plane. Moving plane 2's callback start by
    # one byte makes plane 1's slice length three, which cannot represent one
    # selected row even though all event offsets remain monotonic and in range.
    padded_type = CrystalClick::QBitType.new("Int8", 9_u64)
    padded_binary_type = CrystalClick::BinaryDataType.qbit(padded_type)
    padded_value = CrystalClick::BinaryValue.dynamic(
      dynamic,
      CrystalClick::BinaryValue.qbit(
        padded_binary_type,
        CrystalClick::QBitValue.new(padded_type, Bytes[0x80_u8, 0x40_u8, 0x20_u8, 0x10_u8, 0x08_u8, 0x04_u8, 0x02_u8, 0x01_u8, 0x80_u8]),
      ),
    )
    padded_stream = CrystalClick::ObjectSharedPathCodec.encode(
      dynamic,
      {"root" => CrystalClick::DynamicStructure.new([padded_binary_type] of CrystalClick::BinaryDataType)},
      [padded_value],
    )
    padded_events = padded_stream.events
    bad_span_events = [] of CrystalClick::ObjectSharedPathSubstreamEvent
    padded_events.each_with_index do |event, index|
      offset = index == 4 ? event.relative_offset + 1_u64 : event.relative_offset
      bad_span_events << CrystalClick::ObjectSharedPathSubstreamEvent.new(event.name, offset)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedPathCodec.decode(padded_stream.data, bad_span_events, 1, dynamic)
    end
  end
end
