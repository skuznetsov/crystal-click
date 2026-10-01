module CrystalClick
  class WidePartTable
    # Converts one compositional Array(Tuple) mark into row handles while
    # preserving the separate outer-row and flattened-element axes.
    private class ArrayTupleColumnAdapter
      def self.generic_type?(type_name : String) : Bool
        !WideArrayTupleTypePlan.for_type(type_name).nil? &&
          WideTypePlan.admitted(type_name).nil?
      end

      def self.preflight_mark_charge(
        reader : WidePart,
        column : String,
        mark_index : Int,
        max_materialized_bytes : UInt64,
      ) : UInt64
        table_header = table_row_array_header_bytes
        if table_header > max_materialized_bytes
          raise CorruptPartError.new("Array(Tuple) table materialization charge exceeds aggregate limit")
        end

        reader_charge = reader.array_tuple_mark_range_materialization_charge(
          column,
          mark_index,
          1,
          max_materialized_bytes - table_header
        )
        checked_total_charge(reader_charge, max_materialized_bytes)
      end

      def self.materialize_mark(
        reader : WidePart,
        column : String,
        type_name : String,
        mark_index : Int,
        expected_rows : UInt64,
        expected_charge : UInt64,
        max_materialized_bytes : UInt64,
      ) : Tuple(Array(WideArrayTupleRow), UInt64)
        table_header = table_row_array_header_bytes
        if table_header > max_materialized_bytes
          raise CorruptPartError.new("Array(Tuple) table materialization charge exceeds aggregate limit")
        end

        data = reader.read_array_tuple_mark_range(
          column,
          mark_index,
          1,
          max_materialized_bytes - table_header
        )
        unless data.row_count.to_u64 == expected_rows
          raise CorruptPartError.new("selected Array(Tuple) mark row count changed")
        end

        plan = WideArrayTupleTypePlan.for_type(type_name) ||
               raise(UnsupportedFormatError.new("selected Array(Tuple) type is not admitted by the compositional plan"))
        string_payload_bytes = 0_u64
        data.row_count.times do |outer_index|
          data.row(outer_index).each do |tuple_row|
            row_bytes = tuple_row.string_bytesize
            if row_bytes > UInt64::MAX - string_payload_bytes
              raise CorruptPartError.new("selected Array(Tuple) String byte count overflows")
            end
            string_payload_bytes += row_bytes
          end
        end

        schedule_charge = WideArrayTupleSchedule.logical_charge_for_mark_count(1) ||
                          raise(CorruptPartError.new("Array(Tuple) schedule charge overflows"))
        reader_charge = plan.materialization_charge(
          data.row_count.to_u64,
          data.element_count.to_u64,
          string_payload_bytes,
          schedule_charge
        ) || raise(CorruptPartError.new("Array(Tuple) materialization charge overflows"))
        observed_charge = checked_total_charge(reader_charge, max_materialized_bytes)
        unless observed_charge == expected_charge
          raise CorruptPartError.new("selected Array(Tuple) materialization charge differs from preflight")
        end

        rows = Array(WideArrayTupleRow).new(data.row_count) do |index|
          data.row(index)
        end
        {rows, observed_charge}
      end

      private def self.table_row_array_header_bytes : UInt64
        # The plan already accounts for one row-handle slot per outer row;
        # this table-owned Array is an additional retained container.
        instance_sizeof(Array(WideArrayTupleRow)).to_u64
      end

      private def self.checked_total_charge(
        reader_charge : UInt64,
        max_materialized_bytes : UInt64,
      ) : UInt64
        table_header = table_row_array_header_bytes
        if reader_charge > UInt64::MAX - table_header
          raise CorruptPartError.new("Array(Tuple) table materialization charge overflows")
        end
        total = reader_charge + table_header
        if total > max_materialized_bytes
          raise CorruptPartError.new("selected Array(Tuple) mark exceeds aggregate materialization limit")
        end
        total
      end
    end
  end
end
