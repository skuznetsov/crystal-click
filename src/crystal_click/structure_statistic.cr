module CrystalClick
  # One opaque Object/Dynamic shared-path statistic. Names are raw detached
  # bytes, not filenames or text that needs UTF-8 normalization.
  class StructureStatistic
    @name : String
    getter count : UInt64

    def initialize(name : String, @count : UInt64)
      @name = String.new(name.to_slice)
    end

    def name : String
      String.new(@name.to_slice)
    end

    def name_byte_size : Int32
      @name.bytesize
    end

    def name_byte_at(index : Int) : UInt8
      @name.to_slice[index]
    end

    def same_name?(other : StructureStatistic) : Bool
      return false unless @name.bytesize == other.name_byte_size
      @name.bytesize.times do |index|
        return false unless @name.to_slice[index] == other.name_byte_at(index)
      end
      true
    end

    def name_hash : UInt64
      hash = 0xcbf29ce484222325_u64
      @name.to_slice.each do |byte|
        hash = (hash ^ byte.to_u64) &* 0x100000001b3_u64
      end
      hash
    end

    def ==(other : StructureStatistic) : Bool
      @count == other.@count && same_name?(other)
    end

    def_hash @name, @count
  end
end
