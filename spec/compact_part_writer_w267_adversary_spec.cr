require "./spec_helper"
require "./support/compact_part_writer_w267_fixture"

private def w267a_fixture_limits(max_bytes : Int = 64 * 1024 * 1024, max_elements : Int = 3_000_000) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(64, 1_000_000, max_elements, max_bytes)
end

private def w267a_measure_stateful_batch(
  type : CrystalClick::BinaryDataType,
  granules : Array(Array(CrystalClick::BinaryValue)),
  roles : Array(String),
  mode : UInt64,
  limits : CrystalClick::BinaryCodecLimits,
) : Tuple(Int64, Int64, Int64, Int64)
  budget = CrystalClick::BinaryCodecBudget.new(limits, true)
  output_bytes = 0_i64
  copied_coordinates = 0_i64
  granules.each do |rows|
    streams = CrystalClick::BinaryBulkEncoder.encode(
      type,
      [rows],
      budget,
      CrystalClick::BinaryBulkProfile.single_stream,
      low_cardinality_policy: CrystalClick::BinaryLowCardinalityStoragePolicy::AdditionalKeysOnly,
    )
    roles.each do |role|
      stream = streams.stream(role)
      output_bytes += CrystalClick::BinaryBulkDiscriminatorFramingAdapter.physical_size(stream, mode).to_i64
      copied_coordinates += stream.offset_count.to_i64
    end
  end
  {budget.wire_byte_count, budget.element_count, output_bytes, copied_coordinates}
end

private def w267a_read_u64_le(bytes : Bytes) : UInt64
  unless bytes.size == CrystalClick::BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES
    raise "W267 adversary Variant prefix must be eight bytes"
  end
  value = 0_u64
  bytes.size.times do |index|
    value |= bytes[index].to_u64 << (index * 8)
  end
  value
end

describe "W267 Compact Variant writer adversaries" do
  it "keeps LowCardinality-only and Variant-only callback maps distinct and usable" do
    fixture_limits = w267a_fixture_limits

    string_type = CrystalClick::BinaryDataType.primitive("String")
    low_type = CrystalClick::BinaryDataType.low_cardinality(string_type)
    low_values = ["a", "b", "b", "c"].map do |value|
      CrystalClick::BinaryValue.low_cardinality(low_type, CrystalClick::BinaryValue.string(value))
    end
    low_granules = low_values.each_slice(2).map(&.to_a).to_a
    low_input = CrystalClick::CompactStaticColumnInput.new("lc_only", low_type, low_granules)
    low_plan = CrystalClick::CompactStaticCallbackPlan.new(low_input, fixture_limits)
    low_encoded = CrystalClick::CompactEncodedColumn.encode(
      low_plan,
      low_input.granules,
      CrystalClick::BinaryCodecBudget.new(fixture_limits, true),
    )

    low_plan.variant_discriminator_roles.should be_empty
    low_plan.dictionary_prefix_roles.size.should eq(1)
    low_plan.callback_events.each do |event|
      bytes = low_encoded.callback_bytes(event, 0)
      if event.prefix?
        low_plan.dictionary_prefix_role?(event.role).should be_true
        bytes.size.should eq(8)
        w267a_read_u64_le(bytes).should eq(CrystalClick::BinaryLowCardinalityStorageStreams::VERSION)
      end
    end

    variant_type = CrystalClick::BinaryDataType.variant(
      [string_type, CrystalClick::BinaryDataType.primitive("UInt64")] of CrystalClick::BinaryDataType,
    )
    variant_rows = [
      CrystalClick::BinaryValue.variant(variant_type, 0, CrystalClick::BinaryValue.string("v0")),
      CrystalClick::BinaryValue.variant(variant_type, 1, CrystalClick::BinaryValue.uint64(7_u64)),
      CrystalClick::BinaryValue.variant(variant_type, 0, CrystalClick::BinaryValue.string("v2")),
      CrystalClick::BinaryValue.variant(variant_type, 1, CrystalClick::BinaryValue.uint64(UInt64::MAX)),
    ] of CrystalClick::BinaryValue
    variant_granules = variant_rows.each_slice(2).map(&.to_a).to_a
    variant_input = CrystalClick::CompactStaticColumnInput.new("variant_only", variant_type, variant_granules)
    variant_plan = CrystalClick::CompactStaticCallbackPlan.new(variant_input, fixture_limits)
    variant_encoded = CrystalClick::CompactEncodedColumn.encode(
      variant_plan,
      variant_input.granules,
      CrystalClick::BinaryCodecBudget.new(fixture_limits, true),
    )

    variant_plan.dictionary_prefix_roles.should be_empty
    variant_plan.variant_discriminator_roles.size.should eq(1)
    variant_prefixes = 0
    variant_plan.callback_events.each do |event|
      bytes = variant_encoded.callback_bytes(event, 0)
      if event.prefix?
        variant_plan.variant_discriminator_role?(event.role).should be_true
        event.name.ends_with?(".variant_discr_prefix").should be_true
        w267a_read_u64_le(bytes).should eq(CrystalClick::CompactVariantDiscriminatorMode::Compact.wire_value)
        variant_prefixes += 1
      end
    end
    variant_prefixes.should eq(1)
  end

  it "binds dictionary and discriminator prefixes to separate recursive roles" do
    fixture = CompactPartWriterW267Fixture
    limits = w267a_fixture_limits
    input = CrystalClick::CompactStaticColumnInput.new("ctx", fixture.types["ctx"], fixture.granules_for("ctx"))
    plan = CrystalClick::CompactStaticCallbackPlan.new(input, limits)

    dictionary_roles = plan.dictionary_prefix_roles
    discriminator_roles = plan.variant_discriminator_roles
    dictionary_roles.should_not be_empty
    discriminator_roles.should_not be_empty
    dictionary_roles.any? { |role| discriminator_roles.includes?(role) }.should be_false

    events = plan.callback_events
    dictionary_prefixes = events.select do |event|
      event.prefix? && plan.dictionary_prefix_role?(event.role)
    end
    variant_prefixes = events.select do |event|
      event.prefix? && plan.variant_discriminator_role?(event.role)
    end
    dictionary_prefixes.size.should eq(dictionary_roles.size)
    variant_prefixes.size.should eq(discriminator_roles.size)
    dictionary_prefixes.each do |event|
      event.name.ends_with?(".dict_prefix").should be_true
      events.any? { |body| !body.prefix? && body.role == event.role }.should be_true
    end
    variant_prefixes.each do |event|
      event.name.ends_with?(".variant_discr_prefix").should be_true
      events.any? { |body| !body.prefix? && body.role == event.role }.should be_true
    end
  end

  it "rejects counterfeit callbacks and preserves the selected mode in detached plans" do
    fixture = CompactPartWriterW267Fixture
    limits = w267a_fixture_limits
    key_type = CrystalClick::BinaryDataType.primitive("UInt64")
    key_rows = [CrystalClick::BinaryValue.uint64(1_u64)] of CrystalClick::BinaryValue
    inputs = [] of CrystalClick::CompactStaticColumnInput
    inputs << CrystalClick::CompactStaticColumnInput.new("pk", key_type, [key_rows])
    inputs << CrystalClick::CompactStaticColumnInput.new(
      "payload",
      fixture.types["payload"],
      fixture.granules_for("payload"),
    )

    plan = CrystalClick::CompactStaticWritePlan.new(
      inputs,
      limits,
      CrystalClick::CompactMarkFormat::Mrk4,
      CrystalClick::CompactVariantDiscriminatorMode::Basic,
    )
    plans_snapshot = plan.column_plans
    plans_snapshot.clear
    plans = plan.column_plans
    plans.size.should eq(2)
    plans.each do |column_plan|
      column_plan.variant_discriminator_mode.should eq(CrystalClick::CompactVariantDiscriminatorMode::Basic)
    end

    payload_plan = plans[1]
    detached_names = payload_plan.callback_names
    detached_roles = payload_plan.callback_roles
    detached_events = payload_plan.callback_events
    detached_names.clear
    detached_roles << "forged.role"
    detached_events.clear
    payload_plan.callback_names.should_not be_empty
    payload_plan.callback_roles.includes?("forged.role").should be_false
    payload_plan.variant_discriminator_mode.should eq(plan.variant_discriminator_mode)

    variant_prefix = payload_plan.callback_events.find do |event|
      event.prefix? && payload_plan.variant_discriminator_role?(event.role)
    end || raise "W267 fixture has no Variant discriminator prefix"
    encoded = CrystalClick::CompactEncodedColumn.encode(
      payload_plan,
      inputs[1].granules,
      CrystalClick::BinaryCodecBudget.new(limits, true),
    )
    counterfeit_role = CrystalClick::CompactBinaryBulkCallback.new(
      variant_prefix.name,
      "forged.discriminators",
      variant_prefix.prefix_size,
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      encoded.callback_bytes(counterfeit_role, 0)
    end
    counterfeit_prefix = CrystalClick::CompactBinaryBulkCallback.new(
      variant_prefix.name,
      variant_prefix.role,
      variant_prefix.prefix_size - 1,
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      encoded.callback_bytes(counterfeit_prefix, 0)
    end
  end

  it "preflights all recursive Variant lanes on both cumulative budget axes" do
    fixture = CompactPartWriterW267Fixture
    high_limits = w267a_fixture_limits
    input = CrystalClick::CompactStaticColumnInput.new("ctx", fixture.types["ctx"], fixture.granules_for("ctx"))
    plan = CrystalClick::CompactStaticCallbackPlan.new(input, high_limits)
    roles = plan.variant_discriminator_roles
    roles.size.should eq(2)
    source_bytes, source_elements, adapted_bytes, copied_coordinates = w267a_measure_stateful_batch(
      input.type,
      input.granules,
      roles,
      plan.variant_discriminator_mode.wire_value,
      high_limits,
    )
    adapted_bytes.should be > 0
    copied_coordinates.should be > 2

    # Keep descriptor/callback admission fixed at the high-limit plan. The
    # intentionally short budgets below should isolate source plus adapter
    # work, not fail earlier while materializing the type declaration.
    byte_short_limits = w267a_fixture_limits(
      source_bytes + adapted_bytes - 1,
      3_000_000,
    )
    byte_short_budget = CrystalClick::BinaryCodecBudget.new(byte_short_limits, true)
    expect_raises(CrystalClick::UnsupportedFormatError, /binary codec byte limit exceeded/) do
      CrystalClick::CompactEncodedColumn.encode(plan, input.granules, byte_short_budget)
    end
    # Rejection must happen before discriminator adaptation charges any bytes.
    byte_short_budget.wire_byte_count.should eq(source_bytes)
    byte_short_budget.element_count.should eq(source_elements)

    element_short_limits = w267a_fixture_limits(
      source_bytes + adapted_bytes,
      source_elements + copied_coordinates - 1,
    )
    element_short_budget = CrystalClick::BinaryCodecBudget.new(element_short_limits, true)
    expect_raises(CrystalClick::UnsupportedFormatError, /binary codec element limit exceeded/) do
      CrystalClick::CompactEncodedColumn.encode(plan, input.granules, element_short_budget)
    end
    # Rejection must happen before discriminator adaptation charges coordinates.
    element_short_budget.wire_byte_count.should eq(source_bytes)
    element_short_budget.element_count.should eq(source_elements)
  end

  it "rejects unknown discriminator modes before creating a stage" do
    fixture = CompactPartWriterW267Fixture
    parent = File.tempname("crystal-click-w267-unknown-mode-")
    target = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      unknown_mode = CrystalClick::CompactVariantDiscriminatorMode.new(9_u64)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        unknown_mode.wire_value
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::CompactPartWriter.write_uint64_columns(
          target,
          CompactPartWriterW267Fixture::KEY_NAME,
          fixture.keys,
          fixture.columns,
          rows_per_mark: CompactPartWriterW267Fixture::ROWS_PER_MARK,
          frame_bytes: CompactPartWriterW267Fixture::FRAME_BYTES,
          variant_discriminator_mode: unknown_mode,
        )
      end
      File.exists?(target).should be_false
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
