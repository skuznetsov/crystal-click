module CrystalClick
  # Bounded public entry point for the first complete-part Compact writer.
  # This API intentionally has no ignored Wide-only options.
  module CompactPartWriter
    def self.write_uint64_columns(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      columns : Array(CompactPartColumn),
      rows_per_mark : Int32 = 8192,
      frame_bytes : Int = 4096,
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
      transport_limits : CompressedStreamLimits = CompressedStreamLimits.new,
      reader_limits : CompressedStreamLimits = CompressedStreamLimits.new,
      mark_format : CompactMarkFormat = CompactMarkFormat::Mrk3,
    ) : String
      CompactPartOperation.write_uint64_columns(
        destination,
        key_name,
        keys,
        columns,
        rows_per_mark,
        frame_bytes,
        limits,
        transport_limits,
        reader_limits,
        mark_format,
      )
    end
  end
end
