module CrystalClick
  # Paired detached occurrence structures and normalized decompressed lanes.
  # Both component owners detach their mutable inputs; this owner keeps their
  # association without adding physical filename or compression semantics.
  class BinaryDynamicBulkStreams
    getter structures : BinaryDynamicStructureStreams
    getter data : BinaryBulkStreams

    def initialize(@structures : BinaryDynamicStructureStreams, @data : BinaryBulkStreams)
    end
  end
end
