module CrystalClick
  # Owned depth-aware topology and raw Point values for one exact Geo Array
  # type. Public array exports are detached copies; row access retains this
  # immutable owner.
  class WideGeoArrayColumnData
    @topology : WideGeoArrayTopology
    @points : Array(WidePointValue)

    def initialize(
      plan : GeoArrayColumnType,
      level_sizes : Array(Array(UInt64)),
      points : Array(WidePointValue),
    )
      WideGeoArrayTopology.validate!(plan, level_sizes, points.size)
      @topology = WideGeoArrayTopology.new(plan, level_sizes)
      @points = points.dup
    end

    def topology : WideGeoArrayTopology
      @topology
    end

    def type_name : String
      @topology.plan.type_name
    end

    def row_count : Int32
      @topology.row_count
    end

    def point_count : Int32
      @topology.point_count
    end

    def points : Array(WidePointValue)
      @points.dup
    end

    def point_at(index : Int) : WidePointValue
      raise BoundsError.new("Geo Array Point index is out of bounds") if index < 0 || index >= @points.size
      @points[index]? || raise(BoundsError.new("Geo Array Point index is out of bounds"))
    end

    def row(index : Int) : WideGeoArrayRow
      raise BoundsError.new("Geo Array outer row index is out of bounds") if index < 0 || index >= row_count
      WideGeoArrayRow.new(self, 0, index)
    end

    # Logical bytes for the retained data/topology owner. Readers add their
    # selected schedule and temporary size/coordinate buffers separately.
    def retained_logical_charge : UInt64
      @topology.retained_logical_charge
    end

    def size_at(level : Int32, index : Int32) : UInt64
      @topology.size_at(level, index)
    end

    def offset_at(level : Int32, index : Int32) : UInt64
      @topology.offset_at(level, index)
    end

    def level_count : Int32
      @topology.level_count
    end
  end
end
