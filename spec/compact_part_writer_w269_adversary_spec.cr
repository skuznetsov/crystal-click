require "./spec_helper"
require "file_utils"
require "../scripts/support/compact_physical_context_w259_fixture"
require "./support/compact_part_writer_w269_fixture"

private def w269a_write(
  part_path : String,
  columns : Array(CrystalClick::CompactPartColumn),
  mark_format : CrystalClick::CompactMarkFormat = CrystalClick::CompactMarkFormat::Mrk4,
  discriminator_mode : CrystalClick::CompactVariantDiscriminatorMode = CrystalClick::CompactVariantDiscriminatorMode::Compact,
  limits : CrystalClick::BinaryCodecLimits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
  frame_bytes : Int = CompactPartWriterW269Fixture::FRAME_BYTES,
) : String
  CrystalClick::CompactPartWriter.write_uint64_columns(
    part_path,
    CompactPartWriterW269Fixture::KEY_NAME,
    CompactPartWriterW269Fixture::KEYS,
    columns,
    rows_per_mark: CompactPartWriterW269Fixture::ROWS_PER_MARK,
    frame_bytes: frame_bytes,
    limits: limits,
    mark_format: mark_format,
    variant_discriminator_mode: discriminator_mode,
  )
end

private def w269a_expect_rejection(&block)
  rejected = false
  begin
    yield
  rescue ex : ArgumentError | CrystalClick::UnsupportedFormatError
    rejected = true
  end
  rejected.should be_true
end

private def w269a_refuse_without_publish(columns : Array(CrystalClick::CompactPartColumn), limits : CrystalClick::BinaryCodecLimits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS) : Nil
  parent = File.tempname("crystal-click-w269-refusal-")
  part_path = File.join(parent, "all_1_1_0")
  begin
    Dir.mkdir(parent)
    w269a_expect_rejection do
      w269a_write(part_path, columns, limits: limits)
    end
    File.exists?(part_path).should be_false
    Dir.children(parent).should be_empty
  ensure
    FileUtils.rm_rf(parent)
  end
  nil
end

private def w269a_refuse_during_write_without_publish(&write : String -> String) : Nil
  parent = File.tempname("crystal-click-w269-plan-refusal-")
  part_path = File.join(parent, "all_1_1_0")
  begin
    Dir.mkdir(parent)
    w269a_expect_rejection do
      yield part_path
    end
    File.exists?(part_path).should be_false
    Dir.children(parent).should be_empty
  ensure
    FileUtils.rm_rf(parent)
  end
  nil
end

private def w269a_json_value(
  type : CrystalClick::BinaryDataType,
  dynamic_path : String,
  dynamic_value : CrystalClick::BinaryValue,
) : CrystalClick::BinaryValue
  row = CrystalClick::BinaryJsonRow.new(
    type,
    [
      {"id", CrystalClick::BinaryValue.uint64(1_u64)},
      {"label", CrystalClick::BinaryValue.string("same")},
      {dynamic_path, dynamic_value},
    ] of Tuple(String, CrystalClick::BinaryValue),
  )
  CrystalClick::BinaryValue.json(type, row)
end

private def w269a_nested_typed_dynamic_parts(
  include_typed_dynamic_statistics : Bool = true,
) : Tuple(CrystalClick::BinaryDataType, CrystalClick::ObjectDocumentPlan)
  uint8_type = CrystalClick::BinaryDataType.primitive("UInt8")
  actual_array_type = CrystalClick::BinaryDataType.array(uint8_type)
  dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 1)
  typed_types = {"payload" => dynamic_type} of String => CrystalClick::BinaryDataType
  json_type = CrystalClick::BinaryDataType.json(
    max_dynamic_paths: 0,
    max_dynamic_types: 1,
    typed_paths: typed_types,
  )
  typed_statistics = if include_typed_dynamic_statistics
                       CrystalClick::StructureStatistics.new(
                         [1_u64, 0_u64] of UInt64,
                         [] of CrystalClick::StructureStatistic,
                       )
                     end
  actuals = CrystalClick::DynamicStructure.new(
    [actual_array_type] of CrystalClick::BinaryDataType,
    typed_statistics,
    version: CrystalClick::DynamicStructure::VERSION_V3,
  )
  object = CrystalClick::ObjectStructure.new(
    [] of String,
    version: 4_u64,
    shared_data_version: 0_u64,
    bucket_count: 1_u64,
    statistics: CrystalClick::StructureStatistics.new(
      [] of UInt64,
      [] of CrystalClick::StructureStatistic,
    ),
  )
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    object,
    Hash(String, CrystalClick::DynamicStructure).new,
  )
  object_plan = CrystalClick::ObjectDocumentPlan.new(
    structures,
    typed_types,
    {"payload" => actuals} of String => CrystalClick::DynamicStructure,
  )
  {json_type, object_plan}
end

private def w269a_nested_typed_dynamic_input(
  include_typed_dynamic_statistics : Bool = true,
) : CrystalClick::CompactJsonColumnInput
  parts = w269a_nested_typed_dynamic_parts(include_typed_dynamic_statistics)
  json_type = parts[0]
  object_plan = parts[1]
  schema = CrystalClick::StorageColumnSchema.parse(
    CrystalClick::BinaryDataType.array(json_type).name,
  )
  context = CrystalClick::CompactJsonWriteContext.new(
    {"root/array[0]" => object_plan} of String => CrystalClick::ObjectDocumentPlan,
  )
  input_rows = [
    [CrystalClick::StorageColumnValue.array([] of CrystalClick::StorageColumnValue)] of CrystalClick::StorageColumnValue,
  ] of Array(CrystalClick::StorageColumnValue)
  CrystalClick::CompactJsonColumnInput.new("nested_typed_dynamic", schema, input_rows, context)
end

private def w269a_nonempty_nested_typed_dynamic_column : CrystalClick::CompactPartColumn
  json_type, object_plan = w269a_nested_typed_dynamic_parts
  uint8_type = CrystalClick::BinaryDataType.primitive("UInt8")
  actual_array_type = CrystalClick::BinaryDataType.array(uint8_type)
  dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 1)
  rows = Array(CrystalClick::StorageColumnValue).new(CompactPartWriterW269Fixture::ROW_COUNT)
  CompactPartWriterW269Fixture::ROW_COUNT.times do |index|
    actual = CrystalClick::BinaryValue.array(
      actual_array_type,
      [CrystalClick::BinaryValue.fixed(uint8_type, Bytes[(index + 1).to_u8])] of CrystalClick::BinaryValue,
    )
    payload = CrystalClick::BinaryValue.dynamic(dynamic_type, actual)
    document = CrystalClick::ObjectDocument.new(
      {
        "payload" => payload,
      } of String => CrystalClick::BinaryValue,
    )
    object_value = CrystalClick::StorageColumnValue.object_document(document)
    rows << CrystalClick::StorageColumnValue.array([object_value] of CrystalClick::StorageColumnValue)
  end
  schema = CrystalClick::StorageColumnSchema.parse(CrystalClick::BinaryDataType.array(json_type).name)
  context = CrystalClick::CompactJsonWriteContext.new(
    {"root/array[0]" => object_plan} of String => CrystalClick::ObjectDocumentPlan,
  )
  CrystalClick::CompactPartColumn.json(
    "nested_typed_dynamic",
    schema,
    CompactPartWriterW269Fixture.granules(rows),
    context,
  )
end

private def w269a_limits_with_depth(max_depth : Int32) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(max_depth, 4_096, 4_096, 1_048_576)
end

private def w269a_read_budget : CrystalClick::BinaryCodecBudget
  CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, false)
end

private def w269a_raw_guard_shards(
  physical : CrystalClick::CompactPartPhysicalContext,
) : Array(Array(Array(UInt8)))
  marks = Array(Array(Array(UInt8))).new(CompactPartWriterW269Fixture::MARK_COUNT)
  CompactPartWriterW269Fixture::MARK_COUNT.times do |mark_index|
    window = physical.read_window("guard", mark_index, 1)
    marks << window.granules[0].shards.map { |shard| shard.bytes.to_a }
  end
  marks
end

private def w269a_read_u32(bytes : Bytes, offset : Int) : UInt32
  value = 0_u32
  4.times do |index|
    value |= bytes[offset + index].to_u32 << (index * 8)
  end
  value
end

private def w269a_frame_count(part_path : String) : Int32
  data = File.read(File.join(part_path, "data.bin"))
  bytes = data.to_slice
  offset = 0
  count = 0
  while offset < bytes.size
    if offset > bytes.size - CrystalClick::CompressedBlock::FRAME_HEADER_SIZE
      raise "truncated W269 compressed frame"
    end
    compressed_size = w269a_read_u32(bytes, offset + CrystalClick::CompressedBlock::CHECKSUM_SIZE + 1).to_i
    frame_size = CrystalClick::CompressedBlock::CHECKSUM_SIZE + compressed_size
    if frame_size < CrystalClick::CompressedBlock::FRAME_HEADER_SIZE || frame_size > bytes.size - offset
      raise "invalid W269 compressed frame extent"
    end
    offset += frame_size
    count += 1
  end
  raise "W269 data.bin has no compressed frames" if count == 0
  count
end

describe "W269 Compact JSON writer adversaries" do
  it "binds mixed JSON plans to one exact value grid" do
    fixture = CompactPartWriterW269Fixture
    limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
    root_plan = fixture.object_plan(
      1_u64,
      1_u64,
      0_u64,
      CrystalClick::DynamicStructure::VERSION_V1,
      0_u64,
    )
    context = CrystalClick::CompactJsonWriteContext.new(
      {CompactPartWriterW269Fixture::ROOT_SITE => root_plan} of String => CrystalClick::ObjectDocumentPlan,
    )
    input_a = CrystalClick::CompactJsonColumnInput.new(
      CompactPartWriterW269Fixture::ROOT_COLUMN,
      fixture.json_schema,
      fixture.granules(fixture.root_rows),
      context,
    )
    rows_b = fixture.root_rows
    rows_b[0] = fixture.object_value(
      fixture.document(1_u64, "r1", CrystalClick::BinaryValue.string("different-root-value")),
    )
    input_b = CrystalClick::CompactJsonColumnInput.new(
      input_a.name,
      input_a.schema,
      fixture.granules(rows_b),
      context,
    )
    write_budget = CrystalClick::BinaryCodecBudget.new(limits, true)
    plan = CrystalClick::CompactPartWritePlan.new(
      [input_a] of CrystalClick::CompactPartWriteInput,
      limits,
      write_budget,
      CrystalClick::CompactMarkFormat::Mrk4,
      CrystalClick::CompactVariantDiscriminatorMode::Compact,
    )

    plan.same_input?(input_a, 0).should be_true
    plan.same_input?(input_b, 0).should be_false
    expect_raises(ArgumentError) do
      CrystalClick::CompactStaticWriter.encode_mixed(
        [input_b] of CrystalClick::CompactPartWriteInput,
        [2_u64, 2_u64, 2_u64, 2_u64] of UInt64,
        limits,
        CompactPartWriterW269Fixture::FRAME_BYTES,
        CrystalClick::CompressedStreamBudget.new(CrystalClick::CompressedStreamLimits.new, true),
        write_budget,
        plan,
      )
    end
  end

  it "rejects direct JSON encoding after exposed row or cell containers change" do
    fixture = CompactPartWriterW269Fixture
    limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
    root_plan = fixture.object_plan(
      1_u64,
      1_u64,
      0_u64,
      CrystalClick::DynamicStructure::VERSION_V1,
      0_u64,
    )
    context = CrystalClick::CompactJsonWriteContext.new(
      {CompactPartWriterW269Fixture::ROOT_SITE => root_plan} of String => CrystalClick::ObjectDocumentPlan,
    )

    replaced = CrystalClick::CompactJsonColumnInput.new(
      CompactPartWriterW269Fixture::ROOT_COLUMN,
      fixture.json_schema,
      fixture.granules(fixture.root_rows),
      context,
    )
    replaced_budget = CrystalClick::BinaryCodecBudget.new(limits, true)
    replaced_plan = CrystalClick::CompactJsonCallbackPlan.new(
      replaced,
      limits,
      replaced_budget,
      CrystalClick::CompactVariantDiscriminatorMode::Compact,
    )
    replaced_plan.same_input?(replaced).should be_true
    replaced.granules[0][0] = fixture.object_value(
      fixture.document(1_u64, "r1", CrystalClick::BinaryValue.string("replacement-after-plan")),
    )
    replaced_plan.same_input?(replaced).should be_false
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::CompactJsonEncodedColumn.encode(replaced_plan, replaced_budget)
    end

    removed = CrystalClick::CompactJsonColumnInput.new(
      CompactPartWriterW269Fixture::ROOT_COLUMN,
      fixture.json_schema,
      fixture.granules(fixture.root_rows),
      context,
    )
    removed_budget = CrystalClick::BinaryCodecBudget.new(limits, true)
    removed_plan = CrystalClick::CompactJsonCallbackPlan.new(
      removed,
      limits,
      removed_budget,
      CrystalClick::CompactVariantDiscriminatorMode::Compact,
    )
    removed.granules[0].delete_at(0)
    removed_plan.same_input?(removed).should be_false
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::CompactJsonEncodedColumn.encode(removed_plan, removed_budget)
    end
  end

  it "preflights JSON callback-plan reference-grid nodes and edges before snapshotting" do
    fixture = CompactPartWriterW269Fixture
    root_plan = fixture.object_plan(
      1_u64,
      1_u64,
      0_u64,
      CrystalClick::DynamicStructure::VERSION_V1,
      0_u64,
    )
    context = CrystalClick::CompactJsonWriteContext.new(
      {CompactPartWriterW269Fixture::ROOT_SITE => root_plan} of String => CrystalClick::ObjectDocumentPlan,
    )

    [
      {4, 12},  # Four row arrays plus the outer grid require five reference nodes.
      {64, 11}, # Four outer slots plus eight row slots require twelve edges.
    ].each do |max_nodes, max_elements|
      limits = CrystalClick::BinaryCodecLimits.new(
        64,
        max_nodes,
        max_elements,
        CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS.max_bytes,
      )
      input = CrystalClick::CompactJsonColumnInput.new(
        CompactPartWriterW269Fixture::ROOT_COLUMN,
        fixture.json_schema,
        fixture.granules(fixture.root_rows),
        context,
      )
      budget = CrystalClick::BinaryCodecBudget.new(limits, true)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::CompactJsonCallbackPlan.new(
          input,
          limits,
          budget,
          CrystalClick::CompactVariantDiscriminatorMode::Compact,
        )
      end
      budget.node_count.should eq(0_i64)
      budget.element_count.should eq(0_i64)
      budget.wire_byte_count.should eq(0_i64)
    end
  end

  it "inherits the nested JSON-site depth when admitting typed Dynamic actual arms" do
    input = w269a_nested_typed_dynamic_input

    # The Array(UInt8) actual arm starts below both the outer Array and the
    # nested JSON/Object/typed-Dynamic path; its UInt8 child is at depth five.
    adequate_limits = w269a_limits_with_depth(5_i32)
    adequate_budget = CrystalClick::BinaryCodecBudget.new(adequate_limits, true)
    adequate_plan = CrystalClick::CompactJsonCallbackPlan.new(
      input,
      adequate_limits,
      adequate_budget,
      CrystalClick::CompactVariantDiscriminatorMode::Compact,
    )
    adequate_plan.json_sites[0].descriptor_depth.should eq(2_i32)

    inherited_child_depth_limits = w269a_limits_with_depth(4_i32)
    inherited_child_depth_budget = CrystalClick::BinaryCodecBudget.new(inherited_child_depth_limits, true)
    w269a_expect_rejection do
      CrystalClick::CompactJsonCallbackPlan.new(
        input,
        inherited_child_depth_limits,
        inherited_child_depth_budget,
        CrystalClick::CompactVariantDiscriminatorMode::Compact,
      )
    end
  end

  it "requires full first-prefix statistics on typed Dynamic rosters at nested JSON sites" do
    object_plan = w269a_nested_typed_dynamic_parts(include_typed_dynamic_statistics: false)[1]
    object_plan.typed_dynamic_site_structure_for("payload", "root").statistics.should be_nil

    w269a_expect_rejection do
      CrystalClick::CompactJsonWriteContext.new(
        {CompactPartWriterW269Fixture::ARRAY_SITE => object_plan} of String => CrystalClick::ObjectDocumentPlan,
      )
    end
  end

  it "publishes and reads nonempty nested typed-Dynamic Array(UInt8) under Compact MRK3" do
    parent = File.tempname("crystal-click-w269-mrk3-typed-dynamic-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      column = w269a_nonempty_nested_typed_dynamic_column
      columns = [column] of CrystalClick::CompactPartColumn
      w269a_write(
        part_path,
        columns,
        CrystalClick::CompactMarkFormat::Mrk3,
        CrystalClick::CompactVariantDiscriminatorMode::Compact,
      ).should eq(part_path)
      File.exists?(part_path).should be_true

      json_type, _object_plan = w269a_nested_typed_dynamic_parts
      schema = CrystalClick::StorageColumnSchema.parse(
        CrystalClick::BinaryDataType.array(json_type).name,
      )
      reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
        part_path,
        "nested_typed_dynamic",
        schema,
      )
      reader.mark_count.should eq(CompactPartWriterW269Fixture::MARK_COUNT)
      reader.row_count.should eq(CompactPartWriterW269Fixture::ROW_COUNT.to_u64)
      actual_rows = reader.read_marks(0, reader.mark_count).flatten
      actual_rows.size.should eq(CompactPartWriterW269Fixture::ROW_COUNT)
      dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 1)
      array_type = CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.primitive("UInt8"))
      actual_rows.each_with_index do |outer, index|
        outer.array_values.size.should eq(1)
        payload = outer.array_values[0].object_document.value_for("payload")
        payload.type.should eq(dynamic_type)
        payload.is_null?.should be_false
        actual_array = payload.child_at(0)
        actual_array.type.should eq(array_type)
        actual_array.element_count.should eq(1)
        actual_array.child_at(0).byte_at(0).should eq((index + 1).to_u8)
      end
      reader.read_marks(reader.mark_count, 0).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "returns detached callback-pair rosters from an Object site binding" do
    fixture = CompactPartWriterW269Fixture
    root_plan = fixture.object_plan(
      1_u64,
      1_u64,
      0_u64,
      CrystalClick::DynamicStructure::VERSION_V1,
      0_u64,
    )
    context = CrystalClick::CompactJsonWriteContext.new(
      {CompactPartWriterW269Fixture::ROOT_SITE => root_plan} of String => CrystalClick::ObjectDocumentPlan,
    )
    input = CrystalClick::CompactJsonColumnInput.new(
      CompactPartWriterW269Fixture::ROOT_COLUMN,
      fixture.json_schema,
      fixture.granules(fixture.root_rows),
      context,
    )
    limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
    plan = CrystalClick::CompactJsonCallbackPlan.new(
      input,
      limits,
      CrystalClick::BinaryCodecBudget.new(limits, true),
      CrystalClick::CompactVariantDiscriminatorMode::Compact,
    )
    binding = plan.site_binding(CompactPartWriterW269Fixture::ROOT_SITE)
    expected_prefix_pairs = binding.prefix_pairs.dup
    expected_body_pairs = binding.body_pairs.dup

    binding.prefix_pairs.clear
    binding.body_pairs.clear

    plan.site_binding(CompactPartWriterW269Fixture::ROOT_SITE).prefix_pairs.should eq(expected_prefix_pairs)
    plan.site_binding(CompactPartWriterW269Fixture::ROOT_SITE).body_pairs.should eq(expected_body_pairs)
  end

  it "detaches site plans and row grids before writing" do
    fixture = CompactPartWriterW269Fixture
    root_plan = fixture.object_plan(
      1_u64,
      1_u64,
      0_u64,
      CrystalClick::DynamicStructure::VERSION_V1,
      0_u64,
    )
    caller_plans = {CompactPartWriterW269Fixture::ROOT_SITE => root_plan} of String => CrystalClick::ObjectDocumentPlan
    context = CrystalClick::CompactJsonWriteContext.new(caller_plans)
    caller_granules = fixture.granules(fixture.root_rows)
    column = CrystalClick::CompactPartColumn.json(
      CompactPartWriterW269Fixture::ROOT_COLUMN,
      fixture.json_schema,
      caller_granules,
      context,
    )

    caller_plans.clear
    caller_granules[0].clear
    context.site_count.should eq(1)
    context.site_plans.keys.should eq([CompactPartWriterW269Fixture::ROOT_SITE])

    parent = File.tempname("crystal-click-w269-detached-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      w269a_write(part_path, [column] of CrystalClick::CompactPartColumn).should eq(part_path)
      reader = CrystalClick::CompactRecursiveJsonColumnReader.open(part_path, CompactPartWriterW269Fixture::ROOT_COLUMN, fixture.json_schema)
      actual = reader.read_marks(0, CompactPartWriterW269Fixture::MARK_COUNT).flatten
      expected = fixture.root_rows
      actual.size.should eq(expected.size)
      actual.each_with_index do |value, index|
        CrystalClick::CompactPartValueComparison.storage!(value, expected[index], w269a_read_budget)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects missing, extra, and wrong recursive site bindings before publication" do
    fixture = CompactPartWriterW269Fixture
    root_plan = fixture.object_plan(
      1_u64,
      1_u64,
      0_u64,
      CrystalClick::DynamicStructure::VERSION_V1,
      0_u64,
    )
    left_plan = fixture.object_plan(
      1_u64,
      1_u64,
      0_u64,
      CrystalClick::DynamicStructure::VERSION_V1,
      0_u64,
    )

    wrong_site = CrystalClick::CompactPartColumn.json(
      CompactPartWriterW269Fixture::ROOT_COLUMN,
      fixture.json_schema,
      fixture.granules(fixture.root_rows),
      CrystalClick::CompactJsonWriteContext.new(
        {"root/tuple[0]" => root_plan} of String => CrystalClick::ObjectDocumentPlan,
      ),
    )
    extra_site = CrystalClick::CompactPartColumn.json(
      CompactPartWriterW269Fixture::ROOT_COLUMN,
      fixture.json_schema,
      fixture.granules(fixture.root_rows),
      CrystalClick::CompactJsonWriteContext.new(
        {
          CompactPartWriterW269Fixture::ROOT_SITE => root_plan,
          "root/tuple[0]"                         => root_plan,
        } of String => CrystalClick::ObjectDocumentPlan,
      ),
    )
    missing_tuple_site = CrystalClick::CompactPartColumn.json(
      CompactPartWriterW269Fixture::PAIR_COLUMN,
      fixture.pair_schema,
      fixture.granules(fixture.pair_rows),
      CrystalClick::CompactJsonWriteContext.new(
        {CompactPartWriterW269Fixture::LEFT_SITE => left_plan} of String => CrystalClick::ObjectDocumentPlan,
      ),
    )

    w269a_refuse_without_publish([wrong_site] of CrystalClick::CompactPartColumn)
    w269a_refuse_without_publish([extra_site] of CrystalClick::CompactPartColumn)
    w269a_refuse_without_publish([missing_tuple_site] of CrystalClick::CompactPartColumn)
  end

  it "round trips a late shared Object path without widening the ordinary roster" do
    fixture = CompactPartWriterW269Fixture
    root_plan = fixture.object_plan(
      1_u64,
      1_u64,
      0_u64,
      CrystalClick::DynamicStructure::VERSION_V1,
      0_u64,
    )
    rows = fixture.root_rows
    rows[6] = fixture.object_value(
      CrystalClick::ObjectDocument.new(
        {
          "id"       => CrystalClick::BinaryValue.uint64(7_u64),
          "label"    => CrystalClick::BinaryValue.string("r7"),
          "payload"  => CrystalClick::BinaryValue.uint64(77_u64),
          "new-path" => CrystalClick::BinaryValue.string("late-root"),
        } of String => CrystalClick::BinaryValue,
      )
    )
    late_shared = CrystalClick::CompactPartColumn.json(
      CompactPartWriterW269Fixture::ROOT_COLUMN,
      fixture.json_schema,
      fixture.granules(rows),
      fixture.json_context(
        {CompactPartWriterW269Fixture::ROOT_SITE => root_plan} of String => CrystalClick::ObjectDocumentPlan,
      ),
    )

    parent = File.tempname("crystal-click-w269-late-shared-path-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      w269a_write(part_path, [late_shared] of CrystalClick::CompactPartColumn).should eq(part_path)
      reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
        part_path,
        CompactPartWriterW269Fixture::ROOT_COLUMN,
        fixture.json_schema,
      )
      actual = reader.read_marks(0, CompactPartWriterW269Fixture::MARK_COUNT).flatten
      expected = fixture.root_rows
      expected[6] = rows[6]
      actual.size.should eq(expected.size)
      actual.each_with_index do |value, index|
        CrystalClick::CompactPartValueComparison.storage!(value, expected[index], w269a_read_budget)
      end
      actual[6].object_document.value_for("new-path").as_string.should eq("late-root")

      physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
      first_mark = physical.read_window(CompactPartWriterW269Fixture::ROOT_COLUMN, 0, 1)
      object_shard = first_mark.granules[0].shards.find do |shard|
        shard.stream_name.try(&.ends_with?(".object_structure")) == true
      end.not_nil!
      structure = CrystalClick::ObjectStructureCodec.decode(object_shard.bytes)
      structure.dynamic_paths.should eq(["payload"])

      # The ordinary Dynamic actual roster is still String/UInt64. Bool and
      # NULL values in that field use the existing SharedVariant arm.
      dynamics = first_mark.granules[0].shards.select do |shard|
        shard.stream_name.try(&.ends_with?(".payload.dynamic_structure")) == true
      end.map { |shard| CrystalClick::DynamicStructureCodec.decode(shard.bytes) }
      dynamics.first.types.map(&.name).should eq(["String", "UInt64"])
      expected[3].object_document.value_for("payload").is_null?.should be_true
      expected[5].object_document.value_for("payload").type.name.should eq("Bool")
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "requires complete first-prefix statistics and the admitted Object V3 layouts" do
    fixture = CompactPartWriterW269Fixture

    missing_object_stats = fixture.object_plan(
      1_u64,
      1_u64,
      0_u64,
      CrystalClick::DynamicStructure::VERSION_V3,
      0_u64,
      include_object_statistics: false,
    )
    missing_dynamic_stats = fixture.object_plan(
      1_u64,
      1_u64,
      0_u64,
      CrystalClick::DynamicStructure::VERSION_V3,
      0_u64,
      include_dynamic_statistics: false,
    )
    object_v2 = fixture.object_plan(
      1_u64,
      1_u64,
      0_u64,
      CrystalClick::DynamicStructure::VERSION_V3,
      0_u64,
      object_version: 2_u64,
    )
    advanced = fixture.object_plan(
      1_u64,
      1_u64,
      0_u64,
      CrystalClick::DynamicStructure::VERSION_V3,
      2_u64,
      2_u64,
    )

    [missing_object_stats, missing_dynamic_stats].each do |plan|
      w269a_expect_rejection do
        CrystalClick::CompactJsonWriteContext.new(
          {CompactPartWriterW269Fixture::ROOT_SITE => plan} of String => CrystalClick::ObjectDocumentPlan,
        )
      end
    end

    w269a_refuse_during_write_without_publish do |part_path|
      context = CrystalClick::CompactJsonWriteContext.new(
        {CompactPartWriterW269Fixture::ROOT_SITE => object_v2} of String => CrystalClick::ObjectDocumentPlan,
      )
      column = CrystalClick::CompactPartColumn.json(
        CompactPartWriterW269Fixture::ROOT_COLUMN,
        fixture.json_schema,
        fixture.granules(fixture.root_rows),
        context,
      )
      w269a_write(part_path, [column] of CrystalClick::CompactPartColumn)
    end

    # W278 admits ADVANCED through the existing recursive callback owner.
    advanced_context = CrystalClick::CompactJsonWriteContext.new(
      {CompactPartWriterW269Fixture::ROOT_SITE => advanced} of String => CrystalClick::ObjectDocumentPlan,
    )
    advanced_column = CrystalClick::CompactPartColumn.json(
      CompactPartWriterW269Fixture::ROOT_COLUMN,
      fixture.json_schema,
      fixture.granules(fixture.root_rows),
      advanced_context,
    )
    limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
    budget = CrystalClick::BinaryCodecBudget.new(limits, true)
    callback_plan = CrystalClick::CompactJsonCallbackPlan.new(advanced_column.json_input, limits, budget)
    encoded = CrystalClick::CompactJsonEncodedColumn.encode(callback_plan, budget)
    CompactPartWriterW269Fixture::MARK_COUNT.times do |mark_index|
      encoded.callback_relocation_count_at(mark_index).should be > 0
    end

    w269a_refuse_during_write_without_publish do |part_path|
      json_type = fixture.json_type
      candidate = CrystalClick::DynamicStructure.new(
        [json_type] of CrystalClick::BinaryDataType,
        version: CrystalClick::DynamicStructure::VERSION_V3,
      )
      candidate_counts = candidate.canonical_variant_names.map do |name|
        name == json_type.name ? 1_u64 : 0_u64
      end
      bad_actual_type = CrystalClick::DynamicStructure.new(
        [json_type] of CrystalClick::BinaryDataType,
        CrystalClick::StructureStatistics.new(candidate_counts, [] of CrystalClick::StructureStatistic),
        version: CrystalClick::DynamicStructure::VERSION_V3,
      )
      object = CrystalClick::ObjectStructure.new(
        ["payload"] of String,
        version: 4_u64,
        shared_data_version: 0_u64,
        bucket_count: 1_u64,
        statistics: CrystalClick::StructureStatistics.new([1_u64] of UInt64, [] of CrystalClick::StructureStatistic),
      )
      bad_actual_plan = CrystalClick::ObjectDocumentPlan.new(
        CrystalClick::ObjectDynamicStructureSet.new(
          object,
          {"payload" => bad_actual_type} of String => CrystalClick::DynamicStructure,
        ),
        fixture.json_schema.object_schema.typed_paths,
      )
      context = CrystalClick::CompactJsonWriteContext.new(
        {CompactPartWriterW269Fixture::ROOT_SITE => bad_actual_plan} of String => CrystalClick::ObjectDocumentPlan,
      )
      column = CrystalClick::CompactPartColumn.json(
        CompactPartWriterW269Fixture::ROOT_COLUMN,
        fixture.json_schema,
        fixture.granules(fixture.root_rows),
        context,
      )
      w269a_write(part_path, [column] of CrystalClick::CompactPartColumn)
    end
  end

  it "compares JSON paths and values recursively instead of relying on BinaryValue identity" do
    fixture = CompactPartWriterW269Fixture
    type = fixture.json_type
    expected_json = w269a_json_value(type, "dynamic.one", CrystalClick::BinaryValue.string("payload"))
    independently_decoded_equal = CrystalClick::BinaryValueCodec.decode_value(
      type,
      CrystalClick::BinaryValueCodec.encode_value(expected_json),
    )
    wrong_path = w269a_json_value(type, "dynamic.two", CrystalClick::BinaryValue.string("payload"))
    wrong_value = w269a_json_value(type, "dynamic.one", CrystalClick::BinaryValue.string("changed"))

    CrystalClick::CompactPartValueComparison.binary!(expected_json, independently_decoded_equal, w269a_read_budget)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::CompactPartValueComparison.binary!(expected_json, wrong_path, w269a_read_budget)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::CompactPartValueComparison.binary!(expected_json, wrong_value, w269a_read_budget)
    end

    actual_tree = CrystalClick::StorageColumnValue.array([
      CrystalClick::StorageColumnValue.object_document(fixture.document(1_u64, "same", expected_json)),
    ] of CrystalClick::StorageColumnValue)
    equal_tree = CrystalClick::StorageColumnValue.array([
      CrystalClick::StorageColumnValue.object_document(fixture.document(1_u64, "same", independently_decoded_equal)),
    ] of CrystalClick::StorageColumnValue)
    path_mutation = CrystalClick::StorageColumnValue.array([
      CrystalClick::StorageColumnValue.object_document(fixture.document(1_u64, "same", wrong_path)),
    ] of CrystalClick::StorageColumnValue)
    value_mutation = CrystalClick::StorageColumnValue.array([
      CrystalClick::StorageColumnValue.object_document(fixture.document(1_u64, "same", wrong_value)),
    ] of CrystalClick::StorageColumnValue)

    CrystalClick::CompactPartValueComparison.storage!(actual_tree, equal_tree, w269a_read_budget)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::CompactPartValueComparison.storage!(actual_tree, path_mutation, w269a_read_budget)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::CompactPartValueComparison.storage!(actual_tree, value_mutation, w269a_read_budget)
    end

    tiny_limits = CrystalClick::BinaryCodecLimits.new(1, 1, 1, 1)
    tiny_budget = CrystalClick::BinaryCodecBudget.new(tiny_limits, false)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::CompactPartValueComparison.binary!(expected_json, independently_decoded_equal, tiny_budget)
    end

    write_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true)
    expect_raises(ArgumentError) do
      CrystalClick::CompactPartValueComparison.binary!(expected_json, independently_decoded_equal, write_budget)
    end
    expect_raises(ArgumentError) do
      CrystalClick::CompactPartValueComparison.document!(
        fixture.document(1_u64, "same", expected_json),
        fixture.document(1_u64, "same", independently_decoded_equal),
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true),
      )
    end
    expect_raises(ArgumentError) do
      CrystalClick::CompactPartValueComparison.storage!(
        actual_tree,
        equal_tree,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true),
      )
    end

    inherited_depth_limits = CrystalClick::BinaryCodecLimits.new(3, 64, 64, 4096)
    inherited_depth_budget = CrystalClick::BinaryCodecBudget.new(inherited_depth_limits, false)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::CompactPartValueComparison.storage!(actual_tree, equal_tree, inherited_depth_budget)
    end
  end

  it "preserves an existing destination and sentinel when a write is refused" do
    fixture = CompactPartWriterW269Fixture
    parent = File.tempname("crystal-click-w269-existing-target-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      Dir.mkdir(part_path)
      sentinel = File.join(part_path, "keep.txt")
      File.write(sentinel, "preserve")

      expect_raises(ArgumentError) do
        w269a_write(part_path, [fixture.columns[0]] of CrystalClick::CompactPartColumn)
      end
      File.read(sentinel).should eq("preserve")
      Dir.children(parent).should eq(["all_1_1_0"])
      Dir.children(part_path).should eq(["keep.txt"])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "fails codec preflight without publishing a partial part" do
    fixture = CompactPartWriterW269Fixture
    column = fixture.columns[0]
    tiny_limits = CrystalClick::BinaryCodecLimits.new(1, 1, 1, 1)
    w269a_refuse_without_publish([column] of CrystalClick::CompactPartColumn, tiny_limits)
  end

  it "leaves the static BinaryBulk callback bytes unchanged in a mixed JSON part" do
    fixture = CompactPartWriterW269Fixture
    guard = fixture.static_guard_column
    static_parent = File.tempname("crystal-click-w269-static-guard-")
    mixed_parent = File.tempname("crystal-click-w269-mixed-guard-")
    static_path = File.join(static_parent, "all_1_1_0")
    mixed_path = File.join(mixed_parent, "all_1_1_0")
    begin
      Dir.mkdir(static_parent)
      Dir.mkdir(mixed_parent)
      w269a_write(
        static_path,
        ([guard] of CrystalClick::CompactPartColumn),
        CrystalClick::CompactMarkFormat::Mrk4,
        CrystalClick::CompactVariantDiscriminatorMode::Compact,
      )
      mixed_columns = [fixture.columns[0], guard] of CrystalClick::CompactPartColumn
      w269a_write(
        mixed_path,
        mixed_columns,
        CrystalClick::CompactMarkFormat::Mrk4,
        CrystalClick::CompactVariantDiscriminatorMode::Compact,
      )

      static_physical = CrystalClick::CompactPartPhysicalContext.open(static_path)
      mixed_physical = CrystalClick::CompactPartPhysicalContext.open(mixed_path)
      w269a_raw_guard_shards(static_physical).should eq(w269a_raw_guard_shards(mixed_physical))
    ensure
      FileUtils.rm_rf(static_parent)
      FileUtils.rm_rf(mixed_parent)
    end
  end

  it "authenticates an out-of-window late payload-frame mutation before returning a selected mark" do
    fixture = CompactPartWriterW269Fixture
    parent = File.tempname("crystal-click-w269-late-corruption-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      root_column = fixture.columns[0]
      w269a_write(
        part_path,
        ([root_column] of CrystalClick::CompactPartColumn),
        CrystalClick::CompactMarkFormat::Mrk4,
        CrystalClick::CompactVariantDiscriminatorMode::Compact,
        frame_bytes: 64,
      )
      last_frame = w269a_frame_count(part_path) - 1
      CompactPhysicalContextW259Fixture.corrupt_frame_payload(part_path, last_frame)

      reader = CrystalClick::CompactRecursiveJsonColumnReader.open(part_path, CompactPartWriterW269Fixture::ROOT_COLUMN, fixture.json_schema)
      expect_raises(CrystalClick::CorruptPartError) do
        # The root-Object delegate prepares/authenticates the complete selected
        # physical grid before decoding even an earlier, otherwise-valid mark.
        reader.read_marks(0, 1)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "charges budgeted Object callback copies before retaining detached prefix and body payloads" do
    prefixes = [{".child.prefix", Bytes[1_u8, 2_u8]}] of Tuple(String, Bytes)
    bodies = [{".child.data", Bytes[10_u8, 20_u8]}] of Tuple(String, Bytes)
    layout = CrystalClick::ObjectSharedAdvancedInlineRawLayout.new(
      prefixes,
      bodies,
      [] of CrystalClick::ObjectSharedInlineCallbackRelocation,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
    )

    prefix_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
    prefix_name, prefix_bytes = layout.prefix_callback_at(0, prefix_budget)
    prefix_name.should eq(".child.prefix")
    prefix_bytes[0] = 99_u8
    prefix_budget.node_count.should eq(2_i64)
    prefix_budget.element_count.should eq(2_i64)
    prefix_budget.wire_byte_count.should eq(".child.prefix".bytesize.to_i64 + 2_i64)
    layout.prefix_callback_at(0)[1].should eq(Bytes[1_u8, 2_u8])

    body_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
    body_name, body_bytes = layout.body_callback_at(0, body_budget)
    body_name.should eq(".child.data")
    body_bytes[0] = 99_u8
    body_budget.node_count.should eq(2_i64)
    body_budget.element_count.should eq(2_i64)
    body_budget.wire_byte_count.should eq(".child.data".bytesize.to_i64 + 2_i64)
    layout.body_callback_at(0)[1].should eq(Bytes[10_u8, 20_u8])

    legacy_prefix = layout.prefix_callback_at(0)
    legacy_prefix[1][0] = 77_u8
    legacy_body = layout.body_callback_at(0)
    legacy_body[1][0] = 77_u8
    layout.prefix_callback_at(0)[1].should eq(Bytes[1_u8, 2_u8])
    layout.body_callback_at(0)[1].should eq(Bytes[10_u8, 20_u8])

    [
      {".child.prefix", Bytes[1_u8, 2_u8], true},
      {".child.data", Bytes[10_u8, 20_u8], false},
    ].each do |callback_name, callback_bytes, prefix|
      byte_limit = callback_name.bytesize + callback_bytes.size - 1
      tiny_budget = CrystalClick::BinaryCodecBudget.new(
        CrystalClick::BinaryCodecLimits.new(64, 8, 8, byte_limit), true,
      )
      expect_raises(CrystalClick::UnsupportedFormatError) do
        if prefix
          layout.prefix_callback_at(0, tiny_budget)
        else
          layout.body_callback_at(0, tiny_budget)
        end
      end
      tiny_budget.node_count.should eq(0_i64)
      tiny_budget.element_count.should eq(0_i64)
      tiny_budget.wire_byte_count.should eq(0_i64)
    end
  end
end
