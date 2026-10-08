module CrystalClick
  module WidePartWriter
    # Nominal Sum-family adapter over the shared static BinaryBulk part writer.
    # Aggregate states remain one raw data lane, distinct from their argument.
    private class AggregateFunctionBulkPartWriter
      def self.write(
        destination : String,
        key_name : String,
        keys : Slice(UInt64),
        value_name : String,
        type : BinaryDataType,
        granules : Array(Array(BinaryValue)),
        rows_per_mark : Int32 = 8192,
        profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
        frame_bytes : Int = 4096,
        metadata_version : Int64 = 0_i64,
        limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
        transport_limits : CompressedStreamLimits = CompressedStreamLimits.new,
      ) : String
        BinaryBulkPartWriter.write(
          destination, key_name, keys, value_name, type, granules,
          rows_per_mark, profile, frame_bytes, metadata_version, limits,
          transport_limits, "AggregateFunction"
        ) do
          if granules.size > MAX_MARKS
            raise ArgumentError.new("AggregateFunction mark count is outside the writer limit")
          end
          declaration = BinaryAggregateFunctionBulkColumnDeclaration.new(type, limits)
          canonical = declaration.declaration
          unless profile.single_stream? || profile.with_size_stream?
            raise UnsupportedFormatError.new("unsupported AggregateFunction String profile")
          end
          unless frame_bytes > 0 && frame_bytes <= transport_limits.max_frame_decompressed_bytes
            raise ArgumentError.new("AggregateFunction frame size is outside the compressed transport limit")
          end
          BinaryBulkTypePlan.new(type, profile, nil, limits, true).role_count
          canonical
        end
      end
    end
  end
end
