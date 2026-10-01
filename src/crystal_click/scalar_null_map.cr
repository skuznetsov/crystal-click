module CrystalClick
  # Immutable, owned one-byte-per-row Nullable mask for a scalar Tuple leaf.
  # The wire profile deliberately accepts only the canonical 0/1 encoding.
  class ScalarNullMap
    @bytes : Bytes

    def initialize(bytes : Bytes, expected_rows : UInt64)
      if expected_rows > Int32::MAX.to_u64 || bytes.size.to_u64 != expected_rows
        raise ArgumentError.new("Nullable Tuple mask length does not match rows")
      end
      bytes.each do |byte|
        raise ArgumentError.new("Nullable Tuple mask byte is not 0 or 1") unless byte == 0_u8 || byte == 1_u8
      end
      @bytes = bytes.dup
    end

    def size : Int32
      @bytes.size
    end

    def null_at?(index : Int) : Bool
      raise BoundsError.new("Nullable Tuple mask row index is out of bounds") if index < 0 || index >= @bytes.size
      @bytes[index] == 1_u8
    end

    # Callers receive detached mutable data, never the retained mask storage.
    def bytes : Array(UInt8)
      @bytes.to_a
    end

    def logical_charge : UInt64
      instance_sizeof(ScalarNullMap).to_u64 + @bytes.size.to_u64
    end

    def ==(other : self) : Bool
      return false unless size == other.size

      index = 0
      while index < size
        return false unless null_at?(index) == other.null_at?(index)
        index += 1
      end
      true
    end

    def hash(hasher)
      hasher = @bytes.hash(hasher)
      hasher
    end
  end
end
