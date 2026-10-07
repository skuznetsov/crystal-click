require "./spec_helper"

private def w207_json_value(
  type : CrystalClick::BinaryDataType,
  entries : Array(Tuple(String, CrystalClick::BinaryValue)),
) : CrystalClick::BinaryValue
  row = CrystalClick::BinaryJsonRow.new(type, entries)
  CrystalClick::BinaryValue.json(type, row)
end

private def w207_materialization_budget(
  logical_limit : UInt64 = UInt64::MAX,
  max_string_bytes : UInt64 = UInt64::MAX,
  max_tuple_cells : UInt64 = UInt64::MAX,
  max_nodes : UInt64 = UInt64::MAX,
  max_elements : UInt64 = UInt64::MAX,
  max_depth : Int32 = CrystalClick::ObjectValuesMaterializationBudget::DEFAULT_MAX_DEPTH,
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

private def w207_budget_snapshot(
  budget : CrystalClick::ObjectValuesMaterializationBudget,
) : Tuple(UInt64, UInt64, UInt64, UInt64, UInt64)
  {
    budget.retained_logical_bytes,
    budget.string_payload_bytes,
    budget.tuple_cells,
    budget.node_count,
    budget.element_count,
  }
end

describe CrystalClick::ObjectValuesMaterializationBudget do
  it "charges empty JSON type and row owner headers exactly" do
    value = w207_json_value(
      CrystalClick::BinaryDataType.json,
      [] of Tuple(String, CrystalClick::BinaryValue),
    )

    budget = w207_materialization_budget
    budget.charge_storage_value(CrystalClick::StorageColumnValue.bulk(value))

    # Empty owners still retain their nominal headers and backing arrays.
    # There are no row/roster slots, path Strings, or scalar payloads here.
    expected = instance_sizeof(Array(CrystalClick::OfflineColumnValue)).to_u64
    expected += instance_sizeof(CrystalClick::StorageColumnValue).to_u64
    expected += instance_sizeof(Array(CrystalClick::StorageColumnValue)).to_u64
    expected += instance_sizeof(CrystalClick::BinaryValue).to_u64
    expected += instance_sizeof(Array(CrystalClick::BinaryValue)).to_u64
    expected += instance_sizeof(CrystalClick::BinaryDataType).to_u64
    expected += instance_sizeof(Array(CrystalClick::BinaryDataType)).to_u64
    expected += instance_sizeof(Array(String)).to_u64
    expected += instance_sizeof(CrystalClick::BinaryJsonType).to_u64
    expected += instance_sizeof(Array(Tuple(String, CrystalClick::BinaryDataType))).to_u64
    expected += instance_sizeof(CrystalClick::BinaryJsonRow).to_u64
    expected += instance_sizeof(Array(Tuple(String, CrystalClick::BinaryValue))).to_u64

    budget.retained_logical_bytes.should eq(expected)
    budget.node_count.should eq(7_u64) # base result/schema plus five retained owners
    budget.tuple_cells.should eq(0_u64)
    budget.element_count.should eq(0_u64)
    budget.string_payload_bytes.should eq(0_u64)
  end

  it "matches the independent one-path JSON owner byte formula" do
    type = CrystalClick::BinaryDataType.json
    path = "n"
    value = w207_json_value(
      type,
      [{path, CrystalClick::BinaryValue.uint64(42_u64)}] of Tuple(String, CrystalClick::BinaryValue),
    )

    budget = w207_materialization_budget
    budget.charge_storage_value(CrystalClick::StorageColumnValue.bulk(value))

    # Reconstruct the retained logical owners directly from their public
    # representations. In particular, the JSON type/row headers and the
    # inline tuple slot are not derived from this budget's counters.
    expected = instance_sizeof(Array(CrystalClick::OfflineColumnValue)).to_u64
    expected += instance_sizeof(CrystalClick::StorageColumnValue).to_u64
    expected += instance_sizeof(Array(CrystalClick::StorageColumnValue)).to_u64

    expected += instance_sizeof(CrystalClick::BinaryValue).to_u64
    expected += instance_sizeof(Array(CrystalClick::BinaryValue)).to_u64
    expected += instance_sizeof(CrystalClick::BinaryDataType).to_u64
    expected += instance_sizeof(Array(CrystalClick::BinaryDataType)).to_u64
    expected += instance_sizeof(Array(String)).to_u64
    expected += instance_sizeof(CrystalClick::BinaryJsonType).to_u64
    expected += instance_sizeof(Array(Tuple(String, CrystalClick::BinaryDataType))).to_u64
    expected += instance_sizeof(CrystalClick::BinaryJsonRow).to_u64
    expected += instance_sizeof(Array(Tuple(String, CrystalClick::BinaryValue))).to_u64
    expected += sizeof(Tuple(String, CrystalClick::BinaryValue)).to_u64
    expected += instance_sizeof(String).to_u64 + path.bytesize.to_u64 + 1_u64

    # The retained row child is UInt64(42): one BinaryValue, its eight-byte
    # payload, one descriptor tree, and the retained primitive type-name String.
    expected += instance_sizeof(CrystalClick::BinaryValue).to_u64
    expected += instance_sizeof(Array(CrystalClick::BinaryValue)).to_u64
    expected += sizeof(UInt64).to_u64
    expected += instance_sizeof(CrystalClick::BinaryDataType).to_u64
    expected += instance_sizeof(Array(CrystalClick::BinaryDataType)).to_u64
    expected += instance_sizeof(Array(String)).to_u64
    expected += instance_sizeof(String).to_u64 + "UInt64".bytesize.to_u64 + 1_u64

    budget.retained_logical_bytes.should eq(expected)
    budget.node_count.should eq(11_u64)   # empty owners plus path, value, type and type name
    budget.element_count.should eq(1_u64) # one retained row tuple slot
    budget.string_payload_bytes.should eq(0_u64)
    budget.tuple_cells.should eq(1_u64)
  end

  it "charges JSON row path bytes as retained metadata, not String payload" do
    type = CrystalClick::BinaryDataType.json
    short_path = "x"
    long_path = "metadata"
    short_value = w207_json_value(
      type,
      [{short_path, CrystalClick::BinaryValue.uint64(7_u64)}] of Tuple(String, CrystalClick::BinaryValue),
    )
    long_value = w207_json_value(
      type,
      [{long_path, CrystalClick::BinaryValue.uint64(7_u64)}] of Tuple(String, CrystalClick::BinaryValue),
    )

    short_budget = w207_materialization_budget
    short_budget.charge_document(CrystalClick::ObjectDocument.new({"record" => short_value}))
    long_budget = w207_materialization_budget
    long_budget.charge_document(CrystalClick::ObjectDocument.new({"record" => long_value}))

    # The document path and scalar value are identical. Only the retained
    # BinaryJsonRow path String changes, so its logical-byte delta is literal.
    long_budget.retained_logical_bytes.should eq(
      short_budget.retained_logical_bytes + (long_path.bytesize - short_path.bytesize).to_u64,
    )
    {short_budget.string_payload_bytes, long_budget.string_payload_bytes}.should eq({0_u64, 0_u64})
  end

  it "charges typed JSON roster slots and descriptor owners even when row data matches" do
    path = "field"
    uint64_type = CrystalClick::BinaryDataType.primitive("UInt64")
    untyped_type = CrystalClick::BinaryDataType.json
    typed_type = CrystalClick::BinaryDataType.json(typed_paths: {path => uint64_type})
    untyped_value = w207_json_value(
      untyped_type,
      [{path, CrystalClick::BinaryValue.uint64(9_u64)}] of Tuple(String, CrystalClick::BinaryValue),
    )
    typed_value = w207_json_value(
      typed_type,
      [{path, CrystalClick::BinaryValue.uint64(9_u64)}] of Tuple(String, CrystalClick::BinaryValue),
    )

    untyped_budget = w207_materialization_budget
    untyped_budget.charge_storage_value(CrystalClick::StorageColumnValue.bulk(untyped_value))
    typed_budget = w207_materialization_budget
    typed_budget.charge_storage_value(CrystalClick::StorageColumnValue.bulk(typed_value))

    # The typed roster retains a separate slot, path String, and UInt64
    # descriptor tree in addition to the matching row-value descriptor.
    typed_descriptor_delta = sizeof(Tuple(String, CrystalClick::BinaryDataType)).to_u64
    typed_descriptor_delta += instance_sizeof(String).to_u64 + path.bytesize.to_u64 + 1_u64
    typed_descriptor_delta += instance_sizeof(CrystalClick::BinaryDataType).to_u64
    typed_descriptor_delta += instance_sizeof(Array(CrystalClick::BinaryDataType)).to_u64
    typed_descriptor_delta += instance_sizeof(Array(String)).to_u64
    typed_descriptor_delta += instance_sizeof(String).to_u64 + "UInt64".bytesize.to_u64 + 1_u64
    typed_budget.retained_logical_bytes.should eq(untyped_budget.retained_logical_bytes + typed_descriptor_delta)
    typed_budget.node_count.should eq(untyped_budget.node_count + 3_u64) # path, descriptor, primitive name
    typed_budget.element_count.should eq(untyped_budget.element_count + 1_u64)
    {typed_budget.string_payload_bytes, untyped_budget.string_payload_bytes}.should eq({0_u64, 0_u64})
    {typed_budget.tuple_cells, untyped_budget.tuple_cells}.should eq({1_u64, 1_u64})
  end

  it "retains typed Nullable NULL paths but omits untyped Nothing NULL paths" do
    untyped_type = CrystalClick::BinaryDataType.json
    nothing_row = CrystalClick::BinaryJsonRow.new(
      untyped_type,
      [{"omitted", CrystalClick::BinaryValue.null}] of Tuple(String, CrystalClick::BinaryValue),
    )
    empty_row = CrystalClick::BinaryJsonRow.new(untyped_type, [] of Tuple(String, CrystalClick::BinaryValue))
    nothing_row.path_count.should eq(0)
    nothing_value = CrystalClick::BinaryValue.json(untyped_type, nothing_row)
    empty_value = CrystalClick::BinaryValue.json(untyped_type, empty_row)
    nothing_value.should eq(empty_value)

    empty_budget = w207_materialization_budget
    empty_budget.charge_storage_value(CrystalClick::StorageColumnValue.bulk(empty_value))
    omitted_budget = w207_materialization_budget
    omitted_budget.charge_storage_value(CrystalClick::StorageColumnValue.bulk(nothing_value))
    w207_budget_snapshot(omitted_budget).should eq(w207_budget_snapshot(empty_budget))

    nullable_type = CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.primitive("UInt64"))
    typed_type = CrystalClick::BinaryDataType.json(typed_paths: {"maybe" => nullable_type})
    typed_null = CrystalClick::BinaryValue.nullable(nullable_type)
    typed_value = w207_json_value(
      typed_type,
      [{"maybe", typed_null}] of Tuple(String, CrystalClick::BinaryValue),
    )
    typed_value.json_row.path_count.should eq(1)
    typed_value.json_row.value_for("maybe").not_nil!.is_null?.should be_true

    typed_budget = w207_materialization_budget
    typed_budget.charge_document(CrystalClick::ObjectDocument.new({"record" => typed_value}))
    typed_budget.string_payload_bytes.should eq(0_u64)
    # One ObjectDocument path and one JSON row path are retained cells.
    typed_budget.tuple_cells.should eq(2_u64)
    typed_budget.node_count.should be > empty_budget.node_count
    typed_budget.element_count.should be > empty_budget.element_count
  end

  it "cumulatively charges sibling JSON rows and admits exact limits only" do
    uint8_type = CrystalClick::BinaryDataType.primitive("UInt8")
    string_type = CrystalClick::BinaryDataType.primitive("String")
    tuple_type = CrystalClick::BinaryDataType.tuple([uint8_type, string_type] of CrystalClick::BinaryDataType)
    json_type = CrystalClick::BinaryDataType.json(typed_paths: {"pair" => tuple_type})

    first_tuple = CrystalClick::BinaryValue.tuple(
      tuple_type,
      [
        CrystalClick::BinaryValue.fixed(uint8_type, Bytes[1_u8]),
        CrystalClick::BinaryValue.string("a"),
      ] of CrystalClick::BinaryValue,
    )
    second_tuple = CrystalClick::BinaryValue.tuple(
      tuple_type,
      [
        CrystalClick::BinaryValue.fixed(uint8_type, Bytes[2_u8]),
        CrystalClick::BinaryValue.string("bcd"),
      ] of CrystalClick::BinaryValue,
    )
    first = CrystalClick::StorageColumnValue.bulk(w207_json_value(
      json_type,
      [{"pair", first_tuple}] of Tuple(String, CrystalClick::BinaryValue),
    ))
    second = CrystalClick::StorageColumnValue.bulk(w207_json_value(
      json_type,
      [{"pair", second_tuple}] of Tuple(String, CrystalClick::BinaryValue),
    ))
    siblings = [first, second] of CrystalClick::StorageColumnValue

    probe = w207_materialization_budget
    probe.charge_storage_values(siblings)
    # These are literal value facts, not results inferred from the budget:
    # the two nested Strings contain 1 + 3 bytes; each retained JSON row path
    # contributes one cell, and each Tuple row contributes two more.
    probe.string_payload_bytes.should eq(4_u64)
    probe.tuple_cells.should eq(6_u64)
    probe.element_count.should be > 0_u64
    probe.node_count.should be > 2_u64

    exact = w207_materialization_budget(
      logical_limit: probe.retained_logical_bytes,
      max_string_bytes: 4_u64,
      max_tuple_cells: 6_u64,
      max_nodes: probe.node_count,
      max_elements: probe.element_count,
    )
    exact.charge_storage_values(siblings)
    w207_budget_snapshot(exact).should eq(w207_budget_snapshot(probe))

    # A cumulative sibling rejection must not retain either partial sibling
    # when both are charged as one mark.
    short_limits = [
      {probe.retained_logical_bytes - 1_u64, 4_u64, 6_u64, probe.node_count, probe.element_count},
      {probe.retained_logical_bytes, 3_u64, 6_u64, probe.node_count, probe.element_count},
      {probe.retained_logical_bytes, 4_u64, 5_u64, probe.node_count, probe.element_count},
      {probe.retained_logical_bytes, 4_u64, 6_u64, probe.node_count - 1_u64, probe.element_count},
      {probe.retained_logical_bytes, 4_u64, 6_u64, probe.node_count, probe.element_count - 1_u64},
    ] of Tuple(UInt64, UInt64, UInt64, UInt64, UInt64)
    short_limits.each do |limits|
      logical_limit, string_limit, cell_limit, node_limit, element_limit = limits
      short = w207_materialization_budget(
        logical_limit: logical_limit,
        max_string_bytes: string_limit,
        max_tuple_cells: cell_limit,
        max_nodes: node_limit,
        max_elements: element_limit,
      )
      before = w207_budget_snapshot(short)
      expect_raises(CrystalClick::BoundsError) { short.charge_storage_values(siblings) }
      w207_budget_snapshot(short).should eq(before)
    end

    cumulative = w207_materialization_budget(max_string_bytes: 3_u64)
    cumulative.charge_storage_value(first)
    before_second = w207_budget_snapshot(cumulative)
    expect_raises(CrystalClick::BoundsError) { cumulative.charge_storage_value(second) }
    w207_budget_snapshot(cumulative).should eq(before_second)
    cumulative.string_payload_bytes.should eq(1_u64)
  end

  it "inherits depth while descending through nested JSON rows" do
    inner_type = CrystalClick::BinaryDataType.json
    inner_value = w207_json_value(inner_type, [] of Tuple(String, CrystalClick::BinaryValue))
    outer_type = CrystalClick::BinaryDataType.json
    outer_value = w207_json_value(
      outer_type,
      [{"nested", inner_value}] of Tuple(String, CrystalClick::BinaryValue),
    )
    retained = CrystalClick::StorageColumnValue.bulk(outer_value)

    shallow = w207_materialization_budget(max_depth: 1)
    before = w207_budget_snapshot(shallow)
    expect_raises(CrystalClick::BoundsError) { shallow.charge_storage_value(retained) }
    w207_budget_snapshot(shallow).should eq(before)

    exact_depth = w207_materialization_budget(max_depth: 2)
    exact_depth.charge_storage_value(retained)
    exact_depth.node_count.should be > 2_u64
  end

  it "charges inherited depth for a typed descriptor under an unused Nullable(NULL)" do
    nested_json_type = CrystalClick::BinaryDataType.json(
      typed_paths: {"leaf" => CrystalClick::BinaryDataType.primitive("UInt64")},
    )
    nullable_nested_json = CrystalClick::BinaryDataType.nullable(nested_json_type)
    outer_type = CrystalClick::BinaryDataType.json(typed_paths: {"unused" => nullable_nested_json})
    outer_value = w207_json_value(
      outer_type,
      [{"unused", CrystalClick::BinaryValue.nullable(nullable_nested_json)}] of Tuple(String, CrystalClick::BinaryValue),
    )
    outer_value.json_row.path_count.should eq(1)
    outer_value.json_row.value_for("unused").not_nil!.is_null?.should be_true

    # The nullable payload has no nested JSON row, but its retained type
    # descriptor still owns the deeper JSON typed roster. Starting at the
    # root storage depth, that roster's UInt64 descriptor is depth four.
    shallow = w207_materialization_budget(max_depth: 3)
    before = w207_budget_snapshot(shallow)
    expect_raises(CrystalClick::BoundsError) do
      shallow.charge_storage_value(CrystalClick::StorageColumnValue.bulk(outer_value))
    end
    w207_budget_snapshot(shallow).should eq(before)

    exact_depth = w207_materialization_budget(max_depth: 4)
    exact_depth.charge_storage_value(CrystalClick::StorageColumnValue.bulk(outer_value))
    exact_depth.node_count.should be > 2_u64
  end

  it "charges distinct but structurally equal JSON row and value type owners separately" do
    path = "field"
    entries = [{path, CrystalClick::BinaryValue.uint64(9_u64)}] of Tuple(String, CrystalClick::BinaryValue)

    shared_type = CrystalClick::BinaryDataType.json(
      typed_paths: {path => CrystalClick::BinaryDataType.primitive("UInt64")},
    )
    shared_row = CrystalClick::BinaryJsonRow.new(shared_type, entries)
    shared_value = CrystalClick::BinaryValue.json(shared_type, shared_row)
    shared_row.type.same?(shared_value.type).should be_true

    value_type = CrystalClick::BinaryDataType.json(
      typed_paths: {path => CrystalClick::BinaryDataType.primitive("UInt64")},
    )
    row_type = CrystalClick::BinaryDataType.json(
      typed_paths: {path => CrystalClick::BinaryDataType.primitive("UInt64")},
    )
    value_type.should eq(row_type)
    value_type.same?(row_type).should be_false
    value_type.json_type.not_nil!.same?(row_type.json_type.not_nil!).should be_false
    value_type.json_type.not_nil!.typed_type_at(0).same?(row_type.json_type.not_nil!.typed_type_at(0)).should be_false

    distinct_row = CrystalClick::BinaryJsonRow.new(row_type, entries)
    distinct_value = CrystalClick::BinaryValue.json(value_type, distinct_row)
    distinct_value.type.should eq(distinct_value.json_row.type)
    distinct_value.type.same?(distinct_value.json_row.type).should be_false
    distinct_value.json_row.type.should eq(shared_value.json_row.type)
    distinct_value.json_row.entries.should eq(shared_value.json_row.entries)

    shared_budget = w207_materialization_budget
    shared_budget.charge_storage_value(CrystalClick::StorageColumnValue.bulk(shared_value))
    distinct_budget = w207_materialization_budget
    distinct_budget.charge_storage_value(CrystalClick::StorageColumnValue.bulk(distinct_value))

    # The row retains a second, equal-but-distinct descriptor tree. Count its
    # owners directly: root descriptor, JSON metadata/roster, copied path,
    # declared UInt64 descriptor, and copied primitive-name String. The JSON
    # row path/value and scalar payload are otherwise identical.
    extra_descriptor_bytes = instance_sizeof(CrystalClick::BinaryDataType).to_u64
    extra_descriptor_bytes += instance_sizeof(Array(CrystalClick::BinaryDataType)).to_u64
    extra_descriptor_bytes += instance_sizeof(Array(String)).to_u64
    extra_descriptor_bytes += instance_sizeof(CrystalClick::BinaryJsonType).to_u64
    extra_descriptor_bytes += instance_sizeof(Array(Tuple(String, CrystalClick::BinaryDataType))).to_u64
    extra_descriptor_bytes += sizeof(Tuple(String, CrystalClick::BinaryDataType)).to_u64
    extra_descriptor_bytes += instance_sizeof(String).to_u64 + path.bytesize.to_u64 + 1_u64
    extra_descriptor_bytes += instance_sizeof(CrystalClick::BinaryDataType).to_u64
    extra_descriptor_bytes += instance_sizeof(Array(CrystalClick::BinaryDataType)).to_u64
    extra_descriptor_bytes += instance_sizeof(Array(String)).to_u64
    extra_descriptor_bytes += instance_sizeof(String).to_u64 + "UInt64".bytesize.to_u64 + 1_u64
    extra_descriptor_nodes = 5_u64    # JSON root, JSON owner, roster path, UInt64, primitive name
    extra_descriptor_elements = 1_u64 # one typed-path roster tuple slot

    expected_bytes = shared_budget.retained_logical_bytes + extra_descriptor_bytes
    expected_nodes = shared_budget.node_count + extra_descriptor_nodes
    expected_elements = shared_budget.element_count + extra_descriptor_elements
    distinct_budget.retained_logical_bytes.should eq(expected_bytes)
    distinct_budget.node_count.should eq(expected_nodes)
    distinct_budget.element_count.should eq(expected_elements)
    distinct_budget.tuple_cells.should eq(shared_budget.tuple_cells)
    distinct_budget.string_payload_bytes.should eq(shared_budget.string_payload_bytes)

    exact = w207_materialization_budget(
      logical_limit: expected_bytes,
      max_nodes: expected_nodes,
      max_elements: expected_elements,
    )
    exact.charge_storage_value(CrystalClick::StorageColumnValue.bulk(distinct_value))
    w207_budget_snapshot(exact).should eq(w207_budget_snapshot(distinct_budget))

    short_limits = [
      {expected_bytes - 1_u64, expected_nodes, expected_elements},
      {expected_bytes, expected_nodes - 1_u64, expected_elements},
      {expected_bytes, expected_nodes, expected_elements - 1_u64},
    ] of Tuple(UInt64, UInt64, UInt64)
    short_limits.each do |limits|
      byte_limit, node_limit, element_limit = limits
      short = w207_materialization_budget(
        logical_limit: byte_limit,
        max_nodes: node_limit,
        max_elements: element_limit,
      )
      before = w207_budget_snapshot(short)
      expect_raises(CrystalClick::BoundsError) do
        short.charge_storage_value(CrystalClick::StorageColumnValue.bulk(distinct_value))
      end
      w207_budget_snapshot(short).should eq(before)
    end
  end
end
