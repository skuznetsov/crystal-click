require "./spec_helper"
require "file_utils"
require "./support/compact_part_writer_w283_fixture"
require "../scripts/support/compact_physical_context_w259_fixture"

private def w283_variant_prefix_roles_a : Array(String)
  [
    "root.elements.field.0.discriminators",
    "root.elements.field.1.dictionary",
  ] of String
end

private def w283_variant_prefix_roles_b : Array(String)
  [
    "root.field.0.dictionary",
    "root.field.1.discriminators",
    "root.field.2.elements.field.1.discriminators",
    "root.field.3.elements.field.0.discriminators",
    "root.field.3.elements.field.1.dictionary",
  ] of String
end

private def w283_variant_prefix_pairs(
  site : CrystalClick::CompactRecursiveJsonBulkSite,
  roles : Array(String),
) : Array(Tuple(String, String))
  roles.map { |role| {role, site.prefix_callback_name_for(role)} }
end

private def w283_variant_bulk_callbacks(
  site : CrystalClick::CompactRecursiveJsonBulkSite,
  roles : Array(String),
) : Array(String)
  roles.map { |role| site.callback_name_for(role) }
end

private def w283_variant_bulk_prefix_callbacks(
  site : CrystalClick::CompactRecursiveJsonBulkSite,
  roles : Array(String),
) : Array(String)
  roles.map { |role| site.prefix_callback_name_for(role) }
end

private def w283_variant_binding_callbacks(
  plan : CrystalClick::CompactJsonCallbackPlan,
  key : String,
  prefixes : Bool,
) : Array(String)
  binding = plan.site_binding(key)
  pairs = prefixes ? binding.prefix_pairs : binding.body_pairs
  pairs.map { |pair| pair[1] }
end

private def w283_variant_body_roles_a : Array(String)
  [
    "root.sizes",
    "root.elements.field.0.discriminators",
    "root.elements.field.0.arm.0.sizes",
    "root.elements.field.0.arm.0.elements.data",
    "root.elements.field.0.arm.1.data",
    "root.elements.field.0.arm.2.data",
    "root.elements.field.1.dictionary",
    "root.elements.field.1.indexes",
  ] of String
end

private def w283_variant_body_roles_b : Array(String)
  [
    "root.field.0.dictionary",
    "root.field.0.indexes",
    "root.field.1.discriminators",
    "root.field.1.arm.0.sizes",
    "root.field.1.arm.0.elements.data",
    "root.field.1.arm.1.data",
    "root.field.1.arm.2.data",
    "root.field.2.sizes",
    "root.field.2.elements.field.0.data",
    "root.field.2.elements.field.1.discriminators",
    "root.field.2.elements.field.1.arm.0.sizes",
    "root.field.2.elements.field.1.arm.0.elements.data",
    "root.field.2.elements.field.1.arm.1.data",
    "root.field.2.elements.field.1.arm.2.data",
    "root.field.3.sizes",
    "root.field.3.elements.field.0.discriminators",
    "root.field.3.elements.field.0.arm.0.sizes",
    "root.field.3.elements.field.0.arm.0.elements.data",
    "root.field.3.elements.field.0.arm.1.data",
    "root.field.3.elements.field.0.arm.2.data",
    "root.field.3.elements.field.1.dictionary",
    "root.field.3.elements.field.1.indexes",
  ] of String
end

private def w283_variant_event_pairs(
  events : Array(CrystalClick::CompactBinaryBulkCallback),
  prefixes : Bool,
) : Array(Tuple(String, String))
  events.select { |event| event.prefix? == prefixes }.map { |event| {event.role, event.name} }
end

private def w283_variant_le_u64(bytes : Bytes) : UInt64
  unless bytes.size == 8
    raise "W283 Variant state prefix must contain exactly eight bytes"
  end
  value = 0_u64
  bytes.size.times do |index|
    value |= bytes[index].to_u64 << (index * 8)
  end
  value
end

private def w283_write_le_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times do |index|
    bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8
  end
end

private def w283_reseal_mrk4!(
  part_path : String,
  physical : CrystalClick::CompactPartPhysicalContext,
  raw : Bytes,
) : Nil
  slots = physical.physical_roster
  mark_rows = physical.mark_row_counts
  slot_grid = Array(Array(CrystalClick::CompactPartPhysicalShard?)).new(physical.granule_count) do
    Array(CrystalClick::CompactPartPhysicalShard?).new(slots.size, nil)
  end
  columns = [] of String
  slots.each do |slot|
    columns << slot.column_name unless columns.includes?(slot.column_name)
  end
  columns.each do |column_name|
    window = physical.read_window(column_name, 0, physical.granule_count)
    window.granules.each_with_index do |mark, mark_index|
      mark.shards.each do |shard|
        unless shard.slot_index >= 0 && shard.slot_index < slots.size &&
               slots[shard.slot_index].column_name == column_name
          raise "W283 reframe observed a shard outside the MRK4 slot roster"
        end
        raise "W283 reframe duplicated an MRK4 slot" if slot_grid[mark_index][shard.slot_index]
        slot_grid[mark_index][shard.slot_index] = shard
      end
    end
  end

  offsets = Array(UInt64).new(physical.granule_count + 1)
  queries = [] of UInt64
  physical.granule_count.times do |mark_index|
    first = slot_grid[mark_index][0] || raise "W283 reframe missed the first slot"
    offsets << first.logical_start.to_u64
    slots.size.times do |slot_index|
      shard = slot_grid[mark_index][slot_index] || raise "W283 reframe missed an MRK4 slot"
      queries << shard.logical_start.to_u64
    end
  end
  offsets << raw.size.to_u64
  slots.size.times { queries << raw.size.to_u64 }

  positioned = CrystalClick::CompressedMarkWriter.encode_with_positions(
    raw,
    offsets,
    mark_rows,
    queries,
    frame_bytes: CompactPartWriterW283Fixture::FRAME_BYTES,
  )
  record_width = slots.size * 16 + 8
  marks = Bytes.new((physical.granule_count + 1) * record_width, 0_u8)
  physical.granule_count.times do |mark_index|
    slots.size.times do |slot_index|
      pair = positioned.positions[mark_index * slots.size + slot_index]
      w283_write_le_u64(marks, mark_index * record_width + slot_index * 16, pair[0])
      w283_write_le_u64(marks, mark_index * record_width + slot_index * 16 + 8, pair[1])
    end
    w283_write_le_u64(marks, mark_index * record_width + slots.size * 16, mark_rows[mark_index])
  end
  slots.size.times do |slot_index|
    pair = positioned.positions[physical.granule_count * slots.size + slot_index]
    w283_write_le_u64(marks, physical.granule_count * record_width + slot_index * 16, pair[0])
    w283_write_le_u64(marks, physical.granule_count * record_width + slot_index * 16 + 8, pair[1])
  end
  w283_write_le_u64(marks, physical.granule_count * record_width + slots.size * 16, 0_u64)
  File.write(File.join(part_path, "data.bin"), positioned.files.data)
  File.write(File.join(part_path, "data.mrk4"), marks)
  CompactPhysicalContextW259Fixture.refresh_checksums(part_path)
  nil
end

private def w283_variant_plan(
  profile : CrystalClick::BinaryBulkProfile,
  mode : CrystalClick::CompactVariantDiscriminatorMode,
) : CrystalClick::CompactJsonCallbackPlan
  limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
  CrystalClick::CompactJsonCallbackPlan.new(
    CompactPartWriterW283Fixture.column.json_input(profile),
    limits,
    CrystalClick::BinaryCodecBudget.new(limits, true),
    mode,
  )
end

private def w283_adv_assert_values(
  actual : Array(CrystalClick::StorageColumnValue),
  expected : Array(CrystalClick::StorageColumnValue),
) : Nil
  actual.size.should eq(expected.size)
  actual.each_with_index do |value, index|
    budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, false)
    CrystalClick::CompactPartValueComparison.storage!(value, expected[index], budget)
  end
  nil
end

private def w283_lc_variant_write_read_matrix : Nil
  fixture = CompactPartWriterW283LCVariantFixture
  mark_formats = [
    CrystalClick::CompactMarkFormat::Mrk3,
    CrystalClick::CompactMarkFormat::Mrk4,
  ] of CrystalClick::CompactMarkFormat
  modes = [
    CrystalClick::CompactVariantDiscriminatorMode::Basic,
    CrystalClick::CompactVariantDiscriminatorMode::Compact,
  ] of CrystalClick::CompactVariantDiscriminatorMode

  mark_formats.each do |mark_format|
    modes.each do |mode|
      parent = File.tempname("crystal-click-w283-lc-arm-#{mark_format}-#{mode}-")
      part_path = File.join(parent, "all_1_1_0")
      Dir.mkdir(parent)
      begin
        CrystalClick::CompactPartWriter.write_uint64_columns(
          part_path,
          CompactPartWriterW283LCVariantFixture::KEY_NAME,
          fixture.keys,
          [fixture.column] of CrystalClick::CompactPartColumn,
          rows_per_mark: CompactPartWriterW283LCVariantFixture::ROWS_PER_MARK,
          frame_bytes: CompactPartWriterW283LCVariantFixture::FRAME_BYTES,
          mark_format: mark_format,
          variant_discriminator_mode: mode,
          profile: CrystalClick::BinaryBulkProfile.single_stream,
        ).should eq(part_path)

        reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
          part_path,
          CompactPartWriterW283LCVariantFixture::COLUMN_NAME,
          fixture.schema,
        )
        reader.mark_count.should eq(CompactPartWriterW283LCVariantFixture::MARK_COUNT)
        reader.row_count.should eq(CompactPartWriterW283LCVariantFixture::ROW_COUNT.to_u64)
        reader.mark_row_counts.should eq([2_u64, 2_u64])
        w283_adv_assert_values(
          reader.read_marks(0, reader.mark_count).flatten,
          fixture.rows,
        )
        reader.read_marks(0, 1).size.should eq(1)
        reader.read_marks(1, 1).size.should eq(1)
        reader.read_marks(reader.mark_count, 0).should be_empty
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end
  nil
end

describe "W283 recursive Variant discriminator and state-prefix adversaries" do
  it "admits the public LC-arm Variant carrier but keeps non-goal stateful descendants rejected" do
    fixture = CompactPartWriterW283LCVariantFixture
    fixture.schema.child_at(1).bulk?.should be_true
    fixture.schema.child_at(1).bulk_type.name.should eq(
      CompactPartWriterW283LCVariantFixture::VARIANT_DECLARATION,
    )
    fixture.variant_type.child_at(0).child_at(0).name.should eq("LowCardinality(String)")
    fixture.variant_type.child_at(1).name.should eq("LowCardinality(String)")
    CrystalClick::CompactRecursiveJsonColumnReader.admitted_schema?(fixture.schema).should be_true
    CrystalClick::CompactRecursiveJsonBulkSite.admitted_type?(
      fixture.variant_type,
      2,
      CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
    ).should be_true

    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    unsupported = [
      CrystalClick::BinaryDataType.dynamic,
      CrystalClick::BinaryDataType.qbit(CrystalClick::QBitType.new("Int8", 8_u64)),
      CrystalClick::BinaryDataType.aggregate_function("sum", uint64),
    ] of CrystalClick::BinaryDataType
    unsupported.each do |type|
      CrystalClick::CompactRecursiveJsonBulkSite.admitted_type?(
        type,
        2,
        CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
      ).should be_false
    end
  end

  it "counts LowCardinality child descriptors toward recursive Bulk depth admission" do
    limits = CrystalClick::BinaryCodecLimits.new(
      4,
      CrystalClick::BinaryCodecLimits::DEFAULT_MAX_NODES,
      CrystalClick::BinaryCodecLimits::DEFAULT_MAX_ELEMENTS,
      CrystalClick::BinaryCodecLimits::DEFAULT_MAX_BYTES,
    )
    string = CrystalClick::BinaryDataType.primitive("String")
    low_cardinality_string = CrystalClick::BinaryDataType.low_cardinality(string)
    nullable_low_cardinality = CrystalClick::BinaryDataType.low_cardinality(
      CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.primitive("UInt8")),
    )

    # LC(String) occupies the descriptor at depth 3 and its String child at 4.
    CrystalClick::CompactRecursiveJsonBulkSite.admitted_type?(
      low_cardinality_string,
      3,
      limits,
    ).should be_true
    CrystalClick::CompactRecursiveJsonBulkSite.admitted_type?(
      low_cardinality_string,
      4,
      limits,
    ).should be_false

    # LC(Nullable(UInt8)) has both a child wrapper and a scalar grandchild.
    CrystalClick::CompactRecursiveJsonBulkSite.admitted_type?(
      nullable_low_cardinality,
      2,
      limits,
    ).should be_true
    CrystalClick::CompactRecursiveJsonBulkSite.admitted_type?(
      nullable_low_cardinality,
      3,
      limits,
    ).should be_false
  end

  it "keeps Variant and LC prefix descriptors in full schema DFS before all bodies" do
    plan = w283_variant_plan(
      CrystalClick::BinaryBulkProfile.single_stream,
      CrystalClick::CompactVariantDiscriminatorMode::Compact,
    )
    bulk_a = plan.schema_plan.bulk_site("root/tuple[1]")
    bulk_b = plan.schema_plan.bulk_site("root/tuple[3]")

    expected_prefix_pairs = w283_variant_prefix_pairs(bulk_a, w283_variant_prefix_roles_a) +
                            w283_variant_prefix_pairs(bulk_b, w283_variant_prefix_roles_b)
    expected_names = [] of String
    expected_names.concat(w283_variant_binding_callbacks(plan, "root/tuple[0]", true))
    expected_names.concat(w283_variant_bulk_prefix_callbacks(bulk_a, w283_variant_prefix_roles_a))
    expected_names.concat(w283_variant_binding_callbacks(plan, "root/tuple[2]", true))
    expected_names.concat(w283_variant_bulk_prefix_callbacks(bulk_b, w283_variant_prefix_roles_b))
    expected_names.concat(w283_variant_binding_callbacks(plan, "root/tuple[0]", false))
    expected_names.concat(w283_variant_bulk_callbacks(bulk_a, w283_variant_body_roles_a))
    expected_names.concat(w283_variant_binding_callbacks(plan, "root/tuple[2]", false))
    expected_names.concat(w283_variant_bulk_callbacks(bulk_b, w283_variant_body_roles_b))

    events = plan.callback_events
    plan.callback_names.should eq(expected_names)
    prefix_events = events.select(&.prefix?)
    prefix_events.size.should eq(7)
    w283_variant_event_pairs(events, true).should eq(expected_prefix_pairs)

    variant_prefixes = events.select do |event|
      event.prefix? && event.role.ends_with?(".discriminators")
    end
    variant_prefixes.size.should eq(4)
    variant_prefixes.each do |prefix|
      prefix.name.ends_with?(".variant_discr_prefix").should be_true
      prefix.prefix_size.should eq(8)
      site = [bulk_a, bulk_b].find do |candidate|
        candidate.prefix_role_index(prefix.role).try do |index|
          candidate.prefix_role_at(index).callback_name == prefix.name
        end || false
      end || raise "W283 Variant mode prefix has no schema-owned Bulk descriptor"
      role_index = site.prefix_role_index(prefix.role) || raise "W283 Variant mode role lost its descriptor"
      descriptor = site.prefix_role_at(role_index)
      descriptor.kind.should eq(CrystalClick::CompactRecursiveJsonBulkSite::StatePrefixKind::VariantDiscriminatorMode)

      body = events.find do |event|
        !event.prefix? && event.name == site.callback_name_for(prefix.role)
      end || raise "W283 Variant mode prefix has no discriminator body event"
      body.name.ends_with?(".variant_discr").should be_true
      body.prefix_size.should eq(0)
    end

    lc_prefixes = events.select do |event|
      event.prefix? && event.role.ends_with?(".dictionary")
    end
    lc_prefixes.size.should eq(3)
    lc_prefixes.each do |prefix|
      prefix.name.ends_with?(".dict_prefix").should be_true
      prefix.prefix_size.should eq(8)
      site = [bulk_a, bulk_b].find do |candidate|
        candidate.prefix_role_index(prefix.role).try do |index|
          candidate.prefix_role_at(index).callback_name == prefix.name
        end || false
      end || raise "W283 LC prefix has no schema-owned Bulk descriptor"
      role_index = site.prefix_role_index(prefix.role) || raise "W283 LC role lost its descriptor"
      descriptor = site.prefix_role_at(role_index)
      descriptor.kind.should eq(CrystalClick::CompactRecursiveJsonBulkSite::StatePrefixKind::LowCardinalityDictionaryV1)
    end
  end

  it "preflights the typed state-prefix roster at its exact owner limits" do
    limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
    planned = w283_variant_plan(
      CrystalClick::BinaryBulkProfile.single_stream,
      CrystalClick::CompactVariantDiscriminatorMode::Compact,
    ).schema_plan.bulk_site("root/tuple[1]")

    role_count = planned.role_count.to_u64
    prefix_count = planned.prefix_role_count.to_u64
    prefix_count.should eq(2_u64)
    role_nodes = role_count + 1_u64
    role_elements = role_count * 2_u64
    role_name_bytes = CrystalClick::CompactRecursiveJsonBulkSite.measure_role_name_bytes(
      planned.type,
      4_u64,
      planned.physical_plan.profile,
    )
    prefix_name_bytes = 0_u64
    prefix_count.to_i.times do |index|
      prefix_name_bytes += planned.prefix_callback_name_at(index).bytesize.to_u64 + 1_u64
    end
    required_nodes = role_nodes + prefix_count + 1_u64
    required_elements = role_elements + prefix_count
    required_bytes = role_name_bytes + prefix_name_bytes

    exact_limits = CrystalClick::BinaryCodecLimits.new(
      CrystalClick::BinaryCodecLimits::DEFAULT_MAX_DEPTH,
      required_nodes.to_i,
      required_elements.to_i,
      required_bytes.to_i,
    )
    exact_budget = CrystalClick::BinaryCodecBudget.new(exact_limits, true)
    reopened = CrystalClick::CompactRecursiveJsonBulkSite.new(
      planned.key,
      planned.physical_prefix,
      planned.descriptor_depth,
      planned.initial_array_level,
      planned.type,
      planned.physical_plan,
      exact_limits,
      exact_budget,
    )
    reopened.prefix_role_count.should eq(2)
    {exact_budget.node_count, exact_budget.element_count, exact_budget.wire_byte_count}.should eq(
      {required_nodes.to_i64, required_elements.to_i64, required_bytes.to_i64},
    )

    one_below_limits = [
      CrystalClick::BinaryCodecLimits.new(
        CrystalClick::BinaryCodecLimits::DEFAULT_MAX_DEPTH,
        required_nodes.to_i - 1,
        required_elements.to_i,
        required_bytes.to_i,
      ),
      CrystalClick::BinaryCodecLimits.new(
        CrystalClick::BinaryCodecLimits::DEFAULT_MAX_DEPTH,
        required_nodes.to_i,
        required_elements.to_i - 1,
        required_bytes.to_i,
      ),
      CrystalClick::BinaryCodecLimits.new(
        CrystalClick::BinaryCodecLimits::DEFAULT_MAX_DEPTH,
        required_nodes.to_i,
        required_elements.to_i,
        required_bytes.to_i - 1,
      ),
    ] of CrystalClick::BinaryCodecLimits
    one_below_limits.each do |short_limits|
      short_budget = CrystalClick::BinaryCodecBudget.new(short_limits, true)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::CompactRecursiveJsonBulkSite.new(
          planned.key,
          planned.physical_prefix,
          planned.descriptor_depth,
          planned.initial_array_level,
          planned.type,
          planned.physical_plan,
          short_limits,
          short_budget,
        )
      end
      # The role roster was admitted first; the combined prefix owner must not
      # partially charge any of its count/name dimensions on a later failure.
      {short_budget.node_count, short_budget.element_count, short_budget.wire_byte_count}.should eq(
        {role_nodes.to_i64, role_elements.to_i64, role_name_bytes.to_i64},
      )
    end
  end

  it "preflights Variant/LC per-mark prefix references and rejects missing, extra, wrong-kind, or reordered captures" do
    limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
    site = w283_variant_plan(
      CrystalClick::BinaryBulkProfile.single_stream,
      CrystalClick::CompactVariantDiscriminatorMode::Compact,
    ).schema_plan.bulk_site("root/tuple[1]")
    site.prefix_role_count.should eq(2)

    required_nodes = 2_i64 + (site.prefix_role_count > 0 ? 1_i64 : 0_i64)
    required_elements = site.role_count.to_i64 + site.prefix_role_count.to_i64
    exact_limits = CrystalClick::BinaryCodecLimits.new(
      CrystalClick::BinaryCodecLimits::DEFAULT_MAX_DEPTH,
      required_nodes,
      required_elements,
      0,
    )
    exact_budget = CrystalClick::BinaryCodecBudget.new(exact_limits)
    mark = CrystalClick::CompactRecursiveJsonBulkMark.open(site, exact_budget)
    {exact_budget.node_count, exact_budget.element_count, exact_budget.wire_byte_count}.should eq(
      {required_nodes, required_elements, 0_i64},
    )

    node_short = CrystalClick::BinaryCodecBudget.new(
      CrystalClick::BinaryCodecLimits.new(
        CrystalClick::BinaryCodecLimits::DEFAULT_MAX_DEPTH,
        required_nodes - 1,
        required_elements,
        0,
      ),
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::CompactRecursiveJsonBulkMark.open(site, node_short)
    end
    {node_short.node_count, node_short.element_count, node_short.wire_byte_count}.should eq(
      {0_i64, 0_i64, 0_i64},
    )

    element_short = CrystalClick::BinaryCodecBudget.new(
      CrystalClick::BinaryCodecLimits.new(
        CrystalClick::BinaryCodecLimits::DEFAULT_MAX_DEPTH,
        required_nodes,
        required_elements - 1,
        0,
      ),
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::CompactRecursiveJsonBulkMark.open(site, element_short)
    end
    {element_short.node_count, element_short.element_count, element_short.wire_byte_count}.should eq(
      {0_i64, 0_i64, 0_i64},
    )

    mode_prefix = site.prefix_role_at(0)
    lc_prefix = site.prefix_role_at(1)
    mode_prefix.kind.should eq(
      CrystalClick::CompactRecursiveJsonBulkSite::StatePrefixKind::VariantDiscriminatorMode,
    )
    lc_prefix.kind.should eq(
      CrystalClick::CompactRecursiveJsonBulkSite::StatePrefixKind::LowCardinalityDictionaryV1,
    )
    mode_role = site.role_at(mode_prefix.role_index).name
    lc_role = site.role_at(lc_prefix.role_index).name
    bytes = Bytes[1_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8]

    expect_raises(CrystalClick::CorruptPartError) do
      mark.state_prefix_for_role(mode_role, mode_prefix.kind)
    end
    # A failed callback must not consume the first frozen slot; both a wrong
    # role order and a right role with the wrong prefix family are retriable.
    expect_raises(CrystalClick::CorruptPartError) do
      mark.capture_state_prefix!(lc_role, lc_prefix.kind, bytes)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      mark.capture_state_prefix!(
        mode_role,
        CrystalClick::CompactRecursiveJsonBulkSite::StatePrefixKind::LowCardinalityDictionaryV1,
        bytes,
      )
    end
    expect_raises(CrystalClick::CorruptPartError) do
      mark.capture_state_prefix!(mode_role, mode_prefix.kind, bytes[0, 7])
    end
    mark.capture_state_prefix!(mode_role, mode_prefix.kind, bytes)
    mark.state_prefix_for_role(mode_role, mode_prefix.kind).should eq(bytes)
    expect_raises(CrystalClick::CorruptPartError) do
      mark.state_prefix_for_role(lc_role, lc_prefix.kind)
    end
    mark.capture_state_prefix!(lc_role, lc_prefix.kind, bytes)
    mark.state_prefix_for_role(lc_role, lc_prefix.kind).should eq(bytes)
    expect_raises(CrystalClick::CorruptPartError) do
      mark.capture_state_prefix!(mode_role, mode_prefix.kind, bytes)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      mark.state_prefix_for_role(mode_role, lc_prefix.kind)
    end

    missing = CrystalClick::CompactRecursiveJsonBulkMark.open(
      site,
      CrystalClick::BinaryCodecBudget.new(limits),
    )
    missing.capture_state_prefix!(mode_role, mode_prefix.kind, bytes)
    site.each_role { |role| missing.capture_lane(role.name, Bytes.new(0)) }
    expect_raises(CrystalClick::CorruptPartError) do
      missing.build_streams(CrystalClick::BinaryCodecBudget.new(limits))
    end
  end

  it "retains every typed prefix at Q=0 and distinguishes zero-Q from positive all-NULL marks" do
    [
      CrystalClick::CompactVariantDiscriminatorMode::Basic,
      CrystalClick::CompactVariantDiscriminatorMode::Compact,
    ].each do |mode|
      plan = w283_variant_plan(CrystalClick::BinaryBulkProfile.single_stream, mode)
      encoded = CrystalClick::CompactJsonEncodedColumn.encode(
        plan,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true),
      )
      bulk_a = plan.schema_plan.bulk_site("root/tuple[1]")
      bulk_b = plan.schema_plan.bulk_site("root/tuple[3]")

      plan.callback_events.select(&.prefix?).each do |prefix|
        CompactPartWriterW283Fixture::MARK_COUNT.times do |mark|
          bytes = encoded.callback_bytes(prefix, mark)
          bytes.size.should eq(8)
          expected = if prefix.role.ends_with?(".discriminators")
                       mode.wire_value
                     else
                       1_u64
                     end
          w283_variant_le_u64(bytes).should eq(expected)
        end
      end

      zero_q_roles = [
        {bulk_a, "root.elements.field.0.discriminators"},
        {bulk_b, "root.field.2.elements.field.1.discriminators"},
        {bulk_b, "root.field.3.elements.field.0.discriminators"},
      ] of Tuple(CrystalClick::CompactRecursiveJsonBulkSite, String)
      zero_q_roles.each do |site, role|
        callback = site.callback_name_for(role)
        body = plan.callback_events.find do |event|
          !event.prefix? && event.name == callback
        end || raise "W283 zero-Q Variant body callback is missing"
        encoded.callback_bytes(body, 0).should be_empty
      end

      positive_all_null_role = "root.field.1.discriminators"
      positive_all_null_callback = bulk_b.callback_name_for(positive_all_null_role)
      positive_all_null = plan.callback_events.find do |event|
        !event.prefix? && event.name == positive_all_null_callback
      end || raise "W283 positive-Q Variant body callback is missing"
      encoded.callback_bytes(positive_all_null, 0).should_not be_empty
    end
  end

  it "normalizes one exact BASIC/COMPACT Variant body and rejects malformed or count-mismatched frames" do
    adapter = CrystalClick::BinaryBulkDiscriminatorFramingAdapter
    role = "root.elements.field.0.discriminators"
    limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS

    adapter.read_mark_body(
      role,
      CrystalClick::CompactVariantDiscriminatorMode::Basic.wire_value,
      Bytes[0_u8, 0xff_u8],
      2_u64,
      CrystalClick::BinaryCodecBudget.new(limits, false),
    ).should eq({Bytes[0_u8, 0xff_u8], 2})

    # The nested Array's child occurrence count is six here, not the parent
    # mark's two rows. Keep that inherited-Q distinction at the framing seam.
    compact = adapter.read_mark_body(
      role,
      CrystalClick::CompactVariantDiscriminatorMode::Compact.wire_value,
      Bytes[6_u8, CrystalClick::DynamicDiscriminatorBodyValidator::COMPACT_UNIFORM_TAG, 0xff_u8],
      6_u64,
      CrystalClick::BinaryCodecBudget.new(limits, false),
    )
    compact.should eq({Bytes.new(6, 0xff_u8), 3})

    adapter.read_mark_body(
      role,
      CrystalClick::CompactVariantDiscriminatorMode::Compact.wire_value,
      Bytes.new(0),
      0_u64,
      CrystalClick::BinaryCodecBudget.new(limits, false),
    ).should eq({Bytes.new(0), 0})

    invalid_mode_budget = CrystalClick::BinaryCodecBudget.new(limits, false)
    expect_raises(CrystalClick::CorruptPartError) do
      adapter.read_mark_body(
        role,
        2_u64,
        Bytes.new(0),
        0_u64,
        invalid_mode_budget,
      )
    end
    {invalid_mode_budget.wire_byte_count, invalid_mode_budget.element_count}.should eq({0_i64, 0_i64})

    malformed = [
      Bytes[2_u8, CrystalClick::DynamicDiscriminatorBodyValidator::COMPACT_ROW_TAGS, 0xff_u8],             # truncated row tags
      Bytes[0x82_u8, 0_u8, CrystalClick::DynamicDiscriminatorBodyValidator::COMPACT_UNIFORM_TAG, 0xff_u8], # nonminimal Q
      Bytes[2_u8, 2_u8],                                                                                   # unknown compact group tag
    ] of Bytes
    malformed.each do |bytes|
      expect_raises(CrystalClick::CorruptPartError) do
        adapter.read_mark_body(
          role,
          CrystalClick::CompactVariantDiscriminatorMode::Compact.wire_value,
          bytes,
          2_u64,
          CrystalClick::BinaryCodecBudget.new(limits, false),
        )
      end
    end

    expect_raises(CrystalClick::CorruptPartError) do
      adapter.read_mark_body(
        role,
        CrystalClick::CompactVariantDiscriminatorMode::Compact.wire_value,
        Bytes[2_u8, CrystalClick::DynamicDiscriminatorBodyValidator::COMPACT_UNIFORM_TAG, 0xff_u8],
        1_u64,
        CrystalClick::BinaryCodecBudget.new(limits, false),
      )
    end
    expect_raises(CrystalClick::CorruptPartError) do
      adapter.read_mark_body(
        role,
        CrystalClick::CompactVariantDiscriminatorMode::Compact.wire_value,
        Bytes[2_u8, CrystalClick::DynamicDiscriminatorBodyValidator::COMPACT_UNIFORM_TAG, 0xff_u8, 0x5a_u8],
        2_u64,
        CrystalClick::BinaryCodecBudget.new(limits, false),
      )
    end
  end

  it "charges COMPACT tag normalization at the exact byte budget before allocation" do
    adapter = CrystalClick::BinaryBulkDiscriminatorFramingAdapter
    role = "root.elements.field.0.discriminators"
    body = Bytes[6_u8, CrystalClick::DynamicDiscriminatorBodyValidator::COMPACT_UNIFORM_TAG, 0xff_u8]

    exact_limits = CrystalClick::BinaryCodecLimits.new(
      CrystalClick::BinaryCodecLimits::DEFAULT_MAX_DEPTH,
      CrystalClick::BinaryCodecLimits::DEFAULT_MAX_NODES,
      CrystalClick::BinaryCodecLimits::DEFAULT_MAX_ELEMENTS,
      6,
    )
    exact_budget = CrystalClick::BinaryCodecBudget.new(exact_limits)
    adapter.read_mark_body(
      role,
      CrystalClick::CompactVariantDiscriminatorMode::Compact.wire_value,
      body,
      6_u64,
      exact_budget,
    ).should eq({Bytes.new(6, 0xff_u8), 3})
    {exact_budget.wire_byte_count, exact_budget.element_count}.should eq({6_i64, 0_i64})

    short_limits = CrystalClick::BinaryCodecLimits.new(
      CrystalClick::BinaryCodecLimits::DEFAULT_MAX_DEPTH,
      CrystalClick::BinaryCodecLimits::DEFAULT_MAX_NODES,
      CrystalClick::BinaryCodecLimits::DEFAULT_MAX_ELEMENTS,
      5,
    )
    short_budget = CrystalClick::BinaryCodecBudget.new(short_limits)
    expect_raises(CrystalClick::CorruptPartError) do
      adapter.read_mark_body(
        role,
        CrystalClick::CompactVariantDiscriminatorMode::Compact.wire_value,
        body,
        6_u64,
        short_budget,
      )
    end
    {short_budget.wire_byte_count, short_budget.element_count}.should eq({0_i64, 0_i64})
  end

  it "does not commit an MRK3 Variant body on wrong inherited Q and retries at the same frame boundary" do
    role = "root.elements.field.0.discriminators"
    sibling = 0x5a_u8
    tape = Bytes[6_u8, CrystalClick::DynamicDiscriminatorBodyValidator::COMPACT_UNIFORM_TAG, 0xff_u8, sibling]
    shard = CrystalClick::CompactPartPhysicalShard.new(0, nil, 0_i64, tape.size.to_i64, tape)
    cursor = CrystalClick::CompactBinaryBulkGranuleCursor.new(
      CrystalClick::CompactMarkFormat::Mrk3,
      [shard],
      nil,
    )
    adapter = CrystalClick::BinaryBulkDiscriminatorFramingAdapter
    limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS

    # P=2 would be the parent count; this Array child lane inherits Q=6.
    expect_raises(CrystalClick::CorruptPartError) do
      cursor.with_transactional_borrowed_prefix do |borrowed|
        adapter.read_mark_body(
          role,
          CrystalClick::CompactVariantDiscriminatorMode::Compact.wire_value,
          borrowed,
          2_u64,
          CrystalClick::BinaryCodecBudget.new(limits, false),
          false,
        )
      end
    end
    cursor.position.should eq(0)

    parsed, captured = cursor.with_transactional_borrowed_prefix do |borrowed|
      adapter.read_mark_body(
        role,
        CrystalClick::CompactVariantDiscriminatorMode::Compact.wire_value,
        borrowed,
        6_u64,
        CrystalClick::BinaryCodecBudget.new(limits, false),
        false,
      )
    end
    parsed.should eq(Bytes.new(6, 0xff_u8))
    captured.should eq(tape[0, 3])
    cursor.position.should eq(3)
    cursor.read_exact(1).should eq(Bytes[sibling])
  end

  it "keeps nested and direct LC arm prefixes schema-ordered even when the arm occurrence count is zero" do
    fixture = CompactPartWriterW283LCVariantFixture
    limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
    plan = CrystalClick::CompactJsonCallbackPlan.new(
      fixture.column.json_input(CrystalClick::BinaryBulkProfile.single_stream),
      limits,
      CrystalClick::BinaryCodecBudget.new(limits, true),
      CrystalClick::CompactVariantDiscriminatorMode::Compact,
    )
    site = plan.schema_plan.bulk_site("root/tuple[1]")
    roles = [
      "root.discriminators",
      "root.arm.0.elements.dictionary",
      "root.arm.1.dictionary",
    ] of String
    expected = w283_variant_prefix_pairs(site, roles)
    prefix_names = expected.map(&.[1])
    site_prefixes = plan.callback_events.select do |event|
      event.prefix? && prefix_names.includes?(event.name)
    end
    w283_variant_event_pairs(site_prefixes, true).should eq(expected)

    encoded = CrystalClick::CompactJsonEncodedColumn.encode(
      plan,
      CrystalClick::BinaryCodecBudget.new(limits, true),
    )
    mode_prefix = site_prefixes.find { |event| event.role == roles[0] } ||
                  raise "W283 LC-arm Variant mode prefix is missing"
    nested_lc_prefix = site_prefixes.find { |event| event.role == roles[1] } ||
                       raise "W283 nested LC-arm prefix is missing"
    direct_lc_prefix = site_prefixes.find { |event| event.role == roles[2] } ||
                       raise "W283 direct LC-arm prefix is missing"

    CompactPartWriterW283LCVariantFixture::MARK_COUNT.times do |mark|
      w283_variant_le_u64(encoded.callback_bytes(mode_prefix, mark)).should eq(
        CrystalClick::CompactVariantDiscriminatorMode::Compact.wire_value,
      )
      w283_variant_le_u64(encoded.callback_bytes(nested_lc_prefix, mark)).should eq(1_u64)
      w283_variant_le_u64(encoded.callback_bytes(direct_lc_prefix, mark)).should eq(1_u64)
    end

    nested_lc_indexes_role = "root.arm.0.elements.indexes"
    nested_lc_indexes_callback = site.callback_name_for(nested_lc_indexes_role)
    nested_lc_indexes = plan.callback_events.find do |event|
      !event.prefix? && event.name == nested_lc_indexes_callback
    end || raise "W283 nested LC-arm index callback is missing"
    direct_lc_indexes_role = "root.arm.1.indexes"
    direct_lc_indexes_callback = site.callback_name_for(direct_lc_indexes_role)
    direct_lc_indexes = plan.callback_events.find do |event|
      !event.prefix? && event.name == direct_lc_indexes_callback
    end || raise "W283 direct LC-arm index callback is missing"
    encoded.callback_bytes(nested_lc_indexes, 0).should be_empty
    encoded.callback_bytes(nested_lc_indexes, 1).should be_empty
    encoded.callback_bytes(direct_lc_indexes, 0).should be_empty
    encoded.callback_bytes(direct_lc_indexes, 1).should_not be_empty
  end

  it "round-trips a selected empty Array arm and LC-bearing arms under both discriminator grammars" do
    fixture = CompactPartWriterW283LCVariantFixture
    CrystalClick::CompactRecursiveJsonColumnReader.admitted_schema?(fixture.schema).should be_true
    w283_lc_variant_write_read_matrix
  end

  it "rejects a syntactically valid BASIC discriminator outside its Variant arm roster" do
    fixture = CompactPartWriterW283Fixture
    parent = File.tempname("crystal-click-w283-variant-arm-id-")
    part_path = File.join(parent, "all_1_1_0")
    Dir.mkdir(parent)
    begin
      CrystalClick::CompactPartWriter.write_uint64_columns(
        part_path,
        CompactPartWriterW283Fixture::KEY_NAME,
        fixture.keys,
        [fixture.column] of CrystalClick::CompactPartColumn,
        rows_per_mark: CompactPartWriterW283Fixture::ROWS_PER_MARK,
        frame_bytes: CompactPartWriterW283Fixture::FRAME_BYTES,
        mark_format: CrystalClick::CompactMarkFormat::Mrk4,
        variant_discriminator_mode: CrystalClick::CompactVariantDiscriminatorMode::Basic,
        profile: CrystalClick::BinaryBulkProfile.single_stream,
      ).should eq(part_path)

      role = "root.elements.field.0.discriminators"
      plan = w283_variant_plan(
        CrystalClick::BinaryBulkProfile.single_stream,
        CrystalClick::CompactVariantDiscriminatorMode::Basic,
      )
      site = plan.schema_plan.bulk_site("root/tuple[1]")
      fixture.variant_type.child_count.should eq(3)
      callback = site.callback_name_for(role)
      plan.callback_events.any? do |event|
        !event.prefix? && event.name == callback
      end.should be_true

      # Parent mark 2 contains six Array-child Variant occurrences, including
      # all three declared arms. Replace the first arm-0 byte with arm ID 3;
      # BASIC framing remains one byte per occurrence and therefore valid.
      physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
      granule = physical.read_window(CompactPartWriterW283Fixture::COLUMN_NAME, 2, 1).granules.first? ||
                raise "W283 arm-ID fixture has no third parent mark"
      shard = granule.shards.find { |candidate| candidate.stream_name == callback } ||
              raise "W283 Variant discriminator callback is absent"
      shard.bytes.first.should eq(0_u8)
      shard.bytes.size.should eq(6)

      raw = CrystalClick::CompressedMarkReader.read_all(
        File.join(part_path, "data.bin"),
        File.size(File.join(part_path, "data.bin")).to_i64,
      )
      raw[shard.logical_start.to_i] = 3_u8
      w283_reseal_mrk4!(part_path, physical, raw)

      resealed = CrystalClick::CompactPartPhysicalContext.open(part_path)
      resealed_granule = resealed.read_window(CompactPartWriterW283Fixture::COLUMN_NAME, 2, 1).granules.first? ||
                         raise "W283 resealed arm-ID fixture has no third parent mark"
      resealed_shard = resealed_granule.shards.find { |candidate| candidate.stream_name == callback } ||
                       raise "W283 resealed Variant discriminator callback is absent"
      resealed_shard.bytes.first.should eq(3_u8)

      reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
        part_path,
        CompactPartWriterW283Fixture::COLUMN_NAME,
        fixture.schema,
      )
      expect_raises(CrystalClick::CorruptPartError, /outside its arm roster/) do
        reader.read_marks(2, 1)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
