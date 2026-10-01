module CrystalClick
  # Immutable handle to one nested record in a Geo Array result. Level zero is
  # the table row; each array edge advances one topology level.
  struct WideGeoArrayRow
    @data : WideGeoArrayColumnData
    @level : Int32
    @record_index : Int32

    def initialize(@data : WideGeoArrayColumnData, level : Int, record_index : Int)
      if level < 0 || level >= @data.level_count
        raise BoundsError.new("Geo Array row level is out of bounds")
      end
      if record_index < 0 || record_index >= @data.topology.record_count(level)
        raise BoundsError.new("Geo Array record index is out of bounds")
      end
      @level = level.to_i32
      @record_index = record_index.to_i32
    end

    def data : WideGeoArrayColumnData
      @data
    end

    def level : Int32
      @level
    end

    def record_index : Int32
      @record_index
    end

    def type_name : String
      @data.type_name
    end

    def size : Int32
      size = @data.size_at(@level, @record_index)
      if size > Int32::MAX.to_u64
        raise BoundsError.new("Geo Array child count exceeds the supported index range")
      end
      size.to_i32
    end

    def terminal? : Bool
      @level + 1 == @data.level_count
    end

    def array_at(index : Int) : WideGeoArrayRow
      raise ArgumentError.new("terminal Geo Array records contain Points") if terminal?
      child_index = checked_child_index(index)
      next_record = @data.offset_at(@level, @record_index) + child_index.to_u64
      WideGeoArrayRow.new(@data, @level + 1, next_record.to_i32)
    end

    def point_at(index : Int) : WidePointValue
      raise ArgumentError.new("nonterminal Geo Array records contain nested arrays") unless terminal?
      child_index = checked_child_index(index)
      point_index = @data.offset_at(@level, @record_index) + child_index.to_u64
      @data.point_at(point_index.to_i32)
    end

    def each_array(&block : WideGeoArrayRow ->) : Nil
      raise ArgumentError.new("terminal Geo Array records contain Points") if terminal?
      size.times do |index|
        yield array_at(index)
      end
      nil
    end

    def each_point(&block : WidePointValue ->) : Nil
      raise ArgumentError.new("nonterminal Geo Array records contain nested arrays") unless terminal?
      size.times do |index|
        yield point_at(index)
      end
      nil
    end

    private def checked_child_index(index : Int) : Int32
      if index < 0 || index >= size
        raise BoundsError.new("Geo Array child index is out of bounds")
      end
      index.to_i32
    end
  end
end
