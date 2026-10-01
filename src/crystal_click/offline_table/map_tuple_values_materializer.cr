module CrystalClick
  class OfflineTable
    # Accumulates generic Map(Tuple) rows without collapsing ordered entries
    # into a Hash. Entry and flattened Tuple-cell limits are enforced while
    # String accounting includes key and value payload bytes.
    private class MapTupleValuesMaterializer
      def self.append_rows(
        values : Array(OfflineColumnValue),
        batch : WidePartTableBatch,
        column_name : String,
        expected_type_name : String,
        expected_tuple_type_name : String,
        key_is_string : Bool,
        observed_rows : UInt64,
        expected_rows : UInt64,
        observed_entries : UInt64,
        observed_tuple_cells : UInt64,
        observed_string_bytes : UInt64,
        max_string_bytes : UInt64,
        max_tuple_cells : UInt64,
        expected_field_count : Int32,
      ) : {UInt64, UInt64, UInt64, UInt64}
        rows = batch.map_tuple_rows_for(column_name)
        batch_rows = rows.size.to_u64
        if observed_rows > expected_rows || batch_rows > expected_rows - observed_rows
          raise CorruptPartError.new("observed selected column row count exceeds preflight count")
        end

        entries = observed_entries
        tuple_cells = observed_tuple_cells
        string_bytes = observed_string_bytes
        rows.each do |map_row|
          unless map_row.type_name == expected_type_name
            raise CorruptPartError.new("observed Map(Tuple) row type differs from selected declaration")
          end
          row_entries = map_row.size.to_u64
          if entries > OfflineTable::MAX_MATERIALIZED_VALUES_ARRAY_ELEMENTS ||
             row_entries > OfflineTable::MAX_MATERIALIZED_VALUES_ARRAY_ELEMENTS - entries
            raise BoundsError.new("selected column materialization exceeds Array element limit")
          end
          entries += row_entries

          field_count = expected_field_count.to_u64
          if field_count == 0_u64 || row_entries > UInt64::MAX // field_count
            raise BoundsError.new("selected Map(Tuple) cell count overflows UInt64")
          end
          row_cells = row_entries * field_count
          if tuple_cells > max_tuple_cells || row_cells > max_tuple_cells - tuple_cells
            raise BoundsError.new("selected column materialization exceeds Tuple cell limit")
          end
          tuple_cells += row_cells

          entry_index = 0
          while entry_index < map_row.size
            if key_is_string
              key_bytes = map_row.key_string_bytesize_at(entry_index)
              if string_bytes > max_string_bytes || key_bytes > max_string_bytes - string_bytes
                raise BoundsError.new("selected column materialization exceeds String payload limit")
              end
              string_bytes += key_bytes
            end

            value_row = map_row.value_at(entry_index)
            unless value_row.type_name == expected_tuple_type_name && value_row.field_count == expected_field_count
              raise CorruptPartError.new("observed Map(Tuple) value schema differs from selected declaration")
            end
            row_string_bytes = value_row.string_bytesize
            if string_bytes > max_string_bytes || row_string_bytes > max_string_bytes - string_bytes
              raise BoundsError.new("selected column materialization exceeds String payload limit")
            end
            string_bytes += row_string_bytes
            entry_index += 1
          end
          values << map_row
        end

        {observed_rows + batch_rows, entries, tuple_cells, string_bytes}
      end
    end
  end
end
