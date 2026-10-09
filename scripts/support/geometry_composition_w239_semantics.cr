module CrystalClick
  # Independently authored logical fixture for the finite W239 Geometry
  # profiles. This intentionally does not consume RowBinary bytes or call the
  # BinaryValue codec while constructing values.
  class GeometryCompositionW239Semantics
    alias PointBits = Tuple(UInt64, UInt64)

    GEO_ARMS = [
      "LineString", "MultiLineString", "MultiPolygon", "Point", "Polygon", "Ring", "MultiPoint",
    ] of String

    # Exact Float64 lane bits, written as numeric constants rather than parsed
    # from the stock probe's byte strings.
    P0 = {0x8000_0000_0000_0000_u64, 0x0000_0000_0000_0000_u64}
    P1 = {0x7ff8_0000_0000_1234_u64, 0x400c_0000_0000_0000_u64}
    P2 = {0xfff0_0000_0000_0000_u64, 0x0000_0000_0000_0001_u64}
    P3 = {0x4002_0000_0000_0000_u64, 0x7ff8_0000_0000_5678_u64}

    def self.values(id : String, type : BinaryDataType) : Array(BinaryValue)
      new.values_for(id, type)
    end

    # Compare public logical nodes and exact primitive payloads without using
    # BinaryValueCodec. Float64 uses the explicit bit accessor as well as raw
    # bytes, so NaN payloads and signed zero remain distinguishable.
    def self.same_value?(left : BinaryValue, right : BinaryValue) : Bool
      return false unless left.type == right.type
      return false unless left.type.tag == right.type.tag && left.type.name == right.type.name
      return false unless left.type.field_names == right.type.field_names
      return false unless left.is_null? == right.is_null?
      if left.type.tag == BinaryDataType::TAG_VARIANT
        return false unless left.variant_index? == right.variant_index?
      end

      case left.type.tag
      when BinaryDataType::TAG_STRING
        return false unless left.as_string == right.as_string
        return false unless exact_bytes?(left, right)
      when BinaryDataType::TAG_FLOAT64
        return false unless left.as_float64_bits == right.as_float64_bits
        return false unless exact_bytes?(left, right)
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_CUSTOM,
           BinaryDataType::TAG_MAP, BinaryDataType::TAG_NESTED,
           BinaryDataType::TAG_NULLABLE, BinaryDataType::TAG_VARIANT,
           BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        # Recursive values have no independent scalar payload at this node.
      else
        return false unless exact_bytes?(left, right)
      end

      return false unless left.child_count == right.child_count
      left.child_count.times do |index|
        return false unless same_value?(left.child_at(index), right.child_at(index))
      end
      true
    end

    def values_for(id : String, type : BinaryDataType) : Array(BinaryValue)
      case id
      when "geometry"
        geometry_rows(type)
      when "array_geometry"
        array_geometry_rows(type)
      when "tuple_string_geometry"
        tuple_string_geometry_rows(type)
      when "map_string_geometry"
        map_string_geometry_rows(type)
      when "nested_geometry_point"
        nested_geometry_point_rows(type)
      when "nullable_tuple_geometry"
        nullable_tuple_geometry_rows(type)
      when "variant_string_tuple_geometry"
        variant_string_tuple_geometry_rows(type)
      else
        raise ArgumentError.new("unlisted W239 semantic fixture profile #{id}")
      end
    end

    private def self.exact_bytes?(left : BinaryValue, right : BinaryValue) : Bool
      left_bytes = left.bytes
      right_bytes = right.bytes
      return false unless left_bytes.size == right_bytes.size
      left_bytes.size.times do |index|
        return false unless left_bytes[index] == right_bytes[index]
      end
      true
    end

    private def geometry_rows(type : BinaryDataType) : Array(BinaryValue)
      [
        geo_line(type, [P0, P1]),
        geo_line(type, [] of PointBits),
        geo_multi_line(type, [[P2] of PointBits, [] of PointBits]),
        geo_multi_polygon(type, [[[P3] of PointBits, [] of PointBits], [[] of PointBits]]),
        geo_point(type, P1),
        geo_polygon(type, [[P0] of PointBits, [] of PointBits]),
        geo_ring(type, [] of PointBits),
        geo_multi_point(type, [] of PointBits),
        geo_null(type),
        geo_multi_point(type, [P3]),
      ] of BinaryValue
    end

    private def array_geometry_rows(type : BinaryDataType) : Array(BinaryValue)
      geometry_type = type.child_at(0)
      [
        BinaryValue.array(type, [] of BinaryValue),
        BinaryValue.array(type, [geo_point(geometry_type, P1), geo_line(geometry_type, [P0, P1])]),
        BinaryValue.array(type, [geo_null(geometry_type), geo_multi_point(geometry_type, [] of PointBits), geo_ring(geometry_type, [] of PointBits)]),
        BinaryValue.array(type, [geo_polygon(geometry_type, [[P0] of PointBits, [] of PointBits]), geo_multi_line(geometry_type, [[P2] of PointBits, [] of PointBits])]),
        BinaryValue.array(type, [geo_multi_polygon(geometry_type, [[[P3] of PointBits, [] of PointBits], [[] of PointBits]]), geo_multi_point(geometry_type, [P3])]),
      ] of BinaryValue
    end

    private def tuple_string_geometry_rows(type : BinaryDataType) : Array(BinaryValue)
      geometry_type = type.child_at(1)
      [
        named_tuple(type, [BinaryValue.string(""), geo_point(geometry_type, P1)]),
        named_tuple(type, [BinaryValue.string("λ"), geo_null(geometry_type)]),
        named_tuple(type, [BinaryValue.string("nul\u0000byte"), geo_line(geometry_type, [] of PointBits)]),
        named_tuple(type, [BinaryValue.string("ring"), geo_ring(geometry_type, [] of PointBits)]),
        named_tuple(type, [BinaryValue.string("tail"), geo_multi_polygon(geometry_type, [[[P3] of PointBits, [] of PointBits], [[] of PointBits]])]),
      ] of BinaryValue
    end

    private def map_string_geometry_rows(type : BinaryDataType) : Array(BinaryValue)
      geometry_type = type.child_at(1)
      [
        BinaryValue.map(type, [] of BinaryValue),
        BinaryValue.map(type, [BinaryValue.string("a"), geo_point(geometry_type, P1)]),
        BinaryValue.map(type, [BinaryValue.string("b"), geo_null(geometry_type), BinaryValue.string("c"), geo_multi_point(geometry_type, [] of PointBits)]),
        BinaryValue.map(type, [BinaryValue.string("d"), geo_polygon(geometry_type, [[P0] of PointBits, [] of PointBits]), BinaryValue.string("e"), geo_ring(geometry_type, [P2, P3])]),
        BinaryValue.map(type, [BinaryValue.string("x"), geo_multi_line(geometry_type, [[P2] of PointBits, [] of PointBits]), BinaryValue.string("z"), geo_multi_polygon(geometry_type, [[[P3] of PointBits, [] of PointBits], [[] of PointBits]])]),
      ] of BinaryValue
    end

    private def nested_geometry_point_rows(type : BinaryDataType) : Array(BinaryValue)
      tuple_type = type.child_at(0)
      geometry_type = tuple_type.child_at(0)
      point_type = tuple_type.child_at(1)
      [
        BinaryValue.nested(type, [] of BinaryValue),
        BinaryValue.nested(type, [named_tuple(tuple_type, [geo_line(geometry_type, [P0, P1]), point_value(point_type, P0)])]),
        BinaryValue.nested(type, [named_tuple(tuple_type, [geo_null(geometry_type), point_value(point_type, P1)]), named_tuple(tuple_type, [geo_point(geometry_type, P1), point_value(point_type, P2)])]),
        BinaryValue.nested(type, [named_tuple(tuple_type, [geo_multi_line(geometry_type, [[P2] of PointBits, [] of PointBits]), point_value(point_type, P3)])]),
        BinaryValue.nested(type, [named_tuple(tuple_type, [geo_multi_polygon(geometry_type, [[[P3] of PointBits, [] of PointBits], [[] of PointBits]]), point_value(point_type, P0)]), named_tuple(tuple_type, [geo_ring(geometry_type, [] of PointBits), point_value(point_type, P2)])]),
      ] of BinaryValue
    end

    private def nullable_tuple_geometry_rows(type : BinaryDataType) : Array(BinaryValue)
      tuple_type = type.child_at(0)
      geometry_type = tuple_type.child_at(0)
      [
        BinaryValue.nullable(type),
        BinaryValue.nullable(type, named_tuple(tuple_type, [geo_null(geometry_type)])),
        BinaryValue.nullable(type, named_tuple(tuple_type, [geo_point(geometry_type, P1)])),
        BinaryValue.nullable(type, named_tuple(tuple_type, [geo_ring(geometry_type, [] of PointBits)])),
        BinaryValue.nullable(type, named_tuple(tuple_type, [geo_multi_polygon(geometry_type, [[[P3] of PointBits, [] of PointBits], [[] of PointBits]])])),
      ] of BinaryValue
    end

    private def variant_string_tuple_geometry_rows(type : BinaryDataType) : Array(BinaryValue)
      tuple_type = type.child_at(1)
      geometry_type = tuple_type.child_at(0)
      [
        BinaryValue.variant_null(type),
        BinaryValue.variant(type, 0, BinaryValue.string("text")),
        BinaryValue.variant(type, 1, named_tuple(tuple_type, [geo_null(geometry_type)])),
        BinaryValue.variant(type, 1, named_tuple(tuple_type, [geo_line(geometry_type, [P0, P1])])),
        BinaryValue.variant(type, 1, named_tuple(tuple_type, [geo_multi_polygon(geometry_type, [[[P3] of PointBits, [] of PointBits], [[] of PointBits]])])),
      ] of BinaryValue
    end

    private def named_tuple(type : BinaryDataType, fields : Array(BinaryValue)) : BinaryValue
      BinaryValue.tuple(type, fields)
    end

    private def geo_null(type : BinaryDataType) : BinaryValue
      BinaryValue.custom(type, BinaryValue.variant_null(type.child_at(0)))
    end

    private def geo_point(type : BinaryDataType, bits : PointBits) : BinaryValue
      geometry(type, "Point", point_value(geometry_arm_type(type, "Point"), bits))
    end

    private def geo_line(type : BinaryDataType, points : Array(PointBits)) : BinaryValue
      geometry(type, "LineString", points_alias_value(geometry_arm_type(type, "LineString"), points))
    end

    private def geo_ring(type : BinaryDataType, points : Array(PointBits)) : BinaryValue
      geometry(type, "Ring", points_alias_value(geometry_arm_type(type, "Ring"), points))
    end

    private def geo_multi_point(type : BinaryDataType, points : Array(PointBits)) : BinaryValue
      geometry(type, "MultiPoint", points_alias_value(geometry_arm_type(type, "MultiPoint"), points))
    end

    private def geo_multi_line(type : BinaryDataType, lines : Array(Array(PointBits))) : BinaryValue
      arm_type = geometry_arm_type(type, "MultiLineString")
      array_type = arm_type.child_at(0)
      linestring_type = array_type.child_at(0)
      values = lines.map { |points| points_alias_value(linestring_type, points) }
      geometry(type, "MultiLineString", BinaryValue.custom(arm_type, BinaryValue.array(array_type, values)))
    end

    private def geo_polygon(type : BinaryDataType, rings : Array(Array(PointBits))) : BinaryValue
      geometry(type, "Polygon", polygon_alias_value(geometry_arm_type(type, "Polygon"), rings))
    end

    private def geo_multi_polygon(type : BinaryDataType, polygons : Array(Array(Array(PointBits)))) : BinaryValue
      arm_type = geometry_arm_type(type, "MultiPolygon")
      array_type = arm_type.child_at(0)
      polygon_type = array_type.child_at(0)
      values = polygons.map { |rings| polygon_alias_value(polygon_type, rings) }
      geometry(type, "MultiPolygon", BinaryValue.custom(arm_type, BinaryValue.array(array_type, values)))
    end

    private def geometry(type : BinaryDataType, arm_name : String, arm_value : BinaryValue) : BinaryValue
      variant_type = type.child_at(0)
      index = GEO_ARMS.index(arm_name) || raise ArgumentError.new("unlisted W239 Geometry arm #{arm_name}")
      unless arm_value.type == variant_type.child_at(index)
        raise ArgumentError.new("W239 Geometry fixture arm value does not match #{arm_name}")
      end
      BinaryValue.custom(type, BinaryValue.variant(variant_type, index, arm_value))
    end

    private def geometry_arm_type(type : BinaryDataType, arm_name : String) : BinaryDataType
      index = GEO_ARMS.index(arm_name) || raise ArgumentError.new("unlisted W239 Geometry arm #{arm_name}")
      arm_type = type.child_at(0).child_at(index)
      raise ArgumentError.new("W239 Geometry fixture arm name differs") unless arm_type.name == arm_name
      arm_type
    end

    private def points_alias_value(type : BinaryDataType, points : Array(PointBits)) : BinaryValue
      array_type = type.child_at(0)
      point_type = array_type.child_at(0)
      values = points.map { |bits| point_value(point_type, bits) }
      BinaryValue.custom(type, BinaryValue.array(array_type, values))
    end

    private def polygon_alias_value(type : BinaryDataType, rings : Array(Array(PointBits))) : BinaryValue
      array_type = type.child_at(0)
      ring_type = array_type.child_at(0)
      values = rings.map { |points| points_alias_value(ring_type, points) }
      BinaryValue.custom(type, BinaryValue.array(array_type, values))
    end

    private def point_value(type : BinaryDataType, bits : PointBits) : BinaryValue
      tuple_type = type.child_at(0)
      fields = [float64(tuple_type.child_at(0), bits[0]), float64(tuple_type.child_at(1), bits[1])]
      BinaryValue.custom(type, BinaryValue.tuple(tuple_type, fields))
    end

    private def float64(type : BinaryDataType, bits : UInt64) : BinaryValue
      bytes = Bytes.new(8) { |index| ((bits >> (index * 8)) & 0xff_u64).to_u8 }
      BinaryValue.fixed(type, bytes)
    end
  end
end
