module CrystalClick
  # Logical bounds for the recursive binary type/value codec. These cap work
  # and retained output; they are not a direct RSS or allocator bound.
  class BinaryCodecLimits
    DEFAULT_MAX_DEPTH    =        64
    DEFAULT_MAX_NODES    =     4_096
    DEFAULT_MAX_ELEMENTS = 1_000_000
    DEFAULT_MAX_BYTES    = 64 * 1024 * 1024

    getter max_depth : Int32
    getter max_nodes : Int64
    getter max_elements : Int64
    getter max_bytes : Int64

    def initialize(
      max_depth : Int,
      max_nodes : Int,
      max_elements : Int,
      max_bytes : Int,
    )
      raise ArgumentError.new("binary codec limits must be nonnegative") if max_depth < 0 || max_nodes < 0 || max_elements < 0 || max_bytes < 0
      raise ArgumentError.new("binary codec max_depth exceeds Int32") if max_depth > Int32::MAX

      @max_depth = max_depth.to_i32
      @max_nodes = max_nodes.to_i64
      @max_elements = max_elements.to_i64
      @max_bytes = max_bytes.to_i64
    end

    def self.default : BinaryCodecLimits
      new(
        max_depth: DEFAULT_MAX_DEPTH,
        max_nodes: DEFAULT_MAX_NODES,
        max_elements: DEFAULT_MAX_ELEMENTS,
        max_bytes: DEFAULT_MAX_BYTES
      )
    end
  end
end
