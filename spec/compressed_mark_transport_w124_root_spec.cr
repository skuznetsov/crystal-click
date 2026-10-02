require "./spec_helper"

private def w124_root_u64(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (8 * index)) & 255_u64).to_u8) }
end

# Independent literal-only LZ4 frame; no W124 production writer or index is
# involved in reader expectations. These small inputs need no extension byte.
private def w124_root_frame(raw : Bytes) : Bytes
  raise "root literal frame size" unless 0 < raw.size < 15
  payload = IO::Memory.new
  payload.write_byte(CrystalClick::CompressedBlock::METHOD_LZ4)
  payload.write_bytes((10 + raw.size).to_u32, IO::ByteFormat::LittleEndian)
  payload.write_bytes(raw.size.to_u32, IO::ByteFormat::LittleEndian)
  payload.write_byte((raw.size << 4).to_u8)
  payload.write(raw)
  hash = CrystalClick::CityHashV1.hash128(payload.to_slice)
  output = IO::Memory.new
  w124_root_u64(output, hash[0])
  w124_root_u64(output, hash[1])
  output.write(payload.to_slice)
  output.to_slice
end

private def w124_root_marks(grid : Array(Tuple(UInt64, UInt64, UInt64))) : Bytes
  output = IO::Memory.new
  grid.each { |record| record.each { |word| w124_root_u64(output, word) } }
  output.to_slice
end

# Visible Multiple -> ZSTD framing only. No decoder must allocate from this
# unauthenticated nested size before the whole touched-work reservation.
private def w124_root_multiple(nested_output_size : UInt32) : Bytes
  payload = IO::Memory.new
  payload.write_byte(CrystalClick::CompressedBlock::METHOD_MULTIPLE)
  payload.write_bytes(21_u32, IO::ByteFormat::LittleEndian)
  payload.write_bytes(8_u32, IO::ByteFormat::LittleEndian)
  payload.write(Bytes[2, CrystalClick::CompressedBlock::METHOD_DELTA, CrystalClick::CompressedBlock::METHOD_ZSTD])
  payload.write_byte(CrystalClick::CompressedBlock::METHOD_ZSTD)
  payload.write_bytes(9_u32, IO::ByteFormat::LittleEndian)
  payload.write_bytes(nested_output_size, IO::ByteFormat::LittleEndian)
  hash = CrystalClick::CityHashV1.hash128(payload.to_slice)
  output = IO::Memory.new
  w124_root_u64(output, hash[0])
  w124_root_u64(output, hash[1])
  output.write(payload.to_slice)
  output.to_slice
end

private def w124_root_files(data : Bytes, marks : Bytes, &)
  data_path = File.tempname("crystal-click-w124-root-data")
  marks_path = File.tempname("crystal-click-w124-root-marks")
  begin
    File.open(data_path, "wb") { |io| io.write(data) }
    File.open(marks_path, "wb") { |io| io.write(marks) }
    yield data_path, marks_path
  ensure
    File.delete(data_path) if File.exists?(data_path)
    File.delete(marks_path) if File.exists?(marks_path)
  end
end

private def w124_root_literal : {Bytes, Bytes}
  first = w124_root_frame(Bytes[0, 0, 0, 0, 0, 0, 0, 0, 0x41, 0x42, 0x43, 0x44])
  second = w124_root_frame(Bytes[0x45, 0x46, 0x47])
  third = w124_root_frame(Bytes[0x48, 0x49])
  output = IO::Memory.new
  {first, second, third}.each { |frame| output.write(frame) }
  output.size.should eq(95)
  grid = [
    {0_u64, 8_u64, 2_u64}, {0_u64, 10_u64, 2_u64},
    {38_u64, 2_u64, 2_u64}, {95_u64, 0_u64, 0_u64},
  ]
  {output.to_slice, w124_root_marks(grid)}
end

describe "W124 independent compressed mark transport" do
  it "does not mistake a valid plain grid for compressed marks from row-count bytes" do
    data = w124_root_frame(Bytes[0x41_u8])
    # The plain grid is 48 bytes. Its row field happens to place LZ4's method
    # at byte 16 and a compressed-size word of 32 immediately after it.
    # Header-shaped content alone is not authority to change its format.
    marks = w124_root_marks([{0_u64, 0_u64, 8322_u64}, {27_u64, 0_u64, 0_u64}])
    w124_root_files(data, marks) do |data_path, marks_path|
      window = CrystalClick::CompressedMarkReader.read(data_path, marks_path,
        expected_data_size: 27_i64, expected_mark_size: 48_i64)
      window.bytes.should eq(Bytes[0x41_u8])
      window.rows_per_mark.should eq([8322_u64])
    end
  end

  it "limits actual short writer frames rather than an unused configured frame size" do
    limits = CrystalClick::CompressedStreamLimits.new(max_frame_decompressed_bytes: 2,
      max_frame_compressed_bytes: 11)
    files = CrystalClick::CompressedMarkWriter.encode(Bytes[0x41_u8], [0_u64, 1_u64], [1_u64],
      frame_bytes: 4096, budget: CrystalClick::CompressedStreamBudget.new(limits, writing: true))
    files.data.should eq(w124_root_frame(Bytes[0x41_u8]))
  end

  it "reserves known writer frame counts before per-frame size work" do
    raw = Bytes.new(1024, 0x41_u8)
    limits = CrystalClick::CompressedStreamLimits.new(max_records: 2,
      max_frame_compressed_bytes: 0)
    {true, false}.each do |paired|
      budget = CrystalClick::CompressedStreamBudget.new(limits, writing: true)
      error = expect_raises(CrystalClick::UnsupportedFormatError) do
        if paired
          CrystalClick::CompressedMarkWriter.encode(raw, [0_u64, 1024_u64], [1_u64],
            frame_bytes: 1, budget: budget)
        else
          CrystalClick::CompressedMarkWriter.encode_all(raw, frame_bytes: 1, budget: budget)
        end
      end
      error.message.not_nil!.should match(/record.*limit/i)
      budget.record_count.should eq(0)
    end
  end

  it "keeps the first prefix coordinate even when every real body is empty" do
    raw = Bytes[1, 2, 3, 4, 5, 6, 7, 8]
    files = CrystalClick::CompressedMarkWriter.encode(raw, [8_u64, 8_u64], [2_u64],
      prefix_size: 8, frame_bytes: 8)
    files.marks.should eq(w124_root_marks([{0_u64, 8_u64, 2_u64}, {34_u64, 0_u64, 0_u64}]))
    w124_root_files(files.data, files.marks) do |data_path, marks_path|
      window = CrystalClick::CompressedMarkReader.read(data_path, marks_path,
        expected_data_size: 34_i64, expected_mark_size: 48_i64, prefix_size: 8)
      window.bytes.should eq(raw)
      window.offsets.should eq([8_u64, 8_u64])
    end
  end

  it "rejects limit values outside the supported signed accounting domain" do
    expect_raises(ArgumentError) { CrystalClick::CompressedStreamLimits.new(max_records: UInt64::MAX) }
    expect_raises(ArgumentError) { CrystalClick::CompressedStreamLimits.new(max_decoded_bytes: UInt128::MAX) }
  end

  it "owns constructor inputs as well as copies returned by public accessors" do
    bytes = Bytes[0x41_u8]
    marks = Bytes.new(24, 0_u8)
    offsets = [0_u64, 1_u64]
    rows = [1_u64]
    window = CrystalClick::CompressedMarkWindow.new(bytes, offsets, rows, 0, 0)
    files = CrystalClick::CompressedMarkFiles.new(bytes, marks)
    bytes[0] = 0_u8
    marks[0] = 1_u8
    offsets[0] = 1_u64
    rows[0] = 9_u64
    window.bytes.should eq(Bytes[0x41_u8])
    window.offsets.should eq([0_u64, 1_u64])
    window.rows_per_mark.should eq([1_u64])
    files.data.should eq(Bytes[0x41_u8])
    files.marks.should eq(Bytes.new(24, 0_u8))
  end

  it "writes an adaptive terminal grid without interpreting outer rows as lane values" do
    files = CrystalClick::CompressedMarkWriter.encode(
      Bytes[0x61, 0x62, 0x63], [0_u64, 1_u64, 1_u64, 3_u64], [2_u64, 2_u64, 2_u64], frame_bytes: 2
    )
    files.marks.size.should eq(96)
    CrystalClick::CompressedBlock.decode_all(files.data).should eq(Bytes[0x61, 0x62, 0x63])
    expected = IO::Memory.new
    expected.write(w124_root_frame(Bytes[0x61, 0x62]))
    expected.write(w124_root_frame(Bytes[0x63]))
    files.data.should eq(expected.to_slice)
    files.marks.should eq(w124_root_marks([
      {0_u64, 0_u64, 2_u64}, {0_u64, 1_u64, 2_u64},
      {0_u64, 1_u64, 2_u64}, {55_u64, 0_u64, 0_u64},
    ]))
  end

  it "joins prefix and selected crossing bytes into a detached local window" do
    data, marks = w124_root_literal
    budget = CrystalClick::CompressedStreamBudget.new(CrystalClick::CompressedStreamLimits.new)
    result = nil.as(CrystalClick::CompressedMarkWindow?)
    w124_root_files(data, marks) do |data_path, marks_path|
      result = CrystalClick::CompressedMarkReader.read(data_path, marks_path,
        expected_data_size: 95_i64, expected_mark_size: 96_i64,
        first_mark: 1, mark_count: 1, prefix_size: 8, budget: budget)
    end
    window = result.not_nil!
    window.first_mark.should eq(1)
    window.prefix_size.should eq(8)
    window.bytes.should eq(Bytes[0, 0, 0, 0, 0, 0, 0, 0, 0x43, 0x44, 0x45, 0x46])
    window.offsets.should eq([8_u64, 12_u64])
    window.rows_per_mark.should eq([2_u64])
    budget.decoded_byte_count.should eq(15)
    budget.result_byte_count.should eq(12)
    budget.file_byte_count.should eq(191)
    detached_bytes = window.bytes
    detached_bytes[8] = 0_u8
    detached_offsets = window.offsets
    detached_offsets[0] = 0_u64
    detached_rows = window.rows_per_mark
    detached_rows[0] = 9_u64
    window.bytes[8].should eq(0x43_u8)
    window.offsets.should eq([8_u64, 12_u64])
    window.rows_per_mark.should eq([2_u64])
  end

  it "does not decode or checksum an unselected trailing frame" do
    data, marks = w124_root_literal
    data[67] ^= 1_u8 # checksum of the third frame, outside this window
    w124_root_files(data, marks) do |data_path, marks_path|
      CrystalClick::CompressedMarkReader.read(data_path, marks_path,
        expected_data_size: 95_i64, expected_mark_size: 96_i64,
        first_mark: 1, mark_count: 1, prefix_size: 8).bytes.size.should eq(12)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompressedMarkReader.read(data_path, marks_path,
          expected_data_size: 95_i64, expected_mark_size: 96_i64,
          first_mark: 2, mark_count: 1, prefix_size: 8)
      end
    end
  end

  it "admits frame-end aliases and repeated empty lanes without touching the next frame" do
    data, _ = w124_root_literal
    marks = w124_root_marks([
      {0_u64, 8_u64, 2_u64}, {0_u64, 12_u64, 2_u64},
      {38_u64, 0_u64, 2_u64}, {95_u64, 0_u64, 0_u64},
    ])
    data[38] ^= 1_u8 # next frame checksum must not be consumed by empty body
    budget = CrystalClick::CompressedStreamBudget.new(CrystalClick::CompressedStreamLimits.new)
    w124_root_files(data, marks) do |data_path, marks_path|
      window = CrystalClick::CompressedMarkReader.read(data_path, marks_path,
        expected_data_size: 95_i64, expected_mark_size: 96_i64,
        first_mark: 1, mark_count: 1, prefix_size: 8, budget: budget)
      window.bytes.should eq(Bytes.new(8, 0_u8))
      window.offsets.should eq([8_u64, 8_u64])
      window.rows_per_mark.should eq([2_u64])
    end
    budget.decoded_byte_count.should eq(12)
  end

  it "validates marks outside the selected domain and true terminal EOF even for zero selection" do
    data, _ = w124_root_literal
    bad_grids = [
      [{0_u64, 8_u64, 2_u64}, {39_u64, 0_u64, 2_u64}, {38_u64, 2_u64, 2_u64}, {95_u64, 0_u64, 0_u64}],
      [{0_u64, 8_u64, 2_u64}, {0_u64, 10_u64, 0_u64}, {38_u64, 2_u64, 2_u64}, {95_u64, 0_u64, 0_u64}],
      [{0_u64, 8_u64, 2_u64}, {0_u64, 10_u64, 2_u64}, {38_u64, 2_u64, 2_u64}, {67_u64, 1_u64, 0_u64}],
    ]
    bad_grids.each do |grid|
      w124_root_files(data, w124_root_marks(grid)) do |data_path, marks_path|
        expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::CompressedMarkReader.read(data_path, marks_path,
            expected_data_size: 95_i64, expected_mark_size: 96_i64,
            first_mark: 0, mark_count: 0, prefix_size: 8)
        end
      end
    end
  end

  it "normalizes a last-frame-end terminal and a zero selection at the original EOF" do
    data, _ = w124_root_literal
    marks = w124_root_marks([
      {0_u64, 8_u64, 2_u64}, {0_u64, 10_u64, 2_u64},
      {38_u64, 2_u64, 2_u64}, {67_u64, 2_u64, 0_u64},
    ])
    w124_root_files(data, marks) do |data_path, marks_path|
      window = CrystalClick::CompressedMarkReader.read(data_path, marks_path,
        expected_data_size: 95_i64, expected_mark_size: 96_i64,
        first_mark: 3, mark_count: 0, prefix_size: 8)
      window.first_mark.should eq(3)
      window.bytes.should eq(Bytes.new(8, 0_u8))
      window.offsets.should eq([8_u64])
      window.rows_per_mark.should be_empty
    end
  end

  it "reserves full touched decode work before a corrupt selected checksum is examined" do
    data, marks = w124_root_literal
    data[0] ^= 1_u8
    limits = CrystalClick::CompressedStreamLimits.new(max_decoded_bytes: 14)
    budget = CrystalClick::CompressedStreamBudget.new(limits)
    w124_root_files(data, marks) do |data_path, marks_path|
      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompressedMarkReader.read(data_path, marks_path,
          expected_data_size: 95_i64, expected_mark_size: 96_i64,
          first_mark: 1, mark_count: 1, prefix_size: 8, budget: budget)
      end
      error.message.not_nil!.should match(/decoded.*limit/)
    end
  end

  it "retains an aggregate file budget across separate role reads" do
    data, marks = w124_root_literal
    limits = CrystalClick::CompressedStreamLimits.new(max_file_bytes: 381)
    budget = CrystalClick::CompressedStreamBudget.new(limits)
    w124_root_files(data, marks) do |data_path, marks_path|
      CrystalClick::CompressedMarkReader.read(data_path, marks_path,
        expected_data_size: 95_i64, expected_mark_size: 96_i64,
        first_mark: 1, mark_count: 1, prefix_size: 8, budget: budget)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompressedMarkReader.read(data_path, marks_path,
          expected_data_size: 95_i64, expected_mark_size: 96_i64,
          first_mark: 1, mark_count: 1, prefix_size: 8, budget: budget)
      end
    end
  end

  it "rejects an oversized visible Multiple stage before nested workspace allocation" do
    data = w124_root_multiple(64_u32 * 1024 * 1024)
    marks = w124_root_marks([{0_u64, 0_u64, 1_u64}, {37_u64, 0_u64, 0_u64}])
    w124_root_files(data, marks) do |data_path, marks_path|
      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompressedMarkReader.read(data_path, marks_path,
          expected_data_size: 37_i64, expected_mark_size: 48_i64)
      end
      error.message.not_nil!.should match(/nested.*(size|work)/)
    end
  end

  it "charges Multiple intermediate and final work before inspecting a checksum" do
    data = w124_root_multiple(19_u32) # 8-byte output plus Delta header and parameters
    data[0] ^= 1_u8
    marks = w124_root_marks([{0_u64, 0_u64, 1_u64}, {37_u64, 0_u64, 0_u64}])
    limits = CrystalClick::CompressedStreamLimits.new(max_decoded_bytes: 26)
    budget = CrystalClick::CompressedStreamBudget.new(limits)
    w124_root_files(data, marks) do |data_path, marks_path|
      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompressedMarkReader.read(data_path, marks_path,
          expected_data_size: 37_i64, expected_mark_size: 48_i64, budget: budget)
      end
      error.message.not_nil!.should match(/decoded.*limit/)
    end
  end

  it "charges raw encoding work and the complete unpublished file pair" do
    budget = CrystalClick::CompressedStreamBudget.new(CrystalClick::CompressedStreamLimits.new, writing: true)
    CrystalClick::CompressedMarkWriter.encode(
      Bytes[0x61, 0x62, 0x63], [0_u64, 1_u64, 1_u64, 3_u64], [2_u64, 2_u64, 2_u64],
      frame_bytes: 2, budget: budget)
    budget.decoded_byte_count.should eq(3)
    budget.file_byte_count.should eq(151)
    budget.result_byte_count.should eq(151)
    budget.record_count.should eq(6)
    tight_budget = CrystalClick::CompressedStreamBudget.new(
      CrystalClick::CompressedStreamLimits.new(max_decoded_bytes: 2), writing: true)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::CompressedMarkWriter.encode(Bytes[0x61, 0x62, 0x63], [0_u64, 3_u64], [1_u64], budget: tight_budget)
    end
  end

  it "bounds header indexing work before examining an over-budget trailing frame" do
    first = w124_root_frame(Bytes[0x41_u8])
    second = w124_root_frame(Bytes[0x42_u8])
    second[CrystalClick::CompressedBlock::CHECKSUM_SIZE] = 0x83_u8
    output = IO::Memory.new
    output.write(first)
    output.write(second)
    data = output.to_slice
    budget = CrystalClick::CompressedStreamBudget.new(CrystalClick::CompressedStreamLimits.new(max_records: 1))
    w124_root_files(data, Bytes.empty) do |data_path, _|
      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompressedMarkReader.read_all(data_path, expected_size: data.size.to_i64, budget: budget)
      end
      error.message.not_nil!.should match(/record.*limit/)
      budget.record_count.should eq(1)
    end
  end

  it "reads stock ZSTD and admitted Delta/ZSTD bytes without changing their frame methods" do
    {"wide_u64_zstd_cmrk2", "wide_u64_delta_zstd"}.each do |profile|
      part = File.expand_path("../test/fixtures/public/#{profile}/part", __DIR__)
      data_path = File.join(part, "caa7f9c8e43d2fa739d1e26d71e99843.bin")
      budget = CrystalClick::CompressedStreamBudget.new
      actual = CrystalClick::CompressedMarkReader.read_all(data_path,
        expected_size: File.size(data_path), budget: budget)
      expected = IO::Memory.new
      count = profile == "wide_u64_delta_zstd" ? 4096 : 200_000
      count.times do |number|
        value = if profile != "wide_u64_delta_zstd"
                  number.to_u64
                elsif number == 127 || number == 255
                  UInt64::MAX
                elsif number == 128 || number == 256
                  0_u64
                elsif number == 129
                  1_u64
                elsif number < 512
                  (number % 7).to_u64
                elsif number < 1024
                  1000_u64
                elsif number % 11 == 0
                  42_u64
                else
                  number.to_u64
                end
        expected.write_bytes(value, IO::ByteFormat::LittleEndian)
      end
      actual.should eq(expected.to_slice)
      budget.result_byte_count.should eq(count * 8)
      if profile == "wide_u64_delta_zstd"
        budget.decoded_byte_count.should eq(8 * (4096 + 4107))
      else
        budget.decoded_byte_count.should eq(count * 8)
      end
    end
  end

  it "preserves real marks after the last byte occurrence in a nonempty lane" do
    files = CrystalClick::CompressedMarkWriter.encode(
      Bytes[0x41_u8, 0x42_u8, 0x43_u8], [0_u64, 3_u64, 3_u64], [2_u64, 2_u64], frame_bytes: 2)
    w124_root_files(files.data, files.marks) do |data_path, marks_path|
      window = CrystalClick::CompressedMarkReader.read(data_path, marks_path,
        expected_data_size: files.data.size.to_i64, expected_mark_size: files.marks.size.to_i64,
        first_mark: 1, mark_count: 1)
      window.bytes.should be_empty
      window.offsets.should eq([0_u64, 0_u64])
      window.rows_per_mark.should eq([2_u64])
    end
  end

  it "admits a source-valid positive-row real mark at physical EOF" do
    data = w124_root_frame(Bytes[0x41_u8, 0x42_u8, 0x43_u8])
    data[0] ^= 1_u8 # no prefix/body bytes in this window, so no frame is touched
    marks = w124_root_marks([{0_u64, 0_u64, 2_u64}, {29_u64, 0_u64, 2_u64}, {29_u64, 0_u64, 0_u64}])
    budget = CrystalClick::CompressedStreamBudget.new
    w124_root_files(data, marks) do |data_path, marks_path|
      window = CrystalClick::CompressedMarkReader.read(data_path, marks_path,
        expected_data_size: 29_i64, expected_mark_size: 72_i64,
        first_mark: 1, mark_count: 1, budget: budget)
      window.bytes.should be_empty
      window.offsets.should eq([0_u64, 0_u64])
      window.rows_per_mark.should eq([2_u64])
    end
    budget.decoded_byte_count.should eq(0)
    budget.result_byte_count.should eq(0)
  end

  it "does not let compressed-mark classification bypass the header work cap" do
    compressed_marks = IO::Memory.new
    2.times { compressed_marks.write(w124_root_frame(Bytes[0x41_u8])) }
    budget = CrystalClick::CompressedStreamBudget.new(CrystalClick::CompressedStreamLimits.new(max_records: 1))
    w124_root_files(Bytes.empty, compressed_marks.to_slice) do |data_path, marks_path|
      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompressedMarkReader.read(data_path, marks_path,
          expected_data_size: 0_i64, expected_mark_size: 54_i64, budget: budget)
      end
      error.message.not_nil!.should match(/record.*limit/)
      budget.record_count.should eq(1)
    end
  end
end
