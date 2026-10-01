module CrystalClick
  class OfflineTable
    # Point values are retained as their nominal two-coordinate owner. Charge
    # the physical coordinate bytes, the reader result slots, and the separate
    # OfflineColumnValue output slots before allocating the whole-column array.
    class PointValuesMaterializer
      def self.checked_expected_charge(rows : UInt64, plan : PointColumnType) : UInt64
        reader_charge = begin
          plan.materialization_charge(rows)
        rescue ex : ArgumentError
          raise BoundsError.new("selected Point column materialization exceeds 64 MiB limit")
        end
        output_slot = sizeof(OfflineColumnValue).to_u64
        if rows > (PointColumnType::MAX_MATERIALIZED_BYTES - reader_charge) // output_slot
          raise BoundsError.new("selected Point column materialization exceeds 64 MiB limit")
        end
        total = reader_charge + rows * output_slot
        if total > PointColumnType::MAX_MATERIALIZED_BYTES
          raise BoundsError.new("selected Point column materialization exceeds 64 MiB limit")
        end
        total
      end

      def self.append_values(
        values : Array(OfflineColumnValue),
        batch : WidePartTableBatch,
        column_name : String,
        observed_rows : UInt64,
        expected_rows : UInt64,
      ) : UInt64
        points = batch.point_values_for(column_name)
        batch_rows = points.size.to_u64
        if observed_rows > expected_rows || batch_rows > expected_rows - observed_rows
          raise CorruptPartError.new("observed selected Point row count exceeds preflight count")
        end
        points.each { |point| values << point }
        observed_rows + batch_rows
      end
    end
  end
end
