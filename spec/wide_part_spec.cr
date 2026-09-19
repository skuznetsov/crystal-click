require "./spec_helper"

describe CrystalClick::WidePart do
  it "reads the generated Wide UInt64 fixture and exposes unverified checksums" do
    part = CrystalClick::WidePart.open(FIXTURE)
    part.row_count.should eq(200_000)
    part.mark_count.should eq(196)
    part.checksum_verification.should eq(CrystalClick::ChecksumVerification::Unverified)
    part.read_uint64.should eq((0_u64...200_000_u64).to_a)
  end

  it "reads a bounded mark range without returning adjacent rows" do
    part = CrystalClick::WidePart.open(FIXTURE)
    part.read_uint64_mark_range("value", 2, 2).should eq((2048_u64...4096_u64).to_a)
  end

  it "resolves the ClickHouse SipHash128 stream name rather than guessing a bin" do
    CrystalClick::StreamName.hash("value").should eq("caa7f9c8e43d2fa739d1e26d71e99843")
    CrystalClick::StreamName.hash("another_value").should eq("e1724e0cad9a5e7ee21557991ad0bc5f")
    part = CrystalClick::WidePart.open(FIXTURE)
    part.data_path.should end_with("caa7f9c8e43d2fa739d1e26d71e99843.bin")
  end

  it "rejects a non-UInt64 column" do
    with_fixture_copy do |path|
      File.write(File.join(path, "columns.txt"), "`value` UInt32\n")
      expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::WidePart.open(path) }
    end
  end

  it "rejects an unsupported default codec" do
    with_fixture_copy do |path|
      File.write(File.join(path, "default_compression_codec.txt"), "CODEC(NONE)\n")
      expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::WidePart.open(path) }
    end
  end

  it "rejects an unsupported mark extension" do
    with_fixture_copy do |path|
      mark = Dir.glob(File.join(path, "*.mrk2")).first
      File.rename(mark, mark.not_nil!.sub(/\.mrk2$/, ".mrk3"))
      expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::WidePart.open(path) }
    end
  end

  it "rejects truncated mark records" do
    with_fixture_copy do |path|
      mark = Dir.glob(File.join(path, "*.mrk2")).first
      File.open(mark, "ab") { |io| io.write(Bytes[0]) }
      expect_raises(CrystalClick::CorruptPartError) { CrystalClick::WidePart.open(path) }
    end
  end

  it "rejects a mark whose compressed offset exceeds the data file" do
    with_fixture_copy do |path|
      mark = Dir.glob(File.join(path, "*.mrk2")).first
      bytes = writable_file_bytes(mark)
      bytes[0, 8].fill(0xff_u8)
      File.open(mark, "wb") { |io| io.write(bytes) }
      expect_raises(CrystalClick::CorruptPartError) { CrystalClick::WidePart.open(path) }
    end
  end

  it "bounds selected decoded bytes before appending beyond the mark range" do
    with_fixture_copy do |path|
      mark = Dir.glob(File.join(path, "*.mrk2")).first.not_nil!
      bytes = writable_file_bytes(mark)
      bytes[16, 8].fill(0_u8)
      bytes[16] = 1_u8
      File.open(mark, "wb") { |io| io.write(bytes) }
      File.write(File.join(path, "count.txt"), "198977\n")

      part = CrystalClick::WidePart.open(path)
      error = expect_raises(CrystalClick::CorruptPartError) do
        part.read_uint64_mark_range("value", 0, 1)
      end
      error.message.not_nil!.should contain("selected data exceeds expected byte count")
    end
  end

  it "rejects an unknown compression method" do
    with_fixture_copy do |path|
      data = Dir.glob(File.join(path, "*.bin")).first
      mutate_fixture_file(path, File.basename(data.not_nil!)) { |bytes| bytes[16] = 0x81_u8 }
      expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::WidePart.open(path).read_uint64 }
    end
  end

  it "rejects a truncated compressed header" do
    with_fixture_copy do |path|
      data = Dir.glob(File.join(path, "*.bin")).first
      File.open(data.not_nil!, "wb") { |io| io.write(Bytes.new(20, 0)) }
      expect_raises(CrystalClick::CorruptPartError) { CrystalClick::WidePart.open(path).read_uint64 }
    end
  end

  it "rejects a frame with a declared payload beyond the file" do
    with_fixture_copy do |path|
      data = Dir.glob(File.join(path, "*.bin")).first
      bytes = writable_file_bytes(data.not_nil!)
      Bytes[0xff, 0xff, 0xff, 0x7f].each_with_index { |value, index| bytes[17 + index] = value }
      File.open(data.not_nil!, "wb") { |io| io.write(bytes) }
      expect_raises(CrystalClick::CorruptPartError) { CrystalClick::WidePart.open(path).read_uint64 }
    end
  end

  it "rejects a declared decompressed size over the bounded limit" do
    with_fixture_copy do |path|
      data = Dir.glob(File.join(path, "*.bin")).first
      bytes = writable_file_bytes(data.not_nil!)
      Bytes[0xff, 0xff, 0xff, 0x7f].each_with_index { |value, index| bytes[21 + index] = value }
      File.open(data.not_nil!, "wb") { |io| io.write(bytes) }
      expect_raises(CrystalClick::CorruptPartError) { CrystalClick::WidePart.open(path).read_uint64 }
    end
  end

  it "rejects trailing bytes after the final compressed frame" do
    with_fixture_copy do |path|
      data = Dir.glob(File.join(path, "*.bin")).first
      File.open(data.not_nil!, "ab") { |io| io.write(Bytes[0]) }
      expect_raises(CrystalClick::CorruptPartError) { CrystalClick::WidePart.open(path).read_uint64 }
    end
  end

  it "accepts an EOF compressed offset on the final sentinel" do
    with_fixture_copy do |path|
      data = Dir.glob(File.join(path, "*.bin")).first.not_nil!
      mark = Dir.glob(File.join(path, "*.mrk2")).first.not_nil!
      bytes = writable_file_bytes(mark)
      sentinel = bytes.size - 24
      eof = File.size(data).to_u64
      8.times { |index| bytes[sentinel + index] = ((eof >> (index * 8)) & 0xff).to_u8 }
      8.times { |index| bytes[sentinel + 8 + index] = 0_u8 }
      8.times { |index| bytes[sentinel + 16 + index] = 0_u8 }
      File.open(mark, "wb") { |io| io.write(bytes) }
      part = CrystalClick::WidePart.open(path)
      part.read_uint64_mark_range("value", 195, 1).should eq((199_680_u64...200_000_u64).to_a)
      part.read_uint64.should eq((0_u64...200_000_u64).to_a)
    end
  end

  it "rejects a non-EOF sentinel that stops before the final frame output" do
    with_fixture_copy do |path|
      mark = Dir.glob(File.join(path, "*.mrk2")).first.not_nil!
      bytes = writable_file_bytes(mark)
      data_mark = (bytes.size - 48) + 16
      sentinel = bytes.size - 24
      bytes[data_mark, 8].fill(0_u8)
      bytes[data_mark] = 1_u8
      bytes[sentinel + 8, 8].fill(0_u8)
      bytes[sentinel + 8] = 0x08_u8
      bytes[sentinel + 9] = 0x60_u8
      File.open(mark, "wb") { |io| io.write(bytes) }
      File.write(File.join(path, "count.txt"), "199681\n")

      part = CrystalClick::WidePart.open(path)
      expect_raises(CrystalClick::CorruptPartError) { part.read_uint64 }
    end
  end

  it "rejects a syntactically framed zero-output block at an EOF sentinel" do
    with_fixture_copy do |path|
      data = Dir.glob(File.join(path, "*.bin")).first.not_nil!
      mark = Dir.glob(File.join(path, "*.mrk2")).first.not_nil!
      zero_frame = Bytes.new(25, 0_u8)
      zero_frame[16] = 0x82_u8
      zero_frame[17] = 9_u8
      File.open(data, "ab") { |io| io.write(zero_frame) }

      bytes = writable_file_bytes(mark)
      sentinel = bytes.size - 24
      eof = File.size(data).to_u64
      8.times { |index| bytes[sentinel + index] = ((eof >> (index * 8)) & 0xff).to_u8 }
      8.times { |index| bytes[sentinel + 8 + index] = 0_u8 }
      8.times { |index| bytes[sentinel + 16 + index] = 0_u8 }
      File.open(mark, "wb") { |io| io.write(bytes) }

      expect_raises(CrystalClick::CorruptPartError) { CrystalClick::WidePart.open(path).read_uint64 }
    end
  end

  it "rejects a row-count mismatch instead of returning a prefix" do
    with_fixture_copy do |path|
      File.write(File.join(path, "count.txt"), "199999\n")
      expect_raises(CrystalClick::CorruptPartError) { CrystalClick::WidePart.open(path).read_uint64 }
    end
  end

  it "keeps checksum verification explicitly unverified" do
    with_fixture_copy do |path|
      data = Dir.glob(File.join(path, "*.bin")).first
      mutate_fixture_file(path, File.basename(data.not_nil!)) { |bytes| bytes[0] ^= 0xff_u8 }
      part = CrystalClick::WidePart.open(path)
      part.checksum_verification.should eq(CrystalClick::ChecksumVerification::Unverified)
      # The CRC/hash bytes are intentionally not trusted by this first slice.
    end
  end

  it "rejects an out-of-range mark request" do
    part = CrystalClick::WidePart.open(FIXTURE)
    expect_raises(CrystalClick::BoundsError) { part.read_uint64_mark_range("value", 196, 1) }
    expect_raises(CrystalClick::BoundsError) { part.read_uint64_mark_range("value", -1, 1) }
  end
end
