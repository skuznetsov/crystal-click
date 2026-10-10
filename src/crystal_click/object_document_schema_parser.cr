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
      getter preflight : ObjectRecursiveDeclaration::Preflight

      def initialize(@path : String, @preflight : ObjectRecursiveDeclaration::Preflight)
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
      pending_fields = Array(ParsedField).new
      skip_measures = Array(JsonPathSqlName::TokenMeasure).new
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
        elsif skip_measure = parse_skip_path(argument)
          skip_measures << skip_measure
        else
          unsupported!("JSON schema exceeds the maximum of #{ObjectDocumentSchema::MAX_TYPED_PATHS} typed paths") if pending_fields.size >= ObjectDocumentSchema::MAX_TYPED_PATHS
          field = parse_field(argument, budget)
          unsupported!("duplicate JSON typed path") if seen_paths.includes?(field.path)
          seen_paths << field.path
          pending_fields << field
        end
      end

      skip_paths = materialize_skip_paths(skip_measures, budget)

      # Every recursive declaration and aggregate metadata charge is admitted
      # before constructing any descriptor tree.
      fields = Hash(String, BinaryDataType).new(initial_capacity: pending_fields.size)
      pending_fields.each do |field|
        fields[field.path] = field.preflight.materialize
      end

      retained_path_bytes = 0_u64
      fields.each_key do |path|
        retained_path_bytes = checked_add(retained_path_bytes, path.bytesize.to_u64)
      end
      skip_paths.each do |path|
        retained_path_bytes = checked_add(retained_path_bytes, path.bytesize.to_u64)
      end
      skip_paths.sort! { |left, right| JsonSkipPaths.compare_raw(left, right) }
      declaration_bytes = canonical_declaration_bytes(fields, skip_paths, max_dynamic_paths, max_dynamic_types)
      budget.charge_wire_bytes(checked_add(retained_path_bytes, checked_multiply(declaration_bytes, 2_u64)))

      ObjectDocumentSchema.new(
        fields,
        max_dynamic_paths: max_dynamic_paths,
        max_dynamic_types: max_dynamic_types,
        limits: @limits,
        skip_paths: skip_paths,
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
      backtick_escape = false
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
          if backtick_escape
            backtick_escape = false
          elsif byte == '\\'.ord.to_u8
            backtick_escape = true
          elsif byte == '`'.ord.to_u8
            backtick_quoted = false
          end
        else
          case byte
          when '`'.ord.to_u8
            backtick_quoted = true
          when '\''.ord.to_u8
            label_quoted = true
          when '('.ord.to_u8
            depth += 1
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
      unsupported!("unterminated backtick path") if backtick_quoted || backtick_escape
      unsupported!("unterminated quoted Enum label") if label_quoted
      unsupported!("unbalanced parentheses in Object JSON declaration") unless depth == 0
      yield Range.new(argument_first, after)
      count
    end

    private def parse_option(argument : Range) : {Symbol, Int32}?
      first, after = trim(argument.first, argument.after)
      # A quoted option-like name is always a field path, never capacity
      # syntax. In particular, `max_dynamic_paths=...` inside backticks must
      # not be split at its equals sign.
      return nil if first >= after || @bytes[first] == '`'.ord.to_u8

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
              # An equals sign is also an ordinary byte in a raw path name.
              return nil
            end
      value_first, value_after = trim(cursor + 1, after)
      value = parse_decimal(value_first, value_after)
      {key, value}
    end

    private def parse_field(argument : Range, budget : BinaryCodecBudget) : ParsedField
      first, after = trim(argument.first, argument.after)
      unsupported!("empty Object JSON typed field") if first >= after

      measure = JsonPathSqlName.scan_token(@bytes, first) || unsupported!("invalid Object JSON path")
      cursor = measure.token_after

      had_separator = false
      while cursor < after && whitespace?(@bytes[cursor])
        had_separator = true
        cursor += 1
      end
      unsupported!("Object JSON typed path must be followed by one supported type") unless had_separator && cursor < after

      type_first = cursor

      # Resolve the complete type tail before allocating its descriptor tree.
      # Recursive leaf resolution still delegates existing scalar grammar.
      resolution = ObjectRecursiveDeclaration.preflight_slice(@bytes, type_first, after, @limits, 2) ||
                   unsupported!("typed Object JSON fields admit only supported Object recursive types")
      resolution.account(budget)

      path = JsonPathSqlName.decode_token(@bytes, measure, budget)
      JsonPathSqlName.validate_raw_bytes!(path.to_slice)
      unless measure.quoted || JsonPathSqlName.canonical_size(path.to_slice) == path.bytesize.to_u64
        unsupported!("noncanonical Object JSON path must be backtick quoted")
      end
      ParsedField.new(path, resolution)
    end

    private def parse_skip_path(argument : Range) : JsonPathSqlName::TokenMeasure?
      first, after = trim(argument.first, argument.after)
      return nil unless starts_with_skip_keyword?(first, after)

      cursor = first + "SKIP".bytesize
      unless cursor < after && whitespace?(@bytes[cursor])
        unsupported!("SKIP requires one raw path")
      end
      while cursor < after && whitespace?(@bytes[cursor])
        cursor += 1
      end
      unsupported!("SKIP requires one raw path") if cursor >= after

      measure = JsonPathSqlName.scan_token(@bytes, cursor) || unsupported!("invalid Object JSON SKIP path")
      tail = measure.token_after
      while tail < after && whitespace?(@bytes[tail])
        tail += 1
      end
      unsupported!("SKIP accepts exactly one raw path") unless tail == after

      measure
    end

    private def materialize_skip_paths(
      measures : Array(JsonPathSqlName::TokenMeasure),
      budget : BinaryCodecBudget,
    ) : Array(String)
      total_bytes = 0_u64
      measures.each do |measure|
        total_bytes = checked_add(total_bytes, measure.decoded_bytes)
      end
      # All supplied entries, including duplicates, are known before the first
      # decoded path string is retained.
      budget.ensure_wire_bytes(total_bytes)

      skip_paths = Array(String).new(measures.size)
      measures.each do |measure|
        path = JsonPathSqlName.decode_token(@bytes, measure, budget)
        JsonPathSqlName.validate_raw_bytes!(path.to_slice)
        unsupported!("Object JSON SKIP REGEXP path has no reparsable canonical SQL name") if JsonSkipPaths.regexp_path?(path.to_slice)
        unless measure.quoted || JsonPathSqlName.canonical_size(path.to_slice, quote_skip_keyword: false) == path.bytesize.to_u64
          unsupported!("noncanonical Object JSON SKIP path must be backtick quoted")
        end
        skip_paths << path
      end
      skip_paths
    end

    private def starts_with_skip_keyword?(first : Int32, after : Int32) : Bool
      return false if after - first < "SKIP".bytesize
      return false unless slice_equals?(first, first + "SKIP".bytesize, "SKIP")
      cursor = first + "SKIP".bytesize
      cursor == after || whitespace?(@bytes[cursor])
    end

    private def canonical_declaration_bytes(
      fields : Hash(String, BinaryDataType),
      skip_paths : Array(String),
      max_dynamic_paths : Int32,
      max_dynamic_types : Int32,
    ) : UInt64
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
        size = checked_add(size, JsonPathSqlName.canonical_size(path.to_slice))
        type_bytes = ObjectTypedFieldType.byte_size_for(type, @limits, 2) || unsupported!("unsupported Object JSON typed field type")
        size = checked_add(size, checked_add(1_u64, type_bytes))
        argument_count += 1_u64
      end
      previous_skip_path : String? = nil
      skip_paths.each do |path|
        next if previous_skip_path == path
        size = checked_add(size, 2_u64) if argument_count > 0_u64
        size = checked_add(size, "SKIP ".bytesize.to_u64)
        size = checked_add(size, JsonPathSqlName.canonical_size(path.to_slice, quote_skip_keyword: false))
        argument_count += 1_u64
        previous_skip_path = path
      end
      if argument_count > 0_u64
        size = checked_add(size, 2_u64)
      end
      size
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

    private def unsupported!(message : String) : NoReturn
      raise UnsupportedFormatError.new(message)
    end
  end
end
