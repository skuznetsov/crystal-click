module CrystalClick
  # A bounded table facade over a caller-selected mixture of physical Wide and
  # Compact parts. Each backend remains responsible for its native decoding;
  # this class composes their preflighted row grids and rebases callback
  # coordinates into the original selected-part order.
  class TypedPartTable
    getter part_count : Int32
    getter total_row_count : UInt64
    getter checksum_verification : ChecksumVerification

    private alias Reader = WidePartTable | CompactPartTable

    @columns : Array(String)
    @entries : Array(TypedPartReaderEntry)
    @column_types : Array({String, String})
    @column_sources : Array({String, String, String})
    @part_mark_row_counts : Array(Array(UInt64))

    def self.open_selected_typed(parts : Array(String), columns : Array(String)) : TypedPartTable
      new(parts, columns)
    end

    # :nodoc:
    # Compose selected projection children when the child formats vary by
    # parent. Parent paths remain the output identity; each physical child is
    # independently dispatched to its established Wide or Compact reader.
    def self.open_selected_projection_typed(
      selection : ProjectionChildSelection,
      columns : Array(String),
    ) : TypedPartTable
      new(selection.parent_paths, columns, selection)
    end

    private def initialize(
      parts : Array(String),
      columns : Array(String),
      projection_selection : ProjectionChildSelection? = nil,
    )
      raise BoundsError.new("no parts selected") if parts.empty?
      raise BoundsError.new("part count exceeds limit") if parts.size > WidePartTable::MAX_PARTS
      raise BoundsError.new("no columns selected") if columns.empty?
      raise BoundsError.new("column count exceeds limit") if columns.size > WidePartTable::MAX_COLUMNS

      @columns = Array(String).new(columns.size)
      seen_columns = Hash(String, Bool).new
      columns.each do |column|
        if column.empty? || column.bytesize > WidePartTable::MAX_COLUMN_NAME_BYTES
          raise BoundsError.new("column name is empty or exceeds limit")
        end
        raise BoundsError.new("duplicate selected column") if seen_columns.has_key?(column)
        seen_columns[column] = true
        @columns << String.new(column.to_slice)
      end

      # Validate all names, canonical paths, duplicates and overlap identities
      # before opening any format-specific backend. Projection admission passes
      # the prepared parent/child identity set so it is not revalidated here.
      selected = if selection = projection_selection
                   selection.selected_parts
                 else
                   ProjectionChildSelection.parent_parts!(parts)
                 end

      projection_child_paths = projection_selection.try(&.child_paths)

      @entries = Array(TypedPartReaderEntry).new(selected.size)
      @part_mark_row_counts = Array(Array(UInt64)).new(selected.size)
      expected_types = nil.as(Array({String, String})?)
      expected_sources = nil.as(Array({String, String, String})?)
      expected_aggregate_count_key_names = nil.as(Array(String)?)
      expected_compact_projection_key_names = nil.as(Array(String)?)
      compact_projection_aggregate_seen = false
      wide_projection_children = [] of {String, UInt64, Array(UInt64)}
      projection_without_count = !@columns.includes?("count()")
      total_rows = 0_u64
      total_marks = 0_u64
      checksum_state = ChecksumVerification::SizeChecked

      selected.each_with_index do |selected_part, part_index|
        path, name, info = selected_part
        read_path = if child_paths = projection_child_paths
                      child_paths[part_index]
                    else
                      path
                    end
        dispatch_budget = CompressedStreamBudget.read_default
        metadata = PartMetadataFileReader.new(read_path, dispatch_budget)
        checksums = PartChecksums.parse(
          metadata.read("checksums.txt", PartChecksums::MAX_CHECKSUM_FILE_BYTES).to_slice
        )
        reader : Reader = if CompactMarkFileAdapter.routing_candidate?(read_path, checksums)
          if selection = projection_selection
            CompactPartTable.open_selected_projection_child_typed(path, selection.projection_name, @columns)
          else
            CompactPartTable.open_selected_typed([path], @columns)
          end
        else
          if selection = projection_selection
            WidePartTable.open_selected_projection_typed([path], selection.projection_name, @columns)
          else
            WidePartTable.open_selected_typed([path], @columns)
          end
        end
        unless reader.part_count == 1
          raise CorruptPartError.new("typed part backend did not retain exactly one selected part")
        end

        current_columns = reader.columns
        unless current_columns == @columns
          raise CorruptPartError.new("typed part backend changed the selected column order")
        end
        current_types = reader.column_types
        current_sources = reader.column_sources
        unless current_types.size == @columns.size && current_sources.size == @columns.size
          raise CorruptPartError.new("typed part backend returned incomplete selected metadata")
        end
        if prior_types = expected_types
          unless current_types == prior_types
            raise CorruptPartError.new("selected columns have different types across parts")
          end
        else
          expected_types = detached_types(current_types)
        end
        if prior_sources = expected_sources
          unless current_sources == prior_sources
            raise CorruptPartError.new("selected columns have different source schemas across parts")
          end
        else
          expected_sources = detached_sources(current_sources)
        end

        current_count_key_names = reader.aggregate_count_key_names
        if part_index == 0
          expected_aggregate_count_key_names = current_count_key_names
        elsif current_count_key_names != expected_aggregate_count_key_names
          raise CorruptPartError.new("selected parts have different hidden AggregateFunction(count) sibling group key rosters")
        end

        if projection_selection && projection_without_count
          if compact_reader = reader.as?(CompactPartTable)
            if current_key_names = compact_reader.projection_aggregate_key_names
              compact_projection_aggregate_seen = true
              if prior_key_names = expected_compact_projection_key_names
                unless current_key_names == prior_key_names
                  raise CorruptPartError.new("selected Compact projection aggregate siblings disagree on their group key roster")
                end
              else
                expected_compact_projection_key_names = current_key_names
              end
            end
          end
        end

        marks_by_part = reader.part_mark_row_counts
        unless marks_by_part.size == 1 && !marks_by_part[0].empty? &&
               marks_by_part[0].size <= WidePartTable::MAX_MARKS_PER_READER
          raise CorruptPartError.new("selected part mark inventory is empty or exceeds its limit")
        end
        mark_rows = marks_by_part[0].dup
        part_rows = 0_u64
        mark_rows.each do |rows|
          raise BoundsError.new("mark row count exceeds limit") if rows > WidePartTable::MAX_MARK_ROWS
          if rows > UInt64::MAX - part_rows
            raise CorruptPartError.new("selected part mark row count overflows")
          end
          part_rows += rows
        end
        unless part_rows == reader.total_row_count && part_rows > 0_u64
          raise CorruptPartError.new("selected part mark grid differs from its row count")
        end
        if projection_selection && projection_without_count && reader.is_a?(WidePartTable)
          wide_projection_children << {
            String.new(read_path.to_slice),
            part_rows,
            mark_rows.dup,
          }
        end
        if part_rows > WidePartTable::MAX_TOTAL_ROWS.to_u64 - total_rows
          raise BoundsError.new("total row count exceeds limit")
        end
        total_rows += part_rows
        if mark_rows.size.to_u64 > WidePartTable::MAX_TOTAL_MARKS - total_marks
          raise BoundsError.new("total mark count exceeds limit")
        end
        total_marks += mark_rows.size.to_u64
        @part_mark_row_counts << mark_rows.dup

        if reader.checksum_verification == ChecksumVerification::Unverified
          checksum_state = ChecksumVerification::Unverified
        end
        @entries << TypedPartReaderEntry.new(name, path, info, reader, part_rows, mark_rows)
      end

      @column_types = expected_types || raise(CorruptPartError.new("selected parts have no typed column metadata"))
      @column_sources = expected_sources || raise(CorruptPartError.new("selected parts have no source metadata"))
      if projection_selection && projection_without_count && compact_projection_aggregate_seen
        expected_key_names = expected_compact_projection_key_names ||
                             raise(CorruptPartError.new("Compact projection aggregate omitted its group key roster"))
        wide_projection_children.each do |wide_path, wide_rows, wide_marks|
          wide_key_names = wide_projection_group_key_names!(wide_path, wide_rows, wide_marks)
          unless wide_key_names == expected_key_names
            raise CorruptPartError.new("selected mixed Wide/Compact projection aggregate group key roster differs")
          end
        end
      end
      @total_row_count = total_rows
      @part_count = @entries.size.to_i32
      @checksum_verification = checksum_state
    end

    # Mixed no-Count projection parity is checked only after an admitted
    # Compact aggregate child has supplied its hidden key roster. The Wide
    # child metadata provides the ordered leading UInt64 group keys.
    private def wide_projection_group_key_names!(
      path : String,
      expected_rows : UInt64,
      expected_mark_rows : Array(UInt64),
    ) : Array(String)
      budget = CompressedStreamBudget.read_default
      metadata = PartMetadataFileReader.new(path, budget)
      checksums = PartChecksums.parse(
        metadata.read("checksums.txt", PartChecksums::MAX_CHECKSUM_FILE_BYTES).to_slice,
      )
      columns_text = metadata.read("columns.txt")
      if checksums.entries.has_key?("columns.txt")
        checksums.validate_selected_entries(path, "columns.txt")
      end
      compressed_projection_child = WideMarkFileAdapter.projection_child_compressed_marks?(path, checksums)
      projection_basename = File.basename(path)
      unless projection_basename.ends_with?(".proj") && projection_basename.bytesize > ".proj".bytesize
        raise CorruptPartError.new("Wide projection child path is missing its projection suffix")
      end
      projection_name = projection_basename.byte_slice(0, projection_basename.bytesize - ".proj".bytesize)
      columns = WidePart.parse_columns_metadata(columns_text)
      key_count = 0
      while key_count < columns.size && columns[key_count][1] == "UInt64"
        key_count += 1
      end
      if key_count == 0
        raise CorruptPartError.new("Wide projection aggregate has no UInt64 group key roster")
      end
      key_names = columns.first(key_count).map { |name, _type| String.new(name.to_slice) }
      unless key_names.to_set.size == key_names.size
        raise CorruptPartError.new("Wide projection aggregate group key roster contains duplicate names")
      end
      key_names.each do |key_name|
        key_reader = if compressed_projection_child
                       WidePart.open_projection_child_typed(path, key_name, projection_name, true)
                     else
                       WidePart.open_typed(path, key_name)
                     end
        unless key_reader.column_type == "UInt64" && key_reader.row_count == expected_rows &&
               key_reader.mark_row_counts == expected_mark_rows
          raise CorruptPartError.new("Wide projection aggregate group key row-mark axes differ from its selected state")
        end
        key_reader.selected_checksum_names.each do |checksum_name|
          checksums.validate_selected_entries(path, checksum_name)
        end
      end
      key_names
    end

    def columns : Array(String)
      @columns.map { |column| String.new(column.to_slice) }
    end

    def column_types : Array({String, String})
      detached_types(@column_types)
    end

    def column_sources : Array({String, String, String})
      detached_sources(@column_sources)
    end

    def part_mark_row_counts : Array(Array(UInt64))
      @part_mark_row_counts.map(&.dup)
    end

    def scan_typed(batch_rows : Int = WidePartTable::DEFAULT_BATCH_ROWS, & : WidePartTableBatch -> Nil) : Nil
      validate_batch_rows(batch_rows)
      preflight_backends!

      source_row_offset = 0_u64
      @entries.each_with_index do |entry, part_index|
        entry.reader.scan_typed(batch_rows: batch_rows) do |batch|
          yield rebase_batch!(batch, part_index, source_row_offset)
        end
        source_row_offset = checked_add_rows(source_row_offset, entry.row_count)
      end
      raise CorruptPartError.new("source row count mismatch") unless source_row_offset == @total_row_count
      nil
    end

    def scan_typed_window(
      start_row : UInt64,
      max_rows : Int = WidePartTable::DEFAULT_BATCH_ROWS,
      & : WidePartTableBatch -> Nil
    ) : Nil
      validate_batch_rows(max_rows, "window row count")
      raise BoundsError.new("window start is beyond the source row count") if start_row > @total_row_count
      preflight_backends!
      return nil if start_row == @total_row_count

      available = @total_row_count - start_row
      window_rows = max_rows.to_u64 < available ? max_rows.to_u64 : available
      window_end = start_row + window_rows
      part_start = 0_u64

      @entries.each_with_index do |entry, part_index|
        part_end = checked_add_rows(part_start, entry.row_count)
        overlap_start = start_row > part_start ? start_row : part_start
        overlap_end = window_end < part_end ? window_end : part_end
        if overlap_start < overlap_end
          local_start = overlap_start - part_start
          local_rows = (overlap_end - overlap_start).to_i
          entry.reader.scan_typed_window(local_start, local_rows) do |batch|
            yield rebase_batch!(batch, part_index, part_start)
          end
        end
        part_start = part_end
      end
      raise CorruptPartError.new("source row count mismatch") unless part_start == @total_row_count
      nil
    end

    def scan_typed_candidate_marks(mark_indices : Array(Array(Int32)), & : WidePartTableBatch -> Nil) : Nil
      raise BoundsError.new("candidate mark list does not match selected parts") unless mark_indices.size == @entries.size
      schedule = Array(Array(Int32)).new(mark_indices.size)
      mark_indices.each_with_index do |part_marks, part_index|
        detached = part_marks.dup
        mark_count = @entries[part_index].mark_row_counts.size
        previous = -1
        detached.each do |mark_index|
          raise BoundsError.new("candidate mark index is out of range") if mark_index < 0 || mark_index >= mark_count
          raise BoundsError.new("candidate mark indices must be strictly increasing") if mark_index <= previous
          previous = mark_index
        end
        schedule << detached
      end

      preflight_backends!
      source_row_offset = 0_u64
      @entries.each_with_index do |entry, part_index|
        entry.reader.scan_typed_candidate_marks([schedule[part_index]]) do |batch|
          yield rebase_batch!(batch, part_index, source_row_offset)
        end
        source_row_offset = checked_add_rows(source_row_offset, entry.row_count)
      end
      raise CorruptPartError.new("source row count mismatch") unless source_row_offset == @total_row_count
      nil
    end

    private def preflight_backends! : Nil
      empty_schedule = Array(Array(Int32)).new(1) { [] of Int32 }
      @entries.each do |entry|
        # Both table backends run their complete schedule/cursor preflights
        # before the first selected callback. An empty candidate set exercises
        # those guards without materializing a mark.
        emitted = false
        entry.reader.scan_typed_candidate_marks(empty_schedule) do |_batch|
          emitted = true
        end
        raise CorruptPartError.new("empty typed preflight unexpectedly emitted a batch") if emitted
      end
      nil
    end

    private def rebase_batch!(batch : WidePartTableBatch, part_index : Int, part_start : UInt64) : WidePartTableBatch
      raise CorruptPartError.new("typed backend emitted a nonlocal part index") unless batch.part_index == 0
      absolute_source_offset = checked_add_rows(part_start, batch.part_row_offset)
      batch.rebase_coordinates!(part_index.to_i32, absolute_source_offset)
      batch
    end

    private def validate_batch_rows(rows : Int, label : String = "batch row count") : Nil
      raise BoundsError.new("#{label} is out of range") if rows <= 0 || rows > WidePartTable::MAX_BATCH_ROWS
    end

    private def detached_types(values : Array({String, String})) : Array({String, String})
      values.map { |column, type| {String.new(column.to_slice), String.new(type.to_slice)} }
    end

    private def detached_sources(values : Array({String, String, String})) : Array({String, String, String})
      values.map do |column, source_name, source_type|
        {String.new(column.to_slice), String.new(source_name.to_slice), String.new(source_type.to_slice)}
      end
    end

    private def checked_add_rows(left : UInt64, right : UInt64) : UInt64
      raise CorruptPartError.new("source row offset overflows") if right > UInt64::MAX - left
      left + right
    end
  end
end
