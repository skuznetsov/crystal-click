module CrystalClick
  module WidePartWriter
    # Reopens staged temporal SAF parts through their explicit semantic reader
    # API before publication. The comparison is over raw codes/ticks and exact
    # stored type metadata; no timezone or calendar conversion occurs here.
    private class StagedSimpleAggregateTemporalPartValidator
      def self.validate_scalar(
        stage : String,
        key_name : String,
        value_name : String,
        keys : Slice(UInt64),
        values : Slice(T),
        type_name : String,
        rows_per_mark : Int32,
        checked_mark_count : Proc(Int32, Int32, Int32),
      ) : Nil forall T
        plan = SimpleAggregateTemporalStoragePlan.for_type_name(type_name) ||
               raise(UnsupportedFormatError.new("staged temporal validator requires an admitted temporal SimpleAggregateFunction child"))
        raise UnsupportedFormatError.new("staged temporal validator requires scalar metadata") if plan.nullable?
        plan.validate_payload!(values, false)

        checksums, key_part, value_part = open_parts(stage, key_name, value_name, keys.size, type_name)
        mark_count = checked_mark_count.call(keys.size, rows_per_mark)
        expected_mark_rows = Array(UInt64).new(mark_count)
        start = 0
        while start < keys.size
          rows = {rows_per_mark, keys.size - start}.min
          mark_index = expected_mark_rows.size
          expected_mark_rows << rows.to_u64
          expected_keys = key_part.read_uint64_mark_range(key_name, mark_index, 1)
          observed_values = read_scalar(value_part, value_name, mark_index, plan, values)
          raise CorruptPartError.new("staged temporal SimpleAggregateFunction mark row count differs") unless observed_values.size == rows
          rows.times do |offset|
            unless expected_keys[offset] == keys[start + offset] && values[start + offset] == observed_values[offset]
              raise CorruptPartError.new("staged temporal SimpleAggregateFunction mark readback differs from input")
            end
          end
          start += rows
        end

        validate_marks_and_index(stage, checksums, key_part, value_part, keys, rows_per_mark, mark_count, expected_mark_rows)
        nil
      end

      def self.validate_nullable(
        stage : String,
        key_name : String,
        value_name : String,
        keys : Slice(UInt64),
        values : Slice(T),
        type_name : String,
        rows_per_mark : Int32,
        checked_mark_count : Proc(Int32, Int32, Int32),
        validate_primary_index : Proc(String, PartChecksums, Slice(UInt64), Int32, Int32, Nil),
      ) : Nil forall T
        plan = SimpleAggregateTemporalStoragePlan.for_type_name(type_name) ||
               raise(UnsupportedFormatError.new("staged temporal validator requires an admitted temporal SimpleAggregateFunction child"))
        raise UnsupportedFormatError.new("staged Nullable temporal validator requires outer Nullable metadata") unless plan.nullable?
        plan.validate_payload!(values, true)

        checksums, key_part, value_part = open_parts(stage, key_name, value_name, keys.size, type_name)
        mark_count = checked_mark_count.call(keys.size, rows_per_mark)
        expected_mark_rows = Array(UInt64).new(mark_count)
        start = 0
        while start < keys.size
          rows = {rows_per_mark, keys.size - start}.min
          mark_index = expected_mark_rows.size
          expected_mark_rows << rows.to_u64
          expected_keys = key_part.read_uint64_mark_range(key_name, mark_index, 1)
          observed_values = read_nullable(value_part, value_name, mark_index, plan, values)
          raise CorruptPartError.new("staged Nullable temporal SimpleAggregateFunction mark row count differs") unless observed_values.size == rows
          rows.times do |offset|
            unless expected_keys[offset] == keys[start + offset] && values[start + offset] == observed_values[offset]
              raise CorruptPartError.new("staged Nullable temporal SimpleAggregateFunction mark readback differs from input")
            end
          end
          start += rows
        end

        validate_marks_and_index(stage, checksums, key_part, value_part, keys, rows_per_mark, mark_count, expected_mark_rows)
        validate_primary_index.call(stage, checksums, keys, rows_per_mark, mark_count)
        nil
      end

      private def self.open_parts(
        stage : String,
        key_name : String,
        value_name : String,
        value_count : Int,
        type_name : String,
      ) : {PartChecksums, WidePart, WidePart}
        checksums = PartChecksums.open(stage)
        checksums.entries.each_key { |name| checksums.validate_selected_entries(stage, name) }
        key_part = WidePart.open(stage, key_name)
        value_part = WidePart.open_typed(stage, value_name)
        raise CorruptPartError.new("staged key row count does not match") unless key_part.row_count == value_count.to_u64
        raise CorruptPartError.new("staged temporal SimpleAggregateFunction row count does not match") unless value_part.row_count == value_count.to_u64
        raise CorruptPartError.new("staged temporal SimpleAggregateFunction type does not match") unless value_part.column_type == type_name
        {checksums, key_part, value_part}
      end

      private def self.read_scalar(
        part : WidePart,
        column : String,
        mark_index : Int,
        plan : SimpleAggregateTemporalStoragePlan,
        carrier : Slice(T),
      ) : Array(T) forall T
        {% if T == UInt16 %}
          part.read_simple_aggregate_temporal_raw_mark_range(column, mark_index, 1, plan.function, plan.storage_type_name, UInt16)
        {% elsif T == Int32 %}
          part.read_simple_aggregate_temporal_raw_mark_range(column, mark_index, 1, plan.function, plan.storage_type_name, Int32)
        {% elsif T == UInt32 %}
          part.read_simple_aggregate_temporal_raw_mark_range(column, mark_index, 1, plan.function, plan.storage_type_name, UInt32)
        {% elsif T == Int64 %}
          part.read_simple_aggregate_temporal_raw_mark_range(column, mark_index, 1, plan.function, plan.storage_type_name, Int64)
        {% else %}
          raise UnsupportedFormatError.new("staged temporal SimpleAggregateFunction has an unsupported raw carrier")
        {% end %}
      end

      private def self.read_nullable(
        part : WidePart,
        column : String,
        mark_index : Int,
        plan : SimpleAggregateTemporalStoragePlan,
        carrier : Slice(T),
      ) : Array(T) forall T
        {% if T == UInt16? %}
          part.read_nullable_simple_aggregate_temporal_raw_mark_range(column, mark_index, 1, plan.function, plan.storage_type_name, UInt16)
        {% elsif T == Int32? %}
          part.read_nullable_simple_aggregate_temporal_raw_mark_range(column, mark_index, 1, plan.function, plan.storage_type_name, Int32)
        {% elsif T == UInt32? %}
          part.read_nullable_simple_aggregate_temporal_raw_mark_range(column, mark_index, 1, plan.function, plan.storage_type_name, UInt32)
        {% elsif T == Int64? %}
          part.read_nullable_simple_aggregate_temporal_raw_mark_range(column, mark_index, 1, plan.function, plan.storage_type_name, Int64)
        {% else %}
          raise UnsupportedFormatError.new("staged Nullable temporal SimpleAggregateFunction has an unsupported raw carrier")
        {% end %}
      end

      private def self.validate_marks_and_index(
        stage : String,
        checksums : PartChecksums,
        key_part : WidePart,
        value_part : WidePart,
        keys : Slice(UInt64),
        rows_per_mark : Int32,
        mark_count : Int32,
        expected_mark_rows : Array(UInt64),
      ) : Nil
        raise CorruptPartError.new("staged key marks do not match") unless key_part.mark_row_counts == expected_mark_rows
        raise CorruptPartError.new("staged temporal SimpleAggregateFunction marks do not match") unless value_part.mark_row_counts == expected_mark_rows
        index = PrimaryKeyIndex.open(stage, mark_count, checksums)
        expected_index = Array(UInt64).new(mark_count + 1)
        row = 0
        while row < keys.size
          expected_index << keys[row]
          row += rows_per_mark
        end
        expected_index << keys.last
        raise CorruptPartError.new("staged primary index differs from input") unless index.keys == expected_index
        nil
      end
    end
  end
end
