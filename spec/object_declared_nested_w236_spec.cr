require "./spec_helper"

private def w236_nested_limits(depth = 64, nodes = 4096, elements = 4096, bytes = 65536)
  CrystalClick::BinaryCodecLimits.new(max_depth: depth, max_nodes: nodes, max_elements: elements, max_bytes: bytes)
end

private def w236_nested_record(type : CrystalClick::BinaryDataType, tag : UInt8, label : String) : CrystalClick::BinaryValue
  tuple_type = CrystalClick::BinaryNestedType.tuple_for(type)
  CrystalClick::BinaryValue.tuple(
    tuple_type,
    [
      CrystalClick::BinaryValue.fixed(type.child_at(0).child_at(0), Bytes[tag]),
      CrystalClick::BinaryValue.string(label),
    ] of CrystalClick::BinaryValue,
  )
end

private def w236_nested_value(
  type : CrystalClick::BinaryDataType,
  rows : Array(Tuple(UInt8, String)),
) : CrystalClick::BinaryValue
  records = Array(CrystalClick::BinaryValue).new(rows.size)
  rows.each { |row| records << w236_nested_record(type, row[0], row[1]) }
  CrystalClick::BinaryValue.nested(type, records)
end

private def w236_nested_structures : CrystalClick::ObjectDynamicStructureSet
  CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([] of String),
    {} of String => CrystalClick::DynamicStructure,
  )
end

describe "W236 nominal Nested in declared Object JSON fields" do
  it "accounts the implicit named Tuple and its metadata at exact recursion boundaries" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    string = CrystalClick::BinaryDataType.primitive("String")
    nested = CrystalClick::BinaryDataType.nested(
      [uint8, string] of CrystalClick::BinaryDataType,
      ["tag", "label"] of String,
    )
    declaration = "JSON(events Nested(tag UInt8, label String))"
    descriptor_limits = w236_nested_limits(depth: 3, nodes: 6, elements: 5, bytes: 47)

    metrics = CrystalClick::ObjectRecursiveDeclaration.measure_descriptor(nested, descriptor_limits).not_nil!
    metrics.byte_size.should eq(31_u64)
    {metrics.descriptor_node_count, metrics.metadata_edge_count}.should eq({4_u64, 2_u64})
    {metrics.child_edge_count, metrics.total_node_count, metrics.total_edge_count}.should eq({3_u64, 6_u64, 5_u64})
    {metrics.max_depth, metrics.tuple_name_count, metrics.tuple_name_bytes}.should eq({3, 2_u64, 8_u64})

    nested_name = nested.name
    bytes = nested_name.to_slice
    preflight = CrystalClick::ObjectRecursiveDeclaration.preflight_slice(
      bytes, 0, bytes.size, descriptor_limits,
    ).not_nil!
    {preflight.metrics.byte_size, preflight.metrics.descriptor_node_count,
     preflight.metrics.child_edge_count, preflight.metrics.metadata_edge_count,
     preflight.metrics.tuple_name_count, preflight.metrics.tuple_name_bytes,
     preflight.metrics.max_depth}.should eq({
      metrics.byte_size, metrics.descriptor_node_count,
      metrics.child_edge_count, metrics.metadata_edge_count,
      metrics.tuple_name_count, metrics.tuple_name_bytes,
      metrics.max_depth,
    })
    preflight.materialize.should eq(nested)

    schema_limits = w236_nested_limits(depth: 4, nodes: 7, elements: 6)
    CrystalClick::ObjectDocumentSchema.new({"events" => nested}, limits: schema_limits).declaration.should eq(declaration)
    CrystalClick::ObjectDocumentSchema.parse_declaration(declaration, schema_limits).typed_paths.should eq({"events" => nested})

    [
      w236_nested_limits(depth: 2, nodes: 6, elements: 5, bytes: 47),
      w236_nested_limits(depth: 3, nodes: 5, elements: 5, bytes: 47),
      w236_nested_limits(depth: 3, nodes: 6, elements: 4, bytes: 47),
      w236_nested_limits(depth: 3, nodes: 6, elements: 5, bytes: 46),
    ].each do |one_short|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectRecursiveDeclaration.measure_descriptor(nested, one_short)
      end
    end

    [
      w236_nested_limits(depth: 3, nodes: 7, elements: 6),
      w236_nested_limits(depth: 4, nodes: 6, elements: 6),
      w236_nested_limits(depth: 4, nodes: 7, elements: 5),
    ].each do |one_short|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentSchema.new({"events" => nested}, limits: one_short)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentSchema.parse_declaration(declaration, one_short)
      end
    end

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectRecursiveDeclaration.preflight_slice(
        bytes, 0, bytes.size, w236_nested_limits(bytes: 46),
      )
    end
  end

  it "revalidates borrowed Nested source and forged recursive totals before charging" do
    limits = w236_nested_limits
    bytes = "Nested(a UInt8, b String)".to_slice.dup
    preflight = CrystalClick::ObjectRecursiveDeclaration.preflight_slice(bytes, 0, bytes.size, limits).not_nil!

    # Same-size canonical edits are the current borrowed source, not a snapshot.
    bytes[7] = 'c'.ord.to_u8
    changed = CrystalClick::BinaryDataType.nested(
      [
        CrystalClick::BinaryDataType.primitive("UInt8"),
        CrystalClick::BinaryDataType.primitive("String"),
      ] of CrystalClick::BinaryDataType,
      ["c", "b"] of String,
    )
    preflight.materialize.should eq(changed)

    actual_name = "Nested(a UInt8, b String)"
    actual = CrystalClick::ObjectRecursiveDeclaration.preflight_slice(
      actual_name.to_slice, 0, actual_name.bytesize, limits,
    ).not_nil!
    forged = CrystalClick::ObjectRecursiveDeclaration::Preflight.new(
      actual.byte_size,
      actual.descriptor_node_count - 1_u64,
      actual.child_edge_count,
      actual.metadata_edge_count,
      actual.enum_entry_count,
      actual.decoded_label_bytes,
      actual.explicit_zone_bytes,
      actual.tuple_name_count,
      actual.tuple_name_bytes,
      actual.max_depth,
      actual.root_depth,
      actual.source,
      actual.first,
      actual.after,
      actual.limits,
    )
    expect_raises(ArgumentError) { forged.materialize }
    budget = CrystalClick::BinaryCodecBudget.new(limits, true)
    expect_raises(ArgumentError) { forged.account(budget) }
    {budget.node_count, budget.element_count, budget.wire_byte_count}.should eq({0_i64, 0_i64, 0_i64})
  end

  it "retains nominal Nested through Array, named Tuple, Map, and Variant Object lanes" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    string = CrystalClick::BinaryDataType.primitive("String")
    nested = CrystalClick::BinaryDataType.nested(
      [uint8, string] of CrystalClick::BinaryDataType,
      ["tag", "label"] of String,
    )
    nested_name = nested.name
    array_type = CrystalClick::BinaryDataType.array(nested)
    tuple_type = CrystalClick::BinaryDataType.tuple(
      [nested] of CrystalClick::BinaryDataType,
      ["events"] of String,
    )
    map_type = CrystalClick::BinaryDataType.map(string, nested)
    variant_type = CrystalClick::BinaryDataType.variant(
      [nested, string] of CrystalClick::BinaryDataType,
    )
    nested_arm = variant_type.children.index(nested).not_nil!

    fields = {
      "array"  => array_type,
      "choice" => variant_type,
      "direct" => nested,
      "lookup" => map_type,
      "record" => tuple_type,
    } of String => CrystalClick::BinaryDataType
    declaration = "JSON(array Array(#{nested_name}), choice Variant(#{nested_name}, String), " +
                  "direct #{nested_name}, lookup Map(String, #{nested_name}), " +
                  "record Tuple(events #{nested_name}))"
    schema = CrystalClick::ObjectDocumentSchema.new(fields)
    schema.declaration.should eq(declaration)
    parsed = CrystalClick::ObjectDocumentSchema.parse_declaration(declaration)
    parsed.declaration.should eq(declaration)
    parsed.typed_paths.should eq(fields)

    many = w236_nested_value(nested, [{7_u8, "seven"}, {8_u8, "eight"}] of Tuple(UInt8, String))
    empty = w236_nested_value(nested, [] of Tuple(UInt8, String))
    array_first = CrystalClick::BinaryValue.array(array_type, [many, empty] of CrystalClick::BinaryValue)
    array_second = CrystalClick::BinaryValue.array(array_type, [empty] of CrystalClick::BinaryValue)
    tuple_first = CrystalClick::BinaryValue.tuple(tuple_type, [many] of CrystalClick::BinaryValue)
    tuple_second = CrystalClick::BinaryValue.tuple(tuple_type, [empty] of CrystalClick::BinaryValue)
    map_first = CrystalClick::BinaryValue.map(
      map_type,
      [CrystalClick::BinaryValue.string("first"), many, CrystalClick::BinaryValue.string("empty"), empty] of CrystalClick::BinaryValue,
    )
    map_second = CrystalClick::BinaryValue.map(
      map_type,
      [CrystalClick::BinaryValue.string("empty"), empty] of CrystalClick::BinaryValue,
    )
    choice_first = CrystalClick::BinaryValue.variant(variant_type, nested_arm, many)
    choice_second = CrystalClick::BinaryValue.variant(variant_type, nested_arm, empty)

    first = CrystalClick::ObjectDocument.new({
      "array"  => array_first,
      "choice" => choice_first,
      "direct" => many,
      "lookup" => map_first,
      "record" => tuple_first,
    } of String => CrystalClick::BinaryValue)
    second = CrystalClick::ObjectDocument.new({
      "array"  => array_second,
      "choice" => choice_second,
      "direct" => empty,
      "lookup" => map_second,
      "record" => tuple_second,
    } of String => CrystalClick::BinaryValue)
    plan = CrystalClick::ObjectDocumentPlan.new(w236_nested_structures, parsed.typed_paths)
    streams = CrystalClick::ObjectDocumentCodec.encode(
      plan,
      [[first, second] of CrystalClick::ObjectDocument],
    )
    decoded = CrystalClick::ObjectDocumentCodec.decode(parsed.typed_paths, streams)

    decoded.size.should eq(1)
    decoded[0].size.should eq(2)
    restored_many = decoded[0][0].value_for("direct")
    restored_many.type.should eq(nested)
    restored_many.type.name.should eq(nested_name)
    restored_many.element_count.should eq(2)
    restored_many.element_at(0).type.should eq(nested.child_at(0))
    restored_many.element_at(0).type.field_name_at(0).should eq("tag")
    restored_many.element_at(0).type.field_name_at(1).should eq("label")
    restored_many.element_at(0).element_at(0).bytes.should eq(Bytes[7_u8])
    restored_many.element_at(0).element_at(1).as_string.should eq("seven")

    restored_array = decoded[0][0].value_for("array")
    restored_array.element_count.should eq(2)
    restored_array.element_at(0).type.should eq(nested)
    restored_array.element_at(0).element_count.should eq(2)
    restored_array.element_at(1).element_count.should eq(0)
    decoded[0][0].value_for("record").child_at(0).type.should eq(nested)
    decoded[0][0].value_for("lookup").child_count.should eq(4)
    decoded[0][0].value_for("lookup").child_at(1).type.should eq(nested)
    decoded[0][0].value_for("choice").variant_index?.should eq(nested_arm.to_u8)
    decoded[0][0].value_for("choice").variant_child?.not_nil!.type.should eq(nested)

    decoded[0][1].value_for("direct").type.should eq(nested)
    decoded[0][1].value_for("direct").element_count.should eq(0)
    decoded[0][1].value_for("array").element_count.should eq(1)
    decoded[0][1].value_for("array").element_at(0).element_count.should eq(0)
    decoded[0][1].value_for("record").child_at(0).element_count.should eq(0)
    decoded[0][1].value_for("lookup").child_count.should eq(2)
    decoded[0][1].value_for("choice").variant_child?.not_nil!.element_count.should eq(0)

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentCodec.encode(plan, [[CrystalClick::ObjectDocument.new({} of String => CrystalClick::BinaryValue)]] of Array(CrystalClick::ObjectDocument))
    end
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentCodec.encode(plan, [[] of CrystalClick::ObjectDocument])
    end
  end

  it "uses the canonical named-Tuple field spelling inside Nested declarations" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    string = CrystalClick::BinaryDataType.primitive("String")
    nested = CrystalClick::BinaryDataType.nested(
      [uint8, string] of CrystalClick::BinaryDataType,
      ["payload key", "select"] of String,
    )
    nested_name = "Nested(`payload key` UInt8, `select` String)"

    nested.name.should eq(nested_name)
    schema = CrystalClick::ObjectDocumentSchema.new({"quoted" => nested})
    schema.declaration.should eq("JSON(quoted #{nested_name})")
    parsed = CrystalClick::ObjectDocumentSchema.parse_declaration(schema.declaration)
    parsed.typed_paths.should eq({"quoted" => nested})
  end

  it "keeps malformed names and unsupported Nested intersections outside Object admission" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    string = CrystalClick::BinaryDataType.primitive("String")
    nested = CrystalClick::BinaryDataType.nested(
      [uint8, string] of CrystalClick::BinaryDataType,
      ["tag", "label"] of String,
    )
    qbit = CrystalClick::BinaryDataType.qbit(CrystalClick::QBitType.new("Int8", 9_u64))
    nested_qbit = CrystalClick::BinaryDataType.nested(
      [qbit, uint8] of CrystalClick::BinaryDataType,
      ["bits", "tag"] of String,
    )
    variant_qbit = CrystalClick::BinaryDataType.variant(
      [nested_qbit, string] of CrystalClick::BinaryDataType,
    )
    nested_dynamic = CrystalClick::BinaryDataType.nested(
      [CrystalClick::BinaryDataType.dynamic] of CrystalClick::BinaryDataType,
      ["value"] of String,
    )
    nested_dynamic_array = CrystalClick::BinaryDataType.array(nested_dynamic)
    nested_dynamic_tuple = CrystalClick::BinaryDataType.tuple(
      [nested_dynamic] of CrystalClick::BinaryDataType,
      ["payload"] of String,
    )
    nested_dynamic_map = CrystalClick::BinaryDataType.map(string, nested_dynamic)
    nested_dynamic_variant = CrystalClick::BinaryDataType.variant(
      [nested_dynamic, string] of CrystalClick::BinaryDataType,
    )

    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.nullable(nested) }
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.low_cardinality(nested) }
    [nested_qbit, variant_qbit, nested_dynamic, nested_dynamic_array, nested_dynamic_tuple,
     nested_dynamic_map, nested_dynamic_variant].each do |unsupported|
      expect_raises(ArgumentError) { CrystalClick::ObjectDocumentSchema.new({"payload" => unsupported}) }
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(payload #{unsupported.name})")
      end
    end

    [
      "JSON(payload Nested(UInt8))",
      "JSON(payload Nested())",
      "JSON(payload Nested(a UInt8, a String))",
      "JSON(payload Nested(null UInt8, label String))",
      "JSON(payload Nested(a UInt8, String))",
      "JSON(payload Nullable(Nested(tag UInt8, label String)))",
      "JSON(payload LowCardinality(Nested(tag UInt8, label String)))",
      "JSON(payload SimpleAggregateFunction(anyLast, Nested(tag UInt8)))",
      "JSON(payload Variant(Nested(bits QBit(Int8, 9), tag UInt8), String))",
      "JSON(payload Nested(value Dynamic))",
      "JSON(payload Array(Nested(value Dynamic)))",
      "JSON(payload Tuple(payload Nested(value Dynamic)))",
      "JSON(payload Map(String, Nested(value Dynamic)))",
      "JSON(payload Variant(Nested(value Dynamic), String))",
    ].each do |declaration|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentSchema.parse_declaration(declaration)
      end
    end
  end

  it "keeps static Nested outside ordinary typed-Object-Dynamic actual arms" do
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    string = CrystalClick::BinaryDataType.primitive("String")
    nested = CrystalClick::BinaryDataType.nested(
      [uint8, string] of CrystalClick::BinaryDataType,
      ["tag", "label"] of String,
    )
    nested_array = CrystalClick::BinaryDataType.array(nested)
    nested_tuple = CrystalClick::BinaryDataType.tuple(
      [nested] of CrystalClick::BinaryDataType,
      ["payload"] of String,
    )
    nested_map = CrystalClick::BinaryDataType.map(string, nested)

    # Ordinary scalar arms remain in the existing narrow profile.
    CrystalClick::ObjectDeclaredDynamicDeclaration.validate_actual_type!(
      uint8,
      CrystalClick::BinaryCodecLimits.default,
    ).should be_nil

    [nested, nested_array, nested_tuple, nested_map].each do |actual_type|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDeclaredDynamicDeclaration.validate_actual_type!(
          actual_type,
          CrystalClick::BinaryCodecLimits.default,
        )
      end
    end
  end
end
