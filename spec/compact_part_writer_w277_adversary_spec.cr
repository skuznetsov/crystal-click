require "./spec_helper"
require "file_utils"
require "./support/compact_part_writer_w277_fixture"
require "./support/compact_part_writer_w269_fixture"

private def w277_reject_dynamic_profile_binding(
  input_profile : CrystalClick::BinaryBulkProfile,
  plan_profile : CrystalClick::BinaryBulkProfile,
  metadata_profile : CrystalClick::BinaryBulkProfile,
) : Nil
  fixture = CompactPartWriterW277Fixture
  limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
  selected_column = fixture.columns(:map).first
  metadata_input = selected_column.dynamic_input(input_profile)
  planned_input = selected_column.dynamic_input(plan_profile)
  key_granules = [[CrystalClick::BinaryValue.uint64(1_u64)] of CrystalClick::BinaryValue] of Array(CrystalClick::BinaryValue)
  key_input = CrystalClick::CompactStaticColumnInput.new(
    CompactPartWriterW277Fixture::KEY_NAME,
    fixture.uint64_type,
    key_granules,
    metadata_profile,
  )
  planned_columns = Array(CrystalClick::CompactPartWriteInput).new(2)
  planned_columns << key_input
  planned_columns << planned_input
  codec_budget = CrystalClick::BinaryCodecBudget.new(limits, true)
  write_plan = CrystalClick::CompactPartWritePlan.new(
    planned_columns,
    limits,
    codec_budget,
    CrystalClick::CompactMarkFormat::Mrk4,
  )
  CrystalClick::CompactPartMetadata.new(
    CompactPartWriterW277Fixture::KEY_NAME,
    [metadata_input] of CrystalClick::CompactDynamicColumnInput,
    CompactPartWriterW277Fixture::ROW_COUNT.to_u64,
    limits,
    CrystalClick::BinaryCodecBudget.new(limits, true),
    CrystalClick::CompressedStreamBudget.new(CrystalClick::CompressedStreamLimits.new, true),
    write_plan,
    false,
    metadata_profile,
  )
  nil
end

private def w277_reject_json_profile_binding(
  input_profile : CrystalClick::BinaryBulkProfile,
  plan_profile : CrystalClick::BinaryBulkProfile,
  metadata_profile : CrystalClick::BinaryBulkProfile,
) : Nil
  fixture = CompactPartWriterW277Fixture
  limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
  selected_column = fixture.columns(:map)[2]
  metadata_input = selected_column.json_input(input_profile)
  planned_input = selected_column.json_input(plan_profile)
  key_granules = [[CrystalClick::BinaryValue.uint64(1_u64)] of CrystalClick::BinaryValue] of Array(CrystalClick::BinaryValue)
  key_input = CrystalClick::CompactStaticColumnInput.new(
    CompactPartWriterW277Fixture::KEY_NAME,
    fixture.uint64_type,
    key_granules,
    metadata_profile,
  )
  planned_columns = Array(CrystalClick::CompactPartWriteInput).new(2)
  planned_columns << key_input
  planned_columns << planned_input
  codec_budget = CrystalClick::BinaryCodecBudget.new(limits, true)
  write_plan = CrystalClick::CompactPartWritePlan.new(
    planned_columns,
    limits,
    codec_budget,
    CrystalClick::CompactMarkFormat::Mrk4,
  )
  CrystalClick::CompactPartMetadata.new(
    CompactPartWriterW277Fixture::KEY_NAME,
    [metadata_input] of CrystalClick::CompactJsonColumnInput,
    CompactPartWriterW277Fixture::ROW_COUNT.to_u64,
    limits,
    CrystalClick::BinaryCodecBudget.new(limits, true),
    CrystalClick::CompressedStreamBudget.new(CrystalClick::CompressedStreamLimits.new, true),
    write_plan,
    false,
    metadata_profile,
  )
  nil
end

private def w277_expect_public_refusal(
  columns : Array(CrystalClick::CompactPartColumn),
  profile : CrystalClick::BinaryBulkProfile = CrystalClick::BinaryBulkProfile.with_size_stream,
  transport_limits : CrystalClick::CompressedStreamLimits = CrystalClick::CompressedStreamLimits.new,
) : Nil
  fixture = CompactPartWriterW277Fixture
  parent = File.tempname("crystal-click-w277-refusal-")
  part_path = File.join(parent, "all_1_1_0")
  begin
    Dir.mkdir(parent)
    File.write(File.join(parent, "keep.txt"), "unrelated")
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::CompactPartWriter.write_uint64_columns(
        part_path,
        CompactPartWriterW277Fixture::KEY_NAME,
        fixture.keys,
        columns,
        rows_per_mark: CompactPartWriterW277Fixture::ROWS_PER_MARK,
        frame_bytes: CompactPartWriterW277Fixture::FRAME_BYTES,
        mark_format: CrystalClick::CompactMarkFormat::Mrk4,
        profile: profile,
        transport_limits: transport_limits,
      )
    end
    File.exists?(part_path).should be_false
    Dir.children(parent).sort.should eq(["keep.txt"])
    File.read(File.join(parent, "keep.txt")).should eq("unrelated")
  ensure
    FileUtils.rm_rf(parent)
  end
  nil
end

private def w277_root_dynamic_json_column : CrystalClick::CompactPartColumn
  fixture = CompactPartWriterW277Fixture
  actual_type = fixture.typed_json_leaf_type
  dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 1)
  json_actual = CrystalClick::BinaryValue.json(
    actual_type,
    CrystalClick::BinaryJsonRow.new(
      actual_type,
      [{CompactPartWriterW277Fixture::VALUE_PATH, CrystalClick::BinaryValue.string("root-json-actual")}] of Tuple(String, CrystalClick::BinaryValue),
    ),
  )
  rows = Array(CrystalClick::BinaryValue).new(CompactPartWriterW277Fixture::ROW_COUNT)
  rows << CrystalClick::BinaryValue.dynamic(dynamic_type, json_actual)
  (CompactPartWriterW277Fixture::ROW_COUNT - 1).times do
    rows << CrystalClick::BinaryValue.dynamic(dynamic_type)
  end
  granules = Array(Array(CrystalClick::BinaryValue)).new(CompactPartWriterW277Fixture::MARK_COUNT)
  CompactPartWriterW277Fixture::MARK_COUNT.times do |mark|
    start = mark * CompactPartWriterW277Fixture::ROWS_PER_MARK
    granules << rows[start, CompactPartWriterW277Fixture::ROWS_PER_MARK]
  end
  structure = CrystalClick::DynamicStructure.new(
    [actual_type] of CrystalClick::BinaryDataType,
    CrystalClick::StructureStatistics.new([0_u64, 1_u64] of UInt64, [] of CrystalClick::StructureStatistic),
    version: CrystalClick::DynamicStructure::VERSION_V3,
  )
  context = CrystalClick::CompactDynamicWriteContext.new(
    {CompactPartWriterW277Fixture::ROOT_SITE => structure} of String => CrystalClick::DynamicStructure,
  )
  CrystalClick::CompactPartColumn.dynamic_bulk(
    "root_dynamic_json_actual",
    dynamic_type,
    granules,
    context,
  )
end

describe "W277 propagated String1 Compact context adversaries" do
  it "binds the nested JSON layout at the matching parent profile without weakening child identity" do
    fixture = CompactPartWriterW277Fixture
    limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
    sized = CrystalClick::BinaryBulkProfile.with_size_stream
    single = CrystalClick::BinaryBulkProfile.single_stream
    prepared = fixture.typed_dynamic_bulk_plan(sized, :map)
    physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(prepared, "w277_typed_dynamic")
    read_budget = CrystalClick::BinaryCodecBudget.new(limits, false)

    # A matching String1 parent is admitted through the same JSON-leaf layout
    # comparator used by the authenticated MRK3 tape reader.
    physical.same_prepared_layout?(prepared, read_budget).should be_true

    # Profile equality remains exact: the String0 candidate must not be
    # authenticated against a String1 physical roster.
    single_profile = fixture.typed_dynamic_bulk_plan(single, :map)
    physical.same_prepared_layout?(single_profile, read_budget).should be_false

    # The child Object layout remains MAP0-only for this typed-Dynamic tape
    # owner, even when the parent profile is valid String1.
    changed_child_layout = fixture.typed_dynamic_bulk_plan(sized, :map_with_buckets)
    physical.same_prepared_layout?(changed_child_layout, read_budget).should be_false
  end

  it "keeps the nested Object SharedData codec on String0 under a String1 parent" do
    fixture = CompactPartWriterW277Fixture
    limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
    sized_input = fixture.columns(:map)[2].json_input(CrystalClick::BinaryBulkProfile.with_size_stream)
    callback_plan = CrystalClick::CompactJsonCallbackPlan.new(
      sized_input,
      limits,
      CrystalClick::BinaryCodecBudget.new(limits, true),
    )
    physical = callback_plan.site_binding(CompactPartWriterW277Fixture::ROOT_SITE).physical_plan

    callback_plan.profile.with_size_stream?.should be_true
    physical.shared_profile.single_stream?.should be_true
  end

  it "rejects stale context inputs and callback plans against the selected metadata profile" do
    single = CrystalClick::BinaryBulkProfile.single_stream
    sized = CrystalClick::BinaryBulkProfile.with_size_stream

    expect_raises(CrystalClick::UnsupportedFormatError) do
      w277_reject_dynamic_profile_binding(single, single, sized)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      w277_reject_dynamic_profile_binding(sized, single, sized)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      w277_reject_json_profile_binding(single, single, sized)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      w277_reject_json_profile_binding(sized, single, sized)
    end
  end

  it "retains both advanced Object shared-version gates under String0 and String1" do
    fixture = CompactPartWriterW269Fixture
    profiles = [
      CrystalClick::BinaryBulkProfile.single_stream,
      CrystalClick::BinaryBulkProfile.with_size_stream,
    ] of CrystalClick::BinaryBulkProfile
    [2_u64, 3_u64].each do |shared_version|
      advanced_plan = fixture.object_plan(
        1_u64,
        1_u64,
        0_u64,
        CrystalClick::DynamicStructure::VERSION_V3,
        shared_version,
        2_u64,
      )
      advanced_context = CrystalClick::CompactJsonWriteContext.new(
        {CompactPartWriterW269Fixture::ROOT_SITE => advanced_plan} of String => CrystalClick::ObjectDocumentPlan,
      )
      advanced_column = CrystalClick::CompactPartColumn.json(
        CompactPartWriterW269Fixture::ROOT_COLUMN,
        fixture.json_schema,
        fixture.granules(fixture.root_rows),
        advanced_context,
      )
      profiles.each do |profile|
        w277_expect_public_refusal([advanced_column] of CrystalClick::CompactPartColumn, profile)
      end
    end
  end

  it "keeps the outer recursive JSON ordinary-leaf carrier UInt8-only under String1" do
    json_type = CompactPartWriterW269Fixture.json_type
    supported = CrystalClick::StorageColumnSchema.parse(
      "Array(Tuple(#{json_type.name}, UInt8))",
    )
    unsupported = CrystalClick::StorageColumnSchema.parse(
      "Array(Tuple(#{json_type.name}, String))",
    )
    CrystalClick::CompactRecursiveJsonSchemaPlan.admitted_schema?(supported).should be_true
    CrystalClick::CompactRecursiveJsonSchemaPlan.admitted_schema?(unsupported).should be_false

    # Construct the String1-bound input directly so the existing schema gate
    # is exercised in the selected context profile before any writer stage.
    sized = CrystalClick::BinaryBulkProfile.with_size_stream
    context = CompactPartWriterW277Fixture.columns(:map)[2].json_input(sized).json_context
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::CompactJsonColumnInput.new(
        "outer_string_generic_leaf",
        unsupported,
        [] of Array(CrystalClick::StorageColumnValue),
        context,
        profile: sized,
      )
    end
  end

  it "retains the root Dynamic JSON-actual owner refusal under String1" do
    w277_expect_public_refusal(
      [w277_root_dynamic_json_column] of CrystalClick::CompactPartColumn,
      CrystalClick::BinaryBulkProfile.with_size_stream,
    )
  end

  it "retains the typed-Dynamic MAP child intersection" do
    typed_child = CompactPartWriterW277Fixture.typed_dynamic_json_column(:map_with_buckets)
    w277_expect_public_refusal([typed_child] of CrystalClick::CompactPartColumn)
  end

  it "preserves resource refusal before publication for a String1 JSON body" do
    columns = CompactPartWriterW277Fixture.columns(:map)
    w277_expect_public_refusal(
      columns,
      transport_limits: CrystalClick::CompressedStreamLimits.new(max_result_bytes: 1),
    )
  end
end
