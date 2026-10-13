require "./spec_helper"
require "file_utils"
require "./support/compact_part_writer_w273_fixture"

private alias W273ALeafPlan = Tuple(
  CrystalClick::BinaryDynamicJsonLeafKey,
  CrystalClick::ObjectDocumentPlan,
)

private def w273a_write(
  part_path : String,
  column : CrystalClick::CompactPartColumn,
  mark_format : CrystalClick::CompactMarkFormat = CrystalClick::CompactMarkFormat::Mrk3,
  discriminator_mode : CrystalClick::CompactVariantDiscriminatorMode = CrystalClick::CompactVariantDiscriminatorMode::Compact,
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

private def w273a_bindings(
  actuals : CrystalClick::DynamicStructure,
  actual_type : CrystalClick::BinaryDataType,
  child_path : Array(Int32),
  child_plan : CrystalClick::ObjectDocumentPlan,
) : Hash(String, Array(W273ALeafPlan))
  key = CrystalClick::BinaryDynamicJsonLeafKey.new(
    CompactPartWriterW273Fixture::SITE_PATH,
    actuals.canonical_index_for(actual_type),
    child_path,
  )
  {
    CompactPartWriterW273Fixture::PAYLOAD_PATH => ([{key, child_plan}] of W273ALeafPlan),
  } of String => Array(W273ALeafPlan)
end

private def w273a_plan(
  actuals : CrystalClick::DynamicStructure,
  bindings : Hash(String, Array(W273ALeafPlan)),
) : CrystalClick::ObjectDocumentPlan
  fixture = CompactPartWriterW273Fixture
  base = fixture.object_plan(2)
  CrystalClick::ObjectDocumentPlan.new(
    base.structures,
    base.typed_paths,
    {CompactPartWriterW273Fixture::PAYLOAD_PATH => actuals} of String => CrystalClick::DynamicStructure,
    typed_dynamic_json_object_leaf_plans: bindings,
  )
end

private def w273a_granules(
  rows : Array(CrystalClick::StorageColumnValue),
) : Array(Array(CrystalClick::StorageColumnValue))
  output = Array(Array(CrystalClick::StorageColumnValue)).new(CompactPartWriterW273Fixture::MARK_COUNT)
  CompactPartWriterW273Fixture::MARK_COUNT.times do |mark|
    output << rows[mark * CompactPartWriterW273Fixture::ROWS_PER_MARK, CompactPartWriterW273Fixture::ROWS_PER_MARK]
  end
  output
end

private def w273a_column(
  plan : CrystalClick::ObjectDocumentPlan,
  rows : Array(CrystalClick::StorageColumnValue) = CompactPartWriterW273Fixture.rows(2),
) : CrystalClick::CompactPartColumn
  fixture = CompactPartWriterW273Fixture
  context = CrystalClick::CompactJsonWriteContext.new(
    {CompactPartWriterW273Fixture::SITE_PATH => plan} of String => CrystalClick::ObjectDocumentPlan,
  )
  CrystalClick::CompactPartColumn.json(
    CompactPartWriterW273Fixture::COLUMN_NAME,
    fixture.schema,
    w273a_granules(rows),
    context,
  )
end

private def w273a_expect_constructor_refusal_without_publish(&build : String ->) : Nil
  parent = File.tempname("crystal-click-w273-constructor-refusal-")
  part_path = File.join(parent, "all_1_1_0")
  begin
    Dir.mkdir(parent)
    expect_raises(ArgumentError) { yield part_path }
    File.exists?(part_path).should be_false
    Dir.children(parent).should be_empty
  ensure
    FileUtils.rm_rf(parent)
  end
  nil
end

private def w273a_refuse_without_publish(&write : String -> String) : Nil
  parent = File.tempname("crystal-click-w273-refusal-")
  part_path = File.join(parent, "all_1_1_0")
  begin
    Dir.mkdir(parent)
    expect_raises(CrystalClick::UnsupportedFormatError) { yield part_path }
    File.exists?(part_path).should be_false
    Dir.children(parent).should be_empty
  ensure
    FileUtils.rm_rf(parent)
  end
  nil
end

private def w273a_tuple_column : Tuple(
  CrystalClick::CompactPartColumn,
  CrystalClick::ObjectDocumentPlan,
  Array(CrystalClick::StorageColumnValue),
  Hash(String, Array(W273ALeafPlan)),
  CrystalClick::BinaryDataType,
)
  fixture = CompactPartWriterW273Fixture
  array_type = fixture.array_chain_type(2)
  tuple_type = CrystalClick::BinaryDataType.tuple(
    [array_type] of CrystalClick::BinaryDataType,
  )
  actuals = CrystalClick::DynamicStructure.new(
    [tuple_type] of CrystalClick::BinaryDataType,
    CrystalClick::StructureStatistics.new(
      [4_u64, 0_u64] of UInt64,
      [] of CrystalClick::StructureStatistic,
    ),
    version: CrystalClick::DynamicStructure::VERSION_V3,
  )
  child_plan = fixture.json_bindings(2)[CompactPartWriterW273Fixture::PAYLOAD_PATH][0][1]
  child_path = [0_i32] of Int32
  child_path.concat(fixture.leaf_descriptor_child_path(2))
  bindings = w273a_bindings(actuals, tuple_type, child_path, child_plan)
  plan = w273a_plan(actuals, bindings)

  rows = fixture.rows(2).map do |source|
    source_payload = source.object_document.value_for(CompactPartWriterW273Fixture::PAYLOAD_PATH)
    selected = if source_payload.is_null?
                 nil
               else
                 CrystalClick::BinaryValue.tuple(
                   tuple_type,
                   [source_payload.child_at(0)] of CrystalClick::BinaryValue,
                 )
               end
    payload = CrystalClick::BinaryValue.dynamic(fixture.dynamic_type, selected)
    CrystalClick::StorageColumnValue.object_document(
      CrystalClick::ObjectDocument.new(
        {CompactPartWriterW273Fixture::PAYLOAD_PATH => payload} of String => CrystalClick::BinaryValue,
      ),
    )
  end
  {w273a_column(plan, rows), plan, rows, bindings, tuple_type}
end

private def w273a_common_tuple_control!(
  plan : CrystalClick::ObjectDocumentPlan,
  rows : Array(CrystalClick::StorageColumnValue),
  bindings : Hash(String, Array(W273ALeafPlan)),
  tuple_type : CrystalClick::BinaryDataType,
) : Nil
  fixture = CompactPartWriterW273Fixture
  semantic_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
  documents = w273a_granules(rows).map do |mark_rows|
    mark_rows.map(&.object_document)
  end
  streams = CrystalClick::ObjectDocumentCodec.encode(plan, documents)
  decoded = CrystalClick::ObjectDocumentCodec.decode(
    fixture.schema.object_schema.typed_paths,
    streams,
    typed_dynamic_json_object_leaf_plans: bindings,
  )
  decoded.size.should eq(CompactPartWriterW273Fixture::MARK_COUNT)
  decoded.each_with_index do |mark_rows, mark_index|
    mark_rows.size.should eq(CompactPartWriterW273Fixture::ROWS_PER_MARK)
    mark_rows.each_with_index do |document, row_index|
      source = rows[mark_index * CompactPartWriterW273Fixture::ROWS_PER_MARK + row_index]
      expected = source.object_document.value_for(CompactPartWriterW273Fixture::PAYLOAD_PATH)
      actual = document.value_for(CompactPartWriterW273Fixture::PAYLOAD_PATH)
      actual.type.should eq(fixture.dynamic_type)
      if expected.is_null?
        actual.is_null?.should be_true
      else
        actual.is_null?.should be_false
        actual.child_count.should eq(1)
        actual.child_at(0).type.should eq(tuple_type)
      end
      CrystalClick::CompactPartValueComparison.binary!(actual, expected, semantic_budget)
    end
  end
  nil
end

private def w273a_callback_input(
  depth : Int,
) : CrystalClick::CompactJsonColumnInput
  CompactPartWriterW273Fixture.column(depth).json_input
end

private def w273a_assert_parent_leaf_schedule(
  marks : Array(Array(CrystalClick::StorageColumnValue)),
) : Nil
  fixture = CompactPartWriterW273Fixture
  expected_literals = [
    "[[11,12],[13]]",
    nil,
    nil,
    nil,
    "[]",
    "[[]]",
    nil,
    "[[81],[82,83],[]]",
  ] of String?
  expected_parent_counts = [1, 0, 2, 1]
  expected_size_vectors = [
    [[2] of Int32, [2, 1] of Int32],
    [[] of Int32, [] of Int32],
    [[0, 1] of Int32, [0] of Int32],
    [[3] of Int32, [1, 2, 0] of Int32],
  ] of Array(Array(Int32))
  expected_level_counts = [
    [2, 0, 1, 3],
    [3, 0, 0, 3],
  ] of Array(Int32)
  expected_leaf_counts = [3, 0, 0, 3]

  marks.size.should eq(4)
  marks.each { |mark_rows| mark_rows.size.should eq(2) }
  marks.flatten.each_with_index do |row, index|
    fixture.literal_for(row, 2).should eq(expected_literals[index])
  end
  marks.each_with_index do |mark_rows, mark_index|
    fixture.array_size_vectors_for_mark(mark_rows, 2).should eq(expected_size_vectors[mark_index])
  end
  marks.map do |mark_rows|
    mark_rows.count { |row| !fixture.literal_for(row, 2).nil? }
  end.should eq(expected_parent_counts)

  observed_level_counts = Array(Array(Int32)).new(2) { [] of Int32 }
  observed_leaf_counts = [] of Int32
  marks.each do |mark_rows|
    vectors = fixture.array_size_vectors_for_mark(mark_rows, 2)
    2.times { |level| observed_level_counts[level] << vectors[level].sum }
    observed_leaf_counts << vectors[1].sum
  end
  observed_level_counts.should eq(expected_level_counts)
  observed_leaf_counts.should eq(expected_leaf_counts)
  nil
end

describe "W273 Compact typed-Dynamic Array-chain adversaries" do
  it "recognizes only exact bounded child-zero Array chains ending at JSON" do
    fixture = CompactPartWriterW273Fixture
    direct_json_key = CrystalClick::BinaryDynamicJsonLeafKey.new(
      CompactPartWriterW273Fixture::SITE_PATH,
      0,
      [] of Int32,
    )
    CrystalClick::BinaryArrayJsonLeafShape.wrapper_count?(
      fixture.json_type,
      direct_json_key,
      0,
    ).should eq(0)

    [2, 3, 4].each do |depth|
      actual_type = fixture.array_chain_type(depth)
      child_path = fixture.leaf_descriptor_child_path(depth)
      key = CrystalClick::BinaryDynamicJsonLeafKey.new(
        CompactPartWriterW273Fixture::SITE_PATH,
        0,
        child_path,
      )
      key.descriptor_child_path.should eq(Array(Int32).new(depth) { 0_i32 })
      CrystalClick::BinaryArrayJsonLeafShape.wrapper_count?(actual_type, key, depth).should eq(depth)
      CrystalClick::BinaryArrayJsonLeafShape.wrapper_count?(actual_type, key, depth - 1).should be_nil

      wrong_path = child_path.dup
      wrong_path[0] = 1_i32
      wrong_key = CrystalClick::BinaryDynamicJsonLeafKey.new(
        key.dynamic_site,
        key.canonical_arm_index,
        wrong_path,
      )
      CrystalClick::BinaryArrayJsonLeafShape.wrapper_count?(actual_type, wrong_key, depth).should be_nil

      wrapped_path = [0_i32] of Int32
      wrapped_path.concat(child_path)
      tuple_type = CrystalClick::BinaryDataType.tuple([actual_type] of CrystalClick::BinaryDataType)
      tuple_type.child_at(0).should eq(actual_type)
      tuple_key = CrystalClick::BinaryDynamicJsonLeafKey.new(
        key.dynamic_site,
        key.canonical_arm_index,
        wrapped_path,
      )
      CrystalClick::BinaryArrayJsonLeafShape.wrapper_count?(tuple_type, tuple_key, depth + 1).should be_nil

      nullable_leaf = CrystalClick::BinaryDataType.nullable(fixture.json_type)
      nullable_chain = nullable_leaf
      depth.times { nullable_chain = CrystalClick::BinaryDataType.array(nullable_chain) }
      terminal_type = nullable_chain
      depth.times { terminal_type = terminal_type.child_at(0) }
      terminal_type.tag.should eq(CrystalClick::BinaryDataType::TAG_NULLABLE)
      terminal_type.child_at(0).should eq(fixture.json_type)
      nullable_json_path = child_path.dup
      nullable_json_path << 0_i32
      nullable_json_type = nullable_chain
      nullable_json_path.each do |child_index|
        nullable_json_type = nullable_json_type.child_at(child_index)
      end
      nullable_json_type.should eq(fixture.json_type)
      nullable_key = CrystalClick::BinaryDynamicJsonLeafKey.new(
        key.dynamic_site,
        key.canonical_arm_index,
        nullable_json_path,
      )
      CrystalClick::BinaryArrayJsonLeafShape.wrapper_count?(nullable_chain, nullable_key, depth + 1).should be_nil
    end
  end

  it "rejects wrong, truncated, and overlong exact leaf coordinates before publication" do
    fixture = CompactPartWriterW273Fixture
    child_plan = fixture.json_bindings(2)[CompactPartWriterW273Fixture::PAYLOAD_PATH][0][1]
    [
      [0_i32] of Int32,                 # stops at the intermediate Array
      [1_i32, 0_i32] of Int32,          # wrong first Array child coordinate
      [0_i32, 0_i32, 0_i32] of Int32,   # continues past the JSON leaf
    ].each do |wrong_path|
      w273a_expect_constructor_refusal_without_publish do |_part_path|
        actuals = fixture.actuals(2)
        wrong_bindings = w273a_bindings(
          actuals,
          fixture.array_chain_type(2),
          wrong_path,
          child_plan,
        )
        w273a_plan(actuals, wrong_bindings)
      end
    end
  end

  it "carries every nested Array level into the bound JSON owner's names and depth guard" do
    fixture = CompactPartWriterW273Fixture
    [2, 3].each do |depth|
      input = w273a_callback_input(depth)
      limits = CrystalClick::BinaryCodecLimits.default
      budget = CrystalClick::BinaryCodecBudget.new(limits, true)
      plan = CrystalClick::CompactJsonCallbackPlan.new(
        input,
        limits,
        budget,
        CrystalClick::CompactVariantDiscriminatorMode::Compact,
      )
      object_physical = plan.site_binding(CompactPartWriterW273Fixture::SITE_PATH).physical_plan
      actuals = fixture.actuals(depth)
      key = fixture.json_bindings(depth)[CompactPartWriterW273Fixture::PAYLOAD_PATH][0][0]
      dynamic_physical = object_physical.typed_dynamic(CompactPartWriterW273Fixture::PAYLOAD_PATH)
      dynamic_physical.json_object_site_count.should eq(1)
      site = dynamic_physical.json_object_site(key)
      site.leaf_key.descriptor_child_path.should eq(fixture.leaf_descriptor_child_path(depth))
      site.array_level.should eq(depth.to_u64)
      site.physical_plan.initial_array_level.should eq(depth.to_u64)
      site.binding.canonical_arm_index.should eq(actuals.canonical_index_for(fixture.array_chain_type(depth)))
      dynamic_physical.stream_names.keys.count(&.ends_with?(".sizes")).should eq(depth)

      too_shallow = CrystalClick::BinaryCodecLimits.new(
        site.json_depth - 1,
        CrystalClick::BinaryCodecLimits::DEFAULT_MAX_NODES,
        CrystalClick::BinaryCodecLimits::DEFAULT_MAX_ELEMENTS,
        CrystalClick::BinaryCodecLimits::DEFAULT_MAX_BYTES,
      )
      shallow_budget = CrystalClick::BinaryCodecBudget.new(too_shallow, true)
      error = expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::CompactJsonCallbackPlan.new(
          input,
          too_shallow,
          shallow_budget,
          CrystalClick::CompactVariantDiscriminatorMode::Compact,
        )
      end
      error.message.to_s.should contain("depth")
    end
  end

  it "keeps caller-owned parent-arm V3 counts distinct from JSON leaf element totals" do
    fixture = CompactPartWriterW273Fixture
    fixture.common_codec_roundtrip!(2)
    [1, 0, 2, 1].sum.should eq(4)
    [3, 0, 0, 3].sum.should eq(6)
    fixture.actuals(2).statistics.not_nil!.counts.should eq([4_u64, 0_u64])

    parent = File.tempname("crystal-click-w273-parent-versus-leaf-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      w273a_write(
        part_path,
        fixture.column(2),
        CrystalClick::CompactMarkFormat::Mrk4,
        CrystalClick::CompactVariantDiscriminatorMode::Basic,
      ).should eq(part_path)
      shards = CrystalClick::CompactPartPhysicalContext.open(part_path)
        .read_window(CompactPartWriterW273Fixture::COLUMN_NAME, 0, 1).granules[0].shards
      prefixes = shards.select do |shard|
        shard.stream_name.try(&.ends_with?(".payload.dynamic_structure")) == true
      end.map { |shard| CrystalClick::DynamicStructureCodec.decode(shard.bytes) }
      prefixes.size.should eq(1)
      prefixes[0].statistics.not_nil!.counts.should eq([4_u64, 0_u64])

      reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
        part_path,
        CompactPartWriterW273Fixture::COLUMN_NAME,
        fixture.schema,
      )
      observed = reader.read_marks(0, CompactPartWriterW273Fixture::MARK_COUNT)
      w273a_assert_parent_leaf_schedule(observed)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "refuses a valid tuple-wrapped Array chain outside the bounded Array-only grant without residue" do
    witness = w273a_tuple_column
    w273a_common_tuple_control!(witness[1], witness[2], witness[3], witness[4])
    w273a_refuse_without_publish do |part_path|
      w273a_write(
        part_path,
        witness[0],
        CrystalClick::CompactMarkFormat::Mrk4,
        CrystalClick::CompactVariantDiscriminatorMode::Basic,
      )
    end
  end
end
