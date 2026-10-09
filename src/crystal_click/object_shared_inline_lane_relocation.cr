module CrystalClick
  # Relocation within the raw physical bucket roles, before the source-native
  # Compact callback names are attached by ObjectSharedAdvancedInlineCodec.
  class ObjectSharedInlineLaneRelocation
    COORDINATE_BYTES = 16_u64

    @source_lane : String
    @source_offset : UInt64
    @target_lane : String
    @target_offset : UInt64

    def initialize(
      source_lane : String,
      @source_offset : UInt64,
      target_lane : String,
      @target_offset : UInt64,
    )
      if source_lane.empty? || target_lane.empty?
        raise ArgumentError.new("inline relocation lane names must be nonempty")
      end
      if @source_offset > UInt64::MAX - COORDINATE_BYTES
        raise ArgumentError.new("inline relocation source field overflows UInt64")
      end
      @source_lane = String.new(source_lane.to_slice)
      @target_lane = String.new(target_lane.to_slice)
    end

    def source_lane : String
      String.new(@source_lane.to_slice)
    end

    def source_offset : UInt64
      @source_offset
    end

    def target_lane : String
      String.new(@target_lane.to_slice)
    end

    def target_offset : UInt64
      @target_offset
    end

    def source_lane_byte_size : Int32
      @source_lane.bytesize
    end

    def source_lane_byte_at(index : Int) : UInt8
      @source_lane.to_slice[index]
    end

    def target_lane_byte_size : Int32
      @target_lane.bytesize
    end

    def target_lane_byte_at(index : Int) : UInt8
      @target_lane.to_slice[index]
    end
  end
end
