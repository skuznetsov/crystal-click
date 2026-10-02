module CrystalClick
  # Owned complete decompressed Dynamic discriminator bytes and normalized
  # absolute mark grid. Physical compression and filesystem mark coordinates
  # are deliberately outside this value.
  class DynamicDiscriminatorStream
    @bytes : Bytes
    @marks : Array(DynamicDiscriminatorMark)

    def initialize(bytes : Bytes, marks : Array(DynamicDiscriminatorMark))
      @bytes = Bytes.new(bytes.size) { |index| bytes[index] }
      @marks = marks.dup
    end

    # A detached mutable copy for callers that need to retain or edit bytes.
    def bytes : Bytes
      Bytes.new(@bytes.size) { |index| @bytes[index] }
    end

    # A detached array; the marks themselves are immutable value records.
    def marks : Array(DynamicDiscriminatorMark)
      @marks.dup
    end

    def byte_size : Int32
      @bytes.size
    end

    def mark_count : Int32
      @marks.size
    end

    def mark_at(index : Int) : DynamicDiscriminatorMark
      @marks[index]
    end

    def byte_at(index : Int) : UInt8
      @bytes[index]
    end

    # Internal read-only-by-convention view for the paired codec. Bytes is a
    # mutable Slice type, so callers must not mutate this borrowed range.
    def borrowed_slice(offset : Int, size : Int) : Bytes
      if offset < 0 || size < 0 || offset > @bytes.size || size > @bytes.size - offset
        raise IndexError.new("Dynamic discriminator byte range is out of bounds")
      end
      @bytes[offset, size]
    end
  end
end
