require "./spec_helper"

REAL_READER_ZSTD_FIXTURE  = File.expand_path("../test/fixtures/public/wide_u64_zstd_cmrk2/part", __DIR__)
REAL_READER_DELTA_FIXTURE = File.expand_path("../test/fixtures/public/wide_u64_delta_zstd/part", __DIR__)
REAL_READER_MULTI_FIXTURE = File.expand_path("../test/fixtures/public/wide_multi_input_delta_zstd/part", __DIR__)
REAL_READER_ROWS          = 200_000
REAL_READER_MARK_ROWS     =   1_024
REAL_READER_DELTA_ROWS    =   4_096
REAL_READER_DELTA_MARK    =     256
REAL_READER_MULTI_ROWS    =   4_096
REAL_READER_MULTI_MARK    =     256

def real_reader_u32(bytes : Bytes, offset : Int) : UInt32
  bytes[offset].to_u32 |
    (bytes[offset + 1].to_u32 << 8) |
    (bytes[offset + 2].to_u32 << 16) |
    (bytes[offset + 3].to_u32 << 24)
end

def real_reader_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

def real_reader_write_u64(bytes : Bytes, offset : Int, value : UInt64)
  8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

def real_reader_frame_offsets(bytes : Bytes) : Array(Int32)
  offsets = Array(Int32).new
  offset = 0
  while offset < bytes.size
    raise "truncated test frame header" if bytes.size - offset < 25
    offsets << offset
    compressed_size = real_reader_u32(bytes, offset + 17).to_i
    offset += 16 + compressed_size
  end
  raise "trailing test frame bytes" unless offset == bytes.size
  offsets
end

def with_real_reader_zstd_fixture_copy(&)
  path = File.tempname("crystal-click-real-reader-zstd-spec")
  FileUtils.cp_r(REAL_READER_ZSTD_FIXTURE, path)
  begin
    yield path
  ensure
    FileUtils.rm_rf(path)
  end
end

def real_reader_delta_values : Array(UInt64)
  values = Array(UInt64).new(REAL_READER_DELTA_ROWS)
  REAL_READER_DELTA_ROWS.times do |number|
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

def real_reader_multi_values : Array(UInt64)
  values = Array(UInt64).new(REAL_READER_MULTI_ROWS, 0_u64)
  REAL_READER_MULTI_ROWS.times do |number|
    values[number] = case number
                     when 1
                       UInt64::MAX
                     when 2
                       0_u64
                     when 3
                       1_u64
                     when 2047
                       UInt64::MAX
                     when 2048
                       0_u64
                     else
                       number % 23 == 0 ? 42_u64 : ((number * 17) % 100_000).to_u64
                     end
  end
  values
end

describe "WidePart UInt64 slab reader" do
  it "matches the LZ4 Array reader across exact and partial default slabs" do
    part = CrystalClick::WidePart.open(FIXTURE)
    expected = part.read_uint64

    full = part.read_uint64_slab
    full.to_a.should eq(expected)
    full.size.should eq(expected.size)
    full.slab_size.should eq(1 << CrystalClick::UInt64SlabVector::DEFAULT_SLAB_SHIFT)
    full.slab_count.should eq((expected.size + full.slab_size - 1) // full.slab_size)
    full.capacity.should eq(full.slab_count * full.slab_size)

    exact = part.read_uint64_mark_range_slab("value", 2, 4)
    exact.to_a.should eq(expected[2 * REAL_READER_MARK_ROWS, 4 * REAL_READER_MARK_ROWS])
    exact.size.should eq(exact.slab_size)
    exact.slab_count.should eq(1)

    partial = part.read_uint64_mark_range_slab("value", 1, 5)
    partial.to_a.should eq(expected[REAL_READER_MARK_ROWS, 5 * REAL_READER_MARK_ROWS])
    partial.size.should eq(5 * REAL_READER_MARK_ROWS)
    partial.slab_count.should eq(2)
    partial.capacity.should eq(2 * partial.slab_size)
  end

  it "matches the ZSTD compressed-mark Array reader for full and bounded reads" do
    part = CrystalClick::WidePart.open(REAL_READER_ZSTD_FIXTURE)
    expected = part.read_uint64

    part.read_uint64_slab.to_a.should eq(expected)

    range = part.read_uint64_mark_range_slab("value", 5, 3, slab_shift: 8)
    range.to_a.should eq(part.read_uint64_mark_range("value", 5, 3))
    range.size.should eq(3 * REAL_READER_MARK_ROWS)
    range.slab_size.should eq(1 << 8)
    range.slab_count.should eq(3 * REAL_READER_MARK_ROWS // range.slab_size)
    range.capacity.should eq(range.size)
  end

  it "matches Delta/ZSTD values and ranges, including UInt64 wraparound" do
    part = CrystalClick::WidePart.open(REAL_READER_DELTA_FIXTURE)
    expected = real_reader_delta_values

    full = part.read_uint64_slab(slab_shift: 8)
    full.to_a.should eq(expected)
    full.slab_size.should eq(256)
    full.slab_count.should eq(16)
    full.capacity.should eq(REAL_READER_DELTA_ROWS)
    expected[127, 3].should eq([UInt64::MAX, 0_u64, 1_u64])
    expected[255, 3].should eq([UInt64::MAX, 0_u64, 5_u64])

    range = part.read_uint64_mark_range_slab("value", 4, 1, slab_shift: 8)
    range.to_a.should eq(expected[4 * REAL_READER_DELTA_MARK, REAL_READER_DELTA_MARK])
    range.slab_count.should eq(1)
    range.capacity.should eq(range.slab_size)

    final = part.read_uint64_mark_range_slab("value", 14, 2, slab_shift: 8)
    final.to_a.should eq(part.read_uint64_mark_range("value", 14, 2))
    final.slab_count.should eq(2)
  end

  it "reads only the selected multicolumn input stream and preserves Array parity" do
    part = CrystalClick::WidePart.open(REAL_READER_MULTI_FIXTURE, "input")
    expected = real_reader_multi_values

    full = part.read_uint64_slab
    full.to_a.should eq(expected)
    full.to_a.should eq(part.read_uint64)

    range = part.read_uint64_mark_range_slab("input", 7, 2, slab_shift: 8)
    range.to_a.should eq(expected[7 * REAL_READER_MULTI_MARK, 2 * REAL_READER_MULTI_MARK])
    range.to_a.should eq(part.read_uint64_mark_range("input", 7, 2))
    range.slab_count.should eq(2)

    expect_raises(CrystalClick::UnsupportedFormatError) do
      part.read_uint64_slab("prefix")
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      part.read_uint64_mark_range_slab("prefix", 0, 1)
    end
  end

  it "rejects invalid slab shifts, columns, and mark ranges" do
    part = CrystalClick::WidePart.open(FIXTURE)

    expect_raises(ArgumentError) { part.read_uint64_slab(slab_shift: 3) }
    expect_raises(ArgumentError) { part.read_uint64_mark_range_slab("value", 0, 1, slab_shift: 21) }
    expect_raises(CrystalClick::UnsupportedFormatError) { part.read_uint64_slab("missing") }
    expect_raises(CrystalClick::UnsupportedFormatError) { part.read_uint64_mark_range_slab("missing", 0, 1) }
    expect_raises(CrystalClick::BoundsError) { part.read_uint64_mark_range_slab("value", -1, 1) }
    expect_raises(CrystalClick::BoundsError) { part.read_uint64_mark_range_slab("value", 0, 0) }
    expect_raises(CrystalClick::BoundsError) { part.read_uint64_mark_range_slab("value", part.mark_count, 1) }
    expect_raises(CrystalClick::BoundsError) { part.read_uint64_mark_range_slab("value", 0, part.mark_count + 1) }
  end

  it "retains owned slabs and read-only chunks after garbage collection" do
    part = CrystalClick::WidePart.open(FIXTURE)
    expected = part.read_uint64_mark_range("value", 1, 5)
    vector = part.read_uint64_mark_range_slab("value", 1, 5, slab_shift: 8)

    GC.collect
    vector.to_a.should eq(expected)

    chunks = Array(Array(UInt64)).new
    chunk_sizes = Array(Int32).new
    vector.each_chunk do |chunk|
      chunk.read_only?.should be_true
      chunk.size.should be > 0
      chunk_sizes << chunk.size
      chunks << chunk.to_a
    end
    chunk_sizes.should eq([256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256, 256])
    chunks.flatten.should eq(expected)
  end

  it "keeps the slab and Array readers all-or-error on a later corrupt frame" do
    with_real_reader_zstd_fixture_copy do |path|
      data = Dir.glob(File.join(path, "*.bin")).first.not_nil!
      mutate_fixture_file(path, File.basename(data)) do |bytes|
        offsets = real_reader_frame_offsets(bytes)
        offsets.size.should be > 2
        bytes[offsets[2] + 16] = 0x81_u8
      end

      part = CrystalClick::WidePart.open(path)
      expect_raises(CrystalClick::UnsupportedFormatError) { part.read_uint64_slab }
      expect_raises(CrystalClick::UnsupportedFormatError) do
        part.read_uint64_mark_range_slab("value", 0, part.mark_count)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) { part.read_uint64 }
    end
  end

  it "rejects a huge claimed mark row count without claimed-size slab allocation" do
    with_fixture_copy do |path|
      mark = Dir.glob(File.join(path, "*.mrk2")).first.not_nil!
      mark_bytes = writable_file_bytes(mark)
      original_rows = real_reader_u64(mark_bytes, 16)
      claimed_rows = 8_388_608_u64
      real_reader_write_u64(mark_bytes, 16, claimed_rows)
      File.open(mark, "wb") { |io| io.write(mark_bytes) }
      File.write(File.join(path, "count.txt"), "#{REAL_READER_ROWS.to_u64 - original_rows + claimed_rows}\n")

      part = CrystalClick::WidePart.open(path)
      expect_raises(CrystalClick::CorruptPartError) { part.read_uint64_slab(slab_shift: 4) }
      expect_raises(CrystalClick::CorruptPartError) do
        part.read_uint64_mark_range_slab("value", 0, 1, slab_shift: 4)
      end

      source = File.read(File.expand_path("../src/crystal_click/wide_part.cr", __DIR__))
      source.should_not contain("UInt64SlabVector.new(expected_bytes")
      source.should_not contain("UInt64SlabVector.new(expected_rows")
    end
  end

  it "uses byte chunks instead of scalar pushes in the slab reader" do
    source = File.read(File.expand_path("../src/crystal_click/wide_part.cr", __DIR__))
    slab_start = source.index("def read_uint64_mark_range_slab").not_nil!
    slab_end = source.index("def scan_uint64_mark_range_into", slab_start).not_nil!
    slab_reader = source[slab_start, slab_end - slab_start]

    slab_reader.should contain("concat_le_bytes")
    slab_reader.should_not contain("values << value")
  end
end
