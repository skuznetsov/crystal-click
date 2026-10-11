module CrystalClick
  # Parser-observed extent of one Object shared chunk header inside its
  # original StructurePrefix callback. These bounds are callback-local; they
  # do not assign bytes to a physical lane or create per-record callbacks.
  struct ObjectSharedChunkStructureReadSpan
    getter record : ObjectSharedChunkStructure
    getter prefix_start : Int32
    getter prefix_end : Int32

    def initialize(
      @record : ObjectSharedChunkStructure,
      @prefix_start : Int32,
      @prefix_end : Int32,
    )
    end
  end
end
