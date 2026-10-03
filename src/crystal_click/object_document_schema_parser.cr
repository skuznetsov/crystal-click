module CrystalClick
  # Parser for the deliberately bounded declaration subset emitted by
  # ObjectDocumentSchema. It does not parse general ClickHouse types.
  class ObjectDocumentSchemaParser
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
      getter path : String
      getter type : BinaryDataType

      def initialize(@path : String, @type : BinaryDataType)
      end
    end

    def self.parse(type : String, limits : BinaryCodecLimits = ObjectDocumentSchema::DEFAULT_LIMITS) : ObjectDocumentSchema
      new(type, limits).parse
    end

    private def initialize(@type : String, @limits : BinaryCodecLimits)
      @bytes = @type.to_slice
    end

    def parse : ObjectDocumentSchema
      budget = BinaryCodecBudget.new(@limits, true)
      budget.visit_node(1)
      budget.charge_wire_bytes(@bytes.size.to_u64)

      declaration_first, declaration_after = trim(0, @bytes.size)

      if slice_equals?(declaration_first, declaration_after, "JSON")
        return ObjectDocumentSchema.new({} of String => BinaryDataType, limits: @limits)
      end

      unless declaration_after - declaration_first >= "JSON()".bytesize &&
             slice_equals?(declaration_first, declaration_first + "JSON(".bytesize, "JSON(") &&
             @bytes[declaration_after - 1] == ')'.ord.to_u8
        unsupported!("unsupported Object JSON declaration")
      end

      inner_first = declaration_first + "JSON(".bytesize
      inner_after = declaration_after - 1
      unsupported!("empty Object JSON argument list") if inner_first >= inner_after

      argument_count = count_arguments(inner_first, inner_after)
      budget.preflight_children(argument_count.to_u64)
      fields = Hash(String, BinaryDataType).new
      seen_paths = Set(String).new
      seen_max_dynamic_paths = false
      seen_max_dynamic_types = false
      max_dynamic_paths = ObjectDocumentSchema::DEFAULT_MAX_DYNAMIC_PATHS
      max_dynamic_types = ObjectDocumentSchema::DEFAULT_MAX_DYNAMIC_TYPES

      each_argument(inner_first, inner_after) do |argument|
        budget.visit_node(2)
        if option = parse_option(argument)
          case option[0]
          when :max_dynamic_paths
            unsupported!("duplicate JSON max_dynamic_paths option") if seen_max_dynamic_paths
            seen_max_dynamic_paths = true
            max_dynamic_paths = option[1]
          when :max_dynamic_types
            unsupported!("duplicate JSON max_dynamic_types option") if seen_max_dynamic_types
            seen_max_dynamic_types = true
            max_dynamic_types = option[1]
          else
            unsupported!("unsupported Object JSON capacity option")
          end
        else
          unsupported!("JSON schema exceeds the maximum of #{ObjectDocumentSchema::MAX_TYPED_PATHS} typed paths") if fields.size >= ObjectDocumentSchema::MAX_TYPED_PATHS
          field = parse_field(argument, budget)
          unsupported!("duplicate JSON typed path") if seen_paths.includes?(field.path)
          seen_paths << field.path
          fields[field.path] = field.type
        end
      end

      retained_path_bytes = 0_u64
      fields.each_key do |path|
        retained_path_bytes = checked_add(retained_path_bytes, path.bytesize.to_u64)
      end
      declaration_bytes = canonical_declaration_bytes(fields, max_dynamic_paths, max_dynamic_types)
      budget.charge_wire_bytes(checked_add(retained_path_bytes, checked_multiply(declaration_bytes, 2_u64)))

      ObjectDocumentSchema.new(
        fields,
        max_dynamic_paths: max_dynamic_paths,
        max_dynamic_types: max_dynamic_types,
        limits: @limits
      )
    rescue ex : ArgumentError
      raise UnsupportedFormatError.new("unsupported Object JSON declaration")
    end

    private def count_arguments(first : Int32, after : Int32) : Int32
      scan_arguments(first, after) { |_argument| }
    end

    private def each_argument(first : Int32, after : Int32, &block : Range -> Nil) : Nil
      scan_arguments(first, after) { |argument| yield argument }
      nil
    end

    # Count and enumerate arguments through the same quote/depth state machine.
    # Backticks protect Object paths; single quotes and backslash escapes protect
    # opaque Enum labels so their commas/parentheses never split outer fields.
    private def scan_arguments(first : Int32, after : Int32, &block : Range -> Nil) : Int32
      backtick_quoted = false
      label_quoted = false
      label_escape = false
      depth = 0
      count = 1
      argument_first = first
      index = first
      while index < after
        byte = @bytes[index]
        if label_quoted
          if label_escape
            label_escape = false
          elsif byte == '\\'.ord.to_u8
            label_escape = true
          elsif byte == '\''.ord.to_u8
            label_quoted = false
          end
        elsif backtick_quoted
          backtick_quoted = false if byte == '`'.ord.to_u8
        else
          case byte
          when '`'.ord.to_u8
            backtick_quoted = true
          when '\''.ord.to_u8
            label_quoted = true
          when '('.ord.to_u8
            depth += 1
            unsupported!("nested parentheses are unsupported in Object JSON declarations") if depth > 1
          when ')'.ord.to_u8
            depth -= 1
            unsupported!("unbalanced parentheses in Object JSON declaration") if depth < 0
          when ','.ord.to_u8
            if depth == 0
              yield Range.new(argument_first, index)
              argument_first = index + 1
              count += 1
            end
          end
        end
        index += 1
      end
      unsupported!("unterminated backtick path") if backtick_quoted
      unsupported!("unterminated quoted Enum label") if label_quoted
      unsupported!("unbalanced parentheses in Object JSON declaration") unless depth == 0
      yield Range.new(argument_first, after)
      count
    end

    private def parse_option(argument : Range) : {Symbol, Int32}?
      first, after = trim(argument.first, argument.after)
      key_first = first
      key_after = first
      while key_after < after && !whitespace?(@bytes[key_after]) && @bytes[key_after] != '='.ord.to_u8
        key_after += 1
      end
      cursor = key_after
      while cursor < after && whitespace?(@bytes[cursor])
        cursor += 1
      end
      return nil unless cursor < after && @bytes[cursor] == '='.ord.to_u8

      key = if slice_equals?(key_first, key_after, "max_dynamic_paths")
              :max_dynamic_paths
            elsif slice_equals?(key_first, key_after, "max_dynamic_types")
              :max_dynamic_types
            else
              unsupported!("unsupported Object JSON capacity option")
            end
      value_first, value_after = trim(cursor + 1, after)
      value = parse_decimal(value_first, value_after)
      {key, value}
    end

    private def parse_field(argument : Range, budget : BinaryCodecBudget) : ParsedField
      first, after = trim(argument.first, argument.after)
      unsupported!("empty Object JSON typed field") if first >= after

      quoted = @bytes[first] == '`'.ord.to_u8
      path_first = first
      path_after = first
      cursor = first
      if quoted
        path_first += 1
        cursor = path_first
        while cursor < after && @bytes[cursor] != '`'.ord.to_u8
          cursor += 1
        end
        unsupported!("unterminated backtick path") if cursor >= after
        path_after = cursor
        cursor += 1
      else
        while cursor < after && !whitespace?(@bytes[cursor])
          unsupported!("unexpected backtick in Object JSON path") if @bytes[cursor] == '`'.ord.to_u8
          cursor += 1
        end
        path_after = cursor
      end
      unsupported!("empty Object JSON typed path") if path_first >= path_after

      had_separator = false
      while cursor < after && whitespace?(@bytes[cursor])
        had_separator = true
        cursor += 1
      end
      unsupported!("Object JSON typed path must be followed by one supported type") unless had_separator && cursor < after

      type_first = cursor

      budget.charge_wire_bytes((path_after - path_first).to_u64)
      path = String.new(@bytes[path_first, path_after - path_first])
      validate_path_spelling!(path, quoted)
      # Resolve the complete type tail. Decimal's canonical spelling contains
      # one internal space, while exact whole-tail matching still rejects
      # extra tokens and nested/general type syntax.
      resolution = ObjectTypedFieldType.resolve_slice(@bytes, type_first, after) ||
                   unsupported!("typed Object JSON fields admit only supported nominal scalar types")
      budget.charge_wire_bytes((resolution.byte_size + 1).to_u64)
      if resolution.enum_entry_count > 0_u64
        budget.preflight_children(resolution.enum_entry_count)
        budget.charge_wire_bytes(checked_multiply(resolution.decoded_label_bytes, 2_u64))
        resolution.enum_entry_count.times { budget.visit_node(2) }
      end
      type = resolution.materialize

      ParsedField.new(path, type)
    end

    private def canonical_declaration_bytes(fields : Hash(String, BinaryDataType), max_dynamic_paths : Int32, max_dynamic_types : Int32) : UInt64
      argument_count = 0_u64
      size = "JSON".bytesize.to_u64
      unless max_dynamic_types == ObjectDocumentSchema::DEFAULT_MAX_DYNAMIC_TYPES
        size = checked_add(size, "max_dynamic_types=".bytesize.to_u64)
        size = checked_add(size, decimal_digits(max_dynamic_types.to_u64))
        argument_count += 1_u64
      end
      unless max_dynamic_paths == ObjectDocumentSchema::DEFAULT_MAX_DYNAMIC_PATHS
        size = checked_add(size, 2_u64) if argument_count > 0_u64
        size = checked_add(size, "max_dynamic_paths=".bytesize.to_u64)
        size = checked_add(size, decimal_digits(max_dynamic_paths.to_u64))
        argument_count += 1_u64
      end
      fields.each do |path, type|
        size = checked_add(size, 2_u64) if argument_count > 0_u64
        size = checked_add(size, path.bytesize.to_u64)
        size = checked_add(size, 2_u64) if path.includes?('.') || reserved_path?(path)
        type_bytes = ObjectTypedFieldType.byte_size_for(type) || unsupported!("unsupported Object JSON typed field type")
        size = checked_add(size, checked_add(1_u64, type_bytes))
        argument_count += 1_u64
      end
      if argument_count > 0_u64
        size = checked_add(size, 2_u64)
      end
      size
    end

    private def validate_path_spelling!(path : String, quoted : Bool) : Nil
      bytes = path.to_slice
      unsupported!("typed JSON paths must be dotted ASCII identifiers") if bytes.empty?
      segment_start = true
      bytes.each do |byte|
        if byte == '.'.ord.to_u8
          unsupported!("typed JSON paths must be dotted ASCII identifiers") if segment_start
          segment_start = true
        elsif segment_start
          unless ascii_letter?(byte) || byte == '_'.ord.to_u8
            unsupported!("typed JSON paths must be dotted ASCII identifiers")
          end
          segment_start = false
        elsif !(ascii_letter?(byte) || ascii_digit?(byte) || byte == '_'.ord.to_u8)
          unsupported!("typed JSON paths must be dotted ASCII identifiers")
        end
      end
      unsupported!("typed JSON paths must be dotted ASCII identifiers") if segment_start

      requires_quotes = path.includes?('.') || reserved_path?(path)
      unsupported!("dotted and reserved JSON paths must be backtick quoted") if requires_quotes && !quoted
      nil
    end

    private def reserved_path?(path : String) : Bool
      {
        "SKIP", "null", "inf", "infinity", "nan", "true", "false", "distinct", "all", "some",
        "table", "select", "cube", "rollup", "recursive", "from", "top", "values",
      }.any? { |word| ascii_case_equal?(path, word) }
    end

    private def parse_decimal(first : Int32, after : Int32) : Int32
      unsupported!("empty Object JSON capacity value") if first >= after
      unsupported!("noncanonical Object JSON capacity value") if after - first > 1 && @bytes[first] == '0'.ord.to_u8

      value = 0
      index = first
      while index < after
        byte = @bytes[index]
        unsupported!("invalid Object JSON capacity value") unless byte >= '0'.ord.to_u8 && byte <= '9'.ord.to_u8
        digit = (byte - '0'.ord.to_u8).to_i
        if value > (Int32::MAX - digit) // 10
          unsupported!("Object JSON capacity value exceeds Int32")
        end
        value = value * 10 + digit
        index += 1
      end
      value
    end

    private def decimal_digits(value : UInt64) : UInt64
      digits = 1_u64
      while value >= 10_u64
        value /= 10_u64
        digits += 1_u64
      end
      digits
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      unsupported!("Object JSON declaration size overflows") if right > UInt64::MAX - left
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      unsupported!("Object JSON declaration size overflows") if left > 0_u64 && right > UInt64::MAX // left
      left * right
    end

    private def find_byte(first : Int32, after : Int32, target : UInt8) : Int32?
      index = first
      while index < after
        return index if @bytes[index] == target
        index += 1
      end
      nil
    end

    private def trim(first : Int32, after : Int32) : {Int32, Int32}
      while first < after && whitespace?(@bytes[first])
        first += 1
      end
      while after > first && whitespace?(@bytes[after - 1])
        after -= 1
      end
      {first, after}
    end

    private def whitespace?(byte : UInt8) : Bool
      byte == ' '.ord.to_u8 || byte == '\t'.ord.to_u8 || byte == '\r'.ord.to_u8 || byte == '\n'.ord.to_u8
    end

    private def slice_equals?(first : Int32, after : Int32, expected : String) : Bool
      return false unless after - first == expected.bytesize
      expected_bytes = expected.to_slice
      expected_bytes.size.times do |index|
        return false unless @bytes[first + index] == expected_bytes[index]
      end
      true
    end

    private def ascii_case_equal?(value : String, expected : String) : Bool
      return false unless value.bytesize == expected.bytesize
      left = value.to_slice
      right = expected.to_slice
      left.size.times do |index|
        return false unless ascii_lower(left[index]) == ascii_lower(right[index])
      end
      true
    end

    private def ascii_letter?(byte : UInt8) : Bool
      byte >= 'a'.ord.to_u8 && byte <= 'z'.ord.to_u8 || byte >= 'A'.ord.to_u8 && byte <= 'Z'.ord.to_u8
    end

    private def ascii_digit?(byte : UInt8) : Bool
      byte >= '0'.ord.to_u8 && byte <= '9'.ord.to_u8
    end

    private def ascii_lower(byte : UInt8) : UInt8
      byte >= 'A'.ord.to_u8 && byte <= 'Z'.ord.to_u8 ? byte + 32_u8 : byte
    end

    private def unsupported!(message : String) : NoReturn
      raise UnsupportedFormatError.new(message)
    end
  end
end
