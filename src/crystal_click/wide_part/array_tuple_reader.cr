module CrystalClick
  class WidePart
    # Owns ragged outer-row schedule preparation while delegating scalar leaf
    # decoding and Nullable semantics to the existing TupleReader.
    private class ArrayTupleReader
      alias ReadOuterMark = Proc(Int32, {Array(UInt64), UInt64, UInt64, Array(UInt64)})
      alias ReadOuterRange = Proc(Int32, Int32, {Array(UInt64), UInt64, UInt64, Array(UInt64)})
      alias ValidateMark = Proc(Int32, UInt64, UInt64, Nil)
      alias CheckRange = Proc(Int32, Int32, {Int32, Int32})
      alias ReaderFactory = Proc(WideArrayTupleSchedule, Int32, TupleReader)

      @plan : WideArrayTupleTypePlan
      @read_outer_mark : ReadOuterMark
      @read_outer_range : ReadOuterRange
      @validate_mark : ValidateMark
      @check_range : CheckRange
      @reader_factory : ReaderFactory

      def initialize(
        @plan : WideArrayTupleTypePlan,
        @read_outer_mark : ReadOuterMark,
        @read_outer_range : ReadOuterRange,
        @validate_mark : ValidateMark,
        @check_range : CheckRange,
        @reader_factory : ReaderFactory,
      )
      end

      def read(
        first_mark : Int,
        mark_count : Int,
        max_materialized_bytes : UInt64,
      ) : WideArrayTupleColumnData
        validate_budget(max_materialized_bytes)
        checked_first, checked_count = checked_range(first_mark, mark_count)
        schedule = build_schedule(checked_first, checked_count, max_materialized_bytes, true)
        if schedule.outer_rows > WidePart::MAX_ARRAY_MARK_ROWS ||
           schedule.elements > WidePart::MAX_ARRAY_MARK_ELEMENTS
          raise CorruptPartError.new("Array(Tuple) selected range exceeds materialization limit")
        end
        row_sizes, elements, outer_rows, mark_elements = @read_outer_range.call(checked_first, checked_count)
        unless row_sizes.size.to_u64 == outer_rows && elements == schedule.elements &&
               outer_rows == schedule.outer_rows && mark_elements.size == checked_count
          raise CorruptPartError.new("Array(Tuple) selected size schedule changed")
        end
        mark_elements.each_with_index do |mark_element_count, relative_mark|
          unless mark_element_count == schedule.element_count_at(relative_mark).to_u64
            raise CorruptPartError.new("Array(Tuple) per-mark element schedule changed")
          end
        end

        tuple_data = @reader_factory.call(schedule, checked_first).read(
          checked_first,
          checked_count,
          max_materialized_bytes
        )
        WideArrayTupleColumnData.new(@plan, row_sizes, tuple_data)
      end

      def each(
        first_mark : Int,
        mark_count : Int,
        max_materialized_bytes : UInt64,
        &block : WideArrayTupleColumnData, Int32 -> Nil
      ) : Nil
        validate_budget(max_materialized_bytes)
        checked_first, checked_count = checked_range(first_mark, mark_count)
        schedule = build_schedule(checked_first, checked_count, max_materialized_bytes, false)
        reader = @reader_factory.call(schedule, checked_first)
        checked_count.times do |offset|
          mark_index = checked_first + offset
          row_sizes, elements, outer_rows, mark_elements = @read_outer_mark.call(mark_index)
          relative_mark = mark_index - checked_first
          unless row_sizes.size.to_u64 == outer_rows &&
                 elements == schedule.element_count_at(relative_mark) &&
                 outer_rows == schedule.row_count_at(relative_mark) &&
                 mark_elements.size == 1 && mark_elements.first == elements
            raise CorruptPartError.new("Array(Tuple) mark size schedule changed")
          end
          tuple_data = reader.read(mark_index, 1, max_materialized_bytes)
          yield WideArrayTupleColumnData.new(@plan, row_sizes, tuple_data), mark_index
          nil
        end
        nil
      end

      def materialization_charge(
        first_mark : Int,
        mark_count : Int,
        max_materialized_bytes : UInt64,
      ) : UInt64
        validate_budget(max_materialized_bytes)
        checked_first, checked_count = checked_range(first_mark, mark_count)
        schedule = build_schedule(checked_first, checked_count, max_materialized_bytes, true)
        if schedule.outer_rows > WidePart::MAX_ARRAY_MARK_ROWS ||
           schedule.elements > WidePart::MAX_ARRAY_MARK_ELEMENTS
          raise CorruptPartError.new("Array(Tuple) selected range exceeds materialization limit")
        end
        @reader_factory.call(schedule, checked_first).materialization_charge(
          checked_first,
          checked_count,
          max_materialized_bytes
        )
      end

      private def validate_budget(max_materialized_bytes : UInt64) : Nil
        if max_materialized_bytes > WideTupleTypePlan::MAX_MATERIALIZED_BYTES
          raise ArgumentError.new("Array(Tuple) materialization budget cannot exceed 64 MiB")
        end
      end

      private def checked_range(first_mark : Int, mark_count : Int) : {Int32, Int32}
        if first_mark < 0 || mark_count < 0
          raise BoundsError.new("negative mark range")
        end
        if first_mark > Int32::MAX || mark_count > Int32::MAX
          raise BoundsError.new("Array(Tuple) mark range exceeds supported index range")
        end
        @check_range.call(first_mark.to_i32, mark_count.to_i32)
      end

      private def build_schedule(
        first_mark : Int32,
        mark_count : Int32,
        max_materialized_bytes : UInt64,
        full_range : Bool,
      ) : WideArrayTupleSchedule
        schedule_charge = WideArrayTupleSchedule.logical_charge_for_mark_count(mark_count) ||
                          raise(CorruptPartError.new("Array(Tuple) schedule charge overflows"))
        minimum_charge = @plan.materialization_charge(0_u64, 0_u64, 0_u64, schedule_charge) ||
                         raise(CorruptPartError.new("Array(Tuple) materialization charge overflows"))
        if minimum_charge > max_materialized_bytes
          raise CorruptPartError.new("Array(Tuple) materialization charge exceeds per-range limit")
        end

        total_rows = 0_u64
        total_elements = 0_u64
        WideArrayTupleSchedule.build(mark_count, max_materialized_bytes) do |offset|
          mark_index = first_mark + offset
          row_sizes, elements, rows, mark_elements = @read_outer_mark.call(mark_index)
          unless row_sizes.size.to_u64 == rows && mark_elements.size == 1 && mark_elements.first == elements
            raise CorruptPartError.new("Array(Tuple) size0 mark does not match its row schedule")
          end

          if rows > UInt64::MAX - total_rows || elements > UInt64::MAX - total_elements
            raise CorruptPartError.new("Array(Tuple) selected schedule count overflows")
          end
          candidate_rows = total_rows + rows
          candidate_elements = total_elements + elements
          charge_rows = full_range ? candidate_rows : rows
          charge_elements = full_range ? candidate_elements : elements
          if full_range && (candidate_rows > WidePart::MAX_ARRAY_MARK_ROWS ||
             candidate_elements > WidePart::MAX_ARRAY_MARK_ELEMENTS)
            raise CorruptPartError.new("Array(Tuple) selected range exceeds materialization limit")
          end
          row_charge = @plan.materialization_charge(charge_rows, charge_elements, 0_u64, schedule_charge) ||
                       raise(CorruptPartError.new("Array(Tuple) materialization charge overflows"))
          if row_charge > max_materialized_bytes
            raise CorruptPartError.new("Array(Tuple) materialization charge exceeds per-range limit")
          end
          @validate_mark.call(mark_index, rows, elements)
          total_rows = candidate_rows
          total_elements = candidate_elements
          {rows.to_i32, elements.to_i32}
        end
      end
    end

    def self.supports_named_array_tuple_type?(type : String) : Bool
      !WideArrayTupleTypePlan.for_type(type).nil?
    end

    # Read an owned mark range for the admitted outer Array(Tuple(...))
    # profile. Legacy W51/W55 methods keep their original dispatch and return
    # types; this API always returns the compositional model.
    def read_array_tuple_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      max_materialized_bytes : UInt64 = WideTupleTypePlan::MAX_MATERIALIZED_BYTES,
    ) : WideArrayTupleColumnData
      plan, reader = array_tuple_reader_for_column(column, first_mark, mark_count)
      reader.read(first_mark, mark_count, max_materialized_bytes)
    end

    # Validate selected physical schedules and byte extents before the first
    # callback, then expose one owned outer mark at a time. Result/payload
    # charging is per mark plus the retained selected-range schedule.
    def each_array_tuple_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      max_materialized_bytes : UInt64 = WideTupleTypePlan::MAX_MATERIALIZED_BYTES,
      &block : WideArrayTupleColumnData, Int32 -> Nil
    ) : Nil
      _plan, reader = array_tuple_reader_for_column(column, first_mark, mark_count)
      reader.each(first_mark, mark_count, max_materialized_bytes) do |data, mark_index|
        yield data, mark_index
        nil
      end
      nil
    end

    def array_tuple_mark_range_materialization_charge(
      column : String,
      first_mark : Int,
      mark_count : Int,
      max_materialized_bytes : UInt64 = WideTupleTypePlan::MAX_MATERIALIZED_BYTES,
    ) : UInt64
      _plan, reader = array_tuple_reader_for_column(column, first_mark, mark_count)
      reader.materialization_charge(first_mark, mark_count, max_materialized_bytes)
    end

    private def ensure_named_array_tuple_column(column : String) : WideArrayTupleTypePlan
      ensure_column(column)
      plan = WideArrayTupleTypePlan.for_type(@column_type) ||
             raise(UnsupportedFormatError.new("Array(Tuple) accessor requires an admitted named Array(Tuple) declaration"))
      plan.physical_streams(column).each do |stream_name|
        raise CorruptPartError.new("Array(Tuple) planned child stream is missing: #{stream_name}") unless @streams.has_key?(stream_name)
      end
      plan
    end

    private def array_tuple_reader_for_column(
      column : String,
      first_mark : Int,
      mark_count : Int,
    ) : {WideArrayTupleTypePlan, ArrayTupleReader}
      plan = ensure_named_array_tuple_column(column)
      array_tuple_storage_reader_for_plan(plan, column, first_mark, mark_count)
    end

    private def array_tuple_storage_reader_for_plan(
      plan : WideArrayTupleTypePlan,
      column : String,
      first_mark : Int,
      mark_count : Int,
    ) : {WideArrayTupleTypePlan, ArrayTupleReader}
      array_tuple_reader_checked_range(plan, column, first_mark, mark_count)

      reader = ArrayTupleReader.new(
        plan,
        ->(mark_index : Int32) {
          read_array_outer_sizes(column, mark_index, 1, plan.outer_size_stream(column))
        },
        ->(range_first : Int32, range_count : Int32) {
          read_array_outer_sizes(column, range_first, range_count, plan.outer_size_stream(column))
        },
        ->(mark_index : Int32, outer_rows : UInt64, elements : UInt64) {
          validate_array_tuple_mark(column, plan, mark_index, outer_rows, elements)
        },
        ->(range_first : Int32, range_count : Int32) {
          array_tuple_reader_checked_range(plan, column, range_first.to_i, range_count.to_i)
        },
        ->(schedule : WideArrayTupleSchedule, schedule_first : Int32) {
          logical_rows = ->(range_first : Int32, range_count : Int32) {
            relative_first = range_first - schedule_first
            schedule.elements_in(relative_first, range_count)
          }
          combined_charge = ->(outer_rows : UInt64, elements : UInt64, payload_bytes : UInt64) {
            plan.materialization_charge(outer_rows, elements, payload_bytes, schedule.logical_charge)
          }
          read_range = ->(stream_name : String, range_first : Int32, range_count : Int32, expected_bytes : Int32, width : Int32, _logical_rows : UInt64) {
            relative_first = range_first - schedule_first
            physical_rows = schedule.outer_rows_in(relative_first, range_count)
            tuple_reader_read_range(stream_name, range_first, range_count, expected_bytes, width, physical_rows)
          }
          validate_range = ->(stream_name : String, range_first : Int32, range_count : Int32, expected_bytes : Int32, width : Int32, _logical_rows : UInt64) {
            relative_first = range_first - schedule_first
            physical_rows = schedule.outer_rows_in(relative_first, range_count)
            tuple_reader_validate_range(stream_name, range_first, range_count, expected_bytes, width, physical_rows)
          }
          tuple_reader(plan.tuple_plan, column, logical_rows, combined_charge, read_range, validate_range)
        }
      )
      {plan, reader}
    end

    private def array_tuple_reader_checked_range(
      plan : WideArrayTupleTypePlan,
      column : String,
      first_mark : Int,
      mark_count : Int,
    ) : {Int32, Int32}
      plan.physical_streams(column).each do |stream_name|
        checked_stream_mark_range(@streams[stream_name], first_mark, mark_count)
      end
      if first_mark > Int32::MAX || mark_count > Int32::MAX
        raise BoundsError.new("Array(Tuple) mark range exceeds supported index range")
      end
      {first_mark.to_i32, mark_count.to_i32}
    end

    # Every physical leaf stream has the outer-row mark schedule, even though
    # fixed-width bytes, String sizes and Nullable masks are counted in
    # flattened Tuple elements. Check both axes independently per mark.
    private def validate_array_tuple_mark(
      column : String,
      plan : WideArrayTupleTypePlan,
      mark_index : Int32,
      outer_rows : UInt64,
      elements : UInt64,
    ) : Nil
      mark_elements = [elements]
      plan.tuple_plan.fields.each do |field|
        leaf_stream = plan.leaf_stream_name(column, field)
        leaf_type = field.leaf_type
        if leaf_type.base_type_name == "String"
          read_array_string_element_sizes(
            leaf_stream,
            mark_index,
            1,
            elements,
            outer_rows,
            mark_elements,
            "Array(Tuple(String))",
            "#{leaf_stream}.size",
            leaf_stream
          )
          if leaf_type.nullable?
            null_stream = @streams["#{leaf_stream}.null"]
            _, _, rows = checked_stream_mark_range(null_stream, mark_index, 1)
            raise CorruptPartError.new("Array(Tuple(Nullable(String))) null-map mark rows differ") unless rows == outer_rows
            validate_array_nested_stream_marks(null_stream, mark_index, mark_elements, 1)
          end
        else
          expected_streams = [] of {String, Int32}
          expected_streams << {"#{leaf_stream}.null", 1} if leaf_type.nullable?
          width = plan.stream_width(column, leaf_stream) ||
                  raise(CorruptPartError.new("Array(Tuple) leaf stream has no fixed width"))
          expected_streams << {leaf_stream, width}
          expected_streams.each do |stream_name, stream_width|
            stream = @streams[stream_name]
            _, _, rows = checked_stream_mark_range(stream, mark_index, 1)
            raise CorruptPartError.new("Array(Tuple) child substream mark rows differ") unless rows == outer_rows
            validate_array_nested_stream_marks(stream, mark_index, mark_elements, stream_width)
          end
        end
      end
      nil
    end
  end
end
