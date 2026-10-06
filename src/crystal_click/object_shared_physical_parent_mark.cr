module CrystalClick
  # One physical parent mark and its independently row-counted logical chunks.
  class ObjectSharedPhysicalParentMark
    getter physical_rows : UInt64

    @chunks : Array(ObjectSharedPhysicalChunk)

    def initialize(@physical_rows : UInt64, chunks : Array(ObjectSharedPhysicalChunk))
      if @physical_rows == 0_u64 || @physical_rows > Int32::MAX.to_u64
        raise ArgumentError.new("Object shared physical parent rows must be positive Int32 values")
      end
      if chunks.empty?
        raise ArgumentError.new("Object shared physical parent must contain at least one chunk")
      end
      @chunks = chunks.dup
    end

    def chunks : Array(ObjectSharedPhysicalChunk)
      @chunks.dup
    end

    def chunk_count : Int32
      @chunks.size
    end

    def chunk_at(index : Int) : ObjectSharedPhysicalChunk
      @chunks[index]
    end
  end
end
