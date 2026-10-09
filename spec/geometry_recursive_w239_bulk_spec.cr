require "./spec_helper"
require "./support/geometry_recursive_w239_fixture"

private def w239b_concat(parts : Array(Bytes)) : Bytes
  joined = [] of UInt8
  parts.each { |part| joined.concat(part.to_a) }
  Bytes.new(joined.size) { |index| joined[index] }
end

private W239_GEOMETRY_ROLES = [
  "root.discriminators",
  "root.arm.0.sizes",
  "root.arm.0.elements.field.0.data",
  "root.arm.0.elements.field.1.data",
  "root.arm.1.sizes",
  "root.arm.1.elements.sizes",
  "root.arm.1.elements.elements.field.0.data",
  "root.arm.1.elements.elements.field.1.data",
  "root.arm.2.sizes",
  "root.arm.2.elements.sizes",
  "root.arm.2.elements.elements.sizes",
  "root.arm.2.elements.elements.elements.field.0.data",
  "root.arm.2.elements.elements.elements.field.1.data",
  "root.arm.3.field.0.data",
  "root.arm.3.field.1.data",
  "root.arm.4.sizes",
  "root.arm.4.elements.sizes",
  "root.arm.4.elements.elements.field.0.data",
  "root.arm.4.elements.elements.field.1.data",
  "root.arm.5.sizes",
  "root.arm.5.elements.field.0.data",
  "root.arm.5.elements.field.1.data",
  "root.arm.6.sizes",
  "root.arm.6.elements.field.0.data",
  "root.arm.6.elements.field.1.data",
] of String

describe "W239 nominal Geometry shared bulk visitors" do
  it "retains the 25 fixed-order arm roles and round-trips seven tags plus intrinsic null across sparse marks" do
    fixture = W239GeometryFixture.new
    begin
      type = fixture.geometry_type
      plan = CrystalClick::BinaryBulkTypePlan.new(type, CrystalClick::BinaryBulkProfile.single_stream)
      plan.roles.should eq(W239_GEOMETRY_ROLES.sort)
      plan.role_count.should eq(25_u64)
      plan.roles.should_not contain("root.arm.7.sizes")
      fixture.geometry_marks.map(&.size).should eq([4, 4, 3])

      expected_tags = [255_u8, 0_u8, 3_u8, 6_u8, 4_u8, 1_u8, 2_u8, 5_u8, 0_u8, 3_u8, 255_u8]
      fixture.geometry_marks.flatten.each_with_index do |value, index|
        value.type.name.should eq("Geometry")
        value.child_at(0).type.geometry_storage_variant?.should be_true
        value.child_at(0).variant_index?.should eq(
          expected_tags[index] == 255_u8 ? nil : expected_tags[index].to_i,
        )
      end

      streams = CrystalClick::BinaryBulkCodec.encode(type, fixture.geometry_marks)
      streams.roles.should eq(W239_GEOMETRY_ROLES.sort)
      decoded = CrystalClick::BinaryBulkCodec.decode(
        type, streams, [4_u64, 4_u64, 3_u64],
      )
      w239g_assert_marks(decoded, fixture.geometry_marks)
    ensure
      fixture.close
    end
  end

  it "keeps RowBinary Geometry literals independent of the bulk lane visitor" do
    geometry = CrystalClick::BinaryDataType.custom("Geometry")
    descriptor = Bytes[0x2c_u8, 0x08_u8, 0x47_u8, 0x65_u8, 0x6f_u8, 0x6d_u8, 0x65_u8, 0x74_u8, 0x72_u8, 0x79_u8]

    empty_line = w239g_geometry_value(geometry, 0_u8, 1_u64, true)
    w239b_concat([
      descriptor,
      Bytes[0_u8, 0_u8],
    ] of Bytes).should eq(CrystalClick::BinaryValueCodec.encode(empty_line))

    null_geometry = w239g_geometry_value(geometry, 255_u8, 2_u64)
    w239b_concat([descriptor, Bytes[0xff_u8]] of Bytes).should eq(
      CrystalClick::BinaryValueCodec.encode(null_geometry),
    )

    point_type = geometry.child_at(0).child_at(3)
    coordinates = CrystalClick::BinaryValue.tuple(
      point_type.child_at(0),
      [
        CrystalClick::BinaryValue.float64_bits(0_u64),
        CrystalClick::BinaryValue.float64_bits(0_u64),
      ] of CrystalClick::BinaryValue,
    )
    point_alias = CrystalClick::BinaryValue.custom(point_type, coordinates)
    point_value = CrystalClick::BinaryValue.custom(
      geometry,
      CrystalClick::BinaryValue.variant(geometry.child_at(0), 3, point_alias),
    )
    expected_point = Bytes.new(descriptor.size + 17) do |index|
      if index < descriptor.size
        descriptor[index]
      elsif index == descriptor.size
        3_u8
      else
        0_u8
      end
    end
    CrystalClick::BinaryValueCodec.encode(point_value).should eq(expected_point)
  end
end
