module CrystalClick
  # Single-part typed table backend for Compact physical storage. It preserves
  # WidePartTableBatch carriers while delegating static and Dynamic lifecycle
  # decoding to Compact readers and conversion to established batch adapters.
  class CompactPartTable
    getter part_count : Int32
    getter total_row_count : UInt64
    getter checksum_verification : ChecksumVerification

    private alias CompactColumnReader = CompactBinaryBulkColumnReader | CompactDynamicBulkColumnReader
    private alias SelectedReader = {String, String, BinaryDataType, CompactColumnReader}

    @columns : Array(String)
    @column_types : Array({String, String})
    @column_sources : Array({String, String, String})
    @readers : Array(SelectedReader)
    @part_name : String
    @part_path : String
    @mark_row_counts : Array(UInt64)

    def self.open_selected_typed(parts : Array(String), columns : Array(String)) : CompactPartTable
      new(parts, columns)
    end

    private def initialize(parts : Array(String), columns : Array(String))
      unless parts.size == 1
        raise BoundsError.new("Compact table backend requires exactly one physical part")
      end
      if columns.empty?
        raise BoundsError.new("no columns selected")
      end
      if columns.size > WidePartTable::MAX_COLUMNS
        raise BoundsError.new("column count exceeds limit")
      end

      @columns = Array(String).new(columns.size)
      seen = Set(String).new
      columns.each do |column|
        if column.empty? || column.bytesize > WidePartTable::MAX_COLUMN_NAME_BYTES
          raise BoundsError.new("column name is empty or exceeds limit")
        end
        raise BoundsError.new("duplicate selected column") unless seen.add?(column)
        @columns << String.new(column.to_slice)
      end

      @part_path, @part_name = validate_selected_part(parts[0])
      budget = CompressedStreamBudget.read_default
      metadata = PartMetadataFileReader.new(@part_path, budget)
      physical_columns = WidePart.parse_columns_metadata(metadata.read("columns.txt"))
      physical_types = Hash(String, String).new(initial_capacity: physical_columns.size)
      physical_columns.each do |name, type|
        raise CorruptPartError.new("duplicate Compact physical column") if physical_types.has_key?(name)
        physical_types[name] = type
      end

      @readers = Array(SelectedReader).new(@columns.size)
      @column_types = Array({String, String}).new(@columns.size)
      @column_sources = Array({String, String, String}).new(@columns.size)
      @mark_row_counts = [] of UInt64
      row_count = nil.as(UInt64?)

      @columns.each do |column|
        source_type = physical_types[column]?
        unless source_type
          raise CorruptPartError.new("selected column is absent from Compact columns.txt")
        end
        dynamic_type = compact_dynamic_type(source_type)
        type = dynamic_type || StaticBinaryBulkColumnDeclaration.parse(source_type) ||
               raise(UnsupportedFormatError.new("selected Compact declaration is outside static or Dynamic BinaryBulk admission"))
        if dynamic_type.nil? && !BinaryValueTypedBatchAdapter.admitted?(type)
          raise UnsupportedFormatError.new("selected Compact declaration has no established typed batch carrier")
        end

        reader : CompactColumnReader = if dynamic_type
          CompactDynamicBulkColumnReader.open(
            @part_path,
            column,
            type,
            transport_budget: budget,
          )
        else
          CompactBinaryBulkColumnReader.open(
            @part_path,
            column,
            type,
            transport_budget: budget,
          )
        end
        unless reader.schema_declaration == source_type && reader.source_declaration == source_type
          raise CorruptPartError.new("selected Compact declaration differs from its physical schema")
        end
        if existing_rows = row_count
          unless reader.row_count == existing_rows
            raise CorruptPartError.new("selected Compact columns have different parent row counts")
          end
          unless reader.mark_row_counts == @mark_row_counts
            raise CorruptPartError.new("selected Compact columns have different parent mark grids")
          end
        else
          row_count = reader.row_count
          @mark_row_counts = reader.mark_row_counts
        end

        @readers << {String.new(column.to_slice), String.new(source_type.to_slice), type, reader}
        @column_types << {String.new(column.to_slice), String.new(source_type.to_slice)}
        @column_sources << {
          String.new(column.to_slice),
          String.new(column.to_slice),
          String.new(source_type.to_slice),
        }
      end

      @total_row_count = row_count || raise(CorruptPartError.new("Compact table has no selected readers"))
      if @total_row_count == 0_u64 || @total_row_count > WidePartTable::MAX_TOTAL_ROWS
        raise BoundsError.new("Compact part row count is outside the typed table limit")
      end
      if @mark_row_counts.empty? || @mark_row_counts.size > WidePartTable::MAX_MARKS_PER_READER
        raise BoundsError.new("Compact part mark count is outside the typed table limit")
      end
      if @mark_row_counts.size.to_u64 > WidePartTable::MAX_TOTAL_MARKS
        raise BoundsError.new("Compact part mark count exceeds total mark limit")
      end
      @mark_row_counts.each do |rows|
        if rows == 0_u64 || rows > WidePartTable::MAX_MARK_ROWS
          raise BoundsError.new("Compact mark row count is outside the typed table limit")
        end
      end

      @part_count = 1_i32
      @checksum_verification = ChecksumVerification::SizeChecked
    end

    def columns : Array(String)
      @columns.map { |column| String.new(column.to_slice) }
    end

    def column_types : Array({String, String})
      @column_types.map { |name, type| {String.new(name.to_slice), String.new(type.to_slice)} }
    end

    def column_sources : Array({String, String, String})
      @column_sources.map do |name, source_name, source_type|
        {String.new(name.to_slice), String.new(source_name.to_slice), String.new(source_type.to_slice)}
      end
    end

    def part_mark_row_counts : Array(Array(UInt64))
      [@mark_row_counts.dup]
    end

    def scan_typed(
      batch_rows : Int = WidePartTable::DEFAULT_BATCH_ROWS,
      & : WidePartTableBatch -> Nil
    ) : Nil
      validate_batch_rows(batch_rows)
      scan_selected_marks(nil, batch_rows, nil) { |batch| yield batch }
      nil
    end

    def scan_typed_window(
      start_row : UInt64,
      max_rows : Int = WidePartTable::DEFAULT_BATCH_ROWS,
      & : WidePartTableBatch -> Nil
    ) : Nil
      validate_batch_rows(max_rows, "window row count")
      if start_row > @total_row_count
        raise BoundsError.new("window start is beyond the source row count")
      end
      if start_row == @total_row_count
        validate_dynamic_schedules!
        return nil
      end

      available = @total_row_count - start_row
      rows = max_rows.to_u64 < available ? max_rows.to_u64 : available
      scan_selected_marks(nil, max_rows, {start_row, start_row + rows}) { |batch| yield batch }
      nil
    end

    def scan_typed_candidate_marks(
      mark_indices : Array(Array(Int32)),
      & : WidePartTableBatch -> Nil
    ) : Nil
      unless mark_indices.size == 1
        raise BoundsError.new("candidate mark list does not match the Compact part")
      end
      selected = mark_indices[0].dup
      previous = -1
      selected.each do |mark|
        if mark < 0 || mark >= @mark_row_counts.size
          raise BoundsError.new("candidate mark index is out of range")
        end
        if mark <= previous
          raise BoundsError.new("candidate mark indices must be strictly increasing")
        end
        previous = mark
      end
      # A candidate callback is one complete physical granule, matching the
      # existing typed Wide candidate-mark contract.
      scan_selected_marks(selected, WidePartTable::MAX_MARK_ROWS.to_i, nil) { |batch| yield batch }
      nil
    end

    private def scan_selected_marks(
      candidate_marks : Array(Int32)?,
      batch_rows : Int,
      window_rows : {UInt64, UInt64}?,
      & : WidePartTableBatch -> Nil
    ) : Nil
      validate_dynamic_schedules!

      selected_cursor = 0
      part_row_offset = 0_u64
      @mark_row_counts.each_with_index do |mark_rows, mark_index|
        selected = true
        if marks = candidate_marks
          selected = selected_cursor < marks.size && marks[selected_cursor] == mark_index
          selected_cursor += 1 if selected
        end

        mark_start = part_row_offset
        if mark_rows > UInt64::MAX - part_row_offset
          raise CorruptPartError.new("Compact part row offset overflows")
        end
        part_row_offset += mark_rows
        next unless selected

        row_start = 0_u64
        row_end = mark_rows
        if window = window_rows
          window_start, window_end = window
          mark_end = part_row_offset
          next if window_start >= mark_end || window_end <= mark_start
          row_start = window_start > mark_start ? window_start - mark_start : 0_u64
          row_end = window_end < mark_end ? window_end - mark_start : mark_rows
        end
        next unless row_start < row_end

        values_by_column, retained_charge = materialize_mark(mark_index, mark_rows)
        cursor = row_start
        while cursor < row_end
          remaining = row_end - cursor
          slice_rows = remaining < batch_rows.to_u64 ? remaining : batch_rows.to_u64
          emit_batch(mark_index, mark_start, cursor, slice_rows, values_by_column) { |batch| yield batch }
          cursor += slice_rows
        end
        # The logical charge bounds one selected mark at a time. Values and
        # adapter owners become callback-scoped and are not retained here.
        retained_charge
      end
      unless part_row_offset == @total_row_count
        raise CorruptPartError.new("Compact part row grid differs from its total row count")
      end
      nil
    end

    # A learned Dynamic plan is part-wide state. Validate every granule
    # before mark/window selection can publish rows, including an empty
    # candidate set or an EOF-first window. Previously normalized Dynamic
    # owners remain live while later readers prepare, so their retained
    # workspace is included in each subsequent reader's preflight.
    private def validate_dynamic_schedules! : Nil
      limit = WidePartTable::MAX_MARK_MATERIALIZED_BYTES.to_u64
      @readers.each_with_index do |entry, reader_index|
        reader = entry[3].as?(CompactDynamicBulkColumnReader)
        next unless reader

        other_retained_workspace = 0_u64
        @readers.each_with_index do |other_entry, other_index|
          next if other_index == reader_index
          other_retained_workspace = checked_add(other_retained_workspace, other_entry[3].retained_workspace_bytes)
        end
        if other_retained_workspace > limit
          raise CorruptPartError.new("Compact selected mark exceeds aggregate materialization limit")
        end
        reader_workspace_limit = limit - other_retained_workspace
        workspace_observer = ->(workspace_bytes : UInt64) do
          if workspace_bytes > reader_workspace_limit
            raise CorruptPartError.new("Compact selected mark exceeds aggregate materialization limit")
          end
          nil
        end
        reader.validate_complete_schedule(workspace_observer)
      end
      nil
    end

    private def materialize_mark(
      mark_index : Int32,
      rows : UInt64,
    ) : {Array(Array(BinaryValue)), UInt64}
      remaining_bytes = WidePartTable::MAX_MARK_MATERIALIZED_BYTES.to_u64
      retained_workspace = 0_u64
      @readers.each do |entry|
        retained_workspace = checked_add(retained_workspace, entry[3].retained_workspace_bytes)
      end
      if retained_workspace > remaining_bytes
        raise CorruptPartError.new("Compact selected mark exceeds aggregate materialization limit")
      end
      remaining_bytes -= retained_workspace

      # All selected reader contexts stay live for this mark. Charge their
      # aggregate retained owner before allocating results or decoding values.
      values_by_column = Array(Array(BinaryValue)).new(@readers.size)
      retained_total = retained_workspace

      @readers.each do |entry|
        reader = entry[3]
        charge = ObjectValuesMaterializationBudget.new(logical_limit: remaining_bytes)
        begin
          charge.reserve_binary_values_base(rows, 0_u64)
        rescue ex : BoundsError
          raise CorruptPartError.new("Compact selected mark exceeds aggregate materialization limit")
        end

        peak_extra_workspace = 0_u64
        workspace_observer = ->(current_extra_workspace : UInt64) do
          begin
            charge.ensure_workspace(current_extra_workspace)
          rescue ex : BoundsError
            raise CorruptPartError.new("Compact selected mark exceeds aggregate materialization limit")
          end
          if current_extra_workspace > peak_extra_workspace
            peak_extra_workspace = current_extra_workspace
          end
          nil
        end

        decoded_marks = reader.read_marks(mark_index, 1, workspace_observer)
        unless decoded_marks.size == 1 && decoded_marks[0].size.to_u64 == rows
          raise CorruptPartError.new("Compact selected mark returned an invalid BinaryValue grid")
        end
        values = decoded_marks[0]
        begin
          charge.charge_binary_values(values, peak_extra_workspace)
        rescue ex : BoundsError
          raise CorruptPartError.new("Compact selected mark exceeds aggregate materialization limit")
        end
        owner_bytes = checked_add(charge.retained_logical_bytes, peak_extra_workspace)
        if owner_bytes > remaining_bytes
          raise CorruptPartError.new("Compact selected mark exceeds aggregate materialization limit")
        end
        remaining_bytes -= owner_bytes
        retained_total = checked_add(retained_total, owner_bytes)
        values_by_column << values
      end

      # Convert-estimates are preflighted for every callback slice and selected
      # column before any legacy carrier array or callback is exposed.
      cursor = 0_u64
      carrier_bytes = 0_u64
      while cursor < rows
        slice_rows = (rows - cursor) < WidePartTable::MAX_BATCH_ROWS.to_u64 ? (rows - cursor) : WidePartTable::MAX_BATCH_ROWS.to_u64
        @readers.each_with_index do |entry, column_index|
          # Dynamic already has its exact BinaryValue carrier; installing the
          # borrowed slice does not allocate a second typed owner.
          next if entry[2].contains_dynamic?
          values = values_by_column[column_index]
          slice = Slice.new(values.to_unsafe + cursor.to_i, slice_rows.to_i)
          estimated = BinaryValueTypedBatchAdapter.estimated_materialization_bytes(entry[2], slice)
          unless estimated
            raise UnsupportedFormatError.new("Compact selected mark has no bounded typed carrier estimate")
          end
          if estimated > remaining_bytes - carrier_bytes
            raise CorruptPartError.new("Compact typed carriers exceed aggregate materialization limit")
          end
          carrier_bytes += estimated
        end
        cursor += slice_rows
      end
      {values_by_column, checked_add(retained_total, carrier_bytes)}
    end

    private def emit_batch(
      mark_index : Int32,
      mark_start : UInt64,
      row_offset : UInt64,
      rows : UInt64,
      values_by_column : Array(Array(BinaryValue)),
      & : WidePartTableBatch -> Nil
    ) : Nil
      row_end = row_offset + rows
      type_names = @column_types.map(&.[1])
      batch = WidePartTableBatch.new(
        0_i32,
        @part_name,
        @part_path,
        mark_index,
        row_offset,
        mark_start + row_offset,
        mark_start + row_offset,
        @columns,
        type_names,
        [] of WidePartNumericSlice,
        row_count: rows,
      )
      @readers.each_with_index do |entry, column_index|
        values = values_by_column[column_index]
        slice = Slice.new(values.to_unsafe + row_offset.to_i, rows.to_i)
        if entry[2].contains_dynamic?
          batch.install_dynamic_bulk_values(entry[0], slice, rows.to_i32)
        else
          BinaryValueTypedBatchAdapter.install(
            batch,
            entry[0],
            entry[2],
            slice,
            rows.to_i32,
          )
        end
      end
      yield batch
      nil
    end

    private def validate_batch_rows(rows : Int, label : String = "batch row count") : Nil
      if rows <= 0 || rows > WidePartTable::MAX_BATCH_ROWS
        raise BoundsError.new("#{label} is out of range")
      end
      nil
    end

    private def compact_dynamic_type(source_type : String) : BinaryDataType?
      if source_type == "Dynamic"
        bytes = source_type.to_slice
        return ObjectDeclaredDynamicDeclaration.resolve_slice(bytes, 0, bytes.size).try(&.materialize)
      end
      DynamicBulkColumnDeclaration.parse(source_type)
    end

    private def validate_selected_part(requested_path : String) : {String, String}
      if requested_path.empty? || requested_path.bytesize > WidePartTable::MAX_PART_PATH_BYTES
        raise BoundsError.new("part path is empty or exceeds limit")
      end
      path = File.expand_path(requested_path)
      name = File.basename(path)
      if name.bytesize > WidePartTable::MAX_PART_NAME_BYTES
        raise BoundsError.new("part name exceeds limit")
      end
      info = MergeTreePartInfo.parse(name) || raise(InvalidPartError.new("invalid selected part name: #{name}"))
      raise UnsupportedFormatError.new("patch parts are not supported") if info.patch?
      raise InvalidPartError.new("selected part is a symbolic link: #{name}") if File.symlink?(path)
      raise InvalidPartError.new("selected part is not a directory: #{name}") unless Dir.exists?(path)
      {path, String.new(name.to_slice)}
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise CorruptPartError.new("Compact table materialization charge overflows")
      end
      left + right
    end
  end
end
