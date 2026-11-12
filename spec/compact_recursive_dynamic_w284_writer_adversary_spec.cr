require "./spec_helper"

module CompactRecursiveDynamicW284WriterAdversaryFixture
  extend self

  JSON_DECLARATION   = "JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8)"
  SCHEMA_DECLARATION = "Array(Tuple(doc #{JSON_DECLARATION}, sample Dynamic(max_types=1)))"
  JSON_SITE          = "root/array[0]/tuple[0]"
  DYNAMIC_SITE       = "root/array[0]/tuple[1]"

  def schema : CrystalClick::StorageColumnSchema
    CrystalClick::StorageColumnSchema.parse(SCHEMA_DECLARATION)
  end

  def input(
    dynamic_context : CrystalClick::CompactDynamicWriteContext? = nil,
    include_dynamic_value : Bool = false,
  ) : CrystalClick::CompactJsonColumnInput
    site_context = dynamic_context || dynamic_context_for(
      CrystalClick::BinaryDataType.primitive("UInt64"),
    )
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    dynamic_value = CrystalClick::BinaryValue.dynamic(
      dynamic_type,
      include_dynamic_value ? CrystalClick::BinaryValue.uint64(7_u64) : nil,
    )
    document = CrystalClick::ObjectDocument.new(
      {"t" => CrystalClick::BinaryValue.fixed(
        CrystalClick::BinaryDataType.primitive("UInt8"),
        Bytes[9_u8],
      )} of String => CrystalClick::BinaryValue,
    )
    row = CrystalClick::StorageColumnValue.array([
      CrystalClick::StorageColumnValue.tuple([
        CrystalClick::StorageColumnValue.object_document(document),
        CrystalClick::StorageColumnValue.bulk(dynamic_value),
      ] of CrystalClick::StorageColumnValue),
    ] of CrystalClick::StorageColumnValue)
    column = CrystalClick::CompactPartColumn.json(
      "trace",
      schema,
      [[row] of CrystalClick::StorageColumnValue],
      json_context,
      dynamic_contexts: {DYNAMIC_SITE => site_context} of String => CrystalClick::CompactDynamicWriteContext,
    )
    column.json_input
  end

  def dynamic_context_for(
    actual_type : CrystalClick::BinaryDataType,
    population : UInt64 = 1_u64,
    extra_sites : Hash(String, CrystalClick::DynamicStructure) = {} of String => CrystalClick::DynamicStructure,
  ) : CrystalClick::CompactDynamicWriteContext
    probe = CrystalClick::DynamicStructure.new([actual_type] of CrystalClick::BinaryDataType)
    counts = Array(UInt64).new(probe.canonical_variant_count, 0_u64)
    counts[probe.canonical_index_for(actual_type)] = population
    root = CrystalClick::DynamicStructure.new(
      [actual_type] of CrystalClick::BinaryDataType,
      CrystalClick::StructureStatistics.new(counts, [] of CrystalClick::StructureStatistic),
      version: CrystalClick::DynamicStructure::VERSION_V3,
    )
    sites = {"root" => root} of String => CrystalClick::DynamicStructure
    extra_sites.each { |path, structure| sites[path] = structure }
    CrystalClick::CompactDynamicWriteContext.new(sites)
  end

  def json_context : CrystalClick::CompactJsonWriteContext
    object_schema = CrystalClick::ObjectDocumentSchema.parse_declaration(JSON_DECLARATION)
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
      {} of String => CrystalClick::DynamicStructure,
    )
    plan = CrystalClick::ObjectDocumentPlan.new(structures, object_schema.typed_paths)
    CrystalClick::CompactJsonWriteContext.new(
      {JSON_SITE => plan} of String => CrystalClick::ObjectDocumentPlan,
    )
  end

  def limits(nodes : Int64, elements : Int64, bytes : Int64) : CrystalClick::BinaryCodecLimits
    CrystalClick::BinaryCodecLimits.new(64, nodes, elements, bytes)
  end

  def snapshot(input : CrystalClick::CompactJsonColumnInput) : Array(Array(UInt64))
    input.granules.map do |rows|
      rows.map { |value| value.object_id.to_u64 }
    end
  end
end

describe "W284 recursive Dynamic writer adversaries" do
  it "admits the measured callback-plan budget exactly and refuses one node short without publishing" do
    fixture = CompactRecursiveDynamicW284WriterAdversaryFixture
    input = fixture.input
    before = fixture.snapshot(input)
    roomy_limits = CrystalClick::BinaryCodecLimits.default
    roomy_budget = CrystalClick::BinaryCodecBudget.new(roomy_limits, true)
    roomy_plan = CrystalClick::CompactJsonCallbackPlan.new(input, roomy_limits, roomy_budget)
    plan_nodes = roomy_budget.node_count
    plan_elements = roomy_budget.element_count
    plan_bytes = roomy_budget.wire_byte_count
    event_count = roomy_plan.callback_event_count
    detached_events = roomy_plan.callback_events
    event_count.times do |index|
      indexed = roomy_plan.callback_event_at(index)
      indexed.same?(detached_events[index]).should be_true
      indexed.name.should eq(detached_events[index].name)
      indexed.role.should eq(detached_events[index].role)
      indexed.prefix_size.should eq(detached_events[index].prefix_size)
    end
    expected_first_name = roomy_plan.callback_event_at(0).name
    detached_events[0] = CrystalClick::CompactBinaryBulkCallback.new("detached", "detached", 0)
    roomy_plan.callback_event_at(0).name.should eq(expected_first_name)
    expect_raises(IndexError) { roomy_plan.callback_event_at(-1) }
    expect_raises(IndexError) { roomy_plan.callback_event_at(event_count) }

    exact_limits = fixture.limits(plan_nodes, plan_elements, plan_bytes)
    exact_budget = CrystalClick::BinaryCodecBudget.new(exact_limits, true)
    exact_plan = CrystalClick::CompactJsonCallbackPlan.new(input, exact_limits, exact_budget)
    exact_plan.same_input?(input).should be_true
    exact_budget.node_count.should eq(plan_nodes)
    exact_budget.element_count.should eq(plan_elements)
    exact_budget.wire_byte_count.should eq(plan_bytes)

    [
      fixture.limits(plan_nodes - 1_i64, plan_elements, plan_bytes),
      fixture.limits(plan_nodes, plan_elements - 1_i64, plan_bytes),
      fixture.limits(plan_nodes, plan_elements, plan_bytes - 1_i64),
    ].each do |short_limits|
      short_budget = CrystalClick::BinaryCodecBudget.new(short_limits, true)
      refused_plan = nil.as(CrystalClick::CompactJsonCallbackPlan?)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        refused_plan = CrystalClick::CompactJsonCallbackPlan.new(input, short_limits, short_budget)
      end
      refused_plan.should be_nil
    end
    fixture.snapshot(input).should eq(before)
    roomy_plan.same_input?(input).should be_true
  end

  it "admits the measured encoder budget exactly and refuses one node short without publishing" do
    fixture = CompactRecursiveDynamicW284WriterAdversaryFixture
    input = fixture.input(include_dynamic_value: true)
    before = fixture.snapshot(input)
    roomy_limits = CrystalClick::BinaryCodecLimits.default
    roomy_budget = CrystalClick::BinaryCodecBudget.new(roomy_limits, true)
    roomy_plan = CrystalClick::CompactJsonCallbackPlan.new(input, roomy_limits, roomy_budget)
    plan_nodes = roomy_budget.node_count
    plan_elements = roomy_budget.element_count
    plan_bytes = roomy_budget.wire_byte_count
    _roomy_encoded = CrystalClick::CompactJsonEncodedColumn.encode(roomy_plan, roomy_budget)
    total_nodes = roomy_budget.node_count
    total_elements = roomy_budget.element_count
    total_bytes = roomy_budget.wire_byte_count
    total_nodes.should be > plan_nodes
    total_elements.should be > plan_elements
    total_bytes.should be > plan_bytes

    exact_limits = fixture.limits(total_nodes, total_elements, total_bytes)
    exact_budget = CrystalClick::BinaryCodecBudget.new(exact_limits, true)
    exact_plan = CrystalClick::CompactJsonCallbackPlan.new(input, exact_limits, exact_budget)
    exact_encoded = CrystalClick::CompactJsonEncodedColumn.encode(exact_plan, exact_budget)
    exact_plan.same_input?(input).should be_true
    exact_encoded.callback_event_count.should be > 0
    exact_budget.node_count.should eq(total_nodes)
    exact_budget.element_count.should eq(total_elements)
    exact_budget.wire_byte_count.should eq(total_bytes)

    [
      fixture.limits(total_nodes - 1_i64, total_elements, total_bytes),
      fixture.limits(total_nodes, total_elements - 1_i64, total_bytes),
      fixture.limits(total_nodes, total_elements, total_bytes - 1_i64),
    ].each do |short_limits|
      short_budget = CrystalClick::BinaryCodecBudget.new(short_limits, true)
      short_plan = CrystalClick::CompactJsonCallbackPlan.new(input, short_limits, short_budget)
      refused_encoded = nil.as(CrystalClick::CompactJsonEncodedColumn?)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        refused_encoded = CrystalClick::CompactJsonEncodedColumn.encode(short_plan, short_budget)
      end
      refused_encoded.should be_nil
      short_plan.same_input?(input).should be_true
    end
    fixture.snapshot(input).should eq(before)

    # Independently isolate the recursive-only Dynamic callback wrapper charge
    # from the shared Dynamic plan charges. This W257 fixture has one Dynamic
    # site, three data roles (discriminator plus shared String and UInt64 arms),
    # one state prefix, and therefore five closed callbacks.
    wrapper_budget = CrystalClick::BinaryCodecBudget.new(roomy_limits, true)
    wrapper_schema = CrystalClick::CompactRecursiveJsonSchemaPlan.new(
      fixture.schema,
      input.name,
      roomy_limits,
      wrapper_budget,
      input.profile,
    )
    schema_nodes = wrapper_budget.node_count.to_u64
    schema_elements = wrapper_budget.element_count.to_u64
    schema_bytes = wrapper_budget.wire_byte_count.to_u64
    dynamic_site = wrapper_schema.dynamic_bulk_site(
      CompactRecursiveDynamicW284WriterAdversaryFixture::DYNAMIC_SITE,
    )
    dynamic_context = input.recursive_dynamic_context.site_context_for(
      CompactRecursiveDynamicW284WriterAdversaryFixture::DYNAMIC_SITE,
    )
    wrapped_plan = CrystalClick::CompactDynamicCallbackPlan.for_recursive_json_site(
      dynamic_site,
      input.name,
      dynamic_context,
      input.profile,
      roomy_limits,
      wrapper_budget,
      CrystalClick::CompactVariantDiscriminatorMode::Compact,
    )
    dynamic_plan = wrapped_plan.dynamic_plan
    site_count = dynamic_plan.site_count.to_u64
    role_count = dynamic_plan.role_count
    prefix_count = 0_u64
    data_name_bytes = 0_u64
    role_bytes = 0_u64
    prefix_base_name_bytes = 0_u64
    prefix_role_bytes = 0_u64
    dynamic_plan.each_data_role do |role|
      data_name_bytes += wrapped_plan.physical_plan.stream_name_byte_size_for(role)
      role_bytes += role.bytesize.to_u64
      if wrapped_plan.physical_plan.prefix_size_for(role) > 0
        prefix_count += 1_u64
        prefix_base_name_bytes += wrapped_plan.physical_plan.stream_name_byte_size_for(role)
        prefix_role_bytes += role.bytesize.to_u64
      end
    end
    structure_name_bytes = 0_u64
    wrapped_plan.physical_plan.each_structure_name_byte_size do |name_bytes|
      structure_name_bytes += name_bytes
    end
    site_path_bytes = 0_u64
    dynamic_plan.each_site_path do |site_path|
      site_path_bytes += site_path.bytesize.to_u64
    end
    callback_count = site_count + role_count + prefix_count
    wrapped_plan.callback_event_count.to_u64.should eq(callback_count)
    {site_count, role_count, prefix_count, callback_count}.should eq({1_u64, 3_u64, 1_u64, 5_u64})

    string_copies = 5_u64 * callback_count + 2_u64 * site_count +
                    4_u64 * prefix_count + 2_u64 * role_count
    expected_callback_wrapper_nodes = 14_u64 + callback_count + string_copies
    expected_callback_wrapper_elements = 8_u64 * callback_count + 2_u64 * site_count +
                                         3_u64 * prefix_count + 2_u64 * role_count
    prefix_suffix_bytes = prefix_count * "_prefix".bytesize.to_u64
    callback_name_bytes = structure_name_bytes + data_name_bytes +
                          prefix_base_name_bytes + prefix_suffix_bytes
    callback_role_bytes = site_path_bytes + role_bytes + prefix_role_bytes
    callback_pair_bytes = callback_name_bytes + callback_role_bytes
    expected_wrapper_bytes = callback_name_bytes + prefix_base_name_bytes +
                             structure_name_bytes + site_path_bytes +
                             2_u64 * prefix_base_name_bytes + prefix_suffix_bytes + prefix_role_bytes +
                             data_name_bytes + role_bytes + 2_u64 * callback_pair_bytes + string_copies
    expected_callback_wrapper_elements += expected_wrapper_bytes

    # This lower bound is derived from the known callback names/roles and the
    # two retained name/role copies per callback (final map and event), not from
    # BinaryCodecBudget's measured counters or the preflight's formula.
    independent_wrapper_lower_bound = callback_name_bytes + 2_u64 * callback_pair_bytes

    standalone_budget = CrystalClick::BinaryCodecBudget.new(roomy_limits, true)
    standalone_input = CrystalClick::CompactDynamicColumnInput.new(
      input.name,
      dynamic_site.type,
      [] of Array(CrystalClick::BinaryValue),
      dynamic_context,
      input.profile,
    )
    _standalone_plan = CrystalClick::CompactDynamicCallbackPlan.new(
      standalone_input,
      roomy_limits,
      standalone_budget,
    )
    # Recursive binding additionally budgets its detached adapter map; the
    # callback-wrapper delta is checked independently after removing it.
    adapter_nodes = dynamic_context.site_count.to_u64 + 1_u64
    adapter_elements = dynamic_context.site_count.to_u64
    recursive_delta_nodes = wrapper_budget.node_count.to_u64 - schema_nodes - standalone_budget.node_count.to_u64
    recursive_delta_elements = wrapper_budget.element_count.to_u64 - schema_elements - standalone_budget.element_count.to_u64
    (recursive_delta_nodes - adapter_nodes).should eq(expected_callback_wrapper_nodes)
    (recursive_delta_elements - adapter_elements).should be >= independent_wrapper_lower_bound
    (recursive_delta_elements - adapter_elements).should eq(expected_callback_wrapper_elements)
    (wrapper_budget.wire_byte_count.to_u64 - schema_bytes - standalone_budget.wire_byte_count.to_u64).should eq(0_u64)

    exact_wrapper_limits = fixture.limits(
      (schema_nodes + standalone_budget.node_count.to_u64 + adapter_nodes + expected_callback_wrapper_nodes).to_i64,
      (schema_elements + standalone_budget.element_count.to_u64 + adapter_elements + expected_callback_wrapper_elements).to_i64,
      (schema_bytes + standalone_budget.wire_byte_count.to_u64).to_i64,
    )
    exact_wrapper_budget = CrystalClick::BinaryCodecBudget.new(exact_wrapper_limits, true)
    exact_wrapper_schema = CrystalClick::CompactRecursiveJsonSchemaPlan.new(
      fixture.schema,
      input.name,
      exact_wrapper_limits,
      exact_wrapper_budget,
      input.profile,
    )
    exact_wrapper_site = exact_wrapper_schema.dynamic_bulk_site(
      CompactRecursiveDynamicW284WriterAdversaryFixture::DYNAMIC_SITE,
    )
    _exact_wrapper_plan = CrystalClick::CompactDynamicCallbackPlan.for_recursive_json_site(
      exact_wrapper_site,
      input.name,
      dynamic_context,
      input.profile,
      exact_wrapper_limits,
      exact_wrapper_budget,
      CrystalClick::CompactVariantDiscriminatorMode::Compact,
    )
    exact_wrapper_budget.node_count.to_i64.should eq(exact_wrapper_limits.max_nodes)
    exact_wrapper_budget.element_count.to_i64.should eq(exact_wrapper_limits.max_elements)
    exact_wrapper_budget.wire_byte_count.to_i64.should eq(exact_wrapper_limits.max_bytes)

    [
      fixture.limits(exact_wrapper_limits.max_nodes - 1_i64, exact_wrapper_limits.max_elements, exact_wrapper_limits.max_bytes),
      fixture.limits(exact_wrapper_limits.max_nodes, exact_wrapper_limits.max_elements - 1_i64, exact_wrapper_limits.max_bytes),
    ].each do |short_limits|
      short_budget = CrystalClick::BinaryCodecBudget.new(short_limits, true)
      short_schema = CrystalClick::CompactRecursiveJsonSchemaPlan.new(
        fixture.schema,
        input.name,
        short_limits,
        short_budget,
        input.profile,
      )
      short_site = short_schema.dynamic_bulk_site(
        CompactRecursiveDynamicW284WriterAdversaryFixture::DYNAMIC_SITE,
      )
      refused_wrapper = nil.as(CrystalClick::CompactDynamicCallbackPlan?)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        refused_wrapper = CrystalClick::CompactDynamicCallbackPlan.for_recursive_json_site(
          short_site,
          input.name,
          dynamic_context,
          input.profile,
          short_limits,
          short_budget,
          CrystalClick::CompactVariantDiscriminatorMode::Compact,
        )
      end
      refused_wrapper.should be_nil
    end
  end

  it "binds each Dynamic subplan to the exact roster and full statistics" do
    fixture = CompactRecursiveDynamicW284WriterAdversaryFixture
    input = fixture.input
    limits = CrystalClick::BinaryCodecLimits.default
    budget = CrystalClick::BinaryCodecBudget.new(limits, true)
    plan = CrystalClick::CompactJsonCallbackPlan.new(input, limits, budget)
    dynamic_plan = plan.dynamic_site_plan_for(CompactRecursiveDynamicW284WriterAdversaryFixture::DYNAMIC_SITE)

    bound_context = input.recursive_dynamic_context.site_context_for(
      CompactRecursiveDynamicW284WriterAdversaryFixture::DYNAMIC_SITE,
    )
    dynamic_plan.same_context?(bound_context).should be_true
    dynamic_plan.same_context?(fixture.dynamic_context_for(CrystalClick::BinaryDataType.primitive("UInt8"))).should be_false
    dynamic_plan.same_context?(fixture.dynamic_context_for(
      CrystalClick::BinaryDataType.primitive("UInt64"),
      2_u64,
    )).should be_false
  end

  it "rejects actual JSON and nested Dynamic arms before callback delegation" do
    fixture = CompactRecursiveDynamicW284WriterAdversaryFixture
    limits = CrystalClick::BinaryCodecLimits.default
    json_arm = CrystalClick::BinaryDataType.json(max_dynamic_paths: 0, max_dynamic_types: 0)
    json_input = fixture.input(fixture.dynamic_context_for(json_arm))
    json_budget = CrystalClick::BinaryCodecBudget.new(limits, true)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::CompactJsonCallbackPlan.new(json_input, limits, json_budget)
    end

    nested_dynamic = CrystalClick::BinaryDataType.array(
      CrystalClick::BinaryDataType.dynamic(max_types: 1),
    )
    nested_dynamic_inner = fixture.dynamic_context_for(CrystalClick::BinaryDataType.primitive("UInt64"))
    nested_dynamic_context = fixture.dynamic_context_for(
      nested_dynamic,
      1_u64,
      {"root.elements" => nested_dynamic_inner.structure_at?("root").not_nil!} of String => CrystalClick::DynamicStructure,
    )
    nested_dynamic_input = fixture.input(nested_dynamic_context)
    nested_dynamic_budget = CrystalClick::BinaryCodecBudget.new(limits, true)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::CompactJsonCallbackPlan.new(nested_dynamic_input, limits, nested_dynamic_budget)
    end
  end

  it "applies inherited Dynamic-site depth to each actual static Bulk arm" do
    fixture = CompactRecursiveDynamicW284WriterAdversaryFixture
    limits = CrystalClick::BinaryCodecLimits.new(5, 10_000, 100_000, 1_000_000)
    actual_type = CrystalClick::BinaryDataType.array(
      CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.primitive("UInt8")),
    )
    CrystalClick::CompactRecursiveJsonStaticBulkGrammar.admitted_type?(actual_type, 1, limits).should be_true
    CrystalClick::CompactRecursiveJsonStaticBulkGrammar.admitted_type?(actual_type, 4, limits).should be_false

    input = fixture.input(fixture.dynamic_context_for(actual_type))
    budget = CrystalClick::BinaryCodecBudget.new(limits, true)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::CompactJsonCallbackPlan.new(input, limits, budget)
    end
  end
end
