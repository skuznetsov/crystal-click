require "./spec_helper"

describe "W160 recursive Interval bulk and Object boundaries" do
  it "round-trips Interval leaves through Array, Tuple, Map, Nullable, Variant, and LC" do
    string = CrystalClick::BinaryDataType.primitive("String")
    month = CrystalClick::BinaryDataType.interval(CrystalClick::BinaryIntervalType::Kind::Month)
    year = CrystalClick::BinaryDataType.interval(CrystalClick::BinaryIntervalType::Kind::Year)
    microsecond = CrystalClick::BinaryDataType.interval(CrystalClick::BinaryIntervalType::Kind::Microsecond)
    week = CrystalClick::BinaryDataType.interval(CrystalClick::BinaryIntervalType::Kind::Week)
    mapping = CrystalClick::BinaryDataType.map(string, month)
    nullable_year = CrystalClick::BinaryDataType.nullable(year)
    choice = CrystalClick::BinaryDataType.variant([microsecond, year] of CrystalClick::BinaryDataType)
    low_week = CrystalClick::BinaryDataType.low_cardinality(week)
    tuple = CrystalClick::BinaryDataType.tuple([
      mapping,
      nullable_year,
      choice,
      low_week,
    ] of CrystalClick::BinaryDataType)
    array = CrystalClick::BinaryDataType.array(tuple)

    map_value = CrystalClick::BinaryValue.map(mapping, [
      CrystalClick::BinaryValue.string("k"),
      CrystalClick::BinaryValue.interval(month, 5_i64),
    ] of CrystalClick::BinaryValue)
    variant_value = CrystalClick::BinaryValue.variant(choice, 1, CrystalClick::BinaryValue.interval(year, 9_i64))
    tuple_value = CrystalClick::BinaryValue.tuple(tuple, [
      map_value,
      CrystalClick::BinaryValue.nullable(nullable_year),
      variant_value,
      CrystalClick::BinaryValue.low_cardinality(low_week, CrystalClick::BinaryValue.interval(week, 11_i64)),
    ] of CrystalClick::BinaryValue)
    value = CrystalClick::BinaryValue.array(array, [tuple_value] of CrystalClick::BinaryValue)

    encoded = CrystalClick::BinaryBulkCodec.encode(array, [[value] of CrystalClick::BinaryValue])
    encoded.roles.should eq([
      "root.elements.field.0.elements.field.0.data",
      "root.elements.field.0.elements.field.1.data",
      "root.elements.field.0.sizes",
      "root.elements.field.1.nested.data",
      "root.elements.field.1.nulls",
      "root.elements.field.2.arm.0.data",
      "root.elements.field.2.arm.1.data",
      "root.elements.field.2.discriminators",
      "root.elements.field.3.dictionary",
      "root.elements.field.3.indexes",
      "root.sizes",
    ] of String)
    encoded.stream("root.sizes").bytes.should eq(Bytes[1_u8, 0, 0, 0, 0, 0, 0, 0])
    encoded.stream("root.elements.field.0.sizes").bytes.should eq(Bytes[1_u8, 0, 0, 0, 0, 0, 0, 0])
    encoded.stream("root.elements.field.0.elements.field.0.data").bytes.should eq(Bytes[1_u8, 0x6b_u8])
    encoded.stream("root.elements.field.0.elements.field.1.data").bytes.should eq(Bytes[5_u8, 0, 0, 0, 0, 0, 0, 0])
    encoded.stream("root.elements.field.1.nulls").bytes.should eq(Bytes[1_u8])
    encoded.stream("root.elements.field.1.nested.data").bytes.should eq(Bytes[0_u8, 0, 0, 0, 0, 0, 0, 0])
    encoded.stream("root.elements.field.2.discriminators").bytes.should eq(Bytes[1_u8])
    encoded.stream("root.elements.field.2.arm.0.data").bytes.should be_empty
    encoded.stream("root.elements.field.2.arm.1.data").bytes.should eq(Bytes[9_u8, 0, 0, 0, 0, 0, 0, 0])
    encoded.stream("root.elements.field.3.dictionary").bytes.should eq(Bytes[
      1_u8, 0, 0, 0, 0, 0, 0, 0,
      2_u8, 0, 0, 0, 0, 0, 0, 0,
      0_u8, 0, 0, 0, 0, 0, 0, 0,
      11_u8, 0, 0, 0, 0, 0, 0, 0,
    ])
    encoded.stream("root.elements.field.3.indexes").bytes.should eq(Bytes[
      0x00_u8, 0x05_u8, 0, 0, 0, 0, 0, 0,
      1_u8, 0, 0, 0, 0, 0, 0, 0,
      1_u8,
    ])
    encoded.stream("root.elements.field.3.dictionary").offsets.should eq([8_u64, 32_u64])
    encoded.stream("root.elements.field.3.indexes").offsets.should eq([0_u64, 17_u64])

    decoded = CrystalClick::BinaryBulkCodec.decode(array, encoded, [1_u64])
    decoded_map = decoded[0][0].child_at(0).child_at(0)
    decoded_map.child_at(0).as_string.should eq("k")
    decoded_map.child_at(1).as_interval_count.should eq(5_i64)
    decoded_nullable = decoded[0][0].child_at(0).child_at(1)
    decoded_nullable.is_null?.should be_true
    decoded_nullable.type.name.should eq("Nullable(IntervalYear)")
    decoded_choice = decoded[0][0].child_at(0).child_at(2)
    decoded_choice.variant_index?.should eq(1_u8)
    decoded_choice.variant_child?.not_nil!.as_interval_count.should eq(9_i64)
    decoded_low = decoded[0][0].child_at(0).child_at(3)
    decoded_low.type.should eq(low_week)
    decoded_low.child_at(0).as_interval_count.should eq(11_i64)

    physical = CrystalClick::BinaryBulkPhysicalPlan.new(array, "doc")
    physical.stream_names.should eq({
      "root.sizes"                                  => "doc.size0",
      "root.elements.field.0.sizes"                 => "doc%2E1.size1",
      "root.elements.field.0.elements.field.0.data" => "doc%2E1%2Ekeys",
      "root.elements.field.0.elements.field.1.data" => "doc%2E1%2Evalues",
      "root.elements.field.1.nulls"                 => "doc%2E2.null",
      "root.elements.field.1.nested.data"           => "doc%2E2",
      "root.elements.field.2.discriminators"        => "doc%2E3.variant_discr",
      "root.elements.field.2.arm.0.data"            => "doc%2E3.IntervalMicrosecond",
      "root.elements.field.2.arm.1.data"            => "doc%2E3.IntervalYear",
      "root.elements.field.3.dictionary"            => "doc%2E4.dict",
      "root.elements.field.3.indexes"               => "doc%2E4",
    })
    physical.prefix_size_for("root.elements.field.2.discriminators").should eq(8)
    physical.prefix_size_for("root.elements.field.3.dictionary").should eq(8)
  end

  it "keeps an Interval actual Dynamic arm distinct and physically named inside Array" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    array = CrystalClick::BinaryDataType.array(dynamic)
    nanosecond = CrystalClick::BinaryDataType.interval(CrystalClick::BinaryIntervalType::Kind::Nanosecond)
    roster = CrystalClick::DynamicStructure.new([nanosecond] of CrystalClick::BinaryDataType)
    value = CrystalClick::BinaryValue.array(array, [
      CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.interval(nanosecond, -7_i64)),
    ] of CrystalClick::BinaryValue)

    encoded = CrystalClick::BinaryDynamicBulkCodec.encode(
      array,
      {"root.elements" => roster},
      [[value] of CrystalClick::BinaryValue],
    )
    encoded.structures.site_paths.should eq(["root.elements"] of String)
    encoded.data.roles.should eq([
      "root.elements.arm.0.data",
      "root.elements.arm.1.data",
      "root.elements.discriminators",
      "root.sizes",
    ] of String)
    encoded.data.stream("root.sizes").bytes.should eq(Bytes[1_u8, 0, 0, 0, 0, 0, 0, 0])
    encoded.data.stream("root.elements.discriminators").bytes.should eq(Bytes[0_u8])
    encoded.data.stream("root.elements.arm.0.data").bytes.should eq(Bytes[
      0xf9_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8,
    ])
    encoded.data.stream("root.elements.arm.1.data").bytes.should be_empty

    decoded = CrystalClick::BinaryDynamicBulkCodec.decode(array, encoded, [1_u64])
    decoded[0][0].child_at(0).child_at(0).type.should eq(nanosecond)
    decoded[0][0].child_at(0).child_at(0).as_interval_count.should eq(-7_i64)

    prepared = CrystalClick::BinaryDynamicBulkPlan.new(array, {"root.elements" => roster})
    physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(prepared, "d")
    physical.stream_names.should eq({
      "root.sizes"                      => "d.size0",
      "root.elements.discriminators"    => "d.variant_discr",
      "root.elements.arm.0.data"        => "d.IntervalNanosecond",
      "root.elements.arm.1.data"        => "d.SharedVariant",
      "root.elements.dynamic_structure" => "d.dynamic_structure",
    })
    physical.prefix_size_for("root.elements.discriminators").should eq(8)
  end

  it "rejects same-width Interval-kind substitution and Int64 as an Interval value" do
    month = CrystalClick::BinaryDataType.interval(CrystalClick::BinaryIntervalType::Kind::Month)
    second = CrystalClick::BinaryDataType.interval(CrystalClick::BinaryIntervalType::Kind::Second)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkCodec.encode(month, [[CrystalClick::BinaryValue.interval(second, 7_i64)] of CrystalClick::BinaryValue])
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkCodec.encode(month, [[CrystalClick::BinaryValue.int64(7_i64)] of CrystalClick::BinaryValue])
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryValue.interval(CrystalClick::BinaryDataType.primitive("Int64"), 7_i64)
    end
  end

  it "keeps Interval out of Object declarations and declared Dynamic actual arms" do
    interval = CrystalClick::BinaryDataType.interval(CrystalClick::BinaryIntervalType::Kind::Month)
    expect_raises(ArgumentError, "typed JSON schema admits only supported Object recursive types") do
      CrystalClick::ObjectDocumentSchema.new({"v" => interval})
    end

    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    schema = CrystalClick::ObjectDocumentSchema.new({"v" => dynamic})
    empty = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    )
    object_interval_error = "invalid typed Object Dynamic actual roster: " +
                            "typed Object Dynamic actual arm is outside the recursive declaration grammar"
    expect_raises(ArgumentError, object_interval_error) do
      CrystalClick::ObjectDocumentPlan.new(
        empty,
        schema.typed_paths,
        {"v" => CrystalClick::DynamicStructure.new([interval] of CrystalClick::BinaryDataType)},
      )
    end

    plan = CrystalClick::ObjectDocumentPlan.new(
      empty,
      schema.typed_paths,
      {"v" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)},
    )
    selected_interval = CrystalClick::BinaryValue.dynamic(dynamic, CrystalClick::BinaryValue.interval(interval, 7_i64))
    rows = [[CrystalClick::ObjectDocument.new({"v" => selected_interval})] of CrystalClick::ObjectDocument]
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentCodec.encode(plan, rows, mode: 0_u64)
    end
  end
end
