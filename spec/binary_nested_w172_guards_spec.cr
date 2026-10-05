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

  it "keeps recursive descriptors but refuses unqualified Nested+LC, Variant, or Dynamic bulk products" do
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    string = CrystalClick::BinaryDataType.primitive("String")
    specialized = [
      CrystalClick::BinaryDataType.low_cardinality(uint64),
      CrystalClick::BinaryDataType.variant([uint64, string] of CrystalClick::BinaryDataType),
      CrystalClick::BinaryDataType.dynamic(4),
    ] of CrystalClick::BinaryDataType

    specialized.each do |child|
      nested = CrystalClick::BinaryDataType.nested([child] of CrystalClick::BinaryDataType, ["x"] of String)
      restored = CrystalClick::BinaryDataTypeCodec.decode(CrystalClick::BinaryDataTypeCodec.encode(nested))
      restored.tag.should eq(CrystalClick::BinaryDataType::TAG_NESTED)
      restored.child_at(0).child_at(0).tag.should eq(child.tag)

      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryBulkTypePlan.new(nested, CrystalClick::BinaryBulkProfile.single_stream)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryBulkCodec.encode(nested, [] of Array(CrystalClick::BinaryValue))
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryBulkPhysicalPlan.new(nested, "events")
      end
    end

    ordinary_nested = CrystalClick::BinaryDataType.nested([uint64] of CrystalClick::BinaryDataType, ["n"] of String)
    nested_low_cardinality = CrystalClick::BinaryDataType.nested(
      [CrystalClick::BinaryDataType.low_cardinality(uint64)] of CrystalClick::BinaryDataType,
      ["n"] of String
    )
    variant_around_nested = CrystalClick::BinaryDataType.variant(
      [ordinary_nested, uint64] of CrystalClick::BinaryDataType
    )
    tuple_with_unrelated_low_cardinality = CrystalClick::BinaryDataType.tuple(
      [ordinary_nested, CrystalClick::BinaryDataType.low_cardinality(string)] of CrystalClick::BinaryDataType,
      ["payload", "lookup"] of String
    )

    [variant_around_nested, tuple_with_unrelated_low_cardinality].each do |product|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryBulkTypePlan.new(product, CrystalClick::BinaryBulkProfile.single_stream)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryBulkCodec.encode(product, [] of Array(CrystalClick::BinaryValue))
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryBulkPhysicalPlan.new(product, "events")
      end
    end

    # A valid empty Array(named-Tuple) control has the same role shape as the
    # Nested LC carrier. Nested+LC must fail its admission guard before the
    # reader treats any role as missing or corrupt.
    tuple_with_low_cardinality = CrystalClick::BinaryDataType.tuple(
      [CrystalClick::BinaryDataType.low_cardinality(uint64)] of CrystalClick::BinaryDataType,
      ["n"] of String
    )
    array_tuple_control = CrystalClick::BinaryDataType.array(tuple_with_low_cardinality)
    valid_empty_control = CrystalClick::BinaryBulkCodec.encode(
      array_tuple_control,
      [] of Array(CrystalClick::BinaryValue)
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkCodec.decode(nested_low_cardinality, valid_empty_control, [] of UInt64)
    end

    # Valid V3 metadata may describe Nested, but the specialized Dynamic
    # bulk planner must refuse that actual roster in the read direction too.
    actual = CrystalClick::DynamicStructure.new([ordinary_nested] of CrystalClick::BinaryDataType)
    structure_streams = CrystalClick::BinaryDynamicStructureStreams.new({
      "root" => CrystalClick::DynamicStructureCodec.encode(actual),
    })
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDynamicBulkPlan.decode_structure_streams(
        CrystalClick::BinaryDataType.dynamic(1),
        structure_streams,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
      )
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
