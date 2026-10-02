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
