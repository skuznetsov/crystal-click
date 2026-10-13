require "./spec_helper"
require "file_utils"
require "json"
require "./support/compact_part_writer_w278_fixture"

private def w278_round_trip_column(
  part_path : String,
  column_name : String,
  schema : CrystalClick::StorageColumnSchema,
  profile : CrystalClick::BinaryBulkProfile,
) : Nil
  reader = CrystalClick::CompactRecursiveJsonColumnReader.open(part_path, column_name, schema)
  reader.mark_count.should eq(CompactPartWriterW278Fixture::MARK_COUNT)
  reader.row_count.should eq(CompactPartWriterW278Fixture::ROW_COUNT.to_u64)
  reader.ordinary_profile.should eq(profile)

  expected = CompactPartWriterW278Fixture.rows_for(column_name)
  actual = reader.read_marks(0, reader.mark_count).flatten
  actual.size.should eq(expected.size)
  actual.each_with_index do |value, index|
    budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, false)
    CrystalClick::CompactPartValueComparison.storage!(value, expected[index], budget)
  end

  middle = reader.read_marks(1, 2).flatten
  middle.size.should eq(4)
  middle.each_with_index do |value, index|
    budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, false)
    CrystalClick::CompactPartValueComparison.storage!(value, expected[index + 2], budget)
  end
  reader.read_marks(reader.mark_count, 0).should be_empty
  nil
end

private def w278_write_matrix_cell(
  shared_data_version : UInt64,
  profile : CrystalClick::BinaryBulkProfile,
  mark_format : CrystalClick::CompactMarkFormat,
  compress_marks : Bool,
  discriminator_mode : CrystalClick::CompactVariantDiscriminatorMode,
) : Nil
  fixture = CompactPartWriterW278Fixture
  parent = File.tempname("crystal-click-w278-advanced-")
  part_path = File.join(parent, "all_1_1_0")
  begin
    Dir.mkdir(parent)
    CrystalClick::CompactPartWriter.write_uint64_columns(
      part_path,
      CompactPartWriterW278Fixture::KEY_NAME,
      fixture.keys,
      fixture.columns(shared_data_version),
      rows_per_mark: CompactPartWriterW278Fixture::ROWS_PER_MARK,
      # Small frames force advanced payloads and relocations across blocks.
      frame_bytes: 64,
      mark_format: mark_format,
      variant_discriminator_mode: discriminator_mode,
      compress_marks: compress_marks,
      profile: profile,
    ).should eq(part_path)

    serialization = JSON.parse(File.read(File.join(part_path, "serialization.json")))
    serialization.as_h["version"].as_i.should eq(1)
    serialization.as_h["propagate_types_serialization_versions_to_nested_types"].as_bool.should be_true
    serialization.as_h["types_serialization_versions"].as_h["string"].as_i.should eq(profile.with_size_stream? ? 1 : 0)
    File.read(File.join(part_path, "metadata_version.txt")).should eq("0")

    physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
    physical.mode.should eq(mark_format)
    physical.row_count.should eq(CompactPartWriterW278Fixture::ROW_COUNT.to_u64)
    physical.granule_count.should eq(CompactPartWriterW278Fixture::MARK_COUNT)
    physical.mark_row_counts.should eq(Array(UInt64).new(CompactPartWriterW278Fixture::MARK_COUNT, 2_u64))
    fixture.schemas.each do |column_name, schema|
      w278_round_trip_column(part_path, column_name, schema, profile)
      physical.read_window(column_name, physical.granule_count, 0).granules.should be_empty
    end

    marks_name = physical.marks_name
    checksums = CrystalClick::PartChecksums.open(part_path)
    mark_entry = checksums.entry(marks_name).not_nil!
    mark_entry.compressed.should eq(compress_marks)
  ensure
    FileUtils.rm_rf(parent)
  end
  nil
end

describe "W278 Compact ADVANCED and ADVANCED_CHUNKED writers" do
  it "round-trips all admitted JSON owners across profile, mark, compression, and discriminator modes" do
    shared_versions = [2_u64, 3_u64]
    profiles = [
      CrystalClick::BinaryBulkProfile.single_stream,
      CrystalClick::BinaryBulkProfile.with_size_stream,
    ] of CrystalClick::BinaryBulkProfile
    mark_formats = [
      CrystalClick::CompactMarkFormat::Mrk3,
      CrystalClick::CompactMarkFormat::Mrk4,
    ]
    discriminator_modes = [
      CrystalClick::CompactVariantDiscriminatorMode::Basic,
      CrystalClick::CompactVariantDiscriminatorMode::Compact,
    ]
    cases = 0

    shared_versions.each do |shared_data_version|
      profiles.each do |profile|
        mark_formats.each do |mark_format|
          [false, true].each do |compress_marks|
            discriminator_modes.each do |discriminator_mode|
              w278_write_matrix_cell(
                shared_data_version,
                profile,
                mark_format,
                compress_marks,
                discriminator_mode,
              )
              cases += 1
            end
          end
        end
      end
    end

    cases.should eq(32)
  end

  it "keeps each String profile explicit at the bound column input" do
    fixture = CompactPartWriterW278Fixture
    string0 = CrystalClick::BinaryBulkProfile.single_stream
    string1 = CrystalClick::BinaryBulkProfile.with_size_stream
    columns = fixture.columns(2_u64)

    columns.each do |column|
      column.json_input.profile.should eq(string0)
      column.json_input(string1).profile.should eq(string1)
    end
  end
end
