module CrystalClick
  # Nominal parameters for one JSON DataType descriptor. Typed path types
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
          JsonPathSqlName.write_canonical(io, path.to_slice)
          io << ' ' << type.name
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
        raise ArgumentError.new("JSON path is empty or exceeds the embedded byte limit")
      end
    end

    def self.valid_path_bytes?(bytes : Bytes) : Bool
      bytes.size <= MAX_PATH_BYTES && JsonPathSqlName.valid_raw_bytes?(bytes)
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

    # The paired generic scalar codec is reused only for the represented
    # scalar/container grammar. Typed JSON declarations additionally follow
    # ClickHouse's static JSON schema gate; runtime-tagged descriptors retain
    # the broader generic profile where the tagged RowBinary path represents it.
    def self.validate_typed_type!(type : BinaryDataType) : Nil
      validate_type_node!(type, 1, true, true, false)
      nil
    end

    # A Nothing descriptor is handled separately as the runtime NULL sentinel.
    # Dynamic's selected actual type uses this same bounded runtime-top policy.
    def self.validate_runtime_type!(type : BinaryDataType) : Nil
      validate_type_node!(type, 1, false, true, false)
      nil
    end

    private def self.validate_type_node!(
      type : BinaryDataType,
      depth : Int,
      typed : Bool,
      root : Bool,
      allow_nothing : Bool,
    ) : Nil
      if depth > BinaryCodecLimits::DEFAULT_MAX_DEPTH
        raise ArgumentError.new("JSON path type exceeds the admitted recursive limits")
      end

      if type.tag == BinaryDataType::TAG_AGGREGATE_COUNT ||
         type.tag == BinaryDataType::TAG_QBIT
        reject_type!(typed)
      end

      if type.tag == BinaryDataType::TAG_JSON
        # JSON is a nominal scalar here. Its declared paths are descriptor
        # children of their own and always use the static typed-schema policy,
        # even when this JSON descriptor arrived through a runtime path.
        descriptor = type.json_type || reject_type!(typed)
        descriptor.typed_path_count.times do |index|
          validate_type_node!(descriptor.typed_type_at(index), depth + 1, true, false, false)
        end
        return nil
      end

      if !typed && root
        top_variant = type.tag == BinaryDataType::TAG_VARIANT
        top_dynamic = type.tag == BinaryDataType::TAG_DYNAMIC
        top_nullable = type.tag == BinaryDataType::TAG_NULLABLE
        top_nullable_low_cardinality = type.tag == BinaryDataType::TAG_LOW_CARDINALITY &&
                                       type.child_at(0).tag == BinaryDataType::TAG_NULLABLE
        if top_variant || top_dynamic || top_nullable || top_nullable_low_cardinality
          reject_type!(false)
        end
      end

      case type.tag
      when BinaryDataType::TAG_ARRAY
        validate_type_node!(type.child_at(0), depth + 1, typed, false, false)
      when BinaryDataType::TAG_NULLABLE
        child = type.child_at(0)
        if child.tag == BinaryDataType::TAG_NOTHING
          # ClickHouse's typed JSON schema gate rejects Nullable(Nothing).
          # Runtime tagged values retain it only below a container; a NULL
          # value has no child scalar to serialize.
          reject_type!(typed) if typed || root
          validate_type_node!(child, depth + 1, typed, false, true)
        else
          validate_type_node!(child, depth + 1, typed, false, false)
        end
      when BinaryDataType::TAG_MAP
        key = type.child_at(0)
        if typed && !(key.tag == BinaryDataType::TAG_STRING ||
           (key.tag == BinaryDataType::TAG_LOW_CARDINALITY &&
           key.child_at(0).tag == BinaryDataType::TAG_STRING))
          reject_type!(true)
        end
        validate_type_node!(key, depth + 1, typed, false, false)
        validate_type_node!(type.child_at(1), depth + 1, typed, false, false)
      when BinaryDataType::TAG_NESTED
        validate_type_node!(BinaryNestedType.tuple_for(type), depth + 1, typed, false, false)
      when BinaryDataType::TAG_LOW_CARDINALITY, BinaryDataType::TAG_SIMPLE_AGGREGATE
        validate_type_node!(type.child_at(0), depth + 1, typed, false, false)
      when BinaryDataType::TAG_DYNAMIC
        # The Dynamic actual descriptor is a value-time edge, not a static
        # child of this DataType. Row preflight validates that edge separately.
        return nil
      when BinaryDataType::TAG_VARIANT,
           BinaryDataType::TAG_UNNAMED_TUPLE,
           BinaryDataType::TAG_NAMED_TUPLE
        type.child_count.times do |index|
          validate_type_node!(type.child_at(index), depth + 1, typed, false, false)
        end
      else
        return if type.tag == BinaryDataType::TAG_NOTHING && allow_nothing
        if typed && (type.tag == BinaryDataType::TAG_INTERVAL ||
           type.tag == BinaryDataType::TAG_BFLOAT16 ||
           type.tag == BinaryDataType::TAG_NOTHING)
          reject_type!(true)
        end
        unless type.tag == BinaryDataType::TAG_STRING ||
               type.tag == BinaryDataType::TAG_BOOL || !type.fixed_width.nil?
          reject_type!(typed)
        end
      end
      nil
    end

    private def self.reject_type!(typed : Bool) : Nil
      profile = typed ? "typed JSON schema" : "runtime JSON value"
      raise ArgumentError.new("DataType is outside the admitted #{profile} profile")
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
