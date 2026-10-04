module CrystalClick
  # Detached per-occurrence Dynamic structure streams. Keys are logical site
  # paths, not SQL type names or nominal Dynamic caps.
  class BinaryDynamicStructureStreams
    @structures : Hash(String, Bytes)

    def initialize(structures : Hash(String, Bytes))
      @structures = Hash(String, Bytes).new
      structures.each do |path, bytes|
        detached_path = String.new(path.to_slice)
        if @structures.has_key?(detached_path)
          raise ArgumentError.new("Dynamic structure stream paths must be unique by raw bytes")
        end
        @structures[detached_path] = copy_bytes(bytes)
      end
    end

    def site_count : Int32
      @structures.size
    end

    def site_paths : Array(String)
      paths = @structures.keys.map { |path| String.new(path.to_slice) }
      paths.sort!
      paths
    end

    def has_site?(path : String) : Bool
      @structures.has_key?(path)
    end

    def structure_bytes_for(path : String) : Bytes
      bytes = @structures[path]? || raise(KeyError.new("Dynamic structure stream not found: #{path.inspect}"))
      copy_bytes(bytes)
    end

    def total_input_byte_size : UInt64
      total = 0_u64
      @structures.each_value do |bytes|
        size = bytes.size.to_u64
        if size > UInt64::MAX - total
          raise CorruptPartError.new("Dynamic structure input byte count overflows UInt64")
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
