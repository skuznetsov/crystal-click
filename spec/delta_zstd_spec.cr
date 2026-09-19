require "./spec_helper"

DELTA_ZSTD_FIXTURE = File.expand_path("../test/fixtures/public/wide_u64_delta_zstd/part", __DIR__)
DELTA_ZSTD_ROWS    = 4096
DELTA_ZSTD_MARK    =  256

def delta_zstd_values : Array(UInt64)
  values = Array(UInt64).new(DELTA_ZSTD_ROWS)
  DELTA_ZSTD_ROWS.times do |number|
    value = if number == 127
              UInt64::MAX
            elsif number == 128
              0_u64
            elsif number == 129
              1_u64
            elsif number == 255
              UInt64::MAX
            elsif number == 256
              0_u64
            elsif number < 512
              (number % 7).to_u64
            elsif number < 1024
              1000_u64
            elsif number % 11 == 0
              42_u64
            else
              number.to_u64
            end
    values << value
  end
  values
end

def delta_zstd_u32(bytes : Bytes, offset : Int) : UInt32
  bytes[offset].to_u32 |
    (bytes[offset + 1].to_u32 << 8) |
    (bytes[offset + 2].to_u32 << 16) |
    (bytes[offset + 3].to_u32 << 24)
end

def delta_zstd_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

def delta_zstd_frames(bytes : Bytes) : Array(Tuple(Int32, UInt8, UInt32, UInt32, Int32))
  frames = Array(Tuple(Int32, UInt8, UInt32, UInt32, Int32)).new
  offset = 0
  while offset < bytes.size
    raise "truncated compressed frame header" if bytes.size - offset < 25
    method = bytes[offset + 16]
    compressed_size = delta_zstd_u32(bytes, offset + 17)
    decompressed_size = delta_zstd_u32(bytes, offset + 21)
    frame_end = offset + 16 + compressed_size.to_i
    raise "truncated compressed frame payload" if frame_end > bytes.size
    frames << {offset, method, compressed_size, decompressed_size, frame_end}
    offset = frame_end
  end
  frames
end

def with_delta_zstd_fixture_copy(&)
  path = File.tempname("crystal-click-delta-zstd-spec")
  FileUtils.cp_r(DELTA_ZSTD_FIXTURE, path)
  begin
    yield path
  ensure
    FileUtils.rm_rf(path)
  end
end

def delta_zstd_data_file(path : String) : String
  Dir.glob(File.join(path, "*.bin")).first.not_nil!
end

def delta_zstd_hex(hex : String) : Bytes
  raise "odd-length hex test vector" unless hex.size.even?
  bytes = Bytes.new(hex.size // 2)
  bytes.size.times do |index|
    bytes[index] = hex[index * 2, 2].to_i(16).to_u8
  end
  bytes
end

def delta_zstd_write_u32(bytes : Bytes, offset : Int, value : Int)
  4.times do |index|
    bytes[offset + index] = ((value >> (index * 8)) & 0xff).to_u8
  end
end

def delta_zstd_tiny_frame(zstd_payload : Bytes, nested_output_size : Int, output_size : Int) : Bytes
  nested_compressed_size = 9 + zstd_payload.size
  outer_payload_size = 3 + nested_compressed_size
  outer_compressed_size = 9 + outer_payload_size
  frame = Bytes.new(16 + outer_compressed_size, 0_u8)
  frame[16] = 0x91_u8
  delta_zstd_write_u32(frame, 17, outer_compressed_size)
  delta_zstd_write_u32(frame, 21, output_size)

  frame[25] = 2_u8
  frame[26] = 0x92_u8
  frame[27] = 0x90_u8
  nested_offset = 28
  frame[nested_offset] = 0x90_u8
  delta_zstd_write_u32(frame, nested_offset + 1, nested_compressed_size)
  delta_zstd_write_u32(frame, nested_offset + 5, nested_output_size)
  zstd_payload.copy_to(frame[nested_offset + 9, zstd_payload.size])
  frame
end

describe "Wide UInt64 Delta/ZSTD fixture" do
  it "pins the outer Multiple and nested ZSTD frame chain" do
    data_path = Dir.glob(File.join(DELTA_ZSTD_FIXTURE, "*.bin")).first.not_nil!
    data_contents = File.read(data_path)
    data_frames = delta_zstd_frames(data_contents.to_slice)
    data_frames.size.should eq(8)

    data_frames.each do |frame|
      offset = frame[0]
      method = frame[1]
      compressed_size = frame[2]
      decompressed_size = frame[3]
      frame_end = frame[4]
      method.should eq(0x91_u8)
      decompressed_size.should eq(4096_u32)

      payload_offset = offset + 25
      data_contents.to_slice[payload_offset].should eq(2_u8)
      data_contents.to_slice[payload_offset + 1].should eq(0x92_u8)
      data_contents.to_slice[payload_offset + 2].should eq(0x90_u8)

      nested_offset = payload_offset + 3
      data_contents.to_slice[nested_offset].should eq(0x90_u8)
      nested_compressed_size = delta_zstd_u32(data_contents.to_slice, nested_offset + 1)
      nested_decompressed_size = delta_zstd_u32(data_contents.to_slice, nested_offset + 5)
      nested_compressed_size.should be >= 9_u32
      nested_decompressed_size.should eq(decompressed_size + 11_u32)
      (nested_offset + nested_compressed_size.to_i).should eq(frame_end)
      (offset + 16 + compressed_size.to_i).should eq(frame_end)
    end

    mark_path = Dir.glob(File.join(DELTA_ZSTD_FIXTURE, "*.cmrk2")).first.not_nil!
    mark_contents = File.read(mark_path)
    mark_frames = delta_zstd_frames(mark_contents.to_slice)
    mark_frames.map { |frame| frame[1] }.should eq([0x90_u8, 0x90_u8])
    mark_frames.map { |frame| frame[3] }.should eq([256_u32, 152_u32])
    mark_frames.sum { |frame| frame[3].to_i }.should eq(17 * 24)

    decoded_marks = CrystalClick::CompressedBlock.decode_all(mark_contents.to_slice)
    local_offsets = (0...(decoded_marks.size // 24)).map do |index|
      delta_zstd_u64(decoded_marks, index * 24 + 8)
    end
    local_offsets.first.should eq(0_u64)
    local_offsets.any? { |offset| offset > 0 }.should be_true
  end

  it "reads every known value from the Delta/ZSTD chain" do
    part = CrystalClick::WidePart.open(DELTA_ZSTD_FIXTURE)
    part.row_count.should eq(DELTA_ZSTD_ROWS)
    part.mark_count.should eq(16)
    part.read_uint64.should eq(delta_zstd_values)
  end

  it "reads the middle marks without adjacent values" do
    part = CrystalClick::WidePart.open(DELTA_ZSTD_FIXTURE)
    expected = delta_zstd_values
    part.read_uint64_mark_range("value", 5, 3).should eq(expected[5 * DELTA_ZSTD_MARK, 3 * DELTA_ZSTD_MARK])
  end

  it "ends a selected range at a nonzero local mark offset" do
    part = CrystalClick::WidePart.open(DELTA_ZSTD_FIXTURE)
    expected = delta_zstd_values
    part.read_uint64_mark_range("value", 4, 1).should eq(expected[4 * DELTA_ZSTD_MARK, DELTA_ZSTD_MARK])
  end

  it "reads the final marks through the EOF sentinel" do
    part = CrystalClick::WidePart.open(DELTA_ZSTD_FIXTURE)
    expected = delta_zstd_values
    part.read_uint64_mark_range("value", 14, 2).should eq(expected[14 * DELTA_ZSTD_MARK, 2 * DELTA_ZSTD_MARK])
  end

  it "rejects unsupported Multiple method lists" do
    with_delta_zstd_fixture_copy do |path|
      data = delta_zstd_data_file(path)
      mutate_fixture_file(path, File.basename(data)) { |bytes| bytes[25] = 3_u8 }
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompressedBlock.decode_frame(writable_file_bytes(data), 0_i64)
      end
    end

    with_delta_zstd_fixture_copy do |path|
      data = delta_zstd_data_file(path)
      mutate_fixture_file(path, File.basename(data)) do |bytes|
        bytes[26] = 0x90_u8
        bytes[27] = 0x92_u8
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::CompressedBlock.decode_frame(writable_file_bytes(data), 0_i64)
      end
    end

    with_delta_zstd_fixture_copy do |path|
      data = delta_zstd_data_file(path)
      mutate_fixture_file(path, File.basename(data)) { |bytes| bytes[26] = 0x93_u8 }
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::CompressedBlock.decode_frame(writable_file_bytes(data), 0_i64)
      end
    end
  end

  it "rejects nested header method, size, truncation, and trailing mutations" do
    with_delta_zstd_fixture_copy do |path|
      data = delta_zstd_data_file(path)
      mutate_fixture_file(path, File.basename(data)) { |bytes| bytes[28] = 0x92_u8 }
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::CompressedBlock.decode_frame(writable_file_bytes(data), 0_i64)
      end
    end

    with_delta_zstd_fixture_copy do |path|
      data = delta_zstd_data_file(path)
      mutate_fixture_file(path, File.basename(data)) { |bytes| bytes[29] &-= 1_u8 }
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompressedBlock.decode_frame(writable_file_bytes(data), 0_i64)
      end
    end

    with_delta_zstd_fixture_copy do |path|
      data = delta_zstd_data_file(path)
      bytes = writable_file_bytes(data)
      first_frame_end = delta_zstd_frames(bytes)[0][4]
      File.open(data, "wb") { |io| io.write(bytes[0, first_frame_end - 1]) }
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompressedBlock.decode_frame(writable_file_bytes(data), 0_i64)
      end
    end

    with_delta_zstd_fixture_copy do |path|
      data = delta_zstd_data_file(path)
      bytes = writable_file_bytes(data)
      first_frame_end = delta_zstd_frames(bytes)[0][4]
      frame = bytes[0, first_frame_end]
      expanded = Bytes.new(frame.size + 1, 0_u8)
      frame.copy_to(expanded)
      delta_zstd_write_u32(expanded, 17, delta_zstd_u32(expanded, 17).to_i + 1)
      File.open(data, "wb") { |io| io.write(expanded) }
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::CompressedBlock.decode_frame(writable_file_bytes(data), 0_i64)
      end
    end
  end

  it "rejects unsupported and malformed nested Delta payloads" do
    vectors = [
      {"28b52ffd201399000090130000000800000008000100000000000000", 19, 8},   # wrong nested method
      {"28b52ffd201399000092130000000800000001000100000000000000", 19, 8},   # width 1
      {"28b52ffd201399000092130000000800000008010100000000000000", 19, 8},   # nonzero skip
      {"28b52ffd2012910000921200000007000000080001000000000000", 18, 7},     # unaligned output
      {"28b52ffd201399000092120000000800000008000100000000000000", 19, 8},   # stage size mismatch
      {"28b52ffd2014a100009214000000080000000800010000000000000058", 20, 8}, # trailing Delta payload
    ]

    vectors.each_with_index do |vector, index|
      frame = delta_zstd_tiny_frame(delta_zstd_hex(vector[0]), vector[1], vector[2])
      exception = index == 1 ? CrystalClick::UnsupportedFormatError : CrystalClick::CorruptPartError
      exception = CrystalClick::UnsupportedFormatError if index == 0
      exception = CrystalClick::CorruptPartError if index == 2
      expect_raises(exception) do
        CrystalClick::CompressedBlock.decode_frame(frame, 0_i64)
      end
    end
  end

  it "honors per-frame and aggregate decoded-size limits for Multiple" do
    valid_stage = delta_zstd_hex("28b52ffd201399000092130000000800000008000100000000000000")
    frame = delta_zstd_tiny_frame(valid_stage, 19, 8)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::CompressedBlock.decode_frame(frame, 0_i64, 64_i64 * 1024 * 1024, 7_i64)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::CompressedBlock.decode_all(frame, 64_i64 * 1024 * 1024, 64_i64 * 1024 * 1024, 7_i64)
    end
  end
end
