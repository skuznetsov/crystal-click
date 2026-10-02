module CrystalClick
  # Exact encoder-side association between paired Object metadata and the
  # separately declared typed field schema.
  class ObjectDocumentPlan
    @structures : ObjectDynamicStructureSet
    @typed_types : Hash(String, BinaryDataType)
    @typed_paths : Array(String)

    def initialize(structures : ObjectDynamicStructureSet, typed_paths : Hash(String, BinaryDataType))
      @structures = structures
      @typed_types = Hash(String, BinaryDataType).new
      @typed_paths = Array(String).new(typed_paths.size)
      typed_paths.each do |path, type|
        detached_path = String.new(path.to_slice)
        if @typed_types.has_key?(detached_path)
          raise ArgumentError.new("typed Object paths must be unique by raw bytes")
        end
        if structures.object.has_dynamic_path?(detached_path)
          raise ArgumentError.new("typed and Dynamic Object paths must be disjoint")
        end
        @typed_types[detached_path] = type
        @typed_paths << detached_path
      end
      @typed_paths.sort! { |left, right| compare_paths(left, right) }
    end

    def structures : ObjectDynamicStructureSet
      @structures
    end

    def typed_paths : Hash(String, BinaryDataType)
      detached = Hash(String, BinaryDataType).new
      @typed_types.each do |path, type|
        detached[String.new(path.to_slice)] = type
      end
      detached
    end

    def typed_path_count : Int32
      @typed_paths.size
    end

    def typed_path_at(index : Int) : String
      String.new(@typed_paths[index].to_slice)
    end

    def typed_path_byte_size_at(index : Int) : Int32
      @typed_paths[index].bytesize
    end

    def typed_path_byte_at(index : Int, byte_index : Int) : UInt8
      @typed_paths[index].to_slice[byte_index]
    end

    def has_typed_path?(path : String) : Bool
      @typed_types.has_key?(path)
    end

    def typed_type_for(path : String) : BinaryDataType
      @typed_types[path]? || raise(KeyError.new("typed Object path not found: #{path.inspect}"))
    end

    private def compare_paths(left : String, right : String) : Int32
      left_bytes = left.to_slice
      right_bytes = right.to_slice
      common_size = Math.min(left_bytes.size, right_bytes.size)
      common_size.times do |index|
        return -1 if left_bytes[index] < right_bytes[index]
        return 1 if left_bytes[index] > right_bytes[index]
      end
      left_bytes.size <=> right_bytes.size
    end
  end
end
