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
    @skip_path_owner : JsonSkipPaths
    @declaration : String

    def initialize(
      typed_paths : Hash(String, BinaryDataType),
      max_dynamic_paths : Int = DEFAULT_MAX_DYNAMIC_PATHS,
      max_dynamic_types : Int = DEFAULT_MAX_DYNAMIC_TYPES,
      limits : BinaryCodecLimits = DEFAULT_LIMITS,
      skip_paths : Array(String) = [] of String,
    )
      @limits = limits
      prepared = prepare_with_budget(
        typed_paths,
        max_dynamic_paths,
        max_dynamic_types,
        BinaryCodecBudget.new(@limits, true),
        1,
        @limits,
        skip_paths,
      )
      @max_dynamic_paths = prepared[0]
      @max_dynamic_types = prepared[1]
      @typed_types = prepared[2]
      @typed_paths = prepared[3]
      @skip_path_owner = prepared[4]
      @declaration = prepared[5]
    end

    def initialize(
      typed_paths : Hash(String, BinaryDataType),
      max_dynamic_paths : Int,
      max_dynamic_types : Int,
      budget : BinaryCodecBudget,
      depth : Int = 1,
      skip_paths : Array(String) = [] of String,
    )
      @limits = budget.limits
      prepared = prepare_with_budget(typed_paths, max_dynamic_paths, max_dynamic_types, budget, depth, @limits, skip_paths)
      @max_dynamic_paths = prepared[0]
      @max_dynamic_types = prepared[1]
      @typed_types = prepared[2]
      @typed_paths = prepared[3]
      @skip_path_owner = prepared[4]
      @declaration = prepared[5]
    end

    private def prepare_with_budget(
      typed_paths : Hash(String, BinaryDataType),
      max_dynamic_paths : Int,
      max_dynamic_types : Int,
      budget : BinaryCodecBudget,
      depth : Int,
      limits : BinaryCodecLimits,
      skip_paths : Array(String),
    ) : Tuple(Int32, Int32, Hash(String, BinaryDataType), Array(String), JsonSkipPaths, String)
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
      skip_entry_count = skip_paths.size.to_u64
      budget.preflight_children(entry_count) if entry_count > 0_u64
      budget.ensure_depth(depth + 1) if entry_count > 0_u64
      # Reject an over-budget supplied roster before walking or sorting it.
      # JsonSkipPaths charges these entries when it takes ownership below.
      budget.ensure_future_elements(skip_entry_count) if skip_entry_count > 0_u64
      budget.ensure_future_nodes(skip_entry_count) if skip_entry_count > 0_u64
      budget.ensure_depth(depth + 1) if skip_entry_count > 0_u64

      # Inspect every supplied SKIP name (including duplicates) before any
      # retained copy. The shared owner charges their nodes, edges, and wire
      # bytes when it takes ownership; these checks only preflight headroom.
      skip_wire_bytes = 0_u64
      skip_render_upper_bound = 0_u64
      skip_paths.each do |skip_path|
        JsonPathSqlName.validate_raw_bytes!(skip_path.to_slice)
        if JsonSkipPaths.regexp_path?(skip_path.to_slice)
          raise ArgumentError.new("Object JSON SKIP REGEXP path has no reparsable canonical SQL name")
        end
        path_bytes = skip_path.bytesize.to_u64
        skip_wire_bytes = checked_add(skip_wire_bytes, checked_add(path_bytes, var_uint_size(path_bytes)))
        rendered_path_bytes = JsonPathSqlName.canonical_size(skip_path.to_slice, quote_skip_keyword: false)
        # Include every supplied entry (also duplicates), plus a conservative
        # separator allowance for each one. The normalized exact size is
        # measured after sorting and deduplication below.
        skip_render_upper_bound = checked_add(
          skip_render_upper_bound,
          checked_add(2_u64, checked_add("SKIP ".bytesize.to_u64, rendered_path_bytes)),
        )
      end
      if skip_entry_count > 0_u64
        conservative_declaration_bytes = checked_add(
          declaration_prefix_size,
          checked_add(skip_render_upper_bound, 2_u64), # parentheses
        )
        budget.ensure_wire_bytes(checked_add(
          skip_wire_bytes,
          checked_multiply(conservative_declaration_bytes, 2_u64),
        ))
      else
        budget.ensure_wire_bytes(skip_wire_bytes)
      end

      # Inspect all raw keys without copying them, then admit the complete
      # retained-key and declaration output before allocating either.
      raw_key_bytes = 0_u64
      declaration_bytes = declaration_prefix_size
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

      # Recursive typed descriptors may have consumed part of the shared
      # operation budget, so recheck the SKIP roster immediately before its
      # normalization work and later owner materialization.
      budget.ensure_future_elements(skip_entry_count) if skip_entry_count > 0_u64
      budget.ensure_future_nodes(skip_entry_count) if skip_entry_count > 0_u64
      budget.ensure_depth(depth + 1) if skip_entry_count > 0_u64
      # Preflight a linear, duplicate-inclusive upper bound for the complete
      # declaration before sorting or checking typed-path conflicts.
      conservative_argument_count = capacity_entry_count(normalized_max_dynamic_paths, normalized_max_dynamic_types).to_u64 + entry_count + skip_entry_count
      conservative_declaration_bytes = checked_add(declaration_bytes, skip_render_upper_bound)
      conservative_declaration_bytes = checked_add(conservative_declaration_bytes, 2_u64) if conservative_argument_count > 0_u64
      conservative_retained_wire_bytes = checked_add(raw_key_bytes, checked_multiply(conservative_declaration_bytes, 2_u64))
      budget.ensure_wire_bytes(checked_add(skip_wire_bytes, conservative_retained_wire_bytes))

      # Sort references, not strings, so normalization is O(n log n) while all
      # supplied duplicate bytes remain included in skip_wire_bytes.
      ordered_skip_paths = Array(String).new(skip_paths.size)
      skip_paths.each { |path| ordered_skip_paths << path }
      ordered_skip_paths.sort! { |left, right| JsonSkipPaths.compare_raw(left, right) }
      unique_skip_count = 0
      ordered_skip_paths.each do |skip_path|
        if unique_skip_count == 0 || ordered_skip_paths[unique_skip_count - 1] != skip_path
          ordered_skip_paths[unique_skip_count] = skip_path
          unique_skip_count += 1
        end
      end
      while ordered_skip_paths.size > unique_skip_count
        ordered_skip_paths.pop
      end
      unique_skip_count_u64 = unique_skip_count.to_u64
      argument_count = capacity_entry_count(normalized_max_dynamic_paths, normalized_max_dynamic_types).to_u64 + entry_count + unique_skip_count_u64

      typed_path_refs = Array(String).new(typed_paths.size)
      typed_paths.each_key { |typed_path| typed_path_refs << typed_path }
      typed_path_refs.sort! { |left, right| JsonSkipPaths.compare_raw(left, right) }
      ordered_skip_paths.each do |skip_path|
        if typed_path_conflicts?(typed_path_refs, skip_path)
          raise ArgumentError.new("JSON typed path conflicts with a SKIP path")
        end

        declaration_bytes = checked_add(declaration_bytes, 2_u64) if rendered_entry_count > 0_u64
        rendered_entry_count += 1_u64
        declaration_bytes = checked_add(declaration_bytes, "SKIP ".bytesize.to_u64)
        rendered_path_bytes = JsonPathSqlName.canonical_size(skip_path.to_slice, quote_skip_keyword: false)
        declaration_bytes = checked_add(declaration_bytes, rendered_path_bytes)
      end
      declaration_bytes = checked_add(declaration_bytes, 2_u64) if argument_count > 0_u64 # parentheses

      # String.build may temporarily hold a builder and its finished string.
      retained_wire_bytes = checked_add(raw_key_bytes, checked_multiply(declaration_bytes, 2_u64))
      budget.ensure_future_elements(skip_entry_count) if skip_entry_count > 0_u64
      budget.ensure_future_nodes(skip_entry_count) if skip_entry_count > 0_u64
      budget.ensure_depth(depth + 1) if skip_entry_count > 0_u64
      budget.ensure_wire_bytes(checked_add(skip_wire_bytes, retained_wire_bytes))

      skip_path_owner = JsonSkipPaths.new(skip_paths, budget, depth + 1)
      budget.charge_wire_bytes(retained_wire_bytes)

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
        skip_path_owner,
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
        skip_path_owner,
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

    # Every call returns detached raw-name strings. The full copy set is
    # budgeted before the owner materializes the snapshot.
    def skip_paths : Array(String)
      budget = BinaryCodecBudget.new(@limits, true)
      budget.visit_node(1)
      count = @skip_path_owner.skip_path_count.to_u64
      budget.preflight_children(count) if count > 0_u64
      bytes = 0_u64
      @skip_path_owner.skip_path_count.times do |index|
        budget.visit_node(2)
        bytes = checked_add(bytes, @skip_path_owner.skip_path_byte_size(index).to_u64)
      end
      budget.ensure_wire_bytes(bytes)
      budget.charge_wire_bytes(bytes)
      @skip_path_owner.skip_paths
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
    # the current normalized Object writer. This deliberately is not a
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
        raise ArgumentError.new("schema supports Object V1/V2 MAP and Object V3 MAP, MAP_WITH_BUCKETS, ADVANCED, or CHUNKED layouts")
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
      skip_paths : JsonSkipPaths,
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
        skip_paths.skip_path_count.times do |index|
          if first
            io << '('
          else
            io << ", "
          end
          io << "SKIP "
          JsonPathSqlName.write_canonical(
            io,
            skip_paths.skip_path_byte_size(index),
            quote_skip_keyword: false,
          ) do |byte_index|
            skip_paths.skip_path_byte_at(index, byte_index)
          end
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

    private def typed_path_conflicts?(typed_paths : Array(String), skip_path : String) : Bool
      low = 0
      high = typed_paths.size
      while low < high
        middle = low + (high - low) // 2
        comparison = JsonSkipPaths.compare_raw(typed_paths[middle], skip_path)
        if comparison < 0
          low = middle + 1
        else
          high = middle
        end
      end

      if typed_path = typed_paths[low]?
        JsonSkipPaths.raw_starts_with?(typed_path, skip_path)
      else
        false
      end
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

    private def var_uint_size(value : UInt64) : UInt64
      size = 1_u64
      remaining = value
      while remaining >= 0x80_u64
        remaining >>= 7
        size += 1_u64
      end
      size
    end
  end
end
