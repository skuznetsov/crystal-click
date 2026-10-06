module CrystalClick
  # Nominal parameters for the root JSON DataType descriptor. Typed path types
  # are descriptor metadata: they are not generic DataType/value children.
  class BinaryJsonType
    DEFAULT_MAX_DYNAMIC_PATHS =  1_024
    MAX_DYNAMIC_PATHS         = 10_000
    DEFAULT_MAX_DYNAMIC_TYPES =     32
    MAX_DYNAMIC_TYPES         =    254
    MAX_TYPED_PATHS           =  1_000
    MAX_PATH_BYTES            =    256

    getter max_dynamic_paths : Int32
    getter max_dynamic_types : UInt8

    @typed_paths : Array(Tuple(String, BinaryDataType))

    def initialize(
      max_dynamic_paths : Int = DEFAULT_MAX_DYNAMIC_PATHS,
      max_dynamic_types : Int = DEFAULT_MAX_DYNAMIC_TYPES,
      typed_paths : Hash(String, BinaryDataType) = {} of String => BinaryDataType,
    )
      unless 0 <= max_dynamic_paths <= MAX_DYNAMIC_PATHS
        raise ArgumentError.new("JSON max_dynamic_paths must be between 0 and 10000")
      end
      unless 0 <= max_dynamic_types <= MAX_DYNAMIC_TYPES
        raise ArgumentError.new("JSON max_dynamic_types must be between 0 and 254")
      end
      if typed_paths.size > MAX_TYPED_PATHS
        raise ArgumentError.new("JSON typed path count exceeds the admitted limit")
      end

      # Validate the complete metadata collection under one operation budget
      # before allocating retained path/type records. In particular, a map of
      # many individually-small types cannot multiply the default node limit.
      limits = BinaryCodecLimits.default
      budget = BinaryCodecBudget.new(limits, true)
      context = BinaryCodecContext.new(limits, nil, true, budget, false, false)
      context.visit_node(1)
      if typed_paths.size > 0
        # Each declaration is both path metadata and a descriptor edge. Charge
        # the whole roster before touching any caller-owned name/type deeply.
        count = typed_paths.size.to_u64
        context.preflight_children(count)
        context.visit_metadata_nodes(count, 1)
        context.preflight_children(count)
        context.ensure_depth(2)
      end
      typed_paths.each do |path, type|
        self.class.validate_path!(path)
        budget.charge_wire_bytes(self.class.path_wire_size(path.bytesize.to_u64))
        context.validate_type_tree(type, 2)
        self.class.validate_typed_type!(type)
        if type.tag == BinaryDataType::TAG_NOTHING
          raise ArgumentError.new("Nothing is not admitted as a declared JSON typed path")
        end
      end

      entries = Array(Tuple(String, BinaryDataType)).new(typed_paths.size)
      typed_paths.each do |path, type|
        entries << {String.new(path.to_slice), type}
      end
      entries.sort! { |left, right| left[0] <=> right[0] }

      @max_dynamic_paths = max_dynamic_paths.to_i32
      @max_dynamic_types = max_dynamic_types.to_u8
      @typed_paths = entries
    end

    def typed_path_count : Int32
      @typed_paths.size
    end

    def typed_path_at(index : Int) : String
      String.new(@typed_paths[index][0].to_slice)
    end

    # No-copy metadata accessors for preflight paths. Materializing a path is
    # reserved for a point after the operation has charged the complete JSON
    # schema against its shared limits.
    def typed_path_byte_size(index : Int) : Int32
      @typed_paths[index][0].bytesize
    end

    def typed_path_byte_at(index : Int, byte_index : Int) : UInt8
      @typed_paths[index][0].to_slice[byte_index]
    end

    def typed_type_at(index : Int) : BinaryDataType
      @typed_paths[index][1]
    end

    def typed_type_for(path : String) : BinaryDataType?
      low = 0
      high = @typed_paths.size
      while low < high
        middle = low + (high - low) // 2
        comparison = @typed_paths[middle][0] <=> path
        if comparison < 0
          low = middle + 1
        elsif comparison > 0
          high = middle
        else
          return @typed_paths[middle][1]
        end
      end
      nil
    end

    def typed_paths : Hash(String, BinaryDataType)
      result = Hash(String, BinaryDataType).new(initial_capacity: @typed_paths.size)
      @typed_paths.each do |entry|
        result[String.new(entry[0].to_slice)] = entry[1]
      end
      result
    end

    def type_name : String
      if @max_dynamic_paths == DEFAULT_MAX_DYNAMIC_PATHS &&
         @max_dynamic_types == DEFAULT_MAX_DYNAMIC_TYPES &&
         @typed_paths.empty?
        return "JSON"
      end

      String.build do |io|
        io << "JSON("
        first = true
        if @max_dynamic_types != DEFAULT_MAX_DYNAMIC_TYPES
          io << "max_dynamic_types=" << @max_dynamic_types
          first = false
        end
        if @max_dynamic_paths != DEFAULT_MAX_DYNAMIC_PATHS
          io << ", " unless first
          io << "max_dynamic_paths=" << @max_dynamic_paths
          first = false
        end
        @typed_paths.each do |path, type|
          io << ", " unless first
          io << path << ' ' << type.name
          first = false
        end
        io << ')'
      end
    end

    def ==(other : BinaryJsonType) : Bool
      return false unless @max_dynamic_paths == other.@max_dynamic_paths
      return false unless @max_dynamic_types == other.@max_dynamic_types
      return false unless @typed_paths.size == other.@typed_paths.size
      @typed_paths.each_with_index do |entry, index|
        other_entry = other.@typed_paths[index]
        return false unless entry[0] == other_entry[0] && entry[1] == other_entry[1]
      end
      true
    end

    def hash(hasher)
      hasher = @max_dynamic_paths.hash(hasher)
      hasher = @max_dynamic_types.hash(hasher)
      @typed_paths.hash(hasher)
    end

    def self.validate_path!(path : String) : Nil
      unless valid_path_bytes?(path.to_slice)
        raise ArgumentError.new("JSON paths must use the admitted plain ASCII identifier profile")
      end
    end

    def self.valid_path_bytes?(bytes : Bytes) : Bool
      if bytes.empty? || bytes.size > MAX_PATH_BYTES
        return false
      end
      first = bytes[0]
      unless identifier_start?(first)
        return false
      end
      bytes.each_with_index do |byte, index|
        unless index == 0 ? identifier_start?(byte) : identifier_continue?(byte)
          return false
        end
      end
      if ascii_case_equal?(bytes, "SKIP".to_slice)
        return false
      end
      true
    end

    private def self.ascii_case_equal?(left : Bytes, right : Bytes) : Bool
      return false unless left.size == right.size
      left.each_with_index do |byte, index|
        normalized = byte >= 0x61_u8 && byte <= 0x7a_u8 ? byte - 0x20_u8 : byte
        return false unless normalized == right[index]
      end
      true
    end

    def self.path_wire_size(path_bytes : UInt64) : UInt64
      if path_bytes > UInt64::MAX - 10_u64
        raise ArgumentError.new("JSON path metadata size overflows UInt64")
      end
      path_bytes + var_uint_size(path_bytes)
    end

    def self.valid_path?(path : String) : Bool
      validate_path!(path)
      true
    rescue ArgumentError
      false
    end

    # The paired generic scalar codec is reused only for this explicit closed
    # grammar. A traversal cap prevents schema construction from recursively
    # rendering or validating an arbitrarily deep caller-built type graph.
    def self.validate_typed_type!(type : BinaryDataType) : Nil
      validate_type_node!(type, 1, false)
      nil
    end

    private def self.validate_type_node!(type : BinaryDataType, depth : Int, allow_nothing : Bool) : Nil
      if depth > BinaryCodecLimits::DEFAULT_MAX_DEPTH
        raise ArgumentError.new("JSON typed path type exceeds the admitted recursive limits")
      end
      if type.contains_json? || type.contains_aggregate_count? || type.contains_qbit? ||
         type.contains_dynamic? || type.contains_variant? || type.contains_low_cardinality? ||
         type.contains_nested?
        raise ArgumentError.new("JSON typed path type is outside the admitted scalar/container profile")
      end

      case type.tag
      when BinaryDataType::TAG_ARRAY
        validate_type_node!(type.child_at(0), depth + 1, false)
      when BinaryDataType::TAG_NULLABLE
        child = type.child_at(0)
        return if child.tag == BinaryDataType::TAG_NOTHING
        validate_type_node!(child, depth + 1, false)
      when BinaryDataType::TAG_MAP
        validate_type_node!(type.child_at(0), depth + 1, false)
        validate_type_node!(type.child_at(1), depth + 1, false)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        type.child_count.times do |index|
          validate_type_node!(type.child_at(index), depth + 1, false)
        end
      else
        if type.tag == BinaryDataType::TAG_NOTHING && allow_nothing
          return
        elsif type.tag == BinaryDataType::TAG_STRING ||
              type.tag == BinaryDataType::TAG_BOOL || !type.fixed_width.nil?
          return
        else
          raise ArgumentError.new("JSON typed path type is outside the admitted scalar/container profile")
        end
      end
      nil
    end

    private def self.var_uint_size(value : UInt64) : UInt64
      size = 1_u64
      remaining = value
      while remaining >= 0x80_u64
        remaining >>= 7
        size += 1_u64
      end
      size
    end

    private def self.identifier_start?(byte : UInt8) : Bool
      (byte >= 0x41_u8 && byte <= 0x5a_u8) || (byte >= 0x61_u8 && byte <= 0x7a_u8) || byte == 0x5f_u8
    end

    private def self.identifier_continue?(byte : UInt8) : Bool
      identifier_start?(byte) || (byte >= 0x30_u8 && byte <= 0x39_u8)
    end
  end
end
