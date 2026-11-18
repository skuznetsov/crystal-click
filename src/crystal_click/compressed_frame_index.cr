module CrystalClick
  # Authenticated identity of one compressed frame as observed during a
  # bounded source read. The digest is the exact ClickHouse CityHash128 value
  # stored in the frame header, after the payload has been checked against it.
  struct CompressedFrameFingerprint
    getter compressed_offset : Int64
    getter end_offset : Int64
    getter logical_start : Int64
    getter logical_end : Int64
    getter method : UInt8
    getter checksum : {UInt64, UInt64}

    def initialize(
      @compressed_offset : Int64,
      @end_offset : Int64,
      @logical_start : Int64,
      @logical_end : Int64,
      @method : UInt8,
      @checksum : {UInt64, UInt64},
    )
    end

    def self.from_authenticated_frame(
      frame : CompressedFrameDescriptor,
      checksum : {UInt64, UInt64},
    ) : CompressedFrameFingerprint
      new(frame.compressed_offset, frame.end_offset, frame.logical_start, frame.logical_end, frame.method, checksum)
    end
  end

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

    # Revalidates the retained header index against one current mapped image.
    # Compact direct-UInt64 scans reuse this index only after proving that the
    # mapped file still has the exact geometry admitted with its mark grid.
    # Payload checksums remain lazy and are verified immediately before decode.
    def validate_data_geometry!(data : Bytes, limits : CompressedStreamLimits, budget : CompressedStreamBudget) : Nil
      budget.ensure_direction(false)
      unless data.size.to_i64 == @data_size && @data_size > 0 &&
             @data_size <= Int32::MAX && @data_size <= limits.max_file_bytes
        raise CorruptPartError.new("compressed data file size changed since frame-index admission")
      end

      offset = 0_i64
      @frames.each do |frame|
        budget.reserve_records(1_i64)
        if offset > @data_size - CompressedBlock::FRAME_HEADER_SIZE
          raise CorruptPartError.new("compressed frame header is truncated")
        end

        header_offset = offset.to_i + CompressedBlock::CHECKSUM_SIZE
        method = data[header_offset]
        compressed_size = read_u32(data, header_offset + 1).to_i64
        decompressed_size = read_u32(data, header_offset + 5).to_i64
        unless method == CompressedBlock::METHOD_LZ4 || method == CompressedBlock::METHOD_ZSTD ||
               method == CompressedBlock::METHOD_MULTIPLE
          raise UnsupportedFormatError.new("unsupported ClickHouse compression method")
        end

        unless frame.compressed_offset == offset && frame.method == method &&
               frame.compressed_size == compressed_size && frame.decompressed_size == decompressed_size
          raise CorruptPartError.new("compressed data frame geometry changed since Compact mark-grid admission")
        end
        if frame.end_offset > @data_size || frame.end_offset <= offset
          raise CorruptPartError.new("compressed frame index exceeds the mapped data file")
        end
        offset = frame.end_offset
      end

      unless offset == @data_size
        raise CorruptPartError.new("compressed data frame geometry changed since Compact mark-grid admission")
      end
      nil
    end

    # Read-only geometry guard for a previously admitted index. It checks all
    # frame headers against the same mapped image used by a range read or
    # delivery guard, without charging another operation's file/record budget.
    def validate_data_geometry_readonly!(data : Bytes, limits : CompressedStreamLimits) : Nil
      unless data.size.to_i64 == @data_size && @data_size > 0 &&
             @data_size <= Int32::MAX && @data_size <= limits.max_file_bytes
        raise CorruptPartError.new("compressed data file size changed since frame-index admission")
      end
      @frames.each do |frame|
        offset = frame.compressed_offset.to_i
        if offset < 0 || offset > data.size - CompressedBlock::FRAME_HEADER_SIZE
          raise CorruptPartError.new("compressed frame header is truncated")
        end
        header_offset = offset + CompressedBlock::CHECKSUM_SIZE
        method = data[header_offset]
        compressed_size = read_u32(data, header_offset + 1).to_i64
        decompressed_size = read_u32(data, header_offset + 5).to_i64
        frame_end = frame.compressed_offset + CompressedBlock::CHECKSUM_SIZE + compressed_size
        logical_end = frame.logical_start + decompressed_size
        unless method == frame.method &&
               compressed_size >= CompressedBlock::HEADER_SIZE &&
               frame_end == frame.end_offset &&
               logical_end == frame.logical_end &&
               frame_end <= @data_size
          raise CorruptPartError.new("compressed frame geometry changed since frame-index admission")
        end
      end
      nil
    end

    # Returns a half-open descriptor-index range for frames intersecting one
    # logical interval. This keeps per-mark transport work proportional to the
    # touched frames rather than the complete file index.
    def touched_frame_bounds(start : Int64, finish : Int64) : {Int32, Int32}
      if start < 0 || finish < start || finish > @logical_size
        raise ArgumentError.new("logical range is outside the decompressed stream")
      end
      return {0_i32, 0_i32} if start == finish

      low = 0
      high = @frames.size
      while low < high
        middle = low + (high - low) // 2
        if @frames[middle].logical_end <= start
          low = middle + 1
        else
          high = middle
        end
      end
      first = low

      high = @frames.size
      while low < high
        middle = low + (high - low) // 2
        if @frames[middle].logical_start < finish
          low = middle + 1
        else
          high = middle
        end
      end
      {first.to_i32, low.to_i32}
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
