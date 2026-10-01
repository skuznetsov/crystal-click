module CrystalClick
  class WidePartTable
    # Retained row handles share one immutable, nominally typed mark owner.
    private class GeoArrayColumnAdapter
      def self.type?(type_name : String) : Bool
        !GeoArrayColumnType.for_type(type_name).nil?
      end

      def self.preflight_charge(
        reader : WidePart,
        column : String,
        mark_index : Int,
        expected_rows : UInt64,
        budget : UInt64,
      ) : UInt64
        handles = handle_charge(expected_rows)
        raise CorruptPartError.new("Geo Array table handles exceed aggregate materialization limit") if handles > budget
        charge = reader.geo_array_mark_range_materialization_charge(column, mark_index, 1, budget - handles)
        raise CorruptPartError.new("Geo Array table materialization charge overflows") if charge > UInt64::MAX - handles
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
      ) : {Array(WideGeoArrayRow), UInt64}
        charge = preflight_charge(reader, column, mark_index, expected_rows, budget)
        raise CorruptPartError.new("selected Geo Array charge changed after preflight") unless charge == expected_charge
        handles = handle_charge(expected_rows)
        raise CorruptPartError.new("selected Geo Array handles exceed the aggregate limit") if handles > budget
        data = reader.read_geo_array_mark_range(column, mark_index, 1, budget - handles)
        unless data.type_name == type_name && data.row_count.to_u64 == expected_rows
          raise CorruptPartError.new("selected Geo Array mark schema or row count changed")
        end
        plan = GeoArrayColumnType.for_type(type_name) ||
               raise(UnsupportedFormatError.new("selected Geo Array declaration is unsupported"))
        observed = plan.reader_materialization_charge(data.topology.level_counts, data.point_count.to_u64, 1) ||
                   raise(CorruptPartError.new("selected Geo Array observed charge exceeds the logical limit"))
        raise CorruptPartError.new("selected Geo Array observed charge exceeds the aggregate limit") if observed > budget - handles
        observed += handles
        unless observed == expected_charge
          raise CorruptPartError.new("selected Geo Array observed charge changed after preflight")
        end
        rows = Array(WideGeoArrayRow).new(data.row_count) { |index| data.row(index) }
        {rows, observed}
      end

      private def self.handle_charge(rows : UInt64) : UInt64
        header = instance_sizeof(Array(WideGeoArrayRow)).to_u64
        width = sizeof(WideGeoArrayRow).to_u64
        raise CorruptPartError.new("Geo Array table handle charge overflows") if rows > (UInt64::MAX - header) // width
        header + rows * width
      end
    end
  end
end
