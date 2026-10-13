require "./spec_helper"
require "file_utils"
require "./support/compact_part_writer_w272_fixture"

private alias W272ALeafPlan = Tuple(
  CrystalClick::BinaryDynamicJsonLeafKey,
  CrystalClick::ObjectDocumentPlan,
)

private def w272a_write(
  part_path : String,
  columns : Array(CrystalClick::CompactPartColumn),
  mark_format : CrystalClick::CompactMarkFormat = CrystalClick::CompactMarkFormat::Mrk3,
  discriminator_mode : CrystalClick::CompactVariantDiscriminatorMode = CrystalClick::CompactVariantDiscriminatorMode::Compact,
) : String
  CrystalClick::CompactPartWriter.write_uint64_columns(
    part_path,
    CompactPartWriterW272Fixture::KEY_NAME,
    CompactPartWriterW272Fixture::KEYS,
    columns,
    rows_per_mark: CompactPartWriterW272Fixture::ROWS_PER_MARK,
    frame_bytes: CompactPartWriterW272Fixture::FRAME_BYTES,
    mark_format: mark_format,
    variant_discriminator_mode: discriminator_mode,
  )
end

private def w272a_bindings(
  actuals : CrystalClick::DynamicStructure,
  actual_type : CrystalClick::BinaryDataType,
  child_path : Array(Int32),
  child_plan : CrystalClick::ObjectDocumentPlan,
) : Hash(String, Array(W272ALeafPlan))
  key = CrystalClick::BinaryDynamicJsonLeafKey.new(
    CompactPartWriterW272Fixture::SITE_PATH,
    actuals.canonical_index_for(actual_type),
    [] of Int32,
  )
  child_path.each do |index|
    key = key.with_child(index)
  end
  {
    CompactPartWriterW272Fixture::PAYLOAD_PATH => ([{key, child_plan}] of W272ALeafPlan),
  } of String => Array(W272ALeafPlan)
end

private def w272a_plan(
  actuals : CrystalClick::DynamicStructure,
  bindings : Hash(String, Array(W272ALeafPlan)),
) : CrystalClick::ObjectDocumentPlan
  fixture = CompactPartWriterW272Fixture
  base = fixture.object_plan
  CrystalClick::ObjectDocumentPlan.new(
    base.structures,
    base.typed_paths,
    {CompactPartWriterW272Fixture::PAYLOAD_PATH => actuals} of String => CrystalClick::DynamicStructure,
    typed_dynamic_json_object_leaf_plans: bindings,
  )
end

private def w272a_column(
  plan : CrystalClick::ObjectDocumentPlan,
  rows : Array(CrystalClick::StorageColumnValue) = CompactPartWriterW272Fixture.rows,
) : CrystalClick::CompactPartColumn
  fixture = CompactPartWriterW272Fixture
  context = CrystalClick::CompactJsonWriteContext.new(
    {CompactPartWriterW272Fixture::SITE_PATH => plan} of String => CrystalClick::ObjectDocumentPlan,
  )
  CrystalClick::CompactPartColumn.json(
    CompactPartWriterW272Fixture::COLUMN_NAME,
    fixture.schema,
    fixture.granules(rows),
    context,
  )
end

private def w272a_refuse_without_publish(&write : String -> String) : Nil
  parent = File.tempname("crystal-click-w272-refusal-")
  part_path = File.join(parent, "all_1_1_0")
  begin
    Dir.mkdir(parent)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      yield part_path
    end
    File.exists?(part_path).should be_false
    Dir.children(parent).should be_empty
  ensure
    FileUtils.rm_rf(parent)
  end
  nil
end

private def w272a_expect_constructor_refusal_without_publish(&build : String ->) : Nil
  parent = File.tempname("crystal-click-w272-constructor-refusal-")
  part_path = File.join(parent, "all_1_1_0")
  begin
    Dir.mkdir(parent)
    expect_raises(ArgumentError) do
      yield part_path
    end
    File.exists?(part_path).should be_false
    Dir.children(parent).should be_empty
  ensure
    FileUtils.rm_rf(parent)
  end
  nil
end

private def w272a_json(value : UInt8) : CrystalClick::BinaryValue
  fixture = CompactPartWriterW272Fixture
  cell = CrystalClick::BinaryValue.fixed(fixture.uint8_type, Bytes[value])
  row = CrystalClick::BinaryJsonRow.new(
    fixture.json_type,
    [{CompactPartWriterW272Fixture::VALUE_PATH, cell}] of Tuple(String, CrystalClick::BinaryValue),
  )
  CrystalClick::BinaryValue.json(fixture.json_type, row)
end

private def w272a_wrapped_actual_column(kind : Symbol)
  fixture = CompactPartWriterW272Fixture
  actual_type = fixture.array_json_type
  child_path = [] of Int32
  case kind
  when :nested_array
    actual_type = CrystalClick::BinaryDataType.array(fixture.array_json_type)
    child_path = [0_i32, 0_i32] of Int32
  when :tuple
    actual_type = CrystalClick::BinaryDataType.tuple(
      [fixture.array_json_type] of CrystalClick::BinaryDataType,
    )
    child_path = [0_i32, 0_i32] of Int32
  when :nullable
    actual_type = CrystalClick::BinaryDataType.nullable(fixture.array_json_type)
    child_path = [0_i32, 0_i32] of Int32
  when :low_cardinality
    actual_type = CrystalClick::BinaryDataType.low_cardinality(fixture.array_json_type)
    child_path = [0_i32, 0_i32] of Int32
  else
    raise ArgumentError.new("unknown W272 wrapped actual kind")
  end

  actuals = CrystalClick::DynamicStructure.new(
    [actual_type] of CrystalClick::BinaryDataType,
    CrystalClick::StructureStatistics.new(
      [4_u64, 0_u64] of UInt64,
      [] of CrystalClick::StructureStatistic,
    ),
    version: CrystalClick::DynamicStructure::VERSION_V3,
  )
  child_plan = fixture.json_bindings[CompactPartWriterW272Fixture::PAYLOAD_PATH][0][1]
  bindings = w272a_bindings(actuals, actual_type, child_path, child_plan)
  plan = w272a_plan(actuals, bindings)
  rows = fixture.expected_literals.map do |values|
    selected = if elements = values
                 json_values = Array(CrystalClick::BinaryValue).new(elements.size)
                 elements.each { |element| json_values << w272a_json(element) }
                 array = CrystalClick::BinaryValue.array(fixture.array_json_type, json_values)
                 case kind
                 when :nested_array
                   CrystalClick::BinaryValue.array(actual_type, [array] of CrystalClick::BinaryValue)
                 when :tuple
                   CrystalClick::BinaryValue.tuple(actual_type, [array] of CrystalClick::BinaryValue)
                 when :nullable
                   CrystalClick::BinaryValue.nullable(actual_type, array)
                 when :low_cardinality
                   CrystalClick::BinaryValue.low_cardinality(actual_type, array)
                 else
                   raise ArgumentError.new("unknown W272 wrapped actual kind")
                 end
               else
                 nil
               end
    payload = CrystalClick::BinaryValue.dynamic(fixture.dynamic_type, selected)
    CrystalClick::StorageColumnValue.object_document(
      CrystalClick::ObjectDocument.new(
        {CompactPartWriterW272Fixture::PAYLOAD_PATH => payload} of String => CrystalClick::BinaryValue,
      ),
    )
  end
  column = w272a_column(plan, rows)
  {column: column, plan: plan, rows: rows, bindings: bindings, actual_type: actual_type}
end

private def w272a_common_codec_control!(
  plan : CrystalClick::ObjectDocumentPlan,
  rows : Array(CrystalClick::StorageColumnValue),
  bindings : Hash(String, Array(W272ALeafPlan)),
  actual_type : CrystalClick::BinaryDataType,
) : Nil
  fixture = CompactPartWriterW272Fixture
  semantic_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
  documents = fixture.granules(rows).map do |mark_rows|
    mark_rows.map(&.object_document)
  end
  streams = CrystalClick::ObjectDocumentCodec.encode(plan, documents)
  decoded = CrystalClick::ObjectDocumentCodec.decode(
    fixture.schema.object_schema.typed_paths,
    streams,
    typed_dynamic_json_object_leaf_plans: bindings,
  )
  decoded.size.should eq(CompactPartWriterW272Fixture::MARK_COUNT)
  decoded.each_with_index do |mark_rows, mark_index|
    mark_rows.size.should eq(CompactPartWriterW272Fixture::ROWS_PER_MARK)
    mark_rows.each_with_index do |document, row_index|
      source_row = rows[mark_index * CompactPartWriterW272Fixture::ROWS_PER_MARK + row_index]
      source_payload = source_row.object_document.value_for(CompactPartWriterW272Fixture::PAYLOAD_PATH)
      payload = document.value_for(CompactPartWriterW272Fixture::PAYLOAD_PATH)
      payload.type.should eq(fixture.dynamic_type)
      if source_payload.is_null?
        payload.is_null?.should be_true
      else
        payload.is_null?.should be_false
        payload.child_count.should eq(1)
        payload.child_at(0).type.should eq(actual_type)
      end
      CrystalClick::CompactPartValueComparison.binary!(payload, source_payload, semantic_budget)
    end
  end
  nil
end

describe "W272 Compact typed-Dynamic Array(JSON) admission adversaries" do
  it "rejects wrong leaf coordinates and descriptor bindings at construction before publication" do
    fixture = CompactPartWriterW272Fixture
    child_plan = fixture.json_bindings[CompactPartWriterW272Fixture::PAYLOAD_PATH][0][1]

    w272a_expect_constructor_refusal_without_publish do |_part_path|
      actuals = fixture.actuals
      wrong_coordinate = w272a_bindings(actuals, fixture.array_json_type, [1_i32] of Int32, child_plan)
      w272a_plan(actuals, wrong_coordinate)
    end

    w272a_expect_constructor_refusal_without_publish do |_part_path|
      uint8_array = CrystalClick::BinaryDataType.array(fixture.uint8_type)
      actuals = CrystalClick::DynamicStructure.new(
        [uint8_array] of CrystalClick::BinaryDataType,
        CrystalClick::StructureStatistics.new(
          [4_u64, 0_u64] of UInt64,
          [] of CrystalClick::StructureStatistic,
        ),
        version: CrystalClick::DynamicStructure::VERSION_V3,
      )
      wrong_descriptor = w272a_bindings(actuals, uint8_array, [0_i32] of Int32, child_plan)
      w272a_plan(actuals, wrong_descriptor)
    end
  end

  it "rejects missing caller-owned complete V3 statistics at write-context construction" do
    fixture = CompactPartWriterW272Fixture
    child_plan = fixture.json_bindings[CompactPartWriterW272Fixture::PAYLOAD_PATH][0][1]
    w272a_expect_constructor_refusal_without_publish do |_part_path|
      actuals = CrystalClick::DynamicStructure.new(
        [fixture.array_json_type] of CrystalClick::BinaryDataType,
        version: CrystalClick::DynamicStructure::VERSION_V3,
      )
      bindings = w272a_bindings(actuals, fixture.array_json_type, [0_i32] of Int32, child_plan)
      w272a_column(w272a_plan(actuals, bindings))
    end
  end

  it "refuses a valid but out-of-profile child Object without staging residue" do
    fixture = CompactPartWriterW272Fixture
    exact_bindings = fixture.json_bindings
    key, child_plan = exact_bindings[CompactPartWriterW272Fixture::PAYLOAD_PATH][0]
    advanced_object = CrystalClick::ObjectStructure.new(
      [] of String,
      version: 4_u64,
      shared_data_version: 2_u64,
      bucket_count: 2_u64,
      statistics: CrystalClick::StructureStatistics.new(
        [] of UInt64,
        [] of CrystalClick::StructureStatistic,
      ),
    )
    advanced_child = CrystalClick::ObjectDocumentPlan.new(
      CrystalClick::ObjectDynamicStructureSet.new(
        advanced_object,
        Hash(String, CrystalClick::DynamicStructure).new,
      ),
      child_plan.typed_paths,
    )
    bindings = {
      CompactPartWriterW272Fixture::PAYLOAD_PATH => ([{key, advanced_child}] of W272ALeafPlan),
    } of String => Array(W272ALeafPlan)
    column = w272a_column(w272a_plan(fixture.actuals, bindings))

    w272a_refuse_without_publish do |part_path|
      w272a_write(part_path, [column] of CrystalClick::CompactPartColumn)
    end
  end

  it "keeps deeper arrays and tuple wrappers outside the one-Array grant" do
    [:nested_array, :tuple].each do |kind|
      witness = w272a_wrapped_actual_column(kind)
      w272a_common_codec_control!(
        witness[:plan],
        witness[:rows],
        witness[:bindings],
        witness[:actual_type],
      )
      w272a_refuse_without_publish do |part_path|
        w272a_write(part_path, [witness[:column]] of CrystalClick::CompactPartColumn)
      end
    end
  end

  it "rejects structurally forbidden Nullable and LowCardinality Array(JSON) descriptors at construction" do
    [:nullable, :low_cardinality].each do |kind|
      w272a_expect_constructor_refusal_without_publish do |_part_path|
        w272a_wrapped_actual_column(kind)
      end
    end
  end
end
