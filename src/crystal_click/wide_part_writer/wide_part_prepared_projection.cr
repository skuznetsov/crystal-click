module CrystalClick
  module WidePartWriter
    # :nodoc:
    # Fully planned child part that can only publish beneath its unpublished
    # parent. It reuses the ordinary N-column codecs and shared operation
    # budgets; it has no nested-projection or raw-file interface.
    class WidePartPreparedProjection < ProjectionPreparedPart
      getter entry_name : String
      getter checksum_entry_count : Int32
      getter file_count : Int32

      def summary_sidecars : Array(String)
        ProjectionPartSummary::MRK4_SIDECARS
      end

      @keys : Array(UInt64)
      @additional_key_columns : Array(Array(UInt64))
      @rows_per_mark : Int32
      @context : WidePartOperationContext
      @columns : Array(WidePartPreparedColumn)
      @input : WidePartPublicationInput
      @metadata : WidePartMetadataEnvelope
      @encoded_files : Hash(String, CompressedMarkFiles)?

      private def initialize(
        @entry_name : String,
        @keys : Array(UInt64),
        @additional_key_columns : Array(Array(UInt64)),
        @rows_per_mark : Int32,
        @context : WidePartOperationContext,
        @columns : Array(WidePartPreparedColumn),
        @input : WidePartPublicationInput,
        @metadata : WidePartMetadataEnvelope,
      )
        @checksum_entry_count = @input.checksum_entry_count
        @file_count = @input.expected_files.size
        @encoded_files = nil
      end

      def self.prepare(
        parent_target : String,
        projection : WidePartProjection,
        parent_context : WidePartOperationContext,
        *,
        parent_row_count : UInt64? = nil,
      ) : WidePartPreparedProjection
        projection_name = projection.name
        entry_name = "#{projection_name}.proj"
        final_child_path = File.join(parent_target, entry_name)
        if final_child_path.bytesize > WidePartTable::MAX_PART_PATH_BYTES
          raise ArgumentError.new("projection child path exceeds reader limit")
        end
        key_name = projection.key_name
        key_names = projection.key_names
        rows_per_mark = projection.rows_per_mark
        context = parent_context.with_rows_per_mark(rows_per_mark)
        unless !key_names.empty? && key_names.first == key_name &&
               key_names.to_set.size == key_names.size
          raise UnsupportedFormatError.new("aggregate projection key roster differs from its ordered UInt64 streams")
        end
        if key_names.size > 1 && !projection.aggregate_projection?
          raise UnsupportedFormatError.new("compound projection keys require the admitted aggregate-child route")
        end
        if count_total = projection.count_total
          unless parent_row_count && count_total == parent_row_count.to_u128
            raise UnsupportedFormatError.new("count projection counts must sum to the parent row count")
          end
        end
        if projection.aggregate_projection?
          unless parent_row_count && projection.row_count <= parent_row_count
            raise UnsupportedFormatError.new("aggregate projection row count must be bounded by the parent row count")
          end
        end

        # Only the newly introduced arities consume this extra logical-workspace
        # charge. The one- and two-key writer paths preserve their prior budget
        # behavior. Charge all retained lane copies and BinaryValue carrier
        # grids before asking the projection to detach either representation.
        if key_names.size > 2
          workspace_bytes = ProjectionUInt64Keys.compound_writer_workspace_bytes(
            projection.row_count, key_names.size, rows_per_mark, WidePartWriter::MAX_MARKS
          )
          context.transport_budget.reserve_result_bytes(workspace_bytes)
        end
        additional_key_columns = projection.additional_key_columns
        unless key_names.size == additional_key_columns.size + 1
          raise UnsupportedFormatError.new("aggregate projection key roster differs from its ordered UInt64 streams")
        end
        keys = projection.keys

        prepared_columns = Array(WidePartPreparedColumn).new
        additional_key_columns.each_with_index do |values, index|
          unless values.size == projection.row_count
            raise UnsupportedFormatError.new("compound aggregate projection key stream lost its aligned row count")
          end
          key_lane_name = key_names[index + 1]
          prepared_columns << StaticWidePartColumnInput.prepare_projection_uint64_key(
            key_lane_name, values, context
          )
        end
        aggregate_columns = projection.aggregate_columns
        if !aggregate_columns.empty?
          aggregate_columns.each do |aggregate|
            prepared_columns << StaticWidePartColumnInput.prepare_projection_aggregate(aggregate, context)
          end
        else
          projection.columns.each do |column|
            prepared_columns << column.prepare(context)
          end
        end
        projection.schema_binding.try do |binding|
          binding.validate!(key_names, prepared_columns)
        end

        # The actual parent stage is intentionally not created during
        # preflight. bind_destination checks its concrete child path later.
        placeholder = File.join(parent_target, entry_name)
        input = WidePartPublicationInput.prepare(
          placeholder, key_name, keys.to_unsafe.to_slice(keys.size), prepared_columns,
          rows_per_mark, context.metadata_version,
          defer_destination_check: true,
          aggregate_projection: projection.aggregate_projection?,
          additional_key_names: key_names[1..],
        )
        metadata_columns = Array(Tuple(String, String, Array(String))).new(prepared_columns.size)
        prepared_columns.each do |column|
          metadata_columns << {column.column_name, column.declaration, column.stream_names}
        end
        # Root AggregateFunction(count) has no String value lane, but ClickHouse
        # parts carrying it use the normalized String serialization version 1.
        # Keep that child metadata independent from the parent writer profile.
        metadata_profile = projection.aggregate_projection? ? BinaryBulkProfile.with_size_stream : context.profile
        metadata = WidePartMetadata.new(
          key_name, metadata_columns, keys.to_unsafe.to_slice(keys.size), context.metadata_version,
          metadata_profile, context.limits, context.codec_budget
        )

        new(
          entry_name, keys, additional_key_columns,
          rows_per_mark, context, prepared_columns,
          input, WidePartMetadataEnvelope.new(metadata)
        )
      end

      def encode! : Nil
        raise UnsupportedFormatError.new("projection child was already encoded") if @encoded_files

        encoded = Hash(String, CompressedMarkFiles).new
        @columns.each do |column|
          files = column.encode(
            @input.expected_rows, @context.codec_budget, @context.transport_budget
          )
          files.each do |name, pair|
            if encoded.has_key?(name)
              raise UnsupportedFormatError.new("projection streams collide within the child part")
            end
            encoded[name] = pair
          end
        end
        @encoded_files = encoded
        nil
      end

      def publish(parent_stage : String) : ChecksumRecord
        encoded = @encoded_files || raise UnsupportedFormatError.new("projection child was not encoded")
        child_path = File.join(parent_stage, @entry_name)
        input = @input.bind_destination(child_path)
        additional_index_keys = @additional_key_columns.map do |key_column|
          key_column.to_unsafe.to_slice(key_column.size)
        end
        WidePartPublisher.write(
          input, @keys.to_unsafe.to_slice(@keys.size), @metadata, encoded, @rows_per_mark,
          @context.limits, @context.read_transport_limits, @context.read_transport_budget,
          additional_index_keys: additional_index_keys,
        ) do |stage|
          @columns.each do |column|
            column.validate(stage, @context.read_codec_budget, @context.read_transport_budget)
          end
        end
        ProjectionPartSummary.record(@entry_name, child_path, summary_sidecars)
      end
    end
  end
end
