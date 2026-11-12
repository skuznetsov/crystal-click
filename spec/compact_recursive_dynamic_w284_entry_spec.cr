require "./spec_helper"
require "file_utils"
require "./support/compact_recursive_dynamic_w284_fixture"

private def w284_assert_values(
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

describe "W284 recursive Dynamic sibling in Compact JSON" do
  it "round-trips the exact W257 Array(Tuple(JSON, Dynamic)) values through public Compact APIs" do
    fixture = CompactRecursiveDynamicW284Fixture
    parent = File.tempname("crystal-click-w284-")
    part_path = File.join(parent, "all_1_1_0")
    Dir.mkdir(parent)
    begin
      column = fixture.column
      CrystalClick::CompactPartWriter.write_uint64_columns(
        part_path,
        CompactRecursiveDynamicW284Fixture::KEY_NAME,
        fixture.keys,
        [column] of CrystalClick::CompactPartColumn,
        rows_per_mark: CompactRecursiveDynamicW284Fixture::ROWS_PER_MARK,
        frame_bytes: CompactRecursiveDynamicW284Fixture::FRAME_BYTES,
        mark_format: CrystalClick::CompactMarkFormat::Mrk3,
        variant_discriminator_mode: CrystalClick::CompactVariantDiscriminatorMode::Compact,
        profile: CrystalClick::BinaryBulkProfile.with_size_stream,
      ).should eq(part_path)

      reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
        part_path,
        CompactRecursiveDynamicW284Fixture::COLUMN_NAME,
        fixture.schema,
      )
      reader.mark_count.should eq(CompactRecursiveDynamicW284Fixture::MARK_COUNT)
      reader.row_count.should eq(CompactRecursiveDynamicW284Fixture::ROW_COUNT.to_u64)
      reader.mark_row_counts.should eq([2_u64, 2_u64])
      w284_assert_values(
        reader.read_marks(0, CompactRecursiveDynamicW284Fixture::MARK_COUNT).flatten,
        fixture.rows,
      )
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "prepares mark zero when a fresh reader first requests a later mark" do
    fixture = CompactRecursiveDynamicW284Fixture
    parent = File.tempname("crystal-click-w284-later-")
    part_path = File.join(parent, "all_1_1_0")
    Dir.mkdir(parent)
    begin
      CrystalClick::CompactPartWriter.write_uint64_columns(
        part_path,
        CompactRecursiveDynamicW284Fixture::KEY_NAME,
        fixture.keys,
        [fixture.column] of CrystalClick::CompactPartColumn,
        rows_per_mark: CompactRecursiveDynamicW284Fixture::ROWS_PER_MARK,
        frame_bytes: CompactRecursiveDynamicW284Fixture::FRAME_BYTES,
        mark_format: CrystalClick::CompactMarkFormat::Mrk3,
        variant_discriminator_mode: CrystalClick::CompactVariantDiscriminatorMode::Compact,
        profile: CrystalClick::BinaryBulkProfile.with_size_stream,
      ).should eq(part_path)

      reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
        part_path,
        CompactRecursiveDynamicW284Fixture::COLUMN_NAME,
        fixture.schema,
      )
      # This reader has not requested mark zero. The later DynamicStructure
      # prefix omits first-mark-only statistics, so discovery must still seed
      # the frozen callback roster from the part's first mark.
      w284_assert_values(
        reader.read_marks(1, 1).flatten,
        [fixture.rows[2], fixture.rows[3]] of CrystalClick::StorageColumnValue,
      )
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
