require "./spec_helper"

private def w117_type(name : String) : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.primitive(name)
end

private def w117_limits(
  max_depth : Int = 64,
  max_nodes : Int = 4096,
  max_elements : Int = 1_000_000,
  max_bytes : Int = 64 * 1024 * 1024,
) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: max_depth,
    max_nodes: max_nodes,
    max_elements: max_elements,
    max_bytes: max_bytes
  )
end

private def w117_var_uint(value : UInt64) : Bytes
  bytes = [] of UInt8
  remaining = value
  loop do
    payload = (remaining & 0x7f_u64).to_u8
    remaining >>= 7
    bytes << (remaining == 0 ? payload : payload | 0x80_u8)
    break if remaining == 0
  end
  Bytes.new(bytes.size) { |index| bytes[index] }
end

private def w117_corrupt_descriptor_prefixes(descriptor : Bytes) : Nil
  (0...descriptor.size).each do |length|
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(descriptor[0, length])
    end
  end
end

private def w117_corrupt_value_prefixes(type : CrystalClick::BinaryDataType, value_bytes : Bytes) : Nil
  (0...value_bytes.size).each do |length|
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_value(type, value_bytes[0, length])
    end
  end
end

private def w117_u32_le(value : UInt32) : Bytes
  Bytes[
    (value & 0xff_u32).to_u8,
    ((value >> 8) & 0xff_u32).to_u8,
    ((value >> 16) & 0xff_u32).to_u8,
    ((value >> 24) & 0xff_u32).to_u8,
  ]
end

private def w117_u64_le(value : UInt64) : Bytes
  Bytes[
    (value & 0xff_u64).to_u8,
    ((value >> 8) & 0xff_u64).to_u8,
    ((value >> 16) & 0xff_u64).to_u8,
    ((value >> 24) & 0xff_u64).to_u8,
    ((value >> 32) & 0xff_u64).to_u8,
    ((value >> 40) & 0xff_u64).to_u8,
    ((value >> 48) & 0xff_u64).to_u8,
    ((value >> 56) & 0xff_u64).to_u8,
  ]
end

describe "W117 binary DataType and scalar value codec" do
  it "encodes the admitted primitive descriptors with exact nominal tags" do
    cases = {
      {"Nothing", Bytes[0x00_u8]},
      {"UInt8", Bytes[0x01_u8]},
      {"UInt16", Bytes[0x02_u8]},
      {"UInt32", Bytes[0x03_u8]},
      {"UInt64", Bytes[0x04_u8]},
      {"UInt128", Bytes[0x05_u8]},
      {"UInt256", Bytes[0x06_u8]},
      {"Int8", Bytes[0x07_u8]},
      {"Int16", Bytes[0x08_u8]},
      {"Int32", Bytes[0x09_u8]},
      {"Int64", Bytes[0x0a_u8]},
      {"Int128", Bytes[0x0b_u8]},
      {"Int256", Bytes[0x0c_u8]},
      {"Float32", Bytes[0x0d_u8]},
      {"Float64", Bytes[0x0e_u8]},
      {"String", Bytes[0x15_u8]},
      {"Bool", Bytes[0x2d_u8]},
      {"BFloat16", Bytes[0x31_u8]},
    }

    cases.each do |type_name, wire|
      type = w117_type(type_name)
      type.name.should eq(type_name)
      CrystalClick::BinaryDataTypeCodec.encode(type).should eq(wire)

      decoded = CrystalClick::BinaryDataTypeCodec.decode(wire)
      decoded.name.should eq(type_name)
      CrystalClick::BinaryDataTypeCodec.encode(decoded).should eq(wire)
    end
  end

  it "round-trips fixed strings and named, unnamed, nullable, array, and map descriptors" do
    fixed = CrystalClick::BinaryDataType.fixed_string(3)
    fixed.name.should eq("FixedString(3)")
    CrystalClick::BinaryDataTypeCodec.encode(fixed).should eq(Bytes[0x16_u8, 0x03_u8])
    largest_fixed = CrystalClick::BinaryDataType.fixed_string(0x00ff_ffff)
    largest_fixed.name.should eq("FixedString(16777215)")
    largest_fixed_wire = Bytes[0x16_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0x07_u8]
    CrystalClick::BinaryDataTypeCodec.encode(largest_fixed).should eq(largest_fixed_wire)
    CrystalClick::BinaryDataTypeCodec.decode(largest_fixed_wire).name.should eq(largest_fixed.name)
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.fixed_string(0) }
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.fixed_string(0x0100_0000) }

    array_nullable_int64 = CrystalClick::BinaryDataType.array(
      CrystalClick::BinaryDataType.nullable(w117_type("Int64"))
    )
    array_nullable_int64.name.should eq("Array(Nullable(Int64))")
    CrystalClick::BinaryDataTypeCodec.encode(array_nullable_int64).should eq(
      Bytes[0x1e_u8, 0x23_u8, 0x0a_u8]
    )

    unnamed = CrystalClick::BinaryDataType.tuple([
      w117_type("UInt8"),
      w117_type("String"),
    ] of CrystalClick::BinaryDataType)
    CrystalClick::BinaryDataTypeCodec.encode(unnamed).should eq(
      Bytes[0x1f_u8, 0x02_u8, 0x01_u8, 0x15_u8]
    )

    named = CrystalClick::BinaryDataType.tuple(
      [w117_type("UInt8"), array_nullable_int64] of CrystalClick::BinaryDataType,
      ["x", "items"] of String
    )
    named.name.should eq("Tuple(x UInt8, items Array(Nullable(Int64)))")
    named.field_names.should eq(["x", "items"])
    CrystalClick::BinaryDataTypeCodec.encode(named).should eq(Bytes[
      0x20_u8, 0x02_u8,
      0x01_u8, 0x78_u8, 0x01_u8,
      0x05_u8, 0x69_u8, 0x74_u8, 0x65_u8, 0x6d_u8, 0x73_u8,
      0x1e_u8, 0x23_u8, 0x0a_u8,
    ])

    nullable_tuple = CrystalClick::BinaryDataType.nullable(unnamed)
    nullable_tuple.name.should eq("Nullable(Tuple(UInt8, String))")
    CrystalClick::BinaryDataTypeCodec.encode(nullable_tuple).should eq(
      Bytes[0x23_u8, 0x1f_u8, 0x02_u8, 0x01_u8, 0x15_u8]
    )

    string_uint64_map = CrystalClick::BinaryDataType.map(w117_type("String"), w117_type("UInt64"))
    string_uint64_map.name.should eq("Map(String, UInt64)")
    CrystalClick::BinaryDataTypeCodec.encode(string_uint64_map).should eq(
      Bytes[0x27_u8, 0x15_u8, 0x04_u8]
    )

    # ClickHouse permits composite Map keys; the current kernel must not
    # narrow this source-defined rule to scalar keys.
    array_key_map = CrystalClick::BinaryDataType.map(
      CrystalClick::BinaryDataType.array(w117_type("Int64")),
      w117_type("String")
    )
    CrystalClick::BinaryDataTypeCodec.encode(array_key_map).should eq(
      Bytes[0x27_u8, 0x1e_u8, 0x0a_u8, 0x15_u8]
    )

    nullable_nothing = CrystalClick::BinaryDataType.nullable(w117_type("Nothing"))
    nullable_nothing.name.should eq("Nullable(Nothing)")
    CrystalClick::BinaryDataTypeCodec.encode(nullable_nothing).should eq(
      Bytes[0x23_u8, 0x00_u8]
    )

    nothing_key_map = CrystalClick::BinaryDataType.map(w117_type("Nothing"), w117_type("String"))
    CrystalClick::BinaryDataTypeCodec.encode(nothing_key_map).should eq(
      Bytes[0x27_u8, 0x00_u8, 0x15_u8]
    )
  end

  it "rejects source-invalid tuple names and Nullable or Map-key structures" do
    uint8 = w117_type("UInt8")
    [
      [] of String,
      ["", "valid"] of String,
      ["null"] of String,
      ["null", "valid"] of String,
      ["duplicate", "duplicate"] of String,
    ].each do |names|
      expect_raises(ArgumentError) do
        CrystalClick::BinaryDataType.tuple([uint8, uint8] of CrystalClick::BinaryDataType, names)
      end
    end

    # Numeric names are valid in ClickHouse's binary Tuple representation.
    numeric_names = CrystalClick::BinaryDataType.tuple(
      [uint8, w117_type("String")] of CrystalClick::BinaryDataType,
      ["1", "2"] of String
    )
    numeric_names.field_names.should eq(["1", "2"])

    keyword_name = CrystalClick::BinaryDataType.tuple(
      [uint8] of CrystalClick::BinaryDataType,
      ["values"] of String
    )
    keyword_name.name.should eq("Tuple(`values` UInt8)")
    null_name = CrystalClick::BinaryDataType.tuple(
      [uint8] of CrystalClick::BinaryDataType,
      ["NULL"] of String
    )
    null_name.name.should eq("Tuple(`NULL` UInt8)")
    escaped_controls = CrystalClick::BinaryDataType.tuple(
      [uint8] of CrystalClick::BinaryDataType,
      ["b\b\f"] of String
    )
    escaped_controls.name.should eq("Tuple(`b\\b\\f` UInt8)")

    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.array(uint8)) }
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.map(uint8, uint8)) }
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.nullable(uint8)) }
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.map(CrystalClick::BinaryDataType.nullable(uint8), uint8) }

    # Invalid structures are rejected at the untrusted descriptor boundary,
    # not just by local constructors.
    [
      Bytes[0x20_u8, 0x01_u8, 0x00_u8, 0x01_u8],                                     # empty named field
      Bytes[0x20_u8, 0x01_u8, 0x04_u8, 0x6e_u8, 0x75_u8, 0x6c_u8, 0x6c_u8, 0x01_u8], # `null`
      Bytes[0x23_u8, 0x1e_u8, 0x01_u8],                                              # Nullable(Array(UInt8))
      Bytes[0x23_u8, 0x27_u8, 0x01_u8, 0x01_u8],                                     # Nullable(Map(UInt8, UInt8))
      Bytes[0x23_u8, 0x23_u8, 0x01_u8],                                              # nested Nullable
      Bytes[0x27_u8, 0x23_u8, 0x01_u8, 0x01_u8],                                     # Map Nullable key
    ].each do |wire|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryDataTypeCodec.decode(wire)
      end
    end
  end

  it "preserves raw numeric widths, nominal signedness, and exact Float payload bits" do
    numeric_cases = {
      {"Int8", Bytes[0xff_u8]},
      {"UInt8", Bytes[0xff_u8]},
      {"Int16", Bytes[0x00_u8, 0x80_u8]},
      {"UInt16", Bytes[0x00_u8, 0x80_u8]},
      {"Int32", Bytes[0x00_u8, 0x00_u8, 0x00_u8, 0x80_u8]},
      {"UInt32", Bytes[0x00_u8, 0x00_u8, 0x00_u8, 0x80_u8]},
      {"Int128", Bytes.new(16, 0xa5_u8)},
      {"UInt128", Bytes.new(16, 0xa5_u8)},
      {"Int256", Bytes.new(32) { |index| (index * 7 + 1).to_u8 }},
      {"UInt256", Bytes.new(32) { |index| (index * 7 + 1).to_u8 }},
      {"BFloat16", Bytes[0x01_u8, 0x80_u8]},
    }

    numeric_cases.each do |type_name, raw_bytes|
      type = w117_type(type_name)
      value = CrystalClick::BinaryValue.fixed(type, raw_bytes)
      value.type.name.should eq(type_name)
      value.bytes.should eq(raw_bytes)
      encoded = CrystalClick::BinaryValueCodec.encode_value(value)
      encoded.should eq(raw_bytes)
      CrystalClick::BinaryValueCodec.decode_value(type, encoded).bytes.should eq(raw_bytes)
    end

    int256 = w117_type("Int256")
    uint256 = w117_type("UInt256")
    int_value = CrystalClick::BinaryValue.fixed(int256, Bytes.new(32, 0xa5_u8))
    uint_value = CrystalClick::BinaryValue.fixed(uint256, Bytes.new(32, 0xa5_u8))
    int_value.type.name.should_not eq(uint_value.type.name)

    int64 = CrystalClick::BinaryValue.int64(Int64::MIN)
    int64.as_int64.should eq(Int64::MIN)
    CrystalClick::BinaryValueCodec.encode_value(int64).should eq(
      Bytes[0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x80_u8]
    )
    uint64 = CrystalClick::BinaryValue.uint64(UInt64::MAX)
    uint64.as_uint64.should eq(UInt64::MAX)
    CrystalClick::BinaryValueCodec.encode_value(uint64).should eq(Bytes.new(8, 0xff_u8))

    float32_type = w117_type("Float32")
    [0x0000_0000_u32, 0x8000_0000_u32, 0x7fc0_0001_u32, 0x7fc0_0002_u32].each do |bits|
      value = CrystalClick::BinaryValue.float32_bits(bits)
      bytes = w117_u32_le(bits)
      CrystalClick::BinaryValueCodec.encode_value(value).should eq(bytes)
      decoded = CrystalClick::BinaryValueCodec.decode_value(float32_type, bytes)
      decoded.as_float32_bits.should eq(bits)
    end

    float64_type = w117_type("Float64")
    [
      0x0000_0000_0000_0000_u64,
      0x8000_0000_0000_0000_u64,
      0x7ff8_0000_0000_0001_u64,
      0x7ff8_0000_0000_0002_u64,
    ].each do |bits|
      value = CrystalClick::BinaryValue.float64_bits(bits)
      bytes = w117_u64_le(bits)
      CrystalClick::BinaryValueCodec.encode_value(value).should eq(bytes)
      decoded = CrystalClick::BinaryValueCodec.decode_value(float64_type, bytes)
      decoded.as_float64_bits.should eq(bits)
    end
  end

  it "keeps Bool scalar truth semantics separate from strict Nullable flags" do
    bool_type = w117_type("Bool")
    bool_value = CrystalClick::BinaryValue.bool(true)
    bool_value.as_bool.should be_true
    CrystalClick::BinaryValueCodec.encode_value(bool_value).should eq(Bytes[0x01_u8])
    CrystalClick::BinaryValueCodec.encode(bool_value).should eq(Bytes[0x2d_u8, 0x01_u8])
    [0x00_u8, 0x02_u8, 0xff_u8].each do |byte|
      decoded = CrystalClick::BinaryValueCodec.decode_value(bool_type, Bytes[byte])
      decoded.as_bool.should eq(byte != 0_u8)
      CrystalClick::BinaryValueCodec.encode_value(decoded).should eq(
        Bytes[byte == 0_u8 ? 0x00_u8 : 0x01_u8]
      )
    end

    nullable_bool = CrystalClick::BinaryDataType.nullable(bool_type)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_value(nullable_bool, Bytes[0x02_u8])
    end
  end

  it "preserves nominal empty arrays and recursively composes Array, Nullable, Tuple, and Map" do
    nullable_string_array = CrystalClick::BinaryDataType.array(
      CrystalClick::BinaryDataType.nullable(w117_type("String"))
    )
    nullable_int64_array = CrystalClick::BinaryDataType.array(
      CrystalClick::BinaryDataType.nullable(w117_type("Int64"))
    )
    independently_built_int64_array = CrystalClick::BinaryDataType.array(
      CrystalClick::BinaryDataType.nullable(w117_type("Int64"))
    )
    descriptor_hash = {nullable_int64_array => "nominal array"}
    descriptor_hash[independently_built_int64_array].should eq("nominal array")
    strings = CrystalClick::BinaryValue.array(
      nullable_string_array,
      [] of CrystalClick::BinaryValue
    )
    integers = CrystalClick::BinaryValue.array(
      nullable_int64_array,
      [] of CrystalClick::BinaryValue
    )
    CrystalClick::BinaryValueCodec.encode(strings).should eq(
      Bytes[0x1e_u8, 0x23_u8, 0x15_u8, 0x00_u8]
    )
    CrystalClick::BinaryValueCodec.encode(integers).should eq(
      Bytes[0x1e_u8, 0x23_u8, 0x0a_u8, 0x00_u8]
    )
    CrystalClick::BinaryValueCodec.decode(CrystalClick::BinaryValueCodec.encode(strings)).type.name.should eq(
      "Array(Nullable(String))"
    )
    CrystalClick::BinaryValueCodec.decode(CrystalClick::BinaryValueCodec.encode(integers)).type.name.should eq(
      "Array(Nullable(Int64))"
    )

    nullable_int64 = CrystalClick::BinaryDataType.nullable(w117_type("Int64"))
    nested_type = CrystalClick::BinaryDataType.array(nullable_int64)
    elements = [
      CrystalClick::BinaryValue.null(nullable_int64),
      CrystalClick::BinaryValue.nullable(nullable_int64, CrystalClick::BinaryValue.int64(42_i64)),
    ] of CrystalClick::BinaryValue
    nested = CrystalClick::BinaryValue.array(nested_type, elements)
    expected = Bytes[
      0x1e_u8, 0x23_u8, 0x0a_u8,
      0x02_u8, 0x01_u8, 0x00_u8,
      0x2a_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    ]
    encoded = CrystalClick::BinaryValueCodec.encode(nested)
    encoded.should eq(expected)
    (0...encoded.size).each do |length|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::BinaryValueCodec.decode(encoded[0, length])
      end
    end
    decoded = CrystalClick::BinaryValueCodec.decode(encoded)
    decoded.type.name.should eq(nested_type.name)
    decoded.elements.size.should eq(2)
    decoded.elements[0].is_null?.should be_true
    decoded.elements[1].is_null?.should be_false

    tuple_type = CrystalClick::BinaryDataType.tuple(
      [w117_type("String"), CrystalClick::BinaryDataType.array(nullable_int64)] of CrystalClick::BinaryDataType,
      ["text", "items"] of String
    )
    tuple = CrystalClick::BinaryValue.tuple(tuple_type, [
      CrystalClick::BinaryValue.string(String.new(Bytes[0x61_u8, 0x00_u8, 0xff_u8])),
      nested,
    ] of CrystalClick::BinaryValue)
    tuple_round_trip = CrystalClick::BinaryValueCodec.decode(CrystalClick::BinaryValueCodec.encode(tuple))
    tuple_round_trip.type.name.should eq(tuple_type.name)
    tuple_round_trip.elements[0].as_string.should eq(String.new(Bytes[0x61_u8, 0x00_u8, 0xff_u8]))

    # Nullable(Tuple(...)) is admitted by the pinned ClickHouse type model.
    nullable_tuple_type = CrystalClick::BinaryDataType.nullable(tuple_type)
    wrapped_tuple = CrystalClick::BinaryValue.nullable(nullable_tuple_type, tuple)
    CrystalClick::BinaryValueCodec.decode(CrystalClick::BinaryValueCodec.encode(wrapped_tuple)).type.name.should eq(
      nullable_tuple_type.name
    )
    null_tuple = CrystalClick::BinaryValue.null(nullable_tuple_type)
    CrystalClick::BinaryValueCodec.decode(CrystalClick::BinaryValueCodec.encode(null_tuple)).is_null?.should be_true

    # Tuple names are arbitrary descriptor bytes, not a whitelist of bare
    # identifiers. The raw field name survives descriptor round-trip.
    quoted_name = "with space.`tick`"
    quoted_tuple = CrystalClick::BinaryDataType.tuple(
      [w117_type("UInt8")] of CrystalClick::BinaryDataType,
      [quoted_name] of String
    )
    quoted_wire = Bytes[
      0x20_u8, 0x01_u8, 0x11_u8,
      0x77_u8, 0x69_u8, 0x74_u8, 0x68_u8, 0x20_u8,
      0x73_u8, 0x70_u8, 0x61_u8, 0x63_u8, 0x65_u8, 0x2e_u8,
      0x60_u8, 0x74_u8, 0x69_u8, 0x63_u8, 0x6b_u8, 0x60_u8,
      0x01_u8,
    ]
    quoted_tuple.name.should eq("Tuple(`with space.\\`tick\\`` UInt8)")
    CrystalClick::BinaryDataTypeCodec.encode(quoted_tuple).should eq(quoted_wire)
    CrystalClick::BinaryDataTypeCodec.decode(quoted_wire).field_names.should eq([quoted_name])

    map_type = CrystalClick::BinaryDataType.map(w117_type("String"), w117_type("UInt64"))
    ordered_duplicate_entries = [
      CrystalClick::BinaryValue.string("dup"), CrystalClick::BinaryValue.uint64(1_u64),
      CrystalClick::BinaryValue.string("dup"), CrystalClick::BinaryValue.uint64(2_u64),
    ] of CrystalClick::BinaryValue
    map = CrystalClick::BinaryValue.map(map_type, ordered_duplicate_entries)
    map_round_trip = CrystalClick::BinaryValueCodec.decode(CrystalClick::BinaryValueCodec.encode(map))
    map_round_trip.elements[0].as_string.should eq("dup")
    map_round_trip.elements[2].as_string.should eq("dup")
    map_round_trip.elements[1].as_uint64.should eq(1_u64)
    map_round_trip.elements[3].as_uint64.should eq(2_u64)
    CrystalClick::BinaryValueCodec.encode_value(map_round_trip).should eq(
      Bytes[
        0x02_u8,
        0x03_u8, 0x64_u8, 0x75_u8, 0x70_u8,
        0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
        0x03_u8, 0x64_u8, 0x75_u8, 0x70_u8,
        0x02_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      ]
    )

    map_with_composite_key = CrystalClick::BinaryDataType.map(
      CrystalClick::BinaryDataType.array(w117_type("Int64")),
      w117_type("String")
    )
    map_with_composite_key.name.should eq("Map(Array(Int64), String)")
    CrystalClick::BinaryDataTypeCodec.encode(map_with_composite_key).should eq(
      Bytes[0x27_u8, 0x1e_u8, 0x0a_u8, 0x15_u8]
    )
    composite_key = CrystalClick::BinaryValue.array(
      CrystalClick::BinaryDataType.array(w117_type("Int64")),
      [CrystalClick::BinaryValue.int64(1_i64), CrystalClick::BinaryValue.int64(2_i64)] of CrystalClick::BinaryValue
    )
    composite_map = CrystalClick::BinaryValue.map(map_with_composite_key, [
      composite_key,
      CrystalClick::BinaryValue.string("a"),
    ] of CrystalClick::BinaryValue)
    expected_composite_map = Bytes[
      0x27_u8, 0x1e_u8, 0x0a_u8, 0x15_u8,
      0x01_u8, # one map pair
      0x02_u8, # Array(Int64) key length
      0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x02_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x01_u8, 0x61_u8,
    ]
    CrystalClick::BinaryValueCodec.encode(composite_map).should eq(expected_composite_map)
    CrystalClick::BinaryValueCodec.decode(expected_composite_map).type.name.should eq(map_with_composite_key.name)
  end

  it "represents Nothing only as dynamic NULL and permits Nullable(Nothing) NULL" do
    dynamic_null = CrystalClick::BinaryValue.null
    dynamic_null.is_null?.should be_true
    dynamic_null.type.name.should eq("Nothing")
    CrystalClick::BinaryValueCodec.encode(dynamic_null).should eq(Bytes[0x00_u8])
    CrystalClick::BinaryValueCodec.decode(Bytes[0x00_u8]).is_null?.should be_true

    nothing = w117_type("Nothing")
    expect_raises(ArgumentError) do
      CrystalClick::BinaryValue.fixed(nothing, Bytes.empty)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.decode_value(nothing, Bytes.empty)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode_value(dynamic_null)
    end

    nullable_nothing = CrystalClick::BinaryDataType.nullable(nothing)
    value = CrystalClick::BinaryValue.null(nullable_nothing)
    encoded = CrystalClick::BinaryValueCodec.encode(value)
    encoded.should eq(Bytes[0x23_u8, 0x00_u8, 0x01_u8])
    CrystalClick::BinaryValueCodec.decode(encoded).is_null?.should be_true
    expect_raises(ArgumentError) do
      CrystalClick::BinaryValue.nullable(nullable_nothing, dynamic_null)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_value(nullable_nothing, Bytes[0x00_u8])
    end
  end

  it "constructs Nothing-typed children but refuses their ordinary scalar encoding" do
    nothing = w117_type("Nothing")
    dynamic_null = CrystalClick::BinaryValue.null(nothing)

    expect_raises(CrystalClick::UnsupportedFormatError) do
      array_type = CrystalClick::BinaryDataType.array(nothing)
      value = CrystalClick::BinaryValue.array(array_type, [dynamic_null] of CrystalClick::BinaryValue)
      CrystalClick::BinaryValueCodec.encode(value)
    end

    expect_raises(CrystalClick::UnsupportedFormatError) do
      tuple_type = CrystalClick::BinaryDataType.tuple(
        [nothing, w117_type("UInt8")] of CrystalClick::BinaryDataType
      )
      value = CrystalClick::BinaryValue.tuple(tuple_type, [
        dynamic_null,
        CrystalClick::BinaryValue.fixed(w117_type("UInt8"), Bytes[0x01_u8]),
      ] of CrystalClick::BinaryValue)
      CrystalClick::BinaryValueCodec.encode(value)
    end

    expect_raises(CrystalClick::UnsupportedFormatError) do
      map_type = CrystalClick::BinaryDataType.map(nothing, w117_type("String"))
      value = CrystalClick::BinaryValue.map(map_type, [
        dynamic_null,
        CrystalClick::BinaryValue.string("value"),
      ] of CrystalClick::BinaryValue)
      CrystalClick::BinaryValueCodec.encode(value)
    end
  end

  it "rejects deep descriptor children before large tuple child-array allocation" do
    count_wire = w117_var_uint(1_000_000_u64)
    tuple_wire = Bytes.new(count_wire.size + 1) do |index|
      index == 0 ? 0x1f_u8 : count_wire[index - 1]
    end
    limits = w117_limits(max_depth: 1, max_nodes: 1_000_001, max_elements: 1_000_000)

    # Warm the stats path and prepare inputs before measuring. This checks a
    # bounded allocation discriminator for this runtime, not RSS or speed.
    GC.stats
    before_bytes = GC.stats.total_bytes
    depth_error = expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(tuple_wire, limits)
    end
    allocated_bytes = GC.stats.total_bytes - before_bytes

    depth_error.to_s.should contain("depth")
    allocated_bytes.should be < 2_u64 * 1024_u64 * 1024_u64
  end

  it "detaches descriptor names, strings, fixed bytes, and recursive child arrays" do
    source_name = String.new(Bytes[0x53_u8, 0x74_u8, 0x72_u8, 0x69_u8, 0x6e_u8, 0x67_u8])
    type = CrystalClick::BinaryDataType.primitive(source_name)
    source_name.to_unsafe[0] = 0x58_u8
    type.name.should eq("String")
    exposed_name = type.name
    exposed_name.to_unsafe[0] = 0x59_u8
    type.name.should eq("String")

    string_source = String.new(Bytes[0x61_u8, 0x00_u8, 0xff_u8])
    string_value = CrystalClick::BinaryValue.string(string_source)
    string_source.to_unsafe[0] = 0x58_u8
    string_value.as_string.should eq(String.new(Bytes[0x61_u8, 0x00_u8, 0xff_u8]))
    exposed_string = string_value.as_string
    exposed_string.to_unsafe[0] = 0x59_u8
    string_value.as_string.should eq(String.new(Bytes[0x61_u8, 0x00_u8, 0xff_u8]))

    invalid_utf8 = String.new(Bytes[0xff_u8, 0x00_u8, 0x61_u8])
    invalid_utf8_value = CrystalClick::BinaryValue.string(invalid_utf8)
    encoded_invalid_utf8 = CrystalClick::BinaryValueCodec.encode_value(invalid_utf8_value)
    encoded_invalid_utf8.should eq(Bytes[0x03_u8, 0xff_u8, 0x00_u8, 0x61_u8])
    CrystalClick::BinaryValueCodec.decode_value(w117_type("String"), encoded_invalid_utf8).as_string.to_slice.should eq(
      Bytes[0xff_u8, 0x00_u8, 0x61_u8]
    )

    byte_source = Bytes[0x00_u8, 0xff_u8, 0x01_u8]
    fixed = CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.fixed_string(3), byte_source)
    byte_source[0] = 0x55_u8
    fixed.bytes.should eq(Bytes[0x00_u8, 0xff_u8, 0x01_u8])
    exposed_bytes = fixed.bytes
    exposed_bytes[1] = 0x44_u8
    fixed.bytes.should eq(Bytes[0x00_u8, 0xff_u8, 0x01_u8])

    child_types = [w117_type("UInt8"), w117_type("String")] of CrystalClick::BinaryDataType
    names = ["first", "second"] of String
    tuple_type = CrystalClick::BinaryDataType.tuple(child_types, names)
    child_types.clear
    names[0] = "changed"
    tuple_type.children.size.should eq(2)
    tuple_type.field_names.should eq(["first", "second"])
    children = tuple_type.children
    children.clear
    field_names = tuple_type.field_names
    field_names[0] = "changed"
    tuple_type.children.size.should eq(2)
    tuple_type.field_names.should eq(["first", "second"])

    array_type = CrystalClick::BinaryDataType.array(w117_type("UInt8"))
    source_elements = [CrystalClick::BinaryValue.fixed(w117_type("UInt8"), Bytes[0x01_u8])] of CrystalClick::BinaryValue
    array_value = CrystalClick::BinaryValue.array(array_type, source_elements)
    source_elements.clear
    array_value.elements.size.should eq(1)
    exposed_elements = array_value.elements
    exposed_elements.clear
    array_value.elements.size.should eq(1)
  end

  it "rejects inconsistent value payload types, widths, and container arity" do
    expect_raises(ArgumentError) do
      CrystalClick::BinaryValue.fixed(w117_type("Int64"), Bytes[0x01_u8])
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.fixed_string(2), Bytes[0x01_u8])
    end
    array_type = CrystalClick::BinaryDataType.array(w117_type("UInt8"))
    expect_raises(ArgumentError) do
      CrystalClick::BinaryValue.array(array_type, [CrystalClick::BinaryValue.string("wrong")] of CrystalClick::BinaryValue)
    end

    tuple_type = CrystalClick::BinaryDataType.tuple([w117_type("UInt8")] of CrystalClick::BinaryDataType)
    expect_raises(ArgumentError) do
      CrystalClick::BinaryValue.tuple(tuple_type, [] of CrystalClick::BinaryValue)
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryValue.tuple(tuple_type, [CrystalClick::BinaryValue.string("wrong")] of CrystalClick::BinaryValue)
    end

    map_type = CrystalClick::BinaryDataType.map(w117_type("String"), w117_type("UInt64"))
    expect_raises(ArgumentError) do
      CrystalClick::BinaryValue.map(map_type, [CrystalClick::BinaryValue.string("unpaired")] of CrystalClick::BinaryValue)
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryValue.map(map_type, [
        CrystalClick::BinaryValue.string("key"),
        CrystalClick::BinaryValue.string("wrong value type"),
      ] of CrystalClick::BinaryValue)
    end
  end

  it "requires exact descriptor and value consumption and rejects truncation" do
    descriptor = Bytes[0x1e_u8, 0x23_u8, 0x0a_u8]
    w117_corrupt_descriptor_prefixes(descriptor)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x0a_u8, 0x00_u8])
    end
    tuple_depth_error = expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(
        Bytes[0x1f_u8, 0x01_u8],
        w117_limits(max_depth: 1, max_nodes: 10, max_elements: 10)
      )
    end
    tuple_depth_error.to_s.should contain("depth")

    int64 = w117_type("Int64")
    w117_corrupt_value_prefixes(int64, Bytes[0x2a_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8])
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_value(int64, Bytes[0x2a_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8])
    end

    string_type = w117_type("String")
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_value(string_type, Bytes[0x03_u8, 0x61_u8])
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode(Bytes[0x01_u8, 0x07_u8, 0x00_u8])
    end
  end

  it "rejects nonminimal and overflowing VarUInts, malformed tags, and valid unsupported types distinctly" do
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x16_u8, 0x83_u8, 0x00_u8])
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x16_u8, 0x80_u8])
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(Bytes[
        0x16_u8,
        0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8,
        0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0x02_u8,
      ])
    end

    string_type = w117_type("String")
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_value(string_type, Bytes[0x80_u8, 0x00_u8])
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_value(string_type, Bytes[
        0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8,
        0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0x02_u8,
      ])
    end

    # W119 admits DateTime, W141 admits LowCardinality, W179 admits QBit, and
    # W180 admits a bounded JSON v0 profile. Keep a valid Custom(Point)
    # descriptor outside this general kernel as the refusal control.
    CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x11_u8]).should eq(CrystalClick::BinaryDataType.datetime)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x2c_u8, 0x05, 0x50, 0x6f, 0x69, 0x6e, 0x74])
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(Bytes[0xff_u8])
    end

    # This source-level hard ceiling remains in force even when caller budgets
    # are raised. The advertised count must be rejected before child allocation.
    tuple_count_wire = w117_var_uint(1_000_001_u64)
    too_many_tuple_fields = Bytes.new(tuple_count_wire.size + 1) do |index|
      index == 0 ? 0x1f_u8 : tuple_count_wire[index - 1]
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(
        too_many_tuple_fields,
        w117_limits(max_nodes: 2_000_100, max_elements: 2_000_100)
      )
    end
  end

  it "enforces exact depth, combined node, element, and byte budgets" do
    array_type = CrystalClick::BinaryDataType.array(w117_type("UInt8"))
    array_value = CrystalClick::BinaryValue.array(array_type, [
      CrystalClick::BinaryValue.fixed(w117_type("UInt8"), Bytes[0x11_u8]),
      CrystalClick::BinaryValue.fixed(w117_type("UInt8"), Bytes[0x22_u8]),
    ] of CrystalClick::BinaryValue)
    typed_bytes = CrystalClick::BinaryValueCodec.encode(array_value)

    CrystalClick::BinaryDataTypeCodec.decode(
      CrystalClick::BinaryDataTypeCodec.encode(array_type),
      w117_limits(max_depth: 2, max_nodes: 2, max_elements: 1, max_bytes: 2)
    ).name.should eq(array_type.name)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(
        CrystalClick::BinaryDataTypeCodec.encode(array_type),
        w117_limits(max_depth: 1)
      )
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(
        CrystalClick::BinaryDataTypeCodec.encode(array_type),
        w117_limits(max_elements: 0)
      )
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(
        CrystalClick::BinaryDataTypeCodec.encode(array_type),
        w117_limits(max_bytes: 1)
      )
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(
        CrystalClick::BinaryDataTypeCodec.encode(array_type),
        w117_limits(max_nodes: 1)
      )
    end

    CrystalClick::BinaryValueCodec.decode_value(
      array_type,
      Bytes[0x02_u8, 0x11_u8, 0x22_u8],
      w117_limits(max_depth: 2, max_nodes: 5, max_elements: 3, max_bytes: 3)
    ).elements.size.should eq(2)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_value(
        array_type,
        Bytes[0x02_u8, 0x11_u8, 0x22_u8],
        w117_limits(max_depth: 1)
      )
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_value(
        array_type,
        Bytes[0x02_u8, 0x11_u8, 0x22_u8],
        w117_limits(max_elements: 2)
      )
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_value(
        array_type,
        Bytes[0x02_u8, 0x11_u8, 0x22_u8],
        w117_limits(max_nodes: 4)
      )
    end

    nullable_int64_type = CrystalClick::BinaryDataType.nullable(w117_type("Int64"))
    non_null_nullable = CrystalClick::BinaryValue.nullable(
      nullable_int64_type,
      CrystalClick::BinaryValue.int64(7_i64)
    )
    nullable_wire = Bytes[
      0x00_u8, 0x07_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
    ]
    CrystalClick::BinaryValueCodec.encode_value(
      non_null_nullable,
      w117_limits(max_depth: 2, max_nodes: 4, max_elements: 2, max_bytes: 9)
    ).should eq(nullable_wire)
    CrystalClick::BinaryValueCodec.decode_value(
      nullable_int64_type,
      nullable_wire,
      w117_limits(max_depth: 2, max_nodes: 4, max_elements: 2, max_bytes: 9)
    ).elements[0].as_int64.should eq(7_i64)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_value(
        nullable_int64_type,
        nullable_wire,
        w117_limits(max_depth: 2, max_nodes: 4, max_elements: 1, max_bytes: 9)
      )
    end

    # One Array descriptor child plus two value elements share one element cap.
    CrystalClick::BinaryValueCodec.decode(typed_bytes, w117_limits(max_elements: 3)).elements.size.should eq(2)
    # Exact combined budget: type descriptor (2 nodes), value tree (3 nodes),
    # one descriptor edge plus two Array elements, and five wire bytes.
    CrystalClick::BinaryValueCodec.decode(
      typed_bytes,
      w117_limits(max_depth: 2, max_nodes: 5, max_elements: 3, max_bytes: 5)
    ).elements.size.should eq(2)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode(typed_bytes, w117_limits(max_elements: 2))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode(typed_bytes, w117_limits(max_nodes: 4))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode(typed_bytes, w117_limits(max_depth: 1))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode(typed_bytes, w117_limits(max_bytes: 4))
    end
    # Typed-envelope node accounting includes both the descriptor and value trees.
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode(
        CrystalClick::BinaryValueCodec.encode(CrystalClick::BinaryValue.uint64(1_u64)),
        w117_limits(max_nodes: 1)
      )
    end

    string_value = CrystalClick::BinaryValue.string("abc")
    string_wire = Bytes[0x03_u8, 0x61_u8, 0x62_u8, 0x63_u8]
    CrystalClick::BinaryValueCodec.decode_value(w117_type("String"), string_wire, w117_limits(max_bytes: 4)).as_string.should eq("abc")
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_value(w117_type("String"), string_wire, w117_limits(max_bytes: 3))
    end
    CrystalClick::BinaryValueCodec.encode_value(string_value, w117_limits(max_bytes: 4)).should eq(string_wire)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode_value(string_value, w117_limits(max_bytes: 3))
    end
    CrystalClick::BinaryValueCodec.encode(array_value, w117_limits(max_bytes: typed_bytes.size)).should eq(typed_bytes)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode(array_value, w117_limits(max_bytes: typed_bytes.size - 1))
    end

    # The declared count must be charged before reserve/allocation or reading
    # children; the missing children do not turn an over-budget count into an
    # unbounded allocation attempt.
    large_array_count = w117_var_uint(100_000_u64)
    preflight_error = expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_value(
        CrystalClick::BinaryDataType.array(
          CrystalClick::BinaryDataType.tuple([w117_type("UInt8")] of CrystalClick::BinaryDataType)
        ),
        large_array_count,
        w117_limits(max_nodes: 8, max_elements: 100_002)
      )
    end
    preflight_error.to_s.should contain("node")

    large_map_count = w117_var_uint(100_000_u64)
    map_preflight_error = expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_value(
        CrystalClick::BinaryDataType.map(
          CrystalClick::BinaryDataType.tuple([w117_type("UInt8")] of CrystalClick::BinaryDataType),
          CrystalClick::BinaryDataType.tuple([w117_type("UInt8")] of CrystalClick::BinaryDataType)
        ),
        large_map_count,
        w117_limits(max_nodes: 10, max_elements: 200_100)
      )
    end
    map_preflight_error.to_s.should contain("node")

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_value(array_type, Bytes[0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0x0f_u8], w117_limits(max_elements: 2))
    end
  end
end
