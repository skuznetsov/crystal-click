module CrystalClick
  # Immutable owner/index handle to one row in a materialized Geometry window.
  struct WideGeometryRow
    @data : WideGeometryColumnData
    @row_index : Int32

    def initialize(@data : WideGeometryColumnData, row_index : Int)
      if row_index < 0 || row_index >= @data.row_count
        raise BoundsError.new("Geometry outer row index is out of bounds")
      end
      @row_index = row_index.to_i32
    end

    def data : WideGeometryColumnData
      @data
    end

    def row_index : Int32
      @row_index
    end

    def tag : UInt8
      arm = @data.arm_at(@row_index)
      arm ? arm.value.to_u8 : 255_u8
    end

    def arm : WideGeometryArm?
      @data.arm_at(@row_index)
    end

    def null? : Bool
      arm.nil?
    end

    def arm_index : Int32?
      @data.arm_index_at(@row_index)
    end

    def type_name : String
      "Geometry"
    end

    def arm_type_name : String?
      arm.try(&.type_name)
    end

    def point : WidePointValue
      unless arm == WideGeometryArm::Point
        raise ArgumentError.new("Geometry row does not contain a Point arm")
      end
      lane_index = arm_index ||
                   raise ArgumentError.new("Geometry Point row has no local arm rank")
      @data.point_at(lane_index)
    end

    def geo_array : WideGeoArrayRow
      active_arm = arm || raise ArgumentError.new("NULL Geometry row has no Geo Array value")
      if active_arm == WideGeometryArm::Point
        raise ArgumentError.new("Geometry Point rows use the dense Point lane")
      end
      lane_index = arm_index ||
                   raise ArgumentError.new("Geometry Geo Array row has no local arm rank")
      @data.geo_array_data(active_arm).row(lane_index)
    end
  end
end
