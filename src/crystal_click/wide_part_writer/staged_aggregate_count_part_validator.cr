module CrystalClick
  module WidePartWriter
    # Validates Count's exact nominal column identity and variable-length
    # state boundaries by reopening every staged mark through the public
    # aggregate-count reader before publication.
    private class StagedAggregateCountPartValidator
      def self.validate(
        stage : String,
        key_name : String,
        value_name : String,
        keys : Slice(UInt64),
        values : Slice(BinaryValue),
        plan : WideAggregateCountStoragePlan,
        rows_per_mark : Int32,
        checked_mark_count : Proc(Int32, Int32, Int32),
      ) : Nil
        checksums = PartChecksums.open(stage)
        checksums.entries.each_key { |name| checksums.validate_selected_entries(stage, name) }

        expected_columns = PartSchemaMetadata.typed_columns_metadata(key_name, value_name, plan.type_name)
        unless File.read(File.join(stage, "columns.txt")) == expected_columns
          raise CorruptPartError.new("staged AggregateFunction(count) column metadata differs")
        end
        expected_substreams = PartSchemaMetadata.typed_substreams_metadata(key_name, value_name, plan.type_name)
        unless File.read(File.join(stage, "columns_substreams.txt")) == expected_substreams
          raise CorruptPartError.new("staged AggregateFunction(count) substream metadata differs")
        end
        unless File.read(File.join(stage, "default_compression_codec.txt")) == "CODEC(LZ4)"
          raise CorruptPartError.new("staged AggregateFunction(count) compression metadata differs")
        end
        unless File.read(File.join(stage, "metadata_version.txt")) == "0"
          raise CorruptPartError.new("staged AggregateFunction(count) metadata version differs")
        end
        unless File.read(File.join(stage, "serialization.json")) == PartSchemaMetadata.serialization_metadata
          raise CorruptPartError.new("staged AggregateFunction(count) serialization metadata differs")
        end
        raise CorruptPartError.new("staged AggregateFunction(count) row count differs") unless File.read(File.join(stage, "count.txt")) == keys.size.to_s

        mark_count = checked_mark_count.call(keys.size, rows_per_mark)
        key_part = WidePart.open(stage, key_name)
        value_part = WidePart.open_typed(stage, value_name)
        raise CorruptPartError.new("staged key row count does not match") unless key_part.row_count == keys.size.to_u64
        raise CorruptPartError.new("staged AggregateFunction(count) row count does not match") unless value_part.row_count == values.size.to_u64
        raise CorruptPartError.new("staged AggregateFunction(count) nominal type does not match") unless value_part.column_type == plan.type_name

        expected_mark_rows = Array(UInt64).new(mark_count)
        start_row = 0
        mark_index = 0
        while start_row < keys.size
          rows = {rows_per_mark, keys.size - start_row}.min
          expected_mark_rows << rows.to_u64
          expected_keys = key_part.read_uint64_mark_range(key_name, mark_index, 1)
          observed_values = value_part.read_aggregate_count_mark_range(
            value_name,
            mark_index,
            1,
            plan.data_type
          )
          raise CorruptPartError.new("staged key mark row count differs") unless expected_keys.size == rows
          raise CorruptPartError.new("staged AggregateFunction(count) mark row count differs") unless observed_values.size == rows
          rows.times do |offset|
            unless expected_keys[offset] == keys[start_row + offset] &&
                   observed_values[offset].type == plan.data_type &&
                   values[start_row + offset].type == plan.data_type &&
                   observed_values[offset].count_state == values[start_row + offset].count_state
              raise CorruptPartError.new("staged AggregateFunction(count) mark readback differs from input")
            end
          end
          start_row += rows
          mark_index += 1
        end

        raise CorruptPartError.new("staged key marks do not match") unless key_part.mark_row_counts == expected_mark_rows
        raise CorruptPartError.new("staged AggregateFunction(count) marks do not match") unless value_part.mark_row_counts == expected_mark_rows

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
