require "./spec_helper"

private def w172_bulk_u64(value : UInt64) : Bytes
  Bytes.new(8) { |index| ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w172_bulk_u64s(values : Array(UInt64)) : Bytes
  bytes = [] of UInt8
  values.each do |value|
    w172_bulk_u64(value).each { |byte| bytes << byte }
  end
  Bytes.new(bytes.size) { |index| bytes[index] }
end

private def w172_bulk_concat(parts : Array(Bytes)) : Bytes
  bytes = [] of UInt8
  parts.each { |part| part.each { |byte| bytes << byte } }
  Bytes.new(bytes.size) { |index| bytes[index] }
end

private def w172_bulk_i32(value : Int32) : Bytes
  bits = value.unsafe_as(UInt32)
  Bytes.new(4) { |index| ((bits >> (index * 8)) & 0xff_u32).to_u8 }
end

private def w172_bulk_nested_record(
  type : CrystalClick::BinaryDataType,
  id : UInt64,
  label : String,
  number : Int32?,
) : CrystalClick::BinaryValue
  nullable_type = type.child_at(0).child_at(2)
  number_value = if number
                   CrystalClick::BinaryValue.nullable(
                     nullable_type,
                     CrystalClick::BinaryValue.fixed(nullable_type.child_at(0), w172_bulk_i32(number))
                   )
                 else
                   CrystalClick::BinaryValue.nullable(nullable_type)
                 end
  CrystalClick::BinaryValue.tuple(
    type.child_at(0),
    [
      CrystalClick::BinaryValue.uint64(id),
      CrystalClick::BinaryValue.string(label),
      number_value,
    ] of CrystalClick::BinaryValue
  )
end

private def w172_bulk_nested_value(
  type : CrystalClick::BinaryDataType,
  records : Array(CrystalClick::BinaryValue),
) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.nested(type, records)
end

describe "W172 nominal Nested binary codec" do
  it "decodes an independently authored Nested descriptor without erasing its name" do
    # 0x2f, two fields: a UInt64, b String. Not 0x1e + 0x20.
    wire = Bytes[0x2f_u8, 2_u8, 1_u8, 0x61_u8, 4_u8, 1_u8, 0x62_u8, 0x15_u8]
    type = CrystalClick::BinaryDataTypeCodec.decode(wire)
    type.name.should eq("Nested(a UInt64, b String)")
    CrystalClick::BinaryDataTypeCodec.encode(type).should eq(wire)
  end

  it "requires a nonempty named field roster for the nominal descriptor" do
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")

    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.nested([uint64] of CrystalClick::BinaryDataType, [] of String)
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.nested([uint64] of CrystalClick::BinaryDataType, ["a", "b"] of String)
    end
  end

  it "matches exact Nested bulk roles, physical names, mark offsets, and a nonzero window" do
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    string = CrystalClick::BinaryDataType.primitive("String")
    int32 = CrystalClick::BinaryDataType.primitive("Int32")
    nullable_int32 = CrystalClick::BinaryDataType.nullable(int32)
    type = CrystalClick::BinaryDataType.nested(
      [uint64, string, nullable_int32] of CrystalClick::BinaryDataType,
      ["a", "b", "c"] of String
    )

    first = w172_bulk_nested_value(type, [
      w172_bulk_nested_record(type, 11_u64, "a", 101_i32),
      w172_bulk_nested_record(type, 12_u64, "bb", nil),
    ] of CrystalClick::BinaryValue)
    empty = w172_bulk_nested_value(type, [] of CrystalClick::BinaryValue)
    third = w172_bulk_nested_value(type, [
      w172_bulk_nested_record(type, 31_u64, "z", nil),
    ] of CrystalClick::BinaryValue)
    fourth = w172_bulk_nested_value(type, [
      w172_bulk_nested_record(type, 41_u64, "d", nil),
      w172_bulk_nested_record(type, 42_u64, "e", 402_i32),
      w172_bulk_nested_record(type, 43_u64, "f", 403_i32),
    ] of CrystalClick::BinaryValue)
    fifth = w172_bulk_nested_value(type, [
      w172_bulk_nested_record(type, 51_u64, "g", 501_i32),
      w172_bulk_nested_record(type, 52_u64, "h", nil),
    ] of CrystalClick::BinaryValue)

    # Mark 2 has no outer rows. Empty arrays at marks 1 and the other
    # nonempty marks remain represented in the shared size lane.
    granules = [
      [first] of CrystalClick::BinaryValue,
      [empty] of CrystalClick::BinaryValue,
      [] of CrystalClick::BinaryValue,
      [third] of CrystalClick::BinaryValue,
      [fourth] of CrystalClick::BinaryValue,
      [fifth] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)
    rows_per_mark = [1_u64, 1_u64, 0_u64, 1_u64, 1_u64, 1_u64]

    single = CrystalClick::BinaryBulkCodec.encode(type, granules)
    single.roles.should eq([
      "root.elements.field.0.data",
      "root.elements.field.1.data",
      "root.elements.field.2.nested.data",
      "root.elements.field.2.nulls",
      "root.sizes",
    ] of String)

    size_lane = single.stream("root.sizes")
    size_lane.bytes.should eq(w172_bulk_u64s([2_u64, 0_u64, 1_u64, 3_u64, 2_u64]))
    size_lane.offsets.should eq([0_u64, 8_u64, 16_u64, 16_u64, 24_u64, 32_u64, 40_u64])

    ids_lane = single.stream("root.elements.field.0.data")
    ids_lane.bytes.should eq(w172_bulk_u64s([11_u64, 12_u64, 31_u64, 41_u64, 42_u64, 43_u64, 51_u64, 52_u64]))
    ids_lane.offsets.should eq([0_u64, 16_u64, 16_u64, 16_u64, 24_u64, 48_u64, 64_u64])

    strings_lane = single.stream("root.elements.field.1.data")
    strings_lane.bytes.should eq(Bytes[
      1_u8, 0x61_u8, 2_u8, 0x62_u8, 0x62_u8, 1_u8, 0x7a_u8,
      1_u8, 0x64_u8, 1_u8, 0x65_u8, 1_u8, 0x66_u8, 1_u8, 0x67_u8, 1_u8, 0x68_u8,
    ])
    strings_lane.offsets.should eq([0_u64, 5_u64, 5_u64, 5_u64, 7_u64, 13_u64, 17_u64])

    nullable_lane = single.stream("root.elements.field.2.nulls")
    nullable_lane.bytes.should eq(Bytes[0_u8, 1_u8, 1_u8, 1_u8, 0_u8, 0_u8, 0_u8, 1_u8])
    nullable_lane.offsets.should eq([0_u64, 2_u64, 2_u64, 2_u64, 3_u64, 6_u64, 8_u64])
    nullable_data = single.stream("root.elements.field.2.nested.data")
    nullable_data.bytes.should eq(w172_bulk_concat([
      w172_bulk_i32(101_i32), w172_bulk_i32(0_i32), w172_bulk_i32(0_i32),
      w172_bulk_i32(0_i32), w172_bulk_i32(402_i32), w172_bulk_i32(403_i32),
      w172_bulk_i32(501_i32), w172_bulk_i32(0_i32),
    ] of Bytes))
    nullable_data.offsets.should eq([0_u64, 8_u64, 8_u64, 8_u64, 12_u64, 24_u64, 32_u64])

    physical = CrystalClick::BinaryBulkPhysicalPlan.new(type, "events")
    physical.stream_names.should eq({
      "root.sizes"                        => "events.size0",
      "root.elements.field.0.data"        => "events%2Ea",
      "root.elements.field.1.data"        => "events%2Eb",
      "root.elements.field.2.nulls"       => "events%2Ec.null",
      "root.elements.field.2.nested.data" => "events%2Ec",
    } of String => String)

    selected = CrystalClick::BinaryBulkCodec.decode(
      type,
      single,
      rows_per_mark,
      first_mark: 1,
      mark_count: 4
    )
    selected.size.should eq(4)
    selected[0].size.should eq(1)
    selected[0][0].type.should eq(type)
    selected[0][0].element_count.should eq(0)
    selected[1].should be_empty
    selected[2][0].element_at(0).child_at(0).as_uint64.should eq(31_u64)
    selected[2][0].element_at(0).child_at(1).as_string.should eq("z")
    selected[2][0].element_at(0).child_at(2).is_null?.should be_true
    selected[3][0].element_count.should eq(3)
    selected[3][0].element_at(1).child_at(0).as_uint64.should eq(42_u64)
    selected[3][0].element_at(1).child_at(2).is_null?.should be_false
    selected[3][0].element_at(1).child_at(2).child_at(0).bytes.should eq(w172_bulk_i32(402_i32))

    empty_window = CrystalClick::BinaryBulkCodec.decode(
      type,
      single,
      rows_per_mark,
      first_mark: 6,
      mark_count: 0
    )
    empty_window.should be_empty
  end

  it "keeps the Nested descriptor in the size-stream String profile and emits typed hidden defaults" do
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
    value = CrystalClick::BinaryValue.nested(nested, [record] of CrystalClick::BinaryValue)
    with_sizes = CrystalClick::BinaryBulkProfile.with_size_stream
    sized = CrystalClick::BinaryBulkCodec.encode(
      nested,
      [[value]] of Array(CrystalClick::BinaryValue),
      profile: with_sizes
    )
    sized.has_role?("root.elements.field.1.string_sizes").should be_true
    sized.stream("root.elements.field.1.data").bytes.should eq("seven".to_slice)
    sized.stream("root.elements.field.1.string_sizes").bytes.should eq(w172_bulk_u64(5_u64))
    sized.stream("root.sizes").offsets.should eq([0_u64, 8_u64])
    CrystalClick::BinaryBulkPhysicalPlan.new(nested, "events", profile: with_sizes).stream_names.should eq({
      "root.sizes"                         => "events.size0",
      "root.elements.field.0.data"         => "events%2Eid",
      "root.elements.field.1.data"         => "events%2Elabel",
      "root.elements.field.1.string_sizes" => "events%2Elabel.size",
    } of String => String)
    restored = CrystalClick::BinaryBulkCodec.decode(
      nested,
      sized,
      [1_u64],
      profile: with_sizes
    )
    restored[0][0].type.should eq(nested)
    restored[0][0].element_at(0).child_at(1).as_string.should eq("seven")

    nullable_tuple = CrystalClick::BinaryDataType.nullable(
      CrystalClick::BinaryDataType.tuple([nested] of CrystalClick::BinaryDataType, ["payload"] of String)
    )
    hidden_null = CrystalClick::BinaryValue.null(nullable_tuple)
    hidden = CrystalClick::BinaryBulkCodec.encode(
      nullable_tuple,
      [[hidden_null]] of Array(CrystalClick::BinaryValue)
    )
    hidden.has_role?("root.nested.field.0.sizes").should be_true
    hidden.stream("root.nulls").bytes.should eq(Bytes[1_u8])
    hidden.stream("root.nested.field.0.sizes").bytes.should eq(w172_bulk_u64(0_u64))
    hidden_restored = CrystalClick::BinaryBulkCodec.decode(nullable_tuple, hidden, [1_u64])
    hidden_restored[0][0].type.should eq(nullable_tuple)
    hidden_restored[0][0].is_null?.should be_true
  end

  it "preserves recursive Nested identity through ordinary bulk lanes" do
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    inner = CrystalClick::BinaryDataType.nested([uint64] of CrystalClick::BinaryDataType, ["x"] of String)
    outer = CrystalClick::BinaryDataType.nested([inner] of CrystalClick::BinaryDataType, ["payload"] of String)
    inner_record = CrystalClick::BinaryValue.tuple(
      inner.child_at(0),
      [CrystalClick::BinaryValue.uint64(7_u64)] of CrystalClick::BinaryValue
    )
    inner_value = CrystalClick::BinaryValue.nested(inner, [inner_record] of CrystalClick::BinaryValue)
    outer_record = CrystalClick::BinaryValue.tuple(
      outer.child_at(0),
      [inner_value] of CrystalClick::BinaryValue
    )
    outer_value = CrystalClick::BinaryValue.nested(outer, [outer_record] of CrystalClick::BinaryValue)

    streams = CrystalClick::BinaryBulkCodec.encode(
      outer,
      [[outer_value]] of Array(CrystalClick::BinaryValue)
    )
    streams.roles.should eq([
      "root.elements.field.0.elements.field.0.data",
      "root.elements.field.0.sizes",
      "root.sizes",
    ] of String)
    streams.stream("root.sizes").bytes.should eq(w172_bulk_u64(1_u64))
    streams.stream("root.elements.field.0.sizes").bytes.should eq(w172_bulk_u64(1_u64))
    streams.stream("root.elements.field.0.elements.field.0.data").bytes.should eq(w172_bulk_u64(7_u64))
    CrystalClick::BinaryBulkPhysicalPlan.new(outer, "outer").stream_names.should eq({
      "root.sizes"                                  => "outer.size0",
      "root.elements.field.0.sizes"                 => "outer%2Epayload.size1",
      "root.elements.field.0.elements.field.0.data" => "outer%2Epayload%2Ex",
    } of String => String)

    restored = CrystalClick::BinaryBulkCodec.decode(outer, streams, [1_u64])
    restored[0][0].type.should eq(outer)
    restored_inner = restored[0][0].element_at(0).child_at(0)
    restored_inner.type.should eq(inner)
    restored_inner.element_at(0).child_at(0).as_uint64.should eq(7_u64)
  end

  it "keeps Nested distinct from Array(Tuple) and admits ordinary Dynamic Nested rosters" do
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    nested = CrystalClick::BinaryDataType.nested([uint64] of CrystalClick::BinaryDataType, ["id"] of String)
    tuple_type = nested.child_at(0)
    tuple_value = CrystalClick::BinaryValue.tuple(
      tuple_type,
      [CrystalClick::BinaryValue.uint64(9_u64)] of CrystalClick::BinaryValue
    )
    array_type = CrystalClick::BinaryDataType.array(tuple_type)
    array_value = CrystalClick::BinaryValue.array(array_type, [tuple_value] of CrystalClick::BinaryValue)
    nested_value = CrystalClick::BinaryValue.nested(nested, [tuple_value] of CrystalClick::BinaryValue)

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkCodec.encode(nested, [[array_value]] of Array(CrystalClick::BinaryValue))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkCodec.encode(array_type, [[nested_value]] of Array(CrystalClick::BinaryValue))
    end

    structure = CrystalClick::DynamicStructure.new([nested] of CrystalClick::BinaryDataType)
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 2)
    plan = CrystalClick::BinaryDynamicBulkPlan.new(dynamic, {"root" => structure})
    plan.data_roles.should contain("root.arm.0.sizes")
    plan.data_roles.should contain("root.arm.0.elements.field.0.data")
  end
end
