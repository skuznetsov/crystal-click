require "./spec_helper"

private def w238b_custom(name : String) : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.custom(name)
end

private def w238b_float(bits : UInt64) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.float64_bits(bits)
end

private def w238b_custom_point(x : UInt64, y : UInt64) : CrystalClick::BinaryValue
  type = w238b_custom("Point")
  body = CrystalClick::BinaryValue.tuple(
    type.child_at(0),
    [w238b_float(x), w238b_float(y)] of CrystalClick::BinaryValue,
  )
  CrystalClick::BinaryValue.custom(type, body)
end

private def w238b_geo_value(type : CrystalClick::BinaryDataType, seed : UInt64) : CrystalClick::BinaryValue
  unless type.tag == CrystalClick::BinaryDataType::TAG_CUSTOM
    raise ArgumentError.new("W238 helper requires a nominal Custom Geo descriptor")
  end

  body_type = type.child_at(0)
  body = case body_type.tag
         when CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE, CrystalClick::BinaryDataType::TAG_NAMED_TUPLE
           CrystalClick::BinaryValue.tuple(
             body_type,
             [w238b_float(seed), w238b_float(seed &+ 1_u64)] of CrystalClick::BinaryValue,
           )
         when CrystalClick::BinaryDataType::TAG_ARRAY
           element_type = body_type.child_at(0)
           # Vary the topology while keeping every constructed child nominal.
           children = if seed % 3_u64 == 0_u64
                        [] of CrystalClick::BinaryValue
                      elsif seed % 3_u64 == 1_u64
                        [w238b_geo_value(element_type, seed &+ 1_u64)] of CrystalClick::BinaryValue
                      else
                        [
                          w238b_geo_value(element_type, seed &+ 1_u64),
                          w238b_geo_value(element_type, seed &+ 2_u64),
                        ] of CrystalClick::BinaryValue
                      end
           CrystalClick::BinaryValue.array(body_type, children)
         else
           raise ArgumentError.new("unexpected W238 Custom Geo storage body")
         end
  CrystalClick::BinaryValue.custom(type, body)
end

private def w238b_assert_value(actual : CrystalClick::BinaryValue, expected : CrystalClick::BinaryValue) : Nil
  actual.type.name.should eq(expected.type.name)
  actual.is_null?.should eq(expected.is_null?)
  if actual.type.tag == CrystalClick::BinaryDataType::TAG_VARIANT
    actual.variant_index?.should eq(expected.variant_index?)
  end
  actual.byte_size.should eq(expected.byte_size)
  actual.byte_size.times do |index|
    actual.byte_at(index).should eq(expected.byte_at(index))
  end
  actual.child_count.should eq(expected.child_count)
  actual.child_count.times do |index|
    w238b_assert_value(actual.child_at(index), expected.child_at(index))
  end
end

private def w238b_assert_marks(
  actual : Array(Array(CrystalClick::BinaryValue)),
  expected : Array(Array(CrystalClick::BinaryValue)),
) : Nil
  actual.size.should eq(expected.size)
  actual.each_with_index do |mark, mark_index|
    mark.size.should eq(expected[mark_index].size)
    mark.each_with_index do |value, row_index|
      w238b_assert_value(value, expected[mark_index][row_index])
    end
  end
end

describe "W238 nominal Custom Geo recursive bulk composition" do
  it "keeps all seven aliases nominal while reusing exactly their existing body lanes" do
    names = [
      "Point",
      "MultiPoint",
      "LineString",
      "Ring",
      "MultiLineString",
      "Polygon",
      "MultiPolygon",
    ]

    names.each_with_index do |name, index|
      type = w238b_custom(name)
      type.name.should eq(name)
      type.custom_geo_type.not_nil!.name.should eq(name)
      body_type = type.child_at(0)
      values = [
        w238b_geo_value(type, (index * 3 + 1).to_u64),
        w238b_geo_value(type, (index * 3 + 2).to_u64),
      ] of CrystalClick::BinaryValue
      marks = [
        [values[0]] of CrystalClick::BinaryValue,
        [] of CrystalClick::BinaryValue,
        [values[1]] of CrystalClick::BinaryValue,
      ] of Array(CrystalClick::BinaryValue)
      body_marks = marks.map do |mark|
        mark.map(&.child_at(0))
      end

      type_roles = CrystalClick::BinaryBulkTypePlan.new(
        type, CrystalClick::BinaryBulkProfile.single_stream
      ).roles
      body_roles = CrystalClick::BinaryBulkTypePlan.new(
        body_type, CrystalClick::BinaryBulkProfile.single_stream
      ).roles
      type_roles.should eq(body_roles)

      encoded = CrystalClick::BinaryBulkCodec.encode(type, marks)
      body_encoded = CrystalClick::BinaryBulkCodec.encode(body_type, body_marks)
      encoded.roles.should eq(body_encoded.roles)
      encoded.mark_count.should eq(3)
      encoded.roles.each do |role|
        encoded.stream(role).bytes.should eq(body_encoded.stream(role).bytes)
        encoded.stream(role).offsets.should eq(body_encoded.stream(role).offsets)
      end

      decoded = CrystalClick::BinaryBulkCodec.decode(
        type, encoded, [1_u64, 0_u64, 1_u64]
      )
      w238b_assert_marks(decoded, marks)
      w238b_assert_marks(
        CrystalClick::BinaryBulkCodec.decode(type, encoded, [1_u64, 0_u64, 1_u64], first_mark: 1, mark_count: 2),
        marks[1, 2],
      )
      CrystalClick::BinaryBulkCodec.decode(
        type, encoded, [1_u64, 0_u64, 1_u64], first_mark: 3, mark_count: 0
      ).should be_empty

      physical = CrystalClick::BinaryBulkPhysicalPlan.new(type, "geo")
      body_physical = CrystalClick::BinaryBulkPhysicalPlan.new(body_type, "geo")
      physical.stream_names.should eq(body_physical.stream_names)
      type_roles.each do |role|
        physical.prefix_size_for(role).should eq(body_physical.prefix_size_for(role))
      end
    end
  end

  it "composes Custom Geo through Array, Tuple, Map, Nested, and Variant without new role axes" do
    point = w238b_custom("Point")
    polygon = w238b_custom("Polygon")
    multipolygon = w238b_custom("MultiPolygon")
    string = CrystalClick::BinaryDataType.primitive("String")
    point_a = w238b_custom_point(0x3ff0_0000_0000_0000_u64, 0x4000_0000_0000_0000_u64)
    point_b = w238b_custom_point(0x4008_0000_0000_0000_u64, 0x4010_0000_0000_0000_u64)
    polygon_a = w238b_geo_value(polygon, 31_u64)
    polygon_b = w238b_geo_value(polygon, 32_u64)
    multipolygon_a = w238b_geo_value(multipolygon, 41_u64)

    tuple_type = CrystalClick::BinaryDataType.tuple(
      [point, string, polygon] of CrystalClick::BinaryDataType,
      ["point", "label", "polygon"] of String,
    )
    tuple_value = CrystalClick::BinaryValue.tuple(
      tuple_type,
      [point_a, CrystalClick::BinaryValue.string("a\u0000b"), polygon_a] of CrystalClick::BinaryValue,
    )
    tuple_roles = CrystalClick::BinaryBulkTypePlan.new(
      tuple_type, CrystalClick::BinaryBulkProfile.single_stream
    ).roles
    tuple_roles.should contain("root.field.0.field.0.data")
    tuple_roles.should contain("root.field.0.field.1.data")
    tuple_roles.should contain("root.field.1.data")
    tuple_roles.should contain("root.field.2.sizes")

    array_type = CrystalClick::BinaryDataType.array(multipolygon)
    array_values = [
      CrystalClick::BinaryValue.array(array_type, [] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.array(array_type, [multipolygon_a] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.array(array_type, [w238b_geo_value(multipolygon, 42_u64), multipolygon_a] of CrystalClick::BinaryValue),
    ] of CrystalClick::BinaryValue
    array_roles = CrystalClick::BinaryBulkTypePlan.new(
      array_type, CrystalClick::BinaryBulkProfile.single_stream
    ).roles
    array_roles.should contain("root.sizes")
    array_roles.should contain("root.elements.sizes")
    array_roles.should contain("root.elements.elements.sizes")

    map_type = CrystalClick::BinaryDataType.map(string, polygon)
    map_value = CrystalClick::BinaryValue.map(
      map_type,
      [CrystalClick::BinaryValue.string("left"), polygon_a,
       CrystalClick::BinaryValue.string("right"), polygon_b] of CrystalClick::BinaryValue,
    )
    map_roles = CrystalClick::BinaryBulkTypePlan.new(
      map_type, CrystalClick::BinaryBulkProfile.single_stream
    ).roles
    map_roles.should contain("root.sizes")
    map_roles.should contain("root.elements.field.0.data")
    map_roles.should contain("root.elements.field.1.sizes")

    nested_type = CrystalClick::BinaryDataType.nested(
      [point, multipolygon] of CrystalClick::BinaryDataType,
      ["coordinate", "shape"] of String,
    )
    nested_record_type = nested_type.child_at(0)
    nested_value = CrystalClick::BinaryValue.nested(
      nested_type,
      [
        CrystalClick::BinaryValue.tuple(
          nested_record_type,
          [point_b, multipolygon_a] of CrystalClick::BinaryValue,
        ),
      ] of CrystalClick::BinaryValue,
    )
    nested_roles = CrystalClick::BinaryBulkTypePlan.new(
      nested_type, CrystalClick::BinaryBulkProfile.single_stream
    ).roles
    nested_roles.should contain("root.sizes")
    nested_roles.should contain("root.elements.field.0.field.0.data")
    nested_roles.should contain("root.elements.field.0.field.1.data")
    nested_roles.should contain("root.elements.field.1.sizes")
    nested_roles.should contain("root.elements.field.1.elements.sizes")
    nested_roles.should contain("root.elements.field.1.elements.elements.sizes")

    variant_type = CrystalClick::BinaryDataType.variant(
      [point, polygon] of CrystalClick::BinaryDataType
    )
    point_arm = variant_type.children.index(point).not_nil!
    polygon_arm = variant_type.children.index(polygon).not_nil!
    variant_values = [
      CrystalClick::BinaryValue.variant(variant_type, point_arm, point_a),
      CrystalClick::BinaryValue.variant(variant_type, polygon_arm, polygon_b),
      CrystalClick::BinaryValue.variant_null(variant_type),
    ] of CrystalClick::BinaryValue
    variant_roles = CrystalClick::BinaryBulkTypePlan.new(
      variant_type, CrystalClick::BinaryBulkProfile.single_stream
    ).roles
    variant_roles.should contain("root.discriminators")
    variant_roles.size.to_u64.should eq(
      CrystalClick::BinaryBulkTypePlan.new(
        variant_type.child_at(0), CrystalClick::BinaryBulkProfile.single_stream
      ).role_count +
      CrystalClick::BinaryBulkTypePlan.new(
        variant_type.child_at(1), CrystalClick::BinaryBulkProfile.single_stream
      ).role_count + 1_u64
    )

    cases = [
      {tuple_type, [[tuple_value] of CrystalClick::BinaryValue] of Array(CrystalClick::BinaryValue)},
      {array_type, [[array_values[0], array_values[1]] of CrystalClick::BinaryValue, [array_values[2]] of CrystalClick::BinaryValue]},
      {map_type, [[map_value] of CrystalClick::BinaryValue] of Array(CrystalClick::BinaryValue)},
      {nested_type, [[nested_value] of CrystalClick::BinaryValue] of Array(CrystalClick::BinaryValue)},
      {variant_type, [[variant_values[0], variant_values[1]] of CrystalClick::BinaryValue, [variant_values[2]] of CrystalClick::BinaryValue]},
    ] of Tuple(CrystalClick::BinaryDataType, Array(Array(CrystalClick::BinaryValue)))

    cases.each do |type, marks|
      streams = CrystalClick::BinaryBulkCodec.encode(type, marks)
      plan = CrystalClick::BinaryBulkPhysicalPlan.new(type, "v")
      plan.stream_names.keys.sort.should eq(streams.roles)
      plan.stream_names.size.should eq(streams.role_count)
      w238b_assert_marks(
        CrystalClick::BinaryBulkCodec.decode(type, streams, marks.map(&.size.to_u64)),
        marks,
      )
    end
  end

  it "keeps Nullable(Point) null defaults separate from present Point body lanes" do
    point = w238b_custom("Point")
    nullable_point = CrystalClick::BinaryDataType.nullable(point)
    null_row = CrystalClick::BinaryValue.nullable(nullable_point)
    present_row = CrystalClick::BinaryValue.nullable(
      nullable_point,
      w238b_custom_point(0x3ff0_0000_0000_0000_u64, 0x4000_0000_0000_0000_u64),
    )
    marks = [
      [null_row, present_row] of CrystalClick::BinaryValue,
      [CrystalClick::BinaryValue.nullable(nullable_point)] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)

    plan = CrystalClick::BinaryBulkTypePlan.new(
      nullable_point, CrystalClick::BinaryBulkProfile.single_stream
    )
    plan.roles.should contain("root.nulls")
    plan.roles.should contain("root.nested.field.0.data")
    plan.roles.should contain("root.nested.field.1.data")
    plan.role_count.should eq(3_u64)

    streams = CrystalClick::BinaryBulkCodec.encode(nullable_point, marks)
    streams.stream("root.nulls").bytes.should eq(Bytes[0x01_u8, 0x00_u8, 0x01_u8])
    streams.stream("root.nested.field.0.data").bytes.should eq(
      Bytes.new(24) { |index| index < 8 || index >= 16 ? 0_u8 : [0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0xf0_u8, 0x3f_u8][index - 8] }
    )
    streams.stream("root.nested.field.1.data").bytes.should eq(
      Bytes.new(24) { |index| index < 8 || index >= 16 ? 0_u8 : [0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x40_u8][index - 8] }
    )
    w238b_assert_marks(
      CrystalClick::BinaryBulkCodec.decode(nullable_point, streams, [2_u64, 1_u64]),
      marks,
    )
  end

  it "charges the transparent nominal wrapper's hidden descriptor/value node and edge" do
    point_type = w238b_custom("Point")
    body_type = point_type.child_at(0)
    point_value = w238b_custom_point(0x3ff0_0000_0000_0000_u64, 0x4000_0000_0000_0000_u64)
    body_value = point_value.child_at(0)
    point_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
    body_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)

    CrystalClick::BinaryBulkCodec.encode_with_budget(
      point_type, [[point_value] of CrystalClick::BinaryValue], point_budget
    )
    CrystalClick::BinaryBulkCodec.encode_with_budget(
      body_type, [[body_value] of CrystalClick::BinaryValue], body_budget
    )
    point_budget.node_count.should eq(body_budget.node_count + 2)
    point_budget.element_count.should eq(body_budget.element_count + 2)
    point_budget.wire_byte_count.should eq(body_budget.wire_byte_count)

    shallow = CrystalClick::BinaryCodecLimits.new(
      max_depth: 2, max_nodes: 128, max_elements: 128, max_bytes: 1024
    )
    CrystalClick::BinaryBulkCodec.encode(
      body_type, [[body_value] of CrystalClick::BinaryValue], shallow
    ).role_count.should eq(2)
    expect_raises(CrystalClick::UnsupportedFormatError, /depth limit/) do
      CrystalClick::BinaryBulkCodec.encode(
        point_type, [[point_value] of CrystalClick::BinaryValue], shallow
      )
    end
  end
end
