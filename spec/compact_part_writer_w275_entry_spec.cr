require "./spec_helper"
require "./support/compact_part_writer_w264_fixture"

describe "W275 compressed Compact marks writer entry" do
  {
    CrystalClick::CompactMarkFormat::Mrk3 => "data.cmrk3",
    CrystalClick::CompactMarkFormat::Mrk4 => "data.cmrk4",
  }.each do |mark_format, compressed_name|
    it "publishes #{compressed_name} through the public writer option" do
      fixture = CompactPartWriterW264Fixture
      parent = File.tempname("crystal-click-w275-entry-")
      part_path = File.join(parent, "all_1_1_0")
      Dir.mkdir(parent)

      begin
        CrystalClick::CompactPartWriter.write_uint64_columns(
          part_path,
          CompactPartWriterW264Fixture::KEY_NAME,
          fixture.keys,
          fixture.columns,
          rows_per_mark: CompactPartWriterW264Fixture::ROWS_PER_MARK,
          frame_bytes: CompactPartWriterW264Fixture::FRAME_BYTES,
          mark_format: mark_format,
          compress_marks: true,
        ).should eq(part_path)

        File.exists?(File.join(part_path, compressed_name)).should be_true
        context = CrystalClick::CompactPartPhysicalContext.open(part_path)
        context.mode.should eq(mark_format)
        context.row_count.should eq(CompactPartWriterW264Fixture::ROW_COUNT.to_u64)

        reader = CrystalClick::CompactBinaryBulkColumnReader.open(
          part_path,
          "u",
          fixture.types["u"],
        )
        reader.read_marks(0, reader.mark_count).flatten.map(&.as_uint64).should eq(
          fixture.values_for("u").map(&.as_uint64),
        )
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end
end
