module CrystalClick
  # Authenticated coordinate provenance for one selected path inside the
  # decompressed physical Data lane. The lane owner keeps its frame index and
  # has already authenticated the paired bytes/marks; this object only narrows
  # that resolver to the validated path interval.
  class ObjectSharedInlineDataCoordinateContext < ObjectSharedInlineCoordinateContext
    @data_lane : ObjectSharedPhysicalLaneReader
    getter path_data_start : Int64
    getter path_data_end : Int64

    def initialize(
      @data_lane : ObjectSharedPhysicalLaneReader,
      @path_data_start : Int64,
      @path_data_end : Int64,
    )
      unless @data_lane.name == "data"
        raise ArgumentError.new("inline coordinate context requires the authenticated Data lane")
      end
      if @path_data_start < 0 || @path_data_end < @path_data_start || @path_data_end > @data_lane.logical_size
        raise CorruptPartError.new("inline coordinate context path interval is outside authenticated Data")
      end
      if @path_data_end > Int32::MAX
        raise CorruptPartError.new("inline coordinate context exceeds the supported logical byte domain")
      end
    end

    def path_data_size : Int64
      @path_data_end - @path_data_start
    end

    def data_lane_name : String
      @data_lane.name
    end

    # Proves that a retained callback/path payload is the exact byte view of
    # this authenticated lane interval. The comparison allocates no copy and
    # is charged to the same operation budget used by the caller.
    def validate_path_bytes!(relative_start : UInt64, bytes : Bytes, budget : BinaryCodecBudget) : Nil
      if budget.writing?
        raise ArgumentError.new("inline byte provenance requires a read-direction budget")
      end
      if relative_start > self.path_data_size.to_u64 ||
         bytes.size.to_u64 > self.path_data_size.to_u64 - relative_start
        raise CorruptPartError.new("inline bytes exceed their authenticated path interval")
      end

      byte_count = bytes.size.to_u64
      budget.ensure_wire_bytes(byte_count)
      budget.charge_wire_bytes(byte_count) if byte_count > 0_u64
      absolute_start = self.absolute_path_offset(relative_start)
      bytes.each_with_index do |byte, index|
        unless @data_lane.byte_at(absolute_start.to_i + index) == byte
          raise CorruptPartError.new("inline bytes differ from their authenticated Data interval")
        end
      end
      nil
    end

    def absolute_path_offset(relative_offset : UInt64) : Int64
      if relative_offset > self.path_data_size.to_u64 || relative_offset > Int64::MAX.to_u64
        raise CorruptPartError.new("inline callback offset is outside its authenticated path")
      end
      relative = relative_offset.to_i64
      if @path_data_start > Int64::MAX - relative
        raise CorruptPartError.new("inline callback absolute offset overflows")
      end
      @path_data_start + relative
    end

    # Resolves an original compressed/decompressed pair in the authenticated
    # parent Data domain and rejects coordinates outside this exact path.
    # Terminal offsets are retained here; a callback/role slice applies the
    # stricter terminal-at-role-end rule.
    def resolve_path_position(pair : Tuple(UInt64, UInt64)) : Int64
      absolute = @data_lane.logical_position(pair[0], pair[1])
      unless absolute >= @path_data_start && absolute <= @path_data_end
        raise CorruptPartError.new("inline coordinate is outside its authenticated path Data interval")
      end
      absolute
    end

    def callback_position(
      pair : Tuple(UInt64, UInt64),
      relative_start : UInt64,
      relative_end : UInt64,
      allow_terminal : Bool,
    ) : Int64?
      absolute = resolve_path_position(pair)
      slice_start = absolute_path_offset(relative_start)
      slice_end = absolute_path_offset(relative_end)
      if absolute < slice_start || (allow_terminal ? absolute > slice_end : absolute >= slice_end)
        return nil
      end
      absolute - slice_start
    end

    def same_lane?(lane : ObjectSharedPhysicalLaneReader) : Bool
      @data_lane.same?(lane)
    end

    def same_path?(other : ObjectSharedInlineDataCoordinateContext) : Bool
      @data_lane.same?(other.@data_lane) &&
        @path_data_start == other.@path_data_start &&
        @path_data_end == other.@path_data_end
    end

    def same_path?(other : ObjectSharedInlineCoordinateContext) : Bool
      other.is_a?(ObjectSharedInlineDataCoordinateContext) &&
        same_path?(other.as(ObjectSharedInlineDataCoordinateContext))
    end
  end
end
