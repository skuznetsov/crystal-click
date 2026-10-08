module CrystalClick
  # Nominal Nested guard over the shared static BinaryBulk column encoder.
  class NestedBulkColumnWriter
    def self.encode(
      type : BinaryDataType,
      profile : BinaryBulkProfile,
      physical : BinaryBulkPhysicalPlan,
      granules : Array(Array(BinaryValue)),
      rows_per_mark : Array(UInt64),
      frame_bytes : Int,
      limits : BinaryCodecLimits,
      transport_limits : CompressedStreamLimits,
    ) : Hash(String, CompressedMarkFiles)
      unless type.tag == BinaryDataType::TAG_NESTED
        raise UnsupportedFormatError.new("Nested bulk writer requires a nominal Nested descriptor")
      end
      BinaryBulkColumnWriter.encode(
        type, profile, physical, granules, rows_per_mark,
        frame_bytes, limits, transport_limits
      )
    end
  end
end
