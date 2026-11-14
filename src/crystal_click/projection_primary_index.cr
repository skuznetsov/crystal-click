module CrystalClick
  # Bounded transport admission for the compressed primary.cidx representation
  # used by caller-materialized aggregate projection children.
  class ProjectionPrimaryIndex
    # Returns the leading UInt64 key roster only for a canonical aggregate
    # projection schema. This is called only after a primary.cidx candidate is
    # observed, so raw and unrelated projection children retain their prior
    # admission path.
    def self.aggregate_group_key_column_names(
      part_path : String,
      checksums : PartChecksums,
    ) : Array(String)?
      checksums.validate_selected_entries(part_path, "columns.txt") if checksums.entry("columns.txt")
      metadata = PartMetadataFileReader.new(part_path, CompressedStreamBudget.read_default)
      columns = WidePart.parse_columns_metadata(metadata.read("columns.txt"))
      has_aggregate_state = columns.any? do |name, type_name|
        !WidePartProjectionAggregateDescriptor.for_column(name, type_name).nil?
      end
      return nil unless has_aggregate_state

      key_count = 0
      while key_count < columns.size && columns[key_count][1] == "UInt64"
        key_count += 1
      end
      if key_count == 0
        return [] of String if columns.all? { |name, type_name| !WidePartProjectionAggregateDescriptor.for_column(name, type_name).nil? }
        return nil
      end
      return nil unless columns[key_count..].all? { |name, type_name| !WidePartProjectionAggregateDescriptor.for_column(name, type_name).nil? }

      names = columns.first(key_count).map { |name, _type| String.new(name.to_slice) }
      unless names.to_set.size == names.size
        raise CorruptPartError.new("aggregate projection group key roster contains duplicate names")
      end
      names
    end

    def self.file_signal?(part_path : String, checksums : PartChecksums, name : String) : Bool
      path = File.join(part_path, name)
      File.exists?(path) || File.symlink?(path) || !checksums.entry(name).nil?
    rescue ex : IO::Error
      raise CorruptPartError.new(ex.message || "cannot inspect aggregate projection primary index")
    end

    # Proves the cidx bytes describe the physical ordered UInt64 tuple lanes.
    # The index and per-lane mark inspection use bounded budgets; values are
    # scanned through fixed scratch and never materialized as whole columns.
    def self.validate_child!(
      part_path : String,
      projection_name : String,
      key_names : Array(String),
      expected_row_count : UInt64,
      expected_mark_rows : Array(UInt64),
      selected_readers : Hash(String, WidePart),
      checksums : PartChecksums,
      compressed_projection_child : Bool,
      index_budget : CompressedStreamBudget,
    ) : Nil
      raise CorruptPartError.new("compressed primary index has no UInt64 group-key roster") if key_names.empty?
      raise CorruptPartError.new("compressed primary index has no aggregate data marks") if expected_mark_rows.empty?

      entry_count = expected_mark_rows.size.to_i64 + 1_i64
      if entry_count > PrimaryKeyIndex::MAX_INDEX_ENTRIES.to_i64
        raise CorruptPartError.new("compressed primary index entry count exceeds its reader limit")
      end
      bytes_per_entry = key_names.size.to_i64 * sizeof(UInt64).to_i64
      if bytes_per_entry <= 0 || entry_count > PrimaryKeyIndex::MAX_INDEX_FILE_BYTES // bytes_per_entry
        raise CorruptPartError.new("compressed primary index exceeds its reader limit")
      end
      expected_size = entry_count * bytes_per_entry
      decoded = read_compressed(part_path, expected_size, checksums, index_budget)

      key_readers = Array(WidePart).new(key_names.size)
      key_grid_budget = CompressedStreamBudget.read_default
      key_names.each do |key_name|
        reader = selected_readers[key_name]? || WidePart.open_projection_child_typed(
          part_path,
          key_name,
          projection_name,
          compressed_projection_child,
        )
        unless reader.column_type == "UInt64" && reader.row_count == expected_row_count &&
               reader.mark_row_counts == expected_mark_rows
          raise CorruptPartError.new("compressed projection key grid differs from its selected aggregate columns")
        end
        unless selected_readers.has_key?(key_name)
          reader.selected_checksum_names.each do |checksum_name|
            checksums.validate_selected_entries(part_path, checksum_name)
          end
        end
        validate_plain_key_mark_spans!(reader, key_grid_budget) unless reader.compressed_projection_child?
        key_readers << reader
      end

      scratch = Slice(UInt64).new(256)
      key_readers.each_with_index do |reader, lane|
        seen_mark_starts = Array(Bool).new(expected_mark_rows.size, false)
        seen_terminal = false
        reader.scan_uint64_marks_into(key_names[lane], scratch) do |mark_index, mark_row_offset, _part_row_offset, values|
          unless mark_index >= 0 && mark_index < expected_mark_rows.size && !values.empty?
            raise CorruptPartError.new("compressed projection key scan escaped its mark grid")
          end
          mark_rows = expected_mark_rows[mark_index]
          if mark_row_offset > mark_rows || values.size.to_u64 > mark_rows - mark_row_offset
            raise CorruptPartError.new("compressed projection key scan exceeds its mark row count")
          end

          if mark_row_offset == 0_u64
            validate_tuple_value!(decoded, mark_index, lane, key_names.size, values[0])
            seen_mark_starts[mark_index] = true
          end

          chunk_end = mark_row_offset + values.size.to_u64
          if mark_index == expected_mark_rows.size - 1 && chunk_end == mark_rows
            validate_tuple_value!(decoded, expected_mark_rows.size, lane, key_names.size, values[values.size - 1])
            seen_terminal = true
          end
        end

        unless seen_mark_starts.all? && seen_terminal
          raise CorruptPartError.new("compressed primary index did not cover every ordered key mark and terminal tuple")
        end
      end
      nil
    end

    def self.read_compressed(
      part_path : String,
      expected_size : Int64,
      checksums : PartChecksums,
      budget : CompressedStreamBudget,
    ) : Bytes
      budget.ensure_direction(false)
      if expected_size <= 0 || expected_size > PrimaryKeyIndex::MAX_INDEX_FILE_BYTES || expected_size > Int32::MAX
        raise CorruptPartError.new("compressed primary index exceeds its reader limit")
      end

      raw_name = "primary.idx"
      compressed_name = "primary.cidx"
      raw_path = File.join(part_path, raw_name)
      compressed_path = File.join(part_path, compressed_name)
      raw_present = File.exists?(raw_path) || File.symlink?(raw_path)
      compressed_present = File.exists?(compressed_path) || File.symlink?(compressed_path)
      raw_entry = checksums.entry(raw_name)
      compressed_entry = checksums.entry(compressed_name)

      if raw_present || raw_entry
        raise CorruptPartError.new("compressed primary index is ambiguous with a raw primary index")
      end
      unless compressed_present && compressed_entry
        raise CorruptPartError.new("compressed primary index is missing from the child or checksums.txt")
      end

      entry = compressed_entry.not_nil!
      unless entry.compressed && entry.uncompressed_size && entry.uncompressed_hash
        raise CorruptPartError.new("compressed primary index metadata is incomplete")
      end
      unless entry.uncompressed_size.not_nil! == expected_size.to_u64
        raise CorruptPartError.new("compressed primary index raw size differs from its mark grid")
      end
      if entry.physical_size > PrimaryKeyIndex::MAX_INDEX_FILE_BYTES.to_u64 ||
         entry.physical_size > budget.limits.max_file_bytes.to_u64 ||
         entry.physical_size > Int32::MAX.to_u64
        raise CorruptPartError.new("compressed primary index exceeds its physical size limit")
      end

      checksums.validate_selected_entries(part_path, compressed_name)
      decoded = CompressedMarkReader.read_all(
        compressed_path,
        entry.physical_size.to_i64,
        budget,
        expected_size,
        entry.file_hash,
      )
      unless decoded.size.to_i64 == expected_size
        raise CorruptPartError.new("decompressed primary index size does not match checksums.txt")
      end
      unless CityHashV1.file_hash(decoded) == entry.uncompressed_hash.not_nil!
        raise CorruptPartError.new("decompressed primary index hash does not match checksums.txt")
      end
      decoded
    rescue ex : IO::Error
      raise InvalidPartError.new(ex.message || "cannot read compressed primary index")
    end

    private def self.validate_plain_key_mark_spans!(
      reader : WidePart,
      budget : CompressedStreamBudget,
    ) : Nil
      grid = CompressedMarkReader.inspect(
        reader.data_path,
        reader.mark_path,
        File.size(reader.data_path),
        File.size(reader.mark_path),
        0,
        budget,
      )
      CompressedMarkReader.validate_fixed_width_spans!(grid, sizeof(UInt64).to_i32)
      nil
    rescue ex : IO::Error
      raise CorruptPartError.new(ex.message || "cannot inspect plain aggregate key mark spans")
    end

    private def self.validate_tuple_value!(
      decoded : Bytes,
      entry_index : Int,
      lane : Int,
      key_count : Int,
      expected_value : UInt64,
    ) : Nil
      offset = entry_index * key_count * sizeof(UInt64) + lane * sizeof(UInt64)
      actual = IO::ByteFormat::LittleEndian.decode(UInt64, decoded[offset, sizeof(UInt64)])
      unless actual == expected_value
        raise CorruptPartError.new("compressed primary index differs from the ordered key marks")
      end
      nil
    end
  end
end
