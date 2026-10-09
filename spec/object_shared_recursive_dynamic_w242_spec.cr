require "./spec_helper"

private alias W242LeafBindings = Array(Tuple(
  CrystalClick::BinaryDynamicJsonLeafKey,
  CrystalClick::ObjectDocumentPlan,
))

private def w242_json_type : CrystalClick::BinaryDataType
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  CrystalClick::BinaryDataType.json(
    max_dynamic_paths: 1,
    max_dynamic_types: 1,
    typed_paths: {"v" => uint8} of String => CrystalClick::BinaryDataType,
  )
end

private def w242_json_value(type : CrystalClick::BinaryDataType, byte : UInt8) : CrystalClick::BinaryValue
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  row = CrystalClick::BinaryJsonRow.new(
    type,
    [{"v", CrystalClick::BinaryValue.fixed(uint8, Bytes[byte])}] of Tuple(String, CrystalClick::BinaryValue),
  )
  CrystalClick::BinaryValue.json(type, row)
end

private def w242_child_object_plan(
  json_type : CrystalClick::BinaryDataType,
  shared_data_version : UInt64 = 0_u64,
) : CrystalClick::ObjectDocumentPlan
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([] of String, shared_data_version: shared_data_version),
    {} of String => CrystalClick::DynamicStructure,
  )
  CrystalClick::ObjectDocumentPlan.new(structures, json_type.json_type.not_nil!.typed_paths)
end

private def w242_tuple_actual(
  json_type : CrystalClick::BinaryDataType,
  nested_cap : Int32 = 2,
) : CrystalClick::BinaryDataType
  nested = CrystalClick::BinaryDataType.dynamic(max_types: nested_cap)
  CrystalClick::BinaryDataType.tuple(
    [json_type, CrystalClick::BinaryDataType.array(nested)] of CrystalClick::BinaryDataType,
  )
end

private def w242_tuple_value(
  actual_type : CrystalClick::BinaryDataType,
  json_type : CrystalClick::BinaryDataType,
  string : String?,
) : CrystalClick::BinaryValue
  nested_type = actual_type.child_at(1).child_at(0)
  array_type = actual_type.child_at(1)
  nested = if value = string
             [CrystalClick::BinaryValue.dynamic(nested_type, CrystalClick::BinaryValue.string(value))] of CrystalClick::BinaryValue
           else
             [] of CrystalClick::BinaryValue
           end
  CrystalClick::BinaryValue.tuple(
    actual_type,
    [
      w242_json_value(json_type, 42_u8),
      CrystalClick::BinaryValue.array(array_type, nested),
    ] of CrystalClick::BinaryValue,
  )
end

private def w242_tuple_with_dynamic_values(
  actual_type : CrystalClick::BinaryDataType,
  json_type : CrystalClick::BinaryDataType,
  dynamic_values : Array(CrystalClick::BinaryValue),
) : CrystalClick::BinaryValue
  array_type = actual_type.child_at(1)
  CrystalClick::BinaryValue.tuple(
    actual_type,
    [
      w242_json_value(json_type, 42_u8),
      CrystalClick::BinaryValue.array(array_type, dynamic_values),
    ] of CrystalClick::BinaryValue,
  )
end

private def w242_wire_equal!(actual : CrystalClick::BinaryValue, expected : CrystalClick::BinaryValue) : Nil
  CrystalClick::BinaryValueCodec.encode(actual).should eq(CrystalClick::BinaryValueCodec.encode(expected))
end

private def w242_nested_setup : Tuple(
  CrystalClick::BinaryDataType,
  CrystalClick::BinaryDataType,
  CrystalClick::DynamicStructure,
  String,
  Hash(String, CrystalClick::DynamicStructure),
  W242LeafBindings,
  CrystalClick::ObjectDocumentPlan,
)
  json = w242_json_type
  actual = w242_tuple_actual(json)
  outer = CrystalClick::BinaryDataType.dynamic(max_types: 1)
  outer_structure = CrystalClick::DynamicStructure.new([actual] of CrystalClick::BinaryDataType)
  arm = outer_structure.canonical_index_for(actual)
  nested_site = "root.arm.#{arm}.field.1.elements"
  nested_structure = CrystalClick::DynamicStructure.new(
    [
      CrystalClick::BinaryDataType.primitive("Int64"),
      CrystalClick::BinaryDataType.primitive("String"),
    ] of CrystalClick::BinaryDataType,
  )
  structures = {
    "root"      => outer_structure,
    nested_site => nested_structure,
  } of String => CrystalClick::DynamicStructure
  plan = w242_child_object_plan(json)
  bindings = [{
    CrystalClick::BinaryDynamicJsonLeafKey.new("root", arm, [0_i32] of Int32),
    plan,
  }] of Tuple(CrystalClick::BinaryDynamicJsonLeafKey, CrystalClick::ObjectDocumentPlan)
  {json, actual, outer_structure, nested_site, structures, bindings, plan}
end

private def w242_u64_bytes(value : UInt64) : Bytes
  Bytes.new(8) do |index|
    ((value >> (index * 8)) & 0xff_u64).to_u8
  end
end

private def w242_var_uint(value : UInt64) : Bytes
  output = [] of UInt8
  remaining = value
  loop do
    payload = (remaining & 0x7f_u64).to_u8
    remaining >>= 7
    output << (remaining == 0_u64 ? payload : payload | 0x80_u8)
    break if remaining == 0_u64
  end
  Bytes.new(output.size) { |index| output[index] }
end

private def w242_concat(parts : Array(Bytes)) : Bytes
  size = parts.sum(&.size)
  output = Bytes.new(size)
  offset = 0
  parts.each do |part|
    part.each do |byte|
      output[offset] = byte
      offset += 1
    end
  end
  output
end

private def w242_frame(bytes : Bytes) : Bytes
  w242_concat([w242_var_uint(bytes.size.to_u64), bytes] of Bytes)
end

private def w242_copy_structure(path : String) : CrystalClick::ObjectSharedChunkStructure
  CrystalClick::ObjectSharedChunkStructure.new(
    1_u64,
    [path] of String,
    {0_u64, 0_u64},
    {0_u64, 0_u64},
    {0_u64, 0_u64},
  )
end

describe "W242 recursive Dynamic beside shared JSON" do
  it "reuses the generic paired path codec for Tuple(JSON, Array(Dynamic)) and empty occurrences" do
    json, actual, outer_structure, nested_site, structures, bindings, _plan = w242_nested_setup
    outer_type = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    actual_values = [
      w242_tuple_value(actual, json, "nested-a"),
      w242_tuple_value(actual, json, nil),
      w242_tuple_value(actual, json, "nested-b"),
      w242_tuple_value(actual, json, nil),
    ] of CrystalClick::BinaryValue
    expected = actual_values.map do |value|
      CrystalClick::BinaryValue.dynamic(outer_type, value)
    end
    expected << CrystalClick::BinaryValue.dynamic(outer_type)

    profile = CrystalClick::ObjectSharedPathCodec::COMPACT_PROFILE
    encoded = CrystalClick::ObjectSharedPathCodec.encode_with_json_children_with_budget(
      outer_type,
      structures,
      expected,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
      bindings,
      CrystalClick::ObjectSharedNestedSerializationContext.for_write(0_u64, 1, profile),
      profile,
    )
    decoded = CrystalClick::ObjectSharedPathCodec.decode_with_json_children_with_budget(
      encoded.data,
      encoded.events,
      expected.size,
      outer_type,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
      CrystalClick::ObjectSharedNestedSerializationContext.for_read(0_u64, profile),
      profile,
    )

    decoded.rows.size.should eq(expected.size)
    expected.each_with_index do |value, index|
      w242_wire_equal!(decoded.rows[index], value)
    end
    decoded.structures["root"].should eq(outer_structure)
    decoded.structures[nested_site].should eq(structures[nested_site])
  end

  it "prepares a JSON actual with a sibling Dynamic descriptor" do
    _json, actual, _outer_structure, _nested_site, _structures, _bindings, child_plan = w242_nested_setup

    prepared = CrystalClick::ObjectSharedAdvancedJsonActualPlan.new(
      actual,
      [{[0_i32] of Int32, child_plan}] of Tuple(Array(Int32), CrystalClick::ObjectDocumentPlan),
    )
    prepared.actual_type.should eq(actual)
    prepared.child_plan_count.should eq(1)
    prepared.child_descriptor_path_at(0).should eq([0_i32])
  end

  it "censuses descriptor-only nested sites and applies each Dynamic site's own cap" do
    json = w242_json_type
    actual = w242_tuple_actual(json, 1)
    outer_structure = CrystalClick::DynamicStructure.new([actual] of CrystalClick::BinaryDataType)
    nested_site = "root.arm.#{outer_structure.canonical_index_for(actual)}.field.1.elements"
    child_plan = w242_child_object_plan(json)
    prepared = CrystalClick::ObjectSharedAdvancedJsonActualPlan.new(
      actual,
      [{[0_i32] of Int32, child_plan}] of Tuple(Array(Int32), CrystalClick::ObjectDocumentPlan),
    )
    policy = CrystalClick::ObjectSharedAdvancedJsonWritePolicy.new(
      [prepared] of CrystalClick::ObjectSharedAdvancedJsonActualPlan,
      16,
    )
    int64 = CrystalClick::BinaryDataType.primitive("Int64")
    string = CrystalClick::BinaryDataType.primitive("String")
    nested_type = actual.child_at(1).child_at(0)
    values = [
      w242_tuple_with_dynamic_values(
        actual,
        json,
        [
          CrystalClick::BinaryValue.dynamic(
            nested_type,
            CrystalClick::BinaryValue.fixed(int64, Bytes[1_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8]),
          ),
          CrystalClick::BinaryValue.dynamic(nested_type, CrystalClick::BinaryValue.string("overflow")),
        ] of CrystalClick::BinaryValue,
      ),
      w242_tuple_value(actual, json, nil),
    ] of CrystalClick::BinaryValue

    all_empty = [
      w242_tuple_value(actual, json, nil),
      w242_tuple_value(actual, json, nil),
    ] of CrystalClick::BinaryValue

    census = CrystalClick::ObjectSharedDynamicSiteCensus.build(
      values.map { |value| value.as(CrystalClick::BinaryValue?) },
      [actual] of CrystalClick::BinaryDataType,
      policy,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
    )
    census.structures.keys.sort.should eq(["root", nested_site] of String)
    nested_structure = census.structures[nested_site]
    nested_structure.type_count.should eq(1)
    nested_structure.type_at(0).should eq(int64)
    nested_type.dynamic_max_types.should eq(1_u8)
    census.leaf_bindings.size.should eq(1)

    outer_type = CrystalClick::BinaryDataType.dynamic(max_types: 16)
    dynamic_rows = values.map do |value|
      CrystalClick::BinaryValue.dynamic(outer_type, value)
    end
    profile = CrystalClick::ObjectSharedPathCodec::COMPACT_PROFILE
    encoded = CrystalClick::ObjectSharedPathCodec.encode_with_json_children_with_budget(
      outer_type,
      census.structures,
      dynamic_rows,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
      census.leaf_bindings,
      CrystalClick::ObjectSharedNestedSerializationContext.for_write(0_u64, 1, profile),
      profile,
    )
    decoded = CrystalClick::ObjectSharedPathCodec.decode_with_json_children_with_budget(
      encoded.data,
      encoded.events,
      dynamic_rows.size,
      outer_type,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
      CrystalClick::ObjectSharedNestedSerializationContext.for_read(0_u64, profile),
      profile,
    )
    dynamic_rows.each_with_index do |expected, index|
      w242_wire_equal!(decoded.rows[index], expected)
    end

    # Exercise the production chunk owner too: it must construct one nested
    # site roster using the child's cap, then carry it through Data and Copy.
    # Standalone AdvancedChunkCodec roundtrips have no authenticated enclosing
    # Data lane, so keep this census/chunk control on a MAP child Object. The
    # production v2/v3 inline route is exercised through the physical-part
    # reader, which can provide authenticated callback coordinates.
    physical_child_plan = w242_child_object_plan(json, 1_u64)
    physical_actual = CrystalClick::ObjectSharedAdvancedJsonActualPlan.new(
      actual,
      [{[0_i32] of Int32, physical_child_plan}] of Tuple(Array(Int32), CrystalClick::ObjectDocumentPlan),
    )
    physical_policy = CrystalClick::ObjectSharedAdvancedJsonWritePolicy.new(
      [physical_actual] of CrystalClick::ObjectSharedAdvancedJsonActualPlan,
      16,
    )
    physical_rows = values.map do |value|
      CrystalClick::ObjectSharedMapRow.new([
        CrystalClick::ObjectSharedMapEntry.new("nested".to_slice, value),
      ] of CrystalClick::ObjectSharedMapEntry)
    end
    chunk = CrystalClick::ObjectSharedAdvancedChunkCodec.encode(
      physical_rows,
      1,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
      profile,
      physical_policy,
      CrystalClick::ObjectSharedNestedSerializationContext.for_write(1_u64, 1, profile),
    )
    decoded_rows = CrystalClick::ObjectSharedAdvancedChunkCodec.decode(
      chunk.buckets,
      chunk.copy_streams,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
      profile,
      CrystalClick::ObjectSharedNestedSerializationContext.for_read(1_u64, profile),
    )
    decoded_rows.size.should eq(physical_rows.size)
    physical_rows.each_with_index do |row, index|
      w242_wire_equal!(decoded_rows[index].entry_at(0).value, row.entry_at(0).value)
    end

    empty_physical_rows = all_empty.map do |value|
      CrystalClick::ObjectSharedMapRow.new([
        CrystalClick::ObjectSharedMapEntry.new("nested".to_slice, value),
      ] of CrystalClick::ObjectSharedMapEntry)
    end
    empty_chunk = CrystalClick::ObjectSharedAdvancedChunkCodec.encode(
      empty_physical_rows,
      1,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
      profile,
      physical_policy,
      CrystalClick::ObjectSharedNestedSerializationContext.for_write(1_u64, 1, profile),
    )
    empty_physical_decoded = CrystalClick::ObjectSharedAdvancedChunkCodec.decode(
      empty_chunk.buckets,
      empty_chunk.copy_streams,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
      profile,
      CrystalClick::ObjectSharedNestedSerializationContext.for_read(1_u64, profile),
    )
    empty_physical_decoded.size.should eq(empty_physical_rows.size)
    empty_physical_rows.each_with_index do |row, index|
      w242_wire_equal!(empty_physical_decoded[index].entry_at(0).value, row.entry_at(0).value)
    end

    # An advanced child cannot be decoded from a detached standalone chunk:
    # that path has no authenticated containing-Data coordinate context.
    advanced_child_plan = w242_child_object_plan(json, 2_u64)
    advanced_actual = CrystalClick::ObjectSharedAdvancedJsonActualPlan.new(
      actual,
      [{[0_i32] of Int32, advanced_child_plan}] of Tuple(Array(Int32), CrystalClick::ObjectDocumentPlan),
    )
    advanced_policy = CrystalClick::ObjectSharedAdvancedJsonWritePolicy.new(
      [advanced_actual] of CrystalClick::ObjectSharedAdvancedJsonActualPlan,
      16,
    )
    advanced_chunk = CrystalClick::ObjectSharedAdvancedChunkCodec.encode(
      physical_rows,
      1,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
      profile,
      advanced_policy,
      CrystalClick::ObjectSharedNestedSerializationContext.for_write(2_u64, 1, profile),
    )
    error = expect_raises(CrystalClick::CorruptPartError, "inline callback identity differs from its authenticated source schedule") do
      CrystalClick::ObjectSharedAdvancedChunkCodec.decode(
        advanced_chunk.buckets,
        advanced_chunk.copy_streams,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
        profile,
        CrystalClick::ObjectSharedNestedSerializationContext.for_read(2_u64, profile),
      )
    end
    error.message.to_s.should contain("authenticated source schedule")

    empty_census = CrystalClick::ObjectSharedDynamicSiteCensus.build(
      all_empty.map { |value| value.as(CrystalClick::BinaryValue?) },
      [actual] of CrystalClick::BinaryDataType,
      policy,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
    )
    empty_census.structures.keys.sort.should eq(["root", nested_site] of String)
    empty_census.structures[nested_site].type_count.should eq(0)
    empty_census.leaf_bindings.size.should eq(1)

    empty_rows = all_empty.map do |value|
      CrystalClick::BinaryValue.dynamic(outer_type, value)
    end
    empty_encoded = CrystalClick::ObjectSharedPathCodec.encode_with_json_children_with_budget(
      outer_type,
      empty_census.structures,
      empty_rows,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
      empty_census.leaf_bindings,
      CrystalClick::ObjectSharedNestedSerializationContext.for_write(0_u64, 1, profile),
      profile,
    )
    empty_decoded = CrystalClick::ObjectSharedPathCodec.decode_with_json_children_with_budget(
      empty_encoded.data,
      empty_encoded.events,
      empty_rows.size,
      outer_type,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
      CrystalClick::ObjectSharedNestedSerializationContext.for_read(0_u64, profile),
      profile,
    )
    empty_rows.each_with_index do |expected, index|
      w242_wire_equal!(empty_decoded.rows[index], expected)
    end
  end

  it "keeps a zero-cap nested Dynamic site empty and spills non-JSON children through SharedVariant" do
    json = w242_json_type
    actual = w242_tuple_actual(json, 0)
    nested_type = actual.child_at(1).child_at(0)
    child_plan = w242_child_object_plan(json)
    prepared = CrystalClick::ObjectSharedAdvancedJsonActualPlan.new(
      actual,
      [{[0_i32] of Int32, child_plan}] of Tuple(Array(Int32), CrystalClick::ObjectDocumentPlan),
    )
    policy = CrystalClick::ObjectSharedAdvancedJsonWritePolicy.new(
      [prepared] of CrystalClick::ObjectSharedAdvancedJsonActualPlan,
      16,
    )
    int64 = CrystalClick::BinaryDataType.primitive("Int64")
    nested_values = [
      CrystalClick::BinaryValue.dynamic(
        nested_type,
        CrystalClick::BinaryValue.fixed(int64, Bytes[1_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8]),
      ),
      CrystalClick::BinaryValue.dynamic(nested_type, CrystalClick::BinaryValue.string("overflow")),
      CrystalClick::BinaryValue.dynamic(nested_type),
    ] of CrystalClick::BinaryValue
    actual_value = w242_tuple_with_dynamic_values(actual, json, nested_values)
    root_structure = CrystalClick::DynamicStructure.new([actual] of CrystalClick::BinaryDataType)
    nested_site = "root.arm.#{root_structure.canonical_index_for(actual)}.field.1.elements"
    outer_type = CrystalClick::BinaryDataType.dynamic(max_types: 16)
    rows = [
      CrystalClick::BinaryValue.dynamic(outer_type, actual_value),
      CrystalClick::BinaryValue.dynamic(outer_type),
    ] of CrystalClick::BinaryValue
    census = CrystalClick::ObjectSharedDynamicSiteCensus.build(
      [actual_value] of CrystalClick::BinaryValue?,
      [actual] of CrystalClick::BinaryDataType,
      policy,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
    )

    census.structures.keys.sort.should eq(["root", nested_site] of String)
    census.structures[nested_site].type_count.should eq(0)
    census.leaf_bindings.size.should eq(1)

    profile = CrystalClick::ObjectSharedPathCodec::COMPACT_PROFILE
    encoded = CrystalClick::ObjectSharedPathCodec.encode_with_json_children_with_budget(
      outer_type,
      census.structures,
      rows,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
      census.leaf_bindings,
      CrystalClick::ObjectSharedNestedSerializationContext.for_write(0_u64, 1, profile),
      profile,
    )
    decoded = CrystalClick::ObjectSharedPathCodec.decode_with_json_children_with_budget(
      encoded.data,
      encoded.events,
      rows.size,
      outer_type,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
      CrystalClick::ObjectSharedNestedSerializationContext.for_read(0_u64, profile),
      profile,
    )
    rows.each_with_index do |expected, index|
      w242_wire_equal!(decoded.rows[index], expected)
    end
  end

  it "rejects a prepared JSON-bearing nested actual when its Dynamic site has cap zero" do
    json = w242_json_type
    actual = w242_tuple_actual(json, 0)
    nested_type = actual.child_at(1).child_at(0)
    nested_json_actual = CrystalClick::BinaryDataType.tuple([json] of CrystalClick::BinaryDataType)
    nested_plan = w242_child_object_plan(json)
    prepared_actual = CrystalClick::ObjectSharedAdvancedJsonActualPlan.new(
      actual,
      [{[0_i32] of Int32, w242_child_object_plan(json)}] of Tuple(Array(Int32), CrystalClick::ObjectDocumentPlan),
    )
    prepared_nested_json = CrystalClick::ObjectSharedAdvancedJsonActualPlan.new(
      nested_json_actual,
      [{[0_i32] of Int32, nested_plan}] of Tuple(Array(Int32), CrystalClick::ObjectDocumentPlan),
    )
    policy = CrystalClick::ObjectSharedAdvancedJsonWritePolicy.new(
      [prepared_actual, prepared_nested_json] of CrystalClick::ObjectSharedAdvancedJsonActualPlan,
      16,
    )
    nested_json_value = CrystalClick::BinaryValue.tuple(
      nested_json_actual,
      [w242_json_value(json, 7_u8)] of CrystalClick::BinaryValue,
    )
    actual_value = w242_tuple_with_dynamic_values(
      actual,
      json,
      [CrystalClick::BinaryValue.dynamic(nested_type, nested_json_value)] of CrystalClick::BinaryValue,
    )

    error = expect_raises(
      CrystalClick::UnsupportedFormatError,
      "prepared JSON actual roster exceeds its Dynamic descriptor cap",
    ) do
      CrystalClick::ObjectSharedDynamicSiteCensus.build(
        [actual_value] of CrystalClick::BinaryValue?,
        [actual] of CrystalClick::BinaryDataType,
        policy,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
      )
    end
    error.message.to_s.should contain("Dynamic descriptor cap")
  end

  it "rejects an over-budget site roster before allocating its root structure" do
    json, actual, _outer_structure, _nested_site, _structures, _bindings, child_plan = w242_nested_setup
    prepared = CrystalClick::ObjectSharedAdvancedJsonActualPlan.new(
      actual,
      [{[0_i32] of Int32, child_plan}] of Tuple(Array(Int32), CrystalClick::ObjectDocumentPlan),
    )
    policy = CrystalClick::ObjectSharedAdvancedJsonWritePolicy.new(
      [prepared] of CrystalClick::ObjectSharedAdvancedJsonActualPlan,
    )
    low_elements = CrystalClick::BinaryCodecLimits.new(64, 4_096, 0, 1_024)
    element_budget = CrystalClick::BinaryCodecBudget.new(low_elements, true)
    error = expect_raises(CrystalClick::UnsupportedFormatError, "element limit") do
      CrystalClick::ObjectSharedDynamicSiteCensus.build(
        [w242_tuple_value(actual, json, nil)] of CrystalClick::BinaryValue?,
        [actual] of CrystalClick::BinaryDataType,
        policy,
        element_budget,
      )
    end
    error.message.to_s.should contain("element")
    element_budget.node_count.should eq(0_i64)
    element_budget.element_count.should eq(0_i64)

    low_nodes = CrystalClick::BinaryCodecLimits.new(64, 0, 16, 1_024)
    node_budget = CrystalClick::BinaryCodecBudget.new(low_nodes, true)
    expect_raises(CrystalClick::UnsupportedFormatError, "node limit") do
      CrystalClick::ObjectSharedDynamicSiteCensus.build(
        [w242_tuple_value(actual, json, nil)] of CrystalClick::BinaryValue?,
        [actual] of CrystalClick::BinaryDataType,
        policy,
        node_budget,
      )
    end
    node_budget.node_count.should eq(0_i64)
    node_budget.element_count.should eq(1_i64)
  end

  it "requires the nested Dynamic site's structure separately from the outer actual roster" do
    _json, actual, _outer_structure, nested_site, structures, bindings, _plan = w242_nested_setup
    outer_type = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    root_only = {"root" => structures["root"]} of String => CrystalClick::DynamicStructure

    missing = expect_raises(ArgumentError) do
      CrystalClick::BinaryDynamicBulkPlan.new_with_prefix_without_statistics(
        outer_type,
        root_only,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
        CrystalClick::ObjectSharedPathCodec::COMPACT_PROFILE,
        bindings,
      )
    end
    missing.message.to_s.should contain(nested_site)

    plan = CrystalClick::BinaryDynamicBulkPlan.new_with_prefix_without_statistics(
      outer_type,
      structures,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
      CrystalClick::ObjectSharedPathCodec::COMPACT_PROFILE,
      bindings,
    )
    plan.site_paths.should eq(["root", nested_site] of String)
    actual.contains_dynamic?.should be_true
  end

  it "admits a Dynamic sibling in the shared MAP envelope without widening Copy ownership" do
    json, actual, _outer_structure, _nested_site, _structures, _bindings, _plan = w242_nested_setup
    value = w242_tuple_value(actual, json, "map-envelope")
    row = CrystalClick::ObjectSharedMapRow.new([
      CrystalClick::ObjectSharedMapEntry.new("x".to_slice, value),
    ] of CrystalClick::ObjectSharedMapEntry)

    encoded = CrystalClick::ObjectSharedMapCodec.encode([row] of CrystalClick::ObjectSharedMapRow)
    decoded = CrystalClick::ObjectSharedMapCodec.decode(encoded.sizes, encoded.paths, encoded.values, 1)
    w242_wire_equal!(decoded[0].entry_at(0).value, value)
  end

  it "restores the JSON-payload ancestry fence after an exceptional scoped visit" do
    limits = CrystalClick::BinaryCodecLimits.default
    budget = CrystalClick::BinaryCodecBudget.new(limits, true)
    context = CrystalClick::BinaryCodecContext.new(
      limits,
      nil,
      true,
      budget,
      false,
      false,
      shared_json_envelope_policy: true,
    )
    context.inside_shared_json_payload?.should be_false
    expect_raises(ArgumentError, "scope sentinel") do
      context.with_shared_json_payload_scope do
        context.inside_shared_json_payload?.should be_true
        raise ArgumentError.new("scope sentinel")
      end
    end
    context.inside_shared_json_payload?.should be_false
  end

  it "keeps Dynamic descriptors inside JSON runtime paths outside the MAP exception" do
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    array_type = CrystalClick::BinaryDataType.array(dynamic_type)
    json_type = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 1,
      max_dynamic_types: 1,
      typed_paths: {} of String => CrystalClick::BinaryDataType,
    )
    array = CrystalClick::BinaryValue.array(
      array_type,
      [CrystalClick::BinaryValue.dynamic(dynamic_type, CrystalClick::BinaryValue.string("runtime"))] of CrystalClick::BinaryValue,
    )
    row = CrystalClick::BinaryJsonRow.new(
      json_type,
      [{"runtime", array}] of Tuple(String, CrystalClick::BinaryValue),
    )
    value = CrystalClick::BinaryValue.json(json_type, row)
    ordinary_wire = CrystalClick::BinaryValueCodec.encode(value)

    expect_raises(CrystalClick::UnsupportedFormatError, "Dynamic") do
      CrystalClick::BinaryValueCodec.encode_shared_json_envelope(
        value,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError, "Dynamic") do
      CrystalClick::BinaryValueCodec.decode_shared_json_envelope(
        ordinary_wire,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
      )
    end
  end

  it "accepts the same nested value in specialized Copy and preserves scalar Dynamic wire bytes" do
    json, actual, _outer_structure, _nested_site, _structures, _bindings, _plan = w242_nested_setup
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    value = CrystalClick::BinaryValue.dynamic(dynamic_type, w242_tuple_value(actual, json, "copy-value"))
    entry = CrystalClick::ObjectSharedMapEntry.new("x".to_slice, value)
    row = CrystalClick::ObjectSharedMapRow.new([entry] of CrystalClick::ObjectSharedMapEntry)
    bucket = w242_copy_structure("x")
    encoded = CrystalClick::ObjectSharedCopyCodec.encode(
      [row] of CrystalClick::ObjectSharedMapRow,
      [bucket] of CrystalClick::ObjectSharedChunkStructure,
    )
    decoded = CrystalClick::ObjectSharedCopyCodec.decode(
      encoded.sizes,
      encoded.indexes,
      encoded.values,
      [bucket] of CrystalClick::ObjectSharedChunkStructure,
    )
    w242_wire_equal!(decoded[0].entry_at(0).value, value)

    scalar_dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    scalar_dynamic = CrystalClick::BinaryValue.dynamic(
      scalar_dynamic_type,
      CrystalClick::BinaryValue.string("wire-compatible"),
    )
    ordinary_wire = CrystalClick::BinaryValueCodec.encode(scalar_dynamic)
    shared_child_wire = CrystalClick::BinaryValueCodec.encode_dynamic_bulk_child(
      scalar_dynamic,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
      1,
    )
    shared_child_wire.should eq(ordinary_wire)
    decoded_type, decoded_value = CrystalClick::BinaryValueCodec.decode_dynamic_bulk_child(
      shared_child_wire,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
      1,
    )
    decoded_type.should eq(scalar_dynamic_type)
    w242_wire_equal!(decoded_value.not_nil!, scalar_dynamic)
  end

  it "decodes BinaryValueCodec-authored shared MAP wire for the target descriptor" do
    json, actual, _outer_structure, _nested_site, _structures, _bindings, _plan = w242_nested_setup
    value = w242_tuple_value(actual, json, "independent-map-wire")
    envelope = CrystalClick::BinaryValueCodec.encode(value)
    sizes = w242_u64_bytes(1_u64)
    paths = Bytes[0x01_u8, 0x78_u8]
    values = w242_frame(envelope)

    decoded = CrystalClick::ObjectSharedMapCodec.decode(sizes, paths, values, 1)
    w242_wire_equal!(decoded[0].entry_at(0).value, value)
  end
end
