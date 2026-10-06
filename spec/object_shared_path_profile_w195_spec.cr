require "./spec_helper"

private def w195_path_dynamic_empty : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.dynamic(max_types: 0)
end

private def w195_path_empty_structures : Hash(String, CrystalClick::DynamicStructure)
  {"root" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)}
end

private def w195_path_null_first_string_rows : Array(CrystalClick::BinaryValue)
  dynamic = w195_path_dynamic_empty
  [
    CrystalClick::BinaryValue.dynamic(dynamic),
    CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.string("r-alpha-1")),
  ] of CrystalClick::BinaryValue
end

private def w195_path_null_first_array_rows : Array(CrystalClick::BinaryValue)
  dynamic = w195_path_dynamic_empty
  array_type = CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.primitive("String"))
  array = CrystalClick::BinaryValue.array(array_type, [
    CrystalClick::BinaryValue.string("a"),
    CrystalClick::BinaryValue.string("bc"),
  ] of CrystalClick::BinaryValue)
  [
    CrystalClick::BinaryValue.dynamic(dynamic),
    CrystalClick::BinaryValue.dynamic(dynamic, array),
  ] of CrystalClick::BinaryValue
end

private def w195_path_events_with_size : Array(CrystalClick::ObjectSharedPathSubstreamEvent)
  [
    CrystalClick::ObjectSharedPathSubstreamEvent.new(".dynamic_structure", 0_u64),
    CrystalClick::ObjectSharedPathSubstreamEvent.new(".variant_discr_prefix", 9_u64),
    CrystalClick::ObjectSharedPathSubstreamEvent.new(".variant_discr", 17_u64),
    CrystalClick::ObjectSharedPathSubstreamEvent.new(".SharedVariant.size", 21_u64),
    CrystalClick::ObjectSharedPathSubstreamEvent.new(".SharedVariant", 29_u64),
  ] of CrystalClick::ObjectSharedPathSubstreamEvent
end

private def w195_path_events_single_stream : Array(CrystalClick::ObjectSharedPathSubstreamEvent)
  [
    CrystalClick::ObjectSharedPathSubstreamEvent.new(".dynamic_structure", 0_u64),
    CrystalClick::ObjectSharedPathSubstreamEvent.new(".variant_discr_prefix", 9_u64),
    CrystalClick::ObjectSharedPathSubstreamEvent.new(".variant_discr", 17_u64),
    CrystalClick::ObjectSharedPathSubstreamEvent.new(".SharedVariant", 21_u64),
  ] of CrystalClick::ObjectSharedPathSubstreamEvent
end

private def w195_path_string_with_size_data : Bytes
  Bytes[
    0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    0x02_u8, 0x00_u8, 0xff_u8, 0x00_u8,
    0x0b_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    0x15_u8, 0x09_u8, 0x72_u8, 0x2d_u8, 0x61_u8, 0x6c_u8, 0x70_u8, 0x68_u8, 0x61_u8, 0x2d_u8, 0x31_u8,
  ]
end

private def w195_path_string_single_stream_data : Bytes
  Bytes[
    0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    0x02_u8, 0x00_u8, 0xff_u8, 0x00_u8,
    0x0b_u8, 0x15_u8, 0x09_u8, 0x72_u8, 0x2d_u8, 0x61_u8, 0x6c_u8, 0x70_u8, 0x68_u8, 0x61_u8, 0x2d_u8, 0x31_u8,
  ]
end

private def w195_path_array_with_size_data : Bytes
  Bytes[
    0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    0x02_u8, 0x00_u8, 0xff_u8, 0x00_u8,
    0x08_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    0x1e_u8, 0x15_u8, 0x02_u8, 0x01_u8, 0x61_u8, 0x02_u8, 0x62_u8, 0x63_u8,
  ]
end

private def w195_path_array_single_stream_data : Bytes
  Bytes[
    0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    0x02_u8, 0x00_u8, 0xff_u8, 0x00_u8,
    0x08_u8, 0x1e_u8, 0x15_u8, 0x02_u8, 0x01_u8, 0x61_u8, 0x02_u8, 0x62_u8, 0x63_u8,
  ]
end

describe "W195 path String profile propagation" do
  it "matches independent v0/v1 Dynamic String-envelope bytes and callback tapes for NULL-first rows" do
    dynamic = w195_path_dynamic_empty
    structures = w195_path_empty_structures
    rows = w195_path_null_first_string_rows
    profile0 = CrystalClick::BinaryBulkProfile.single_stream
    profile1 = CrystalClick::BinaryBulkProfile.with_size_stream

    encoded0 = CrystalClick::ObjectSharedPathCodec.encode(dynamic, structures, rows, profile: profile0)
    encoded0.data.should eq(w195_path_string_single_stream_data)
    encoded0.events.map { |event| {event.name, event.relative_offset} }.should eq([
      {".dynamic_structure", 0_u64},
      {".variant_discr_prefix", 9_u64},
      {".variant_discr", 17_u64},
      {".SharedVariant", 21_u64},
    ] of Tuple(String, UInt64))

    encoded1 = CrystalClick::ObjectSharedPathCodec.encode(dynamic, structures, rows, profile: profile1)
    encoded1.data.should eq(w195_path_string_with_size_data)
    encoded1.events.map { |event| {event.name, event.relative_offset} }.should eq([
      {".dynamic_structure", 0_u64},
      {".variant_discr_prefix", 9_u64},
      {".variant_discr", 17_u64},
      {".SharedVariant.size", 21_u64},
      {".SharedVariant", 29_u64},
    ] of Tuple(String, UInt64))

    # The historical overload remains the with-size profile, and neither
    # decoder guesses a profile from the bytes or callback tape.
    legacy_default = CrystalClick::ObjectSharedPathCodec.encode(dynamic, structures, rows)
    legacy_default.data.should eq(w195_path_string_with_size_data)
    legacy_default.events.map { |event| {event.name, event.relative_offset} }.should eq(
      encoded1.events.map { |event| {event.name, event.relative_offset} }
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedPathCodec.decode(
        w195_path_string_single_stream_data,
        w195_path_events_single_stream,
        2,
        dynamic,
        profile: profile1,
      )
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::ObjectSharedPathCodec.decode(
        w195_path_string_with_size_data,
        w195_path_events_with_size,
        2,
        dynamic,
        profile: profile0,
      )
    end

    decoded0 = CrystalClick::ObjectSharedPathCodec.decode(
      w195_path_string_single_stream_data,
      w195_path_events_single_stream,
      2,
      dynamic,
      profile: profile0,
    )
    decoded0[0].is_null?.should be_true
    decoded0[1].child_at(0).as_string.should eq("r-alpha-1")

    decoded1 = CrystalClick::ObjectSharedPathCodec.decode(
      w195_path_string_with_size_data,
      w195_path_events_with_size,
      2,
      dynamic,
      profile: profile1,
    )
    decoded1[0].is_null?.should be_true
    decoded1[1].child_at(0).as_string.should eq("r-alpha-1")
  end

  it "preserves exact recursive Array(String) envelopes under either outer String profile" do
    dynamic = w195_path_dynamic_empty
    structures = w195_path_empty_structures
    rows = w195_path_null_first_array_rows
    profile0 = CrystalClick::BinaryBulkProfile.single_stream
    profile1 = CrystalClick::BinaryBulkProfile.with_size_stream

    encoded0 = CrystalClick::ObjectSharedPathCodec.encode(dynamic, structures, rows, profile: profile0)
    encoded0.data.should eq(w195_path_array_single_stream_data)
    encoded0.events.map { |event| {event.name, event.relative_offset} }.should eq([
      {".dynamic_structure", 0_u64},
      {".variant_discr_prefix", 9_u64},
      {".variant_discr", 17_u64},
      {".SharedVariant", 21_u64},
    ] of Tuple(String, UInt64))

    encoded1 = CrystalClick::ObjectSharedPathCodec.encode(dynamic, structures, rows, profile: profile1)
    encoded1.data.should eq(w195_path_array_with_size_data)
    encoded1.events.map { |event| {event.name, event.relative_offset} }.should eq([
      {".dynamic_structure", 0_u64},
      {".variant_discr_prefix", 9_u64},
      {".variant_discr", 17_u64},
      {".SharedVariant.size", 21_u64},
      {".SharedVariant", 29_u64},
    ] of Tuple(String, UInt64))

    decoded0 = CrystalClick::ObjectSharedPathCodec.decode(
      w195_path_array_single_stream_data,
      w195_path_events_single_stream,
      2,
      dynamic,
      profile: profile0,
    )
    decoded0[0].is_null?.should be_true
    decoded0[1].child_at(0).elements.map(&.as_string).should eq(["a", "bc"] of String)

    decoded1 = CrystalClick::ObjectSharedPathCodec.decode(
      w195_path_array_with_size_data,
      w195_path_events_with_size,
      2,
      dynamic,
      profile: profile1,
    )
    decoded1[0].is_null?.should be_true
    decoded1[1].child_at(0).elements.map(&.as_string).should eq(["a", "bc"] of String)
  end
end
