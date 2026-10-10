module CrystalClick
  module WidePartWriter
    # One owner for N-column planning, aggregate budgets, metadata, staged
    # readback and exclusive publication. Per-column codecs remain the
    # responsibility of their admitted owner adapters.
    private class WidePartOperation
      def self.write_uint64_columns(
        destination : String,
        key_name : String,
        keys : Slice(UInt64),
        columns : Array(WidePartColumn),
        rows_per_mark : Int32 = 8192,
        profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
        shared_profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
        mode : UInt64 = ObjectDocumentCodec::DEFAULT_MODE,
        frame_bytes : Int = 4096,
        metadata_version : Int64 = 0_i64,
        limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
        transport_limits : CompressedStreamLimits = CompressedStreamLimits.new,
        shared_json_policy : ObjectSharedAdvancedJsonWritePolicy? = nil,
        shared_target_chunk_rows : Int32 = 1,
        projections : Array(WidePartProjection) = [] of WidePartProjection,
        schema_binding : WidePartSchemaBinding? = nil,
      ) : String
        if projections.size > WidePartWriter::MAX_PROJECTIONS
          raise UnsupportedFormatError.new("projection count exceeds the writer limit")
        end
        retained_projections = projections.dup
        context = WidePartOperationContext.new(
          rows_per_mark, profile, shared_profile, mode, frame_bytes,
          metadata_version, limits, transport_limits, shared_json_policy,
          shared_target_chunk_rows
        )
        if columns.empty?
          raise ArgumentError.new("a Wide part requires at least one value column")
        end

        prepared = Array(WidePartPreparedColumn).new(columns.size)
        columns.each { |column| prepared << column.prepare(context) }
        schema_binding.try { |binding| binding.validate!(key_name, prepared) }
        projection_names = retained_projections.map(&.name)

        input = WidePartPublicationInput.prepare(
          destination, key_name, keys, prepared, rows_per_mark, metadata_version,
          projection_names
        )
        metadata_columns = Array(Tuple(String, String, Array(String))).new(prepared.size)
        prepared.each do |column|
          metadata_columns << {column.column_name, column.declaration, column.stream_names}
        end
        metadata = WidePartMetadata.new(
          key_name, metadata_columns, keys, metadata_version, profile,
          limits, context.codec_budget
        )

        prepared_projections = Array(WidePartPreparedProjection).new(retained_projections.size)
        combined_entries = input.checksum_entry_count.to_i64
        combined_files = input.expected_files.size.to_i64
        retained_projections.each do |projection|
          child = WidePartPreparedProjection.prepare(input.target, projection, context)
          combined_entries += child.checksum_entry_count.to_i64
          combined_files += child.file_count.to_i64
          if combined_entries > PartChecksums::MAX_ENTRIES.to_i64
            raise UnsupportedFormatError.new("combined Wide projection checksum roster exceeds its limit")
          end
          prepared_projections << child
        end
        max_combined_files = PartChecksums::MAX_ENTRIES.to_i64 +
                             (prepared_projections.size.to_i64 + 1_i64) * 5_i64
        if combined_files > max_combined_files
          raise UnsupportedFormatError.new("combined Wide projection file roster exceeds its limit")
        end

        encoded = Hash(String, CompressedMarkFiles).new
        prepared.each do |column|
          files = column.encode(
            input.expected_rows, context.codec_budget, context.transport_budget
          )
          files.each do |name, pair|
            if encoded.has_key?(name)
              raise UnsupportedFormatError.new("encoded physical streams collide across value columns")
            end
            encoded[name] = pair
          end
        end
        prepared_projections.each(&.encode!)

        WidePartPublisher.write(
          input, keys, WidePartMetadataEnvelope.new(metadata), encoded,
          rows_per_mark, limits, transport_limits, context.read_transport_budget,
          prepared_projections
        ) do |stage|
          prepared.each do |column|
            column.validate(stage, context.read_codec_budget, context.read_transport_budget)
          end
        end
      end
    end
  end
end
