require "./spec_helper"

# These controls author the ClickHouse frame and mark bytes directly. The
# production writer/index never supplies its own expected transport bytes.
private def w124_oracle_write_u64(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
end

private def w124_oracle_write_u32(bytes : Bytes, offset : Int32, value : UInt32) : Nil
  4.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u32).to_u8 }
end

private def w124_oracle_write_hash(bytes : Bytes, offset : Int32, hash : {UInt64, UInt64}) : Nil
  w124_oracle_write_u64_at(bytes, offset, hash[0])
  w124_oracle_write_u64_at(bytes, offset + 8, hash[1])
end

private def w124_oracle_write_u64_at(bytes : Bytes, offset : Int32, value : UInt64) : Nil
  8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w124_oracle_frame(raw : Bytes) : Bytes
  raise "W124 literal frame needs 1..14 raw bytes" unless 1 <= raw.size < 15
  compressed_size = 10 + raw.size
  frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + 1 + raw.size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w124_oracle_write_u32(frame, header + 1, compressed_size.to_u32)
  w124_oracle_write_u32(frame, header + 5, raw.size.to_u32)
  frame[CrystalClick::CompressedBlock::FRAME_HEADER_SIZE] = (raw.size << 4).to_u8
  raw.copy_to(frame[CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + 1, raw.size])
  w124_oracle_write_hash(frame, 0, CrystalClick::CityHashV1.hash128(frame[header, compressed_size]))
  frame
end

private def w124_oracle_marks(grid : Array(Tuple(UInt64, UInt64, UInt64))) : Bytes
  io = IO::Memory.new
  grid.each { |record| record.each { |word| w124_oracle_write_u64(io, word) } }
  io.to_slice
end

private def w124_oracle_files(data : Bytes, marks : Bytes, &) : Nil
  data_path = File.tempname("crystal-click-w124-oracle-data")
  marks_path = File.tempname("crystal-click-w124-oracle-marks")
  begin
    File.open(data_path, "wb") { |io| io.write(data) }
    File.open(marks_path, "wb") { |io| io.write(marks) }
    yield data_path, marks_path
  ensure
    File.delete(data_path) if File.exists?(data_path)
    File.delete(marks_path) if File.exists?(marks_path)
  end
end

private def w124_oracle_read_budget(limits : CrystalClick::CompressedStreamLimits = CrystalClick::CompressedStreamLimits.new) : CrystalClick::CompressedStreamBudget
  CrystalClick::CompressedStreamBudget.new(limits)
end

describe "W124 transport preflight and file-boundary controls" do
  it "preflights the aggregate mark/header record limit before validating a late malformed row count" do
    first = w124_oracle_frame(Bytes[0x41_u8])
    marks = w124_oracle_marks([
      {0_u64, 0_u64, 1_u64}, {0_u64, 0_u64, 1_u64},
      {0_u64, 0_u64, 1_u64}, {0_u64, 0_u64, UInt64::MAX},
      {first.size.to_u64, 0_u64, 0_u64},
    ])
    limits = CrystalClick::CompressedStreamLimits.new(max_records: 2)
    budget = w124_oracle_read_budget(limits)
    w124_oracle_files(first, marks) do |data_path, marks_path|
      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompressedMarkReader.read(data_path, marks_path,
          expected_data_size: first.size.to_i64, expected_mark_size: marks.size.to_i64,
          first_mark: 0, mark_count: 0, budget: budget)
      end
      error.message.not_nil!.should match(/record.*limit/i)
      budget.record_count.should be <= limits.max_records
    end
  end

  it "preflights retained window bytes against the result limit" do
    data = w124_oracle_frame(Bytes[0x41_u8, 0x42_u8, 0x43_u8])
    marks = w124_oracle_marks([
      {0_u64, 0_u64, 2_u64}, {data.size.to_u64, 0_u64, 0_u64},
    ])
    budget = w124_oracle_read_budget(CrystalClick::CompressedStreamLimits.new(max_result_bytes: 2))
    w124_oracle_files(data, marks) do |data_path, marks_path|
      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompressedMarkReader.read(data_path, marks_path,
          expected_data_size: data.size.to_i64, expected_mark_size: marks.size.to_i64,
          first_mark: 0, mark_count: 1, budget: budget)
      end
      error.message.not_nil!.should match(/result.*limit/i)
    end
  end

  it "uses read_all for the full metadata suffix and verifies every frame checksum" do
    first = w124_oracle_frame(Bytes[0x41_u8, 0x42_u8])
    suffix = w124_oracle_frame(Bytes[0x53_u8, 0x55_u8, 0x46_u8])
    data = Bytes.new(first.size + suffix.size)
    first.copy_to(data[0, first.size])
    suffix.copy_to(data[first.size, suffix.size])
    w124_oracle_files(data, w124_oracle_marks([{0_u64, 0_u64, 0_u64}])) do |data_path, _|
      CrystalClick::CompressedMarkReader.read_all(data_path, expected_size: data.size.to_i64).should eq(
        Bytes[0x41_u8, 0x42_u8, 0x53_u8, 0x55_u8, 0x46_u8]
      )
    end
    expect_raises(ArgumentError) do
      CrystalClick::CompressedMarkWriter.encode_all(Bytes.empty)
    end
    w124_oracle_files(Bytes.empty, Bytes.empty) do |data_path, _|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompressedMarkReader.read_all(data_path, expected_size: 0_i64)
      end
    end

    corrupted_suffix = data.dup
    corrupted_suffix[first.size] ^= 1_u8
    w124_oracle_files(corrupted_suffix, w124_oracle_marks([{0_u64, 0_u64, 0_u64}])) do |data_path, _|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompressedMarkReader.read_all(data_path, expected_size: corrupted_suffix.size.to_i64)
      end
    end
  end

  it "admits the paired empty lane only with the canonical zero terminal and zero prefix" do
    files = CrystalClick::CompressedMarkWriter.encode(Bytes.empty, [0_u64], [] of UInt64)
    files.data.should be_empty
    files.marks.should eq(w124_oracle_marks([{0_u64, 0_u64, 0_u64}]))
    w124_oracle_files(files.data, files.marks) do |data_path, marks_path|
      window = CrystalClick::CompressedMarkReader.read(data_path, marks_path,
        expected_data_size: 0_i64, expected_mark_size: 24_i64)
      window.bytes.should be_empty
      window.offsets.should eq([0_u64])
      window.rows_per_mark.should be_empty
      window.prefix_size.should eq(0)
    end

    invalid = w124_oracle_marks([{0_u64, 1_u64, 0_u64}])
    w124_oracle_files(Bytes.empty, invalid) do |data_path, marks_path|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompressedMarkReader.read(data_path, marks_path,
          expected_data_size: 0_i64, expected_mark_size: invalid.size.to_i64)
      end
    end

    nonempty = w124_oracle_frame(Bytes[0x41_u8])
    nonempty_terminal = w124_oracle_marks([{nonempty.size.to_u64, 0_u64, 0_u64}])
    w124_oracle_files(nonempty, nonempty_terminal) do |data_path, marks_path|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompressedMarkReader.read(data_path, marks_path,
          expected_data_size: nonempty.size.to_i64, expected_mark_size: nonempty_terminal.size.to_i64,
          first_mark: 0, mark_count: 0)
      end
    end
    expect_raises(ArgumentError) do
      CrystalClick::CompressedMarkWriter.encode(Bytes[0x41_u8], [0_u64], [] of UInt64)
    end
  end

  it "retains positive outer-row marks for an all-empty lane" do
    files = CrystalClick::CompressedMarkWriter.encode(Bytes.empty,
      [0_u64, 0_u64, 0_u64], [2_u64, 2_u64])
    files.data.should be_empty
    files.marks.should eq(w124_oracle_marks([
      {0_u64, 0_u64, 2_u64}, {0_u64, 0_u64, 2_u64}, {0_u64, 0_u64, 0_u64},
    ]))
    w124_oracle_files(files.data, files.marks) do |data_path, marks_path|
      window = CrystalClick::CompressedMarkReader.read(data_path, marks_path,
        expected_data_size: 0_i64, expected_mark_size: 72_i64,
        first_mark: 0, mark_count: 2)
      window.bytes.should be_empty
      window.offsets.should eq([0_u64, 0_u64, 0_u64])
      window.rows_per_mark.should eq([2_u64, 2_u64])
    end
  end

  it "returns detached selected bytes after the mapped source file changes" do
    raw = Bytes[0x41_u8, 0x42_u8]
    data = w124_oracle_frame(raw)
    marks = w124_oracle_marks([
      {0_u64, 0_u64, 1_u64}, {data.size.to_u64, 0_u64, 0_u64},
    ])
    w124_oracle_files(data, marks) do |data_path, marks_path|
      window = CrystalClick::CompressedMarkReader.read(data_path, marks_path,
        expected_data_size: data.size.to_i64, expected_mark_size: marks.size.to_i64,
        first_mark: 0, mark_count: 1)
      window.bytes.should eq(raw)

      File.open(data_path, "r+") do |io|
        io.seek(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + 1)
        io.write_byte(0x5a_u8)
      end
      window.bytes.should eq(raw)
    end
  end

  it "rejects symlinked inputs, mismatched path sizes, invalid windows and a write budget on a read" do
    data = w124_oracle_frame(Bytes[0x41_u8])
    marks = w124_oracle_marks([
      {0_u64, 0_u64, 1_u64}, {data.size.to_u64, 0_u64, 0_u64},
    ])
    w124_oracle_files(data, marks) do |data_path, marks_path|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompressedMarkReader.read(data_path, marks_path,
          expected_data_size: data.size.to_i64 + 1, expected_mark_size: marks.size.to_i64)
      end
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompressedMarkReader.read(data_path, marks_path,
          expected_data_size: data.size.to_i64, expected_mark_size: marks.size.to_i64 - 1)
      end
      {-1, 2}.each do |first_mark|
        expect_raises(ArgumentError) do
          CrystalClick::CompressedMarkReader.read(data_path, marks_path,
            expected_data_size: data.size.to_i64, expected_mark_size: marks.size.to_i64,
            first_mark: first_mark, mark_count: 0)
        end
      end
      expect_raises(ArgumentError) do
        CrystalClick::CompressedMarkReader.read(data_path, marks_path,
          expected_data_size: data.size.to_i64, expected_mark_size: marks.size.to_i64,
          first_mark: 0, mark_count: -1)
      end
      expect_raises(ArgumentError) do
        CrystalClick::CompressedMarkReader.read(data_path, marks_path,
          expected_data_size: data.size.to_i64, expected_mark_size: marks.size.to_i64,
          budget: CrystalClick::CompressedStreamBudget.new(CrystalClick::CompressedStreamLimits.new, writing: true))
      end
      expect_raises(ArgumentError) do
        CrystalClick::CompressedMarkReader.read_all(data_path,
          expected_size: data.size.to_i64,
          budget: CrystalClick::CompressedStreamBudget.new(CrystalClick::CompressedStreamLimits.new, writing: true))
      end

      link_path = File.tempname("crystal-click-w124-oracle-link")
      begin
        File.symlink(data_path, link_path)
        expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::CompressedMarkReader.read(link_path, marks_path,
            expected_data_size: data.size.to_i64, expected_mark_size: marks.size.to_i64)
        end
      ensure
        File.delete(link_path) if File.exists?(link_path)
      end

      marks_link_path = File.tempname("crystal-click-w124-oracle-marks-link")
      begin
        File.symlink(marks_path, marks_link_path)
        expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::CompressedMarkReader.read(data_path, marks_link_path,
            expected_data_size: data.size.to_i64, expected_mark_size: marks.size.to_i64)
        end
      ensure
        File.delete(marks_link_path) if File.exists?(marks_link_path)
      end
    end
  end

  it "classifies truncated frame headers as corrupt and unknown checksummed codecs as unsupported" do
    complete = w124_oracle_frame(Bytes[0x41_u8])
    truncated = complete[0, CrystalClick::CompressedBlock::FRAME_HEADER_SIZE - 1]
    truncated_marks = w124_oracle_marks([
      {0_u64, 0_u64, 1_u64}, {truncated.size.to_u64, 0_u64, 0_u64},
    ])
    w124_oracle_files(truncated, truncated_marks) do |data_path, marks_path|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompressedMarkReader.read(data_path, marks_path,
          expected_data_size: truncated.size.to_i64, expected_mark_size: truncated_marks.size.to_i64)
      end
    end

    unknown = w124_oracle_frame(Bytes[0x41_u8])
    unknown[CrystalClick::CompressedBlock::CHECKSUM_SIZE] = 0x83_u8
    payload_size = unknown.size - CrystalClick::CompressedBlock::CHECKSUM_SIZE
    w124_oracle_write_hash(unknown, 0,
      CrystalClick::CityHashV1.hash128(unknown[CrystalClick::CompressedBlock::CHECKSUM_SIZE, payload_size]))
    unknown_marks = w124_oracle_marks([
      {0_u64, 0_u64, 1_u64}, {unknown.size.to_u64, 0_u64, 0_u64},
    ])
    w124_oracle_files(unknown, unknown_marks) do |data_path, marks_path|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::CompressedMarkReader.read(data_path, marks_path,
          expected_data_size: unknown.size.to_i64, expected_mark_size: unknown_marks.size.to_i64)
      end
    end
  end

  it "rejects invalid writer domains and resource limits before returning framed files" do
    bytes = Bytes[0x41_u8, 0x42_u8, 0x43_u8]
    expect_raises(ArgumentError) do
      CrystalClick::CompressedMarkWriter.encode(bytes, [0_u64, 3_u64], [] of UInt64)
    end
    expect_raises(ArgumentError) do
      CrystalClick::CompressedMarkWriter.encode(bytes, [1_u64, 3_u64], [1_u64])
    end
    expect_raises(ArgumentError) do
      CrystalClick::CompressedMarkWriter.encode(bytes, [0_u64, 2_u64, 1_u64], [1_u64, 1_u64])
    end
    expect_raises(ArgumentError) do
      CrystalClick::CompressedMarkWriter.encode(bytes, [0_u64, 2_u64], [1_u64], prefix_size: 2, frame_bytes: 1)
    end
    expect_raises(ArgumentError) do
      CrystalClick::CompressedMarkWriter.encode(bytes, [0_u64, 3_u64], [1_u64], frame_bytes: 0)
    end

    write_budget = CrystalClick::CompressedStreamBudget.new(
      CrystalClick::CompressedStreamLimits.new(max_result_bytes: 1), writing: true
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::CompressedMarkWriter.encode(bytes, [0_u64, 3_u64], [1_u64], budget: write_budget)
    end
    expect_raises(ArgumentError) do
      CrystalClick::CompressedMarkWriter.encode(bytes, [0_u64, 3_u64], [1_u64], budget: w124_oracle_read_budget)
    end
  end
end
