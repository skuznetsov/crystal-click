require "./spec_helper"

private def w140_schema_usage(type : CrystalClick::BinaryDataType)
  schema = CrystalClick::ObjectDocumentSchema.new({"payload" => type})
  usage = CrystalClick::ObjectSchemaLogicalUsage.measure(schema, schema.typed_paths)
  {schema, usage}
end

describe CrystalClick::ObjectSchemaLogicalUsage do
  it "keeps the scalar baseline and reserves exact or one-short zero-row budgets" do
    schema, usage = w140_schema_usage(CrystalClick::BinaryDataType.primitive("UInt8"))
    fields = schema.typed_paths

    # Independent reconstruction of the prior scalar byte floor.
    scalar_bytes = instance_sizeof(CrystalClick::ObjectDocumentSchema).to_u64
    scalar_bytes += instance_sizeof(Hash(String, CrystalClick::BinaryDataType)).to_u64
    scalar_bytes += instance_sizeof(Array(String)).to_u64
    scalar_bytes += instance_sizeof(String).to_u64 + schema.declaration_byte_size.to_u64 + 1_u64
    scalar_bytes += sizeof(Pointer(String)).to_u64
    scalar_bytes += sizeof(Pointer(String)).to_u64 + sizeof(Pointer(CrystalClick::BinaryDataType)).to_u64 + 8_u64
    fields.each do |path, type|
      scalar_bytes += instance_sizeof(String).to_u64 + path.bytesize.to_u64 + 1_u64
      scalar_bytes += instance_sizeof(CrystalClick::BinaryDataType).to_u64
      scalar_bytes += instance_sizeof(Array(CrystalClick::BinaryDataType)).to_u64
      scalar_bytes += instance_sizeof(Array(String)).to_u64
      scalar_bytes += instance_sizeof(String).to_u64 + "UInt8".bytesize.to_u64 + 1_u64
    end
    usage.bytes.should eq(scalar_bytes * 2_u64)
    {usage.nodes, usage.elements}.should eq({3_u64, 2_u64})

    retained_bytes = instance_sizeof(Array(CrystalClick::OfflineColumnValue)).to_u64 + usage.bytes
    exact_nodes = usage.nodes + 1_u64 # result array plus schema/path/type owners
    exact_elements = usage.elements
    exact = CrystalClick::ObjectValuesMaterializationBudget.new(
      logical_limit: retained_bytes,
      max_nodes: exact_nodes,
      max_elements: exact_elements,
    )
    exact.reserve_base(
      0_u64,
      usage.bytes,
      descriptor_nodes: usage.nodes,
      descriptor_elements: usage.elements,
    )
    {exact.retained_logical_bytes, exact.node_count, exact.element_count}.should eq({retained_bytes, exact_nodes, exact_elements})

    short_logical = CrystalClick::ObjectValuesMaterializationBudget.new(
      logical_limit: retained_bytes - 1_u64,
      max_nodes: exact_nodes,
      max_elements: exact_elements,
    )
    expect_raises(CrystalClick::BoundsError) do
      short_logical.reserve_base(0_u64, usage.bytes, descriptor_nodes: usage.nodes, descriptor_elements: usage.elements)
    end
    {short_logical.retained_logical_bytes, short_logical.node_count, short_logical.element_count}.should eq({0_u64, 0_u64, 0_u64})

    short_nodes = CrystalClick::ObjectValuesMaterializationBudget.new(
      logical_limit: retained_bytes,
      max_nodes: exact_nodes - 1_u64,
      max_elements: exact_elements,
    )
    expect_raises(CrystalClick::BoundsError) do
      short_nodes.reserve_base(0_u64, usage.bytes, descriptor_nodes: usage.nodes, descriptor_elements: usage.elements)
    end
    {short_nodes.retained_logical_bytes, short_nodes.node_count, short_nodes.element_count}.should eq({0_u64, 0_u64, 0_u64})

    short_elements = CrystalClick::ObjectValuesMaterializationBudget.new(
      logical_limit: retained_bytes,
      max_nodes: exact_nodes,
      max_elements: exact_elements - 1_u64,
    )
    expect_raises(CrystalClick::BoundsError) do
      short_elements.reserve_base(0_u64, usage.bytes, descriptor_nodes: usage.nodes, descriptor_elements: usage.elements)
    end
    {short_elements.retained_logical_bytes, short_elements.node_count, short_elements.element_count}.should eq({0_u64, 0_u64, 0_u64})
  end

  it "adds sibling descriptor subtrees, child edges, and named Tuple metadata at zero rows" do
    byte = CrystalClick::BinaryDataType.primitive("UInt8")
    string = CrystalClick::BinaryDataType.primitive("String")
    left = CrystalClick::BinaryDataType.array(byte)
    right = CrystalClick::BinaryDataType.array(string)
    tuple = CrystalClick::BinaryDataType.tuple([left, right], ["left", "right"] of String)
    map = CrystalClick::BinaryDataType.map(string, tuple)
    schema, usage = w140_schema_usage(map)

    # map -> String key + Tuple value -> two Array sibling subtrees -> leaves.
    # The root type is already in the base count; each descendant type and each
    # owned Tuple name is counted once. Elements include every child/name slot.
    {usage.nodes, usage.elements}.should eq({11_u64, 10_u64})
    {schema.limits.max_depth, usage.bytes > 0_u64}.should eq({CrystalClick::ObjectDocumentSchema::DEFAULT_LIMITS.max_depth, true})

    retained_bytes = instance_sizeof(Array(CrystalClick::OfflineColumnValue)).to_u64 + usage.bytes
    exact_nodes = usage.nodes + 1_u64
    exact = CrystalClick::ObjectValuesMaterializationBudget.new(
      logical_limit: retained_bytes,
      max_nodes: exact_nodes,
      max_elements: usage.elements,
    )
    exact.reserve_base(0_u64, usage.bytes, descriptor_nodes: usage.nodes, descriptor_elements: usage.elements)
    {exact.retained_logical_bytes, exact.node_count, exact.element_count}.should eq({retained_bytes, exact_nodes, usage.elements})

    [
      {retained_bytes - 1_u64, exact_nodes, usage.elements},
      {retained_bytes, exact_nodes - 1_u64, usage.elements},
      {retained_bytes, exact_nodes, usage.elements - 1_u64},
    ].each do |logical_limit, node_limit, element_limit|
      short = CrystalClick::ObjectValuesMaterializationBudget.new(
        logical_limit: logical_limit,
        max_nodes: node_limit,
        max_elements: element_limit,
      )
      expect_raises(CrystalClick::BoundsError) do
        short.reserve_base(0_u64, usage.bytes, descriptor_nodes: usage.nodes, descriptor_elements: usage.elements)
      end
      {short.retained_logical_bytes, short.node_count, short.element_count}.should eq({0_u64, 0_u64, 0_u64})
    end

    shallow_schema, shallow_usage = w140_schema_usage(CrystalClick::BinaryDataType.primitive("UInt8"))
    declaration_delta = "JSON(payload Map(String, Tuple(left Array(UInt8), right Array(String))))".bytesize - "JSON(payload UInt8)".bytesize
    type_name_delta = "Map(String, Tuple(left Array(UInt8), right Array(String)))".bytesize - "UInt8".bytesize
    recursive_owner_bytes = sizeof(Pointer(CrystalClick::BinaryDataType)).to_u64 * 2_u64
    recursive_owner_bytes += instance_sizeof(CrystalClick::BinaryDataType).to_u64 * 6_u64
    recursive_owner_bytes += instance_sizeof(Array(CrystalClick::BinaryDataType)).to_u64 * 6_u64
    recursive_owner_bytes += instance_sizeof(Array(String)).to_u64 * 6_u64
    recursive_owner_bytes += sizeof(Pointer(CrystalClick::BinaryDataType)).to_u64 * 4_u64
    recursive_owner_bytes += sizeof(Pointer(String)).to_u64 * 2_u64
    recursive_owner_bytes += (instance_sizeof(String).to_u64 + "left".bytesize.to_u64 + 1_u64)
    recursive_owner_bytes += (instance_sizeof(String).to_u64 + "right".bytesize.to_u64 + 1_u64)
    recursive_owner_bytes += instance_sizeof(String).to_u64 + "UInt8".bytesize.to_u64 + 1_u64
    # Both the Map key and the nested Array value are descendant String type
    # positions; the logical tree estimate charges each position's primitive
    # descriptor/name owner, even when an immutable descriptor is shared.
    2.times do
      recursive_owner_bytes += instance_sizeof(String).to_u64 + "String".bytesize.to_u64 + 1_u64
    end
    (usage.bytes - shallow_usage.bytes).should eq(
      2_u64 * (declaration_delta.to_u64 + type_name_delta.to_u64) + recursive_owner_bytes,
    )
    usage.bytes.should be > shallow_usage.bytes
    shallow_schema.declaration_byte_size.should eq("JSON(payload UInt8)".bytesize)
  end

  it "charges temporal, enum, and Tuple name length deltas without changing owner counts" do
    short_type = CrystalClick::BinaryDataType.tuple(
      [
        CrystalClick::BinaryDataType.datetime("UTC"),
        CrystalClick::BinaryDataType.enum8([{"a", 1_i16}, {"b", 2_i16}] of CrystalClick::BinaryEnumDefinition::Entry),
      ] of CrystalClick::BinaryDataType,
      ["ts", "state"] of String,
    )
    long_type = CrystalClick::BinaryDataType.tuple(
      [
        CrystalClick::BinaryDataType.datetime("America/New_York"),
        CrystalClick::BinaryDataType.enum8([{"first_long", 1_i16}, {"second_long", 2_i16}] of CrystalClick::BinaryEnumDefinition::Entry),
      ] of CrystalClick::BinaryDataType,
      ["timestamp", "enum_state"] of String,
    )
    short_schema, short_usage = w140_schema_usage(short_type)
    long_schema, long_usage = w140_schema_usage(long_type)

    short_type_name = "Tuple(ts DateTime('UTC'), state Enum8('a' = 1, 'b' = 2))"
    long_type_name = "Tuple(timestamp DateTime('America/New_York'), enum_state Enum8('first_long' = 1, 'second_long' = 2))"
    type_name_delta = long_type_name.bytesize - short_type_name.bytesize
    declaration_delta = long_schema.declaration_byte_size - short_schema.declaration_byte_size
    declaration_delta.should eq(type_name_delta)

    tuple_name_delta = "timestamp".bytesize + "enum_state".bytesize - "ts".bytesize - "state".bytesize
    zone_name_delta = "America/New_York".bytesize - "UTC".bytesize
    enum_label_delta = "first_long".bytesize + "second_long".bytesize - "a".bytesize - "b".bytesize
    expected_byte_delta = 2_u64 * (declaration_delta.to_u64 + type_name_delta.to_u64)
    expected_byte_delta += tuple_name_delta.to_u64 + zone_name_delta.to_u64 + enum_label_delta.to_u64

    (long_usage.bytes - short_usage.bytes).should eq(expected_byte_delta)
    {short_usage.nodes, short_usage.elements}.should eq({10_u64, 8_u64})
    {long_usage.nodes, long_usage.elements}.should eq({10_u64, 8_u64})
  end

  it "uses the schema's custom depth limit for a deep zero-row descriptor" do
    type = CrystalClick::BinaryDataType.primitive("UInt8")
    66.times { type = CrystalClick::BinaryDataType.array(type) }
    limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: 68,
      max_nodes: 4_096,
      max_elements: 10_000,
      max_bytes: 1_000_000,
    )
    schema = CrystalClick::ObjectDocumentSchema.new({"payload" => type}, limits: limits)

    usage = CrystalClick::ObjectSchemaLogicalUsage.measure(schema, schema.typed_paths)
    usage.nodes.should eq(69_u64)    # schema, path, 67 type descriptors
    usage.elements.should eq(68_u64) # two path slots and 66 Array child edges
  end
end
