require "./spec_helper"

private def w140_root_limits(depth = 64, nodes = 4096, elements = 4096, bytes = 65536)
  CrystalClick::BinaryCodecLimits.new(max_depth: depth, max_nodes: nodes, max_elements: elements, max_bytes: bytes)
end

private class W140RootCountingIO < IO
  getter writes = 0

  def read(slice : Bytes) : Int32
    0
  end

  def write(slice : Bytes) : Nil
    @writes += 1
  end
end

describe "W140 root recursive policy adversaries" do
  it "charges the Array child independently from the JSON root and field" do
    declaration = "JSON(v Array(UInt8))"
    type = CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.primitive("UInt8"))
    exact = w140_root_limits(depth: 3, nodes: 3, elements: 2, bytes: 65536)
    CrystalClick::ObjectDocumentSchema.parse_declaration(declaration, exact).declaration.should eq(declaration)
    CrystalClick::ObjectDocumentSchema.new({"v" => type}, limits: exact).declaration.should eq(declaration)

    [
      w140_root_limits(depth: 2, nodes: 3, elements: 2),
      w140_root_limits(depth: 3, nodes: 2, elements: 2),
      w140_root_limits(depth: 3, nodes: 3, elements: 1),
    ].each do |one_short|
      expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::ObjectDocumentSchema.parse_declaration(declaration, one_short) }
      expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::ObjectDocumentSchema.new({"v" => type}, limits: one_short) }
    end
  end

  it "accounts the sum of sibling subtrees rather than resetting their budgets" do
    u8 = CrystalClick::BinaryDataType.primitive("UInt8")
    fields = {"a" => CrystalClick::BinaryDataType.array(u8), "b" => CrystalClick::BinaryDataType.array(u8)}
    declaration = "JSON(a Array(UInt8), b Array(UInt8))"
    exact = w140_root_limits(depth: 3, nodes: 5, elements: 4)
    CrystalClick::ObjectDocumentSchema.new(fields, limits: exact).declaration.should eq(declaration)
    CrystalClick::ObjectDocumentSchema.parse_declaration(declaration, exact).declaration.should eq(declaration)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentSchema.new(fields, limits: w140_root_limits(depth: 3, nodes: 4, elements: 4))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentSchema.parse_declaration(declaration, w140_root_limits(depth: 3, nodes: 5, elements: 3))
    end
  end

  it "retains exact nested Tuple, Enum, and zone aggregates across recursive calls" do
    token = "Array(Tuple(n UInt16, state Enum8('off' = 0, 'on' = 1), at DateTime64(3, 'UTC')))"
    bytes = token.to_slice
    scanned = CrystalClick::ObjectRecursiveDeclaration.preflight_slice(bytes, 0, bytes.size, w140_root_limits).not_nil!
    type = scanned.materialize
    measured = CrystalClick::ObjectRecursiveDeclaration.measure_descriptor(type, w140_root_limits).not_nil!
    [scanned.metrics, measured].each do |metrics|
      {metrics.descriptor_node_count, metrics.child_edge_count, metrics.metadata_edge_count}.should eq({5_u64, 4_u64, 5_u64})
      {metrics.tuple_name_count, metrics.tuple_name_bytes}.should eq({3_u64, 8_u64})
      {metrics.enum_entry_count, metrics.decoded_label_bytes, metrics.explicit_zone_bytes}.should eq({2_u64, 5_u64, 3_u64})
      {metrics.total_node_count, metrics.total_edge_count, metrics.max_depth}.should eq({10_u64, 9_u64, 3})
      metrics.byte_size.should eq(token.bytesize.to_u64)
    end

    declaration = "JSON(v #{token})"
    exact = w140_root_limits(depth: 4, nodes: 11, elements: 10)
    CrystalClick::ObjectDocumentSchema.new({"v" => type}, limits: exact).declaration.should eq(declaration)
    CrystalClick::ObjectDocumentSchema.parse_declaration(declaration, exact).declaration.should eq(declaration)
    [
      w140_root_limits(depth: 4, nodes: 10, elements: 10),
      w140_root_limits(depth: 4, nodes: 11, elements: 9),
    ].each do |one_short|
      expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::ObjectDocumentSchema.new({"v" => type}, limits: one_short) }
      expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::ObjectDocumentSchema.parse_declaration(declaration, one_short) }
    end
  end

  it "revalidates a borrowed recursive Map key after same-size mutation" do
    bytes = "Array(Map(String, UInt16))".to_slice.dup
    preflight = CrystalClick::ObjectRecursiveDeclaration.preflight_slice(bytes, 0, bytes.size, w140_root_limits).not_nil!
    "UInt16".to_slice.each_with_index { |byte, index| bytes[10 + index] = byte }
    expect_raises(ArgumentError) { preflight.materialize }
  end

  it "refuses forged aggregate metadata before materializing the tree" do
    bytes = "Array(Map(String, UInt16))".to_slice.dup
    actual = CrystalClick::ObjectRecursiveDeclaration.preflight_slice(bytes, 0, bytes.size, w140_root_limits).not_nil!
    forged = CrystalClick::ObjectRecursiveDeclaration::Preflight.new(
      actual.byte_size, actual.descriptor_node_count - 1_u64,
      actual.child_edge_count, actual.metadata_edge_count,
      actual.enum_entry_count, actual.decoded_label_bytes,
      actual.explicit_zone_bytes, actual.tuple_name_count, actual.tuple_name_bytes,
      actual.max_depth, actual.root_depth, actual.source, actual.first, actual.after, actual.limits,
    )
    expect_raises(ArgumentError) { forged.materialize }
    budget = CrystalClick::BinaryCodecBudget.new(w140_root_limits, true)
    expect_raises(ArgumentError) { forged.account(budget) }
    {budget.node_count, budget.element_count, budget.wire_byte_count}.should eq({0_i64, 0_i64, 0_i64})

    # A public module bridge must preserve the same contract as the handle.
    bridge_budget = CrystalClick::BinaryCodecBudget.new(w140_root_limits, true)
    expect_raises(ArgumentError) { CrystalClick::ObjectRecursiveDeclaration.account_slice(forged, bridge_budget) }
    {bridge_budget.node_count, bridge_budget.element_count, bridge_budget.wire_byte_count}.should eq({0_i64, 0_i64, 0_i64})
    text_budget = CrystalClick::BinaryCodecBudget.new(w140_root_limits, true)
    expect_raises(ArgumentError) { CrystalClick::ObjectRecursiveDeclarationText.account_slice(forged, text_budget) }
    {text_budget.node_count, text_budget.element_count, text_budget.wire_byte_count}.should eq({0_i64, 0_i64, 0_i64})
  end

  it "does not let public materialization bridges bypass aggregate limits" do
    bytes = "Tuple(n Array(UInt8), m String)".to_slice
    # Tuple + Array + UInt8 + String + two names = six nodes, three
    # descriptor child edges + two name slots = five elements.
    one_short = w140_root_limits(nodes: 5, elements: 5)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectRecursiveDeclaration.materialize_slice(bytes, 0, bytes.size, 1, one_short)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectRecursiveDeclarationText.materialize_slice(bytes, 0, bytes.size, 1, one_short)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectRecursiveDeclaration.validate_tuple_names(bytes, 0, bytes.size, 1, one_short)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectRecursiveDeclarationText.validate_tuple_names(bytes, 0, bytes.size, 1, one_short)
    end
  end

  it "treats canonical same-metric borrowed edits as current source, not a snapshot" do
    bytes = "Array(UInt16)".to_slice.dup
    preflight = CrystalClick::ObjectRecursiveDeclaration.preflight_slice(bytes, 0, bytes.size, w140_root_limits).not_nil!
    bytes[10] = '3'.ord.to_u8
    bytes[11] = '2'.ord.to_u8
    preflight.materialize.should eq(CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.primitive("UInt32")))
  end

  it "admits larger caller depth without removing standalone helper bounds" do
    type = CrystalClick::BinaryDataType.primitive("UInt8")
    65.times { type = CrystalClick::BinaryDataType.array(type) }
    large = w140_root_limits(depth: 70, nodes: 100, elements: 100)
    schema = CrystalClick::ObjectDocumentSchema.new({"v" => type}, limits: large)
    CrystalClick::ObjectDocumentSchema.parse_declaration(schema.declaration, large).typed_paths["v"].should eq(type)
    expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::ObjectRecursiveDeclaration.byte_size_for(type) }
    CrystalClick::ObjectRecursiveDeclaration.byte_size_for(type, large).should_not be_nil
  end

  it "rejects the whole descriptor before writing any canonical output" do
    type = CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.primitive("UInt8"))
    io = W140RootCountingIO.new
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectRecursiveDeclaration.append_name(io, type, w140_root_limits(depth: 2), root_depth: 2)
    end
    io.writes.should eq(0)
  end
end
