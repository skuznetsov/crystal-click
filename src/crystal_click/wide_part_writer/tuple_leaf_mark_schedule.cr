module CrystalClick
  module WidePartWriter
    # Maps one outer-row mark to the corresponding flattened leaf interval.
    # Row-aligned W106 schedules are formula-backed; ragged W107 schedules
    # retain only one bounded record per outer mark.
    private class TupleLeafMarkSchedule
      enum Axis
        Leaf
        Outer
      end

      struct Mark
        getter outer_start : Int32
        getter outer_rows : Int32
        getter leaf_start : Int32
        getter leaf_count : Int32

        def initialize(
          @outer_start : Int32,
          @outer_rows : Int32,
          @leaf_start : Int32,
          @leaf_count : Int32,
        )
        end
      end

      getter row_count : Int32
      getter leaf_count : Int32
      getter rows_per_mark : Int32
      getter mark_count : Int32

      @marks : Array(Mark)?

      private def initialize(
        @marks : Array(Mark)?,
        @row_count : Int32,
        @leaf_count : Int32,
        @rows_per_mark : Int32,
        @mark_count : Int32,
      )
      end

      def mark(index : Int32, axis : Axis = Axis::Leaf) : Mark
        raise BoundsError.new("Tuple mark index is out of bounds") if index < 0 || index >= @mark_count
        if marks = @marks
          mark = marks[index]
          return mark if axis == Axis::Leaf
          return Mark.new(mark.outer_start, mark.outer_rows, mark.outer_start, mark.outer_rows)
        end

        start = index.to_i64 * @rows_per_mark.to_i64
        rows = {@rows_per_mark.to_i64, @row_count.to_i64 - start}.min.to_i32
        Mark.new(start.to_i32, rows, start.to_i32, rows)
      end

      # Logical retained-storage estimate used before a ragged mark array is
      # allocated. Mark records are inline values in the backing Array.
      def self.ragged_logical_charge(mark_count : Int32) : UInt64?
        return nil if mark_count < 0
        fixed = instance_sizeof(TupleLeafMarkSchedule).to_u64 + instance_sizeof(Array(Mark)).to_u64
        slots = mark_count.to_u64
        record_bytes = sizeof(Mark).to_u64
        return nil if slots > (UInt64::MAX - fixed) // record_bytes
        fixed + slots * record_bytes
      end

      def logical_charge : UInt64
        self.class.ragged_logical_charge(@marks ? @mark_count : 0).not_nil!
      end

      def self.row_aligned(row_count : Int32, rows_per_mark : Int32) : TupleLeafMarkSchedule
        raise ArgumentError.new("Tuple mark schedule row count must be positive") if row_count <= 0
        raise ArgumentError.new("Tuple mark schedule size must be positive") if rows_per_mark <= 0

        count = mark_count_for(row_count, rows_per_mark)
        new(nil, row_count, row_count, rows_per_mark, count)
      end

      def self.from_row_sizes(
        row_sizes : Slice(UInt64),
        rows_per_mark : Int32,
        max_rows : UInt64,
        max_elements : Int32,
        max_marks : Int32,
        max_schedule_bytes : UInt64,
      ) : TupleLeafMarkSchedule
        raise ArgumentError.new("Array(Tuple) row sizes must be nonempty") if row_sizes.empty?
        raise ArgumentError.new("rows_per_mark must be positive") if rows_per_mark <= 0
        raise ArgumentError.new("element limit must be positive") if max_elements <= 0
        raise ArgumentError.new("mark limit must be positive") if max_marks <= 0
        raise ArgumentError.new("outer row count exceeds writer limit") if row_sizes.size.to_u64 > max_rows

        row_count = row_sizes.size
        count = mark_count_for(row_count, rows_per_mark)
        raise ArgumentError.new("mark count exceeds writer limit") if count > max_marks
        schedule_charge = ragged_logical_charge(count) ||
                          raise ArgumentError.new("Array(Tuple) mark schedule charge overflows")
        if schedule_charge > max_schedule_bytes
          raise ArgumentError.new("Array(Tuple) mark schedule exceeds materialization limit")
        end

        marks = Array(Mark).new(count)
        leaf_start = 0_u64
        row_start = 0
        while row_start < row_count
          rows = {rows_per_mark, row_count - row_start}.min
          mark_leaf_start = leaf_start
          rows.times do |offset|
            size = row_sizes[row_start + offset]
            if leaf_start > max_elements.to_u64 || size > max_elements.to_u64 - leaf_start
              raise ArgumentError.new("Array(Tuple) element count exceeds writer limit")
            end
            leaf_start += size
          end
          count_in_mark = leaf_start - mark_leaf_start
          unless mark_leaf_start <= Int32::MAX.to_u64 && count_in_mark <= Int32::MAX.to_u64
            raise ArgumentError.new("Array(Tuple) element offsets exceed writer limit")
          end
          marks << Mark.new(row_start, rows, mark_leaf_start.to_i32, count_in_mark.to_i32)
          row_start += rows
        end
        new(marks, row_count, leaf_start.to_i32, rows_per_mark, count)
      end

      def self.scheduled_mark(
        schedule : TupleLeafMarkSchedule?,
        mark_index : Int32,
        start_row : Int32,
        row_count : Int32,
        rows_per_mark : Int32,
        axis : Axis = Axis::Leaf,
      ) : Mark?
        if schedule
          current = schedule.not_nil!
          return nil if mark_index >= current.mark_count
          current.mark(mark_index, axis)
        else
          return nil if start_row >= row_count
          rows = {rows_per_mark, row_count - start_row}.min
          Mark.new(start_row, rows, start_row, rows)
        end
      end

      private def self.mark_count_for(row_count : Int32, rows_per_mark : Int32) : Int32
        # Division plus remainder avoids overflow in (row_count + rpm - 1).
        count = row_count // rows_per_mark
        count += 1 if row_count % rows_per_mark != 0
        count
      end
    end
  end
end
