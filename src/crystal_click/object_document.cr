module CrystalClick
  # One flattened logical Object row. Paths are exact raw storage identities;
  # this type does not expand dotted names or interpret JSON text.
  class ObjectDocument
    @values : Hash(String, BinaryValue)
    @paths : Array(String)

    def initialize(values : Hash(String, BinaryValue))
      @values = Hash(String, BinaryValue).new
      @paths = Array(String).new(values.size)
      values.each do |path, value|
        detached_path = String.new(path.to_slice)
        if @values.has_key?(detached_path)
          raise ArgumentError.new("Object document paths must be unique by raw bytes")
        end
        @values[detached_path] = value
        @paths << detached_path
      end
      @paths.sort! { |left, right| compare_paths(left, right) }
    end

    def paths : Array(String)
      @paths.map { |path| String.new(path.to_slice) }
    end

    def path_count : Int32
      @paths.size
    end

    def path_at(index : Int) : String
      String.new(@paths[index].to_slice)
    end

    def path_byte_size_at(index : Int) : Int32
      @paths[index].bytesize
    end

    def path_byte_at(index : Int, byte_index : Int) : UInt8
      @paths[index].to_slice[byte_index]
    end

    def has_path?(path : String) : Bool
      @values.has_key?(path)
    end

    def value_for(path : String) : BinaryValue
      @values[path]? || raise(KeyError.new("Object document path not found: #{path.inspect}"))
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
