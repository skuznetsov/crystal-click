require "spec"
require "file_utils"
require "../src/crystal_click/errors"
require "../src/crystal_click/metadata"
require "../src/crystal_click/lz4"
require "../src/crystal_click/zstd"
require "../src/crystal_click/compressed_block"
require "../src/crystal_click/part_checksums"
require "../src/crystal_click"

CHECKSUMS_V4_HEADER    = "checksums format version: 4\n"
PART_CHECKSUMS_FIXTURE = File.expand_path("../test/fixtures/public/wide_u64_lz4/part", __DIR__)

private def part_checksum_fixture_copy
  path = File.tempname("crystal-click-part-checksum-spec")
  FileUtils.cp_r(PART_CHECKSUMS_FIXTURE, path)
  path
end

private def part_checksum_with_fixture_copy(&)
  path = part_checksum_fixture_copy
  begin
    yield path
  ensure
    FileUtils.rm_rf(path)
  end
end

private def part_checksum_writable_file_bytes(file : String) : Bytes
  bytes = Bytes.new(File.size(file).to_i)
  File.open(file) { |io| io.read_fully(bytes) }
  bytes
end

private def checksum_bytes(values : Array(UInt8)) : Bytes
  bytes = Bytes.new(values.size)
  values.each_with_index { |value, index| bytes[index] = value }
  bytes
end

private def checksum_var_uint(value : UInt64) : Array(UInt8)
  bytes = [] of UInt8
  remaining = value
  while remaining >= 0x80
    bytes << ((remaining & 0x7f) | 0x80).to_u8
    remaining >>= 7
  end
  bytes << remaining.to_u8
  bytes
end

private def checksum_write_u32(bytes : Bytes, offset : Int, value : Int)
  4.times do |index|
    bytes[offset + index] = ((value.to_u32 >> (index * 8)) & 0xff_u32).to_u8
  end
end

private def checksum_literal_lz4(payload : Bytes) : Bytes
  bytes = [] of UInt8
  if payload.size < 15
    bytes << (payload.size << 4).to_u8
  else
    bytes << 0xf0_u8
    remaining = payload.size - 15
    while remaining >= 255
      bytes << 255_u8
      remaining -= 255
    end
    bytes << remaining.to_u8
  end
  payload.each { |byte| bytes << byte }
  checksum_bytes(bytes)
end

private def checksum_v4(payload : Bytes) : Bytes
  compressed = checksum_literal_lz4(payload)
  compressed_size = 9 + compressed.size
  frame = Bytes.new(16 + compressed_size, 0_u8)
  frame[16] = CrystalClick::CompressedBlock::METHOD_LZ4
  checksum_write_u32(frame, 17, compressed_size)
  checksum_write_u32(frame, 21, payload.size)
  compressed.copy_to(frame[25, compressed.size])

  output = Bytes.new(CHECKSUMS_V4_HEADER.bytesize + frame.size, 0_u8)
  CHECKSUMS_V4_HEADER.to_slice.copy_to(output)
  frame.copy_to(output[CHECKSUMS_V4_HEADER.bytesize, frame.size])
  output
end

private def checksum_v3_entry(
  name : String,
  physical_size : UInt64,
  compressed : Bool = true,
  uncompressed_size : UInt64 = physical_size,
  compressed_flag : UInt8? = nil,
) : Array(UInt8)
  bytes = [] of UInt8
  bytes.concat(checksum_var_uint(name.bytesize.to_u64))
  bytes.concat(name.bytes)
  bytes.concat(checksum_var_uint(physical_size))
  16.times { bytes << 0_u8 }
  bytes << (compressed_flag || (compressed ? 1_u8 : 0_u8))
  if compressed
    bytes.concat(checksum_var_uint(uncompressed_size))
    16.times { bytes << 0_u8 }
  end
  bytes
end

private def checksum_payload(entries : Array({String, UInt64, Bool})) : Bytes
  bytes = [] of UInt8
  bytes.concat(checksum_var_uint(entries.size.to_u64))
  entries.each do |entry|
    bytes.concat(checksum_v3_entry(entry[0], entry[1], entry[2]))
  end
  checksum_bytes(bytes)
end

describe CrystalClick::PartChecksums do
  it "preserves positional checksum entry construction without a recorded hash argument" do
    entry = CrystalClick::PartChecksums::Entry.new(24_u64, false, nil)
    entry.physical_size.should eq(24_u64)
    entry.file_hash.should eq({0_u64, 0_u64})
  end

  it "retains the little-endian writer-recorded hash for primary.idx without promoting size-only checks" do
    parent = File.tempname("crystal-click-checksum-hash-spec")
    Dir.mkdir(parent)
    begin
      part_path = File.join(parent, "part")
      keys = [1_u64, 2_u64, 3_u64, 4_u64]
      values = [10_u64, 20_u64, 30_u64, 40_u64]
      CrystalClick::WidePartWriter.write_uint64_pair(
        part_path,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "value",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 2
      )

      primary_index_contents = File.read(File.join(part_path, "primary.idx"))
      primary_index = primary_index_contents.to_slice
      checksums = CrystalClick::PartChecksums.open(part_path)
      primary_entry = checksums.entry("primary.idx").not_nil!
      primary_entry.file_hash.should eq(CrystalClick::CityHashV1.file_hash(primary_index))
      checksums.validate_selected_entries(part_path, "primary.idx").should eq(
        CrystalClick::ChecksumVerification::SizeChecked
      )

      stock_part_path = File.expand_path("../test/fixtures/public/wide_u64_pk_raw/part", __DIR__)
      stock_primary_contents = File.read(File.join(stock_part_path, "primary.idx"))
      stock_primary_index = stock_primary_contents.to_slice
      stock_primary_entry = CrystalClick::PartChecksums.open(stock_part_path).entry("primary.idx").not_nil!
      stock_primary_entry.file_hash.should eq(CrystalClick::CityHashV1.file_hash(stock_primary_index))
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "parses the public v4 fixture and checks selected physical sizes only" do
    checksums = CrystalClick::PartChecksums.open(PART_CHECKSUMS_FIXTURE)
    data_name = File.basename(Dir.glob(File.join(PART_CHECKSUMS_FIXTURE, "*.bin")).first.not_nil!)
    mark_name = File.basename(Dir.glob(File.join(PART_CHECKSUMS_FIXTURE, "*.mrk2")).first.not_nil!)

    checksums.entry(data_name).not_nil!.compressed.should be_true
    checksums.entry(mark_name).not_nil!.compressed.should be_false
    checksums.validate_selected_entries(PART_CHECKSUMS_FIXTURE, data_name, mark_name).should eq(
      CrystalClick::ChecksumVerification::SizeChecked
    )

    zstd_fixture = File.expand_path("../test/fixtures/public/wide_u64_zstd_cmrk2/part", __DIR__)
    zstd_checksums = CrystalClick::PartChecksums.open(zstd_fixture)
    zstd_mark_name = File.basename(Dir.glob(File.join(zstd_fixture, "*.cmrk2")).first.not_nil!)
    zstd_checksums.entry(zstd_mark_name).not_nil!.compressed.should be_true
    zstd_checksums.validate_selected_entries(
      zstd_fixture,
      File.basename(Dir.glob(File.join(zstd_fixture, "*.bin")).first.not_nil!),
      zstd_mark_name
    ).should eq(CrystalClick::ChecksumVerification::SizeChecked)
  end

  it "requires the exact v4 header, complete compressed payload, and EOF" do
    checksums_path = File.join(PART_CHECKSUMS_FIXTURE, "checksums.txt")
    bytes = part_checksum_writable_file_bytes(checksums_path)
    wrong_version = Bytes.new(bytes.size, 0_u8)
    bytes.copy_to(wrong_version)
    wrong_version[26] = '3'.ord.to_u8

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::PartChecksums.parse(wrong_version)
    end

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::PartChecksums.parse(bytes[0, bytes.size - 1])
    end

    part_checksum_with_fixture_copy do |path|
      checksum_file = File.join(path, "checksums.txt")
      File.open(checksum_file, "ab") { |io| io.write(Bytes[0]) }
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::PartChecksums.open(path)
      end
    end
  end

  it "keeps outer frame checksum bytes explicitly unverified" do
    part_checksum_with_fixture_copy do |path|
      checksum_path = File.join(path, "checksums.txt")
      bytes = part_checksum_writable_file_bytes(checksum_path)
      bytes[CHECKSUMS_V4_HEADER.bytesize] ^= 0xff_u8
      File.open(checksum_path, "wb") { |io| io.write(bytes) }

      checksums = CrystalClick::PartChecksums.open(path)
      data_name = File.basename(Dir.glob(File.join(path, "*.bin")).first.not_nil!)
      mark_name = File.basename(Dir.glob(File.join(path, "*.mrk2")).first.not_nil!)
      checksums.validate_selected_entries(path, data_name, mark_name).should eq(
        CrystalClick::ChecksumVerification::SizeChecked
      )
    end
  end

  it "rejects duplicate and unsafe v3 entry names" do
    duplicate = checksum_payload([{"data.bin", 10_u64, true}, {"data.bin", 10_u64, true}])
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::PartChecksums.parse(checksum_v4(duplicate))
    end

    {"../data.bin", "/tmp/data.bin", "a/../data.bin"}.each do |name|
      payload = checksum_payload([{name, 10_u64, true}])
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::PartChecksums.parse(checksum_v4(payload))
      end
    end
  end

  it "rejects a v3 entry truncated within the physical hash bytes" do
    name = "primary.idx"
    entry = checksum_v3_entry(name, 24_u64, compressed: false)
    hash_start = checksum_var_uint(name.bytesize.to_u64).size + name.bytesize + checksum_var_uint(24_u64).size
    truncated_payload = [1_u8]
    truncated_payload.concat(entry[0, hash_start + 7])

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::PartChecksums.parse(checksum_v4(checksum_bytes(truncated_payload)))
    end
  end

  it "bounds entry count and selected-entry presence and physical size" do
    count = CrystalClick::PartChecksums::MAX_ENTRIES + 1
    oversized_count = checksum_bytes(checksum_var_uint(count.to_u64))
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::PartChecksums.parse(checksum_v4(oversized_count))
    end

    oversized_name = "x" * (CrystalClick::PartChecksums::MAX_NAME_BYTES + 1)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::PartChecksums.parse(checksum_v4(checksum_payload([{oversized_name, 10_u64, true}])))
    end

    unrelated_max = CrystalClick::PartChecksums.parse(
      checksum_v4(checksum_payload([{"unrelated.bin", UInt64::MAX, true}]))
    )
    unrelated_entry = unrelated_max.entry("unrelated.bin").not_nil!
    unrelated_entry.physical_size.should eq(UInt64::MAX)
    unrelated_entry.uncompressed_size.should eq(UInt64::MAX)

    part_checksum_with_fixture_copy do |path|
      checksums = CrystalClick::PartChecksums.open(path)
      data_name = File.basename(Dir.glob(File.join(path, "*.bin")).first.not_nil!)
      mark_name = File.basename(Dir.glob(File.join(path, "*.mrk2")).first.not_nil!)

      expect_raises(CrystalClick::CorruptPartError) do
        checksums.validate_selected_entries(path, data_name, "missing.mrk2")
      end

      data_path = File.join(path, data_name)
      File.open(data_path, "ab") { |io| io.write(Bytes[0]) }
      expect_raises(CrystalClick::CorruptPartError) do
        checksums.validate_selected_entries(path, data_name, mark_name)
      end
    end
  end
end
