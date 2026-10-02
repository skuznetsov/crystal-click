require "spec"
require "../src/crystal_click/binary_temporal_type"
require "../src/crystal_click/binary_decimal_type"
require "../src/crystal_click/binary_enum_definition"

describe "W119 scalar parameter owners as standalone imports" do
  it "owns temporal timezone names and accepts wide integer scale arguments" do
    source_zone = String.new(Bytes[0x55_u8, 0x54_u8, 0x43_u8])
    temporal = CrystalClick::BinaryTemporalType.datetime64(3_i64, source_zone)

    source_zone.to_unsafe[0] = 0x58_u8
    temporal.family.should eq(CrystalClick::BinaryTemporalType::Family::DateTime64)
    temporal.scale.should eq(3_i32)
    temporal.fixed_width.should eq(8)
    temporal.explicit_time_zone?.should be_true
    temporal.time_zone?.not_nil!.name.should eq("UTC")
    temporal.type_name.should eq("DateTime64(3, 'UTC')")

    exposed_zone = temporal.time_zone?.not_nil!.name
    exposed_zone.to_unsafe[0] = 0x58_u8
    temporal.time_zone?.not_nil!.name.should eq("UTC")
    CrystalClick::BinaryTemporalType.time64(3_i64).scale.should eq(3_i32)
  end

  it "preserves Decimal wire width with width-specific precision and scale limits" do
    narrow = CrystalClick::BinaryDecimalType.new(32, 1, 9)
    wide = CrystalClick::BinaryDecimalType.new(256, 3, 2)
    same_display_other_width = CrystalClick::BinaryDecimalType.new(64, 1, 9)

    narrow.width_bits.should eq(32)
    narrow.precision.should eq(1)
    narrow.scale.should eq(9)
    narrow.fixed_width.should eq(4)
    wide.fixed_width.should eq(32)
    narrow.type_name.should eq(same_display_other_width.type_name)
    narrow.should_not eq(same_display_other_width)
    expect_raises(ArgumentError) { CrystalClick::BinaryDecimalType.new(32, 0, 0) }
    expect_raises(ArgumentError) { CrystalClick::BinaryDecimalType.new(32, 1, 10) }
  end

  it "sorts Enum codes and detaches opaque labels from inputs and outputs" do
    source_label = String.new(Bytes[0x7a_u8])
    source_entries = [
      {source_label, 2_i16},
      {"a", -1_i16},
    ] of CrystalClick::BinaryEnumDefinition::Entry
    definition = CrystalClick::BinaryEnumDefinition.new(8, source_entries)

    source_label.to_unsafe[0] = 0x78_u8
    definition.entries.should eq([
      {"a", -1_i16},
      {"z", 2_i16},
    ])
    definition.type_name.should eq("Enum8('a' = -1, 'z' = 2)")

    exposed_entries = definition.entries
    exposed_entries[1][0].to_unsafe[0] = 0x78_u8
    definition.entry_at(1)[0].should eq("z")
    entry = definition.entry_at(0)
    entry[0].to_unsafe[0] = 0x78_u8
    definition.entry_at(0)[0].should eq("a")

    opaque = String.new(Bytes[0xff_u8, 0x00_u8, 0x61_u8])
    opaque_definition = CrystalClick::BinaryEnumDefinition.new(8, [
      {opaque, -1_i16},
    ] of CrystalClick::BinaryEnumDefinition::Entry)
    opaque.to_unsafe[0] = 0x00_u8
    opaque_definition.entry_at(0)[0].to_slice.should eq(Bytes[0xff_u8, 0x00_u8, 0x61_u8])
  end
end
