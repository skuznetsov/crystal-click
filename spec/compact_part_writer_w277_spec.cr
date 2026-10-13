require "./spec_helper"
require "file_utils"
require "json"
require "./support/compact_part_writer_w277_fixture"

private def w277_round_trip_column(
  part_path : String,
  shared_layout : Symbol,
  column_name : String,
) : Nil
  fixture = CompactPartWriterW277Fixture
  if column_name == CompactPartWriterW277Fixture::ROOT_DYNAMIC_COLUMN ||
     column_name == CompactPartWriterW277Fixture::TUPLE_ARRAY_COLUMN
    reader = CrystalClick::CompactDynamicBulkColumnReader.open(
      part_path,
      column_name,
      fixture.types[column_name],
    )
    reader.mark_count.should eq(CompactPartWriterW277Fixture::MARK_COUNT)
    fixture.signatures_from(column_name, reader.read_marks(0, reader.mark_count)).should eq(
      fixture.expected_signatures(column_name),
    )
    expected_middle = Array(String).new(4)
    (2...6).each { |index| expected_middle << fixture.expected_signatures(column_name)[index] }
    fixture.signatures_from(column_name, reader.read_marks(1, 2)).should eq(expected_middle)
    fixture.signatures_from(column_name, reader.read_marks(reader.mark_count, 0)).should be_empty
  else
    reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
      part_path,
      column_name,
      fixture.schemas(shared_layout)[column_name],
    )
    reader.mark_count.should eq(CompactPartWriterW277Fixture::MARK_COUNT)
    fixture.signatures_from(column_name, reader.read_marks(0, reader.mark_count)).should eq(
      fixture.expected_signatures(column_name),
    )
    expected_middle = Array(String).new(4)
    (2...6).each { |index| expected_middle << fixture.expected_signatures(column_name)[index] }
    fixture.signatures_from(column_name, reader.read_marks(1, 2)).should eq(expected_middle)
    fixture.signatures_from(column_name, reader.read_marks(reader.mark_count, 0)).should be_empty
  end
  nil
end

private def w277_write_profile_case(
  part_path : String,
  shared_layout : Symbol,
  mark_format : CrystalClick::CompactMarkFormat,
  compress_marks : Bool,
  discriminator_mode : CrystalClick::CompactVariantDiscriminatorMode,
) : Nil
  fixture = CompactPartWriterW277Fixture
  CrystalClick::CompactPartWriter.write_uint64_columns(
    part_path,
    CompactPartWriterW277Fixture::KEY_NAME,
    fixture.keys,
    fixture.columns(shared_layout),
    rows_per_mark: CompactPartWriterW277Fixture::ROWS_PER_MARK,
    frame_bytes: CompactPartWriterW277Fixture::FRAME_BYTES,
    mark_format: mark_format,
    variant_discriminator_mode: discriminator_mode,
    compress_marks: compress_marks,
    profile: CrystalClick::BinaryBulkProfile.with_size_stream,
  ).should eq(part_path)

  serialization = JSON.parse(File.read(File.join(part_path, "serialization.json")))
  serialization.as_h["version"].as_i.should eq(1)
  serialization.as_h["propagate_types_serialization_versions_to_nested_types"].as_bool.should be_true
  serialization.as_h["types_serialization_versions"].as_h["string"].as_i.should eq(1)
  File.read(File.join(part_path, "metadata_version.txt")).should eq("0")

  physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
  physical.mode.should eq(mark_format)
  physical.row_count.should eq(CompactPartWriterW277Fixture::ROW_COUNT.to_u64)
  physical.granule_count.should eq(CompactPartWriterW277Fixture::MARK_COUNT)
  fixture.column_names_for(shared_layout).each do |column_name|
    w277_round_trip_column(part_path, shared_layout, column_name)
    physical.read_window(column_name, physical.granule_count, 0).granules.should be_empty
  end
end

describe "W277 propagated String1 Compact context writers" do
  it "round-trips the admitted MAP and MAP_WITH_BUCKETS context matrix" do
    layouts = [:map, :map_with_buckets]
    mark_formats = [
      CrystalClick::CompactMarkFormat::Mrk3,
      CrystalClick::CompactMarkFormat::Mrk4,
    ]
    discriminator_modes = [
      CrystalClick::CompactVariantDiscriminatorMode::Basic,
      CrystalClick::CompactVariantDiscriminatorMode::Compact,
    ]
    case_index = 0

    layouts.each do |shared_layout|
      mark_formats.each do |mark_format|
        [false, true].each do |compress_marks|
          discriminator_modes.each do |discriminator_mode|
            parent = File.tempname("crystal-click-w277-context-matrix-#{case_index}-")
            part_path = File.join(parent, "all_1_1_0")
            begin
              Dir.mkdir(parent)
              w277_write_profile_case(
                part_path,
                shared_layout,
                mark_format,
                compress_marks,
                discriminator_mode,
              )
            ensure
              FileUtils.rm_rf(parent)
            end
            case_index += 1
          end
        end
      end
    end
    case_index.should eq(16)
  end

  it "keeps context factories on String0 by default and accepts an explicit String1 binding" do
    columns = CompactPartWriterW277Fixture.columns(:map)
    single = CrystalClick::BinaryBulkProfile.single_stream
    sized = CrystalClick::BinaryBulkProfile.with_size_stream

    columns[0].dynamic_input.profile.should eq(single)
    columns[0].dynamic_input(sized).profile.should eq(sized)
    columns[2].json_input.profile.should eq(single)
    columns[2].json_input(sized).profile.should eq(sized)
  end
end
