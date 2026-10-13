require "./spec_helper"
require "file_utils"
require "./support/compact_part_writer_w271_fixture"

private module CompactPartWriterW271SourceOwnerFixture
  extend self

  COLUMN_NAME = "typed_dynamic_json_source_owner"
  ARRAY_SITE  = "root/array[0]"

  def schema : CrystalClick::StorageColumnSchema
    CrystalClick::StorageColumnSchema.parse(
      CrystalClick::BinaryDataType.array(CompactPartWriterW271Fixture.declared_json_type).name,
    )
  end

  def rows : Array(CrystalClick::StorageColumnValue)
    object_rows = CompactPartWriterW271Fixture.rows
    object_indexes = [
      [0, 1],
      [] of Int32,
      [] of Int32,
      [] of Int32,
      [4],
      [5],
      [6],
      [7, 2, 3],
    ] of Array(Int32)

    object_indexes.map do |indexes|
      children = indexes.map do |index|
        object_rows[index].object?.should be_true
        object_rows[index]
      end
      CrystalClick::StorageColumnValue.array(children)
    end
  end

  def column : CrystalClick::CompactPartColumn
    granules = CompactPartWriterW271Fixture.granules(rows)
    context = CrystalClick::CompactJsonWriteContext.new(
      {ARRAY_SITE => CompactPartWriterW271Fixture.object_plan} of String => CrystalClick::ObjectDocumentPlan,
    )
    CrystalClick::CompactPartColumn.json(COLUMN_NAME, schema, granules, context)
  end
end

private struct CompactPartWriterW271SourceOwnerCapture
  getter budget : CrystalClick::BinaryCodecBudget
  getter prefix : CrystalClick::ObjectDocumentCallbackPrefix
  getter physical_plan : CrystalClick::ObjectDocumentPhysicalPlan
  getter schedule : CrystalClick::CompactJsonObjectRoleSchedule
  getter source : CrystalClick::CompactRecursiveJsonObjectSiteSource

  def initialize(
    @budget : CrystalClick::BinaryCodecBudget,
    @prefix : CrystalClick::ObjectDocumentCallbackPrefix,
    @physical_plan : CrystalClick::ObjectDocumentPhysicalPlan,
    @schedule : CrystalClick::CompactJsonObjectRoleSchedule,
    @source : CrystalClick::CompactRecursiveJsonObjectSiteSource,
  )
  end
end

private def w271_write_source_owner_part(part_path : String) : String
  CrystalClick::CompactPartWriter.write_uint64_columns(
    part_path,
    CompactPartWriterW271Fixture::KEY_NAME,
    CompactPartWriterW271Fixture::KEYS,
    [CompactPartWriterW271SourceOwnerFixture.column] of CrystalClick::CompactPartColumn,
    rows_per_mark: CompactPartWriterW271Fixture::ROWS_PER_MARK,
    frame_bytes: CompactPartWriterW271Fixture::FRAME_BYTES,
    mark_format: CrystalClick::CompactMarkFormat::Mrk4,
    variant_discriminator_mode: CrystalClick::CompactVariantDiscriminatorMode::Basic,
  )
end

private def w271_capture_source_owner(
  physical : CrystalClick::CompactPartPhysicalContext,
  granule : CrystalClick::CompactPartPhysicalGranule,
  schema_plan : CrystalClick::CompactRecursiveJsonSchemaPlan,
  site : CrystalClick::CompactRecursiveJsonSchemaPlan::JsonSite,
  profile : CrystalClick::CompactSerializationProfile,
  limits : CrystalClick::BinaryCodecLimits,
) : CompactPartWriterW271SourceOwnerCapture
  budget = CrystalClick::BinaryCodecBudget.new(limits)
  ledger = CrystalClick::CompactRecursiveJsonParentMarkLedger.new(
    physical,
    CompactPartWriterW271SourceOwnerFixture::COLUMN_NAME,
    granule,
    budget,
  )
  source = ledger.site_source(site.key)
  nested_context = CrystalClick::ObjectSharedNestedSerializationContext.for_read(
    0_u64,
    profile.ordinary_profile,
  )
  prefix = CrystalClick::ObjectDocumentCallbackPrefixReader.read_static_json_prefix(
    source,
    site.descriptor,
    site.descriptor_depth,
    site.physical_prefix,
    site.callback_prefix,
    site.array_level,
    nested_context,
    budget,
    true,
  )
  physical_plan = CrystalClick::ObjectDocumentPhysicalPlan.from_escaped_prefix(
    site.physical_prefix,
    prefix.plan,
    profile.ordinary_profile,
    CrystalClick::BinaryBulkProfile.single_stream,
    limits,
    site.array_level,
    typed_descriptor_root_depth: prefix.typed_descriptor_root_depth,
    inferred_actual_root_depth: prefix.inferred_actual_root_depth,
    root_dynamic_json_budget: budget,
  )
  prefix.bind_physical_plan!(physical_plan)
  schedule = CrystalClick::CompactJsonObjectRoleSchedule.build(
    prefix,
    physical_plan,
    profile.ordinary_profile,
    budget,
  )

  source.begin_body_capture!
  ledger.finish_prefixes!
  array_sites = schema_plan.array_sites
  ledger.begin_array_sizes!(array_sites.size)
  array_sizes = Hash(String, Array(UInt64)).new(initial_capacity: array_sites.size)
  array_sites.each do |array_site|
    byte_count = granule.row_count * 8_u64
    if byte_count > Int32::MAX.to_u64
      raise CrystalClick::CorruptPartError.new("W271 source-owner Array-size lane exceeds its supported byte domain")
    end
    bytes = ledger.capture_array_size_lane(array_site.callback_name, byte_count.to_i32)
    values = Array(UInt64).new(granule.row_count.to_i)
    granule.row_count.to_i.times do |index|
      value = 0_u64
      8.times do |byte_index|
        value |= bytes[index * 8 + byte_index].to_u64 << (byte_index * 8)
      end
      values << value
    end
    array_sizes[array_site.key] = values
  end
  ledger.finish_array_sizes!

  site_rows = schema_plan.mark_site_rows(granule.row_count, array_sizes)
  site_rows[site.key].should eq(2_u64)
  schedule.begin_body_capture!(budget)
  schedule.capture_physical_body_events!(source, budget)
  schedule.finish_body_capture!(budget)

  prefixes = Hash(String, Array(String)).new(initial_capacity: 1)
  prefixes[site.key] = schedule.prefix_events.map { |event| String.new(event[2].to_slice) }
  schedules = {site.key => schedule} of String => CrystalClick::CompactJsonObjectRoleSchedule
  expected_logical_events = schema_plan.expected_event_names(prefixes, schedules)
  expected_site_events = schedule.prefix_events.map { |event| String.new(event[2].to_slice) }
  expected_site_events.concat(schedule.body_events.map { |event| String.new(event[2].to_slice) })
  schedule.event_names.should eq(expected_site_events)
  expected_parent_events = expected_site_events.dup
  array_sites.each_with_index do |array_site, index|
    prefix_event_count = schedule.prefix_events.size
    expected_parent_events.insert(prefix_event_count + index, array_site.callback_name)
  end
  expected_logical_events.should eq(expected_parent_events)
  source.validate_expected_events!(schedule.event_names)
  source.finish!

  # Parent order is prefix callbacks, Array-size lanes, then body callbacks.
  # MRK4 authenticates canonical physical names; the site validator separately
  # compares the logical names and exact captured bytes.
  physical_events = [] of String
  schedule.prefix_events.each { |event| physical_events << event[1] }
  array_sites.each { |array_site| physical_events << array_site.callback_name }
  schedule.body_events.each { |event| physical_events << event[1] }
  ledger.finish_mark!(physical_events)
  ledger.complete?.should be_true

  CompactPartWriterW271SourceOwnerCapture.new(budget, prefix, physical_plan, schedule, source)
end

private def w271_assert_same_owner_capture_bytes!(
  first : CompactPartWriterW271SourceOwnerCapture,
  second : CompactPartWriterW271SourceOwnerCapture,
) : Nil
  first.schedule.owner_schedules.keys.sort.should eq(second.schedule.owner_schedules.keys.sort)
  first.schedule.owner_schedules.each do |root, first_owner|
    second_owner = second.schedule.owner_for_root(root)
    first_owner.prefix.prefix_callback_count.should eq(second_owner.prefix.prefix_callback_count)
    first_owner.prefix.body_callback_count.should eq(second_owner.prefix.body_callback_count)
    first_owner.prefix.body_callback_slice_count.should eq(second_owner.prefix.body_callback_slice_count)

    first_owner.prefix.prefix_callback_count.times do |index|
      first_name, first_bytes = first_owner.prefix.prefix_callback_at(index, first.budget)
      second_name, second_bytes = second_owner.prefix.prefix_callback_at(index, second.budget)
      first_name.should eq(second_name)
      first_bytes.should eq(second_bytes)
    end

    first_owner.prefix.body_callback_count.times do |index|
      first_name, first_bytes = first_owner.prefix.body_callback_at(index, first.budget)
      second_name, second_bytes = second_owner.prefix.body_callback_at(index, second.budget)
      first_name.should eq(second_name)
      first_bytes.should eq(second_bytes)
      first_slice = first_owner.prefix.body_callback_slice_at(index)
      second_slice = second_owner.prefix.body_callback_slice_at(index)
      first_slice.canonical_name.should eq(second_slice.canonical_name)
      first_slice.callback_name.should eq(second_slice.callback_name)
      first_slice.relative_start.should eq(second_slice.relative_start)
      first_slice.relative_end.should eq(second_slice.relative_end)
      first_slice.bytes.should eq(second_slice.bytes)
    end
  end
  nil
end

describe "Compact recursive JSON prepared-source child-owner authentication (W271)" do
  it "rejects an equal-byte child capture from another coordinate context" do
    fixture = CompactPartWriterW271SourceOwnerFixture
    schema = fixture.schema
    limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
    part_type = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(schema.declaration).not_nil!
    parent = File.tempname("crystal-click-w271-source-owner-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      w271_write_source_owner_part(part_path).should eq(part_path)

      physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
      physical.mode.mrk4?.should be_true
      physical.row_count.should eq(CompactPartWriterW271Fixture::ROW_COUNT.to_u64)
      granule = physical.read_window(CompactPartWriterW271SourceOwnerFixture::COLUMN_NAME, 0, 1).granules.first
      granule.mark.should eq(0)
      granule.row_count.should eq(CompactPartWriterW271Fixture::ROWS_PER_MARK.to_u64)

      plan_budget = CrystalClick::BinaryCodecBudget.new(limits)
      schema_plan = CrystalClick::CompactRecursiveJsonSchemaPlan.new(
        schema,
        CompactPartWriterW271SourceOwnerFixture::COLUMN_NAME,
        limits,
        plan_budget,
      )
      schema_plan.json_sites.size.should eq(1)
      schema_plan.array_sites.size.should eq(1)
      site = schema_plan.json_sites.first
      site.key.should eq(CompactPartWriterW271SourceOwnerFixture::ARRAY_SITE)
      profile = CrystalClick::CompactSerializationProfile.open(
        part_path,
        physical.columns,
        CompactPartWriterW271SourceOwnerFixture::COLUMN_NAME,
        part_type,
        physical.row_count,
        CrystalClick::CompressedStreamBudget.read_default,
      )
      profile.map_basic.should be_true

      first = w271_capture_source_owner(physical, granule, schema_plan, site, profile, limits)
      second = w271_capture_source_owner(physical, granule, schema_plan, site, profile, limits)
      w271_assert_same_owner_capture_bytes!(first, second)

      first_root = first.schedule.validate_root_owner!(first.prefix, first.physical_plan, first.budget)
      second_root = second.schedule.validate_root_owner!(second.prefix, second.physical_plan, second.budget)
      first_root.root.should eq(second_root.root)
      child_root = first.schedule.owner_schedules.keys.find { |root| root != first_root.root } ||
                   raise CrystalClick::CorruptPartError.new("W271 schedule has no typed-Dynamic child owner")
      first_child = first.schedule.owner_for_root(child_root)
      second_child = second.schedule.owner_for_root(child_root)
      first_child.parent_typed_path.should eq(CompactPartWriterW271Fixture::PAYLOAD_PATH)
      second_child.parent_typed_path.should eq(CompactPartWriterW271Fixture::PAYLOAD_PATH)
      first_child.prefix.same?(second_child.prefix).should be_false
      first_child.prefix.body_callback_slice_count.should be > 0
      first_child.prefix.body_callback_slice_at(0).context.same?(
        second_child.prefix.body_callback_slice_at(0).context,
      ).should be_false

      first.source.validate_prepared_source!(
        first.prefix,
        first.physical_plan,
        first.schedule.body_bindings,
        first.schedule.body_pairs,
        first.budget,
        first.schedule,
      )

      # Change exactly the child registry entry. The root prefix, root owner,
      # flattened events, callback names/bytes, literal payload and row counts
      # remain those of the first capture.
      root_name = first_root.root
      root_owner_before = first.schedule.owner_for_root(root_name)
      first.schedule.owner_schedules[child_root] = second_child
      begin
        first.schedule.owner_for_root(root_name).prefix.same?(root_owner_before.prefix).should be_true
        expect_raises(CrystalClick::CorruptPartError) do
          first.source.validate_prepared_source!(
            first.prefix,
            first.physical_plan,
            first.schedule.body_bindings,
            first.schedule.body_pairs,
            first.budget,
            first.schedule,
          )
        end
      ensure
        first.schedule.owner_schedules[child_root] = first_child
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
