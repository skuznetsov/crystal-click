require "./spec_helper"

private def w172_guard_nested_member(type : CrystalClick::BinaryDataType, value : CrystalClick::BinaryValue) : CrystalClick::BinaryValue
  case type.tag
  when CrystalClick::BinaryDataType::TAG_ARRAY,
       CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE,
       CrystalClick::BinaryDataType::TAG_NAMED_TUPLE
    value.child_at(0)
  when CrystalClick::BinaryDataType::TAG_MAP
    value.child_at(1)
  else
    raise "test wrapper must be Array, Tuple, or Map"
  end
end

describe "W172 Nested logical binary adversarial guards" do
  it "fails closed on empty, nonminimal, oversized, truncated, and trailing descriptors" do
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.nested([] of CrystalClick::BinaryDataType, [] of String)
    end

    malformed = [
      Bytes[0x2f_u8, 0x00_u8],                                                       # empty field roster
      Bytes[0x2f_u8, 0x81_u8, 0x00_u8],                                              # nonminimal count
      Bytes[0x2f_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0x07_u8],                   # huge count
      Bytes[0x2f_u8, 0x01_u8, 0x03_u8, 0x61_u8],                                     # truncated name
      Bytes[0x2f_u8, 0x01_u8, 0x01_u8, 0x61_u8],                                     # missing child descriptor
      Bytes[0x2f_u8, 0x01_u8, 0x01_u8, 0x61_u8, 0x04_u8, 0x04_u8],                   # trailing descriptor
      Bytes[0x2f_u8, 0x01_u8, 0x00_u8, 0x04_u8],                                     # empty field name
      Bytes[0x2f_u8, 0x01_u8, 0x04_u8, 0x6e_u8, 0x75_u8, 0x6c_u8, 0x6c_u8, 0x04_u8], # reserved null
      Bytes[0x2f_u8, 0x02_u8, 0x01_u8, 0x61_u8, 0x04_u8, 0x01_u8, 0x61_u8, 0x04_u8], # duplicate name
    ] of Bytes

    malformed.each do |wire|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryDataTypeCodec.decode(wire)
      end
    end
  end

  it "charges the implicit Tuple against shared descriptor depth, node, edge, and byte limits" do
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    nested = CrystalClick::BinaryDataType.nested([uint64] of CrystalClick::BinaryDataType, ["a"] of String)
    nested_wire = Bytes[0x2f_u8, 0x01_u8, 0x01_u8, 0x61_u8, 0x04_u8]
    CrystalClick::BinaryDataTypeCodec.encode(nested).should eq(nested_wire)

    plain_array = CrystalClick::BinaryDataType.array(uint64)
    base = CrystalClick::BinaryCodecLimits.default

    # Plain Array(UInt64) fits at depth/node/edge limits 2/2/1; Nested needs
    # the extra implicit named-Tuple node and its edge before reaching UInt64.
    shallow = CrystalClick::BinaryCodecLimits.new(2, base.max_nodes, base.max_elements, base.max_bytes)
    CrystalClick::BinaryDataTypeCodec.encode(plain_array, shallow).should eq(Bytes[0x1e_u8, 0x04_u8])
    CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x1e_u8, 0x04_u8], shallow).tag.should eq(CrystalClick::BinaryDataType::TAG_ARRAY)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.encode(nested, shallow)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(nested_wire, shallow)
    end

    few_nodes = CrystalClick::BinaryCodecLimits.new(base.max_depth, 2, base.max_elements, base.max_bytes)
    CrystalClick::BinaryDataTypeCodec.encode(plain_array, few_nodes).should eq(Bytes[0x1e_u8, 0x04_u8])
    CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x1e_u8, 0x04_u8], few_nodes).tag.should eq(CrystalClick::BinaryDataType::TAG_ARRAY)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.encode(nested, few_nodes)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(nested_wire, few_nodes)
    end

    few_edges = CrystalClick::BinaryCodecLimits.new(base.max_depth, base.max_nodes, 1, base.max_bytes)
    CrystalClick::BinaryDataTypeCodec.encode(plain_array, few_edges).should eq(Bytes[0x1e_u8, 0x04_u8])
    CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x1e_u8, 0x04_u8], few_edges).tag.should eq(CrystalClick::BinaryDataType::TAG_ARRAY)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.encode(nested, few_edges)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(nested_wire, few_edges)
    end

    short_bytes = CrystalClick::BinaryCodecLimits.new(base.max_depth, base.max_nodes, base.max_elements, nested_wire.size - 1)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.encode(nested, short_bytes)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(nested_wire, short_bytes)
    end
    exact_bytes = CrystalClick::BinaryCodecLimits.new(base.max_depth, base.max_nodes, base.max_elements, nested_wire.size)
    CrystalClick::BinaryDataTypeCodec.encode(nested, exact_bytes).should eq(nested_wire)
    CrystalClick::BinaryDataTypeCodec.decode(nested_wire, exact_bytes).tag.should eq(CrystalClick::BinaryDataType::TAG_NESTED)

    exact_shape = CrystalClick::BinaryCodecLimits.new(3, 3, 2, base.max_bytes)
    CrystalClick::BinaryDataTypeCodec.encode(nested, exact_shape).should eq(nested_wire)
    CrystalClick::BinaryDataTypeCodec.decode(nested_wire, exact_shape).tag.should eq(CrystalClick::BinaryDataType::TAG_NESTED)

    # A typed row envelope must use the same budget for its descriptor and
    # nested value traversal, not reset counters at the descriptor boundary.
    record = CrystalClick::BinaryValue.tuple(
      nested.child_at(0),
      [CrystalClick::BinaryValue.uint64(1_u64)] of CrystalClick::BinaryValue
    )
    value = CrystalClick::BinaryValue.nested(nested, [record] of CrystalClick::BinaryValue)
    envelope = CrystalClick::BinaryValueCodec.encode(value)
    shared_node_short = CrystalClick::BinaryCodecLimits.new(3, 5, base.max_elements, base.max_bytes)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode(value, shared_node_short)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode(envelope, shared_node_short)
    end
    shared_edges_short = CrystalClick::BinaryCodecLimits.new(3, base.max_nodes, 3, base.max_bytes)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode(value, shared_edges_short)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode(envelope, shared_edges_short)
    end
  end

  it "detaches field names and keeps Nested nominally distinct from Array(named Tuple)" do
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    external_name = String.new("a".to_slice)
    nested = CrystalClick::BinaryDataType.nested([uint64] of CrystalClick::BinaryDataType, [external_name] of String)
    external_name.to_unsafe[0] = 0x7a_u8

    nested.tag.should eq(CrystalClick::BinaryDataType::TAG_NESTED)
    nested.named_tuple?.should be_false
    nested.name.should eq("Nested(a UInt64)")
    nested.child_at(0).field_name_at(0).should eq("a")

    tuple_type = nested.child_at(0)
    tuple_value = CrystalClick::BinaryValue.tuple(
      tuple_type,
      [CrystalClick::BinaryValue.uint64(7_u64)] of CrystalClick::BinaryValue
    )
    nested_value = CrystalClick::BinaryValue.nested(nested, [tuple_value] of CrystalClick::BinaryValue)
    array_tuple_type = CrystalClick::BinaryDataType.array(tuple_type)
    array_tuple_value = CrystalClick::BinaryValue.array(
      array_tuple_type,
      [tuple_value] of CrystalClick::BinaryValue
    )

    restored_nested = CrystalClick::BinaryValueCodec.decode(CrystalClick::BinaryValueCodec.encode(nested_value))
    restored_array_tuple = CrystalClick::BinaryValueCodec.decode(CrystalClick::BinaryValueCodec.encode(array_tuple_value))
    restored_nested.type.tag.should eq(CrystalClick::BinaryDataType::TAG_NESTED)
    restored_array_tuple.type.tag.should eq(CrystalClick::BinaryDataType::TAG_ARRAY)
    restored_array_tuple.type.should_not eq(restored_nested.type)

    expect_raises(ArgumentError) do
      CrystalClick::BinaryValue.nested(array_tuple_type, [tuple_value] of CrystalClick::BinaryValue)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkCodec.encode(
        nested,
        [[array_tuple_value]] of Array(CrystalClick::BinaryValue)
      )
    end
  end

  it "rejects Nullable(Nested) through both constructor and wire decode" do
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    nested = CrystalClick::BinaryDataType.nested([uint64] of CrystalClick::BinaryDataType, ["a"] of String)
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.nullable(nested)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x23_u8, 0x2f_u8, 0x01_u8, 0x01_u8, 0x61_u8, 0x04_u8])
    end
  end

  it "retains specialized Nested descriptors while checking positive bulk parity and profile guards" do
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    string = CrystalClick::BinaryDataType.primitive("String")
    profile = CrystalClick::BinaryBulkProfile.single_stream

    specialized = [
      CrystalClick::BinaryDataType.low_cardinality(uint64),
      CrystalClick::BinaryDataType.variant([uint64, string] of CrystalClick::BinaryDataType),
      CrystalClick::BinaryDataType.dynamic(2),
    ] of CrystalClick::BinaryDataType
    specialized.each do |child|
      nested = CrystalClick::BinaryDataType.nested([child] of CrystalClick::BinaryDataType, ["x"] of String)
      restored = CrystalClick::BinaryDataTypeCodec.decode(CrystalClick::BinaryDataTypeCodec.encode(nested))
      restored.should eq(nested)
      restored.tag.should eq(CrystalClick::BinaryDataType::TAG_NESTED)
    end

    low_cardinality = CrystalClick::BinaryDataType.low_cardinality(uint64)
    nested_low_cardinality = CrystalClick::BinaryDataType.nested(
      [low_cardinality] of CrystalClick::BinaryDataType,
      ["value"] of String,
    )
    nested_low_cardinality_record = CrystalClick::BinaryValue.tuple(
      nested_low_cardinality.child_at(0),
      [CrystalClick::BinaryValue.low_cardinality(low_cardinality, CrystalClick::BinaryValue.uint64(7_u64))] of CrystalClick::BinaryValue,
    )
    nested_low_cardinality_value = CrystalClick::BinaryValue.nested(
      nested_low_cardinality,
      [nested_low_cardinality_record] of CrystalClick::BinaryValue,
    )
    low_cardinality_plan = CrystalClick::BinaryBulkTypePlan.new(nested_low_cardinality, profile)
    low_cardinality_streams = CrystalClick::BinaryBulkCodec.encode(
      nested_low_cardinality,
      [[nested_low_cardinality_value]] of Array(CrystalClick::BinaryValue),
    )
    low_cardinality_plan.roles.should eq(low_cardinality_streams.roles)
    CrystalClick::BinaryBulkPhysicalPlan.new(nested_low_cardinality, "events").stream_names.keys.sort.should eq(low_cardinality_streams.roles)
    low_cardinality_restored = CrystalClick::BinaryBulkCodec.decode(nested_low_cardinality, low_cardinality_streams, [1_u64])
    low_cardinality_restored[0][0].type.should eq(nested_low_cardinality)
    low_cardinality_restored[0][0].element_at(0).child_at(0).child_at(0).as_uint64.should eq(7_u64)

    # The legal Nested+LC role roster is now read as data, so a missing lane
    # must fail as corruption rather than being confused with type admission.
    missing_dictionary_lanes = Hash(String, CrystalClick::BinaryBulkStream).new
    low_cardinality_streams.roles.each do |role|
      next if role == "root.elements.field.0.dictionary"
      missing_dictionary_lanes[role] = low_cardinality_streams.stream(role)
    end
    missing_dictionary = CrystalClick::BinaryBulkStreams.new(
      low_cardinality_streams.mark_count,
      missing_dictionary_lanes,
    )
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryBulkCodec.decode(nested_low_cardinality, missing_dictionary, [1_u64])
    end

    # The reverse recursive direction remains composable too: Nested can be
    # the selected arm of Variant without losing its nominal type.
    ordinary_nested = CrystalClick::BinaryDataType.nested([uint64] of CrystalClick::BinaryDataType, ["n"] of String)
    ordinary_record = CrystalClick::BinaryValue.tuple(
      ordinary_nested.child_at(0),
      [CrystalClick::BinaryValue.uint64(12_u64)] of CrystalClick::BinaryValue,
    )
    ordinary_value = CrystalClick::BinaryValue.nested(ordinary_nested, [ordinary_record] of CrystalClick::BinaryValue)
    variant = CrystalClick::BinaryDataType.variant([ordinary_nested, uint64] of CrystalClick::BinaryDataType)
    nested_arm = variant.children.index(ordinary_nested).not_nil!
    variant_value = CrystalClick::BinaryValue.variant(variant, nested_arm, ordinary_value)
    variant_plan = CrystalClick::BinaryBulkTypePlan.new(variant, profile)
    variant_streams = CrystalClick::BinaryBulkCodec.encode(variant, [[variant_value]] of Array(CrystalClick::BinaryValue))
    variant_plan.roles.should eq(variant_streams.roles)
    variant_restored = CrystalClick::BinaryBulkCodec.decode(variant, variant_streams, [1_u64])[0][0]
    variant_restored.variant_child?.not_nil!.type.should eq(ordinary_nested)
    variant_restored.variant_child?.not_nil!.element_at(0).child_at(0).as_uint64.should eq(12_u64)

    # The ordinary bulk entry remains guarded: Dynamic requires its actual
    # structure roster and goes through the paired Dynamic bulk owner.
    nested_dynamic = CrystalClick::BinaryDataType.nested(
      [CrystalClick::BinaryDataType.dynamic(2)] of CrystalClick::BinaryDataType,
      ["payload"] of String,
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkTypePlan.new(nested_dynamic, profile)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkCodec.encode(nested_dynamic, [] of Array(CrystalClick::BinaryValue))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkPhysicalPlan.new(nested_dynamic, "events")
    end
  end

  it "retains Nested through ordinary Array, Tuple, and Map row and bulk composition" do
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    string = CrystalClick::BinaryDataType.primitive("String")
    nested = CrystalClick::BinaryDataType.nested(
      [uint64, string] of CrystalClick::BinaryDataType,
      ["id", "label"] of String
    )
    record = CrystalClick::BinaryValue.tuple(
      nested.child_at(0),
      [CrystalClick::BinaryValue.uint64(7_u64), CrystalClick::BinaryValue.string("seven")] of CrystalClick::BinaryValue
    )
    nested_value = CrystalClick::BinaryValue.nested(nested, [record] of CrystalClick::BinaryValue)

    array_type = CrystalClick::BinaryDataType.array(nested)
    array_value = CrystalClick::BinaryValue.array(array_type, [nested_value] of CrystalClick::BinaryValue)
    tuple_type = CrystalClick::BinaryDataType.tuple([nested] of CrystalClick::BinaryDataType, ["payload"] of String)
    tuple_value = CrystalClick::BinaryValue.tuple(tuple_type, [nested_value] of CrystalClick::BinaryValue)
    map_type = CrystalClick::BinaryDataType.map(uint64, nested)
    map_value = CrystalClick::BinaryValue.map(
      map_type,
      [CrystalClick::BinaryValue.uint64(1_u64), nested_value] of CrystalClick::BinaryValue
    )

    [
      {type: array_type, value: array_value},
      {type: tuple_type, value: tuple_value},
      {type: map_type, value: map_value},
    ].each do |entry|
      row_restored = CrystalClick::BinaryValueCodec.decode(CrystalClick::BinaryValueCodec.encode(entry[:value]))
      row_nested = w172_guard_nested_member(entry[:type], row_restored)
      row_nested.type.tag.should eq(CrystalClick::BinaryDataType::TAG_NESTED)

      rows = [[entry[:value]]] of Array(CrystalClick::BinaryValue)
      streams = CrystalClick::BinaryBulkCodec.encode(entry[:type], rows)
      bulk_restored = CrystalClick::BinaryBulkCodec.decode(entry[:type], streams, [1_u64])[0][0]
      bulk_nested = w172_guard_nested_member(entry[:type], bulk_restored)
      bulk_nested.type.tag.should eq(CrystalClick::BinaryDataType::TAG_NESTED)
      bulk_nested.child_at(0).type.tag.should eq(CrystalClick::BinaryDataType::TAG_NAMED_TUPLE)
    end
  end
end
