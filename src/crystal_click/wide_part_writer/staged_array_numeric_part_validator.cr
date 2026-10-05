module CrystalClick
  module WidePartWriter
    # Validates staged numeric and nullable-numeric Array payloads while
    # receiving private writer helpers through synchronous typed callbacks.
    private class StagedArrayNumericPartValidator
      def self.validate_scalar(
        stage : String,
        key_name : String,
        value_name : String,
        keys : Slice(UInt64),
        values : Slice(Array(T)),
        rows_per_mark : Int32,
        type_name : String,
        checked_mark_count : Proc(Int32, Int32, Int32),
        rows_identical : Proc(Array(T), Array(T), Bool),
        validate_primary_index : Proc(String, PartChecksums, Slice(UInt64), Int32, Int32, Nil),
      ) : Nil forall T
        checksums = PartChecksums.open(stage)
        checksums.entries.each_key do |name|
          checksums.validate_selected_entries(stage, name)
        end

        mark_count = checked_mark_count.call(keys.size, rows_per_mark)
        key_part = WidePart.open(stage, key_name)
        value_part = WidePart.open_typed(stage, value_name)
        raise CorruptPartError.new("staged key row count does not match") unless key_part.row_count == keys.size.to_u64
        raise CorruptPartError.new("staged Array numeric row count does not match") unless value_part.row_count == values.size.to_u64
        raise CorruptPartError.new("staged Array numeric type does not match") unless value_part.column_type == "Array(#{type_name})"

        expected_mark_rows = Array(UInt64).new(mark_count)
        start = 0
        while start < keys.size
          rows = {rows_per_mark, keys.size - start}.min
          mark_index = expected_mark_rows.size
          expected_mark_rows << rows.to_u64
          expected_keys = key_part.read_uint64_mark_range(key_name, mark_index, 1)
          expected_values = value_part.read_array_numeric_mark_range(value_name, mark_index, 1, T)
          rows.times do |offset|
            unless expected_keys[offset] == keys[start + offset] && rows_identical.call(expected_values[offset], values[start + offset])
              raise CorruptPartError.new("staged Array numeric stream readback differs from input")
            end
          end
          start += rows
        end
        raise CorruptPartError.new("staged key marks do not match") unless key_part.mark_row_counts == expected_mark_rows
        raise CorruptPartError.new("staged Array numeric marks do not match") unless value_part.mark_row_counts == expected_mark_rows
        raise CorruptPartError.new("staged Array numeric substream metadata differs") unless File.read(File.join(stage, "columns_substreams.txt")) == PartSchemaMetadata.array_uint64_substreams_metadata(key_name, value_name)
        raise CorruptPartError.new("staged Array numeric serialization metadata differs") unless File.read(File.join(stage, "serialization.json")) == PartSchemaMetadata.serialization_metadata

        validate_primary_index.call(stage, checksums, keys, rows_per_mark, mark_count)
        nil
      end

      def self.validate_nullable(
        stage : String,
        key_name : String,
        value_name : String,
        keys : Slice(UInt64),
        values : Slice(Array(T?)),
        rows_per_mark : Int32,
        type_name : String,
        checked_mark_count : Proc(Int32, Int32, Int32),
        rows_identical : Proc(Array(T?), Array(T?), Bool),
        validate_primary_index : Proc(String, PartChecksums, Slice(UInt64), Int32, Int32, Nil),
      ) : Nil forall T
        checksums = PartChecksums.open(stage)
        checksums.entries.each_key do |name|
          checksums.validate_selected_entries(stage, name)
        end

        mark_count = checked_mark_count.call(keys.size, rows_per_mark)
        key_part = WidePart.open(stage, key_name)
        value_part = WidePart.open_typed(stage, value_name)
        expected_type = "Array(Nullable(#{type_name}))"
        raise CorruptPartError.new("staged key row count does not match") unless key_part.row_count == keys.size.to_u64
        raise CorruptPartError.new("staged Array(Nullable(T)) row count does not match") unless value_part.row_count == values.size.to_u64
        raise CorruptPartError.new("staged Array(Nullable(T)) column type does not match") unless value_part.column_type == expected_type
        unless File.read(File.join(stage, "columns_substreams.txt")) == PartSchemaMetadata.array_nullable_numeric_substreams_metadata(key_name, value_name)
          raise CorruptPartError.new("staged Array(Nullable(T)) substream metadata does not match")
        end

        expected_mark_rows = Array(UInt64).new(mark_count)
        start = 0
        while start < keys.size
          rows = {rows_per_mark, keys.size - start}.min
          mark_index = expected_mark_rows.size
          expected_mark_rows << rows.to_u64
          expected_keys = key_part.read_uint64_mark_range(key_name, mark_index, 1)
          expected_values = value_part.read_array_nullable_numeric_mark_range(value_name, mark_index, 1, T)
          rows.times do |offset|
            unless expected_keys[offset] == keys[start + offset] && rows_identical.call(expected_values[offset], values[start + offset])
              raise CorruptPartError.new("staged Array(Nullable(T)) stream readback differs from input")
            end
          end
          start += rows
        end
        raise CorruptPartError.new("staged key marks do not match") unless key_part.mark_row_counts == expected_mark_rows
        raise CorruptPartError.new("staged Array(Nullable(T)) marks do not match") unless value_part.mark_row_counts == expected_mark_rows
        raise CorruptPartError.new("staged Array(Nullable(T)) serialization metadata differs") unless File.read(File.join(stage, "serialization.json")) == PartSchemaMetadata.serialization_metadata

        validate_primary_index.call(stage, checksums, keys, rows_per_mark, mark_count)
        nil
      end
    end
  end
end
