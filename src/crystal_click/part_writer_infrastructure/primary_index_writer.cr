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

      def self.compound_size(mark_count : Int, key_count : Int) : Int64
        unless mark_count > 0 && key_count > 0
          raise ArgumentError.new("compound primary index requires marks and key columns")
        end

        mark_count_value = mark_count.to_i64
        keys = key_count.to_i64
        if mark_count_value >= PrimaryKeyIndex::MAX_INDEX_ENTRIES ||
           keys > PrimaryKeyIndex::MAX_INDEX_FILE_BYTES // sizeof(UInt64)
          raise ArgumentError.new("compound primary index exceeds reader limit")
        end

        entries = mark_count_value + 1_i64
        bytes_per_entry = keys * sizeof(UInt64)
        if entries > PrimaryKeyIndex::MAX_INDEX_FILE_BYTES // bytes_per_entry
          raise ArgumentError.new("compound primary index exceeds reader limit")
        end
        entries * bytes_per_entry
      end

      # Visits each mark-start tuple followed by the terminal tuple. The same
      # fixed-width buffer is reused for each yield; consumers must process it
      # before the next entry is yielded.
      def self.each_compound_entry(
        key_columns : Indexable(Slice(UInt64)),
        rows_per_mark : Int,
        &block : Bytes -> Nil
      ) : Nil
        row_count = validate_compound_columns!(key_columns, rows_per_mark)
        tuple = Bytes.new(key_columns.size * sizeof(UInt64), 0_u8)

        row = 0
        while row < row_count
          write_compound_tuple!(tuple, key_columns, row)
          yield tuple
          row += rows_per_mark
        end
        write_compound_tuple!(tuple, key_columns, row_count - 1)
        yield tuple
        nil
      end

      def self.write_compound(
        stage : String,
        key_columns : Indexable(Slice(UInt64)),
        rows_per_mark : Int32,
      ) : ChecksumRecord
        bytes = IO::Memory.new
        each_compound_entry(key_columns, rows_per_mark) do |entry|
          bytes.write(entry)
        end
        raw = bytes.to_slice
        File.write(File.join(stage, "primary.idx"), raw)
        ChecksumRecord.new("primary.idx", raw.size.to_u64, CityHashV1.file_hash(raw), false)
      end

      # Compatibility wrapper for callers that still hold a key pair.
      def self.write_compound(
        stage : String,
        first_keys : Slice(UInt64),
        second_keys : Slice(UInt64),
        rows_per_mark : Int32,
      ) : ChecksumRecord
        write_compound(stage, [first_keys, second_keys] of Slice(UInt64), rows_per_mark)
      end

      # Validates the raw tuple index against the same ordered key lanes and
      # row grid used to publish it. Scalar readers remain unchanged.
      def self.validate_compound!(
        stage : String,
        expected_rows : Array(UInt64),
        key_columns : Indexable(Slice(UInt64)),
        checksums : PartChecksums,
      ) : Nil
        if expected_rows.empty? || key_columns.empty?
          raise CorruptPartError.new("compound primary index keys do not share a bounded row grid")
        end
        row_count = key_columns[0].size
        key_columns.each do |column|
          unless column.size == row_count
            raise CorruptPartError.new("compound primary index keys do not share a bounded row grid")
          end
        end
        unless row_count > 0 && row_count.to_u64 <= WidePart::MAX_ROWS
          raise CorruptPartError.new("compound primary index keys do not share a bounded row grid")
        end

        expected_size = begin
          compound_size(expected_rows.size, key_columns.size)
        rescue ex : ArgumentError
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
          if rows == 0 || rows > row_count.to_u64 - row_start
            raise CorruptPartError.new("compound primary index row grid exceeds its key streams")
          end
          byte_offset = index_entry * key_columns.size * sizeof(UInt64)
          key_columns.each_with_index do |column, lane|
            actual = IO::ByteFormat::LittleEndian.decode(UInt64, raw[byte_offset + lane * sizeof(UInt64), sizeof(UInt64)])
            unless actual == column[row_start.to_i]
              raise CorruptPartError.new("compound primary index differs from the ordered key marks")
            end
          end
          row_start += rows
          index_entry += 1
        end
        unless row_start == row_count.to_u64
          raise CorruptPartError.new("compound primary index row grid does not consume its key streams")
        end
        byte_offset = index_entry * key_columns.size * sizeof(UInt64)
        key_columns.each_with_index do |column, lane|
          actual = IO::ByteFormat::LittleEndian.decode(UInt64, raw[byte_offset + lane * sizeof(UInt64), sizeof(UInt64)])
          unless actual == column[row_count - 1]
            message = key_columns.size == 2 ? "compound primary index terminal differs from the final key pair" : "compound primary index terminal differs from the final key tuple"
            raise CorruptPartError.new(message)
          end
        end
        nil
      rescue ex : IO::Error
        raise InvalidPartError.new(ex.message || "cannot read compound primary index")
      end

      # Compatibility wrapper for callers that still hold a key pair.
      def self.validate_compound!(
        stage : String,
        expected_rows : Array(UInt64),
        first_keys : Slice(UInt64),
        second_keys : Slice(UInt64),
        checksums : PartChecksums,
      ) : Nil
        validate_compound!(stage, expected_rows, [first_keys, second_keys] of Slice(UInt64), checksums)
      end

      private def self.validate_compound_columns!(
        key_columns : Indexable(Slice(UInt64)),
        rows_per_mark : Int,
      ) : Int
        unless !key_columns.empty? && rows_per_mark > 0 && rows_per_mark <= WidePartTable::MAX_MARK_ROWS
          raise ArgumentError.new("compound primary index keys do not share a bounded row grid")
        end
        row_count = key_columns[0].size
        unless row_count > 0 && row_count.to_u64 <= WidePart::MAX_ROWS
          raise ArgumentError.new("compound primary index keys do not share a bounded row grid")
        end
        key_columns.each do |column|
          unless column.size == row_count
            raise ArgumentError.new("compound primary index keys do not share a bounded row grid")
          end
        end
        compound_size(mark_count_for(row_count, rows_per_mark), key_columns.size)
        row_count
      end

      private def self.mark_count_for(row_count : Int, rows_per_mark : Int) : Int64
        (row_count.to_i64 + rows_per_mark.to_i64 - 1_i64) // rows_per_mark.to_i64
      end

      private def self.write_compound_tuple!(
        tuple : Bytes,
        key_columns : Indexable(Slice(UInt64)),
        row : Int,
      ) : Nil
        key_columns.each_with_index do |column, lane|
          StreamEncoding.write_uint64_le(tuple, lane * sizeof(UInt64), column[row])
        end
        nil
      end
    end
  end
end
