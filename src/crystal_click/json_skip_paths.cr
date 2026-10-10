module CrystalClick
  # Immutable raw-path policy shared by JSON descriptors and Object schemas.
  # Supplied entries are charged before they are copied, then sorted and
  # deduplicated by raw byte identity.
  class JsonSkipPaths
    @paths : Array(String)

    def initialize(
      paths : Array(String),
      budget : BinaryCodecBudget,
      depth : Int = 1,
      max_path_bytes : Int? = nil,
    )
      count = paths.size.to_u64
      if count > 0_u64
        budget.preflight_children(count)
        budget.ensure_depth(depth)
        count.times { budget.visit_node(depth) }
      end

      total_wire_bytes = 0_u64
      paths.each do |path|
        bytes = path.to_slice
        if bytes.empty?
          raise ArgumentError.new("JSON SKIP path is empty or exceeds its admitted byte limit")
        end
        if maximum = max_path_bytes
          if bytes.size > maximum
            raise ArgumentError.new("JSON SKIP path is empty or exceeds its admitted byte limit")
          end
        end
        unless JsonPathSqlName.valid_raw_bytes?(bytes)
          raise ArgumentError.new("JSON SKIP path is empty or exceeds its admitted byte limit")
        end
        path_bytes = bytes.size.to_u64
        prefix_bytes = var_uint_size(path_bytes)
        if total_wire_bytes > UInt64::MAX - prefix_bytes || total_wire_bytes + prefix_bytes > UInt64::MAX - path_bytes
          raise ArgumentError.new("JSON SKIP path metadata size overflows UInt64")
        end
        total_wire_bytes += prefix_bytes + path_bytes
      end
      budget.charge_wire_bytes(total_wire_bytes) if total_wire_bytes > 0_u64

      retained = Array(String).new(paths.size)
      paths.each { |path| retained << String.new(path.to_slice) }
      retained.sort! { |left, right| self.class.compare_raw(left, right) }

      unique_count = 0
      retained.each do |path|
        if unique_count == 0 || retained[unique_count - 1] != path
          retained[unique_count] = path
          unique_count += 1
        end
      end
      while retained.size > unique_count
        retained.pop
      end
      @paths = retained
    end

    def size : Int32
      @paths.size
    end

    def skip_path_count : Int32
      @paths.size
    end

    def skip_path_at(index : Int) : String
      String.new(@paths[index].to_slice)
    end

    def skip_path_byte_size(index : Int) : Int32
      @paths[index].bytesize
    end

    def skip_path_byte_at(index : Int, byte_index : Int) : UInt8
      @paths[index].to_slice[byte_index]
    end

    # The public collection is detached; callers cannot mutate this policy.
    def skip_paths : Array(String)
      @paths.map { |path| String.new(path.to_slice) }
    end

    def typed_path_conflicts?(typed_path : String) : Bool
      @paths.each do |skip_path|
        return true if self.class.raw_starts_with?(typed_path, skip_path)
      end
      false
    end

    # This intentionally preserves the current stock binary RowBinary law:
    # exact matches are always skipped, but prefix matching considers only an
    # interior predecessor (the final sorted prefix is not applied).
    def binary_path_skipped?(path : String) : Bool
      low = 0
      high = @paths.size
      while low < high
        middle = low + (high - low) // 2
        comparison = self.class.compare_raw(@paths[middle], path)
        if comparison < 0
          low = middle + 1
        elsif comparison > 0
          high = middle
        else
          return true
        end
      end

      return false if low == 0 || low == @paths.size
      self.class.raw_starts_with?(path, @paths[low - 1])
    end

    # ClickHouse renders a raw SKIP path named REGEXP as the same token used by
    # its regex-clause grammar. Preserve that binary identity, but let
    # SQL-name-dependent callers refuse to publish a non-reconstructible name.
    def has_regexp_path? : Bool
      @paths.any? { |path| self.class.regexp_path?(path.to_slice) }
    end

    def ==(other : JsonSkipPaths) : Bool
      @paths == other.@paths
    end

    def hash(hasher)
      @paths.hash(hasher)
    end

    def self.raw_starts_with?(path : String, prefix : String) : Bool
      path_bytes = path.to_slice
      prefix_bytes = prefix.to_slice
      return false if prefix_bytes.size > path_bytes.size
      prefix_bytes.size.times do |index|
        return false unless path_bytes[index] == prefix_bytes[index]
      end
      true
    end

    def self.compare_raw(left : String, right : String) : Int32
      left_bytes = left.to_slice
      right_bytes = right.to_slice
      shared = left_bytes.size < right_bytes.size ? left_bytes.size : right_bytes.size
      shared.times do |index|
        left_byte = left_bytes[index]
        right_byte = right_bytes[index]
        return -1 if left_byte < right_byte
        return 1 if left_byte > right_byte
      end
      left_bytes.size <=> right_bytes.size
    end

    # This is deliberately only the six ASCII bytes of the reserved SQL token;
    # it does not normalize or reinterpret arbitrary raw path identity.
    def self.regexp_path?(bytes : Bytes) : Bool
      return false unless bytes.size == 6
      word = "regexp".to_slice
      6.times do |index|
        byte = bytes[index]
        byte += 0x20_u8 if byte >= 'A'.ord.to_u8 && byte <= 'Z'.ord.to_u8
        return false unless byte == word[index]
      end
      true
    end

    private def var_uint_size(value : UInt64) : UInt64
      size = 1_u64
      remaining = value
      while remaining >= 0x80_u64
        size += 1_u64
        remaining >>= 7
      end
      size
    end
  end
end
