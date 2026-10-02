module CrystalClick
  # Detached complete physical lanes for paired logical Object document
  # composition. Malformed lane sets and grids are retained for the decoder to
  # classify; construction does not certify a stream profile.
  class ObjectDocumentStreams
    @structures : ObjectDynamicStructureStreams
    @rows_per_mark : Array(UInt64)
    @typed_paths : Hash(String, BinaryBulkStreams)
    @typed_names : Array(String)
    @dynamic_paths : Hash(String, DynamicValueStreams)
    @dynamic_names : Array(String)
    @shared : BinaryBulkStreams

    def initialize(
      structures : ObjectDynamicStructureStreams,
      rows_per_mark : Array(UInt64),
      typed_paths : Hash(String, BinaryBulkStreams),
      dynamic_paths : Hash(String, DynamicValueStreams),
      shared : BinaryBulkStreams,
    )
      @structures = structures
      @rows_per_mark = rows_per_mark.dup
      @typed_paths = Hash(String, BinaryBulkStreams).new
      @typed_names = Array(String).new(typed_paths.size)
      typed_paths.each do |path, streams|
        detached_path = String.new(path.to_slice)
        if @typed_paths.has_key?(detached_path)
          raise ArgumentError.new("typed Object lane keys must be unique by raw bytes")
        end
        @typed_paths[detached_path] = streams
        @typed_names << detached_path
      end
      @typed_names.sort! { |left, right| compare_paths(left, right) }

      @dynamic_paths = Hash(String, DynamicValueStreams).new
      @dynamic_names = Array(String).new(dynamic_paths.size)
      dynamic_paths.each do |path, streams|
        detached_path = String.new(path.to_slice)
        if @dynamic_paths.has_key?(detached_path)
          raise ArgumentError.new("Dynamic Object lane keys must be unique by raw bytes")
        end
        @dynamic_paths[detached_path] = streams
        @dynamic_names << detached_path
      end
      @dynamic_names.sort! { |left, right| compare_paths(left, right) }
      @shared = shared
    end

    def structures : ObjectDynamicStructureStreams
      @structures
    end

    def mark_count : Int32
      @rows_per_mark.size
    end

    def row_count_at(mark_index : Int) : UInt64
      @rows_per_mark[mark_index]
    end

    def rows_per_mark : Array(UInt64)
      @rows_per_mark.dup
    end

    def typed_path_count : Int32
      @typed_paths.size
    end

    def typed_path_at(index : Int) : String
      String.new(@typed_names[index].to_slice)
    end

    def typed_path_byte_size_at(index : Int) : Int32
      @typed_names[index].bytesize
    end

    def typed_path_byte_at(index : Int, byte_index : Int) : UInt8
      @typed_names[index].to_slice[byte_index]
    end

    def has_typed_path?(path : String) : Bool
      @typed_paths.has_key?(path)
    end

    def typed_paths : Array(String)
      @typed_names.map { |path| String.new(path.to_slice) }
    end

    def typed_for(path : String) : BinaryBulkStreams
      @typed_paths[path]? || raise(KeyError.new("typed Object lanes not found: #{path.inspect}"))
    end

    def dynamic_path_count : Int32
      @dynamic_paths.size
    end

    def dynamic_path_at(index : Int) : String
      String.new(@dynamic_names[index].to_slice)
    end

    def dynamic_path_byte_size_at(index : Int) : Int32
      @dynamic_names[index].bytesize
    end

    def dynamic_path_byte_at(index : Int, byte_index : Int) : UInt8
      @dynamic_names[index].to_slice[byte_index]
    end

    def has_dynamic_path?(path : String) : Bool
      @dynamic_paths.has_key?(path)
    end

    def dynamic_paths : Array(String)
      @dynamic_names.map { |path| String.new(path.to_slice) }
    end

    def dynamic_for(path : String) : DynamicValueStreams
      @dynamic_paths[path]? || raise(KeyError.new("Dynamic Object lanes not found: #{path.inspect}"))
    end

    def shared : BinaryBulkStreams
      @shared
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
