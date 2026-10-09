require "./spec_helper"

private def w231_try_tuple(
  children : Array(CrystalClick::BinaryDataType),
  names : Array(String)? = nil,
) : CrystalClick::BinaryDataType?
  CrystalClick::BinaryDataType.tuple(children, names)
rescue ex : ArgumentError | CrystalClick::UnsupportedFormatError
  nil
end

private def w231_try_array(child : CrystalClick::BinaryDataType) : CrystalClick::BinaryDataType?
  CrystalClick::BinaryDataType.array(child)
rescue ex : ArgumentError | CrystalClick::UnsupportedFormatError
  nil
end

private def w231_try_nullable(child : CrystalClick::BinaryDataType) : CrystalClick::BinaryDataType?
  CrystalClick::BinaryDataType.nullable(child)
rescue ex : ArgumentError | CrystalClick::UnsupportedFormatError
  nil
end

private def w231_try_map(
  key : CrystalClick::BinaryDataType,
  value : CrystalClick::BinaryDataType,
) : CrystalClick::BinaryDataType?
  CrystalClick::BinaryDataType.map(key, value)
rescue ex : ArgumentError | CrystalClick::UnsupportedFormatError
  nil
end

private def w231_try_nested(
  children : Array(CrystalClick::BinaryDataType),
  names : Array(String),
) : CrystalClick::BinaryDataType?
  CrystalClick::BinaryDataType.nested(children, names)
rescue ex : ArgumentError | CrystalClick::UnsupportedFormatError
  nil
end

private def w231_qbit_type : CrystalClick::QBitType
  CrystalClick::QBitType.new("Int8", 3_u64)
end

private def w231_qbit_value(
  type : CrystalClick::QBitType,
  seed : UInt8,
) : CrystalClick::BinaryValue
  raw = Bytes.new(type.raw_row_bytes) { |index| (seed.to_i + index).to_u8 }
  CrystalClick::BinaryValue.qbit(CrystalClick::QBitValue.new(type, raw))
end

private def w231_zero_qbit_value(type : CrystalClick::QBitType) : CrystalClick::BinaryValue
  raw = Bytes.new(type.raw_row_bytes, 0_u8)
  CrystalClick::BinaryValue.qbit(CrystalClick::QBitValue.new(type, raw))
end

private def w231_product_roles(type : CrystalClick::BinaryDataType) : Array(String)
  CrystalClick::BinaryBulkTypePlan.new(
    type,
    CrystalClick::BinaryBulkProfile.single_stream,
  ).roles
end

private def w231_dynamic_structure_wire(actual_type : CrystalClick::BinaryDataType) : Bytes
  io = IO::Memory.new
  # Dynamic V3 full structure: version 4, one ordinary arm, the exact
  # candidate descriptor, then an empty statistics suffix.
  io.write(Bytes[0x04_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x01_u8])
  io.write(CrystalClick::BinaryDataTypeCodec.encode(actual_type))
  io.write(Bytes[0x00_u8])
  io.to_slice
end

describe "W231 static recursive QBit products" do
  it "admits source-valid Tuple, Array(Tuple), QBit-key/value Map, Nested, and Nullable(Tuple) descriptors" do
    qbit = CrystalClick::BinaryDataType.qbit(w231_qbit_type)
    tuple = w231_try_tuple(
      [qbit, qbit] of CrystalClick::BinaryDataType,
      ["left", "right"] of String,
    )
    tuple.should_not be_nil

    if tuple_for_codec = tuple
      CrystalClick::BinaryDataTypeCodec.decode(
        CrystalClick::BinaryDataTypeCodec.encode(tuple_for_codec)
      ).should eq(tuple_for_codec)
      CrystalClick::BinaryDataTypeCodec.decode(
        CrystalClick::BinaryDataTypeCodec.encode(CrystalClick::BinaryDataType.array(tuple_for_codec))
      ).should eq(CrystalClick::BinaryDataType.array(tuple_for_codec))
    end

    map = w231_try_map(CrystalClick::BinaryDataType.primitive("String"), qbit)
    map.should_not be_nil
    if map_type = map
      CrystalClick::BinaryDataTypeCodec.decode(
        CrystalClick::BinaryDataTypeCodec.encode(map_type)
      ).should eq(map_type)
    end

    qbit_key_map = w231_try_map(qbit, CrystalClick::BinaryDataType.primitive("UInt64"))
    qbit_key_map.should_not be_nil
    if key_map_type = qbit_key_map
      CrystalClick::BinaryDataTypeCodec.decode(
        CrystalClick::BinaryDataTypeCodec.encode(key_map_type)
      ).should eq(key_map_type)
    end

    nested = w231_try_nested(
      [qbit, qbit] of CrystalClick::BinaryDataType,
      ["left", "right"] of String,
    )
    nested.should_not be_nil
    if nested_type = nested
      CrystalClick::BinaryDataTypeCodec.decode(
        CrystalClick::BinaryDataTypeCodec.encode(nested_type)
      ).should eq(nested_type)
    end

    nullable_tuple = if tuple_for_nullable = tuple
                       w231_try_nullable(tuple_for_nullable)
                     else
                       nil
                     end
    nullable_tuple.should_not be_nil
    if nullable_type = nullable_tuple
      CrystalClick::BinaryDataTypeCodec.decode(
        CrystalClick::BinaryDataTypeCodec.encode(nullable_type)
      ).should eq(nullable_type)
    end
  end

  it "round-trips exact Tuple QBit leaves through the existing value and bulk APIs" do
    qbit_type = w231_qbit_type
    qbit = CrystalClick::BinaryDataType.qbit(qbit_type)
    tuple = w231_try_tuple([qbit, qbit] of CrystalClick::BinaryDataType)
    tuple.should_not be_nil

    if tuple_type = tuple
      first = CrystalClick::BinaryValue.tuple(
        tuple_type,
        [w231_qbit_value(qbit_type, 0x10_u8), w231_qbit_value(qbit_type, 0x30_u8)] of CrystalClick::BinaryValue,
      )
      second = CrystalClick::BinaryValue.tuple(
        tuple_type,
        [w231_qbit_value(qbit_type, 0x50_u8), w231_qbit_value(qbit_type, 0x70_u8)] of CrystalClick::BinaryValue,
      )

      rowbinary = CrystalClick::BinaryValueCodec.encode_value(first)
      CrystalClick::BinaryValueCodec.decode_value(tuple_type, rowbinary).should eq(first)
      CrystalClick::BinaryValueCodec.decode(
        CrystalClick::BinaryValueCodec.encode(first)
      ).should eq(first)

      roles = w231_product_roles(tuple_type)
      roles.should contain("root.field.0.qbit_plane.0")
      roles.should contain("root.field.1.qbit_plane.0")

      streams = CrystalClick::BinaryBulkCodec.encode(
        tuple_type,
        [[first, second] of CrystalClick::BinaryValue, [second] of CrystalClick::BinaryValue],
      )
      streams.has_role?("root.field.0.qbit_plane.0").should be_true
      streams.has_role?("root.field.1.qbit_plane.0").should be_true
      CrystalClick::BinaryBulkCodec.decode(tuple_type, streams, [2_u64, 1_u64]).should eq(
        [[first, second] of CrystalClick::BinaryValue, [second] of CrystalClick::BinaryValue]
      )
    end
  end

  it "shares one Array size lane while keeping both Tuple QBit site paths distinct" do
    qbit_type = w231_qbit_type
    qbit = CrystalClick::BinaryDataType.qbit(qbit_type)
    tuple = w231_try_tuple([qbit, qbit] of CrystalClick::BinaryDataType)
    tuple.should_not be_nil

    if tuple_type = tuple
      array = w231_try_array(tuple_type)
      array.should_not be_nil
      if array_type = array
        first = CrystalClick::BinaryValue.tuple(
          tuple_type,
          [w231_qbit_value(qbit_type, 0x11_u8), w231_qbit_value(qbit_type, 0x21_u8)] of CrystalClick::BinaryValue,
        )
        second = CrystalClick::BinaryValue.tuple(
          tuple_type,
          [w231_qbit_value(qbit_type, 0x31_u8), w231_qbit_value(qbit_type, 0x41_u8)] of CrystalClick::BinaryValue,
        )
        two = CrystalClick::BinaryValue.array(array_type, [first, second] of CrystalClick::BinaryValue)
        empty = CrystalClick::BinaryValue.array(array_type, [] of CrystalClick::BinaryValue)

        roles = w231_product_roles(array_type)
        roles.count { |role| role == "root.sizes" }.should eq(1)
        roles.should contain("root.elements.field.0.qbit_plane.0")
        roles.should contain("root.elements.field.1.qbit_plane.0")

        marks = [[two, empty] of CrystalClick::BinaryValue, [] of CrystalClick::BinaryValue]
        streams = CrystalClick::BinaryBulkCodec.encode(array_type, marks)
        CrystalClick::BinaryBulkCodec.decode(array_type, streams, [2_u64, 0_u64]).should eq(marks)
      end
    end
  end

  it "maps BASIC Map and Nested QBit values through their existing recursive visitors" do
    qbit_type = w231_qbit_type
    qbit = CrystalClick::BinaryDataType.qbit(qbit_type)

    map = w231_try_map(CrystalClick::BinaryDataType.primitive("String"), qbit)
    map.should_not be_nil
    if map_type = map
      pair = CrystalClick::BinaryValue.map(
        map_type,
        [CrystalClick::BinaryValue.string("k"), w231_qbit_value(qbit_type, 0x61_u8)] of CrystalClick::BinaryValue,
      )
      roles = w231_product_roles(map_type)
      roles.should contain("root.sizes")
      roles.should contain("root.elements.field.1.qbit_plane.0")
      streams = CrystalClick::BinaryBulkCodec.encode(map_type, [[pair] of CrystalClick::BinaryValue])
      CrystalClick::BinaryBulkCodec.decode(map_type, streams, [1_u64]).should eq([[pair] of CrystalClick::BinaryValue])
    end

    qbit_key_map = w231_try_map(qbit, CrystalClick::BinaryDataType.primitive("UInt64"))
    qbit_key_map.should_not be_nil
    if key_map_type = qbit_key_map
      pair = CrystalClick::BinaryValue.map(
        key_map_type,
        [w231_qbit_value(qbit_type, 0x51_u8), CrystalClick::BinaryValue.uint64(10_u64)] of CrystalClick::BinaryValue,
      )
      roles = w231_product_roles(key_map_type)
      roles.should contain("root.sizes")
      roles.should contain("root.elements.field.0.qbit_plane.0")
      streams = CrystalClick::BinaryBulkCodec.encode(key_map_type, [[pair] of CrystalClick::BinaryValue])
      CrystalClick::BinaryBulkCodec.decode(key_map_type, streams, [1_u64]).should eq([[pair] of CrystalClick::BinaryValue])
    end

    nested = w231_try_nested(
      [qbit] of CrystalClick::BinaryDataType,
      ["embedding"] of String,
    )
    nested.should_not be_nil
    if nested_type = nested
      tuple_type = CrystalClick::BinaryNestedType.tuple_for(nested_type)
      item = CrystalClick::BinaryValue.tuple(
        tuple_type,
        [w231_qbit_value(qbit_type, 0x71_u8)] of CrystalClick::BinaryValue,
      )
      one = CrystalClick::BinaryValue.nested(nested_type, [item] of CrystalClick::BinaryValue)
      empty = CrystalClick::BinaryValue.nested(nested_type, [] of CrystalClick::BinaryValue)
      roles = w231_product_roles(nested_type)
      roles.should contain("root.sizes")
      roles.should contain("root.elements.field.0.qbit_plane.0")
      marks = [[one, empty] of CrystalClick::BinaryValue]
      streams = CrystalClick::BinaryBulkCodec.encode(nested_type, marks)
      CrystalClick::BinaryBulkCodec.decode(nested_type, streams, [2_u64]).should eq(marks)
    end
  end

  it "keeps two QBit Map leaves on one size lane with independent static sites" do
    left_type = w231_qbit_type
    right_type = CrystalClick::QBitType.new("Float32", 2_u64)
    left = CrystalClick::BinaryDataType.qbit(left_type)
    right = CrystalClick::BinaryDataType.qbit(right_type)
    map = w231_try_map(left, right)
    map.should_not be_nil

    if map_type = map
      pair = CrystalClick::BinaryValue.map(
        map_type,
        [w231_qbit_value(left_type, 0x12_u8), w231_qbit_value(right_type, 0x52_u8)] of CrystalClick::BinaryValue,
      )
      plan = CrystalClick::BinaryBulkTypePlan.new(
        map_type,
        CrystalClick::BinaryBulkProfile.single_stream,
      )
      sites = plan.qbit_static_sites
      sites.size.should eq(2)
      sites[0].path.should eq("root.elements.field.0")
      sites[0].qbit_type.should eq(left_type)
      sites[1].path.should eq("root.elements.field.1")
      sites[1].qbit_type.should eq(right_type)
      sites[0].size_roles.should eq(["root.sizes"])
      sites[1].size_roles.should eq(["root.sizes"])
      plan.roles.count { |role| role == "root.sizes" }.should eq(1)

      streams = CrystalClick::BinaryBulkCodec.encode(map_type, [[pair] of CrystalClick::BinaryValue])
      CrystalClick::BinaryBulkCodec.decode(map_type, streams, [1_u64]).should eq(
        [[pair] of CrystalClick::BinaryValue]
      )
    end
  end

  it "compares mixed Tuple(QBit, UInt64) descendants without widening scalar identity" do
    qbit_type = w231_qbit_type
    qbit = CrystalClick::BinaryDataType.qbit(qbit_type)
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    tuple = CrystalClick::BinaryDataType.tuple([qbit, uint64] of CrystalClick::BinaryDataType)
    value = CrystalClick::BinaryValue.tuple(
      tuple,
      [w231_qbit_value(qbit_type, 0x18_u8), CrystalClick::BinaryValue.uint64(77_u64)] of CrystalClick::BinaryValue,
    )
    decoded = CrystalClick::BinaryValueCodec.decode(CrystalClick::BinaryValueCodec.encode(value))
    decoded.should eq(value)
    decoded.hash.should eq(value.hash)

    scalar = CrystalClick::BinaryValue.uint64(77_u64)
    decoded_scalar = CrystalClick::BinaryValueCodec.decode(CrystalClick::BinaryValueCodec.encode(scalar))
    decoded_scalar.should_not eq(scalar)
  end

  it "compares mixed Map(String, QBit) keys and planes structurally after bulk decode" do
    qbit_type = w231_qbit_type
    map_type = CrystalClick::BinaryDataType.map(
      CrystalClick::BinaryDataType.primitive("String"),
      CrystalClick::BinaryDataType.qbit(qbit_type),
    )
    value = CrystalClick::BinaryValue.map(
      map_type,
      [
        CrystalClick::BinaryValue.string("embedding"),
        w231_qbit_value(qbit_type, 0x28_u8),
      ] of CrystalClick::BinaryValue,
    )
    streams = CrystalClick::BinaryBulkCodec.encode(map_type, [[value] of CrystalClick::BinaryValue])
    decoded = CrystalClick::BinaryBulkCodec.decode(map_type, streams, [1_u64])[0][0]
    decoded.should eq(value)
    decoded.hash.should eq(value.hash)
  end

  it "rejects unequal payload, nominal, nullable, Variant, JSON, and child-order subtrees" do
    qbit_type = w231_qbit_type
    qbit = CrystalClick::BinaryDataType.qbit(qbit_type)
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    tuple_type = CrystalClick::BinaryDataType.tuple([qbit, uint64] of CrystalClick::BinaryDataType)
    baseline = CrystalClick::BinaryValue.tuple(
      tuple_type,
      [w231_qbit_value(qbit_type, 0x14_u8), CrystalClick::BinaryValue.uint64(77_u64)] of CrystalClick::BinaryValue,
    )

    changed_scalar = CrystalClick::BinaryValue.tuple(
      tuple_type,
      [w231_qbit_value(qbit_type, 0x14_u8), CrystalClick::BinaryValue.uint64(78_u64)] of CrystalClick::BinaryValue,
    )
    baseline.should_not eq(changed_scalar)

    changed_qbit = CrystalClick::BinaryValue.tuple(
      tuple_type,
      [w231_qbit_value(qbit_type, 0x15_u8), CrystalClick::BinaryValue.uint64(77_u64)] of CrystalClick::BinaryValue,
    )
    baseline.should_not eq(changed_qbit)

    alternate_qbit_type = CrystalClick::QBitType.new("BFloat16", 3_u64)
    alternate_qbit = CrystalClick::BinaryDataType.qbit(alternate_qbit_type)
    alternate_tuple_type = CrystalClick::BinaryDataType.tuple([alternate_qbit, uint64] of CrystalClick::BinaryDataType)
    alternate_nominal = CrystalClick::BinaryValue.tuple(
      alternate_tuple_type,
      [w231_qbit_value(alternate_qbit_type, 0x14_u8), CrystalClick::BinaryValue.uint64(77_u64)] of CrystalClick::BinaryValue,
    )
    baseline.should_not eq(alternate_nominal)

    float32 = CrystalClick::BinaryDataType.primitive("Float32")
    float_tuple_type = CrystalClick::BinaryDataType.tuple([qbit, float32] of CrystalClick::BinaryDataType)
    nan_one = CrystalClick::BinaryValue.tuple(
      float_tuple_type,
      [w231_qbit_value(qbit_type, 0x24_u8), CrystalClick::BinaryValue.float32_bits(0x7fc0_0001_u32)] of CrystalClick::BinaryValue,
    )
    nan_two = CrystalClick::BinaryValue.tuple(
      float_tuple_type,
      [w231_qbit_value(qbit_type, 0x24_u8), CrystalClick::BinaryValue.float32_bits(0x7fc0_0002_u32)] of CrystalClick::BinaryValue,
    )
    nan_one.should_not eq(nan_two)

    nullable_type = CrystalClick::BinaryDataType.nullable(tuple_type)
    null_value = CrystalClick::BinaryValue.nullable(nullable_type)
    present_value = CrystalClick::BinaryValue.nullable(nullable_type, baseline)
    null_value.should_not eq(present_value)

    variant_type = CrystalClick::BinaryDataType.variant([
      CrystalClick::BinaryDataType.primitive("UInt8"),
      CrystalClick::BinaryDataType.primitive("String"),
    ] of CrystalClick::BinaryDataType)
    variant_tuple_type = CrystalClick::BinaryDataType.tuple([qbit, variant_type] of CrystalClick::BinaryDataType)
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    variant_zero = CrystalClick::BinaryValue.tuple(
      variant_tuple_type,
      [
        w231_qbit_value(qbit_type, 0x34_u8),
        CrystalClick::BinaryValue.variant(variant_type, 0, CrystalClick::BinaryValue.string("seven")),
      ] of CrystalClick::BinaryValue,
    )
    variant_one = CrystalClick::BinaryValue.tuple(
      variant_tuple_type,
      [
        w231_qbit_value(qbit_type, 0x34_u8),
        CrystalClick::BinaryValue.variant(variant_type, 1, CrystalClick::BinaryValue.fixed(uint8, Bytes[0x07_u8])),
      ] of CrystalClick::BinaryValue,
    )
    variant_zero.should_not eq(variant_one)
    variant_zero.hash.should eq(
      CrystalClick::BinaryValue.tuple(
        variant_tuple_type,
        [
          w231_qbit_value(qbit_type, 0x34_u8),
          CrystalClick::BinaryValue.variant(variant_type, 0, CrystalClick::BinaryValue.string("seven")),
        ] of CrystalClick::BinaryValue,
      ).hash
    )

    json_type = CrystalClick::BinaryDataType.json
    json_row_a = CrystalClick::BinaryJsonRow.new(
      json_type,
      [{"a", CrystalClick::BinaryValue.string("x")}] of Tuple(String, CrystalClick::BinaryValue),
    )
    json_row_same = CrystalClick::BinaryJsonRow.new(
      json_type,
      [{"a", CrystalClick::BinaryValue.string("x")}] of Tuple(String, CrystalClick::BinaryValue),
    )
    json_row_b = CrystalClick::BinaryJsonRow.new(
      json_type,
      [{"b", CrystalClick::BinaryValue.string("x")}] of Tuple(String, CrystalClick::BinaryValue),
    )
    json_row_changed_value = CrystalClick::BinaryJsonRow.new(
      json_type,
      [{"a", CrystalClick::BinaryValue.string("y")}] of Tuple(String, CrystalClick::BinaryValue),
    )
    json_tuple_type = CrystalClick::BinaryDataType.tuple([qbit, json_type] of CrystalClick::BinaryDataType)
    json_a = CrystalClick::BinaryValue.tuple(
      json_tuple_type,
      [w231_qbit_value(qbit_type, 0x44_u8), CrystalClick::BinaryValue.json(json_type, json_row_a)] of CrystalClick::BinaryValue,
    )
    json_b = CrystalClick::BinaryValue.tuple(
      json_tuple_type,
      [w231_qbit_value(qbit_type, 0x44_u8), CrystalClick::BinaryValue.json(json_type, json_row_b)] of CrystalClick::BinaryValue,
    )
    json_same = CrystalClick::BinaryValue.tuple(
      json_tuple_type,
      [w231_qbit_value(qbit_type, 0x44_u8), CrystalClick::BinaryValue.json(json_type, json_row_same)] of CrystalClick::BinaryValue,
    )
    json_changed_value = CrystalClick::BinaryValue.tuple(
      json_tuple_type,
      [w231_qbit_value(qbit_type, 0x44_u8), CrystalClick::BinaryValue.json(json_type, json_row_changed_value)] of CrystalClick::BinaryValue,
    )
    json_a.should eq(json_same)
    json_a.hash.should eq(json_same.hash)
    json_a.should_not eq(json_b)
    json_a.should_not eq(json_changed_value)

    pair_type = CrystalClick::BinaryDataType.tuple([qbit, qbit] of CrystalClick::BinaryDataType)
    left = w231_qbit_value(qbit_type, 0x54_u8)
    right = w231_qbit_value(qbit_type, 0x64_u8)
    ordered = CrystalClick::BinaryValue.tuple(pair_type, [left, right] of CrystalClick::BinaryValue)
    reordered = CrystalClick::BinaryValue.tuple(pair_type, [right, left] of CrystalClick::BinaryValue)
    ordered.should_not eq(reordered)
  end

  it "writes QBit defaults at nested field paths for NULL Nullable(Tuple) rows" do
    qbit_type = w231_qbit_type
    qbit = CrystalClick::BinaryDataType.qbit(qbit_type)
    tuple = w231_try_tuple([qbit] of CrystalClick::BinaryDataType)
    tuple.should_not be_nil

    if tuple_type = tuple
      nullable_tuple = w231_try_nullable(tuple_type)
      nullable_tuple.should_not be_nil
      if nullable_type = nullable_tuple
        default_tuple = CrystalClick::BinaryValue.tuple(
          tuple_type,
          [w231_zero_qbit_value(qbit_type)] of CrystalClick::BinaryValue,
        )
        present_tuple = CrystalClick::BinaryValue.tuple(
          tuple_type,
          [w231_qbit_value(qbit_type, 0x35_u8)] of CrystalClick::BinaryValue,
        )
        null = CrystalClick::BinaryValue.nullable(nullable_type)
        present = CrystalClick::BinaryValue.nullable(nullable_type, present_tuple)

        roles = w231_product_roles(nullable_type)
        roles.should contain("root.nulls")
        roles.should contain("root.nested.field.0.qbit_plane.0")

        actual = CrystalClick::BinaryBulkCodec.encode(nullable_type, [[null, present] of CrystalClick::BinaryValue])
        expected = CrystalClick::BinaryBulkCodec.encode(
          tuple_type,
          [[default_tuple, present_tuple] of CrystalClick::BinaryValue],
        )
        tuple_type.child_at(0).qbit_type.not_nil!.plane_count.times do |plane|
          actual.stream("root.nested.field.0.qbit_plane.#{plane}").bytes.should eq(
            expected.stream("root.field.0.qbit_plane.#{plane}").bytes
          )
        end
        CrystalClick::BinaryBulkCodec.decode(nullable_type, actual, [2_u64]).should eq(
          [[null, present] of CrystalClick::BinaryValue]
        )
      end
    end
  end

  it "keeps unsupported QBit wrappers rejected while allowing only the sealed products" do
    qbit = CrystalClick::BinaryDataType.qbit(w231_qbit_type)
    array = CrystalClick::BinaryDataType.array(qbit)
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    nullable_uint64 = CrystalClick::BinaryDataType.nullable(uint64)
    low_cardinality_nullable_uint64 = CrystalClick::BinaryDataType.low_cardinality(nullable_uint64)

    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.nullable(array)
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.low_cardinality(qbit)
    end
    qbit_variant = CrystalClick::BinaryDataType.variant([
      qbit, CrystalClick::BinaryDataType.primitive("UInt8"),
    ] of CrystalClick::BinaryDataType)
    qbit_variant.contains_qbit?.should be_true
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.map(nullable_uint64, uint64)
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.map(low_cardinality_nullable_uint64, uint64)
    end
  end

  it "keeps static site copies detached and aggregates role/element budgets across leaves" do
    qbit_type = w231_qbit_type
    qbit = CrystalClick::BinaryDataType.qbit(qbit_type)
    tuple = CrystalClick::BinaryDataType.tuple([qbit, qbit] of CrystalClick::BinaryDataType)
    plan = CrystalClick::BinaryBulkTypePlan.new(
      tuple,
      CrystalClick::BinaryBulkProfile.single_stream,
    )

    sites = plan.qbit_static_sites
    sites.size.should eq(2)
    sites[0].plane_roles.clear
    sites[0].size_roles.clear
    sites[0].nullable_roles.clear
    sites.clear
    plan.qbit_static_sites.size.should eq(2)
    plan.qbit_static_site("root.field.0").not_nil!.plane_roles.should_not be_empty
    plan.qbit_static_site("root.field.1").not_nil!.plane_roles.should_not be_empty

    one_site_tuple = CrystalClick::BinaryDataType.tuple([qbit] of CrystalClick::BinaryDataType)
    per_site_bound = Math.max(4, qbit_type.plane_count + 1)
    bounded = CrystalClick::BinaryCodecLimits.new(
      max_depth: 64,
      max_nodes: 128,
      max_elements: per_site_bound,
      max_bytes: 4096,
    )
    CrystalClick::BinaryBulkTypePlan.new(
      one_site_tuple,
      CrystalClick::BinaryBulkProfile.single_stream,
      nil,
      bounded,
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkTypePlan.new(
        tuple,
        CrystalClick::BinaryBulkProfile.single_stream,
        nil,
        bounded,
      )
    end
  end

  it "bounds direct static-site planning by depth, node, and edge limits without values" do
    type = CrystalClick::BinaryDataType.qbit(w231_qbit_type)
    8.times do
      type = CrystalClick::BinaryDataType.array(type)
    end

    shallow = CrystalClick::BinaryCodecLimits.new(
      max_depth: 4,
      max_nodes: 128,
      max_elements: 128,
      max_bytes: 4096,
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkTypePlan.new(type, CrystalClick::BinaryBulkProfile.single_stream, nil, shallow)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryQBitRecursiveAdmission.static_sites(type, shallow, true)
    end

    node_limited = CrystalClick::BinaryCodecLimits.new(
      max_depth: 64,
      max_nodes: 3,
      max_elements: 128,
      max_bytes: 4096,
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkTypePlan.new(type, CrystalClick::BinaryBulkProfile.single_stream, nil, node_limited)
    end

    edge_limited = CrystalClick::BinaryCodecLimits.new(
      max_depth: 64,
      max_nodes: 128,
      max_elements: 3,
      max_bytes: 4096,
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryQBitRecursiveAdmission.static_sites(type, edge_limited, true)
    end
  end

  it "does not transfer static product admission to Count, Dynamic, JSON, or Object owners" do
    qbit = CrystalClick::BinaryDataType.qbit(w231_qbit_type)
    tuple = CrystalClick::BinaryDataType.tuple([qbit] of CrystalClick::BinaryDataType)
    array_tuple = CrystalClick::BinaryDataType.array(tuple)
    map_key = CrystalClick::BinaryDataType.map(qbit, CrystalClick::BinaryDataType.primitive("UInt64"))
    map_value = CrystalClick::BinaryDataType.map(CrystalClick::BinaryDataType.primitive("String"), qbit)
    nested = CrystalClick::BinaryDataType.nested([qbit] of CrystalClick::BinaryDataType, ["embedding"] of String)
    nullable_tuple = CrystalClick::BinaryDataType.nullable(tuple)
    products = [tuple, array_tuple, map_key, map_value, nested, nullable_tuple] of CrystalClick::BinaryDataType

    products.each do |argument|
      CrystalClick::BinaryAggregateCountArgumentPolicy.admitted?(argument).should be_false
      expect_raises(ArgumentError) do
        CrystalClick::BinaryAggregateCountType.new(argument)
      end
      expect_raises(ArgumentError) do
        CrystalClick::BinaryAggregateFunctionType.new("count", argument)
      end
      expect_raises(ArgumentError) do
        CrystalClick::BinaryDataType.aggregate_count(argument)
      end
      expect_raises(ArgumentError) do
        CrystalClick::BinaryDataType.aggregate_function("count", argument)
      end
      expect_raises(ArgumentError) do
        CrystalClick::BinaryDataType.json(typed_paths: {"items" => argument})
      end
      expect_raises(ArgumentError) do
        CrystalClick::ObjectDocumentSchema.new({"items" => argument})
      end

      dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
      if argument.tag == CrystalClick::BinaryDataType::TAG_NULLABLE
        # Root Nullable is rejected by Dynamic V3 structure construction before
        # any QBit-specific plan or value admission is reached.
        expect_raises(ArgumentError, "top-level Nothing and Nullable are not admitted in Dynamic V3") do
          CrystalClick::DynamicStructure.new([argument] of CrystalClick::BinaryDataType)
        end
      else
        structure = CrystalClick::DynamicStructure.new([argument] of CrystalClick::BinaryDataType)
        expect_raises(CrystalClick::UnsupportedFormatError) do
          CrystalClick::BinaryDynamicBulkPlan.new(dynamic, {"root" => structure})
        end
        expect_raises(CrystalClick::UnsupportedFormatError) do
          CrystalClick::BinaryDynamicBulkCodec.encode(
            dynamic,
            {"root" => structure},
            [] of Array(CrystalClick::BinaryValue),
          )
        end
      end
      forged = CrystalClick::BinaryDynamicBulkStreams.new(
        CrystalClick::BinaryDynamicStructureStreams.new({
          "root" => w231_dynamic_structure_wire(argument),
        }),
        CrystalClick::BinaryBulkStreams.new(
          0,
          {} of String => CrystalClick::BinaryBulkStream,
        ),
      )
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryDynamicBulkCodec.decode(dynamic, forged, [] of UInt64)
      end
    end

    # A Dynamic field beside a static QBit leaf is not part of the admitted
    # static product closure. Its actual roster must not be made to appear
    # complete by the descriptor-side static QBit site.
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    mixed = CrystalClick::BinaryDataType.tuple([dynamic, qbit] of CrystalClick::BinaryDataType)
    actual_string = CrystalClick::BinaryDataType.primitive("String")
    mixed_structure = CrystalClick::DynamicStructure.new([actual_string] of CrystalClick::BinaryDataType)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDynamicBulkPlan.new(mixed, {"root.field.0" => mixed_structure})
    end
  end
end
