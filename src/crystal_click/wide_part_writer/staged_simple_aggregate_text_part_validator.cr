module CrystalClick
  module WidePartWriter
    # Validates all admitted SimpleAggregateFunction text children through the
    # exact public mark readers before a staged part can be published.
    private class StagedSimpleAggregateTextPartValidator
      def self.validate_scalar(
        stage : String,
        key_name : String,
        value_name : String,
        keys : Slice(UInt64),
        values : Slice(String),
        type_name : String,
        rows_per_mark : Int32,
        checked_mark_count : Proc(Int32, Int32, Int32),
      ) : Nil
        plan = SimpleAggregateTextStoragePlan.for_type_name(type_name) ||
               raise(UnsupportedFormatError.new("staged text validator requires a SimpleAggregateFunction String or FixedString child"))
        raise UnsupportedFormatError.new("staged scalar text validator requires scalar metadata") if plan.nullable?

        checksums, key_part, value_part = open_parts(stage, key_name, value_name, keys, values.size, type_name)
        mark_count = checked_mark_count.call(keys.size, rows_per_mark)
        expected_mark_rows = Array(UInt64).new(mark_count)
        start = 0
        while start < keys.size
          rows = {rows_per_mark, keys.size - start}.min
          mark_index = expected_mark_rows.size
          expected_mark_rows << rows.to_u64
          expected_keys = key_part.read_uint64_mark_range(key_name, mark_index, 1)
          observed_values = read_scalar(value_part, value_name, mark_index, plan)
          raise CorruptPartError.new("staged SimpleAggregateFunction text mark row count differs") unless observed_values.size == rows
          rows.times do |offset|
            raise CorruptPartError.new("staged SimpleAggregateFunction text key differs from input") unless expected_keys[offset] == keys[start + offset]
            unless value_matches?(values[start + offset], observed_values[offset], plan)
              raise CorruptPartError.new("staged SimpleAggregateFunction text stream readback differs from input")
            end
          end
          expected_bytes = expected_raw_bytes(values, start, rows, plan)
          observed_bytes = raw_bytes(value_part, value_name, mark_index, plan)
          raise CorruptPartError.new("staged SimpleAggregateFunction text raw bytes differ from input") unless observed_bytes == expected_bytes
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
        values : Slice(String?),
        type_name : String,
        rows_per_mark : Int32,
        checked_mark_count : Proc(Int32, Int32, Int32),
        validate_primary_index : Proc(String, PartChecksums, Slice(UInt64), Int32, Int32, Nil),
      ) : Nil
        plan = SimpleAggregateTextStoragePlan.for_type_name(type_name) ||
               raise(UnsupportedFormatError.new("staged text validator requires a SimpleAggregateFunction String or FixedString child"))
        raise UnsupportedFormatError.new("staged Nullable text validator requires Nullable metadata") unless plan.nullable?

        checksums, key_part, value_part = open_parts(stage, key_name, value_name, keys, values.size, type_name)
        mark_count = checked_mark_count.call(keys.size, rows_per_mark)
        expected_mark_rows = Array(UInt64).new(mark_count)
        start = 0
        while start < keys.size
          rows = {rows_per_mark, keys.size - start}.min
          mark_index = expected_mark_rows.size
          expected_mark_rows << rows.to_u64
          expected_keys = key_part.read_uint64_mark_range(key_name, mark_index, 1)
          observed_values = read_nullable(value_part, value_name, mark_index, plan)
          raise CorruptPartError.new("staged Nullable SimpleAggregateFunction text mark row count differs") unless observed_values.size == rows
          rows.times do |offset|
            raise CorruptPartError.new("staged Nullable SimpleAggregateFunction text key differs from input") unless expected_keys[offset] == keys[start + offset]
            unless nullable_value_matches?(values[start + offset], observed_values[offset], plan)
              raise CorruptPartError.new("staged Nullable SimpleAggregateFunction text stream readback differs from input")
            end
          end
          expected_bytes = expected_raw_bytes(values, start, rows, plan)
          observed_bytes = raw_bytes(value_part, value_name, mark_index, plan)
          raise CorruptPartError.new("staged Nullable SimpleAggregateFunction text raw bytes differ from input") unless observed_bytes == expected_bytes
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
        keys : Slice(UInt64),
        value_count : Int,
        type_name : String,
      ) : {PartChecksums, WidePart, WidePart}
        checksums = PartChecksums.open(stage)
        checksums.entries.each_key { |name| checksums.validate_selected_entries(stage, name) }
        key_part = WidePart.open(stage, key_name)
        value_part = WidePart.open_typed(stage, value_name)
        raise CorruptPartError.new("staged key row count does not match") unless key_part.row_count == keys.size.to_u64
        raise CorruptPartError.new("staged SimpleAggregateFunction text row count does not match") unless value_part.row_count == value_count.to_u64
        raise CorruptPartError.new("staged SimpleAggregateFunction text type does not match") unless value_part.column_type == type_name
        {checksums, key_part, value_part}
      end

      private def self.read_scalar(part : WidePart, column : String, mark_index : Int, plan : SimpleAggregateTextStoragePlan) : Array(String)
        if plan.variable_string?
          part.read_simple_aggregate_string_mark_range(column, mark_index, 1)
        else
          part.read_simple_aggregate_fixed_string_mark_range(column, mark_index, 1)
        end
      end

      private def self.read_nullable(part : WidePart, column : String, mark_index : Int, plan : SimpleAggregateTextStoragePlan) : Array(String?)
        if plan.variable_string?
          part.read_nullable_simple_aggregate_string_mark_range(column, mark_index, 1)
        else
          part.read_nullable_simple_aggregate_fixed_string_mark_range(column, mark_index, 1)
        end
      end

      private def self.raw_bytes(part : WidePart, column : String, mark_index : Int, plan : SimpleAggregateTextStoragePlan) : UInt64
        if plan.variable_string?
          if plan.nullable?
            part.nullable_simple_aggregate_string_mark_range_raw_bytes(column, mark_index, 1)
          else
            part.simple_aggregate_string_mark_range_raw_bytes(column, mark_index, 1)
          end
        elsif plan.nullable?
          part.nullable_simple_aggregate_fixed_string_mark_range_raw_bytes(column, mark_index, 1)
        else
          part.simple_aggregate_fixed_string_mark_range_raw_bytes(column, mark_index, 1)
        end
      end

      private def self.value_matches?(expected : String, actual : String, plan : SimpleAggregateTextStoragePlan) : Bool
        if plan.variable_string?
          same_bytes?(expected, actual)
        else
          padded_fixed_string_matches?(expected, actual, plan.fixed_string_width.not_nil!)
        end
      end

      private def self.nullable_value_matches?(expected : String?, actual : String?, plan : SimpleAggregateTextStoragePlan) : Bool
        if expected.nil?
          actual.nil?
        elsif actual.nil?
          false
        else
          value_matches?(expected.not_nil!, actual.not_nil!, plan)
        end
      end

      private def self.same_bytes?(expected : String, actual : String) : Bool
        left = expected.to_slice
        right = actual.to_slice
        return false unless left.size == right.size
        left.size.times { |index| return false unless left[index] == right[index] }
        true
      end

      private def self.padded_fixed_string_matches?(expected : String, actual : String, width : Int32) : Bool
        input = expected.to_slice
        output = actual.to_slice
        return false if input.size > width || output.size != width
        width.times do |index|
          expected_byte = index < input.size ? input[index] : 0_u8
          return false unless output[index] == expected_byte
        end
        true
      end

      private def self.expected_raw_bytes(values : Slice(String), start : Int, rows : Int, plan : SimpleAggregateTextStoragePlan) : UInt64
        if width = plan.fixed_string_width
          rows.to_u64 * width.to_u64
        else
          total_string_bytes(values, start, rows)
        end
      end

      private def self.expected_raw_bytes(values : Slice(String?), start : Int, rows : Int, plan : SimpleAggregateTextStoragePlan) : UInt64
        if width = plan.fixed_string_width
          rows.to_u64 * width.to_u64
        else
          total_nullable_string_bytes(values, start, rows)
        end
      end

      private def self.total_string_bytes(values : Slice(String), start : Int, rows : Int) : UInt64
        total = 0_u64
        rows.times do |offset|
          size = values[start + offset].bytesize.to_u64
          raise CorruptPartError.new("staged input String byte count overflows") if size > UInt64::MAX - total
          total += size
        end
        total
      end

      private def self.total_nullable_string_bytes(values : Slice(String?), start : Int, rows : Int) : UInt64
        total = 0_u64
        rows.times do |offset|
          next unless value = values[start + offset]
          size = value.bytesize.to_u64
          raise CorruptPartError.new("staged input Nullable(String) byte count overflows") if size > UInt64::MAX - total
          total += size
        end
        total
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
        raise CorruptPartError.new("staged SimpleAggregateFunction text marks do not match") unless value_part.mark_row_counts == expected_mark_rows
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
