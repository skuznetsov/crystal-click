require "./spec_helper"
require "file_utils"
require "./support/compact_part_writer_w276_fixture"
require "./support/compact_part_writer_w268_fixture"
require "./support/compact_part_writer_w273_fixture"

private def w276_expect_context_rejected_before_stage(
  columns : Array(CrystalClick::CompactPartColumn),
  keys : Slice(UInt64),
  rows_per_mark : Int32,
  frame_bytes : Int32,
) : Nil
  parent = File.tempname("crystal-click-w276-context-")
  part_path = File.join(parent, "all_1_1_0")
  Dir.mkdir(parent)

  begin
    expect_raises(CrystalClick::UnsupportedFormatError, /does not admit Dynamic or JSON context inputs/) do
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
    File.exists?(part_path).should be_false
    Dir.children(parent).should be_empty
  ensure
    FileUtils.rm_rf(parent)
  end
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

  it "rejects an explicit String1 Dynamic input before stage creation" do
    fixture = CompactPartWriterW268Fixture
    w276_expect_context_rejected_before_stage(
      fixture.columns,
      fixture.keys,
      CompactPartWriterW268Fixture::ROWS_PER_MARK,
      CompactPartWriterW268Fixture::FRAME_BYTES,
    )
  end

  it "rejects an explicit String1 JSON input before stage creation" do
    fixture = CompactPartWriterW273Fixture
    w276_expect_context_rejected_before_stage(
      ([fixture.column(2)] of CrystalClick::CompactPartColumn),
      CompactPartWriterW273Fixture::KEYS,
      CompactPartWriterW273Fixture::ROWS_PER_MARK,
      CompactPartWriterW273Fixture::FRAME_BYTES,
    )
  end
end
