module CrystalClick
  # Detached caller-owned buffers for the three physical shared-MAP lanes.
  class ObjectSharedMapStreams
    @sizes : Bytes
    @paths : Bytes
    @values : Bytes

    def initialize(sizes : Bytes, paths : Bytes, values : Bytes)
      @sizes = Bytes.new(sizes.size) { |index| sizes[index] }
      @paths = Bytes.new(paths.size) { |index| paths[index] }
      @values = Bytes.new(values.size) { |index| values[index] }
    end

    def sizes : Bytes
      Bytes.new(@sizes.size) { |index| @sizes[index] }
    end

    def paths : Bytes
      Bytes.new(@paths.size) { |index| @paths[index] }
    end

    def values : Bytes
      Bytes.new(@values.size) { |index| @values[index] }
    end
  end
end
