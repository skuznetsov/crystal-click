module CrystalClick
  # Header-indexed frame metadata. The payload checksum is intentionally
  # verified only when a consumer touches this frame.
  struct CompressedFrameDescriptor
    getter compressed_offset : Int64
    getter end_offset : Int64
    getter logical_start : Int64
    getter logical_end : Int64
    getter method : UInt8

    def initialize(
      @compressed_offset : Int64,
      @end_offset : Int64,
      @logical_start : Int64,
      @logical_end : Int64,
      @method : UInt8,
    )
    end

    def compressed_size : Int64
      end_offset - compressed_offset - CompressedBlock::CHECKSUM_SIZE
    end

    def decompressed_size : Int64
      logical_end - logical_start
    end
  end
end
