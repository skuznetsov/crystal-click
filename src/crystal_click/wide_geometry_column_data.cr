module CrystalClick
  # Owned Geometry tags, local arm ranks, Point values, and the six immutable
  # nominal Geo Array owners for one materialized window.
  class WideGeometryColumnData
    @plan : GeometryColumnType
    @tags : Array(UInt8)
    @arm_indexes : Array(Int32)
    @points : Array(WidePointValue)
    @geo_arrays : StaticArray(WideGeoArrayColumnData?, 7)
    @arm_counts : StaticArray(Int32, 7)
    @retained_logical_charge : UInt64

    def initialize(
      tags : Array(UInt8),
      point_values : Array(WidePointValue),
      geo_arrays : Hash(WideGeometryArm, WideGeoArrayColumnData),
    )
      @plan = GeometryColumnType.for_type("Geometry") ||
              raise ArgumentError.new("Geometry requires the exact Geometry descriptor")

      if tags.size.to_u64 > GeometryColumnType::MAX_LOGICAL_ELEMENTS
        raise ArgumentError.new("Geometry row count exceeds the supported range")
      end

      arm_counts = StaticArray(Int32, 7).new(0)
      tags.each do |tag|
        case tag
        when 0_u8 then arm_counts[0] += 1
        when 1_u8 then arm_counts[1] += 1
        when 2_u8 then arm_counts[2] += 1
        when 3_u8 then arm_counts[3] += 1
        when 4_u8 then arm_counts[4] += 1
        when 5_u8 then arm_counts[5] += 1
        when 6_u8 then arm_counts[6] += 1
        when 255_u8 # NULL has no arm lane.
        else
          raise ArgumentError.new("Geometry contains an invalid global arm tag")
        end
      end

      unless point_values.size == arm_counts[3]
        raise ArgumentError.new("Geometry Point lane count does not match its discriminator tags")
      end

      geo_array_slots = StaticArray(WideGeoArrayColumnData?, 7).new(nil)
      geo_arrays.each do |arm, data|
        arm_index = checked_arm_index(arm)
        if arm_index == 3
          raise ArgumentError.new("Geometry Point values use the dense Point lane")
        end

        expected_name = arm.type_name
        unless data.type_name == expected_name
          raise ArgumentError.new("Geometry Geo Array owner has the wrong nominal arm type")
        end
        unless data.row_count == arm_counts[arm_index]
          raise ArgumentError.new("Geometry Geo Array owner row count does not match its tag histogram")
        end
        geo_array_slots[arm_index] = data
      end

      unless geo_arrays.size == 6
        raise ArgumentError.new("Geometry requires exactly six nominal Geo Array owners")
      end
      {0, 1, 2, 4, 5, 6}.each do |arm_index|
        unless geo_array_slots[arm_index]
          raise ArgumentError.new("Geometry is missing a nominal Geo Array owner")
        end
      end

      arm_level_counts = Array(Array(UInt64)).new(7) { [] of UInt64 }
      arm_point_counts = Array(UInt64).new(7, 0_u64)
      7.times do |arm_index|
        if arm_index == 3
          arm_point_counts[arm_index] = arm_counts[arm_index].to_u64
          next
        end

        data = geo_array_slots[arm_index] ||
               raise ArgumentError.new("Geometry is missing a nominal Geo Array owner")
        arm_level_counts[arm_index] = data.topology.level_counts
        arm_point_counts[arm_index] = data.point_count.to_u64
      end

      charge = @plan.materialization_charge(tags.size.to_u64, arm_level_counts, arm_point_counts) ||
               raise ArgumentError.new("Geometry materialization exceeds the supported logical budget")

      @tags = tags.dup
      @arm_indexes = Array(Int32).new(tags.size, -1_i32)
      next_indexes = StaticArray(Int32, 7).new(0)
      tags.each_with_index do |tag, row_index|
        next if tag == 255_u8

        arm_index = tag.to_i
        @arm_indexes[row_index] = next_indexes[arm_index]
        next_indexes[arm_index] += 1
      end
      @points = point_values.dup
      @geo_arrays = geo_array_slots
      @arm_counts = arm_counts
      @retained_logical_charge = charge
    end

    def type_name : String
      "Geometry"
    end

    def row_count : Int32
      @tags.size.to_i32
    end

    def tags : Array(UInt8)
      @tags.dup
    end

    def arm_indexes : Array(Int32)
      @arm_indexes.dup
    end

    def points : Array(WidePointValue)
      @points.dup
    end

    def arm_at(index : Int) : WideGeometryArm?
      tag = @tags[checked_row_index(index)]
      return nil if tag == 255_u8
      WideGeometryArm.for_tag(tag)
    end

    def arm_index_at(index : Int) : Int32?
      arm_index = @arm_indexes[checked_row_index(index)]
      arm_index < 0 ? nil : arm_index
    end

    def arm_count(arm : WideGeometryArm) : Int32
      @arm_counts[checked_arm_index(arm)]
    end

    def point_at(lane_index : Int) : WidePointValue
      if lane_index < 0 || lane_index >= @points.size
        raise BoundsError.new("Geometry Point lane index is out of bounds")
      end
      @points[lane_index]
    end

    def geo_array_data(arm : WideGeometryArm) : WideGeoArrayColumnData
      arm_index = checked_arm_index(arm)
      if arm_index == 3
        raise ArgumentError.new("Geometry Point values use the dense Point lane")
      end
      @geo_arrays[arm_index] ||
        raise ArgumentError.new("Geometry is missing a nominal Geo Array owner")
    end

    def row(index : Int) : WideGeometryRow
      WideGeometryRow.new(self, checked_row_index(index))
    end

    def retained_logical_charge : UInt64
      @retained_logical_charge
    end

    private def checked_row_index(index : Int) : Int32
      if index < 0 || index >= @tags.size
        raise BoundsError.new("Geometry outer row index is out of bounds")
      end
      index.to_i32
    end

    private def checked_arm_index(arm : WideGeometryArm) : Int32
      case arm
      when WideGeometryArm::LineString      then 0
      when WideGeometryArm::MultiLineString then 1
      when WideGeometryArm::MultiPolygon    then 2
      when WideGeometryArm::Point           then 3
      when WideGeometryArm::Polygon         then 4
      when WideGeometryArm::Ring            then 5
      when WideGeometryArm::MultiPoint      then 6
      else
        raise ArgumentError.new("Geometry arm value is invalid")
      end
    end
  end
end
