require "./spec_helper"
require "file_utils"
require "../scripts/support/compact_part_writer_w271_native_fixture"

private def w271_inferred_write(
  part_path : String,
  mark_format : CrystalClick::CompactMarkFormat,
  discriminator_mode : CrystalClick::CompactVariantDiscriminatorMode,
) : String
  fixture = CompactPartWriterW271NativeFixture
  CrystalClick::CompactPartWriter.write_uint64_columns(
    part_path,
    CompactPartWriterW271NativeFixture::KEY_NAME,
    CompactPartWriterW271NativeFixture::KEYS,
    [fixture.column] of CrystalClick::CompactPartColumn,
    rows_per_mark: CompactPartWriterW271NativeFixture::ROWS_PER_MARK,
    frame_bytes: CompactPartWriterW271NativeFixture::FRAME_BYTES,
    mark_format: mark_format,
    variant_discriminator_mode: discriminator_mode,
  )
end

private def w271_inferred_assert_values(
  actual : Array(CrystalClick::StorageColumnValue),
  expected : Array(Int64?),
) : Nil
  actual.size.should eq(expected.size)
  fixture = CompactPartWriterW271NativeFixture

  actual.each_with_index do |value, index|
    value.object?.should be_true
    document = value.object_document
    payload = document.value_for(CompactPartWriterW271NativeFixture::PAYLOAD_PATH)
    payload.type.should eq(fixture.dynamic_type)
    fixture.literal_for(document).should eq(expected[index])

    if literal = expected[index]
      payload.is_null?.should be_false
      payload.child_count.should eq(1)
      json = payload.child_at(0)
      json.type.should eq(fixture.json_type)
      json.json_row.path_count.should eq(1)
      cell = json.json_row.value_for(CompactPartWriterW271NativeFixture::VALUE_PATH).not_nil!
      cell.type.should eq(fixture.int64_type)
      cell.as_int64.should eq(literal)
    else
      payload.is_null?.should be_true
      payload.child_count.should eq(0)
    end
  end
  nil
end

private def w271_inferred_assert_window(
  actual_marks : Array(Array(CrystalClick::StorageColumnValue)),
  first_mark : Int32,
  mark_count : Int32,
) : Nil
  fixture = CompactPartWriterW271NativeFixture
  actual_marks.size.should eq(mark_count)
  actual_marks.each do |mark|
    mark.size.should eq(CompactPartWriterW271NativeFixture::ROWS_PER_MARK)
  end

  first_row = first_mark * CompactPartWriterW271NativeFixture::ROWS_PER_MARK
  row_count = mark_count * CompactPartWriterW271NativeFixture::ROWS_PER_MARK
  expected = fixture.expected_literals[first_row, row_count]
  w271_inferred_assert_values(actual_marks.flatten, expected)

  actual_counts = actual_marks.map do |mark|
    mark.count { |value| !fixture.literal_for(value.object_document).nil? }
  end
  actual_counts.should eq(fixture.expected_mark_arm_counts[first_mark, mark_count])
  nil
end

describe CrystalClick::CompactPartWriter do
  it "reads inferred Dynamic JSON paths with complete child statistics across Compact marks" do
    fixture = CompactPartWriterW271NativeFixture

    # This is the common-codec validity control. The child JSON descriptor has
    # no typed `value` path: its child Object plan carries an inferred Dynamic
    # path instead, unlike the frozen UInt8 baseline fixture.
    fixture.common_codec_roundtrip!
    fixture.json_type.json_type.not_nil!.typed_paths.should be_empty
    child_plan = fixture.json_bindings[CompactPartWriterW271NativeFixture::PAYLOAD_PATH][0][1]
    child_plan.typed_paths.should be_empty
    child_object = child_plan.structures.object
    child_object.dynamic_path_count.should eq(1)
    child_object.dynamic_path_at(0).should eq(CompactPartWriterW271NativeFixture::VALUE_PATH)
    child_object.statistics.not_nil!.counts.should eq([4_u64])
    inferred = child_plan.structures.dynamic_for(CompactPartWriterW271NativeFixture::VALUE_PATH)
    inferred.type_count.should eq(1)
    inferred.type_at(0).name.should eq("Int64")
    inferred.statistics.not_nil!.counts.should eq([4_u64, 0_u64])
    fixture.actuals.statistics.not_nil!.counts.should eq([4_u64, 0_u64])

    combinations = [
      {CrystalClick::CompactMarkFormat::Mrk3, CrystalClick::CompactVariantDiscriminatorMode::Basic},
      {CrystalClick::CompactMarkFormat::Mrk3, CrystalClick::CompactVariantDiscriminatorMode::Compact},
      {CrystalClick::CompactMarkFormat::Mrk4, CrystalClick::CompactVariantDiscriminatorMode::Basic},
      {CrystalClick::CompactMarkFormat::Mrk4, CrystalClick::CompactVariantDiscriminatorMode::Compact},
    ]
    windows = [
      {0, CompactPartWriterW271NativeFixture::MARK_COUNT},
      {1, 2},
      {CompactPartWriterW271NativeFixture::MARK_COUNT - 1, 1},
      {1, 1},
      {CompactPartWriterW271NativeFixture::MARK_COUNT, 0},
    ]

    combinations.each do |mark_format, discriminator_mode|
      mark_suffix = mark_format.mrk3? ? "mrk3" : "mrk4"
      mode_suffix = discriminator_mode == CrystalClick::CompactVariantDiscriminatorMode::Basic ? "basic" : "compact"
      parent = File.tempname("crystal-click-w271-inferred-#{mark_suffix}-#{mode_suffix}-")
      part_path = File.join(parent, "all_1_1_0")
      begin
        Dir.mkdir(parent)
        w271_inferred_write(part_path, mark_format, discriminator_mode).should eq(part_path)
        File.exists?(part_path).should be_true

        recursive = CrystalClick::CompactRecursiveJsonColumnReader.open(
          part_path,
          CompactPartWriterW271NativeFixture::COLUMN_NAME,
          fixture.schema,
        )
        recursive.schema_declaration.should eq(fixture.schema.declaration)
        recursive.mark_count.should eq(CompactPartWriterW271NativeFixture::MARK_COUNT)
        recursive.row_count.should eq(CompactPartWriterW271NativeFixture::ROW_COUNT.to_u64)
        recursive.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
        windows.each do |first_mark, mark_count|
          w271_inferred_assert_window(recursive.read_marks(first_mark, mark_count), first_mark, mark_count)
        end
        recursive.read_marks(recursive.mark_count, 0).should be_empty

        static_root = CrystalClick::CompactStaticJsonBulkColumnReader.open(
          part_path,
          CompactPartWriterW271NativeFixture::COLUMN_NAME,
          fixture.declared_json_type,
        )
        static_root.schema_declaration.should eq(fixture.declared_json_type.name)
        static_root.mark_count.should eq(CompactPartWriterW271NativeFixture::MARK_COUNT)
        static_root.row_count.should eq(CompactPartWriterW271NativeFixture::ROW_COUNT.to_u64)
        static_root.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
        windows.each do |first_mark, mark_count|
          documents = static_root.read_marks(first_mark, mark_count)
          object_marks = documents.map do |mark|
            mark.map { |document| CrystalClick::StorageColumnValue.object_document(document) }
          end
          w271_inferred_assert_window(object_marks, first_mark, mark_count)
        end
        static_root.read_marks(static_root.mark_count, 0).should be_empty
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end
end
