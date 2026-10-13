require "./spec_helper"
require "file_utils"
require "./support/compact_part_writer_w271_fixture"

private alias W271LeafPlan = Tuple(
  CrystalClick::BinaryDynamicJsonLeafKey,
  CrystalClick::ObjectDocumentPlan,
)

private def w271a_write(
  part_path : String,
  columns : Array(CrystalClick::CompactPartColumn),
  mark_format : CrystalClick::CompactMarkFormat = CrystalClick::CompactMarkFormat::Mrk3,
  discriminator_mode : CrystalClick::CompactVariantDiscriminatorMode = CrystalClick::CompactVariantDiscriminatorMode::Compact,
) : String
  fixture = CompactPartWriterW271Fixture
  CrystalClick::CompactPartWriter.write_uint64_columns(
    part_path,
    CompactPartWriterW271Fixture::KEY_NAME,
    CompactPartWriterW271Fixture::KEYS,
    columns,
    rows_per_mark: CompactPartWriterW271Fixture::ROWS_PER_MARK,
    frame_bytes: CompactPartWriterW271Fixture::FRAME_BYTES,
    mark_format: mark_format,
    variant_discriminator_mode: discriminator_mode,
  )
end

private def w271a_expect_rejection(&block) : Nil
  rejected = false
  begin
    yield
  rescue ex : ArgumentError | CrystalClick::UnsupportedFormatError | CrystalClick::CorruptPartError
    rejected = true
  end
  rejected.should be_true
  nil
end

private def w271a_expect_constructor_rejection(&block) : Nil
  expect_raises(ArgumentError) do
    yield
  end
  nil
end

private def w271a_refuse_without_publish(&write : String -> String) : Nil
  parent = File.tempname("crystal-click-w271-refusal-")
  part_path = File.join(parent, "all_1_1_0")
  begin
    Dir.mkdir(parent)
    w271a_expect_rejection { yield part_path }
    File.exists?(part_path).should be_false
    Dir.children(parent).should be_empty
  ensure
    FileUtils.rm_rf(parent)
  end
  nil
end

private def w271a_rebuild_plan(
  actuals : CrystalClick::DynamicStructure,
  bindings : Hash(String, Array(W271LeafPlan)),
) : CrystalClick::ObjectDocumentPlan
  fixture = CompactPartWriterW271Fixture
  base = fixture.object_plan
  CrystalClick::ObjectDocumentPlan.new(
    base.structures,
    base.typed_paths,
    {CompactPartWriterW271Fixture::PAYLOAD_PATH => actuals} of String => CrystalClick::DynamicStructure,
    typed_dynamic_json_object_leaf_plans: bindings,
  )
end

private def w271a_column(
  plan : CrystalClick::ObjectDocumentPlan,
  rows : Array(CrystalClick::StorageColumnValue),
) : CrystalClick::CompactPartColumn
  fixture = CompactPartWriterW271Fixture
  context = CrystalClick::CompactJsonWriteContext.new(
    {CompactPartWriterW271Fixture::SITE_PATH => plan} of String => CrystalClick::ObjectDocumentPlan,
  )
  CrystalClick::CompactPartColumn.json(
    CompactPartWriterW271Fixture::COLUMN_NAME,
    fixture.schema,
    fixture.granules(rows),
    context,
  )
end

private def w271a_rows_with_shared_variant_actual : Array(CrystalClick::StorageColumnValue)
  fixture = CompactPartWriterW271Fixture
  rows = fixture.rows
  unexpected = CrystalClick::BinaryValue.dynamic(
    fixture.dynamic_type,
    CrystalClick::BinaryValue.string("shared-fallback"),
  )
  rows[0] = CrystalClick::StorageColumnValue.object_document(
    CrystalClick::ObjectDocument.new(
      {CompactPartWriterW271Fixture::PAYLOAD_PATH => unexpected} of String => CrystalClick::BinaryValue,
    ),
  )
  rows
end

private def w271a_rows_with_variant_actual : Array(CrystalClick::StorageColumnValue)
  fixture = CompactPartWriterW271Fixture
  rows = fixture.rows
  string_type = CrystalClick::BinaryDataType.primitive("String")
  variant_type = CrystalClick::BinaryDataType.variant(
    [fixture.uint8_type, string_type] of CrystalClick::BinaryDataType,
  )
  string_index = variant_type.children.index(string_type).not_nil!
  variant = CrystalClick::BinaryValue.variant(
    variant_type,
    string_index,
    CrystalClick::BinaryValue.string("unsupported variant actual"),
  )
  unexpected = CrystalClick::BinaryValue.dynamic(fixture.dynamic_type, variant)
  rows[0] = CrystalClick::StorageColumnValue.object_document(
    CrystalClick::ObjectDocument.new(
      {CompactPartWriterW271Fixture::PAYLOAD_PATH => unexpected} of String => CrystalClick::BinaryValue,
    ),
  )
  rows
end

private def w271a_first_dynamic_prefix(part_path : String) : CrystalClick::DynamicStructure
  physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
  physical.mode.should eq(CrystalClick::CompactMarkFormat::Mrk4)
  shards = physical.read_window(CompactPartWriterW271Fixture::COLUMN_NAME, 0, 1).granules[0].shards
  prefixes = shards.select do |shard|
    shard.stream_name.try(&.ends_with?(".payload.dynamic_structure")) == true
  end.map { |shard| CrystalClick::DynamicStructureCodec.decode(shard.bytes) }
  prefixes.size.should eq(1)
  prefixes[0]
end

private def w271a_read_full(part_path : String) : Array(CrystalClick::StorageColumnValue)
  reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
    part_path,
    CompactPartWriterW271Fixture::COLUMN_NAME,
    CompactPartWriterW271Fixture.schema,
  )
  reader.read_marks(0, CompactPartWriterW271Fixture::MARK_COUNT).flatten
end

private def w271a_assert_original_literals(actual : Array(CrystalClick::StorageColumnValue)) : Nil
  fixture = CompactPartWriterW271Fixture
  actual.size.should eq(CompactPartWriterW271Fixture::ROW_COUNT)
  actual.each_with_index do |value, index|
    fixture.literal_for(value).should eq(fixture.expected_literals[index])
  end
  nil
end

private def w271a_array_json_actual_column : CrystalClick::CompactPartColumn
  fixture = CompactPartWriterW271Fixture
  array_json_type = CrystalClick::BinaryDataType.array(fixture.json_type)
  actuals = CrystalClick::DynamicStructure.new(
    [array_json_type] of CrystalClick::BinaryDataType,
    CrystalClick::StructureStatistics.new(
      [4_u64, 0_u64] of UInt64,
      [] of CrystalClick::StructureStatistic,
    ),
    version: CrystalClick::DynamicStructure::VERSION_V3,
  )
  child_plan = fixture.json_bindings[CompactPartWriterW271Fixture::PAYLOAD_PATH][0][1]
  key = CrystalClick::BinaryDynamicJsonLeafKey.new(
    CompactPartWriterW271Fixture::SITE_PATH,
    actuals.canonical_index_for(array_json_type),
    [] of Int32,
  ).with_child(0)
  bindings = {
    CompactPartWriterW271Fixture::PAYLOAD_PATH => ([{key, child_plan}] of W271LeafPlan),
  } of String => Array(W271LeafPlan)
  plan = w271a_rebuild_plan(actuals, bindings)

  rows = fixture.expected_literals.map do |literal|
    child = if value = literal
              cell = CrystalClick::BinaryValue.fixed(fixture.uint8_type, Bytes[value])
              row = CrystalClick::BinaryJsonRow.new(
                fixture.json_type,
                [{CompactPartWriterW271Fixture::VALUE_PATH, cell}] of Tuple(String, CrystalClick::BinaryValue),
              )
              json = CrystalClick::BinaryValue.json(fixture.json_type, row)
              CrystalClick::BinaryValue.array(array_json_type, [json] of CrystalClick::BinaryValue)
            else
              nil
            end
    dynamic = CrystalClick::BinaryValue.dynamic(fixture.dynamic_type, child)
    document = CrystalClick::ObjectDocument.new(
      {CompactPartWriterW271Fixture::PAYLOAD_PATH => dynamic} of String => CrystalClick::BinaryValue,
    )
    CrystalClick::StorageColumnValue.object_document(document)
  end
  w271a_column(plan, rows)
end

describe "W271 Compact typed-Dynamic JSON writer adversaries" do
  it "rejects missing, foreign, wrong-path, and wrong-schema bindings at plan construction" do
    fixture = CompactPartWriterW271Fixture
    exact_bindings = fixture.json_bindings
    key, child_plan = exact_bindings[CompactPartWriterW271Fixture::PAYLOAD_PATH][0]

    w271a_expect_constructor_rejection do
      w271a_rebuild_plan(
        fixture.actuals,
        Hash(String, Array(W271LeafPlan)).new,
      )
    end

    foreign_key = CrystalClick::BinaryDynamicJsonLeafKey.new(
      "root/foreign-site",
      key.canonical_arm_index,
      key.descriptor_child_path,
    )
    foreign_bindings = {
      CompactPartWriterW271Fixture::PAYLOAD_PATH => ([{foreign_key, child_plan}] of W271LeafPlan),
    } of String => Array(W271LeafPlan)
    w271a_expect_constructor_rejection do
      w271a_rebuild_plan(fixture.actuals, foreign_bindings)
    end

    wrong_path_key = key.with_child(0)
    wrong_path_bindings = {
      CompactPartWriterW271Fixture::PAYLOAD_PATH => ([{wrong_path_key, child_plan}] of W271LeafPlan),
    } of String => Array(W271LeafPlan)
    w271a_expect_constructor_rejection do
      w271a_rebuild_plan(fixture.actuals, wrong_path_bindings)
    end

    w271a_expect_constructor_rejection do
      uint16 = CrystalClick::BinaryDataType.primitive("UInt16")
      wrong_child = CrystalClick::ObjectDocumentPlan.new(
        child_plan.structures,
        {CompactPartWriterW271Fixture::VALUE_PATH => uint16} of String => CrystalClick::BinaryDataType,
      )
      wrong_schema_bindings = {
        CompactPartWriterW271Fixture::PAYLOAD_PATH => ([{key, wrong_child}] of W271LeafPlan),
      } of String => Array(W271LeafPlan)
      w271a_rebuild_plan(fixture.actuals, wrong_schema_bindings)
    end
  end

  it "rejects omitted V3 first-prefix statistics while constructing the write context" do
    fixture = CompactPartWriterW271Fixture
    exact_bindings = fixture.json_bindings
    w271a_expect_constructor_rejection do
      no_statistics = CrystalClick::DynamicStructure.new(
        [fixture.json_type] of CrystalClick::BinaryDataType,
        version: CrystalClick::DynamicStructure::VERSION_V3,
      )
      missing_prefix_plan = w271a_rebuild_plan(no_statistics, exact_bindings)
      w271a_column(missing_prefix_plan, fixture.rows)
    end
  end

  it "preserves caller-owned V3 counts without changing the decoded JSON payload" do
    fixture = CompactPartWriterW271Fixture
    # Deliberately keep this supplied sample at three JSON values even though
    # the decoded payload below still contains all four JSON literals.
    caller_counts = CrystalClick::DynamicStructure.new(
      [fixture.json_type] of CrystalClick::BinaryDataType,
      CrystalClick::StructureStatistics.new(
        [3_u64, 0_u64] of UInt64,
        [] of CrystalClick::StructureStatistic,
      ),
      version: CrystalClick::DynamicStructure::VERSION_V3,
    )
    caller_count_plan = w271a_rebuild_plan(caller_counts, fixture.json_bindings)
    column = w271a_column(caller_count_plan, fixture.rows)

    parent = File.tempname("crystal-click-w271-caller-counts-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      w271a_write(
        part_path,
        ([column] of CrystalClick::CompactPartColumn),
        CrystalClick::CompactMarkFormat::Mrk4,
      ).should eq(part_path)

      first_prefix = w271a_first_dynamic_prefix(part_path)
      first_statistics = first_prefix.statistics.not_nil!
      first_statistics.counts.should eq([3_u64, 0_u64])
      first_statistics.shared.should be_empty
      w271a_assert_original_literals(w271a_read_full(part_path))
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a valid advanced child Object layout before publication" do
    fixture = CompactPartWriterW271Fixture
    exact_bindings = fixture.json_bindings
    key, child_plan = exact_bindings[CompactPartWriterW271Fixture::PAYLOAD_PATH][0]

    wrong_object_prefix = CrystalClick::ObjectStructure.new(
      [] of String,
      version: 4_u64,
      # Keep the prefix constructor-valid: MAP (shared-data version zero)
      # mandates exactly one bucket. This recognized advanced V4 layout is a
      # valid descriptor, but advanced child relocation is outside this
      # Compact profile.
      shared_data_version: 2_u64,
      bucket_count: 2_u64,
      statistics: CrystalClick::StructureStatistics.new(
        [] of UInt64,
        [] of CrystalClick::StructureStatistic,
      ),
    )
    wrong_child_structures = CrystalClick::ObjectDynamicStructureSet.new(
      wrong_object_prefix,
      Hash(String, CrystalClick::DynamicStructure).new,
    )
    wrong_child_prefix_plan = CrystalClick::ObjectDocumentPlan.new(
      wrong_child_structures,
      child_plan.typed_paths,
    )
    wrong_prefix_bindings = {
      CompactPartWriterW271Fixture::PAYLOAD_PATH => ([{key, wrong_child_prefix_plan}] of W271LeafPlan),
    } of String => Array(W271LeafPlan)
    wrong_prefix = w271a_rebuild_plan(fixture.actuals, wrong_prefix_bindings)
    wrong_prefix_column = w271a_column(wrong_prefix, fixture.rows)
    w271a_refuse_without_publish do |part_path|
      w271a_write(part_path, [wrong_prefix_column] of CrystalClick::CompactPartColumn)
    end
  end

  it "routes an unrostered String actual through SharedVariant" do
    fixture = CompactPartWriterW271Fixture
    # Three rows use the declared JSON arm, one selects SharedVariant String,
    # and four NULL rows contribute to neither count.
    actuals = CrystalClick::DynamicStructure.new(
      [fixture.json_type] of CrystalClick::BinaryDataType,
      CrystalClick::StructureStatistics.new(
        [3_u64, 1_u64] of UInt64,
        [CrystalClick::StructureStatistic.new("String", 1_u64)] of CrystalClick::StructureStatistic,
      ),
      version: CrystalClick::DynamicStructure::VERSION_V3,
    )
    plan = w271a_rebuild_plan(actuals, fixture.json_bindings)
    column = w271a_column(plan, w271a_rows_with_shared_variant_actual)

    parent = File.tempname("crystal-click-w271-shared-variant-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      w271a_write(
        part_path,
        ([column] of CrystalClick::CompactPartColumn),
        CrystalClick::CompactMarkFormat::Mrk4,
      ).should eq(part_path)

      first_statistics = w271a_first_dynamic_prefix(part_path).statistics.not_nil!
      first_statistics.counts.should eq([3_u64, 1_u64])
      first_statistics.shared.should eq(
        [CrystalClick::StructureStatistic.new("String", 1_u64)] of CrystalClick::StructureStatistic,
      )

      actual = w271a_read_full(part_path)
      actual.size.should eq(CompactPartWriterW271Fixture::ROW_COUNT)
      actual.each_with_index do |value, index|
        if index == 0
          payload = value.object_document.value_for(CompactPartWriterW271Fixture::PAYLOAD_PATH)
          payload.type.should eq(fixture.dynamic_type)
          payload.is_null?.should be_false
          payload.child_count.should eq(1)
          shared = payload.child_at(0)
          shared.type.name.should eq("String")
          shared.as_string.should eq("shared-fallback")
        else
          fixture.literal_for(value).should eq(fixture.expected_literals[index])
        end
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a Variant actual outside the typed-Dynamic arm profile without publication" do
    fixture = CompactPartWriterW271Fixture
    column = w271a_column(fixture.object_plan, w271a_rows_with_variant_actual)
    w271a_refuse_without_publish do |part_path|
      w271a_write(part_path, [column] of CrystalClick::CompactPartColumn)
    end
  end

  it "does not allow a zero-arm mark to disappear from the keyed row extent" do
    fixture = CompactPartWriterW271Fixture
    rows = fixture.rows
    shortened_marks = [
      rows[0, CompactPartWriterW271Fixture::ROWS_PER_MARK],
      [] of CrystalClick::StorageColumnValue,
      rows[4, CompactPartWriterW271Fixture::ROWS_PER_MARK],
      rows[6, CompactPartWriterW271Fixture::ROWS_PER_MARK],
    ] of Array(CrystalClick::StorageColumnValue)
    shortened = CrystalClick::CompactPartColumn.json(
      CompactPartWriterW271Fixture::COLUMN_NAME,
      fixture.schema,
      shortened_marks,
      fixture.context,
    )
    w271a_refuse_without_publish do |part_path|
      w271a_write(part_path, [shortened] of CrystalClick::CompactPartColumn)
    end
  end

  it "admits the qualified Array(JSON) Dynamic actual and rejects an unknown discriminator mode" do
    fixture = CompactPartWriterW271Fixture
    wrapped_actual = w271a_array_json_actual_column
    parent = File.tempname("crystal-click-w271-array-json-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      w271a_write(
        part_path,
        [wrapped_actual] of CrystalClick::CompactPartColumn,
        mark_format: CrystalClick::CompactMarkFormat::Mrk4,
        discriminator_mode: CrystalClick::CompactVariantDiscriminatorMode::Compact,
      ).should eq(part_path)
      File.exists?(part_path).should be_true

      actual = w271a_read_full(part_path)
      actual.size.should eq(CompactPartWriterW271Fixture::ROW_COUNT)
      actual.each_with_index do |value, index|
        expected = fixture.expected_literals[index]
        payload = value.object_document.value_for(CompactPartWriterW271Fixture::PAYLOAD_PATH)
        payload.type.should eq(fixture.dynamic_type)
        if literal = expected
          payload.is_null?.should be_false
          payload.child_count.should eq(1)
          array_type = CrystalClick::BinaryDataType.array(fixture.json_type)
          array = payload.child_at(0)
          array.type.should eq(array_type)
          array.elements.size.should eq(1)
          json = array.elements[0]
          json.type.should eq(fixture.json_type)
          cell = json.json_row.value_for(CompactPartWriterW271Fixture::VALUE_PATH).not_nil!
          cell.type.should eq(fixture.uint8_type)
          cell.byte_at(0).should eq(literal)
        else
          payload.is_null?.should be_true
        end
      end
      first_prefix = w271a_first_dynamic_prefix(part_path)
      first_prefix.statistics.not_nil!.counts.should eq([4_u64, 0_u64])
    ensure
      FileUtils.rm_rf(parent)
    end

    unsupported_mode = CrystalClick::CompactVariantDiscriminatorMode.new(2_u64)
    w271a_refuse_without_publish do |part_path|
      w271a_write(
        part_path,
        [fixture.column] of CrystalClick::CompactPartColumn,
        discriminator_mode: unsupported_mode,
      )
    end
  end

  it "rejects a caller plan changed after callback planning" do
    fixture = CompactPartWriterW271Fixture
    limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
    input = fixture.column.json_input
    budget = CrystalClick::BinaryCodecBudget.new(limits, true)
    plan = CrystalClick::CompactPartWritePlan.new(
      [input] of CrystalClick::CompactPartWriteInput,
      limits,
      budget,
      CrystalClick::CompactMarkFormat::Mrk4,
      CrystalClick::CompactVariantDiscriminatorMode::Compact,
    )
    plan.same_input?(input, 0).should be_true
    input.granules[0][0] = w271a_rows_with_shared_variant_actual[0]
    plan.same_input?(input, 0).should be_false

    expect_raises(ArgumentError) do
      CrystalClick::CompactStaticWriter.encode_mixed(
        [input] of CrystalClick::CompactPartWriteInput,
        [2_u64, 2_u64, 2_u64, 2_u64] of UInt64,
        limits,
        CompactPartWriterW271Fixture::FRAME_BYTES,
        CrystalClick::CompressedStreamBudget.new(CrystalClick::CompressedStreamLimits.new, true),
        budget,
        plan,
      )
    end
  end
end
