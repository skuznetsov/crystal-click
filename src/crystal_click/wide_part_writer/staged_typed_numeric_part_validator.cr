module CrystalClick
  module WidePartWriter
    # Validates the staged numeric value column and its key/index framing while
    # receiving private writer helpers through synchronous typed callbacks.
    private class StagedTypedNumericPartValidator
      def self.validate_scalar(
        stage : String,
        key_name : String,
        value_name : String,
        keys : Slice(UInt64),
        values : Slice(T),
        type_name : String,
        rows_per_mark : Int32,
        checked_mark_count : Proc(Int32, Int32, Int32),
        read_mark : Proc(WidePart, String, Int32, Slice(T), String, Array(T)),
        value_equal : Proc(T, T, Bool),
        validate_bool_raw : Proc(String, String, Slice(T), Int32, Nil),
      ) : Nil forall T
        checksums = PartChecksums.open(stage)
        checksums.entries.each_key do |name|
          checksums.validate_selected_entries(stage, name)
        end
        if temporal_type = DateTimeColumnType.parse(type_name)
          if temporal_type.shape == DateTimeColumnType::Shape::Scalar &&
             File.read(File.join(stage, "columns.txt")) != PartSchemaMetadata.typed_columns_metadata(key_name, value_name, temporal_type.type_name)
            raise CorruptPartError.new("staged typed temporal column metadata differs")
          end
        end
        if interval_type = IntervalColumnType.parse(type_name)
          if interval_type.shape == IntervalColumnType::Shape::Scalar &&
             File.read(File.join(stage, "columns.txt")) != PartSchemaMetadata.typed_columns_metadata(key_name, value_name, interval_type.type_name)
            raise CorruptPartError.new("staged typed Interval column metadata differs")
          end
        end
        if aggregate_type = SimpleAggregateColumnType.parse(type_name)
          if aggregate_type.shape == SimpleAggregateColumnType::Shape::Scalar &&
             File.read(File.join(stage, "columns.txt")) != PartSchemaMetadata.typed_columns_metadata(key_name, value_name, aggregate_type.type_name)
            raise CorruptPartError.new("staged typed SimpleAggregateFunction column metadata differs")
          end
        end

        mark_count = checked_mark_count.call(keys.size, rows_per_mark)
        key_part = WidePart.open(stage, key_name)
        value_part = WidePart.open_typed(stage, value_name)
        raise CorruptPartError.new("staged key row count does not match") unless key_part.row_count == keys.size.to_u64
        raise CorruptPartError.new("staged typed payload row count does not match") unless value_part.row_count == values.size.to_u64
        raise CorruptPartError.new("staged typed payload column type does not match") unless value_part.column_type == type_name

        expected_mark_rows = Array(UInt64).new(mark_count)
        start = 0
        while start < keys.size
          rows = {rows_per_mark, keys.size - start}.min
          mark_index = expected_mark_rows.size
          expected_mark_rows << rows.to_u64
          expected_keys = key_part.read_uint64_mark_range(key_name, mark_index, 1)
          expected_values = read_mark.call(value_part, value_name, mark_index, values, type_name)
          rows.times do |offset|
            unless expected_keys[offset] == keys[start + offset] && value_equal.call(expected_values[offset], values[start + offset])
              raise CorruptPartError.new("staged typed numeric stream readback differs from input")
            end
          end
          start += rows
        end
        raise CorruptPartError.new("staged key marks do not match") unless key_part.mark_row_counts == expected_mark_rows
        raise CorruptPartError.new("staged typed payload marks do not match") unless value_part.mark_row_counts == expected_mark_rows
        {% if T == Bool %}
          validate_bool_raw.call(stage, value_name, values, rows_per_mark)
        {% end %}

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
        values : Slice(T),
        type_name : String,
        rows_per_mark : Int32,
        checked_mark_count : Proc(Int32, Int32, Int32),
        read_mark : Proc(WidePart, String, Int32, Slice(T), String, Array(T)),
        value_equal : Proc(T, T, Bool),
        validate_bool_raw : Proc(String, String, Slice(T), Int32, Nil),
        validate_primary_index : Proc(String, PartChecksums, Slice(UInt64), Int32, Int32, Nil),
      ) : Nil forall T
        checksums = PartChecksums.open(stage)
        checksums.entries.each_key { |name| checksums.validate_selected_entries(stage, name) }
        if temporal_type = DateTimeColumnType.parse(type_name)
          if temporal_type.shape == DateTimeColumnType::Shape::Nullable &&
             File.read(File.join(stage, "columns.txt")) != PartSchemaMetadata.typed_columns_metadata(key_name, value_name, temporal_type.type_name)
            raise CorruptPartError.new("staged Nullable temporal column metadata differs")
          end
        end
        if interval_type = IntervalColumnType.parse(type_name)
          if interval_type.shape == IntervalColumnType::Shape::Nullable &&
             File.read(File.join(stage, "columns.txt")) != PartSchemaMetadata.typed_columns_metadata(key_name, value_name, interval_type.type_name)
            raise CorruptPartError.new("staged Nullable Interval column metadata differs")
          end
        end
        if aggregate_type = SimpleAggregateColumnType.parse(type_name)
          if aggregate_type.shape == SimpleAggregateColumnType::Shape::Nullable &&
             File.read(File.join(stage, "columns.txt")) != PartSchemaMetadata.typed_columns_metadata(key_name, value_name, aggregate_type.type_name)
            raise CorruptPartError.new("staged Nullable SimpleAggregateFunction column metadata differs")
          end
        end

        mark_count = checked_mark_count.call(keys.size, rows_per_mark)
        key_part = WidePart.open(stage, key_name)
        value_part = WidePart.open_typed(stage, value_name)
        raise CorruptPartError.new("staged key row count does not match") unless key_part.row_count == keys.size.to_u64
        raise CorruptPartError.new("staged Nullable payload row count does not match") unless value_part.row_count == values.size.to_u64
        raise CorruptPartError.new("staged Nullable payload type does not match") unless value_part.column_type == type_name

        expected_mark_rows = Array(UInt64).new(mark_count)
        start = 0
        while start < keys.size
          rows = {rows_per_mark, keys.size - start}.min
          mark_index = expected_mark_rows.size
          expected_mark_rows << rows.to_u64
          expected_keys = key_part.read_uint64_mark_range(key_name, mark_index, 1)
          expected_values = read_mark.call(value_part, value_name, mark_index, values, type_name)
          rows.times do |offset|
            unless expected_keys[offset] == keys[start + offset] && value_equal.call(expected_values[offset], values[start + offset])
              raise CorruptPartError.new("staged Nullable numeric stream readback differs from input")
            end
          end
          start += rows
        end
        raise CorruptPartError.new("staged key marks do not match") unless key_part.mark_row_counts == expected_mark_rows
        raise CorruptPartError.new("staged Nullable payload marks do not match") unless value_part.mark_row_counts == expected_mark_rows
        {% if T == Bool? %}
          validate_bool_raw.call(stage, value_name, values, rows_per_mark)
        {% end %}

        validate_primary_index.call(stage, checksums, keys, rows_per_mark, mark_count)
        nil
      end
    end
  end
end
