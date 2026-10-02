module CrystalClick
  # Detached complete Object/Dynamic byte streams. Size-only methods let a
  # paired decoder charge the aggregate input budget before copying getters.
  class ObjectDynamicStructureStreams
    @object : Bytes
    @dynamics : Hash(String, Bytes)

    def initialize(object : Bytes, dynamics : Hash(String, Bytes))
      @object = copy_bytes(object)
      @dynamics = Hash(String, Bytes).new
      dynamics.each do |path, bytes|
        detached_path = String.new(path.to_slice)
        if @dynamics.has_key?(detached_path)
          raise ArgumentError.new("Dynamic stream path keys must be unique by raw bytes")
        end
        @dynamics[detached_path] = copy_bytes(bytes)
      end
    end

    def object : Bytes
      copy_bytes(@object)
    end

    def dynamics : Hash(String, Bytes)
      detached = Hash(String, Bytes).new
      @dynamics.each do |path, bytes|
        detached[String.new(path.to_slice)] = copy_bytes(bytes)
      end
      detached
    end

    def dynamic_count : Int32
      @dynamics.size
    end

    # Check a borrowed owned key without allocating a detached copy of the
    # entire Dynamic-stream map.
    def has_dynamic_path?(path : String) : Bool
      @dynamics.has_key?(path)
    end

    def object_input_byte_size : UInt64
      @object.size.to_u64
    end

    def total_input_byte_size : UInt64
      total = @object.size.to_u64
      @dynamics.each_value do |bytes|
        size = bytes.size.to_u64
        if size > UInt64::MAX - total
          raise CorruptPartError.new("paired Object/Dynamic input byte count overflows UInt64")
        end
        total += size
      end
      total
    end

    private def copy_bytes(bytes : Bytes) : Bytes
      Bytes.new(bytes.size) { |index| bytes[index] }
    end
  end
end
