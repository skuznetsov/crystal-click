module CrystalClick
  module PartWriterInfrastructure
    # Writes the shared canonical v4 checksums envelope. Format owners supply
    # the exact files and records, retaining control of their own boundaries.
    class PartChecksumsWriter
      def self.write(stage : String, records : Array(ChecksumRecord)) : Nil
        payload = encode_payload(records)
        frame = StreamEncoding.encode_lz4_frame(payload)
        File.open(File.join(stage, "checksums.txt"), "wb") do |file|
          file << PartChecksums::CHECKSUMS_HEADER
          file.write(frame)
        end
        nil
      end

      # Exact final size without materializing the checksums payload. Compact
      # uses this before reserving the bounded detached result and stage file.
      def self.encoded_size(records : Array(ChecksumRecord)) : Int64
        payload_size = payload_size(records)
        extension_size = payload_size < 15_i64 ? 0_i64 : ((payload_size - 15_i64) // 255_i64) + 1_i64
        frame_size = checked_add_i64(
          CompressedBlock::FRAME_HEADER_SIZE.to_i64,
          checked_add_i64(1_i64 + extension_size, payload_size),
        )
        checked_add_i64(PartChecksums::CHECKSUMS_HEADER.bytesize.to_i64, frame_size)
      end

      # Return the exact complete v4 envelope for callers that must preflight
      # and compare all checksum declarations, including the raw fold omitted
      # from PartChecksums::Entry.
      def self.encode(records : Array(ChecksumRecord)) : Bytes
        payload = encode_payload(records)
        frame = StreamEncoding.encode_lz4_frame(payload)
        total = PartChecksums::CHECKSUMS_HEADER.bytesize + frame.size
        output = Bytes.new(total, 0_u8)
        header = PartChecksums::CHECKSUMS_HEADER.to_slice
        header.copy_to(output[0, header.size])
        frame.copy_to(output[header.size, frame.size])
        output
      end

      private def self.encode_payload(records : Array(ChecksumRecord)) : Bytes
        sorted_records = records.sort_by(&.name)
        payload = IO::Memory.new
        StreamEncoding.write_var_uint(payload, sorted_records.size.to_u64)
        sorted_records.each do |record|
          name = record.name.to_slice
          StreamEncoding.write_var_uint(payload, name.size.to_u64)
          payload.write(name)
          StreamEncoding.write_var_uint(payload, record.physical_size)
          StreamEncoding.write_hash128_le(payload, record.file_hash)
          if record.compressed
            payload.write_byte(1_u8)
            StreamEncoding.write_var_uint(payload, record.uncompressed_size || raise "compressed checksum has no raw size")
            StreamEncoding.write_hash128_le(
              payload,
              record.uncompressed_hash || raise "compressed checksum has no raw hash"
            )
          else
            payload.write_byte(0_u8)
          end
        end
        payload.to_slice.dup
      end

      private def self.payload_size(records : Array(ChecksumRecord)) : Int64
        total = StreamEncoding.var_uint_size(records.size.to_u64)
        records.each do |record|
          name_size = record.name.bytesize.to_u64
          total = checked_add_i64(total, StreamEncoding.var_uint_size(name_size))
          total = checked_add_i64(total, name_size.to_i64)
          total = checked_add_i64(total, StreamEncoding.var_uint_size(record.physical_size))
          total = checked_add_i64(total, 16_i64 + 1_i64)
          if record.compressed
            total = checked_add_i64(
              total,
              StreamEncoding.var_uint_size(record.uncompressed_size || raise "compressed checksum has no raw size"),
            )
            total = checked_add_i64(total, 16_i64)
            raise "compressed checksum has no raw hash" unless record.uncompressed_hash
          end
        end
        total
      end

      private def self.checked_add_i64(left : Int64, right : Int64) : Int64
        if right < 0 || right > Int64::MAX - left
          raise UnsupportedFormatError.new("checksums envelope size overflows Int64")
        end
        left + right
      end
    end
  end
end
