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
      @limits : BinaryCodecLimits = DEFAULT_LIMITS,
    )
      unless 0 <= max_dynamic_paths <= MAX_DYNAMIC_PATHS
        raise ArgumentError.new("JSON max_dynamic_paths is outside the admitted range")
      end
      unless 0 <= max_dynamic_types <= MAX_DYNAMIC_TYPES
        raise ArgumentError.new("JSON max_dynamic_types is outside the admitted range")
      end
      if typed_paths.size > MAX_TYPED_PATHS
        raise ArgumentError.new("JSON schema exceeds the maximum of #{MAX_TYPED_PATHS} typed paths")
      end

      @max_dynamic_paths = max_dynamic_paths.to_i32
      @max_dynamic_types = max_dynamic_types.to_i32
      budget = BinaryCodecBudget.new(@limits, true)
      budget.visit_node(1)
      entry_count = typed_paths.size.to_u64
      budget.preflight_children(entry_count) if entry_count > 0_u64

      # Inspect all raw keys without copying them, then admit the complete
      # retained-key and declaration output before allocating either.
      raw_key_bytes = 0_u64
      declaration_bytes = declaration_prefix_size
      argument_count = capacity_entry_count.to_u64 + entry_count
      declaration_bytes = checked_add(declaration_bytes, 1_u64) if argument_count > 0_u64 # opening parenthesis
      rendered_entry_count = 0_u64
      unless @max_dynamic_types == DEFAULT_MAX_DYNAMIC_TYPES
        declaration_bytes = checked_add(declaration_bytes, checked_add("max_dynamic_types=".bytesize.to_u64, digits(@max_dynamic_types.to_u64)))
        rendered_entry_count += 1_u64
      end
      unless @max_dynamic_paths == DEFAULT_MAX_DYNAMIC_PATHS
        declaration_bytes = checked_add(declaration_bytes, 2_u64) if rendered_entry_count > 0_u64
        declaration_bytes = checked_add(declaration_bytes, checked_add("max_dynamic_paths=".bytesize.to_u64, digits(@max_dynamic_paths.to_u64)))
        rendered_entry_count += 1_u64
      end
      typed_paths.each do |path, type|
        budget.visit_node(2)
        validate_path!(path)
        metadata_count = type.metadata_entry_count.to_u64
        if metadata_count > 0_u64
          budget.preflight_children(metadata_count)
          metadata_count.times { budget.visit_node(2) }
        end
        type_bytes = ObjectTypedFieldType.byte_size_for(type) ||
                     raise ArgumentError.new("typed JSON schema admits only supported nominal scalar types")
        if rendered_entry_count > 0_u64
          declaration_bytes = checked_add(declaration_bytes, 2_u64)
        end
        rendered_entry_count += 1_u64
        quoted = quoted_path?(path)
        rendered_path_bytes = path.bytesize.to_u64
        rendered_path_bytes = checked_add(rendered_path_bytes, 2_u64) if quoted
        declaration_bytes = checked_add(declaration_bytes, rendered_path_bytes)
        declaration_bytes = checked_add(declaration_bytes, checked_add(1_u64, type_bytes))
        raw_key_bytes = checked_add(raw_key_bytes, path.bytesize.to_u64)
      end
      declaration_bytes = checked_add(declaration_bytes, 1_u64) if argument_count > 0_u64 # closing parenthesis

      # String.build may temporarily hold a builder and its finished string.
      budget.ensure_wire_bytes(checked_add(raw_key_bytes, checked_multiply(declaration_bytes, 2_u64)))
      budget.charge_wire_bytes(checked_add(raw_key_bytes, checked_multiply(declaration_bytes, 2_u64)))

      @typed_types = Hash(String, BinaryDataType).new(initial_capacity: typed_paths.size)
      @typed_paths = Array(String).new(typed_paths.size)
      typed_paths.each do |path, type|
        detached = String.new(path.to_slice)
        @typed_types[detached] = type
        @typed_paths << detached
      end
      @typed_paths.sort!
      @declaration = render_declaration
      unless @declaration.bytesize.to_u64 == declaration_bytes
        raise UnsupportedFormatError.new("JSON schema declaration exceeded its preflight size")
      end
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
      object = plan.structures.object
      unless object.version == 4_u64 && object.shared_data_version == 0_u64 && object.bucket_count == 1_u64
        raise ArgumentError.new("schema supports only Object V3 with one MAP bucket")
      end
      if object.dynamic_path_count > @max_dynamic_paths
        raise ArgumentError.new("Object plan exceeds JSON max_dynamic_paths")
      end
      unless plan.typed_path_count == @typed_paths.size
        raise ArgumentError.new("Object plan typed paths differ from the declared JSON schema")
      end

      budget = BinaryCodecBudget.new(@limits, true)
      budget.visit_node(1)
      total_count = checked_add(object.dynamic_path_count.to_u64, plan.typed_path_count.to_u64)
      budget.preflight_children(total_count) if total_count > 0_u64

      path_bytes = 0_u64
      object.dynamic_path_count.times do |index|
        budget.visit_node(2)
        path_bytes = checked_add(path_bytes, object.dynamic_path_byte_size(index).to_u64)
      end
      plan.typed_path_count.times do |index|
        budget.visit_node(2)
        size = plan.typed_path_byte_size_at(index)
        path_bytes = checked_add(path_bytes, size.to_u64)
        unless same_path_bytes?(@typed_paths[index], plan, index, size)
          raise ArgumentError.new("Object plan typed paths differ from the declared JSON schema")
        end
        expected = @typed_types[@typed_paths[index]]
        unless plan.typed_type_for(@typed_paths[index]) == expected
          raise ArgumentError.new("Object plan typed type differs from the declared JSON schema")
        end
      end
      budget.ensure_wire_bytes(path_bytes)
      budget.charge_wire_bytes(path_bytes)

      object.dynamic_path_count.times do |index|
        budget.visit_node(2)
        path = object.dynamic_path_at(index)
        dynamic = plan.structures.dynamic_for(path)
        if dynamic.type_count > @max_dynamic_types
          raise ArgumentError.new("Dynamic path exceeds JSON max_dynamic_types")
        end
      end
      nil
    end

    private def render_declaration : String
      String.build do |io|
        io << "JSON"
        first = true
        if @max_dynamic_types != DEFAULT_MAX_DYNAMIC_TYPES
          io << '(' << "max_dynamic_types=" << @max_dynamic_types
          first = false
        end
        if @max_dynamic_paths != DEFAULT_MAX_DYNAMIC_PATHS
          if first
            io << '('
          else
            io << ", "
          end
          io << "max_dynamic_paths=" << @max_dynamic_paths
          first = false
        end
        @typed_paths.each do |path|
          if first
            io << '('
          else
            io << ", "
          end
          if quoted_path?(path)
            io << '`' << path << '`'
          else
            io << path
          end
          io << ' '
          ObjectTypedFieldType.append_name(io, @typed_types[path])
          first = false
        end
        io << ')' unless first
      end
    end

    private def declaration_prefix_size : UInt64
      "JSON".bytesize.to_u64
    end

    private def capacity_entry_count : Int32
      count = 0
      count += 1 unless @max_dynamic_types == DEFAULT_MAX_DYNAMIC_TYPES
      count += 1 unless @max_dynamic_paths == DEFAULT_MAX_DYNAMIC_PATHS
      count
    end

    private def quoted_path?(path : String) : Bool
      return true if path.includes?('.')
      return true if ascii_case_equal?(path, "SKIP")
      return true if ascii_case_equal?(path, "null")
      return true if {
                       "inf", "infinity", "nan", "true", "false", "distinct", "all", "some",
                       "table", "select", "cube", "rollup", "recursive", "from", "top", "values",
                     }.any? { |word| ascii_case_equal?(path, word) }
      false
    end

    private def validate_path!(path : String) : Nil
      bytes = path.to_slice
      raise ArgumentError.new("typed JSON path cannot be empty") if bytes.empty?
      segment_start = true
      bytes.each do |byte|
        if byte == '.'.ord.to_u8
          if segment_start
            raise ArgumentError.new("typed JSON paths must be dotted ASCII identifiers")
          end
          segment_start = true
        elsif segment_start
          unless ascii_letter?(byte) || byte == '_'.ord.to_u8
            raise ArgumentError.new("typed JSON paths must be dotted ASCII identifiers")
          end
          segment_start = false
        elsif !(ascii_letter?(byte) || ascii_digit?(byte) || byte == '_'.ord.to_u8)
          raise ArgumentError.new("typed JSON paths must be dotted ASCII identifiers")
        end
      end
      raise ArgumentError.new("typed JSON paths must be dotted ASCII identifiers") if segment_start
      nil
    end

    private def same_path_bytes?(expected : String, plan : ObjectDocumentPlan, index : Int, actual_size : Int32) : Bool
      return false unless expected.bytesize == actual_size
      actual_size.times do |byte_index|
        return false unless expected.to_slice[byte_index] == plan.typed_path_byte_at(index, byte_index)
      end
      true
    end

    private def ascii_case_equal?(value : String, expected : String) : Bool
      return false unless value.bytesize == expected.bytesize
      value.to_slice.each_with_index do |byte, index|
        left = ascii_lower(byte)
        right = ascii_lower(expected.to_slice[index])
        return false unless left == right
      end
      true
    end

    private def ascii_lower(byte : UInt8) : UInt8
      byte >= 'A'.ord.to_u8 && byte <= 'Z'.ord.to_u8 ? byte + 32_u8 : byte
    end

    private def ascii_letter?(byte : UInt8) : Bool
      (byte >= 'a'.ord.to_u8 && byte <= 'z'.ord.to_u8) || (byte >= 'A'.ord.to_u8 && byte <= 'Z'.ord.to_u8)
    end

    private def ascii_digit?(byte : UInt8) : Bool
      byte >= '0'.ord.to_u8 && byte <= '9'.ord.to_u8
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
