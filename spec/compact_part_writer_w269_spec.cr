require "./spec_helper"
require "file_utils"
require "./support/compact_part_writer_w269_fixture"

private def w269_write(
  part_path : String,
  columns : Array(CrystalClick::CompactPartColumn),
  mark_format : CrystalClick::CompactMarkFormat,
  discriminator_mode : CrystalClick::CompactVariantDiscriminatorMode,
  limits : CrystalClick::BinaryCodecLimits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
) : String
  CrystalClick::CompactPartWriter.write_uint64_columns(
    part_path,
    CompactPartWriterW269Fixture::KEY_NAME,
    CompactPartWriterW269Fixture::KEYS,
    columns,
    rows_per_mark: CompactPartWriterW269Fixture::ROWS_PER_MARK,
    frame_bytes: CompactPartWriterW269Fixture::FRAME_BYTES,
    limits: limits,
    mark_format: mark_format,
    variant_discriminator_mode: discriminator_mode,
  )
end

private def w269_assert_values(
  actual : Array(CrystalClick::StorageColumnValue),
  expected : Array(CrystalClick::StorageColumnValue),
) : Nil
  actual.size.should eq(expected.size)
  actual.each_with_index do |value, index|
    budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, false)
    CrystalClick::CompactPartValueComparison.storage!(value, expected[index], budget)
  end
end

private def w269_object_prefixes(
  physical : CrystalClick::CompactPartPhysicalContext,
  column_name : String,
  mark_index : Int,
) : Array(CrystalClick::ObjectStructure)
  window = physical.read_window(column_name, mark_index, 1)
  shards = window.granules[0].shards.select do |shard|
    shard.stream_name.try(&.ends_with?(".object_structure")) == true
  end
  shards.map { |shard| CrystalClick::ObjectStructureCodec.decode(shard.bytes) }
end

private def w269_dynamic_prefixes(
  physical : CrystalClick::CompactPartPhysicalContext,
  column_name : String,
  mark_index : Int,
) : Array(CrystalClick::DynamicStructure)
  window = physical.read_window(column_name, mark_index, 1)
  shards = window.granules[0].shards.select do |shard|
    shard.stream_name.try(&.ends_with?(".payload.dynamic_structure")) == true
  end
  shards.map { |shard| CrystalClick::DynamicStructureCodec.decode(shard.bytes) }
end

private def w269_assert_first_prefix(
  physical : CrystalClick::CompactPartPhysicalContext,
  column_name : String,
  expected_object_counts : Array(UInt64),
  expected_versions : Array(UInt64),
  expected_dynamic_counts : Array(Array(UInt64)),
  expected_dynamic_shared : Array(Array(Tuple(String, UInt64))),
) : Nil
  objects = w269_object_prefixes(physical, column_name, 0)
  objects.size.should eq(expected_object_counts.size)
  objects.map { |structure| structure.statistics.not_nil!.count_at(0) }.sort.should eq(expected_object_counts.sort)
  objects.each { |structure| structure.version.should eq(4_u64) }

  dynamics = w269_dynamic_prefixes(physical, column_name, 0)
  dynamics.size.should eq(expected_versions.size)
  dynamics.map(&.version).sort.should eq(expected_versions.sort)
  dynamics.each do |structure|
    expected_index = expected_versions.index(structure.version).not_nil!
    expected_counts = expected_dynamic_counts[expected_index]
    structure.statistics.not_nil!.counts.should eq(expected_counts)
    actual_shared = structure.statistics.not_nil!.shared.map { |entry| {entry.name, entry.count} }.sort_by { |entry| entry[0] }
    expected_shared = expected_dynamic_shared[expected_index].sort_by { |entry| entry[0] }
    actual_shared.should eq(expected_shared)
  end
  nil
end

private def w269_assert_later_prefix(
  physical : CrystalClick::CompactPartPhysicalContext,
  column_name : String,
  mark_index : Int,
  expected_object_count : Int32,
  expected_dynamic_versions : Array(UInt64),
) : Nil
  objects = w269_object_prefixes(physical, column_name, mark_index)
  objects.size.should eq(expected_object_count)
  objects.each do |structure|
    structure.version.should eq(4_u64)
    structure.statistics.should be_nil
  end

  dynamics = w269_dynamic_prefixes(physical, column_name, mark_index)
  dynamics.size.should eq(expected_dynamic_versions.size)
  dynamics.map(&.version).sort.should eq(expected_dynamic_versions.sort)
  dynamics.each do |structure|
    if structure.version == CrystalClick::DynamicStructure::VERSION_V3
      structure.statistics.should be_nil
    else
      statistics = structure.statistics.not_nil!
      statistics.counts.should eq(Array(UInt64).new(structure.canonical_variant_count, 0_u64))
      statistics.shared.should be_empty
    end
  end
  nil
end

describe CrystalClick::CompactPartWriter do
  it "round trips four independent static-JSON site shapes across plain marks and discriminator modes" do
    fixture = CompactPartWriterW269Fixture
    combinations = [
      {CrystalClick::CompactMarkFormat::Mrk3, CrystalClick::CompactVariantDiscriminatorMode::Basic},
      {CrystalClick::CompactMarkFormat::Mrk3, CrystalClick::CompactVariantDiscriminatorMode::Compact},
      {CrystalClick::CompactMarkFormat::Mrk4, CrystalClick::CompactVariantDiscriminatorMode::Basic},
      {CrystalClick::CompactMarkFormat::Mrk4, CrystalClick::CompactVariantDiscriminatorMode::Compact},
    ]

    combinations.each do |mark_format, discriminator_mode|
      suffix = mark_format == CrystalClick::CompactMarkFormat::Mrk3 ? "mrk3" : "mrk4"
      mode_suffix = discriminator_mode == CrystalClick::CompactVariantDiscriminatorMode::Basic ? "basic" : "compact"
      parent = File.tempname("crystal-click-w269-#{suffix}-#{mode_suffix}-")
      part_path = File.join(parent, "all_1_1_0")

      begin
        Dir.mkdir(parent)
        w269_write(part_path, fixture.columns, mark_format, discriminator_mode).should eq(part_path)

        fixture.schemas.each do |column_name, schema|
          reader = CrystalClick::CompactRecursiveJsonColumnReader.open(part_path, column_name, schema)
          reader.mark_count.should eq(CompactPartWriterW269Fixture::MARK_COUNT)
          reader.row_count.should eq(CompactPartWriterW269Fixture::ROW_COUNT.to_u64)
          expected = fixture.rows_for(column_name)

          [
            {0, CompactPartWriterW269Fixture::MARK_COUNT},
            {1, 2},
            {CompactPartWriterW269Fixture::MARK_COUNT - 1, 1},
            {CompactPartWriterW269Fixture::MARK_COUNT, 0},
          ].each do |first_mark, mark_count|
            actual_marks = reader.read_marks(first_mark, mark_count)
            actual_marks.size.should eq(mark_count)
            expected_start = first_mark * CompactPartWriterW269Fixture::ROWS_PER_MARK
            expected_count = mark_count * CompactPartWriterW269Fixture::ROWS_PER_MARK
            expected_rows = expected[expected_start, expected_count]
            actual_rows = actual_marks.flatten
            w269_assert_values(actual_rows, expected_rows)
          end

          reader.read_marks(reader.mark_count, 0).should be_empty
          if column_name == CompactPartWriterW269Fixture::ARRAY_COLUMN
            reader.read_marks(1, 1)[0][0].array_values.should be_empty
          elsif column_name == CompactPartWriterW269Fixture::TAGGED_COLUMN
            reader.read_marks(1, 1)[0][0].array_values.size.should eq(2)
          end
        end

        physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
        physical.mode.should eq(mark_format)
        physical.row_count.should eq(CompactPartWriterW269Fixture::ROW_COUNT.to_u64)
        physical.granule_count.should eq(CompactPartWriterW269Fixture::MARK_COUNT)

        if mark_format == CrystalClick::CompactMarkFormat::Mrk4
          # Each first-prefix Object structure and Dynamic roster is caller-owned
          # sample context, not a mark-zero or whole-part census. The right Tuple
          # site's untyped payload starts absent but still gets its supplied prefix.
          w269_assert_first_prefix(
            physical,
            CompactPartWriterW269Fixture::ROOT_COLUMN,
            [3_u64],
            [CrystalClick::DynamicStructure::VERSION_V1],
            [[1_u64, 1_u64, 1_u64]] of Array(UInt64),
            [[{"Bool", 1_u64}] of Tuple(String, UInt64)] of Array(Tuple(String, UInt64)),
          )
          w269_assert_first_prefix(
            physical,
            CompactPartWriterW269Fixture::ARRAY_COLUMN,
            [1_u64],
            [CrystalClick::DynamicStructure::VERSION_V2],
            [[0_u64, 1_u64, 0_u64]] of Array(UInt64),
            [[] of Tuple(String, UInt64)] of Array(Tuple(String, UInt64)),
          )
          w269_assert_first_prefix(
            physical,
            CompactPartWriterW269Fixture::TAGGED_COLUMN,
            [1_u64],
            [CrystalClick::DynamicStructure::VERSION_V3],
            [[0_u64, 1_u64, 0_u64]] of Array(UInt64),
            [[] of Tuple(String, UInt64)] of Array(Tuple(String, UInt64)),
          )
          w269_assert_first_prefix(
            physical,
            CompactPartWriterW269Fixture::PAIR_COLUMN,
            [0_u64, 1_u64],
            [CrystalClick::DynamicStructure::VERSION_V1, CrystalClick::DynamicStructure::VERSION_V2],
            [[0_u64, 1_u64, 0_u64], [0_u64, 0_u64, 0_u64]] of Array(UInt64),
            [
              [] of Tuple(String, UInt64),
              [] of Tuple(String, UInt64),
            ] of Array(Tuple(String, UInt64)),
          )

          later_prefix_specs = [
            {CompactPartWriterW269Fixture::ROOT_COLUMN, 1_i32, [CrystalClick::DynamicStructure::VERSION_V1] of UInt64},
            {CompactPartWriterW269Fixture::ARRAY_COLUMN, 1_i32, [CrystalClick::DynamicStructure::VERSION_V2] of UInt64},
            {CompactPartWriterW269Fixture::TAGGED_COLUMN, 1_i32, [CrystalClick::DynamicStructure::VERSION_V3] of UInt64},
            {
              CompactPartWriterW269Fixture::PAIR_COLUMN,
              2_i32,
              [CrystalClick::DynamicStructure::VERSION_V1, CrystalClick::DynamicStructure::VERSION_V2] of UInt64,
            },
          ] of Tuple(String, Int32, Array(UInt64))
          later_prefix_specs.each do |column_name, object_count, dynamic_versions|
            (1...CompactPartWriterW269Fixture::MARK_COUNT).each do |mark_index|
              # Object V4 later prefixes omit statistics. Dynamic V1/V2 retain
              # their canonical roster with zero counts; V3 omits statistics.
              w269_assert_later_prefix(physical, column_name, mark_index, object_count, dynamic_versions)
            end
          end

          physical.physical_roster.size.should be > fixture.schemas.size
          fixture.schemas.each_key do |column_name|
            window = physical.read_window(column_name, 0, CompactPartWriterW269Fixture::MARK_COUNT)
            window.granules.size.should eq(CompactPartWriterW269Fixture::MARK_COUNT)
          end
        end
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end
end
