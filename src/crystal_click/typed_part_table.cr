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

    private def initialize(parts : Array(String), columns : Array(String))
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
      # before opening any format-specific backend.
      selected = Array({String, String, MergeTreePartInfo}).new(parts.size)
      seen_paths = Hash(String, Bool).new
      parts.each do |requested_path|
        path, name, info = validate_selected_part(requested_path)
        raise BoundsError.new("duplicate selected part path") if seen_paths.has_key?(path)
        seen_paths[path] = true
        selected << {path, name, info}
      end
      reject_overlapping_parts(selected)

      @entries = Array(TypedPartReaderEntry).new(selected.size)
      @part_mark_row_counts = Array(Array(UInt64)).new(selected.size)
      expected_types = nil.as(Array({String, String})?)
      expected_sources = nil.as(Array({String, String, String})?)
      total_rows = 0_u64
      total_marks = 0_u64
      checksum_state = ChecksumVerification::SizeChecked

      selected.each do |path, name, info|
        dispatch_budget = CompressedStreamBudget.read_default
        metadata = PartMetadataFileReader.new(path, dispatch_budget)
        checksums = PartChecksums.parse(
          metadata.read("checksums.txt", PartChecksums::MAX_CHECKSUM_FILE_BYTES).to_slice
        )
        reader : Reader = if CompactMarkFileAdapter.routing_candidate?(path, checksums)
          CompactPartTable.open_selected_typed([path], @columns)
        else
          WidePartTable.open_selected_typed([path], @columns)
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
      @total_row_count = total_rows
      @part_count = @entries.size.to_i32
      @checksum_verification = checksum_state
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

    private def validate_selected_part(requested_path : String) : {String, String, MergeTreePartInfo}
      if requested_path.empty? || requested_path.bytesize > WidePartTable::MAX_PART_PATH_BYTES
        raise BoundsError.new("part path is empty or exceeds limit")
      end
      path = File.expand_path(requested_path)
      name = File.basename(path)
      raise BoundsError.new("part name exceeds limit") if name.bytesize > WidePartTable::MAX_PART_NAME_BYTES
      info = MergeTreePartInfo.parse(name) || raise(InvalidPartError.new("invalid selected part name: #{name}"))
      raise UnsupportedFormatError.new("patch parts are not supported") if info.patch?
      raise InvalidPartError.new("selected part is a symbolic link: #{name}") if File.symlink?(path)
      raise InvalidPartError.new("selected part is not a directory: #{name}") unless Dir.exists?(path)
      {path, name, info}
    rescue ex : IO::Error
      raise InvalidPartError.new(ex.message || "cannot read selected part")
    end

    private def reject_overlapping_parts(parts : Array({String, String, MergeTreePartInfo})) : Nil
      parts.each_with_index do |left, left_index|
        (left_index + 1...parts.size).each do |right_index|
          right = parts[right_index]
          if left[2].overlaps?(right[2])
            raise InvalidPartError.new("selected parts overlap: #{left[1]} and #{right[1]}")
          end
        end
      end
      nil
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
