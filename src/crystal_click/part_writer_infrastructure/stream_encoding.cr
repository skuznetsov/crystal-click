module CrystalClick
  module PartWriterInfrastructure
    # Literal-LZ4 and little-endian helpers shared by complete-part writers.
    # Keep this byte-for-byte aligned with the legacy Wide writer helper.
    class StreamEncoding
      def self.encode_lz4_frame(raw : Bytes) : Bytes
        raise ArgumentError.new("empty LZ4 blocks are unsupported") if raw.empty?
        extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
        payload_size = 1 + extension_size + raw.size
        compressed_size = CompressedBlock::HEADER_SIZE + payload_size
        if compressed_size > WidePart::MAX_FRAME_COMPRESSED_BYTES
          raise ArgumentError.new("compressed frame exceeds reader limit")
        end

        frame = Bytes.new(CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
        header = CompressedBlock::CHECKSUM_SIZE
        frame[header] = CompressedBlock::METHOD_LZ4
        write_uint32_le(frame, header + 1, compressed_size.to_u32)
        write_uint32_le(frame, header + 5, raw.size.to_u32)

        cursor = CompressedBlock::FRAME_HEADER_SIZE
        if raw.size < 15
          frame[cursor] = (raw.size << 4).to_u8
          cursor += 1
        else
          frame[cursor] = 0xf0_u8
          cursor += 1
          remaining = raw.size - 15
          while remaining >= 255
            frame[cursor] = 255_u8
            cursor += 1
            remaining -= 255
          end
          frame[cursor] = remaining.to_u8
          cursor += 1
        end
        raw.copy_to(frame[cursor, raw.size])
        checksum = CityHashV1.hash128(frame[CompressedBlock::CHECKSUM_SIZE, compressed_size])
        write_hash128_le(frame, checksum)
        frame
      end

      def self.write_hash128_le(io : IO, hash : {UInt64, UInt64}) : Nil
        write_uint64_le(io, hash[0])
        write_uint64_le(io, hash[1])
      end

      def self.write_hash128_le(bytes : Bytes, hash : {UInt64, UInt64}) : Nil
        write_uint64_le(bytes, 0, hash[0])
        write_uint64_le(bytes, 8, hash[1])
      end

      def self.write_uint64_le(io : IO, value : UInt64) : Nil
        8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
      end

      def self.write_var_uint(io : IO, value : UInt64) : Nil
        remaining = value
        while remaining >= 0x80_u64
          io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
          remaining >>= 7
        end
        io.write_byte(remaining.to_u8)
      end

      def self.write_uint64_le(bytes : Bytes, offset : Int, value : UInt64) : Nil
        8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
      end

      def self.write_uint32_le(bytes : Bytes, offset : Int, value : UInt32) : Nil
        4.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u32).to_u8 }
      end

      def self.var_uint_size(value : UInt64) : Int64
        size = 1_i64
        remaining = value
        while remaining >= 0x80_u64
          remaining >>= 7
          size += 1_i64
        end
        size
      end
    end
  end
end
