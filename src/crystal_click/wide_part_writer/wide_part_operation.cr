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
      ) : String
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

        input = WidePartPublicationInput.prepare(
          destination, key_name, keys, prepared, rows_per_mark, metadata_version
        )
        metadata_columns = Array(Tuple(String, String, Array(String))).new(prepared.size)
        prepared.each do |column|
          metadata_columns << {column.column_name, column.declaration, column.stream_names}
        end
        metadata = WidePartMetadata.new(
          key_name, metadata_columns, keys, metadata_version, profile,
          limits, context.codec_budget
        )

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

        WidePartPublisher.write(
          input, keys, WidePartMetadataEnvelope.new(metadata), encoded,
          rows_per_mark, limits, transport_limits, context.read_transport_budget
        ) do |stage|
          prepared.each do |column|
            column.validate(stage, context.read_codec_budget, context.read_transport_budget)
          end
        end
      end
    end
  end
end
