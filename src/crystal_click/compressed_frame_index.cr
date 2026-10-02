module CrystalClick
  # Indexes every outer frame header without hashing or decompressing payloads.
  # Descriptor allocation happens only after the aggregate frame-record charge.
  class CompressedFrameIndex
    getter frames : Array(CompressedFrameDescriptor)
    getter data_size : Int64
    getter logical_size : Int64

    def initialize(data : Bytes, limits : CompressedStreamLimits, budget : CompressedStreamBudget)
      @data_size = data.size.to_i64
      frame_count, @logical_size = scan_headers(data, limits, budget)

      @frames = Array(CompressedFrameDescriptor).new(frame_count.to_i)
      offset = 0_i64
      logical_offset = 0_i64
      while offset < @data_size
        method = data[offset.to_i + CompressedBlock::CHECKSUM_SIZE]
        compressed_size = read_u32(data, offset.to_i + CompressedBlock::CHECKSUM_SIZE + 1).to_i64
        decompressed_size = read_u32(data, offset.to_i + CompressedBlock::CHECKSUM_SIZE + 5).to_i64
        frame_end = offset + CompressedBlock::CHECKSUM_SIZE + compressed_size
        logical_end = logical_offset + decompressed_size
        @frames << CompressedFrameDescriptor.new(offset, frame_end, logical_offset, logical_end, method)
        offset = frame_end
        logical_offset = logical_end
      end
    end

    # Mark coordinates name a frame start plus an in-frame offset. A frame-end
    # alias is legal, and physical EOF is a legal coordinate for real marks as
    # well as for the terminal mark after the final arm occurrence.
    def logical_position(compressed_offset : UInt64, decompressed_offset : UInt64, _terminal : Bool) : Int64
      if compressed_offset == @data_size.to_u64 && decompressed_offset == 0_u64
        return @logical_size
      end

      low = 0
      high = @frames.size
      while low < high
        middle = low + (high - low) // 2
        if @frames[middle].compressed_offset.to_u64 < compressed_offset
          low = middle + 1
        else
          high = middle
        end
      end
      if low < @frames.size
        frame = @frames[low]
        if frame.compressed_offset.to_u64 == compressed_offset
          raise CorruptPartError.new("mark decompressed offset exceeds frame") if decompressed_offset > frame.decompressed_size.to_u64
          return frame.logical_start + decompressed_offset.to_i64
        end
      end

      raise CorruptPartError.new("mark compressed offset does not name a frame boundary")
    end

    private def scan_headers(data : Bytes, limits : CompressedStreamLimits, budget : CompressedStreamBudget) : Tuple(Int64, Int64)
      raise CorruptPartError.new("compressed stream is empty") if data.empty?

      offset = 0_i64
      logical_offset = 0_i64
      frame_count = 0_i64
      while offset < @data_size
        budget.reserve_records(1_i64)
        if offset > @data_size - CompressedBlock::FRAME_HEADER_SIZE
          raise CorruptPartError.new("compressed frame header is truncated")
        end

        header_offset = offset.to_i + CompressedBlock::CHECKSUM_SIZE
        method = data[header_offset]
        compressed_size = read_u32(data, header_offset + 1).to_i64
        decompressed_size = read_u32(data, header_offset + 5).to_i64
        if compressed_size < CompressedBlock::HEADER_SIZE || compressed_size > limits.max_frame_compressed_bytes
          raise CorruptPartError.new("compressed frame size is invalid")
        end
        if decompressed_size <= 0 || decompressed_size > limits.max_frame_decompressed_bytes
          raise CorruptPartError.new("decompressed frame size is invalid")
        end

        unless method == CompressedBlock::METHOD_LZ4 || method == CompressedBlock::METHOD_ZSTD ||
               method == CompressedBlock::METHOD_MULTIPLE
          raise UnsupportedFormatError.new("unsupported ClickHouse compression method")
        end

        frame_size = CompressedBlock::CHECKSUM_SIZE.to_i64 + compressed_size
        if frame_size > @data_size - offset
          raise CorruptPartError.new("compressed frame is truncated")
        end
        if decompressed_size > Int64::MAX - logical_offset
          raise CorruptPartError.new("compressed stream logical size overflows")
        end

        offset += frame_size
        logical_offset += decompressed_size
        frame_count += 1_i64
      end

      raise CorruptPartError.new("compressed stream has trailing bytes") unless offset == @data_size
      {frame_count, logical_offset}
    end

    private def read_u32(bytes : Bytes, offset : Int) : UInt32
      if offset < 0 || offset > bytes.size - 4
        raise CorruptPartError.new("truncated compressed frame header")
      end
      bytes[offset].to_u32 |
        (bytes[offset + 1].to_u32 << 8) |
        (bytes[offset + 2].to_u32 << 16) |
        (bytes[offset + 3].to_u32 << 24)
    end
  end
end
