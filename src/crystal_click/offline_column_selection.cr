module CrystalClick
  # A selected offline column. Selection is metadata-only; values owns and
  # materializes the complete bounded projection when explicitly requested.
  class OfflineColumnSelection
    getter name : String

    @table : OfflineTable

    def initialize(@table : OfflineTable, name : String)
      @name = name.dup
    end

    def values(
      max_rows : UInt64 = OfflineTable::MAX_MATERIALIZED_VALUES_ROWS,
      max_string_bytes : UInt64 = OfflineTable::MAX_MATERIALIZED_VALUES_STRING_BYTES,
      max_tuple_cells : UInt64 = OfflineTable::MAX_MATERIALIZED_VALUES_TUPLE_CELLS,
    ) : Array(OfflineColumnValue)
      @table.materialize_selected_values(@name, max_rows, max_string_bytes, max_tuple_cells)
    end
  end
end
