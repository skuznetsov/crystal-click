module CrystalClick
  module WidePartWriter
    # Owns the canonical v4 checksums envelope emitted by WidePartWriter.
    # The part orchestrators continue to supply records and choose when this
    # sidecar is written.
    private class PartChecksumsWriter
      def self.write(stage : String, records : Array(ChecksumRecord)) : Nil
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

        frame = StreamEncoding.encode_lz4_frame(payload.to_slice)
        File.open(File.join(stage, "checksums.txt"), "wb") do |file|
          file << PartChecksums::CHECKSUMS_HEADER
          file.write(frame)
        end
        nil
      end
    end
  end
end
