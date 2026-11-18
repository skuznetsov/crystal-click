require "./spec_helper"

private def catu_type : CrystalClick::BinaryDataType
  CrystalClick::StaticBinaryBulkColumnDeclaration.parse(
    CrystalClick::WideTypePlan::TYPE_ARRAY_TUPLE_UINT64_STRING,
  ) || raise "exact Array(Tuple) type did not parse"
end

private def catu_tuple(
  type : CrystalClick::BinaryDataType,
  number : UInt64,
  payload : Bytes,
) : CrystalClick::BinaryValue
  tuple_type = type.child_at(0)
  CrystalClick::BinaryValue.tuple(
    tuple_type,
    [
      CrystalClick::BinaryValue.uint64(number),
      CrystalClick::BinaryValue.string(tuple_type.child_at(1), payload),
    ] of CrystalClick::BinaryValue,
  )
end

private def catu_fixture(
  profile : CrystalClick::BinaryBulkProfile,
) : Tuple(CrystalClick::BinaryDataType, CrystalClick::BinaryBulkStreams, Array(CrystalClick::BinaryValue))
  type = catu_type
  rows = [
    CrystalClick::BinaryValue.array(type, [] of CrystalClick::BinaryValue),
    CrystalClick::BinaryValue.array(type, [
      catu_tuple(type, 0_u64, Bytes.empty),
      catu_tuple(type, UInt64::MAX, Bytes[0x00_u8, 0xff_u8, 0x61_u8]),
    ] of CrystalClick::BinaryValue),
    CrystalClick::BinaryValue.array(type, [
      catu_tuple(type, 1_u64, Bytes[0x78_u8]),
    ] of CrystalClick::BinaryValue),
  ] of CrystalClick::BinaryValue
  streams = CrystalClick::BinaryBulkCodec.encode(
    type,
    [rows] of Array(CrystalClick::BinaryValue),
    profile: profile,
  )
  {type, streams, rows}
end

private def catu_no_workspace : Proc(UInt64, Nil)
  ->(_bytes : UInt64) { nil }
end

private def catu_decode(
  type : CrystalClick::BinaryDataType,
  streams : CrystalClick::BinaryBulkStreams,
  rows : Array(CrystalClick::BinaryValue),
  profile : CrystalClick::BinaryBulkProfile,
  limits : CrystalClick::BinaryCodecLimits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
  workspace_observer : Proc(UInt64, Nil) = catu_no_workspace,
  physical_workspace_bytes : UInt64 = 0_u64,
) : CrystalClick::CompactArrayTupleUInt64StringMark
  CrystalClick::CompactArrayTupleUInt64StringMark.decode(
    type,
    streams,
    [rows.size.to_u64],
    profile,
    CrystalClick::BinaryCodecBudget.new(limits),
    workspace_observer,
    physical_workspace_bytes,
  )
end

private def catu_replace_lane(
  source : CrystalClick::BinaryBulkStreams,
  role : String,
  bytes : Bytes? = nil,
  offsets : Array(UInt64)? = nil,
) : CrystalClick::BinaryBulkStreams
  streams = Hash(String, CrystalClick::BinaryBulkStream).new
  source.roles.each do |candidate|
    lane = source.stream(candidate)
    if candidate == role
      streams[candidate] = CrystalClick::BinaryBulkStream.new(bytes || lane.bytes, offsets || lane.offsets)
    else
      streams[candidate] = lane
    end
  end
  CrystalClick::BinaryBulkStreams.new(source.mark_count, streams)
end

private def catu_store_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

describe "Compact exact Array(Tuple(UInt64, String)) mark reader" do
  it "returns read-only flat values and exact raw String bytes for both String profiles" do
    {
      CrystalClick::BinaryBulkProfile.single_stream,
      CrystalClick::BinaryBulkProfile.with_size_stream,
    }.each do |profile|
      type, streams, rows = catu_fixture(profile)
      observed = [] of UInt64
      observer = ->(bytes : UInt64) { observed << bytes }
      result = catu_decode(type, streams, rows, profile, workspace_observer: observer, physical_workspace_bytes: 12_345_u64)

      result.row_count.should eq(3)
      result.element_count.should eq(3)
      result.string_byte_count.should eq(4)
      result.row_offsets.to_a.should eq([0_u64, 0_u64, 2_u64, 3_u64])
      result.uint64_values.to_a.should eq([0_u64, UInt64::MAX, 1_u64])
      result.string_offsets.to_a.should eq([0_u64, 0_u64, 3_u64, 4_u64])
      result.string_payload.to_a.should eq([0x00_u8, 0xff_u8, 0x61_u8, 0x78_u8])
      result.string_bytes_at(0).to_a.should eq([] of UInt8)
      result.string_bytes_at(1).to_a.should eq([0x00_u8, 0xff_u8, 0x61_u8])
      result.string_bytes_at(2).to_a.should eq([0x78_u8])
      result.row_offsets.read_only?.should be_true
      result.uint64_values.read_only?.should be_true
      result.string_offsets.read_only?.should be_true
      result.string_payload.read_only?.should be_true
      result.string_bytes_at(1).read_only?.should be_true
      observed.last.should be >= 12_345_u64 + streams.total_input_byte_size + 92_u64
    end
  end

  it "rejects malformed count, lane-grid, and String-length encodings" do
    type, streams, rows = catu_fixture(CrystalClick::BinaryBulkProfile.with_size_stream)
    oversized_count = streams.stream("root.sizes").bytes
    catu_store_u64(oversized_count, 0, Int32::MAX.to_u64)
    bad_count = catu_replace_lane(streams, "root.sizes", bytes: oversized_count)
    expect_raises(CrystalClick::CorruptPartError) do
      catu_decode(type, bad_count, rows, CrystalClick::BinaryBulkProfile.with_size_stream)
    end

    value_lane = streams.stream("root.elements.field.0.data")
    bad_grid = catu_replace_lane(
      streams,
      "root.elements.field.0.data",
      offsets: [0_u64, value_lane.byte_size.to_u64 + 1_u64],
    )
    expect_raises(CrystalClick::CorruptPartError) do
      catu_decode(type, bad_grid, rows, CrystalClick::BinaryBulkProfile.with_size_stream)
    end

    string_sizes = streams.stream("root.elements.field.1.string_sizes").bytes
    catu_store_u64(string_sizes, 0, 1_u64)
    bad_string_sizes = catu_replace_lane(
      streams,
      "root.elements.field.1.string_sizes",
      bytes: string_sizes,
    )
    expect_raises(CrystalClick::CorruptPartError) do
      catu_decode(type, bad_string_sizes, rows, CrystalClick::BinaryBulkProfile.with_size_stream)
    end

    v0_type, v0_streams, v0_rows = catu_fixture(CrystalClick::BinaryBulkProfile.single_stream)
    bad_varuint = catu_replace_lane(
      v0_streams,
      "root.elements.field.1.data",
      bytes: Bytes[0x80_u8, 0x00_u8],
      offsets: [0_u64, 2_u64],
    )
    expect_raises(CrystalClick::CorruptPartError) do
      catu_decode(v0_type, bad_varuint, v0_rows, CrystalClick::BinaryBulkProfile.single_stream)
    end
  end

  it "enforces codec limits before returning flat output" do
    type, streams, rows = catu_fixture(CrystalClick::BinaryBulkProfile.with_size_stream)

    too_few_bytes = CrystalClick::BinaryCodecLimits.new(
      max_depth: 64,
      max_nodes: 1_000,
      max_elements: 1_000,
      max_bytes: 1,
    )
    expect_raises(CrystalClick::CorruptPartError) do
      catu_decode(type, streams, rows, CrystalClick::BinaryBulkProfile.with_size_stream, too_few_bytes)
    end

    too_few_nodes = CrystalClick::BinaryCodecLimits.new(
      max_depth: 64,
      max_nodes: 1,
      max_elements: 1_000,
      max_bytes: 1_024,
    )
    expect_raises(CrystalClick::CorruptPartError) do
      catu_decode(type, streams, rows, CrystalClick::BinaryBulkProfile.with_size_stream, too_few_nodes)
    end
  end
end
