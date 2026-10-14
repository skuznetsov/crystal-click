require "./spec_helper"
require "file_utils"
require "./support/compact_part_writer_w282_fixture"

private def w282_profile_cases : Array(Tuple(String, CrystalClick::CompactMarkFormat, CrystalClick::BinaryBulkProfile))
  [
    {"mrk3_s0", CrystalClick::CompactMarkFormat::Mrk3, CrystalClick::BinaryBulkProfile.single_stream},
    {"mrk3_s1", CrystalClick::CompactMarkFormat::Mrk3, CrystalClick::BinaryBulkProfile.with_size_stream},
    {"mrk4_s0", CrystalClick::CompactMarkFormat::Mrk4, CrystalClick::BinaryBulkProfile.single_stream},
    {"mrk4_s1", CrystalClick::CompactMarkFormat::Mrk4, CrystalClick::BinaryBulkProfile.with_size_stream},
  ] of Tuple(String, CrystalClick::CompactMarkFormat, CrystalClick::BinaryBulkProfile)
end

private def w282_write_and_read_main_fixture : Nil
  fixture = CompactPartWriterW282Fixture
  w282_profile_cases.each do |case_name, mark_format, profile|
    parent = File.tempname("crystal-click-w282-main-#{case_name}-")
    part_path = File.join(parent, "all_1_1_0")
    Dir.mkdir(parent)
    begin
      CrystalClick::CompactPartWriter.write_uint64_columns(
        part_path,
        CompactPartWriterW282Fixture::KEY_NAME,
        fixture.keys,
        [fixture.column] of CrystalClick::CompactPartColumn,
        rows_per_mark: CompactPartWriterW282Fixture::ROWS_PER_MARK,
        frame_bytes: CompactPartWriterW282Fixture::FRAME_BYTES,
        mark_format: mark_format,
        profile: profile,
      ).should eq(part_path)

      reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
        part_path,
        CompactPartWriterW282Fixture::COLUMN_NAME,
        fixture.schema,
      )
      reader.ordinary_profile.should eq(profile)
      reader.mark_count.should eq(CompactPartWriterW282Fixture::MARK_COUNT)
      reader.row_count.should eq(CompactPartWriterW282Fixture::ROW_COUNT.to_u64)
      reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])

      fixture.signatures_from(reader.read_marks(0, reader.mark_count)).should eq(fixture.expected_signatures)
      fixture.signatures_from(reader.read_marks(0, 1)).should eq(fixture.expected_signatures[0, 2])
      fixture.signatures_from(reader.read_marks(1, 2)).should eq(fixture.expected_signatures[2, 4])
      fixture.signatures_from(reader.read_marks(3, 1)).should eq(fixture.expected_signatures[6, 2])
      reader.read_marks(reader.mark_count, 0).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end
  nil
end

private def w282_write_and_read_outer_array_fixture : Nil
  fixture = CompactPartWriterW282Fixture
  [
    {"mrk3", CrystalClick::CompactMarkFormat::Mrk3},
    {"mrk4", CrystalClick::CompactMarkFormat::Mrk4},
  ].each do |case_name, mark_format|
    parent = File.tempname("crystal-click-w282-outer-array-#{case_name}-")
    part_path = File.join(parent, "all_1_1_0")
    Dir.mkdir(parent)
    begin
      CrystalClick::CompactPartWriter.write_uint64_columns(
        part_path,
        CompactPartWriterW282Fixture::KEY_NAME,
        fixture.outer_array_keys,
        [fixture.outer_array_column] of CrystalClick::CompactPartColumn,
        rows_per_mark: CompactPartWriterW282Fixture::OUTER_ARRAY_ROWS_PER_MARK,
        frame_bytes: CompactPartWriterW282Fixture::FRAME_BYTES,
        mark_format: mark_format,
        profile: CrystalClick::BinaryBulkProfile.single_stream,
      ).should eq(part_path)

      reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
        part_path,
        CompactPartWriterW282Fixture::OUTER_ARRAY_COLUMN_NAME,
        fixture.outer_array_schema,
      )
      reader.row_count.should eq(CompactPartWriterW282Fixture::OUTER_ARRAY_ROW_COUNT.to_u64)
      reader.mark_count.should eq(CompactPartWriterW282Fixture::OUTER_ARRAY_MARK_COUNT)
      fixture.outer_array_signatures_from(reader.read_marks(0, reader.mark_count)).should eq(fixture.expected_outer_array_signatures)
      fixture.outer_array_signatures_from(reader.read_marks(1, 1)).should eq(fixture.expected_outer_array_signatures[1, 1])
      fixture.outer_array_signatures_from(reader.read_marks(3, 1)).should eq(fixture.expected_outer_array_signatures[3, 1])
      reader.read_marks(reader.mark_count, 0).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end
  nil
end

describe "W282 recursive LowCardinality in Compact JSON Bulk islands" do
  it "parses the public carrier with interleaved JSON and recursive Bulk sites" do
    fixture = CompactPartWriterW282Fixture
    parsed = fixture.schema

    parsed.declaration.should eq(fixture.schema_declaration)
    parsed.child_at(0).object_schema.declaration.should eq(CompactPartWriterW282Fixture::JSON_DECLARATION)
    parsed.child_at(1).bulk?.should be_true
    parsed.child_at(2).object_schema.declaration.should eq(CompactPartWriterW282Fixture::JSON_DECLARATION)
    parsed.child_at(3).bulk?.should be_true
    fixture.signatures_from([fixture.rows] of Array(CrystalClick::StorageColumnValue)).should eq(fixture.expected_signatures)
  end

  it "admits recursive LowCardinality below the JSON-free Bulk subtree" do
    fixture = CompactPartWriterW282Fixture
    CrystalClick::CompactRecursiveJsonColumnReader.admitted_schema?(fixture.schema).should be_true
  end

  it "round-trips interleaved JSON and recursive Bulk across MRK3/MRK4 and String0/String1 windows" do
    w282_write_and_read_main_fixture
  end

  it "traverses a Bulk island under an outer Array without relying on a root Tuple position" do
    fixture = CompactPartWriterW282Fixture
    CrystalClick::CompactRecursiveJsonColumnReader.admitted_schema?(fixture.outer_array_schema).should be_true
    w282_write_and_read_outer_array_fixture
  end
end
