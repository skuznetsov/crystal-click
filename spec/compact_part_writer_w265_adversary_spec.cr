require "./spec_helper"
require "./support/compact_part_writer_w264_fixture"

describe CrystalClick::CompactPartWriter do
  it "keeps the public MRK4 declaration-name admission gate before staging" do
    parent = File.tempname("crystal-click-w265-mrk4-ascii-name-")
    begin
      Dir.mkdir(parent)
      value_type = CrystalClick::BinaryDataType.primitive("UInt64")
      non_ascii = "café"
      column = CrystalClick::CompactPartColumn.binary_bulk(
        non_ascii,
        value_type,
        [[CrystalClick::BinaryValue.uint64(11_u64), CrystalClick::BinaryValue.uint64(22_u64)]],
      )

      expect_raises(ArgumentError, /column name is invalid/) do
        CrystalClick::CompactPartWriter.write_uint64_columns(
          File.join(parent, "part"),
          CompactPartWriterW264Fixture::KEY_NAME,
          Slice[1_u64, 2_u64],
          [column],
          rows_per_mark: 2,
          mark_format: CrystalClick::CompactMarkFormat::Mrk4,
        )
      end
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
