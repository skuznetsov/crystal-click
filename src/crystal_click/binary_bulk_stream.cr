module CrystalClick
  # Detached owner for one decompressed physical lane and its per-mark byte
  # coordinates. Construction intentionally leaves semantic grid validation to
  # BinaryBulkCodec so callers can represent malformed inputs for validation.
  class BinaryBulkStream
    @bytes : Bytes
    @offsets : Array(UInt64)

    def initialize(bytes : Bytes, offsets : Array(UInt64))
      @bytes = Bytes.new(bytes.size) { |index| bytes[index] }
      @offsets = offsets.dup
    end

    def bytes : Bytes
      Bytes.new(@bytes.size) { |index| @bytes[index] }
    end

    def offsets : Array(UInt64)
      @offsets.dup
    end

    def byte_size : Int32
      @bytes.size
    end

    # A malformed empty offset grid reports a negative count; the paired codec
    # rejects that grid before using it as a mark domain.
    def mark_count : Int32
      @offsets.size - 1
    end

    def offset_count : Int32
      @offsets.size
    end

    def offset_at(index : Int) : UInt64
      @offsets[index]
    end

    def byte_at(index : Int) : UInt8
      @bytes[index]
    end

    # The returned Slice borrows only the requested range. It is read-only by
    # convention and never copies unselected lane bytes.
    def borrowed_slice(offset : UInt64, size : UInt64) : Bytes
      if offset > @bytes.size.to_u64 || size > (@bytes.size.to_u64 - offset) ||
         offset > Int32::MAX.to_u64 || size > Int32::MAX.to_u64
        raise CorruptPartError.new("binary bulk byte range is outside its lane")
      end
      @bytes[offset.to_i32, size.to_i32]
    end

    def borrowed_slice(offset : Int, size : Int) : Bytes
      if offset < 0 || size < 0 || offset.to_i128 > UInt64::MAX.to_i128 || size.to_i128 > UInt64::MAX.to_i128
        raise CorruptPartError.new("binary bulk byte range is outside its lane")
      end
      borrowed_slice(offset.to_u64, size.to_u64)
    end
  end
end
