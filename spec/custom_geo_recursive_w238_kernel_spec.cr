require "./spec_helper"

private def w238_var_uint(value : UInt64) : Bytes
  bytes = [] of UInt8
  remaining = value
  loop do
    payload = (remaining & 0x7f_u64).to_u8
    remaining >>= 7
    bytes << (remaining == 0_u64 ? payload : payload | 0x80_u8)
    break if remaining == 0_u64
  end
  Bytes.new(bytes.size) { |index| bytes[index] }
end

private def w238_join(parts : Array(Bytes)) : Bytes
  bytes = [] of UInt8
  parts.each { |part| bytes.concat(part.to_a) }
  Bytes.new(bytes.size) { |index| bytes[index] }
end

private def w238_custom_descriptor(name : String) : Bytes
  name_bytes = name.to_slice
  bytes = [] of UInt8
  bytes << 0x2c_u8 # ClickHouse binary DataTypeCustom
  bytes.concat(w238_var_uint(name_bytes.size.to_u64).to_a)
  bytes.concat(name_bytes.to_a)
  Bytes.new(bytes.size) { |index| bytes[index] }
end

private def w238_array_descriptor(child : Bytes) : Bytes
  w238_join([Bytes[0x1e_u8], child] of Bytes)
end

private def w238_array_body(elements : Array(Bytes)) : Bytes
  parts = [w238_var_uint(elements.size.to_u64)] of Bytes
  parts.concat(elements)
  w238_join(parts)
end

private def w238_u64_le(value : UInt64) : Bytes
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

private def w238_point_value(type : CrystalClick::BinaryDataType) : CrystalClick::BinaryValue
  coordinates = type.child_at(0)
  body = CrystalClick::BinaryValue.tuple(
    coordinates,
    [
      CrystalClick::BinaryValue.float64_bits(0x3ff0_0000_0000_0000_u64),
      CrystalClick::BinaryValue.float64_bits(0x4000_0000_0000_0000_u64),
    ] of CrystalClick::BinaryValue,
  )
  CrystalClick::BinaryValue.custom(type, body)
end

describe "W238 nominal Custom Geo recursive scalar codec" do
  it "round-trips all seven name-only descriptors without collapsing aliases" do
    names = [
      "Point",
      "MultiPoint",
      "LineString",
      "Ring",
      "MultiLineString",
      "Polygon",
      "MultiPolygon",
    ]

    names.each do |name|
      descriptor = w238_custom_descriptor(name)
      decoded = CrystalClick::BinaryDataTypeCodec.decode(descriptor)

      decoded.name.should eq(name)
      decoded.should eq(CrystalClick::BinaryDataType.custom(name))
      decoded.contains_custom_geo?.should be_true
      CrystalClick::BinaryDataTypeCodec.encode(decoded).should eq(descriptor)
    end

    multipoint = CrystalClick::BinaryDataTypeCodec.decode(w238_custom_descriptor("MultiPoint"))
    line_string = CrystalClick::BinaryDataTypeCodec.decode(w238_custom_descriptor("LineString"))
    ring = CrystalClick::BinaryDataTypeCodec.decode(w238_custom_descriptor("Ring"))
    multipoint.name.should_not eq(line_string.name)
    line_string.name.should_not eq(ring.name)
    multipoint.name.should_not eq(ring.name)

    multipoint_wire = w238_custom_descriptor("MultiPoint")
    line_string_wire = w238_custom_descriptor("LineString")
    ring_wire = w238_custom_descriptor("Ring")
    multipoint_wire.should_not eq(line_string_wire)
    line_string_wire.should_not eq(ring_wire)
    multipoint_wire.should_not eq(ring_wire)
    multipoint.should_not eq(line_string)
    line_string.should_not eq(ring)
    ring.should_not eq(multipoint)
    multipoint.child_at(0).should eq(line_string.child_at(0))
  end

  it "charges each compact Custom descriptor for its hidden storage graph" do
    profiles = {
      {"Point", 4, 3, 3},
      {"MultiPoint", 6, 5, 5},
      {"LineString", 6, 5, 5},
      {"Ring", 6, 5, 5},
      {"MultiLineString", 8, 7, 7},
      {"Polygon", 8, 7, 7},
      {"MultiPolygon", 10, 9, 9},
    }

    profiles.each do |profile|
      name, nodes, edges, depth = profile
      type = CrystalClick::BinaryDataType.custom(name)
      limits = CrystalClick::BinaryCodecLimits.new(
        max_depth: depth,
        max_nodes: nodes,
        max_elements: edges,
        max_bytes: 128,
      )
      wire = CrystalClick::BinaryDataTypeCodec.encode(type, limits)
      CrystalClick::BinaryDataTypeCodec.decode(wire, limits).should eq(type)

      node_short = CrystalClick::BinaryCodecLimits.new(
        max_depth: depth,
        max_nodes: nodes - 1,
        max_elements: edges,
        max_bytes: 128,
      )
      expect_raises(CrystalClick::UnsupportedFormatError, "node limit") do
        CrystalClick::BinaryDataTypeCodec.encode(type, node_short)
      end
      expect_raises(CrystalClick::CorruptPartError, "node limit") do
        CrystalClick::BinaryDataTypeCodec.decode(wire, node_short)
      end

      edge_short = CrystalClick::BinaryCodecLimits.new(
        max_depth: depth,
        max_nodes: nodes,
        max_elements: edges - 1,
        max_bytes: 128,
      )
      expect_raises(CrystalClick::UnsupportedFormatError, "element limit") do
        CrystalClick::BinaryDataTypeCodec.encode(type, edge_short)
      end
      expect_raises(CrystalClick::CorruptPartError, "element limit") do
        CrystalClick::BinaryDataTypeCodec.decode(wire, edge_short)
      end

      depth_short = CrystalClick::BinaryCodecLimits.new(
        max_depth: depth - 1,
        max_nodes: nodes,
        max_elements: edges,
        max_bytes: 128,
      )
      expect_raises(CrystalClick::UnsupportedFormatError, "depth limit") do
        CrystalClick::BinaryDataTypeCodec.encode(type, depth_short)
      end
      expect_raises(CrystalClick::CorruptPartError, "depth limit") do
        CrystalClick::BinaryDataTypeCodec.decode(wire, depth_short)
      end
    end
  end

  it "keeps Point nominally distinct from its Tuple storage body" do
    point_wire = w238_custom_descriptor("Point")
    point_type = CrystalClick::BinaryDataTypeCodec.decode(point_wire)
    tuple_type = CrystalClick::BinaryDataTypeCodec.decode(
      Bytes[0x1f_u8, 0x02_u8, 0x0e_u8, 0x0e_u8]
    )

    point_type.name.should eq("Point")
    tuple_type.name.should eq("Tuple(Float64, Float64)")
    CrystalClick::BinaryDataTypeCodec.encode(point_type).should eq(point_wire)
    CrystalClick::BinaryDataTypeCodec.encode(point_type).should_not eq(
      CrystalClick::BinaryDataTypeCodec.encode(tuple_type)
    )

    point_body = w238_join([
      w238_u64_le(0x3ff0_0000_0000_0000_u64),
      w238_u64_le(0x4000_0000_0000_0000_u64),
    ] of Bytes)
    point_value = CrystalClick::BinaryValueCodec.decode_value(point_type, point_body)
    tuple_value = CrystalClick::BinaryValueCodec.decode_value(tuple_type, point_body)
    CrystalClick::BinaryValueCodec.encode_value(point_value).should eq(point_body)
    CrystalClick::BinaryValueCodec.encode_value(tuple_value).should eq(point_body)

    full_point_wire = w238_join([point_wire, point_body] of Bytes)
    decoded_full_point = CrystalClick::BinaryValueCodec.decode(full_point_wire)
    decoded_full_point.type.name.should eq("Point")
    CrystalClick::BinaryValueCodec.encode(decoded_full_point).should eq(full_point_wire)
  end

  it "admits only the Tuple-backed Point beneath Nullable and validates its body" do
    point_type = CrystalClick::BinaryDataType.custom("Point")
    nullable_type = CrystalClick::BinaryDataType.nullable(point_type)
    nullable_descriptor = w238_join([
      Bytes[0x23_u8],
      w238_custom_descriptor("Point"),
    ] of Bytes)

    decoded_type = CrystalClick::BinaryDataTypeCodec.decode(nullable_descriptor)
    decoded_type.should eq(nullable_type)
    CrystalClick::BinaryDataTypeCodec.encode(decoded_type).should eq(nullable_descriptor)

    point_value = w238_point_value(point_type)
    point_body = w238_join([
      w238_u64_le(0x3ff0_0000_0000_0000_u64),
      w238_u64_le(0x4000_0000_0000_0000_u64),
    ] of Bytes)
    nullable_present = CrystalClick::BinaryValue.nullable(nullable_type, point_value)
    nullable_absent = CrystalClick::BinaryValue.null(nullable_type)

    CrystalClick::BinaryValueCodec.encode_value(nullable_present).should eq(w238_join([Bytes[0_u8], point_body] of Bytes))
    CrystalClick::BinaryValueCodec.encode_value(nullable_absent).should eq(Bytes[1_u8])
    decoded_present = CrystalClick::BinaryValueCodec.decode_value(nullable_type, w238_join([Bytes[0_u8], point_body] of Bytes))
    decoded_present.is_null?.should be_false
    decoded_present.child_at(0).type.should eq(point_type)
    CrystalClick::BinaryValueCodec.encode_value(decoded_present).should eq(w238_join([Bytes[0_u8], point_body] of Bytes))
    decoded_absent = CrystalClick::BinaryValueCodec.decode_value(nullable_type, Bytes[1_u8])
    decoded_absent.is_null?.should be_true
    CrystalClick::BinaryValueCodec.encode_value(decoded_absent).should eq(Bytes[1_u8])

    wrong_storage = CrystalClick::BinaryDataType.tuple([
      CrystalClick::BinaryDataType.primitive("Float32"),
      CrystalClick::BinaryDataType.primitive("Float32"),
    ] of CrystalClick::BinaryDataType)
    wrong_body = CrystalClick::BinaryValue.tuple(
      wrong_storage,
      [
        CrystalClick::BinaryValue.float32_bits(0x3f80_0000_u32),
        CrystalClick::BinaryValue.float32_bits(0x4000_0000_u32),
      ] of CrystalClick::BinaryValue,
    )
    expect_raises(ArgumentError, "exact storage descriptor") do
      CrystalClick::BinaryValue.custom(point_type, wrong_body)
    end
  end

  it "keeps Custom Geo out of Dynamic actuals and JSON value profiles" do
    point_type = CrystalClick::BinaryDataType.custom("Point")
    point_value = w238_point_value(point_type)

    expect_raises(ArgumentError, "Custom Geo") do
      CrystalClick::BinaryValue.dynamic(CrystalClick::BinaryDataType.dynamic, point_value)
    end
    expect_raises(CrystalClick::UnsupportedFormatError, "Custom Geo") do
      CrystalClick::BinaryValueCodec.encode_dynamic_bulk_child(
        point_value,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
        1,
      )
    end

    envelope = w238_join([
      w238_custom_descriptor("Point"),
      w238_join([
        w238_u64_le(0x3ff0_0000_0000_0000_u64),
        w238_u64_le(0x4000_0000_0000_0000_u64),
      ] of Bytes),
    ] of Bytes)
    expect_raises(CrystalClick::UnsupportedFormatError, "Custom Geo") do
      CrystalClick::BinaryValueCodec.decode_dynamic_bulk_child(
        envelope,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
        1,
      )
    end

    expect_raises(ArgumentError, "typed JSON schema") do
      CrystalClick::BinaryDataType.json(typed_paths: {"geom" => point_type})
    end

    json_type = CrystalClick::BinaryDataType.json
    expect_raises(ArgumentError, "JSON runtime value type") do
      CrystalClick::BinaryJsonRow.new(json_type, [{"geom", point_value}] of Tuple(String, CrystalClick::BinaryValue))
    end
  end

  it "reuses one Array(Point) body grammar for aliases with distinct nominal names" do
    point = w238_join([
      w238_u64_le(0x3ff0_0000_0000_0000_u64),
      w238_u64_le(0x4000_0000_0000_0000_u64),
    ] of Bytes)
    body = w238_array_body([point] of Bytes)

    ["MultiPoint", "LineString", "Ring"].each do |name|
      descriptor = w238_custom_descriptor(name)
      type = CrystalClick::BinaryDataTypeCodec.decode(descriptor)
      value = CrystalClick::BinaryValueCodec.decode_value(type, body)

      type.name.should eq(name)
      CrystalClick::BinaryValueCodec.encode_value(value).should eq(body)
      CrystalClick::BinaryValueCodec.encode(value).should eq(w238_join([descriptor, body] of Bytes))
    end

    empty_body = w238_array_body([] of Bytes)
    ring_type = CrystalClick::BinaryDataTypeCodec.decode(w238_custom_descriptor("Ring"))
    empty_ring = CrystalClick::BinaryValueCodec.decode_value(ring_type, empty_body)
    CrystalClick::BinaryValueCodec.encode_value(empty_ring).should eq(empty_body)

    nested_body = w238_array_body([w238_array_body([point] of Bytes)] of Bytes)
    ["MultiLineString", "Polygon"].each do |name|
      descriptor = w238_custom_descriptor(name)
      type = CrystalClick::BinaryDataTypeCodec.decode(descriptor)
      value = CrystalClick::BinaryValueCodec.decode_value(type, nested_body)

      type.name.should eq(name)
      CrystalClick::BinaryValueCodec.encode_value(value).should eq(nested_body)
      CrystalClick::BinaryValueCodec.encode(value).should eq(w238_join([descriptor, nested_body] of Bytes))
    end

    recursive_type = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical("Array(Point)").not_nil!
    recursive_type.name.should eq("Array(Point)")
    recursive_type.contains_custom_geo?.should be_true
  end

  it "recursively preserves ragged, empty, and populated MultiPolygon paths" do
    point_a = w238_join([
      w238_u64_le(0x3ff0_0000_0000_0000_u64),
      w238_u64_le(0x4000_0000_0000_0000_u64),
    ] of Bytes)
    point_b = w238_join([
      w238_u64_le(0x4008_0000_0000_0000_u64),
      w238_u64_le(0x4010_0000_0000_0000_u64),
    ] of Bytes)

    empty_ring = w238_array_body([] of Bytes)
    one_point_ring = w238_array_body([point_a] of Bytes)
    two_point_ring = w238_array_body([point_a, point_b] of Bytes)
    first_polygon = w238_array_body([one_point_ring] of Bytes)
    second_polygon = w238_array_body([empty_ring, two_point_ring] of Bytes)
    body = w238_array_body([first_polygon, second_polygon] of Bytes)

    descriptor = w238_custom_descriptor("MultiPolygon")
    type = CrystalClick::BinaryDataTypeCodec.decode(descriptor)
    value = CrystalClick::BinaryValueCodec.decode_value(type, body)

    type.name.should eq("MultiPolygon")
    CrystalClick::BinaryValueCodec.encode_value(value).should eq(body)
    CrystalClick::BinaryValueCodec.encode(value).should eq(w238_join([descriptor, body] of Bytes))
  end

  it "owns borrowed descriptor names and value bodies after decoding" do
    descriptor = w238_custom_descriptor("Point")
    retained_descriptor = w238_custom_descriptor("Point")
    type = CrystalClick::BinaryDataTypeCodec.decode(descriptor)
    descriptor[2] = 'X'.ord.to_u8
    type.name.should eq("Point")
    CrystalClick::BinaryDataTypeCodec.encode(type).should eq(retained_descriptor)

    body = w238_join([
      w238_u64_le(0x3ff0_0000_0000_0000_u64),
      w238_u64_le(0x4000_0000_0000_0000_u64),
    ] of Bytes)
    retained_body = w238_join([body] of Bytes)
    value = CrystalClick::BinaryValueCodec.decode_value(type, body)
    body[0] = 0xff_u8
    CrystalClick::BinaryValueCodec.encode_value(value).should eq(retained_body)
  end

  it "rejects truncated or trailing descriptor and value bytes" do
    point_descriptor = w238_custom_descriptor("Point")
    truncated_descriptor = point_descriptor[0, point_descriptor.size - 1]
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(truncated_descriptor)
    end

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(w238_join([point_descriptor, Bytes[0x00_u8]] of Bytes))
    end

    point_type = CrystalClick::BinaryDataTypeCodec.decode(point_descriptor)
    point_body = Bytes.new(16) { |index| index.to_u8 }
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_value(point_type, point_body[0, 15])
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_value(point_type, w238_join([point_body, Bytes[0x00_u8]] of Bytes))
    end
  end

  it "keeps unknown Custom names, Geometry, invalid Nullable aliases, and LowCardinality guarded" do
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.decode(w238_custom_descriptor("NotAGeoAlias"))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.decode(w238_custom_descriptor("Geometry"))
    end

    nullable_array_alias = w238_join([
      Bytes[0x23_u8], # Nullable
      w238_custom_descriptor("MultiPoint"),
    ] of Bytes)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(nullable_array_alias)
    end

    low_cardinality_geo = w238_join([
      Bytes[0x26_u8], # LowCardinality
      w238_custom_descriptor("Point"),
    ] of Bytes)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(low_cardinality_geo)
    end
  end

  it "retains the existing ordinary Array(Tuple) control" do
    tuple_descriptor = Bytes[0x1f_u8, 0x02_u8, 0x0e_u8, 0x0e_u8]
    array_descriptor = w238_array_descriptor(tuple_descriptor)
    type = CrystalClick::BinaryDataTypeCodec.decode(array_descriptor)
    body = w238_array_body([
      w238_join([w238_u64_le(0x3ff0_0000_0000_0000_u64), w238_u64_le(0x4000_0000_0000_0000_u64)] of Bytes),
      w238_join([w238_u64_le(0x4008_0000_0000_0000_u64), w238_u64_le(0x4010_0000_0000_0000_u64)] of Bytes),
    ] of Bytes)

    value = CrystalClick::BinaryValueCodec.decode_value(type, body)
    type.name.should eq("Array(Tuple(Float64, Float64))")
    CrystalClick::BinaryValueCodec.encode_value(value).should eq(body)
  end
end
