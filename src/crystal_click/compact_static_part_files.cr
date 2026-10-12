module CrystalClick
  # Detached, unpublished physical files produced by the static Compact
  # backend. Hash tuples use CityHash's {low64, high64} order.
  class CompactStaticPartFiles
    @data : Bytes
    @marks : Bytes

    getter raw_size : UInt64
    getter raw_hash_fold : {UInt64, UInt64}
    getter data_hash : {UInt64, UInt64}
    getter marks_hash : {UInt64, UInt64}

    def initialize(
      data : Bytes,
      marks : Bytes,
      @raw_size : UInt64,
      @raw_hash_fold : {UInt64, UInt64},
      @data_hash : {UInt64, UInt64},
      @marks_hash : {UInt64, UInt64},
    )
      @data = data.dup
      @marks = marks.dup
    end

    def data : Bytes
      @data.dup
    end

    def data_size : Int32
      @data.size
    end

    def marks : Bytes
      @marks.dup
    end

    def marks_size : Int32
      @marks.size
    end
  end
end
