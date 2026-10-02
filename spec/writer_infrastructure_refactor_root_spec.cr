require "./spec_helper"

# Test-only entry points keep the same private facade seam before/after the
# extraction. Literal expectations do not use the checksum reader/writer.
module CrystalClick::WidePartWriter
  def self.refactor_root_write_checksums(stage : String) : Nil
    records = [
      ChecksumRecord.new("z.bin", 3_u64, {4_u64, 5_u64}, true, 2_u64, {6_u64, 7_u64}),
      ChecksumRecord.new("a.txt", 1_u64, {2_u64, 3_u64}, false),
    ]
    write_checksums(stage, records)
    records.map(&.name).should eq(["z.bin", "a.txt"])
  end

  def self.refactor_root_create_stage(parent : String) : String
    create_stage(parent)
  end

  def self.refactor_root_write_multibyte_checksums(stage : String) : Nil
    records = [ChecksumRecord.new("x", 128_u64, {0_u64, 0_u64}, true, UInt64::MAX, {0_u64, 0_u64})]
    write_checksums(stage, records)
  end

  def self.refactor_root_publish(stage : String, target : String) : Nil
    publish_exclusively(stage, target)
  end
end

def with_writer_refactor_root(&)
  parent = File.tempname("crystal-click-writer-refactor-root-")
  Dir.mkdir(parent)
  begin
    yield parent
  ensure
    FileUtils.rm_rf(parent)
  end
end

describe "shared writer infrastructure contract" do
  it "retains sorted checksum wire bytes without mutating the input record order" do
    with_writer_refactor_root do |parent|
      CrystalClick::WidePartWriter.refactor_root_write_checksums(parent)
      bytes = writable_file_bytes(File.join(parent, "checksums.txt"))
      header = "checksums format version: 4\n".to_slice
      bytes[0, header.size].should eq(header)
      payload = CrystalClick::CompressedBlock.decode_all(bytes[header.size, bytes.size - header.size])
      payload.should eq(Bytes[
        2, 5, 97, 46, 116, 120, 116, 1,
        2, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0,
        5, 122, 46, 98, 105, 110, 3,
        4, 0, 0, 0, 0, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0, 1, 2,
        6, 0, 0, 0, 0, 0, 0, 0, 7, 0, 0, 0, 0, 0, 0, 0,
      ])
    end
  end

  it "retains multi-byte and maximum UInt64 VarUInt fields in the checksum envelope" do
    with_writer_refactor_root do |parent|
      CrystalClick::WidePartWriter.refactor_root_write_multibyte_checksums(parent)
      bytes = writable_file_bytes(File.join(parent, "checksums.txt"))
      header = "checksums format version: 4\n".to_slice
      bytes[0, header.size].should eq(header)
      payload = CrystalClick::CompressedBlock.decode_all(bytes[header.size, bytes.size - header.size])
      payload.should eq(Bytes[
        1, 1, 120, 128, 1,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        1, 255, 255, 255, 255, 255, 255, 255, 255, 255, 1,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      ])
    end
  end

  it "keeps shared index EOF and plain metadata bytes through the public writer" do
    with_writer_refactor_root do |parent|
      keys = [1_u64, 2_u64, 2_u64, 9_u64, UInt64::MAX]
      values = ["", "a\0b", "é", "tail", ""]
      part = File.join(parent, "part")
      CrystalClick::WidePartWriter.write_uint64_string_pair(part, "pk", keys.to_unsafe.to_slice(keys.size), "value", values.to_unsafe.to_slice(values.size), rows_per_mark: 2)
      writable_file_bytes(File.join(part, "primary.idx")).should eq(Bytes[
        1, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0,
        255, 255, 255, 255, 255, 255, 255, 255,
        255, 255, 255, 255, 255, 255, 255, 255,
      ])
      File.read(File.join(part, "count.txt")).should eq("5")
      File.read(File.join(part, "default_compression_codec.txt")).should eq("CODEC(LZ4)")
      File.read(File.join(part, "metadata_version.txt")).should eq("0")
      File.read(File.join(part, "columns.txt")).should eq("columns format version: 1\n2 columns:\n`pk` UInt64\n`value` String\n")
      Dir.children(parent).should eq(["part"])
    end
  end

  it "allocates distinct same-parent stages and preserves the stage prefix" do
    with_writer_refactor_root do |parent|
      first = CrystalClick::WidePartWriter.refactor_root_create_stage(parent)
      second = CrystalClick::WidePartWriter.refactor_root_create_stage(parent)
      first.should_not eq(second)
      {first, second}.each do |stage|
        File.dirname(stage).should eq(parent)
        File.basename(stage).should start_with(".crystal-click-wide-writer-")
        Dir.exists?(stage).should be_true
      end
    end
  end

  it "does not replace a target created after stage allocation" do
    with_writer_refactor_root do |parent|
      stage = CrystalClick::WidePartWriter.refactor_root_create_stage(parent)
      File.write(File.join(stage, "candidate.txt"), "candidate")
      target = File.join(parent, "part")
      Dir.mkdir(target)
      File.write(File.join(target, "keep.txt"), "preserve")
      {% if flag?(:darwin) %}
        expect_raises(ArgumentError, "destination already exists") do
          CrystalClick::WidePartWriter.refactor_root_publish(stage, target)
        end
      {% else %}
        expect_raises(CrystalClick::UnsupportedFormatError, "atomic exclusive Wide-part publication is unsupported on this platform") do
          CrystalClick::WidePartWriter.refactor_root_publish(stage, target)
        end
      {% end %}
      File.read(File.join(target, "keep.txt")).should eq("preserve")
      File.read(File.join(stage, "candidate.txt")).should eq("candidate")
    end
  end

  it "rejects a dangling destination symlink before staging" do
    with_writer_refactor_root do |parent|
      target = File.join(parent, "part")
      File.symlink(File.join(parent, "missing"), target)
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_pair(target, "pk", Slice[1_u64], "value", Slice[2_u64], rows_per_mark: 1)
      end
      File.symlink?(target).should be_true
      Dir.children(parent).should eq(["part"])
    end
  end
end
