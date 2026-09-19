require "./spec_helper"

ZSTD_FIXTURE = File.expand_path("../test/fixtures/public/wide_u64_zstd_cmrk2/part", __DIR__)

def with_zstd_fixture_copy(&)
  path = File.tempname("crystal-click-zstd-spec")
  FileUtils.cp_r(ZSTD_FIXTURE, path)
  begin
    yield path
  ensure
    FileUtils.rm_rf(path)
  end
end

def zstd_mark_file(path : String) : String
  Dir.glob(File.join(path, "*.cmrk2")).first.not_nil!
end

describe "ClickHouse ZSTD compressed blocks and marks" do
  it "reads the complete UInt64 column" do
    CrystalClick::WidePart.open(ZSTD_FIXTURE).read_uint64.should eq((0_u64...200_000_u64).to_a)
  end

  it "reads the last bounded mark range" do
    CrystalClick::WidePart.open(ZSTD_FIXTURE).read_uint64_mark_range("value", 195, 1).should eq((199_680_u64...200_000_u64).to_a)
  end

  it "rejects an unknown method in compressed marks" do
    with_zstd_fixture_copy do |path|
      mark = zstd_mark_file(path)
      mutate_fixture_file(path, File.basename(mark)) { |bytes| bytes[16] = 0x81_u8 }
      expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::WidePart.open(path) }
    end
  end

  it "rejects unknown and ambiguous compressed mark pairs" do
    with_zstd_fixture_copy do |path|
      mark = zstd_mark_file(path)
      FileUtils.cp(mark, mark.sub(/\.cmrk2$/, ".cmrk3"))
      expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::WidePart.open(path) }
    end

    with_zstd_fixture_copy do |path|
      mark = zstd_mark_file(path)
      FileUtils.cp(mark, mark.sub(/\.cmrk2$/, ".mrk2"))
      expect_raises(CrystalClick::CorruptPartError) { CrystalClick::WidePart.open(path) }
    end
  end

  it "rejects truncated and trailing partial compressed marks" do
    with_zstd_fixture_copy do |path|
      mark = zstd_mark_file(path)
      bytes = writable_file_bytes(mark)
      File.open(mark, "wb") { |io| io.write(bytes[0, bytes.size - 1]) }
      expect_raises(CrystalClick::CorruptPartError) { CrystalClick::WidePart.open(path) }
    end

    with_zstd_fixture_copy do |path|
      mark = zstd_mark_file(path)
      File.open(mark, "ab") { |io| io.write(Bytes[0]) }
      expect_raises(CrystalClick::CorruptPartError) { CrystalClick::WidePart.open(path) }
    end
  end

  it "rejects a trailing complete compressed frame instead of ignoring it" do
    with_zstd_fixture_copy do |path|
      mark = zstd_mark_file(path)
      bytes = writable_file_bytes(mark)
      File.open(mark, "ab") { |io| io.write(bytes[0, 88]) }
      expect_raises(CrystalClick::CorruptPartError) { CrystalClick::WidePart.open(path) }
    end
  end

  it "rejects a declared ZSTD output-size mismatch" do
    with_zstd_fixture_copy do |path|
      mark = zstd_mark_file(path)
      mutate_fixture_file(path, File.basename(mark)) do |bytes|
        bytes[21] = 0xff_u8
        bytes[22] = 0x00_u8
        bytes[23] = 0x00_u8
        bytes[24] = 0x00_u8
      end
      expect_raises(CrystalClick::CorruptPartError) { CrystalClick::WidePart.open(path) }
    end
  end

  it "rejects a ZSTD payload error" do
    with_zstd_fixture_copy do |path|
      mark = zstd_mark_file(path)
      mutate_fixture_file(path, File.basename(mark)) { |bytes| bytes[25] = 0_u8 }
      expect_raises(CrystalClick::CorruptPartError) { CrystalClick::WidePart.open(path) }
    end
  end

  it "keeps checksum verification explicitly unverified for ZSTD reads" do
    with_zstd_fixture_copy do |path|
      data = Dir.glob(File.join(path, "*.bin")).first.not_nil!
      mutate_fixture_file(path, File.basename(data)) { |bytes| bytes[0] ^= 0xff_u8 }
      part = CrystalClick::WidePart.open(path)
      part.checksum_verification.should eq(CrystalClick::ChecksumVerification::Unverified)
      part.read_uint64.should eq((0_u64...200_000_u64).to_a)
    end
  end
end
