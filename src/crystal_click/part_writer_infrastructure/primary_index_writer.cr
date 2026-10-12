module CrystalClick
  module PartWriterInfrastructure
    # Writes the shared raw primary.idx representation used by Wide and
    # Compact complete-part publishers.
    class PrimaryIndexWriter
      def self.write(stage : String, keys : Slice(UInt64), rows_per_mark : Int32) : ChecksumRecord
        bytes = IO::Memory.new
        row = 0
        while row < keys.size
          StreamEncoding.write_uint64_le(bytes, keys[row])
          row += rows_per_mark
        end
        StreamEncoding.write_uint64_le(bytes, keys.last)
        raw = bytes.to_slice
        if raw.size.to_i64 > PrimaryKeyIndex::MAX_INDEX_FILE_BYTES
          raise ArgumentError.new("primary index exceeds reader limit")
        end
        File.write(File.join(stage, "primary.idx"), raw)
        ChecksumRecord.new("primary.idx", raw.size.to_u64, CityHashV1.file_hash(raw), false)
      end
    end
  end
end
