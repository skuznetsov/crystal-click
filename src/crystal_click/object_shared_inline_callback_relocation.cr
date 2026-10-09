module CrystalClick
  # A fixed-width MarkInCompressedFile field embedded in one Compact callback.
  # Both offsets are local to the exact raw callback bytes named here; the
  # containing Data owner resolves them only after it authenticates callback
  # intervals and plans the final literal-LZ4 positions.
  class ObjectSharedInlineCallbackRelocation
    COORDINATE_BYTES = 16_u64

    @source_callback : String
    @source_offset : UInt64
    @target_callback : String
    @target_offset : UInt64

    def initialize(
      source_callback : String,
      @source_offset : UInt64,
      target_callback : String,
      @target_offset : UInt64,
    )
      if source_callback.empty? || target_callback.empty?
        raise ArgumentError.new("inline relocation callback names must be nonempty")
      end
      if @source_offset > UInt64::MAX - COORDINATE_BYTES
        raise ArgumentError.new("inline relocation source field overflows UInt64")
      end
      @source_callback = String.new(source_callback.to_slice)
      @target_callback = String.new(target_callback.to_slice)
    end

    def source_callback : String
      String.new(@source_callback.to_slice)
    end

    def source_offset : UInt64
      @source_offset
    end

    def target_callback : String
      String.new(@target_callback.to_slice)
    end

    def target_offset : UInt64
      @target_offset
    end

    def source_callback_byte_size : Int32
      @source_callback.bytesize
    end

    def source_callback_byte_at(index : Int) : UInt8
      @source_callback.to_slice[index]
    end

    def target_callback_byte_size : Int32
      @target_callback.bytesize
    end

    def target_callback_byte_at(index : Int) : UInt8
      @target_callback.to_slice[index]
    end
  end
end
