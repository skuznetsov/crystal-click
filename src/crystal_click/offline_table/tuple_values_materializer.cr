module CrystalClick
  class OfflineTable
    # Owns non-exact W94 Tuple row accumulation and the corresponding bounded
    # materialization accounting. Row handles retain only their owned mark data.
    private class TupleValuesMaterializer
      def self.checked_expected_cells(expected_rows : UInt64, field_count : Int32, limit : UInt64) : UInt64
        raise CorruptPartError.new("selected Tuple has no fields") if field_count <= 0

        fields = field_count.to_u64
        if expected_rows > UInt64::MAX // fields
          raise BoundsError.new("selected column Tuple cell count overflows UInt64")
        end

        cells = expected_rows * fields
        if cells > limit
          raise BoundsError.new("selected column materialization exceeds Tuple cell limit")
        end
        cells
      end

      def self.append_rows(
        values : Array(OfflineColumnValue),
        batch : WidePartTableBatch,
        column_name : String,
        observed_rows : UInt64,
        expected_rows : UInt64,
        observed_string_bytes : UInt64,
        max_string_bytes : UInt64,
        expected_field_count : Int32,
      ) : {UInt64, UInt64}
        rows = batch.tuple_rows_for(column_name)
        batch_rows = rows.size.to_u64
        if observed_rows > expected_rows || batch_rows > expected_rows - observed_rows
          raise CorruptPartError.new("observed selected column row count exceeds preflight count")
        end

        string_bytes = observed_string_bytes
        rows.each do |row|
          unless row.field_count == expected_field_count
            raise CorruptPartError.new("observed Tuple row field count differs from preflight schema")
          end

          row_string_bytes = row.string_bytesize
          if string_bytes > max_string_bytes || row_string_bytes > max_string_bytes - string_bytes
            raise BoundsError.new("selected column materialization exceeds String payload limit")
          end
          string_bytes += row_string_bytes
          values << row
        end

        {observed_rows + batch_rows, string_bytes}
      end
    end
  end
end
