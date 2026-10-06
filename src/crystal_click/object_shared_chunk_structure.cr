module CrystalClick
  # One Object ADVANCED/ADVANCED_CHUNKED shared-data chunk record. This is a
  # metadata value only: mark-pair interpretation and target-stream bounds are
  # owned by the enclosing physical stream/layout reader.
  class ObjectSharedChunkStructure
    getter row_count : UInt64
    getter data_marks : Tuple(UInt64, UInt64)
    getter paths_marks : Tuple(UInt64, UInt64)
    getter paths_substreams_metadata_marks : Tuple(UInt64, UInt64)

    @paths : Array(String)

    def initialize(
      @row_count : UInt64,
      paths : Array(String),
      @data_marks : Tuple(UInt64, UInt64),
      @paths_marks : Tuple(UInt64, UInt64),
      @paths_substreams_metadata_marks : Tuple(UInt64, UInt64),
    )
      @paths = paths.map { |path| String.new(path.to_slice) }
      @paths.each_cons(2) do |pair|
        unless self.class.compare_paths(pair[0], pair[1]) < 0
          raise ArgumentError.new("Object shared chunk paths must be byte-sorted and unique")
        end
      end
    end

    # The record owns its opaque path bytes; callers receive detached strings
    # and an independent array rather than mutable aliases into this value.
    def paths : Array(String)
      @paths.map { |path| String.new(path.to_slice) }
    end

    def path_count : Int32
      @paths.size
    end

    def path_at(index : Int) : String
      String.new(@paths[index].to_slice)
    end

    # Byte-wise access lets enclosing codecs preflight opaque path work without
    # first creating the detached String returned by `path_at`.
    def path_byte_size(index : Int) : Int32
      @paths[index].bytesize
    end

    def path_byte_at(index : Int, byte_index : Int) : UInt8
      @paths[index].to_slice[byte_index]
    end

    def ==(other : ObjectSharedChunkStructure) : Bool
      @row_count == other.@row_count &&
        @paths == other.@paths &&
        @data_marks == other.@data_marks &&
        @paths_marks == other.@paths_marks &&
        @paths_substreams_metadata_marks == other.@paths_substreams_metadata_marks
    end

    def_hash @row_count, @paths, @data_marks, @paths_marks, @paths_substreams_metadata_marks

    # Path names are opaque bytes, not normalized or compared as Unicode text.
    def self.compare_paths(left : String, right : String) : Int32
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
