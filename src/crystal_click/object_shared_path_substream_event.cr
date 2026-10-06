module CrystalClick
  # One ordered substream-getter callback in a decompressed Object path slice.
  # Offsets are relative to the complete Data slice, not compressed marks.
  class ObjectSharedPathSubstreamEvent
    @name : String
    getter relative_offset : UInt64

    def initialize(name : String, @relative_offset : UInt64)
      @name = String.new(name.to_slice)
    end

    def name : String
      String.new(@name.to_slice)
    end

    # Bounded readers can compare or preflight the owned name without first
    # allocating the detached public getter value.
    def name_byte_size : Int32
      @name.bytesize
    end

    def name_byte_at(index : Int) : UInt8
      @name.to_slice[index]
    end

    def matches_name?(candidate : String) : Bool
      return false unless candidate.bytesize == @name.bytesize
      candidate.to_slice.each_with_index do |byte, index|
        return false unless byte == @name.to_slice[index]
      end
      true
    end
  end
end
