module CrystalClick
  module WidePartWriter
    # Nominal SimpleAggregateFunction adapter over the shared static part
    # writer. It retains the exact SAF/outer-Nullable guard and declaration
    # budget; inner Nullable remains a child of the nominal SAF node.
    private class SimpleAggregateBulkPartWriter
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
          transport_limits, "SimpleAggregate"
        ) do
          if granules.size > MAX_MARKS
            raise ArgumentError.new("SimpleAggregate mark count is outside the writer limit")
          end
          declaration = SimpleAggregateBulkColumnDeclaration.new(type, limits)
          canonical = declaration.declaration
          unless profile.single_stream? || profile.with_size_stream?
            raise UnsupportedFormatError.new("unsupported SimpleAggregate String profile")
          end
          unless frame_bytes > 0 && frame_bytes <= transport_limits.max_frame_decompressed_bytes
            raise ArgumentError.new("SimpleAggregate frame size is outside the compressed transport limit")
          end
          BinaryBulkTypePlan.new(type, profile, nil, limits, true).role_count
          canonical
        end
      end
    end
  end
end
