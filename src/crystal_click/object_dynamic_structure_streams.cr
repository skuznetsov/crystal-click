module CrystalClick
  # Detached complete Object/Dynamic byte streams. Size-only methods let a
  # paired decoder charge the aggregate input budget before copying getters.
  class ObjectDynamicStructureStreams
    @object : Bytes
    @dynamics : Hash(String, Bytes)
    @object_statistics_offset : Int32?
    @dynamic_statistics_offsets : Hash(String, Int32)

    def initialize(
      object : Bytes,
      dynamics : Hash(String, Bytes),
      @object_statistics_offset : Int32? = nil,
      dynamic_statistics_offsets : Hash(String, Int32) = Hash(String, Int32).new,
    )
      @object = copy_bytes(object)
      @dynamics = Hash(String, Bytes).new
      @dynamic_statistics_offsets = Hash(String, Int32).new
      dynamics.each do |path, bytes|
        detached_path = String.new(path.to_slice)
        if @dynamics.has_key?(detached_path)
          raise ArgumentError.new("Dynamic stream path keys must be unique by raw bytes")
        end
        @dynamics[detached_path] = copy_bytes(bytes)
      end
      dynamic_statistics_offsets.each do |path, offset|
        detached_path = String.new(path.to_slice)
        unless @dynamics.has_key?(detached_path)
          raise ArgumentError.new("Dynamic statistics offsets must name an existing stream")
        end
        if @dynamic_statistics_offsets.has_key?(detached_path)
          raise ArgumentError.new("Dynamic statistics offset paths must be unique by raw bytes")
        end
        @dynamic_statistics_offsets[detached_path] = offset
      end
    end

    def object : Bytes
      copy_bytes(@object)
    end

    # Borrowed internal view used only by the paired physical writer before it
    # immediately copies the bytes into independent compressed frames.
    def borrowed_object : Bytes
      @object
    end

    def object_statistics_offset : Int32?
      @object_statistics_offset
    end

    def dynamic_statistics_offset(path : String) : Int32?
      @dynamic_statistics_offsets[path]?
    end

    def dynamic_statistics_offset_count : Int32
      @dynamic_statistics_offsets.size
    end

    # Borrowed internal view; callers must not mutate it or retain it beyond the
    # enclosing writer operation.
    def borrowed_dynamic(path : String) : Bytes
      @dynamics[path]? || raise(KeyError.new("Dynamic structure stream not found: #{path.inspect}"))
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
