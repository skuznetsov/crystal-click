module CrystalClick
  # Parsed path values plus the explicitly decoded Dynamic site rosters.
  class ObjectSharedPathDecodeResult
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

    def structures : Hash(String, DynamicStructure)
      detached = Hash(String, DynamicStructure).new
      @structures.each do |path, structure|
        detached[String.new(path.to_slice)] = structure
      end
      detached
    end
  end
end
