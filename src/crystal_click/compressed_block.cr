module CrystalClick
  module CompressedBlock
    CHECKSUM_SIZE     = 16
    HEADER_SIZE       =  9
    FRAME_HEADER_SIZE = CHECKSUM_SIZE + HEADER_SIZE
    METHOD_LZ4        = 0x82_u8
    METHOD_ZSTD       = 0x90_u8
    DEFAULT_MAX_FRAME = 64_i64 * 1024 * 1024

    struct Frame
      getter end_offset : Int64
      getter output : Bytes

      def initialize(@end_offset : Int64, @output : Bytes)
      end
    end

    def self.decode_frame(
      data : Bytes,
      offset : Int64,
      max_compressed_size : Int64 = DEFAULT_MAX_FRAME,
      max_decompressed_size : Int64 = DEFAULT_MAX_FRAME,
    ) : Frame
      raise CorruptPartError.new("invalid compressed frame limit") if max_compressed_size < HEADER_SIZE
      raise CorruptPartError.new("invalid decompressed frame limit") if max_decompressed_size <= 0
      raise CorruptPartError.new("frame offset out of bounds") if offset < 0 || offset > data.size.to_i64 - FRAME_HEADER_SIZE

      header_offset = offset.to_i
      method = data[header_offset + CHECKSUM_SIZE]
      compressed_size = u32(data, header_offset + CHECKSUM_SIZE + 1).to_i64
      decompressed_size = u32(data, header_offset + CHECKSUM_SIZE + 5).to_i64
      raise CorruptPartError.new("compressed frame size is invalid") if compressed_size < HEADER_SIZE || compressed_size > max_compressed_size
      raise CorruptPartError.new("decompressed frame size is invalid") if decompressed_size <= 0 || decompressed_size > max_decompressed_size

      remaining = data.size.to_i64 - offset - CHECKSUM_SIZE
      raise CorruptPartError.new("compressed frame is truncated") if compressed_size > remaining
      frame_end = offset + CHECKSUM_SIZE + compressed_size
      payload_size = compressed_size - HEADER_SIZE
      payload = data[header_offset + FRAME_HEADER_SIZE, payload_size.to_i]
      output = case method
               when METHOD_LZ4
                 LZ4.decode(payload, decompressed_size.to_i)
               when METHOD_ZSTD
                 ZSTD.decode(payload, decompressed_size.to_i, max_decompressed_size)
               else
                 raise UnsupportedFormatError.new("unsupported ClickHouse compression method")
               end
      Frame.new(frame_end, output)
    end

    def self.decode_all(
      data : Bytes,
      max_compressed_size : Int64 = DEFAULT_MAX_FRAME,
      max_decompressed_size : Int64 = DEFAULT_MAX_FRAME,
      max_output_size : Int64 = DEFAULT_MAX_FRAME,
    ) : Bytes
      raise CorruptPartError.new("compressed stream is empty") if data.empty?
      raise CorruptPartError.new("invalid aggregate decompressed limit") if max_output_size < 0

      output = IO::Memory.new
      offset = 0_i64
      total_output = 0_i64
      while offset < data.size.to_i64
        frame = decode_frame(data, offset, max_compressed_size, max_decompressed_size)
        frame_output_size = frame.output.size.to_i64
        raise CorruptPartError.new("decompressed stream exceeds limit") if frame_output_size > max_output_size - total_output
        total_output += frame_output_size
        output.write(frame.output)
        raise CorruptPartError.new("compressed frame did not advance") if frame.end_offset <= offset
        offset = frame.end_offset
      end
      raise CorruptPartError.new("compressed stream has trailing bytes") unless offset == data.size.to_i64
      output.to_slice
    end

    private def self.u32(bytes : Bytes, offset : Int) : UInt32
      raise CorruptPartError.new("truncated compressed header") if offset < 0 || offset > bytes.size - 4
      bytes[offset].to_u32 |
        (bytes[offset + 1].to_u32 << 8) |
        (bytes[offset + 2].to_u32 << 16) |
        (bytes[offset + 3].to_u32 << 24)
    end
  end
end
