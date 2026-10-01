module CrystalClick
  # Bounded selected-range schedule for ragged Array rows. It retains only
  # cumulative per-mark outer-row and flattened-element boundaries; each
  # mark's individual .size0 vector is discarded after validation.
  class WideArrayTupleSchedule
    @row_prefixes : Array(UInt64)
    @element_prefixes : Array(UInt64)

    private def initialize(@row_prefixes : Array(UInt64), @element_prefixes : Array(UInt64))
      unless @row_prefixes.size == @element_prefixes.size && !@row_prefixes.empty? &&
             @row_prefixes.first == 0_u64 && @element_prefixes.first == 0_u64
        raise ArgumentError.new("Array(Tuple) schedule prefixes are invalid")
      end
      index = 1
      while index < @row_prefixes.size
        raise ArgumentError.new("Array(Tuple) row prefix decreases") if @row_prefixes[index] < @row_prefixes[index - 1]
        raise ArgumentError.new("Array(Tuple) element prefix decreases") if @element_prefixes[index] < @element_prefixes[index - 1]
        index += 1
      end
    end

    # Estimate retained schedule bytes before allocating any prefix array or
    # collecting selected .size0 values.
    def self.logical_charge_for_mark_count(mark_count : Int) : UInt64?
      return nil if mark_count < 0 || mark_count >= Int32::MAX
      slots = mark_count.to_u64 + 1_u64
      fixed = instance_sizeof(WideArrayTupleSchedule).to_u64
      header = instance_sizeof(Array(UInt64)).to_u64
      return nil if header > (UInt64::MAX - fixed) // 2_u64
      fixed += header * 2_u64
      return nil if slots > UInt64::MAX // (sizeof(UInt64).to_u64 * 2_u64)
      slot_bytes = slots * sizeof(UInt64).to_u64 * 2_u64
      return nil if slot_bytes > UInt64::MAX - fixed
      fixed + slot_bytes
    end

    def self.build(mark_count : Int, max_logical_charge : UInt64, & : Int32 -> {Int32, Int32}) : WideArrayTupleSchedule
      charge = logical_charge_for_mark_count(mark_count) ||
               raise(CorruptPartError.new("Array(Tuple) schedule charge overflows"))
      if charge > max_logical_charge
        raise CorruptPartError.new("Array(Tuple) schedule charge exceeds per-range limit")
      end

      prefix_size = mark_count + 1
      row_prefixes = Array(UInt64).new(prefix_size, 0_u64)
      element_prefixes = Array(UInt64).new(prefix_size, 0_u64)
      rows = 0_u64
      elements = 0_u64
      mark_count.to_i32.times do |index|
        row_count, element_count = yield index
        if row_count < 0 || element_count < 0
          raise CorruptPartError.new("Array(Tuple) mark schedule count is negative")
        end
        if row_count.to_u64 > UInt64::MAX - rows || element_count.to_u64 > UInt64::MAX - elements
          raise CorruptPartError.new("Array(Tuple) selected schedule count overflows")
        end
        rows += row_count.to_u64
        elements += element_count.to_u64
        row_prefixes[index + 1] = rows
        element_prefixes[index + 1] = elements
      end
      new(row_prefixes, element_prefixes)
    end

    def mark_count : Int32
      (@row_prefixes.size - 1).to_i32
    end

    def outer_rows : UInt64
      @row_prefixes.last
    end

    def elements : UInt64
      @element_prefixes.last
    end

    def outer_rows_in(first_mark : Int, mark_count : Int) : UInt64
      start_index, end_index = checked_range(first_mark, mark_count)
      @row_prefixes[end_index] - @row_prefixes[start_index]
    end

    def elements_in(first_mark : Int, mark_count : Int) : UInt64
      start_index, end_index = checked_range(first_mark, mark_count)
      @element_prefixes[end_index] - @element_prefixes[start_index]
    end

    def outer_row_offset(mark_index : Int) : UInt64
      @row_prefixes[checked_boundary(mark_index)]
    end

    def element_offset(mark_index : Int) : UInt64
      @element_prefixes[checked_boundary(mark_index)]
    end

    def row_count_at(mark_index : Int) : Int32
      index = checked_mark(mark_index)
      (@row_prefixes[index + 1] - @row_prefixes[index]).to_i32
    end

    def element_count_at(mark_index : Int) : Int32
      index = checked_mark(mark_index)
      count = @element_prefixes[index + 1] - @element_prefixes[index]
      raise ArgumentError.new("Array(Tuple) mark element count exceeds the supported range") if count > Int32::MAX.to_u64
      count.to_i32
    end

    # Logical retained schedule charge: this owner plus two prefix Array
    # headers and their UInt64 slots. It intentionally excludes capacities and
    # allocator/RSS overhead.
    def logical_charge : UInt64
      self.class.logical_charge_for_mark_count(mark_count) ||
        raise ArgumentError.new("Array(Tuple) schedule charge overflows")
    end

    private def checked_mark(mark_index : Int) : Int32
      raise BoundsError.new("Array(Tuple) schedule mark index is out of bounds") if mark_index < 0 || mark_index >= mark_count
      mark_index.to_i32
    end

    private def checked_boundary(mark_index : Int) : Int32
      raise BoundsError.new("Array(Tuple) schedule boundary is out of bounds") if mark_index < 0 || mark_index > mark_count
      mark_index.to_i32
    end

    private def checked_range(first_mark : Int, mark_count : Int) : {Int32, Int32}
      raise BoundsError.new("Array(Tuple) schedule range is invalid") if first_mark < 0 || mark_count < 0
      raise BoundsError.new("Array(Tuple) schedule range is invalid") if first_mark > mark_count() || mark_count > self.mark_count - first_mark
      {first_mark.to_i32, (first_mark + mark_count).to_i32}
    end
  end
end
