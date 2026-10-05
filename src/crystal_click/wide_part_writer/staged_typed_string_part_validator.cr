module CrystalClick
  module WidePartWriter
    # Validates staged String and Nullable(String) payloads while receiving
    # private writer helpers through synchronous callbacks.
    private class StagedTypedStringPartValidator
      def self.validate_scalar(
        stage : String,
        key_name : String,
        value_name : String,
        keys : Slice(UInt64),
        values : Slice(String),
        rows_per_mark : Int32,
        checked_mark_count : Proc(Int32, Int32, Int32),
      ) : Nil
        checksums = PartChecksums.open(stage)
        checksums.entries.each_key do |name|
          checksums.validate_selected_entries(stage, name)
        end

        mark_count = checked_mark_count.call(keys.size, rows_per_mark)
        key_part = WidePart.open(stage, key_name)
        value_part = WidePart.open_typed(stage, value_name)
        raise CorruptPartError.new("staged key row count does not match") unless key_part.row_count == keys.size.to_u64
        raise CorruptPartError.new("staged String row count does not match") unless value_part.row_count == values.size.to_u64
        raise CorruptPartError.new("staged String column type does not match") unless value_part.column_type == "String"

        expected_mark_rows = Array(UInt64).new(mark_count)
        start = 0
        while start < keys.size
          rows = {rows_per_mark, keys.size - start}.min
          expected_mark_rows << rows.to_u64
          mark_index = expected_mark_rows.size - 1
          expected_keys = key_part.read_uint64_mark_range(key_name, mark_index, 1)
          expected_values = value_part.read_string_mark_range(value_name, mark_index, 1)
          rows.times do |offset|
            unless expected_keys[offset] == keys[start + offset] && expected_values[offset] == values[start + offset]
              raise CorruptPartError.new("staged String stream readback differs from input")
            end
          end
          start += rows
        end
        raise CorruptPartError.new("staged key marks do not match") unless key_part.mark_row_counts == expected_mark_rows
        raise CorruptPartError.new("staged String marks do not match") unless value_part.mark_row_counts == expected_mark_rows

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

      def self.validate_nullable(
        stage : String,
        key_name : String,
        value_name : String,
        keys : Slice(UInt64),
        values : Slice(String?),
        rows_per_mark : Int32,
        checked_mark_count : Proc(Int32, Int32, Int32),
        validate_primary_index : Proc(String, PartChecksums, Slice(UInt64), Int32, Int32, Nil),
      ) : Nil
        checksums = PartChecksums.open(stage)
        checksums.entries.each_key { |name| checksums.validate_selected_entries(stage, name) }

        mark_count = checked_mark_count.call(keys.size, rows_per_mark)
        key_part = WidePart.open(stage, key_name)
        value_part = WidePart.open_typed(stage, value_name)
        raise CorruptPartError.new("staged key row count does not match") unless key_part.row_count == keys.size.to_u64
        raise CorruptPartError.new("staged Nullable(String) row count does not match") unless value_part.row_count == values.size.to_u64
        raise CorruptPartError.new("staged Nullable(String) type does not match") unless value_part.column_type == "Nullable(String)"

        expected_mark_rows = Array(UInt64).new(mark_count)
        start = 0
        while start < keys.size
          rows = {rows_per_mark, keys.size - start}.min
          mark_index = expected_mark_rows.size
          expected_mark_rows << rows.to_u64
          expected_keys = key_part.read_uint64_mark_range(key_name, mark_index, 1)
          expected_values = value_part.read_nullable_string_mark_range(value_name, mark_index, 1)
          rows.times do |offset|
            unless expected_keys[offset] == keys[start + offset] && expected_values[offset] == values[start + offset]
              raise CorruptPartError.new("staged Nullable(String) stream readback differs from input")
            end
          end
          start += rows
        end
        raise CorruptPartError.new("staged key marks do not match") unless key_part.mark_row_counts == expected_mark_rows
        raise CorruptPartError.new("staged Nullable(String) marks do not match") unless value_part.mark_row_counts == expected_mark_rows

        validate_primary_index.call(stage, checksums, keys, rows_per_mark, mark_count)
        nil
      end
    end
  end
end
