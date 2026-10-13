require "./spec_helper"
require "file_utils"
require "./support/compact_part_writer_w271_fixture"

describe CrystalClick::CompactPartWriter do
  it "writes and reads an ordinary JSON arm of a typed Dynamic in a root Object" do
    fixture = CompactPartWriterW271Fixture
    parent = File.tempname("crystal-click-w271-typed-dynamic-json-")
    part_path = File.join(parent, "all_1_1_0")

    begin
      Dir.mkdir(parent)
      columns = [fixture.column] of CrystalClick::CompactPartColumn
      CrystalClick::CompactPartWriter.write_uint64_columns(
        part_path,
        CompactPartWriterW271Fixture::KEY_NAME,
        CompactPartWriterW271Fixture::KEYS,
        columns,
        rows_per_mark: CompactPartWriterW271Fixture::ROWS_PER_MARK,
        frame_bytes: CompactPartWriterW271Fixture::FRAME_BYTES,
        mark_format: CrystalClick::CompactMarkFormat::Mrk3,
        variant_discriminator_mode: CrystalClick::CompactVariantDiscriminatorMode::Compact,
      ).should eq(part_path)
      File.exists?(part_path).should be_true

      reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
        part_path,
        CompactPartWriterW271Fixture::COLUMN_NAME,
        fixture.schema,
      )
      reader.mark_count.should eq(CompactPartWriterW271Fixture::MARK_COUNT)
      reader.row_count.should eq(CompactPartWriterW271Fixture::ROW_COUNT.to_u64)

      actual_marks = reader.read_marks(0, CompactPartWriterW271Fixture::MARK_COUNT)
      actual_marks.size.should eq(CompactPartWriterW271Fixture::MARK_COUNT)
      actual_marks.each do |mark_rows|
        mark_rows.size.should eq(CompactPartWriterW271Fixture::ROWS_PER_MARK)
      end

      actual = actual_marks.flatten
      actual.size.should eq(CompactPartWriterW271Fixture::ROW_COUNT)
      actual.each_with_index do |value, index|
        budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, false)
        CrystalClick::CompactPartValueComparison.storage!(value, fixture.rows[index], budget)
      end
      actual.map { |value| fixture.literal_for(value) }.should eq(fixture.expected_literals)
      actual_marks.map { |mark_rows| fixture.arm_count(mark_rows) }.should eq(fixture.expected_mark_arm_counts)
      fixture.arm_count(actual_marks[1]).should eq(0)
      reader.read_marks(reader.mark_count, 0).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
