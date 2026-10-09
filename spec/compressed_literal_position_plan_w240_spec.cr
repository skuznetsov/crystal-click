require "./spec_helper"

private def w240_write_u64(bytes : Bytes, offset : Int32, value : UInt64) : Nil
  8.times do |index|
    bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8
  end
end

private def w240_patch_position_fields(
  bytes : Bytes,
  field_offsets : Array(Int32),
  positions : Array(Tuple(UInt64, UInt64)),
) : Nil
  field_offsets.each_with_index do |field_offset, index|
    w240_write_u64(bytes, field_offset, positions[index][0])
    w240_write_u64(bytes, field_offset + 8, positions[index][1])
  end
end

private def w240_index_positions(
  data : Bytes,
  positions : Array(Tuple(UInt64, UInt64)),
  expected_offsets : Array(UInt64),
) : Nil
  budget = CrystalClick::CompressedStreamBudget.read_default
  index = CrystalClick::CompressedFrameIndex.new(data, budget.limits, budget)
  positions.each_with_index do |position, row|
    index.logical_position(position[0], position[1], false).should eq(expected_offsets[row].to_i64)
  end
end

describe "W240 literal-LZ4 physical position planning" do
  it "matches final encoding across empty, partial, full, and multiple-frame inputs" do
    cases = [
      {0_i64, 4, [0_u64]},
      {5_i64, 4, [0_u64, 3_u64, 4_u64, 5_u64]},
      {8_i64, 4, [0_u64, 3_u64, 4_u64, 7_u64, 8_u64]},
      {10_i64, 4, [0_u64, 3_u64, 4_u64, 5_u64, 8_u64, 9_u64, 10_u64]},
      {17_i64, 8, [0_u64, 7_u64, 8_u64, 16_u64, 17_u64]},
    ]
    [14, 15, 16, 269, 270, 271].each do |size|
      cases << {size.to_i64, size, [0_u64, (size - 1).to_u64, size.to_u64]}
    end

    cases.each do |byte_size, frame_bytes, queries|
      raw = Bytes.new(byte_size.to_i, 0x5a_u8)
      offsets = byte_size == 0 ? [0_u64] : [0_u64, byte_size.to_u64]
      rows = byte_size == 0 ? ([] of UInt64) : [1_u64]

      planned = CrystalClick::CompressedMarkWriter.plan_literal_positions(
        byte_size, queries, frame_bytes: frame_bytes
      )
      encoded = CrystalClick::CompressedMarkWriter.encode_with_positions(
        raw, offsets, rows, queries, frame_bytes: frame_bytes
      )

      planned.should eq(encoded.positions)
      if byte_size == 0
        planned.should eq([{0_u64, 0_u64}])
        encoded.files.data.should be_empty
      end
    end
  end

  it "uses actual frame starts and in-frame offsets from an independent frame index" do
    raw = Bytes.new(10, 0x39_u8)
    queries = [0_u64, 3_u64, 4_u64, 5_u64, 8_u64, 9_u64, 10_u64]
    planned = CrystalClick::CompressedMarkWriter.plan_literal_positions(
      raw.size.to_i64, queries, frame_bytes: 4
    )
    encoded = CrystalClick::CompressedMarkWriter.encode_with_positions(
      raw, [0_u64, 10_u64], [1_u64], queries, frame_bytes: 4
    )

    budget = CrystalClick::CompressedStreamBudget.read_default
    index = CrystalClick::CompressedFrameIndex.new(encoded.files.data, budget.limits, budget)
    index.frames.map(&.compressed_offset).should eq([0_i64, 30_i64, 60_i64])
    index.frames.map(&.logical_start).should eq([0_i64, 4_i64, 8_i64])
    planned.should eq([
      {0_u64, 0_u64},
      {0_u64, 3_u64},
      {30_u64, 0_u64},
      {30_u64, 1_u64},
      {60_u64, 0_u64},
      {60_u64, 1_u64},
      {88_u64, 0_u64},
    ])
    planned.each_with_index do |position, row|
      index.logical_position(position[0], position[1], false).should eq(queries[row].to_i64)
    end
  end

  it "tracks actual frame sizes across literal-length extension thresholds" do
    cases = [
      {14, 40},
      {15, 42},
      {16, 43},
      {269, 296},
      {270, 298},
      {271, 299},
    ]

    cases.each do |raw_size, physical_size|
      raw = Bytes.new(raw_size, 0x6b_u8)
      queries = [0_u64, (raw_size - 1).to_u64, raw_size.to_u64]
      planned = CrystalClick::CompressedMarkWriter.plan_literal_positions(
        raw_size.to_i64, queries, frame_bytes: raw_size
      )
      encoded = CrystalClick::CompressedMarkWriter.encode_with_positions(
        raw, [0_u64, raw_size.to_u64], [1_u64], queries, frame_bytes: raw_size
      )
      budget = CrystalClick::CompressedStreamBudget.read_default
      index = CrystalClick::CompressedFrameIndex.new(encoded.files.data, budget.limits, budget)

      planned.should eq(encoded.positions)
      index.frames.size.should eq(1)
      index.logical_size.should eq(raw_size.to_i64)
      index.frames.first.compressed_offset.should eq(0_i64)
      index.frames.first.logical_start.should eq(0_i64)
      index.frames.first.decompressed_size.should eq(raw_size.to_i64)
      index.frames.first.end_offset.should eq(physical_size.to_i64)
      planned.should eq([
        {0_u64, 0_u64},
        {0_u64, (raw_size - 1).to_u64},
        {physical_size.to_u64, 0_u64},
      ])
      planned.each_with_index do |position, row|
        index.logical_position(position[0], position[1], false).should eq(queries[row].to_i64)
      end
    end
  end

  it "keeps plans valid after same-size fixed-width coordinate patches change content" do
    byte_size = 48_i64
    queries = [0_u64, 8_u64, 16_u64, 32_u64, 48_u64]
    planned = CrystalClick::CompressedMarkWriter.plan_literal_positions(
      byte_size, queries, frame_bytes: 8
    )
    field_positions = [planned[1], planned[3]]
    original = Bytes.new(byte_size.to_i, 0x00_u8)
    changed = Bytes.new(byte_size.to_i, 0xff_u8)
    w240_patch_position_fields(original, [4, 24], field_positions)
    w240_patch_position_fields(changed, [4, 24], field_positions)
    original.should_not eq(changed)
    original.size.should eq(changed.size)

    original_encoded = CrystalClick::CompressedMarkWriter.encode_with_positions(
      original, [0_u64, byte_size.to_u64], [1_u64], queries, frame_bytes: 8
    )
    changed_encoded = CrystalClick::CompressedMarkWriter.encode_with_positions(
      changed, [0_u64, byte_size.to_u64], [1_u64], queries, frame_bytes: 8
    )
    original_encoded.positions.should eq(planned)
    changed_encoded.positions.should eq(planned)
    original_encoded.files.data.size.should eq(changed_encoded.files.data.size)
    w240_index_positions(original_encoded.files.data, planned, queries)
    w240_index_positions(changed_encoded.files.data, planned, queries)
  end

  it "rejects negative, oversized, and out-of-domain inputs before returning a plan" do
    expect_raises(ArgumentError) do
      CrystalClick::CompressedMarkWriter.plan_literal_positions(-1_i64, [0_u64])
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::CompressedMarkWriter.plan_literal_positions(Int32::MAX.to_i64 + 1_i64, [] of UInt64)
    end
    expect_raises(ArgumentError) do
      CrystalClick::CompressedMarkWriter.plan_literal_positions(1_i64, [2_u64])
    end
    expect_raises(ArgumentError) do
      CrystalClick::CompressedMarkWriter.plan_literal_positions(1_i64, [0_u64], frame_bytes: 0)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      limits = CrystalClick::CompressedStreamLimits.new(max_frame_decompressed_bytes: 3)
      budget = CrystalClick::CompressedStreamBudget.new(limits, writing: true)
      CrystalClick::CompressedMarkWriter.plan_literal_positions(4_i64, [0_u64], frame_bytes: 4, budget: budget)
    end
  end

  it "charges only query records and retained positions, and preflights both limits" do
    budget = CrystalClick::CompressedStreamBudget.new(
      CrystalClick::CompressedStreamLimits.new(max_records: 2, max_result_bytes: 32), writing: true
    )
    positions = CrystalClick::CompressedMarkWriter.plan_literal_positions(
      10_i64, [0_u64, 10_u64], frame_bytes: 4, budget: budget
    )
    positions.size.should eq(2)
    budget.record_count.should eq(2_i64)
    budget.result_byte_count.should eq(32_i64)
    budget.file_byte_count.should eq(0_i64)
    budget.decoded_byte_count.should eq(0_i64)

    records_limited = CrystalClick::CompressedStreamBudget.new(
      CrystalClick::CompressedStreamLimits.new(max_records: 1), writing: true
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::CompressedMarkWriter.plan_literal_positions(
        1_i64, [UInt64::MAX, 0_u64], budget: records_limited
      )
    end
    records_limited.record_count.should eq(0_i64)

    results_limited = CrystalClick::CompressedStreamBudget.new(
      CrystalClick::CompressedStreamLimits.new(max_result_bytes: 16), writing: true
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::CompressedMarkWriter.plan_literal_positions(
        1_i64, [0_u64, 1_u64], budget: results_limited
      )
    end
    results_limited.record_count.should eq(0_i64)
    results_limited.result_byte_count.should eq(0_i64)
  end

  it "enforces exhausted cumulative record and result budgets across planning calls" do
    result_limited = CrystalClick::CompressedStreamBudget.new(
      CrystalClick::CompressedStreamLimits.new(max_records: 3, max_result_bytes: 32), writing: true
    )
    2.times do
      CrystalClick::CompressedMarkWriter.plan_literal_positions(1_i64, [0_u64], budget: result_limited)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::CompressedMarkWriter.plan_literal_positions(1_i64, [0_u64], budget: result_limited)
    end
    result_limited.record_count.should eq(2_i64)
    result_limited.result_byte_count.should eq(32_i64)

    record_limited = CrystalClick::CompressedStreamBudget.new(
      CrystalClick::CompressedStreamLimits.new(max_records: 2, max_result_bytes: 48), writing: true
    )
    2.times do
      CrystalClick::CompressedMarkWriter.plan_literal_positions(1_i64, [0_u64], budget: record_limited)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::CompressedMarkWriter.plan_literal_positions(1_i64, [0_u64], budget: record_limited)
    end
    record_limited.record_count.should eq(2_i64)
    record_limited.result_byte_count.should eq(32_i64)
  end

  it "enforces the compressed-size cap on a partial final frame" do
    budget = CrystalClick::CompressedStreamBudget.new(
      CrystalClick::CompressedStreamLimits.new(max_frame_compressed_bytes: 25), writing: true
    )
    CrystalClick::CompressedMarkWriter.plan_literal_positions(
      14_i64, [0_u64, 14_u64], frame_bytes: 16, budget: budget
    ).should eq([{0_u64, 0_u64}, {40_u64, 0_u64}])

    # With frame_bytes=16, byte_size=15 is a single partial last frame.
    # Its extra LZ4 extension byte pushes the compressed-size field over 25.
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::CompressedMarkWriter.plan_literal_positions(
        15_i64, [0_u64, 15_u64], frame_bytes: 16, budget: budget
      )
    end
    budget.record_count.should eq(2_i64)
    budget.result_byte_count.should eq(32_i64)
  end

  it "does not consume budget for invalid coordinates" do
    budget = CrystalClick::CompressedStreamBudget.write_default
    expect_raises(ArgumentError) do
      CrystalClick::CompressedMarkWriter.plan_literal_positions(1_i64, [2_u64], budget: budget)
    end
    budget.record_count.should eq(0_i64)
    budget.result_byte_count.should eq(0_i64)
  end

  it "rejects a read-direction budget" do
    budget = CrystalClick::CompressedStreamBudget.read_default
    expect_raises(ArgumentError) do
      CrystalClick::CompressedMarkWriter.plan_literal_positions(1_i64, [0_u64], budget: budget)
    end
    budget.record_count.should eq(0_i64)
    budget.result_byte_count.should eq(0_i64)
  end
end
