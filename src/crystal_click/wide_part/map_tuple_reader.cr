module CrystalClick
  class WidePart
    # Owns Map row scheduling and ordered key/value assembly. Tuple value
    # semantics and scalar codecs are delegated to the shared TupleReader.
    private class MapTupleReader
      alias ReadOuterMark = Proc(Int32, {Array(UInt64), UInt64, UInt64, Array(UInt64)})
      alias ReadOuterRange = Proc(Int32, Int32, {Array(UInt64), UInt64, UInt64, Array(UInt64)})
      alias ReadKeyStringBytes = Proc(Int32, UInt64, UInt64, UInt64)
      alias ValidateKeyMark = Proc(Int32, UInt64, UInt64, UInt64, Nil)
      alias CheckRange = Proc(Int32, Int32, {Int32, Int32})
      alias TupleReaderFactory = Proc(WideMapTupleSchedule, Int32, Int32, Int32, TupleReader)
      alias ReadKeyRange = Proc(WideMapTupleSchedule, Int32, Int32, Int32, WideTupleLeafColumn)

      @plan : WideMapTupleTypePlan
      @column : String
      @read_outer_mark : ReadOuterMark
      @read_outer_range : ReadOuterRange
      @read_key_string_bytes : ReadKeyStringBytes
      @validate_key_mark : ValidateKeyMark
      @check_range : CheckRange
      @tuple_reader_factory : TupleReaderFactory
      @read_key_range : ReadKeyRange

      def initialize(
        @plan : WideMapTupleTypePlan,
        @column : String,
        @read_outer_mark : ReadOuterMark,
        @read_outer_range : ReadOuterRange,
        @read_key_string_bytes : ReadKeyStringBytes,
        @validate_key_mark : ValidateKeyMark,
        @check_range : CheckRange,
        @tuple_reader_factory : TupleReaderFactory,
        @read_key_range : ReadKeyRange,
      )
      end

      def read(
        first_mark : Int,
        mark_count : Int,
        max_materialized_bytes : UInt64,
      ) : WideMapTupleColumnData
        validate_budget(max_materialized_bytes)
        checked_first, checked_count = checked_range(first_mark, mark_count)
        schedule = build_schedule(checked_first, checked_count, max_materialized_bytes, true)
        tuple_reader = @tuple_reader_factory.call(schedule, checked_first, checked_first, checked_count)
        # Establish the complete key+Tuple range charge and all value-stream
        # boundaries before touching raw key frames or allocating either
        # result owner.
        tuple_reader.materialization_charge(checked_first, checked_count, max_materialized_bytes)
        validate_key_mark_boundaries(schedule, checked_first, checked_count)

        if schedule.outer_rows > WidePart::MAX_ARRAY_MARK_ROWS || schedule.entries > WidePart::MAX_ARRAY_MARK_ELEMENTS
          raise CorruptPartError.new("Map(Tuple) selected range exceeds materialization limit")
        end
        row_sizes, entries, outer_rows, mark_entries = @read_outer_range.call(checked_first, checked_count)
        unless row_sizes.size.to_u64 == outer_rows && entries == schedule.entries &&
               outer_rows == schedule.outer_rows && mark_entries.size == checked_count
          raise CorruptPartError.new("Map(Tuple) selected size schedule changed")
        end
        mark_entries.each_with_index do |mark_entry_count, relative_mark|
          unless mark_entry_count == schedule.entry_count_at(relative_mark).to_u64
            raise CorruptPartError.new("Map(Tuple) per-mark entry schedule changed")
          end
        end

        tuple_data = tuple_reader.read(
          checked_first,
          checked_count,
          max_materialized_bytes
        )
        key_column = @read_key_range.call(schedule, checked_first, checked_first, checked_count)
        WideMapTupleColumnData.new(@plan, key_column, tuple_data, row_sizes)
      end

      def each(
        first_mark : Int,
        mark_count : Int,
        max_materialized_bytes : UInt64,
        &block : WideMapTupleColumnData, Int32 -> Nil
      ) : Nil
        validate_budget(max_materialized_bytes)
        checked_first, checked_count = checked_range(first_mark, mark_count)
        schedule = build_schedule(checked_first, checked_count, max_materialized_bytes, false)
        validate_value_mark_boundaries(schedule, checked_first, checked_count, max_materialized_bytes)
        validate_key_mark_boundaries(schedule, checked_first, checked_count)
        checked_count.times do |offset|
          mark_index = checked_first + offset
          relative_mark = mark_index - checked_first
          row_sizes, entries, outer_rows, mark_entries = @read_outer_mark.call(mark_index)
          unless row_sizes.size.to_u64 == outer_rows &&
                 entries == schedule.entry_count_at(relative_mark).to_u64 &&
                 outer_rows == schedule.row_count_at(relative_mark).to_u64 &&
                 mark_entries.size == 1 && mark_entries.first == entries
            raise CorruptPartError.new("Map(Tuple) mark size schedule changed")
          end

          tuple_data = @tuple_reader_factory.call(schedule, checked_first, mark_index, 1).read(mark_index, 1, max_materialized_bytes)
          key_column = @read_key_range.call(schedule, checked_first, mark_index, 1)
          yield WideMapTupleColumnData.new(@plan, key_column, tuple_data, row_sizes), mark_index
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
        charge = @tuple_reader_factory.call(schedule, checked_first, checked_first, checked_count).materialization_charge(
          checked_first,
          checked_count,
          max_materialized_bytes
        )
        validate_key_mark_boundaries(schedule, checked_first, checked_count)
        charge
      end

      private def validate_budget(max_materialized_bytes : UInt64) : Nil
        if max_materialized_bytes > WideTupleTypePlan::MAX_MATERIALIZED_BYTES
          raise ArgumentError.new("Map(Tuple) materialization budget cannot exceed 64 MiB")
        end
      end

      private def checked_range(first_mark : Int, mark_count : Int) : {Int32, Int32}
        if first_mark < 0 || mark_count < 0
          raise BoundsError.new("negative mark range")
        end
        if first_mark > Int32::MAX || mark_count > Int32::MAX
          raise BoundsError.new("Map(Tuple) mark range exceeds supported index range")
        end
        @check_range.call(first_mark.to_i32, mark_count.to_i32)
      end

      private def build_schedule(
        first_mark : Int32,
        mark_count : Int32,
        max_materialized_bytes : UInt64,
        full_range : Bool,
      ) : WideMapTupleSchedule
        schedule_charge = WideMapTupleSchedule.logical_charge_for_mark_count(mark_count) ||
                          raise(CorruptPartError.new("Map(Tuple) schedule charge overflows"))
        minimum_charge = @plan.materialization_charge(0_u64, 0_u64, 0_u64, 0_u64, schedule_charge) ||
                         raise(CorruptPartError.new("Map(Tuple) materialization charge overflows"))
        if minimum_charge > max_materialized_bytes
          raise CorruptPartError.new("Map(Tuple) materialization charge exceeds per-range limit")
        end

        total_rows = 0_u64
        total_entries = 0_u64
        total_key_string_bytes = 0_u64
        WideMapTupleSchedule.build(mark_count, max_materialized_bytes) do |offset|
          mark_index = first_mark + offset
          row_sizes, entries, rows, mark_entries = @read_outer_mark.call(mark_index)
          unless row_sizes.size.to_u64 == rows && mark_entries.size == 1 && mark_entries.first == entries
            raise CorruptPartError.new("Map(Tuple) size0 mark does not match its entry schedule")
          end
          if rows > WidePart::MAX_ARRAY_MARK_ROWS || entries > WidePart::MAX_ARRAY_MARK_ELEMENTS
            raise CorruptPartError.new("Map(Tuple) mark exceeds materialization limit")
          end
          if rows > UInt64::MAX - total_rows || entries > UInt64::MAX - total_entries
            raise CorruptPartError.new("Map(Tuple) selected schedule count overflows")
          end
          candidate_rows = total_rows + rows
          candidate_entries = total_entries + entries
          if full_range && (candidate_rows > WidePart::MAX_ARRAY_MARK_ROWS ||
             candidate_entries > WidePart::MAX_ARRAY_MARK_ELEMENTS)
            raise CorruptPartError.new("Map(Tuple) selected range exceeds materialization limit")
          end

          # The key size stream is structural metadata and is needed to know
          # the complete retained payload charge. Do not inspect/decompress
          # the raw key stream until the combined key+Tuple charge is admitted.
          key_string_bytes = @read_key_string_bytes.call(mark_index, rows, entries)
          if key_string_bytes > UInt64::MAX - total_key_string_bytes
            raise CorruptPartError.new("Map(Tuple) selected key bytes overflow")
          end
          candidate_key_string_bytes = total_key_string_bytes + key_string_bytes
          charge_rows = full_range ? candidate_rows : rows
          charge_entries = full_range ? candidate_entries : entries
          charge_key_bytes = full_range ? candidate_key_string_bytes : key_string_bytes
          charge = @plan.materialization_charge(
            charge_rows,
            charge_entries,
            charge_key_bytes,
            0_u64,
            schedule_charge
          ) || raise(CorruptPartError.new("Map(Tuple) materialization charge overflows"))
          if charge > max_materialized_bytes
            raise CorruptPartError.new("Map(Tuple) materialization charge exceeds per-range limit")
          end
          total_rows = candidate_rows
          total_entries = candidate_entries
          total_key_string_bytes = candidate_key_string_bytes
          {rows.to_i32, entries.to_i32, key_string_bytes}
        end
      end

      # Physical key/value child byte boundaries are checked across the whole
      # selected range before the first lazy callback. The key sizes were
      # already read to compute the combined charge; this pass checks the raw
      # key extent without constructing key values.
      private def validate_key_mark_boundaries(
        schedule : WideMapTupleSchedule,
        first_mark : Int32,
        mark_count : Int32,
      ) : Nil
        mark_count.times do |offset|
          mark_index = first_mark + offset
          relative_mark = mark_index - first_mark
          @validate_key_mark.call(
            mark_index,
            schedule.row_count_at(relative_mark).to_u64,
            schedule.entry_count_at(relative_mark).to_u64,
            schedule.key_string_bytes_at(relative_mark)
          )
        end
      end

      # TupleReader performs selected-wide and per-mark value stream checks.
      # Repeating the mark-local preflight here ensures equal aggregate byte
      # totals cannot hide a shifted later mark boundary before callbacks.
      private def validate_value_mark_boundaries(
        schedule : WideMapTupleSchedule,
        first_mark : Int32,
        mark_count : Int32,
        max_materialized_bytes : UInt64,
      ) : Nil
        mark_count.times do |offset|
          mark_index = first_mark + offset
          @tuple_reader_factory.call(schedule, first_mark, mark_index, 1).materialization_charge(
            mark_index,
            1,
            max_materialized_bytes
          )
        end
      end
    end

    def self.supports_named_map_tuple_type?(type : String) : Bool
      !WideMapTupleTypePlan.for_type(type).nil?
    end

    # Read one owned range for the generic BASIC Map(K, Tuple(...)) profile.
    # Legacy Map accessors retain their existing dispatch and return types.
    def read_map_tuple_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      max_materialized_bytes : UInt64 = WideTupleTypePlan::MAX_MATERIALIZED_BYTES,
    ) : WideMapTupleColumnData
      _plan, reader = map_tuple_reader_for_column(column, first_mark, mark_count)
      reader.read(first_mark, mark_count, max_materialized_bytes)
    end

    # Validate selected physical boundaries before the first callback, while
    # allocating only one outer mark's rows and entry payload at a time.
    def each_map_tuple_mark_range(
      column : String,
      first_mark : Int,
      mark_count : Int,
      max_materialized_bytes : UInt64 = WideTupleTypePlan::MAX_MATERIALIZED_BYTES,
      &block : WideMapTupleColumnData, Int32 -> Nil
    ) : Nil
      _plan, reader = map_tuple_reader_for_column(column, first_mark, mark_count)
      reader.each(first_mark, mark_count, max_materialized_bytes) do |data, mark_index|
        yield data, mark_index
        nil
      end
      nil
    end

    def map_tuple_mark_range_materialization_charge(
      column : String,
      first_mark : Int,
      mark_count : Int,
      max_materialized_bytes : UInt64 = WideTupleTypePlan::MAX_MATERIALIZED_BYTES,
    ) : UInt64
      _plan, reader = map_tuple_reader_for_column(column, first_mark, mark_count)
      reader.materialization_charge(first_mark, mark_count, max_materialized_bytes)
    end

    private def ensure_map_tuple_column(column : String) : WideMapTupleTypePlan
      ensure_column(column)
      plan = WideMapTupleTypePlan.for_type(@column_type) ||
             raise(UnsupportedFormatError.new("Map(Tuple) accessor requires an admitted Map(K, named Tuple(...)) declaration"))
      plan.physical_streams(column).each do |stream_name|
        raise CorruptPartError.new("Map(Tuple) planned child stream is missing: #{stream_name}") unless @streams.has_key?(stream_name)
      end
      plan
    end

    private def map_tuple_reader_for_column(
      column : String,
      first_mark : Int,
      mark_count : Int,
    ) : {WideMapTupleTypePlan, MapTupleReader}
      plan = ensure_map_tuple_column(column)
      map_tuple_reader_checked_range(plan, column, first_mark, mark_count)

      reader = MapTupleReader.new(
        plan,
        column,
        ->(mark_index : Int32) {
          read_array_outer_sizes(column, mark_index, 1, plan.outer_size_stream(column))
        },
        ->(range_first : Int32, range_count : Int32) {
          read_array_outer_sizes(column, range_first, range_count, plan.outer_size_stream(column))
        },
        ->(mark_index : Int32, outer_rows : UInt64, entries : UInt64) {
          read_map_tuple_key_string_bytes(plan, column, mark_index, outer_rows, entries)
        },
        ->(mark_index : Int32, outer_rows : UInt64, entries : UInt64, key_string_bytes : UInt64) {
          validate_map_tuple_key_mark(plan, column, mark_index, outer_rows, entries, key_string_bytes)
        },
        ->(range_first : Int32, range_count : Int32) {
          map_tuple_reader_checked_range(plan, column, range_first.to_i, range_count.to_i)
        },
        ->(schedule : WideMapTupleSchedule, schedule_first : Int32, range_first : Int32, range_count : Int32) {
          logical_rows = ->(range_first : Int32, range_count : Int32) {
            relative_first = range_first - schedule_first
            schedule.entries_in(relative_first, range_count)
          }
          combined_charge = ->(outer_rows : UInt64, entries : UInt64, value_string_bytes : UInt64) {
            relative_first = range_first - schedule_first
            schedule_outer_rows = schedule.outer_rows_in(relative_first, range_count)
            schedule_key_bytes = schedule.key_string_bytes_in(relative_first, range_count)
            raise CorruptPartError.new("Map(Tuple) outer-row schedule changed") unless outer_rows == schedule_outer_rows
            plan.materialization_charge(
              outer_rows,
              entries,
              schedule_key_bytes,
              value_string_bytes,
              schedule.logical_charge
            )
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
          tuple_reader(plan.tuple_plan, plan.value_column_prefix(column), logical_rows, combined_charge, read_range, validate_range)
        },
        ->(schedule : WideMapTupleSchedule, schedule_first : Int32, range_first : Int32, range_count : Int32) {
          read_map_tuple_keys(plan, column, schedule, schedule_first, range_first, range_count)
        }
      )
      {plan, reader}
    end

    private def map_tuple_reader_checked_range(
      plan : WideMapTupleTypePlan,
      column : String,
      first_mark : Int,
      mark_count : Int,
    ) : {Int32, Int32}
      if first_mark < 0 || mark_count < 0
        raise BoundsError.new("negative mark range")
      end
      if first_mark > Int32::MAX || mark_count > Int32::MAX
        raise BoundsError.new("Map(Tuple) mark range exceeds supported index range")
      end
      streams = plan.physical_streams(column)
      reference_name = plan.outer_size_stream(column)
      reference = @streams[reference_name]
      _start, _finish, reference_rows = checked_stream_mark_range(reference, first_mark, mark_count)
      streams.each do |stream_name|
        stream = @streams[stream_name]
        _stream_start, _stream_finish, stream_rows = checked_stream_mark_range(stream, first_mark, mark_count)
        unless stream_rows == reference_rows
          raise CorruptPartError.new("Map(Tuple) child substream mark rows differ")
        end
      end
      mark_count.times do |offset|
        expected_mark_rows = reference.marks[first_mark + offset].rows
        streams.each do |stream_name|
          stream = @streams[stream_name]
          unless stream.marks[first_mark + offset].rows == expected_mark_rows
            raise CorruptPartError.new("Map(Tuple) child substream mark rows differ")
          end
        end
      end
      {first_mark.to_i32, mark_count.to_i32}
    end

    private def read_map_tuple_key_string_bytes(
      plan : WideMapTupleTypePlan,
      column : String,
      mark_index : Int32,
      outer_rows : UInt64,
      entries : UInt64,
    ) : UInt64
      if plan.key_type.base_type_name == "String"
        _sizes, total_bytes = read_map_tuple_key_sizes_for_mark(plan, column, mark_index, outer_rows, entries)
        return total_bytes
      end
      if width = map_tuple_key_fixed_string_width(plan.key_type)
        return 0_u64 if entries == 0_u64
        raise CorruptPartError.new("Map(Tuple) FixedString key bytes overflow") if entries > UInt64::MAX // width.to_u64
        return entries * width.to_u64
      end
      0_u64
    end

    private def map_tuple_key_fixed_string_width(key_type : WideTupleLeafType) : Int32?
      if parameterized_type = key_type.parameterized_type
        if parameterized_type.is_a?(WideTupleFixedStringType)
          return parameterized_type.width
        end
      end
      nil
    end

    private def read_map_tuple_key_sizes_for_mark(
      plan : WideMapTupleTypePlan,
      column : String,
      mark_index : Int32,
      outer_rows : UInt64,
      entries : UInt64,
    ) : {Array(UInt64), UInt64}
      if outer_rows > WidePart::MAX_ARRAY_MARK_ROWS || entries > WidePart::MAX_ARRAY_MARK_ELEMENTS
        raise CorruptPartError.new("Map(Tuple) mark exceeds materialization limit")
      end
      size_stream = @streams[plan.key_size_stream_name(column)]
      start_mark, end_mark, stream_rows = checked_stream_mark_range(size_stream, mark_index, 1)
      raise CorruptPartError.new("Map(Tuple) key-size substream mark rows differ") unless stream_rows == outer_rows
      size_bytes = checked_array_mark_byte_count(entries, 8)
      validate_mark_range_bytes(size_stream, start_mark, end_mark, size_bytes, 8)
      encoded_sizes = read_mark_range_bytes(size_stream, start_mark, end_mark, size_bytes, 8)
      sizes = Array(UInt64).new(entries.to_i)
      total_bytes = 0_u64
      mark_bytes = 0_u64
      offset = 0
      while offset < encoded_sizes.size
        size = u64(encoded_sizes, offset)
        if size > MAX_DATA_FILE_BYTES.to_u64 - total_bytes || size > MAX_ARRAY_MARK_BYTES.to_u64 - total_bytes
          raise CorruptPartError.new("Map(Tuple) key String bytes exceed selected data limit")
        end
        if size > MAX_ARRAY_MARK_BYTES.to_u64 - mark_bytes
          raise CorruptPartError.new("Map(Tuple) key String bytes exceed per-mark limit")
        end
        total_bytes += size
        mark_bytes += size
        sizes << size
        offset += 8
      end
      raise CorruptPartError.new("Map(Tuple) key-size count differs from size0") unless sizes.size.to_u64 == entries
      {sizes, total_bytes}
    end

    private def validate_map_tuple_key_mark(
      plan : WideMapTupleTypePlan,
      column : String,
      mark_index : Int32,
      outer_rows : UInt64,
      entries : UInt64,
      key_string_bytes : UInt64,
    ) : Nil
      key_stream = @streams[plan.key_stream_name(column)]
      start_mark, end_mark, rows = checked_stream_mark_range(key_stream, mark_index, 1)
      raise CorruptPartError.new("Map(Tuple) key substream mark rows differ") unless rows == outer_rows
      width = if plan.key_type.base_type_name == "String"
                1
              else
                plan.key_type.raw_width || raise(CorruptPartError.new("Map(Tuple) key leaf has no physical width"))
              end
      expected_bytes = if plan.key_type.base_type_name == "String"
                         if key_string_bytes > Int32::MAX.to_u64 || key_string_bytes > MAX_ARRAY_MARK_BYTES.to_u64
                           raise CorruptPartError.new("Map(Tuple) key String bytes exceed per-mark limit")
                         end
                         key_string_bytes.to_i
                       else
                         checked_array_mark_byte_count(entries, width)
                       end
      validate_mark_range_bytes(key_stream, start_mark, end_mark, expected_bytes, width)
      nil
    end

    private def read_map_tuple_keys(
      plan : WideMapTupleTypePlan,
      column : String,
      schedule : WideMapTupleSchedule,
      schedule_first : Int32,
      first_mark : Int32,
      mark_count : Int32,
    ) : WideTupleLeafColumn
      relative_first = first_mark - schedule_first
      rows = schedule.outer_rows_in(relative_first, mark_count)
      entries = schedule.entries_in(relative_first, mark_count)
      key_string_bytes = schedule.key_string_bytes_in(relative_first, mark_count)
      key_type = plan.key_type
      key_stream = @streams[plan.key_stream_name(column)]
      key_start, key_end, key_rows = checked_stream_mark_range(key_stream, first_mark, mark_count)
      raise CorruptPartError.new("Map(Tuple) key substream mark rows differ") unless key_rows == rows

      if key_type.base_type_name == "String"
        sizes = Array(UInt64).new(entries.to_i)
        mark_count.times do |offset|
          mark_index = first_mark + offset
          relative_mark = mark_index - schedule_first
          mark_sizes, mark_bytes = read_map_tuple_key_sizes_for_mark(
            plan,
            column,
            mark_index,
            schedule.row_count_at(relative_mark).to_u64,
            schedule.entry_count_at(relative_mark).to_u64
          )
          unless mark_bytes == schedule.key_string_bytes_at(relative_mark)
            raise CorruptPartError.new("Map(Tuple) key String size schedule changed")
          end
          sizes.concat(mark_sizes)
        end
        raise CorruptPartError.new("Map(Tuple) key String size count differs from entries") unless sizes.size.to_u64 == entries
        if key_string_bytes > Int32::MAX.to_u64 || key_string_bytes > MAX_ARRAY_MARK_BYTES.to_u64
          raise CorruptPartError.new("Map(Tuple) key String bytes exceed selected limit")
        end
        raw_bytes = read_mark_range_bytes(key_stream, key_start, key_end, key_string_bytes.to_i, 1)
        values = [] of String
        StringPayloadDecoder.each(sizes, raw_bytes, "Map(Tuple) String key") do |value, _index|
          values << value
          nil
        end
        WideTupleLeafColumn.new("keys", key_type, values, nil)
      else
        width = key_type.raw_width || raise(CorruptPartError.new("Map(Tuple) key leaf has no physical width"))
        expected_bytes = checked_array_mark_byte_count(entries, width)
        bytes = read_mark_range_bytes(key_stream, key_start, key_end, expected_bytes, width)
        decoder = tuple_leaf_decoder
        decoder.decode_fixed(WideTupleField.new("keys", key_type), bytes, entries, width)
      end
    end
  end
end
