module CrystalClick
  class WidePart
    # Nominal Nested entry points share W107's bounded ragged reader while
    # requiring exact Nested metadata and stream identity.
    def read_nested_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      max_materialized_bytes : UInt64 = WideTupleTypePlan::MAX_MATERIALIZED_BYTES,
    ) : WideArrayTupleColumnData
      _plan, reader = nested_reader_for_column(column, first_mark, mark_count)
      reader.read(first_mark, mark_count, max_materialized_bytes)
    end

    def each_nested_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      max_materialized_bytes : UInt64 = WideTupleTypePlan::MAX_MATERIALIZED_BYTES,
      &block : WideArrayTupleColumnData, Int32 -> Nil
    ) : Nil
      _plan, reader = nested_reader_for_column(column, first_mark, mark_count)
      reader.each(first_mark, mark_count, max_materialized_bytes) do |data, mark_index|
        yield data, mark_index
        nil
      end
      nil
    end

    def nested_mark_range_materialization_charge(
      column : String,
      first_mark : Int,
      mark_count : Int,
      max_materialized_bytes : UInt64 = WideTupleTypePlan::MAX_MATERIALIZED_BYTES,
    ) : UInt64
      _plan, reader = nested_reader_for_column(column, first_mark, mark_count)
      reader.materialization_charge(first_mark, mark_count, max_materialized_bytes)
    end

    private def nested_reader_for_column(
      column : String,
      first_mark : Int,
      mark_count : Int,
    ) : {WideNestedTypePlan, ArrayTupleReader}
      ensure_column(column)
      plan = WideNestedTypePlan.for_type(@column_type) ||
             raise(UnsupportedFormatError.new("Nested accessor requires an admitted nominal Nested declaration"))
      storage_plan = plan.storage_plan
      storage_plan.physical_streams(column).each do |stream_name|
        unless @streams.has_key?(stream_name)
          raise CorruptPartError.new("Nested planned child stream is missing: #{stream_name}")
        end
      end
      _storage, reader = array_tuple_storage_reader_for_plan(storage_plan, column, first_mark, mark_count)
      {plan, reader}
    end
  end
end
