require "../errors"
require "../geometry_column_type"
require "../geo_array_column_type"
require "../point_column_type"
require "../wide_geometry_arm"
require "../wide_geometry_column_data"
require "../wide_geometry_mark_schedule"
require "../wide_geo_array_column_data"
require "../wide_point_value"
require "../variant_type_plan"
require "./geo_array_reader"

module CrystalClick
  class WidePart
    # Coordinates the bounded seven-arm Geometry reader. Physical table rows
    # are supplied separately from each arm's sparse window-local ranks.
    private class GeometryReader
      DISCRIMINATOR_PLAN = WideVariantTypePlanDescriptor.new(
        "Geometry",
        [
          WideVariantArmPlan.new("LineString", 0_u8, [] of Tuple(String, Int32)),
          WideVariantArmPlan.new("MultiLineString", 1_u8, [] of Tuple(String, Int32)),
          WideVariantArmPlan.new("MultiPolygon", 2_u8, [] of Tuple(String, Int32)),
          WideVariantArmPlan.new("Point", 3_u8, [] of Tuple(String, Int32)),
          WideVariantArmPlan.new("Polygon", 4_u8, [] of Tuple(String, Int32)),
          WideVariantArmPlan.new("Ring", 5_u8, [] of Tuple(String, Int32)),
          WideVariantArmPlan.new("MultiPoint", 6_u8, [] of Tuple(String, Int32)),
        ] of WideVariantArmPlan
      )

      alias OuterRows = Proc(Int32, Int32, Array(UInt64))
      alias Mode = Proc(UInt64)
      alias ReadTags = Proc(Int32, UInt64, UInt64, Array(UInt8))
      alias ReadRange = Proc(String, Int32, Int32, Int32, Int32, UInt64, Bytes)
      alias ValidateRange = Proc(String, Int32, Int32, Int32, Int32, UInt64, Nil)
      alias DecodeUInt64 = Proc(Bytes, Int32, UInt64)
      alias DecodeFloat64 = Proc(Bytes, Int32, Float64)

      alias ScheduleContext = Tuple(WideGeometryMarkSchedule, Array(UInt64), UInt64, UInt64, UInt64)
      alias Prepared = Tuple(
        WideGeometryMarkSchedule,
        Array(UInt64),
        Array(StaticArray(UInt64, 16)),
        Array(Array(UInt64)),
        Array(UInt64),
        UInt64,
        UInt64,
        UInt64,
      )

      @plan : GeometryColumnType
      @column : String
      @outer_rows : OuterRows
      @mode : Mode
      @read_tags : ReadTags
      @read_range : ReadRange
      @validate_range : ValidateRange
      @decode_uint64 : DecodeUInt64
      @decode_float64 : DecodeFloat64

      def initialize(
        @plan : GeometryColumnType,
        @column : String,
        @outer_rows : OuterRows,
        @mode : Mode,
        @read_tags : ReadTags,
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
      ) : WideGeometryColumnData
        schedule, rows, _summaries, levels, point_counts, _summary_charge, _tag_scratch, charge =
          prepare(first_mark, mark_count, max_materialized_bytes, true)
        ensure_charge!(charge, max_materialized_bytes, "Geometry range materialization charge exceeds per-range limit")

        arrays = Hash(WideGeometryArm, WideGeoArrayColumnData).new
        geometry_arms.each do |arm|
          next if arm == WideGeometryArm::Point
          arrays[arm] = geo_reader(arm, schedule).read(0, mark_count, max_materialized_bytes)
        end
        points = read_points(schedule, first_mark, mark_count, point_counts[3])
        begin
          WideGeometryColumnData.new(schedule.flattened_tags, points, arrays)
        rescue ex : ArgumentError
          raise CorruptPartError.new("Geometry decoded topology is inconsistent")
        end
      end

      def each(
        first_mark : Int32,
        mark_count : Int32,
        max_materialized_bytes : UInt64,
        &block : WideGeometryColumnData, Int32 -> Nil
      ) : Nil
        schedule = preflight_each(first_mark, mark_count, max_materialized_bytes)
        # Discovery summaries are local to preflight_each and are unreachable
        # here. Only the immutable tag/rank schedule survives lazy delivery.
        mark_count.times do |offset|
          arrays = Hash(WideGeometryArm, WideGeoArrayColumnData).new
          geometry_arms.each do |arm|
            next if arm == WideGeometryArm::Point
            arrays[arm] = geo_reader(arm, schedule).read(offset, 1, max_materialized_bytes)
          end
          points = read_points(schedule, first_mark + offset, 1, schedule.arm_count_at(offset, 3))
          begin
            data = WideGeometryColumnData.new(schedule.tags_for_mark(offset), points, arrays)
          rescue ex : ArgumentError
            raise CorruptPartError.new("Geometry decoded mark topology is inconsistent")
          end
          yield data, first_mark + offset
          nil
        end
        nil
      end

      def materialization_charge(
        first_mark : Int32,
        mark_count : Int32,
        max_materialized_bytes : UInt64,
      ) : UInt64
        prepared = prepare(first_mark, mark_count, max_materialized_bytes, true)
        charge = prepared[7]
        ensure_charge!(charge, max_materialized_bytes, "Geometry range materialization charge exceeds per-range limit")
        charge
      end

      def validate_selected_structure(
        first_mark : Int32,
        mark_count : Int32,
        max_materialized_bytes : UInt64,
      ) : Nil
        prepared = prepare(first_mark, mark_count, max_materialized_bytes, true)
        ensure_charge!(prepared[7], max_materialized_bytes, "Geometry range materialization charge exceeds per-range limit")
        nil
      end

      private def prepare(
        first_mark : Int32,
        mark_count : Int32,
        max_materialized_bytes : UInt64,
        full_window_charge : Bool,
      ) : Prepared
        schedule, rows, schedule_charge, summary_charge, tag_scratch =
          prepare_schedule(first_mark, mark_count, max_materialized_bytes)
        summaries = Array(StaticArray(UInt64, 16)).new(mark_count) { StaticArray(UInt64, 16).new(0_u64) }
        levels = Array(Array(UInt64)).new(7) do |index|
          arm = geometry_arms[index]
          Array(UInt64).new(arm.depth, 0_u64)
        end
        points = Array(UInt64).new(7, 0_u64)
        child_budget = max_materialized_bytes - schedule_charge - summary_charge - tag_scratch

        geometry_arms.each_with_index do |arm, arm_index|
          if arm == WideGeometryArm::Point
            points[arm_index] = schedule.arm_range_count(first_mark, mark_count, arm_index)
            next
          end

          lane_levels, lane_points = geo_reader(arm, schedule).logical_shape(0, mark_count, child_budget) do |mark_offset, counts, point_count|
            counts.each_with_index do |count, level|
              summaries[mark_offset][summary_level_slot(arm, level)] = count
            end
            summaries[mark_offset][summary_point_slot(arm)] = point_count
          end
          levels[arm_index] = lane_levels
          points[arm_index] = lane_points
        end

        ensure_point_structure!(schedule, first_mark)
        ensure_occurrence_limit!(rows, levels, points)
        charge = if full_window_charge
                   @plan.reader_materialization_charge(rows, levels, points, summary_charge, tag_scratch) ||
                     raise(CorruptPartError.new("Geometry logical materialization charge overflows or exceeds 64 MiB"))
                 else
                   0_u64
                 end
        {schedule, rows, summaries, levels, points, summary_charge, tag_scratch, charge}
      end

      private def preflight_each(
        first_mark : Int32,
        mark_count : Int32,
        max_materialized_bytes : UInt64,
      ) : WideGeometryMarkSchedule
        prepared = prepare(first_mark, mark_count, max_materialized_bytes, false)
        schedule = prepared[0]
        mark_count.times do |offset|
          levels, points = shape_at(schedule, offset, prepared[2])
          ensure_charge!(
            mark_charge(schedule, offset, levels, points),
            max_materialized_bytes,
            "Geometry mark materialization charge exceeds per-mark limit"
          )
        end
        schedule
      end

      private def shape_at(
        schedule : WideGeometryMarkSchedule,
        mark_offset : Int,
        summaries : Array(StaticArray(UInt64, 16)),
      ) : {Array(Array(UInt64)), Array(UInt64)}
        levels = Array(Array(UInt64)).new(7) do |arm_index|
          arm = geometry_arms[arm_index]
          values = Array(UInt64).new(arm.depth, 0_u64)
          arm.depth.times do |level|
            values[level] = summaries[mark_offset][summary_level_slot(arm, level)]
          end
          values
        end
        points = Array(UInt64).new(7, 0_u64)
        geometry_arms.each_with_index do |arm, arm_index|
          points[arm_index] = if arm == WideGeometryArm::Point
                                schedule.arm_count_at(mark_offset, arm_index)
                              else
                                summaries[mark_offset][summary_point_slot(arm)]
                              end
        end
        {levels, points}
      end

      private def mark_charge(
        schedule : WideGeometryMarkSchedule,
        mark_offset : Int,
        levels : Array(Array(UInt64)),
        points : Array(UInt64),
      ) : UInt64
        rows = [schedule.outer_rows_at(mark_offset)] of UInt64
        tag_scratch = @plan.reader_tag_scratch_charge(rows) ||
                      raise(CorruptPartError.new("Geometry mark tag scratch charge exceeds native limits"))
        charge = @plan.reader_materialization_charge(rows, levels, points, 0_u64, tag_scratch) ||
                 raise(CorruptPartError.new("Geometry mark materialization charge exceeds 64 MiB"))
        single_schedule = WideGeometryMarkSchedule.logical_charge_for_shape(rows) ||
                          raise(CorruptPartError.new("Geometry mark schedule charge overflows"))
        full_schedule = schedule.logical_charge
        if single_schedule > full_schedule
          raise CorruptPartError.new("Geometry mark schedule charge is inconsistent")
        end
        checked_add(charge, full_schedule - single_schedule)
      end

      private def geo_reader(arm : WideGeometryArm, schedule : WideGeometryMarkSchedule) : GeoArrayReader
        child_plan = GeoArrayColumnType.for_type(arm.type_name) ||
                     raise CorruptPartError.new("Geometry arm has no exact Geo Array plan")
        child_column = "#{@column}.#{arm.type_name}"
        arm_index = arm_index(arm)
        GeoArrayReader.new(
          child_plan,
          child_column,
          ->(stream : String, first : Int32, count : Int32) {
            sparse_range_rows(schedule, arm_index, first, count)
          },
          ->(stream : String, mark : Int32) {
            sparse_mark_rows(schedule, arm_index, mark)
          },
          ->(stream : String, first : Int32, count : Int32, bytes : Int32, width : Int32, rows : UInt64) {
            read_sparse_range(schedule, arm_index, stream, first, count, bytes, width, rows)
          },
          ->(stream : String, first : Int32, count : Int32, bytes : Int32, width : Int32, rows : UInt64) {
            validate_sparse_range(schedule, arm_index, stream, first, count, bytes, width, rows)
          },
          ->(bytes : Bytes, offset : Int32) { @decode_uint64.call(bytes, offset) },
          ->(bytes : Bytes, offset : Int32) { @decode_float64.call(bytes, offset) }
        )
      end

      private def sparse_range_rows(schedule : WideGeometryMarkSchedule, arm_index : Int32, first : Int32, count : Int32) : UInt64
        checked_local_range(schedule, first, count)
        schedule.arm_range_count(schedule.first_mark + first, count, arm_index)
      end

      private def sparse_mark_rows(schedule : WideGeometryMarkSchedule, arm_index : Int32, mark_offset : Int32) : UInt64
        if mark_offset < 0 || mark_offset >= schedule.mark_count
          raise BoundsError.new("Geometry sparse child mark is out of bounds")
        end
        schedule.arm_count_at(mark_offset, arm_index)
      end

      private def read_sparse_range(
        schedule : WideGeometryMarkSchedule,
        arm_index : Int32,
        stream : String,
        first : Int32,
        count : Int32,
        expected_bytes : Int32,
        element_width : Int32,
        expected_sparse_rows : UInt64,
      ) : Bytes
        physical_rows = physical_rows_for_range(schedule, first, count)
        unless sparse_range_rows(schedule, arm_index, first, count) == expected_sparse_rows
          raise CorruptPartError.new("Geometry sparse child row schedule differs")
        end
        @read_range.call(stream, schedule.first_mark + first, count, expected_bytes, element_width, physical_rows)
      end

      private def validate_sparse_range(
        schedule : WideGeometryMarkSchedule,
        arm_index : Int32,
        stream : String,
        first : Int32,
        count : Int32,
        expected_bytes : Int32,
        element_width : Int32,
        expected_sparse_rows : UInt64,
      ) : Nil
        physical_rows = physical_rows_for_range(schedule, first, count)
        unless sparse_range_rows(schedule, arm_index, first, count) == expected_sparse_rows
          raise CorruptPartError.new("Geometry sparse child row schedule differs")
        end
        @validate_range.call(stream, schedule.first_mark + first, count, expected_bytes, element_width, physical_rows)
      end

      private def physical_rows_for_range(schedule : WideGeometryMarkSchedule, first : Int32, count : Int32) : UInt64
        checked_local_range(schedule, first, count)
        total = 0_u64
        count.times do |offset|
          rows = schedule.outer_rows_at(first + offset)
          if rows > UInt64::MAX - total
            raise CorruptPartError.new("Geometry physical row schedule overflows")
          end
          total += rows
        end
        total
      end

      private def checked_local_range(schedule : WideGeometryMarkSchedule, first : Int32, count : Int32) : Nil
        if first < 0 || count <= 0 || first > schedule.mark_count || count > schedule.mark_count - first
          raise BoundsError.new("Geometry sparse child range is out of bounds")
        end
      end

      private def read_points(
        schedule : WideGeometryMarkSchedule,
        first_mark : Int32,
        mark_count : Int32,
        point_count : UInt64,
      ) : Array(WidePointValue)
        rows = physical_rows_for_range(schedule, first_mark - schedule.first_mark, mark_count)
        x_stream, y_stream = (PointColumnType.for_type("Point") ||
                              raise CorruptPartError.new("Geometry Point plan is missing")).coordinate_streams("#{@column}.Point")
        bytes = checked_byte_count(point_count)
        x_bytes = @read_range.call(x_stream, first_mark, mark_count, bytes, 8, rows)
        y_bytes = @read_range.call(y_stream, first_mark, mark_count, bytes, 8, rows)
        unless x_bytes.size == bytes && y_bytes.size == bytes
          raise CorruptPartError.new("Geometry Point coordinate byte counts differ from discriminator tags")
        end

        values = Array(WidePointValue).new(point_count.to_i)
        point_count.to_i.times do |index|
          offset = index * 8
          values << WidePointValue.new(@decode_float64.call(x_bytes, offset), @decode_float64.call(y_bytes, offset))
        end
        values
      end

      private def ensure_point_structure!(schedule : WideGeometryMarkSchedule, first_mark : Int32) : Nil
        x_stream, y_stream = (PointColumnType.for_type("Point") ||
                              raise CorruptPartError.new("Geometry Point plan is missing")).coordinate_streams("#{@column}.Point")
        schedule.mark_count.times do |offset|
          point_count = schedule.arm_count_at(offset, arm_index(WideGeometryArm::Point))
          bytes = checked_byte_count(point_count)
          rows = schedule.outer_rows_at(offset)
          mark = first_mark + offset
          @validate_range.call(x_stream, mark, 1, bytes, 8, rows)
          @validate_range.call(y_stream, mark, 1, bytes, 8, rows)
        end
      end

      private def ensure_occurrence_limit!(
        rows_by_mark : Array(UInt64),
        levels : Array(Array(UInt64)),
        points : Array(UInt64),
      ) : Nil
        outer_rows = rows_by_mark.sum
        occurrences = 0_u64
        geometry_arms.each_with_index do |arm, arm_index|
          arm_levels = levels[arm_index]
          arm_levels.each do |count|
            if count > GeometryColumnType::MAX_LOGICAL_ELEMENTS
              raise CorruptPartError.new("Geometry nested axis exceeds the materialization limit")
            end
          end
          point_count = points[arm_index]
          if point_count > GeometryColumnType::MAX_LOGICAL_ELEMENTS
            raise CorruptPartError.new("Geometry Point count exceeds the materialization limit")
          end
          count = arm == WideGeometryArm::Point ? point_count : arm_levels[0]
          if count > UInt64::MAX - occurrences
            raise CorruptPartError.new("Geometry arm occurrence count overflows")
          end
          occurrences += count
        end
        if occurrences > outer_rows
          raise CorruptPartError.new("Geometry arm occurrences exceed selected outer rows")
        end
      end

      private def summary_level_slot(arm : WideGeometryArm, level : Int) : Int32
        base = case arm
               when WideGeometryArm::LineString      then 0
               when WideGeometryArm::MultiLineString then 1
               when WideGeometryArm::MultiPolygon    then 3
               when WideGeometryArm::Polygon         then 6
               when WideGeometryArm::Ring            then 8
               when WideGeometryArm::MultiPoint      then 9
               else
                 raise ArgumentError.new("Geometry Point arm has no size axis")
               end
        base + level
      end

      private def summary_point_slot(arm : WideGeometryArm) : Int32
        case arm
        when WideGeometryArm::LineString      then 10
        when WideGeometryArm::MultiLineString then 11
        when WideGeometryArm::MultiPolygon    then 12
        when WideGeometryArm::Polygon         then 13
        when WideGeometryArm::Ring            then 14
        when WideGeometryArm::MultiPoint      then 15
        else
          raise ArgumentError.new("Geometry Point arm has no Geo Array Point count")
        end
      end

      private def arm_index(arm : WideGeometryArm) : Int32
        case arm
        when WideGeometryArm::LineString      then 0
        when WideGeometryArm::MultiLineString then 1
        when WideGeometryArm::MultiPolygon    then 2
        when WideGeometryArm::Point           then 3
        when WideGeometryArm::Polygon         then 4
        when WideGeometryArm::Ring            then 5
        when WideGeometryArm::MultiPoint      then 6
        else
          raise ArgumentError.new("Geometry arm is invalid")
        end
      end

      private def geometry_arms : Array(WideGeometryArm)
        [
          WideGeometryArm::LineString,
          WideGeometryArm::MultiLineString,
          WideGeometryArm::MultiPolygon,
          WideGeometryArm::Point,
          WideGeometryArm::Polygon,
          WideGeometryArm::Ring,
          WideGeometryArm::MultiPoint,
        ] of WideGeometryArm
      end

      private def prepare_schedule(
        first_mark : Int32,
        mark_count : Int32,
        max_materialized_bytes : UInt64,
      ) : ScheduleContext
        if max_materialized_bytes > GeometryColumnType::MAX_MATERIALIZED_BYTES
          raise ArgumentError.new("Geometry materialization budget cannot exceed 64 MiB")
        end
        if first_mark < 0 || mark_count <= 0 || mark_count > Int32::MAX - first_mark
          raise BoundsError.new("Geometry mark range is out of bounds")
        end

        rows_by_mark = @outer_rows.call(first_mark, mark_count)
        unless rows_by_mark.size == mark_count
          raise CorruptPartError.new("Geometry physical mark row schedule differs")
        end
        schedule_charge = WideGeometryMarkSchedule.logical_charge_for_shape(rows_by_mark) ||
                          raise CorruptPartError.new("Geometry mark schedule exceeds native limits")
        summary_charge = @plan.reader_summary_charge(rows_by_mark) ||
                         raise CorruptPartError.new("Geometry summary charge exceeds native limits")
        tag_scratch = @plan.reader_tag_scratch_charge(rows_by_mark) ||
                      raise CorruptPartError.new("Geometry tag scratch charge exceeds native limits")
        minimum = checked_add(schedule_charge, summary_charge)
        minimum = checked_add(minimum, tag_scratch)
        if minimum > max_materialized_bytes
          raise CorruptPartError.new("Geometry selected mark schedule exceeds per-range limit")
        end

        mode = @mode.call
        tags_by_mark = Array(Array(UInt8)).new(mark_count) do |offset|
          tags = @read_tags.call(first_mark + offset.to_i32, rows_by_mark[offset], mode)
          unless tags.size.to_u64 == rows_by_mark[offset]
            raise CorruptPartError.new("Geometry discriminator rows differ from physical marks")
          end
          tags
        end
        schedule = begin
          WideGeometryMarkSchedule.new(first_mark, rows_by_mark, tags_by_mark)
        rescue ex : ArgumentError
          raise CorruptPartError.new("Geometry decoded discriminator schedule is invalid")
        end
        tags_by_mark.clear
        {schedule, rows_by_mark, schedule_charge, summary_charge, tag_scratch}
      end

      private def checked_add(total : UInt64, amount : UInt64) : UInt64
        if amount > UInt64::MAX - total
          raise CorruptPartError.new("Geometry logical materialization charge overflows")
        end
        total + amount
      end

      private def checked_byte_count(values : UInt64) : Int32
        if values > Int32::MAX.to_u64 // 8_u64
          raise CorruptPartError.new("Geometry Point coordinate byte count exceeds native limits")
        end
        (values * 8_u64).to_i32
      end

      private def ensure_charge!(charge : UInt64, budget : UInt64, message : String) : Nil
        raise CorruptPartError.new(message) if charge > budget
        nil
      end
    end
  end
end
