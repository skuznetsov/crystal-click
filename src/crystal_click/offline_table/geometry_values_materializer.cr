module CrystalClick
  class OfflineTable
    # Catalog rows retain one immutable Geometry owner per physical mark. The
    # preflight conservatively reserves every one-mark reader peak plus its
    # table handles, in addition to the final result slots. This bounds the
    # logical construction peak without claiming allocator or process RSS.
    private class GeometryValuesMaterializer
      def self.materialize(
        table : OfflineTable,
        candidates : Array(OfflinePartCandidate),
        column : String,
        type_name : String,
        expected_rows : UInt64,
      ) : Array(OfflineColumnValue)
        limit = GeometryColumnType::MAX_MATERIALIZED_BYTES
        value_header = instance_sizeof(Array(OfflineColumnValue)).to_u64
        value_slot = sizeof(OfflineColumnValue).to_u64
        if value_header > limit || expected_rows > (limit - value_header) // value_slot
          raise BoundsError.new("Geometry catalog result exceeds logical materialization limit")
        end
        result_charge = value_header + expected_rows * value_slot

        # Validate every candidate mark before allocating the final result, so
        # a later malformed mark cannot follow an earlier exposed row.
        candidates.each do |candidate|
          reader = WidePart.open_typed(candidate.path, column: column)
          raise CorruptPartError.new("Geometry catalog schema changed") unless reader.column_type == type_name
          reader.validate_geometry_mark_range_structure(column, 0, reader.mark_count)
        end

        preflight_charge = result_charge
        candidates.each do |candidate|
          reader = WidePart.open_typed(candidate.path, column: column)
          raise CorruptPartError.new("Geometry catalog schema changed") unless reader.column_type == type_name
          reader.mark_row_counts.each_with_index do |mark_rows, mark_index|
            peak = reader.geometry_mark_range_materialization_charge(column, mark_index, 1, limit)
            handle_charge = geometry_handle_charge(mark_rows)
            if peak > limit - preflight_charge || handle_charge > limit - preflight_charge - peak
              raise BoundsError.new("Geometry catalog result exceeds logical materialization limit")
            end
            preflight_charge += peak + handle_charge
          end
        end

        values = Array(OfflineColumnValue).new(expected_rows.to_i)
        retained_charge = result_charge
        last_owner = nil.as(WideGeometryColumnData?)
        table.scan_typed([column]) do |batch|
          rows = batch.geometry_rows_for(column)
          if values.size.to_u64 > expected_rows || rows.size.to_u64 > expected_rows - values.size.to_u64
            raise CorruptPartError.new("Geometry catalog row count changed")
          end
          rows.each do |row|
            raise CorruptPartError.new("Geometry catalog nominal identity changed") unless row.type_name == type_name
            owner = row.data
            raise CorruptPartError.new("Geometry catalog owner identity changed") unless owner.type_name == type_name
            unless owner.same?(last_owner)
              owner_charge = owner.retained_logical_charge
              if owner_charge > limit - retained_charge
                raise BoundsError.new("Geometry catalog retained owners exceed logical materialization limit")
              end
              retained_charge += owner_charge
              last_owner = owner
            end
            values << row
          end
          nil
        end unless candidates.empty?

        raise CorruptPartError.new("Geometry catalog retained charge exceeds conservative preflight") if retained_charge > preflight_charge
        raise CorruptPartError.new("Geometry catalog row count differs from preflight") unless values.size.to_u64 == expected_rows
        values
      end

      private def self.geometry_handle_charge(rows : UInt64) : UInt64
        header = instance_sizeof(Array(WideGeometryRow)).to_u64
        width = sizeof(WideGeometryRow).to_u64
        if width == 0_u64 || rows > (UInt64::MAX - header) // width
          raise BoundsError.new("Geometry catalog row-handle charge overflows")
        end
        header + rows * width
      end
    end
  end
end
