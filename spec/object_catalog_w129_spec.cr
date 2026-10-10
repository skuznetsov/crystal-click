require "./spec_helper"

private def w129_type(name : String) : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.primitive(name)
end

describe "W129 Object catalog schema declaration" do
  it "parses the canonical writer grammar independent of admitted argument order" do
    schema = CrystalClick::ObjectDocumentSchema.parse_declaration(
      "JSON(t String, max_dynamic_paths=7, `SKIP` UInt64, max_dynamic_types=3, `a.b` String, `select` UInt64)"
    )

    schema.max_dynamic_paths.should eq(7)
    schema.max_dynamic_types.should eq(3)
    schema.typed_paths.should eq({
      "SKIP"   => w129_type("UInt64"),
      "a.b"    => w129_type("String"),
      "select" => w129_type("UInt64"),
      "t"      => w129_type("String"),
    })
    schema.declaration.should eq("JSON(max_dynamic_types=3, max_dynamic_paths=7, `SKIP` UInt64, `a.b` String, `select` UInt64, t String)")
  end

  it "accepts bare JSON as the default empty typed schema" do
    schema = CrystalClick::ObjectDocumentSchema.parse_declaration("JSON")
    schema.max_dynamic_paths.should eq(CrystalClick::ObjectDocumentSchema::DEFAULT_MAX_DYNAMIC_PATHS)
    schema.max_dynamic_types.should eq(CrystalClick::ObjectDocumentSchema::DEFAULT_MAX_DYNAMIC_TYPES)
    schema.typed_paths.should be_empty
    schema.declaration.should eq("JSON")
  end

  it "ignores declaration-edge whitespace without widening path spelling" do
    schema = CrystalClick::ObjectDocumentSchema.parse_declaration("  JSON(`a.b` String) \n")
    schema.declaration.should eq("JSON(`a.b` String)")

    opaque = CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(`a..b` String)")
    opaque.typed_paths.should eq({"a..b" => w129_type("String")})
    opaque.declaration.should eq("JSON(`a..b` String)")

    ["JSON(select UInt64)", "JSON(SKIP String)", "JSON(a.b UInt64)"].each do |declaration|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentSchema.parse_declaration(declaration)
      end
    end
  end

  it "rejects duplicate capacity options and semantically duplicate typed paths" do
    [
      "JSON(max_dynamic_paths=1, max_dynamic_paths=2)",
      "JSON(max_dynamic_types=1, max_dynamic_types=1)",
      "JSON(t UInt64, `t` UInt64)",
      "JSON(`a.b` UInt64, `a.b` String)",
    ].each do |declaration|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentSchema.parse_declaration(declaration)
      end
    end
  end

  it "rejects unsupported typed scalar types, malformed paths, and out-of-range capacities" do
    [
      "JSON(t BFloat16)",
      "JSON(a.b String)",
      "JSON(max_dynamic_paths=10001)",
      "JSON(max_dynamic_types=255)",
      "JSON(max_dynamic_paths=-1)",
      "JSON(max_dynamic_paths=01)",
      "JSON(unknown=1)",
      "JSON()",
      "JSON(t String,,x UInt64)",
      "JSON(t String",
    ].each do |declaration|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentSchema.parse_declaration(declaration)
      end
    end
  end

  it "bounds declaration bytes and argument nodes before retaining a schema" do
    bytes_limited = CrystalClick::BinaryCodecLimits.new(max_depth: 16, max_nodes: 32, max_elements: 32, max_bytes: 3)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentSchema.parse_declaration("JSON", bytes_limited)
    end

    nodes_limited = CrystalClick::BinaryCodecLimits.new(max_depth: 16, max_nodes: 2, max_elements: 2, max_bytes: 128)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(a UInt64, b UInt64)", nodes_limited)
    end
  end
end

describe CrystalClick::ObjectValuesMaterializationBudget do
  it "atomically charges a complete mark and allows a smaller retry" do
    budget = CrystalClick::ObjectValuesMaterializationBudget.new(
      logical_limit: 4_096_u64,
      max_string_bytes: 32_u64,
      max_tuple_cells: 1_u64,
      max_nodes: 64_u64,
      max_elements: 64_u64,
    )
    budget.reserve_base(2_u64, 16_u64)
    first = CrystalClick::ObjectDocument.new({"first" => CrystalClick::BinaryValue.uint64(1_u64)})
    second = CrystalClick::ObjectDocument.new({"second" => CrystalClick::BinaryValue.uint64(2_u64)})
    before = {budget.retained_logical_bytes, budget.string_payload_bytes, budget.tuple_cells, budget.node_count, budget.element_count}

    expect_raises(CrystalClick::BoundsError) { budget.charge_documents([first, second]) }
    {budget.retained_logical_bytes, budget.string_payload_bytes, budget.tuple_cells, budget.node_count, budget.element_count}.should eq(before)

    budget.charge_documents([first])
    budget.tuple_cells.should eq(1_u64)
  end

  it "accounts for every pending mark owner together with reader workspace" do
    first = CrystalClick::ObjectDocument.new({"first" => CrystalClick::BinaryValue.uint64(1_u64)})
    second = CrystalClick::ObjectDocument.new({"second" => CrystalClick::BinaryValue.uint64(2_u64)})
    workspace_bytes = 128_u64
    probe = CrystalClick::ObjectValuesMaterializationBudget.new(
      logical_limit: 65_536_u64,
      max_string_bytes: 32_u64,
      max_tuple_cells: 8_u64,
      max_nodes: 64_u64,
      max_elements: 64_u64,
    )
    probe.reserve_base(2_u64, 16_u64)
    probe.charge_documents([first])

    budget = CrystalClick::ObjectValuesMaterializationBudget.new(
      logical_limit: probe.retained_logical_bytes + workspace_bytes,
      max_string_bytes: 32_u64,
      max_tuple_cells: 8_u64,
      max_nodes: 64_u64,
      max_elements: 64_u64,
    )
    budget.reserve_base(2_u64, 16_u64)
    budget.ensure_workspace(workspace_bytes)
    before = {budget.retained_logical_bytes, budget.string_payload_bytes, budget.tuple_cells, budget.node_count, budget.element_count}

    expect_raises(CrystalClick::BoundsError) do
      budget.charge_documents([first, second], workspace_bytes)
    end
    {budget.retained_logical_bytes, budget.string_payload_bytes, budget.tuple_cells, budget.node_count, budget.element_count}.should eq(before)

    budget.charge_documents([first], workspace_bytes)
    budget.retained_logical_bytes.should eq(probe.retained_logical_bytes)
  end

  it "atomically rejects recursive retained cells without consuming the prior budget" do
    budget = CrystalClick::ObjectValuesMaterializationBudget.new(
      logical_limit: 4_096_u64,
      max_string_bytes: 32_u64,
      max_tuple_cells: 2_u64,
      max_nodes: 64_u64,
      max_elements: 64_u64,
    )
    budget.reserve_base(1_u64, 16_u64)
    before = {budget.retained_logical_bytes, budget.string_payload_bytes, budget.tuple_cells, budget.node_count, budget.element_count}

    array_type = CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.primitive("String"))
    nested = CrystalClick::BinaryValue.array(array_type, [
      CrystalClick::BinaryValue.string("a"), CrystalClick::BinaryValue.string("b"),
    ])
    document = CrystalClick::ObjectDocument.new({"items" => nested})
    expect_raises(CrystalClick::BoundsError) { budget.charge_document(document) }

    {budget.retained_logical_bytes, budget.string_payload_bytes, budget.tuple_cells, budget.node_count, budget.element_count}.should eq(before)
    budget.charge_document(CrystalClick::ObjectDocument.new({"n" => CrystalClick::BinaryValue.uint64(1_u64)}))
    budget.tuple_cells.should eq(1_u64)

    budget.charge_document(CrystalClick::ObjectDocument.new({"m" => CrystalClick::BinaryValue.uint64(2_u64)}))
    after_two = {budget.retained_logical_bytes, budget.string_payload_bytes, budget.tuple_cells, budget.node_count, budget.element_count}
    expect_raises(CrystalClick::BoundsError) do
      budget.charge_document(CrystalClick::ObjectDocument.new({"k" => CrystalClick::BinaryValue.uint64(3_u64)}))
    end
    {budget.retained_logical_bytes, budget.string_payload_bytes, budget.tuple_cells, budget.node_count, budget.element_count}.should eq(after_two)
    expect_raises(CrystalClick::BoundsError) { budget.reserve_base(0_u64, 0_u64) }
    {budget.retained_logical_bytes, budget.string_payload_bytes, budget.tuple_cells, budget.node_count, budget.element_count}.should eq(after_two)
  end

  it "aggregates retained owners with reader workspace before mutating counters" do
    budget = CrystalClick::ObjectValuesMaterializationBudget.new(
      logical_limit: 1_024_u64,
      max_string_bytes: 32_u64,
      max_tuple_cells: 8_u64,
      max_nodes: 64_u64,
      max_elements: 64_u64,
    )
    budget.reserve_base(0_u64, 16_u64, 700_u64)
    document = CrystalClick::ObjectDocument.new({"n" => CrystalClick::BinaryValue.uint64(1_u64)})
    before = {budget.retained_logical_bytes, budget.string_payload_bytes, budget.tuple_cells, budget.node_count, budget.element_count}
    expect_raises(CrystalClick::BoundsError) { budget.charge_document(document, 700_u64) }
    {budget.retained_logical_bytes, budget.string_payload_bytes, budget.tuple_cells, budget.node_count, budget.element_count}.should eq(before)

    budget.charge_document(document)
    budget.retained_logical_bytes.should be > before[0]
    expect_raises(CrystalClick::BoundsError) { budget.ensure_workspace(1_024_u64) }
  end

  it "rejects charging before base reservation without mutating prior counters" do
    budget = CrystalClick::ObjectValuesMaterializationBudget.new(
      logical_limit: 4_096_u64,
      max_string_bytes: 32_u64,
      max_tuple_cells: 8_u64,
      max_nodes: 64_u64,
      max_elements: 64_u64,
    )
    document = CrystalClick::ObjectDocument.new({"n" => CrystalClick::BinaryValue.uint64(1_u64)})
    before = {budget.retained_logical_bytes, budget.string_payload_bytes, budget.tuple_cells, budget.node_count, budget.element_count}
    expect_raises(CrystalClick::BoundsError) { budget.charge_document(document) }
    expect_raises(CrystalClick::BoundsError) { budget.ensure_workspace(1_u64) }
    {budget.retained_logical_bytes, budget.string_payload_bytes, budget.tuple_cells, budget.node_count, budget.element_count}.should eq(before)

    budget.reserve_base(0_u64, 16_u64)
    budget.charge_document(document)
    budget.tuple_cells.should eq(1_u64)
  end

  it "charges Enum label owners as descriptors rather than String payload" do
    short_type = CrystalClick::BinaryDataType.enum8([
      {"a", 1_i16}, {"b", 2_i16},
    ] of CrystalClick::BinaryEnumDefinition::Entry)
    short_value = CrystalClick::BinaryValue.fixed(short_type, Bytes[1_u8])
    short_document = CrystalClick::ObjectDocument.new({"state" => short_value})
    short_budget = CrystalClick::ObjectValuesMaterializationBudget.new(
      logical_limit: 4_096_u64,
      max_string_bytes: 0_u64,
      max_tuple_cells: 8_u64,
      max_nodes: 64_u64,
      max_elements: 64_u64,
    )
    short_budget.reserve_base(1_u64, 16_u64)
    short_budget.charge_document(short_document)
    short_budget.string_payload_bytes.should eq(0_u64)

    long_type = CrystalClick::BinaryDataType.enum8([
      {"a-long-enum-label", 1_i16}, {"another-long-enum-label", 2_i16},
    ] of CrystalClick::BinaryEnumDefinition::Entry)
    long_value = CrystalClick::BinaryValue.fixed(long_type, Bytes[1_u8])
    long_document = CrystalClick::ObjectDocument.new({"state" => long_value})
    long_budget = CrystalClick::ObjectValuesMaterializationBudget.new(
      logical_limit: short_budget.retained_logical_bytes,
      max_string_bytes: 0_u64,
      max_tuple_cells: 8_u64,
      max_nodes: 64_u64,
      max_elements: 64_u64,
    )
    long_budget.reserve_base(1_u64, 16_u64)
    before = {long_budget.retained_logical_bytes, long_budget.string_payload_bytes, long_budget.tuple_cells, long_budget.node_count, long_budget.element_count}
    expect_raises(CrystalClick::BoundsError) { long_budget.charge_document(long_document) }
    {long_budget.retained_logical_bytes, long_budget.string_payload_bytes, long_budget.tuple_cells, long_budget.node_count, long_budget.element_count}.should eq(before)
    long_budget.string_payload_bytes.should eq(0_u64)
  end
end
