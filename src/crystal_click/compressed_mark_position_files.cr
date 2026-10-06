module CrystalClick
  # Owned compressed data/mark files paired with arbitrary logical-byte
  # position queries mapped into the same physical frame coordinate system.
  class CompressedMarkPositionFiles
    @files : CompressedMarkFiles
    @positions : Array(Tuple(UInt64, UInt64))

    def initialize(@files : CompressedMarkFiles, positions : Array(Tuple(UInt64, UInt64)))
      @positions = positions.dup
    end

    def files : CompressedMarkFiles
      @files
    end

    def positions : Array(Tuple(UInt64, UInt64))
      @positions.dup
    end

    def count : Int32
      @positions.size
    end

    def position_at(index : Int) : Tuple(UInt64, UInt64)
      if index < 0 || index >= @positions.size
        raise IndexError.new("compressed mark position index is outside the query result")
      end
      @positions[index]
    end
  end
end
