require "./spec_helper"
require "file_utils"
require "./support/compact_part_writer_w272_fixture"

private def w272_write(
  part_path : String,
  mark_format : CrystalClick::CompactMarkFormat,
  discriminator_mode : CrystalClick::CompactVariantDiscriminatorMode,
) : String
  fixture = CompactPartWriterW272Fixture
  CrystalClick::CompactPartWriter.write_uint64_columns(
    part_path,
    CompactPartWriterW272Fixture::KEY_NAME,
    CompactPartWriterW272Fixture::KEYS,
    [fixture.column] of CrystalClick::CompactPartColumn,
    rows_per_mark: CompactPartWriterW272Fixture::ROWS_PER_MARK,
    frame_bytes: CompactPartWriterW272Fixture::FRAME_BYTES,
    mark_format: mark_format,
    variant_discriminator_mode: discriminator_mode,
  )
end

private def w272_assert_literals(
  actual : Array(CrystalClick::StorageColumnValue),
  expected : Array(Array(UInt8)?),
) : Nil
  actual.size.should eq(expected.size)
  fixture = CompactPartWriterW272Fixture
  actual.each_with_index do |value, index|
    expected_array = expected[index]
    fixture.literal_for(value).should eq(expected_array)

    payload = value.object_document.value_for(CompactPartWriterW272Fixture::PAYLOAD_PATH)
    payload.type.should eq(fixture.dynamic_type)
    if values = expected_array
      payload.is_null?.should be_false
      payload.child_count.should eq(1)
      actual_array = payload.child_at(0)
      actual_array.type.should eq(fixture.array_json_type)
      actual_array.elements.size.should eq(values.size)
      actual_array.elements.each_with_index do |json, element_index|
        json.type.should eq(fixture.json_type)
        json.json_row.type.should eq(fixture.json_type)
        cell = json.json_row.value_for(CompactPartWriterW272Fixture::VALUE_PATH).not_nil!
        cell.type.should eq(fixture.uint8_type)
        cell.byte_at(0).should eq(values[element_index])
      end
    else
      payload.is_null?.should be_true
    end
  end
  nil
end

private def w272_assert_marks(
  actual : Array(Array(CrystalClick::StorageColumnValue)),
  first_mark : Int,
  mark_count : Int,
) : Nil
  fixture = CompactPartWriterW272Fixture
  actual.size.should eq(mark_count)
  expected_row_start = first_mark * CompactPartWriterW272Fixture::ROWS_PER_MARK
  expected_row_count = mark_count * CompactPartWriterW272Fixture::ROWS_PER_MARK
  expected = fixture.expected_literals[expected_row_start, expected_row_count]
  w272_assert_literals(actual.flatten, expected)
  actual.map do |mark_rows|
    mark_rows.count { |row| !fixture.literal_for(row).nil? }
  end.should eq(fixture.expected_mark_actual_counts[first_mark, mark_count])
  actual.map do |mark_rows|
    mark_rows.sum { |row| fixture.literal_for(row).try(&.size) || 0 }
  end.should eq(fixture.expected_mark_json_element_counts[first_mark, mark_count])
  nil
end

describe CrystalClick::CompactPartWriter do
  it "round trips typed-Dynamic Array(JSON) actuals with distinct arm and child-element grids" do
    fixture = CompactPartWriterW272Fixture
    # This guard runs before the public call so a malformed plan, leaf key or
    # value roster cannot masquerade as a Compact physical-admission failure.
    fixture.common_codec_roundtrip!

    parent = File.tempname("crystal-click-w272-public-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      w272_write(
        part_path,
        CrystalClick::CompactMarkFormat::Mrk3,
        CrystalClick::CompactVariantDiscriminatorMode::Basic,
      ).should eq(part_path)
      File.exists?(part_path).should be_true

      windows = [
        {0, CompactPartWriterW272Fixture::MARK_COUNT},
        {1, 2},
        {CompactPartWriterW272Fixture::MARK_COUNT - 1, 1},
        {1, 1},
        {CompactPartWriterW272Fixture::MARK_COUNT, 0},
      ]

      recursive = CrystalClick::CompactRecursiveJsonColumnReader.open(
        part_path,
        CompactPartWriterW272Fixture::COLUMN_NAME,
        fixture.schema,
      )
      recursive.schema_declaration.should eq(fixture.schema.declaration)
      recursive.mark_count.should eq(CompactPartWriterW272Fixture::MARK_COUNT)
      recursive.row_count.should eq(CompactPartWriterW272Fixture::ROW_COUNT.to_u64)
      recursive.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
      windows.each do |first_mark, mark_count|
        w272_assert_marks(recursive.read_marks(first_mark, mark_count), first_mark, mark_count)
      end
      zero_arm = recursive.read_marks(1, 1)
      zero_arm.size.should eq(1)
      zero_arm[0].size.should eq(CompactPartWriterW272Fixture::ROWS_PER_MARK)
      w272_assert_literals(zero_arm[0], [nil, nil] of Array(UInt8)?)
      empty_actual = recursive.read_marks(2, 1)[0][0]
      fixture.literal_for(empty_actual).should eq([] of UInt8)

      static_root = CrystalClick::CompactStaticJsonBulkColumnReader.open(
        part_path,
        CompactPartWriterW272Fixture::COLUMN_NAME,
        fixture.declared_json_type,
      )
      static_root.schema_declaration.should eq(fixture.declared_json_type.name)
      static_root.mark_count.should eq(CompactPartWriterW272Fixture::MARK_COUNT)
      static_root.row_count.should eq(CompactPartWriterW272Fixture::ROW_COUNT.to_u64)
      static_root.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
      windows.each do |first_mark, mark_count|
        documents = static_root.read_marks(first_mark, mark_count)
        values = documents.map do |mark|
          mark.map { |document| CrystalClick::StorageColumnValue.object_document(document) }
        end
        w272_assert_marks(values, first_mark, mark_count)
      end
      static_empty_actual = static_root.read_marks(2, 1)[0][0]
      fixture.literal_for(CrystalClick::StorageColumnValue.object_document(static_empty_actual)).should eq([] of UInt8)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
