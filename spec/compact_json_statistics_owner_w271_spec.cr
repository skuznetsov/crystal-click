require "./spec_helper"
require "file_utils"
require "../scripts/support/compact_part_writer_w271_native_fixture"

private def w271_write_statistics_owner_part(part_path : String) : String
  fixture = CompactPartWriterW271NativeFixture
  CrystalClick::CompactPartWriter.write_uint64_columns(
    part_path,
    CompactPartWriterW271NativeFixture::KEY_NAME,
    CompactPartWriterW271NativeFixture::KEYS,
    [fixture.column] of CrystalClick::CompactPartColumn,
    rows_per_mark: CompactPartWriterW271NativeFixture::ROWS_PER_MARK,
    frame_bytes: CompactPartWriterW271NativeFixture::FRAME_BYTES,
    mark_format: CrystalClick::CompactMarkFormat::Mrk4,
    variant_discriminator_mode: CrystalClick::CompactVariantDiscriminatorMode::Basic,
  )
end

private def w271_capture_statistics_owner_prefixes(part_path : String)
  fixture = CompactPartWriterW271NativeFixture
  limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
  physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
  granule = physical.read_window(CompactPartWriterW271NativeFixture::COLUMN_NAME, 0, 1).granules.first
  budget = CrystalClick::BinaryCodecBudget.new(limits)
  profile = CrystalClick::CompactStaticJsonBulkColumnReader.open(
    part_path,
    CompactPartWriterW271NativeFixture::COLUMN_NAME,
    fixture.declared_json_type,
  ).ordinary_profile
  manifest = CrystalClick::CompactStaticJsonSiteManifest.new(
    CompactPartWriterW271NativeFixture::COLUMN_NAME,
    fixture.declared_json_type,
  )
  site_identity = "#{manifest.physical_prefix}:mark=#{granule.mark}"
  framer = CrystalClick::CompactJsonObjectSiteFramer.new(
    physical.mode,
    granule.shards,
    budget,
    physical,
    site_identity,
  )
  observed_offsets = Hash(String, Int32).new
  observe_statistics = ->(name : String, offset : Int32) do
    if previous = observed_offsets[name]?
      unless previous == offset
        raise CrystalClick::CorruptPartError.new("W271 statistics observer saw a changed offset")
      end
    else
      observed_offsets[String.new(name.to_slice)] = offset
    end
    nil
  end
  prefix = CrystalClick::ObjectDocumentCallbackPrefixReader.read_static_json_prefix(
    framer,
    fixture.declared_json_type,
    1_i32,
    manifest.physical_prefix,
    manifest.callback_prefix,
    0_u64,
    CrystalClick::ObjectSharedNestedSerializationContext.for_read(0_u64, profile),
    budget,
    true,
    observe_statistics,
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

  key = fixture.json_bindings[CompactPartWriterW271NativeFixture::PAYLOAD_PATH].first[0]
  child_prefix = prefix.typed_dynamic_json_prefixes_for(CompactPartWriterW271NativeFixture::PAYLOAD_PATH)[key]
  child_owner = schedule.owner_for_root(child_prefix.physical_prefix)
  child_plan = child_owner.physical_plan
  child_structure_name = child_plan.dynamic_structure_stream(CompactPartWriterW271NativeFixture::VALUE_PATH)
  parent_structure_name = physical_plan.typed_dynamic(CompactPartWriterW271NativeFixture::PAYLOAD_PATH).structure_name_for("root")
  child_grid = CrystalClick::StorageOccurrenceGrid.new(
    [granule.row_count] of UInt64,
    [1_u64] of UInt64,
    budget,
  )

  {
    budget:               budget,
    prefix:               prefix,
    physical_plan:        physical_plan,
    schedule:             schedule,
    child_prefix:         child_prefix,
    child_owner:          child_owner,
    child_plan:           child_plan,
    child_grid:            child_grid,
    child_structure_name: child_structure_name,
    parent_structure_name: parent_structure_name,
    observed_offsets:     observed_offsets,
  }
end

private def w271_materialize_statistics_owner_child(capture, offsets : Hash(String, Int32)?)
  budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS)
  CrystalClick::ObjectDocumentInlineBodyMaterializer.materialize(
    capture[:child_prefix],
    capture[:child_plan],
    capture[:child_grid],
    budget,
    capture[:child_owner].body_bindings,
    capture[:child_owner].body_pairs,
    offsets,
  )
end

describe "Compact W271 owner-local Dynamic statistics offsets" do
  it "retains exact per-Object maps while the outer observer sees the flattened prefix census" do
    parent = File.tempname("crystal-click-w271-statistics-owner-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      w271_write_statistics_owner_part(part_path).should eq(part_path)
      capture = w271_capture_statistics_owner_prefixes(part_path)

      capture[:observed_offsets].size.should eq(2)
      parent_offset = capture[:observed_offsets][capture[:parent_structure_name]]?
      parent_offset.should_not be_nil
      child_offset = capture[:observed_offsets][capture[:child_structure_name]]?
      child_offset.should_not be_nil

      parent_snapshot = capture[:prefix].statistics_offsets_snapshot(
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS),
      )
      child_snapshot = capture[:child_prefix].statistics_offsets_snapshot(
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS),
      )
      expected_parent = Hash(String, Int32).new
      expected_parent[capture[:parent_structure_name]] = parent_offset.not_nil!
      expected_child = Hash(String, Int32).new
      expected_child[capture[:child_structure_name]] = child_offset.not_nil!
      parent_snapshot.should eq(expected_parent)
      child_snapshot.should eq(expected_child)
      parent_snapshot.has_key?(capture[:child_structure_name]).should be_false
      child_snapshot.has_key?(capture[:parent_structure_name]).should be_false

      # Returned snapshots are detached from the parser-owned exact-key maps.
      child_snapshot[capture[:child_structure_name]] = -1_i32
      capture[:child_prefix].statistics_offsets_snapshot(
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS),
      ).should eq(expected_child)

      valid = w271_materialize_statistics_owner_child(capture, expected_child)
      valid.mark_count.should eq(1)
      valid.row_count_at(0).should eq(1_u64)

      missing = expect_raises(CrystalClick::CorruptPartError) do
        w271_materialize_statistics_owner_child(capture, nil)
      end
      missing.message.should eq("complete Object statistics offsets are missing")

      # The parent's exact map is valid, but foreign to this child owner.
      foreign = expect_raises(CrystalClick::CorruptPartError) do
        w271_materialize_statistics_owner_child(capture, expected_parent)
      end
      foreign.message.should eq("complete Dynamic statistics offset is missing")

      out_of_range = Hash(String, Int32).new
      out_of_range[capture[:child_structure_name]] = Int32::MAX
      invalid = expect_raises(CrystalClick::CorruptPartError) do
        w271_materialize_statistics_owner_child(capture, out_of_range)
      end
      invalid.message.should eq("inline Dynamic statistics offset is outside its parsed prefix")
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "preflights snapshot wire-byte budget before charging or returning a partial map" do
    parent = File.tempname("crystal-click-w271-statistics-budget-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      w271_write_statistics_owner_part(part_path).should eq(part_path)
      capture = w271_capture_statistics_owner_prefixes(part_path)
      limits = CrystalClick::BinaryCodecLimits.new(64, 4096, 1_000_000, 0)
      budget = CrystalClick::BinaryCodecBudget.new(limits)

      error = expect_raises(CrystalClick::CorruptPartError) do
        capture[:child_prefix].statistics_offsets_snapshot(budget)
      end
      error.message.should eq("binary codec byte limit exceeded")
      budget.node_count.should eq(0_i64)
      budget.element_count.should eq(0_i64)
      budget.wire_byte_count.should eq(0_i64)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
