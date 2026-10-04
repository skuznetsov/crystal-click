require "./spec_helper"

describe "W155 rebased shared-envelope context guards" do
  it "charges two literal Bool nodes to the supplied writing budget across calls" do
    # One descriptor node and one scalar node; no children or name metadata.
    limits = CrystalClick::BinaryCodecLimits.new(2, 3, 1, 16)
    budget = CrystalClick::BinaryCodecBudget.new(limits, true)
    bytes = CrystalClick::BinaryValueCodec.encode_dynamic_bulk_child(
      CrystalClick::BinaryValue.bool(true), budget, 2,
    )
    bytes.should eq(Bytes[0x2d_u8, 0x01_u8])
    budget.node_count.should eq(2_i64)
    budget.element_count.should eq(0_i64)
    budget.wire_byte_count.should eq(0_i64) # Final lane owner pays wire bytes.
    expect_raises(CrystalClick::UnsupportedFormatError, "node limit") do
      CrystalClick::BinaryValueCodec.encode_dynamic_bulk_child(
        CrystalClick::BinaryValue.bool(false), budget, 2,
      )
    end
  end

  it "charges two literal Bool nodes to the supplied reading budget across calls" do
    limits = CrystalClick::BinaryCodecLimits.new(2, 3, 1, 16)
    budget = CrystalClick::BinaryCodecBudget.new(limits)
    type, value = CrystalClick::BinaryValueCodec.decode_dynamic_bulk_child(
      Bytes[0x2d_u8, 0x01_u8], budget, 2,
    )
    type.should eq(CrystalClick::BinaryDataType.primitive("Bool"))
    value.not_nil!.as_bool.should be_true
    budget.node_count.should eq(2_i64)
    budget.element_count.should eq(0_i64)
    budget.wire_byte_count.should eq(0_i64) # Input lanes are already prepaid.
    expect_raises(CrystalClick::CorruptPartError, "node limit") do
      CrystalClick::BinaryValueCodec.decode_dynamic_bulk_child(
        Bytes[0x2d_u8, 0x00_u8], budget, 2,
      )
    end
  end

  it "preflights the requested parent value edge before visiting the scalar" do
    budget = CrystalClick::BinaryCodecBudget.new(
      CrystalClick::BinaryCodecLimits.new(2, 3, 0, 16),
    )
    expect_raises(CrystalClick::CorruptPartError, "element limit") do
      CrystalClick::BinaryValueCodec.decode_dynamic_bulk_child(
        Bytes[0x2d_u8, 0x01_u8], budget, 2, charge_parent_value_edge: true)
    end
    # Descriptor visited, scalar not visited: this checks ordering independently
    # of whether the eventual operation would also reject the exhausted budget.
    budget.node_count.should eq(1_i64)
    budget.element_count.should eq(0_i64)
  end

  it "charges one requested parent value edge but no edge for a Nothing sentinel" do
    limits = CrystalClick::BinaryCodecLimits.new(2, 3, 1, 16)
    bool_budget = CrystalClick::BinaryCodecBudget.new(limits)
    _, value = CrystalClick::BinaryValueCodec.decode_dynamic_bulk_child(
      Bytes[0x2d_u8, 0x01_u8], bool_budget, 2, charge_parent_value_edge: true)
    value.not_nil!.as_bool.should be_true
    bool_budget.node_count.should eq(2_i64)
    bool_budget.element_count.should eq(1_i64)

    nothing_budget = CrystalClick::BinaryCodecBudget.new(limits)
    type, sentinel = CrystalClick::BinaryValueCodec.decode_dynamic_bulk_child(
      Bytes[0x00_u8], nothing_budget, 2, charge_parent_value_edge: true)
    type.should eq(CrystalClick::BinaryDataType.primitive("Nothing"))
    sentinel.should be_nil
    nothing_budget.node_count.should eq(2_i64)
    nothing_budget.element_count.should eq(0_i64)
  end
end
