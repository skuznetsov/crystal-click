require "./spec_helper"

private def w208_json_type : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.json(
    max_dynamic_paths: 1,
    max_dynamic_types: 1,
    typed_paths: w208_typed_paths,
  )
end

private def w208_typed_paths : Hash(String, CrystalClick::BinaryDataType)
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  string = CrystalClick::BinaryDataType.primitive("String")
  nullable = CrystalClick::BinaryDataType.nullable(uint8)
  {
    "id"    => uint8,
    "label" => string,
    "maybe" => nullable,
  } of String => CrystalClick::BinaryDataType
end

private def w208_plan(
  json_type : CrystalClick::BinaryDataType,
  dynamic_paths : Array(String),
  dynamic_actuals : Array(CrystalClick::BinaryDataType),
  typed_paths : Hash(String, CrystalClick::BinaryDataType)? = nil,
) : CrystalClick::ObjectDocumentPlan
  dynamics = Hash(String, CrystalClick::DynamicStructure).new
  dynamic_paths.each do |path|
    dynamics[path] = CrystalClick::DynamicStructure.new(dynamic_actuals)
  end
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new(dynamic_paths),
    dynamics,
  )
  CrystalClick::ObjectDocumentPlan.new(
    structures,
    typed_paths || json_type.json_type.not_nil!.typed_paths,
  )
end

private def w208_limits(
  max_depth : Int = 64,
  max_nodes : Int = 4_096,
  max_elements : Int = 1_000_000,
  max_bytes : Int = 64 * 1024 * 1024,
) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: max_depth,
    max_nodes: max_nodes,
    max_elements: max_elements,
    max_bytes: max_bytes,
  )
end

private def w208_nullable(type : CrystalClick::BinaryDataType) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.null(type)
end

describe "W208 Dynamic JSON Object logical binding" do
  it "binds an unused direct JSON arm by canonical index, site, and roster rather than statistics" do
    json = w208_json_type
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    zero_stats = CrystalClick::StructureStatistics.new(
      [0_u64, 0_u64, 0_u64] of UInt64,
      [] of CrystalClick::StructureStatistic,
    )
    structure = CrystalClick::DynamicStructure.new([uint8, json] of CrystalClick::BinaryDataType, zero_stats)
    plan = w208_plan(json, ["counter"] of String, [uint64] of CrystalClick::BinaryDataType)
    budget = CrystalClick::BinaryCodecBudget.new(w208_limits, true)

    # The JSON descriptor is actual roster position 1 but canonical arm 0.
    {structure.type_at(1), structure.canonical_index_for(json)}.should eq({json, 0})
    binding = CrystalClick::DynamicJsonObjectBinding.new(
      "root/tuple[0]",
      structure,
      0,
      plan,
      budget,
      depth: 1,
    )

    # Statistics are data-dependent counters, not part of the site/arm identity.
    changed_stats = CrystalClick::StructureStatistics.new(
      [7_u64, 0_u64, 0_u64] of UInt64,
      [] of CrystalClick::StructureStatistic,
    )
    same_roster = CrystalClick::DynamicStructure.new([uint8, json] of CrystalClick::BinaryDataType, changed_stats)
    binding.validate_for!("root/tuple[0]", same_roster, 0, budget, depth: 1)
    reordered_roster = CrystalClick::DynamicStructure.new([json, uint8] of CrystalClick::BinaryDataType, changed_stats)
    binding.validate_for!("root/tuple[0]", reordered_roster, 0, budget, depth: 1)

    expect_raises(ArgumentError) do
      binding.validate_for!("root/tuple[1]", structure, 0, budget, depth: 1)
    end
    expect_raises(ArgumentError) do
      binding.validate_for!("root/tuple[0]", structure, structure.canonical_index_for(uint8), budget, depth: 1)
    end
    expect_raises(ArgumentError) do
      binding.validate_for!("root/tuple[0]", structure, structure.shared_index, budget, depth: 1)
    end

    changed_json = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 1,
      max_dynamic_types: 0,
      typed_paths: w208_typed_paths,
    )
    changed_roster = CrystalClick::DynamicStructure.new([uint8, changed_json] of CrystalClick::BinaryDataType)
    expect_raises(ArgumentError) do
      binding.validate_for!("root/tuple[0]", changed_roster, 0, budget, depth: 1)
    end
  end

  it "derives the Object schema from exact JSON caps and typed paths and rejects mismatched plans" do
    json = w208_json_type
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    plan = w208_plan(json, ["counter"] of String, [uint64] of CrystalClick::BinaryDataType)
    structure = CrystalClick::DynamicStructure.new(
      [CrystalClick::BinaryDataType.primitive("UInt8"), json] of CrystalClick::BinaryDataType
    )
    budget = CrystalClick::BinaryCodecBudget.new(w208_limits, true)
    CrystalClick::DynamicJsonObjectBinding.new("root", structure, 0, plan, budget, depth: 1).should_not be_nil

    wrong_typed = w208_typed_paths
    wrong_typed["id"] = CrystalClick::BinaryDataType.primitive("UInt16")
    wrong_typed_plan = w208_plan(json, ["counter"] of String, [uint64] of CrystalClick::BinaryDataType, wrong_typed)
    expect_raises(ArgumentError) do
      CrystalClick::DynamicJsonObjectBinding.new("root", structure, 0, wrong_typed_plan, budget, depth: 1)
    end

    too_many_paths = w208_plan(
      json,
      ["counter", "other"] of String,
      [uint64] of CrystalClick::BinaryDataType,
    )
    expect_raises(ArgumentError) do
      CrystalClick::DynamicJsonObjectBinding.new("root", structure, 0, too_many_paths, budget, depth: 1)
    end

    too_many_types = w208_plan(
      json,
      ["counter"] of String,
      [uint64, CrystalClick::BinaryDataType.primitive("String")] of CrystalClick::BinaryDataType,
    )
    expect_raises(ArgumentError) do
      CrystalClick::DynamicJsonObjectBinding.new("root", structure, 0, too_many_types, budget, depth: 1)
    end

    dotted = w208_plan(json, ["counter.value"] of String, [uint64] of CrystalClick::BinaryDataType)
    dotted_budget = CrystalClick::BinaryCodecBudget.new(w208_limits, true)
    dotted_binding = CrystalClick::DynamicJsonObjectBinding.new(
      "root",
      structure,
      0,
      dotted,
      dotted_budget,
      depth: 1,
    )
    dotted_binding.should_not be_nil
  end

  it "bridges borrowed typed NULL and scalar children through the existing Object codec" do
    bound_type = w208_json_type
    row_type = w208_json_type
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    nullable = w208_typed_paths["maybe"]
    plan = w208_plan(bound_type, ["counter"] of String, [uint64] of CrystalClick::BinaryDataType)
    structure = CrystalClick::DynamicStructure.new([uint8, bound_type] of CrystalClick::BinaryDataType)
    write_budget = CrystalClick::BinaryCodecBudget.new(w208_limits, true)
    binding = CrystalClick::DynamicJsonObjectBinding.new("root", structure, 0, plan, write_budget, depth: 1)

    id = CrystalClick::BinaryValue.fixed(uint8, Bytes[7_u8])
    label = CrystalClick::BinaryValue.string("blue")
    nullable_null = w208_nullable(nullable)
    counter = CrystalClick::BinaryValue.uint64(91_u64)
    discarded_null = CrystalClick::BinaryValue.null
    full_row = CrystalClick::BinaryJsonRow.new(
      row_type,
      [
        {"id", id},
        {"label", label},
        {"maybe", nullable_null},
        {"counter", counter},
        {"scratch", discarded_null},
      ] of Tuple(String, CrystalClick::BinaryValue),
      write_budget,
      depth: 1,
    )
    row_type.should eq(bound_type)
    row_type.same?(bound_type).should be_false
    full_row.value_for("scratch").should be_nil

    expect_raises(ArgumentError) do
      CrystalClick::BinaryJsonRow.new(
        row_type,
        [
          {"id", id},
          {"label", label},
        ] of Tuple(String, CrystalClick::BinaryValue),
        write_budget,
        depth: 1,
      )
    end

    full_document = CrystalClick::BinaryJsonObjectAdapter.to_document(full_row, binding, write_budget, depth: 1)
    full_document.value_for("id").same?(id).should be_true
    full_document.value_for("label").same?(label).should be_true
    full_document.value_for("maybe").same?(nullable_null).should be_true
    full_document.value_for("counter").same?(counter).should be_true
    full_document.has_path?("scratch").should be_false

    changed_row_type = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 1,
      typed_paths: w208_typed_paths,
    )
    changed_row = CrystalClick::BinaryJsonRow.new(
      changed_row_type,
      [
        {"id", id},
        {"label", label},
        {"maybe", nullable_null},
      ] of Tuple(String, CrystalClick::BinaryValue),
      write_budget,
      depth: 1,
    )
    expect_raises(ArgumentError) do
      CrystalClick::BinaryJsonObjectAdapter.to_document(changed_row, binding, write_budget, depth: 1)
    end
    read_mismatch_budget = CrystalClick::BinaryCodecBudget.new(w208_limits)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryJsonObjectAdapter.to_document(changed_row, binding, read_mismatch_budget, depth: 1)
    end

    sparse_row = CrystalClick::BinaryJsonRow.new(
      row_type,
      [
        {"id", CrystalClick::BinaryValue.fixed(uint8, Bytes[8_u8])},
        {"label", CrystalClick::BinaryValue.string("red")},
        {"maybe", w208_nullable(nullable)},
      ] of Tuple(String, CrystalClick::BinaryValue),
      write_budget,
      depth: 1,
    )
    sparse_document = CrystalClick::BinaryJsonObjectAdapter.to_document(sparse_row, binding, write_budget, depth: 1)

    streams = CrystalClick::ObjectDocumentCodec.encode_with_budget(
      plan,
      [[full_document, sparse_document] of CrystalClick::ObjectDocument],
      write_budget,
    )
    read_budget = CrystalClick::BinaryCodecBudget.new(w208_limits)
    decoded = CrystalClick::ObjectDocumentCodec.decode_with_budget(
      w208_typed_paths,
      streams,
      read_budget,
    )
    decoded.size.should eq(1)
    decoded[0].size.should eq(2)
    decoded[0][0].value_for("id").byte_at(0).should eq(7_u8)
    decoded[0][0].value_for("label").as_string.should eq("blue")
    decoded[0][0].value_for("maybe").is_null?.should be_true
    decoded[0][0].value_for("counter").as_uint64.should eq(91_u64)
    decoded[0][1].value_for("id").byte_at(0).should eq(8_u8)
    decoded[0][1].has_path?("counter").should be_false

    restored = decoded[0].map do |document|
      CrystalClick::BinaryJsonObjectAdapter.to_json_row(document, binding, read_budget, depth: 1)
    end
    restored[0].value_for("label").not_nil!.as_string.should eq("blue")
    restored[0].value_for("counter").not_nil!.as_uint64.should eq(91_u64)
    restored[0].value_for("maybe").not_nil!.type.should eq(nullable)
    restored[0].value_for("maybe").not_nil!.is_null?.should be_true
    restored[1].value_for("counter").should be_nil
    restored[0].value_for("label").not_nil!.same?(decoded[0][0].value_for("label")).should be_true
  end

  it "charges the caller's BinaryJsonRow budget across siblings and carries inherited depth in both directions" do
    type = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
      typed_paths: {"id" => CrystalClick::BinaryDataType.primitive("UInt8")} of String => CrystalClick::BinaryDataType,
    )
    values = [{"id", CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[1_u8])}] of Tuple(String, CrystalClick::BinaryValue)

    measured = CrystalClick::BinaryCodecBudget.new(w208_limits, true)
    CrystalClick::BinaryJsonRow.new(type, values, measured, depth: 1)
    exact_limits = w208_limits(
      max_nodes: measured.node_count,
      max_elements: measured.element_count,
      max_bytes: measured.wire_byte_count,
    )
    exact = CrystalClick::BinaryCodecBudget.new(exact_limits, true)
    CrystalClick::BinaryJsonRow.new(type, values, exact, depth: 1).type.should eq(type)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryJsonRow.new(type, values, exact, depth: 1)
    end

    read_budget = CrystalClick::BinaryCodecBudget.new(exact_limits)
    CrystalClick::BinaryJsonRow.new(type, values, read_budget, depth: 1).type.should eq(type)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryJsonRow.new(type, values, read_budget, depth: 1)
    end

    deep_limits = w208_limits(max_depth: 64)
    deep_budget = CrystalClick::BinaryCodecBudget.new(deep_limits, true)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryJsonRow.new(type, values, deep_budget, depth: 64)
    end
  end

  it "charges equal typed value descriptors only when their owner roots are distinct" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    nullable = CrystalClick::BinaryDataType.nullable(uint8)
    declared_array = CrystalClick::BinaryDataType.array(nullable)
    json = CrystalClick::BinaryDataType.json(
      typed_paths: {
        "left"  => declared_array,
        "right" => declared_array,
      } of String => CrystalClick::BinaryDataType,
    )
    entries_for = ->(value_type : CrystalClick::BinaryDataType) do
      [
        {"left", CrystalClick::BinaryValue.array(value_type, [] of CrystalClick::BinaryValue)},
        {"right", CrystalClick::BinaryValue.array(value_type, [] of CrystalClick::BinaryValue)},
      ] of Tuple(String, CrystalClick::BinaryValue)
    end

    shared = CrystalClick::BinaryCodecBudget.new(w208_limits(max_depth: 4), true)
    shared_row = CrystalClick::BinaryJsonRow.new(json, entries_for.call(declared_array), shared, depth: 1)
    shared.node_count.should eq(14_i64)    # JSON type 9 + row/value owners 5
    shared.element_count.should eq(12_i64) # JSON descriptor 8 + row edges 4
    shared_row.path_count.should eq(2)

    distinct_value_type = CrystalClick::BinaryDataType.array(nullable)
    distinct_value_type.should eq(declared_array)
    distinct_value_type.same?(declared_array).should be_false
    distinct = CrystalClick::BinaryCodecBudget.new(w208_limits(max_depth: 4), true)
    distinct_row = CrystalClick::BinaryJsonRow.new(json, entries_for.call(distinct_value_type), distinct, depth: 1)
    distinct.node_count.should eq(20_i64)    # shared 14 + two 3-node descriptor traversals
    distinct.element_count.should eq(16_i64) # shared 12 + two 2-edge descriptor traversals
    distinct_row.path_count.should eq(2)

    exact_write = CrystalClick::BinaryCodecBudget.new(
      w208_limits(max_depth: 4, max_nodes: 20, max_elements: 16), true,
    )
    CrystalClick::BinaryJsonRow.new(json, entries_for.call(distinct_value_type), exact_write, depth: 1).path_count.should eq(2)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryJsonRow.new(
        json,
        entries_for.call(distinct_value_type),
        CrystalClick::BinaryCodecBudget.new(w208_limits(max_depth: 4, max_nodes: 19, max_elements: 16), true),
        depth: 1,
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryJsonRow.new(
        json,
        entries_for.call(distinct_value_type),
        CrystalClick::BinaryCodecBudget.new(w208_limits(max_depth: 4, max_nodes: 20, max_elements: 15), true),
        depth: 1,
      )
    end

    exact_read = CrystalClick::BinaryCodecBudget.new(
      w208_limits(max_depth: 4, max_nodes: 20, max_elements: 16),
    )
    CrystalClick::BinaryJsonRow.new(json, entries_for.call(distinct_value_type), exact_read, depth: 1).path_count.should eq(2)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryJsonRow.new(
        json,
        entries_for.call(distinct_value_type),
        CrystalClick::BinaryCodecBudget.new(w208_limits(max_depth: 4, max_nodes: 19, max_elements: 16)),
        depth: 1,
      )
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryJsonRow.new(
        json,
        entries_for.call(distinct_value_type),
        CrystalClick::BinaryCodecBudget.new(w208_limits(max_depth: 4, max_nodes: 20, max_elements: 15)),
        depth: 1,
      )
    end
  end

  it "charges schema owners with the supplied budget and classifies invalid Object paths on read" do
    typed = {"id" => CrystalClick::BinaryDataType.primitive("UInt8")} of String => CrystalClick::BinaryDataType
    measured = CrystalClick::BinaryCodecBudget.new(w208_limits, true)
    CrystalClick::ObjectDocumentSchema.new(typed, 1, 1, measured, depth: 1)
    exact_limits = w208_limits(
      max_nodes: measured.node_count,
      max_elements: measured.element_count,
      max_bytes: measured.wire_byte_count,
    )
    exact = CrystalClick::BinaryCodecBudget.new(exact_limits, true)
    CrystalClick::ObjectDocumentSchema.new(typed, 1, 1, exact, depth: 1).should_not be_nil
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentSchema.new(typed, 1, 1, exact, depth: 1)
    end

    deep = CrystalClick::BinaryCodecBudget.new(w208_limits(max_depth: 64), true)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentSchema.new(typed, 1, 1, deep, depth: 64)
    end

    json = w208_json_type
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    plan = w208_plan(json, ["counter"] of String, [uint64] of CrystalClick::BinaryDataType)
    structure = CrystalClick::DynamicStructure.new([CrystalClick::BinaryDataType.primitive("UInt8"), json] of CrystalClick::BinaryDataType)
    binding_budget = CrystalClick::BinaryCodecBudget.new(w208_limits)
    binding = CrystalClick::DynamicJsonObjectBinding.new("root", structure, 0, plan, binding_budget, depth: 1)
    wrong_path = CrystalClick::ObjectDocument.new({
      "id"        => CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[1_u8]),
      "label"     => CrystalClick::BinaryValue.string("x"),
      "maybe"     => CrystalClick::BinaryValue.null(w208_typed_paths["maybe"]),
      ("x" * 257) => CrystalClick::BinaryValue.uint64(2_u64),
    } of String => CrystalClick::BinaryValue)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryJsonObjectAdapter.to_json_row(wrong_path, binding, binding_budget, depth: 1)
    end
    write_invalid_path_budget = CrystalClick::BinaryCodecBudget.new(w208_limits, true)
    expect_raises(ArgumentError) do
      CrystalClick::BinaryJsonObjectAdapter.to_json_row(wrong_path, binding, write_invalid_path_budget, depth: 1)
    end

    missing_typed = CrystalClick::ObjectDocument.new({
      "id"    => CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[1_u8]),
      "label" => CrystalClick::BinaryValue.string("x"),
    } of String => CrystalClick::BinaryValue)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryJsonObjectAdapter.to_json_row(missing_typed, binding, binding_budget, depth: 1)
    end

    wrong_typed_value = CrystalClick::ObjectDocument.new({
      "id"    => CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("UInt16"), Bytes[1_u8, 0_u8]),
      "label" => CrystalClick::BinaryValue.string("x"),
      "maybe" => CrystalClick::BinaryValue.null(w208_typed_paths["maybe"]),
    } of String => CrystalClick::BinaryValue)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryJsonObjectAdapter.to_json_row(wrong_typed_value, binding, binding_budget, depth: 1)
    end
  end

  it "charges each adapter direction cumulatively and preserves inherited depth" do
    json = CrystalClick::BinaryDataType.json(max_dynamic_paths: 1, max_dynamic_types: 1)
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    structure = CrystalClick::DynamicStructure.new([json] of CrystalClick::BinaryDataType)
    plan = w208_plan(json, ["counter"] of String, [uint64] of CrystalClick::BinaryDataType)
    first_row = CrystalClick::BinaryJsonRow.new(
      json,
      [{"counter", CrystalClick::BinaryValue.uint64(1_u64)}] of Tuple(String, CrystalClick::BinaryValue),
    )
    second_row = CrystalClick::BinaryJsonRow.new(
      json,
      [{"counter", CrystalClick::BinaryValue.uint64(2_u64)}] of Tuple(String, CrystalClick::BinaryValue),
    )

    write_measure = CrystalClick::BinaryCodecBudget.new(w208_limits, true)
    write_binding = CrystalClick::DynamicJsonObjectBinding.new("root", structure, 0, plan, write_measure, depth: 1)
    first_document = CrystalClick::BinaryJsonObjectAdapter.to_document(first_row, write_binding, write_measure, depth: 1)
    second_document = CrystalClick::BinaryJsonObjectAdapter.to_document(second_row, write_binding, write_measure, depth: 1)
    write_limits = w208_limits(
      max_depth: write_measure.limits.max_depth,
      max_nodes: write_measure.node_count.to_i,
      max_elements: write_measure.element_count.to_i,
      max_bytes: write_measure.wire_byte_count.to_i,
    )
    exact_write = CrystalClick::BinaryCodecBudget.new(write_limits, true)
    exact_write_binding = CrystalClick::DynamicJsonObjectBinding.new("root", structure, 0, plan, exact_write, depth: 1)
    CrystalClick::BinaryJsonObjectAdapter.to_document(first_row, exact_write_binding, exact_write, depth: 1)
    CrystalClick::BinaryJsonObjectAdapter.to_document(second_row, exact_write_binding, exact_write, depth: 1)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryJsonObjectAdapter.to_document(first_row, exact_write_binding, exact_write, depth: 1)
    end

    [
      w208_limits(max_nodes: (write_measure.node_count - 1).to_i),
      w208_limits(max_elements: (write_measure.element_count - 1).to_i),
      w208_limits(max_bytes: (write_measure.wire_byte_count - 1).to_i),
    ].each do |one_short|
      constrained = CrystalClick::BinaryCodecBudget.new(one_short, true)
      constrained_binding = CrystalClick::DynamicJsonObjectBinding.new("root", structure, 0, plan, constrained, depth: 1)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryJsonObjectAdapter.to_document(first_row, constrained_binding, constrained, depth: 1)
        CrystalClick::BinaryJsonObjectAdapter.to_document(second_row, constrained_binding, constrained, depth: 1)
      end
    end

    read_measure = CrystalClick::BinaryCodecBudget.new(w208_limits)
    read_binding = CrystalClick::DynamicJsonObjectBinding.new("root", structure, 0, plan, read_measure, depth: 1)
    CrystalClick::BinaryJsonObjectAdapter.to_json_row(first_document, read_binding, read_measure, depth: 1)
    CrystalClick::BinaryJsonObjectAdapter.to_json_row(second_document, read_binding, read_measure, depth: 1)
    read_limits = w208_limits(
      max_nodes: read_measure.node_count.to_i,
      max_elements: read_measure.element_count.to_i,
      max_bytes: read_measure.wire_byte_count.to_i,
    )
    exact_read = CrystalClick::BinaryCodecBudget.new(read_limits)
    exact_read_binding = CrystalClick::DynamicJsonObjectBinding.new("root", structure, 0, plan, exact_read, depth: 1)
    CrystalClick::BinaryJsonObjectAdapter.to_json_row(first_document, exact_read_binding, exact_read, depth: 1)
    CrystalClick::BinaryJsonObjectAdapter.to_json_row(second_document, exact_read_binding, exact_read, depth: 1)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryJsonObjectAdapter.to_json_row(first_document, exact_read_binding, exact_read, depth: 1)
    end

    [
      w208_limits(max_nodes: (read_measure.node_count - 1).to_i),
      w208_limits(max_elements: (read_measure.element_count - 1).to_i),
      w208_limits(max_bytes: (read_measure.wire_byte_count - 1).to_i),
    ].each do |one_short|
      constrained = CrystalClick::BinaryCodecBudget.new(one_short)
      constrained_binding = CrystalClick::DynamicJsonObjectBinding.new("root", structure, 0, plan, constrained, depth: 1)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryJsonObjectAdapter.to_json_row(first_document, constrained_binding, constrained, depth: 1)
        CrystalClick::BinaryJsonObjectAdapter.to_json_row(second_document, constrained_binding, constrained, depth: 1)
      end
    end

    shallow_write = CrystalClick::BinaryCodecBudget.new(w208_limits(max_depth: 64), true)
    shallow_binding = CrystalClick::DynamicJsonObjectBinding.new("root", structure, 0, plan, shallow_write, depth: 1)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryJsonObjectAdapter.to_document(first_row, shallow_binding, shallow_write, depth: 64)
    end
    shallow_read = CrystalClick::BinaryCodecBudget.new(w208_limits(max_depth: 64))
    shallow_read_binding = CrystalClick::DynamicJsonObjectBinding.new("root", structure, 0, plan, shallow_read, depth: 1)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryJsonObjectAdapter.to_json_row(first_document, shallow_read_binding, shallow_read, depth: 64)
    end
  end

  it "charges both logical owners with the literal one-path accounting law" do
    json = CrystalClick::BinaryDataType.json(max_dynamic_paths: 1, max_dynamic_types: 1)
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    structure = CrystalClick::DynamicStructure.new([json] of CrystalClick::BinaryDataType)
    plan = w208_plan(json, ["counter"] of String, [uint64] of CrystalClick::BinaryDataType)
    setup_budget = CrystalClick::BinaryCodecBudget.new(w208_limits, true)
    binding = CrystalClick::DynamicJsonObjectBinding.new("root", structure, 0, plan, setup_budget, depth: 1)

    row = CrystalClick::BinaryJsonRow.new(
      json,
      [{"counter", CrystalClick::BinaryValue.uint64(1_u64)}] of Tuple(String, CrystalClick::BinaryValue),
    )
    forward = CrystalClick::BinaryCodecBudget.new(w208_limits, true)
    CrystalClick::BinaryJsonObjectAdapter.to_document(row, binding, forward, depth: 1)
    # One row owner, JSON descriptor, path record, UInt64 descriptor/value,
    # captured descriptor, and output ObjectDocument root: seven logical nodes.
    forward.node_count.should eq(7_i64)
    # A path record/value pair plus one ObjectDocument path edge: three edges.
    forward.element_count.should eq(3_i64)
    # JSON path wire record is 7+1 bytes; the bridge materializes a temporary
    # seven-byte key and the returned ObjectDocument's detached key. The UInt64
    # scalar contributes no borrowed payload bytes.
    forward.wire_byte_count.should eq(22_i64)

    document = CrystalClick::ObjectDocument.new(
      {"counter" => CrystalClick::BinaryValue.uint64(1_u64)} of String => CrystalClick::BinaryValue,
    )
    reverse = CrystalClick::BinaryCodecBudget.new(w208_limits)
    CrystalClick::BinaryJsonObjectAdapter.to_json_row(document, binding, reverse, depth: 1)
    # The reverse direction charges the source ObjectDocument root and path
    # edge, then the same descriptor/row/value ownership and path metadata.
    reverse.node_count.should eq(7_i64)
    reverse.element_count.should eq(3_i64)
    # One seven-byte temporary lookup key plus the eight-byte retained row
    # path wire record; the UInt64 scalar is borrowed unchanged.
    reverse.wire_byte_count.should eq(15_i64)
  end

  it "bridges a nested JSON child logically while leaving SharedVariant persistence rejected" do
    child_type = CrystalClick::BinaryDataType.json(max_dynamic_paths: 0, max_dynamic_types: 0)
    child_row = CrystalClick::BinaryJsonRow.new(
      child_type,
      [] of Tuple(String, CrystalClick::BinaryValue),
    )
    child = CrystalClick::BinaryValue.json(child_type, child_row)
    parent_type = CrystalClick::BinaryDataType.json(max_dynamic_paths: 1, max_dynamic_types: 1)
    parent_row = CrystalClick::BinaryJsonRow.new(
      parent_type,
      [{"spill", child}] of Tuple(String, CrystalClick::BinaryValue),
    )
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    structure = CrystalClick::DynamicStructure.new([parent_type] of CrystalClick::BinaryDataType)
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["spill"] of String),
      {"spill" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)} of String => CrystalClick::DynamicStructure,
    )
    plan = CrystalClick::ObjectDocumentPlan.new(
      structures,
      {} of String => CrystalClick::BinaryDataType,
    )
    budget = CrystalClick::BinaryCodecBudget.new(w208_limits, true)
    binding = CrystalClick::DynamicJsonObjectBinding.new("root", structure, 0, plan, budget, depth: 1)
    document = CrystalClick::BinaryJsonObjectAdapter.to_document(parent_row, binding, budget, depth: 1)
    document.value_for("spill").same?(child).should be_true

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentCodec.encode_with_budget(
        plan,
        [[document] of CrystalClick::ObjectDocument],
        budget,
      )
    end
  end
end
