module CrystalClick
  # Bounded selected-range schedule for ragged Map rows. It retains only
  # cumulative outer-row and flattened-entry boundaries; per-row size0 data is
  # discarded after the selected marks have been checked.
  class WideMapTupleSchedule
    @row_prefixes : Array(UInt64)
    @entry_prefixes : Array(UInt64)
    @key_string_byte_prefixes : Array(UInt64)

    private def initialize(
      @row_prefixes : Array(UInt64),
      @entry_prefixes : Array(UInt64),
      @key_string_byte_prefixes : Array(UInt64),
    )
      unless @row_prefixes.size == @entry_prefixes.size &&
             @row_prefixes.size == @key_string_byte_prefixes.size &&
             !@row_prefixes.empty? && @row_prefixes.first == 0_u64 &&
             @entry_prefixes.first == 0_u64 && @key_string_byte_prefixes.first == 0_u64
        raise ArgumentError.new("Map(Tuple) schedule prefixes are invalid")
      end
      index = 1
      while index < @row_prefixes.size
        raise ArgumentError.new("Map(Tuple) row prefix decreases") if @row_prefixes[index] < @row_prefixes[index - 1]
        raise ArgumentError.new("Map(Tuple) entry prefix decreases") if @entry_prefixes[index] < @entry_prefixes[index - 1]
        if @key_string_byte_prefixes[index] < @key_string_byte_prefixes[index - 1]
          raise ArgumentError.new("Map(Tuple) key byte prefix decreases")
        end
        index += 1
      end
    end

    def self.logical_charge_for_mark_count(mark_count : Int) : UInt64?
      return nil if mark_count < 0 || mark_count >= Int32::MAX
      slots = mark_count.to_u64 + 1_u64
      fixed = instance_sizeof(WideMapTupleSchedule).to_u64
      header = instance_sizeof(Array(UInt64)).to_u64
      return nil if header > (UInt64::MAX - fixed) // 3_u64
      fixed += header * 3_u64
      return nil if slots > UInt64::MAX // (sizeof(UInt64).to_u64 * 3_u64)
      slot_bytes = slots * sizeof(UInt64).to_u64 * 3_u64
      return nil if slot_bytes > UInt64::MAX - fixed
      fixed + slot_bytes
    end

    def self.build(mark_count : Int, max_logical_charge : UInt64, & : Int32 -> {Int32, Int32, UInt64}) : WideMapTupleSchedule
      charge = logical_charge_for_mark_count(mark_count) ||
               raise(CorruptPartError.new("Map(Tuple) schedule charge overflows"))
      if charge > max_logical_charge
        raise(CorruptPartError.new("Map(Tuple) schedule charge exceeds per-range limit"))
      end

      prefix_size = mark_count + 1
      row_prefixes = Array(UInt64).new(prefix_size, 0_u64)
      entry_prefixes = Array(UInt64).new(prefix_size, 0_u64)
      key_string_byte_prefixes = Array(UInt64).new(prefix_size, 0_u64)
      rows = 0_u64
      entries = 0_u64
      key_string_bytes = 0_u64
      mark_count.to_i32.times do |index|
        row_count, entry_count, mark_key_string_bytes = yield index
        if row_count < 0 || entry_count < 0
          raise CorruptPartError.new("Map(Tuple) mark schedule count is negative")
        end
        if row_count.to_u64 > UInt64::MAX - rows || entry_count.to_u64 > UInt64::MAX - entries ||
           mark_key_string_bytes > UInt64::MAX - key_string_bytes
          raise CorruptPartError.new("Map(Tuple) selected schedule count overflows")
        end
        rows += row_count.to_u64
        entries += entry_count.to_u64
        key_string_bytes += mark_key_string_bytes
        row_prefixes[index + 1] = rows
        entry_prefixes[index + 1] = entries
        key_string_byte_prefixes[index + 1] = key_string_bytes
      end
      new(row_prefixes, entry_prefixes, key_string_byte_prefixes)
    end

    def mark_count : Int32
      (@row_prefixes.size - 1).to_i32
    end

    def outer_rows : UInt64
      @row_prefixes.last
    end

    def entries : UInt64
      @entry_prefixes.last
    end

    def key_string_bytes : UInt64
      @key_string_byte_prefixes.last
    end

    def outer_rows_in(first_mark : Int, mark_count : Int) : UInt64
      start_index, end_index = checked_range(first_mark, mark_count)
      @row_prefixes[end_index] - @row_prefixes[start_index]
    end

    def entries_in(first_mark : Int, mark_count : Int) : UInt64
      start_index, end_index = checked_range(first_mark, mark_count)
      @entry_prefixes[end_index] - @entry_prefixes[start_index]
    end

    def key_string_bytes_in(first_mark : Int, mark_count : Int) : UInt64
      start_index, end_index = checked_range(first_mark, mark_count)
      @key_string_byte_prefixes[end_index] - @key_string_byte_prefixes[start_index]
    end

    def outer_row_offset(mark_index : Int) : UInt64
      @row_prefixes[checked_boundary(mark_index)]
    end

    def entry_offset(mark_index : Int) : UInt64
      @entry_prefixes[checked_boundary(mark_index)]
    end

    def key_string_bytes_at(mark_index : Int) : UInt64
      index = checked_mark(mark_index)
      @key_string_byte_prefixes[index + 1] - @key_string_byte_prefixes[index]
    end

    def row_count_at(mark_index : Int) : Int32
      index = checked_mark(mark_index)
      (@row_prefixes[index + 1] - @row_prefixes[index]).to_i32
    end

    def entry_count_at(mark_index : Int) : Int32
      index = checked_mark(mark_index)
      count = @entry_prefixes[index + 1] - @entry_prefixes[index]
      raise ArgumentError.new("Map(Tuple) mark entry count exceeds the supported range") if count > Int32::MAX
      count.to_i32
    end

    def logical_charge : UInt64
      self.class.logical_charge_for_mark_count(mark_count) ||
        raise ArgumentError.new("Map(Tuple) schedule charge overflows")
    end

    private def checked_mark(mark_index : Int) : Int32
      raise BoundsError.new("Map(Tuple) schedule mark index is out of bounds") if mark_index < 0 || mark_index >= mark_count
      mark_index.to_i32
    end

    private def checked_boundary(mark_index : Int) : Int32
      raise BoundsError.new("Map(Tuple) schedule boundary is out of bounds") if mark_index < 0 || mark_index > mark_count
      mark_index.to_i32
    end

    private def checked_range(first_mark : Int, mark_count : Int) : {Int32, Int32}
      raise BoundsError.new("Map(Tuple) schedule range is invalid") if first_mark < 0 || mark_count < 0
      raise BoundsError.new("Map(Tuple) schedule range is invalid") if first_mark > self.mark_count || mark_count > self.mark_count - first_mark
      {first_mark.to_i32, (first_mark + mark_count).to_i32}
    end
  end
end
