require "./spec_helper"

private def w281s_budget(
  max_depth : Int,
  max_nodes : Int,
  max_elements : Int,
  max_bytes : Int,
  writing : Bool = true,
) : CrystalClick::BinaryCodecBudget
  limits = CrystalClick::BinaryCodecLimits.new(
    max_depth: max_depth,
    max_nodes: max_nodes,
    max_elements: max_elements,
    max_bytes: max_bytes,
  )
  CrystalClick::BinaryCodecBudget.new(limits, writing)
end

private def w281s_parse(
  source : String,
  budget : CrystalClick::BinaryCodecBudget,
  inherited_depth : Int32 = 1,
) : CrystalClick::BinaryDataType?
  CrystalClick::StorageStaticBulkDeclaration.parse_slice(
    source,
    0,
    source.bytesize.to_i32,
    budget,
    inherited_depth,
  )
end

private def w281s_counts(budget : CrystalClick::BinaryCodecBudget) : Tuple(Int64, Int64, Int64)
  {budget.node_count, budget.element_count, budget.wire_byte_count}
end

private def w281s_seeded_budget(
  max_nodes : Int,
  max_elements : Int,
  max_bytes : Int,
  max_depth : Int = 64,
) : CrystalClick::BinaryCodecBudget
  budget = w281s_budget(max_depth, max_nodes, max_elements, max_bytes)
  budget.charge_node
  budget.charge_node
  budget.charge_elements(3_u64)
  budget.charge_wire_bytes(5_u64)
  budget
end

describe "StorageStaticBulkDeclaration bounded static fallback" do
  it "parses literal canonical static leaves and wrappers with JSON-looking quoted text" do
    escaped_enum = "Enum8('left" + "\\" + "'JSON' = 1)"
    escaped_backtick_field = "Tuple(`JSON" + "\\" + "` alias` BFloat16, x Time)"
    declarations = [
      {"BFloat16", "BFloat16"},
      {"Time", "Time"},
      {"Nothing", "Nothing"},
      {"Tuple()", "Tuple()"},
      {"Map(UInt8, String)", "Map(UInt8, String)"},
      {"Enum8('JSON' = 1)", "Enum8('JSON' = 1)"},
      {escaped_enum, escaped_enum},
      {"Tuple(`JSON alias` BFloat16, x Time)", "Tuple(`JSON alias` BFloat16, x Time)"},
      {escaped_backtick_field, escaped_backtick_field},
      {"Tuple(JSON BFloat16, x Time)", "Tuple(JSON BFloat16, x Time)"},
      {"Tuple(JSONx UInt8, x Time)", "Tuple(JSONx UInt8, x Time)"},
    ] of Tuple(String, String)

    declarations.each do |source, expected_name|
      budget = w281s_budget(
        CrystalClick::BinaryCodecLimits::DEFAULT_MAX_DEPTH,
        CrystalClick::BinaryCodecLimits::DEFAULT_MAX_NODES,
        CrystalClick::BinaryCodecLimits::DEFAULT_MAX_ELEMENTS,
        CrystalClick::BinaryCodecLimits::DEFAULT_MAX_BYTES,
      )
      descriptor = w281s_parse(source, budget) || raise "W281 expected static declaration to parse: #{source}"
      descriptor.name.should eq(expected_name)
    end
  end

  it "transfers a successful trial's exact node, edge, and name-work deltas once" do
    # Map(UInt8, String) is six descriptor/name visits, four parser/name edges,
    # and 142 bytes of conservative SQL-name work under the existing budget.
    budget = w281s_seeded_budget(
      max_nodes: 8,
      max_elements: 7,
      max_bytes: 147,
    )
    w281s_counts(budget).should eq({2_i64, 3_i64, 5_i64})

    descriptor = w281s_parse("Map(UInt8, String)", budget) ||
                 raise "W281 expected Map static declaration to parse"

    descriptor.name.should eq("Map(UInt8, String)")
    w281s_counts(budget).should eq({8_i64, 7_i64, 147_i64})
  end

  it "propagates each exact logical limit failure without poisoning the parent budget" do
    [
      {7, 7, 147}, # one node below the six-node trial delta
      {8, 6, 147}, # one edge below the four-edge trial delta
      {8, 7, 146}, # one name-work byte below the 142-byte trial delta
    ].each do |max_nodes, max_elements, max_bytes|
      budget = w281s_seeded_budget(max_nodes, max_elements, max_bytes)
      before = w281s_counts(budget)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        w281s_parse("Map(UInt8, String)", budget)
      end
      w281s_counts(budget).should eq(before)
      before.should eq({2_i64, 3_i64, 5_i64})
    end
  end

  it "preserves inherited absolute descriptor depth at the exact boundary" do
    exact = w281s_budget(max_depth: 3, max_nodes: 32, max_elements: 32, max_bytes: 4096)
    descriptor = w281s_parse("Map(UInt8, String)", exact, 2) ||
                 raise "W281 expected Map at inherited depth two to parse"
    descriptor.name.should eq("Map(UInt8, String)")
    w281s_counts(exact).should eq({6_i64, 4_i64, 142_i64})

    one_below = w281s_budget(max_depth: 2, max_nodes: 32, max_elements: 32, max_bytes: 4096)
    before = w281s_counts(one_below)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      w281s_parse("Map(UInt8, String)", one_below, 2)
    end
    w281s_counts(one_below).should eq(before)
  end

  it "returns nil for malformed, noncanonical, stateful, and JSON-bearing candidates without parent changes" do
    rejected = [
      "Map(UInt8)",
      "Nullable( UInt8 )",
      "Map(UInt8,String)",
      "Variant(UInt8, String)",
      "Dynamic",
      "JSON(UInt8)",
      "Array(JSON(UInt8))",
      "Tuple(UInt8, JSON(UInt8))",
    ] of String
    budget = w281s_seeded_budget(max_nodes: 4096, max_elements: 4096, max_bytes: 4096)
    before = w281s_counts(budget)

    rejected.each do |source|
      w281s_parse(source, budget).should be_nil
      w281s_counts(budget).should eq(before)
    end
  end

  it "rejects an actual JSON type atom even when the parent has no residual nodes" do
    budget = w281s_budget(max_depth: 64, max_nodes: 0, max_elements: 0, max_bytes: 4096)
    w281s_parse("JSON(UInt8)", budget).should be_nil
    w281s_counts(budget).should eq({0_i64, 0_i64, 0_i64})
  end

  it "limits the JSON atom scan to the supplied candidate slice" do
    before_candidate = "JSON BFloat16"
    first = "JSON ".bytesize.to_i32
    after = before_candidate.bytesize.to_i32
    first_budget = w281s_budget(max_depth: 64, max_nodes: 32, max_elements: 32, max_bytes: 4096)
    first_descriptor = CrystalClick::StorageStaticBulkDeclaration.parse_slice(
      before_candidate,
      first,
      after,
      first_budget,
      1,
    ) || raise "W281 candidate after JSON text should parse as BFloat16"
    first_descriptor.name.should eq("BFloat16")

    after_candidate = "BFloat16 JSON"
    second_budget = w281s_budget(max_depth: 64, max_nodes: 32, max_elements: 32, max_bytes: 4096)
    second_descriptor = CrystalClick::StorageStaticBulkDeclaration.parse_slice(
      after_candidate,
      0,
      "BFloat16".bytesize.to_i32,
      second_budget,
      1,
    ) || raise "W281 candidate before JSON text should parse as BFloat16"
    second_descriptor.name.should eq("BFloat16")
  end

  it "bounds source-slice size by residual bytes before creating a trial" do
    budget = w281s_budget(max_depth: 64, max_nodes: 128, max_elements: 128, max_bytes: 17)
    before = w281s_counts(budget)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      w281s_parse("Map(UInt8, String)", budget)
    end
    w281s_counts(budget).should eq(before)
  end

  it "rejects invalid spans and read-direction parents before changing counters" do
    invalid_span_budget = w281s_seeded_budget(max_nodes: 128, max_elements: 128, max_bytes: 4096)
    before = w281s_counts(invalid_span_budget)
    expect_raises(ArgumentError) do
      CrystalClick::StorageStaticBulkDeclaration.parse_slice("Time", -1, 4, invalid_span_budget, 1)
    end
    w281s_counts(invalid_span_budget).should eq(before)

    read_budget = w281s_budget(max_depth: 64, max_nodes: 128, max_elements: 128, max_bytes: 4096, writing: false)
    read_before = w281s_counts(read_budget)
    expect_raises(ArgumentError) do
      w281s_parse("Time", read_budget)
    end
    w281s_counts(read_budget).should eq(read_before)
  end

  it "does not widen default ObjectJson typed fields while static Bulk accepts a non-String Map key" do
    object_json_guards = [
      "Map(UInt8, String)",
      "BFloat16",
      "Nothing",
      "IntervalDay",
      "Point",
      "SimpleAggregateFunction(sum, UInt64)",
    ] of String

    object_json_guards.each do |declaration|
      bytes = declaration.to_slice
      CrystalClick::ObjectRecursiveDeclaration.preflight_slice(bytes, 0, bytes.size).should be_nil
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(value #{declaration})")
      end
    end

    map_declaration = "Map(UInt8, String)"
    map_bytes = map_declaration.to_slice
    dynamic_bulk = CrystalClick::ObjectRecursiveDeclaration.preflight_slice(
      map_bytes,
      0,
      map_bytes.size,
      profile: CrystalClick::ObjectRecursiveDeclaration::AdmissionProfile::DynamicBulk,
    )
    dynamic_bulk.should_not be_nil
    CrystalClick::ObjectRecursiveDeclaration.preflight_slice(map_bytes, 0, map_bytes.size).should be_nil
  end
end
