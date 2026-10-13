require "./spec_helper"
require "file_utils"
require "json"
require "./support/compact_part_writer_w273_fixture"

private def w273_write(
  part_path : String,
  column : CrystalClick::CompactPartColumn,
  mark_format : CrystalClick::CompactMarkFormat,
  discriminator_mode : CrystalClick::CompactVariantDiscriminatorMode,
) : String
  CrystalClick::CompactPartWriter.write_uint64_columns(
    part_path,
    CompactPartWriterW273Fixture::KEY_NAME,
    CompactPartWriterW273Fixture::KEYS,
    [column] of CrystalClick::CompactPartColumn,
    rows_per_mark: CompactPartWriterW273Fixture::ROWS_PER_MARK,
    frame_bytes: CompactPartWriterW273Fixture::FRAME_BYTES,
    mark_format: mark_format,
    variant_discriminator_mode: discriminator_mode,
  )
end

private def w273_assert_rows(
  actual : Array(CrystalClick::StorageColumnValue),
  depth : Int,
  expected_literals : Array(String?),
) : Nil
  fixture = CompactPartWriterW273Fixture
  actual.size.should eq(expected_literals.size)
  actual.each_with_index do |value, index|
    expected = expected_literals[index]
    fixture.literal_for(value, depth).should eq(expected)

    payload = value.object_document.value_for(CompactPartWriterW273Fixture::PAYLOAD_PATH)
    payload.type.should eq(fixture.dynamic_type)
    if expected
      payload.is_null?.should be_false
      payload.child_count.should eq(1)
      payload.child_at(0).type.should eq(fixture.array_chain_type(depth))
    else
      payload.is_null?.should be_true
      payload.child_count.should eq(0)
    end
  end
  nil
end

private def w273_assert_marks(
  actual : Array(Array(CrystalClick::StorageColumnValue)),
  first_mark : Int,
  mark_count : Int,
  depth : Int,
  expected_literals : Array(String?),
  expected_actual_counts : Array(Int32),
  expected_size_vectors : Array(Array(Array(Int32))),
  expected_level_counts : Array(Array(Int32)),
  expected_leaf_counts : Array(Int32),
) : Nil
  rows_per_mark = CompactPartWriterW273Fixture::ROWS_PER_MARK
  actual.size.should eq(mark_count)
  actual.each { |mark_rows| mark_rows.size.should eq(rows_per_mark) }

  row_start = first_mark * rows_per_mark
  row_count = mark_count * rows_per_mark
  w273_assert_rows(actual.flatten, depth, expected_literals[row_start, row_count])

  actual.each_with_index do |mark_rows, offset|
    fixture = CompactPartWriterW273Fixture
    fixture.array_size_vectors_for_mark(mark_rows, depth).should eq(
      expected_size_vectors[first_mark + offset],
    )
  end

  actual.map do |mark_rows|
    mark_rows.count do |row|
      !CompactPartWriterW273Fixture.literal_for(row, depth).nil?
    end
  end.should eq(expected_actual_counts[first_mark, mark_count])

  observed_level_counts = Array(Array(Int32)).new(depth) { [] of Int32 }
  observed_leaf_counts = [] of Int32
  actual.each do |mark_rows|
    vectors = CompactPartWriterW273Fixture.array_size_vectors_for_mark(mark_rows, depth)
    depth.times { |level| observed_level_counts[level] << vectors[level].sum }
    observed_leaf_counts << vectors[depth - 1].sum
  end
  expected_level_counts.each_with_index do |counts, level|
    observed_level_counts[level].should eq(counts[first_mark, mark_count])
  end
  observed_leaf_counts.should eq(expected_leaf_counts[first_mark, mark_count])
  nil
end

private def w273_assert_mrk4_prefixes(
  part_path : String,
  depth : Int,
  expected_actual_counts : Array(Int32),
) : Nil
  fixture = CompactPartWriterW273Fixture
  physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
  physical.mode.should eq(CrystalClick::CompactMarkFormat::Mrk4)
  expected_total_actuals = expected_actual_counts.sum.to_u64
  CompactPartWriterW273Fixture::MARK_COUNT.times do |mark_index|
    shards = physical.read_window(
      CompactPartWriterW273Fixture::COLUMN_NAME,
      mark_index,
      1,
    ).granules[0].shards
    prefixes = shards.select do |shard|
      shard.stream_name.try(&.ends_with?(".payload.dynamic_structure")) == true
    end.map { |shard| CrystalClick::DynamicStructureCodec.decode(shard.bytes) }
    prefixes.size.should eq(1)
    prefix = prefixes[0]
    prefix.version.should eq(CrystalClick::DynamicStructure::VERSION_V3)
    prefix.types.map(&.name).should eq([fixture.array_chain_type(depth).name])
    if mark_index == 0
      # These V3 counts belong to the selected parent actual arm. The JSON
      # leaf totals are asserted independently in the size-lane schedule.
      prefix.statistics.not_nil!.counts.should eq([expected_total_actuals, 0_u64])
      prefix.statistics.not_nil!.shared.should be_empty
    else
      # Later MAP0 prefixes retain the same arm roster but omit first-prefix
      # statistics, including the all-Dynamic-NULL mark.
      prefix.statistics.should be_nil
    end
  end
  nil
end

private def w273_check_public_case(
  depth : Int,
  mark_format : CrystalClick::CompactMarkFormat,
  discriminator_mode : CrystalClick::CompactVariantDiscriminatorMode,
) : Nil
  fixture = CompactPartWriterW273Fixture
  column = fixture.column(depth)
  expected_literals = fixture.expected_literals(depth)
  expected_actual_counts = fixture.expected_mark_actual_counts(depth)
  expected_size_vectors = fixture.expected_mark_array_size_vectors(depth)
  expected_level_counts = fixture.expected_mark_array_element_counts(depth)
  expected_leaf_counts = fixture.expected_mark_json_element_counts(depth)

  parent = File.tempname("crystal-click-w273-public-")
  part_path = File.join(parent, "all_1_1_0")
  begin
    Dir.mkdir(parent)
    w273_write(part_path, column, mark_format, discriminator_mode).should eq(part_path)
    File.exists?(part_path).should be_true
    if mark_format == CrystalClick::CompactMarkFormat::Mrk4
      w273_assert_mrk4_prefixes(part_path, depth, expected_actual_counts)
    end

    windows = [
      {0, CompactPartWriterW273Fixture::MARK_COUNT},
      {1, 2},
      {1, 1},
      {2, 1},
      {3, 1},
      {CompactPartWriterW273Fixture::MARK_COUNT, 0},
    ]
    recursive = CrystalClick::CompactRecursiveJsonColumnReader.open(
      part_path,
      CompactPartWriterW273Fixture::COLUMN_NAME,
      fixture.schema,
    )
    recursive.schema_declaration.should eq(fixture.schema.declaration)
    recursive.mark_count.should eq(CompactPartWriterW273Fixture::MARK_COUNT)
    recursive.row_count.should eq(CompactPartWriterW273Fixture::ROW_COUNT.to_u64)
    recursive.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
    windows.each do |first_mark, count|
      w273_assert_marks(
        recursive.read_marks(first_mark, count),
        first_mark,
        count,
        depth,
        expected_literals,
        expected_actual_counts,
        expected_size_vectors,
        expected_level_counts,
        expected_leaf_counts,
      )
    end
    recursive.read_marks(CompactPartWriterW273Fixture::MARK_COUNT, 0).should eq(
      [] of Array(CrystalClick::StorageColumnValue),
    )
    empty_mark = recursive.read_marks(2, 1)[0]
    fixture.literal_for(empty_mark[0], depth).should eq("[]")
    fixture.literal_for(empty_mark[1], depth).should eq("[[]]")

    static_root = CrystalClick::CompactStaticJsonBulkColumnReader.open(
      part_path,
      CompactPartWriterW273Fixture::COLUMN_NAME,
      fixture.declared_json_type,
    )
    static_root.schema_declaration.should eq(fixture.declared_json_type.name)
    static_root.mark_count.should eq(CompactPartWriterW273Fixture::MARK_COUNT)
    static_root.row_count.should eq(CompactPartWriterW273Fixture::ROW_COUNT.to_u64)
    static_root.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
    windows.each do |first_mark, count|
      values = static_root.read_marks(first_mark, count).map do |mark_rows|
        mark_rows.map { |document| CrystalClick::StorageColumnValue.object_document(document) }
      end
      w273_assert_marks(
        values,
        first_mark,
        count,
        depth,
        expected_literals,
        expected_actual_counts,
        expected_size_vectors,
        expected_level_counts,
        expected_leaf_counts,
      )
    end
    static_root.read_marks(CompactPartWriterW273Fixture::MARK_COUNT, 0).should eq(
      [] of Array(CrystalClick::ObjectDocument),
    )
    static_empty_mark = static_root.read_marks(2, 1)[0]
    fixture.literal_for(CrystalClick::StorageColumnValue.object_document(static_empty_mark[0]), depth).should eq("[]")
    fixture.literal_for(CrystalClick::StorageColumnValue.object_document(static_empty_mark[1]), depth).should eq("[[]]")
  ensure
    FileUtils.rm_rf(parent)
  end
  nil
end

private def w273_depth_four_plan(
  depth : Int,
) : Tuple(
  CrystalClick::BinaryDataType,
  CrystalClick::ObjectDocumentPlan,
  CrystalClick::CompactJsonWriteContext,
  Hash(String, Array(Tuple(CrystalClick::BinaryDynamicJsonLeafKey, CrystalClick::ObjectDocumentPlan))),
)
  fixture = CompactPartWriterW273Fixture
  actual_type = fixture.array_chain_type(depth)
  actuals = CrystalClick::DynamicStructure.new(
    [actual_type] of CrystalClick::BinaryDataType,
    CrystalClick::StructureStatistics.new(
      [5_u64, 0_u64] of UInt64,
      [] of CrystalClick::StructureStatistic,
    ),
    version: CrystalClick::DynamicStructure::VERSION_V3,
  )
  child_plan = fixture.json_bindings(2)[CompactPartWriterW273Fixture::PAYLOAD_PATH][0][1]
  leaf_key = CrystalClick::BinaryDynamicJsonLeafKey.new(
    CompactPartWriterW273Fixture::SITE_PATH,
    actuals.canonical_index_for(actual_type),
    Array(Int32).new(depth) { 0_i32 },
  )
  bindings = {
    CompactPartWriterW273Fixture::PAYLOAD_PATH =>
      ([{leaf_key, child_plan}] of Tuple(CrystalClick::BinaryDynamicJsonLeafKey, CrystalClick::ObjectDocumentPlan)),
  } of String => Array(Tuple(CrystalClick::BinaryDynamicJsonLeafKey, CrystalClick::ObjectDocumentPlan))
  base = fixture.object_plan(2)
  plan = CrystalClick::ObjectDocumentPlan.new(
    base.structures,
    base.typed_paths,
    {CompactPartWriterW273Fixture::PAYLOAD_PATH => actuals} of String => CrystalClick::DynamicStructure,
    typed_dynamic_json_object_leaf_plans: bindings,
  )
  context = CrystalClick::CompactJsonWriteContext.new(
    {CompactPartWriterW273Fixture::SITE_PATH => plan} of String => CrystalClick::ObjectDocumentPlan,
  )
  {actual_type, plan, context, bindings}
end

private def w273_depth_four_value(
  remaining_depth : Int,
  node : JSON::Any,
) : CrystalClick::BinaryValue
  fixture = CompactPartWriterW273Fixture
  unless 1 <= remaining_depth <= CrystalClick::BinaryCodecLimits::DEFAULT_MAX_DEPTH
    raise ArgumentError.new("W273 recursive Array value depth is outside the bounded fixture range")
  end

  children = Array(CrystalClick::BinaryValue).new(node.as_a.size)
  node.as_a.each do |child|
    if remaining_depth == 1
      byte = child.as_i.to_u8
      cell = CrystalClick::BinaryValue.fixed(fixture.uint8_type, Bytes[byte])
      row = CrystalClick::BinaryJsonRow.new(
        fixture.json_type,
        [{CompactPartWriterW273Fixture::VALUE_PATH, cell}] of Tuple(String, CrystalClick::BinaryValue),
      )
      children << CrystalClick::BinaryValue.json(fixture.json_type, row)
    else
      children << w273_depth_four_value(remaining_depth - 1, child)
    end
  end
  actual_type = fixture.json_type
  remaining_depth.times do
    actual_type = CrystalClick::BinaryDataType.array(actual_type)
  end
  CrystalClick::BinaryValue.array(actual_type, children)
end

private def w273_depth_four_rows(
  depth : Int,
  literals : Array(String?),
) : Array(CrystalClick::StorageColumnValue)
  fixture = CompactPartWriterW273Fixture
  literals.map do |literal|
    actual = literal.try do |source|
      w273_depth_four_value(depth, JSON.parse(source))
    end
    payload = CrystalClick::BinaryValue.dynamic(fixture.dynamic_type, actual)
    document = CrystalClick::ObjectDocument.new(
      {CompactPartWriterW273Fixture::PAYLOAD_PATH => payload} of String => CrystalClick::BinaryValue,
    )
    CrystalClick::StorageColumnValue.object_document(document)
  end
end

private def w273_depth_four_granules(
  rows : Array(CrystalClick::StorageColumnValue),
) : Array(Array(CrystalClick::StorageColumnValue))
  output = Array(Array(CrystalClick::StorageColumnValue)).new(CompactPartWriterW273Fixture::MARK_COUNT)
  CompactPartWriterW273Fixture::MARK_COUNT.times do |mark|
    output << rows[mark * CompactPartWriterW273Fixture::ROWS_PER_MARK, CompactPartWriterW273Fixture::ROWS_PER_MARK]
  end
  output
end

private def w273_depth_four_common_control!(
  plan : CrystalClick::ObjectDocumentPlan,
  bindings : Hash(String, Array(Tuple(CrystalClick::BinaryDynamicJsonLeafKey, CrystalClick::ObjectDocumentPlan))),
  rows : Array(CrystalClick::StorageColumnValue),
  literals : Array(String?),
  size_vectors : Array(Array(Array(Int32))),
  depth : Int,
) : Nil
  fixture = CompactPartWriterW273Fixture
  documents = w273_depth_four_granules(rows).map { |mark_rows| mark_rows.map(&.object_document) }
  streams = CrystalClick::ObjectDocumentCodec.encode(plan, documents)
  decoded = CrystalClick::ObjectDocumentCodec.decode(
    fixture.schema.object_schema.typed_paths,
    streams,
    typed_dynamic_json_object_leaf_plans: bindings,
  )
  decoded.size.should eq(CompactPartWriterW273Fixture::MARK_COUNT)
  decoded.each_with_index do |mark_rows, mark_index|
    mark_rows.size.should eq(CompactPartWriterW273Fixture::ROWS_PER_MARK)
    storage_rows = mark_rows.map { |document| CrystalClick::StorageColumnValue.object_document(document) }
    fixture.array_size_vectors_for_mark(storage_rows, depth).should eq(size_vectors[mark_index])
    mark_rows.each_with_index do |document, row_index|
      row = CrystalClick::StorageColumnValue.object_document(document)
      fixture.literal_for(row, depth).should eq(literals[mark_index * 2 + row_index])
    end
  end
  nil
end

describe CrystalClick::CompactPartWriter do
  it "round trips nested typed-Dynamic Array chains of depths two and three across mark and discriminator modes" do
    combinations = [
      {CrystalClick::CompactMarkFormat::Mrk3, CrystalClick::CompactVariantDiscriminatorMode::Basic},
      {CrystalClick::CompactMarkFormat::Mrk3, CrystalClick::CompactVariantDiscriminatorMode::Compact},
      {CrystalClick::CompactMarkFormat::Mrk4, CrystalClick::CompactVariantDiscriminatorMode::Basic},
      {CrystalClick::CompactMarkFormat::Mrk4, CrystalClick::CompactVariantDiscriminatorMode::Compact},
    ]
    [2, 3].each do |depth|
      # Keep the common control as an explicit prerequisite for each physical
      # configuration, so admission failures are not confused with bad input.
      CompactPartWriterW273Fixture.common_codec_roundtrip!(depth)
      combinations.each do |mark_format, discriminator_mode|
        w273_check_public_case(depth, mark_format, discriminator_mode)
      end
    end
  end

  it "uses a generic bounded descriptor/value walk beyond the two frozen W273 row depths" do
    fixture = CompactPartWriterW273Fixture
    depth = 4
    actual_type, plan, context, bindings = w273_depth_four_plan(depth)
    actual_type.should eq(fixture.array_chain_type(depth))
    leaf_key = bindings[CompactPartWriterW273Fixture::PAYLOAD_PATH][0][0]
    leaf_key.descriptor_child_path.should eq([0_i32, 0_i32, 0_i32, 0_i32])

    literals = [
      "[[[[11,12],[]],[[13]]]]",
      nil,
      nil,
      nil,
      "[]",
      "[[]]",
      "[[[]]]",
      "[[[[81]],[[82,83],[]],[]]]",
    ] of String?
    size_vectors = [
      [
        [1] of Int32,
        [2] of Int32,
        [2, 1] of Int32,
        [2, 0, 1] of Int32,
      ] of Array(Int32),
      [
        [] of Int32,
        [] of Int32,
        [] of Int32,
        [] of Int32,
      ] of Array(Int32),
      [
        [0, 1] of Int32,
        [0] of Int32,
        [] of Int32,
        [] of Int32,
      ] of Array(Int32),
      [
        [1, 1] of Int32,
        [1, 3] of Int32,
        [0, 1, 2, 0] of Int32,
        [1, 2, 0] of Int32,
      ] of Array(Int32),
    ] of Array(Array(Int32))
    level_counts = [
      [1, 0, 1, 2],
      [2, 0, 0, 4],
      [3, 0, 0, 3],
      [3, 0, 0, 3],
    ] of Array(Int32)
    leaf_counts = [3, 0, 0, 3]
    rows = w273_depth_four_rows(depth, literals)
    w273_depth_four_common_control!(plan, bindings, rows, literals, size_vectors, depth)

    column = CrystalClick::CompactPartColumn.json(
      CompactPartWriterW273Fixture::COLUMN_NAME,
      fixture.schema,
      w273_depth_four_granules(rows),
      context,
    )
    parent = File.tempname("crystal-click-w273-depth-four-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      w273_write(
        part_path,
        column,
        CrystalClick::CompactMarkFormat::Mrk4,
        CrystalClick::CompactVariantDiscriminatorMode::Compact,
      ).should eq(part_path)
      w273_assert_mrk4_prefixes(part_path, depth, [1, 0, 2, 2])

      recursive = CrystalClick::CompactRecursiveJsonColumnReader.open(
        part_path,
        CompactPartWriterW273Fixture::COLUMN_NAME,
        fixture.schema,
      )
      w273_assert_marks(
        recursive.read_marks(0, CompactPartWriterW273Fixture::MARK_COUNT),
        0,
        CompactPartWriterW273Fixture::MARK_COUNT,
        depth,
        literals,
        [1, 0, 2, 2],
        size_vectors,
        level_counts,
        leaf_counts,
      )
      recursive.read_marks(CompactPartWriterW273Fixture::MARK_COUNT, 0).should eq(
        [] of Array(CrystalClick::StorageColumnValue),
      )

      static_root = CrystalClick::CompactStaticJsonBulkColumnReader.open(
        part_path,
        CompactPartWriterW273Fixture::COLUMN_NAME,
        fixture.declared_json_type,
      )
      static_marks = static_root.read_marks(0, CompactPartWriterW273Fixture::MARK_COUNT).map do |mark_rows|
        mark_rows.map { |document| CrystalClick::StorageColumnValue.object_document(document) }
      end
      w273_assert_marks(
        static_marks,
        0,
        CompactPartWriterW273Fixture::MARK_COUNT,
        depth,
        literals,
        [1, 0, 2, 2],
        size_vectors,
        level_counts,
        leaf_counts,
      )
      static_root.read_marks(CompactPartWriterW273Fixture::MARK_COUNT, 0).should eq(
        [] of Array(CrystalClick::ObjectDocument),
      )

      zero_actual_mark = recursive.read_marks(1, 1)[0]
      zero_actual_mark.size.should eq(CompactPartWriterW273Fixture::ROWS_PER_MARK)
      zero_actual_mark.each do |row|
        row.object_document.value_for(CompactPartWriterW273Fixture::PAYLOAD_PATH).is_null?.should be_true
      end
      empty_actual_mark = static_root.read_marks(2, 1)[0]
      fixture.literal_for(CrystalClick::StorageColumnValue.object_document(empty_actual_mark[0]), depth).should eq("[]")
      fixture.literal_for(CrystalClick::StorageColumnValue.object_document(empty_actual_mark[1]), depth).should eq("[[]]")
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
