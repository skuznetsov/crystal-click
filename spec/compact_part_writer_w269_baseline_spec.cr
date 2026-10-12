require "./spec_helper"
require "file_utils"
require "./support/compact_part_writer_w269_fixture"

describe CrystalClick::CompactPartWriter do
  it "continues to reject the historical unbound BinaryValue JSON route before publication" do
    root_type, wrapped_type, root_granules, wrapped_granules = CompactPartWriterW269Fixture.legacy_binary_fixtures
    columns = [
      CrystalClick::CompactPartColumn.binary_bulk("root", root_type, root_granules),
      CrystalClick::CompactPartColumn.binary_bulk("wrapped", wrapped_type, wrapped_granules),
    ] of CrystalClick::CompactPartColumn
    parent = File.tempname("crystal-click-w269-unbound-json-")
    part_path = File.join(parent, "all_1_1_0")

    begin
      Dir.mkdir(parent)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::CompactPartWriter.write_uint64_columns(
          part_path,
          CompactPartWriterW269Fixture::KEY_NAME,
          Slice[1_u64, 2_u64, 3_u64, 4_u64],
          columns,
          rows_per_mark: 2,
          mark_format: CrystalClick::CompactMarkFormat::Mrk4,
        )
      end
      File.exists?(part_path).should be_false
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
