module CrystalClick
  # One bounded Array edge's complete mark schedule. Physical rows stay rooted
  # at the enclosing part marks; parent_rows describe this Array's input axis,
  # and child_rows are derived from its per-parent sizes. Nested Arrays create
  # another frame rather than replacing the root physical-row coordinates.
  class StorageArrayOccurrenceFrame
    @array_level : UInt64
    @parent_grid : StorageOccurrenceGrid
    @child_grid : StorageOccurrenceGrid
    @size_stream : BinaryBulkStream

    def self.for_write(
      array_level : UInt64,
      physical_rows : Array(UInt64),
      parent_rows : Array(UInt64),
      sizes_by_mark : Array(Array(UInt64)),
      budget : BinaryCodecBudget,
    ) : StorageArrayOccurrenceFrame
      new(array_level, physical_rows, parent_rows, sizes_by_mark, nil, budget, true)
    end

    # Writer path that derives sizes from caller values after preflighting the
    # complete Q/C schedule, without first allocating a duplicate size grid.
    def self.for_write_values(
      array_level : UInt64,
      physical_rows : Array(UInt64),
      parent_rows : Array(UInt64),
      values_by_mark : Array(Array(StorageColumnValue)),
      budget : BinaryCodecBudget,
    ) : StorageArrayOccurrenceFrame
      new(array_level, physical_rows, parent_rows, nil, values_by_mark, budget, true)
    end

    def self.for_read(
      array_level : UInt64,
      physical_rows : Array(UInt64),
      parent_rows : Array(UInt64),
      sizes_by_mark : Array(Array(UInt64)),
      budget : BinaryCodecBudget,
    ) : StorageArrayOccurrenceFrame
      new(array_level, physical_rows, parent_rows, sizes_by_mark, nil, budget, false)
    end

    private def initialize(
      @array_level : UInt64,
      physical_rows : Array(UInt64),
      parent_rows : Array(UInt64),
      sizes_by_mark : Array(Array(UInt64))?,
      values_by_mark : Array(Array(StorageColumnValue))?,
      budget : BinaryCodecBudget,
      writing : Bool,
    )
      unless budget.writing? == writing
        fail_schedule!(writing, "Array occurrence budget has the wrong direction")
      end

      mark_count = physical_rows.size
      if sizes_by_mark.nil? == values_by_mark.nil?
        fail_schedule!(writing, "Array occurrence frame requires exactly one complete schedule source")
      end
      source_mark_count = if schedules = sizes_by_mark
                            schedules.size
                          else
                            values_by_mark.not_nil!.size
                          end
      unless mark_count > 0 && mark_count <= StorageOccurrenceGrid::MAX_MARK_COUNT &&
             parent_rows.size == mark_count && source_mark_count == mark_count
        fail_schedule!(writing, "Array occurrence schedule does not match the complete part mark grid")
      end

      total_parents = 0_u64
      total_children = 0_u64
      total_size_bytes = 0_u64

      # Derive every count and validate the caller's complete schedule before
      # allocating a flattened size vector, byte lane, offset grid, or child
      # occurrence grid. A same-total redistribution inside a mark is valid:
      # the size vector defines the Array value, not merely its mark total.
      mark_count.times do |mark|
        physical = physical_rows[mark]
        parents = parent_rows[mark]
        unless physical > 0_u64 && physical <= Int32::MAX.to_u64
          fail_schedule!(writing, "Array physical mark rows are outside the supported domain")
        end
        source_parent_count = source_parent_count_at(mark, sizes_by_mark, values_by_mark)
        unless parents <= Int32::MAX.to_u64 && source_parent_count == parents
          fail_schedule!(writing, "Array size count differs from its inherited parent occurrence grid")
        end
        children = 0_u64
        parent_index = 0
        while parent_index.to_u64 < parents
          size = source_size_at(mark, parent_index, sizes_by_mark, values_by_mark, writing)
          if size > Int32::MAX.to_u64
            fail_schedule!(writing, "Array child size exceeds the supported row domain")
          end
          children = checked_add(children, size, writing)
          parent_index += 1
        end
        if children > Int32::MAX.to_u64
          fail_schedule!(writing, "Array child occurrences per mark exceed the supported row domain")
        end
        total_parents = checked_add(total_parents, parents, writing)
        total_children = checked_add(total_children, children, writing)
        total_size_bytes = checked_add(total_size_bytes, checked_multiply(parents, 8_u64, writing), writing)
        if total_parents > Int32::MAX.to_u64 || total_children > Int32::MAX.to_u64 ||
           total_size_bytes > Int32::MAX.to_u64
          fail_schedule!(writing, "Array occurrence schedule exceeds the supported flattened domain")
        end
      end

      # The frame retains one size value per input parent, K+1 byte offsets,
      # and two complete occurrence grids. Preflight all of them together so a
      # late grid limit cannot follow earlier proportional schedule copies.
      schedule_records = checked_add(total_parents, mark_count.to_u64 + 1_u64, writing)
      grid_records = checked_multiply(mark_count.to_u64, 4_u64, writing)
      retained_records = checked_add(schedule_records, grid_records, writing)
      budget.ensure_future_nodes(retained_records)
      budget.ensure_future_elements(retained_records)
      budget.ensure_wire_bytes(total_size_bytes)

      (total_parents + mark_count.to_u64 + 1_u64).times { budget.charge_node }
      budget.charge_elements(schedule_records)
      budget.charge_wire_bytes(total_size_bytes)

      child_rows = Array(UInt64).new(mark_count)
      mark_count.times do |mark|
        children = 0_u64
        parent_index = 0
        while parent_index.to_u64 < parent_rows[mark]
          size = source_size_at(mark, parent_index, sizes_by_mark, values_by_mark, writing)
          children = checked_add(children, size, writing)
          parent_index += 1
        end
        child_rows << children
      end

      bytes = Bytes.new(total_size_bytes.to_i)
      byte_offsets = Array(UInt64).new(mark_count + 1)
      byte_offsets << 0_u64
      cursor = 0_u64
      mark_count.times do |mark|
        parent_index = 0
        while parent_index.to_u64 < parent_rows[mark]
          size = source_size_at(mark, parent_index, sizes_by_mark, values_by_mark, writing)
          8.times do |index|
            bytes[cursor.to_i] = ((size >> (index * 8)) & 0xff).to_u8
            cursor += 1_u64
          end
          parent_index += 1
        end
        byte_offsets << cursor
      end
      unless cursor == total_size_bytes
        fail_schedule!(writing, "Array size lane changed after its complete schedule preflight")
      end

      @parent_grid = StorageOccurrenceGrid.new(physical_rows, parent_rows, budget)
      @child_grid = StorageOccurrenceGrid.new(physical_rows, child_rows, budget)
      @size_stream = BinaryBulkStream.new(bytes, byte_offsets)
    end

    def array_level : UInt64
      @array_level
    end

    # `parent_grid` is P→Q for this edge; `child_grid` is P→C. Both retain
    # the root physical rows even when this frame is nested under another Array.
    def parent_grid : StorageOccurrenceGrid
      @parent_grid
    end

    def child_grid : StorageOccurrenceGrid
      @child_grid
    end

    def mark_count : Int32
      @parent_grid.mark_count
    end

    def physical_rows_at(mark : Int) : UInt64
      @parent_grid.physical_rows_at(mark)
    end

    def parent_count_at(mark : Int) : UInt64
      @parent_grid.logical_occurrences_at(mark)
    end

    def child_count_at(mark : Int) : UInt64
      @child_grid.logical_occurrences_at(mark)
    end

    def size_stream : BinaryBulkStream
      @size_stream
    end

    def size_offsets : Array(UInt64)
      @size_stream.offsets
    end

    def size_at(mark : Int, parent_index : Int) : UInt64
      parent_count = parent_count_at(mark)
      if parent_index < 0 || parent_index.to_u64 >= parent_count
        raise IndexError.new("Array parent index is outside the occurrence frame")
      end
      offset = @size_stream.offset_at(mark) + parent_index.to_u64 * 8_u64
      value = 0_u64
      8.times do |index|
        value |= @size_stream.byte_at((offset + index.to_u64).to_i).to_u64 << (index * 8)
      end
      value
    end

    private def checked_add(left : UInt64, right : UInt64, writing : Bool) : UInt64
      total = left.to_u128 + right.to_u128
      if total > UInt64::MAX.to_u128
        fail_schedule!(writing, "Array occurrence count overflows UInt64")
      end
      total.to_u64
    end

    private def checked_multiply(left : UInt64, right : UInt64, writing : Bool) : UInt64
      product = left.to_u128 * right.to_u128
      if product > UInt64::MAX.to_u128
        fail_schedule!(writing, "Array occurrence byte count overflows UInt64")
      end
      product.to_u64
    end

    private def source_parent_count_at(
      mark : Int,
      sizes_by_mark : Array(Array(UInt64))?,
      values_by_mark : Array(Array(StorageColumnValue))?,
    ) : UInt64
      if schedules = sizes_by_mark
        schedules[mark].size.to_u64
      else
        values_by_mark.not_nil![mark].size.to_u64
      end
    end

    private def source_size_at(
      mark : Int,
      parent_index : Int,
      sizes_by_mark : Array(Array(UInt64))?,
      values_by_mark : Array(Array(StorageColumnValue))?,
      writing : Bool,
    ) : UInt64
      if schedules = sizes_by_mark
        schedules[mark][parent_index]
      else
        value = values_by_mark.not_nil![mark][parent_index]
        unless value.array?
          fail_schedule!(writing, "Array occurrence source contains a non-Array value")
        end
        value.child_count.to_u64
      end
    end

    private def fail_schedule!(writing : Bool, message : String) : NoReturn
      if writing
        raise UnsupportedFormatError.new(message)
      else
        raise CorruptPartError.new(message)
      end
    end
  end
end
