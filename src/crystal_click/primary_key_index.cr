module CrystalClick
  # Bounded reader for ClickHouse's raw primary.idx or framed primary.cidx.
  # The index contains one key per physical .mrk2 entry, including its final
  # zero-row sentinel; only the first `data_mark_count` keys start data marks.
  class PrimaryKeyIndex
    MAX_INDEX_FILE_BYTES = 8_i64 * 1024 * 1024
    MAX_INDEX_ENTRIES    = WidePartTable::MAX_MARKS_PER_READER + 1

    getter keys : Array(UInt64)
    getter data_mark_count : Int32

    def self.open(
      part_path : String,
      data_mark_count : Int,
      checksums : PartChecksums,
      verify_recorded_hash : Bool = false,
    ) : PrimaryKeyIndex
      raise BoundsError.new("primary index mark count is out of range") if data_mark_count < 0 || data_mark_count >= MAX_INDEX_ENTRIES

      raw_name = "primary.idx"
      compressed_name = "primary.cidx"
      raw_path = File.join(part_path, raw_name)
      compressed_path = File.join(part_path, compressed_name)
      raw_present = File.exists?(raw_path) || File.symlink?(raw_path)
      compressed_present = File.exists?(compressed_path) || File.symlink?(compressed_path)
      raw_entry = checksums.entry(raw_name)
      compressed_entry = checksums.entry(compressed_name)

      if (raw_present && compressed_present) || (raw_entry && compressed_entry)
        raise CorruptPartError.new("part has ambiguous raw and compressed primary indexes")
      end
      unless raw_present ^ compressed_present
        raise UnsupportedFormatError.new("part must contain exactly one supported primary index")
      end

      name = raw_present ? raw_name : compressed_name
      entry = raw_present ? raw_entry : compressed_entry
      raise CorruptPartError.new("primary index is absent from checksums.txt") unless entry
      compressed = name == compressed_name
      unless entry.not_nil!.compressed == compressed
        raise CorruptPartError.new("primary index compression metadata does not match its extension")
      end

      expected_entries = data_mark_count.to_i64 + 1
      raise BoundsError.new("primary index entry count exceeds limit") if expected_entries > MAX_INDEX_ENTRIES
      expected_size = expected_entries * 8_i64
      path = raw_present ? raw_path : compressed_path
      checksums.validate_selected_entries(part_path, name)
      physical_size = entry.not_nil!.physical_size
      raise BoundsError.new("primary index exceeds size limit") if physical_size > MAX_INDEX_FILE_BYTES

      if compressed
        declared_size = entry.not_nil!.uncompressed_size || raise(CorruptPartError.new("compressed primary index has no uncompressed size"))
        raise CorruptPartError.new("compressed primary index size does not match its mark count") unless declared_size.to_i64 == expected_size
      else
        raise CorruptPartError.new("raw primary index size does not match its mark count") unless physical_size.to_i64 == expected_size
        raise CorruptPartError.new("raw primary index declares an uncompressed size") if entry.not_nil!.uncompressed_size
      end

      file_data = File.read(path)
      file_bytes = file_data.to_slice
      raise CorruptPartError.new("primary index changed size while being read") unless file_bytes.size.to_u64 == physical_size
      raise CorruptPartError.new("primary index exceeds size limit") if file_bytes.size.to_i64 > MAX_INDEX_FILE_BYTES
      if verify_recorded_hash
        recorded_hash = entry.not_nil!.file_hash
        raise CorruptPartError.new("primary index file hash does not match checksums.txt") unless CityHashV1.file_hash(file_bytes) == recorded_hash
      end

      decoded = if compressed
                  CompressedBlock.decode_all(
                    file_bytes,
                    MAX_INDEX_FILE_BYTES,
                    expected_size,
                    expected_size
                  )
                else
                  file_bytes
                end
      raise CorruptPartError.new("decoded primary index size does not match its mark count") unless decoded.size.to_i64 == expected_size

      keys = Array(UInt64).new(expected_entries.to_i)
      expected_entries.to_i.times do |index|
        key = read_uint64_le(decoded, index * 8)
        if previous = keys.last?
          raise CorruptPartError.new("primary index keys are not monotone") if key < previous
        end
        keys << key
      end
      new(keys, data_mark_count.to_i32)
    rescue ex : IO::Error
      raise InvalidPartError.new(ex.message || "cannot read primary index")
    end

    # Return a conservative inclusive range of data-mark ordinals. The key at
    # the final entry is the adaptive sentinel and is never emitted as a mark.
    def candidate_marks(lower_bound : UInt64?, upper_bound : UInt64?) : Array(Int32)
      return [] of Int32 if @data_mark_count == 0

      first_mark = 0
      if lower = lower_bound
        low = 0
        high = @data_mark_count
        while low < high
          middle = low + (high - low) // 2
          if @keys[middle] < lower
            low = middle + 1
          else
            high = middle
          end
        end
        first_ge = low
        return [] of Int32 if first_ge == @data_mark_count && lower > @keys[@data_mark_count]
        # A lower bound can fall after any row in the predecessor granule.
        first_mark = first_ge == @data_mark_count ? @data_mark_count - 1 : (first_ge > 0 ? first_ge - 1 : 0)
      end

      after_last_mark = @data_mark_count
      if upper = upper_bound
        low = 0
        high = @data_mark_count
        while low < high
          middle = low + (high - low) // 2
          if @keys[middle] <= upper
            low = middle + 1
          else
            high = middle
          end
        end
        after_last_mark = low
      end

      marks = Array(Int32).new
      mark = first_mark
      while mark < after_last_mark
        marks << mark.to_i32
        mark += 1
      end
      marks
    end

    private def initialize(@keys : Array(UInt64), @data_mark_count : Int32)
    end

    private def self.read_uint64_le(bytes : Bytes, offset : Int) : UInt64
      raise CorruptPartError.new("truncated primary index key") if offset < 0 || offset > bytes.size - 8
      value = 0_u64
      8.times do |byte_index|
        value |= bytes[offset + byte_index].to_u64 << (byte_index * 8)
      end
      value
    end
  end
end
