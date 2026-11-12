require "./spec_helper"

module CompactRecursiveDynamicW284CaptureFixture
  extend self

  SITE_KEY    = "root/array[0]/tuple[1]"
  SCHEMA      = "Array(Tuple(doc JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8), sample Dynamic(max_types=1)))"
  COLUMN_NAME = "trace"

  def site : CrystalClick::CompactRecursiveJsonDynamicBulkSite
    limits = CrystalClick::BinaryCodecLimits.default
    schema = CrystalClick::StorageColumnSchema.parse(SCHEMA)
    budget = CrystalClick::BinaryCodecBudget.new(limits, true)
    schema_plan = CrystalClick::CompactRecursiveJsonSchemaPlan.new(
      schema,
      COLUMN_NAME,
      limits,
      budget,
      CrystalClick::BinaryBulkProfile.single_stream,
    )
    schema_plan.dynamic_bulk_site(SITE_KEY)
  end

  def capture_plan(
    site : CrystalClick::CompactRecursiveJsonDynamicBulkSite,
    actual_type : CrystalClick::BinaryDataType,
    limits : CrystalClick::BinaryCodecLimits,
    budget : CrystalClick::BinaryCodecBudget,
  ) : CrystalClick::CompactRecursiveJsonDynamicBulkCapturePlan
    structure = CrystalClick::DynamicStructure.new([actual_type] of CrystalClick::BinaryDataType)
    CrystalClick::CompactRecursiveJsonDynamicBulkCapturePlan.new(
      site,
      structure,
      CrystalClick::BinaryBulkProfile.single_stream,
      limits,
      budget,
    )
  end

  def roomy_capture_plan(
    site : CrystalClick::CompactRecursiveJsonDynamicBulkSite,
    actual_type : CrystalClick::BinaryDataType,
  ) : CrystalClick::CompactRecursiveJsonDynamicBulkCapturePlan
    limits = CrystalClick::BinaryCodecLimits.default
    capture_plan(site, actual_type, limits, CrystalClick::BinaryCodecBudget.new(limits, false))
  end

  def mode_prefix(value : UInt64 = CrystalClick::DynamicDiscriminatorBodyValidator::BASIC_MODE) : Bytes
    Bytes.new(CrystalClick::BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES) do |index|
      ((value >> (index * 8)) & 0xff_u64).to_u8
    end
  end

  def dictionary_prefix : Bytes
    bytes = Bytes.new(8, 0_u8)
    bytes[0] = CrystalClick::BinaryLowCardinalityStorageStreams::VERSION.to_u8
    bytes
  end

  def prefix_role_for(
    plan : CrystalClick::CompactRecursiveJsonDynamicBulkCapturePlan,
    callback : String,
  ) : String
    found = nil.as(String?)
    plan.each_data_role do |role|
      next if plan.physical_plan.prefix_size_for(role) == 0
      if plan.prefix_callback_name_for(role) == callback
        found = role
        break
      end
    end
    found || raise("fixture callback is not bound to a Dynamic state-prefix role")
  end

  def capture_prefixes(
    mark : CrystalClick::CompactRecursiveJsonDynamicBulkMark,
    plan : CrystalClick::CompactRecursiveJsonDynamicBulkCapturePlan,
  ) : Nil
    (1...plan.prefix_callback_count).each do |index|
      callback = plan.prefix_callback_at(index)
      role = prefix_role_for(plan, callback)
      kind = if role.ends_with?(".dictionary")
               CrystalClick::CompactRecursiveJsonDynamicBulkMark::StatePrefixKind::LowCardinalityDictionaryV1
             else
               CrystalClick::CompactRecursiveJsonDynamicBulkMark::StatePrefixKind::VariantDiscriminatorMode
             end
      bytes = if kind == CrystalClick::CompactRecursiveJsonDynamicBulkMark::StatePrefixKind::LowCardinalityDictionaryV1
                dictionary_prefix
              else
                mode_prefix
              end
      mark.capture_state_prefix!(role, kind, bytes)
    end
    nil
  end

  def capture_lanes(
    mark : CrystalClick::CompactRecursiveJsonDynamicBulkMark,
    plan : CrystalClick::CompactRecursiveJsonDynamicBulkCapturePlan,
    discriminator_body : Bytes = Bytes.empty,
    count : Int32? = nil,
  ) : Nil
    lane_count = count || plan.data_role_count.to_i32
    lane_count.times do |index|
      role = plan.body_role_at(index)
      bytes = role == "root.discriminators" ? discriminator_body : Bytes.empty
      mark.capture_lane(role, bytes)
    end
    nil
  end

  def mark(
    plan : CrystalClick::CompactRecursiveJsonDynamicBulkCapturePlan,
  ) : CrystalClick::CompactRecursiveJsonDynamicBulkMark
    limits = CrystalClick::BinaryCodecLimits.default
    CrystalClick::CompactRecursiveJsonDynamicBulkMark.new(
      plan,
      CrystalClick::BinaryCodecBudget.new(limits, false),
    )
  end

  def limits(nodes : Int64, elements : Int64, bytes : Int64) : CrystalClick::BinaryCodecLimits
    CrystalClick::BinaryCodecLimits.new(
      CrystalClick::BinaryCodecLimits::DEFAULT_MAX_DEPTH,
      nodes,
      elements,
      bytes,
    )
  end
end

describe "W284 recursive Dynamic capture adversaries" do
  it "fails closed on JSON, nested Dynamic, and Dynamic-only-forbidden actual arms" do
    fixture = CompactRecursiveDynamicW284CaptureFixture
    site = fixture.site
    limits = CrystalClick::BinaryCodecLimits.default

    json = CrystalClick::BinaryDataType.json(max_dynamic_paths: 0, max_dynamic_types: 0)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      fixture.capture_plan(site, json, limits, CrystalClick::BinaryCodecBudget.new(limits, false))
    end

    nested_dynamic = CrystalClick::BinaryDataType.array(
      CrystalClick::BinaryDataType.dynamic(max_types: 1),
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      fixture.capture_plan(site, nested_dynamic, limits, CrystalClick::BinaryCodecBudget.new(limits, false))
    end

    simple_aggregate = CrystalClick::BinaryDataType.simple_aggregate(
      CrystalClick::BinarySimpleAggregateType::Function::Sum,
      CrystalClick::BinaryDataType.primitive("UInt64"),
    )
    CrystalClick::CompactRecursiveJsonStaticBulkGrammar.admitted_type?(
      simple_aggregate,
      site.descriptor_depth + 1,
      limits,
    ).should be_true
    expect_raises(CrystalClick::UnsupportedFormatError) do
      fixture.capture_plan(site, simple_aggregate, limits, CrystalClick::BinaryCodecBudget.new(limits, false))
    end
  end

  it "preflights closed callback wrappers in elements at the exact and one-under boundary" do
    fixture = CompactRecursiveDynamicW284CaptureFixture
    site = fixture.site
    actual = CrystalClick::BinaryDataType.primitive("UInt64")
    limits = CrystalClick::BinaryCodecLimits.default
    standalone_budget = CrystalClick::BinaryCodecBudget.new(limits, false)
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    structure = CrystalClick::DynamicStructure.new([actual] of CrystalClick::BinaryDataType)
    structures = {"root" => structure} of String => CrystalClick::DynamicStructure
    _base = CrystalClick::BinaryDynamicBulkPlan.decode_structure_prefixes_without_statistics_from_structures(
      dynamic_type,
      structures,
      standalone_budget,
      CrystalClick::BinaryBulkProfile.single_stream,
      initial_depth: site.descriptor_depth,
    )

    measured_budget = CrystalClick::BinaryCodecBudget.new(limits, false)
    measured = fixture.capture_plan(site, actual, limits, measured_budget)
    expected_callbacks = [
      "trace%2Esample.dynamic_structure",
      "trace%2Esample.variant_discr_prefix",
      "trace%2Esample.variant_discr",
      "trace%2Esample.SharedVariant",
      "trace%2Esample.UInt64",
    ]
    (measured.prefix_callbacks + measured.body_callbacks).should eq(expected_callbacks)
    measured.site.descriptor_depth.should eq(3)
    measured.site.initial_array_level.should eq(1_u64)

    wrapper_element_delta = measured_budget.element_count - standalone_budget.element_count
    independent_name_copy_lower_bound = 0_i64
    expected_callbacks.each do |name|
      independent_name_copy_lower_bound += 2_i64 * (name.bytesize.to_i64 + 1_i64)
    end
    wrapper_element_delta.should be >= independent_name_copy_lower_bound

    exact_limits = fixture.limits(
      measured_budget.node_count,
      measured_budget.element_count,
      measured_budget.wire_byte_count,
    )
    exact_budget = CrystalClick::BinaryCodecBudget.new(exact_limits, false)
    exact = fixture.capture_plan(site, actual, exact_limits, exact_budget)
    exact.prefix_callbacks.concat(exact.body_callbacks).should eq(expected_callbacks)
    exact_budget.node_count.should eq(measured_budget.node_count)
    exact_budget.element_count.should eq(measured_budget.element_count)
    exact_budget.wire_byte_count.should eq(measured_budget.wire_byte_count)

    one_under_limits = fixture.limits(
      measured_budget.node_count,
      measured_budget.element_count - 1_i64,
      measured_budget.wire_byte_count,
    )
    one_under_budget = CrystalClick::BinaryCodecBudget.new(one_under_limits, false)
    refused = nil.as(CrystalClick::CompactRecursiveJsonDynamicBulkCapturePlan?)
    expect_raises(CrystalClick::CorruptPartError) do
      refused = fixture.capture_plan(site, actual, one_under_limits, one_under_budget)
    end
    refused.should be_nil
  end

  it "rejects reordered, repeated, missing, and overrun state-prefix and body captures" do
    fixture = CompactRecursiveDynamicW284CaptureFixture
    site = fixture.site
    actual = CrystalClick::BinaryDataType.low_cardinality(
      CrystalClick::BinaryDataType.primitive("String"),
    )
    plan = fixture.roomy_capture_plan(site, actual)
    mark = fixture.mark(plan)
    mode_role = "root.discriminators"
    dictionary_role = nil.as(String?)
    plan.each_data_role do |role|
      dictionary_role = role if role.ends_with?(".dictionary")
    end
    dictionary = dictionary_role || raise("LowCardinality fixture has no dictionary role")

    expect_raises(CrystalClick::CorruptPartError) do
      mark.capture_state_prefix!(
        dictionary,
        CrystalClick::CompactRecursiveJsonDynamicBulkMark::StatePrefixKind::LowCardinalityDictionaryV1,
        fixture.dictionary_prefix,
      )
    end
    mark.capture_state_prefix!(
      mode_role,
      CrystalClick::CompactRecursiveJsonDynamicBulkMark::StatePrefixKind::VariantDiscriminatorMode,
      fixture.mode_prefix,
    )
    mark.capture_state_prefix!(
      dictionary,
      CrystalClick::CompactRecursiveJsonDynamicBulkMark::StatePrefixKind::LowCardinalityDictionaryV1,
      fixture.dictionary_prefix,
    )
    expect_raises(CrystalClick::CorruptPartError) do
      mark.capture_state_prefix!(
        mode_role,
        CrystalClick::CompactRecursiveJsonDynamicBulkMark::StatePrefixKind::VariantDiscriminatorMode,
        fixture.mode_prefix,
      )
    end
    expect_raises(CrystalClick::CorruptPartError) do
      plan.prefix_callback_at(plan.prefix_callback_count)
    end

    first_body = plan.body_role_at(0)
    second_body = plan.body_role_at(1)
    expect_raises(CrystalClick::CorruptPartError) do
      mark.capture_lane(second_body, Bytes.empty)
    end
    fixture.capture_lanes(mark, plan)
    expect_raises(CrystalClick::CorruptPartError) do
      mark.capture_lane(first_body, Bytes.empty)
    end

    missing_prefix = fixture.mark(plan)
    fixture.capture_lanes(missing_prefix, plan)
    expect_raises(CrystalClick::CorruptPartError) do
      missing_prefix.build_streams(CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, false))
    end

    missing_body = fixture.mark(plan)
    fixture.capture_prefixes(missing_body, plan)
    fixture.capture_lanes(missing_body, plan, count: plan.data_role_count.to_i32 - 1)
    expect_raises(CrystalClick::CorruptPartError) do
      missing_body.build_streams(CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, false))
    end
  end

  it "keeps a packaged mark unpublished and reusable after one-under element refusal" do
    fixture = CompactRecursiveDynamicW284CaptureFixture
    site = fixture.site
    plan = fixture.roomy_capture_plan(site, CrystalClick::BinaryDataType.primitive("UInt64"))
    mark = fixture.mark(plan)
    fixture.capture_prefixes(mark, plan)
    fixture.capture_lanes(mark, plan)

    role_count = plan.data_role_count
    roster_key_bytes = 0_u64
    plan.each_data_role { |role| roster_key_bytes += role.bytesize.to_u64 + 1_u64 }
    expected_nodes = 3_u64 + 5_u64 * role_count
    expected_elements = 8_u64 * role_count + 2_u64 * roster_key_bytes
    expected_nodes.should be <= Int64::MAX.to_u64
    expected_elements.should be <= Int64::MAX.to_u64

    refused_budget = CrystalClick::BinaryCodecBudget.new(
      fixture.limits(expected_nodes.to_i64, expected_elements.to_i64 - 1_i64, 0_i64),
      false,
    )
    refused_streams = nil.as(CrystalClick::BinaryBulkStreams?)
    expect_raises(CrystalClick::CorruptPartError) do
      refused_streams = mark.build_streams(refused_budget)
    end
    refused_streams.should be_nil
    refused_budget.node_count.should eq(0_i64)
    refused_budget.element_count.should eq(0_i64)
    refused_budget.wire_byte_count.should eq(0_i64)

    exact_budget = CrystalClick::BinaryCodecBudget.new(
      fixture.limits(expected_nodes.to_i64, expected_elements.to_i64, 0_i64),
      false,
    )
    streams = mark.build_streams(exact_budget)
    streams.role_count.should eq(role_count.to_i)
    exact_budget.node_count.to_u64.should eq(expected_nodes)
    exact_budget.element_count.to_u64.should eq(expected_elements)
    exact_budget.wire_byte_count.should eq(0_i64)
  end

  it "preserves zero-Q empty versus NULL discriminator bodies and the empty SharedVariant lane" do
    fixture = CompactRecursiveDynamicW284CaptureFixture
    site = fixture.site
    plan = fixture.roomy_capture_plan(site, CrystalClick::BinaryDataType.primitive("UInt64"))
    shared_role = "root.arm.#{plan.dynamic_plan.shared_index("root")}.data"
    uint64_index = plan.arm_count.times.find do |index|
      plan.arm_type(index) == CrystalClick::BinaryDataType.primitive("UInt64")
    end || raise("UInt64 fixture arm is missing")
    uint64_role = "root.arm.#{uint64_index}.data"

    empty_mark = fixture.mark(plan)
    fixture.capture_prefixes(empty_mark, plan)
    fixture.capture_lanes(empty_mark, plan, Bytes.empty)
    empty_streams = empty_mark.build_streams(CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, false))

    null_mark = fixture.mark(plan)
    fixture.capture_prefixes(null_mark, plan)
    fixture.capture_lanes(null_mark, plan, Bytes[0xff_u8])
    null_streams = null_mark.build_streams(CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, false))

    empty_streams.stream("root.discriminators").bytes.should eq(Bytes.empty)
    null_streams.stream("root.discriminators").bytes.should eq(Bytes[0xff_u8])
    {shared_role, uint64_role}.each do |role|
      empty_streams.has_role?(role).should be_true
      null_streams.has_role?(role).should be_true
      empty_streams.stream(role).byte_size.should eq(0)
      null_streams.stream(role).byte_size.should eq(0)
    end
  end
end
