module CrystalClick
  class WidePartTable
    # Converts one selected generic Map(Tuple) mark into ordered row handles
    # while charging the table-owned handle array on top of the reader result.
    private class MapTupleColumnAdapter
      def self.generic_type?(type_name : String) : Bool
        !WideMapTupleTypePlan.for_type(type_name).nil? && WideTypePlan.admitted(type_name).nil?
      end

      def self.preflight_mark_charge(
        reader : WidePart,
        column : String,
        mark_index : Int,
        expected_rows : UInt64,
        max_materialized_bytes : UInt64,
      ) : UInt64
        table_charge = table_rows_charge(expected_rows)
        if table_charge > max_materialized_bytes
          raise CorruptPartError.new("Map(Tuple) table materialization charge exceeds aggregate limit")
        end

        reader_charge = reader.map_tuple_mark_range_materialization_charge(
          column,
          mark_index,
          1,
          max_materialized_bytes - table_charge
        )
        checked_total_charge(reader_charge, expected_rows, max_materialized_bytes)
      end

      def self.materialize_mark(
        reader : WidePart,
        column : String,
        type_name : String,
        mark_index : Int,
        expected_rows : UInt64,
        expected_charge : UInt64,
        max_materialized_bytes : UInt64,
      ) : Tuple(Array(WideMapTupleRow), UInt64)
        table_charge = table_rows_charge(expected_rows)
        if table_charge > max_materialized_bytes
          raise CorruptPartError.new("Map(Tuple) table materialization charge exceeds aggregate limit")
        end
        data = reader.read_map_tuple_mark_range(
          column,
          mark_index,
          1,
          max_materialized_bytes - table_charge
        )
        unless data.row_count.to_u64 == expected_rows
          raise CorruptPartError.new("selected Map(Tuple) mark row count changed")
        end

        plan = WideMapTupleTypePlan.for_type(type_name) ||
               raise(UnsupportedFormatError.new("selected Map(Tuple) type is not admitted by the compositional plan"))
        key_string_bytes = data.key_string_bytesize

        value_string_bytes = 0_u64
        data.entry_count.times do |entry_index|
          bytes = data.tuple_data.row(entry_index).string_bytesize
          if bytes > UInt64::MAX - value_string_bytes
            raise CorruptPartError.new("Map(Tuple) String payload byte count overflows")
          end
          value_string_bytes += bytes
        end

        schedule_charge = WideMapTupleSchedule.logical_charge_for_mark_count(1) ||
                          raise(CorruptPartError.new("Map(Tuple) schedule charge overflows"))
        reader_charge = plan.materialization_charge(
          data.row_count.to_u64,
          data.entry_count.to_u64,
          key_string_bytes,
          value_string_bytes,
          schedule_charge
        ) || raise(CorruptPartError.new("Map(Tuple) materialization charge overflows"))
        observed_charge = checked_total_charge(reader_charge, data.row_count.to_u64, max_materialized_bytes)
        unless observed_charge == expected_charge
          raise CorruptPartError.new("selected Map(Tuple) materialization charge changed after preflight")
        end

        rows = Array(WideMapTupleRow).new(data.row_count) do |index|
          data.row(index)
        end
        {rows, observed_charge}
      end

      private def self.table_rows_charge(rows : UInt64) : UInt64
        row_size = sizeof(WideMapTupleRow).to_u64
        header = instance_sizeof(Array(WideMapTupleRow)).to_u64
        if row_size == 0_u64 || rows > (UInt64::MAX - header) // row_size
          raise CorruptPartError.new("Map(Tuple) table materialization charge overflows")
        end
        header + rows * row_size
      end

      private def self.checked_total_charge(
        reader_charge : UInt64,
        rows : UInt64,
        max_materialized_bytes : UInt64,
      ) : UInt64
        table_charge = table_rows_charge(rows)
        if reader_charge > UInt64::MAX - table_charge
          raise CorruptPartError.new("Map(Tuple) table materialization charge overflows")
        end
        total = reader_charge + table_charge
        if total > max_materialized_bytes
          raise CorruptPartError.new("selected Map(Tuple) mark exceeds aggregate materialization limit")
        end
        total
      end
    end
  end
end
