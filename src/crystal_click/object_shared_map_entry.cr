module CrystalClick
  # One detached raw path and its nominal W117 value in a shared Object MAP.
  class ObjectSharedMapEntry
    getter value : BinaryValue

    @path : Bytes

    def initialize(path : Bytes, @value : BinaryValue)
      @path = Bytes.new(path.size) { |index| path[index] }
    end

    def path : Bytes
      Bytes.new(@path.size) { |index| @path[index] }
    end

    def path_byte_size : Int32
      @path.size
    end

    def path_byte_at(index : Int) : UInt8
      @path[index]
    end
  end
end
