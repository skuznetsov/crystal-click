module CrystalClick
  # Payload coordinates for one Dynamic envelope in the retained Copy lane.
  # Values are stored inline in a worker-local reusable reference slab.
  struct CompactJsonCopyReference
    getter row_index : Int32
    getter payload_offset : Int32
    getter payload_size : Int32

    def initialize(@row_index : Int32, @payload_offset : Int32, @payload_size : Int32)
    end
  end

  # Reusable borrowed output arena for one Compact Advanced root JSON scan.
  # Column wrappers and value buffers survive mark resets. Most path cells are
  # sparse, while selected UInt64 and Nullable(UInt32) lanes use retained
  # native buffers.
  class CompactJsonColumnarBatch
    getter part_index : Int32
    getter part_name : String
    getter part_path : String
    getter mark_index : Int32
    getter mark_row_offset : UInt64
    getter part_row_offset : UInt64
    getter source_row_offset : UInt64
    getter row_count : Int32
    getter column_count : Int32

    @columns : Array(CompactJsonColumnarColumn)
    @columns_by_path : Hash(String, CompactJsonColumnarColumn)
    @uint64_columns : Hash(String, Array(UInt64))
    @companion_names : Array(String)
    @companion_high_water_rows : Array(UInt64)
    @mark_row_count : Int32
    @window_start : Int32
    @selected_output_rows : Slice(Int32)
    @selected_source_row_count : Int32
    @selected_source_rows_active : Bool
    @copy_reference_slab : Slice(CompactJsonCopyReference)
    @copy_reference_ranges : Slice(Int32)
    @copy_reference_path_count : Int32
    @copy_reference_count : Int32
    @cell_count : UInt64
    @cell_payload_bytes : UInt64
    @column_buffer_bytes : UInt64
    @companion_buffer_bytes : UInt64
    @companion_reserved_bytes : UInt64
    @companion_columns_filled : Int32
    @max_cells : UInt64
    getter workspace_limit : UInt64
    @workspace_header_bytes : UInt64

    def self.from_layout(
      paths : Array(String),
      companion_columns : Array(String),
      fallback_types : Hash(String, BinaryDataType),
      max_rows : Int,
      max_cells : UInt64,
      workspace_limit : UInt64 = WidePartTable::MAX_MARK_MATERIALIZED_BYTES.to_u64,
      max_paths : Int = BinaryCodecLimits::DEFAULT_MAX_NODES,
    ) : CompactJsonColumnarBatch
      new(paths, companion_columns, fallback_types, max_rows, max_cells, workspace_limit, max_paths)
    end

    private def initialize(
      paths : Array(String),
      companion_columns : Array(String),
      fallback_types : Hash(String, BinaryDataType),
      max_rows : Int,
      @max_cells : UInt64,
      @workspace_limit : UInt64,
      max_paths : Int,
    )
      if max_rows <= 0 || max_rows.to_u64 > WidePartTable::MAX_MARK_ROWS
        raise BoundsError.new("Compact JSON columnar mark capacity is out of range")
      end
      if max_paths < 0 || paths.size > max_paths
        raise BoundsError.new("Compact JSON path roster exceeds its codec bound")
      end
      if companion_columns.size > WidePartTable::MAX_COLUMNS
        raise BoundsError.new("Compact JSON companion roster exceeds its selected-column bound")
      end
      @workspace_header_bytes = calculate_header_workspace_bytes(paths, companion_columns, fallback_types, max_rows)
      check_workspace!(@workspace_header_bytes)

      @columns = Array(CompactJsonColumnarColumn).new(paths.size)
      @columns_by_path = Hash(String, CompactJsonColumnarColumn).new(initial_capacity: paths.size)
      @uint64_columns = Hash(String, Array(UInt64)).new(initial_capacity: companion_columns.size)
      @companion_names = Array(String).new(companion_columns.size)
      @companion_high_water_rows = Array(UInt64).new(companion_columns.size, 0_u64)
      unique_paths = Set(String).new
      paths.each do |path|
        if !unique_paths.add?(path)
          raise CorruptPartError.new("Compact JSON columnar path roster is duplicated")
        end
        fallback_type = fallback_types[path]?
        column = CompactJsonColumnarColumn.new(String.new(path.to_slice), fallback_type, max_rows)
        @columns << column
        @columns_by_path[column.path] = column
      end
      @columns.sort! { |left, right| ObjectSharedChunkStructure.compare_paths(left.path, right.path) }

      companion_seen = Set(String).new
      companion_columns.each do |name|
        if name.empty? || !companion_seen.add?(name)
          raise CorruptPartError.new("Compact JSON UInt64 companion roster is empty or duplicated")
        end
        @companion_names << String.new(name.to_slice)
        @uint64_columns[@companion_names[-1]] = [] of UInt64
      end

      @part_index = 0_i32
      @part_name = ""
      @part_path = ""
      @mark_index = -1_i32
      @mark_row_offset = 0_u64
      @part_row_offset = 0_u64
      @source_row_offset = 0_u64
      @row_count = 0_i32
      @column_count = @columns.size.to_i32
      @mark_row_count = 0_i32
      @window_start = 0_i32
      @selected_output_rows = Slice(Int32).new(0)
      @selected_source_row_count = 0_i32
      @selected_source_rows_active = false
      @copy_reference_slab = Slice(CompactJsonCopyReference).empty
      @copy_reference_ranges = Slice(Int32).new(0)
      @copy_reference_path_count = 0_i32
      @copy_reference_count = 0_i32
      @cell_count = 0_u64
      @cell_payload_bytes = 0_u64
      @column_buffer_bytes = 0_u64
      @companion_buffer_bytes = 0_u64
      @companion_reserved_bytes = 0_u64
      @companion_columns_filled = 0_i32
    end

    def columns : Slice(CompactJsonColumnarColumn)
      Slice.new(@columns.to_unsafe, @columns.size, read_only: true)
    end

    def column_at(index : Int) : CompactJsonColumnarColumn
      @columns[index]
    end

    def column_for(path : String) : CompactJsonColumnarColumn?
      @columns_by_path[path]?
    end

    # :nodoc:
    # Return native, mutable full-mark destinations only when the exact
    # declared Nullable(UInt32) output column owns this representation.
    def begin_nullable_uint32_fill!(path : String, type : BinaryDataType) : Tuple(Slice(UInt32), Slice(UInt8))?
      column = @columns_by_path[path]? || return nil
      return nil unless column.has_nullable_uint32_lane? && column.fallback_type == type
      output_rows = @selected_source_rows_active ? @row_count.to_u64 : @mark_row_count.to_u64
      if @cell_count > UInt64::MAX - output_rows || @cell_count + output_rows > @max_cells
        raise CorruptPartError.new("Compact JSON columnar output exceeds the codec element bound")
      end
      if @selected_source_rows_active
        column.set_window!(0_i32, @mark_row_count)
      end
      lane = column.begin_nullable_uint32_fill!(type, @mark_row_count)
      if lane.nil? && @selected_source_rows_active
        column.set_window!(0_i32, @row_count)
      end
      lane
    end

    # :nodoc:
    def complete_nullable_uint32_fill!(path : String, rows : Int) : Nil
      if rows < 0
        raise CorruptPartError.new("Compact JSON Nullable(UInt32) fill has a negative row count")
      end
      column = @columns_by_path[path]? || raise(CorruptPartError.new("Compact JSON Nullable(UInt32) column is outside its sealed roster"))
      output_rows = @selected_source_rows_active ? @row_count : rows
      if @cell_count > UInt64::MAX - output_rows.to_u64 || @cell_count + output_rows.to_u64 > @max_cells
        raise CorruptPartError.new("Compact JSON columnar output exceeds the codec element bound")
      end
      column.complete_nullable_uint32_fill!(rows)
      compact_selected_nullable_uint32!(column) if @selected_source_rows_active
      @cell_count += output_rows.to_u64
      validate_workspace!
      nil
    end

    # :nodoc:
    def validate_layout!(paths : Array(String), companion_columns : Array(String)) : Nil
      unless @columns.size == paths.size && @columns.all? { |column| @columns_by_path.has_key?(column.path) } &&
             paths.all? { |path| @columns_by_path.has_key?(path) } &&
             @companion_names == companion_columns
        raise CorruptPartError.new("Compact JSON columnar destination differs from its sealed output roster")
      end
      nil
    end

    # :nodoc:
    # Drops borrowed leaf references while retaining the sealed shape and its
    # accounted high-water buffer state for the next assigned mark.
    def reset! : Nil
      @columns.each(&.reset!)
      @uint64_columns.each_value(&.clear)
      @part_index = 0_i32
      @part_name = ""
      @part_path = ""
      @mark_index = -1_i32
      @mark_row_offset = 0_u64
      @part_row_offset = 0_u64
      @source_row_offset = 0_u64
      @row_count = 0_i32
      @mark_row_count = 0_i32
      @window_start = 0_i32
      @selected_source_row_count = 0_i32
      @selected_source_rows_active = false
      @copy_reference_path_count = 0_i32
      @copy_reference_count = 0_i32
      @cell_count = 0_u64
      @cell_payload_bytes = 0_u64
      @companion_reserved_bytes = 0_u64
      @companion_columns_filled = 0_i32
      nil
    end

    # Direct selected UInt64 companions (for example a row key) are retained
    # as native values and exposed as a borrowed slice for the active window.
    def uint64_column(name : String) : Slice(UInt64)
      values = @uint64_columns[name]? || raise(KeyError.new("Compact JSON UInt64 companion not found: #{name.inspect}"))
      Slice.new(values.to_unsafe + @window_start, @row_count, read_only: true)
    end

    def snapshot : CompactJsonColumnarBatch
      copy = self.class.from_layout(
        @columns.map { |column| String.new(column.path.to_slice) },
        @companion_names.map { |name| String.new(name.to_slice) },
        @columns.each_with_object(Hash(String, BinaryDataType).new) do |column, types|
          if type = column.fallback_type
            types[column.path] = type
          end
        end,
        Math.max(@mark_row_count, @row_count),
        @max_cells,
        @workspace_limit,
        @columns.size,
      )
      copy.begin_mark!(
        @part_index,
        @part_name,
        @part_path,
        @mark_index,
        @mark_row_offset,
        @part_row_offset,
        @source_row_offset,
        @row_count.to_u64,
      )
      @columns.each do |column|
        if column.copy_nullable_uint32_window_to!(copy.column_for(column.path) ||
                                                  raise(CorruptPartError.new("Compact JSON snapshot lost a path column")))
          copy.note_nullable_uint32_snapshot_fill!(@row_count)
        else
          column.each_active_cell do |row, value|
            copy.append_value!(column.path, row - @window_start, value)
          end
        end
      end
      @companion_names.each do |name|
        values = @uint64_columns[name]
        copy_values = copy.uint64_values_for_snapshot(name)
        @row_count.times { |row| copy_values << values[@window_start + row] }
      end
      copy.finish_companion_fill!
      copy.set_window!(0, @row_count, @mark_row_offset, @part_row_offset, @source_row_offset)
      copy
    end

    # :nodoc:
    def begin_mark!(
      part_index : Int,
      part_name : String,
      part_path : String,
      mark_index : Int,
      mark_row_offset : UInt64,
      part_row_offset : UInt64,
      source_row_offset : UInt64,
      mark_rows : UInt64,
    ) : Nil
      if mark_index < 0 || mark_index > Int32::MAX || mark_rows == 0_u64 || mark_rows > WidePartTable::MAX_MARK_ROWS
        raise CorruptPartError.new("Compact JSON columnar mark metadata is outside its bound")
      end
      reset!
      @part_index = part_index.to_i32
      @part_name = String.new(part_name.to_slice)
      @part_path = String.new(part_path.to_slice)
      @mark_index = mark_index.to_i32
      @mark_row_offset = mark_row_offset
      @part_row_offset = part_row_offset
      @source_row_offset = source_row_offset
      @mark_row_count = mark_rows.to_i32
      @window_start = 0_i32
      @row_count = @mark_row_count
      @selected_source_row_count = 0_i32
      @selected_source_rows_active = false
      @copy_reference_path_count = 0_i32
      @copy_reference_count = 0_i32
      @cell_count = 0_u64
      @cell_payload_bytes = 0_u64
      @companion_reserved_bytes = projected_companion_buffer_bytes(mark_rows.to_i)
      @companion_columns_filled = 0_i32
      check_workspace!(retained_workspace_bytes)
      @columns.each { |column| column.set_window!(0_i32, @row_count) }
      nil
    end

    # :nodoc:
    # Begin a packed callback batch while retaining the full source extent for
    # strict decoders. Decoder appends use source-row coordinates and are kept
    # only for selected rows, at dense callback-row coordinates.
    def begin_selected_mark!(
      part_index : Int,
      part_name : String,
      part_path : String,
      mark_index : Int,
      mark_row_offset : UInt64,
      part_row_offset : UInt64,
      source_row_offset : UInt64,
      source_rows : UInt64,
      selected_rows : Slice(Int32),
    ) : Nil
      if mark_index < 0 || mark_index > Int32::MAX || source_rows == 0_u64 || source_rows > WidePartTable::MAX_MARK_ROWS
        raise CorruptPartError.new("Compact JSON selected mark metadata is outside its bound")
      end
      if selected_rows.empty? || selected_rows.size.to_u64 > source_rows
        raise CorruptPartError.new("Compact JSON selected row mask is empty or exceeds its source mark")
      end

      previous = -1_i32
      all_rows_selected = selected_rows.size.to_u64 == source_rows
      selected_rows.each_with_index do |row, index|
        unless row > previous && row.to_u64 < source_rows
          raise CorruptPartError.new("Compact JSON selected row mask is unordered, duplicated, or out of range")
        end
        all_rows_selected &&= row == index
        previous = row
      end

      if all_rows_selected
        begin_mark!(part_index, part_name, part_path, mark_index, mark_row_offset,
          part_row_offset, source_row_offset, source_rows)
        return nil
      end

      reset!
      required_map_size = source_rows.to_i
      if required_map_size > @selected_output_rows.size
        new_map_bytes = checked_multiply(required_map_size.to_u64, sizeof(Int32).to_u64)
        validate_workspace!(new_map_bytes)
        selected_rows_map = Slice(Int32).new(required_map_size)
        @selected_output_rows = selected_rows_map
      end
      required_map_size.times { |row| @selected_output_rows[row] = -1_i32 }
      @part_index = part_index.to_i32
      @part_name = String.new(part_name.to_slice)
      @part_path = String.new(part_path.to_slice)
      @mark_index = mark_index.to_i32
      @mark_row_offset = mark_row_offset
      @part_row_offset = part_row_offset
      @source_row_offset = source_row_offset
      @mark_row_count = source_rows.to_i32
      @selected_source_row_count = source_rows.to_i32
      @selected_source_rows_active = true
      @window_start = 0_i32
      @row_count = selected_rows.size.to_i32
      selected_rows.each_with_index do |row, destination_row|
        @selected_output_rows[row] = destination_row.to_i32
      end
      @cell_count = 0_u64
      @cell_payload_bytes = 0_u64
      @companion_reserved_bytes = projected_companion_buffer_bytes(selected_rows.size)
      @companion_columns_filled = 0_i32
      @columns.each { |column| column.set_window!(0_i32, @row_count) }
      validate_workspace!
      nil
    end

    # :nodoc:
    # Return the packed callback row for a source row, or nil when rejected.
    def selected_output_row(source_row : Int) : Int32?
      return source_row.to_i32 unless @selected_source_rows_active
      return nil if source_row < 0 || source_row >= @selected_source_row_count
      destination = @selected_output_rows[source_row]
      destination >= 0 ? destination : nil
    end

    # :nodoc:
    def source_mark_row_count : Int32
      @selected_source_rows_active ? @selected_source_row_count : @mark_row_count
    end

    # :nodoc:
    def selected_mark? : Bool
      @selected_source_rows_active
    end

    # :nodoc:
    # Prepare one retained pointer-free Copy reference slab and a compact
    # `[start, count, cursor]` record per dictionary path. Growth is bounded
    # before allocation and accounts both old and replacement storage while
    # the column-binding owner is live.
    def begin_selected_copy_reference_ledger!(
      path_count : Int,
      total_entries : Int,
      additional_workspace_bytes : UInt64 = 0_u64,
    ) : Nil
      unless @selected_source_rows_active && path_count >= 0 && path_count <= Int32::MAX &&
             total_entries >= 0 && total_entries <= Int32::MAX
        raise CorruptPartError.new("Compact JSON selected Copy ledger is outside its source mark")
      end
      required_ranges = checked_multiply(path_count.to_u64, 3_u64).to_i
      new_slab_bytes = if total_entries > @copy_reference_slab.size
                         checked_multiply(total_entries.to_u64, sizeof(CompactJsonCopyReference).to_u64)
                       else
                         0_u64
                       end
      new_range_bytes = if required_ranges > @copy_reference_ranges.size
                          checked_multiply(required_ranges.to_u64, sizeof(Int32).to_u64)
                        else
                          0_u64
                        end
      growth_bytes = checked_add(new_slab_bytes, new_range_bytes)
      validate_workspace!(checked_add(growth_bytes, additional_workspace_bytes))

      if total_entries > @copy_reference_slab.size
        @copy_reference_slab = Slice.new(Pointer(CompactJsonCopyReference).malloc(total_entries), total_entries)
      end
      if required_ranges > @copy_reference_ranges.size
        @copy_reference_ranges = Slice(Int32).new(required_ranges)
      end
      @copy_reference_path_count = path_count.to_i32
      @copy_reference_count = total_entries.to_i32
      required_ranges.times { |index| @copy_reference_ranges[index] = 0_i32 }
      nil
    end

    # :nodoc:
    # Count an index after the shared Copy validator has checked its range and
    # strict per-row byte-path ordering.
    def count_selected_copy_reference_path!(path_index : Int32) : Nil
      unless path_index >= 0 && path_index < @copy_reference_path_count
        raise CorruptPartError.new("Compact JSON selected Copy path index is outside its ledger")
      end
      count_offset = path_index * 3 + 1
      if @copy_reference_ranges[count_offset] == Int32::MAX
        raise CorruptPartError.new("Compact JSON selected Copy path count exceeds Int32")
      end
      @copy_reference_ranges[count_offset] += 1
      nil
    end

    # :nodoc:
    # Convert path counts into contiguous reference ranges and preserve the
    # existing rejection of dictionary entries not used by any Copy row.
    def finish_selected_copy_reference_plan! : Nil
      next_offset = 0
      @copy_reference_path_count.times do |path_index|
        base = path_index * 3
        count = @copy_reference_ranges[base + 1]
        if count == 0
          raise CorruptPartError.new("Object shared Copy dictionary contains an unreferenced path")
        end
        if count > @copy_reference_count - next_offset
          raise CorruptPartError.new("Compact JSON selected Copy path counts exceed their entry extent")
        end
        @copy_reference_ranges[base] = next_offset
        @copy_reference_ranges[base + 2] = 0_i32
        next_offset += count
      end
      unless next_offset == @copy_reference_count
        raise CorruptPartError.new("Compact JSON selected Copy path counts differ from their entry extent")
      end
      nil
    end

    # :nodoc:
    def append_selected_copy_reference!(path_index : Int32, reference : CompactJsonCopyReference) : Nil
      unless path_index >= 0 && path_index < @copy_reference_path_count
        raise CorruptPartError.new("Compact JSON selected Copy path index is outside its ledger")
      end
      base = path_index * 3
      start = @copy_reference_ranges[base]
      count = @copy_reference_ranges[base + 1]
      cursor = @copy_reference_ranges[base + 2]
      if cursor >= count
        raise CorruptPartError.new("Compact JSON selected Copy path has too many references")
      end
      @copy_reference_slab[start + cursor] = reference
      @copy_reference_ranges[base + 2] = cursor + 1
      nil
    end

    # :nodoc:
    def finish_selected_copy_reference_fill! : Nil
      @copy_reference_path_count.times do |path_index|
        base = path_index * 3
        unless @copy_reference_ranges[base + 2] == @copy_reference_ranges[base + 1]
          raise CorruptPartError.new("Compact JSON selected Copy reference count differs from its index lane")
        end
      end
      nil
    end

    # :nodoc:
    def selected_copy_reference_path_count : Int32
      @copy_reference_path_count
    end

    # :nodoc:
    def selected_copy_references_for_path(path_index : Int32) : Slice(CompactJsonCopyReference)
      if path_index < 0 || path_index >= @copy_reference_path_count
        raise CorruptPartError.new("Compact JSON selected Copy path index is outside its ledger")
      end
      base = path_index * 3
      start = @copy_reference_ranges[base]
      count = @copy_reference_ranges[base + 1]
      if start < 0 || count < 0 || start > @copy_reference_slab.size || count > @copy_reference_slab.size - start
        raise CorruptPartError.new("Compact JSON selected Copy path range exceeds its reference slab")
      end
      Slice.new(@copy_reference_slab.to_unsafe + start, count, read_only: true)
    end

    # :nodoc:
    # End source-coordinate appending after every decoder validates the full
    # mark. The callback retains the packed window only.
    def finish_selected_mark! : Nil
      return nil unless @selected_source_rows_active
      @mark_row_count = @row_count
      @selected_source_row_count = 0_i32
      @selected_source_rows_active = false
      @columns.each { |column| column.set_window!(0_i32, @row_count) }
      validate_workspace!
      nil
    end

    # :nodoc:
    def append_value!(path : String, row : Int, value : BinaryValue) : Bool
      if row < 0 || row >= @mark_row_count
        raise CorruptPartError.new("Compact JSON columnar value row is outside its mark")
      end
      column = @columns_by_path[path]? || raise(CorruptPartError.new("Compact JSON decoder emitted a path outside its sealed plan roster"))
      append_column_value!(column, row, value)
    end

    # :nodoc:
    # The decoder resolves each path before walking its cells. A caller can
    # include the scratch space it holds while filling the column.
    def append_column_value!(
      column : CompactJsonColumnarColumn,
      row : Int,
      value : BinaryValue,
      additional_workspace_bytes : UInt64 = 0_u64,
    ) : Bool
      append_column_cell!(column, row, CompactJsonColumnarCell.owned(value), additional_workspace_bytes)
    end

    # :nodoc:
    # Retain a cell representation directly, including a read-only String
    # span from a prepared lane.
    def append_column_cell!(
      column : CompactJsonColumnarColumn,
      row : Int,
      value : CompactJsonColumnarCell,
      additional_workspace_bytes : UInt64 = 0_u64,
    ) : Bool
      if row < 0 || row >= @mark_row_count
        raise CorruptPartError.new("Compact JSON columnar value row is outside its mark")
      end
      destination_row = selected_output_row(row) || return false
      prior = column.last_cell_at(destination_row)
      inserted = column.append_cell!(destination_row, value)
      @column_buffer_bytes = checked_add(@column_buffer_bytes, column.account_buffer_high_water_cells!)
      if inserted
        @cell_count += 1_u64
      elsif previous = prior
        previous_bytes = columnar_cell_workspace_bytes(previous)
        if previous_bytes > @cell_payload_bytes
          raise CorruptPartError.new("Compact JSON column payload accounting underflows")
        end
        @cell_payload_bytes -= previous_bytes
      end
      @cell_payload_bytes = checked_add(@cell_payload_bytes, columnar_cell_workspace_bytes(value))
      if @cell_count > @max_cells
        raise CorruptPartError.new("Compact JSON columnar output exceeds the codec element bound")
      end
      validate_workspace!(additional_workspace_bytes)
      inserted
    end

    # :nodoc:
    def fill_uint64_column!(name : String, encoded : Bytes, expected_rows : UInt64) : Nil
      values = @uint64_columns[name]? || raise(CorruptPartError.new("Compact JSON decoder emitted an unselected UInt64 companion"))
      unless expected_rows == @mark_row_count.to_u64 && encoded.size.to_u64 == expected_rows * 8_u64
        raise CorruptPartError.new("Compact JSON UInt64 companion mark has the wrong byte extent")
      end
      values.clear
      companion_index = @companion_names.index(name) || raise(CorruptPartError.new("Compact JSON companion index is missing"))
      previous_high_water = @companion_high_water_rows[companion_index]
      output_rows = @selected_source_rows_active ? @row_count.to_u64 : expected_rows
      if output_rows > previous_high_water
        @companion_high_water_rows[companion_index] = output_rows
        delta_rows = output_rows - previous_high_water
        @companion_buffer_bytes = checked_add(@companion_buffer_bytes,
          checked_multiply(delta_rows, sizeof(UInt64).to_u64))
      end
      offset = 0
      expected_rows.to_i.times do |source_row|
        if destination_row = selected_output_row(source_row)
          unless destination_row == values.size
            raise CorruptPartError.new("Compact JSON selected UInt64 companion rows are not dense")
          end
          decoded = 0_u64
          8.times do |byte_index|
            decoded |= encoded[offset + byte_index].to_u64 << (byte_index * 8)
          end
          values << decoded
        end
        offset += 8
      end
      @companion_columns_filled += 1_i32
      finish_companion_fill! if @companion_columns_filled == @companion_names.size
      check_workspace!(retained_workspace_bytes)
      nil
    end

    # :nodoc:
    def set_window!(start : Int, count : Int, mark_row_offset : UInt64, part_row_offset : UInt64, source_row_offset : UInt64) : Nil
      if start < 0 || count < 0 || start > @mark_row_count || count > @mark_row_count - start
        raise CorruptPartError.new("Compact JSON callback window exceeds its retained mark")
      end
      @window_start = start.to_i32
      @row_count = count.to_i32
      @mark_row_offset = mark_row_offset
      @part_row_offset = part_row_offset
      @source_row_offset = source_row_offset
      @columns.each { |column| column.set_window!(@window_start, @row_count) }
      nil
    end

    # :nodoc:
    def set_location!(
      part_index : Int,
      part_name : String,
      part_path : String,
      mark_index : Int,
      mark_row_offset : UInt64,
      part_row_offset : UInt64,
      source_row_offset : UInt64,
    ) : Nil
      @part_index = part_index.to_i32
      @part_name = String.new(part_name.to_slice)
      @part_path = String.new(part_path.to_slice)
      @mark_index = mark_index.to_i32
      @mark_row_offset = mark_row_offset
      @part_row_offset = part_row_offset
      @source_row_offset = source_row_offset
      nil
    end

    # :nodoc:
    def retained_workspace_bytes : UInt64
      companion_bytes = Math.max(@companion_buffer_bytes, @companion_reserved_bytes)
      selection_bytes = checked_multiply(@selected_output_rows.size.to_u64, sizeof(Int32).to_u64)
      copy_reference_bytes = checked_multiply(
        @copy_reference_slab.size.to_u64,
        sizeof(CompactJsonCopyReference).to_u64,
      )
      copy_reference_range_bytes = checked_multiply(
        @copy_reference_ranges.size.to_u64,
        sizeof(Int32).to_u64,
      )
      scratch_bytes = checked_add(selection_bytes,
        checked_add(copy_reference_bytes, copy_reference_range_bytes))
      checked_add(@workspace_header_bytes,
        checked_add(scratch_bytes,
          checked_add(@column_buffer_bytes, checked_add(companion_bytes, @cell_payload_bytes))))
    end

    # :nodoc:
    def validate_workspace!(additional_bytes : UInt64 = 0_u64) : Nil
      check_workspace!(checked_add(retained_workspace_bytes, additional_bytes))
      nil
    end

    # :nodoc:
    # Used only by `snapshot` to append the already-decoded retained values.
    def uint64_values_for_snapshot(name : String) : Array(UInt64)
      @uint64_columns[name]? || raise(KeyError.new("Compact JSON UInt64 companion not found"))
    end

    # :nodoc:
    # Count a dense native lane copied by a column snapshot; its source cells
    # already have an exact one-per-row representation and need no row-index
    # or CompactJsonColumnarCell placeholders.
    def note_nullable_uint32_snapshot_fill!(rows : Int) : Nil
      if rows < 0 || @cell_count > UInt64::MAX - rows.to_u64 || @cell_count + rows.to_u64 > @max_cells
        raise CorruptPartError.new("Compact JSON snapshot exceeds the codec element bound")
      end
      @cell_count += rows.to_u64
      validate_workspace!
      nil
    end

    # :nodoc:
    def finish_companion_fill! : Nil
      @companion_names.each_with_index do |name, index|
        current_rows = @uint64_columns[name].size.to_u64
        previous_high_water = @companion_high_water_rows[index]
        if current_rows > previous_high_water
          @companion_high_water_rows[index] = current_rows
          delta_rows = current_rows - previous_high_water
          @companion_buffer_bytes = checked_add(@companion_buffer_bytes,
            checked_multiply(delta_rows, sizeof(UInt64).to_u64))
        end
      end
      @companion_reserved_bytes = 0_u64
      @companion_columns_filled = @companion_names.size.to_i32
      check_workspace!(retained_workspace_bytes)
      nil
    end

    private def calculate_header_workspace_bytes(
      paths : Array(String),
      companion_columns : Array(String),
      fallback_types : Hash(String, BinaryDataType),
      max_rows : Int,
    ) : UInt64
      bytes = instance_sizeof(CompactJsonColumnarBatch).to_u64
      bytes = checked_add(bytes, instance_sizeof(Array(CompactJsonColumnarColumn)).to_u64)
      bytes = checked_add(bytes, checked_multiply(paths.size.to_u64, sizeof(Pointer(CompactJsonColumnarColumn)).to_u64))
      bytes = checked_add(bytes, instance_sizeof(Hash(String, CompactJsonColumnarColumn)).to_u64)
      bytes = checked_add(bytes, instance_sizeof(Hash(String, Array(UInt64))).to_u64)
      bytes = checked_add(bytes, instance_sizeof(Array(String)).to_u64)
      bytes = checked_add(bytes, checked_multiply(companion_columns.size.to_u64, sizeof(Pointer(String)).to_u64))
      bytes = checked_add(bytes, instance_sizeof(Array(UInt64)).to_u64)
      bytes = checked_add(bytes, checked_multiply(companion_columns.size.to_u64, sizeof(UInt64).to_u64))
      # Account for hash slots and key references in both path maps. This is a
      # conservative logical owner estimate, not allocator-capacity/RSS.
      bytes = checked_add(bytes,
        checked_multiply(paths.size.to_u64, (64 + sizeof(Pointer(String)) * 2).to_u64))
      bytes = checked_add(bytes,
        checked_multiply(companion_columns.size.to_u64, (64 + sizeof(Pointer(String)) * 2).to_u64))
      lane_bytes = checked_multiply(max_rows.to_u64, (sizeof(UInt32) + sizeof(UInt8)).to_u64)
      paths.each do |path|
        bytes = checked_add(bytes, instance_sizeof(CompactJsonColumnarColumn).to_u64)
        bytes = checked_add(bytes, string_owner_bytes(path))
        bytes = checked_add(bytes, instance_sizeof(Array(Int32)).to_u64)
        bytes = checked_add(bytes, instance_sizeof(Array(CompactJsonColumnarCell)).to_u64)
        if type = fallback_types[path]?
          if CompactJsonColumnarColumn.nullable_uint32_type?(type)
            bytes = checked_add(bytes, lane_bytes)
          end
        end
      end
      companion_columns.each do |name|
        bytes = checked_add(bytes, string_owner_bytes(name))
        bytes = checked_add(bytes, instance_sizeof(Array(UInt64)).to_u64)
      end
      bytes
    end

    private def compact_selected_nullable_uint32!(column : CompactJsonColumnarColumn) : Nil
      destination_rows = Slice.new(@selected_output_rows.to_unsafe, @selected_source_row_count, read_only: true)
      column.retain_nullable_uint32_rows!(destination_rows, @selected_source_row_count)
      nil
    end

    private def check_workspace!(bytes : UInt64) : Nil
      if bytes > @workspace_limit
        raise CorruptPartError.new("Compact JSON columnar output exceeds the aggregate materialization limit")
      end
      nil
    end

    private def string_owner_bytes(value : String) : UInt64
      checked_add(instance_sizeof(String).to_u64, value.bytesize.to_u64 + 1_u64)
    end

    private def binary_value_workspace_bytes(value : BinaryValue) : UInt64
      bytes = checked_add(instance_sizeof(BinaryValue).to_u64,
        checked_add(instance_sizeof(Array(BinaryValue)).to_u64, value.byte_size.to_u64))
      bytes = checked_add(bytes, checked_multiply(value.element_count.to_u64, sizeof(Pointer(BinaryValue)).to_u64))
      value.element_count.times do |index|
        bytes = checked_add(bytes, binary_value_workspace_bytes(value.element_at(index)))
      end
      if value.type.tag == BinaryDataType::TAG_JSON
        row = value.json_row
        bytes = checked_add(bytes, instance_sizeof(BinaryJsonRow).to_u64)
        bytes = checked_add(bytes, checked_multiply(row.path_count.to_u64,
          sizeof(Pointer(String)).to_u64 + sizeof(Pointer(BinaryValue)).to_u64))
        row.path_count.times do |index|
          bytes = checked_add(bytes,
            instance_sizeof(String).to_u64 + row.path_byte_size(index).to_u64 + 1_u64)
          bytes = checked_add(bytes, binary_value_workspace_bytes(row.value_at(index)))
        end
      end
      bytes
    end

    private def columnar_cell_workspace_bytes(value : CompactJsonColumnarCell) : UInt64
      # Borrowed String payload bytes are charged to their prepared input lane.
      # The output retains only its inline slice slot.
      value.owned_value?.try { |owned| binary_value_workspace_bytes(owned) } || 0_u64
    end

    private def projected_companion_buffer_bytes(required_rows : Int) : UInt64
      required = required_rows.to_u64
      total = 0_u64
      @companion_high_water_rows.each do |high_water_rows|
        slots = Math.max(high_water_rows, required)
        total = checked_add(total, checked_multiply(slots, sizeof(UInt64).to_u64))
      end
      total
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      raise CorruptPartError.new("Compact JSON columnar workspace overflows") if right > UInt64::MAX - left
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      raise CorruptPartError.new("Compact JSON columnar workspace overflows") if left > 0_u64 && right > UInt64::MAX // left
      left * right
    end
  end
end
