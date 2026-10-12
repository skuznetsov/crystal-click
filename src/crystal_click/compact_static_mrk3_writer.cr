module CrystalClick
  # Backward-compatible MRK3 backend entry point. New callers that also need
  # MRK4 metadata should construct one CompactStaticWritePlan and pass it to
  # CompactStaticWriter so metadata and physical slots share the same owner.
  class CompactStaticMRK3Writer
    def self.encode(
      columns : Array(CompactStaticColumnInput),
      rows_per_mark : Array(UInt64),
      limits : BinaryCodecLimits,
      frame_bytes : Int,
      transport_budget : CompressedStreamBudget,
      codec_budget : BinaryCodecBudget,
    ) : CompactStaticPartFiles
      plan = CompactStaticWritePlan.new(columns, limits, CompactMarkFormat::Mrk3)
      CompactStaticWriter.encode(
        columns,
        rows_per_mark,
        limits,
        frame_bytes,
        transport_budget,
        codec_budget,
        plan,
      )
    end
  end
end
