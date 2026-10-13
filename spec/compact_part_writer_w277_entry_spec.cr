require "./spec_helper"
require "file_utils"
require "json"
require "./support/compact_part_writer_w277_fixture"

private def w277_assert_round_trip(
  part_path : String,
  column_names : Array(String),
) : Nil
  fixture = CompactPartWriterW277Fixture
  column_names.each do |column_name|
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
    else
      reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
        part_path,
        column_name,
        fixture.schemas(:map)[column_name],
      )
      reader.mark_count.should eq(CompactPartWriterW277Fixture::MARK_COUNT)
      fixture.signatures_from(column_name, reader.read_marks(0, reader.mark_count)).should eq(
        fixture.expected_signatures(column_name),
      )
    end
  end
  nil
end

describe "W277 propagated String1 Compact context entry" do
  it "keeps a String0 control round-trippable across admitted recursive owners" do
    fixture = CompactPartWriterW277Fixture
    parent = File.tempname("crystal-click-w277-s0-control-")
    part_path = File.join(parent, "all_1_1_0")
    Dir.mkdir(parent)

    begin
      CrystalClick::CompactPartWriter.write_uint64_columns(
        part_path,
        CompactPartWriterW277Fixture::KEY_NAME,
        fixture.keys,
        fixture.columns(:map),
        rows_per_mark: CompactPartWriterW277Fixture::ROWS_PER_MARK,
        frame_bytes: CompactPartWriterW277Fixture::FRAME_BYTES,
        mark_format: CrystalClick::CompactMarkFormat::Mrk4,
        profile: CrystalClick::BinaryBulkProfile.single_stream,
      ).should eq(part_path)

      serialization = JSON.parse(File.read(File.join(part_path, "serialization.json")))
      serialization.as_h["propagate_types_serialization_versions_to_nested_types"].as_bool.should be_true
      serialization.as_h["types_serialization_versions"].as_h["string"].as_i.should eq(0)
      File.read(File.join(part_path, "metadata_version.txt")).should eq("0")
      w277_assert_round_trip(part_path, fixture.column_names_for(:map))
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes and reads String1 through Dynamic and JSON context owners" do
    fixture = CompactPartWriterW277Fixture
    parent = File.tempname("crystal-click-w277-s1-entry-")
    part_path = File.join(parent, "all_1_1_0")
    Dir.mkdir(parent)

    begin
      CrystalClick::CompactPartWriter.write_uint64_columns(
        part_path,
        CompactPartWriterW277Fixture::KEY_NAME,
        fixture.keys,
        fixture.columns(:map),
        rows_per_mark: CompactPartWriterW277Fixture::ROWS_PER_MARK,
        frame_bytes: CompactPartWriterW277Fixture::FRAME_BYTES,
        mark_format: CrystalClick::CompactMarkFormat::Mrk4,
        profile: CrystalClick::BinaryBulkProfile.with_size_stream,
      ).should eq(part_path)

      serialization = JSON.parse(File.read(File.join(part_path, "serialization.json")))
      serialization.as_h["version"].as_i.should eq(1)
      serialization.as_h["propagate_types_serialization_versions_to_nested_types"].as_bool.should be_true
      serialization.as_h["types_serialization_versions"].as_h["string"].as_i.should eq(1)
      File.read(File.join(part_path, "metadata_version.txt")).should eq("0")
      w277_assert_round_trip(part_path, fixture.column_names_for(:map))
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
