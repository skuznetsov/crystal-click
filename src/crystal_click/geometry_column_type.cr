module CrystalClick
  # Exact physical descriptor for the stock Geometry declaration. Typed part
  # admission remains independently guarded by the production reader gate.
  class GeometryColumnType
    MAX_MATERIALIZED_BYTES = 64_u64 * 1024_u64 * 1024_u64
    MAX_LOGICAL_ELEMENTS   = 65_536_u64

    def self.for_type(type_name : String) : GeometryColumnType?
      return nil unless type_name == "Geometry"
      new
    end

    def type_name : String
      "Geometry"
    end

    def discriminator_stream(column : String) : String
      "#{column}#{WideVariantTypePlanDescriptor::DISCRIMINATOR_SUFFIX}"
    end

    def physical_streams(column : String) : Array(Tuple(String, Int32))
      streams = [{discriminator_stream(column), 1}] of Tuple(String, Int32)
      {
        WideGeometryArm::LineString,
        WideGeometryArm::MultiLineString,
        WideGeometryArm::MultiPolygon,
        WideGeometryArm::Point,
        WideGeometryArm::Polygon,
        WideGeometryArm::Ring,
        WideGeometryArm::MultiPoint,
      }.each do |arm|
        child_column = "#{column}.#{arm.type_name}"
        child_streams = if arm == WideGeometryArm::Point
                          PointColumnType.for_type(arm.type_name).not_nil!.physical_streams(child_column)
                        else
                          GeoArrayColumnType.for_type(arm.type_name).not_nil!.physical_streams(child_column)
                        end
        streams.concat(child_streams)
      end
      streams
    end

    def stream_width(column : String, stream : String) : Int32?
      physical_streams(column).each do |candidate|
        return candidate[1] if candidate[0] == stream
      end
      nil
    end

    # Logical accounting for one retained Geometry result plus explicitly
    # supplied concurrently-live schedule and scratch storage. This bounds
    # storage; topology consistency is validated by the owning data model.
    def materialization_charge(
      outer_rows : UInt64,
      arm_level_counts : Array(Array(UInt64)),
      arm_point_counts : Array(UInt64),
      schedule_charge : UInt64 = 0_u64,
      scratch_bytes : UInt64 = 0_u64,
    ) : UInt64?
      return nil if outer_rows > MAX_LOGICAL_ELEMENTS
      return nil unless arm_level_counts.size == 7
      return nil unless arm_point_counts.size == 7

      total = instance_sizeof(GeometryColumnType).to_u64
      total = checked_add(total, instance_sizeof(WideGeometryColumnData).to_u64) || return nil
      total = checked_add(total, instance_sizeof(Array(UInt8)).to_u64) || return nil
      total = checked_add(total, instance_sizeof(Array(Int32)).to_u64) || return nil
      total = checked_add(total, instance_sizeof(Array(WidePointValue)).to_u64) || return nil

      occurrence_count = 0_u64
      arm_index = 0
      {
        WideGeometryArm::LineString,
        WideGeometryArm::MultiLineString,
        WideGeometryArm::MultiPolygon,
        WideGeometryArm::Point,
        WideGeometryArm::Polygon,
        WideGeometryArm::Ring,
        WideGeometryArm::MultiPoint,
      }.each do |arm|
        level_counts = arm_level_counts[arm_index]
        point_count = arm_point_counts[arm_index]
        return nil if point_count > MAX_LOGICAL_ELEMENTS
        return nil unless level_counts.size == arm.depth

        occurrences = if arm == WideGeometryArm::Point
                        point_count
                      else
                        level_counts[0]
                      end
        return nil if occurrences > MAX_LOGICAL_ELEMENTS
        occurrence_count = checked_add(occurrence_count, occurrences) || return nil
        return nil if occurrence_count > outer_rows

        level_counts.each do |count|
          return nil if count > MAX_LOGICAL_ELEMENTS
        end

        if arm == WideGeometryArm::Point
          total = checked_product(total, point_count, sizeof(WidePointValue).to_u64) || return nil
        else
          geo_plan = GeoArrayColumnType.for_type(arm.type_name) || return nil
          geo_charge = geo_plan.materialization_charge(level_counts, point_count) || return nil
          total = checked_add(total, geo_charge) || return nil
        end

        arm_index += 1
      end

      total = checked_product(total, outer_rows, sizeof(UInt8).to_u64) || return nil
      total = checked_product(total, outer_rows, sizeof(Int32).to_u64) || return nil
      total = checked_add(total, schedule_charge) || return nil
      total = checked_add(total, scratch_bytes) || return nil
      return nil if total > MAX_MATERIALIZED_BYTES
      total
    end

    # Logical storage retained by the Geometry reader's compact per-mark
    # shape summaries and aggregate decoded axis vectors. This helper is shared
    # with the staged writer so its full-range readback reservation accounts
    # for the same summary before any child payload is read.
    def reader_summary_charge(outer_rows_by_mark : Array(UInt64)) : UInt64?
      return nil if outer_rows_by_mark.empty?
      return nil if outer_rows_by_mark.size > Int32::MAX

      mark_count = outer_rows_by_mark.size.to_u64
      total = instance_sizeof(Array(StaticArray(UInt64, 16))).to_u64
      total = checked_product(
        total, mark_count, sizeof(StaticArray(UInt64, 16)).to_u64
      ) || return nil

      # Aggregate output keeps seven size-vector slots (Point is empty), ten
      # total size values, and a separate seven-value Point-count vector.
      total = checked_add(total, instance_sizeof(Array(Array(UInt64))).to_u64) || return nil
      total = checked_add(total, 7_u64 * sizeof(Pointer(Array(UInt64))).to_u64) || return nil
      total = checked_add(total, 7_u64 * instance_sizeof(Array(UInt64)).to_u64) || return nil
      total = checked_add(total, 10_u64 * sizeof(UInt64).to_u64) || return nil
      total = checked_add(total, instance_sizeof(Array(UInt64)).to_u64) || return nil
      total = checked_add(total, 7_u64 * sizeof(UInt64).to_u64) || return nil
      # Per-mark callback counts can coexist with the retained summary.
      total = checked_add(total, instance_sizeof(Array(UInt64)).to_u64) || return nil
      total = checked_add(total, 3_u64 * sizeof(UInt64).to_u64) || return nil
      return nil if total > MAX_MATERIALIZED_BYTES
      total
    end

    # Scratch live while the reader turns selected discriminator frames into
    # per-mark tag arrays, builds a schedule that copies those tags, and then
    # flattens the original tags for the returned owner. The input outer-row
    # vector remains live during schedule construction, as does one decoded
    # frame view while its current-mark tag vector is materialized.
    def reader_tag_scratch_charge(outer_rows_by_mark : Array(UInt64)) : UInt64?
      return nil if outer_rows_by_mark.empty?
      return nil if outer_rows_by_mark.size > Int32::MAX

      mark_count = outer_rows_by_mark.size.to_u64
      outer_rows = 0_u64
      max_mark_rows = 0_u64
      outer_rows_by_mark.each do |rows|
        return nil if rows > UInt64::MAX - outer_rows
        outer_rows += rows
        max_mark_rows = rows if rows > max_mark_rows
      end
      return nil if outer_rows > MAX_LOGICAL_ELEMENTS || max_mark_rows > MAX_LOGICAL_ELEMENTS

      # The reader's own row grid remains live while it copies tags into its
      # schedule. A staged writer may separately retain its input mark grid.
      total = instance_sizeof(Array(UInt64)).to_u64
      total = checked_product(total, mark_count, sizeof(UInt64).to_u64) || return nil

      total = checked_add(total, instance_sizeof(Array(Array(UInt8))).to_u64) || return nil
      total = checked_product(total, mark_count, sizeof(Pointer(Array(UInt8))).to_u64) || return nil
      total = checked_product(total, mark_count, instance_sizeof(Array(UInt8)).to_u64) || return nil
      total = checked_add(total, outer_rows) || return nil

      total = checked_add(total, instance_sizeof(Array(UInt8)).to_u64) || return nil
      total = checked_add(total, outer_rows) || return nil
      total = checked_add(total, instance_sizeof(Array(UInt8)).to_u64) || return nil
      total = checked_add(total, max_mark_rows) || return nil

      # Conservative logical allowance for the six-entry child-owner Hash
      # assembled immediately before WideGeometryColumnData construction.
      # This is a bounded directory reserve, not an allocator or RSS estimate.
      total = checked_add(total, 4_096_u64) || return nil

      total = checked_add(total, sizeof(Bytes).to_u64) || return nil
      frame_view_bytes = checked_add(max_mark_rows, 19_u64) || return nil
      total = checked_add(total, frame_view_bytes) || return nil
      return nil if total > MAX_MATERIALIZED_BYTES
      total
    end

    # Conservative full-window reader peak shared by the Geometry reader and
    # paired writer readback preflight. Child reader charges include each
    # nominal Geo Array lane's decoded result plus its full-range discovery
    # schedule/scratch. Summing all six child peaks intentionally over-reserves
    # compared with sequential lane processing, while avoiding a writer-side
    # estimate that can miss discriminator and sparse-mark schedule costs.
    # `summary_charge` and `scratch_bytes` are the Geometry reader's bounded
    # per-mark summaries and other concurrently-live buffers. This is logical
    # accounting, not an estimate of allocator overhead or process RSS.
    def reader_materialization_charge(
      outer_rows_by_mark : Array(UInt64),
      arm_level_counts : Array(Array(UInt64)),
      arm_point_counts : Array(UInt64),
      summary_charge : UInt64 = 0_u64,
      scratch_bytes : UInt64 = 0_u64,
    ) : UInt64?
      return nil if outer_rows_by_mark.empty?
      return nil if outer_rows_by_mark.size > Int32::MAX
      return nil unless arm_level_counts.size == 7
      return nil unless arm_point_counts.size == 7

      outer_rows = 0_u64
      outer_rows_by_mark.each do |rows|
        return nil if rows > UInt64::MAX - outer_rows
        outer_rows += rows
      end
      return nil if outer_rows > MAX_LOGICAL_ELEMENTS

      mark_count = outer_rows_by_mark.size
      geometry_schedule_charge = WideGeometryMarkSchedule.logical_charge_for_shape(outer_rows_by_mark) || return nil
      total = materialization_charge(outer_rows, arm_level_counts, arm_point_counts) || return nil
      total = checked_add(total, geometry_schedule_charge) || return nil

      arm_index = 0
      {
        WideGeometryArm::LineString,
        WideGeometryArm::MultiLineString,
        WideGeometryArm::MultiPolygon,
        WideGeometryArm::Point,
        WideGeometryArm::Polygon,
        WideGeometryArm::Ring,
        WideGeometryArm::MultiPoint,
      }.each do |arm|
        point_count = arm_point_counts[arm_index]
        lane_charge = if arm == WideGeometryArm::Point
                        point_schedule = checked_product(
                          instance_sizeof(Array(UInt64)).to_u64,
                          mark_count.to_u64,
                          sizeof(UInt64).to_u64
                        ) || return nil
                        point_plan = PointColumnType.for_type(arm.type_name) || return nil
                        point_plan.materialization_charge(point_count, point_schedule)
                      else
                        geo_plan = GeoArrayColumnType.for_type(arm.type_name) || return nil
                        geo_plan.reader_materialization_charge(
                          arm_level_counts[arm_index], point_count, mark_count
                        ) || return nil
                      end
        total = checked_add(total, lane_charge) || return nil
        arm_index += 1
      end

      total = checked_add(total, summary_charge) || return nil
      total = checked_add(total, scratch_bytes) || return nil
      return nil if total > MAX_MATERIALIZED_BYTES
      total
    rescue ArgumentError
      nil
    end

    private def checked_add(total : UInt64, amount : UInt64) : UInt64?
      return nil if amount > UInt64::MAX - total
      total + amount
    end

    private def checked_product(total : UInt64, count : UInt64, width : UInt64) : UInt64?
      return nil if width != 0_u64 && count > UInt64::MAX // width
      checked_add(total, count * width)
    end
  end
end
