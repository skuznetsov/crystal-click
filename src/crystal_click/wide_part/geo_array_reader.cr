module CrystalClick
  class WidePart
    # Reads an exact stock-qualified Geo Array from its depth-indexed UInt64
    # size streams and two Float64 coordinate streams. Physical .mrk2 rows on
    # every stream remain table rows; nested size and Point cardinalities are
    # discovered independently from the decoded values.
    private class GeoArrayReader
      alias RangeRows = Proc(String, Int32, Int32, UInt64)
      alias MarkRows = Proc(String, Int32, UInt64)
      alias ReadRange = Proc(String, Int32, Int32, Int32, Int32, UInt64, Bytes)
      alias ValidateRange = Proc(String, Int32, Int32, Int32, Int32, UInt64, Nil)
      alias DecodeUInt64 = Proc(Bytes, Int32, UInt64)
      alias DecodeFloat64 = Proc(Bytes, Int32, Float64)
      alias SizeLevelsByMark = Array(Array(Array(UInt64)))

      @plan : GeoArrayColumnType
      @column : String
      @range_rows : RangeRows
      @mark_rows : MarkRows
      @read_range : ReadRange
      @validate_range : ValidateRange
      @decode_uint64 : DecodeUInt64
      @decode_float64 : DecodeFloat64

      def initialize(
        @plan : GeoArrayColumnType,
        @column : String,
        @range_rows : RangeRows,
        @mark_rows : MarkRows,
        @read_range : ReadRange,
        @validate_range : ValidateRange,
        @decode_uint64 : DecodeUInt64,
        @decode_float64 : DecodeFloat64,
      )
      end

      def read(
        first_mark : Int32,
        mark_count : Int32,
        max_materialized_bytes : UInt64,
      ) : WideGeoArrayColumnData
        validate_budget(max_materialized_bytes)
        checked_first, checked_count = checked_range(first_mark, mark_count)
        schedule, levels_by_mark, level_counts, point_count = discover_sizes(
          checked_first,
          checked_count,
          max_materialized_bytes
        )
        charge = full_range_charge(level_counts, point_count, schedule.mark_count, level_counts, point_count)
        ensure_charge!(charge, max_materialized_bytes, "Geo Array range materialization charge exceeds per-range limit")
        validate_coordinate_structure!(schedule, checked_first)

        x_stream, y_stream = @plan.coordinate_streams(@column)
        expected_points = schedule.total_point_count
        expected_rows = schedule.total_outer_rows
        expected_bytes = checked_byte_count(expected_points)
        x_bytes = @read_range.call(x_stream, checked_first, checked_count, expected_bytes, 8, expected_rows)
        y_bytes = @read_range.call(y_stream, checked_first, checked_count, expected_bytes, 8, expected_rows)
        ensure_coordinate_bytes!(x_bytes, y_bytes, expected_points)

        points = materialize_points(x_bytes, y_bytes, expected_points)
        flattened_levels = flatten(levels_by_mark, level_counts)
        begin
          WideGeoArrayColumnData.new(@plan, flattened_levels, points)
        rescue ex : ArgumentError
          raise CorruptPartError.new("Geo Array decoded topology is inconsistent")
        end
      end

      def each(
        first_mark : Int32,
        mark_count : Int32,
        max_materialized_bytes : UInt64,
        &block : WideGeoArrayColumnData, Int32 -> Nil
      ) : Nil
        validate_budget(max_materialized_bytes)
        checked_first, checked_count = checked_range(first_mark, mark_count)
        schedule, levels_by_mark, selected_level_counts, selected_point_count = discover_sizes(
          checked_first,
          checked_count,
          max_materialized_bytes
        )

        checked_count.times do |offset|
          per_mark_levels = schedule.level_counts_at(offset)
          per_mark_points = schedule.point_count_at(offset)
          charge = full_range_charge(
            per_mark_levels,
            per_mark_points,
            schedule.mark_count,
            selected_level_counts,
            selected_point_count
          )
          ensure_charge!(charge, max_materialized_bytes, "Geo Array mark materialization charge exceeds per-mark limit")
        end

        validate_coordinate_structure!(schedule, checked_first)
        x_stream, y_stream = @plan.coordinate_streams(@column)
        checked_count.times do |offset|
          mark_index = checked_first + offset
          points_count = schedule.point_count_at(offset)
          outer_rows = schedule.outer_rows_at(offset)
          expected_bytes = checked_byte_count(points_count)
          x_bytes = @read_range.call(x_stream, mark_index, 1, expected_bytes, 8, outer_rows)
          y_bytes = @read_range.call(y_stream, mark_index, 1, expected_bytes, 8, outer_rows)
          ensure_coordinate_bytes!(x_bytes, y_bytes, points_count)

          points = materialize_points(x_bytes, y_bytes, points_count)
          begin
            data = WideGeoArrayColumnData.new(@plan, levels_by_mark[offset], points)
          rescue ex : ArgumentError
            raise CorruptPartError.new("Geo Array decoded mark topology is inconsistent")
          end
          yield data, mark_index
          nil
        end
        nil
      end

      # Size-stream I/O is required because later stream cardinalities are
      # values of earlier size streams. This charge is exact to the logical
      # selected counts, not a metadata-only estimate.
      def materialization_charge(
        first_mark : Int32,
        mark_count : Int32,
        max_materialized_bytes : UInt64,
      ) : UInt64
        validate_budget(max_materialized_bytes)
        checked_first, checked_count = checked_range(first_mark, mark_count)
        schedule, _levels_by_mark, level_counts, point_count = discover_sizes(
          checked_first,
          checked_count,
          max_materialized_bytes
        )
        charge = full_range_charge(level_counts, point_count, schedule.mark_count, level_counts, point_count)
        ensure_charge!(charge, max_materialized_bytes, "Geo Array range materialization charge exceeds per-range limit")
        charge
      end

      # Geometry composes the same six nominal Geo Array lanes under one
      # discriminator. Return only the selected aggregate shape, while the
      # callback receives compact per-mark counts from this single existing
      # size-discovery pass. No child topology or Point buffers escape.
      def logical_shape(
        first_mark : Int32,
        mark_count : Int32,
        max_materialized_bytes : UInt64,
      ) : {Array(UInt64), UInt64}
        logical_shape(first_mark, mark_count, max_materialized_bytes) do |_mark_offset, _level_counts, _point_count|
          nil
        end
      end

      def logical_shape(
        first_mark : Int32,
        mark_count : Int32,
        max_materialized_bytes : UInt64,
        &block : Int32, Array(UInt64), UInt64 -> Nil
      ) : {Array(UInt64), UInt64}
        validate_budget(max_materialized_bytes)
        checked_first, checked_count = checked_range(first_mark, mark_count)
        schedule, levels_by_mark, level_counts, point_count = discover_sizes(
          checked_first,
          checked_count,
          max_materialized_bytes
        )
        charge = full_range_charge(level_counts, point_count, schedule.mark_count, level_counts, point_count)
        ensure_charge!(charge, max_materialized_bytes, "Geo Array range materialization charge exceeds per-range limit")
        validate_coordinate_structure!(schedule, checked_first)

        checked_count.times do |mark_offset|
          per_mark_counts = Array(UInt64).new(@plan.depth) do |level|
            levels_by_mark[mark_offset][level].size.to_u64
          end
          yield mark_offset.to_i32, per_mark_counts, schedule.point_count_at(mark_offset)
        end
        {level_counts, point_count}
      end

      def validate_selected_structure(
        first_mark : Int32,
        mark_count : Int32,
        max_materialized_bytes : UInt64,
      ) : Nil
        validate_budget(max_materialized_bytes)
        checked_first, checked_count = checked_range(first_mark, mark_count)
        schedule, _levels_by_mark, level_counts, point_count = discover_sizes(
          checked_first,
          checked_count,
          max_materialized_bytes
        )
        charge = full_range_charge(level_counts, point_count, schedule.mark_count, level_counts, point_count)
        ensure_charge!(charge, max_materialized_bytes, "Geo Array range materialization charge exceeds per-range limit")
        checked_count.times do |offset|
          mark_charge = full_range_charge(
            schedule.level_counts_at(offset),
            schedule.point_count_at(offset),
            schedule.mark_count,
            level_counts,
            point_count
          )
          ensure_charge!(mark_charge, max_materialized_bytes, "Geo Array mark materialization charge exceeds per-mark limit")
        end
        validate_coordinate_structure!(schedule, checked_first)
        nil
      end

      private def discover_sizes(
        first_mark : Int32,
        mark_count : Int32,
        max_materialized_bytes : UInt64,
      ) : {WideGeoArrayMarkSchedule, SizeLevelsByMark, Array(UInt64), UInt64}
        raise CorruptPartError.new("Geo Array selected range is empty") if mark_count <= 0
        physical_streams = @plan.physical_streams(@column)
        reference_stream = @plan.outer_size_stream(@column)
        range_rows = @range_rows.call(reference_stream, first_mark, mark_count)
        if range_rows > GeoArrayColumnType::MAX_LOGICAL_ELEMENTS
          raise CorruptPartError.new("Geo Array selected outer-row count exceeds the materialization limit")
        end
        physical_streams.each do |stream, width|
          unless width == 8 && @range_rows.call(stream, first_mark, mark_count) == range_rows
            raise CorruptPartError.new("Geo Array physical stream mark rows differ")
          end
        end

        zero_counts = Array(UInt64).new(@plan.depth, 0_u64)
        minimum_charge = full_range_charge(zero_counts, 0_u64, mark_count, zero_counts, 0_u64)
        ensure_charge!(minimum_charge, max_materialized_bytes, "Geo Array selected mark schedule exceeds per-range limit")

        schedule = WideGeoArrayMarkSchedule.new(mark_count, @plan.depth)
        levels_by_mark = SizeLevelsByMark.new(mark_count) do
          Array(Array(UInt64)).new(@plan.depth) { Array(UInt64).new }
        end
        selected_level_counts = Array(UInt64).new(@plan.depth, 0_u64)
        total_outer_rows = 0_u64

        # Physical rows on every stream are the outer table rows. Check each
        # selected mark before using its size payload to discover nested rows.
        mark_count.times do |offset|
          mark_index = first_mark + offset
          outer_rows = @mark_rows.call(reference_stream, mark_index)
          if outer_rows > GeoArrayColumnType::MAX_LOGICAL_ELEMENTS ||
             outer_rows > UInt64::MAX - total_outer_rows
            raise CorruptPartError.new("Geo Array selected outer-row schedule exceeds the materialization limit")
          end
          physical_streams.each do |stream, _width|
            unless @mark_rows.call(stream, mark_index) == outer_rows
              raise CorruptPartError.new("Geo Array physical mark rows differ")
            end
          end
          total_outer_rows += outer_rows
          schedule.record_outer_rows(offset, outer_rows)
        end
        unless total_outer_rows == range_rows && total_outer_rows <= GeoArrayColumnType::MAX_LOGICAL_ELEMENTS
          raise CorruptPartError.new("Geo Array selected mark rows differ from the physical range")
        end

        per_mark_counts = Array(UInt64).new(@plan.depth, 0_u64)
        @plan.depth.times do |level|
          level_records = 0_u64
          mark_count.times do |offset|
            records = expected_size_records(schedule, levels_by_mark, offset, level)
            if records > GeoArrayColumnType::MAX_LOGICAL_ELEMENTS || records > UInt64::MAX - level_records
              raise CorruptPartError.new("Geo Array selected nested-record schedule exceeds the materialization limit")
            end
            level_records += records
          end
          if level_records > GeoArrayColumnType::MAX_LOGICAL_ELEMENTS
            raise CorruptPartError.new("Geo Array selected nested-record schedule exceeds the materialization limit")
          end

          candidate_counts = selected_level_counts.dup
          candidate_counts[level] = level_records
          partial_charge = full_range_charge(candidate_counts, 0_u64, mark_count, candidate_counts, 0_u64)
          ensure_charge!(partial_charge, max_materialized_bytes, "Geo Array size schedule exceeds per-range limit")

          stream = @plan.size_stream(@column, level)
          # Every selected boundary at this depth passes before any of the
          # corresponding size values are read or decoded.
          mark_count.times do |offset|
            records = expected_size_records(schedule, levels_by_mark, offset, level)
            @validate_range.call(
              stream,
              first_mark + offset,
              1,
              checked_byte_count(records),
              8,
              schedule.outer_rows_at(offset)
            )
          end

          mark_count.times do |offset|
            records = expected_size_records(schedule, levels_by_mark, offset, level)
            bytes = @read_range.call(
              stream,
              first_mark + offset,
              1,
              checked_byte_count(records),
              8,
              schedule.outer_rows_at(offset)
            )
            ensure_size_bytes!(bytes, records)
            sizes = decode_sizes(bytes, records, level)
            child_records = checked_size_sum(sizes, level)
            if child_records > GeoArrayColumnType::MAX_LOGICAL_ELEMENTS
              raise CorruptPartError.new("Geo Array mark child cardinality exceeds the materialization limit")
            end
            levels_by_mark[offset][level] = sizes
          end
          selected_level_counts[level] = level_records
        end

        selected_point_count = 0_u64
        mark_count.times do |offset|
          outer_rows = schedule.outer_rows_at(offset)
          point_count = checked_size_sum(levels_by_mark[offset][@plan.depth - 1], @plan.depth - 1)
          if point_count > GeoArrayColumnType::MAX_LOGICAL_ELEMENTS ||
             point_count > UInt64::MAX - selected_point_count
            raise CorruptPartError.new("Geo Array selected Point count exceeds the materialization limit")
          end
          selected_point_count += point_count
          @plan.depth.times do |level|
            per_mark_counts[level] = levels_by_mark[offset][level].size.to_u64
          end
          begin
            schedule.record(offset, outer_rows, per_mark_counts, point_count)
          rescue ex : ArgumentError
            raise CorruptPartError.new("Geo Array mark schedule is inconsistent")
          end
        end
        if selected_point_count > GeoArrayColumnType::MAX_LOGICAL_ELEMENTS
          raise CorruptPartError.new("Geo Array selected Point count exceeds the materialization limit")
        end

        charge = full_range_charge(selected_level_counts, selected_point_count, mark_count, selected_level_counts, selected_point_count)
        ensure_charge!(charge, max_materialized_bytes, "Geo Array selected topology exceeds per-range limit")
        {schedule, levels_by_mark, selected_level_counts, selected_point_count}
      end

      private def expected_size_records(
        schedule : WideGeoArrayMarkSchedule,
        levels_by_mark : SizeLevelsByMark,
        mark_offset : Int32,
        level : Int32,
      ) : UInt64
        return schedule.outer_rows_at(mark_offset) if level == 0
        checked_size_sum(levels_by_mark[mark_offset][level - 1], level - 1)
      end

      private def checked_size_sum(sizes : Array(UInt64), level : Int) : UInt64
        total = 0_u64
        sizes.each do |size|
          if size > UInt64::MAX - total
            raise CorruptPartError.new("Geo Array size level #{level} total overflows UInt64")
          end
          total += size
          if total > GeoArrayColumnType::MAX_LOGICAL_ELEMENTS
            raise CorruptPartError.new("Geo Array size level #{level} exceeds the materialization limit")
          end
        end
        total
      end

      private def decode_sizes(bytes : Bytes, records : UInt64, level : Int32) : Array(UInt64)
        result = Array(UInt64).new(records.to_i)
        index = 0_u64
        while index < records
          result << @decode_uint64.call(bytes, (index * 8_u64).to_i32)
          index += 1_u64
        end
        checked_size_sum(result, level)
        result
      end

      private def flatten(levels_by_mark : SizeLevelsByMark, level_counts : Array(UInt64)) : Array(Array(UInt64))
        flattened = Array(Array(UInt64)).new(@plan.depth)
        @plan.depth.times do |level|
          values = Array(UInt64).new(level_counts[level].to_i)
          levels_by_mark.each { |mark_levels| mark_levels[level].each { |size| values << size } }
          flattened << values
        end
        flattened
      end

      private def validate_coordinate_structure!(schedule : WideGeoArrayMarkSchedule, first_mark : Int32) : Nil
        x_stream, y_stream = @plan.coordinate_streams(@column)
        schedule.mark_count.times do |offset|
          mark_index = first_mark + offset
          rows = schedule.outer_rows_at(offset)
          expected_bytes = checked_byte_count(schedule.point_count_at(offset))
          @validate_range.call(x_stream, mark_index, 1, expected_bytes, 8, rows)
          @validate_range.call(y_stream, mark_index, 1, expected_bytes, 8, rows)
        end
        nil
      end

      private def materialize_points(x_bytes : Bytes, y_bytes : Bytes, point_count : UInt64) : Array(WidePointValue)
        points = Array(WidePointValue).new(point_count.to_i)
        index = 0_u64
        while index < point_count
          byte_offset = (index * 8_u64).to_i32
          points << WidePointValue.new(
            @decode_float64.call(x_bytes, byte_offset),
            @decode_float64.call(y_bytes, byte_offset)
          )
          index += 1_u64
        end
        points
      end

      private def full_range_charge(
        result_level_counts : Array(UInt64),
        result_point_count : UInt64,
        mark_count : Int,
        selected_level_counts : Array(UInt64),
        selected_point_count : UInt64,
      ) : UInt64
        @plan.reader_materialization_charge(
          result_level_counts,
          result_point_count,
          mark_count,
          selected_level_counts,
          selected_point_count
        ) || raise(CorruptPartError.new("Geo Array logical materialization charge overflows or exceeds 64 MiB"))
      end

      private def validate_budget(max_materialized_bytes : UInt64) : Nil
        if max_materialized_bytes > GeoArrayColumnType::MAX_MATERIALIZED_BYTES
          raise ArgumentError.new("Geo Array materialization budget cannot exceed 64 MiB")
        end
      end

      private def checked_range(first_mark : Int32, mark_count : Int32) : {Int32, Int32}
        raise BoundsError.new("negative Geo Array mark range") if first_mark < 0 || mark_count < 0
        raise CorruptPartError.new("Geo Array selected range is empty") if mark_count == 0
        if mark_count > Int32::MAX - first_mark
          raise BoundsError.new("Geo Array mark range exceeds supported index range")
        end
        {first_mark, mark_count}
      end

      private def ensure_charge!(charge : UInt64, max_materialized_bytes : UInt64, message : String) : Nil
        raise CorruptPartError.new(message) if charge > max_materialized_bytes
        nil
      end

      private def checked_byte_count(values : UInt64) : Int32
        if values > Int32::MAX.to_u64 // 8_u64
          raise CorruptPartError.new("Geo Array selected byte count exceeds native range")
        end
        (values * 8_u64).to_i32
      end

      private def ensure_size_bytes!(bytes : Bytes, records : UInt64) : Nil
        expected = checked_byte_count(records)
        raise CorruptPartError.new("Geo Array size byte count differs from the decoded schedule") unless bytes.size == expected
      end

      private def ensure_coordinate_bytes!(x_bytes : Bytes, y_bytes : Bytes, points : UInt64) : Nil
        expected = checked_byte_count(points)
        unless x_bytes.size == expected && y_bytes.size == expected
          raise CorruptPartError.new("Geo Array coordinate byte count differs from the decoded Point count")
        end
      end
    end
  end
end
