module CrystalClick
  # Reusable borrowed output arena for one Compact Advanced root JSON scan.
  # Column wrappers and value buffers survive mark resets. Path cells are
  # sparse, while selected UInt64 companions use retained dense arrays.
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
        column = CompactJsonColumnarColumn.new(String.new(path.to_slice), fallback_type)
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
      @cell_count = 0_u64
      @cell_payload_bytes = 0_u64
      @column_buffer_bytes = 0_u64
      @companion_buffer_bytes = 0_u64
      @companion_reserved_bytes = 0_u64
      @companion_columns_filled = 0_i32
      @workspace_header_bytes = calculate_header_workspace_bytes
      check_workspace!(@workspace_header_bytes)
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
        column.each_active_cell do |row, value|
          copy.append_value!(column.path, row - @window_start, value)
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
      @cell_count = 0_u64
      @cell_payload_bytes = 0_u64
      @companion_reserved_bytes = projected_companion_buffer_bytes(mark_rows.to_i)
      @companion_columns_filled = 0_i32
      check_workspace!(retained_workspace_bytes)
      @columns.each { |column| column.set_window!(0_i32, @row_count) }
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
    # Retain a cell representation directly. The Copy String path uses this
    # overload to keep its read-only lane span inline instead of copying it
    # into a BinaryValue payload.
    def append_column_cell!(
      column : CompactJsonColumnarColumn,
      row : Int,
      value : CompactJsonColumnarCell,
      additional_workspace_bytes : UInt64 = 0_u64,
    ) : Bool
      if row < 0 || row >= @mark_row_count
        raise CorruptPartError.new("Compact JSON columnar value row is outside its mark")
      end
      prior = column.last_cell_at(row.to_i32)
      inserted = column.append_cell!(row.to_i32, value)
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
      if expected_rows > previous_high_water
        @companion_high_water_rows[companion_index] = expected_rows
        delta_rows = expected_rows - previous_high_water
        @companion_buffer_bytes = checked_add(@companion_buffer_bytes,
          checked_multiply(delta_rows, sizeof(UInt64).to_u64))
      end
      offset = 0
      expected_rows.to_i.times do
        decoded = 0_u64
        8.times do |byte_index|
          decoded |= encoded[offset + byte_index].to_u64 << (byte_index * 8)
        end
        values << decoded
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
      checked_add(@workspace_header_bytes,
        checked_add(@column_buffer_bytes, checked_add(companion_bytes, @cell_payload_bytes)))
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

    private def calculate_header_workspace_bytes : UInt64
      bytes = instance_sizeof(CompactJsonColumnarBatch).to_u64
      bytes = checked_add(bytes, instance_sizeof(Array(CompactJsonColumnarColumn)).to_u64)
      bytes = checked_add(bytes, checked_multiply(@columns.size.to_u64, sizeof(Pointer(CompactJsonColumnarColumn)).to_u64))
      bytes = checked_add(bytes, instance_sizeof(Hash(String, CompactJsonColumnarColumn)).to_u64)
      bytes = checked_add(bytes, instance_sizeof(Hash(String, Array(UInt64))).to_u64)
      bytes = checked_add(bytes, instance_sizeof(Array(String)).to_u64)
      bytes = checked_add(bytes, checked_multiply(@companion_names.size.to_u64, sizeof(Pointer(String)).to_u64))
      bytes = checked_add(bytes, instance_sizeof(Array(UInt64)).to_u64)
      bytes = checked_add(bytes, checked_multiply(@companion_high_water_rows.size.to_u64, sizeof(UInt64).to_u64))
      # Account for hash slots and key references in both path maps. This is a
      # conservative logical owner estimate, not allocator-capacity/RSS.
      bytes = checked_add(bytes,
        checked_multiply(@columns.size.to_u64, (64 + sizeof(Pointer(String)) * 2).to_u64))
      bytes = checked_add(bytes,
        checked_multiply(@companion_names.size.to_u64, (64 + sizeof(Pointer(String)) * 2).to_u64))
      @columns.each do |column|
        bytes = checked_add(bytes, instance_sizeof(CompactJsonColumnarColumn).to_u64)
        bytes = checked_add(bytes, string_owner_bytes(column.path))
        bytes = checked_add(bytes, instance_sizeof(Array(Int32)).to_u64)
        bytes = checked_add(bytes, instance_sizeof(Array(CompactJsonColumnarCell)).to_u64)
      end
      @companion_names.each do |name|
        bytes = checked_add(bytes, string_owner_bytes(name))
        bytes = checked_add(bytes, instance_sizeof(Array(UInt64)).to_u64)
      end
      bytes
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
      # Borrowed String payload bytes already belong to the prepared Copy lane
      # and are charged there. The output retains only its inline slice slot.
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
