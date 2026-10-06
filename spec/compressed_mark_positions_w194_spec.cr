require "./spec_helper"

private def w194_marks(records : Array(Tuple(UInt64, UInt64, UInt64))) : Bytes
  output = Bytes.new(records.size * CrystalClick::CompressedMarkWriter::MARK_RECORD_SIZE, 0_u8)
  records.each_with_index do |record, record_index|
    record_offset = record_index * CrystalClick::CompressedMarkWriter::MARK_RECORD_SIZE
    w194_write_u64(output, record_offset, record[0])
    w194_write_u64(output, record_offset + 8, record[1])
    w194_write_u64(output, record_offset + 16, record[2])
  end
  output
end

private def w194_write_u64(output : Bytes, offset : Int32, word : UInt64) : Nil
  8.times do |byte_index|
    output[offset + byte_index] = ((word >> (byte_index * 8)) & 0xff_u64).to_u8
  end
end

describe "W194 compressed mark physical-position queries" do
  it "maps partial/full-frame boundaries with the same physical coordinates as the paired mark writer" do
    raw = Bytes[0x41_u8, 0x42_u8, 0x43_u8, 0x44_u8, 0x45_u8, 0x46_u8, 0x47_u8, 0x48_u8, 0x49_u8]
    offsets = [2_u64, 4_u64, 9_u64]
    rows = [1_u64, 1_u64]
    queries = [9_u64, 3_u64, 4_u64, 3_u64, 0_u64, 8_u64]

    positioned = CrystalClick::CompressedMarkWriter.encode_with_positions(
      raw, offsets, rows, queries, prefix_size: 2, frame_bytes: 4
    )
    ordinary = CrystalClick::CompressedMarkWriter.encode(
      raw, offsets, rows, prefix_size: 2, frame_bytes: 4
    )

    positioned.files.data.should eq(ordinary.data)
    positioned.files.marks.should eq(ordinary.marks)
    positioned.positions.should eq([
      {87_u64, 0_u64}, # logical EOF: three frames, including one partial frame
      {0_u64, 3_u64},  # inside frame zero
      {30_u64, 0_u64}, # exact full-frame boundary
      {0_u64, 3_u64},  # duplicate query retains its position in the result
      {0_u64, 0_u64},
      {60_u64, 0_u64}, # second full-frame boundary
    ])
    positioned.count.should eq(queries.size)
  end

  it "keeps the prefix mark identity at logical EOF while an EOF query uses canonical physical EOF" do
    raw = Bytes[1_u8, 2_u8, 3_u8, 4_u8, 5_u8, 6_u8, 7_u8, 8_u8]
    result = CrystalClick::CompressedMarkWriter.encode_with_positions(
      raw, [8_u64, 8_u64], [2_u64], [8_u64, 0_u64, 8_u64],
      prefix_size: 8, frame_bytes: 8
    )

    result.files.marks.should eq(w194_marks([
      {0_u64, 8_u64, 2_u64},
      {34_u64, 0_u64, 0_u64},
    ]))
    result.positions.should eq([
      {34_u64, 0_u64},
      {0_u64, 0_u64},
      {34_u64, 0_u64},
    ])
  end

  it "returns canonical zero positions for duplicate queries on an empty stream" do
    result = CrystalClick::CompressedMarkWriter.encode_with_positions(
      Bytes.empty, [0_u64], [] of UInt64, [0_u64, 0_u64], frame_bytes: 4
    )

    result.files.data.should be_empty
    result.files.marks.should eq(w194_marks([{0_u64, 0_u64, 0_u64}]))
    result.positions.should eq([{0_u64, 0_u64}, {0_u64, 0_u64}])
  end

  it "rejects query offsets outside the logical UInt64 byte domain" do
    raw = Bytes[0x41_u8]
    offsets = [0_u64, 1_u64]
    rows = [1_u64]

    {2_u64, UInt64::MAX}.each do |query|
      expect_raises(ArgumentError) do
        CrystalClick::CompressedMarkWriter.encode_with_positions(raw, offsets, rows, [query])
      end
    end

    expect_raises(ArgumentError) do
      CrystalClick::CompressedMarkWriter.encode_with_positions(
        raw, offsets, rows, [0_u64], budget: CrystalClick::CompressedStreamBudget.read_default
      )
    end
  end

  it "preflights the declared query record count before inspecting query offsets" do
    raw = Bytes[0x41_u8]
    offsets = [0_u64, 1_u64]
    rows = [1_u64]
    queries = [UInt64::MAX, 0_u64]
    budget = CrystalClick::CompressedStreamBudget.new(
      CrystalClick::CompressedStreamLimits.new(max_records: 4), writing: true
    )

    # One frame plus two mark records fit; the two query records do not.
    # The budget rejection must win before inspecting the invalid first query.
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::CompressedMarkWriter.encode_with_positions(
        raw, offsets, rows, queries, frame_bytes: 1, budget: budget
      )
    end
    budget.record_count.should eq(0_i64)
  end

  it "charges file bytes only to files and includes query records and position results in the shared budget" do
    raw = Bytes[0x41_u8]
    offsets = [0_u64, 1_u64]
    rows = [1_u64]
    limits = CrystalClick::CompressedStreamLimits.new(
      max_file_bytes: 150,
      max_records: 8,
      max_decoded_bytes: 2,
      max_result_bytes: 182,
    )
    budget = CrystalClick::CompressedStreamBudget.new(limits, writing: true)

    2.times do
      CrystalClick::CompressedMarkWriter.encode_with_positions(
        raw, offsets, rows, [0_u64], frame_bytes: 1, budget: budget
      )
    end

    budget.file_byte_count.should eq(150_i64)   # 2 * (27 data + 48 marks)
    budget.record_count.should eq(8_i64)        # 2 * (1 frame + 2 marks + 1 query)
    budget.decoded_byte_count.should eq(2_i64)  # query result storage is not decoded input
    budget.result_byte_count.should eq(182_i64) # 2 * (75 file bytes + 16 query bytes)

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::CompressedMarkWriter.encode_with_positions(
        raw, offsets, rows, [0_u64], frame_bytes: 1, budget: budget
      )
    end
  end

  it "preflights query record and result-byte limits" do
    raw = Bytes[0x41_u8]
    offsets = [0_u64, 1_u64]
    rows = [1_u64]

    records_budget = CrystalClick::CompressedStreamBudget.new(
      CrystalClick::CompressedStreamLimits.new(max_records: 3), writing: true
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::CompressedMarkWriter.encode_with_positions(
        raw, offsets, rows, [0_u64], frame_bytes: 1, budget: records_budget
      )
    end

    result_budget = CrystalClick::CompressedStreamBudget.new(
      CrystalClick::CompressedStreamLimits.new(max_result_bytes: 90), writing: true
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::CompressedMarkWriter.encode_with_positions(
        raw, offsets, rows, [0_u64], frame_bytes: 1, budget: result_budget
      )
    end
  end

  it "preflights a batch together with query records and retained query positions" do
    raw_sizes = [1_i32]
    mark_count = 2
    query_count = 1_i64

    exact_budget = CrystalClick::CompressedStreamBudget.new(
      CrystalClick::CompressedStreamLimits.new(
        max_file_bytes: 75,
        max_records: 4,
        max_decoded_bytes: 1,
        max_result_bytes: 91,
      ), writing: true
    )
    CrystalClick::CompressedMarkWriter.preflight_batch_with_positions(
      raw_sizes, mark_count, query_count, 1, exact_budget
    ).should be_nil
    exact_budget.file_byte_count.should eq(0_i64)
    exact_budget.record_count.should eq(0_i64)
    exact_budget.decoded_byte_count.should eq(0_i64)
    exact_budget.result_byte_count.should eq(0_i64)

    record_limited_budget = CrystalClick::CompressedStreamBudget.new(
      CrystalClick::CompressedStreamLimits.new(max_records: 3), writing: true
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::CompressedMarkWriter.preflight_batch_with_positions(
        raw_sizes, mark_count, query_count, 1, record_limited_budget
      )
    end
    record_limited_budget.record_count.should eq(0_i64)

    result_limited_budget = CrystalClick::CompressedStreamBudget.new(
      CrystalClick::CompressedStreamLimits.new(max_result_bytes: 90), writing: true
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::CompressedMarkWriter.preflight_batch_with_positions(
        raw_sizes, mark_count, query_count, 1, result_limited_budget
      )
    end
    result_limited_budget.result_byte_count.should eq(0_i64)

    expect_raises(ArgumentError) do
      CrystalClick::CompressedMarkWriter.preflight_batch_with_positions(
        raw_sizes, mark_count, -1_i64, 1, exact_budget
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::CompressedMarkWriter.preflight_batch_with_positions(
        raw_sizes, mark_count, Int64::MAX, 1, exact_budget
      )
    end
  end

  it "returns detached position snapshots and safe file holders" do
    raw = Bytes[0x41_u8, 0x42_u8]
    result = CrystalClick::CompressedMarkWriter.encode_with_positions(
      raw, [0_u64, 2_u64], [1_u64], [1_u64, 2_u64], frame_bytes: 1
    )

    position_snapshot = result.positions
    position_snapshot[0] = {UInt64::MAX, UInt64::MAX}
    result.positions.should eq([{27_u64, 0_u64}, {54_u64, 0_u64}])
    result.position_at(0).should eq({27_u64, 0_u64})
    expect_raises(IndexError) { result.position_at(-1) }
    expect_raises(IndexError) { result.position_at(result.count) }

    data_snapshot = result.files.data
    marks_snapshot = result.files.marks
    data_snapshot[0] ^= 0xff_u8
    marks_snapshot[0] ^= 0xff_u8
    result.files.data.should_not eq(data_snapshot)
    result.files.marks.should_not eq(marks_snapshot)
  end

  it "matches the ordinary encoder's budget charges when there are no position queries" do
    raw = Bytes[0x41_u8, 0x42_u8, 0x43_u8]
    offsets = [1_u64, 3_u64]
    rows = [1_u64]
    ordinary_budget = CrystalClick::CompressedStreamBudget.write_default
    positions_budget = CrystalClick::CompressedStreamBudget.write_default

    ordinary = CrystalClick::CompressedMarkWriter.encode(
      raw, offsets, rows, prefix_size: 1, frame_bytes: 2, budget: ordinary_budget
    )
    positioned = CrystalClick::CompressedMarkWriter.encode_with_positions(
      raw, offsets, rows, [] of UInt64, prefix_size: 1, frame_bytes: 2, budget: positions_budget
    )

    positioned.files.data.should eq(ordinary.data)
    positioned.files.marks.should eq(ordinary.marks)
    positioned.positions.should be_empty
    positions_budget.file_byte_count.should eq(ordinary_budget.file_byte_count)
    positions_budget.record_count.should eq(ordinary_budget.record_count)
    positions_budget.decoded_byte_count.should eq(ordinary_budget.decoded_byte_count)
    positions_budget.result_byte_count.should eq(ordinary_budget.result_byte_count)
  end
end
