require "./spec_helper"

private def w186_storage_budget_counters(budget : CrystalClick::ObjectValuesMaterializationBudget)
  {
    budget.retained_logical_bytes,
    budget.string_payload_bytes,
    budget.tuple_cells,
    budget.node_count,
    budget.element_count,
  }
end

private def w186_storage_budget(
  logical_limit : UInt64 = UInt64::MAX,
  max_string_bytes : UInt64 = UInt64::MAX,
  max_tuple_cells : UInt64 = UInt64::MAX,
  max_nodes : UInt64 = UInt64::MAX,
  max_elements : UInt64 = UInt64::MAX,
  max_depth : Int32 = 64,
) : CrystalClick::ObjectValuesMaterializationBudget
  budget = CrystalClick::ObjectValuesMaterializationBudget.new(
    logical_limit: logical_limit,
    max_string_bytes: max_string_bytes,
    max_tuple_cells: max_tuple_cells,
    max_nodes: max_nodes,
    max_elements: max_elements,
    max_depth: max_depth,
  )
  budget.reserve_base(0_u64, 0_u64)
  budget
end

describe CrystalClick::ObjectValuesMaterializationBudget do
  it "charges mixed bulk, Object, and nested Tuple storage values in one usage" do
    document = CrystalClick::ObjectDocument.new({
      "body" => CrystalClick::BinaryValue.string("json"),
    })
    values = [
      CrystalClick::StorageColumnValue.bulk(CrystalClick::BinaryValue.uint64(7_u64)),
      CrystalClick::StorageColumnValue.object_document(document),
      CrystalClick::StorageColumnValue.tuple([
        CrystalClick::StorageColumnValue.bulk(CrystalClick::BinaryValue.string("leaf")),
      ] of CrystalClick::StorageColumnValue),
    ] of CrystalClick::StorageColumnValue

    budget = w186_storage_budget
    budget.charge_storage_values(values)

    budget.string_payload_bytes.should eq(8_u64)
    budget.tuple_cells.should eq(2_u64)
    budget.node_count.should be > 2_u64
    budget.element_count.should be > 0_u64
    budget.retained_logical_bytes.should be > 0_u64

    exact_bytes = budget.retained_logical_bytes
    exact = w186_storage_budget(logical_limit: exact_bytes)
    exact.charge_storage_values(values)
    exact.retained_logical_bytes.should eq(exact_bytes)

    one_short = w186_storage_budget(logical_limit: exact_bytes - 1_u64)
    before = w186_storage_budget_counters(one_short)
    expect_raises(CrystalClick::BoundsError) { one_short.charge_storage_values(values) }
    w186_storage_budget_counters(one_short).should eq(before)
  end

  it "accumulates sibling logical bytes and leaves counters unchanged on an atomic failure" do
    first = CrystalClick::StorageColumnValue.bulk(CrystalClick::BinaryValue.string("left"))
    second = CrystalClick::StorageColumnValue.bulk(CrystalClick::BinaryValue.string("right"))
    probe = w186_storage_budget
    probe.charge_storage_values([first, second])
    exact_total = probe.retained_logical_bytes

    budget = w186_storage_budget(logical_limit: exact_total - 1_u64)
    budget.charge_storage_value(first)
    before = w186_storage_budget_counters(budget)
    expect_raises(CrystalClick::BoundsError) { budget.charge_storage_values([second]) }
    w186_storage_budget_counters(budget).should eq(before)

    atomic = w186_storage_budget(logical_limit: exact_total - 1_u64)
    before_atomic = w186_storage_budget_counters(atomic)
    expect_raises(CrystalClick::BoundsError) { atomic.charge_storage_values([first, second]) }
    w186_storage_budget_counters(atomic).should eq(before_atomic)
  end

  it "accumulates sibling String payloads under the shared limit" do
    first = CrystalClick::StorageColumnValue.bulk(CrystalClick::BinaryValue.string("ab"))
    second = CrystalClick::StorageColumnValue.bulk(CrystalClick::BinaryValue.string("cd"))
    budget = w186_storage_budget(max_string_bytes: 3_u64)
    budget.charge_storage_value(first)
    before = w186_storage_budget_counters(budget)

    expect_raises(CrystalClick::BoundsError) { budget.charge_storage_value(second) }
    w186_storage_budget_counters(budget).should eq(before)
  end

  it "accumulates sibling Tuple cells, nodes, and elements" do
    first = CrystalClick::StorageColumnValue.tuple([
      CrystalClick::StorageColumnValue.bulk(CrystalClick::BinaryValue.uint64(1_u64)),
    ] of CrystalClick::StorageColumnValue)
    second = CrystalClick::StorageColumnValue.tuple([
      CrystalClick::StorageColumnValue.bulk(CrystalClick::BinaryValue.uint64(2_u64)),
    ] of CrystalClick::StorageColumnValue)

    cells = w186_storage_budget(max_tuple_cells: 1_u64)
    cells.charge_storage_value(first)
    before_cells = w186_storage_budget_counters(cells)
    expect_raises(CrystalClick::BoundsError) { cells.charge_storage_value(second) }
    w186_storage_budget_counters(cells).should eq(before_cells)

    nodes_probe = w186_storage_budget
    nodes_probe.charge_storage_values([first, second])
    nodes = w186_storage_budget(max_nodes: nodes_probe.node_count - 1_u64)
    nodes.charge_storage_value(first)
    before_nodes = w186_storage_budget_counters(nodes)
    expect_raises(CrystalClick::BoundsError) { nodes.charge_storage_value(second) }
    w186_storage_budget_counters(nodes).should eq(before_nodes)

    elements = w186_storage_budget(max_elements: 1_u64)
    elements.charge_storage_value(first)
    before_elements = w186_storage_budget_counters(elements)
    expect_raises(CrystalClick::BoundsError) { elements.charge_storage_value(second) }
    w186_storage_budget_counters(elements).should eq(before_elements)
  end

  it "charges a storage Tuple wrapper at inherited depth without changing root Object defaults" do
    document = CrystalClick::ObjectDocument.new({
      "value" => CrystalClick::BinaryValue.uint64(9_u64),
    })
    legacy = w186_storage_budget
    legacy.charge_document(document)

    wrapped = w186_storage_budget
    wrapped.charge_storage_value(CrystalClick::StorageColumnValue.object_document(document))
    wrapped.string_payload_bytes.should eq(legacy.string_payload_bytes)
    wrapped.tuple_cells.should eq(legacy.tuple_cells)
    wrapped.element_count.should eq(legacy.element_count)
    wrapped.node_count.should eq(legacy.node_count + 1_u64)
    (wrapped.retained_logical_bytes - legacy.retained_logical_bytes).should eq(
      instance_sizeof(CrystalClick::StorageColumnValue).to_u64 +
      instance_sizeof(Array(CrystalClick::StorageColumnValue)).to_u64
    )

    nested = CrystalClick::StorageColumnValue.tuple([
      CrystalClick::StorageColumnValue.bulk(CrystalClick::BinaryValue.uint64(1_u64)),
    ] of CrystalClick::StorageColumnValue)
    shallow = w186_storage_budget(max_depth: 1)
    before = w186_storage_budget_counters(shallow)
    expect_raises(CrystalClick::BoundsError) { shallow.charge_storage_value(nested) }
    w186_storage_budget_counters(shallow).should eq(before)

    array_type = CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.primitive("String"))
    nested_document = CrystalClick::ObjectDocument.new({
      "items" => CrystalClick::BinaryValue.array(
        array_type,
        [CrystalClick::BinaryValue.string("x")] of CrystalClick::BinaryValue,
      ),
    })
    inherited = CrystalClick::StorageColumnValue.tuple([
      CrystalClick::StorageColumnValue.object_document(nested_document),
    ] of CrystalClick::StorageColumnValue)
    shallow_object = w186_storage_budget(max_depth: 2)
    before_object = w186_storage_budget_counters(shallow_object)
    expect_raises(CrystalClick::BoundsError) { shallow_object.charge_storage_value(inherited) }
    w186_storage_budget_counters(shallow_object).should eq(before_object)
  end
end
