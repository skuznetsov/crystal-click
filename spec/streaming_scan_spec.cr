require "./spec_helper"

BORROWED_ZSTD_FIXTURE  = File.expand_path("../test/fixtures/public/wide_u64_zstd_cmrk2/part", __DIR__)
BORROWED_DELTA_FIXTURE = File.expand_path("../test/fixtures/public/wide_u64_delta_zstd/part", __DIR__)
BORROWED_MULTI_FIXTURE = File.expand_path("../test/fixtures/public/wide_multi_input_delta_zstd/part", __DIR__)
BORROWED_ROWS          = 200_000
BORROWED_MARK_ROWS     =   1_024
BORROWED_DELTA_MARK    =     256

def borrowed_scan_chunks(
  part : CrystalClick::WidePart,
  column : String,
  first_mark : Int,
  mark_count : Int,
  scratch_size : Int,
) : {Array(UInt64), Array(Int32), Slice(UInt64)}
  scratch = Slice(UInt64).new(scratch_size)
  values = Array(UInt64).new
  sizes = Array(Int32).new
  first_buffer = scratch
  part.scan_uint64_mark_range_into(column, first_mark, mark_count, scratch) do |chunk|
    sizes << chunk.size
    values.concat(chunk.to_a)
  end
  {values, sizes, first_buffer}
end

def borrowed_u32(bytes : Bytes, offset : Int) : UInt32
  bytes[offset].to_u32 |
    (bytes[offset + 1].to_u32 << 8) |
    (bytes[offset + 2].to_u32 << 16) |
    (bytes[offset + 3].to_u32 << 24)
end

def borrowed_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

def write_borrowed_u64(bytes : Bytes, offset : Int, value : UInt64)
  8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

def borrowed_frame_offsets(bytes : Bytes) : Array(Int32)
  offsets = Array(Int32).new
  offset = 0
  while offset < bytes.size
    raise "truncated test frame header" if bytes.size - offset < 25
    offsets << offset
    compressed_size = borrowed_u32(bytes, offset + 17).to_i
    offset += 16 + compressed_size
  end
  raise "trailing test frame bytes" unless offset == bytes.size
  offsets
end

def with_borrowed_zstd_fixture_copy(&)
  path = File.tempname("crystal-click-borrowed-zstd-spec")
  FileUtils.cp_r(BORROWED_ZSTD_FIXTURE, path)
  begin
    yield path
  ensure
    FileUtils.rm_rf(path)
  end
end

describe "borrowed UInt64 mark-range scanning" do
  it "scans the full LZ4 stream into non-dividing borrowed chunks" do
    part = CrystalClick::WidePart.open(FIXTURE)
    values, sizes, scratch = borrowed_scan_chunks(part, "value", 0, part.mark_count, 257)

    values.should eq((0_u64...BORROWED_ROWS.to_u64).to_a)
    sizes.all? { |size| size > 0 && size <= 257 }.should be_true
    sizes.sum.should eq(BORROWED_ROWS)
    sizes.last.should eq(BORROWED_ROWS % 257)
    scratch.size.should eq(257)
  end

  it "matches direct ZSTD full and range reads" do
    part = CrystalClick::WidePart.open(BORROWED_ZSTD_FIXTURE)
    expected = part.read_uint64
    values, sizes, _ = borrowed_scan_chunks(part, "value", 0, part.mark_count, 511)
    values.should eq(expected)
    sizes.all? { |size| size > 0 && size <= 511 }.should be_true

    expected_range = part.read_uint64_mark_range("value", 5, 3)
    range, _, _ = borrowed_scan_chunks(part, "value", 5, 3, 127)
    range.should eq(expected_range)
  end

  it "matches Delta/ZSTD ranges after full-frame reconstruction and preserves UInt64 wraparound" do
    part = CrystalClick::WidePart.open(BORROWED_DELTA_FIXTURE)
    expected = part.read_uint64
    values, _, _ = borrowed_scan_chunks(part, "value", 0, part.mark_count, 73)
    values.should eq(expected)
    values[127, 3].should eq([UInt64::MAX, 0_u64, 1_u64])

    expected_range = part.read_uint64_mark_range("value", 1, 2)
    range, _, _ = borrowed_scan_chunks(part, "value", 1, 2, 73)
    range.should eq(expected_range)
    range[0, 3].should eq(expected[BORROWED_DELTA_MARK, 3])
  end

  it "scans only the selected multicolumn input stream" do
    part = CrystalClick::WidePart.open(BORROWED_MULTI_FIXTURE, "input")
    expected = part.read_uint64
    values, _, _ = borrowed_scan_chunks(part, "input", 0, part.mark_count, 113)
    values.should eq(expected)

    range, _, _ = borrowed_scan_chunks(part, "input", 7, 2, 113)
    range.should eq(part.read_uint64_mark_range("input", 7, 2))
    expect_raises(CrystalClick::UnsupportedFormatError) do
      part.scan_uint64_mark_range_into("prefix", 0, 1, Slice(UInt64).new(8)) { |_| }
    end
  end

  it "aliases the caller scratch while copied values remain stable" do
    part = CrystalClick::WidePart.open(FIXTURE)
    scratch = Slice(UInt64).new(257)
    retained : Slice(UInt64)? = nil
    copied = Array(UInt64).new
    first_pointer : Pointer(UInt64)? = nil
    chunk_pointers = Array(Pointer(UInt64)).new

    part.scan_uint64_mark_range_into("value", 0, part.mark_count, scratch) do |chunk|
      chunk_pointers << chunk.to_unsafe
      if retained.nil?
        retained = chunk
        first_pointer = chunk.to_unsafe
        copied.concat(chunk.to_a)
      end
    end

    first = retained.not_nil!
    first_pointer.not_nil!.should eq(scratch.to_unsafe)
    chunk_pointers.all? { |pointer| pointer == scratch.to_unsafe }.should be_true
    first.to_unsafe.should eq(scratch.to_unsafe)
    copied.should eq((0_u64...257_u64).to_a)
    first[0].should_not eq(copied[0])
  end

  it "rejects empty and read-only scratch before mapping or decoding" do
    with_fixture_copy do |path|
      data = Dir.glob(File.join(path, "*.bin")).first.not_nil!
      mutate_fixture_file(path, File.basename(data)) { |bytes| bytes[16] = 0x81_u8 }
      part = CrystalClick::WidePart.open(path)

      expect_raises(CrystalClick::BoundsError) do
        part.scan_uint64_mark_range_into("value", 0, 1, Slice(UInt64).empty) { |_| }
      end
      expect_raises(CrystalClick::BoundsError) do
        part.scan_uint64_mark_range_into("value", 0, 1, Slice(UInt64).new(257, read_only: true)) { |_| }
      end
    end
  end

  it "propagates the callback exception and remains readable afterwards" do
    part = CrystalClick::WidePart.open(FIXTURE)
    callback_error = Exception.new("borrowed callback failed")
    raised = expect_raises(Exception) do
      part.scan_uint64_mark_range_into("value", 0, part.mark_count, Slice(UInt64).new(257)) do |_chunk|
        raise callback_error
      end
    end
    raised.should eq(callback_error)
    part.read_uint64.should eq((0_u64...BORROWED_ROWS.to_u64).to_a)
  end

  it "delivers a valid prefix before a later corrupt frame" do
    with_borrowed_zstd_fixture_copy do |path|
      data = Dir.glob(File.join(path, "*.bin")).first.not_nil!
      mutate_fixture_file(path, File.basename(data)) do |bytes|
        offsets = borrowed_frame_offsets(bytes)
        offsets.size.should be > 2
        bytes[offsets[2] + 16] = 0x81_u8
      end
      part = CrystalClick::WidePart.open(path)
      prefix = Array(UInt64).new

      error = expect_raises(CrystalClick::UnsupportedFormatError) do
        part.scan_uint64_mark_range_into("value", 0, part.mark_count, Slice(UInt64).new(257)) do |chunk|
          prefix.concat(chunk.to_a)
        end
      end
      error.message.not_nil!.should contain("unsupported")
      prefix.empty?.should be_false
      prefix.should eq((0_u64...prefix.size.to_u64).to_a)
    end
  end

  it "preserves owning read parity and all-or-error behavior" do
    part = CrystalClick::WidePart.open(FIXTURE)
    part.read_uint64_mark_range("value", 2, 2).should eq((2048_u64...4096_u64).to_a)
    part.read_uint64.should eq((0_u64...BORROWED_ROWS.to_u64).to_a)

    with_fixture_copy do |path|
      data = Dir.glob(File.join(path, "*.bin")).first.not_nil!
      mutate_fixture_file(path, File.basename(data)) do |bytes|
        offsets = borrowed_frame_offsets(bytes)
        bytes[offsets[2] + 16] = 0x81_u8
      end
      corrupt = CrystalClick::WidePart.open(path)
      expect_raises(CrystalClick::UnsupportedFormatError) { corrupt.read_uint64 }
    end
  end

  it "does not size the owning output from an untrusted huge mark row count" do
    with_fixture_copy do |path|
      mark = Dir.glob(File.join(path, "*.mrk2")).first.not_nil!
      mark_bytes = writable_file_bytes(mark)
      original_rows = borrowed_u64(mark_bytes, 16)
      claimed_rows = 8_388_608_u64
      write_borrowed_u64(mark_bytes, 16, claimed_rows)
      File.open(mark, "wb") { |io| io.write(mark_bytes) }
      File.write(File.join(path, "count.txt"), "#{BORROWED_ROWS.to_u64 - original_rows + claimed_rows}\n")

      part = CrystalClick::WidePart.open(path)
      expect_raises(CrystalClick::CorruptPartError) do
        part.read_uint64_mark_range("value", 0, 1)
      end

      source = File.read(File.expand_path("../src/crystal_click/wide_part.cr", __DIR__))
      source.should_not contain("Array(UInt64).new(expected_bytes")
    end
  end

  it "keeps range validation and the data-path source guard narrow" do
    part = CrystalClick::WidePart.open(FIXTURE)
    expect_raises(CrystalClick::BoundsError) do
      part.scan_uint64_mark_range_into("value", -1, 1, Slice(UInt64).new(8)) { |_| }
    end
    expect_raises(CrystalClick::BoundsError) do
      part.scan_uint64_mark_range_into("value", 0, 0, Slice(UInt64).new(8)) { |_| }
    end
    expect_raises(CrystalClick::BoundsError) do
      part.scan_uint64_mark_range_into("value", part.mark_count, 1, Slice(UInt64).new(8)) { |_| }
    end

    source = File.read(File.expand_path("../src/crystal_click/wide_part.cr", __DIR__))
    source.should_not contain("selected = IO::Memory")
    source.should_not contain("selected.to_slice")
    source.should contain("CompressedBlock.decode_all")
  end
end
