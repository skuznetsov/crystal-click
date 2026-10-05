module CrystalClick
  module WidePartWriter
    # Reopens staged Decimal SAF parts through their exact public readers. The
    # ordinary numeric TypedMarkReadback path intentionally remains closed to
    # semantic Decimal children.
    private class StagedSimpleAggregateDecimalPartValidator
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
        plan = SimpleAggregateDecimalStoragePlan.for_type_name(type_name) ||
               raise(UnsupportedFormatError.new("staged Decimal validator requires a Decimal SimpleAggregateFunction child"))
        raise UnsupportedFormatError.new("staged Decimal validator requires scalar metadata") if plan.nullable?
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
          raise CorruptPartError.new("staged Decimal SimpleAggregateFunction mark row count differs") unless observed_values.size == rows
          rows.times do |offset|
            unless expected_keys[offset] == keys[start + offset] && value_equal?(values[start + offset], observed_values[offset])
              raise CorruptPartError.new("staged Decimal SimpleAggregateFunction readback differs from input")
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
        plan = SimpleAggregateDecimalStoragePlan.for_type_name(type_name) ||
               raise(UnsupportedFormatError.new("staged Decimal validator requires a Decimal SimpleAggregateFunction child"))
        raise UnsupportedFormatError.new("staged Nullable Decimal validator requires outer Nullable metadata") unless plan.nullable?
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
          raise CorruptPartError.new("staged Nullable Decimal SimpleAggregateFunction mark row count differs") unless observed_values.size == rows
          rows.times do |offset|
            unless expected_keys[offset] == keys[start + offset] && nullable_value_equal?(values[start + offset], observed_values[offset])
              raise CorruptPartError.new("staged Nullable Decimal SimpleAggregateFunction readback differs from input")
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
        raise CorruptPartError.new("staged Decimal SimpleAggregateFunction row count does not match") unless value_part.row_count == value_count.to_u64
        raise CorruptPartError.new("staged Decimal SimpleAggregateFunction type does not match") unless value_part.column_type == type_name
        {checksums, key_part, value_part}
      end

      private def self.read_scalar(part : WidePart, column : String, mark_index : Int, plan : SimpleAggregateDecimalStoragePlan, values : Slice(T)) : Array(T) forall T
        {% if T == Int32 %}
          part.read_simple_aggregate_decimal32_raw_mark_range(column, mark_index, 1, plan.function, plan.precision, plan.scale)
        {% elsif T == Int64 %}
          part.read_simple_aggregate_decimal64_raw_mark_range(column, mark_index, 1, plan.function, plan.precision, plan.scale)
        {% elsif T == Int128 %}
          part.read_simple_aggregate_decimal128_raw_mark_range(column, mark_index, 1, plan.function, plan.precision, plan.scale)
        {% elsif T == Decimal256Value %}
          part.read_simple_aggregate_decimal256_raw_mark_range(column, mark_index, 1, plan.function, plan.precision, plan.scale)
        {% else %}
          raise UnsupportedFormatError.new("staged Decimal SimpleAggregateFunction has unsupported coefficient width")
        {% end %}
      end

      private def self.read_nullable(part : WidePart, column : String, mark_index : Int, plan : SimpleAggregateDecimalStoragePlan, values : Slice(T)) : Array(T) forall T
        {% if T == Int32? %}
          part.read_nullable_simple_aggregate_decimal32_raw_mark_range(column, mark_index, 1, plan.function, plan.precision, plan.scale)
        {% elsif T == Int64? %}
          part.read_nullable_simple_aggregate_decimal64_raw_mark_range(column, mark_index, 1, plan.function, plan.precision, plan.scale)
        {% elsif T == Int128? %}
          part.read_nullable_simple_aggregate_decimal128_raw_mark_range(column, mark_index, 1, plan.function, plan.precision, plan.scale)
        {% elsif T == Decimal256Value? %}
          part.read_nullable_simple_aggregate_decimal256_raw_mark_range(column, mark_index, 1, plan.function, plan.precision, plan.scale)
        {% else %}
          raise UnsupportedFormatError.new("staged Decimal SimpleAggregateFunction has unsupported coefficient width")
        {% end %}
      end

      private def self.value_equal?(expected : T, actual : T) : Bool forall T
        {% if T == Decimal256Value %}
          expected.low == actual.low && expected.high == actual.high
        {% elsif T == Int32 || T == Int64 || T == Int128 %}
          expected == actual
        {% else %}
          false
        {% end %}
      end

      private def self.nullable_value_equal?(expected : T?, actual : T?) : Bool forall T
        if expected.nil?
          actual.nil?
        elsif actual.nil?
          false
        else
          value_equal?(expected.not_nil!, actual.not_nil!)
        end
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
        raise CorruptPartError.new("staged Decimal SimpleAggregateFunction marks do not match") unless value_part.mark_row_counts == expected_mark_rows
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
