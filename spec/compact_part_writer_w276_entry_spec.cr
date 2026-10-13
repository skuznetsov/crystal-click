require "./spec_helper"
require "file_utils"
require "json"
require "./support/compact_part_writer_w276_fixture"

describe "W276 propagated String1 Compact writer entry" do
  [CrystalClick::CompactMarkFormat::Mrk3, CrystalClick::CompactMarkFormat::Mrk4].each do |mark_format|
    it "writes recursive String1 callbacks and reads them back in #{mark_format}" do
      fixture = CompactPartWriterW276Fixture
      parent = File.tempname("crystal-click-w276-entry-")
      part_path = File.join(parent, "all_1_1_0")
      Dir.mkdir(parent)

      begin
        CrystalClick::CompactPartWriter.write_uint64_columns(
          part_path,
          CompactPartWriterW276Fixture::KEY_NAME,
          fixture.keys,
          fixture.columns,
          rows_per_mark: CompactPartWriterW276Fixture::ROWS_PER_MARK,
          frame_bytes: CompactPartWriterW276Fixture::FRAME_BYTES,
          mark_format: mark_format,
          profile: CrystalClick::BinaryBulkProfile.with_size_stream,
        ).should eq(part_path)

        serialization = JSON.parse(File.read(File.join(part_path, "serialization.json")))
        serialization.as_h["version"].as_i.should eq(1)
        serialization.as_h["propagate_types_serialization_versions_to_nested_types"].as_bool.should be_true
        serialization.as_h["types_serialization_versions"].as_h["string"].as_i.should eq(1)
        File.read(File.join(part_path, "metadata_version.txt")).should eq("0")

        physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
        physical.mode.should eq(mark_format)
        physical.row_count.should eq(CompactPartWriterW276Fixture::ROW_COUNT.to_u64)
        physical.granule_count.should eq(4)

        CompactPartWriterW276Fixture::COLUMN_NAMES.each do |column_name|
          reader = CrystalClick::CompactBinaryBulkColumnReader.open(
            part_path,
            column_name,
            fixture.types[column_name],
          )
          reader.mark_count.should eq(4)
          reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
          expected = fixture.expected_signatures(column_name)
          fixture.signatures_from(reader.read_marks(0, 4)).should eq(expected)
          fixture.signatures_from(reader.read_marks(1, 2)).should eq(expected[2, 4])
          fixture.signatures_from(reader.read_marks(4, 0)).should be_empty
        end

        if mark_format.mrk4?
          physical.physical_roster.select { |slot| slot.column_name == "text" }
            .map { |slot| slot.stream_name || "" }.should eq(["text.size", "text"])
          physical.physical_roster.select { |slot| slot.column_name == "string_array" }
            .map { |slot| slot.stream_name || "" }.should eq(
            [
              "string_array%2Eitems.size0",
              "string_array%2Eitems.null",
              "string_array%2Eitems.size",
              "string_array%2Eitems",
            ],
          )

          low_cardinality_streams = physical.physical_roster.select { |slot| slot.column_name == "lc_text" }
            .map { |slot| slot.stream_name || "" }
          low_cardinality_streams.should eq(["lc_text.dict_prefix", "lc_text.dict", "lc_text"])
          low_cardinality_streams.any?(&.ends_with?(".size")).should be_false

          empty_child_mark = physical.read_window("string_array", 2, 1).granules.first
          empty_child_mark.shards.map { |shard| shard.stream_name || "" }.should eq(
            [
              "string_array%2Eitems.size0",
              "string_array%2Eitems.null",
              "string_array%2Eitems.size",
              "string_array%2Eitems",
            ],
          )
          empty_child_mark.shards[2].bytes.should be_empty
          empty_child_mark.shards[3].bytes.should be_empty
        end
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end
end
