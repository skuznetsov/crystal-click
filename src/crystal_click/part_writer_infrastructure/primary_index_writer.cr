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

      # Writes the bounded raw UInt64 pair form used only by a two-key Wide
      # aggregate projection child. Ordinary part readers retain the scalar
      # eight-byte index contract.
      def self.write_compound(
        stage : String,
        first_keys : Slice(UInt64),
        second_keys : Slice(UInt64),
        rows_per_mark : Int32,
      ) : ChecksumRecord
        unless rows_per_mark > 0 && first_keys.size > 0 && first_keys.size == second_keys.size
          raise ArgumentError.new("compound primary index keys do not share a bounded row grid")
        end
        mark_count = (first_keys.size.to_i64 + rows_per_mark.to_i64 - 1_i64) // rows_per_mark.to_i64
        entry_count = mark_count + 1_i64
        index_size = entry_count * 16_i64
        if entry_count > PrimaryKeyIndex::MAX_INDEX_ENTRIES.to_i64 ||
           index_size > PrimaryKeyIndex::MAX_INDEX_FILE_BYTES || index_size > Int32::MAX
          raise ArgumentError.new("compound primary index exceeds reader limit")
        end

        bytes = IO::Memory.new
        row = 0
        while row < first_keys.size
          StreamEncoding.write_uint64_le(bytes, first_keys[row])
          StreamEncoding.write_uint64_le(bytes, second_keys[row])
          row += rows_per_mark
        end
        StreamEncoding.write_uint64_le(bytes, first_keys.last)
        StreamEncoding.write_uint64_le(bytes, second_keys.last)
        raw = bytes.to_slice
        unless raw.size.to_i64 == index_size
          raise UnsupportedFormatError.new("compound primary index size differs from its mark grid")
        end
        File.write(File.join(stage, "primary.idx"), raw)
        ChecksumRecord.new("primary.idx", raw.size.to_u64, CityHashV1.file_hash(raw), false)
      end

      # Validates the bounded compound representation against the same ordered
      # row grid used to publish the key lanes. Scalar readers remain unchanged.
      def self.validate_compound!(
        stage : String,
        expected_rows : Array(UInt64),
        first_keys : Slice(UInt64),
        second_keys : Slice(UInt64),
        checksums : PartChecksums,
      ) : Nil
        unless !expected_rows.empty? && first_keys.size > 0 && first_keys.size == second_keys.size
          raise CorruptPartError.new("compound primary index keys do not share a bounded row grid")
        end
        expected_entries = expected_rows.size.to_i64 + 1_i64
        expected_size = expected_entries * 16_i64
        if expected_entries > PrimaryKeyIndex::MAX_INDEX_ENTRIES.to_i64 ||
           expected_size > PrimaryKeyIndex::MAX_INDEX_FILE_BYTES || expected_size > Int32::MAX
          raise CorruptPartError.new("staged compound primary index exceeds reader limit")
        end
        if File.exists?(File.join(stage, "primary.cidx")) || File.symlink?(File.join(stage, "primary.cidx"))
          raise CorruptPartError.new("compound primary index must use the raw primary.idx representation")
        end
        entry = checksums.entry("primary.idx") ||
                raise CorruptPartError.new("compound primary index is absent from checksums.txt")
        unless !entry.compressed && entry.uncompressed_size.nil? && entry.physical_size.to_i64 == expected_size
          raise CorruptPartError.new("compound primary index checksum metadata differs from its mark grid")
        end
        checksums.validate_selected_entries(stage, "primary.idx")
        raw_text = File.read(File.join(stage, "primary.idx"))
        raw = raw_text.to_slice
        unless raw.size.to_i64 == expected_size
          raise CorruptPartError.new("compound primary index changed size while being read")
        end
        unless CityHashV1.file_hash(raw) == entry.file_hash
          raise CorruptPartError.new("compound primary index file hash does not match checksums.txt")
        end

        row_start = 0_u64
        index_entry = 0
        expected_rows.each do |rows|
          if rows == 0 || rows > first_keys.size.to_u64 - row_start
            raise CorruptPartError.new("compound primary index row grid exceeds its key streams")
          end
          byte_offset = index_entry * 16
          actual_first = IO::ByteFormat::LittleEndian.decode(UInt64, raw[byte_offset, 8])
          actual_second = IO::ByteFormat::LittleEndian.decode(UInt64, raw[byte_offset + 8, 8])
          unless actual_first == first_keys[row_start.to_i] && actual_second == second_keys[row_start.to_i]
            raise CorruptPartError.new("compound primary index differs from the ordered key marks")
          end
          row_start += rows
          index_entry += 1
        end
        unless row_start == first_keys.size.to_u64
          raise CorruptPartError.new("compound primary index row grid does not consume its key streams")
        end
        byte_offset = index_entry * 16
        terminal_first = IO::ByteFormat::LittleEndian.decode(UInt64, raw[byte_offset, 8])
        terminal_second = IO::ByteFormat::LittleEndian.decode(UInt64, raw[byte_offset + 8, 8])
        unless terminal_first == first_keys.last && terminal_second == second_keys.last
          raise CorruptPartError.new("compound primary index terminal differs from the final key pair")
        end
        nil
      rescue ex : IO::Error
        raise InvalidPartError.new(ex.message || "cannot read compound primary index")
      end
    end
  end
end
