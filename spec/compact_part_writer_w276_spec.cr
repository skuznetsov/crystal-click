require "./spec_helper"
require "file_utils"
require "json"
require "./support/compact_part_writer_w276_fixture"
require "./support/compact_part_writer_w268_fixture"
require "./support/compact_part_writer_w273_fixture"

private def w276_write_with_size_stream(
  part_path : String,
  columns : Array(CrystalClick::CompactPartColumn),
  keys : Slice(UInt64),
  rows_per_mark : Int32,
  frame_bytes : Int32,
) : String
  CrystalClick::CompactPartWriter.write_uint64_columns(
    part_path,
    "pk",
    keys,
    columns,
    rows_per_mark: rows_per_mark,
    frame_bytes: frame_bytes,
    profile: CrystalClick::BinaryBulkProfile.with_size_stream,
  )
end

describe "W276 Compact String profile compatibility" do
  it "preserves the default String0 bytes when the profile is omitted" do
    fixture = CompactPartWriterW276Fixture
    parent = File.tempname("crystal-click-w276-default-profile-")
    default_path = File.join(parent, "default_1_1_0")
    explicit_path = File.join(parent, "explicit_1_1_0")
    Dir.mkdir(parent)

    begin
      CrystalClick::CompactPartWriter.write_uint64_columns(
        default_path,
        CompactPartWriterW276Fixture::KEY_NAME,
        fixture.keys,
        fixture.columns,
        rows_per_mark: CompactPartWriterW276Fixture::ROWS_PER_MARK,
        frame_bytes: CompactPartWriterW276Fixture::FRAME_BYTES,
        mark_format: CrystalClick::CompactMarkFormat::Mrk4,
      )
      CrystalClick::CompactPartWriter.write_uint64_columns(
        explicit_path,
        CompactPartWriterW276Fixture::KEY_NAME,
        fixture.keys,
        fixture.columns,
        rows_per_mark: CompactPartWriterW276Fixture::ROWS_PER_MARK,
        frame_bytes: CompactPartWriterW276Fixture::FRAME_BYTES,
        mark_format: CrystalClick::CompactMarkFormat::Mrk4,
        profile: CrystalClick::BinaryBulkProfile.single_stream,
      )

      default_files = Dir.children(default_path).sort
      default_files.should eq(Dir.children(explicit_path).sort)
      default_files.each do |name|
        File.read(File.join(default_path, name)).should eq(File.read(File.join(explicit_path, name)))
      end
      File.read(File.join(default_path, "serialization.json")).should eq("{\"columns\":[],\"propagate_types_serialization_versions_to_nested_types\":true,\"types_serialization_versions\":{\"string\":0},\"version\":1}")
      File.read(File.join(default_path, "metadata_version.txt")).should eq("0")
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "round-trips explicit String1 Dynamic context inputs" do
    fixture = CompactPartWriterW268Fixture
    parent = File.tempname("crystal-click-w276-dynamic-string1-")
    part_path = File.join(parent, "all_1_1_0")
    Dir.mkdir(parent)

    begin
      w276_write_with_size_stream(
        part_path,
        fixture.columns,
        fixture.keys,
        CompactPartWriterW268Fixture::ROWS_PER_MARK,
        CompactPartWriterW268Fixture::FRAME_BYTES,
      ).should eq(part_path)

      serialization = JSON.parse(File.read(File.join(part_path, "serialization.json")))
      serialization.as_h["version"].as_i.should eq(1)
      serialization.as_h["propagate_types_serialization_versions_to_nested_types"].as_bool.should be_true
      serialization.as_h["types_serialization_versions"].as_h["string"].as_i.should eq(1)

      root = CrystalClick::CompactDynamicBulkColumnReader.open(
        part_path,
        CompactPartWriterW268Fixture::ROOT_COLUMN,
        fixture.root_type,
      )
      fixture.signature(
        CompactPartWriterW268Fixture::ROOT_COLUMN,
        root.read_marks(0, CompactPartWriterW268Fixture::MARK_COUNT).flatten,
      ).should eq(CompactPartWriterW268Fixture::ROOT_SIGNATURES)

      context = CrystalClick::CompactDynamicBulkColumnReader.open(
        part_path,
        CompactPartWriterW268Fixture::CTX_COLUMN,
        fixture.ctx_type,
      )
      fixture.signature(
        CompactPartWriterW268Fixture::CTX_COLUMN,
        context.read_marks(0, CompactPartWriterW268Fixture::MARK_COUNT).flatten,
      ).should eq(CompactPartWriterW268Fixture::CTX_SIGNATURES)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "round-trips explicit String1 typed-Dynamic JSON input" do
    fixture = CompactPartWriterW273Fixture
    parent = File.tempname("crystal-click-w276-json-string1-")
    part_path = File.join(parent, "all_1_1_0")
    Dir.mkdir(parent)

    begin
      w276_write_with_size_stream(
        part_path,
        ([fixture.column(2)] of CrystalClick::CompactPartColumn),
        CompactPartWriterW273Fixture::KEYS,
        CompactPartWriterW273Fixture::ROWS_PER_MARK,
        CompactPartWriterW273Fixture::FRAME_BYTES,
      ).should eq(part_path)

      serialization = JSON.parse(File.read(File.join(part_path, "serialization.json")))
      serialization.as_h["version"].as_i.should eq(1)
      serialization.as_h["propagate_types_serialization_versions_to_nested_types"].as_bool.should be_true
      serialization.as_h["types_serialization_versions"].as_h["string"].as_i.should eq(1)

      reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
        part_path,
        CompactPartWriterW273Fixture::COLUMN_NAME,
        fixture.schema,
      )
      values = reader.read_marks(0, CompactPartWriterW273Fixture::MARK_COUNT).flatten
      values.map { |value| fixture.literal_for(value, 2) }.should eq(
        CompactPartWriterW273Fixture.expected_literals(2),
      )
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
