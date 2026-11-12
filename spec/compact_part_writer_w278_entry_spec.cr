require "./spec_helper"
require "file_utils"
require "json"
require "./support/compact_part_writer_w278_fixture"

private def w278_assert_values(
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

private def w278_assert_root_windows(part_path : String) : Nil
  fixture = CompactPartWriterW278Fixture
  reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
    part_path,
    CompactPartWriterW278Fixture::ROOT_COLUMN,
    fixture.json_schema,
  )
  reader.mark_count.should eq(CompactPartWriterW278Fixture::MARK_COUNT)
  reader.row_count.should eq(CompactPartWriterW278Fixture::ROW_COUNT.to_u64)
  expected = fixture.root_rows

  full = reader.read_marks(0, reader.mark_count).flatten
  w278_assert_values(full, expected)

  middle = reader.read_marks(1, 2).flatten
  w278_assert_values(middle, expected[2, 4])

  reader.read_marks(reader.mark_count, 0).should be_empty
  nil
end

private def w278_write_root(
  part_path : String,
  shared_data_version : UInt64,
  profile : CrystalClick::BinaryBulkProfile,
) : Nil
  fixture = CompactPartWriterW278Fixture
  CrystalClick::CompactPartWriter.write_uint64_columns(
    part_path,
    CompactPartWriterW278Fixture::KEY_NAME,
    fixture.keys,
    [fixture.column(CompactPartWriterW278Fixture::ROOT_COLUMN, shared_data_version)] of CrystalClick::CompactPartColumn,
    rows_per_mark: CompactPartWriterW278Fixture::ROWS_PER_MARK,
    frame_bytes: CompactPartWriterW278Fixture::FRAME_BYTES,
    mark_format: CrystalClick::CompactMarkFormat::Mrk4,
    profile: profile,
  ).should eq(part_path)
  nil
end

private def w278_write_root_case(
  shared_data_version : UInt64,
  profile : CrystalClick::BinaryBulkProfile,
) : Nil
  parent = File.tempname("crystal-click-w278-root-v#{shared_data_version}-")
  part_path = File.join(parent, "all_1_1_0")
  Dir.mkdir(parent)
  begin
    w278_write_root(part_path, shared_data_version, profile)
    w278_assert_root_windows(part_path)
  ensure
    FileUtils.rm_rf(parent)
  end
  nil
end

private def w278_assert_column_windows(
  part_path : String,
  column_name : String,
  schema : CrystalClick::StorageColumnSchema,
) : Nil
  fixture = CompactPartWriterW278Fixture
  reader = CrystalClick::CompactRecursiveJsonColumnReader.open(part_path, column_name, schema)
  reader.mark_count.should eq(CompactPartWriterW278Fixture::MARK_COUNT)
  reader.row_count.should eq(CompactPartWriterW278Fixture::ROW_COUNT.to_u64)
  expected = fixture.rows_for(column_name)

  w278_assert_values(reader.read_marks(0, reader.mark_count).flatten, expected)
  w278_assert_values(reader.read_marks(1, 2).flatten, expected[2, 4])
  reader.read_marks(reader.mark_count, 0).should be_empty
  nil
end

describe "W278 Compact advanced Object writer entry" do
  it "keeps the root, Array(JSON), tagged, and pair MAP controls round-trippable under String0 and String1" do
    fixture = CompactPartWriterW278Fixture
    profiles = [
      CrystalClick::BinaryBulkProfile.single_stream,
      CrystalClick::BinaryBulkProfile.with_size_stream,
    ] of CrystalClick::BinaryBulkProfile

    profiles.each_with_index do |profile, profile_index|
      parent = File.tempname("crystal-click-w278-map-profile-#{profile_index}-")
      part_path = File.join(parent, "all_1_1_0")
      Dir.mkdir(parent)
      begin
        CrystalClick::CompactPartWriter.write_uint64_columns(
          part_path,
          CompactPartWriterW278Fixture::KEY_NAME,
          fixture.keys,
          fixture.columns(0_u64),
          rows_per_mark: CompactPartWriterW278Fixture::ROWS_PER_MARK,
          frame_bytes: CompactPartWriterW278Fixture::FRAME_BYTES,
          mark_format: CrystalClick::CompactMarkFormat::Mrk4,
          profile: profile,
        ).should eq(part_path)

        serialization = JSON.parse(File.read(File.join(part_path, "serialization.json")))
        serialization.as_h["version"].as_i.should eq(1)
        serialization.as_h["propagate_types_serialization_versions_to_nested_types"].as_bool.should be_true
        serialization.as_h["types_serialization_versions"].as_h["string"].as_i.should eq(profile_index)
        File.read(File.join(part_path, "metadata_version.txt")).should eq("0")

        fixture.schemas.each do |column_name, schema|
          w278_assert_column_windows(part_path, column_name, schema)
        end
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "writes root Object V3 ADVANCED under String0" do
    w278_write_root_case(2_u64, CrystalClick::BinaryBulkProfile.single_stream)
  end

  it "writes root Object V3 ADVANCED under String1" do
    w278_write_root_case(2_u64, CrystalClick::BinaryBulkProfile.with_size_stream)
  end

  it "writes root Object V3 ADVANCED_CHUNKED under String0" do
    w278_write_root_case(3_u64, CrystalClick::BinaryBulkProfile.single_stream)
  end

  it "writes root Object V3 ADVANCED_CHUNKED under String1" do
    w278_write_root_case(3_u64, CrystalClick::BinaryBulkProfile.with_size_stream)
  end
end
