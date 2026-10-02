module CrystalClick
  # Detached selected transport result. Accessors return copies so mutation of
  # one caller's view cannot alter the retained window.
  class CompressedMarkWindow
    getter first_mark : Int32
    getter prefix_size : Int32

    @bytes : Bytes
    @offsets : Array(UInt64)
    @rows_per_mark : Array(UInt64)

    def initialize(
      bytes : Bytes,
      offsets : Array(UInt64),
      rows_per_mark : Array(UInt64),
      first_mark : Int,
      prefix_size : Int,
    )
      if first_mark < 0 || first_mark > Int32::MAX
        raise ArgumentError.new("first mark exceeds supported in-memory domain")
      end
      if prefix_size < 0 || prefix_size > Int32::MAX
        raise ArgumentError.new("prefix size exceeds supported in-memory domain")
      end
      @bytes = bytes.dup
      @offsets = offsets.dup
      @rows_per_mark = rows_per_mark.dup
      @first_mark = first_mark.to_i32
      @prefix_size = prefix_size.to_i32
    end

    def bytes : Bytes
      @bytes.dup
    end

    def offsets : Array(UInt64)
      @offsets.dup
    end

    def rows_per_mark : Array(UInt64)
      @rows_per_mark.dup
    end
  end
end
