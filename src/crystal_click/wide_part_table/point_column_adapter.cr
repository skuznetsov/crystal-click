module CrystalClick
  class WidePartTable
    # Keeps the fixed Point range reader's structural checks and charge
    # calculation out of the broad primitive dispatch.
    private class PointColumnAdapter
      def self.type?(column_type : String) : Bool
        !PointColumnType.for_type(column_type).nil?
      end

      def self.preflight_charge(
        reader : WidePart,
        column : String,
        mark_index : Int32,
        max_materialized_bytes : UInt64,
      ) : UInt64
        reader.point_mark_range_materialization_charge(
          column,
          mark_index,
          1,
          max_materialized_bytes
        )
      end

      def self.materialize_mark(
        reader : WidePart,
        column : String,
        mark_index : Int32,
        expected_rows : UInt64,
        expected_charge : UInt64,
        max_materialized_bytes : UInt64,
      ) : Tuple(Array(WidePointValue), UInt64)
        values = reader.read_point_mark_range(column, mark_index, 1, max_materialized_bytes)
        unless values.size.to_u64 == expected_rows
          raise CorruptPartError.new("selected Point mark row count changed")
        end
        observed_charge = reader.point_mark_range_materialization_charge(
          column,
          mark_index,
          1,
          max_materialized_bytes
        )
        unless observed_charge == expected_charge
          raise CorruptPartError.new("selected Point materialization charge changed after preflight")
        end
        {values, observed_charge}
      end
    end
  end
end
