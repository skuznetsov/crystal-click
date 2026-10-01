module CrystalClick
  class OfflineTable
    # Accumulates bounded Array(Tuple) results while retaining one outer-row
    # handle per source row and accounting inner cells and all String payloads.
    private class ArrayTupleValuesMaterializer
      def self.append_rows(
        values : Array(OfflineColumnValue),
        batch : WidePartTableBatch,
        column_name : String,
        observed_rows : UInt64,
        expected_rows : UInt64,
        observed_elements : UInt64,
        observed_tuple_cells : UInt64,
        observed_string_bytes : UInt64,
        max_string_bytes : UInt64,
        max_tuple_cells : UInt64,
        expected_field_count : Int32,
      ) : {UInt64, UInt64, UInt64, UInt64}
        rows = batch.array_tuple_rows_for(column_name)
        batch_rows = rows.size.to_u64
        if observed_rows > expected_rows || batch_rows > expected_rows - observed_rows
          raise CorruptPartError.new("observed selected column row count exceeds preflight count")
        end

        elements = observed_elements
        tuple_cells = observed_tuple_cells
        string_bytes = observed_string_bytes
        rows.each do |outer_row|
          row_elements = outer_row.size.to_u64
          if elements > OfflineTable::MAX_MATERIALIZED_VALUES_ARRAY_ELEMENTS ||
             row_elements > OfflineTable::MAX_MATERIALIZED_VALUES_ARRAY_ELEMENTS - elements
            raise BoundsError.new("selected column materialization exceeds Array element limit")
          end
          elements += row_elements

          field_count = expected_field_count.to_u64
          if field_count == 0_u64 || row_elements > UInt64::MAX // field_count
            raise BoundsError.new("selected column Array(Tuple) cell count overflows UInt64")
          end
          row_cells = row_elements * field_count
          if tuple_cells > max_tuple_cells || row_cells > max_tuple_cells - tuple_cells
            raise BoundsError.new("selected column materialization exceeds Tuple cell limit")
          end
          tuple_cells += row_cells

          outer_row.each do |tuple_row|
            unless tuple_row.field_count == expected_field_count
              raise CorruptPartError.new("observed Array(Tuple) row field count differs from preflight schema")
            end
            row_string_bytes = tuple_row.string_bytesize
            if string_bytes > max_string_bytes || row_string_bytes > max_string_bytes - string_bytes
              raise BoundsError.new("selected column materialization exceeds String payload limit")
            end
            string_bytes += row_string_bytes
          end
          values << outer_row
        end

        {observed_rows + batch_rows, elements, tuple_cells, string_bytes}
      end
    end
  end
end
