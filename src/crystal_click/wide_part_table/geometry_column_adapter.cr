module CrystalClick
  class WidePartTable
    # Adds the borrowed per-row handles to the reader's conservative peak
    # charge. Geometry owners stay shared by the handles for one physical mark.
    private class GeometryColumnAdapter
      def self.type?(type_name : String) : Bool
        !GeometryColumnType.for_type(type_name).nil?
      end

      def self.preflight_charge(
        reader : WidePart,
        column : String,
        mark_index : Int,
        expected_rows : UInt64,
        budget : UInt64,
      ) : UInt64
        handles = handle_charge(expected_rows)
        raise CorruptPartError.new("Geometry table handles exceed aggregate materialization limit") if handles > budget
        charge = reader.geometry_mark_range_materialization_charge(column, mark_index, 1, budget - handles)
        raise CorruptPartError.new("Geometry table materialization charge overflows") if charge > UInt64::MAX - handles
        charge + handles
      end

      def self.materialize_mark(
        reader : WidePart,
        column : String,
        type_name : String,
        mark_index : Int,
        expected_rows : UInt64,
        expected_charge : UInt64,
        budget : UInt64,
      ) : {Array(WideGeometryRow), UInt64}
        charge = preflight_charge(reader, column, mark_index, expected_rows, budget)
        raise CorruptPartError.new("selected Geometry charge changed after preflight") unless charge == expected_charge

        handles = handle_charge(expected_rows)
        raise CorruptPartError.new("selected Geometry handles exceed aggregate materialization limit") if handles > budget
        data = reader.read_geometry_mark_range(column, mark_index, 1, budget - handles)
        unless data.type_name == type_name && data.row_count.to_u64 == expected_rows
          raise CorruptPartError.new("selected Geometry mark schema or row count changed")
        end

        retained = retained_owner_charge(data)
        unless retained == data.retained_logical_charge
          raise CorruptPartError.new("selected Geometry retained-owner charge changed")
        end
        raise CorruptPartError.new("selected Geometry owner exceeds reader peak charge") if retained > charge - handles

        rows = Array(WideGeometryRow).new(data.row_count) { |index| data.row(index) }
        {rows, charge}
      end

      private def self.retained_owner_charge(data : WideGeometryColumnData) : UInt64
        levels = Array(Array(UInt64)).new(7) { [] of UInt64 }
        points = Array(UInt64).new(7, 0_u64)
        {
          WideGeometryArm::LineString,
          WideGeometryArm::MultiLineString,
          WideGeometryArm::MultiPolygon,
          WideGeometryArm::Point,
          WideGeometryArm::Polygon,
          WideGeometryArm::Ring,
          WideGeometryArm::MultiPoint,
        }.each_with_index do |arm, arm_index|
          if arm == WideGeometryArm::Point
            points[arm_index] = data.arm_count(arm).to_u64
          else
            owner = data.geo_array_data(arm)
            unless owner.type_name == arm.type_name && owner.row_count == data.arm_count(arm)
              raise CorruptPartError.new("selected Geometry nominal child owner changed")
            end
            levels[arm_index] = owner.topology.level_counts
            points[arm_index] = owner.point_count.to_u64
          end
        end

        plan = GeometryColumnType.for_type("Geometry").not_nil!
        plan.materialization_charge(data.row_count.to_u64, levels, points) ||
          raise(CorruptPartError.new("selected Geometry retained-owner charge exceeds logical limit"))
      end

      private def self.handle_charge(rows : UInt64) : UInt64
        header = instance_sizeof(Array(WideGeometryRow)).to_u64
        width = sizeof(WideGeometryRow).to_u64
        raise CorruptPartError.new("Geometry table handle charge overflows") if width == 0_u64 || rows > (UInt64::MAX - header) // width
        header + rows * width
      end
    end
  end
end
