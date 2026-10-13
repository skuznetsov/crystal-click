require "./spec_helper"
require "file_utils"
require "./support/compact_part_writer_w271_fixture"

private def w271_write(
  part_path : String,
  mark_format : CrystalClick::CompactMarkFormat,
  discriminator_mode : CrystalClick::CompactVariantDiscriminatorMode,
) : String
  fixture = CompactPartWriterW271Fixture
  CrystalClick::CompactPartWriter.write_uint64_columns(
    part_path,
    CompactPartWriterW271Fixture::KEY_NAME,
    CompactPartWriterW271Fixture::KEYS,
    [fixture.column] of CrystalClick::CompactPartColumn,
    rows_per_mark: CompactPartWriterW271Fixture::ROWS_PER_MARK,
    frame_bytes: CompactPartWriterW271Fixture::FRAME_BYTES,
    mark_format: mark_format,
    variant_discriminator_mode: discriminator_mode,
  )
end

private def w271_assert_literals(
  actual : Array(CrystalClick::StorageColumnValue),
  expected : Array(UInt8?),
) : Nil
  actual.size.should eq(expected.size)
  fixture = CompactPartWriterW271Fixture
  actual.each_with_index do |value, index|
    fixture.literal_for(value).should eq(expected[index])
    payload = value.object_document.value_for(CompactPartWriterW271Fixture::PAYLOAD_PATH)
    payload.type.should eq(fixture.dynamic_type)
    if literal = expected[index]
      payload.is_null?.should be_false
      payload.child_count.should eq(1)
      json = payload.child_at(0)
      json.type.should eq(fixture.json_type)
      cell = json.json_row.value_for(CompactPartWriterW271Fixture::VALUE_PATH).not_nil!
      cell.type.should eq(fixture.uint8_type)
      cell.byte_at(0).should eq(literal)
    else
      payload.is_null?.should be_true
    end
  end
  nil
end

private def w271_assert_raw_prefixes(
  part_path : String,
  mark_format : CrystalClick::CompactMarkFormat,
) : Nil
  return unless mark_format.mrk4?

  fixture = CompactPartWriterW271Fixture
  physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
  physical.mode.should eq(mark_format)
  physical.row_count.should eq(CompactPartWriterW271Fixture::ROW_COUNT.to_u64)
  physical.granule_count.should eq(CompactPartWriterW271Fixture::MARK_COUNT)

  CompactPartWriterW271Fixture::MARK_COUNT.times do |mark_index|
    window = physical.read_window(CompactPartWriterW271Fixture::COLUMN_NAME, mark_index, 1)
    shards = window.granules[0].shards
    object_prefixes = shards.select do |shard|
      shard.stream_name.try(&.ends_with?(".object_structure")) == true
    end.map { |shard| CrystalClick::ObjectStructureCodec.decode(shard.bytes) }
    object_prefixes.should_not be_empty
    object_prefixes.each do |structure|
      structure.version.should eq(4_u64)
      structure.bucket_count.should eq(1_u64)
      if mark_index == 0
        structure.statistics.should_not be_nil
      else
        structure.statistics.should be_nil
      end
    end

    dynamic_prefixes = shards.select do |shard|
      shard.stream_name.try(&.ends_with?(".payload.dynamic_structure")) == true
    end.map { |shard| CrystalClick::DynamicStructureCodec.decode(shard.bytes) }
    dynamic_prefixes.size.should eq(1)
    dynamic = dynamic_prefixes[0]
    dynamic.version.should eq(CrystalClick::DynamicStructure::VERSION_V3)
    dynamic.types.map(&.name).should eq([fixture.json_type.name])
    if mark_index == 0
      dynamic.statistics.not_nil!.counts.should eq([4_u64, 0_u64])
      dynamic.statistics.not_nil!.shared.should be_empty
    else
      # Later V3 MAP0 callbacks keep the actual roster but clear first-prefix
      # statistics; they do not recompute counts from each mark.
      dynamic.statistics.should be_nil
    end
  end
  nil
end

describe CrystalClick::CompactPartWriter do
  it "round trips typed-Dynamic ordinary JSON leaves across plain marks and discriminator modes" do
    fixture = CompactPartWriterW271Fixture
    combinations = [
      {CrystalClick::CompactMarkFormat::Mrk3, CrystalClick::CompactVariantDiscriminatorMode::Basic},
      {CrystalClick::CompactMarkFormat::Mrk3, CrystalClick::CompactVariantDiscriminatorMode::Compact},
      {CrystalClick::CompactMarkFormat::Mrk4, CrystalClick::CompactVariantDiscriminatorMode::Basic},
      {CrystalClick::CompactMarkFormat::Mrk4, CrystalClick::CompactVariantDiscriminatorMode::Compact},
    ]
    windows = [
      {0, CompactPartWriterW271Fixture::MARK_COUNT},
      {1, 2},
      {CompactPartWriterW271Fixture::MARK_COUNT - 1, 1},
      {1, 1},
      {CompactPartWriterW271Fixture::MARK_COUNT, 0},
    ]

    combinations.each do |mark_format, discriminator_mode|
      mark_suffix = mark_format.mrk3? ? "mrk3" : "mrk4"
      mode_suffix = discriminator_mode == CrystalClick::CompactVariantDiscriminatorMode::Basic ? "basic" : "compact"
      parent = File.tempname("crystal-click-w271-#{mark_suffix}-#{mode_suffix}-")
      part_path = File.join(parent, "all_1_1_0")
      begin
        Dir.mkdir(parent)
        w271_write(part_path, mark_format, discriminator_mode).should eq(part_path)
        File.exists?(part_path).should be_true

        recursive = CrystalClick::CompactRecursiveJsonColumnReader.open(
          part_path,
          CompactPartWriterW271Fixture::COLUMN_NAME,
          fixture.schema,
        )
        recursive.schema_declaration.should eq(fixture.schema.declaration)
        recursive.mark_count.should eq(CompactPartWriterW271Fixture::MARK_COUNT)
        recursive.row_count.should eq(CompactPartWriterW271Fixture::ROW_COUNT.to_u64)
        recursive.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
        windows.each do |first_mark, mark_count|
          actual_marks = recursive.read_marks(first_mark, mark_count)
          actual_marks.size.should eq(mark_count)
          expected_row_start = first_mark * CompactPartWriterW271Fixture::ROWS_PER_MARK
          expected_row_count = mark_count * CompactPartWriterW271Fixture::ROWS_PER_MARK
          expected = fixture.expected_literals[expected_row_start, expected_row_count]
          w271_assert_literals(actual_marks.flatten, expected)
          actual_marks.map { |mark| fixture.arm_count(mark) }.should eq(
            fixture.expected_mark_arm_counts[first_mark, mark_count],
          )
        end
        recursive.read_marks(recursive.mark_count, 0).should be_empty
        zero_arm = recursive.read_marks(1, 1)
        zero_arm.size.should eq(1)
        zero_arm[0].size.should eq(CompactPartWriterW271Fixture::ROWS_PER_MARK)
        fixture.arm_count(zero_arm[0]).should eq(0)
        # The zero-arm mark retains both NULL rows and does not shift later
        # literals into its extent.
        w271_assert_literals(zero_arm.flatten, [nil, nil] of UInt8?)
        w271_assert_literals(recursive.read_marks(2, 1).flatten, [51_u8, 61_u8] of UInt8?)

        static_root = CrystalClick::CompactStaticJsonBulkColumnReader.open(
          part_path,
          CompactPartWriterW271Fixture::COLUMN_NAME,
          fixture.declared_json_type,
        )
        static_root.schema_declaration.should eq(fixture.declared_json_type.name)
        static_root.mark_count.should eq(CompactPartWriterW271Fixture::MARK_COUNT)
        static_root.row_count.should eq(CompactPartWriterW271Fixture::ROW_COUNT.to_u64)
        static_root.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
        windows.each do |first_mark, mark_count|
          documents = static_root.read_marks(first_mark, mark_count)
          documents.size.should eq(mark_count)
          object_values = documents.map do |mark|
            mark.map { |document| CrystalClick::StorageColumnValue.object_document(document) }
          end
          expected_row_start = first_mark * CompactPartWriterW271Fixture::ROWS_PER_MARK
          expected_row_count = mark_count * CompactPartWriterW271Fixture::ROWS_PER_MARK
          expected = fixture.expected_literals[expected_row_start, expected_row_count]
          w271_assert_literals(object_values.flatten, expected)
          object_values.map { |mark| fixture.arm_count(mark) }.should eq(
            fixture.expected_mark_arm_counts[first_mark, mark_count],
          )
        end
        static_root.read_marks(static_root.mark_count, 0).should be_empty
        w271_assert_raw_prefixes(part_path, mark_format)
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end
end
