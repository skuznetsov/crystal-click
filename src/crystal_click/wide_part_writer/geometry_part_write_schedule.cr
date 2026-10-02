module CrystalClick
  module WidePartWriter
    # Retains one outer-row mark schedule for the primary key and one sparse
    # logical-element schedule for every Geometry size/coordinate stream.
    # TupleLeafMarkSchedule keeps the outer mark rows even when a lane has no
    # values in that mark.
    private class GeometryPartWriteSchedule
      @key_schedule : TupleLeafMarkSchedule
      @size_schedules : StaticArray(StaticArray(TupleLeafMarkSchedule?, 3), 7)
      @coordinate_schedules : StaticArray(TupleLeafMarkSchedule?, 7)

      private def initialize(
        @key_schedule : TupleLeafMarkSchedule,
        @size_schedules : StaticArray(StaticArray(TupleLeafMarkSchedule?, 3), 7),
        @coordinate_schedules : StaticArray(TupleLeafMarkSchedule?, 7),
      )
      end

      def self.reserved_charge(mark_count : Int32) : UInt64
        raise ArgumentError.new("Geometry schedule mark count must be positive") if mark_count <= 0
        per_sparse_schedule = TupleLeafMarkSchedule.ragged_logical_charge(mark_count) ||
                              raise ArgumentError.new("Geometry schedule charge overflows")
        total = instance_sizeof(GeometryPartWriteSchedule).to_u64
        total = checked_add(total, instance_sizeof(TupleLeafMarkSchedule).to_u64, "Geometry key schedule")
        total = checked_add(total, checked_multiply(per_sparse_schedule, 17_u64, "Geometry sparse schedules"), "Geometry sparse schedules")
        total
      end

      def self.interval_scratch_charge(mark_count : Int32) : UInt64
        raise ArgumentError.new("Geometry schedule mark count must be positive") if mark_count <= 0
        # The builder constructs one arm at a time. Its largest interval set is
        # the depth-three MultiPolygon: three size vectors plus coordinates.
        total = checked_multiply(8_u64, instance_sizeof(Array(UInt64)).to_u64, "Geometry interval headers")
        total = checked_add(
          total,
          2_u64 * instance_sizeof(Array(Array(UInt64))).to_u64 +
          6_u64 * sizeof(Pointer(Array(UInt64))).to_u64,
          "Geometry interval collection headers"
        )
        checked_add(
          total,
          checked_multiply(checked_multiply(8_u64, mark_count.to_u64, "Geometry interval slots"), sizeof(UInt64).to_u64, "Geometry interval slots"),
          "Geometry interval scratch"
        )
      end

      def self.build(
        data : WideGeometryColumnData,
        rows_per_mark : Int32,
        mark_count : Int32,
      ) : GeometryPartWriteSchedule
        key_schedule = TupleLeafMarkSchedule.row_aligned(data.row_count, rows_per_mark)
        levels = StaticArray(StaticArray(TupleLeafMarkSchedule?, 3), 7).new(
          StaticArray(TupleLeafMarkSchedule?, 3).new(nil)
        )
        coordinates = StaticArray(TupleLeafMarkSchedule?, 7).new(nil)

        7.times do |arm_index|
          arm = WideGeometryArm.for_tag(arm_index.to_u8) ||
                raise ArgumentError.new("Geometry schedule arm tag is invalid")
          depth = arm.depth
          level_starts = Array(Array(UInt64)).new(depth) { [] of UInt64 }
          level_counts = Array(Array(UInt64)).new(depth) { [] of UInt64 }
          point_starts = [] of UInt64
          point_counts = [] of UInt64
          topology = arm == WideGeometryArm::Point ? nil : data.geo_array_data(arm).topology

          outer_start = 0
          lane_start = 0_u64
          mark_index = 0
          while mark_index < mark_count
            outer_rows = {rows_per_mark, data.row_count - outer_start}.min
            occurrences = 0_u64
            outer_rows.times do |offset|
              occurrences += 1_u64 if data.arm_at(outer_start + offset) == arm
            end

            if arm == WideGeometryArm::Point
              point_starts << lane_start
              point_counts << occurrences
            else
              current_start = lane_start
              current_count = occurrences
              depth.times do |level|
                level_starts[level] << current_start
                level_counts[level] << current_count
                if level + 1 < depth
                  current_end = checked_add(current_start, current_count, "Geometry nested range")
                  next_start = topology.not_nil!.offset_at(level, current_start.to_i)
                  next_end = topology.not_nil!.offset_at(level, current_end.to_i)
                  current_start = next_start
                  current_count = next_end - next_start
                end
              end
              current_end = checked_add(current_start, current_count, "Geometry Point range")
              point_starts << topology.not_nil!.offset_at(depth - 1, current_start.to_i)
              point_end = topology.not_nil!.offset_at(depth - 1, current_end.to_i)
              point_counts << point_end - point_starts.last
            end

            lane_start = checked_add(lane_start, occurrences, "Geometry arm lane prefix")
            outer_start += outer_rows
            mark_index += 1
          end

          arm_levels = levels[arm_index]
          depth.times do |level|
            arm_levels[level] = TupleLeafMarkSchedule.from_intervals(
              data.row_count.to_u64, rows_per_mark, level_starts[level], level_counts[level]
            )
          end
          levels[arm_index] = arm_levels
          coordinates[arm_index] = TupleLeafMarkSchedule.from_intervals(
            data.row_count.to_u64, rows_per_mark, point_starts, point_counts
          )
        end

        new(key_schedule, levels, coordinates)
      end

      def key_schedule : TupleLeafMarkSchedule
        @key_schedule
      end

      def size_schedule(arm : WideGeometryArm, level : Int) : TupleLeafMarkSchedule
        arm_index = checked_arm_index(arm)
        if level < 0 || level >= arm.depth
          raise BoundsError.new("Geometry size schedule level is out of bounds")
        end
        @size_schedules[arm_index][level] ||
          raise ArgumentError.new("Geometry size schedule is missing")
      end

      def coordinate_schedule(arm : WideGeometryArm) : TupleLeafMarkSchedule
        arm_index = checked_arm_index(arm)
        @coordinate_schedules[arm_index] ||
          raise ArgumentError.new("Geometry coordinate schedule is missing")
      end

      private def checked_arm_index(arm : WideGeometryArm) : Int32
        case arm
        when WideGeometryArm::LineString      then 0
        when WideGeometryArm::MultiLineString then 1
        when WideGeometryArm::MultiPolygon    then 2
        when WideGeometryArm::Point           then 3
        when WideGeometryArm::Polygon         then 4
        when WideGeometryArm::Ring            then 5
        when WideGeometryArm::MultiPoint      then 6
        else
          raise ArgumentError.new("Geometry schedule arm is invalid")
        end
      end

      private def self.checked_add(left : UInt64, right : UInt64, label : String) : UInt64
        raise ArgumentError.new("#{label} overflows UInt64") if right > UInt64::MAX - left
        left + right
      end

      private def self.checked_multiply(left : UInt64, right : UInt64, label : String) : UInt64
        raise ArgumentError.new("#{label} overflows UInt64") if right != 0 && left > UInt64::MAX // right
        left * right
      end
    end
  end
end
