require "./spec_helper"
require "file_utils"
require "./support/compact_part_writer_w270_fixture"

describe CrystalClick::CompactPartWriter do
  it "publishes and reads back nested typed-Dynamic Array(UInt8) JSON under plain MRK3" do
    fixture = CompactPartWriterW270Fixture
    parent = File.tempname("crystal-click-w270-mrk3-typed-dynamic-")
    part_path = File.join(parent, "all_1_1_0")

    begin
      Dir.mkdir(parent)
      columns = [fixture.column] of CrystalClick::CompactPartColumn
      CrystalClick::CompactPartWriter.write_uint64_columns(
        part_path,
        CompactPartWriterW270Fixture::KEY_NAME,
        CompactPartWriterW270Fixture::KEYS,
        columns,
        rows_per_mark: CompactPartWriterW270Fixture::ROWS_PER_MARK,
        mark_format: CrystalClick::CompactMarkFormat::Mrk3,
        variant_discriminator_mode: CrystalClick::CompactVariantDiscriminatorMode::Compact,
      ).should eq(part_path)
      File.exists?(part_path).should be_true

      reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
        part_path,
        CompactPartWriterW270Fixture::COLUMN_NAME,
        fixture.schema,
      )
      reader.mark_count.should eq(CompactPartWriterW270Fixture::MARK_COUNT)
      reader.row_count.should eq(CompactPartWriterW270Fixture::ROW_COUNT.to_u64)
      actual = reader.read_marks(0, CompactPartWriterW270Fixture::MARK_COUNT).flatten
      expected = fixture.rows
      actual.size.should eq(expected.size)
      actual.each_with_index do |value, index|
        budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, false)
        CrystalClick::CompactPartValueComparison.storage!(value, expected[index], budget)
      end
      reader.read_marks(reader.mark_count, 0).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
