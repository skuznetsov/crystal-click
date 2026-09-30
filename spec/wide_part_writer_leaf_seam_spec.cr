require "./spec_helper"

# The spec-only wrappers keep production leaf owners private while letting
# this seam test exercise them with root and nested physical stream prefixes.
module CrystalClick
  module WidePartWriter
    def self.write_uint64_leaf_for_spec(
      stage : String,
      logical_prefix : String,
      values : Slice(UInt64),
      rows_per_mark : Int32,
    )
      LeafStreamWriter.write_uint64_stream(stage, logical_prefix, values, rows_per_mark).map do |record|
        {
          name:              record.name,
          physical_size:     record.physical_size,
          file_hash:         record.file_hash,
          compressed:        record.compressed,
          uncompressed_size: record.uncompressed_size,
          uncompressed_hash: record.uncompressed_hash,
        }
      end
    end

    def self.write_string_leaf_for_spec(
      stage : String,
      logical_prefix : String,
      values : Slice(T),
      rows_per_mark : Int32,
    ) forall T
      LeafStreamWriter.write_string_streams(stage, logical_prefix, values, rows_per_mark).map do |record|
        {
          name:              record.name,
          physical_size:     record.physical_size,
          file_hash:         record.file_hash,
          compressed:        record.compressed,
          uncompressed_size: record.uncompressed_size,
          uncompressed_hash: record.uncompressed_hash,
        }
      end
    end
  end
end

private def leaf_seam_uint64_bytes(values : Array(UInt64)) : Array(UInt8)
  bytes = Array(UInt8).new(values.size * 8, 0_u8)
  values.each_with_index do |value, index|
    8.times do |offset|
      bytes[index * 8 + offset] = ((value >> (offset * 8)) & 0xff_u64).to_u8
    end
  end
  bytes
end

private def leaf_seam_read_uint32(bytes : Bytes, offset : Int) : UInt32
  value = 0_u32
  4.times { |index| value |= bytes[offset + index].to_u32 << (index * 8) }
  value
end

private def leaf_seam_read_uint64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

private def leaf_seam_frame_size(bytes : Bytes, offset : UInt64) : UInt64
  header_offset = offset.to_i
  compressed_size = leaf_seam_read_uint32(
    bytes,
    header_offset + CrystalClick::CompressedBlock::CHECKSUM_SIZE + 1
  )
  (CrystalClick::CompressedBlock::CHECKSUM_SIZE.to_u64 + compressed_size.to_u64)
end

private def leaf_seam_expected_mark_offsets(data : Bytes, emits_frame : Array(Bool)) : Array(UInt64)
  offsets = [0_u64]
  current = 0_u64
  emits_frame.each do |emits|
    current += leaf_seam_frame_size(data, current) if emits
    offsets << current
  end
  offsets
end

private def leaf_seam_marks(stage : String, logical_name : String) : Array(Tuple(UInt64, UInt64, UInt64))
  path = File.join(stage, "#{CrystalClick::StreamName.hash(logical_name)}.mrk2")
  bytes = File.read(path).to_slice
  raise "misaligned test mark file" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0

  marks = [] of Tuple(UInt64, UInt64, UInt64)
  offset = 0
  while offset < bytes.size
    marks << {
      leaf_seam_read_uint64(bytes, offset),
      leaf_seam_read_uint64(bytes, offset + 8),
      leaf_seam_read_uint64(bytes, offset + 16),
    }
    offset += CrystalClick::WidePart::MARK_SIZE
  end
  marks
end

private def leaf_seam_assert_checksums(
  stage : String,
  records : Array(NamedTuple(
    name: String,
    physical_size: UInt64,
    file_hash: Tuple(UInt64, UInt64),
    compressed: Bool,
    uncompressed_size: UInt64?,
    uncompressed_hash: Tuple(UInt64, UInt64)?,
  )),
  expected_raw : Hash(String, Array(UInt8)),
) : Nil
  records.each do |record|
    physical = File.read(File.join(stage, record[:name])).to_slice
    record[:physical_size].should eq(physical.size.to_u64)
    record[:file_hash].should eq(CrystalClick::CityHashV1.file_hash(physical))

    if record[:compressed]
      raw = expected_raw[record[:name]]
      raw_slice = raw.to_unsafe.to_slice(raw.size)
      record[:uncompressed_size].should eq(raw.size.to_u64)
      record[:uncompressed_hash].should eq(CrystalClick::CityHashV1.file_hash(raw_slice))
    else
      record[:uncompressed_size].should be_nil
      record[:uncompressed_hash].should be_nil
    end
  end
end

describe CrystalClick::WidePartWriter do
  it "keeps UInt64 payload bytes, marks, and checksums for root and escaped prefixes" do
    parent = File.tempname("crystal-click-leaf-u64-seam")
    Dir.mkdir(parent)
    root_stage = File.join(parent, "root")
    child_stage = File.join(parent, "child")
    Dir.mkdir(root_stage)
    Dir.mkdir(child_stage)

    values = [0_u64, 0x0102_0304_0506_0708_u64, 17_u64, UInt64::MAX, 42_u64]
    root_prefix = "root_value"
    child_prefix = "payload%2Ea.nested%2Eb"
    root_data_name = "#{CrystalClick::StreamName.hash(root_prefix)}.bin"
    child_data_name = "#{CrystalClick::StreamName.hash(child_prefix)}.bin"
    expected = leaf_seam_uint64_bytes(values)
    expected_raw = {} of String => Array(UInt8)

    begin
      root_records = CrystalClick::WidePartWriter.write_uint64_leaf_for_spec(
        root_stage,
        root_prefix,
        values.to_unsafe.to_slice(values.size),
        2
      )
      child_records = CrystalClick::WidePartWriter.write_uint64_leaf_for_spec(
        child_stage,
        child_prefix,
        values.to_unsafe.to_slice(values.size),
        2
      )

      [
        {root_stage, root_prefix, root_records},
        {child_stage, child_prefix, child_records},
      ].each do |stage, prefix, records|
        data_name = "#{CrystalClick::StreamName.hash(prefix)}.bin"
        marks_name = "#{CrystalClick::StreamName.hash(prefix)}.mrk2"
        expected_raw[data_name] = expected
        File.exists?(File.join(stage, data_name)).should be_true
        File.exists?(File.join(stage, marks_name)).should be_true
        CrystalClick::CompressedBlock.decode_all(File.read(File.join(stage, data_name)).to_slice).to_a.should eq(expected)

        marks = leaf_seam_marks(stage, prefix)
        marks.map(&.[2]).should eq([2_u64, 2_u64, 1_u64, 0_u64])
        data = File.read(File.join(stage, data_name)).to_slice
        marks.map(&.[0]).should eq(leaf_seam_expected_mark_offsets(data, [true, true, true]))
        marks.each { |mark| mark[1].should eq(0_u64) }
        records.map { |record| record[:name] }.sort.should eq([data_name, marks_name].sort)
        leaf_seam_assert_checksums(stage, records, expected_raw)
      end

      File.read(File.join(root_stage, root_data_name)).should eq(File.read(File.join(child_stage, child_data_name)))
      File.read(File.join(root_stage, "#{CrystalClick::StreamName.hash(root_prefix)}.mrk2")).should eq(
        File.read(File.join(child_stage, "#{CrystalClick::StreamName.hash(child_prefix)}.mrk2"))
      )

      wrong_unescaped = CrystalClick::StreamName.hash("payload.a.nested.b")
      File.exists?(File.join(child_stage, "#{wrong_unescaped}.bin")).should be_false
      File.exists?(File.join(child_stage, "#{wrong_unescaped}.mrk2")).should be_false
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps String size and payload streams for root, escaped, and arbitrary prefixes" do
    parent = File.tempname("crystal-click-leaf-string-seam")
    Dir.mkdir(parent)
    stages = ["root", "escaped", "arbitrary"].map do |name|
      stage = File.join(parent, name)
      Dir.mkdir(stage)
      stage
    end
    prefixes = ["description", "payload%2Eb", "outer%2Einner%2Eleaf"]
    values = ["", "", "a\0b", String.new(Bytes[0xff_u8, 0_u8]), "é"]
    expected_sizes = leaf_seam_uint64_bytes(values.map { |value| value.bytesize.to_u64 })
    expected_payload = values.flat_map { |value| value.to_slice.to_a }

    begin
      prefixes.each_with_index do |prefix, index|
        stage = stages[index]
        records = CrystalClick::WidePartWriter.write_string_leaf_for_spec(
          stage,
          prefix,
          values.to_unsafe.to_slice(values.size),
          2
        )
        size_name = "#{CrystalClick::StreamName.hash("#{prefix}.size")}.bin"
        size_marks_name = "#{CrystalClick::StreamName.hash("#{prefix}.size")}.mrk2"
        value_name = "#{CrystalClick::StreamName.hash(prefix)}.bin"
        value_marks_name = "#{CrystalClick::StreamName.hash(prefix)}.mrk2"
        expected_raw = {
          size_name  => expected_sizes,
          value_name => expected_payload,
        }

        CrystalClick::CompressedBlock.decode_all(File.read(File.join(stage, size_name)).to_slice).to_a.should eq(expected_sizes)
        CrystalClick::CompressedBlock.decode_all(File.read(File.join(stage, value_name)).to_slice).to_a.should eq(expected_payload)
        records.map { |record| record[:name] }.sort.should eq([size_name, size_marks_name, value_name, value_marks_name].sort)
        leaf_seam_assert_checksums(stage, records, expected_raw)

        size_marks = leaf_seam_marks(stage, "#{prefix}.size")
        size_data = File.read(File.join(stage, size_name)).to_slice
        size_marks.map(&.[2]).should eq([2_u64, 2_u64, 1_u64, 0_u64])
        size_marks.map(&.[0]).should eq(leaf_seam_expected_mark_offsets(size_data, [true, true, true]))
        size_marks.each { |mark| mark[1].should eq(0_u64) }

        value_marks = leaf_seam_marks(stage, prefix)
        value_data = File.read(File.join(stage, value_name)).to_slice
        value_marks.map(&.[2]).should eq([2_u64, 2_u64, 1_u64, 0_u64])
        value_marks.map(&.[0]).should eq(leaf_seam_expected_mark_offsets(value_data, [false, true, true]))
        value_marks.each { |mark| mark[1].should eq(0_u64) }
      end

      escaped_wrong = CrystalClick::StreamName.hash("payload.b")
      File.exists?(File.join(stages[1], "#{escaped_wrong}.bin")).should be_false
      File.exists?(File.join(stages[1], "#{escaped_wrong}.mrk2")).should be_false
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "preserves all-empty String data marks and zero-byte checksum metadata" do
    parent = File.tempname("crystal-click-leaf-string-empty")
    Dir.mkdir(parent)
    stage = File.join(parent, "stage")
    Dir.mkdir(stage)
    prefix = "tuple%2Ec"
    values = ["", "", ""]
    size_name = "#{CrystalClick::StreamName.hash("#{prefix}.size")}.bin"
    data_name = "#{CrystalClick::StreamName.hash(prefix)}.bin"
    expected_raw = {
      size_name => leaf_seam_uint64_bytes([0_u64, 0_u64, 0_u64]),
      data_name => [] of UInt8,
    }

    begin
      records = CrystalClick::WidePartWriter.write_string_leaf_for_spec(
        stage,
        prefix,
        values.to_unsafe.to_slice(values.size),
        2
      )
      data_path = File.join(stage, data_name)
      File.size(data_path).should eq(0)
      marks = leaf_seam_marks(stage, prefix)
      marks.map(&.[0]).should eq([0_u64, 0_u64, 0_u64])
      marks.map(&.[2]).should eq([2_u64, 1_u64, 0_u64])

      data_record = records.find { |record| record[:name] == data_name }.not_nil!
      data_record[:compressed].should be_true
      data_record[:physical_size].should eq(0_u64)
      data_record[:uncompressed_size].should eq(0_u64)
      data_record[:uncompressed_hash].should eq(CrystalClick::CityHashV1.file_hash(Bytes.new(0)))
      leaf_seam_assert_checksums(stage, records, expected_raw)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "preserves String leaf type and per-mark decompressed-size guards" do
    parent = File.tempname("crystal-click-leaf-string-limits")
    Dir.mkdir(parent)
    wrong_type_stage = File.join(parent, "wrong_type")
    Dir.mkdir(wrong_type_stage)
    oversized_stage = File.join(parent, "oversized")
    Dir.mkdir(oversized_stage)
    oversized = String.new(Bytes.new(CrystalClick::WidePart::MAX_FRAME_DECOMPRESSED_BYTES + 1, 0_u8))

    begin
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.write_string_leaf_for_spec(
          wrong_type_stage,
          "wrong_type",
          [1_u64].to_unsafe.to_slice(1),
          1
        )
      end

      error = expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_string_leaf_for_spec(
          oversized_stage,
          "oversized",
          [oversized].to_unsafe.to_slice(1),
          1
        )
      end
      error.message.should eq("String payload granule exceeds decompressed frame limit")
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
