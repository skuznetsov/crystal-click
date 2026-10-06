module CrystalClick
  # Detached caller-owned buffers for the three exact per-chunk Copy lanes.
  class ObjectSharedCopyStreams
    @sizes : Bytes
    @indexes : Bytes
    @values : Bytes

    def initialize(sizes : Bytes, indexes : Bytes, values : Bytes)
      @sizes = Bytes.new(sizes.size) { |index| sizes[index] }
      @indexes = Bytes.new(indexes.size) { |index| indexes[index] }
      @values = Bytes.new(values.size) { |index| values[index] }
    end

    def sizes : Bytes
      Bytes.new(@sizes.size) { |index| @sizes[index] }
    end

    def indexes : Bytes
      Bytes.new(@indexes.size) { |index| @indexes[index] }
    end

    def values : Bytes
      Bytes.new(@values.size) { |index| @values[index] }
    end
  end
end
