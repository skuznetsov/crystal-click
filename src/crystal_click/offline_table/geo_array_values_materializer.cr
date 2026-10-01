module CrystalClick
  class OfflineTable
    # Catalog rows retain their immutable mark owner. Charge all source marks
    # before allocating the final array; ragged discovery reads size streams.
    private class GeoArrayValuesMaterializer
      def self.materialize(
        table : OfflineTable,
        candidates : Array(OfflinePartCandidate),
        column : String,
        type_name : String,
        expected_rows : UInt64,
      ) : Array(OfflineColumnValue)
        limit = GeoArrayColumnType::MAX_MATERIALIZED_BYTES
        header = instance_sizeof(Array(OfflineColumnValue)).to_u64
        slot = sizeof(OfflineColumnValue).to_u64
        raise BoundsError.new("Geo Array catalog result exceeds logical materialization limit") if expected_rows > (limit - header) // slot
        base_charge = header + expected_rows * slot
        preflight_charge = base_charge
        candidates.each do |candidate|
          reader = WidePart.open_typed(candidate.path, column: column)
          raise CorruptPartError.new("Geo Array catalog schema changed") unless reader.column_type == type_name
          reader.mark_row_counts.each_with_index do |mark_rows, index|
            charge = reader.geo_array_mark_range_materialization_charge(column, index, 1, limit)
            table_handles = instance_sizeof(Array(WideGeoArrayRow)).to_u64 + mark_rows * sizeof(WideGeoArrayRow).to_u64
            if charge > limit - preflight_charge || table_handles > limit - preflight_charge - charge
              raise BoundsError.new("Geo Array catalog result exceeds logical materialization limit")
            end
            preflight_charge += charge + table_handles
          end
        end

        values = Array(OfflineColumnValue).new(expected_rows.to_i)
        retained_charge = base_charge
        last_owner = nil.as(WideGeoArrayColumnData?)
        table.scan_typed([column]) do |batch|
          rows = batch.geo_array_rows_for(column)
          if values.size.to_u64 > expected_rows || rows.size.to_u64 > expected_rows - values.size.to_u64
            raise CorruptPartError.new("Geo Array catalog row count changed")
          end
          rows.each do |row|
            owner = row.data
            raise CorruptPartError.new("Geo Array catalog nominal identity changed") unless owner.type_name == type_name
            unless owner.same?(last_owner)
              charge = owner.retained_logical_charge
              raise BoundsError.new("Geo Array catalog retained owners exceed logical materialization limit") if charge > limit - retained_charge
              retained_charge += charge
              last_owner = owner
            end
            values << row
          end
        end unless candidates.empty?
        raise CorruptPartError.new("Geo Array catalog row count differs from preflight") unless values.size.to_u64 == expected_rows
        values
      end
    end
  end
end
