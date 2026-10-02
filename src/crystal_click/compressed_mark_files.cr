module CrystalClick
  # Owned, unpublished pair produced by the transport writer.
  class CompressedMarkFiles
    @data : Bytes
    @marks : Bytes

    def initialize(data : Bytes, marks : Bytes)
      @data = data.dup
      @marks = marks.dup
    end

    def data : Bytes
      @data.dup
    end

    def marks : Bytes
      @marks.dup
    end
  end
end
