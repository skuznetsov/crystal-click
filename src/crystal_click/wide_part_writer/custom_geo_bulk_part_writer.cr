module CrystalClick
  module WidePartWriter
    # The nominal adapter owns admission; all lane encoding and exclusive
    # publication remain in the shared static BinaryBulk publisher.
    private class CustomGeoBulkPartWriter
      def self.write(
        destination : String,
        key_name : String,
        keys : Slice(UInt64),
        value_name : String,
        type : BinaryDataType,
        granules : Array(Array(BinaryValue)),
        rows_per_mark : Int32,
        profile : BinaryBulkProfile,
        frame_bytes : Int,
        metadata_version : Int64,
        limits : BinaryCodecLimits,
        transport_limits : CompressedStreamLimits,
      ) : String
        BinaryBulkPartWriter.write(
          destination, key_name, keys, value_name, type, granules,
          rows_per_mark, profile, frame_bytes, metadata_version, limits,
          transport_limits, "Custom Geo"
        ) do
          declaration = BinaryCustomGeoBulkColumnDeclaration.new(type, limits)
          unless profile.single_stream? || profile.with_size_stream?
            raise UnsupportedFormatError.new("unsupported Custom Geo bulk profile")
          end
          if type.tag == BinaryDataType::TAG_CUSTOM && !profile.with_size_stream?
            raise UnsupportedFormatError.new("bare Custom Geo publication requires nested String serialization version 1 for legacy typed consumers")
          end
          unless frame_bytes > 0 && frame_bytes <= transport_limits.max_frame_decompressed_bytes
            raise ArgumentError.new("Custom Geo frame size is outside the compressed transport limit")
          end
          declaration.declaration
        end
      end
    end
  end
end
