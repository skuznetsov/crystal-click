module CrystalClick
  class WidePart
    # Reads one exact Point column from its two Float64 coordinate streams.
    # WidePart supplies the existing mark/frame and scalar decoder callbacks.
    private class PointReader
      alias RangeRows = Proc(String, Int32, Int32, UInt64)
      alias MarkRows = Proc(String, Int32, UInt64)
      alias ReadRange = Proc(String, Int32, Int32, Int32, Int32, UInt64, Bytes)
      alias ValidateRange = Proc(String, Int32, Int32, Int32, Int32, UInt64, Nil)
      alias DecodeFloat64 = Proc(Bytes, Int32, Float64)

      @plan : PointColumnType
      @column : String
      @range_rows : RangeRows
      @mark_rows : MarkRows
      @read_range : ReadRange
      @validate_range : ValidateRange
      @decode_float64 : DecodeFloat64

      def initialize(
        @plan : PointColumnType,
        @column : String,
        @range_rows : RangeRows,
        @mark_rows : MarkRows,
        @read_range : ReadRange,
        @validate_range : ValidateRange,
        @decode_float64 : DecodeFloat64,
      )
      end

      def read(
        first_mark : Int32,
        mark_count : Int32,
        max_materialized_bytes : UInt64,
      ) : Array(WidePointValue)
        validate_budget(max_materialized_bytes)
        schedule, rows, schedule_charge = preflight_schedule(first_mark, mark_count, max_materialized_bytes)
        charge = checked_charge(rows, schedule_charge)
        raise CorruptPartError.new("Point materialization charge exceeds per-range limit") if charge > max_materialized_bytes
        validate_structure!(schedule, first_mark)

        x_stream, y_stream = @plan.coordinate_streams(@column)
        expected_bytes = checked_byte_count(rows)
        x_bytes = @read_range.call(x_stream, first_mark, mark_count, expected_bytes, 8, rows)
        y_bytes = @read_range.call(y_stream, first_mark, mark_count, expected_bytes, 8, rows)
        ensure_coordinate_bytes!(x_bytes, y_bytes, rows)
        materialize(x_bytes, y_bytes, rows)
      end

      def each(
        first_mark : Int32,
        mark_count : Int32,
        max_materialized_bytes : UInt64,
        & : Array(WidePointValue), Int32 -> Nil
      ) : Nil
        validate_budget(max_materialized_bytes)
        schedule, _rows, schedule_charge = preflight_schedule(first_mark, mark_count, max_materialized_bytes)

        # A later oversized mark must not follow callbacks for earlier marks.
        # The schedule is bounded and metadata-only, so check every mark first.
        schedule.each do |rows|
          charge = checked_charge(rows, schedule_charge)
          raise CorruptPartError.new("Point mark materialization charge exceeds per-mark limit") if charge > max_materialized_bytes
        end
        validate_structure!(schedule, first_mark)

        x_stream, y_stream = @plan.coordinate_streams(@column)
        schedule.each_with_index do |rows, offset|
          mark_index = first_mark + offset.to_i32
          expected_bytes = checked_byte_count(rows)
          x_bytes = @read_range.call(x_stream, mark_index, 1, expected_bytes, 8, rows)
          y_bytes = @read_range.call(y_stream, mark_index, 1, expected_bytes, 8, rows)
          ensure_coordinate_bytes!(x_bytes, y_bytes, rows)
          yield materialize(x_bytes, y_bytes, rows), mark_index
          nil
        end
        nil
      end

      def materialization_charge(
        first_mark : Int32,
        mark_count : Int32,
        max_materialized_bytes : UInt64,
      ) : UInt64
        validate_budget(max_materialized_bytes)
        _schedule, rows, schedule_charge = preflight_schedule(first_mark, mark_count, max_materialized_bytes)
        charge = checked_charge(rows, schedule_charge)
        raise CorruptPartError.new("Point materialization charge exceeds per-range limit") if charge > max_materialized_bytes
        charge
      end

      def validate_selected_structure(
        first_mark : Int32,
        mark_count : Int32,
        max_materialized_bytes : UInt64,
      ) : Nil
        validate_budget(max_materialized_bytes)
        schedule, _rows, schedule_charge = preflight_schedule(first_mark, mark_count, max_materialized_bytes)
        schedule.each do |rows|
          if checked_charge(rows, schedule_charge) > max_materialized_bytes
            raise CorruptPartError.new("Point mark materialization charge exceeds per-mark limit")
          end
        end
        validate_structure!(schedule, first_mark)
        nil
      end

      private def preflight_schedule(
        first_mark : Int32,
        mark_count : Int32,
        max_materialized_bytes : UInt64,
      ) : {Array(UInt64), UInt64, UInt64}
        raise CorruptPartError.new("Point has no coordinate streams") if mark_count <= 0
        x_stream, y_stream = @plan.coordinate_streams(@column)
        x_rows = @range_rows.call(x_stream, first_mark, mark_count)
        y_rows = @range_rows.call(y_stream, first_mark, mark_count)
        raise CorruptPartError.new("Point coordinate mark rows differ") unless x_rows == y_rows

        charge = schedule_charge(mark_count)
        # Reject an over-budget retained schedule before allocating it. This
        # phase reads only marks and row counts; no selected payload is decoded.
        schedule_only_charge = checked_charge(0_u64, charge)
        if schedule_only_charge > max_materialized_bytes
          raise CorruptPartError.new("Point selected mark schedule exceeds per-range limit")
        end

        schedule = Array(UInt64).new(mark_count)
        total_rows = 0_u64
        mark_count.times do |offset|
          mark_index = first_mark + offset
          rows = @mark_rows.call(x_stream, mark_index)
          unless @mark_rows.call(y_stream, mark_index) == rows
            raise CorruptPartError.new("Point coordinate mark rows differ")
          end
          if rows > UInt64::MAX - total_rows
            raise CorruptPartError.new("Point selected row count overflows")
          end
          total_rows += rows
          schedule << rows
        end
        raise CorruptPartError.new("Point selected mark schedule differs from range rows") unless total_rows == x_rows
        {schedule, total_rows, charge}
      end

      private def validate_structure!(schedule : Array(UInt64), first_mark : Int32) : Nil
        x_stream, y_stream = @plan.coordinate_streams(@column)
        # Validate every selected mark on both streams before the first value
        # callback. Equal aggregate byte counts cannot hide shifted boundaries.
        schedule.each_with_index do |rows, offset|
          mark_index = first_mark + offset.to_i32
          expected_bytes = checked_byte_count(rows)
          @validate_range.call(x_stream, mark_index, 1, expected_bytes, 8, rows)
          @validate_range.call(y_stream, mark_index, 1, expected_bytes, 8, rows)
        end
        nil
      end

      private def schedule_charge(mark_count : Int32) : UInt64
        raise CorruptPartError.new("Point selected mark count is invalid") if mark_count < 0
        header = instance_sizeof(Array(UInt64)).to_u64
        entries = mark_count.to_u64
        if entries > (PointColumnType::MAX_MATERIALIZED_BYTES - header) // sizeof(UInt64).to_u64
          raise CorruptPartError.new("Point selected mark schedule exceeds reader limit")
        end
        header + entries * sizeof(UInt64).to_u64
      end

      private def checked_charge(rows : UInt64, schedule_charge : UInt64) : UInt64
        @plan.materialization_charge(rows, schedule_charge)
      rescue ex : ArgumentError
        raise CorruptPartError.new("Point materialization charge exceeds per-range limit")
      end

      private def validate_budget(max_materialized_bytes : UInt64) : Nil
        if max_materialized_bytes > PointColumnType::MAX_MATERIALIZED_BYTES
          raise ArgumentError.new("Point materialization budget cannot exceed 64 MiB")
        end
      end

      private def checked_byte_count(rows : UInt64) : Int32
        if rows > Int32::MAX.to_u64 // 8_u64
          raise CorruptPartError.new("Point selected byte count exceeds reader limit")
        end
        (rows * 8_u64).to_i32
      end

      private def ensure_coordinate_bytes!(x_bytes : Bytes, y_bytes : Bytes, rows : UInt64) : Nil
        expected_bytes = checked_byte_count(rows)
        unless x_bytes.size == expected_bytes && y_bytes.size == expected_bytes
          raise CorruptPartError.new("Point coordinate byte count differs from selected rows")
        end
      end

      private def materialize(x_bytes : Bytes, y_bytes : Bytes, rows : UInt64) : Array(WidePointValue)
        count = rows.to_i
        result = Array(WidePointValue).new(count)
        offset = 0
        while offset < count
          byte_offset = offset * 8
          result << WidePointValue.new(
            @decode_float64.call(x_bytes, byte_offset),
            @decode_float64.call(y_bytes, byte_offset)
          )
          offset += 1
        end
        result
      end
    end
  end
end
