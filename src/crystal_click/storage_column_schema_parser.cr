module CrystalClick
  # Parser for the closed recursive-storage declaration subset. It admits a
  # root Tuple, recursively admits Tuple edges, delegates exact JSON leaves to
  # ObjectDocumentSchemaParser, and delegates JSON-free subtrees to the
  # existing recursive declaration and physical-plan owners.
  class StorageColumnSchemaParser
    private struct Range
      getter first : Int32
      getter after : Int32

      def initialize(@first : Int32, @after : Int32)
      end

      def size : Int32
        @after - @first
      end
    end

    private struct ParsedField
      getter name : String
      getter display : String
      getter child : StorageColumnSchema

      def initialize(@name : String, @display : String, @child : StorageColumnSchema)
      end
    end

    def self.parse(source : String, limits : BinaryCodecLimits = ObjectDocumentSchema::DEFAULT_LIMITS) : StorageColumnSchema
      new(source, limits).parse
    end

    private def initialize(@source : String, @limits : BinaryCodecLimits)
      @bytes = @source.to_slice
      @budget = BinaryCodecBudget.new(@limits, true)
    end

    def parse : StorageColumnSchema
      if @bytes.size > @limits.max_bytes
        raise UnsupportedFormatError.new("recursive storage declaration exceeds configured byte limit")
      end
      first, after = trim(0, @bytes.size)
      unless tuple_slice?(first, after)
        unsupported!("recursive storage currently requires a root Tuple")
      end

      # Only the root retains exact source text. Canonical declarations and
      # detached tuple names can still repeat nested suffixes once per Tuple
      # ancestor, so reserve a depth-scaled upper bound before the first
      # proportional schema/name allocation. JSON and BinaryBulk descriptor
      # owners apply their own grammar-specific budgets as well.
      source_bytes = @bytes.size.to_u64
      depth_factor = checked_add(checked_multiply(@limits.max_depth.to_u64, 3_u64), 2_u64)
      expansion = checked_multiply(source_bytes, depth_factor)
      @budget.ensure_wire_bytes(expansion)
      @budget.charge_wire_bytes(expansion)

      schema = parse_node(first, after, 1, true)
      unless schema.tuple? && schema.has_json?
        unsupported!("recursive storage root Tuple must contain a JSON leaf")
      end
      schema
    rescue ex : ArgumentError
      raise UnsupportedFormatError.new("unsupported recursive storage declaration")
    end

    private def parse_node(first : Int32, after : Int32, depth : Int32, retain_source : Bool = false) : StorageColumnSchema
      first, after = trim(first, after)
      raise UnsupportedFormatError.new("binary codec depth limit exceeded") if depth > @limits.max_depth

      # Whole JSON-free subtrees stay under the existing BinaryBulk owners,
      # including their tuple/LC/Variant physical conventions.
      if preflight = ObjectRecursiveDeclaration.preflight_slice(@bytes, first, after, @limits, depth)
        preflight.account(@budget)
        type = preflight.materialize
        prefix = retain_source ? text(first, after) : ""
        return StorageColumnSchema.bulk(type, prefix)
      end

      if json_slice?(first, after)
        declaration = text(first, after)
        schema = ObjectDocumentSchema.parse_declaration(declaration, @limits)
        # JSON's nominal descriptor tree begins at the structural site depth.
        # The site itself and each typed path are separately charged as
        # storage-owned nodes/edges, but do not add an artificial level to the
        # existing Object value/type depth convention.
        @budget.visit_node(depth)
        typed_paths = schema.typed_paths
        path_count = typed_paths.size.to_u64
        @budget.preflight_children(path_count) if path_count > 0_u64
        typed_paths.each do |_path, type|
          # A typed-path metadata owner is not another value-tree level.
          # Its descriptor begins at this JSON site's structural depth.
          @budget.visit_node(depth)
          unless ObjectRecursiveDeclaration.account_descriptor(type, @budget, @limits, depth)
            unsupported!("typed Object JSON fields admit only supported Object recursive types")
          end
        end
        return StorageColumnSchema.object(schema, retain_source ? declaration : "")
      end

      unless tuple_slice?(first, after)
        unsupported!("JSON is admitted only as a direct Tuple field")
      end

      @budget.visit_node(depth)
      body_first = first + "Tuple(".bytesize
      body_after = after - 1
      source = retain_source ? text(first, after) : ""
      if body_first == body_after
        return StorageColumnSchema.tuple(source, false, [] of String, [] of String, [] of StorageColumnSchema)
      end

      ranges = split_fields(body_first, body_after)
      unsupported!("Tuple arity exceeds ClickHouse's supported maximum") if ranges.size > BinaryDataType::MAX_TUPLE_ARITY
      @budget.preflight_children(ranges.size.to_u64)
      first_named = tuple_field_prefix(ranges[0]) != nil
      if first_named
        # Match ObjectRecursiveDeclaration's named Tuple metadata ownership:
        # one element edge and one node for each retained field name. The
        # conservative source-text expansion above already reserves the
        # decoded/display text bytes before any corresponding String copy.
        @budget.preflight_children(ranges.size.to_u64)
        ranges.size.times { @budget.visit_node(depth) }
      end
      names = Array(String).new(initial_capacity: first_named ? ranges.size : 0)
      displays = Array(String).new(initial_capacity: first_named ? ranges.size : 0)
      fields = Array(ParsedField).new(initial_capacity: ranges.size)
      seen = Set(String).new
      ranges.each do |range|
        prefix = tuple_field_prefix(range)
        if first_named
          unless prefix
            unsupported!("named and unnamed Tuple fields cannot be mixed")
          end
          name_first, name_after, child_first = prefix
          unless shape = ObjectTupleFieldName.shape(@bytes, name_first, name_after)
            unsupported!("Tuple field name is not in canonical ClickHouse form")
          end
          unsupported!("Tuple field name cannot be empty or null") if shape[0] == 0_u64 || ObjectTupleFieldName.null?(@bytes, name_first, name_after)
          name = ObjectTupleFieldName.decode(@bytes, name_first, name_after)
          unsupported!("duplicate Tuple field name") if seen.includes?(name)
          seen << name
          display = text(name_first, name_after)
          child = parse_node(child_first, range.after, depth + 1)
          names << name
          displays << display
          fields << ParsedField.new(name, display, child)
        else
          if prefix
            unsupported!("named and unnamed Tuple fields cannot be mixed")
          end
          child = parse_node(range.first, range.after, depth + 1)
          fields << ParsedField.new("", "", child)
        end
      end

      children = fields.map(&.child)
      StorageColumnSchema.tuple(source, first_named, names, displays, children)
    end

    private def split_fields(first : Int32, after : Int32) : Array(Range)
      ranges = Array(Range).new
      field_first = first
      index = first
      depth = 0
      backtick = false
      backtick_escape = false
      label = false
      label_escape = false
      while index < after
        byte = @bytes[index]
        if label
          if label_escape
            label_escape = false
          elsif byte == '\\'.ord.to_u8
            label_escape = true
          elsif byte == '\''.ord.to_u8
            label = false
          end
        elsif backtick
          if backtick_escape
            backtick_escape = false
          elsif byte == '\\'.ord.to_u8
            backtick_escape = true
          elsif byte == '`'.ord.to_u8
            backtick = false
          end
        else
          case byte
          when '`'.ord.to_u8
            backtick = true
          when '\''.ord.to_u8
            label = true
          when '('.ord.to_u8
            depth += 1
          when ')'.ord.to_u8
            depth -= 1
            unsupported!("unbalanced recursive storage declaration") if depth < 0
          when ','.ord.to_u8
            if depth == 0
              range_first, range_after = trim(field_first, index)
              unsupported!("empty Tuple field") if range_first >= range_after
              ranges << Range.new(range_first, range_after)
              field_first = index + 1
            end
          end
        end
        index += 1
      end
      unsupported!("unterminated Tuple field quote") if backtick || backtick_escape || label
      unsupported!("unbalanced recursive storage declaration") unless depth == 0
      range_first, range_after = trim(field_first, after)
      unsupported!("empty Tuple field") if range_first >= range_after
      ranges << Range.new(range_first, range_after)
      ranges
    end

    private def tuple_field_prefix(range : Range) : {Int32, Int32, Int32}?
      ObjectTupleFieldName.prefix(@bytes, range.first, range.after)
    end

    private def tuple_slice?(first : Int32, after : Int32) : Bool
      after - first >= "Tuple()".bytesize &&
        slice_equals?(first, first + "Tuple(".bytesize, "Tuple(") &&
        @bytes[after - 1] == ')'.ord.to_u8
    end

    private def json_slice?(first : Int32, after : Int32) : Bool
      slice_equals?(first, after, "JSON") ||
        (after - first >= "JSON()".bytesize &&
          slice_equals?(first, first + "JSON(".bytesize, "JSON(") &&
          @bytes[after - 1] == ')'.ord.to_u8)
    end

    private def text(first : Int32, after : Int32) : String
      String.new(@bytes[first, after - first])
    end

    private def trim(first : Int32, after : Int32) : {Int32, Int32}
      left = first
      right = after
      while left < right && whitespace?(@bytes[left])
        left += 1
      end
      while right > left && whitespace?(@bytes[right - 1])
        right -= 1
      end
      {left, right}
    end

    private def whitespace?(byte : UInt8) : Bool
      byte == ' '.ord.to_u8 || byte == '\t'.ord.to_u8 || byte == '\r'.ord.to_u8 || byte == '\n'.ord.to_u8
    end

    private def slice_equals?(first : Int32, after : Int32, expected : String) : Bool
      return false if first < 0 || after < first || after > @bytes.size
      return false unless after - first == expected.bytesize
      expected.to_slice.each_with_index.all? { |byte, offset| @bytes[first + offset] == byte }
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        unsupported!("recursive storage declaration budget overflow")
      end
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      if left != 0_u64 && right > UInt64::MAX // left
        unsupported!("recursive storage declaration budget overflow")
      end
      left * right
    end

    private def unsupported!(message : String) : NoReturn
      raise UnsupportedFormatError.new(message)
    end
  end
end
