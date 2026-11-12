require "./spec_helper"
require "file_utils"
require "./support/compact_part_writer_w283_fixture"

private def w283_profile_cases : Array(Tuple(String, CrystalClick::BinaryBulkProfile))
  [
    {"s0", CrystalClick::BinaryBulkProfile.single_stream},
    {"s1", CrystalClick::BinaryBulkProfile.with_size_stream},
  ] of Tuple(String, CrystalClick::BinaryBulkProfile)
end

private def w283_mark_format_cases : Array(Tuple(String, CrystalClick::CompactMarkFormat))
  [
    {"mrk3", CrystalClick::CompactMarkFormat::Mrk3},
    {"mrk4", CrystalClick::CompactMarkFormat::Mrk4},
  ] of Tuple(String, CrystalClick::CompactMarkFormat)
end

private def w283_mode_cases : Array(Tuple(String, CrystalClick::CompactVariantDiscriminatorMode))
  [
    {"basic", CrystalClick::CompactVariantDiscriminatorMode::Basic},
    {"compact", CrystalClick::CompactVariantDiscriminatorMode::Compact},
  ] of Tuple(String, CrystalClick::CompactVariantDiscriminatorMode)
end

private def w283_assert_values(
  actual : Array(CrystalClick::StorageColumnValue),
  expected : Array(CrystalClick::StorageColumnValue),
) : Nil
  actual.size.should eq(expected.size)
  actual.each_with_index do |value, index|
    budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, false)
    CrystalClick::CompactPartValueComparison.storage!(value, expected[index], budget)
  end
  nil
end

private def w283_write_and_read_matrix : Nil
  fixture = CompactPartWriterW283Fixture
  fixture.rows.size.should eq(CompactPartWriterW283Fixture::ROW_COUNT)

  w283_mark_format_cases.each do |mark_name, mark_format|
    w283_mode_cases.each do |mode_name, mode|
      w283_profile_cases.each do |profile_name, profile|
        parent = File.tempname("crystal-click-w283-#{mark_name}-#{mode_name}-#{profile_name}-")
        part_path = File.join(parent, "all_1_1_0")
        Dir.mkdir(parent)
        begin
          CrystalClick::CompactPartWriter.write_uint64_columns(
            part_path,
            CompactPartWriterW283Fixture::KEY_NAME,
            fixture.keys,
            [fixture.column] of CrystalClick::CompactPartColumn,
            rows_per_mark: CompactPartWriterW283Fixture::ROWS_PER_MARK,
            frame_bytes: CompactPartWriterW283Fixture::FRAME_BYTES,
            mark_format: mark_format,
            variant_discriminator_mode: mode,
            profile: profile,
          ).should eq(part_path)

          reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
            part_path,
            CompactPartWriterW283Fixture::COLUMN_NAME,
            fixture.schema,
          )
          reader.ordinary_profile.should eq(profile)
          reader.mark_count.should eq(CompactPartWriterW283Fixture::MARK_COUNT)
          reader.row_count.should eq(CompactPartWriterW283Fixture::ROW_COUNT.to_u64)
          reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])

          [
            {0, CompactPartWriterW283Fixture::MARK_COUNT},
            {1, 2},
            {CompactPartWriterW283Fixture::MARK_COUNT - 1, 1},
            {CompactPartWriterW283Fixture::MARK_COUNT, 0},
          ].each do |first_mark, mark_count|
            actual_marks = reader.read_marks(first_mark, mark_count)
            actual_marks.size.should eq(mark_count)
            first_row = first_mark * CompactPartWriterW283Fixture::ROWS_PER_MARK
            expected_count = mark_count * CompactPartWriterW283Fixture::ROWS_PER_MARK
            expected_rows = fixture.rows[first_row, expected_count]
            w283_assert_values(actual_marks.flatten, expected_rows)
          end
        ensure
          FileUtils.rm_rf(parent)
        end
      end
    end
  end
  nil
end

describe "W283 recursive Variant in Compact JSON Bulk islands" do
  it "uses the public recursive storage carrier and preserves the intended Variant arms" do
    fixture = CompactPartWriterW283Fixture
    parsed = fixture.schema

    parsed.declaration.should eq(fixture.schema_declaration)
    parsed.child_at(0).object_schema.declaration.should eq(CompactPartWriterW283Fixture::JSON_DECLARATION)
    parsed.child_at(1).bulk?.should be_true
    parsed.child_at(2).object_schema.declaration.should eq(CompactPartWriterW283Fixture::JSON_DECLARATION)
    parsed.child_at(3).bulk?.should be_true

    fixture.variant_type.name.should eq(CompactPartWriterW283Fixture::VARIANT_DECLARATION)
    fixture.variant_type.children.map(&.name).should eq(
      ["Array(UInt8)", "String", "UInt64"] of String,
    )
    fixture.rows.size.should eq(CompactPartWriterW283Fixture::ROW_COUNT)
  end

  it "admits interleaved JSON with Variant beneath Array/Tuple, Tuple, Map, and Nested" do
    CrystalClick::CompactRecursiveJsonColumnReader.admitted_schema?(
      CompactPartWriterW283Fixture.schema,
    ).should be_true
  end

  it "round-trips BASIC/COMPACT discriminators across MRK3/MRK4 and String0/String1 windows" do
    w283_write_and_read_matrix
  end
end
