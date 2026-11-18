module CrystalClick
  # Parsed path values plus the explicitly decoded Dynamic site rosters.
  struct ObjectSharedPathDecodeResult
    @rows : Array(BinaryValue)
    @structures : Hash(String, DynamicStructure)

    def initialize(rows : Array(BinaryValue), structures : Hash(String, DynamicStructure))
      @rows = rows.dup
      @structures = Hash(String, DynamicStructure).new
      structures.each do |path, structure|
        @structures[String.new(path.to_slice)] = structure
      end
    end

    def rows : Array(BinaryValue)
      @rows.dup
    end

    # Read-only per-row access avoids copying the full result array when a
    # verifier consumes the result in a bounded loop. BinaryValue exposes no
    # mutable collection owner, so the backing array remains private.
    def row_count : Int32
      @rows.size
    end

    def row_at(index : Int) : BinaryValue
      @rows[index]
    end

    def structures : Hash(String, DynamicStructure)
      detached = Hash(String, DynamicStructure).new
      @structures.each do |path, structure|
        detached[String.new(path.to_slice)] = structure
      end
      detached
    end
  end
end
