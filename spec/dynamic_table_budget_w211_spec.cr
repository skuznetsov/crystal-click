require "./spec_helper"
require "file_utils"

W211_DYNAMIC_STRING_BYTES = 32 * 1024 * 1024

private def w211_write_dynamic_string_part(
  destination : String,
  value_name : String,
  dynamic : CrystalClick::BinaryDataType,
  structures : Hash(String, CrystalClick::DynamicStructure),
  value : CrystalClick::BinaryValue,
) : Nil
  CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
    destination,
    "pk",
    Slice[7_u64],
    value_name,
    dynamic,
    structures,
    [[value] of CrystalClick::BinaryValue],
    rows_per_mark: 1,
    frame_bytes: 16 * 1024 * 1024,
  ).should eq(destination)
end

private def w211_merge_dynamic_string_parts(
  left_part : String,
  right_part : String,
  merged_part : String,
  left_name : String,
  right_name : String,
  dynamic : CrystalClick::BinaryDataType,
) : Nil
  left_reader = CrystalClick::DynamicBulkColumnReader.open(left_part, left_name, dynamic)
  right_reader = CrystalClick::DynamicBulkColumnReader.open(right_part, right_name, dynamic)
  left_streams = left_reader.physical_stream_names
  right_streams = right_reader.physical_stream_names
  combined_streams = left_streams + right_streams
  combined_streams.uniq.size.should eq(combined_streams.size)

  FileUtils.cp_r(left_part, merged_part)
  right_checksums = right_reader.selected_checksum_names
  left_checksums = left_reader.selected_checksum_names
  right_checksums.each do |name|
    raise CrystalClick::CorruptPartError.new("independent Dynamic parts share a physical checksum name") if left_checksums.includes?(name)
    FileUtils.cp(File.join(right_part, name), File.join(merged_part, name))
  end

  File.write(
    File.join(merged_part, "columns.txt"),
    "columns format version: 1\n3 columns:\n`pk` UInt64\n`#{left_name}` #{left_reader.schema_declaration}\n`#{right_name}` #{right_reader.schema_declaration}\n"
  )
  File.write(File.join(merged_part, "columns_substreams.txt"), String.build do |io|
    io << "columns substreams version: 1\n3 columns:\n"
    io << "1 substreams for column `pk`:\n\tpk\n"
    [{left_name, left_streams}, {right_name, right_streams}].each do |column|
      name, streams = column
      io << streams.size << " substreams for column `" << name << "`:\n"
      streams.each { |stream| io << '\t' << stream << '\n' }
    end
  end)

  CrystalClick::WidePartWriter.w211_rewrite_merged_checksums(
    merged_part,
    left_part,
    right_part,
    right_checksums,
  )
end

module CrystalClick::WidePartWriter
  # The public checksum view intentionally omits uncompressed hashes. Rebuild
  # the exact union from the two writer-authored rosters and hash each copied
  # compressed stream's decoded bytes, preserving the v4 checksum envelope.
  def self.w211_rewrite_merged_checksums(
    merged_part : String,
    left_part : String,
    right_part : String,
    right_stream_names : Array(String),
  ) : Nil
    left = PartChecksums.open(left_part)
    right = PartChecksums.open(right_part)
    selected = left.entries.keys
    right_stream_names.each do |name|
      if left.entries.has_key?(name)
        raise CorruptPartError.new("merged Dynamic checksum rosters collide")
      end
      raise CorruptPartError.new("right Dynamic checksum entry is absent") unless right.entries.has_key?(name)
      selected << name
    end

    records = [] of ChecksumRecord
    selected.sort!.each do |name|
      entry = left.entry(name)
      unless entry
        entry = right.entry(name)
      end
      checksum = entry || raise(CorruptPartError.new("merged checksum entry has no source"))
      content = File.read(File.join(merged_part, name))
      bytes = content.to_slice
      unless bytes.size.to_u64 == checksum.physical_size
        raise CorruptPartError.new("merged Dynamic stream size differs from its source checksum")
      end

      if checksum.compressed
        raw_size = checksum.uncompressed_size || raise(CorruptPartError.new("compressed source checksum has no raw size"))
        raw = if bytes.empty?
                Bytes.new(0)
              else
                CompressedBlock.decode_all(
                  bytes,
                  PartChecksums::MAX_FRAME_COMPRESSED_BYTES,
                  PartChecksums::MAX_FRAME_DECOMPRESSED_BYTES,
                  PartChecksums::MAX_PAYLOAD_BYTES,
                )
              end
        unless raw.size.to_u64 == raw_size
          raise CorruptPartError.new("merged Dynamic stream raw size differs from its source checksum")
        end
        records << ChecksumRecord.new(
          name,
          bytes.size.to_u64,
          CityHashV1.file_hash(bytes),
          true,
          raw_size,
          CityHashV1.file_hash(raw),
        )
      else
        records << ChecksumRecord.new(name, bytes.size.to_u64, CityHashV1.file_hash(bytes), false)
      end
    end
    write_checksums(merged_part, records)
  end
end

describe "W211 Dynamic table cumulative logical-owner budget" do
  it "admits either 32 MiB Dynamic column alone but rejects their combined mark before callback" do
    parent = File.tempname("crystal-click-w211-dynamic-budget-")
    Dir.mkdir(parent)
    begin
      left_part = File.join(parent, "left_1_1_0")
      right_part = File.join(parent, "right_1_1_0")
      merged_part = File.join(parent, "all_1_1_0")

      dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
      structures = {
        "root" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType),
      }
      payload = String.new(Bytes.new(W211_DYNAMIC_STRING_BYTES, 'x'.ord.to_u8))
      string_value = CrystalClick::BinaryValue.string(payload)
      dynamic_value = CrystalClick::BinaryValue.dynamic(dynamic, string_value)

      w211_write_dynamic_string_part(left_part, "left", dynamic, structures, dynamic_value)
      w211_write_dynamic_string_part(right_part, "right", dynamic, structures, dynamic_value)
      w211_merge_dynamic_string_parts(left_part, right_part, merged_part, "left", "right", dynamic)

      {"left", "right"}.each do |column|
        table = CrystalClick::WidePartTable.open_selected_typed([merged_part], ["pk", column])
        callbacks = 0
        table.scan_typed do |batch|
          callbacks += 1
          batch.values_for("pk", UInt64).should eq(Slice[7_u64])
          values = batch.dynamic_bulk_values_for(column)
          values.size.should eq(1)
          value = values[0]
          value.is_null?.should be_false
          value.type.tag.should eq(CrystalClick::BinaryDataType::TAG_DYNAMIC)
          actual = value.child_at(0)
          actual.type.tag.should eq(CrystalClick::BinaryDataType::TAG_STRING)
          actual.byte_size.should eq(W211_DYNAMIC_STRING_BYTES)
          actual.byte_at(0).should eq('x'.ord.to_u8)
          actual.byte_at(actual.byte_size - 1).should eq('x'.ord.to_u8)
        end
        callbacks.should eq(1)
      end

      table = CrystalClick::WidePartTable.open_selected_typed([merged_part], ["pk", "left", "right"])
      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_typed do |_batch|
          callbacks += 1
        end
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
