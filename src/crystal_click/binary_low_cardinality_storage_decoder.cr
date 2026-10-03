module CrystalClick
  # Reader for the bounded MergeTree LowCardinality dictionary/index lane
  # profile. It validates/replays every mark to restore dictionary state for a
  # selected middle window, while materializing only selected row values.
  module BinaryLowCardinalityStorageDecoder
    private struct DictionaryRecord
      getter start : UInt64
      getter finish : UInt64
      getter key_count : UInt64
      getter key_work : UInt64

      def initialize(@start : UInt64, @finish : UInt64, @key_count : UInt64, @key_work : UInt64)
      end
    end

    private struct IndexPlan
      getter flags : UInt64
      getter width : Int32
      getter row_count : UInt64
      getter additional_count : UInt64
      getter global_count : UInt64
      getter dictionary_start : UInt64?

      def initialize(
        @flags : UInt64,
        @width : Int32,
        @row_count : UInt64,
        @additional_count : UInt64,
        @global_count : UInt64,
        @dictionary_start : UInt64?,
      )
      end
    end

    def self.decode(
      type : BinaryDataType,
      streams : BinaryBulkStreams,
      occurrences_per_mark : Array(UInt64),
      budget : BinaryCodecBudget,
      first_mark : Int,
      mark_count : Int?,
    ) : Array(Array(BinaryValue))
      decode_internal(type, streams, occurrences_per_mark, budget, first_mark, mark_count, false)
    end

    # Bulk integration has already validated the complete recursive type tree
    # under its shared budget. This entrypoint preserves full LC state replay
    # while avoiding a second descriptor-tree visit per path occurrence.
    def self.decode_prevalidated(
      type : BinaryDataType,
      streams : BinaryBulkStreams,
      occurrences_per_mark : Array(UInt64),
      budget : BinaryCodecBudget,
      first_mark : Int,
      mark_count : Int?,
    ) : Array(Array(BinaryValue))
      decode_internal(type, streams, occurrences_per_mark, budget, first_mark, mark_count, true)
    end

    private def self.decode_internal(
      type : BinaryDataType,
      streams : BinaryBulkStreams,
      occurrences_per_mark : Array(UInt64),
      budget : BinaryCodecBudget,
      first_mark : Int,
      mark_count : Int?,
      prevalidated_type : Bool,
    ) : Array(Array(BinaryValue))
      unless !budget.writing?
        raise ArgumentError.new("LowCardinality storage decoder requires a read-direction budget")
      end

      traversal = BinaryCodecContext.new(budget.limits, nil, false, budget, false, false)
      nullable, scalar_type = BinaryLowCardinalityStorageStreams.ensure_root_type(type, traversal)
      traversal.validate_type_tree(type) unless prevalidated_type

      real_marks = streams.mark_count
      if real_marks < 0 || occurrences_per_mark.size != real_marks
        corrupt!("LowCardinality occurrence grid does not match its mark domain")
      end
      selected_first, selected_count = validate_selection(first_mark, mark_count, real_marks)
      unless streams.role_count == 2 &&
             streams.roles == [BinaryLowCardinalityStorageStreams::DICTIONARY_ROLE,
                               BinaryLowCardinalityStorageStreams::INDEX_ROLE]
        corrupt!("LowCardinality physical role set is incomplete")
      end
      dictionary = streams.stream(BinaryLowCardinalityStorageStreams::DICTIONARY_ROLE)
      indexes = streams.stream(BinaryLowCardinalityStorageStreams::INDEX_ROLE)
      validate_grids(dictionary, indexes, real_marks)

      total_wire_bytes = streams.total_input_byte_size
      budget.ensure_wire_bytes(total_wire_bytes)
      budget.charge_wire_bytes(total_wire_bytes)

      # Count-derived metadata is charged/preflighted before grids or mark plans
      # are copied. Offsets themselves remain borrowed from BinaryBulkStream.
      mark_records = real_marks.to_u64
      offsets = add(mark_records, 1_u64)
      metadata = add(mul(2_u64, offsets), mark_records)
      budget.ensure_future_nodes(metadata)
      budget.ensure_future_elements(metadata)
      budget.charge_elements(metadata)
      metadata.times { budget.charge_node }

      selected_rows = 0_u64
      occurrences_per_mark.each do |count|
        if count > Int32::MAX.to_u64
          corrupt!("LowCardinality occurrence count exceeds the supported in-memory domain")
        end
      end
      selected_count.times do |offset|
        selected_rows = add(selected_rows, occurrences_per_mark[selected_first + offset])
      end

      # The dictionary lane is a v1 prefix followed by exact count+keys records.
      prefix = dictionary.borrowed_slice(0_u64, 8_u64)
      version_context = BinaryCodecContext.new(budget.limits, prefix, false, budget, false, false)
      version = BinaryLowCardinalityStorageStreams.read_u64(version_context)
      version_context.ensure_consumed
      unless version == BinaryLowCardinalityStorageStreams::VERSION
        raise UnsupportedFormatError.new("unsupported LowCardinality dictionary serialization version")
      end

      records, suffix_key_work = scan_dictionary_records(dictionary, scalar_type, nullable, budget)
      records_by_start = Hash(UInt64, DictionaryRecord).new
      records.each { |record| records_by_start[record.start] = record }

      plans = Array(IndexPlan).new(real_marks)
      total_materialized_keys = 0_u64
      key_work = suffix_key_work
      active_global_count : UInt64? = nil
      active_global_start : UInt64? = nil
      used_records = Set(UInt64).new

      # First pass validates every record, count, state transition and index
      # bound without allocating key/value arrays or selected outputs.
      real_marks.times do |mark|
        start = indexes.offset_at(mark)
        finish = indexes.offset_at(mark + 1)
        expected_rows = occurrences_per_mark[mark]
        if expected_rows == 0_u64
          unless finish == start
            corrupt!("zero-occurrence LowCardinality mark has index bytes")
          end
          plans << IndexPlan.new(0_u64, 1, 0_u64, 0_u64, active_global_count || 0_u64, nil)
          next
        end
        if finish - start < 16_u64
          corrupt!("nonempty LowCardinality mark is shorter than its index header")
        end

        context = lane_context(indexes, start, finish, budget)
        flags = BinaryLowCardinalityStorageStreams.read_u64(context)
        if (flags & ~BinaryLowCardinalityStorageStreams::ALLOWED_MASK) != 0_u64
          corrupt!("LowCardinality index flags contain reserved bits")
        end
        code = flags & 0x3_u64
        width = BinaryLowCardinalityStorageStreams.width_for_code(code)
        global = (flags & BinaryLowCardinalityStorageStreams::GLOBAL_BIT) != 0_u64
        additional = (flags & BinaryLowCardinalityStorageStreams::ADDITIONAL_BIT) != 0_u64
        update = (flags & BinaryLowCardinalityStorageStreams::UPDATE_BIT) != 0_u64
        if update && !global && !additional
          corrupt!("LowCardinality dictionary update has no dictionary source")
        end
        unless global || additional
          corrupt!("LowCardinality index record names no dictionary source")
        end

        additional_count = 0_u64
        if additional
          additional_count = BinaryLowCardinalityStorageStreams.read_u64(context)
          if additional_count == 0_u64
            corrupt!("LowCardinality additional-key flag names an empty key record")
          end
          validate_key_count(additional_count, scalar_type, context, budget)
          before_keys = context.input_offset
          additional_count.times { skip_scalar(scalar_type, context) }
          # The first pass inspects every scalar without materializing it; the
          # replay pass then copies/hashes each key into its bounded lookup set.
          additional_work = add((context.input_offset - before_keys).to_u64, additional_count)
          key_work = add(key_work, add(additional_work, additional_work))
          total_materialized_keys = add(total_materialized_keys, additional_count)
        end

        global_count = 0_u64
        dictionary_start = nil.as(UInt64?)
        if global
          coordinate = dictionary.offset_at(mark)
          if update || active_global_count.nil?
            record = records_by_start[coordinate]?
            unless record
              corrupt!("LowCardinality dictionary coordinate is not a record boundary")
            end
            active_global_count = record.not_nil!.key_count
            active_global_start = coordinate
            dictionary_start = coordinate
            total_materialized_keys = add(total_materialized_keys, record.not_nil!.key_count)
            key_work = add(key_work, record.not_nil!.key_work)
            used_records.add(coordinate)
          else
            unless active_global_count && active_global_start == coordinate
              corrupt!("LowCardinality dictionary coordinate changed without an update")
            end
          end
          global_count = active_global_count || 0_u64
        end

        row_count = BinaryLowCardinalityStorageStreams.read_u64(context)
        unless row_count == expected_rows && row_count > 0_u64
          corrupt!("LowCardinality index row count does not match its mark")
        end
        id_bytes = mul(row_count, width.to_u64)
        context.ensure_remaining_input_bytes(id_bytes)
        maximum_id = if global
                       additional ? add(global_count, additional_count) : global_count
                     else
                       additional_count
                     end
        row_count.times do
          id = BinaryLowCardinalityStorageStreams.read_index(context, width)
          if id >= maximum_id
            corrupt!("LowCardinality index is outside its dictionary key range")
          end
        end
        context.ensure_consumed
        plans << IndexPlan.new(flags, width, row_count, additional_count, global_count, dictionary_start)
      end

      records.each do |record|
        unless used_records.includes?(record.start)
          corrupt!("LowCardinality dictionary lane contains an unreferenced record")
        end
      end
      if key_work > budget.limits.max_bytes.to_u64
        corrupt!("LowCardinality cumulative key inspection work exceeds byte limit")
      end

      output_nodes_per_row = nullable ? 3_u64 : 2_u64
      output_edges_per_row = nullable ? 2_u64 : 1_u64
      output_nodes = mul(selected_rows, output_nodes_per_row)
      output_edges = mul(selected_rows, output_edges_per_row)
      selected_metadata_edges = selected_count.to_u64
      planned_nodes = add(total_materialized_keys, output_nodes)
      planned_edges = add(add(total_materialized_keys, output_edges), selected_metadata_edges)
      budget.ensure_future_nodes(planned_nodes)
      budget.ensure_future_elements(planned_edges)
      budget.charge_elements(planned_edges)
      planned_nodes.times { budget.charge_node }

      # Decode/replay the complete state sequence after the bounded preflight.
      result = Array(Array(BinaryValue)).new(selected_count)
      active_values : Array(BinaryValue)? = nil
      active_start : UInt64? = nil
      selected_end = selected_first + selected_count
      real_marks.times do |mark|
        plan = plans[mark]
        is_selected = mark >= selected_first && mark < selected_end
        if plan.row_count == 0_u64
          result << ([] of BinaryValue) if is_selected
          next
        end

        if (plan.flags & BinaryLowCardinalityStorageStreams::GLOBAL_BIT) != 0_u64
          if plan.dictionary_start
            coordinate = plan.dictionary_start.not_nil!
            record = records_by_start[coordinate]?
            unless record
              corrupt!("LowCardinality dictionary record disappeared after preflight")
            end
            active_values = read_dictionary_record(dictionary, record.not_nil!, scalar_type, nullable, budget)
            active_start = coordinate
          elsif active_start != dictionary.offset_at(mark) || active_values.nil?
            corrupt!("LowCardinality dictionary state is unavailable during replay")
          end
        end

        index_start = indexes.offset_at(mark)
        index_finish = indexes.offset_at(mark + 1)
        context = lane_context(indexes, index_start, index_finish, budget)
        flags = BinaryLowCardinalityStorageStreams.read_u64(context)
        width = BinaryLowCardinalityStorageStreams.width_for_code(flags & 0x3_u64)
        global = (flags & BinaryLowCardinalityStorageStreams::GLOBAL_BIT) != 0_u64
        additional = (flags & BinaryLowCardinalityStorageStreams::ADDITIONAL_BIT) != 0_u64

        additional_values = [] of BinaryValue
        if additional
          count = BinaryLowCardinalityStorageStreams.read_u64(context)
          unless count == plan.additional_count
            corrupt!("LowCardinality additional-key count changed after preflight")
          end
          additional_values = read_additional_keys(
            context,
            scalar_type,
            count,
            nullable && !global
          )
        end
        rows = BinaryLowCardinalityStorageStreams.read_u64(context)
        unless rows == plan.row_count
          corrupt!("LowCardinality index row count changed after preflight")
        end

        selected_values = if is_selected
                            Array(BinaryValue).new(rows.to_i32)
                          else
                            nil
                          end
        rows.times do
          id = BinaryLowCardinalityStorageStreams.read_index(context, width)
          if is_selected
            value = if global
                      global_values = active_values || corrupt!("LowCardinality global dictionary is unavailable")
                      if id < global_values.size.to_u64
                        nullable ? wrap_nullable(type, id, global_values) : BinaryValue.low_cardinality(type, global_values[id.to_i])
                      else
                        unless additional && id - global_values.size.to_u64 < additional_values.size.to_u64
                          corrupt!("LowCardinality additional index is outside its key range")
                        end
                        scalar = additional_values[(id - global_values.size.to_u64).to_i]
                        child = nullable ? BinaryValue.nullable(type.child_at(0), scalar) : scalar
                        BinaryValue.low_cardinality(type, child)
                      end
                    else
                      unless additional && id < additional_values.size.to_u64
                        corrupt!("LowCardinality additional-only index is outside its key range")
                      end
                      if nullable && id == 0_u64
                        BinaryValue.low_cardinality(type, BinaryValue.nullable(type.child_at(0)))
                      else
                        scalar = additional_values[id.to_i]
                        child = nullable ? BinaryValue.nullable(type.child_at(0), scalar) : scalar
                        BinaryValue.low_cardinality(type, child)
                      end
                    end
            selected_values.not_nil! << value
          end
        end
        context.ensure_consumed
        result << selected_values.not_nil! if is_selected
      end
      result
    end

    private def self.scan_dictionary_records(
      stream : BinaryBulkStream,
      scalar_type : BinaryDataType,
      nullable : Bool,
      budget : BinaryCodecBudget,
    ) : {Array(DictionaryRecord), UInt64}
      marks = stream.mark_count.to_u64
      records = [] of DictionaryRecord
      work = 0_u64
      offset = 8_u64
      eof = stream.byte_size.to_u64
      while offset < eof
        if records.size.to_u64 >= marks
          corrupt!("LowCardinality dictionary has more records than mark boundaries")
        end
        if eof - offset < 8_u64
          corrupt!("LowCardinality dictionary record has a truncated key count")
        end
        context = lane_context(stream, offset, eof, budget)
        count = BinaryLowCardinalityStorageStreams.read_u64(context)
        if count == 0_u64
          corrupt!("LowCardinality global dictionary record is empty")
        end
        validate_key_count(count, scalar_type, context, budget)
        before = context.input_offset
        count.times { skip_scalar(scalar_type, context) }
        finish = offset + context.input_offset.to_u64
        if finish <= offset
          corrupt!("LowCardinality dictionary record makes no progress")
        end
        if nullable && count < 2_u64
          corrupt!("nullable LowCardinality global dictionary lacks reserved slots")
        end
        key_work = add((context.input_offset - before).to_u64, count)
        work = add(work, key_work)
        records << DictionaryRecord.new(offset, finish, count, key_work)
        offset = finish
      end
      {records, work}
    end

    private def self.read_dictionary_record(
      stream : BinaryBulkStream,
      record : DictionaryRecord,
      scalar_type : BinaryDataType,
      nullable : Bool,
      budget : BinaryCodecBudget,
    ) : Array(BinaryValue)
      context = lane_context(stream, record.start, record.finish, budget)
      count = BinaryLowCardinalityStorageStreams.read_u64(context)
      unless count == record.key_count
        corrupt!("LowCardinality dictionary key count changed after preflight")
      end
      keys = Array(BinaryValue).new(count.to_i32)
      seen = Hash(String, Int32).new
      count.times do |index|
        key = BinaryLowCardinalityStorageStreams.read_scalar(scalar_type, context)
        physical = BinaryLowCardinalityStorageStreams.scalar_bytes(key)
        if index == 0
          unless BinaryLowCardinalityStorageStreams.is_default_scalar?(scalar_type, key)
            corrupt!("LowCardinality global dictionary slot zero is not the canonical default")
          end
          seen[physical] = 0
        elsif nullable && index == 1
          unless BinaryLowCardinalityStorageStreams.is_default_scalar?(scalar_type, key)
            corrupt!("nullable LowCardinality default slot is not canonical")
          end
          # Nullable ColumnUnique intentionally serializes default base bytes
          # in both reserved slots: slot 0 is NULL, slot 1 is non-NULL default.
        elsif seen.has_key?(physical)
          corrupt!("LowCardinality dictionary contains duplicate non-reserved keys")
        else
          seen[physical] = index.to_i32
        end
        keys << key
      end
      context.ensure_consumed
      keys
    end

    private def self.read_additional_keys(
      context : BinaryCodecContext,
      scalar_type : BinaryDataType,
      count : UInt64,
      nullable_implicit_null : Bool,
    ) : Array(BinaryValue)
      keys = Array(BinaryValue).new(count.to_i32)
      seen = Hash(String, Bool).new
      count.times do |index|
        key = BinaryLowCardinalityStorageStreams.read_scalar(scalar_type, context)
        # In Nullable additional-only mode ClickHouse overlays null_map[0] on
        # the first physically serialized nested key. Its scalar bytes do not
        # identify a non-NULL dictionary entry and are excluded from the
        # duplicate-key set. Global+additional records have no implicit NULL.
        if nullable_implicit_null && index == 0_u64
          keys << key
          next
        end
        physical = BinaryLowCardinalityStorageStreams.scalar_bytes(key)
        if seen.has_key?(physical)
          corrupt!("LowCardinality additional-key record contains duplicate keys")
        end
        seen[physical] = true
        keys << key
      end
      keys
    end

    private def self.skip_scalar(type : BinaryDataType, context : BinaryCodecContext) : Nil
      case type.tag
      when BinaryDataType::TAG_STRING
        length = context.read_var_uint
        context.read_slice(length)
      when BinaryDataType::TAG_BOOL
        BoolValueCodec.decode(context.read_byte)
      else
        width = type.fixed_width || context.unsupported!("unsupported LowCardinality dictionary scalar")
        context.read_slice(width.to_u64)
      end
      nil
    end

    private def self.validate_key_count(
      count : UInt64,
      scalar_type : BinaryDataType,
      context : BinaryCodecContext,
      budget : BinaryCodecBudget,
    ) : Nil
      if count > Int32::MAX.to_u64 || count > budget.limits.max_elements.to_u64
        corrupt!("LowCardinality dictionary key count exceeds its bounded domain")
      end
      minimum = if scalar_type.tag == BinaryDataType::TAG_STRING
                  1_u64
                else
                  (scalar_type.fixed_width || 1).to_u64
                end
      minimum_bytes = mul(count, minimum)
      context.ensure_remaining_input_bytes(minimum_bytes)
    end

    private def self.lane_context(
      stream : BinaryBulkStream,
      start : UInt64,
      finish : UInt64,
      budget : BinaryCodecBudget,
    ) : BinaryCodecContext
      if finish < start
        corrupt!("LowCardinality lane range is reversed")
      end
      borrowed = stream.borrowed_slice(start, finish - start)
      BinaryCodecContext.new(budget.limits, borrowed, false, budget, false, false)
    end

    private def self.validate_grids(
      dictionary : BinaryBulkStream,
      indexes : BinaryBulkStream,
      marks : Int32,
    ) : Nil
      expected = marks.to_i64 + 1_i64
      unless dictionary.offset_count.to_i64 == expected && indexes.offset_count.to_i64 == expected
        corrupt!("LowCardinality lane offset-grid length is invalid")
      end
      unless indexes.offset_at(0) == 0_u64
        corrupt!("LowCardinality index lane must begin at byte zero")
      end
      previous = 8_u64
      0.upto(marks) do |index|
        current = dictionary.offset_at(index)
        if current < 8_u64 || current < previous || current > dictionary.byte_size.to_u64
          corrupt!("LowCardinality dictionary coordinates are outside the monotone suffix domain")
        end
        previous = current
      end
      unless previous == dictionary.byte_size.to_u64
        corrupt!("LowCardinality dictionary terminal coordinate does not match EOF")
      end
      previous = 0_u64
      1.upto(marks) do |index|
        current = indexes.offset_at(index)
        if current < previous || current > indexes.byte_size.to_u64
          corrupt!("LowCardinality index coordinates are not monotone within EOF")
        end
        previous = current
      end
      unless previous == indexes.byte_size.to_u64
        corrupt!("LowCardinality index terminal coordinate does not match EOF")
      end
      nil
    end

    private def self.wrap_nullable(type : BinaryDataType, id : UInt64, keys : Array(BinaryValue)) : BinaryValue
      child = if id == 0_u64
                BinaryValue.nullable(type.child_at(0))
              else
                BinaryValue.nullable(type.child_at(0), keys[id.to_i])
              end
      BinaryValue.low_cardinality(type, child)
    end

    private def self.validate_selection(first_mark : Int, mark_count : Int?, marks : Int32) : {Int32, Int32}
      first = first_mark.to_i128
      domain = marks.to_i128
      if first < 0_i128 || first > domain
        corrupt!("LowCardinality selected mark window is outside its domain")
      end
      count = mark_count.try(&.to_i128) || (domain - first)
      if count < 0_i128 || count > domain - first
        corrupt!("LowCardinality selected mark window is outside its domain")
      end
      {first.to_i32, count.to_i32}
    end

    private def self.add(left : UInt64, right : UInt64) : UInt64
      BinaryLowCardinalityStorageStreams.checked_add(left, right, "LowCardinality size arithmetic overflows")
    end

    private def self.mul(left : UInt64, right : UInt64) : UInt64
      BinaryLowCardinalityStorageStreams.checked_multiply(left, right, "LowCardinality size arithmetic overflows")
    end

    private def self.corrupt!(message : String) : NoReturn
      raise CorruptPartError.new(message)
    end
  end
end
