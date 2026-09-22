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

    # Operation-local high-water storage for borrowed frame output.
    # A slice returned by `decode_frame_into` is stable only until this
    # workspace is used again.
    class DecodeWorkspace
      def initialize
        @buffer = Bytes.new(0)
      end

      def buffer_for(size : Int) : Bytes
        raise CorruptPartError.new("negative decode workspace size") if size < 0
        @buffer = Bytes.new(size) if size > @buffer.size
        @buffer
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

    # Decodes into workspace-owned storage. `Frame#output` is borrowed until
    # the next decode that uses the same workspace.
    def self.decode_frame_into(
      data : Bytes,
      offset : Int64,
      workspace : DecodeWorkspace,
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
                 destination = workspace.buffer_for(decompressed_size.to_i)
                 LZ4.decode_into(payload, destination, decompressed_size.to_i)
               when METHOD_ZSTD
                 destination = workspace.buffer_for(decompressed_size.to_i)
                 ZSTD.decode_into(payload, destination, decompressed_size.to_i, max_decompressed_size)
               when METHOD_MULTIPLE
                 decode_multiple_into(payload, decompressed_size.to_i, max_decompressed_size, workspace)
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
      workspace = DecodeWorkspace.new
      offset = 0_i64
      total_output = 0_i64
      while offset < data.size.to_i64
        frame = decode_frame_into(data, offset, workspace, max_compressed_size, max_decompressed_size)
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

    # Decodes `count` little-endian UInt64 delta words into `destination` and
    # returns the final wrapping accumulator. Frame decoders validate their
    # framing before calling this kernel; the public entry point also checks
    # that both slices contain at least `count * 8` bytes for benchmark use.
    #
    # Forward overlap (destination at or before input) is safe for the normal
    # Multiple/Delta in-place path. If destination starts inside the source,
    # a backward two-pass scalar path is selected so no unread delta word is
    # overwritten. `delta_byte_scalar` preserves the original byte-wise
    # baseline, `delta_scalar` selects the portable typed scalar path, and
    # `delta_neon` selects the AArch64 inline-assembly pair kernel. The default
    # is the typed scalar path so the optimized backend remains an experiment.
    def self.decode_delta_words(
      input : Bytes,
      destination : Bytes,
      count : Int,
      initial_accumulator : UInt64 = 0_u64,
    ) : UInt64
      raise ArgumentError.new("negative Delta word count") if count < 0
      raise ArgumentError.new("Delta input is too short") if count > input.size // 8
      raise ArgumentError.new("Delta destination is too short") if count > destination.size // 8
      return initial_accumulator if count == 0

      input_address = input.to_unsafe.address
      destination_address = destination.to_unsafe.address
      input_end = input_address &+ (count * 8).to_u64
      if destination_address > input_address && destination_address < input_end
        return decode_delta_words_backward(input, destination, count, initial_accumulator)
      end

      {% if flag?(:delta_byte_scalar) %}
        decode_delta_words_byte_scalar(input, destination, count, initial_accumulator)
      {% elsif flag?(:delta_neon) && flag?(:aarch64) %}
        decode_delta_words_neon(input, destination, count, initial_accumulator)
      {% else %}
        decode_delta_words_scalar(input, destination, count, initial_accumulator)
      {% end %}
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

    private def self.decode_multiple_into(input : Bytes, expected_size : Int, max_size : Int64, workspace : DecodeWorkspace) : Bytes
      raise CorruptPartError.new("Multiple payload is empty") if input.empty?

      method_count = input[0].to_i
      raise CorruptPartError.new("Multiple method count exceeds limit") if method_count > MAX_MULTIPLE_METHODS
      raise CorruptPartError.new("truncated Multiple method list") if input.size < 1 + method_count
      unless method_count == 2 && input[1] == METHOD_DELTA && input[2] == METHOD_ZSTD
        raise UnsupportedFormatError.new("unsupported ClickHouse Multiple codec list")
      end

      nested = input[1 + method_count, input.size - 1 - method_count]
      raise CorruptPartError.new("nested compressed block header is truncated") if nested.size < HEADER_SIZE
      raise UnsupportedFormatError.new("unexpected nested ClickHouse compression method") unless nested[0] == METHOD_ZSTD

      nested_compressed_size = u32(nested, 1).to_i64
      nested_decompressed_size = u32(nested, 5).to_i64
      raise CorruptPartError.new("nested compressed block size is invalid") if nested_compressed_size < HEADER_SIZE || nested_compressed_size != nested.size
      raise CorruptPartError.new("nested decompressed block size is invalid") if nested_decompressed_size <= 0 || nested_decompressed_size > max_size

      nested_payload = nested[HEADER_SIZE, (nested_compressed_size - HEADER_SIZE).to_i]
      destination = workspace.buffer_for(nested_decompressed_size.to_i)
      decoded = ZSTD.decode_into(nested_payload, destination, nested_decompressed_size.to_i, max_size)

      raise CorruptPartError.new("nested compressed block header is truncated") if decoded.size < HEADER_SIZE
      raise UnsupportedFormatError.new("unexpected nested ClickHouse compression method") unless decoded[0] == METHOD_DELTA

      delta_compressed_size = u32(decoded, 1).to_i64
      delta_decompressed_size = u32(decoded, 5).to_i64
      raise CorruptPartError.new("nested compressed block size is invalid") if delta_compressed_size < HEADER_SIZE || delta_compressed_size != decoded.size
      raise CorruptPartError.new("nested decompressed block size is invalid") if delta_decompressed_size <= 0 || delta_decompressed_size > max_size
      raise CorruptPartError.new("Multiple output size mismatch") unless delta_decompressed_size == expected_size

      delta_payload = decoded[HEADER_SIZE, (delta_compressed_size - HEADER_SIZE).to_i]
      raise CorruptPartError.new("Delta payload header is truncated") if delta_payload.size < 2
      raise UnsupportedFormatError.new("unsupported Delta width") unless delta_payload[0] == 8_u8
      raise CorruptPartError.new("Delta skip byte is invalid") unless delta_payload[1] == 0_u8
      raise CorruptPartError.new("Delta output size is not UInt64-aligned") unless expected_size % 8 == 0
      raise CorruptPartError.new("Delta payload size mismatch") unless delta_payload.size == 2 + expected_size

      decode_delta_in_place(decoded, expected_size)
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
      {% if flag?(:delta_byte_scalar) %}
        accumulator = 0_u64
        input_offset = 2
        output_offset = 0
        while input_offset < input.size
          accumulator = accumulator &+ u64(input, input_offset)
          write_u64(output, output_offset, accumulator)
          input_offset += 8
          output_offset += 8
        end
      {% elsif flag?(:delta_neon) && flag?(:aarch64) %}
        decode_delta_words_neon_pointers(input.to_unsafe + 2, output.to_unsafe, expected_size // 8, 0_u64)
      {% else %}
        decode_delta_words_scalar_pointers(input.to_unsafe + 2, output.to_unsafe, expected_size // 8, 0_u64)
      {% end %}
      output
    end

    private def self.decode_delta_in_place(input : Bytes, expected_size : Int) : Bytes
      {% if flag?(:delta_byte_scalar) %}
        accumulator = 0_u64
        input_offset = HEADER_SIZE + 2
        output_offset = 0
        while output_offset < expected_size
          accumulator = accumulator &+ u64(input, input_offset)
          write_u64(input, output_offset, accumulator)
          input_offset += 8
          output_offset += 8
        end
      {% elsif flag?(:delta_neon) && flag?(:aarch64) %}
        input_pointer = input.to_unsafe
        decode_delta_words_neon_pointers(input_pointer + HEADER_SIZE + 2, input_pointer, expected_size // 8, 0_u64)
      {% else %}
        input_pointer = input.to_unsafe
        decode_delta_words_scalar_pointers(input_pointer + HEADER_SIZE + 2, input_pointer, expected_size // 8, 0_u64)
      {% end %}
      input[0, expected_size]
    end

    private def self.decode_delta_words_byte_scalar(
      input : Bytes,
      destination : Bytes,
      count : Int,
      accumulator : UInt64,
    ) : UInt64
      count.times do |index|
        offset = index * 8
        accumulator = accumulator &+ u64(input, offset)
        write_u64(destination, offset, accumulator)
      end
      accumulator
    end

    private def self.decode_delta_words_scalar_pointers(
      input_pointer : Pointer(UInt8),
      destination_pointer : Pointer(UInt8),
      count : Int,
      accumulator : UInt64,
    ) : UInt64
      remaining = count
      while remaining > 0
        accumulator = accumulator &+ IO::ByteFormat::LittleEndian.decode(UInt64, input_pointer.to_slice(8))
        IO::ByteFormat::LittleEndian.encode(accumulator, destination_pointer.to_slice(8))
        input_pointer += 8
        destination_pointer += 8
        remaining -= 1
      end
      accumulator
    end

    private def self.decode_delta_words_scalar(
      input : Bytes,
      destination : Bytes,
      count : Int,
      accumulator : UInt64,
    ) : UInt64
      decode_delta_words_scalar_pointers(input.to_unsafe, destination.to_unsafe, count, accumulator)
    end

    private def self.decode_delta_words_backward(
      input : Bytes,
      destination : Bytes,
      count : Int,
      initial_accumulator : UInt64,
    ) : UInt64
      final_accumulator = initial_accumulator
      count.times do |index|
        final_accumulator = final_accumulator &+ u64(input, index * 8)
      end

      accumulator = final_accumulator
      index = count
      while index > 0
        index -= 1
        offset = index * 8
        delta = u64(input, offset)
        write_u64(destination, offset, accumulator)
        accumulator = accumulator &- delta
      end
      final_accumulator
    end

    private def self.decode_delta_words_neon(
      input : Bytes,
      destination : Bytes,
      count : Int,
      accumulator : UInt64,
    ) : UInt64
      decode_delta_words_neon_pointers(input.to_unsafe, destination.to_unsafe, count, accumulator)
    end

    private def self.decode_delta_words_neon_pointers(
      input_pointer : Pointer(UInt8),
      destination_pointer : Pointer(UInt8),
      count : Int,
      accumulator : UInt64,
    ) : UInt64
      pair_count = count // 2
      if pair_count > 0
        input_address = input_pointer.address
        destination_address = destination_pointer.address
        pair_count_u64 = pair_count.to_u64
        input_address_after = uninitialized UInt64
        destination_address_after = uninitialized UInt64
        pair_count_after = uninitialized UInt64
        accumulator_after = uninitialized UInt64

        asm(
          "
          1:
            ld1     {v0.2d}, [$0], #16
            movi    v1.2d, #0
            ins     v1.d[1], v0.d[0]
            add     v0.2d, v0.2d, v1.2d
            dup     v1.2d, $3
            add     v0.2d, v0.2d, v1.2d
            st1     {v0.2d}, [$1], #16
            umov    $3, v0.d[1]
            subs    $2, $2, #1
            b.ne    1b
          "
                : "=r"(input_address_after), "=r"(destination_address_after), "=r"(pair_count_after), "=r"(accumulator_after)
                : "0"(input_address), "1"(destination_address), "2"(pair_count_u64), "3"(accumulator)
                : "v0", "v1", "cc", "memory"
                : "volatile"
        )

        # Keep every tied output live across the asm expression. The first
        # three values are not needed by the caller, but declaring and using
        # them makes the pointer/counter mutation explicit to LLVM.
        input_address = input_address_after
        destination_address = destination_address_after
        pair_count_u64 = pair_count_after
        accumulator = accumulator_after
      end

      if count.odd?
        input_pointer += pair_count * 16
        destination_pointer += pair_count * 16
        accumulator = accumulator &+ IO::ByteFormat::LittleEndian.decode(UInt64, input_pointer.to_slice(8))
        IO::ByteFormat::LittleEndian.encode(accumulator, destination_pointer.to_slice(8))
      end
      accumulator
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
