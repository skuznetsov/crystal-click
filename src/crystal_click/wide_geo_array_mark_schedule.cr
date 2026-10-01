module CrystalClick
  # Per-selected-mark logical cardinalities discovered by decoding every
  # nested size stream. All physical mark rows stay on the outer table axis.
  class WideGeoArrayMarkSchedule
    @outer_rows : Array(UInt64)
    @level_counts : Array(Array(UInt64))
    @point_counts : Array(UInt64)
    @recorded : Array(Bool)

    def self.logical_charge_for_mark_count(mark_count : Int, depth : Int) : UInt64?
      return nil if mark_count < 0 || mark_count >= Int32::MAX
      return nil if depth < 1 || depth > 3
      marks = mark_count.to_u64
      total = instance_sizeof(WideGeoArrayMarkSchedule).to_u64
      total = checked_add(total, instance_sizeof(Array(UInt64)).to_u64) || return nil
      total = checked_product_add(total, marks, sizeof(UInt64).to_u64) || return nil
      total = checked_add(total, instance_sizeof(Array(UInt64)).to_u64) || return nil
      total = checked_product_add(total, marks, sizeof(UInt64).to_u64) || return nil
      total = checked_add(total, instance_sizeof(Array(Bool)).to_u64) || return nil
      total = checked_product_add(total, marks, sizeof(Bool).to_u64) || return nil
      total = checked_add(total, instance_sizeof(Array(Array(UInt64))).to_u64) || return nil
      level_array_slots = depth.to_u64 * sizeof(Pointer(Array(UInt64))).to_u64
      total = checked_add(total, level_array_slots) || return nil
      depth.times do
        total = checked_add(total, instance_sizeof(Array(UInt64)).to_u64) || return nil
        total = checked_product_add(total, marks, sizeof(UInt64).to_u64) || return nil
      end
      total
    end

    def initialize(mark_count : Int, depth : Int)
      charge = self.class.logical_charge_for_mark_count(mark_count, depth) ||
               raise(ArgumentError.new("Geo Array mark schedule shape exceeds native limits"))
      raise ArgumentError.new("Geo Array mark schedule exceeds the 64 MiB limit") if charge > GeoArrayColumnType::MAX_MATERIALIZED_BYTES
      # Every valid logical row count is at most 65,536, so UInt64::MAX is a
      # private sentinel for marks whose physical outer rows have not yet
      # been recorded.
      @outer_rows = Array(UInt64).new(mark_count, UInt64::MAX)
      @level_counts = Array(Array(UInt64)).new(depth) { Array(UInt64).new(mark_count, 0_u64) }
      @point_counts = Array(UInt64).new(mark_count, 0_u64)
      @recorded = Array(Bool).new(mark_count, false)
    end

    def mark_count : Int32
      @outer_rows.size.to_i32
    end

    def depth : Int32
      @level_counts.size.to_i32
    end

    def record_outer_rows(mark_index : Int, outer_rows : UInt64) : Nil
      index = checked_mark(mark_index)
      raise ArgumentError.new("Geo Array outer mark rows were already recorded") if @outer_rows[index] != UInt64::MAX
      if outer_rows > GeoArrayColumnType::MAX_LOGICAL_ELEMENTS
        raise ArgumentError.new("Geo Array outer mark rows exceed the logical element limit")
      end
      @outer_rows[index] = outer_rows
      nil
    end

    def record(mark_index : Int, outer_rows : UInt64, level_counts : Array(UInt64), point_count : UInt64) : Nil
      index = checked_mark(mark_index)
      raise ArgumentError.new("Geo Array mark schedule was already recorded") if @recorded[index]
      raise ArgumentError.new("Geo Array mark schedule depth differs") unless level_counts.size == depth
      raise ArgumentError.new("Geo Array outer mark rows were not recorded") if @outer_rows[index] == UInt64::MAX
      raise ArgumentError.new("Geo Array outer schedule differs from its recorded rows") unless @outer_rows[index] == outer_rows
      if outer_rows > GeoArrayColumnType::MAX_LOGICAL_ELEMENTS || level_counts[0] != outer_rows
        raise ArgumentError.new("Geo Array outer schedule differs from its size0 record count")
      end
      if point_count > GeoArrayColumnType::MAX_LOGICAL_ELEMENTS || level_counts.any? { |count| count > GeoArrayColumnType::MAX_LOGICAL_ELEMENTS }
        raise ArgumentError.new("Geo Array mark schedule exceeds the logical element limit")
      end
      @outer_rows[index] = outer_rows
      level_counts.each_with_index { |count, level| @level_counts[level][index] = count }
      @point_counts[index] = point_count
      @recorded[index] = true
      nil
    end

    def outer_rows_at(mark_index : Int) : UInt64
      @outer_rows[checked_outer_mark(mark_index)]
    end

    def level_count_at(level : Int, mark_index : Int) : UInt64
      @level_counts[checked_level(level)][checked_recorded_mark(mark_index)]
    end

    def point_count_at(mark_index : Int) : UInt64
      @point_counts[checked_recorded_mark(mark_index)]
    end

    def level_counts_at(mark_index : Int) : Array(UInt64)
      index = checked_recorded_mark(mark_index)
      @level_counts.map { |level_counts| level_counts[index] }
    end

    def total_outer_rows : UInt64
      ensure_complete!
      sum(@outer_rows)
    end

    def total_level_count(level : Int) : UInt64
      ensure_complete!
      sum(@level_counts[checked_level(level)])
    end

    def total_point_count : UInt64
      ensure_complete!
      sum(@point_counts)
    end

    def logical_charge : UInt64
      self.class.logical_charge_for_mark_count(mark_count, depth) ||
        raise(ArgumentError.new("Geo Array mark schedule charge overflows"))
    end

    private def checked_mark(mark_index : Int) : Int32
      if mark_index < 0 || mark_index >= mark_count
        raise BoundsError.new("Geo Array schedule mark index is out of bounds")
      end
      mark_index.to_i32
    end

    private def checked_recorded_mark(mark_index : Int) : Int32
      index = checked_mark(mark_index)
      raise ArgumentError.new("Geo Array mark schedule entry is incomplete") unless @recorded[index]
      index
    end

    private def checked_outer_mark(mark_index : Int) : Int32
      index = checked_mark(mark_index)
      raise ArgumentError.new("Geo Array outer mark schedule entry is incomplete") if @outer_rows[index] == UInt64::MAX
      index
    end

    private def ensure_complete! : Nil
      raise ArgumentError.new("Geo Array mark schedule is incomplete") unless @recorded.all?
      nil
    end

    private def checked_level(level : Int) : Int32
      if level < 0 || level >= depth
        raise BoundsError.new("Geo Array schedule level is out of bounds")
      end
      level.to_i32
    end

    private def sum(values : Array(UInt64)) : UInt64
      total = 0_u64
      values.each do |value|
        if value > UInt64::MAX - total
          raise CorruptPartError.new("Geo Array selected schedule total overflows")
        end
        total += value
      end
      total
    end

    private def self.checked_add(total : UInt64, amount : UInt64) : UInt64?
      return nil if amount > UInt64::MAX - total
      total + amount
    end

    private def self.checked_product_add(total : UInt64, count : UInt64, width : UInt64) : UInt64?
      return nil if width != 0_u64 && count > UInt64::MAX // width
      checked_add(total, count * width)
    end
  end
end
