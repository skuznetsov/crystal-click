module CrystalClick
  module PartWriterInfrastructure
    # Writes scalar and compound primary-index representations shared by
    # complete-part publishers.
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

      # Checks compressed physical, decoded, and retained-result bounds before
      # a child stage is created. The writer repeats this after other siblings
      # consume from the shared transaction budget.
      def self.preflight_compressed_output(
        raw_size : Int64,
        frame_bytes : Int,
        budget : CompressedStreamBudget,
      ) : Int64
        budget.ensure_direction(true)
        if raw_size <= 0 || raw_size > PrimaryKeyIndex::MAX_INDEX_FILE_BYTES
          raise ArgumentError.new("primary index exceeds reader limit")
        end
        physical_size = CompressedMarkWriter.preflight_all(raw_size, frame_bytes, budget).to_i64
        if physical_size > PrimaryKeyIndex::MAX_INDEX_FILE_BYTES || physical_size > Int32::MAX
          raise UnsupportedFormatError.new("compressed primary index exceeds reader limit")
        end
        if raw_size > Int64::MAX - physical_size
          raise UnsupportedFormatError.new("compressed primary index result size overflows")
        end
        budget.preflight_result_bytes(raw_size + physical_size)
        physical_size
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

      # Writes compound mark-start tuples followed by the final tuple using
      # the same traversal as the raw compound index path.
      def self.write_compound_compressed(
        stage : String,
        key_columns : Indexable(Slice(UInt64)),
        rows_per_mark : Int32,
        frame_bytes : Int,
        budget : CompressedStreamBudget,
      ) : ChecksumRecord
        physical, record = prepare_compound_compressed(key_columns, rows_per_mark, frame_bytes, budget)
        File.write(File.join(stage, "primary.cidx"), physical)
        record
      end

      # Prepares the exact compressed tuple bytes and checksum record without
      # touching a stage directory. Compact projection writers use this before
      # stage creation so the child checksum envelope is fully planned.
      def self.prepare_compound_compressed(
        key_columns : Indexable(Slice(UInt64)),
        rows_per_mark : Int32,
        frame_bytes : Int,
        budget : CompressedStreamBudget,
      ) : Tuple(Bytes, ChecksumRecord)
        row_count = validate_compound_columns!(key_columns, rows_per_mark)
        mark_count = mark_count_for(row_count, rows_per_mark)
        raw_size = compound_size(mark_count, key_columns.size)

        prepare_compressed_bytes(raw_size, frame_bytes, budget) do |raw|
          offset = 0
          each_compound_entry(key_columns, rows_per_mark) do |entry|
            entry.copy_to(raw[offset, entry.size])
            offset += entry.size
          end
          unless offset == raw.size
            raise UnsupportedFormatError.new("compound compressed primary index differs from its planned size")
          end
        end
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
        row_count = validate_index_grid_shape!(expected_rows, key_columns, "compound primary index")

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

        validate_index_grid_bytes!(
          raw, expected_rows, key_columns, row_count, expected_size, "compound primary index"
        )
      rescue ex : IO::Error
        raise InvalidPartError.new(ex.message || "cannot read compound primary index")
      end

      # Authenticates the decompressed cidx bytes against the exact same
      # ordered key columns and mark grid used during publication.
      def self.validate_compressed!(
        decoded : Bytes,
        expected_rows : Array(UInt64),
        key_columns : Indexable(Slice(UInt64)),
      ) : Nil
        row_count = validate_index_grid_shape!(expected_rows, key_columns, "compressed primary index")
        expected_size = begin
          compound_size(expected_rows.size, key_columns.size)
        rescue ex : ArgumentError
          raise CorruptPartError.new("staged compressed primary index exceeds reader limit")
        end
        validate_index_grid_bytes!(
          decoded, expected_rows, key_columns, row_count, expected_size, "compressed primary index"
        )
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

      private def self.prepare_compressed_bytes(
        raw_size : Int64,
        frame_bytes : Int,
        budget : CompressedStreamBudget,
        &block : Bytes -> Nil
      ) : Tuple(Bytes, ChecksumRecord)
        budget.ensure_direction(true)
        physical_size = PrimaryIndexWriter.preflight_compressed_output(raw_size, frame_bytes, budget)
        budget.reserve_result_bytes(raw_size)

        raw = Bytes.new(raw_size.to_i)
        yield raw
        physical = CompressedMarkWriter.encode_all(raw, frame_bytes, budget)
        unless physical.size.to_i64 == physical_size
          raise UnsupportedFormatError.new("compressed primary index differs from its preflighted size")
        end
        record = ChecksumRecord.new(
          "primary.cidx", physical.size.to_u64, CityHashV1.file_hash(physical), true,
          raw.size.to_u64, CityHashV1.file_hash(raw)
        )
        {physical, record}
      end

      private def self.validate_index_grid_bytes!(
        decoded : Bytes,
        expected_rows : Array(UInt64),
        key_columns : Indexable(Slice(UInt64)),
        row_count : Int,
        expected_size : Int64,
        representation : String,
      ) : Nil
        unless decoded.size.to_i64 == expected_size
          raise CorruptPartError.new("staged #{representation} size differs from its mark grid")
        end

        row_start = 0_u64
        entry_index = 0
        expected_rows.each do |rows|
          if rows == 0 || row_start > row_count.to_u64 || rows > row_count.to_u64 - row_start
            raise CorruptPartError.new("#{representation} row grid exceeds its key streams")
          end
          validate_index_tuple!(decoded, entry_index, key_columns, row_start.to_i, representation)
          row_start += rows
          entry_index += 1
        end
        unless row_start == row_count.to_u64
          raise CorruptPartError.new("#{representation} row grid does not consume its key streams")
        end
        terminal_error = if representation == "compound primary index"
                           key_columns.size == 2 ? "compound primary index terminal differs from the final key pair" : "compound primary index terminal differs from the final key tuple"
                         else
                           "compressed primary index terminal differs from the final key tuple"
                         end
        validate_index_tuple!(decoded, entry_index, key_columns, row_count - 1, representation, terminal_error)
        nil
      end

      private def self.validate_index_grid_shape!(
        expected_rows : Array(UInt64),
        key_columns : Indexable(Slice(UInt64)),
        representation : String,
      ) : Int
        if expected_rows.empty? || key_columns.empty?
          raise CorruptPartError.new("#{representation} keys do not share a bounded row grid")
        end
        row_count = key_columns[0].size
        key_columns.each do |column|
          unless column.size == row_count
            raise CorruptPartError.new("#{representation} keys do not share a bounded row grid")
          end
        end
        unless row_count > 0 && row_count.to_u64 <= WidePart::MAX_ROWS
          raise CorruptPartError.new("#{representation} keys do not share a bounded row grid")
        end
        row_count
      end

      private def self.validate_index_tuple!(
        decoded : Bytes,
        entry_index : Int,
        key_columns : Indexable(Slice(UInt64)),
        row : Int,
        representation : String,
        mismatch_message : String? = nil,
      ) : Nil
        byte_offset = entry_index * key_columns.size * sizeof(UInt64)
        key_columns.each_with_index do |column, lane|
          actual = IO::ByteFormat::LittleEndian.decode(
            UInt64, decoded[byte_offset + lane * sizeof(UInt64), sizeof(UInt64)]
          )
          unless actual == column[row]
            raise CorruptPartError.new(mismatch_message || "#{representation} differs from the ordered key marks")
          end
        end
        nil
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
