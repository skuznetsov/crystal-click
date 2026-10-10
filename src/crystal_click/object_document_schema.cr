module CrystalClick
  # Immutable, explicit schema for the W128 normalized Object V3 part writer.
  # Typed JSON field admission is intentionally closed and owned by
  # ObjectTypedFieldType rather than inferred from all BinaryDataType values.
  class ObjectDocumentSchema
    DEFAULT_MAX_DYNAMIC_PATHS =  1_024
    DEFAULT_MAX_DYNAMIC_TYPES =     32
    MAX_DYNAMIC_PATHS         = 10_000
    MAX_DYNAMIC_TYPES         =    254
    MAX_TYPED_PATHS           =  1_000
    DEFAULT_LIMITS            = ObjectDocumentCodec::DEFAULT_LIMITS

    getter max_dynamic_paths : Int32
    getter max_dynamic_types : Int32
    getter limits : BinaryCodecLimits

    @typed_types : Hash(String, BinaryDataType)
    @typed_paths : Array(String)
    @declaration : String

    def initialize(
      typed_paths : Hash(String, BinaryDataType),
      max_dynamic_paths : Int = DEFAULT_MAX_DYNAMIC_PATHS,
      max_dynamic_types : Int = DEFAULT_MAX_DYNAMIC_TYPES,
      limits : BinaryCodecLimits = DEFAULT_LIMITS,
    )
      @limits = limits
      prepared = prepare_with_budget(
        typed_paths,
        max_dynamic_paths,
        max_dynamic_types,
        BinaryCodecBudget.new(@limits, true),
        1,
        @limits,
      )
      @max_dynamic_paths = prepared[0]
      @max_dynamic_types = prepared[1]
      @typed_types = prepared[2]
      @typed_paths = prepared[3]
      @declaration = prepared[4]
    end

    def initialize(
      typed_paths : Hash(String, BinaryDataType),
      max_dynamic_paths : Int,
      max_dynamic_types : Int,
      budget : BinaryCodecBudget,
      depth : Int = 1,
    )
      @limits = budget.limits
      prepared = prepare_with_budget(typed_paths, max_dynamic_paths, max_dynamic_types, budget, depth, @limits)
      @max_dynamic_paths = prepared[0]
      @max_dynamic_types = prepared[1]
      @typed_types = prepared[2]
      @typed_paths = prepared[3]
      @declaration = prepared[4]
    end

    private def prepare_with_budget(
      typed_paths : Hash(String, BinaryDataType),
      max_dynamic_paths : Int,
      max_dynamic_types : Int,
      budget : BinaryCodecBudget,
      depth : Int,
      limits : BinaryCodecLimits,
    ) : Tuple(Int32, Int32, Hash(String, BinaryDataType), Array(String), String)
      unless 0 <= max_dynamic_paths <= MAX_DYNAMIC_PATHS
        raise ArgumentError.new("JSON max_dynamic_paths is outside the admitted range")
      end
      unless 0 <= max_dynamic_types <= MAX_DYNAMIC_TYPES
        raise ArgumentError.new("JSON max_dynamic_types is outside the admitted range")
      end
      if typed_paths.size > MAX_TYPED_PATHS
        raise ArgumentError.new("JSON schema exceeds the maximum of #{MAX_TYPED_PATHS} typed paths")
      end

      normalized_max_dynamic_paths = max_dynamic_paths.to_i32
      normalized_max_dynamic_types = max_dynamic_types.to_i32
      budget.visit_node(depth)
      inherited_depth = depth.to_i32
      entry_count = typed_paths.size.to_u64
      budget.preflight_children(entry_count) if entry_count > 0_u64
      budget.ensure_depth(depth + 1) if entry_count > 0_u64

      # Inspect all raw keys without copying them, then admit the complete
      # retained-key and declaration output before allocating either.
      raw_key_bytes = 0_u64
      declaration_bytes = declaration_prefix_size
      argument_count = capacity_entry_count(normalized_max_dynamic_paths, normalized_max_dynamic_types).to_u64 + entry_count
      declaration_bytes = checked_add(declaration_bytes, 1_u64) if argument_count > 0_u64 # opening parenthesis
      rendered_entry_count = 0_u64
      unless normalized_max_dynamic_types == DEFAULT_MAX_DYNAMIC_TYPES
        declaration_bytes = checked_add(declaration_bytes, checked_add("max_dynamic_types=".bytesize.to_u64, digits(normalized_max_dynamic_types.to_u64)))
        rendered_entry_count += 1_u64
      end
      unless normalized_max_dynamic_paths == DEFAULT_MAX_DYNAMIC_PATHS
        declaration_bytes = checked_add(declaration_bytes, 2_u64) if rendered_entry_count > 0_u64
        declaration_bytes = checked_add(declaration_bytes, checked_add("max_dynamic_paths=".bytesize.to_u64, digits(normalized_max_dynamic_paths.to_u64)))
        rendered_entry_count += 1_u64
      end
      typed_paths.each do |path, type|
        budget.visit_node(depth + 1)
        validate_path!(path)
        metrics = ObjectRecursiveDeclaration.account_descriptor(type, budget, limits, depth + 1) ||
                  raise ArgumentError.new("typed JSON schema admits only supported Object recursive types")
        type_bytes = metrics.byte_size
        if rendered_entry_count > 0_u64
          declaration_bytes = checked_add(declaration_bytes, 2_u64)
        end
        rendered_entry_count += 1_u64
        rendered_path_bytes = JsonPathSqlName.canonical_size(path.to_slice)
        declaration_bytes = checked_add(declaration_bytes, rendered_path_bytes)
        declaration_bytes = checked_add(declaration_bytes, checked_add(1_u64, type_bytes))
        raw_key_bytes = checked_add(raw_key_bytes, path.bytesize.to_u64)
      end
      declaration_bytes = checked_add(declaration_bytes, 1_u64) if argument_count > 0_u64 # closing parenthesis

      # String.build may temporarily hold a builder and its finished string.
      budget.ensure_wire_bytes(checked_add(raw_key_bytes, checked_multiply(declaration_bytes, 2_u64)))
      budget.charge_wire_bytes(checked_add(raw_key_bytes, checked_multiply(declaration_bytes, 2_u64)))

      typed_types_copy = Hash(String, BinaryDataType).new(initial_capacity: typed_paths.size)
      typed_paths_copy = Array(String).new(typed_paths.size)
      typed_paths.each do |path, type|
        detached = String.new(path.to_slice)
        typed_types_copy[detached] = type
        typed_paths_copy << detached
      end
      typed_paths_copy.sort!
      declaration = render_declaration(
        normalized_max_dynamic_types,
        normalized_max_dynamic_paths,
        typed_paths_copy,
        typed_types_copy,
        limits,
        inherited_depth,
      )
      unless declaration.bytesize.to_u64 == declaration_bytes
        raise UnsupportedFormatError.new("JSON schema declaration exceeded its preflight size")
      end
      {
        normalized_max_dynamic_paths,
        normalized_max_dynamic_types,
        typed_types_copy,
        typed_paths_copy,
        declaration,
      }
    end

    # Every call returns a new Hash with detached path strings. Its complete
    # copy set is budgeted before the first proportional allocation.
    def typed_paths : Hash(String, BinaryDataType)
      budget = BinaryCodecBudget.new(@limits, true)
      budget.visit_node(1)
      count = @typed_paths.size.to_u64
      budget.preflight_children(count) if count > 0_u64
      bytes = 0_u64
      @typed_paths.each do |path|
        budget.visit_node(2)
        bytes = checked_add(bytes, path.bytesize.to_u64)
      end
      budget.ensure_wire_bytes(bytes)
      budget.charge_wire_bytes(bytes)

      detached = Hash(String, BinaryDataType).new(initial_capacity: @typed_types.size)
      @typed_paths.each do |path|
        detached[String.new(path.to_slice)] = @typed_types[path]
      end
      detached
    end

    def declaration : String
      budget = BinaryCodecBudget.new(@limits, true)
      size = @declaration.bytesize.to_u64
      budget.ensure_wire_bytes(size)
      budget.charge_wire_bytes(size)
      String.new(@declaration.to_slice)
    end

    def declaration_byte_size : Int32
      @declaration.bytesize
    end

    # Parse the bounded canonical Object JSON declaration subset accepted by
    # the current normalized Object V3 writer. This deliberately is not a
    # general ClickHouse type parser.
    def self.parse_declaration(type : String, limits : BinaryCodecLimits = DEFAULT_LIMITS) : ObjectDocumentSchema
      ObjectDocumentSchemaParser.parse(type, limits)
    end

    # Validate exact typed-path/type identity and declared dynamic capacities
    # without inferring or modifying either roster.
    def validate_plan(plan : ObjectDocumentPlan) : Nil
      validate_plan(plan, BinaryCodecBudget.new(@limits, true), 1)
    end

    def validate_plan(
      plan : ObjectDocumentPlan,
      budget : BinaryCodecBudget,
      depth : Int = 1,
    ) : Nil
      object = plan.structures.object
      unless ObjectSharedBucketLayout.supported?(object)
        raise ArgumentError.new("schema supports only Object V3 MAP, MAP_WITH_BUCKETS, ADVANCED, or CHUNKED with 1..256 buckets")
      end
      if object.dynamic_path_count > @max_dynamic_paths
        raise ArgumentError.new("Object plan exceeds JSON max_dynamic_paths")
      end
      unless plan.typed_path_count == @typed_paths.size
        raise ArgumentError.new("Object plan typed paths differ from the declared JSON schema")
      end

      context = BinaryCodecContext.new(budget.limits, nil, budget.writing?, budget, false, false)
      context.visit_node(depth)
      total_count = checked_add(object.dynamic_path_count.to_u64, plan.typed_path_count.to_u64)
      context.preflight_children(total_count) if total_count > 0_u64
      context.ensure_depth(depth + 1) if total_count > 0_u64

      path_bytes = 0_u64
      object.dynamic_path_count.times do |index|
        context.visit_node(depth + 1)
        path_bytes = checked_add(path_bytes, object.dynamic_path_byte_size(index).to_u64)
      end
      plan.typed_path_count.times do |index|
        context.visit_node(depth + 1)
        size = plan.typed_path_byte_size_at(index)
        path_bytes = checked_add(path_bytes, size.to_u64)
        unless same_path_bytes?(@typed_paths[index], plan, index, size)
          raise ArgumentError.new("Object plan typed paths differ from the declared JSON schema")
        end
        expected = @typed_types[@typed_paths[index]]
        actual = plan.typed_type_for(@typed_paths[index])
        context.validate_type_tree(expected, depth + 1)
        context.validate_type_tree(actual, depth + 1) unless actual.same?(expected)
        unless actual == expected
          raise ArgumentError.new("Object plan typed type differs from the declared JSON schema")
        end
      end
      context.budget.ensure_wire_bytes(path_bytes)
      context.budget.charge_wire_bytes(path_bytes)

      object.dynamic_path_count.times do |index|
        context.visit_node(depth + 1)
        path = object.dynamic_path_at(index)
        dynamic = plan.structures.dynamic_for(path)
        if dynamic.type_count > @max_dynamic_types
          raise ArgumentError.new("Dynamic path exceeds JSON max_dynamic_types")
        end
      end
      nil
    end

    private def render_declaration(
      max_dynamic_types : Int32,
      max_dynamic_paths : Int32,
      typed_paths : Array(String),
      typed_types : Hash(String, BinaryDataType),
      limits : BinaryCodecLimits,
      inherited_depth : Int32,
    ) : String
      String.build do |io|
        io << "JSON"
        first = true
        if max_dynamic_types != DEFAULT_MAX_DYNAMIC_TYPES
          io << '(' << "max_dynamic_types=" << max_dynamic_types
          first = false
        end
        if max_dynamic_paths != DEFAULT_MAX_DYNAMIC_PATHS
          if first
            io << '('
          else
            io << ", "
          end
          io << "max_dynamic_paths=" << max_dynamic_paths
          first = false
        end
        typed_paths.each do |path|
          if first
            io << '('
          else
            io << ", "
          end
          JsonPathSqlName.write_canonical(io, path.to_slice)
          io << ' '
          ObjectTypedFieldType.append_name(io, typed_types[path], limits, inherited_depth + 1)
          first = false
        end
        io << ')' unless first
      end
    end

    private def declaration_prefix_size : UInt64
      "JSON".bytesize.to_u64
    end

    private def capacity_entry_count(max_dynamic_paths : Int32, max_dynamic_types : Int32) : Int32
      count = 0
      count += 1 unless max_dynamic_types == DEFAULT_MAX_DYNAMIC_TYPES
      count += 1 unless max_dynamic_paths == DEFAULT_MAX_DYNAMIC_PATHS
      count
    end

    private def validate_path!(path : String) : Nil
      JsonPathSqlName.validate_raw_bytes!(path.to_slice)
    end

    private def same_path_bytes?(expected : String, plan : ObjectDocumentPlan, index : Int, actual_size : Int32) : Bool
      return false unless expected.bytesize == actual_size
      actual_size.times do |byte_index|
        return false unless expected.to_slice[byte_index] == plan.typed_path_byte_at(index, byte_index)
      end
      true
    end

    private def digits(value : UInt64) : UInt64
      count = 1_u64
      remaining = value
      while remaining >= 10_u64
        remaining //= 10_u64
        count += 1_u64
      end
      count
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise UnsupportedFormatError.new("JSON schema size overflows UInt64")
      end
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      if right != 0_u64 && left > UInt64::MAX // right
        raise UnsupportedFormatError.new("JSON schema size overflows UInt64")
      end
      left * right
    end
  end
end
