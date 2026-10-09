require "./spec_helper"

private def w239_join(parts : Array(Bytes)) : Bytes
  bytes = [] of UInt8
  parts.each { |part| bytes.concat(part.to_a) }
  Bytes.new(bytes.size) { |index| bytes[index] }
end

private def w239_geometry_descriptor : Bytes
  # Custom tag, VarUInt(8), and the nominal name only; no Variant roster.
  Bytes[0x2c_u8, 0x08_u8, 0x47_u8, 0x65_u8, 0x6f_u8, 0x6d_u8, 0x65_u8, 0x74_u8, 0x72_u8, 0x79_u8]
end

private def w239_geometry_row(discriminator : UInt8) : Bytes
  case discriminator
  when 0_u8, 1_u8, 2_u8, 4_u8, 5_u8, 6_u8
    # Empty Array bodies exercise each nominal arm without hiding the global
    # discriminator behind a locally selected alias.
    Bytes[discriminator, 0_u8]
  when 3_u8
    # Point is Tuple(Float64, Float64), both coordinates exactly zero.
    Bytes.new(17) { |index| index == 0 ? discriminator : 0_u8 }
  else
    raise ArgumentError.new("Geometry discriminator is outside the fixed seven-arm roster")
  end
end

describe "W239 nominal Geometry recursive scalar codec" do
  it "reads the name-only nominal descriptor and preserves all seven persisted global discriminators" do
    descriptor = w239_geometry_descriptor
    type = CrystalClick::BinaryDataTypeCodec.decode(descriptor)

    type.tag.should eq(CrystalClick::BinaryDataType::TAG_CUSTOM)
    type.name.should eq("Geometry")
    type.custom_geo_type.not_nil!.profile.should eq(CrystalClick::BinaryCustomGeoType::Profile::Geometry)
    type.child_count.should eq(1)
    storage = type.child_at(0)
    storage.tag.should eq(CrystalClick::BinaryDataType::TAG_VARIANT)
    storage.geometry_storage_variant?.should be_true
    borrowed_arms = storage.children
    borrowed_arms.clear
    storage.child_count.should eq(7)
    storage.children.map(&.name).should eq([
      "LineString",
      "MultiLineString",
      "MultiPolygon",
      "Point",
      "Polygon",
      "Ring",
      "MultiPoint",
    ] of String)
    CrystalClick::BinaryDataTypeCodec.encode(type).should eq(descriptor)

    (0..6).each do |index|
      discriminator = index.to_u8
      row = w239_geometry_row(discriminator)
      wire = w239_join([descriptor, row] of Bytes)
      value = CrystalClick::BinaryValueCodec.decode(wire)

      value.type.should eq(type)
      value.type.name.should eq("Geometry")
      value.child_at(0).variant_index?.should eq(discriminator)
      CrystalClick::BinaryValueCodec.encode(value).should eq(wire)
    end

    null_wire = w239_join([descriptor, Bytes[0xff_u8]] of Bytes)
    null_value = CrystalClick::BinaryValueCodec.decode(null_wire)
    null_value.type.should eq(type)
    null_value.child_at(0).is_null?.should be_true
    null_value.child_at(0).variant_index?.should be_nil
    CrystalClick::BinaryValueCodec.encode(null_value).should eq(null_wire)

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(descriptor[0, descriptor.size - 1])
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(w239_join([descriptor, Bytes[0_u8]] of Bytes))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode(w239_join([descriptor, Bytes[7_u8]] of Bytes))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode(w239_join([descriptor, Bytes[3_u8]] of Bytes))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode(w239_join([descriptor, Bytes[0xff_u8, 0_u8]] of Bytes))
    end
  end

  it "keeps Geometry's fixed roster distinct from an ordinary name-sorted Variant" do
    geometry = CrystalClick::BinaryDataTypeCodec.decode(w239_geometry_descriptor)
    aliases = [
      CrystalClick::BinaryDataType.custom("LineString"),
      CrystalClick::BinaryDataType.custom("MultiLineString"),
      CrystalClick::BinaryDataType.custom("MultiPolygon"),
      CrystalClick::BinaryDataType.custom("Point"),
      CrystalClick::BinaryDataType.custom("Polygon"),
      CrystalClick::BinaryDataType.custom("Ring"),
      CrystalClick::BinaryDataType.custom("MultiPoint"),
    ] of CrystalClick::BinaryDataType
    ordinary = CrystalClick::BinaryDataType.variant(aliases)

    geometry.child_at(0).children.map(&.name).should eq([
      "LineString",
      "MultiLineString",
      "MultiPolygon",
      "Point",
      "Polygon",
      "Ring",
      "MultiPoint",
    ] of String)
    ordinary.children.map(&.name).should eq([
      "LineString",
      "MultiLineString",
      "MultiPoint",
      "MultiPolygon",
      "Point",
      "Polygon",
      "Ring",
    ] of String)
    geometry.name.should eq("Geometry")
    CrystalClick::BinaryDataTypeCodec.encode(geometry).should eq(w239_geometry_descriptor)
    geometry.variant_type_id?.should be_true
    ordinary.variant_type_id?.should be_true
    CrystalClick::BinaryDataType.array(geometry).variant_type_id?.should be_false
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.encode(geometry.child_at(0))
    end
  end

  it "charges the complete hidden Geometry expansion at exact and one-short bounds" do
    descriptor = w239_geometry_descriptor
    exact = CrystalClick::BinaryCodecLimits.new(
      max_depth: 11,
      max_nodes: 50,
      max_elements: 49,
      max_bytes: 64,
    )
    geometry = CrystalClick::BinaryDataTypeCodec.decode(descriptor, exact)
    CrystalClick::BinaryDataTypeCodec.encode(geometry, exact).should eq(descriptor)

    node_short = CrystalClick::BinaryCodecLimits.new(
      max_depth: 11,
      max_nodes: 49,
      max_elements: 49,
      max_bytes: 64,
    )
    expect_raises(CrystalClick::CorruptPartError, "node limit") do
      CrystalClick::BinaryDataTypeCodec.decode(descriptor, node_short)
    end
    expect_raises(CrystalClick::UnsupportedFormatError, "node limit") do
      CrystalClick::BinaryDataTypeCodec.encode(geometry, node_short)
    end

    edge_short = CrystalClick::BinaryCodecLimits.new(
      max_depth: 11,
      max_nodes: 50,
      max_elements: 48,
      max_bytes: 64,
    )
    expect_raises(CrystalClick::CorruptPartError, "element limit") do
      CrystalClick::BinaryDataTypeCodec.decode(descriptor, edge_short)
    end
    expect_raises(CrystalClick::UnsupportedFormatError, "element limit") do
      CrystalClick::BinaryDataTypeCodec.encode(geometry, edge_short)
    end

    depth_short = CrystalClick::BinaryCodecLimits.new(
      max_depth: 10,
      max_nodes: 50,
      max_elements: 49,
      max_bytes: 64,
    )
    expect_raises(CrystalClick::CorruptPartError, "depth limit") do
      CrystalClick::BinaryDataTypeCodec.decode(descriptor, depth_short)
    end
    expect_raises(CrystalClick::UnsupportedFormatError, "depth limit") do
      CrystalClick::BinaryDataTypeCodec.encode(geometry, depth_short)
    end
  end
end
