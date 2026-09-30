module CrystalClick
  class WidePartTable
    # Converts one selected compositional Tuple mark into row handles while
    # reusing WidePart's schedule checks, decoder, and charge calculation.
    private class TupleColumnAdapter
      ROW_ARRAY_ACCOUNTING_BYTES = 64_u64

      def self.generic_type?(type_name : String) : Bool
        WideTupleTypePlan.for_type(type_name).is_a?(WideTupleTypePlan) &&
          !WidePart.supports_tuple_uint64_string_type?(type_name)
      end

      def self.preflight_mark_charge(
        reader : WidePart,
        column : String,
        mark_index : Int,
        rows : UInt64,
        max_materialized_bytes : UInt64,
      ) : UInt64
        column_charge = reader.tuple_mark_range_materialization_charge(
          column,
          mark_index,
          1,
          max_materialized_bytes: max_materialized_bytes
        )
        checked_total_charge(column_charge, rows, max_materialized_bytes)
      end

      def self.materialize_mark(
        reader : WidePart,
        column : String,
        type_name : String,
        mark_index : Int,
        expected_rows : UInt64,
        expected_charge : UInt64,
        max_materialized_bytes : UInt64,
      ) : Tuple(Array(WideTupleRow), UInt64)
        data = reader.read_tuple_mark_range(
          column,
          mark_index,
          1,
          max_materialized_bytes: max_materialized_bytes
        )
        unless data.row_count.to_u64 == expected_rows
          raise CorruptPartError.new("selected Tuple mark row count changed")
        end

        plan = WideTupleTypePlan.for_type(type_name) ||
               raise(UnsupportedFormatError.new("selected Tuple type is not admitted by the compositional plan"))
        string_payload_bytes = 0_u64
        rows = Array(WideTupleRow).new(data.row_count)
        data.row_count.times do |index|
          row = data.row(index)
          row_bytes = row.string_bytesize
          if row_bytes > UInt64::MAX - string_payload_bytes
            raise CorruptPartError.new("Tuple String byte count overflows")
          end
          string_payload_bytes += row_bytes
          rows << row
        end

        column_charge = plan.materialization_charge(data.row_count.to_u64, string_payload_bytes) ||
                        raise(CorruptPartError.new("Tuple materialization charge overflows"))
        observed_charge = checked_total_charge(column_charge, data.row_count.to_u64, max_materialized_bytes)
        unless observed_charge == expected_charge
          raise CorruptPartError.new("selected Tuple materialization charge changed after preflight")
        end
        {rows, observed_charge}
      end

      # Private arithmetic helper is deliberately separate so tests can
      # exercise overflow and aggregate rejection through a spec-only wrapper.
      def self.checked_total_charge(
        column_charge : UInt64,
        rows : UInt64,
        max_materialized_bytes : UInt64,
      ) : UInt64
        row_size = sizeof(WideTupleRow).to_u64
        if row_size == 0_u64 || rows > (UInt64::MAX - ROW_ARRAY_ACCOUNTING_BYTES) // row_size
          raise CorruptPartError.new("Tuple table materialization charge overflows")
        end
        row_charge = ROW_ARRAY_ACCOUNTING_BYTES + rows * row_size
        if column_charge > UInt64::MAX - row_charge
          raise CorruptPartError.new("Tuple table materialization charge overflows")
        end
        total = column_charge + row_charge
        if total > max_materialized_bytes
          raise CorruptPartError.new("selected Tuple mark exceeds aggregate materialization limit")
        end
        total
      end
    end
  end
end
