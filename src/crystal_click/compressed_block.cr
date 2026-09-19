module CrystalClick
  module CompressedBlock
    CHECKSUM_SIZE        = 16
    HEADER_SIZE          =  9
    FRAME_HEADER_SIZE    = CHECKSUM_SIZE + HEADER_SIZE
    METHOD_LZ4           = 0x82_u8
    METHOD_ZSTD          = 0x90_u8
    METHOD_MULTIPLE      = 0x91_u8
    METHOD_DELTA         = 0x92_u8
    MAX_MULTIPLE_METHODS =       2
    DEFAULT_MAX_FRAME    = 64_i64 * 1024 * 1024

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
               when METHOD_MULTIPLE
                 decode_multiple(payload, decompressed_size.to_i, max_decompressed_size)
               else
                 raise UnsupportedFormatError.new("unsupported ClickHouse compression method")
               end
      raise CorruptPartError.new("compressed frame output size mismatch") unless output.size == decompressed_size
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

    private def self.decode_multiple(input : Bytes, expected_size : Int, max_size : Int64) : Bytes
      raise CorruptPartError.new("Multiple payload is empty") if input.empty?

      method_count = input[0].to_i
      raise CorruptPartError.new("Multiple method count exceeds limit") if method_count > MAX_MULTIPLE_METHODS
      raise CorruptPartError.new("truncated Multiple method list") if input.size < 1 + method_count
      unless method_count == 2 && input[1] == METHOD_DELTA && input[2] == METHOD_ZSTD
        raise UnsupportedFormatError.new("unsupported ClickHouse Multiple codec list")
      end

      current = input[1 + method_count, input.size - 1 - method_count]
      current = decode_nested_stage(current, METHOD_ZSTD, max_size)
      current = decode_nested_stage(current, METHOD_DELTA, max_size)
      raise CorruptPartError.new("Multiple output size mismatch") unless current.size == expected_size
      current
    end

    private def self.decode_nested_stage(input : Bytes, expected_method : UInt8, max_size : Int64) : Bytes
      raise CorruptPartError.new("nested compressed block header is truncated") if input.size < HEADER_SIZE

      method = input[0]
      raise UnsupportedFormatError.new("unexpected nested ClickHouse compression method") unless method == expected_method

      compressed_size = u32(input, 1).to_i64
      decompressed_size = u32(input, 5).to_i64
      raise CorruptPartError.new("nested compressed block size is invalid") if compressed_size < HEADER_SIZE || compressed_size != input.size
      raise CorruptPartError.new("nested decompressed block size is invalid") if decompressed_size <= 0 || decompressed_size > max_size

      payload = input[HEADER_SIZE, (compressed_size - HEADER_SIZE).to_i]
      case expected_method
      when METHOD_ZSTD
        ZSTD.decode(payload, decompressed_size.to_i, max_size)
      when METHOD_DELTA
        decode_delta(payload, decompressed_size.to_i, max_size)
      else
        raise UnsupportedFormatError.new("unsupported nested ClickHouse compression method")
      end
    end

    private def self.decode_delta(input : Bytes, expected_size : Int, max_size : Int64) : Bytes
      raise CorruptPartError.new("invalid Delta output size") if expected_size <= 0 || expected_size.to_i64 > max_size
      raise CorruptPartError.new("Delta output size is not UInt64-aligned") unless expected_size % 8 == 0
      raise CorruptPartError.new("Delta payload header is truncated") if input.size < 2
      raise UnsupportedFormatError.new("unsupported Delta width") unless input[0] == 8_u8
      raise CorruptPartError.new("Delta skip byte is invalid") unless input[1] == 0_u8
      raise CorruptPartError.new("Delta payload size mismatch") unless input.size == 2 + expected_size

      output = Bytes.new(expected_size)
      accumulator = 0_u64
      input_offset = 2
      output_offset = 0
      while input_offset < input.size
        accumulator = accumulator &+ u64(input, input_offset)
        write_u64(output, output_offset, accumulator)
        input_offset += 8
        output_offset += 8
      end
      output
    end

    private def self.u64(bytes : Bytes, offset : Int) : UInt64
      raise CorruptPartError.new("truncated UInt64") if offset < 0 || offset > bytes.size - 8
      bytes[offset].to_u64 |
        (bytes[offset + 1].to_u64 << 8) |
        (bytes[offset + 2].to_u64 << 16) |
        (bytes[offset + 3].to_u64 << 24) |
        (bytes[offset + 4].to_u64 << 32) |
        (bytes[offset + 5].to_u64 << 40) |
        (bytes[offset + 6].to_u64 << 48) |
        (bytes[offset + 7].to_u64 << 56)
    end

    private def self.write_u64(bytes : Bytes, offset : Int, value : UInt64)
      raise CorruptPartError.new("truncated UInt64 output") if offset < 0 || offset > bytes.size - 8
      8.times do |index|
        bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8
      end
    end
  end
end
