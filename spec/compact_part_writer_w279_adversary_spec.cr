require "./spec_helper"
require "file_utils"
require "./support/compact_part_writer_w279_fixture"
require "./support/compact_part_writer_w278_fixture"

private struct W279AdvancedChildCapture
  getter budget : CrystalClick::BinaryCodecBudget
  getter child_owner : CrystalClick::CompactJsonObjectRoleSchedule::OwnerSchedule
  getter child_prefix : CrystalClick::ObjectDocumentInlinePrefix
  getter limits : CrystalClick::BinaryCodecLimits
  getter physical_plan : CrystalClick::ObjectDocumentPhysicalPlan
  getter prefix : CrystalClick::ObjectDocumentCallbackPrefix
  getter profile : CrystalClick::BinaryBulkProfile
  getter schedule : CrystalClick::CompactJsonObjectRoleSchedule

  def initialize(
    @budget : CrystalClick::BinaryCodecBudget,
    @child_owner : CrystalClick::CompactJsonObjectRoleSchedule::OwnerSchedule,
    @child_prefix : CrystalClick::ObjectDocumentInlinePrefix,
    @limits : CrystalClick::BinaryCodecLimits,
    @physical_plan : CrystalClick::ObjectDocumentPhysicalPlan,
    @prefix : CrystalClick::ObjectDocumentCallbackPrefix,
    @profile : CrystalClick::BinaryBulkProfile,
    @schedule : CrystalClick::CompactJsonObjectRoleSchedule,
  )
  end
end

private def w279_write_advanced_child_part(part_path : String) : String
  fixture = CompactPartWriterW279Fixture
  CrystalClick::CompactPartWriter.write_uint64_columns(
    part_path,
    CompactPartWriterW279Fixture::KEY_NAME,
    fixture.keys,
    [fixture.column(2, 2_u64)] of CrystalClick::CompactPartColumn,
    rows_per_mark: CompactPartWriterW279Fixture::ROWS_PER_MARK,
    frame_bytes: 64,
    mark_format: CrystalClick::CompactMarkFormat::Mrk4,
    variant_discriminator_mode: CrystalClick::CompactVariantDiscriminatorMode::Basic,
  )
end

private def w279_capture_advanced_child(part_path : String) : W279AdvancedChildCapture
  fixture = CompactPartWriterW279Fixture
  limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
  physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
  granule = physical.read_window(CompactPartWriterW279Fixture::COLUMN_NAME, 0, 1).granules.first
  budget = CrystalClick::BinaryCodecBudget.new(limits)
  profile = CrystalClick::CompactStaticJsonBulkColumnReader.open(
    part_path,
    CompactPartWriterW279Fixture::COLUMN_NAME,
    fixture.declared_json_type,
  ).ordinary_profile
  manifest = CrystalClick::CompactStaticJsonSiteManifest.new(
    CompactPartWriterW279Fixture::COLUMN_NAME,
    fixture.declared_json_type,
  )
  framer = CrystalClick::CompactJsonObjectSiteFramer.new(
    physical.mode,
    granule.shards,
    budget,
    physical,
    "#{manifest.physical_prefix}:mark=#{granule.mark}",
  )
  prefix = CrystalClick::ObjectDocumentCallbackPrefixReader.read_static_json_prefix(
    framer,
    fixture.declared_json_type,
    1_i32,
    manifest.physical_prefix,
    manifest.callback_prefix,
    0_u64,
    CrystalClick::ObjectSharedNestedSerializationContext.for_read(2_u64, profile),
    budget,
    true,
  )
  physical_plan = CrystalClick::ObjectDocumentPhysicalPlan.from_escaped_prefix(
    manifest.physical_prefix,
    prefix.plan,
    profile,
    CrystalClick::BinaryBulkProfile.single_stream,
    limits,
    prefix.array_level,
    typed_descriptor_root_depth: prefix.typed_descriptor_root_depth,
    inferred_actual_root_depth: prefix.inferred_actual_root_depth,
    root_dynamic_json_budget: budget,
  )
  prefix.bind_physical_plan!(physical_plan)
  schedule = CrystalClick::CompactJsonObjectRoleSchedule.build(prefix, physical_plan, profile, budget)
  schedule.begin_body_capture!(budget)
  schedule.capture_physical_body_events!(framer, budget)
  schedule.finish_body_capture!(budget)
  framer.validate_expected_events!(schedule.physical_event_names(budget), schedule.event_names)
  framer.finish!

  key = fixture.json_bindings(2, 2_u64)[CompactPartWriterW279Fixture::PAYLOAD_PATH].first[0]
  child_prefix = prefix.typed_dynamic_json_prefixes_for(CompactPartWriterW279Fixture::PAYLOAD_PATH)[key]
  child_owner = schedule.owner_for_root(child_prefix.physical_prefix)
  child_owner.parent_key.should eq(key)
  W279AdvancedChildCapture.new(
    budget,
    child_owner,
    child_prefix,
    limits,
    physical_plan,
    prefix,
    profile,
    schedule,
  )
end

private def w279_child_advanced_grammar(capture : W279AdvancedChildCapture) : CrystalClick::CompactJsonObjectSharedAdvancedTapeGrammar
  CrystalClick::CompactJsonObjectSharedAdvancedTapeGrammar.new(
    capture.child_prefix,
    capture.child_owner.physical_plan,
    capture.schedule,
    3_u64,
    capture.profile,
    capture.limits,
    CrystalClick::BinaryCodecBudget.new(capture.limits),
  )
end

private def w279_clone_child_prefix(
  capture : W279AdvancedChildCapture,
  key : CrystalClick::BinaryDynamicJsonLeafKey,
  nested_context : CrystalClick::ObjectSharedNestedSerializationContext,
  incomplete_body : Bool = false,
) : CrystalClick::ObjectDocumentInlinePrefix
  source = capture.child_prefix
  budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS)
  prefix_callbacks = Array(Tuple(String, Bytes)).new(source.prefix_callback_count)
  source.prefix_callback_count.times do |index|
    prefix_callbacks << source.prefix_callback_at(index, budget)
  end

  empty_dynamic_sites = Hash(String, Hash(String, CrystalClick::DynamicStructure)).new
  empty_dynamic_plans = Hash(String, CrystalClick::BinaryDynamicBulkPlan).new
  empty_json_prefixes = Hash(
    String,
    CrystalClick::ObjectSharedPathJsonTapeCodec::PrefixMap,
  ).new
  clone = CrystalClick::ObjectDocumentInlinePrefix.new(
    key,
    source.descriptor,
    source.json_descriptor_depth,
    source.typed_descriptor_root_depth,
    source.inferred_actual_root_depth,
    source.physical_prefix,
    source.callback_prefix,
    source.array_level,
    nested_context,
    source.object_structure_statistics_offset,
    source.statistics_offsets_snapshot(budget),
    source.plan,
    source.structures,
    prefix_callbacks,
    empty_dynamic_sites,
    empty_dynamic_sites,
    empty_dynamic_plans,
    empty_dynamic_plans,
    empty_json_prefixes,
    source.statistics_context,
    empty_json_prefixes,
  )
  clone.bind_physical_plan!(source.physical_plan)
  clone.bind_body_schedule!(capture.child_owner.body_bindings.dup, capture.child_owner.body_pairs.dup)
  if incomplete_body
    clone.start_body_capture!
  else
    callbacks = Array(Tuple(String, Bytes)).new(source.body_callback_count)
    slices = Array(CrystalClick::ObjectSharedInlineCallbackReadSlice).new(source.body_callback_slice_count)
    source.body_callback_count.times do |index|
      callbacks << source.body_callback_at(index, budget)
      slices << source.body_callback_slice_at(index)
    end
    clone.bind_body_callbacks!(callbacks, slices)
  end
  clone
end

private def w279_object_structure(
  shared_version : UInt64,
  bucket_count : UInt64,
  object_version : UInt64 = 4_u64,
) : CrystalClick::ObjectDynamicStructureSet
  statistics = CrystalClick::StructureStatistics.new(
    [] of UInt64,
    [] of CrystalClick::StructureStatistic,
  )
  object = CrystalClick::ObjectStructure.new(
    [] of String,
    version: object_version,
    shared_data_version: shared_version,
    bucket_count: bucket_count,
    statistics: statistics,
  )
  CrystalClick::ObjectDynamicStructureSet.new(
    object,
    Hash(String, CrystalClick::DynamicStructure).new,
  )
end

private def w279_column_with_child_layout(
  parent_shared_version : UInt64,
  parent_bucket_count : UInt64,
  child_shared_version : UInt64,
  child_bucket_count : UInt64,
  child_object_version : UInt64 = 4_u64,
) : CrystalClick::CompactPartColumn
  fixture = CompactPartWriterW279Fixture
  actuals = fixture.actuals(0)
  key = CrystalClick::BinaryDynamicJsonLeafKey.new(
    "root",
    actuals.canonical_index_for(fixture.actual_type(0)),
    [] of Int32,
  )
  child_plan = CrystalClick::ObjectDocumentPlan.new(
    w279_object_structure(child_shared_version, child_bucket_count, child_object_version),
    fixture.json_type.json_type.not_nil!.typed_paths,
  )
  parent_plan = CrystalClick::ObjectDocumentPlan.new(
    w279_object_structure(parent_shared_version, parent_bucket_count),
    fixture.schema.object_schema.typed_paths,
    {CompactPartWriterW279Fixture::PAYLOAD_PATH => actuals} of String => CrystalClick::DynamicStructure,
    typed_dynamic_json_object_leaf_plans: {
      CompactPartWriterW279Fixture::PAYLOAD_PATH => [{key, child_plan}] of CompactPartWriterW279Fixture::LeafPlan,
    } of String => Array(CompactPartWriterW279Fixture::LeafPlan),
  )
  context = CrystalClick::CompactJsonWriteContext.new(
    {CompactPartWriterW279Fixture::SITE_PATH => parent_plan} of String => CrystalClick::ObjectDocumentPlan,
  )
  CrystalClick::CompactPartColumn.json(
    CompactPartWriterW279Fixture::COLUMN_NAME,
    fixture.schema,
    fixture.granules(0),
    context,
  )
end

private def w279_expect_layout_refusal(column : CrystalClick::CompactPartColumn) : Nil
  limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
  budget = CrystalClick::BinaryCodecBudget.new(limits, true)
  expect_raises(CrystalClick::UnsupportedFormatError) do
    CrystalClick::CompactJsonCallbackPlan.new(column.json_input, limits, budget)
  end
  nil
end

describe "W279 typed-Dynamic JSON child admission adversaries" do
  it "retains W278 static JSON owner reads on MRK3 Advanced layouts" do
    fixture = CompactPartWriterW278Fixture
    parent = File.tempname("crystal-click-w279-w278-static-mrk3-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      CrystalClick::CompactPartWriter.write_uint64_columns(
        part_path,
        CompactPartWriterW278Fixture::KEY_NAME,
        fixture.keys,
        fixture.columns(2_u64),
        rows_per_mark: CompactPartWriterW278Fixture::ROWS_PER_MARK,
        frame_bytes: 64,
        mark_format: CrystalClick::CompactMarkFormat::Mrk3,
        profile: CrystalClick::BinaryBulkProfile.single_stream,
      ).should eq(part_path)

      fixture.schemas.each do |column_name, schema|
        reader = CrystalClick::CompactRecursiveJsonColumnReader.open(part_path, column_name, schema)
        expected = fixture.rows_for(column_name)
        actual = reader.read_marks(0, reader.mark_count).flatten
        actual.size.should eq(expected.size)
        actual.each_with_index do |value, index|
          budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, false)
          CrystalClick::CompactPartValueComparison.storage!(value, expected[index], budget)
        end
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects mismatched Object versions and every unsealed parent or child bucket tuple" do
    # Same Object V3 version, but a different parent's/child's SharedData
    # version must not be silently normalized to the root's layout.
    w279_expect_layout_refusal(w279_column_with_child_layout(1_u64, 2_u64, 2_u64, 2_u64))

    # SharedData v2's sealed tuple is exactly two buckets at both owners.
    w279_expect_layout_refusal(w279_column_with_child_layout(2_u64, 2_u64, 2_u64, 1_u64))
    w279_expect_layout_refusal(w279_column_with_child_layout(1_u64, 1_u64, 1_u64, 2_u64))

    # A legacy Object wire-2 MAP prefix is not the admitted Object V3 child,
    # even though its effective MAP bucket count matches the parent.
    w279_expect_layout_refusal(w279_column_with_child_layout(0_u64, 1_u64, 0_u64, 1_u64, 2_u64))
  end

  it "rejects child prefixes with a foreign key, inherited profile, missing binding, or incomplete capture" do
    parent = File.tempname("crystal-click-w279-child-binding-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      w279_write_advanced_child_part(part_path).should eq(part_path)
      capture = w279_capture_advanced_child(part_path)
      key = capture.child_prefix.key
      prefixes = capture.prefix.typed_dynamic_json_prefixes_for(CompactPartWriterW279Fixture::PAYLOAD_PATH)
      original = prefixes[key]

      wrong_key = CrystalClick::BinaryDynamicJsonLeafKey.new(
        key.dynamic_site,
        key.canonical_arm_index,
        [0_i32, 1_i32],
      )
      prefixes[key] = w279_clone_child_prefix(
        capture,
        wrong_key,
        original.nested_context,
      )
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::ObjectDocumentTypedDynamicJsonReadContext.from_prefix(
          capture.prefix,
          CrystalClick::BinaryCodecBudget.new(capture.limits),
        )
      end

      prefixes[key] = w279_clone_child_prefix(
        capture,
        key,
        CrystalClick::ObjectSharedNestedSerializationContext.for_read(
          2_u64,
          CrystalClick::BinaryBulkProfile.with_size_stream,
        ),
      )
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentTypedDynamicJsonReadContext.from_prefix(
          capture.prefix,
          CrystalClick::BinaryCodecBudget.new(capture.limits),
        )
      end

      prefixes.delete(key)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::ObjectDocumentTypedDynamicJsonReadContext.from_prefix(
          capture.prefix,
          CrystalClick::BinaryCodecBudget.new(capture.limits),
        )
      end

      prefixes[key] = w279_clone_child_prefix(
        capture,
        key,
        original.nested_context,
        true,
      )
      expect_raises(ArgumentError) do
        CrystalClick::ObjectDocumentTypedDynamicJsonReadContext.from_prefix(
          capture.prefix,
          CrystalClick::BinaryCodecBudget.new(capture.limits),
        )
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "binds Advanced validation to the exact child schedule rather than the root roster" do
    parent = File.tempname("crystal-click-w279-owner-local-schedule-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      w279_write_advanced_child_part(part_path).should eq(part_path)
      capture = w279_capture_advanced_child(part_path)
      child_bindings = capture.child_owner.body_bindings
      original_bindings = child_bindings.dup
      advanced_indices = [] of Int32
      child_bindings.each_with_index do |binding, index|
        if binding[1] == :advanced_bucket || binding[1] == :advanced_copy
          advanced_indices << index
        end
      end
      advanced_indices.size.should eq(CrystalClick::CompactJsonObjectSharedAdvancedTapeGrammar::EXPECTED_ADVANCED_ROLES)

      # The root schedule remains byte-for-byte valid. Omitting or reordering
      # only a child advanced role must still invalidate that child grammar.
      child_bindings.delete_at(advanced_indices.last)
      expect_raises(CrystalClick::CorruptPartError) { w279_child_advanced_grammar(capture) }
      child_bindings.clear
      original_bindings.each { |binding| child_bindings << binding }

      left = advanced_indices[0]
      right = advanced_indices[1]
      first_binding = child_bindings[left]
      child_bindings[left] = child_bindings[right]
      child_bindings[right] = first_binding
      expect_raises(CrystalClick::CorruptPartError) { w279_child_advanced_grammar(capture) }
      child_bindings.clear
      original_bindings.each { |binding| child_bindings << binding }

      # Conversely, a child whose own schedule is intact remains valid when
      # only the root owner's parallel Advanced roster is malformed.
      root = CrystalClick::ObjectDocumentInlineCallbackOrder.canonical_root_prefix(capture.physical_plan)
      root_owner = capture.schedule.owner_for_root(root)
      root_bindings = root_owner.body_bindings
      original_root_bindings = root_bindings.dup
      root_bindings.pop
      w279_child_advanced_grammar(capture)
      root_bindings.clear
      original_root_bindings.each { |binding| root_bindings << binding }
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "refuses resource exhaustion without publishing a part or mutating an unrelated sentinel" do
    parent = File.tempname("crystal-click-w279-transport-budget-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      sentinel = File.join(parent, "keep.txt")
      File.write(sentinel, "unrelated")
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::CompactPartWriter.write_uint64_columns(
          part_path,
          CompactPartWriterW279Fixture::KEY_NAME,
          CompactPartWriterW279Fixture.keys,
          [CompactPartWriterW279Fixture.column(2, 3_u64)] of CrystalClick::CompactPartColumn,
          rows_per_mark: CompactPartWriterW279Fixture::ROWS_PER_MARK,
          frame_bytes: 64,
          mark_format: CrystalClick::CompactMarkFormat::Mrk4,
          profile: CrystalClick::BinaryBulkProfile.with_size_stream,
          transport_limits: CrystalClick::CompressedStreamLimits.new(max_result_bytes: 1),
        )
      end
      File.exists?(part_path).should be_false
      Dir.children(parent).sort.should eq(["keep.txt"])
      File.read(sentinel).should eq("unrelated")
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
