require "./spec_helper"
require "../scripts/support/geometry_composition_w239_semantics"

describe "W239 independent Geometry semantic fixture" do
  it "accepts the authored Point and rejects a coherent coordinate swap" do
    type = CrystalClick::BinaryDataType.custom("Geometry")
    expected = CrystalClick::GeometryCompositionW239Semantics.values("geometry", type)[4]

    CrystalClick::GeometryCompositionW239Semantics.same_value?(expected, expected).should be_true
    expected_variant = expected.child_at(0)
    expected_variant.variant_index?.should eq(3_u8)
    expected_point = expected_variant.variant_child?.not_nil!
    expected_coordinates = expected_point.child_at(0)
    expected_coordinates.child_at(0).as_float64_bits.should eq(0x7ff8_0000_0000_1234_u64)
    expected_coordinates.child_at(1).as_float64_bits.should eq(0x400c_0000_0000_0000_u64)

    swapped_coordinates = CrystalClick::BinaryValue.tuple(
      expected_coordinates.type,
      [expected_coordinates.child_at(1), expected_coordinates.child_at(0)] of CrystalClick::BinaryValue,
    )
    swapped_point = CrystalClick::BinaryValue.custom(
      expected_point.type,
      swapped_coordinates,
    )
    swapped_variant = CrystalClick::BinaryValue.variant(type.child_at(0), 3, swapped_point)
    swapped = CrystalClick::BinaryValue.custom(type, swapped_variant)

    # This counterfeit remains structurally valid and has a coherent codec
    # round trip, so only comparison to the independent semantic fixture
    # rejects the x/y inversion.
    swapped_bytes = CrystalClick::BinaryValueCodec.encode_value(swapped)
    decoded_swap = CrystalClick::BinaryValueCodec.decode_value(type, swapped_bytes)
    decoded_swap.type.name.should eq("Geometry")
    decoded_swap.child_at(0).variant_index?.should eq(3_u8)
    CrystalClick::BinaryValueCodec.encode_value(decoded_swap).should eq(swapped_bytes)
    CrystalClick::GeometryCompositionW239Semantics.same_value?(decoded_swap, expected).should be_false
  end
end
