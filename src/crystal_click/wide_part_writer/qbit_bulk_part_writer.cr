module CrystalClick
  module WidePartWriter
    # Narrow recursive QBit adapter over the shared static publisher. The
    # existing scalar QBit part writers keep their specialized root contract.
    private class QBitBulkPartWriter
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
          transport_limits, "recursive QBit"
        ) do
          if granules.size > MAX_MARKS
            raise ArgumentError.new("recursive QBit mark count is outside the writer limit")
          end
          declaration = BinaryQBitBulkColumnDeclaration.new(type, limits)
          canonical = declaration.declaration
          unless profile.single_stream? || profile.with_size_stream?
            raise UnsupportedFormatError.new("unsupported recursive QBit profile")
          end
          unless frame_bytes > 0 && frame_bytes <= transport_limits.max_frame_decompressed_bytes
            raise ArgumentError.new("recursive QBit frame size is outside the compressed transport limit")
          end
          BinaryBulkTypePlan.new(type, profile, nil, limits, true).role_count
          canonical
        end
      end
    end
  end
end
